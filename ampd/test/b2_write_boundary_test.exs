defmodule Ampd.B2WriteBoundaryTest do
  @moduledoc """
  Gate 2 — the B2 write boundary, exercised on the REAL participants, the
  real `Ampd.Store` persistence and the real journal owner, and exported as
  `wek-r3-trace@3` for `wek/r3/verifier.mjs`.

  Every case here does three things: asserts the substrate's behaviour
  directly (refusal codes, store equality, counts), declares the HARNESS's
  expectation of the trace (kind, expected code, event count — never read
  from the log), and writes `<case>.trace.json` + `<case>.case.json` into
  `B2_EVIDENCE_DIR` for the verifier. The manifest is assembled from the
  case files when the module finishes.

  Crashes are injected deterministically: a barrier adapter that blocks
  until the test releases it, a kill while a participant is suspended, or
  a kill after a stage boundary the harness reproduces inside one
  transaction. Snapshots are the journal owner's own reads of the three
  registries, taken in evidence mode around each attempt.

  A late write that LANDS in any case below is an enforcement failure. The
  broken-control patches under `wek/b2/controls/` make one land, and the
  same harness plus the same verifier must then go RED.
  """
  use ExUnit.Case, async: false
  alias Ampd.{Authority, AuthorityCoordinator, Effects, Gateway, Receipts, GrantRegistry}
  alias Ampd.Effects.Witness

  @cap "github.pr.draft"
  @resource "traaviis/trvm"
  @req %{"er" => "er-github.pr.draft", "rev" => 1, "params" => %{"repo" => "traaviis/trvm"}}

  setup_all do
    # Outside the data dir: every case resets the world, which wipes that dir.
    dir =
      System.get_env("B2_EVIDENCE_DIR") ||
        Path.join(System.tmp_dir!(), "ampd-b2-evidence-#{System.pid()}")

    File.mkdir_p!(dir)
    rev = System.get_env("B2_SUBSTRATE_REVISION") || "unpinned"
    src = System.get_env("B2_SUBSTRATE_SOURCE") || File.cwd!()

    on_exit(fn ->
      cases =
        dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".case.json"))
        |> Enum.sort()
        |> Enum.map(&JSON.decode!(File.read!(Path.join(dir, &1))))

      manifest = %{
        "schema" => "wek-r3-case-manifest@1",
        "note" =>
          "HARNESS-OWNED. Case kinds, expected codes and event counts come from test/b2_write_boundary_test.exs, " <>
            "never from the traces. Provenance is substrate because these traces were emitted by the running runtime.",
        "provenance" => "substrate",
        "substrate" => %{"revision" => rev, "source" => src},
        "cases" => cases
      }

      File.write!(Path.join(dir, "manifest.json"), JSON.encode!(manifest))
    end)

    {:ok, dir: dir, rev: rev}
  end

  setup do
    Application.put_env(:ampd, :witness_snapshots, false)
    on_exit(fn -> Application.put_env(:ampd, :witness_snapshots, false) end)
    :ok
  end

  # ------------------------------------------------------------ helpers
  defp params, do: Ampd.Core.params()["pr.draft"]
  defp req, do: %{@req | "params" => params()}

  # A fresh demo world with N one-shot grants for the capability, minted
  # BEFORE the first snapshot so the baseline holds them (T1/T3).
  defp world!(n \\ 1) do
    Ampd.reset_demo()
    Authority.revoke_domain(@cap)
    grants = for _ <- 1..n, do: Authority.one_shot(@cap)
    [_] = Witness.files()
    Application.put_env(:ampd, :witness_snapshots, true)
    grants
  end

  defp wait_up(mod, probe, n \\ 200)
  defp wait_up(_mod, _probe, 0), do: flunk("registry did not come back")

  defp wait_up(mod, probe, n) do
    ok =
      Process.whereis(mod) != nil and
        try do
          probe.()
          true
        catch
          :exit, _ -> false
        end

    if ok do
      :ok
    else
      Process.sleep(20)
      wait_up(mod, probe, n - 1)
    end
  end

  defp kill!(mod, probe) do
    old = Process.whereis(mod)
    Process.exit(old, :kill)
    wait_up(mod, fn -> if Process.whereis(mod) == old, do: exit(:same), else: probe.() end)
  end

  defp claim!(grants_expected \\ 1) do
    {:claimed, auth, e, lease} =
      Authority.claim_and_consume(@cap, @resource, Gateway.ctx(), req())

    assert e["state"] == "CLAIMED" and e["branch"] == "B2"
    g = Enum.find(GrantRegistry.list(), &(&1["id"] == auth["grant_ref"]))

    assert g["status"] == "consumed" and g["uses_remaining"] == 0 and
             g["consumptions"] == [e["id"]]

    assert length(Enum.filter(GrantRegistry.list(), &(&1["consumptions"] != []))) ==
             grants_expected

    {auth, e, lease}
  end

  defp receipt_fields(e),
    do: %{
      "actor" => "kestrel",
      "capability" => @cap,
      "pack" => "github@1.4.2",
      "grant_ref" => e["grant_ref"],
      "effect_ref" => e["id"]
    }

  defp proof_of(r), do: get_in(r, ["operator_detail", "proof"])

  # Present a ticket to the receipts participant and report WHATEVER happened to
  # the owner — a landing as a landing, a refusal as a refusal — so that a build
  # in which the write lands produces a trace the verifier can fail (E-LATE),
  # not a harness that stopped before exporting.
  defp present(ticket, fields) do
    case Receipts.emit(ticket, fields) do
      {:ok, rc, w} ->
        Effects.landed(ticket, w)
        {:landed, rc}

      {:refused, r} ->
        Effects.refused(ticket, r["code"], proof_of(r))
        {:refused, r}
    end
  end

  # Write the trace and the harness's case spec. `count` is the harness's
  # expected event count (or crash position) — a literal, never the log's.
  defp export(ctx, id, kind, shape, expect \\ %{}) do
    files = Witness.files()
    trace = Witness.assemble(files, shape, ctx.rev)
    File.write!(Path.join(ctx.dir, "#{id}.trace.json"), JSON.encode!(trace))

    File.write!(
      Path.join(ctx.dir, "#{id}.case.json"),
      JSON.encode!(%{
        "case" => id,
        "kind" => kind,
        "trace" => "#{id}.trace.json",
        "expect" => expect,
        "must_fail" => false
      })
    )

    trace
  end

  defp close_with_state_and_listing do
    :ok = Effects.witness_state("state")
    Effects.witness_listing()
  end

  defp events(trace),
    do: trace["segments"] |> Enum.flat_map(& &1["events"]) |> Enum.map(& &1["type"])

  # ---------------------------------------------------------------- C1
  test "C1 · the whole B2 path succeeds through Gateway.perform, witnessed at both participants",
       ctx do
    [g] = world!()
    before = Effects.stores()

    r = Gateway.perform(@cap, @resource, Gateway.ctx(), req())
    assert r["allow"], inspect(r)
    e = Effects.get(r["effect_id"])
    assert e["state"] == "COMMITTED" and e["branch"] == "B2" and e["grant_ref"] == g["id"]

    assert Enum.map(e["history"], & &1["state"]) ==
             ~w(PROPOSED AUTHORIZED CLAIMED ATTEMPTED COMMITTED)

    g2 = Enum.find(GrantRegistry.list(), &(&1["id"] == g["id"]))
    assert g2["consumptions"] == [e["id"]]
    assert [w] = g2["consumption_witness"]
    assert w["ticket_id"] =~ ~r/^tk-/ and w["lease_id"] =~ ~r/^ls-/

    [rc] = Receipts.of_kind("capability-effect-receipt@1")
    assert rc["effect_ref"] == e["id"] and rc["landed_by"]["ticket_id"] =~ ~r/^tk-/
    assert r["receipt"]["id"] == rc["id"]

    listing = close_with_state_and_listing()

    assert listing[e["id"]] == %{
             "crash_phase" => nil,
             "approvals" => "NOT_REQUIRED",
             "grant_registry" => "COMPLETE",
             "receipts" => "COMPLETE"
           }

    assert Effects.recovery_listing() == listing
    refute Effects.stores() == before

    trace = export(ctx, "C1-b2-success", "enforcement", {:run, 17})
    assert length(events(trace)) == 17
  end

  # ---------------------------------------------------------------- F2
  test "F2 · retirement with no newer write: adapter raises, UNKNOWN, consumption stays, no receipt",
       ctx do
    [g] = world!()

    r =
      Gateway.perform(@cap, @resource, Gateway.ctx(), req(), fn _ -> raise "adapter refused" end)

    refute r["allow"]
    e = Effects.get(r["effect_id"])
    assert e["state"] == "UNKNOWN"
    assert Receipts.count() == 0
    assert Enum.find(GrantRegistry.list(), &(&1["id"] == g["id"]))["status"] == "consumed"

    assert Receipts.fence()["retired"] |> Map.keys() |> length() == 1,
           "S-3 must be acknowledged at the receipts participant"

    assert GrantRegistry.fence()["retired"] |> Map.keys() |> length() == 1

    listing = close_with_state_and_listing()

    assert listing[e["id"]] == %{
             "crash_phase" => nil,
             "approvals" => "NOT_REQUIRED",
             "grant_registry" => "COMPLETE",
             "receipts" => "INDETERMINATE"
           }

    export(ctx, "F2-retirement-no-newer-write", "enforcement", {:run, 13})
  end

  # ---------------------------------------------------------------- F1
  test "F1 · a held write released after ACKNOWLEDGED retirement is refused at the resource, state unchanged",
       ctx do
    world!()
    {_auth, e, lease} = claim!()
    {:ok, _e, _a} = Effects.attempt(lease, "b2-harness")
    committed = Effects.commit(lease, nil)
    assert committed["state"] == "COMMITTED"

    {:ok, held} = Effects.authorize_write(lease, "emit_receipt", e["id"])
    assert held["op"] == "emit_receipt" and held["target"] == e["id"]

    # S-3: retire, acknowledged by both declared participants before UNKNOWN is journaled.
    u = Effects.unknown(e["id"], "operator abandoned the effect")
    assert u["state"] == "UNKNOWN"
    assert Map.has_key?(Receipts.fence()["retired"], held["lease_id"])
    assert Map.has_key?(GrantRegistry.fence()["retired"], held["lease_id"])

    before = Effects.stores()
    outcome = present(held, receipt_fields(e))
    after_ = Effects.stores()
    listing = close_with_state_and_listing()

    export(ctx, "F1-held-write-after-acknowledged-retirement", "refusal", {:run, 18}, %{
      "code" => "write-lease-closed"
    })

    assert {:refused, r} = outcome,
           "ENFORCEMENT FAILURE: the held write landed after an acknowledged retirement"

    assert r["code"] == "write-lease-closed", inspect(r)
    assert after_ == before, "ENFORCEMENT FAILURE: the held write changed the store"
    assert Receipts.count() == 0
    assert listing[e["id"]]["receipts"] == "MISSING"
  end

  # ---------------------------------------------------------------- F6b
  test "F6b · a landing whose report is delayed past retirement is ordered by the resource, not by arrival",
       ctx do
    world!()
    {_auth, e, lease} = claim!()
    {:ok, _e, _a} = Effects.attempt(lease, "b2-harness")
    Effects.commit(lease, nil)
    {:ok, t} = Effects.authorize_write(lease, "emit_receipt", e["id"])
    {:ok, rc, witness} = Receipts.emit(t, receipt_fields(e))
    assert rc["landed_by"]["ticket_id"] == t["ticket_id"]
    # The report is NOT sent. Retirement must learn of the landing from the resource.
    u = Effects.unknown(e["id"], "operator abandoned the effect")
    assert u["state"] == "UNKNOWN"
    # The delayed report arrives after retirement. Gathered at the ack, it is
    # idempotent and logs nothing; NOT gathered (the broken control), it is
    # logged here — after the retirement — and the verifier reads E-LATE.
    tseq_before = Effects.incarnation()["tseq"]
    landed = Effects.landed(t, witness)
    tseq_after = Effects.incarnation()["tseq"]

    listing = close_with_state_and_listing()
    trace = export(ctx, "F6b-delayed-report-gathered-at-retirement", "enforcement", {:run, 18})
    types = events(trace)

    assert landed == :ok

    assert tseq_after == tseq_before,
           "the delayed report was logged AFTER retirement: arrival order masqueraded as mutation order"

    assert listing[e["id"]]["receipts"] == "COMPLETE"

    assert Enum.find_index(types, &(&1 == "landed")) <
             Enum.find_index(types, &(&1 == "lease_retired")),
           "the landing must precede the retirement in the log: #{inspect(types)}"
  end

  # ---------------------------------------------------------------- F3
  test "F3 · after the journal owner restarts, an old ticket and an old lease are both stale",
       ctx do
    world!()
    {_auth, e, lease} = claim!()
    {:ok, _e, _a} = Effects.attempt(lease, "b2-harness")
    Effects.commit(lease, nil)
    {:ok, held} = Effects.authorize_write(lease, "emit_receipt", e["id"])
    old = Effects.incarnation()

    kill!(Effects, fn -> Effects.all() end)
    new = Effects.incarnation()
    refute new["epoch"] == old["epoch"]

    assert Receipts.fence()["epoch"] == new["epoch"],
           "the new epoch must reach the participant before anything is served"

    assert GrantRegistry.fence()["epoch"] == new["epoch"]
    assert Effects.recover!() == [], "a COMMITTED effect is not in flight"

    before = Effects.stores()
    outcome = present(held, receipt_fields(e))
    after_ = Effects.stores()
    owner = Effects.authorize_write(lease, "emit_receipt", e["id"])
    listing = close_with_state_and_listing()

    export(ctx, "F3-old-ticket-and-lease-after-owner-restart", "refusal", {:run, 20}, %{
      "code" => "write-lease-stale"
    })

    assert {:refused, r} = outcome,
           "ENFORCEMENT FAILURE: an old-epoch ticket landed after the restart"

    assert r["code"] == "write-lease-stale", inspect(r)
    assert after_ == before, "ENFORCEMENT FAILURE: an old-epoch ticket changed the store"
    assert {:refused, r2} = owner
    assert r2["code"] == "write-lease-stale"
    assert listing[e["id"]]["receipts"] == "MISSING"
  end

  # ---------------------------------------------------------------- F3b
  test "F3b · a participant restart restores its persisted fence: a live ticket lands once, a retired lease stays retired",
       ctx do
    world!()
    {_auth, e, lease} = claim!()
    {:ok, _e, _a} = Effects.attempt(lease, "b2-harness")
    Effects.commit(lease, nil)
    {:ok, t} = Effects.authorize_write(lease, "emit_receipt", e["id"])
    epoch = Effects.incarnation()["epoch"]

    kill!(Receipts, fn -> Receipts.all() end)
    assert Receipts.fence()["epoch"] == epoch, "the fence must come back from disk, not be reset"

    {:ok, rc, w} = Receipts.emit(t, receipt_fields(e))
    assert rc["effect_ref"] == e["id"]
    assert :ok = Effects.landed(t, w)

    kill!(Receipts, fn -> Receipts.all() end)
    assert {:refused, r} = Receipts.emit(t, receipt_fields(e))
    assert r["code"] == "write-duplicate"
    assert Receipts.count() == 1

    listing = close_with_state_and_listing()
    assert listing[e["id"]]["receipts"] == "COMPLETE"
    # The ticket already has its terminal (landed); reporting the second presentation
    # is idempotent and logs nothing, so the trace is the 17-event completed path.
    tseq = Effects.incarnation()["tseq"]
    :ok = Effects.refused(t, r["code"], proof_of(r))
    assert Effects.incarnation()["tseq"] == tseq
    export(ctx, "F3b-participant-restart-restores-fence", "enforcement", {:run, 17})
  end

  # ---------------------------------------------------------------- F4a
  test "F4a · duplicate: a second consumption is refused by the owner (R7), then the receipt completes",
       ctx do
    [g] = world!()
    {_auth, e, lease} = claim!()
    before = Effects.stores()
    assert {:refused, r} = Effects.authorize_write(lease, "consume_grant", g["id"])
    assert r["code"] == "write-duplicate"
    assert Effects.stores() == before

    {:ok, _e, _a} = Effects.attempt(lease, "b2-harness")
    Effects.commit(lease, nil)
    {:ok, t1} = Effects.authorize_write(lease, "emit_receipt", e["id"])
    {:ok, _rc, w} = Receipts.emit(t1, receipt_fields(e))
    :ok = Effects.landed(t1, w)
    # After completion a further authorisation is retired, not duplicate (R8 / F-D2c).
    assert {:refused, r3} = Effects.authorize_write(lease, "emit_receipt", e["id"])
    assert r3["code"] == "write-lease-retired"

    listing = close_with_state_and_listing()
    assert listing[e["id"]]["receipts"] == "COMPLETE"
    export(ctx, "F4a-duplicate", "refusal", {:run, 23}, %{"code" => "write-duplicate"})
  end

  # Two tickets live at once for one op: the resource refuses the second by its
  # own witness. NOT exported: E-4 brackets each attempt with its own before/after
  # snapshots and reads a refusal's bracket as "unchanged", which two interleaved
  # attempts cannot satisfy (the first landing sits inside the second's bracket).
  # That is an evidence-shape limit of wek-r3-trace@3, recorded for WEK, not an
  # enforcement gap: the assertions below are the enforcement.
  test "F4a' · two live tickets for one op: the resource lands one and refuses the other as duplicate (untraced)" do
    world!()
    {_auth, e, lease} = claim!()
    {:ok, _e, _a} = Effects.attempt(lease, "b2-harness")
    Effects.commit(lease, nil)
    {:ok, t1} = Effects.authorize_write(lease, "emit_receipt", e["id"])
    {:ok, t2} = Effects.authorize_write(lease, "emit_receipt", e["id"])
    refute t1["ticket_id"] == t2["ticket_id"]
    {:ok, _rc, w} = Receipts.emit(t2, receipt_fields(e))
    :ok = Effects.landed(t2, w)
    before = Effects.stores()
    assert {:refused, r} = Receipts.emit(t1, receipt_fields(e))
    assert r["code"] == "write-duplicate"
    assert Effects.stores() == before and Receipts.count() == 1
    # and the same ticket presented twice is refused the same way
    assert {:refused, r2} = Receipts.emit(t2, receipt_fields(e))
    assert r2["code"] == "write-duplicate"
    assert Receipts.count() == 1
    Application.put_env(:ampd, :witness_snapshots, false)
  end

  # ---------------------------------------------------------------- F4b
  test "F4b · wrong target: a lease for one effect cannot write another effect's receipt", ctx do
    [_g1, _g2] = world!(2)
    {_a1, e1, lease1} = claim!(1)
    {_a2, e2, _lease2} = claim!(2)
    refute e1["id"] == e2["id"]
    {:ok, _e, _a} = Effects.attempt(lease1, "b2-harness")
    Effects.commit(lease1, nil)

    before = Effects.stores()
    assert {:refused, r} = Effects.authorize_write(lease1, "emit_receipt", e2["id"])
    assert r["code"] == "write-unscoped"
    assert Effects.stores() == before

    {:ok, t} = Effects.authorize_write(lease1, "emit_receipt", e1["id"])
    assert {:refused, r2} = Receipts.emit(t, Map.put(receipt_fields(e1), "effect_ref", e2["id"]))
    assert r2["code"] == "write-unscoped"
    assert Effects.stores() == before and Receipts.count() == 0
    :ok = Effects.refused(t, r2["code"], proof_of(r2))

    listing = close_with_state_and_listing()
    assert listing[e1["id"]]["receipts"] == "MISSING"

    assert listing[e2["id"]] == %{
             "crash_phase" => nil,
             "approvals" => "NOT_REQUIRED",
             "grant_registry" => "COMPLETE",
             "receipts" => "NOT_YET_OWED"
           }

    export(ctx, "F4b-wrong-target", "refusal", {:run, 27}, %{"code" => "write-unscoped"})
  end

  # ---------------------------------------------------------------- F4c
  test "F4c · unmediated: no ticket, a forged ticket, a reconstructed lease, a forged consumption — all refused, state unchanged",
       ctx do
    [g] = world!()
    {_auth, e, lease} = claim!()
    {:ok, _e, _a} = Effects.attempt(lease, "b2-harness")
    Effects.commit(lease, nil)
    before = Effects.stores()
    epoch = Effects.incarnation()["epoch"]

    # (i) the legacy arity, naming an effect
    assert {:refused, r1} = Receipts.emit(receipt_fields(e))
    assert r1["code"] == "write-unmediated"

    # (ii) a forged ticket in the current epoch
    forged = %{
      "ticket_id" => "tk-forged",
      "lease_id" => lease["lease_id"],
      "effect" => e["id"],
      "op" => "emit_receipt",
      "target" => e["id"],
      "epoch" => epoch,
      "mac" => String.duplicate("0", 64)
    }

    assert {:refused, r2} = Receipts.emit(forged, receipt_fields(e))
    assert r2["code"] == "write-unmediated"

    # (iii) a lease VALUE reconstructed from data (R4), at the owner
    assert {:refused, r3} =
             Effects.authorize_write(Map.delete(lease, "mac"), "emit_receipt", e["id"])

    assert r3["code"] == "write-unmediated"

    # (iv) a forged consumption ticket presented INSIDE the total order
    forged_c = %{forged | "op" => "consume_grant", "target" => g["id"]}

    assert {:refused, r4} =
             AuthorityCoordinator.transact(fn -> GrantRegistry.consume_one_shot(forged_c) end)

    assert r4["code"] == "write-unmediated"

    # (v) a forged landing report
    assert {:refused, r5} = Effects.landed(forged, %{"ticket_id" => "tk-forged", "proof" => "00"})
    assert r5["code"] == "write-unmediated"
    assert Effects.stores() == before, "ENFORCEMENT FAILURE: an unmediated write changed a store"
    assert Receipts.count() == 0

    # (vi) a forged landing REPORT for a real ticket: the proof does not verify
    {:ok, t_real} = Effects.authorize_write(lease, "emit_receipt", e["id"])

    assert {:refused, r6} =
             Effects.landed(t_real, %{
               "ticket_id" => t_real["ticket_id"],
               "proof" => String.duplicate("0", 64)
             })

    assert r6["code"] == "landing-unproven"
    assert Receipts.count() == 0
    # then the real ticket lands, legitimately, so the trace stays complete (E-2)
    {:landed, _} = present(t_real, receipt_fields(e))

    listing = close_with_state_and_listing()
    assert listing[e["id"]]["receipts"] == "COMPLETE"
    # Only (iii) is a trace event: (i), (ii), (iv), (v) and (vi) have no ticket the owner issued
    # or no valid proof, so they are asserted by store equality above, not by a `refused` line.
    # (vi)'s real ticket then lands: +5 events (before, authorized, landed, after, retired).
    export(ctx, "F4c-unmediated", "refusal", {:run, 20}, %{"code" => "write-unmediated"})
  end

  # ---------------------------------------------------------------- F9
  test "F9 · S-1 enforced: ATTEMPTED is refused while the consumption is outstanding", ctx do
    world!()

    {e, lease} =
      AuthorityCoordinator.transact(fn ->
        auth = Gateway.decide(@cap, @resource, Gateway.ctx(), req())
        assert auth["allow"]

        e =
          Effects.propose(%{
            "effect_key" => auth["effect_key"],
            "capability" => @cap,
            "pack" => "github@1.4.2",
            "actor" => "kestrel",
            "resource" => @resource,
            "request_id" => "er-github.pr.draft",
            "request_revision" => 1,
            "request" => params(),
            "branch" => "B2",
            "grant_ref" => auth["grant_ref"],
            "approval_ref" => nil
          })

        Effects.authorized(e["id"], %{"grant_ref" => auth["grant_ref"]})
        {:ok, _c, lease} = Effects.claim(e["id"])
        {e, lease}
      end)

    before = Effects.stores()
    attempted = Effects.attempt(lease, "b2-harness")
    state_after = Effects.get(e["id"])["state"]
    f = Effects.fail(e["id"], "abandoned before consumption")
    listing = close_with_state_and_listing()
    export(ctx, "F9-s1-enforced", "enforcement", {:run, 8})

    assert {:refused, r} = attempted,
           "ENFORCEMENT FAILURE: ATTEMPTED was journaled with the consumption outstanding (S-1)"

    assert r["code"] == "sequencing-violated"
    assert state_after == "CLAIMED"
    assert Effects.stores() == before
    assert f["state"] == "FAILED"
    # The listing covers CLAIMED / ATTEMPTED / COMMITTED / UNKNOWN effects (contract `listingOf`);
    # a FAILED effect owes nothing and is not listed. Its classification is still derivable:
    assert Ampd.Effects.Contract.classify(
             Effects.get(e["id"]),
             Effects.stores(),
             "grant_registry"
           ) == "MISSING"

    assert Ampd.Effects.Contract.classify(Effects.get(e["id"]), Effects.stores(), "receipts") ==
             "NOT_OWED"

    refute Map.has_key?(listing, e["id"])
  end

  # ---------------------------------------------------------------- F5a
  test "F5a · CLAIMED crash: killed between CLAIM and consumption, recovers UNKNOWN with crash_phase CLAIMED",
       ctx do
    world!()

    e =
      AuthorityCoordinator.transact(fn ->
        auth = Gateway.decide(@cap, @resource, Gateway.ctx(), req())

        e =
          Effects.propose(%{
            "effect_key" => auth["effect_key"],
            "capability" => @cap,
            "pack" => "github@1.4.2",
            "actor" => "kestrel",
            "resource" => @resource,
            "request_id" => "er-github.pr.draft",
            "request_revision" => 1,
            "request" => params(),
            "branch" => "B2",
            "grant_ref" => auth["grant_ref"],
            "approval_ref" => nil
          })

        Effects.authorized(e["id"], %{"grant_ref" => auth["grant_ref"]})
        {:ok, c, _lease} = Effects.claim(e["id"])
        c
      end)

    kill!(Effects, fn -> Effects.all() end)
    assert Effects.get(e["id"])["state"] == "CLAIMED"
    :ok = Effects.witness_state("post_crash_state")
    assert Effects.recover!() == [e["id"]]
    listing = Effects.witness_listing()

    assert listing[e["id"]] == %{
             "crash_phase" => "CLAIMED",
             "approvals" => "NOT_REQUIRED",
             "grant_registry" => "MISSING",
             "receipts" => "NOT_YET_OWED"
           }

    export(ctx, "F5a-claimed-crash", "recovery", {:crash, 4})
  end

  # ---------------------------------------------------------------- F5b
  test "F5b · ATTEMPTED crash: killed inside the adapter, the commit is stale, recovers UNKNOWN with crash_phase ATTEMPTED",
       ctx do
    world!()
    me = self()

    adapter = fn _attempt ->
      send(me, {:in_adapter, self()})

      receive do
        :go -> :did_the_thing
      end
    end

    task = Task.async(fn -> Gateway.perform(@cap, @resource, Gateway.ctx(), req(), adapter) end)
    assert_receive {:in_adapter, pid}, 5_000
    e = Enum.find(Effects.all(), &(&1["state"] == "ATTEMPTED"))
    assert e
    kill!(Effects, fn -> Effects.all() end)
    send(pid, :go)
    r = Task.await(task, 10_000)
    refute r["allow"]
    assert r["reason"] =~ "effect-commit-refused · write-lease-stale"
    assert Effects.get(e["id"])["state"] == "ATTEMPTED"
    assert Receipts.count() == 0

    :ok = Effects.witness_state("post_crash_state")
    assert Effects.recover!() == [e["id"]]
    listing = Effects.witness_listing()

    assert listing[e["id"]] == %{
             "crash_phase" => "ATTEMPTED",
             "approvals" => "NOT_REQUIRED",
             "grant_registry" => "COMPLETE",
             "receipts" => "INDETERMINATE"
           }

    export(ctx, "F5b-attempted-crash", "recovery", {:crash, 9})
  end

  # ---------------------------------------------------------------- F6
  test "F6 · a persisted mutation whose report never reached the owner: LOST, then COMPLETE from the row",
       ctx do
    world!()
    {_auth, e, lease} = claim!()
    {:ok, _e, _a} = Effects.attempt(lease, "b2-harness")
    Effects.commit(lease, nil)
    {:ok, t} = Effects.authorize_write(lease, "emit_receipt", e["id"])
    {:ok, rc, w} = Receipts.emit(t, receipt_fields(e))
    assert rc["landed_by"]["ticket_id"] == t["ticket_id"]
    # the crash: the report is never sent
    kill!(Effects, fn -> Effects.all() end)
    :ok = Effects.witness_state("post_crash_state")
    assert Effects.recover!() == []
    # a delayed report to the new incarnation cannot masquerade as a new-epoch landing
    tseq = Effects.incarnation()["tseq"]
    assert {:refused, r} = Effects.landed(t, w)
    assert r["code"] == "write-unmediated"
    assert Effects.incarnation()["tseq"] == tseq
    listing = Effects.witness_listing()
    assert listing[e["id"]]["receipts"] == "COMPLETE"
    export(ctx, "F6-persisted-mutation-report-lost", "recovery", {:crash, 12})
  end

  # ---------------------------------------------------------------- F7
  test "F7 · retirement interrupted between participant acknowledgments: never journaled, held write stale after restart",
       ctx do
    world!()
    {_auth, e, lease} = claim!()
    {:ok, _e, _a} = Effects.attempt(lease, "b2-harness")
    Effects.commit(lease, nil)
    {:ok, held} = Effects.authorize_write(lease, "emit_receipt", e["id"])
    old = Effects.incarnation()

    # The ack loop is grant_registry then receipts. Suspend receipts so the
    # owner blocks between the two acknowledgments, then kill it there.
    :ok = :sys.suspend(Receipts)
    me = self()

    try do
      spawn(fn ->
        send(me, {:retire, catch_exit(Effects.unknown(e["id"], "operator abandoned"))})
      end)

      wait_up(GrantRegistry, fn ->
        if Map.has_key?(GrantRegistry.fence()["retired"], held["lease_id"]),
          do: :ok,
          else: exit(:not_yet)
      end)

      Process.exit(Process.whereis(Effects), :kill)
      assert_receive {:retire, reason}, 5_000
      assert match?({:killed, _}, reason) or match?({:noproc, _}, reason), inspect(reason)
    after
      :sys.resume(Receipts)
    end

    wait_up(Effects, fn ->
      if Effects.incarnation()["epoch"] == old["epoch"], do: exit(:old), else: Effects.all()
    end)

    refute Map.has_key?(Receipts.fence()["retired"], held["lease_id"]),
           "receipts never acknowledged the retirement; the new epoch replaced the retired set"

    assert Effects.get(e["id"])["state"] == "COMMITTED",
           "an unacknowledged retirement must not be journaled"

    assert Effects.recover!() == []
    new = Effects.incarnation()["epoch"]
    assert Receipts.fence()["epoch"] == new and GrantRegistry.fence()["epoch"] == new

    before = Effects.stores()
    assert {:refused, r} = Receipts.emit(held, receipt_fields(e))
    assert r["code"] == "write-lease-stale"

    assert {:refused, r2} =
             AuthorityCoordinator.transact(fn ->
               GrantRegistry.consume_one_shot(%{
                 held
                 | "op" => "consume_grant",
                   "target" => e["grant_ref"]
               })
             end)

    assert r2["code"] == "write-lease-stale"
    assert Effects.stores() == before
    :ok = Effects.refused(held, r["code"], proof_of(r))

    listing = close_with_state_and_listing()
    assert listing[e["id"]]["receipts"] == "MISSING"

    export(ctx, "F7-retirement-interrupted-between-acks", "refusal", {:run, 17}, %{
      "code" => "write-lease-stale"
    })
  end

  # ---------------------------------------------------------------- F10
  # An impossible journal edge through the public API with a live, valid lease:
  # `CLAIMED → COMMITTED`, no ATTEMPTED record. A refused edge leaves no trace
  # footprint, so the case has C1's 17 events. The harness attempts only after the
  # premature commit was refused: a substrate that ADMITS the edge then commits
  # again on the live lease and lands the receipt — the same 17 events with an
  # illegal history, which the verifier judges under L-2 rather than failing on
  # length (control `no-transition-legality`).
  test "F10 · an impossible journal edge is refused before any write: CLAIMED → COMMITTED", ctx do
    world!()
    {_auth, e, lease} = claim!()
    before = Effects.stores()
    tseq = Effects.incarnation()["tseq"]
    journal_before = Effects.get(e["id"])
    premature = Effects.commit(lease, :premature)
    journal_after = Effects.get(e["id"])
    tseq_after = Effects.incarnation()["tseq"]

    if match?({:refused, _}, premature) do
      {:ok, _e, _a} = Effects.attempt(lease, "b2-harness")
    end

    committed = Effects.commit(lease, nil)
    {:ok, t} = Effects.authorize_write(lease, "emit_receipt", e["id"])
    outcome = present(t, receipt_fields(e))
    listing = close_with_state_and_listing()
    trace = export(ctx, "F10-impossible-edge-refused", "enforcement", {:run, 17})

    assert {:refused, r} = premature, "ENFORCEMENT FAILURE: CLAIMED → COMMITTED was journaled"
    assert r["code"] == "journal-transition-illegal"

    assert journal_after == journal_before and tseq_after == tseq,
           "a refused edge must write nothing"

    assert committed["state"] == "COMMITTED"

    assert Enum.map(Effects.get(e["id"])["history"], & &1["state"]) ==
             ~w(PROPOSED AUTHORIZED CLAIMED ATTEMPTED COMMITTED)

    assert match?({:landed, _}, outcome)
    assert listing[e["id"]]["receipts"] == "COMPLETE"
    assert Effects.stores() != before
    assert length(events(trace)) == 17
  end

  # The regression the review of 58c224e asked for, through the public API, both
  # forbidden edges, with a live valid lease. Recorded at 58c224e (wek/b2/logs/
  # probe-transitions-before-58c224e.txt):
  #   A · COMMITTED → ATTEMPTED returned {:ok, effect, attempt}; history
  #       [PROPOSED AUTHORIZED CLAIMED ATTEMPTED COMMITTED ATTEMPTED], 2 attempts
  #   B · CLAIMED → COMMITTED returned the effect map; history
  #       [PROPOSED AUTHORIZED CLAIMED COMMITTED]
  # Untraced: the exported F10 carries edge B; edge A is here and in the
  # table-driven lifecycle suite.
  test "R2 · regression: the two edges 58c224e admitted are refused, unchanged" do
    world!()
    {_auth, e, lease} = claim!()
    obs = fn -> {Effects.get(e["id"]), Effects.stores(), Effects.incarnation()["tseq"]} end
    before = obs.()

    assert {:refused, %{"code" => "journal-transition-illegal"}} =
             Effects.commit(lease, :never_attempted)

    assert obs.() == before
    {:ok, _, _} = Effects.attempt(lease, "b2-harness")
    %{"state" => "COMMITTED"} = Effects.commit(lease, nil)
    before = obs.()

    assert {:refused, %{"code" => "journal-transition-illegal"}} =
             Effects.attempt(lease, "b2-harness-again")

    assert obs.() == before
    assert length(Effects.get(e["id"])["attempts"]) == 1
    Application.put_env(:ampd, :witness_snapshots, false)
  end

  # ------------------------------------------------------- revocation
  test "post-CLAIM grant revocation is not lease retirement: the effect completes and the grant stays consumed",
       ctx do
    [g] = world!()

    r =
      Gateway.perform(@cap, @resource, Gateway.ctx(), req(), fn _ ->
        Authority.revoke_domain(@cap)
        :did_the_thing
      end)

    assert r["allow"] and r["receipt"]
    assert Enum.find(GrantRegistry.list(), &(&1["id"] == g["id"]))["status"] == "consumed"
    listing = close_with_state_and_listing()
    assert listing[r["effect_id"]]["grant_registry"] == "COMPLETE"
    export(ctx, "C2-post-claim-revocation-is-not-retirement", "enforcement", {:run, 17})
  end
end
