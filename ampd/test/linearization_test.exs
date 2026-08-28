defmodule Ampd.LinearizationTest do
  @moduledoc """
  Authority linearization. C1.0b claimed the TOCTOU window was closed by
  ordering; the review narrowed that correctly — `Effects.claim/1`
  serialized effects against *effects*, and nothing serialized an effect
  against a *grant mutation*. This interleaving was reachable:

      decide under grant G  →  another process revokes G (and returns)
                            →  claim → consume → adapter runs

  These falsifiers pin the boundary:

  > **CLAIM is the authority boundary.** Before it, revocation wins.
  > After it, the effect holds a lease for its frozen snapshot.
  """
  use ExUnit.Case, async: false
  alias Ampd.{Authority, AuthorityCoordinator, GrantRegistry, CapabilityRegistry,
              Gateway, Receipts, Effects}

  defp grant_pr_create do
    Authority.set_draft("pr.create", true)
    Authority.commit(CapabilityRegistry.get("github")["surface"])
  end

  # ---------------------------------------------------------------- before
  test "once a revoke returns, no later effect authorizes under it" do
    Ampd.reset_demo()
    assert Ampd.Conformance.exercise("pr.draft")["allow"]
    assert Receipts.count() == 1

    Authority.revoke_domain("github.pr.draft")

    r = Ampd.Conformance.exercise("pr.draft")
    refute r["allow"], "an effect authorized after its grant's revocation returned"
    assert r["reason"] =~ "authority-missing"
    assert Receipts.count() == 1, "a receipt was emitted under revoked authority"
  end

  # NOTE ON WHAT THIS PROVES. This one passes with the coordinator disabled
  # too — `perform` re-decides inside `claim_and_consume`, so it holds for
  # the weaker reason that no stale decision is carried across the call.
  # It is a regression guard on that structure, not evidence of
  # linearization. The falsifier that actually fails without the
  # coordinator is the one-shot double-spend below.
  test "perform re-decides rather than carrying a caller's earlier verdict" do
    Ampd.reset_demo()

    # Exactly the reviewed interleaving, made explicit: look first...
    pf = Gateway.preflight("github.pr.draft", "traaviis/trvm", Gateway.ctx(),
           %{"er" => "er-github.pr.draft", "rev" => 1, "params" => %{"repo" => "traaviis/trvm"}})

    assert pf["eligible"], "precondition: preflight must start out eligible"
    assert pf["advisory"] == true

    # ...then revoke, and only then try to act on that decision.
    Authority.revoke_domain("github.pr.draft")

    r = Ampd.Conformance.exercise("pr.draft")

    refute r["allow"],
           "perform honoured a decision taken before a completed revocation"

    assert Receipts.count() == 0
    assert Effects.all() |> Enum.all?(&(&1["state"] != "COMMITTED"))
  end

  # ----------------------------------------------------------------- after
  test "after CLAIM the effect holds a lease: a revoke mid-adapter does not undo it" do
    Ampd.reset_demo()

    # The adapter runs outside the authority lock — deliberately, so a slow
    # remote call cannot block every revocation on someone else's TCP
    # timeout. Revoking from inside it is the sharpest test of the lease.
    adapter = fn _attempt ->
      Authority.revoke_domain("github.pr.draft")
      :did_the_thing
    end

    r = Gateway.perform("github.pr.draft", "traaviis/trvm", Gateway.ctx(),
          %{"er" => "er-github.pr.draft", "rev" => 1, "params" => Ampd.Core.params()["pr.draft"]},
          adapter)

    assert r["allow"], "a claimed effect was cancelled by a revocation that arrived after the claim"
    assert Receipts.count() == 1
    e = List.last(Effects.all())
    assert e["state"] == "COMMITTED"

    # The revoke still took effect — for everything after it.
    refute Ampd.Conformance.exercise("pr.draft")["allow"]
    assert Receipts.count() == 1
  end

  # ----------------------------------------------------------- concurrency
  # THE falsifier for this round. Without the coordinator, N concurrent
  # exercises each `decide` "allow" against the same single use before any
  # of them consumes it, and several commit — authority is double-spent.
  # Verified to fail when `AuthorityCoordinator.transact/2` is stubbed out.
  test "concurrent performs on a one-shot produce exactly one receipt" do
    Ampd.reset_demo()
    Authority.revoke_domain("github.pr.draft")
    Authority.one_shot("github.pr.draft")

    results =
      1..24
      |> Task.async_stream(fn _ -> Ampd.Conformance.exercise("pr.draft")["allow"] end,
           max_concurrency: 24, timeout: 15_000)
      |> Enum.map(fn {:ok, v} -> v end)

    allowed = Enum.count(results, & &1)

    assert allowed == 1, "#{allowed} of 24 concurrent exercises authorized one one-shot use"
    assert Receipts.count() == 1
    assert Enum.count(Effects.all(), &(&1["state"] == "COMMITTED")) == 1
  end

  # An invariant check, not a falsifier: at this contention it also passes
  # with the coordinator stubbed out, because the registry GenServers
  # serialize each individual operation and the window is narrow. It earns
  # its place by asserting verdict and ledger can never disagree.
  test "a revoke racing many performs never lets the grant be spent twice" do
    for round <- 1..8 do
      Ampd.reset_demo()
      Authority.revoke_domain("github.pr.draft")
      Authority.one_shot("github.pr.draft")

      # 12 contenders for one use, with a revocation landing somewhere in
      # the middle. Whatever order the coordinator picks, the grant permits
      # at most one effect and every verdict must agree with the ledger.
      tasks =
        Enum.map(1..12, fn _ -> Task.async(fn -> {:perform, Ampd.Conformance.exercise("pr.draft")} end) end) ++
          [Task.async(fn -> {:revoke, Authority.revoke_domain("github.pr.draft")} end)]

      results = Task.await_many(tasks, 20_000)
      allowed = Enum.count(results, fn r -> match?({:perform, %{"allow" => true}}, r) end)
      committed = Enum.count(Effects.all(), &(&1["state"] == "COMMITTED"))

      assert allowed <= 1, "round #{round}: #{allowed} effects authorized on a single use"
      assert Receipts.count() == allowed,
             "round #{round}: #{allowed} allowed but #{Receipts.count()} receipts — verdict and ledger disagree"
      assert committed == allowed
    end
  end

  test "concurrent grant edits leave exactly one active grant per domain" do
    Ampd.reset_demo()

    1..16
    |> Task.async_stream(
      fn i ->
        if rem(i, 2) == 0 do
          Authority.set_dur("run")
        else
          Authority.set_dur("workspace")
        end

        Authority.commit(CapabilityRegistry.get("github")["surface"])
      end,
      max_concurrency: 16, timeout: 15_000
    )
    |> Stream.run()

    active =
      GrantRegistry.list()
      |> Enum.filter(&(&1["status"] == "active" and &1["capability"] == "github.repo.read"))

    assert length(active) == 1,
           "grant domain accumulated #{length(active)} active grants under concurrent edits"
  end

  # ------------------------------------------------------------ mechanics
  test "the coordinator is re-entrant rather than self-deadlocking" do
    Ampd.reset_demo()

    v =
      AuthorityCoordinator.transact(fn ->
        # Already inside the order — this must run directly, not enqueue.
        AuthorityCoordinator.transact(fn -> :nested end)
      end)

    assert v == :nested
  end

  test "a raw registry mutation is refused mechanically, not by convention" do
    Ampd.reset_demo()
    before = GrantRegistry.list()

    # The accident this prevents: reaching for the primitive instead of the
    # linearized API. It is unordered against a concurrent claim, so it is
    # refused rather than served.
    assert {:refused, r} = GrantRegistry.revoke_domain("github.repo.read")
    assert r["schema"] == "refusal@1"
    assert r["code"] == "unordered-authority-mutation"
    assert r["operator_detail"]["module"] =~ "GrantRegistry"
    assert GrantRegistry.list() == before, "a refused mutation still changed state"

    # Same operation through Ampd.Authority is served.
    Authority.revoke_domain("github.repo.read")
    refute Ampd.Conformance.authorize("github.repo.read", "traaviis/trvm", Gateway.ctx(), nil)["allow"]
  end

  test "the raw guard covers every authority-bearing registry" do
    Ampd.reset_demo()

    assert {:refused, _} = Ampd.Session.end_run()
    assert {:refused, _} = Ampd.Approvals.mark("ap_x", "granted")
    assert {:refused, _} = Ampd.CapabilityRegistry.update_github()
    assert {:refused, _} = Ampd.Effects.claim("ef_0001")
    assert {:refused, _} = GrantRegistry.set_dur("run")

    # The two ops `grant-request@1` added are inside the boundary too. A
    # request creates no authority, but it is a durable object a human
    # decides on, and an unordered write to it races the decision.
    assert {:refused, _} = GrantRegistry.request_grant(%{"capability" => "github.pr.merge"})
    assert {:refused, _} = GrantRegistry.resolve_request("gq_0001", "granted", nil)

    # ...and none of them moved anything.
    assert Ampd.Session.run() == "run-b51"
    assert Ampd.CapabilityRegistry.get("github")["version"] == "1.4.2"
    assert GrantRegistry.requests() == []
  end

  test "preflight is advisory and mutates nothing" do
    Ampd.reset_demo()
    grant_pr_create()

    approvals_before = length(Ampd.Approvals.all())
    ops_before = AuthorityCoordinator.ops()

    pf =
      Gateway.preflight("github.pr.create", "traaviis/trvm", Gateway.ctx(),
        %{"er" => "er-github.pr.create", "rev" => 1, "params" => Ampd.Core.params()["pr.create"]})

    assert pf["schema"] == "preflight@1"
    assert pf["advisory"] == true
    assert pf["eligible"] == true
    assert pf["requires_approval"] == true
    assert pf["effect_key"] =~ ~r/^sha256:/
    assert pf["placement"]["site"] == "local"

    assert length(Ampd.Approvals.all()) == approvals_before,
           "preflight opened a pending approval — it is supposed to create nothing"

    assert AuthorityCoordinator.ops() == ops_before,
           "preflight consumed an ordered operation"
  end

  test "preflight never stales consent the way decide did" do
    Ampd.reset_demo()
    grant_pr_create()
    Ampd.Conformance.exercise("pr.create")
    p = List.last(Ampd.Approvals.all())
    Authority.grant_approval(p["id"])

    # A revised proposal: through the ordered path this stales prior
    # consent. Preflight must only report.
    Gateway.preflight("github.pr.create", "traaviis/trvm", Gateway.ctx(),
      %{"er" => "er-github.pr.create", "rev" => 2,
        "params" => %{"repo" => "traaviis/trvm", "branch" => "lane-a", "title" => "edited"}})

    assert Enum.find(Ampd.Approvals.all(), &(&1["id"] == p["id"]))["status"] == "granted",
           "preflight staled an approval outside the total order"
  end

  test "every authority mutation and claim passes through the one order" do
    Ampd.reset_demo()
    before = AuthorityCoordinator.ops()

    Authority.revoke_domain("github.pr.draft")
    Authority.one_shot("github.pr.draft")
    grant_pr_create()
    Ampd.Conformance.exercise("pr.draft")

    assert AuthorityCoordinator.ops() > before,
           "authority changed without passing through the coordinator"
  end
end
