defmodule Ampd.TerminalPossessionTest do
  @moduledoc """
  D.1.3c·2b·1 falsifiers — `K.1`..`K.24`.

  The proposition:

      A Peer possesses a terminal attachment only after two ordered
      re-derivations either side of a local owner transition, and the
      possession dies with the Carrier relation it is subordinate to, with
      the process that owns the stream, and with the process that owns the
      Peer binding. Owning the descriptor is not possessing the terminal;
      neither is a record that says COMMITTING.

  ## Why these drive the seams and not `acquire/1`

  `acquire/1` needs a host willing to hand back a real PTY stream, and
  `super-host verify` keeps that positive path against a real Carrier. What
  a host will *not* do is answer while the world moves underneath it, answer
  with a malformed identity, or die between B1 and B2 — so the fault matrix
  drives `admit_attach/1`, `own_stream/3`, `commit_b1/3`, `prepare/3` and
  `commit_b2/3` directly, with a socketpair standing in for the stream.

  That split is the same one D.1.3b made for the Carrier machine, and it is
  the reason a fabricated observation appears here at all: the shapes being
  falsified are shapes a correct host never produces.

  ## What every negative case proves

      1  it was refused
      2  by the expected name
      3  no ACTIVE record exists afterwards
      4  the stream is closed — measured, not assumed
  """
  use ExUnit.Case, async: false

  alias Ampd.{Authority, Bridge, Carrier, Control, Loci, Peer, Worker}
  alias Ampd.Carrier.Machine.Harness
  alias Ampd.Carrier.Terminal, as: T
  alias Ampd.TerminalAttachment, as: TA

  # ==================================================================== setup
  setup do
    if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()

    Ampd.reset()
    Bridge.reset()
    Peer.reset()
    Harness.reset()
    Application.delete_env(:ampd, :profile_overrides)
    Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Effector.Host)
    Application.put_env(:ampd, :carrier_machine, Harness)
    Ampd.Carrier.Machine.Gate.sync()

    on_exit(fn ->
      Application.delete_env(:ampd, :carrier_machine)
      Harness.reset()
    end)

    if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()
    Ampd.AuthorityCoordinator.transact(fn -> Loci.reset() end)
    Process.sleep(120)
    Authority.install_worktree()

    repo = init_repo!()
    {:ok, r} = Authority.register_repository(repo)

    {control, agent} = Ampd.attach_pair("kestrel")
    ws = ok!(Control.command(control, :open_workspace, ["acme"]), "workspace")
    goal = ok!(Control.command(control, :open_goal, [ws["id"], "possess a terminal"]), "goal")
    lane = ok!(Control.command(control, :open_lane, [goal["id"], "kestrel", r["ref"], nil]), "lane")
    w = ok!(Control.command(control, :open_worker, [lane["id"], "work"]), "worker")
    ok!(Control.command(agent, :attach_worker, [w["id"]]), "worker")

    {:ok, inc} = Carrier.start(agent, lane["id"])

    %{control: control, agent: agent, lane: lane, worker: w, inc: inc}
  end

  # ------------------------------------------------------------------ helpers

  # A well-formed host answer. Every field is the shape `host/src/attach.rs`
  # mints and `super-host verify` already measures the width of.
  defp obs(over \\ %{}) do
    Map.merge(
      %{
        "schema" => "carrier-pty-attach-observation@1",
        "attached" => true,
        "attachment_ref" => "ta_" <> hex(),
        "attachment_epoch" => hex(),
        "pty_epoch" => hex()
      },
      over
    )
  end

  defp hex, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp pair, do: Ampd.Transport.socketpair(:stream)

  defp closed?(s), do: :socket.getopt(s, :otp, :fd) == {:error, :closed}

  # Everything a successful acquisition does, minus the machine. Returns the
  # pieces each falsifier needs to interfere with.
  defp provision(agent) do
    {:ok, ticket} = T.admit_attach(agent)
    {mine, theirs} = pair()
    o = obs()
    {:ok, pid, identity} = T.own_stream(ticket, o, mine)
    %{ticket: ticket, obs: o, pid: pid, identity: identity, mine: mine, theirs: theirs}
  end

  defp possess!(agent) do
    p = provision(agent)
    {:ok, record} = T.commit_b1(p.ticket, p.obs, p.pid)
    :ok = TA.prepare(p.pid, Map.merge(record, p.identity), Peer.owner_pid(agent))
    {:ok, active} = T.commit_b2(p.ticket, record, p.pid)
    Map.merge(p, %{record: record, active: active})
  end

  defp dead!(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, _, _}, 3000
  end

  defp ok!(result, key) do
    assert result["allow"] == true,
           "expected #{key}, got: #{inspect(Map.take(result, ["allow", "reason", "refusal"]))}"

    result[key]
  end

  defp init_repo! do
    dir = Path.join(Ampd.Store.data_dir(), "fixture-repo-d13c2b1")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "README"), "d13c2b1\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.email", "d13c@example.invalid"],
          ["config", "user.name", "D13C"],
          ["config", "commit.gpgsign", "false"],
          ["add", "-A"],
          ["commit", "-q", "-m", "init"]
        ] do
      {_, 0} = System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)
    end

    dir
  end

  # ===================================================================== K.1
  describe "K.1 · a success whose physical identity is malformed is not a success" do
    test "a missing identity closes the one socket and returns a protocol failure" do
      {mine, theirs} = pair()

      bad = %{"schema" => "carrier-pty-attach-observation@1", "attached" => true}
      assert {:error, why} = T.interpret(bad, [mine])
      assert why =~ "physical identity"
      assert closed?(mine), "a malformed success kept the descriptor"

      :socket.close(theirs)
    end

    test "each of the three identities is checked, and by shape not presence" do
      for {k, v} <- [
            {"attachment_ref", String.duplicate("a", 32)},
            {"attachment_ref", "ta_" <> String.duplicate("A", 32)},
            {"attachment_epoch", "0123456789abcdef"},
            {"pty_epoch", "0123456789abcdef0123456789abcdeg"}
          ] do
        {mine, theirs} = pair()
        assert {:error, why} = T.interpret(obs(%{k => v}), [mine])
        assert why =~ k, "#{k}=#{v} was accepted or misreported: #{why}"
        assert closed?(mine)
        :socket.close(theirs)
      end
    end

    test "a malformed `refused` is malformed, not absent" do
      # The defect this closes: `is_binary(r) and r != ""` makes every
      # non-string `refused` indistinguishable from no `refused` at all.
      for v <- [0, true, false, %{}, [], ""] do
        {mine, theirs} = pair()
        assert {:error, why} = T.interpret(obs(%{"refused" => v}), [mine])
        assert why =~ "refused", "refused=#{inspect(v)} passed as a clean success"
        assert closed?(mine)
        :socket.close(theirs)
      end
    end

    test "a malformed `attached` is malformed too" do
      {mine, theirs} = pair()
      assert {:error, why} = T.interpret(obs(%{"attached" => "true"}), [mine])
      assert why =~ "attached"
      assert closed?(mine)
      :socket.close(theirs)
    end

    test "a well-formed success still passes" do
      {mine, theirs} = pair()
      assert {:ok, _o, ^mine} = T.interpret(obs(), [mine])
      :socket.close(mine)
      :socket.close(theirs)
    end
  end

  # ================================================================ K.2 / K.3
  test "K.2 · the current owning Peer can admit an attach, and the ticket names no PTY", ctx do
    assert {:ok, t} = T.admit_attach(ctx.agent)

    assert t["schema"] == "terminal-attachment-ticket@1"
    assert t["peer_ref"] == ctx.agent
    assert t["carrier_ref"] == ctx.inc["carrier_ref"]
    assert t["carrier_epoch"] == ctx.inc["carrier_epoch"]
    assert t["worker_ref"] == ctx.worker["id"]

    # **The correction this slice is built on.** The World cannot know which
    # terminal it is agreeing about, only which Carrier.
    refute Map.has_key?(t, "pty_epoch"),
           "ORDERED A bound a pty_epoch the runtime cannot know until the host answers"
  end

  test "K.2b · a second attach is refused while one is possessed", ctx do
    p = possess!(ctx.agent)

    assert {:refused, r} = T.admit_attach(ctx.agent)
    assert r["code"] == "terminal-already-attached"
    assert active?(ctx.agent), "a refused second admission disturbed the live attachment"

    TA.close(p.pid)
    :socket.close(p.theirs)
  end

  test "K.2c · a Peer with no live Carrier cannot admit an attach", ctx do
    :ok = Peer.detach_carrier(ctx.agent)

    assert {:refused, r} = T.admit_attach(ctx.agent)
    assert r["code"] == "terminal-no-live-carrier"
    assert Peer.terminal_attachment(ctx.agent) == nil
  end

  test "K.3 · a ticket cannot be redirected to another Peer", ctx do
    {:ok, t} = T.admit_attach(ctx.agent)
    {:ok, other} = Peer.attach_agent("kestrel")

    p = provision(ctx.agent)
    forged = Map.put(t, "peer_ref", other)

    assert {:refused, r} = T.commit_b1(forged, p.obs, p.pid)
    assert r["code"] == "carrier-not-attached"
    assert Peer.terminal_attachment(other) == nil
    assert Peer.terminal_attachment(ctx.agent) == nil

    TA.close(p.pid)
    :socket.close(p.theirs)
  end

  test "K.4 · the ticket is evidence only — it is not durable and starts nothing", ctx do
    before = Loci.attempts() |> length()
    {:ok, _t} = T.admit_attach(ctx.agent)

    assert Loci.attempts() |> length() == before,
           "a terminal attach attempt was written to the durable store"

    assert Peer.terminal_attachments() == %{}
  end

  # =================================================================== K.5-K.7
  describe "B1 refuses when the World moved during the machine phase" do
    test "K.5 · the Carrier was replaced", ctx do
      p = provision(ctx.agent)

      # The Carrier relation ends and a new one is admitted while the host
      # was busy. The ticket named the first.
      :ok = Peer.detach_carrier(ctx.agent)
      {:ok, _new} = Carrier.start(ctx.agent, ctx.lane["id"])

      assert {:refused, r} = T.commit_b1(p.ticket, p.obs, p.pid)
      assert r["code"] in ~w(terminal-carrier-replaced terminal-no-live-carrier)
      assert Peer.terminal_attachment(ctx.agent) == nil

      TA.close(p.pid)
      :socket.close(p.theirs)
    end

    test "K.6 · the Worker generation moved", ctx do
      p = provision(ctx.agent)
      Ampd.AuthorityCoordinator.transact(fn -> Worker.close(ctx.worker["id"]) end)

      assert {:refused, r} = T.commit_b1(p.ticket, p.obs, p.pid)
      assert r["code"] in ~w(worker-not-open terminal-worker-generation-stale)
      assert Peer.terminal_attachment(ctx.agent) == nil

      TA.close(p.pid)
      :socket.close(p.theirs)
    end

    test "K.7 · occupancy disappeared", ctx do
      p = provision(ctx.agent)
      :ok = Peer.detach_worker(ctx.agent)

      assert {:refused, r} = T.commit_b1(p.ticket, p.obs, p.pid)
      assert r["code"] == "carrier-not-attached"
      assert Peer.terminal_attachment(ctx.agent) == nil

      TA.close(p.pid)
      :socket.close(p.theirs)
    end
  end

  # =================================================================== K.8-K.9
  test "K.8 · B1 installs COMMITTING, and COMMITTING is not ACTIVE", ctx do
    p = provision(ctx.agent)
    assert {:ok, record} = T.commit_b1(p.ticket, p.obs, p.pid)

    assert record["schema"] == "terminal-attachment@1"
    assert record["status"] == "COMMITTING"
    assert record["pty_epoch"] == p.obs["pty_epoch"]
    assert record["carrier_ref"] == ctx.inc["carrier_ref"]
    assert Peer.terminal_attachment(ctx.agent)["status"] == "COMMITTING"

    # No pid, no descriptor, no pathname reaches the semantic object.
    for k <- ~w(pid fd socket path pty stream owner) do
      refute Map.has_key?(record, k), "the semantic record carries #{k}"
    end

    TA.close(p.pid)
    :socket.close(p.theirs)
  end

  test "K.9 · a COMMITTING attachment cannot read, write or resize", ctx do
    p = provision(ctx.agent)
    {:ok, _record} = T.commit_b1(p.ticket, p.obs, p.pid)

    :ok = :socket.send(p.theirs, "prompt$ ")

    assert {:error, :provisional} = TA.read(p.pid)
    assert {:error, :provisional} = TA.write(p.pid, "ls\n")
    assert {:refused, r} = T.resize(ctx.agent, 30, 90)
    assert r["code"] == "terminal-not-possessed"

    # And prepared is no better.
    :ok = TA.prepare(p.pid, Map.merge(Peer.terminal_attachment(ctx.agent), p.identity), self())
    assert {:error, :prepared} = TA.read(p.pid)
    assert {:error, :prepared} = TA.write(p.pid, "ls\n")
    assert {:refused, _} = T.resize(ctx.agent, 30, 90)

    TA.close(p.pid)
    :socket.close(p.theirs)
  end

  # ================================================================ K.10-K.11
  test "K.10 · record A cannot prepare owner B", ctx do
    a = provision(ctx.agent)
    {:ok, record} = T.commit_b1(a.ticket, a.obs, a.pid)

    {mine_b, theirs_b} = pair()
    {:ok, pid_b, _} = T.own_stream(a.ticket, obs(), mine_b)

    assert {:error, {:identity_mismatch, bad}} =
             TA.prepare(pid_b, Map.merge(record, a.identity), self())

    assert "attachment_ref" in bad
    assert TA.state(pid_b) == :provisional

    TA.close(a.pid)
    TA.close(pid_b)
    :socket.close(a.theirs)
    :socket.close(theirs_b)
  end

  test "K.10b · the World's own finalisation is addressed by identity", ctx do
    p = provision(ctx.agent)
    {:ok, record} = T.commit_b1(p.ticket, p.obs, p.pid)

    assert {:refused, {:identity_mismatch, _}} =
             Peer.activate_terminal(ctx.agent, "ta_" <> String.duplicate("0", 32), record["attachment_epoch"])

    assert {:refused, {:identity_mismatch, _}} =
             Peer.activate_terminal(ctx.agent, record["attachment_ref"], String.duplicate("0", 32))

    assert Peer.terminal_attachment(ctx.agent)["status"] == "COMMITTING"

    TA.close(p.pid)
    :socket.close(p.theirs)
  end

  test "K.11 · a wrong Peer-owner pid cannot become the ACTIVE lifetime witness", ctx do
    p = provision(ctx.agent)
    {:ok, record} = T.commit_b1(p.ticket, p.obs, p.pid)

    impostor = spawn(fn -> receive do: (:stop -> :ok) end)
    refute impostor == Peer.owner_pid(ctx.agent)

    # `prepare/3` accepts it — a monitor on the wrong process succeeds, which
    # is exactly why this cannot be left to the call path.
    :ok = TA.prepare(p.pid, Map.merge(record, p.identity), impostor)

    assert {:refused, r} = T.commit_b2(p.ticket, record, p.pid)
    assert r["code"] == "terminal-owner-not-peer-owner"
    assert Peer.terminal_attachment(ctx.agent) == nil
    dead!(p.pid)
    assert closed?(p.mine)

    send(impostor, :stop)
    :socket.close(p.theirs)
  end

  # ================================================================ K.12-K.14
  test "K.12 · an ACTIVE attachment survives its setup transaction", ctx do
    parent = self()
    owner = Peer.owner_pid(ctx.agent)
    assert owner == parent, "the test process is the peer binding's owner"

    {:ok, ticket} = T.admit_attach(ctx.agent)
    {mine, theirs} = pair()
    o = obs()

    setup =
      spawn(fn ->
        receive do: (:go -> :ok)
        {:ok, pid, identity} = T.own_stream(ticket, o, mine)
        {:ok, record} = T.commit_b1(ticket, o, pid)
        :ok = TA.prepare(pid, Map.merge(record, identity), owner)
        {:ok, _} = T.commit_b2(ticket, record, pid)
        send(parent, {:owner, pid})
        receive do: (:die -> :ok)
      end)

    :ok = :socket.setopt(mine, {:otp, :controlling_process}, setup)
    send(setup, :go)
    pid = receive do: ({:owner, p} -> p), after: (3000 -> flunk("no owner"))

    assert TA.state(pid) == :active
    assert Peer.terminal_attachment(ctx.agent)["status"] == "ACTIVE"

    ref = Process.monitor(setup)
    send(setup, :die)
    assert_receive {:DOWN, ^ref, :process, _, _}, 3000
    Process.sleep(150)

    assert Process.alive?(pid), "an ACTIVE attachment died with its setup transaction"
    assert Peer.terminal_attachment(ctx.agent)["status"] == "ACTIVE"

    TA.close(pid)
    :socket.close(theirs)
  end

  test "K.13 · the true Peer owner dying closes the attachment", ctx do
    parent = self()

    # A peer whose binding is owned by a process we can kill.
    holder = spawn(fn ->
      {:ok, id} = Peer.attach_agent("kestrel")
      send(parent, {:peer, id})
      receive do: (:die -> :ok)
    end)

    peer = receive do: ({:peer, id} -> id), after: (3000 -> flunk("no peer"))
    assert Peer.owner_pid(peer) == holder

    # It has no occupancy, so this proves only the lifetime binding — which
    # is the one thing under test.
    {mine, theirs} = pair()
    carrier = %{"carrier_ref" => ctx.inc["carrier_ref"], "carrier_epoch" => ctx.inc["carrier_epoch"]}
    {:ok, pid, identity} = T.own_stream(carrier, obs(), mine)
    :ok = TA.prepare(pid, identity, holder)
    assert TA.state(pid) == :prepared

    send(holder, :die)
    dead!(pid)
    assert closed?(mine)
    :socket.close(theirs)
  end

  test "K.14 · killing the stream owner removes the semantic record", ctx do
    p = possess!(ctx.agent)
    assert Peer.terminal_attachment(ctx.agent)["status"] == "ACTIVE"

    # `:kill` skips `terminate/2`. A record that depended on the dying
    # process announcing itself would survive this.
    Process.exit(p.pid, :kill)
    dead!(p.pid)
    Process.sleep(150)

    assert Peer.terminal_attachment(ctx.agent) == nil,
           "a semantic terminal record outlived the process owning its stream"

    assert closed?(p.mine)
    :socket.close(p.theirs)
  end

  # ================================================================ K.15-K.18
  describe "B2 re-derives, and a change between B1 and B2 refuses" do
    test "K.15 · the Worker moved between B1 and B2", ctx do
      p = provision(ctx.agent)
      {:ok, record} = T.commit_b1(p.ticket, p.obs, p.pid)
      :ok = TA.prepare(p.pid, Map.merge(record, p.identity), Peer.owner_pid(ctx.agent))

      Ampd.AuthorityCoordinator.transact(fn -> Worker.close(ctx.worker["id"]) end)

      assert {:refused, r} = T.commit_b2(p.ticket, record, p.pid)
      assert r["code"] in ~w(worker-not-open terminal-worker-generation-stale)
      refute active?(ctx.agent)

      T.release(ctx.agent)
      :socket.close(p.theirs)
    end

    test "K.16 · the Carrier was replaced between B1 and B2", ctx do
      p = provision(ctx.agent)
      {:ok, record} = T.commit_b1(p.ticket, p.obs, p.pid)
      :ok = TA.prepare(p.pid, Map.merge(record, p.identity), Peer.owner_pid(ctx.agent))

      # Carrier removal is what clears the record — so B2 must then find no
      # COMMITTING record at all, and must not restore one.
      :ok = Peer.detach_carrier(ctx.agent)
      {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])

      assert {:refused, r} = T.commit_b2(p.ticket, record, p.pid)
      assert r["code"] in ~w(terminal-carrier-replaced terminal-record-gone)
      refute active?(ctx.agent)

      :socket.close(p.theirs)
    end

    test "K.17 · the Peer was lost between B1 and B2", ctx do
      p = provision(ctx.agent)
      {:ok, record} = T.commit_b1(p.ticket, p.obs, p.pid)
      :ok = TA.prepare(p.pid, Map.merge(record, p.identity), Peer.owner_pid(ctx.agent))

      :ok = Peer.detach(ctx.agent)

      assert {:refused, r} = T.commit_b2(p.ticket, record, p.pid)
      assert r["code"] == "terminal-peer-gone"
      assert Peer.terminal_attachment(ctx.agent) == nil
      dead!(p.pid)
      assert closed?(p.mine)

      :socket.close(p.theirs)
    end

    test "K.18 · B2 succeeds exactly once", ctx do
      p = possess!(ctx.agent)

      assert {:refused, r} = T.commit_b2(p.ticket, p.record, p.pid)
      assert r["code"] == "terminal-record-not-committing"
      assert active?(ctx.agent), "a refused second B2 disturbed the live attachment"

      TA.close(p.pid)
      :socket.close(p.theirs)
    end
  end

  # ================================================================ K.19-K.20
  test "K.19 · the ACTIVE record and its owner agree on all five physical fields", ctx do
    p = possess!(ctx.agent)

    held = TA.record(p.pid)

    for k <- ~w(attachment_ref attachment_epoch carrier_ref carrier_epoch pty_epoch) do
      assert p.active[k] == held[k], "#{k} differs between the World and the stream owner"
      assert is_binary(p.active[k])
    end

    assert p.active["status"] == "ACTIVE"
    assert TA.state(p.pid) == :active

    # Only now do bytes mean anything.
    :ok = :socket.send(p.theirs, "hello\n")
    assert {:ok, "hello\n"} = TA.read(p.pid, 6, 2000)

    TA.close(p.pid)
    :socket.close(p.theirs)
  end

  test "K.20 · ending the Carrier relation ends the terminal relation", ctx do
    for ending <- [:detach, :pending, :reset] do
      p = possess!(ctx.agent)
      assert active?(ctx.agent)

      case ending do
        :detach -> Peer.detach_carrier(ctx.agent)
        :pending -> Peer.detach_carrier_pending(ctx.agent)
        :reset -> Peer.reset()
      end

      assert Peer.terminal_attachment(ctx.agent) == nil,
             "#{ending} left a terminal record behind"

      dead!(p.pid)
      assert closed?(p.mine), "#{ending} left the stream open"
      :socket.close(p.theirs)

      if ending != :reset, do: {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      if ending == :reset, do: :done
    end
  end

  # ================================================================ K.21-K.24
  test "K.21 · a stale attachment cannot resize the one that replaced it", ctx do
    a = possess!(ctx.agent)
    stale = a.active

    :ok = Peer.detach_carrier(ctx.agent)
    dead!(a.pid)
    {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
    b = possess!(ctx.agent)

    refute stale["attachment_ref"] == b.active["attachment_ref"]

    assert {:refused, r} = T.resize_record(stale, 30, 90)
    assert r["code"] == "terminal-attachment-stale"

    # A degenerate resize is refused before anything is asked of the host.
    assert {:refused, z} = T.resize(ctx.agent, 0, 0)
    assert z["code"] == "terminal-resize-degenerate"

    TA.close(b.pid)
    :socket.close(a.theirs)
    :socket.close(b.theirs)
  end

  test "K.22 · no raw descriptor, socket or pid enters the semantic state", ctx do
    p = possess!(ctx.agent)

    published = Map.values(Peer.terminal_attachments()) ++ [p.active]

    for record <- published, {k, v} <- record do
      refute is_pid(v), "#{k} in the semantic record is a pid"
      refute is_reference(v), "#{k} in the semantic record is a reference"
      refute is_port(v), "#{k} in the semantic record is a port"
      refute k in ~w(pid fd socket sock path pty_path stream owner descriptor)
    end

    TA.close(p.pid)
    :socket.close(p.theirs)
  end

  test "K.23 · no terminal record is durable", ctx do
    p = possess!(ctx.agent)
    assert active?(ctx.agent)

    # The whole durable surface, read after a live attachment exists.
    dumped = :erlang.term_to_binary(Loci.attempts()) |> :erlang.binary_to_term()

    refute Enum.any?(dumped, fn a ->
             a["schema"] == "terminal-attachment@1" or Map.has_key?(a, "pty_epoch")
           end),
           "a terminal attachment reached the durable attempt store"

    # And it does not survive the runtime incarnation.
    Peer.reset()
    assert Peer.terminal_attachments() == %{}

    dead!(p.pid)
    :socket.close(p.theirs)
  end

  test "K.24 · the frozen c·2a physical grammar is untouched", ctx do
    # The cardinality rules c·2a·2 froze, re-asserted here so a change to the
    # identity checks above cannot quietly relax them.
    {mine, theirs} = pair()
    assert {:error, why} = T.interpret(obs(), [])
    assert why =~ "no stream descriptor"

    assert {:error, w2} = T.interpret(%{"attached" => false, "refused" => "nope"}, [mine])
    assert w2 =~ "descriptor"
    assert closed?(mine)

    assert {:refused, o} = T.interpret(%{"attached" => false, "refused" => "no such carrier"}, [])
    assert o["refused"] == "no such carrier"

    assert T.observation_schema() == "carrier-pty-attach-observation@1"
    assert "terminal-attachment@1" in T.schemas()
    assert Peer.terminal_schema() == "terminal-attachment@1"

    :socket.close(theirs)
    _ = ctx
  end

  defp active?(peer), do: match?(%{"status" => "ACTIVE"}, Peer.terminal_attachment(peer))
end
