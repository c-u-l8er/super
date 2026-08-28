defmodule Ampd.TransportTest do
  @moduledoc """
  The C1.1 acceptance battery, run **through the socket** rather than
  against `Ampd.Control`.

  The distinction is the point of the milestone. Everything up to C1.1.2
  proved the semantics of a command issued against a peer handle; nothing
  proved that a *connection* could only ever produce the commands its
  identity is allowed to produce, because there were no connections. These
  tests speak JSON over a Unix domain socket to a listener the runtime
  created, exactly as the Rust host does.
  """
  use ExUnit.Case, async: false
  alias Ampd.{Authority, Bridge, Frame, GrantRegistry}

  setup do
    Ampd.reset_demo()
    Bridge.reset()
    Ampd.Peer.reset()

    # `Bridge.reset/0` sends `:stop` to each channel; the connection then
    # tears itself down in its own process. That is concurrent with the
    # next test starting, so a test asserting "one subscriber" could see
    # the previous test's still draining. Wait for the world to be quiet
    # rather than assume it — an intermittent failure in a harness is worse
    # than a slow one.
    drain_subscriptions(200)
    Process.put(:pushes, [])
    :ok
  end

  defp drain_subscriptions(0), do: flunk("subscriptions did not drain between tests")

  defp drain_subscriptions(n) do
    if Ampd.Subscriptions.count() == 0 do
      :ok
    else
      Process.sleep(10)
      drain_subscriptions(n - 1)
    end
  end

  # ----------------------------------------------------------- a client
  #
  # Speaks the same length-prefixed protocol the Rust host does, over one
  # end of a descriptor pair. There is no path to connect to — the runtime
  # never publishes one — so the test holds the client end from the moment
  # the pair exists, exactly as the host does.
  defp recv(s, timeout \\ 3_000) do
    case :socket.recv(s, 4, timeout) do
      {:ok, <<n::big-32>>} ->
        case :socket.recv(s, n, timeout) do
          {:ok, body} -> JSON.decode!(body)
          {:error, why} -> {:error, why}
        end

      {:error, why} ->
        {:error, why}
    end
  end

  defp drain_socket(s) do
    case recv(s, 120) do
      {:error, _} -> :ok
      _ -> drain_socket(s)
    end
  end

  defp raw(s, map) do
    body = JSON.encode!(map)
    :socket.send(s, <<byte_size(body)::big-32>> <> body)
    recv(s)
  end

  # **The test client demultiplexes, because the protocol requires it.**
  #
  # After `subscribe`, a channel is full-duplex: a pushed projection can
  # land between a command being written and its answer coming back, so
  # "the next frame is my reply" is false. That assumption is what made the
  # F.6 Rust host read a projection as the result of `operator_projection`
  # and score a check for the wrong reason — and this client had exactly
  # the same bug, which showed up as intermittent failures rather than as a
  # wrong answer, because a test that reads the wrong frame usually just
  # fails confusingly.
  #
  # So: correlate on `client_request_id`, and stash anything that is not
  # this call's answer where `push_after/3` can find it.
  defp call(s, command, args \\ %{}, crid \\ nil) do
    id = crid || "t#{System.unique_integer([:positive])}"
    body = JSON.encode!(%{"schema" => "command@1", "command" => command, "args" => args,
                          "client_request_id" => id})

    :socket.send(s, <<byte_size(body)::big-32>> <> body)
    await_reply(s, id, 60)
  end

  defp await_reply(_s, id, 0), do: flunk("no reply to #{id}")

  defp await_reply(s, id, tries) do
    case recv(s) do
      %{"schema" => "reply@1", "client_request_id" => ^id} = f ->
        f

      # A frame-level refusal could not echo an id — the frame it refused
      # was never decoded — and with one command in flight it is ours.
      %{"schema" => "reply@1", "client_request_id" => nil} = f ->
        f

      %{"schema" => "projection-snapshot@1"} = p ->
        stash(p)
        await_reply(s, id, tries - 1)

      other ->
        other
    end
  end

  defp stash(p), do: Process.put(:pushes, Process.get(:pushes, []) ++ [p])

  # The same rule the Rust dispatcher applies. `Ampd.Subscriptions`
  # coalesces over a short window, so a timer armed by an earlier mutation
  # can fire after this one subscribed and deliver a projection at the
  # revision already held. Read until the world has actually moved past
  # `base` rather than taking the first thing that arrives.
  defp push_after(s, base, tries \\ 40)
  defp push_after(_s, base, 0), do: flunk("no projection past revision #{base}")

  defp push_after(s, base, tries) do
    stashed = Process.get(:pushes, [])

    case Enum.find(stashed, &(&1["revision"] > base)) do
      nil ->
        Process.put(:pushes, [])

        case recv(s, 1_500) do
          %{"schema" => "projection-snapshot@1", "revision" => r} = f when r > base -> f
          %{"schema" => "projection-snapshot@1"} -> push_after(s, base, tries - 1)
          other -> other
        end

      found ->
        Process.put(:pushes, stashed -- [found])
        found
    end
  end

  defp agent_channel(actor \\ "kestrel") do
    {runtime_end, client_end} = Ampd.Transport.socketpair()
    {:ok, _pid, _peer} = Bridge.adopt_channel(runtime_end, :agent, actor)
    {client_end, recv(client_end), nil}
  end

  defp control_channel do
    {runtime_end, client_end} = Ampd.Transport.socketpair()

    case Bridge.adopt_channel(runtime_end, :human_control) do
      {:ok, _pid, _peer} -> {client_end, recv(client_end), nil}
      {:refused, r} -> {:refused, r}
    end
  end

  # ------------------------------------------------------------- hello
  test "a connection is told what it is before it asks anything" do
    {s, hello, _} = agent_channel()

    assert hello["schema"] == "hello@1"
    assert hello["channel"] == "agent"
    assert hello["actor"] == "kestrel"
    assert hello["max_frame_bytes"] == Frame.max_bytes()
    assert is_integer(hello["revision"])
    assert "request_grant" in hello["commands"]

    # The commands it is told about are exactly the commands it may send.
    refute "revoke_grant" in hello["commands"]

    :socket.close(s)
  end

  # -------------------------------------------- identity is the connection
  test "the connection determines the actor, and no frame can say otherwise" do
    {s, _hello, _} = agent_channel("kestrel")

    proj = call(s, "agent_projection")["result"]
    assert proj["actor"] == "kestrel"

    # A human command on an agent channel is refused by channel, before
    # its arguments are ever considered.
    r = call(s, "revoke_grant", %{"grant_id" => "gr_0193"})["result"]
    refute r["allow"]
    assert r["refusal"]["code"] == "human-consent-required"

    # **Unphrasable, not refused-after-validation.** There is no field in
    # `command@1` in which to claim an identity; a frame carrying one is
    # rejected as a frame.
    for field <- ~w(actor peer_id channel) do
      bad =
        raw(s, %{"schema" => "command@1", "command" => "agent_projection",
                 "args" => %{}, field => "mallory"})

      refute bad["result"]["allow"]
      assert bad["result"]["refusal"]["code"] == "identity-not-claimable"
    end

    # And the channel still is what it was.
    assert call(s, "agent_projection")["result"]["actor"] == "kestrel"
    :socket.close(s)
  end

  test "two agent channels see only their own world" do
    {k, _, _} = agent_channel("kestrel")
    {m, _, _} = agent_channel("mallory")
    Authority.mint(%{"capability" => "github.repo.read", "actor" => "mallory"})

    kp = call(k, "agent_projection")["result"]
    mp = call(m, "agent_projection")["result"]

    assert Enum.all?(kp["grants"], &(&1["actor"] == "kestrel"))
    assert Enum.all?(mp["grants"], &(&1["actor"] == "mallory"))
    assert mp["grants"] != []

    # The authority snapshot is a digest over every grant on the machine,
    # so watching it change is a side channel. It is not in either.
    refute Map.has_key?(kp, "authority_snapshot")
    refute Map.has_key?(mp, "authority_snapshot")

    :socket.close(k)
    :socket.close(m)
  end

  # --------------------------------------------------- the control channel
  test "the human control channel is opened once" do
    {s, hello, _} = control_channel()
    assert hello["channel"] == "human_control"
    assert hello["actor"] == nil

    {runtime2, _client2} = Ampd.Transport.socketpair()
    assert {:refused, r} = Bridge.adopt_channel(runtime2, :human_control)
    assert r["code"] == "control-channel-already-claimed"

    assert call(s, "operator_projection")["result"]["schema"] == "operator-projection@2"
    :socket.close(s)
  end

  # **The defect that only a separate OS process could surface.**
  #
  # "The control channel is claimed" is held in two places, freed by two
  # different events: `Ampd.Peer` frees its claim when the peer detaches,
  # and `Ampd.Bridge` used to clear `control_open` only on an explicit
  # `close_channel/1`. This test previously *called* `close_channel/1` by
  # hand after closing the socket — so the two locks were never given the
  # chance to disagree, and the suite was green while a host that simply
  # closed its window could never take the control channel again.
  #
  # Found by the Rust host doing what a host actually does: closing a file
  # descriptor. The manual call is gone, and its absence is the assertion.
  test "closing the control socket frees the claim everywhere it is held" do
    {s, _, _} = control_channel()
    {rt2, _c2} = Ampd.Transport.socketpair()
    assert {:refused, _} = Bridge.adopt_channel(rt2, :human_control)

    :socket.close(s)
    Process.sleep(200)

    assert {c3, hello3, _} = control_channel(),
           "the descriptor closed but the bridge still believed a channel was active"

    assert hello3["channel"] == "human_control"
    :socket.close(c3)
  end

  # ------------------------------------------- nothing to find, nothing to race
  #
  # The first C1.1 transport put a socket file per identity in a `0700`
  # directory. Every process here runs as the same OS user and can
  # `readdir`, so the identity law degraded from "whoever connects is
  # Kestrel because the listener was for Kestrel" to **first connector
  # wins** — and the bridge socket was worse, because whoever won that one
  # could ask for the human control channel.
  #
  # There is now no file. This walks the directories a same-user process
  # would search and asserts there is nothing there to open.
  test "a same-user process has no path to any channel" do
    {k, _, _} = agent_channel("kestrel")
    {h, _, _} = control_channel()

    # Channels are live and serving.
    assert call(k, "agent_projection")["result"]["actor"] == "kestrel"
    assert call(h, "operator_projection")["result"]["schema"] == "operator-projection@2"

    searchable =
      [System.get_env("XDG_RUNTIME_DIR"), System.tmp_dir!(), File.cwd!()]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    # **Descends.** The first version of this only looked at top-level
    # entries, so a socket left inside `ampd-pair-<rand>/` was invisible to
    # it — the sabotage probe that leaks one passed with the fix disabled,
    # which is the harness catching the test rather than the code.
    leaked = Enum.flat_map(searchable, &sockets_under(&1, 2, true))

    assert leaked == [],
           "the runtime left something on the filesystem a same-user process could open: " <>
             inspect(leaked)

    # And the bridge does not hand out paths at all — a channel record
    # names its identity and its peer, never a place.
    for ch <- Bridge.list() do
      refute Map.has_key?(ch, "path"), "a channel record still carries a path"
    end

    :socket.close(k)
    :socket.close(h)
  end

  # At the top level only things named for this runtime are ours to judge —
  # the box has plenty of unrelated sockets, and a test that fails on
  # someone else's is a test that will be disabled. Inside one of our own
  # directories, anything counts.
  defp sockets_under(_dir, 0, _), do: []

  defp sockets_under(dir, depth, ours_only) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(not ours_only or String.contains?(&1, "ampd")))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.flat_map(fn p ->
          case File.stat(p) do
            {:ok, %File.Stat{type: :directory}} -> sockets_under(p, depth - 1, false)
            {:ok, %File.Stat{type: :other}} -> [p]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end


  test "binding a channel requires the channel, not just its name" do
    # The bridge protocol has no shape in which an actor is named without
    # the descriptor it names being handed over in the same message.
    assert {:refused, r} = Bridge.adopt_channel(:not_a_descriptor, :agent, "kestrel")
    assert r["code"] == "channel-adopt-failed"

    assert {:refused, r2} = Bridge.adopt_channel(-1, :agent, "kestrel")
    assert r2["code"] == "channel-adopt-failed"
  end

  # ------------------------------------------------- the runtime pushes
  test "the UI does not poll: a mutation pushes a new projection" do
    {s, hello, _} = control_channel()

    sub = call(s, "subscribe")["result"]
    assert sub["schema"] == "projection-snapshot@1"
    assert sub["revision"] >= hello["revision"]
    base = sub["revision"]

    # Nobody asks for anything. The world moves.
    g = Authority.mint(%{"capability" => "github.pr.create", "actor" => "kestrel"})

    push = push_after(s, base)
    assert push["schema"] == "projection-snapshot@1"
    assert push["revision"] > base, "the revision did not advance with the mutation"
    assert Enum.any?(push["projection"]["grants"], &(&1["id"] == g["id"]))
    assert push["world_generation"] == hello["world_generation"]

    :socket.close(s)
  end

  test "a burst sends one frame and still reports every mutation" do
    {s, _hello, _} = control_channel()
    base = call(s, "subscribe")["result"]["revision"]

    for i <- 1..6, do: Authority.mint(%{"capability" => "github.pr.create", "actor" => "burst#{i}"})

    push = push_after(s, base)
    # Coalesced pushes, uncoalesced revisions: the client is not told six
    # times, and is still told that six things happened.
    assert push["revision"] >= base + 6

    :socket.close(s)
  end

  test "an agent is pushed its own projection, not the operator's" do
    {s, _hello, _} = agent_channel("kestrel")
    sub = call(s, "subscribe")["result"]
    assert sub["projection"]["schema"] == "agent-projection@2"

    base = sub["revision"]
    Authority.mint(%{"capability" => "github.pr.create", "actor" => "kestrel"})
    push = push_after(s, base)
    assert push["projection"]["schema"] == "agent-projection@2"
    refute Map.has_key?(push["projection"], "peers")
    refute Map.has_key?(push["projection"], "seals")

    :socket.close(s)
  end

  # ---------------------------------------------- close, reopen, same world
  test "close and reopen reaches the same durable world" do
    {s, _hello, _} = control_channel()

    g = Authority.mint(%{"capability" => "github.pr.create", "actor" => "kestrel"})
    before = call(s, "operator_projection")["result"]
    assert Enum.any?(before["grants"], &(&1["id"] == g["id"]))

    :socket.close(s)
    Process.sleep(200)

    # Kill the registry so the reopened channel cannot be reading a cached
    # process state — the world has to come back off disk.
    old = Process.whereis(GrantRegistry)
    Process.exit(old, :kill)
    wait_back(GrantRegistry, old, 100)

    {s2, hello2, _} = control_channel()
    after_ = call(s2, "operator_projection")["result"]

    assert Enum.any?(after_["grants"], &(&1["id"] == g["id"])),
           "the world did not survive close/reopen"

    assert hello2["world_generation"] == before["world"]["lineage"]["generation"],
           "the world generation moved without a restore"

    :socket.close(s2)
  end

  # **The asymmetry: invalid for commands, still valid for information.**
  #
  # `Ampd.Subscriptions` used to store the whole `peer@1` record and build
  # every push from it. So when `Ampd.Peer` died the binding was gone, the
  # connection's commands correctly refused `unknown-peer`, and the cached
  # record went on producing Kestrel's projection for a channel that was no
  # longer Kestrel's. Reproduced before it was fixed:
  #
  #     a COMMAND on the old socket → unknown-peer
  #     an unrelated mutation       → the same socket received
  #                                   agent-projection@1 for actor "kestrel"
  #
  # Two fixes, and this asserts both: the connection monitors `Ampd.Peer`
  # and closes when it dies, and `Ampd.Subscriptions` re-resolves the
  # binding before every push instead of trusting a copy of it.
  test "a dead Peer takes its channels with it, including their subscriptions" do
    {s, _hello, _} = agent_channel("kestrel")
    assert call(s, "agent_projection")["result"]["actor"] == "kestrel"
    assert call(s, "subscribe")["result"]["projection"]["schema"] == "agent-projection@2"

    old = Process.whereis(Ampd.Peer)
    Process.exit(old, :kill)
    wait_back(Ampd.Peer, old, 100)
    Process.sleep(120)

    # An unrelated mutation. Nothing this socket asked for, and nothing
    # that belongs to it.
    Authority.mint(%{"capability" => "github.pr.create", "actor" => "mallory"})

    # The socket is closed, not merely refusing. Anything it still received
    # would be a private projection delivered to an identity that no longer
    # exists.
    assert recv(s, 1_500) == {:error, :closed},
           "an invalidated channel was still receiving projections"

    # And the subscription is gone from the runtime's side too, so a later
    # mutation has nobody to deliver to.
    Authority.mint(%{"capability" => "github.pr.create", "actor" => "mallory2"})
    Process.sleep(80)
    assert Ampd.Subscriptions.count() == 0
  end

  test "subscribing on a binding that has already gone is refused, not cached" do
    {s, _hello, _} = agent_channel("kestrel")
    peer = Ampd.Peer.list() |> Enum.find(&(&1["actor"] == "kestrel"))
    Ampd.Peer.detach(peer["id"])

    r = Ampd.Subscriptions.subscribe(peer)
    refute r["allow"]
    assert r["refusal"]["code"] == "unknown-peer"
    assert Ampd.Subscriptions.count() == 0

    :socket.close(s)
  end

  # ------------------------------------------------------- hostile bytes
  test "a hostile frame is a refusal, and the connection survives it" do
    {s, _hello, _} = agent_channel()

    hostile = [
      "not json",
      "[1,2,3]",
      JSON.encode!(%{"schema" => "command@1", "command" => "Elixir.System", "args" => ["halt"]}),
      JSON.encode!(%{"schema" => "command@1", "command" => "preflight", "args" => 42}),
      JSON.encode!(%{"schema" => "command@9", "command" => "runtime_status"}),
      JSON.encode!(%{"schema" => "command@1", "command" => "request_grant",
                     "args" => %{"capability" => "github.pr.draft", "resource" => "traaviis/trvm",
                                 "options" => %{"reason" => String.duplicate("A", 100_000)}}})
    ]

    for bytes <- hostile do
      :socket.send(s, <<byte_size(bytes)::big-32>> <> bytes)
      reply = recv(s)
      assert reply["schema"] == "reply@1", "#{String.slice(bytes, 0, 30)} did not answer"
      refute reply["result"]["allow"]
      assert is_binary(reply["result"]["refusal"]["correlation_id"])
    end

    # Still alive and still itself.
    assert call(s, "agent_projection")["result"]["actor"] == "kestrel"
    :socket.close(s)
  end

  test "the atom table does not grow, whatever a socket sends" do
    {s, _hello, _} = agent_channel()
    call(s, "warmup")
    before = :erlang.system_info(:atom_count)

    for i <- 1..300, do: call(s, "no_such_command_#{i}")

    assert :erlang.system_info(:atom_count) == before,
           "the socket interned atoms from wire input"

    :socket.close(s)
  end

  test "an oversized frame is refused by the driver, and the runtime survives" do
    {s, _hello, _} = agent_channel()

    # 300 KB, over the 256 KB frame limit. `packet_size` means the driver
    # refuses after reading the 4-byte length — the body is never copied
    # into the VM.
    big = String.duplicate("A", 300 * 1024)
    :socket.send(s, <<byte_size(big)::big-32>> <> big)

    case recv(s, 2_000) do
      {:error, _closed} -> :ok
      %{"result" => r} -> assert r["refusal"]["code"] == "frame-too-large"
    end

    # The runtime is unharmed: a fresh channel still works.
    {s2, hello2, _} = agent_channel("kestrel")
    assert hello2["schema"] == "hello@1"
    assert call(s2, "agent_projection")["result"]["actor"] == "kestrel"

    :socket.close(s)
    :socket.close(s2)
  end

  # ------------------------------------------- the full loop, over the wire
  test "request, approve, and revoke — the whole loop through two sockets" do
    {h, _, _} = control_channel()
    {k, _, _} = agent_channel("kestrel")

    call(h, "subscribe")

    # The agent asks. It receives no authority.
    q = call(k, "request_grant", %{"capability" => "github.pr.create", "resource" => "traaviis/trvm",
                                   "options" => %{"duration" => "run", "reason" => "close the argv boundary"}})["result"]

    refute q["allow"]
    assert q["held"]
    id = q["grant_request"]["id"]

    # The operator sees it pushed, without asking.
    push = recv(h)
    assert Enum.any?(push["projection"]["grant_requests"], &(&1["id"] == id))

    # An agent cannot approve its own request — the command is not on its
    # channel at all.
    self_approve = call(k, "approve_grant_request", %{"request_id" => id})["result"]
    assert self_approve["refusal"]["code"] == "human-consent-required"

    # The person approves, narrowing.
    ok = call(h, "approve_grant_request", %{"request_id" => id, "duration" => "once"})["result"]
    assert ok["allow"]
    gid = ok["granted"]["id"]
    assert ok["granted"]["duration"] == "once"

    # The agent is told, and can now exercise it.
    kproj = call(k, "agent_projection")["result"]
    assert Enum.any?(kproj["grants"], &(&1["id"] == gid))

    # The operator revokes exactly that grant, by id.
    rev = call(h, "revoke_grant", %{"grant_id" => gid})["result"]
    assert rev["allow"]
    assert rev["revoked"] == gid

    kproj2 = call(k, "agent_projection")["result"]
    refute Enum.any?(kproj2["grants"], &(&1["id"] == gid))

    :socket.close(h)
    :socket.close(k)
  end

  test "bulk revocation over the wire names its exact set" do
    {h, _, _} = control_channel()
    Authority.mint(%{"capability" => "github.repo.read", "actor" => "mallory"})

    scope = %{"capability" => "github.repo.read"}
    ids = GrantRegistry.matching(scope) |> Enum.map(& &1["id"]) |> Enum.sort()

    stale = call(h, "revoke_capability_domain", %{"scope" => scope, "expected_ids" => [hd(ids)]})["result"]
    refute stale["allow"]
    assert stale["refusal"]["code"] == "bulk-scope-changed"

    ok = call(h, "revoke_capability_domain", %{"scope" => scope, "expected_ids" => ids})["result"]
    assert ok["allow"]
    assert ok["revoked"] == ids

    :socket.close(h)
  end


  # ------------------------------------------------ projection continuity
  # **`revision` is not a fact about the world on its own.** `ops/0` counts
  # this incarnation's ordered mutations and resets to 0 when the
  # coordinator restarts — while `world_generation` does not, because the
  # world on disk did not change. Reproduced: generation 1 revision 7 →
  # generation 1 revision 0. A client holding the first cannot read the
  # second: same world, smaller number.
  test "a coordinator restart changes the epoch rather than rewinding the revision" do
    {s, hello, _} = control_channel()
    call(s, "subscribe")

    for i <- 1..5, do: Authority.mint(%{"capability" => "github.pr.create", "actor" => "rev#{i}"})

    before = call(s, "operator_projection")
    assert before["revision"] > hello["revision"]
    assert before["projection_epoch"] == hello["projection_epoch"]
    assert before["world_generation"] == hello["world_generation"]

    old = Process.whereis(Ampd.AuthorityCoordinator)
    Process.exit(old, :kill)
    wait_back(Ampd.AuthorityCoordinator, old, 100)

    Authority.mint(%{"capability" => "github.pr.create", "actor" => "after"})
    now = call(s, "operator_projection")

    # The revision did go backwards. That is allowed, and it is exactly why
    # it cannot be the only continuity field.
    assert now["revision"] < before["revision"]
    assert now["world_generation"] == before["world_generation"],
           "the durable world did not change, so its generation must not"

    assert now["projection_epoch"] != before["projection_epoch"],
           "the revision rewound inside an unchanged world and nothing said so"

    :socket.close(s)
  end

  test "every frame that carries a revision carries the whole triple" do
    {s, hello, _} = control_channel()
    keys = ~w(world_generation projection_epoch revision)

    for f <- [hello, call(s, "operator_projection"), call(s, "subscribe")] do
      for k <- keys, do: assert(Map.has_key?(f, k), "#{f["schema"]} is missing #{k}")
    end

    Authority.mint(%{"capability" => "github.pr.create", "actor" => "kestrel"})
    push = push_after(s, hello["revision"])
    for k <- keys, do: assert(Map.has_key?(push, k), "the push is missing #{k}")

    :socket.close(s)
  end


  # ------------------------------------------------ a bounded live projection
  #
  # **This is not about corrupt data.** `operator-projection@1` carried
  # every effect and every receipt the world had ever produced, and both
  # grow without limit in a perfectly healthy world — a receipt is written
  # for every committed effect and nothing removes one. So the live
  # projection was on a path to exceeding one frame by ordinary use, at
  # which point the channel received `frame-too-large` instead of a world.
  test "a world with more history than fits in a frame still has a usable projection" do
    {s, _hello, _} = control_channel()

    # More receipts than the window, and more bytes than a frame would
    # hold if they all rode along.
    big = String.duplicate("x", 4_000)
    n = 140

    for i <- 1..n do
      Ampd.AuthorityCoordinator.transact(fn ->
        Ampd.Receipts.emit(%{"actor" => "kestrel", "capability" => "github.pr.create",
                               "effect_ref" => "ef_#{i}", "note" => big})
      end)
    end

    assert Ampd.Receipts.count() == n

    op = call(s, "operator_projection")
    assert op["result"]["schema"] == "operator-projection@2",
           "the projection did not survive a world with real history"

    r = op["result"]["receipts"]
    assert length(r["recent"]) == Ampd.Projection.history_window()
    assert r["total"] == n
    assert r["more"] == true
    assert is_binary(r["next_cursor"])

    # The window says how much it is a window onto. That is the difference
    # between an explicit bounded projection and one that lies by omission.
    assert r["total"] > length(r["recent"])

    # And the rest is a cursor away, newest first, without repeats.
    page1 = call(s, "list_receipts", %{"limit" => 40})["result"]
    assert page1["schema"] == "history-page@1"
    assert length(page1["items"]) == 40
    assert page1["total"] == n

    page2 = call(s, "list_receipts", %{"cursor" => page1["next_cursor"], "limit" => 40})["result"]
    assert length(page2["items"]) == 40

    ids1 = Enum.map(page1["items"], & &1["id"])
    ids2 = Enum.map(page2["items"], & &1["id"])
    assert ids1 == Enum.sort(ids1, :desc), "a page must be newest first"
    assert MapSet.disjoint?(MapSet.new(ids1), MapSet.new(ids2)), "pages overlapped"

    # Every page says which world it came from, so pages from either side
    # of a restore cannot be stitched into a history that never happened.
    for pg <- [page1, page2] do
      for k <- ~w(world_generation projection_epoch revision) do
        assert Map.has_key?(pg, k), "a history page is missing #{k}"
      end
    end

    :socket.close(s)
  end

  test "an agent pages only its own history" do
    {k, _, _} = agent_channel("kestrel")

    for i <- 1..5 do
      Ampd.AuthorityCoordinator.transact(fn ->
        Ampd.Receipts.emit(%{"actor" => "kestrel", "effect_ref" => "ef_k#{i}"})
        Ampd.Receipts.emit(%{"actor" => "mallory", "effect_ref" => "ef_m#{i}"})
      end)
    end

    page = call(k, "list_receipts", %{})["result"]
    assert page["total"] == 5
    assert Enum.all?(page["items"], &(&1["actor"] == "kestrel"))

    :socket.close(k)
  end


  # **Isolates the `Ampd.Subscriptions` half of the fix.** When
  # `Ampd.Peer` dies, the connection's own monitor closes the socket — so
  # that path would stay green even if subscriptions still served from a
  # cached identity. Here the binding is detached while `Ampd.Peer` is
  # perfectly healthy, so nothing tears the connection down and the only
  # thing that can catch it is re-resolving before the push.
  test "a subscription whose binding is detached stops being served" do
    {s, _hello, _} = agent_channel("kestrel")
    peer = Ampd.Peer.list() |> Enum.find(&(&1["actor"] == "kestrel"))

    assert call(s, "subscribe")["result"]["projection"]["actor"] == "kestrel"
    assert Ampd.Subscriptions.count() == 1

    Ampd.Peer.detach(peer["id"])
    assert Process.whereis(Ampd.Peer) != nil, "Ampd.Peer must be alive or this proves nothing"

    # **Drain before the mint, or this test blames the detach for a push
    # that predates it.**
    #
    # A push delivered while the subscription was still live is correct,
    # and it sits in the socket buffer until something reads it — so
    # `recv/2` at the end of the test could pick up a frame from before the
    # detach and report a private projection delivered to a detached
    # identity. Reproduced deterministically by emitting one `changed/0`
    # between the subscribe and the detach; it then fails every time.
    #
    # After the detach, `build/1` answers `:gone` for this id forever, so
    # nothing new can be pushed and anything read after this point is a
    # real violation. Found as a one-in-ten flake, which is the only kind
    # of failure this harness treats as worse than a slow one.
    Process.sleep(60)
    drain_socket(s)

    Authority.mint(%{"capability" => "github.pr.create", "actor" => "mallory"})
    Process.sleep(150)

    assert Ampd.Subscriptions.count() == 0,
           "a subscription outlived the binding it was granted under"

    refute match?(%{"schema" => "projection-snapshot@1"}, recv(s, 600)),
           "a private projection was delivered to a detached identity"

    :socket.close(s)
  end


  # **Evidence paging must be lossless.** The previous version of the test
  # above asserted the pages did not overlap and did not repeat — and both
  # were true while one record per page boundary was being dropped, because
  # `next_cursor` named the first *omitted* item and the fetch then dropped
  # everything `>= cursor`, cursor included. Reproduced over 120 records:
  # 118 returned, `rcpt-0070` and `rcpt-0019` gone.
  #
  # Not-overlapping and not-repeating are the easy half. This is the half
  # that matters: concatenating every page equals the history exactly once.
  test "paging the whole history returns every record exactly once" do
    {s, _hello, _} = control_channel()
    n = 137

    for i <- 1..n do
      Ampd.AuthorityCoordinator.transact(fn ->
        Ampd.Receipts.emit(%{"actor" => "kestrel", "effect_ref" => "ef_#{i}"})
      end)
    end

    all = Ampd.Receipts.all() |> Enum.map(& &1["id"]) |> Enum.sort(:desc)
    assert length(all) == n

    # Walk it the way a client would: follow next_cursor until it is nil.
    walked = drain(s, "list_receipts", nil, 17, [])

    assert walked == all,
           "paging lost or duplicated records: #{length(all)} exist, #{length(walked)} walked, " <>
             "missing #{inspect(all -- walked)}, extra #{inspect(walked -- all)}"

    assert length(Enum.uniq(walked)) == length(walked), "a record was returned twice"

    # The same must hold at a page size that divides the total exactly —
    # that is where an off-by-one at the boundary hides best.
    assert drain(s, "list_receipts", nil, 1, []) == all
    :socket.close(s)
  end

  defp drain(s, cmd, cursor, limit, acc) do
    args = if cursor, do: %{"cursor" => cursor, "limit" => limit}, else: %{"limit" => limit}
    p = call(s, cmd, args)["result"]
    acc = acc ++ Enum.map(p["items"], & &1["id"])

    if p["next_cursor"], do: drain(s, cmd, p["next_cursor"], limit, acc), else: acc
  end

  # The window a live projection carries hands out a cursor too, and it has
  # to mean the same thing the paged command means — the two disagreeing is
  # exactly what dropped a record.
  test "a projection window's cursor resumes without a gap" do
    {s, _hello, _} = control_channel()

    for i <- 1..70 do
      Ampd.AuthorityCoordinator.transact(fn ->
        Ampd.Receipts.emit(%{"actor" => "kestrel", "effect_ref" => "ef_w#{i}"})
      end)
    end

    w = call(s, "operator_projection")["result"]["receipts"]
    assert w["more"] == true

    rest = drain(s, "list_receipts", w["next_cursor"], 50, [])
    shown = Enum.map(w["recent"], & &1["id"])

    all = Ampd.Receipts.all() |> Enum.map(& &1["id"]) |> Enum.sort(:desc)
    assert shown ++ rest == all,
           "the window's cursor skipped #{inspect(all -- (shown ++ rest))}"

    :socket.close(s)
  end

  # **The agent projection is the one an untrusted party controls the size
  # of.** It carried every request the actor had ever made, resolved
  # included, so request-and-resolve cycles grew it without bound.
  test "an agent cannot grow its own projection without bound" do
    {h, _, _} = control_channel()
    {k, _, _} = agent_channel("kestrel")

    for _ <- 1..80 do
      q = call(k, "request_grant", %{"capability" => "github.pr.create",
                                     "resource" => "traaviis/trvm"})["result"]

      call(h, "deny_grant_request", %{"request_id" => q["grant_request"]["id"], "note" => "no"})
    end

    proj = call(k, "agent_projection")["result"]
    assert proj["grant_requests"] == [], "resolved requests stayed in the live queue"

    hist = proj["grant_requests_history"]
    assert hist["total"] == 80
    assert length(hist["recent"]) == Ampd.Projection.history_window()
    assert hist["more"] == true

    # And an agent pages only its own.
    walked = drain(k, "list_grant_requests", nil, 25, [])
    assert length(walked) == 80
    assert length(Enum.uniq(walked)) == 80

    :socket.close(h)
    :socket.close(k)
  end


  # Descriptor *ownership* is measured where it actually happens — in
  # `super-host verify`, against `/proc/<ampd>/fd` across real SCM_RIGHTS
  # binds. A test here cannot reach it: `Ampd.Transport.socketpair/1`
  # hands back a socket *handle*, so `adopt_channel/3` takes the handle
  # branch and never the integer one that `dup` applies to. A test that
  # exercises the wrong branch and reports success is worse than no test,
  # and this one did until it was measured.

  # **The mirror image of the host's confinement test.** That one proves a
  # process the *host* spawns inherits only its own channel. This one asks
  # the same of a process the *runtime* spawns.
  #
  # Declared an invariant check, not a falsifier, and the distinction is
  # load-bearing: it passes on this OTP whether or not our own measures are
  # in place, because `erl_child_setup` closes every descriptor above 2
  # before `exec`. So it cannot be falsified by removing `cmsg_cloexec` or
  # `dup: false` — it asserts the property holds, not that our code is what
  # makes it hold. Counting it as a falsifier would be claiming evidence
  # this round does not have.
  test "a process the runtime spawns sees none of the runtime's channels" do
    {k, _, _} = agent_channel("kestrel")
    {m, _, _} = agent_channel("mallory")
    {h, _, _} = control_channel()

    assert call(k, "agent_projection")["result"]["actor"] == "kestrel"
    assert call(h, "operator_projection")["result"]["schema"] == "operator-projection@2"

    port =
      Port.open(
        {:spawn, ~s(/bin/sh -c 'for f in /proc/self/fd/*; do readlink "$f"; done')},
        [:binary, :exit_status, :stderr_to_stdout]
      )

    out = collect(port, "")

    sockets =
      out
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "socket:"))

    assert sockets == [],
           "a process the runtime spawned inherited #{length(sockets)} of its sockets: " <>
             inspect(sockets)

    Enum.each([k, m, h], &:socket.close/1)
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, d}} -> collect(port, acc <> d)
      {^port, {:exit_status, _}} -> acc
    after
      3_000 -> acc
    end
  end

  defp wait_back(_mod, _old, 0), do: flunk("process did not come back")

  defp wait_back(mod, old, n) do
    pid = Process.whereis(mod)

    if pid != nil and pid != old do
      :ok
    else
      Process.sleep(20)
      wait_back(mod, old, n - 1)
    end
  end
end
