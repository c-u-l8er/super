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

  ## What every negative case proves

      1  it was refused
      2  by the expected name, and by a name only this fault produces
      3  no record survives — not merely no ACTIVE one
      4  the stream is closed, measured rather than assumed

  Point 2 is the one that was got wrong first: several of these asserted
  `code in ~w(a b)`, which stays green when the check that produces `a` is
  deleted and `b` answers instead. Where two codes are genuinely both
  correct the case is arranged so only one of them can be.
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

    # **Every socket and owner this test makes, closed whatever happens.**
    #
    # Disposal used to sit after the assertions, so a failing assertion
    # leaked a descriptor and a process for the rest of the run — and the
    # leak was invisible, because the next `setup` resets the semantic state
    # that would have shown it. A cleanup that only runs when the test passes
    # is a cleanup for the case that did not need it.
    # Unlinked on purpose: a supervised child is torn down *before* the
    # `on_exit` callbacks that need to read it, and the cleanup then dies
    # calling a process ExUnit has already stopped.
    {:ok, litter} = Agent.start(fn -> {[], []} end)

    on_exit(fn ->
      # **This suite accounts for its own Carriers.**
      #
      # `pending_reaps` deliberately survives `Peer.reset/0` — a reap is a
      # fact about the OS and the OS did not attend the reset — so a Carrier
      # this file started and left live becomes a debt in whichever suite
      # runs next, created by *that* suite's reset and attributed to it.
      # Measured: without this, `Ampd.CarrierTest`'s `E27` fails on some
      # orderings with a `ln_0003`/`wk_0004` incarnation it never started.
      #
      # Drain, reset, drain — the ordering `Ampd.CarrierTest`'s own setup
      # documents, performed here so the debt is settled in the world that
      # incurred it.
      if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()
      Peer.reset()
      if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()
    end)

    on_exit(fn ->
      {socks, pids} = Agent.get(litter, & &1)
      for p <- pids, Process.alive?(p), do: TA.close(p)
      for s <- socks, do: :socket.close(s)
      Agent.stop(litter)
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

    %{
      control: control,
      agent: agent,
      goal: goal,
      lane: lane,
      worker: w,
      inc: inc,
      repo_ref: r["ref"],
      litter: litter
    }
  end

  # ------------------------------------------------------------------ helpers

  defp track_sock(ctx, s), do: Agent.update(ctx.litter, fn {a, b} -> {[s | a], b} end) && s
  defp track_pid(ctx, p), do: Agent.update(ctx.litter, fn {a, b} -> {a, [p | b]} end) && p

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

  defp pair(ctx) do
    {mine, theirs} = Ampd.Transport.socketpair(:stream)
    track_sock(ctx, mine)
    track_sock(ctx, theirs)
    {mine, theirs}
  end

  defp closed?(s), do: :socket.getopt(s, :otp, :fd) == {:error, :closed}

  # Everything a successful acquisition does, minus the machine.
  defp provision(ctx, peer \\ nil, o \\ nil) do
    peer = peer || ctx.agent
    {:ok, ticket} = T.admit_attach(peer)
    {mine, theirs} = pair(ctx)
    o = o || obs()
    {:ok, pid, identity} = T.own_stream(ticket, o, mine)
    track_pid(ctx, pid)
    %{ticket: ticket, obs: o, pid: pid, identity: identity, mine: mine, theirs: theirs, peer: peer}
  end

  defp possess!(ctx, peer \\ nil) do
    p = provision(ctx, peer)
    {:ok, record} = T.commit_b1(p.ticket, p.obs, p.pid)
    :ok = TA.prepare(p.pid, Map.merge(record, p.identity), Peer.owner_pid(p.peer))
    {:ok, active} = T.commit_b2(p.ticket, record, p.pid)
    Map.merge(p, %{record: record, active: active})
  end

  defp dead!(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, _, _}, 3000
  end

  # Refused, by this exact name, with nothing of this attempt left behind.
  defp converged!(ctx, p, code, peer \\ nil) do
    peer = peer || ctx.agent
    assert Peer.terminal_attachment(peer) == nil, "#{code} left a record behind"
    dead!(p.pid)
    assert closed?(p.mine), "#{code} left the stream open"
  end

  defp active?(peer), do: match?(%{"status" => "ACTIVE"}, Peer.terminal_attachment(peer))

  # A second fully-occupied peer, with its own Lane, Worker and Carrier.
  defp second_peer!(ctx) do
    {:ok, other} = Peer.attach_agent("kestrel")

    lane2 =
      ok!(
        Control.command(ctx.control, :open_lane, [ctx.goal["id"], "kestrel", ctx.repo_ref, nil]),
        "lane"
      )

    w2 = ok!(Control.command(ctx.control, :open_worker, [lane2["id"], "work"]), "worker")
    ok!(Control.command(other, :attach_worker, [w2["id"]]), "worker")
    {:ok, inc2} = Carrier.start(other, lane2["id"])
    %{peer: other, lane: lane2, worker: w2, inc: inc2}
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

  # Every byte of the durable surface, not one collection of it.
  #
  # The first version of this read `Loci.attempts()` and called it "the whole
  # durable surface". It is one of eight dets-backed stores, so a terminal
  # record written to any other would have passed.
  defp on_disk?(needle) do
    dir = Ampd.Store.data_dir()

    Path.wildcard(Path.join(dir, "**/*"))
    |> Enum.filter(&File.regular?/1)
    |> Enum.any?(fn f ->
      case File.read(f) do
        {:ok, bin} -> String.contains?(bin, needle)
        _ -> false
      end
    end)
  end

  # ===================================================================== K.1
  describe "K.1 · a success whose physical identity is malformed is not a success" do
    test "a missing identity closes the one socket and returns a protocol failure", ctx do
      {mine, _theirs} = pair(ctx)

      bad = %{"schema" => "carrier-pty-attach-observation@1", "attached" => true}
      assert {:error, why} = T.interpret(bad, [mine])
      assert why =~ "physical identity"
      assert closed?(mine), "a malformed success kept the descriptor"
    end

    test "each of the three identities is checked, and by shape not presence", ctx do
      cases = [
        {"attachment_ref", String.duplicate("a", 32)},
        {"attachment_ref", "ta_" <> String.duplicate("A", 32)},
        {"attachment_epoch", "0123456789abcdef"},
        {"pty_epoch", "0123456789abcdef0123456789abcdeg"}
      ]

      # Counted, so a comprehension that silently ran zero times cannot pass.
      assert length(cases) == 4

      for {k, v} <- cases do
        {mine, _} = pair(ctx)
        assert {:error, why} = T.interpret(obs(%{k => v}), [mine])
        assert why =~ k, "#{k}=#{v} was accepted or misreported: #{why}"
        assert closed?(mine)
      end
    end

    test "a malformed `refused` is malformed, not absent", ctx do
      # The defect this closes: `is_binary(r) and r != ""` makes every
      # non-string `refused` indistinguishable from no `refused` at all.
      for v <- [0, true, false, %{}, [], ""] do
        {mine, _} = pair(ctx)
        assert {:error, why} = T.interpret(obs(%{"refused" => v}), [mine])
        assert why =~ "refused", "refused=#{inspect(v)} passed as a clean success"
        assert closed?(mine)
      end
    end

    test "a malformed `attached` is malformed too", ctx do
      {mine, _} = pair(ctx)
      assert {:error, why} = T.interpret(obs(%{"attached" => "true"}), [mine])
      assert why =~ "`attached` field"
      assert closed?(mine)
    end

    test "a well-formed success still passes", ctx do
      {mine, _} = pair(ctx)
      assert {:ok, _o, ^mine} = T.interpret(obs(), [mine])
    end
  end

  # ===================================================================== K.2
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
    _ = possess!(ctx)

    assert {:refused, r} = T.admit_attach(ctx.agent)
    assert r["code"] == "terminal-already-attached"
    assert active?(ctx.agent), "a refused second admission disturbed the live attachment"
  end

  test "K.2c · a Peer with no live Carrier cannot admit an attach", ctx do
    assert Peer.carrier(ctx.agent) != nil
    :ok = Peer.detach_carrier(ctx.agent)

    assert {:refused, r} = T.admit_attach(ctx.agent)
    assert r["code"] == "terminal-no-live-carrier"
  end

  # ===================================================================== K.3
  test "K.3 · a ticket cannot be redirected to another fully-occupied Peer", ctx do
    other = second_peer!(ctx)

    # Both peers are complete: occupancy, an open Worker, a live Carrier.
    # So a refusal here is about the *redirection* and cannot be the
    # "this peer has nothing" answer the first version of this test got.
    assert {:ok, _} = T.admit_attach(other.peer)

    p = provision(ctx)
    forged = Map.put(p.ticket, "peer_ref", other.peer)

    assert {:refused, r} = T.commit_b1(forged, p.obs, p.pid)

    # **Named precisely.** Both peers are bound in the same `Ampd.Peer`
    # incarnation, so `attachment-epoch-stale` cannot be the answer — the
    # epochs are equal. What differs is the Locus: the ticket agreed about
    # lane 1 and the peer it was redirected to occupies lane 2, which is the
    # redirection itself being refused rather than an absence.
    assert r["code"] == "carrier-attached-elsewhere",
           "expected the redirection to be caught as position drift, got #{r["code"]}"

    assert Peer.terminal_attachment(other.peer) == nil
    assert Peer.terminal_attachment(ctx.agent) == nil
    dead!(p.pid)
    assert closed?(p.mine)
  end

  # ===================================================================== K.4
  test "K.4 · the ticket is evidence only — it is not durable and starts nothing", ctx do
    assert {:ok, t} = T.admit_attach(ctx.agent)

    refute on_disk?(t["ticket_id"]), "the ORDERED A ticket reached the durable surface"
    assert Peer.terminal_attachments() == %{}
  end

  # =================================================================== K.5-K.7
  describe "B1 refuses when the World moved during the machine phase" do
    test "K.5 · the Carrier was replaced", ctx do
      p = provision(ctx)

      # Replaced, not merely lost — so `terminal-no-live-carrier` cannot be
      # the answer and the code below is the only correct one.
      :ok = Peer.detach_carrier(ctx.agent)
      {:ok, new} = Carrier.start(ctx.agent, ctx.lane["id"])
      refute new["carrier_ref"] == p.ticket["carrier_ref"]
      assert Peer.carrier(ctx.agent) != nil

      assert {:refused, r} = T.commit_b1(p.ticket, p.obs, p.pid)
      assert r["code"] == "terminal-carrier-replaced"
      converged!(ctx, p, "terminal-carrier-replaced")
    end

    test "K.6 · the Worker generation moved", ctx do
      p = provision(ctx)

      # Closed **and reopened**: status is back to "open", so `worker-not-open`
      # cannot answer and only the generation check can.
      Ampd.AuthorityCoordinator.transact(fn -> Worker.close(ctx.worker["id"]) end)
      Ampd.AuthorityCoordinator.transact(fn -> Worker.reopen(ctx.worker["id"]) end)
      assert Loci.worker(ctx.worker["id"])["status"] == "open"

      assert {:refused, r} = T.commit_b1(p.ticket, p.obs, p.pid)
      assert r["code"] == "terminal-worker-generation-stale"
      converged!(ctx, p, "terminal-worker-generation-stale")
    end

    test "K.7 · occupancy disappeared", ctx do
      p = provision(ctx)
      :ok = Peer.detach_worker(ctx.agent)

      assert {:refused, r} = T.commit_b1(p.ticket, p.obs, p.pid)
      assert r["code"] == "carrier-not-attached"
      converged!(ctx, p, "carrier-not-attached")
    end
  end

  # =================================================================== K.8-K.9
  test "K.8 · B1 installs COMMITTING, and COMMITTING is not ACTIVE", ctx do
    p = provision(ctx)
    assert {:ok, record} = T.commit_b1(p.ticket, p.obs, p.pid)

    assert record["schema"] == "terminal-attachment@1"
    assert record["status"] == "COMMITTING"
    assert record["pty_epoch"] == p.obs["pty_epoch"]
    assert record["carrier_ref"] == ctx.inc["carrier_ref"]
    assert Peer.terminal_attachment(ctx.agent)["status"] == "COMMITTING"

    for k <- ~w(pid fd socket path pty stream owner) do
      refute Map.has_key?(record, k), "the semantic record carries #{k}"
    end
  end

  test "K.9 · a COMMITTING attachment cannot read, write or resize", ctx do
    p = provision(ctx)
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
    assert {:refused, r2} = T.resize(ctx.agent, 30, 90)
    assert r2["code"] == "terminal-not-possessed"
  end

  # ================================================================ K.10-K.11
  test "K.10 · record A cannot prepare owner B, and every bound field is reported", ctx do
    a = provision(ctx)
    {:ok, record} = T.commit_b1(a.ticket, a.obs, a.pid)

    {mine_b, _} = pair(ctx)
    {:ok, pid_b, _} = T.own_stream(a.ticket, obs(), mine_b)
    track_pid(ctx, pid_b)

    assert {:error, {:identity_mismatch, bad}} =
             TA.prepare(pid_b, Map.merge(record, a.identity), self())

    # The three the two attachments actually differ on — not "at least the
    # ref". A check that reported only the first field would pass on `in`.
    assert Enum.sort(bad) == ~w(attachment_epoch attachment_ref pty_epoch)
    assert TA.state(pid_b) == :provisional
  end

  test "K.10b · the World's own finalisation is addressed by identity", ctx do
    p = provision(ctx)
    {:ok, record} = T.commit_b1(p.ticket, p.obs, p.pid)

    assert {:refused, {:identity_mismatch, _}} =
             Peer.activate_terminal(
               ctx.agent,
               "ta_" <> String.duplicate("0", 32),
               record["attachment_epoch"]
             )

    assert {:refused, {:identity_mismatch, _}} =
             Peer.activate_terminal(ctx.agent, record["attachment_ref"], String.duplicate("0", 32))

    # And so is cancellation, which used to take only the peer.
    assert {:refused, :identity_mismatch} =
             Peer.remove_terminal(ctx.agent, "ta_" <> String.duplicate("0", 32), record["attachment_epoch"])

    assert Peer.terminal_attachment(ctx.agent)["status"] == "COMMITTING"
  end

  test "K.11 · a wrong Peer-owner pid cannot become the ACTIVE lifetime witness", ctx do
    p = provision(ctx)
    {:ok, record} = T.commit_b1(p.ticket, p.obs, p.pid)

    impostor = spawn(fn -> receive do: (:stop -> :ok) end)
    refute impostor == Peer.owner_pid(ctx.agent)

    # `prepare/3` accepts it — a monitor on the wrong process succeeds, which
    # is exactly why this cannot be left to the call path.
    :ok = TA.prepare(p.pid, Map.merge(record, p.identity), impostor)

    assert {:refused, r} = T.commit_b2(p.ticket, record, p.pid)
    assert r["code"] == "terminal-owner-not-peer-owner"
    converged!(ctx, p, "terminal-owner-not-peer-owner")

    send(impostor, :stop)
  end

  test "K.11b · an owner that dies mid-commit refuses the commit, not the total order", ctx do
    p = provision(ctx)
    {:ok, record} = T.commit_b1(p.ticket, p.obs, p.pid)
    :ok = TA.prepare(p.pid, Map.merge(record, p.identity), Peer.owner_pid(ctx.agent))

    coordinator = Process.whereis(Ampd.AuthorityCoordinator)
    seq_before = Ampd.ViewClock.read()

    # **The ordinary case, made deterministic.** `Ampd.Peer` is outside the
    # total order and its `:DOWN` handling kills stream owners, so B2 can be
    # holding a pid that dies under it. A `GenServer.call` to a dead process
    # exits the caller — and inside `transact/1` the caller is the total
    # order, so the whole control plane would go down: seq to zero, the
    # projection epoch re-minted, every subscriber resnapshotting.
    Process.exit(p.pid, :kill)
    dead!(p.pid)

    # **The one legitimate disjunct in this file, and it is worth saying why.**
    # `Ampd.Peer` monitors the stream owner, so by the time B2 runs the record
    # may already be gone — the death arrives by two routes and both names
    # are the same fact. Neither can mask a deleted check: what is under test
    # here is not the name but the line below it.
    assert {:refused, r} = T.commit_b2(p.ticket, record, p.pid)
    assert r["code"] in ~w(terminal-owner-gone terminal-record-gone)

    assert Process.whereis(Ampd.AuthorityCoordinator) == coordinator,
           "a dead stream owner took the AuthorityCoordinator down with it"

    assert Ampd.ViewClock.read() >= seq_before
    assert Peer.terminal_attachment(ctx.agent) == nil
    assert closed?(p.mine)
  end

  # ================================================================ K.12-K.14
  test "K.12 · an ACTIVE attachment survives its setup transaction", ctx do
    parent = self()
    owner = Peer.owner_pid(ctx.agent)
    assert owner == parent, "the test process is the peer binding's owner"

    {:ok, ticket} = T.admit_attach(ctx.agent)
    {mine, _theirs} = pair(ctx)
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
    track_pid(ctx, pid)

    assert TA.state(pid) == :active
    assert active?(ctx.agent)

    ref = Process.monitor(setup)
    send(setup, :die)
    assert_receive {:DOWN, ^ref, :process, _, _}, 3000
    Process.sleep(150)

    assert Process.alive?(pid), "an ACTIVE attachment died with its setup transaction"
    assert active?(ctx.agent)
    refute closed?(mine)
  end

  test "K.13 · the true Peer owner dying closes an ACTIVE possession", ctx do
    parent = self()

    # A **complete** possession — occupancy, Carrier, ACTIVE record — whose
    # peer binding is owned by a process we can kill. The first version of
    # this killed the owner of an unoccupied peer holding a merely PREPARED
    # attachment, which re-proved the attachment's own monitor and never
    # reached `Ampd.Peer.drop/2` at all.
    lane2 = ok!(Control.command(ctx.control, :open_lane, [ctx.goal["id"], "kestrel", ctx.repo_ref, nil]), "lane")
    w2 = ok!(Control.command(ctx.control, :open_worker, [lane2["id"], "work"]), "worker")

    holder =
      spawn(fn ->
        {:ok, id} = Peer.attach_agent("kestrel")
        send(parent, {:peer, id})
        receive do: (:die -> :ok)
      end)

    peer = receive do: ({:peer, id} -> id), after: (3000 -> flunk("no peer"))
    assert Peer.owner_pid(peer) == holder

    ok!(Control.command(peer, :attach_worker, [w2["id"]]), "worker")
    {:ok, _} = Carrier.start(peer, lane2["id"])
    p = possess!(ctx, peer)
    assert active?(peer)

    send(holder, :die)
    dead!(p.pid)
    Process.sleep(150)

    assert Peer.terminal_attachment(peer) == nil,
           "a possession outlived the process that owned its Peer binding"

    assert closed?(p.mine)
  end

  test "K.13b · losing the registry that holds the record closes the stream", ctx do
    p = possess!(ctx)
    assert active?(ctx.agent)

    # `Ampd.Peer` holds every `terminal-attachment@1` and its state is
    # ephemeral, so its death takes every record with it. A stream owner that
    # survived would hold the host's single attachment slot for its Carrier
    # with nothing in the runtime referring to it — and there is no reaper
    # for attachments. This is not the ownership monitor: it says *my record
    # is gone*, which is a different fact from *my owner is gone*.
    peer_pid = Process.whereis(Ampd.Peer)
    Process.exit(peer_pid, :kill)

    dead!(p.pid)
    assert closed?(p.mine), "an orphaned stream owner kept the descriptor"

    # And the supervisor puts the registry back, holding nothing.
    Process.sleep(250)
    assert Process.whereis(Ampd.Peer) != nil
    assert Peer.terminal_attachments() == %{}
  end

  test "K.14 · killing the stream owner removes the ACTIVE record", ctx do
    p = possess!(ctx)
    assert active?(ctx.agent)

    # `:kill` skips `terminate/2`. A record that depended on the dying
    # process announcing itself would survive this.
    Process.exit(p.pid, :kill)
    dead!(p.pid)
    Process.sleep(150)

    assert Peer.terminal_attachment(ctx.agent) == nil,
           "a semantic terminal record outlived the process owning its stream"

    assert closed?(p.mine)
  end

  test "K.14b · a COMMITTING record does not outlive its stream owner either", ctx do
    p = provision(ctx)
    {:ok, _record} = T.commit_b1(p.ticket, p.obs, p.pid)
    assert Peer.terminal_attachment(ctx.agent)["status"] == "COMMITTING"

    # The monitor is established at install, so this is the half that holds
    # during the interval the commit actually spends unfinished.
    Process.exit(p.pid, :kill)
    dead!(p.pid)
    Process.sleep(150)

    assert Peer.terminal_attachment(ctx.agent) == nil,
           "a COMMITTING record outlived the process owning its stream"

    assert closed?(p.mine)
  end

  # ================================================================ K.15-K.18
  describe "B2 re-derives, and a change between B1 and B2 refuses" do
    test "K.15 · the Worker generation moved between B1 and B2", ctx do
      p = provision(ctx)
      {:ok, record} = T.commit_b1(p.ticket, p.obs, p.pid)
      :ok = TA.prepare(p.pid, Map.merge(record, p.identity), Peer.owner_pid(ctx.agent))

      Ampd.AuthorityCoordinator.transact(fn -> Worker.close(ctx.worker["id"]) end)
      Ampd.AuthorityCoordinator.transact(fn -> Worker.reopen(ctx.worker["id"]) end)

      assert {:refused, r} = T.commit_b2(p.ticket, record, p.pid)
      assert r["code"] == "terminal-worker-generation-stale"

      # **B2's own convergence**, which is why nothing else is allowed to
      # have torn this down first.
      converged!(ctx, p, "terminal-worker-generation-stale")
    end

    test "K.16 · the Carrier was replaced between B1 and B2", ctx do
      p = provision(ctx)
      {:ok, record} = T.commit_b1(p.ticket, p.obs, p.pid)
      :ok = TA.prepare(p.pid, Map.merge(record, p.identity), Peer.owner_pid(ctx.agent))

      # Carrier removal is itself what clears the record, so B2 must find no
      # COMMITTING record and must not restore one.
      :ok = Peer.detach_carrier(ctx.agent)
      {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])

      assert {:refused, r} = T.commit_b2(p.ticket, record, p.pid)
      assert r["code"] == "terminal-carrier-replaced"
      converged!(ctx, p, "terminal-carrier-replaced")
    end

    test "K.17 · the Peer was lost between B1 and B2", ctx do
      p = provision(ctx)
      {:ok, record} = T.commit_b1(p.ticket, p.obs, p.pid)
      :ok = TA.prepare(p.pid, Map.merge(record, p.identity), Peer.owner_pid(ctx.agent))

      :ok = Peer.detach(ctx.agent)

      assert {:refused, r} = T.commit_b2(p.ticket, record, p.pid)
      assert r["code"] == "terminal-peer-gone"
      converged!(ctx, p, "terminal-peer-gone")
    end

    test "K.18 · B2 succeeds exactly once", ctx do
      p = possess!(ctx)

      assert {:refused, r} = T.commit_b2(p.ticket, p.record, p.pid)
      assert r["code"] == "terminal-record-not-committing"
      assert active?(ctx.agent), "a refused second B2 tore down the live attachment"
      assert Process.alive?(p.pid)
      refute closed?(p.mine)
    end
  end

  # ================================================================ K.19-K.20
  test "K.19 · the ACTIVE record and its owner agree on all five physical fields", ctx do
    p = possess!(ctx)
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
  end

  test "K.19b · and a disagreement between them refuses at B2", ctx do
    # The stream owner is created for observation A; the record B1 binds
    # describes observation B. Both are well formed; they are not the same
    # attachment, and only the cross-check catches it.
    {:ok, ticket} = T.admit_attach(ctx.agent)
    {mine, _} = pair(ctx)
    a = obs()
    b = obs()
    {:ok, pid, _identity} = T.own_stream(ticket, a, mine)
    track_pid(ctx, pid)

    {:ok, record} = T.commit_b1(ticket, b, pid)
    # `prepare/3` refuses this too — so the owner keeps A's identity and B2
    # is left comparing a record that describes B against a stream that is A.
    assert {:error, {:identity_mismatch, _}} = TA.prepare(pid, record, Peer.owner_pid(ctx.agent))

    assert {:refused, r} = T.commit_b2(ticket, record, pid)
    assert r["code"] == "terminal-owner-identity-mismatch"
    assert Peer.terminal_attachment(ctx.agent) == nil
    dead!(pid)
    assert closed?(mine)
  end

  describe "K.20 · ending the Carrier relation ends the terminal relation" do
    test "detach_carrier", ctx do
      p = possess!(ctx)
      :ok = Peer.detach_carrier(ctx.agent)
      converged!(ctx, p, "detach_carrier")
    end

    test "detach_carrier_pending", ctx do
      p = possess!(ctx)
      assert {:ok, inc} = Peer.detach_carrier_pending(ctx.agent)
      assert inc["carrier_ref"] == ctx.inc["carrier_ref"]
      converged!(ctx, p, "detach_carrier_pending")

      # **This function records a reap debt and deliberately does not
      # announce it — its caller does.** Calling it directly and stopping
      # there leaves an entry in `pending_reaps`, which survives every
      # `Peer.reset/0` by design, and the first later test to assert on that
      # map fails carrying a Carrier it never started. Measured:
      # `Ampd.CarrierTest`'s `E27` at seed 3.
      #
      # So the debt is asserted and then discharged the way
      # `Ampd.Carrier.converge/1` discharges it.
      assert Enum.any?(Peer.pending_reaps(), &(&1["carrier_ref"] == inc["carrier_ref"]))
      Ampd.Carrier.Reaper.orphaned(inc)
      :ok = Ampd.Carrier.Reaper.drain()
      assert Peer.pending_reaps() == []
    end

    test "reset", ctx do
      p = possess!(ctx)
      :ok = Peer.reset()
      assert Peer.terminal_attachments() == %{}
      dead!(p.pid)
      assert closed?(p.mine)
    end
  end

  # ================================================================ K.21-K.24
  test "K.21 · a stale attachment cannot resize the one that replaced it", ctx do
    a = possess!(ctx)
    stale = a.active

    :ok = Peer.detach_carrier(ctx.agent)
    dead!(a.pid)
    {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
    b = possess!(ctx)

    refute stale["attachment_ref"] == b.active["attachment_ref"]

    assert {:refused, r} = T.resize_record(stale, 30, 90)
    assert r["code"] == "terminal-attachment-stale"

    # A degenerate resize is refused before anything is asked of the host.
    assert {:refused, z} = T.resize(ctx.agent, 0, 0)
    assert z["code"] == "terminal-resize-degenerate"
  end

  test "K.21b · resize is refused while the stream has not finished becoming ACTIVE", ctx do
    # The window B2 opens between finalising the World record and finalising
    # the stream. Bytes are refused there by the owner's own phase; a resize
    # never touches the owner, so it is the one operation that could have
    # been performed on half a possession.
    p = provision(ctx)
    {:ok, record} = T.commit_b1(p.ticket, p.obs, p.pid)
    :ok = TA.prepare(p.pid, Map.merge(record, p.identity), Peer.owner_pid(ctx.agent))
    {:ok, _} = Peer.activate_terminal(ctx.agent, record["attachment_ref"], record["attachment_epoch"])

    assert active?(ctx.agent), "the World says ACTIVE"
    assert TA.state(p.pid) == :prepared, "and the stream has not caught up"

    assert {:refused, r} = T.resize(ctx.agent, 30, 90)
    assert r["code"] == "terminal-stream-not-active"
  end

  test "K.22 · no raw descriptor, socket or pid enters the semantic state", ctx do
    p = possess!(ctx)

    published = Peer.terminal_attachments()
    assert map_size(published) == 1, "the projection returned nothing, so the walk proves nothing"

    for record <- Map.values(published) ++ [p.active] do
      assert map_size(record) > 5
      walk(record)
    end
  end

  defp walk(m) when is_map(m) do
    for {k, v} <- m do
      refute is_pid(v), "#{k} in the semantic record is a pid"
      refute is_reference(v), "#{k} in the semantic record is a reference"
      refute is_port(v), "#{k} in the semantic record is a port"
      refute k in ~w(pid fd socket sock path pty_path stream owner descriptor)
      if is_map(v), do: walk(v)
      if is_list(v), do: Enum.each(v, &walk/1)
    end
  end

  defp walk(_), do: :ok

  test "K.23 · no terminal record is durable", ctx do
    p = possess!(ctx)
    assert active?(ctx.agent)

    # The identity strings themselves, swept across every file the runtime
    # writes — not one collection of one store.
    refute on_disk?(p.active["attachment_ref"]),
           "the attachment ref reached the durable surface"

    refute on_disk?(p.active["pty_epoch"]), "the pty epoch reached the durable surface"
    refute on_disk?("terminal-attachment@1"), "the record schema reached the durable surface"

    # And the relation does not survive the runtime incarnation.
    Peer.reset()
    assert Peer.terminal_attachments() == %{}
    dead!(p.pid)
  end

  test "K.24 · the frozen c·2a physical grammar is untouched", ctx do
    {mine, _} = pair(ctx)

    assert {:error, why} = T.interpret(obs(), [])
    assert why =~ "no stream descriptor"

    {two_a, _} = pair(ctx)
    {two_b, _} = pair(ctx)
    assert {:error, w3} = T.interpret(obs(), [two_a, two_b])
    assert w3 =~ "2 stream descriptors"
    assert closed?(two_a) and closed?(two_b)

    assert {:error, w2} = T.interpret(%{"attached" => false, "refused" => "nope"}, [mine])
    assert w2 =~ "descriptor"
    assert closed?(mine)

    assert {:refused, o} = T.interpret(%{"attached" => false, "refused" => "no such carrier"}, [])
    assert o["refused"] == "no such carrier"

    assert T.observation_schema() == "carrier-pty-attach-observation@1"
    assert "terminal-attachment@1" in T.schemas()
    assert Peer.terminal_schema() == "terminal-attachment@1"
  end

  # ================================================================ the whole
  test "K.25 · a machine that cannot answer publishes nothing", ctx do
    # No host carrier channel is possessed in this suite, so `acquire/1`
    # reaches the machine phase and gets an error. Every earlier phase must
    # have left the world exactly as it found it.
    assert {:error, why} = T.acquire(ctx.agent)
    assert why =~ "no host carrier channel"

    assert Peer.terminal_attachment(ctx.agent) == nil
    assert Peer.terminal_attachments() == %{}
    assert DynamicSupervisor.count_children(TA.Supervisor).active == 0
  end

  test "K.26 · a stream that cannot be handed over is closed, and nothing is published", ctx do
    {:ok, ticket} = T.admit_attach(ctx.agent)
    {mine, _} = pair(ctx)

    # `{:otp, :controlling_process}` may only be set by the current owner, so
    # calling `own_stream/3` from a process that is not the owner is the one
    # way to make the handover fail for real.
    parent = self()
    spawn(fn -> send(parent, {:r, T.own_stream(ticket, obs(), mine)}) end)

    assert_receive {:r, {:error, {:transfer_failed, {:invalid, :not_owner}}}}, 3000
    assert closed?(mine), "a failed handover left the descriptor open"
    assert Peer.terminal_attachment(ctx.agent) == nil
  end
end
