defmodule Ampd.CockpitTest do
  @moduledoc """
  **The cockpit observes one world incarnation.**

      A peer-bound command may return information only from the
      incarnation that peer belongs to.

  F.8.2.5 made that true of *writes*. It was not true of reads, and the
  contradiction was reachable in the interval a lineage advance opens
  between its durable generation bump and its channel barrier:

      GEN-1 CHANNEL
        ├── request_grant     → world-incarnation-changed
        └── agent_projection  → served, assembled out of generation 2

  Measured exactly that way before the fence existed. `Ampd.Authority.in_world/2`
  only parks a value that `Ampd.Authority.tx/1` later reads, so a command
  that reaches no coordinator was never fenced by one — and the `:both`
  commands did not even enter `in_world/2`.

  The second law here is about the *cursor*, and it matters for the same
  reason: the WebView's only input is this frame.

      The revision attached to a projection describes the projection
      actually returned.

  `Ampd.Subscriptions.build/1` merged `continuity/0` with a separately
  built projection, and Elixir evaluates the cursor first. Measured, with
  `Ampd.Session` suspended to park the build between the two: cursor
  `revision 1`, content `revision 2`, and the grant that the intervening
  revocation removed already absent from the list. A client comparing
  cursors sees a revision it believes it has already rendered, so the
  correction never arrives — and the correction is a revoked grant still on
  the screen.
  """
  use ExUnit.Case, async: false

  alias Ampd.{Authority, AuthorityCoordinator, Bridge, CommandSpec, Control,
              GrantRegistry, Peer, Projection, Subscriptions, Transport, World}

  setup do
    Ampd.reset_demo()
    Bridge.reset()
    Peer.reset()
    Process.sleep(120)
    :ok
  end

  defp agent_channel(actor \\ "kestrel") do
    {rt, _cl} = Transport.socketpair()
    {:ok, _conn, id} = Bridge.adopt_channel(rt, :agent, actor)
    id
  end

  defp control_channel do
    {rt, _cl} = Transport.socketpair()
    {:ok, _conn, id} = Bridge.adopt_channel(rt, :human_control, nil)
    id
  end

  # The interval W.1 is about, entered deterministically: suspending
  # `Ampd.Bridge` stops a lineage advance *inside* its transaction, after
  # the manifest has been rewritten and before any channel has been closed.
  #
  #     manifest    generation 2      durable, already written
  #     channels    still bound to generation 1
  #     coordinator held by the advance
  #
  # Everything is torn down before the assertions run, so a failure cannot
  # leave the bridge suspended and take the rest of the file with it.
  defp during_advance(fun) do
    bridge = Process.whereis(Bridge)
    :sys.suspend(bridge)
    spawn(fn -> Authority.advance_lineage("restore", %{"generation" => 1}) end)

    settled =
      Enum.reduce_while(1..300, false, fn _, _ ->
        if World.lineage()["generation"] == 2,
          do: {:halt, true},
          else: (Process.sleep(20); {:cont, false})
      end)

    result = if settled, do: fun.(), else: :never_advanced
    :sys.resume(bridge)
    Process.sleep(80)

    assert settled, "the restore never made the discontinuity durable"
    result
  end

  # ------------------------------------------------ the read is fenced too
  test "a projection is fenced to the incarnation its channel was bound to" do
    kestrel = agent_channel()
    human = control_channel()

    {agent_r, op_r} =
      during_advance(fn ->
        {Control.command(kestrel, :agent_projection, []),
         Control.command(human, :operator_projection, [])}
      end)

    for {label, r} <- [{"agent_projection", agent_r}, {"operator_projection", op_r}] do
      refute r["allow"], "#{label} was served to a channel whose incarnation had ended"
      assert r["refusal"]["code"] == "world-incarnation-changed", label

      refute Map.has_key?(r, "projection"),
             "#{label} returned a projection alongside its refusal"
    end
  end

  test "a subscription is fenced too, and never hands back a snapshot of the new world" do
    kestrel = agent_channel()
    before_subs = Subscriptions.count()

    r = during_advance(fn -> Control.command(kestrel, :subscribe, []) end)

    refute r["allow"]
    assert r["refusal"]["code"] == "world-incarnation-changed"

    refute Map.has_key?(r, "projection"),
           "a channel bound to the ended incarnation received a snapshot of the one that replaced it"

    assert Subscriptions.count() == before_subs,
           "a refused subscribe still registered the subscriber"
  end

  test "history is fenced too" do
    kestrel = agent_channel()

    {receipts, effects, requests} =
      during_advance(fn ->
        {Control.command(kestrel, :list_receipts, [nil, 50]),
         Control.command(kestrel, :list_effect_history, [nil, 50]),
         Control.command(kestrel, :list_grant_requests, [nil, 50])}
      end)

    for r <- [receipts, effects, requests] do
      assert r["refusal"]["code"] == "world-incarnation-changed"
      refute Map.has_key?(r, "items"), "a history page crossed an incarnation boundary"
    end
  end

  test "a channel bound in the new incarnation is served normally" do
    during_advance(fn -> :ok end)

    # The barrier has run by now; the person and the engine reacquire.
    human = control_channel()
    kestrel = agent_channel()

    op = Control.command(human, :operator_projection, [])
    ag = Control.command(kestrel, :agent_projection, [])

    assert op["schema"] =~ ~r/^operator-projection@/
    assert ag["schema"] =~ ~r/^agent-projection@/
    assert op["world_incarnation"] == World.incarnation()
    assert op["world_generation"] == 2
  end

  # ------------------------------------------------ the cursor is the content's
  test "every peer-bound read names the incarnation it was assembled in" do
    human = control_channel()
    kestrel = agent_channel()

    # A refusal to look up, so `inspect_refusal` has something real.
    Control.command(kestrel, :request_effect, ["github.pr.merge", "acme/api", %{}])
    cid = Ampd.RefusalLog.recent(1) |> hd() |> Map.fetch!("correlation_id")

    calls = %{
      agent_projection: {kestrel, []},
      preflight: {kestrel, ["github.pr.create", "traaviis/trvm", %{"er" => "e", "rev" => 1, "params" => %{}}]},
      list_receipts: {kestrel, [nil, 50]},
      list_effect_history: {kestrel, [nil, 50]},
      list_grant_requests: {kestrel, [nil, 50]},
      inspect_refusal: {kestrel, [cid]},
      operator_projection: {human, []},
      recovery_status: {human, []}
    }

    # **Derived from `Ampd.CommandSpec`, not from this list.** A read added
    # later that forgets to be framed would otherwise be caught by nothing:
    # its reply would simply have no cursor, and a client cannot tell a
    # missing cursor from an unchanged one.
    #
    # `runtime_status` is the one exclusion and it is principled: it is
    # answered before the peer is resolved, because a caller with no binding
    # still deserves to learn whether this runtime is healthy. With no peer
    # there is no incarnation to fence it to.
    expected = CommandSpec.reads() -- [:runtime_status]

    assert Enum.sort(Map.keys(calls)) == Enum.sort(expected),
           "a read command was declared in command-spec@1 and never exercised here: " <>
             "#{inspect(expected -- Map.keys(calls))}"

    inc = World.incarnation()

    for {cmd, {peer, args}} <- calls do
      r = Control.command(peer, cmd, args)

      assert r["world_incarnation"] == inc,
             "#{cmd} answered without naming the incarnation it was assembled in: #{inspect(r["world_incarnation"])}"

      assert r["revision"] == AuthorityCoordinator.ops(), "#{cmd} carried no revision"
      assert r["projection_epoch"] == AuthorityCoordinator.epoch(), "#{cmd} carried no epoch"
    end
  end

  test "a mutation landing during a snapshot build cannot mislabel it" do
    human = control_channel()
    peer = Peer.resolve(human)
    target = Enum.find(GrantRegistry.list(), &(&1["status"] == "active"))
    assert target, "precondition: the demo world must have an active grant to revoke"

    before_rev = AuthorityCoordinator.ops()

    # `Ampd.Session` is read first inside `Ampd.Projection.operator/0` and
    # `Ampd.GrantRegistry` after it, so suspending Session parks the build
    # between the cursor sample and the grant read — the exact window that
    # produced `revision 1` beside revision 2's content.
    :sys.suspend(Process.whereis(Ampd.Session))
    me = self()
    spawn(fn -> send(me, {:snap, Subscriptions.snapshot(peer)}) end)
    Process.sleep(250)

    spawn(fn -> Authority.revoke_one(target["id"]) end)
    Process.sleep(250)
    :sys.resume(Process.whereis(Ampd.Session))

    snap = receive do
      {:snap, s} -> s
    after
      8_000 -> flunk("the snapshot never returned")
    end

    now_rev = AuthorityCoordinator.ops()
    shown = Enum.map(snap["projection"]["grants"], & &1["id"])

    assert now_rev > before_rev, "precondition: the revocation must have landed"

    refute target["id"] in shown,
           "precondition: the projection must reflect the revocation"

    assert snap["revision"] == now_rev,
           "the frame is labelled revision #{snap["revision"]} and its content is revision " <>
             "#{now_rev} — a client comparing cursors would treat the newer authority as " <>
             "already rendered, and the revoked grant would stay on the screen"

    assert snap["world_incarnation"] == World.incarnation()
  end

  test "a world that moves during every attempt is still observed, and still coherently" do
    human = control_channel()

    # **The witness that killed the optimistic-only design.** A seqlock
    # alone is defeated by a world that moves during every attempt, and the
    # first version of this measured exactly that: 40 of 40 reads failed to
    # settle. Refusing them by name was the obvious next move and it is the
    # wrong one — a busy world that cannot be observed is a worse product
    # than a slow one, and this frame is the cockpit's only input.
    # The churn moves the **active grant set**, which the operator
    # projection reads twice — once as `grants` and once, further down, as
    # the `authority_snapshot` digest over the same registry. That gives
    # the frame an invariant that can be checked from outside it.
    #
    # **W.2.3.3 · AND THE CHURN HAS TO OUTLIVE THE READS, WHICH A FIXED
    # COUNT DOES NOT GUARANTEE.** This was `Enum.take(20_000)` — a budget,
    # not a duration. Forty `operator_projection` reads under contention
    # each retry the optimistic loop before reaching the ordered fallback,
    # and every one of them builds the whole operator map; the two costs are
    # the same order of magnitude, so the loop sometimes drained first. The
    # remaining reads then ran against a quiet world, the fallback was never
    # reached, and a sabotage that deletes the fallback was never executed.
    # `ampd/tools/sabotage.sh` reports that as NOT A FALSIFIER — for a fix
    # that is present and working.
    #
    # **Measured at W.2.3.3 before it was changed: one run in eight.** So
    # every previous chain that recorded this law as falsified was standing
    # on a coin that had come up heads, and the round it finally came up
    # tails was the one that noticed.
    #
    #   > A falsifier for a fix that removes a race may not itself be
    #   > decided by one.
    #
    # The loop is unbounded now and killed below — and again from `on_exit`,
    # so an assertion that fails before the kill cannot leak an infinite
    # churn into the next test, which is the safety property `Enum.take`
    # was providing by accident. `ops_before`/`ops_after` is the check that
    # the world really was moving: **a witness whose fault may silently not
    # have happened is not a witness**, because it reports the absence of a
    # fault as the presence of a fix.
    churn =
      spawn(fn ->
        Stream.repeatedly(fn ->
          Authority.revoke_domain("github.pr.draft")
          Authority.one_shot("github.pr.draft")
        end)
        |> Stream.run()
      end)

    on_exit(fn -> Process.exit(churn, :kill) end)

    # **AND THE READ COUNT IS SIZED FROM THE MEASURED RATE, NOT FROM TASTE.**
    #
    # Guaranteeing the churn outlives the reads was necessary and was not
    # sufficient: re-measured with the unbounded loop in place, one run in
    # twelve still passed with the fix disabled. The residual cause is the
    # tear WINDOW rather than the fault's presence. A read only tears if a
    # mutation lands between `Projection.operator/0`'s two reads of the
    # grant registry — `grants` and, five entries later, `authority_snapshot`
    # — and a churn that revokes and re-grants the same domain is invisible
    # unless an ODD number of transitions falls inside it. On top of that, a
    # read whose optimistic seqlock happens to settle never reaches the
    # sabotaged fallback at all.
    #
    # Both are per-read coin flips, so the answer is the exponent. Measured
    # across twenty sabotaged runs at forty reads, a whole run failed to
    # detect roughly one time in ten, which puts the per-read detection rate
    # near six percent:
    #
    #     (1 - p) ^ 40  ≈ 0.10        →   p ≈ 0.056
    #     (1 - p) ^ 200 ≈ 0.00001
    #
    # **This is the honest limit of the claim: the bound is computed, and a
    # dozen green runs is consistency with it rather than proof of it.** A
    # deterministic construction would need a synchronisation point inside
    # `Projection.operator/0` — a test seam in the product, which this
    # runtime refuses more strongly than it dislikes an exponent.
    reads = 200

    ops_before = AuthorityCoordinator.ops()
    results = for _ <- 1..reads, do: Control.command(human, :operator_projection, [])
    ops_after = AuthorityCoordinator.ops()
    Process.exit(churn, :kill)
    Process.sleep(50)

    assert ops_after - ops_before >= reads,
           "the world advanced by only #{ops_after - ops_before} operations across " <>
             "#{reads} reads: the coherence assertions below would be about a world that " <>
             "was not moving, which is not the state this test exists to measure"

    packs = Ampd.CapabilityRegistry.all()

    for r <- results do
      refute r["refusal"],
             "a read starved under load: #{inspect(r["refusal"]["code"])}"

      assert r["schema"] =~ ~r/^operator-projection@/
      assert is_integer(r["revision"])
      assert is_binary(r["projection_epoch"])
      assert r["world_incarnation"] == World.incarnation()

      # **Liveness is half the claim; this is the other half.** A frame
      # assembled across a mutation has its `grants` from one revision and
      # its `authority_snapshot` from the next. `Ampd.Core.snapshot_of/2`
      # digests exactly the active grants, so recomputing it from the
      # frame's own list is a coherence check on the frame itself — and it
      # is the one that fails if the fallback stops assembling the content
      # inside the total order.
      assert Ampd.Core.snapshot_of(r["grants"], packs) == r["authority_snapshot"],
             "the frame's grant list and its authority digest were read at different " <>
               "revisions — a projection torn across a mutation, labelled with one cursor"
    end
  end

  # ------------------------------------------------------- the cursor itself
  test "epoch and revision are one sample, because separately they tear" do
    c = AuthorityCoordinator.cursor()

    assert c["projection_epoch"] == AuthorityCoordinator.epoch()
    assert c["revision"] == AuthorityCoordinator.ops()

    # The continuity frame is built from that one sample plus one read of
    # the manifest — four independent samples is what it was, and two of
    # the pairs could disagree with each other.
    cont = Projection.continuity()

    assert Map.keys(cont) |> Enum.sort() ==
             ~w(projection_epoch revision view_revision world_generation world_incarnation)

    assert cont["view_revision"] == c["view_revision"]

    assert cont["world_incarnation"] == World.incarnation()
    assert cont["world_generation"] == World.lineage()["generation"]
  end

  # ------------------------------------------ the second clock: view vs authority
  #
  # `operator-projection@2` carries `peers`, `channels` and
  # `recent_refusals`. None of them is under the coordinator, and only the
  # coordinator called `Ampd.Subscriptions.changed/0` — so a change to any
  # of them was invisible to a subscriber, with every field it could
  # compare unchanged. Measured before this existed:
  #
  #     subscribed · channels in view: 1
  #     an agent channel opens
  #     pushes received: 0 · revision 1 -> 1
  #     a fresh snapshot shows 2 channels; the subscriber still holds 1
  #
  # The fix is not to call a connection opening an authority mutation.
  defp drain(acc \\ []) do
    receive do
      {:ampd_push, s} -> drain([s | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  test "a channel opening reaches a subscriber, and moves no authority" do
    human = control_channel()
    snap = Subscriptions.subscribe(Peer.resolve(human))
    drain()

    authority_before = AuthorityCoordinator.ops()
    view_before = snap["view_revision"]
    channels_before = length(snap["projection"]["channels"])

    agent_channel("mallory")

    pushes = drain()

    assert pushes != [],
           "a channel opened, the projection changed, and no subscriber was told"

    last = List.last(pushes)

    assert length(last["projection"]["channels"]) > channels_before,
           "the push did not carry the new channel"

    assert last["view_revision"] > view_before,
           "the view revision did not move, so a client would classify this as already seen"

    assert last["revision"] == authority_before,
           "opening a channel rewrote authority history — a connection is not consent"

    assert AuthorityCoordinator.ops() == authority_before
  end

  test "a channel closing reaches a subscriber too" do
    human = control_channel()
    {rt, _cl} = Transport.socketpair()
    {:ok, conn, _id} = Bridge.adopt_channel(rt, :agent, "mallory")

    snap = Subscriptions.subscribe(Peer.resolve(human))
    drain()
    open_count = length(snap["projection"]["channels"])

    Process.exit(conn, :kill)

    pushes = drain()
    assert pushes != [], "a channel died and no subscriber was told"

    assert length(List.last(pushes)["projection"]["channels"]) < open_count
  end

  test "a refusal landing reaches a subscriber" do
    human = control_channel()
    kestrel = agent_channel()
    snap = Subscriptions.subscribe(Peer.resolve(human))
    drain()

    # **The newest entry, not the count.** `recent_refusals` is a window of
    # 20, so once the ring is full the length can never grow and an
    # assertion on it passes or fails according to how much else the suite
    # happened to run first — which is a test measuring its own neighbours.
    newest = fn frame ->
      frame["projection"]["recent_refusals"] |> List.first() |> Kernel.||(%{}) |> Map.get("correlation_id")
    end

    before = newest.(snap)
    authority_before = AuthorityCoordinator.ops()

    # **A refusal that reaches no coordinator.** The first version of this
    # used `request_effect`, which runs an authority transaction whether or
    # not it is allowed — so the push it produced came from the coordinator
    # and the witness would have been green with the refusal notification
    # removed entirely. Measured: the probe stayed green.
    #
    # An agent asking for a human-only command is refused by
    # `Ampd.Control` before anything is dispatched. Nothing is ordered,
    # nothing is decided, and a line appears in the operator's diagnostic
    # view.
    r = Control.command(kestrel, :approve_effect, ["er-x", "ap_0001"])
    assert r["refusal"]["code"] == "human-consent-required"

    pushes = drain()
    assert pushes != [], "a refusal entered the operator's diagnostic view unannounced"

    assert AuthorityCoordinator.ops() == authority_before,
           "precondition: this refusal must not be an authority mutation"

    assert newest.(List.last(pushes)) != before,
           "the pushed frame does not carry the refusal that caused it"
  end

  test "an authority change moves both clocks" do
    human = control_channel()
    snap = Subscriptions.subscribe(Peer.resolve(human))
    drain()

    target = Enum.find(GrantRegistry.list(), &(&1["status"] == "active"))
    Authority.revoke_one(target["id"])

    pushes = drain()
    assert pushes != []
    last = List.last(pushes)

    assert last["revision"] > snap["revision"], "an authority mutation did not move the authority revision"
    assert last["view_revision"] > snap["view_revision"], "...nor the view revision"
  end

  # ------------------------------------------ a new runtime announces itself
  test "a coordinator restart announces its new epoch to existing subscribers" do
    human = control_channel()
    snap = Subscriptions.subscribe(Peer.resolve(human))
    drain()

    held_epoch = snap["projection_epoch"]

    # `:one_for_one`, so this is replaced while `Ampd.Peer`, `Ampd.Bridge`,
    # `Ampd.Subscriptions` and every channel survive. Nothing announced the
    # new epoch, so `Continuity::NewRuntime` was classifiable and never
    # observable: measured as zero pushes, subscription intact, and a host
    # holding the old epoch until some unrelated later mutation happened to
    # cause a push.
    ref = Process.monitor(Process.whereis(AuthorityCoordinator))
    Process.exit(Process.whereis(AuthorityCoordinator), :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

    pushes = drain()

    assert pushes != [],
           "a new runtime incarnation started and told nobody — the cockpit would render " <>
             "a projection from an epoch that no longer exists, indefinitely"

    last = List.last(pushes)

    assert last["projection_epoch"] != held_epoch,
           "the announced frame carries the old epoch"

    assert last["projection_epoch"] == AuthorityCoordinator.epoch()

    # **Announcing, and only announcing.** Closing the channel would be
    # `NewIncarnation` behaviour, and the distinction is the whole value of
    # the enum: a runtime restart keeps the person's authority, a world
    # discontinuity does not.
    assert Peer.resolve(human) != nil,
           "a coordinator restart cost the person their control channel"

    assert Subscriptions.count() == 1, "a coordinator restart dropped the subscription"
    assert last["world_incarnation"] == World.incarnation(), "the world changed under a restart"
  end

  # ---------------------------------------- the view clock may not lag the view
  test "a frame's view revision is never older than the content beside it" do
    kestrel = agent_channel()
    Process.sleep(80)

    # Park a pessimistic build inside the total order, with `Ampd.Bridge`
    # suspended, and land a projection-visible change while it is blocked.
    #
    # The change is a refusal that reaches **no coordinator** — an agent
    # issuing a human-only command — so nothing about it is ordered. Under
    # the old mechanism its `:touched` cast could not even be processed:
    # the coordinator was busy being the thing that made the frame
    # coherent. Measured: cursor `view_revision 2` beside content
    # containing a refusal that belonged to view 3.
    me = self()
    :sys.suspend(Process.whereis(Bridge))

    spawn(fn ->
      send(me, {:frame, AuthorityCoordinator.observe(fn -> Projection.operator() end)})
    end)

    Process.sleep(250)

    r = Control.command(kestrel, :approve_effect, ["er-x", "ap_0001"])
    cid = r["refusal"]["correlation_id"]
    assert is_binary(cid)

    Process.sleep(250)
    :sys.resume(Process.whereis(Bridge))

    {cursor, content} =
      receive do
        {:frame, f} -> f
      after
        8_000 -> flunk("the ordered build never returned")
      end

    Process.sleep(200)

    present = Enum.any?(content["recent_refusals"], &(&1["correlation_id"] == cid))

    assert present,
           "precondition: the build must have read the refusal that landed during it"

    assert cursor["view_revision"] >= Ampd.ViewClock.read() or
             cursor["view_revision"] >= AuthorityCoordinator.cursor()["view_revision"],
           "the cursor names a view older than the clock had already reached"

    # The law, stated as the assertion: a frame is never labelled with a
    # view older than its own content. The clock is ticked synchronously by
    # the mutator and sampled after the build, so this cannot be a race the
    # test usually wins.
    refute cursor["view_revision"] < AuthorityCoordinator.cursor()["view_revision"],
           "cursor #{cursor["view_revision"]} beside content that belongs to a later view — " <>
             "a client told this has already seen the newer state and skips it"
  end

  test "the view clock is ticked by the mutator, not announced to a process" do
    before = Ampd.ViewClock.read()

    # A channel opening ticks it synchronously. No cast, no coordinator: it
    # is readable immediately, including while the coordinator is busy.
    agent_channel("tick-witness")

    assert Ampd.ViewClock.read() > before,
           "the view clock did not advance at the moment the view changed"

    # And the coordinator reports the same number it can read, rather than
    # one it keeps for itself.
    assert AuthorityCoordinator.cursor()["view_revision"] == Ampd.ViewClock.read()
  end

  # ------------------------------------------ a subscription is a live lease
  test "a subscribed channel does not outlive the process that promised to push to it" do
    alias Ampd.Transport.Wire

    {rt, cl} = Transport.socketpair()
    {:ok, conn, human} = Bridge.adopt_channel(rt, :human_control, nil)
    Process.sleep(120)
    _hello = :socket.recv(cl, 0, 500)

    # Subscribed **through the connection**, which is what makes the
    # connection the subscriber — and therefore what makes it the process
    # that has to care when the subscription server dies.
    Wire.send_frame(cl, %{
      "schema" => "command@1",
      "command" => "subscribe",
      "args" => %{},
      "client_request_id" => "c1"
    })

    Process.sleep(300)
    assert Subscriptions.count() == 1
    assert Process.alive?(conn)

    # `:one_for_one`, so only this restarts — every socket stays up and
    # every `subs` entry is gone. Measured before the lease existed: a real
    # authority mutation afterwards produced zero pushes, the connection was
    # still alive, and the host would have held LIVE LOCAL forever.
    Process.exit(Process.whereis(Subscriptions), :kill)
    Process.sleep(500)

    refute Process.alive?(conn),
           "the subscription died and its channel stayed open — the host has no way to " <>
             "learn it will never be told about the world again"

    assert Bridge.list() == []
    assert Peer.resolve(human) == nil
  end

  # ------------------------------------ a read that writes is not retried
  #
  # **STRESS EVIDENCE. THE PROOF IS IN `multiplicity_test.exs`.**
  #
  # This probe races a churn process against one command and hopes the clock
  # moves inside the window. Measured before W.1.4 it failed 3 runs in 20 —
  # detecting a real at-most-once violation, and detecting it 15% of the
  # time. A probe at that rate cannot demonstrate a fix: twenty green runs
  # afterwards is the outcome you would expect from changing nothing.
  #
  # It stays because it covers the whole path end to end, which the
  # deterministic witnesses do not. It no longer carries the claim.
  test "a read that constructs a refusal is executed exactly once (stress)" do
    kestrel = agent_channel()

    # `Ampd.Refusal.new/2` records into `Ampd.RefusalLog` as it constructs,
    # so a read that can refuse writes as it decides. Under the optimistic
    # seqlock these recorded **four** refusals for one client command, and
    # the client saw one. The ring is bounded, so what that destroys is the
    # meaning of the ring — and it evicts real refusals four times faster
    # than the world produced them.
    for {cmd, args, code} <- [
          {:preflight, ["github.pr.merge", "acme/api", %{"er" => "e", "rev" => 1, "params" => %{}}],
           "denied-by-default"},
          {:inspect_refusal, ["rf-nothing-here"], "refusal-unknown"}
        ] do
      Ampd.RefusalLog.reset()

      churn =
        spawn(fn ->
          Stream.repeatedly(fn ->
            Authority.revoke_domain("github.pr.draft")
            Authority.one_shot("github.pr.draft")
          end)
          |> Enum.take(20_000)
        end)

      Control.command(kestrel, cmd, args)
      Process.exit(churn, :kill)
      Process.sleep(120)

      recorded = Enum.filter(Ampd.RefusalLog.recent(60), &(&1["code"] == code))

      assert length(recorded) == 1,
             "#{cmd} recorded #{length(recorded)} #{code} refusals for one command — " <>
               "`kind: :read` was taken to mean safe-to-retry, and it does not"
    end
  end

  test "every read declares whether it may be executed more than once" do
    # Enforced at compile time in `Ampd.CommandSpec`; asserted here so the
    # classification itself is visible, and so a read moved into `:safe`
    # because a probe was inconvenient shows up as a change to this list.
    assert CommandSpec.retry_once() == [:inspect_refusal, :preflight]

    safe = CommandSpec.reads() -- CommandSpec.retry_once()
    assert :agent_projection in safe
    assert :operator_projection in safe
    assert :list_receipts in safe
  end

  test "an observation is ordered but is not an operation" do
    before = AuthorityCoordinator.ops()

    {cursor, v} = AuthorityCoordinator.observe(fn -> :looked end)

    assert v == :looked
    assert cursor["revision"] == before

    assert AuthorityCoordinator.ops() == before,
           "the pessimistic read path advanced the revision it was reporting — a cursor that " <>
             "changes because it was looked at makes every read a mutation, and every push a " <>
             "reason for another push"
  end

  test "the incarnation is 128 bits, not 64" do
    inc = World.incarnation()

    assert String.length(inc) == 32,
           "world_incarnation is #{String.length(inc) * 4} bits; it is about to be the identity " <>
             "a restored world is recognised by across machines"

    assert inc =~ ~r/^[0-9a-f]{32}$/
  end
end
