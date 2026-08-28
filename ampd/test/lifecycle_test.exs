defmodule Ampd.LifecycleTest do
  @moduledoc """
  **A channel handoff is a transaction.**

      A channel is either committed to one live connection, or rolled back
      completely. There is no timed-out-but-still-starting state.

  F.8.2.1 closed `adopt_channel/3`'s ownership at the `Ampd.Bridge`
  boundary and said ownership then moved to the connection process. It did
  not: a `:socket` handle is owned by its `{otp, controlling_process}`, and
  that stayed `Ampd.Bridge`. So the startup was a bare `spawn` with no
  monitor, racing a `receive after 5_000` against a `GenServer.call` whose
  own default deadline is also `5_000`, and every abnormal exit fell
  through the gap.

  Unlike the descriptor rounds, this **is** reachable from inside the BEAM:
  it happens above raw-descriptor adoption, so a socket-handle channel
  exercises exactly the same code. All three were measured failing before
  they were fixed:

      Peer suspended  → host told `channel-bind-failed` at 5001 ms, and a
                        live `kestrel` binding appeared the moment the
                        suspension lifted
      killed bound    → socket open, bridge still listing the channel,
                        peer still resolving
      killed control  → `control-channel-already-claimed`, forever

  The third is not a leak. It is one crash taking the person's authority
  away and never giving it back.
  """
  use ExUnit.Case, async: false
  alias Ampd.{Bridge, NativeFd, Transport}

  setup do
    Ampd.reset_demo()
    Bridge.reset()
    Ampd.Peer.reset()
    Process.sleep(120)
    on_exit(fn -> File.rm_rf("/tmp/ampd-pair-x") end)
    :ok
  end

  # `close(2)` frees the *number*, and the next socket takes it — so a
  # descriptor's state has to be read before anything else opens one.
  # Getting this wrong made a passing fix look broken once already.
  defp fd!(sock) do
    {:ok, fd} = :socket.getopt(sock, :otp, :fd)
    fd
  end

  defp settled(fd, want, tries \\ 60)
  defp settled(fd, _want, 0), do: NativeFd.state(fd)

  defp settled(fd, want, tries) do
    case NativeFd.state(fd) do
      ^want -> want
      _ -> Process.sleep(25) && settled(fd, want, tries - 1)
    end
  end

  test "a connection killed after binding takes its socket, its channel and its identity with it" do
    {runtime_end, _client} = Transport.socketpair()
    fd = fd!(runtime_end)
    {:ok, pid, peer_id} = Bridge.adopt_channel(runtime_end, :agent, "kestrel")

    assert length(Bridge.list()) == 1
    assert Ampd.Peer.resolve(peer_id) != nil

    Process.exit(pid, :kill)

    assert settled(fd, :closed) == :closed,
           "the socket outlived the connection — nothing but Ampd.Bridge could have closed it"

    assert Bridge.list() == [],
           "the bridge is still serving a channel whose connection is dead"

    assert Ampd.Peer.resolve(peer_id) == nil,
           "an identity outlived the connection that held it"
  end

  test "a killed human control channel does not lock the person out of their own world" do
    {runtime_end, _client} = Transport.socketpair()
    fd = fd!(runtime_end)
    {:ok, pid, _} = Bridge.adopt_channel(runtime_end, :human_control, nil)

    Process.exit(pid, :kill)
    assert settled(fd, :closed) == :closed

    # The claim is held in two places — `Ampd.Peer.control_claimed` and
    # `Ampd.Bridge.control_open` — and an abnormal exit used to free
    # neither. Both, or the person never gets their channel back.
    {second, _} = Transport.socketpair()

    assert {:ok, _, _} = Bridge.adopt_channel(second, :human_control, nil),
           "one crash took the human control channel away permanently"
  end

  test "a startup that outlives its deadline is rolled back before the caller is told" do
    {runtime_end, _client} = Transport.socketpair()
    fd = fd!(runtime_end)

    # `:sys.suspend/1` is the whole point: it stops `Ampd.Peer` answering
    # without killing it, which is what a genuinely slow authority table
    # looks like from here.
    :sys.suspend(Ampd.Peer)
    result = Bridge.adopt_channel(runtime_end, :agent, "kestrel")

    assert {:refused, r} = result
    assert r["code"] == "channel-bind-failed"

    assert settled(fd, :closed) == :closed,
           "the socket survived a startup the caller was told had failed"

    :sys.resume(Ampd.Peer)
    Process.sleep(400)

    # **The one that is worse than a leak.** `GenServer.call`'s timeout is
    # the client's, not the server's: the call is still in `Ampd.Peer`'s
    # mailbox and it will be performed whenever it gets there. Measured —
    # a live `kestrel` binding appearing after the host had been told
    # `channel-bind-failed`. The host and the world disagreeing about who
    # is in it is a worse failure than any descriptor count.
    assert Ampd.Peer.list() == [],
           "the runtime committed an identity after telling the caller the bind failed"

    assert Bridge.list() == []
  end

  test "a refused channel has ceased to exist before the refusal is observable" do
    # Reach `Connection`'s own bind refusal rather than the bridge's fast
    # path: hold `Ampd.Peer`'s control claim here, so `Ampd.Bridge` still
    # believes the channel is available and the refusal happens one layer
    # in, after the socket has been handed over.
    {:ok, _held} = Ampd.Peer.claim_control_channel()

    {runtime_end, _client} = Transport.socketpair()
    fd = fd!(runtime_end)

    # **Nobody is reading the other end.** `socket:send/2` is the
    # infinity-timeout form, so a refusal written to this socket waits for
    # a reader that does not exist. The channel never committed, so there
    # is no reader by construction — which is why the refusal is not
    # written to it at all any more.
    chunk = :binary.copy("x", 65_536)

    Enum.reduce_while(1..200, 0, fn _, n ->
      case :socket.send(runtime_end, chunk, 80) do
        :ok -> {:cont, n + 1}
        _ -> {:halt, n}
      end
    end)

    t0 = System.monotonic_time(:millisecond)
    assert {:refused, r} = Bridge.adopt_channel(runtime_end, :human_control, nil)
    elapsed = System.monotonic_time(:millisecond) - t0

    assert r["code"] == "control-channel-already-claimed"

    # Measured at 1003 ms and `:inheritable` before this was fixed: the
    # refusal branch waited a flat second for `DOWN` and then returned
    # without rolling anything back.
    assert NativeFd.state(fd) == :closed,
           "the refusal was observable while the channel it refused still existed"

    assert elapsed < 900,
           "the refusal took #{elapsed} ms — it is waiting out a deadline it should not have"

    assert Bridge.list() == []
  end

  test "no channel outlives the world it was bound to" do
    {a_rt, _a_cl} = Transport.socketpair()
    a_fd = fd!(a_rt)
    {:ok, _apid, a_peer} = Bridge.adopt_channel(a_rt, :agent, "kestrel")

    {h_rt, _h_cl} = Transport.socketpair()
    h_fd = fd!(h_rt)
    {:ok, _hpid, _} = Bridge.adopt_channel(h_rt, :human_control, nil)

    assert length(Bridge.list()) == 2

    # The production path, not a test helper: this is what a person
    # re-initializing their world actually runs.
    Ampd.Bootstrap.reset_world!()

    # **Asserted immediately, with no polling, because the claim is a
    # barrier.** `reset_world!/0` returning means the channels of the
    # previous world are already gone — not that they will be shortly.
    # Polling for convergence here passes against a fire-and-forget reset
    # too, which is what the old implementation was, so it would measure
    # nothing.
    assert NativeFd.state(a_fd) == :closed,
           "an agent channel outlived its world — reset_world! returned before it was gone"

    assert NativeFd.state(h_fd) == :closed,
           "the human channel outlived its world — reset_world! returned before it was gone"
    assert Bridge.list() == [], "the bridge is still serving channels from the previous world"
    assert Ampd.Peer.resolve(a_peer) == nil
    assert Ampd.Subscriptions.count() == 0

    # **The one that makes it a product bug rather than a leak.** The claim
    # was held on behalf of a connection to a world that no longer existed,
    # so the person was refused a control channel in the world they had
    # just reset. World generation changed; capability generation did not.
    {fresh, _} = Transport.socketpair()

    assert {:ok, _, _} = Bridge.adopt_channel(fresh, :human_control, nil),
           "the person cannot take a control channel in the world they just reset"
  end

  test "a command queued behind a world reset cannot execute in the world that replaced it" do
    {rt, _cl} = Transport.socketpair()
    {:ok, conn, kestrel} = Bridge.adopt_channel(rt, :agent, "kestrel")
    coord = Process.whereis(Ampd.AuthorityCoordinator)

    # **Wait for the transactions, not for a number.** Two earlier versions
    # of this were wrong in the same direction — a wait that could not
    # fail. The first returned `:ok` from the exhausted loop as well as
    # from the halt, because `Process.sleep/1` returns `:ok`. The second
    # counted the mailbox, which a suspended coordinator also fills with
    # the `:ops` and `:epoch` calls a connection makes while building its
    # `hello@1` — so it reached two before either transaction had arrived,
    # resumed early, and the command came back `unknown-peer` from a world
    # that had already been reset. Both passed for reasons the test was not
    # measuring.
    queued = fn want ->
      Enum.reduce_while(1..300, false, fn _, _ ->
        {:messages, msgs} = Process.info(coord, :messages)
        n = Enum.count(msgs, &match?({:"$gen_call", _, {:tx, _, _}}, &1))

        if n >= want do
          {:halt, true}
        else
          Process.sleep(20)
          {:cont, false}
        end
      end)
    end

    # **Ordering, established rather than guessed.** Suspending the
    # coordinator lets both calls be *seen* in its mailbox before either
    # runs, so this is a deterministic witness and not a race the test
    # usually wins.
    :sys.suspend(coord)

    spawn(fn -> Ampd.Bootstrap.reset_world!() end)
    assert queued.(1), "the world reset never reached the coordinator"

    me = self()

    spawn(fn ->
      send(me, {:result,
        Ampd.Control.command(kestrel, :request_grant,
          ["github.pr.create", "acme/api", %{"reason" => "stale-world witness", "duration" => "run"}])})
    end)

    assert queued.(2), "the command never queued behind the reset"
    assert Process.alive?(conn), "the witness needs the connection alive when the reset is applied"

    :sys.resume(coord)

    result = receive do
      {:result, r} -> r
    after
      8_000 -> flunk("the command never returned")
    end

    # Killing the connection does not retract a message already in another
    # process's mailbox — the closure was queued, and it carries kestrel's
    # actor. Measured before the fence existed: the request appeared in the
    # new world, actor, capability and reason intact, in a world that never
    # had a kestrel.
    refute result["allow"]
    assert result["refusal"]["code"] == "world-incarnation-changed"

    assert Ampd.GrantRegistry.requests() == [],
           "a command from the previous world was written into the world that replaced it"
  end

  test "a factory reset is a different world, not the next revision of this one" do
    before_lineage = Ampd.World.lineage()
    before = Ampd.Projection.continuity()

    Ampd.Bootstrap.reset_world!()

    now_lineage = Ampd.World.lineage()
    now = Ampd.Projection.continuity()

    # The reset really did make a different world...
    assert before_lineage["installation_id"] != now_lineage["installation_id"]

    # ...and every field the continuity triple used to carry says otherwise.
    # `generation` restarts at 1 for a new installation, the coordinator
    # survives so `projection_epoch` does not move, and `revision` merely
    # advances because the reset was itself an ordered transaction. A client
    # holding those three would classify a brand-new world as the next
    # revision of the old one.
    assert before["world_generation"] == now["world_generation"]
    assert before["projection_epoch"] == now["projection_epoch"]
    assert now["revision"] > before["revision"]

    assert before["world_incarnation"] != now["world_incarnation"],
           "nothing in the continuity frame distinguishes this world from the one it replaced"
  end

  test "an identity does not outlive the process that asked for it" do
    # The rule underneath the case above, on its own, and **named for what
    # it measures**. It was called "an identity cannot be created for a
    # connection that is already gone", which is a different claim and one
    # this does not make: stubbing out `Ampd.Peer`'s dead-caller guard
    # leaves it green, because `Process.monitor/1` on a dead pid delivers
    # `DOWN` immediately and the binding is dropped one message later. What
    # this measures is the monitor.
    task = Task.async(fn -> Ampd.Peer.attach_agent("kestrel") end)
    assert {:ok, _id} = Task.await(task), "a live caller must still be able to attach"

    # The task has exited by now, so its identity goes with it.
    Process.sleep(200)

    assert Ampd.Peer.list() == [],
           "an identity outlived the process that asked for it"
  end
end
