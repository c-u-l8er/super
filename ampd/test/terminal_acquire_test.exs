defmodule Ampd.TerminalAcquireTest do
  @moduledoc """
  D.1.3c·2c·1c **B9** — the negative acquisition matrix, through the command.

  ## What this adds that `terminal_possession_test` does not

  That file falsifies `Ampd.Carrier.Terminal.admit_attach/1`, which is the
  admission *function*. This falsifies `acquire_terminal`, which is the
  **command** — the thing a real agent on a real channel can actually send —
  and until D.1.3c·2c·1c there was no such command and therefore nothing to
  aim these at. The distinction is the one the round has been paying for
  repeatedly: *a capability reachable only from a test is not a capability*,
  and its mirror is that a refusal only reachable by calling an internal
  function is not a refusal a caller can meet.

  ## The grammar carries NO field, and that is the authority argument

  `acquire_terminal` declares `fields: []`. There is no `carrier_ref`, no
  `worker_ref`, no `peer_ref` — nothing to name someone else's position with,
  so there is nothing here to get wrong. Every case below is therefore a
  statement about **who is on the connection**, re-derived from that Peer
  alone, and no test may pass an identity in to make one happen.

  ## Why the machine is never reached, and why that is checked

  `acquire/1` is `admit_attach/1 |> machine_attach/1 |> own_stream/3 |>
  commit/4`. Every refusal below happens in the first, so the unbounded host
  round trip never starts — the same property `carrier_test`'s E1 states for
  starts (*"the machine never saw it"*). It is checked here by the refusal's
  own name: `terminal-machine-refused` and `terminal-acquire-indeterminate`
  are the two codes that can only arise after admission, and `Z0` below is
  the discriminator that proves they are reachable at all. Without `Z0` every
  row here would also pass against an `acquire_terminal` that refused
  unconditionally.

  ## The positive path is NOT here

  A successful acquire needs a real host carrier channel: `attach/2` asks
  `Ampd.Bridge.carrier_endpoint()` and refuses to resolve a host by name.
  There is no terminal-machine harness and this file does not add one — a
  fabricated `pty-attach` answer would be the same *harness proves the
  harness* shape D.1.3b·2c found when the Elixir side invented the attested
  floor rows. The positive path is proved against a real host, twice:
  `super-host verify`'s R0a section and `tools/terminal-join-probe.mjs`.
  """
  use ExUnit.Case, async: false

  alias Ampd.{Authority, Bridge, Carrier, Control, Loci, Peer, World}
  alias Ampd.Carrier.Machine.Harness

  setup do
    if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()
    Ampd.reset()
    Bridge.reset()
    Peer.reset()
    Harness.reset()
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
    worker = ok!(Control.command(control, :open_worker, [lane["id"], "work"]), "worker")
    ok!(Control.command(agent, :attach_worker, [worker["id"]]), "worker")

    %{control: control, agent: agent, lane: lane, worker: worker}
  end

  defp ok!(result, key) do
    assert result["allow"] == true,
           "expected #{key}, got: #{inspect(Map.take(result, ["allow", "reason", "refusal"]))}"

    result[key]
  end

  defp init_repo! do
    dir = Path.join(Ampd.Store.data_dir(), "fixture-repo-b9")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "README"), "b9\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.email", "b9@example.invalid"],
          ["config", "user.name", "B9"],
          ["config", "commit.gpgsign", "false"],
          ["add", "-A"],
          ["commit", "-q", "-m", "init"]
        ] do
      {out, code} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
      assert code == 0, "fixture repo setup failed: git #{Enum.join(args, " ")} -> #{out}"
    end

    dir
  end

  # The command, with the empty argument list the grammar declares. Written
  # once so no test can quietly pass a field.
  defp acquire(peer), do: Control.command(peer, :acquire_terminal, [])

  defp refusal(r), do: get_in(r, ["refusal", "code"]) || r["reason"]

  defp refused!(r, code) do
    assert r["allow"] == false, "expected a refusal, got #{inspect(r)}"
    assert refusal(r) == code, "expected #{code}, got #{inspect(refusal(r))}"
    r
  end

  # The two codes that exist only AFTER admission. Any test asserting an
  # admission refusal also asserts it is not one of these, because a
  # post-admission failure would mean the unbounded machine phase had already
  # started for a caller the World should have stopped.
  @post_admission ~w(terminal-machine-refused terminal-acquire-indeterminate)

  defp never_reached_the_machine!(r) do
    refute refusal(r) in @post_admission,
           "#{refusal(r)} is a post-admission code — the machine phase ran for a refused caller"

    r
  end

  defp start_carrier!(agent, lane) do
    r = Control.command(agent, :start_carrier, [lane["id"]])
    assert r["allow"] == true, "expected a Carrier, got #{inspect(r)}"
    r["carrier"]
  end

  # ================================================================== Z0
  #
  # **The discriminator, and every other test in this file depends on it.**
  #
  # A fully-occupied Peer with a live Carrier and no terminal passes the whole
  # admission chain, and then fails in the machine phase because this test
  # runtime possesses no host carrier channel. That failure is
  # `terminal-acquire-indeterminate`, which is a *different* answer from every
  # refusal below — so the matrix is measuring admission and not measuring an
  # `acquire_terminal` that never works.
  test "Z0 · a fully-occupied Peer with a live Carrier is ADMITTED and fails only in the machine",
       ctx do
    _c = start_carrier!(ctx.agent, ctx.lane)

    r = acquire(ctx.agent)
    assert r["allow"] == false
    assert refusal(r) in @post_admission,
           "expected a post-admission failure, got #{inspect(refusal(r))} — if this is an " <>
             "admission refusal then the rows below prove nothing"
  end

  # ================================================================== Z1
  test "Z1 · a Peer that occupies nothing cannot acquire a terminal", ctx do
    # The same actor, a second live channel, occupying nothing. Identity is
    # necessary and not sufficient — D.1.2's result, and the reason this
    # command can afford an empty grammar.
    {:ok, stranger} = Peer.attach_agent("kestrel")
    _ = start_carrier!(ctx.agent, ctx.lane)

    acquire(stranger)
    |> refused!("carrier-not-attached")
    |> never_reached_the_machine!()
  end

  # ================================================================== Z2
  test "Z2 · another actor's Peer cannot acquire this one's terminal", ctx do
    {:ok, other} = Peer.attach_agent("magpie")
    _ = start_carrier!(ctx.agent, ctx.lane)

    # `magpie` occupies nothing, and there is no argument on this command with
    # which it could designate `kestrel`'s position. That absence is the whole
    # defence: the refusal is not "you named someone else's Worker", it is
    # "you are standing nowhere".
    acquire(other)
    |> refused!("carrier-not-attached")
    |> never_reached_the_machine!()
  end

  # ================================================================== Z3
  test "Z3 · the human control channel cannot acquire a terminal", ctx do
    _ = start_carrier!(ctx.agent, ctx.lane)

    # Refused by the grammar's channel restriction, before any of the chain
    # above runs. A person is the source of consent and occupies nothing;
    # `Ampd.Worker.occupancy/2` would refuse this too, and the grammar
    # refusing first is what makes that a second line rather than the only
    # one.
    r = acquire(ctx.control)
    assert r["allow"] == false
    never_reached_the_machine!(r)
    refute refusal(r) == nil
  end

  # ================================================================== Z4
  test "Z4 · a Worker with no Carrier has no terminal to possess", ctx do
    acquire(ctx.agent)
    |> refused!("terminal-no-live-carrier")
    |> never_reached_the_machine!()
  end

  # ================================================================== Z5
  test "Z5 · a second acquire is refused while one is possessed", ctx do
    _ = start_carrier!(ctx.agent, ctx.lane)

    # The record is installed as world state, not passed on the wire: the
    # command still carries no field. This is `terminal_possession_test`'s
    # K.2b, asked through the command rather than through `admit_attach/1`.
    peer = Peer.resolve(ctx.agent)

    {:ok, _} =
      Peer.install_terminal(
        peer["id"],
        %{
          "schema" => "terminal-attachment@1",
          "attachment_ref" => "ta_" <> String.duplicate("f", 32),
          "status" => "ACTIVE",
          "worker_ref" => ctx.worker["id"],
          "worker_generation" => 1
        },
        self()
      )

    acquire(ctx.agent)
    |> refused!("terminal-already-attached")
    |> never_reached_the_machine!()
  end

  # ================================================================== Z6
  test "Z6 · a Carrier that has gone leaves nothing to possess", ctx do
    _ = start_carrier!(ctx.agent, ctx.lane)
    assert Control.command(ctx.agent, :stop_carrier, [])["allow"] == true

    acquire(ctx.agent)
    |> refused!("terminal-no-live-carrier")
    |> never_reached_the_machine!()
  end

  # ================================================================== Z7
  test "Z7 · closing the Worker ends the possession's basis", ctx do
    _ = start_carrier!(ctx.agent, ctx.lane)
    assert Control.command(ctx.control, :close_worker, [ctx.worker["id"]])["allow"] == true

    # `worker-not-open` and not `terminal-no-live-carrier`: the chain asks
    # the cheaper, more specific question first, so a closed Worker is
    # refused as a closed Worker rather than as whichever later row its
    # closure also happened to break.
    acquire(ctx.agent)
    |> refused!("worker-not-open")
    |> never_reached_the_machine!()
  end

  # ================================================================== Z8
  test "Z8 · a Peer that is gone cannot acquire, and is refused BEFORE the terminal chain", ctx do
    _ = start_carrier!(ctx.agent, ctx.lane)
    ref = ctx.agent
    Peer.detach(ref)

    # **`unknown-peer`, not `terminal-peer-gone`, and the difference is the
    # finding.** `admit/1` has a `terminal-peer-gone` clause for the Peer
    # vanishing *during* admission — a race it must survive. A caller whose
    # Peer is already gone never gets that far: `Ampd.Control` will not
    # dispatch for a reference it cannot resolve, so the command is refused
    # one layer earlier and by a name that says so. Asserting
    # `terminal-peer-gone` here would have been asserting that the outer gate
    # does not exist.
    acquire(ref)
    |> refused!("unknown-peer")
    |> never_reached_the_machine!()
  end

  # ================================================================== Z9
  test "Z9 · a World whose lineage has moved leaves no current Carrier", ctx do
    _ = start_carrier!(ctx.agent, ctx.lane)
    before = World.lineage()

    # A new World incarnation. `Ampd.Carrier.still_current?/2` binds
    # `world_ref`, so the Carrier the Peer holds stops being the one
    # embodying this Worker the moment the lineage moves — which is the
    # property, and it is stated as a refusal rather than as a silent
    # replacement.
    World.bump_generation!("b9 acquisition matrix", %{})
    refute World.lineage() == before

    # **`world-incarnation-changed`, and again it is the OUTER gate.**
    # `still_current?/2` binds `world_ref` and would refuse this as
    # `terminal-carrier-not-current`; it never runs, because a command
    # arriving under a superseded world incarnation is refused before
    # dispatch. Two independent reasons this cannot succeed, and the command
    # path meets the first — which is what a matrix aimed at the command
    # rather than at the function is for.
    r = acquire(ctx.agent)
    assert r["allow"] == false
    never_reached_the_machine!(r)

    assert refusal(r) == "world-incarnation-changed",
           "expected the incarnation gate, got #{inspect(refusal(r))}"
  end
end
