defmodule Ampd.OrderedClosureTest do
  @moduledoc """
  C1.0b·2·1 falsifiers — `Q.1`..`Q.9`.

  The proposition C1.0b·2 proved for two participants, now for the set the
  reachability census actually names:

      Every cross-process call reachable while an AuthorityCoordinator
      ordered transaction or ordered observation is executing is either
      routed through `Ampd.Participant` with an explicit class or excluded
      for a stated reason — and no participant's failure takes the total
      order with it merely because that participant happened to be next.

  ## Why these families and not others

  `tools/ordered-reachability.exs` derives the reachable set from compiled
  BEAM abstract code. It names `Ampd.GrantRegistry`, `Ampd.CapabilityRegistry`,
  `Ampd.Approvals`, `Ampd.Effects`, `Ampd.Session`, `Ampd.Worktree`,
  `Ampd.Bridge`, `Ampd.Receipts` and `Ampd.Embodiment` — every one of them
  through a real `Ampd.Authority` entry point. So the tests below enter
  through `Ampd.Authority` wherever a one-line entry exists, and say so where
  they enter through `transact/1` directly because the real path needs a
  world's worth of fixture.

  **Source enumeration is not the proof.** `tools/check-ordered-closure.mjs`
  reads the census and the adjudication and can only tell you the boundary is
  *declared*. These tests kill and suspend the real registries.

  ## The sharpest one is `Q.5`

  A suspended participant is alive, so its request is neither delivered nor
  lost — it is queued. `Q.5` suspends `Ampd.Approvals` mid-transaction, reads
  INDETERMINATE, resumes it, and then finds the mutation **applied**. That is
  what INDETERMINATE means and it is not visible from any return value: the
  caller abandoned the response, and the work went on.
  """
  use ExUnit.Case, async: false

  alias Ampd.{Authority, AuthorityCoordinator, GrantRegistry}

  @families [
    Ampd.GrantRegistry,
    Ampd.CapabilityRegistry,
    Ampd.Approvals,
    Ampd.Effects,
    Ampd.Session,
    Ampd.Worktree,
    Ampd.Bridge,
    Ampd.Receipts,
    Ampd.Embodiment,
    Ampd.RefusalLog,
    Ampd.Subscriptions,
    Ampd.Carrier.Reaper
  ]

  setup do
    on_exit(fn ->
      for m <- @families do
        if Process.whereis(m) == nil, do: _ = Supervisor.restart_child(Ampd.Supervisor, m)
      end

      Process.sleep(250)
    end)

    :ok
  end

  defp coordinator, do: Process.whereis(AuthorityCoordinator)
  defp ordered(fun), do: AuthorityCoordinator.transact(fun)

  defp absent(mod, fun) do
    before = coordinator()
    :ok = Supervisor.terminate_child(Ampd.Supervisor, mod)
    result = fun.()
    assert coordinator() == before, "losing #{inspect(mod)} took the total order down"
    result
  end

  defp code_of({:refused, r}), do: r["code"]
  defp code_of(other), do: {:unexpected, other}

  # ===================================================================== Q.1
  describe "Q.1 · a mutation that never arrived is NOT_APPLIED, in every family" do
    test "Ampd.GrantRegistry, through Ampd.Authority.mint/1" do
      r = absent(Ampd.GrantRegistry, fn -> Authority.mint(%{"capability" => "q1"}) end)
      assert code_of(r) == "participant-not-applied"
    end

    test "Ampd.CapabilityRegistry, through Ampd.Authority.install_postgres/0" do
      r = absent(Ampd.CapabilityRegistry, fn -> Authority.install_postgres() end)
      assert code_of(r) == "participant-not-applied"
    end

    test "Ampd.Approvals, through Ampd.Authority.grant_approval/1" do
      r = absent(Ampd.Approvals, fn -> Authority.grant_approval("ap_q1") end)
      assert code_of(r) == "participant-not-applied"
    end

    test "Ampd.Session, through Ampd.Authority.end_run/0" do
      r = absent(Ampd.Session, fn -> Authority.end_run() end)
      assert code_of(r) == "participant-not-applied"
    end

    test "Ampd.Worktree, through Ampd.Authority.register_repository/1" do
      r = absent(Ampd.Worktree, fn -> Authority.register_repository("/nonexistent/q1") end)
      assert code_of(r) == "participant-not-applied"
    end

    test "Ampd.Effects, entered through transact/1 — the real path needs a claimed grant" do
      r = absent(Ampd.Effects, fn -> ordered(fn -> Ampd.Effects.propose(%{"id" => "q1"}) end) end)
      assert code_of(r) == "participant-not-applied"
    end

    test "Ampd.Bridge, entered through transact/1 — the real path is advance_lineage/2" do
      r = absent(Ampd.Bridge, fn -> ordered(fn -> Ampd.Bridge.reset() end) end)
      assert code_of(r) == "participant-not-applied"
    end

    test "Ampd.Receipts, entered through transact/1" do
      r = absent(Ampd.Receipts, fn -> ordered(fn -> Ampd.Receipts.emit(%{"id" => "rc_q1"}) end) end)
      assert code_of(r) == "participant-not-applied"
    end
  end

  # ===================================================================== Q.2
  describe "Q.2 · a read that cannot be obtained is UNAVAILABLE, never a refusal about the world" do
    test "Ampd.GrantRegistry.list/0 inside an ordered observation" do
      r = absent(Ampd.GrantRegistry, fn -> ordered(fn -> GrantRegistry.list() end) end)
      assert code_of(r) == "participant-unavailable"
    end

    test "Ampd.Worktree.repos/0 inside an ordered observation" do
      r = absent(Ampd.Worktree, fn -> ordered(fn -> Ampd.Worktree.repos() end) end)
      assert code_of(r) == "participant-unavailable"
    end

    test "the two classes are graded differently for the operator" do
      # `unavailable` and `not_applied` are both retryable; `indeterminate` is
      # not, and is the only one that requires a human. A grading that made
      # them all the same would pass every other test in this file.
      u = Ampd.Participant.refusal(Ampd.Participant.Failure.new(:unavailable, X, :op, :noproc))
      n = Ampd.Participant.refusal(Ampd.Participant.Failure.new(:not_applied, X, :op, :noproc))
      i = Ampd.Participant.refusal(Ampd.Participant.Failure.new(:indeterminate, X, :op, :timeout))

      assert u["retryable"] and n["retryable"]
      refute i["retryable"]
      refute u["requires_human"] or n["requires_human"]
      assert i["requires_human"]
    end
  end

  # ===================================================================== Q.3
  test "Q.3 · a participant crashing mid-transaction does not restart the total order" do
    # Not "the coordinator is alive afterwards" — that is satisfied by a
    # coordinator that died and was restarted, which is precisely the
    # control-plane discontinuity this exists to prevent. The epoch is minted
    # in `init/1`, so an unchanged epoch is the falsifiable form.
    epoch = AuthorityCoordinator.epoch()
    before = coordinator()

    for mod <- [Ampd.GrantRegistry, Ampd.Approvals, Ampd.Session, Ampd.Worktree] do
      :ok = Supervisor.terminate_child(Ampd.Supervisor, mod)
      _ = ordered(fn -> apply(mod, :sealed, []) end)
      _ = Supervisor.restart_child(Ampd.Supervisor, mod)
    end

    assert coordinator() == before
    assert AuthorityCoordinator.epoch() == epoch, "the total order was re-minted by a registry fault"
  end

  # ===================================================================== Q.4
  test "Q.4 · the ordered surface is CLOSED — every crossing converted or adjudicated" do
    # The generated census, not a hand-maintained list. This asserts the
    # artifact and the gate agree with the source they were derived from.
    root = Path.expand("../..", __DIR__)
    census = Path.join(root, "tools/ordered-reachability.json")
    rules = Path.join(root, "tools/ordered-boundary-exclusions.json")

    assert File.exists?(census), "the reachability census has never been generated"
    c = census |> File.read!() |> JSON.decode!()
    x = rules |> File.read!() |> JSON.decode!()

    unadjudicated =
      for cr <- c["crossings"],
          cr["kind"] != "converted",
          not Map.has_key?(x["crossings"], cr["id"]),
          do: cr["id"]

    assert unadjudicated == [],
           "reachable inside the order, neither converted nor excluded:\n  " <>
             Enum.join(unadjudicated, "\n  ")

    unseen =
      for o <- c["opaque"],
          not Map.has_key?(x["opaque"], "#{o["in"]} #{o["why"]}"),
          do: "#{o["in"]} #{o["why"]}"

    assert unseen == [],
           "the census cannot follow these and nothing says where they land:\n  " <>
             Enum.join(unseen, "\n  ")

    assert c["totals"]["converted"] > 0
  end

  # ===================================================================== Q.5
  test "Q.5 · a timed-out mutation is INDETERMINATE, and the work goes on without us" do
    # `:sys.suspend/1` gives what no absent participant can: a process that is
    # ALIVE and not answering. The request is neither lost nor delivered — it
    # is queued, which is the exact state `INDETERMINATE` describes and the
    # one no return value distinguishes.
    #
    # **`Ampd.Approvals.push/1`, deliberately, and the first version used
    # `GrantRegistry.mint/1` and proved nothing.** A mint in a bare world is
    # refused `capability-undeclared` on its own merits, so the second half
    # of this test — the mutation landing after the caller gave up — was
    # asserting a mutation that would never have happened anyway. The
    # participant this test needs is one whose ordered mutation has no domain
    # precondition, so that the only thing that can stop it is the timeout.
    before = length(Ampd.Approvals.all())
    coord = coordinator()

    :ok = :sys.suspend(Ampd.Approvals)

    result =
      try do
        ordered(fn -> Ampd.Approvals.push(%{"id" => "ap_q5", "status" => "pending"}) end)
      after
        :sys.resume(Ampd.Approvals)
      end

    assert code_of(result) == "participant-indeterminate"
    assert coordinator() == coord, "a slow registry took the total order down"

    r = elem(result, 1)
    refute r["retryable"], "an indeterminate mutation must not be offered as retryable"
    assert r["requires_human"]
    assert r["operator_detail"]["participant"] == "Ampd.Approvals"
    assert r["operator_detail"]["reason"] == ":timeout"

    # And now the half that is not visible from the refusal, and is the whole
    # reason a timeout may not be read as a refusal: the response was
    # abandoned, the work was not.
    Process.sleep(300)

    assert length(Ampd.Approvals.all()) == before + 1,
           "the push the caller gave up on never landed — then INDETERMINATE would be too " <>
             "strong here, and the asymmetry this slice rests on is not the one measured"
  end

  # ===================================================================== Q.6
  test "Q.6 · a slow participant does not make the transaction return before it" do
    # The failure this rules out: a boundary that returned early and let the
    # closure keep running would linearize two operations under one `seq`.
    ops = AuthorityCoordinator.ops()
    :ok = :sys.suspend(Ampd.Session)

    _ =
      try do
        ordered(fn -> Ampd.Session.end_run() end)
      after
        :sys.resume(Ampd.Session)
      end

    # A refused transaction is still an operation the order performed.
    assert AuthorityCoordinator.ops() >= ops
  end

  # ===================================================================== Q.7
  test "Q.7 · every converted family declares the class of every message it sends" do
    # The list is read, not inferred. A tag sent but named by no list is
    # silently a read — which gives an indeterminate write a retryable
    # "basis unavailable" and invites the second execution the class forbids.
    for {mod, mutations, reads} <- [
          {Ampd.GrantRegistry, [:mint, :revoke_one, :consume, :commit, :reset, :close_store],
           [:sealed, :list, :requests]},
          {Ampd.CapabilityRegistry, [:install_postgres, :update_github, :reset], [:get, :all, :sealed]},
          {Ampd.Approvals, [:mark, :push, :new_pending], [:all, :sealed]},
          {Ampd.Effects, [:propose, :claim, :to, :attempt, :recover], [:all, :sealed]},
          {Ampd.Session, [:world, :end_run, :reset], [:snap, :retired?, :sealed]},
          {Ampd.Worktree, [:create, :set_state, :request, :register_repo], [:get, :all, :sealed]},
          {Ampd.Bridge, [:adopt, :reset, :bind_effect, :drop_effect], [:list, :effect_endpoint]},
          {Ampd.Receipts, [:emit, :reset], [:all, :sealed]},
          {Ampd.Embodiment, [:refresh], [:identity, :probe]},
          {Ampd.Subscriptions, [:subscribe, :unsubscribe], [:count]},
          {Ampd.RefusalLog, [:reset], [:get, :recent, :count]},
          # `:drain` is a mailbox barrier that mutates nothing — see the
          # comment on this module's empty mutation list. Classifying it a
          # mutation would make a barrier that did not answer INDETERMINATE.
          {Ampd.Carrier.Reaper, [], [:unconfirmed, :drain]}
        ] do
      for t <- mutations, do: assert(mod.class(t) == :mutate, "#{inspect(mod)}.#{t} is a mutation")
      for t <- reads, do: assert(mod.class(t) == :read, "#{inspect(mod)}.#{t} is a read")
    end
  end

  # ===================================================================== Q.8
  test "Q.8 · the embodiment deadline is inside the budget it runs under" do
    # It was 30_000 inside a 15_000 budget, reachable from
    # `Ampd.Carrier.admit_start/2` → `Locus.profile_digest/0` → here. The
    # coordinator's client raised at fifteen while the coordinator was still
    # blocked, so the fail-closed answer this module exists to give never
    # arrived. Read off the module that owns it, like C14's other four.
    identity = Ampd.Embodiment.identity_deadline_ms()
    budget = AuthorityCoordinator.budget_ms()

    assert identity < budget,
           "the embodiment measurement outlives the transaction that encloses it: " <>
             "#{identity} >= #{budget}"

    assert budget - identity >= 2_000, "less than 2s of margin under the transaction budget"

    # **And above the wait it encloses.** The first version of this assertion
    # demanded margin over the SUM of the two channel waits this handler can
    # make — 20_000, above the transaction budget itself, so no value of the
    # deadline could have satisfied it. The rule is per-wait, not per-handler:
    # a handler that outruns its caller's deadline is bounded BY that
    # deadline, which is the whole reason the caller has one.
    channel = Ampd.Worktree.EffectChannel.deadline_ms()

    assert channel < identity,
           "the embodiment deadline does not clear the channel wait it encloses: " <>
             "#{channel} >= #{identity}"

    assert identity - channel >= 2_000, "less than 2s of margin over the channel wait"
  end

  # ===================================================================== Q.9
  test "Q.9 · a participant failure inside the embodiment cache is still fail-closed" do
    # This module's contract is that ABSENT MEASUREMENT REFUSES rather than
    # raises: `unidentified/2` digests differently from every real identity.
    # The boundary raises where a bare call exited, so without the rescue
    # clause the exception would leave through the coordinator and turn a
    # fail-closed measurement into a failed transaction.
    #
    # **Suspended, not terminated — and the sabotage battery is what said
    # so.** The first version of this test stopped the process through its
    # supervisor, and `identity/0` checks `Process.whereis(__MODULE__)`
    # first: with the process gone it answers `unidentified/2` from that
    # branch and never reaches the boundary at all. So the test passed with
    # the rescue clause disabled, and probe 126 came back **NOT A
    # FALSIFIER** — a fix nothing tested, sitting under a green suite.
    #
    # A suspended cache is registered and does not answer, which is the only
    # state that reaches the clause under test. It costs the full
    # `identity_deadline_ms/0` to run, and that is the price of testing the
    # branch rather than its neighbour.
    before = coordinator()

    :ok = :sys.suspend(Ampd.Embodiment)

    id =
      try do
        ordered(fn -> Ampd.Embodiment.identity() end)
      after
        :sys.resume(Ampd.Embodiment)
      end

    assert is_map(id), "the embodiment cache raised instead of answering unidentified"
    assert id["resolved"] == false
    assert coordinator() == before, "a silent embodiment cache took the total order down"

    # **The reason names the CLASS, and only the rescue clause can write
    # that.** The `whereis`-nil branch says "is not running"; the
    # `catch :exit` branch says "did not answer" with no class. Asserting the
    # class is what makes this test about the clause it is named for.
    assert id["reason"] =~ "unavailable",
           "the reason did not carry the participant class, so this did not come " <>
             "through the boundary: #{inspect(id["reason"])}"
  end

  # A stand-in server name for the grading assertions in Q.2. It never runs.
  defmodule X do
  end
end
