defmodule Ampd.IncarnationTest do
  @moduledoc """
  **A world incarnation is a fence, and authority is reacquired on the other
  side of one.**

      installation_id changes   →  a different world installation
      generation changes        →  a discontinuous incarnation of this one
                                   old channels invalid · authority reacquired
      projection_epoch changes  →  same incarnation, new runtime · resnapshot
      revision changes          →  ordinary mutation

  F.8.2.4 built `world_incarnation` and then fenced authority on only half
  of it. Its reasoning was that a generation advance leaves the actor named
  and the stores in place, so a channel could keep operating — and that the
  real consequence, stale consent, was already enforced per-approval by the
  lineage inside the intent digest.

  The consent half was true and it was not the whole law:

      old consent cannot survive a restore
        does not imply
      old work may safely cross one

  A queued `request_grant` has no approval to invalidate. It opens a
  brand-new request in the restored world, on behalf of an actor that world
  may never have named — which is the F.8.2.3 bug with one lineage
  component held constant. These are the witnesses for both halves: the
  fence that refuses work formed in the ending incarnation, and the barrier
  that leaves no channel able to form any.
  """
  use ExUnit.Case, async: false
  alias Ampd.{Authority, AuthorityCoordinator, Bridge, Control, GrantRegistry, Peer,
              Transport, World}

  setup do
    Ampd.reset_demo()
    Bridge.reset()
    Peer.reset()
    Process.sleep(120)
    :ok
  end

  # ------------------------------------------------------------- helpers
  defp coord, do: Process.whereis(AuthorityCoordinator)

  # Wait for `want` authority transactions to be *visible in the
  # coordinator's mailbox*, not for a number of anything else. F.8.2.4
  # recorded two earlier versions of this that could not fail — one that
  # returned `:ok` from the exhausted loop because `Process.sleep/1` does,
  # and one that counted the whole mailbox, which a suspended coordinator
  # also fills with the `:ops` and `:epoch` calls a connection makes while
  # building its `hello@1`.
  defp queued(want) do
    Enum.reduce_while(1..300, false, fn _, _ ->
      if tx_waiting() >= want do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end

  defp tx_waiting do
    {:messages, msgs} = Process.info(coord(), :messages)
    Enum.count(msgs, &match?({:"$gen_call", _, {:tx, _, _}}, &1))
  end

  defp agent_channel(actor \\ "kestrel") do
    {rt, _cl} = Transport.socketpair()
    {:ok, conn, id} = Bridge.adopt_channel(rt, :agent, actor)
    {conn, id}
  end

  defp control_channel do
    {rt, _cl} = Transport.socketpair()
    {:ok, conn, id} = Bridge.adopt_channel(rt, :human_control, nil)
    {conn, id}
  end

  defp issue(peer_id, cmd, args) do
    me = self()
    spawn(fn -> send(me, {:result, Control.command(peer_id, cmd, args)}) end)
  end

  defp await_result do
    receive do
      {:result, r} -> r
    after
      8_000 -> flunk("the command never returned")
    end
  end

  # **The witness shape for every "queued behind a restore" case.**
  #
  # Suspending the coordinator lets the restore and the command both be
  # *seen* in its mailbox before either runs, so the interleaving is
  # established rather than raced for. The command resolves its peer and
  # captures its expectation while the world is still generation 1; the
  # restore linearizes first; the command arrives in generation 2.
  defp queued_behind_restore(peer_id, cmd, args) do
    :sys.suspend(coord())

    spawn(fn -> Authority.advance_lineage("restore", %{"generation" => 1}) end)
    assert queued(1), "the restore never reached the coordinator"

    issue(peer_id, cmd, args)
    assert queued(2), "the command never queued behind the restore"

    :sys.resume(coord())
    await_result()
  end

  # ------------------------------------------- the fence, on the generation
  test "a grant request queued behind a restore cannot execute in the incarnation that replaced it" do
    {_conn, kestrel} = agent_channel()
    assert World.lineage()["generation"] == 1

    r =
      queued_behind_restore(kestrel, :request_grant, [
        "github.pr.create",
        "acme/api",
        %{"reason" => "stale-incarnation witness", "duration" => "run"}
      ])

    refute r["allow"]
    assert r["refusal"]["code"] == "world-incarnation-changed"

    # The agent learns *that* its world ended and nothing more — no
    # generations, no topology. That is the dual-disclosure law, and this
    # refusal is subject to it like every other.
    refute Map.has_key?(r["refusal"], "operator_detail")

    # The operator, on a channel bound to the incarnation that now exists,
    # pastes the correlation id and sees which half moved — because the
    # remediations differ. A generation advance is this world's next
    # incarnation and the host reattaches to it; a different installation is
    # a different world entirely, with nothing to reattach to.
    {_hc, human} = control_channel()
    d = Control.command(human, :inspect_refusal, [r["refusal"]["correlation_id"]])

    assert d["refusal"]["operator_detail"]["discontinuity"] == "generation"
    assert d["refusal"]["operator_detail"]["installation_changed"] == false
    assert d["refusal"]["operator_detail"]["expected_generation"] == 1
    assert d["refusal"]["operator_detail"]["current_generation"] == 2

    assert World.lineage()["generation"] == 2

    assert GrantRegistry.requests() == [],
           "a request formed in generation 1 was written into generation 2 — " <>
             "it has no approval to invalidate, so nothing else would have caught it"
  end

  test "an effect request queued behind a restore cannot re-decide in the incarnation that replaced it" do
    {_conn, kestrel} = agent_channel()
    Authority.set_draft("pr.create", true)
    Authority.commit(Ampd.CapabilityRegistry.get("github")["surface"])

    before = Ampd.Receipts.count()
    approvals_before = length(Ampd.Approvals.all())

    r =
      queued_behind_restore(kestrel, :request_effect, [
        "github.pr.create",
        "traaviis/trvm",
        %{"er" => "er-github.pr.create", "rev" => 1, "params" => Ampd.Core.params()["pr.create"]}
      ])

    # **The shape, not only the verdict.** `request_effect` is the one
    # command that does not pass through `Ampd.Control.settled/2` — it
    # returns whatever `Ampd.Gateway.perform/5` gives it, and `perform`
    # receives the coordinator's `refusal@1` through the same `{:refused, _}`
    # tuple it uses for its own authorization verdicts. Measured before the
    # fix: a bare `refusal@1` with no `allow` key and `operator_detail`
    # still attached, handed to the agent.
    assert r["allow"] == false, "a fenced effect request answered with no verdict at all"
    assert r["refusal"]["code"] == "world-incarnation-changed"
    assert r["reason"] == "The world this channel belongs to no longer exists."

    refute Map.has_key?(r["refusal"], "operator_detail"),
           "a fenced effect request leaked operator_detail past the dual-disclosure boundary"

    refute Map.has_key?(r, "operator_detail")

    assert Ampd.Receipts.count() == before
    assert length(Ampd.Approvals.all()) == approvals_before,
           "an effect request from the previous incarnation opened an approval in this one"
  end

  test "a human revocation queued behind a restore cannot mutate the incarnation that replaced it" do
    {_conn, human} = control_channel()

    target = GrantRegistry.list() |> Enum.find(&(&1["status"] == "active"))
    assert target, "precondition: the demo world must have an active grant to revoke"

    r = queued_behind_restore(human, :revoke_grant, [target["id"]])

    refute r["allow"]
    assert r["refusal"]["code"] == "world-incarnation-changed"

    after_ = Enum.find(GrantRegistry.list(), &(&1["id"] == target["id"]))

    assert after_["status"] == "active",
           "a revocation formed in generation 1 mutated generation 2 — the person consented " <>
             "to this under an authority snapshot the restored world cannot re-derive"
  end

  # The other branch of `discontinuity`, and it is here so the field cannot
  # be a constant. One value pinned by one witness is indistinguishable from
  # a hard-coded string, and this field exists precisely because the two
  # remediations differ: a generation advance is this world's next
  # incarnation and the host reattaches to it; a new installation has
  # nothing to reattach to.
  test "a factory reset is the other discontinuity, and says so" do
    {_conn, kestrel} = agent_channel()
    before = World.lineage()["installation_id"]

    :sys.suspend(coord())

    spawn(fn -> Ampd.Bootstrap.reset_world!() end)
    assert queued(1), "the factory reset never reached the coordinator"

    issue(kestrel, :request_grant, [
      "github.pr.create",
      "acme/api",
      %{"reason" => "installation-discontinuity witness", "duration" => "run"}
    ])

    assert queued(2), "the command never queued behind the reset"

    :sys.resume(coord())
    r = await_result()

    assert r["refusal"]["code"] == "world-incarnation-changed"
    assert World.lineage()["installation_id"] != before

    {_hc, human} = control_channel()
    d = Control.command(human, :inspect_refusal, [r["refusal"]["correlation_id"]])

    assert d["refusal"]["operator_detail"]["discontinuity"] == "installation"
    assert d["refusal"]["operator_detail"]["installation_changed"] == true
  end

  test "an ordinary command in the incarnation its channel was bound to is served" do
    {_conn, kestrel} = agent_channel()

    # The control case, and it is not decoration: a fence that refuses
    # everything is indistinguishable from a fence that works, and every
    # falsifier above would still be green.
    r =
      Control.command(kestrel, :request_grant, [
        "github.pr.create",
        "acme/api",
        %{"reason" => "same incarnation", "duration" => "run"}
      ])

    assert r["held"] == true
    assert length(GrantRegistry.requests()) == 1
  end

  # ----------------------------------------------- the barrier, on the advance
  test "a lineage advance closes every channel bound to the incarnation that ended" do
    {human_conn, human} = control_channel()
    {agent_conn, kestrel} = agent_channel()
    {other_conn, mallory} = agent_channel("mallory")

    assert length(Bridge.list()) == 3
    assert length(Peer.list()) == 3
    old_epoch = Peer.epoch()

    Authority.advance_lineage("restore", %{"generation" => 1})

    # The bridge has nothing left to serve, and neither socket nor process
    # outlived the incarnation. `Ampd.Bridge.reset/0` watches each killed
    # connection out before it returns — the process barrier F.8.2.4 added
    # — so this is a completed teardown, not a request for one.
    assert Bridge.list() == [], "a channel outlived the incarnation it was bound to"
    refute Process.alive?(human_conn)
    refute Process.alive?(agent_conn)
    refute Process.alive?(other_conn)

    # And no handle from the ended incarnation resolves, whatever the table
    # happens to contain — `Ampd.Peer.reset/0` mints a fresh epoch, so the
    # refusal does not depend on a map having been emptied.
    assert Peer.list() == []
    assert Peer.epoch() != old_epoch
    assert Peer.resolve(human) == nil
    assert Peer.resolve(kestrel) == nil
    assert Peer.resolve(mallory) == nil
  end

  test "after a restore the person reacquires control and the engine reacquires its binding" do
    {_hc, human} = control_channel()
    {_ac, kestrel} = agent_channel()

    Authority.advance_lineage("restore", %{"generation" => 1})

    # The old channels are gone, and *not* by being told they are stale:
    # the handle no longer names anything at all.
    assert Control.command(human, :operator_projection, [])["refusal"]["code"] == "unknown-peer"
    assert Control.command(kestrel, :agent_projection, [])["refusal"]["code"] == "unknown-peer"

    # The control claim is free — this is the F.8.2.3 failure one level up.
    # A barrier that closed the sockets but left `control_open` set would
    # refuse the person a control channel in the world they just restored,
    # which is worse than not having torn anything down.
    {_hc2, human2} = control_channel()
    {_ac2, kestrel2} = agent_channel()

    assert Control.command(human2, :operator_projection, [])["schema"] =~ ~r/^operator-projection@/

    # And the reacquired channel is bound to the *new* incarnation, so its
    # work is served rather than fenced.
    r =
      Control.command(kestrel2, :request_grant, [
        "github.pr.create",
        "acme/api",
        %{"reason" => "reacquired after restore", "duration" => "run"}
      ])

    assert r["held"] == true
    assert length(GrantRegistry.requests()) == 1
  end

  # ------------------------------------------------ bind-time, not submit-time
  #
  # **The falsifier F.8.2.4 claimed and did not have.**
  #
  # Its probe replaced the peer record's `world_lineage` with `nil`, which
  # proves the expectation must *exist* — not that it must be sampled when
  # the channel is bound. In that witness the coordinator is suspended, so
  # the queued restore has not run when the command is submitted, and the
  # bind-time and submission-time samples are the same value. An
  # implementation that read `Ampd.World.lineage()` at submission would have
  # passed it.
  #
  # This one interposes where they genuinely differ. Suspending
  # `Ampd.Bridge` stops the restore *inside* its transaction, after the
  # manifest has been rewritten and before any channel has been closed:
  #
  #     manifest    generation 2      (durable, already written)
  #     channels    still bound to generation 1
  #     coordinator blocked inside the advance
  #
  # A command issued in that interval resolves a generation-1 peer while
  # `Ampd.World.lineage()` already answers generation 2. Bind-time refuses
  # it; submission-time launders it into the incarnation that replaced it.
  test "the expected incarnation is the channel's, not the one current at submission" do
    {_conn, kestrel} = agent_channel()
    bridge = Process.whereis(Bridge)

    :sys.suspend(bridge)

    spawn(fn -> Authority.advance_lineage("restore", %{"generation" => 1}) end)

    # Wait on the durable fact, not on a sleep: the manifest is a file, so
    # this is observable without asking any process that might be blocked.
    assert Enum.reduce_while(1..300, false, fn _, _ ->
             if World.lineage()["generation"] == 2 do
               {:halt, true}
             else
               Process.sleep(20)
               {:cont, false}
             end
           end),
           "the restore never made the discontinuity durable"

    # The channel is still bound — the barrier is blocked behind the
    # suspended bridge — so this resolves, and the two sample points now
    # disagree.
    assert Peer.resolve(kestrel)["world_lineage"]["generation"] == 1

    issue(kestrel, :request_grant, [
      "github.pr.create",
      "acme/api",
      %{"reason" => "bind-vs-submit witness", "duration" => "run"}
    ])

    # **Settle on either outcome, because W.1 moved where this is caught.**
    #
    # With the entry fence, a bind-time implementation refuses here without
    # ever reaching the coordinator — the manifest already says generation
    # 2 and the channel says 1. A submission-time implementation compares
    # generation 2 against generation 2, passes, and parks at the
    # coordinator, which is held by the advance. Waiting for *either* keeps
    # the witness deterministic in both directions; waiting only for the
    # coordinator was an assertion about the defect rather than the fix,
    # and it is what the previous version did.
    assert Enum.reduce_while(1..300, false, fn _, _ ->
             {:messages, mine} = Process.info(self(), :messages)

             if Enum.any?(mine, &match?({:result, _}, &1)) or tx_waiting() >= 1 do
               {:halt, true}
             else
               Process.sleep(20)
               {:cont, false}
             end
           end),
           "the command neither returned nor reached the coordinator"

    # Resumed before the assertions, so a failure cannot leave the bridge
    # suspended and take the rest of the file down with it — three tests
    # were lost to exactly that while this was being built.
    :sys.resume(bridge)
    r = await_result()

    refute r["allow"]
    assert r["refusal"]["code"] == "world-incarnation-changed"

    assert GrantRegistry.requests() == [],
           "the expectation was sampled at submission — a command formed in generation 1 " <>
             "read the generation that replaced it and laundered itself into it"
  end

  # ---------------------------------------------------------- continuity
  test "a restore is a new incarnation of the same installation" do
    before_lineage = World.lineage()
    before = Ampd.Projection.continuity()

    Authority.advance_lineage("restore", %{"generation" => 1})

    now_lineage = World.lineage()
    now = Ampd.Projection.continuity()

    # Same installation — this is not a factory reset, and a client must be
    # able to tell those apart.
    assert before_lineage["installation_id"] == now_lineage["installation_id"]
    assert now_lineage["generation"] == before_lineage["generation"] + 1

    # ...and still a different incarnation, because the generation is
    # hashed in. This is the field the three-field continuity triple could
    # not carry: `world_generation` moving is visible, but it was advisory
    # — nothing bound to it.
    assert before["world_incarnation"] != now["world_incarnation"]
    assert now["world_generation"] == before["world_generation"] + 1
  end

  test "a coordinator restart is a new runtime, not a new incarnation" do
    before_incarnation = World.incarnation()
    before = Ampd.Projection.continuity()

    ref = Process.monitor(coord())
    Process.exit(coord(), :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

    assert Enum.reduce_while(1..100, false, fn _, _ ->
             if is_pid(coord()), do: {:halt, true}, else: (Process.sleep(20); {:cont, false})
           end),
           "the coordinator never came back"

    now = Ampd.Projection.continuity()

    # The world on disk did not change, so the incarnation must not. Only
    # the runtime did, and `projection_epoch` is what names that — a client
    # resnapshots, it does not discard the world.
    assert World.incarnation() == before_incarnation
    assert now["world_incarnation"] == before["world_incarnation"]
    assert now["projection_epoch"] != before["projection_epoch"]
  end
end
