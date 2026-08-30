defmodule Ampd.WorkerTest do
  @moduledoc """
  **D.1.2's falsifiers.** The proposition, restated as something a machine
  can refuse:

      A Carrier does not occupy a position because its identity is
      associated with that position. It occupies a position because it
      explicitly took up an assignment to stand there, that assignment is
      still open, and nothing underneath it has moved since.

  ## The hypothesis, and the honest result

  D.1.2 was asked to test whether actor identity is *sufficient* for
  position, and told not to protect the hypothesis from the implementation.

  It is not sufficient, and `D2-01` and `D2-11` are why: with one actor
  holding three Lanes, the D.1.1 rule `peer.actor == lane.actor` made one
  Carrier present at all three simultaneously and gave it every capability
  established from any of them. That is authority exercised without being
  selected — ambient authority at the semantic layer, produced by the
  abstraction meant to remove it. The rule had to go.

  What is *not* claimed: that identity is irrelevant. It is retained as a
  necessary condition and `D2-12` is the test that it still bites.

  ## What makes these falsifiers rather than assertions

  Same three-part rule as D.1.1: the call was refused, refused **by the
  expected name**, and the world is **unchanged**. A negative test that
  checks only the first two passes when the call failed for an unrelated
  reason, and the third is the only one that can tell the difference.
  """

  use ExUnit.Case, async: false

  alias Ampd.{Authority, Control, Loci, Locus, Peer, Worker, Worktree, World}

  setup do
    Ampd.reset()
    Ampd.Bridge.reset()
    Peer.reset()
    Application.delete_env(:ampd, :profile_overrides)
    Application.delete_env(:ampd, :worktree_effector)
    Process.sleep(120)
    Authority.install_worktree()

    repo = init_repo!()
    {:ok, r} = Authority.register_repository(repo)

    {control, agent} = Ampd.attach_pair("kestrel")
    ws = ok!(Control.command(control, :open_workspace, ["acme"]), "workspace")
    goal = ok!(Control.command(control, :open_goal, [ws["id"], "occupy a position"]), "goal")

    # **The shape the whole slice is about.** One actor, three Lanes. Under
    # D.1.1 a single Carrier authenticating as `kestrel` was present at all
    # three at once.
    lane_a = lane!(control, goal, "kestrel", r["ref"])
    lane_b = lane!(control, goal, "kestrel", r["ref"])
    lane_m = lane!(control, goal, "mallory", r["ref"])

    %{
      repo: repo,
      repo_ref: r["ref"],
      control: control,
      agent: agent,
      goal: goal,
      lane_a: lane_a,
      lane_b: lane_b,
      lane_m: lane_m
    }
  end

  # ==================================================================== 01
  describe "D2-01 · identity is not occupancy" do
    test "a matching actor with no attachment occupies nothing", ctx do
      grant_worktree!(ctx.lane_a["id"])

      # The Carrier *is* the Lane's actor. Under D.1.1 this was the whole
      # of occupancy and every call below succeeded.
      assert Loci.lane(ctx.lane_a["id"])["actor"] == "kestrel"
      assert Peer.resolve(ctx.agent)["actor"] == "kestrel"

      before = world_footprint()

      e = Control.command(ctx.agent, :establish_worktree, [ctx.lane_a["id"], "wt-a"])
      assert e["allow"] == false
      assert refusal_code(e) == "carrier-not-attached"

      a = Control.command(ctx.agent, :attach_locus, [ctx.lane_a["id"]])
      assert a["allow"] == false
      assert refusal_code(a) == "carrier-not-attached"

      assert world_footprint() == before, "a refused occupancy moved the world"
    end

    test "opening the Worker is still not occupancy — attaching is", ctx do
      grant_worktree!(ctx.lane_a["id"])
      w = ok!(Control.command(ctx.control, :open_worker, [ctx.lane_a["id"], "implement"]), "worker")

      # The assignment exists and names this Carrier's actor. That is an
      # association, and an association is not a position.
      assert w["actor"] == "kestrel"
      assert w["status"] == "open"
      assert Worker.status_of(Loci.worker(w["id"])) == "OFFLINE"

      before = world_footprint()
      e = Control.command(ctx.agent, :establish_worktree, [ctx.lane_a["id"], "wt-a"])
      assert e["allow"] == false
      assert refusal_code(e) == "carrier-not-attached"
      assert world_footprint() == before

      # And now the act.
      ok!(Control.command(ctx.agent, :attach_worker, [w["id"]]), "worker")
      assert Worker.status_of(Loci.worker(w["id"])) == "OCCUPIED"
      assert Control.command(ctx.agent, :establish_worktree, [ctx.lane_a["id"], "wt-a"])["allow"]
    end
  end

  # ==================================================================== 02
  describe "D2-02 · occupying one position does not confer another" do
    test "attached to Lane A, the same Carrier reaches nothing on Lane B", ctx do
      # Both Lanes are this actor's, and both are fully granted. The only
      # thing that differs is where the Carrier is standing.
      grant_worktree!(ctx.lane_a["id"])
      grant_worktree!(ctx.lane_b["id"])
      wa = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])

      assert Control.command(ctx.agent, :establish_worktree, [ctx.lane_a["id"], "wt-a"])["allow"]

      before = world_footprint()
      e = Control.command(ctx.agent, :establish_worktree, [ctx.lane_b["id"], "wt-b"])

      assert e["allow"] == false, "a Carrier at Lane A exercised Lane B's authority"
      assert refusal_code(e) == "carrier-attached-elsewhere"

      # **The distinction has to be in the code, because that is all an
      # agent receives.** `Ampd.Refusal.project/2` strips `operator_detail`
      # on an agent channel, so a grading carried only there would be one
      # the agent cannot act on. The first version of this slice made
      # exactly that mistake and this assertion is what found it.
      refute Map.has_key?(e["refusal"], "operator_detail"),
             "an agent channel received operator detail"

      assert world_footprint() == before

      # The attachment is to a Worker, and it is the one that was taken up.
      assert Peer.attachment(ctx.agent)["worker_ref"] == wa["id"]
    end

    test "a capability established from Lane A is not reachable from Lane B", ctx do
      grant_worktree!(ctx.lane_a["id"])
      grant_worktree!(ctx.lane_b["id"])
      occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane_a["id"], "wt-a"])
      cap_id = r["capability"]["id"]

      assert Control.command(ctx.agent, :observe_worktree, [cap_id])["allow"] == true

      # Move to the other position. Same identity, same world, same grant,
      # same capability record on disk.
      assert Control.command(ctx.agent, :detach_worker, [])["allow"]
      occupy!(ctx.control, ctx.agent, ctx.lane_b["id"])

      o = Control.command(ctx.agent, :observe_worktree, [cap_id])
      assert o["allow"] == false

      # **And the refusal is graded.** This Carrier holds Lane A's actor,
      # so it is told where it actually is; a stranger is told only
      # `capability-not-held`. That distinction is disclosure, not
      # decoration — "detach and come back" is unactionable if it reads the
      # same as "this was never yours".
      assert refusal_code(o) == "carrier-attached-elsewhere"

      {:ok, stranger} = Peer.attach_agent("mallory")
      assert refusal_code(Control.command(stranger, :observe_worktree, [cap_id])) ==
               "capability-not-held"
    end
  end

  # ==================================================================== 03
  describe "D2-03 · the Carrier dies; the Worker and the Lane do not" do
    test "Carrier death destroys the attachment and nothing else", ctx do
      grant_worktree!(ctx.lane_a["id"])
      w = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane_a["id"], "wt-a"])
      cap_id = r["capability"]["id"]
      path = Worktree.resource(r["capability"]["resource_ref"])["path"]

      assert Worker.status_of(Loci.worker(w["id"])) == "OCCUPIED"

      Peer.reset()
      Process.sleep(50)

      assert Peer.resolve(ctx.agent) == nil, "the Carrier did not actually die"
      assert Peer.attachment(ctx.agent) == nil, "the attachment outlived its Carrier"
      assert Peer.attachments() == [], "an attachment survived the epoch it was made in"

      # Everything World-persistent is exactly as it was.
      assert Loci.worker(w["id"])["status"] == "open"
      assert Loci.worker(w["id"])["locus_ref"] == ctx.lane_a["id"]
      assert Loci.lane(ctx.lane_a["id"])["actor"] == "kestrel"
      assert Loci.cap(cap_id)["status"] == "active"
      assert File.dir?(path)

      # And the position now reads as what it is: assigned, unoccupied.
      assert Worker.status_of(Loci.worker(w["id"])) == "OFFLINE"
    end

    test "the Worker survives a full registry reload", ctx do
      w = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])
      Ampd.Bootstrap.reload_registries!()

      reloaded = Loci.worker(w["id"])
      assert reloaded["status"] == "open"
      assert reloaded["actor"] == "kestrel"
      assert reloaded["locus_ref"] == ctx.lane_a["id"]
      assert reloaded["purpose"] == "work"
    end
  end

  # ==================================================================== 04
  describe "D2-04 · a replacement Carrier inherits nothing" do
    test "a fresh Carrier with the right identity starts nowhere", ctx do
      grant_worktree!(ctx.lane_a["id"])
      w = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane_a["id"], "wt-a"])
      cap_id = r["capability"]["id"]

      Peer.reset()
      Process.sleep(50)
      {:ok, kestrel} = Peer.attach_agent("kestrel")

      before = world_footprint()

      # Right identity, right world, open Worker sitting there — and it is
      # not standing anywhere.
      assert Peer.attachment(kestrel) == nil

      o = Control.command(kestrel, :observe_worktree, [cap_id])
      assert o["allow"] == false
      assert refusal_code(o) == "carrier-not-attached"

      e = Control.command(kestrel, :establish_worktree, [ctx.lane_a["id"], "wt-b"])
      assert e["allow"] == false
      assert refusal_code(e) == "carrier-not-attached"

      assert world_footprint() == before

      # Taking the position up again is one explicit act, and then it works.
      ok!(Control.command(kestrel, :attach_worker, [w["id"]]), "worker")
      assert Control.command(kestrel, :observe_worktree, [cap_id])["allow"] == true
    end
  end

  # ==================================================================== 05
  describe "D2-05 · reattachment reconstructs, and reconstructs only what is current" do
    test "authority is derived from now, not from what the last Carrier had", ctx do
      g = grant_worktree!(ctx.lane_a["id"])
      w = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane_a["id"], "wt-a"])
      cap_id = r["capability"]["id"]

      a = Control.command(ctx.agent, :attach_locus, [ctx.lane_a["id"]])
      assert a["count"] == 1

      # The Carrier dies, and the grant is revoked in the interval when
      # nobody is standing there — the window a design that handed the old
      # set to the replacement would miss entirely.
      Peer.reset()
      Process.sleep(50)
      Authority.revoke_one(g["id"])

      {:ok, kestrel} = Peer.attach_agent("kestrel")
      ok!(Control.command(kestrel, :attach_worker, [w["id"]]), "worker")

      a2 = Control.command(kestrel, :attach_locus, [ctx.lane_a["id"]])
      assert a2["allow"] == true, "the position is still occupiable"
      assert a2["count"] == 0, "a replacement Carrier inherited authority it could not re-establish"
      refute Map.has_key?(a2["capabilities"], cap_id)

      # Persistence is not authority: the record is untouched.
      assert Loci.cap(cap_id)["status"] == "active"
    end
  end

  # ==================================================================== 06
  describe "D2-06 · a revocation while the position is offline is still a revocation" do
    test "the discontinuity is not skipped by having nobody present for it", ctx do
      g = grant_worktree!(ctx.lane_a["id"])
      w = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane_a["id"], "wt-a"])
      cap_id = r["capability"]["id"]

      # Vacate without dying — an ordinary detach, not a crash.
      Control.command(ctx.agent, :detach_worker, [])
      assert Worker.status_of(Loci.worker(w["id"])) == "OFFLINE"

      Authority.revoke_one(g["id"])

      # Same Carrier, same handle, back at the same position.
      ok!(Control.command(ctx.agent, :attach_worker, [w["id"]]), "worker")

      o = Control.command(ctx.agent, :observe_worktree, [cap_id])
      assert o["allow"] == false
      assert refusal_code(o) == "capability-authority-revoked"

      assert Control.command(ctx.agent, :attach_locus, [ctx.lane_a["id"]])["count"] == 0
    end
  end

  # ==================================================================== 07
  describe "D2-07 · occupancy does not cross a world discontinuity" do
    test "an attachment made before the advance cannot establish occupancy", ctx do
      grant_worktree!(ctx.lane_a["id"])
      w = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])
      attached_in = Peer.attachment(ctx.agent)["world_ref"]

      Authority.advance_lineage("D.1.2 falsifier D2-07")
      refute attached_in == World.lineage()

      # The advance closes every channel, so this is belt and braces — the
      # attachment is unreachable *and* would refuse if it were reachable.
      assert Peer.attachment(ctx.agent) == nil

      {:ok, kestrel} = Peer.attach_agent("kestrel")
      before = world_footprint()

      e = Control.command(kestrel, :establish_worktree, [ctx.lane_a["id"], "wt-a"])
      assert e["allow"] == false
      assert refusal_code(e) == "carrier-not-attached"
      assert world_footprint() == before

      # The Worker survived, exactly as the Lane did. Both are records.
      assert Loci.worker(w["id"])["status"] == "open"
      ok!(Control.command(kestrel, :attach_worker, [w["id"]]), "worker")
      assert Peer.attachment(kestrel)["world_ref"] == World.lineage()
    end

    test "a synthesised pre-advance attachment refuses by name", ctx do
      # `Peer.reset/0` makes the natural path unreachable, which is a good
      # property and a poor test: it proves the channel closed, not that
      # `occupancy/2` re-derives the lineage. So the stale attachment is
      # reconstructed directly against the live table.
      w = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])

      stale = %{
        Peer.attachment(ctx.agent)
        | "world_ref" => %{"installation_id" => "w-0000000000000000", "generation" => 1}
      }

      assert {:refused, ref} =
               Worker.occupancy_of(
                 stale,
                 Peer.resolve(ctx.agent),
                 Loci.lane(ctx.lane_a["id"])
               )

      assert ref["code"] == "attachment-generation-stale"
      assert Loci.worker(w["id"])["status"] == "open"

      # The live attachment is untouched and still good — what was tested
      # is the clause, not a broken world.
      assert Worker.occupies?(Peer.resolve(ctx.agent), Loci.lane(ctx.lane_a["id"]))
    end
  end

  # ==================================================================== 08
  describe "D2-08 · a closed assignment is not a position" do
    test "the correct actor cannot occupy through a closed Worker", ctx do
      grant_worktree!(ctx.lane_a["id"])
      w = ok!(Control.command(ctx.control, :open_worker, [ctx.lane_a["id"], "implement"]), "worker")
      ok!(Control.command(ctx.control, :close_worker, [w["id"]]), "worker")

      before = world_footprint()

      a = Control.command(ctx.agent, :attach_worker, [w["id"]])
      assert a["allow"] == false
      assert refusal_code(a) == "worker-not-open"
      assert world_footprint() == before

      # And the Lane is untouched — closing an assignment ends an
      # assignment, it does not retract a position.
      assert Loci.lane(ctx.lane_a["id"])["status"] == "open"
    end

    test "closing underneath a live Carrier evicts it", ctx do
      grant_worktree!(ctx.lane_a["id"])
      w = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])
      assert Control.command(ctx.agent, :establish_worktree, [ctx.lane_a["id"], "wt-a"])["allow"]

      ok!(Control.command(ctx.control, :close_worker, [w["id"]]), "worker")

      # The attachment record is still in the table. It is not occupancy,
      # because occupancy is re-derived and the Worker is shut.
      assert Peer.attachment(ctx.agent) != nil
      assert Worker.status_of(Loci.worker(w["id"])) == "OFFLINE"

      e = Control.command(ctx.agent, :establish_worktree, [ctx.lane_a["id"], "wt-b"])
      assert e["allow"] == false
      assert refusal_code(e) == "worker-not-open"
    end

    test "re-opening does not revive the attachment that spanned the close", ctx do
      # **The authority-resurrection defect, at the occupancy layer.**
      # `Ampd.Locus.grant_of/1` carries a measured scar from this exact
      # shape: a revoked capability came back when an equivalent grant was
      # minted. A design comparing only `status` has the same hole here.
      grant_worktree!(ctx.lane_a["id"])
      w = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])
      assert Peer.attachment(ctx.agent)["worker_generation"] == 1

      ok!(Control.command(ctx.control, :close_worker, [w["id"]]), "worker")
      ok!(Control.command(ctx.control, :reopen_worker, [w["id"]]), "worker")

      reopened = Loci.worker(w["id"])
      assert reopened["status"] == "open"
      assert reopened["generation"] == 3, "close and reopen must each advance the generation"

      before = world_footprint()
      e = Control.command(ctx.agent, :establish_worktree, [ctx.lane_a["id"], "wt-a"])

      assert e["allow"] == false, "an attachment survived the interval in which it was invalid"
      assert refusal_code(e) == "attachment-worker-generation-stale"
      assert world_footprint() == before

      # A new attachment is the remedy, and it is available immediately.
      assert Control.command(ctx.agent, :detach_worker, [])["allow"]
      ok!(Control.command(ctx.agent, :attach_worker, [w["id"]]), "worker")
      assert Peer.attachment(ctx.agent)["worker_generation"] == 3
      assert Control.command(ctx.agent, :establish_worktree, [ctx.lane_a["id"], "wt-a"])["allow"]
    end
  end

  # ==================================================================== 09
  describe "D2-09 · a prior epoch's occupancy does not resolve" do
    test "the attachment lookup is epoch-fenced, not merely emptied", ctx do
      w = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])
      old_handle = ctx.agent
      old_epoch = Peer.epoch()

      Peer.reset()
      Process.sleep(50)
      refute Peer.epoch() == old_epoch

      # The handle is from the previous incarnation. Neither the binding
      # nor the attachment resolves through it.
      assert Peer.resolve(old_handle) == nil
      assert Peer.attachment(old_handle) == nil

      # A fresh Carrier cannot inherit the position by holding an old id.
      {:ok, kestrel} = Peer.attach_agent("kestrel")
      assert Peer.attachment(kestrel) == nil
      assert Worker.status_of(Loci.worker(w["id"])) == "OFFLINE"
    end

    test "a live attachment carrying a stale epoch refuses by name", ctx do
      occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])
      stale = %{Peer.attachment(ctx.agent) | "peer_epoch" => "deadbeef"}

      assert {:refused, ref} =
               Worker.occupancy_of(stale, Peer.resolve(ctx.agent), Loci.lane(ctx.lane_a["id"]))

      assert ref["code"] == "attachment-epoch-stale"
    end
  end

  # ==================================================================== 10
  describe "D2-10 · one Carrier is at one place, and one place holds one Carrier" do
    test "a second attachment by the same Carrier is refused, not silently moved", ctx do
      wa = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])
      wb = ok!(Control.command(ctx.control, :open_worker, [ctx.lane_b["id"], "review"]), "worker")

      r = Control.command(ctx.agent, :attach_worker, [wb["id"]])
      assert r["allow"] == false
      assert refusal_code(r) == "carrier-already-attached"

      # **Refused, not replaced.** A silent move would mean an attach call
      # could take a Carrier off a position it believed it held.
      assert Peer.attachment(ctx.agent)["worker_ref"] == wa["id"]
      assert Worker.status_of(Loci.worker(wb["id"])) == "OFFLINE"

      # Explicit vacate, then it is available.
      Control.command(ctx.agent, :detach_worker, [])
      ok!(Control.command(ctx.agent, :attach_worker, [wb["id"]]), "worker")
      assert Peer.attachment(ctx.agent)["worker_ref"] == wb["id"]
    end

    test "D2-10c · two Workers on one Lane do not admit two Carriers", ctx do
      # **The bug review found, and the reason it was invisible.** D.1.2
      # enforced exclusivity by `worker_ref`, and D.1.2 also allows more
      # than one Worker on a Lane. Two Workers with the same `locus_ref`
      # therefore raised no conflict, and both Carriers satisfied
      # `occupancy/2` for the same Lane at the same time.
      #
      # "One Carrier per Worker" and "one Carrier per Locus" are separate
      # invariants. Only the second is the one the ontology claims, because
      # the position is the Lane and the Worker is an assignment at it.
      grant_worktree!(ctx.lane_a["id"])
      w1 = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"], "implement")
      w2 = ok!(Control.command(ctx.control, :open_worker, [ctx.lane_a["id"], "review"]), "worker")

      assert Loci.worker(w1["id"])["locus_ref"] == Loci.worker(w2["id"])["locus_ref"]

      {:ok, second} = Peer.attach_agent("kestrel")
      before = world_footprint()

      r = Control.command(second, :attach_worker, [w2["id"]])

      assert r["allow"] == false, "two Carriers occupied one Lane through two Workers"
      assert refusal_code(r) == "locus-already-occupied"
      assert Peer.attachment(second) == nil
      assert world_footprint() == before

      # And the first Carrier is undisturbed — a refused attach must not
      # move the Carrier that legitimately holds the position.
      assert Peer.attachment(ctx.agent)["worker_ref"] == w1["id"]
      refute Worker.occupies?(Peer.resolve(second), Loci.lane(ctx.lane_a["id"]))
      assert Worker.occupies?(Peer.resolve(ctx.agent), Loci.lane(ctx.lane_a["id"]))

      # The cockpit must never show one Lane with two occupants.
      p = Control.command(ctx.control, :operator_projection, [])
      occupied = Enum.count(p["workers"], fn {_, w} ->
        w["locus_ref"] == ctx.lane_a["id"] and w["occupancy"] == "OCCUPIED"
      end)

      assert occupied == 1, "the cockpit rendered two OCCUPIED Workers under one Lane"
    end

    test "a second Carrier cannot occupy an occupied Worker", ctx do
      w = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])
      {:ok, second} = Peer.attach_agent("kestrel")

      # Same actor, same world, open Worker — and it is taken.
      r = Control.command(second, :attach_worker, [w["id"]])
      assert r["allow"] == false
      assert refusal_code(r) == "worker-already-occupied"
      assert Peer.attachment(second) == nil
      assert Peer.attachment(ctx.agent)["worker_ref"] == w["id"]
    end
  end

  # ==================================================================== 15
  describe "D2-15 · a Carrier that lost its position cannot hold it hostage" do
    test "a replacement takes over a reopened assignment without cooperation", ctx do
      # **The second bug review found, and it is the same bug as D2-10c.**
      # A closed Worker's attachment is semantically inert — occupancy is
      # re-derived, so it confers nothing. But the *raw row* was still what
      # exclusivity was computed from, so a Carrier that had lost all
      # authority kept **denial power** over the position simply by staying
      # connected and declining to detach.
      #
      # That contradicts the one sentence `close_worker` exists to make
      # true: a person can end an occupancy without asking the Carrier to
      # cooperate. It ended the authority and not the reservation.
      grant_worktree!(ctx.lane_a["id"])
      w = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])

      ok!(Control.command(ctx.control, :close_worker, [w["id"]]), "worker")
      ok!(Control.command(ctx.control, :reopen_worker, [w["id"]]), "worker")

      # C1 is still connected and does **not** detach. It has already lost
      # occupancy — that is D2-08 — and the question here is only whether
      # it can stop anyone else from taking the position.
      assert Peer.resolve(ctx.agent) != nil, "C1 must still be live for this to test anything"
      refute Worker.occupies?(Peer.resolve(ctx.agent), Loci.lane(ctx.lane_a["id"]))

      {:ok, replacement} = Peer.attach_agent("kestrel")
      r = Control.command(replacement, :attach_worker, [w["id"]])

      assert r["allow"] == true,
             "a Carrier with no authority kept a reopened assignment hostage: #{inspect(r["refusal"])}"

      assert Worker.occupies?(Peer.resolve(replacement), Loci.lane(ctx.lane_a["id"]))
      assert Control.command(replacement, :establish_worktree, [ctx.lane_a["id"], "wt-a"])["allow"]

      # And C1 stays refused. Reaping its row must not have handed it
      # anything — losing the position and being unable to block it are the
      # same event, not a trade.
      refute Worker.occupies?(Peer.resolve(ctx.agent), Loci.lane(ctx.lane_a["id"]))

      e = Control.command(ctx.agent, :establish_worktree, [ctx.lane_a["id"], "wt-b"])
      assert e["allow"] == false
      assert refusal_code(e) in ~w(carrier-not-attached attachment-worker-generation-stale)
    end

    test "correctness does not depend on close_worker having cleaned up", ctx do
      # **The crash case.** The durable Worker transition can succeed and
      # the process can die before any ephemeral cleanup runs, so eager
      # deletion on `close_worker` is an optimisation and must never be the
      # only correctness mechanism.
      #
      # Modelled by never giving cleanup a chance: the Worker is closed and
      # reopened, and the registries are reloaded from disk — which is what
      # a restart would do to the durable half — while `Ampd.Peer`'s
      # ephemeral table is untouched, exactly as a crash-free process would
      # leave it.
      w = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])
      ok!(Control.command(ctx.control, :close_worker, [w["id"]]), "worker")
      ok!(Control.command(ctx.control, :reopen_worker, [w["id"]]), "worker")
      Ampd.Bootstrap.reload_registries!()

      assert Peer.attachment(ctx.agent) != nil,
             "this case is only meaningful while the stale row is still there"

      {:ok, replacement} = Peer.attach_agent("kestrel")
      assert Control.command(replacement, :attach_worker, [w["id"]])["allow"] == true
    end

    test "two Carriers racing for one Locus have exactly one winner", ctx do
      # Both attach attempts are in flight before either completes, so the
      # decision cannot be made by whoever read the table first. The Peer
      # owner is the serialization point and the only place the invariant
      # can actually hold.
      w1 = ok!(Control.command(ctx.control, :open_worker, [ctx.lane_a["id"], "a"]), "worker")
      w2 = ok!(Control.command(ctx.control, :open_worker, [ctx.lane_a["id"], "b"]), "worker")

      {:ok, c1} = Peer.attach_agent("kestrel")
      {:ok, c2} = Peer.attach_agent("kestrel")

      results =
        [{c1, w1}, {c2, w2}]
        |> Enum.map(fn {c, w} ->
          Task.async(fn -> Control.command(c, :attach_worker, [w["id"]]) end)
        end)
        |> Task.await_many(10_000)

      won = Enum.count(results, & &1["allow"])

      assert won == 1, "#{won} Carriers won the same Locus — the race has no single winner"

      losers = Enum.reject(results, & &1["allow"])
      assert Enum.all?(losers, &(refusal_code(&1) == "locus-already-occupied"))

      live =
        Enum.count([c1, c2], fn c ->
          Worker.occupies?(Peer.resolve(c) || %{}, Loci.lane(ctx.lane_a["id"]))
        end)

      assert live == 1
    end
  end

  # ==================================================================== 16
  describe "D2-16 · staleness is monotonic" do
    test "nothing in the grammar can make a failed attachment satisfy occupancy again", ctx do
      # **The safety argument for reaping, stated as a test.**
      # `Ampd.Peer.attach_worker/3` acts on a stale-row list its caller
      # computed a moment earlier. That is only sound if a row that failed
      # occupancy cannot pass it later — otherwise reaping could revoke a
      # live occupancy, and the fix for the hostage bug would have created
      # a worse one.
      #
      # The three bases an attachment binds are each monotonic, and this
      # walks every operation the grammar offers that could plausibly undo
      # one.
      w = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])
      att = Peer.attachment(ctx.agent)
      lane = Loci.lane(ctx.lane_a["id"])

      assert Worker.occupancy_of(att, Peer.resolve(ctx.agent), lane) == :ok

      # Worker generation. Close makes it stale; re-opening is the operation
      # that most looks like it should restore it, and does not.
      ok!(Control.command(ctx.control, :close_worker, [w["id"]]), "worker")
      refute Worker.occupancy_of(att, Peer.resolve(ctx.agent), lane) == :ok

      ok!(Control.command(ctx.control, :reopen_worker, [w["id"]]), "worker")

      assert Loci.worker(w["id"])["status"] == "open",
             "the Worker really is open again — this is the case that must still refuse"

      refute Worker.occupancy_of(att, Peer.resolve(ctx.agent), lane) == :ok

      # And it stays stale across further cycles: the counter only climbs.
      gens =
        for _ <- 1..3 do
          ok!(Control.command(ctx.control, :close_worker, [w["id"]]), "worker")
          ok!(Control.command(ctx.control, :reopen_worker, [w["id"]]), "worker")
          refute Worker.occupancy_of(att, Peer.resolve(ctx.agent), lane) == :ok
          Loci.worker(w["id"])["generation"]
        end

      assert gens == Enum.sort(gens) and gens == Enum.uniq(gens),
             "Worker generation did not advance monotonically: #{inspect(gens)}"

      # World lineage. Also only advances, and there is no command that
      # lowers it — `Ampd.World.bump_generation!/2` is the sole writer and
      # it adds one.
      before_gen = World.lineage()["generation"]
      Authority.advance_lineage("D2-16")
      assert World.lineage()["generation"] == before_gen + 1
      refute Worker.occupancy_of(att, Peer.resolve(ctx.agent) || %{}, lane) == :ok
    end

    test "a reaped row cannot have been live, so a replacement cannot displace an occupant", ctx do
      # The consequence that matters: `stale_on/1` never names a Carrier
      # that currently holds the position.
      #
      # **Scope, stated because the title is broader than the proof.** This
      # is a property of the *sanctioned* path — `attach_worker` the command,
      # which routes through `Ampd.Worker.attach/2` and therefore through
      # `stale_on/1`. It is not a property of `Ampd.Peer.attach_worker/3`,
      # which accepts the witness without checking it; a direct in-BEAM
      # caller passing a live peer id in `reap` does displace the occupant.
      # That is a declared trusted-BEAM precondition, recorded at
      # `Ampd.Peer.attach_worker/3`, and no command in the grammar reaches
      # it with a caller-supplied list.
      w1 = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"], "implement")
      lane = Loci.lane(ctx.lane_a["id"])

      assert Worker.stale_on(lane) == [],
             "a live occupant was listed as reapable"

      w2 = ok!(Control.command(ctx.control, :open_worker, [ctx.lane_a["id"], "review"]), "worker")
      {:ok, second} = Peer.attach_agent("kestrel")

      r = Control.command(second, :attach_worker, [w2["id"]])
      assert r["allow"] == false
      assert refusal_code(r) == "locus-already-occupied"

      # The live occupant is exactly where it was.
      assert Peer.attachment(ctx.agent)["worker_ref"] == w1["id"]
      assert Worker.occupies?(Peer.resolve(ctx.agent), lane)

      # Now make it genuinely stale, and the same call succeeds.
      ok!(Control.command(ctx.control, :close_worker, [w1["id"]]), "worker")
      assert Worker.stale_on(lane) == [ctx.agent]

      assert Control.command(second, :attach_worker, [w2["id"]])["allow"] == true
      assert Peer.attachment(ctx.agent) == nil, "the stale row was not reaped on admission"
    end
  end

  # ==================================================================== 11
  describe "D2-11 · a Worker is an assignment, not an authority bag" do
    test "the durable record carries no authority, at any depth", ctx do
      w = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])
      grant_worktree!(ctx.lane_a["id"])
      Control.command(ctx.agent, :establish_worktree, [ctx.lane_a["id"], "wt-a"])

      # Read it back off disk, not from the reply — the reply is what the
      # runtime chose to say, and this is a claim about what is stored.
      Ampd.Bootstrap.reload_registries!()
      rec = Loci.worker(w["id"])

      assert Enum.sort(Map.keys(rec)) == Loci.worker_keys(),
             "the worker@1 key set drifted from the declared vocabulary"

      for {route, key} <- keys_with_paths(rec), key in Loci.worker_forbidden_keys() do
        flunk("worker@1 carries a forbidden key at #{route}")
      end

      # Named individually as well as by list, because a denylist that is
      # itself wrong fails silently.
      refute Map.has_key?(rec, "rights")
      refute Map.has_key?(rec, "authority_basis")
      refute Map.has_key?(rec, "resource_ref")
      refute Map.has_key?(rec, "pid")
      refute Map.has_key?(rec, "pty")
      refute Map.has_key?(rec, "command")

      # Ancestry is referentially closed, and it is closed *upward*.
      assert Loci.lane(rec["locus_ref"]) != nil
      assert Loci.goal(rec["goal_ref"]) != nil
      assert Loci.workspace(rec["workspace_ref"]) != nil
      assert Loci.lane(rec["locus_ref"])["goal_ref"] == rec["goal_ref"]
      assert Loci.goal(rec["goal_ref"])["workspace_ref"] == rec["workspace_ref"]
    end

    test "creating a Worker confers nothing", ctx do
      # No grant anywhere. A Worker is opened and taken up in full, and the
      # capability check still refuses for want of authority.
      occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])
      before = world_footprint()

      e = Control.command(ctx.agent, :establish_worktree, [ctx.lane_a["id"], "wt-a"])
      assert e["allow"] == false
      assert refusal_code(e) == "worktree-authority-missing"
      assert world_footprint() == before
    end

    test "a Worker cannot be opened for an actor the Lane is not held by", ctx do
      # There is no argument in which to say it — the actor is copied from
      # the Lane. This is the property, stated as the absence of a field.
      spec = Ampd.CommandSpec.get("open_worker")
      refute "actor" in Enum.map(spec.fields, & &1.name)

      w = ok!(Control.command(ctx.control, :open_worker, [ctx.lane_m["id"], "review"]), "worker")
      assert w["actor"] == "mallory"

      # And a `kestrel` Carrier cannot take it up.
      r = Control.command(ctx.agent, :attach_worker, [w["id"]])
      assert r["allow"] == false
      assert refusal_code(r) == "worker-not-assignable"
    end
  end

  # ==================================================================== 12
  describe "D2-12 · identity is still necessary" do
    test "the wrong actor is refused by name and moves nothing", ctx do
      grant_worktree!(ctx.lane_m["id"], "mallory")
      w = ok!(Control.command(ctx.control, :open_worker, [ctx.lane_m["id"], "review"]), "worker")

      before = world_footprint()

      # `kestrel` holds a valid Worker id and a valid Lane id, and both
      # objects really exist. Knowing an id is not being assigned to it.
      a = Control.command(ctx.agent, :attach_worker, [w["id"]])
      assert a["allow"] == false
      assert refusal_code(a) == "worker-not-assignable"

      e = Control.command(ctx.agent, :establish_worktree, [ctx.lane_m["id"], "wt-m"])
      assert e["allow"] == false
      assert refusal_code(e) == "locus-not-occupied"

      assert world_footprint() == before
      assert Peer.attachment(ctx.agent) == nil
      assert Worker.status_of(Loci.worker(w["id"])) == "OFFLINE"
    end

    test "a non-existent Worker and another actor's Worker give the same answer", ctx do
      w = ok!(Control.command(ctx.control, :open_worker, [ctx.lane_m["id"], "review"]), "worker")

      real = Control.command(ctx.agent, :attach_worker, [w["id"]])
      fake = Control.command(ctx.agent, :attach_worker, ["wk_9999"])

      # Otherwise a caller free to guess ids enumerates another actor's
      # assignments one probe at a time — the same disclosure rule
      # `capability-not-held` already enforces one layer up.
      assert refusal_code(real) == refusal_code(fake)
      assert refusal_code(real) == "worker-not-assignable"
    end

    test "the human control channel holds no actor and occupies nothing", ctx do
      w = ok!(Control.command(ctx.control, :open_worker, [ctx.lane_a["id"], "implement"]), "worker")

      # A person opens the assignment and cannot take it up. They are the
      # source of consent, not an occupant.
      assert {:refused, ref} = Worker.attach(Peer.resolve(ctx.control), w["id"])
      assert ref["code"] == "carrier-has-no-actor"

      refute Worker.occupies?(Peer.resolve(ctx.control), Loci.lane(ctx.lane_a["id"]))
    end
  end

  # ==================================================================== 13
  describe "D2-13 · the grammar cannot express a process" do
    test "no worker command declares a field that could name one", ctx do
      _ = ctx

      words = ~w(open_worker close_worker reopen_worker attach_worker detach_worker list_workers)
      forbidden = ~w(pid pty tty command cmd argv exec executable shell path cwd env fd socket)

      for word <- words do
        spec = Ampd.CommandSpec.get(word)
        assert spec != nil, "#{word} is not declared"

        for f <- spec.fields do
          refute f.name in forbidden,
                 "#{word} declares `#{f.name}` — D.1.2 introduces no ambient host execution"

          # Every reference is an opaque runtime-minted id or a bounded
          # string. Nothing is a map a caller could smuggle structure in.
          assert match?({:id, _}, f.type) or match?({:string, _}, f.type),
                 "#{word}.#{f.name} is #{inspect(f.type)}"
        end
      end
    end

    test "attaching to a Worker cannot invoke the host effector", ctx do
      # `super-host effect` is a mechanism boundary, not an authorization
      # boundary — the D.1.1 finding this slice is forbidden to undo. The
      # test is that occupancy alone reaches it not at all.
      w = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])
      assert Loci.worker(w["id"])["status"] == "open"

      before = world_footprint()
      assert before.admitted == 0, "occupancy alone admitted a machine resource"
      assert before.receipts == 0

      # The only command that can cause an effect still refuses, because
      # occupancy is not authority.
      e = Control.command(ctx.agent, :establish_worktree, [ctx.lane_a["id"], "wt-a"])
      assert e["allow"] == false
      assert refusal_code(e) == "worktree-authority-missing"
      assert world_footprint() == before
    end
  end

  # ==================================================================== 14
  describe "D2-14 · occupancy is visible to a person, and honestly" do
    test "the operator projection reports live occupancy, not attachment rows", ctx do
      w = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])

      p = Control.command(ctx.control, :operator_projection, [])
      assert p["workers"][w["id"]]["occupancy"] == "OCCUPIED"

      # Close the Worker under the live attachment. The row is still in
      # `Ampd.Peer`'s table; the projection must not say OCCUPIED, because
      # the runtime would refuse anything issued from there.
      ok!(Control.command(ctx.control, :close_worker, [w["id"]]), "worker")
      assert Peer.attachment(ctx.agent) != nil

      p2 = Control.command(ctx.control, :operator_projection, [])

      assert p2["workers"][w["id"]]["occupancy"] == "OFFLINE",
             "the cockpit showed a position as filled when nothing could act from it"
    end

    test "an agent sees its own assignments and no others", ctx do
      mine = occupy!(ctx.control, ctx.agent, ctx.lane_a["id"])
      theirs = ok!(Control.command(ctx.control, :open_worker, [ctx.lane_m["id"], "review"]), "worker")

      r = Control.command(ctx.agent, :list_workers, [])
      assert r["allow"] == true
      assert Map.has_key?(r["workers"], mine["id"])

      # Another actor's assignment names another actor's Lane, so serving
      # it would leak the ancestry `list_loci` already had to close.
      refute Map.has_key?(r["workers"], theirs["id"])
      assert r["count"] == 1

      op = Control.command(ctx.control, :list_workers, [])
      assert map_size(op["workers"]) == 2, "the operator sees the world"
    end
  end

  # ------------------------------------------------------------- fixtures
  defp lane!(control, goal, actor, repo_ref),
    do: ok!(Control.command(control, :open_lane, [goal["id"], actor, repo_ref, nil]), "lane")

  defp occupy!(control, carrier, lane_id, purpose \\ "work") do
    w = ok!(Control.command(control, :open_worker, [lane_id, purpose]), "worker")
    ok!(Control.command(carrier, :attach_worker, [w["id"]]), "worker")
    w
  end

  defp grant_worktree!(lane_id, actor \\ "kestrel") do
    g =
      Authority.mint(%{
        "capability" => Locus.create_capability(),
        "resource" => lane_id,
        "actor" => actor,
        "duration" => "workspace"
      })

    refute match?({:refused, _}, g), "the grant was refused: #{inspect(g)}"
    g
  end

  defp ok!(result, key) do
    assert result["allow"] == true,
           "expected #{key} to be allowed, got: #{inspect(Map.take(result, ["allow", "reason", "refusal"]))}"

    result[key]
  end

  defp refusal_code(r), do: r["refusal"]["code"]

  defp world_footprint do
    %{
      receipts: length(Ampd.Receipts.all()),
      active_caps: Loci.caps() |> Enum.count(fn {_, c} -> c["status"] == "active" end),
      admitted: Worktree.resources() |> Enum.count(fn {_, r} -> r["state"] != "REQUESTED" end),
      workers: map_size(Loci.workers()),
      dirs: Worktree.root() |> File.ls!() |> Enum.sort()
    }
  end

  # Every key anywhere in a term, with the route that reached it — the same
  # recursive shape `F19f` uses, because a nested object inherits every
  # rule of the record it is embedded in.
  defp keys_with_paths(term), do: keys_with_paths(term, [])

  defp keys_with_paths(m, at) when is_map(m) do
    Enum.flat_map(m, fn {k, v} ->
      [{Enum.join(at ++ [to_string(k)], "."), to_string(k)}] ++ keys_with_paths(v, at ++ [to_string(k)])
    end)
  end

  defp keys_with_paths(l, at) when is_list(l) do
    l |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> keys_with_paths(v, at ++ ["[#{i}]"]) end)
  end

  defp keys_with_paths(_, _), do: []

  defp init_repo! do
    dir = Path.join(Ampd.Store.data_dir(), "fixture-repo-d12")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "README"), "d12\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.email", "d12@example.invalid"],
          ["config", "user.name", "D12"],
          ["config", "commit.gpgsign", "false"],
          ["add", "-A"],
          ["commit", "-q", "-m", "init"]
        ] do
      {out, code} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
      assert code == 0, "fixture repo setup failed: git #{Enum.join(args, " ")} → #{out}"
    end

    dir
  end
end
