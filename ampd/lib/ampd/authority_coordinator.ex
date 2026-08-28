defmodule Ampd.AuthorityCoordinator do
  @moduledoc """
  The linearization point for authority.

  C1.0b claimed the TOCTOU window was closed by ordering. That claim was
  too broad, and the review narrowed it correctly: `Effects.claim/1`
  serializes **effects against effects**, but nothing serialized an effect
  against a *grant* mutation. This interleaving survived:

      decide under grant G / snapshot X
                    │
                    ├──── another process REVOKES G  (returns!)
                    │
                    ▼
      propose → claim → consume → adapter runs

  So an effect could execute using an authorization sampled before a
  revocation that had already completed.

  Every authority-changing command and every effect claim now passes
  through this one process, which gives them a total order:

                       AuthorityCoordinator
                               │
             ┌─────────────────┼─────────────────┐
        request_grant     revoke_grant      claim_effect
             └─────────────────┴─────────────────┘
                               │
                         TOTAL ORDER

  **CLAIM is the authority boundary.** Before the claim, revocation wins —
  the decision is re-taken inside the order, so a stale one cannot ride.
  After the claim, the effect holds an authority lease for its frozen
  snapshot, and a later revocation does not retroactively cancel an effect
  that may already have touched the world.

  This is logical atomicity over separate DETS stores. SQLite will later
  make it durable atomicity; the ordering semantics are pinned by vectors
  first so the port cannot quietly lose them.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    # **A fresh epoch per incarnation, because `seq` is not durable.**
    #
    # `ops/0` counts ordered mutations, and `Ampd.Subscriptions` publishes
    # that count as the projection revision. It resets to 0 when this
    # process restarts — while `world_generation` does not, because the
    # world on disk did not change. Reproduced:
    #
    #     world_generation 1 · revision 7
    #     AuthorityCoordinator killed and restarted
    #     world_generation 1 · revision 0
    #
    # A client holding `(generation 1, revision 7)` then receives
    # `(generation 1, revision 1)` and has no way to read it: same world,
    # smaller number. Treating it as a rollback is wrong and treating it as
    # an increment is worse.
    #
    # The epoch names the incarnation, so the tuple is total:
    #
    #     same generation, same epoch      → revisions are comparable
    #     same generation, new epoch       → discard the projection, resnapshot
    #     different generation             → discard everything
    #
    # A durable revision is the SQLite port's to give (C1.1b). This is the
    # cheap, honest version that does not pretend to be it.
    # **Two clocks, because the cockpit renders more than authority.**
    #
    # `seq` counts ordered authority mutations. `view` counts every change
    # a projection can *show* — which is a strictly larger set, and the
    # difference was a product bug: `operator-projection@2` carries `peers`,
    # `channels` and `recent_refusals`, none of which is under this process.
    # Measured before this existed:
    #
    #     subscribed · channels in view: 1
    #     an agent channel opens
    #     pushes received: 0 · revision 1 -> 1
    #     a fresh snapshot shows 2 channels; the subscriber still holds 1
    #
    # The cockpit sat LIVE LOCAL rendering a channel topology that was no
    # longer true, indefinitely, and nothing was wrong with any of it.
    #
    # The wrong fix is to call a connection opening an authority mutation so
    # the UI notices. A channel appearing must not rewrite authority
    # history. So: durable world truth above transient runtime presence,
    # two counters, and the stream is driven by the second.
    {:ok, %{seq: 0, epoch: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)},
     {:continue, :announce}}
  end

  # **A new runtime incarnation has to announce itself.**
  #
  # `:one_for_one` means this process can be replaced while `Ampd.Peer`,
  # `Ampd.Bridge`, `Ampd.Subscriptions` and every channel survive — so a
  # restart minted a new `projection_epoch` that nothing was told about.
  # Measured: after killing this process, zero pushes, the control channel
  # still alive and the subscription still registered. A host held the old
  # epoch and its old projection indefinitely, until some unrelated later
  # mutation happened to cause a push.
  #
  # `Continuity::NewRuntime` was therefore classifiable and not
  # *observable*: the host's enum knew what to do with an epoch change and
  # nothing ever delivered one.
  #
  # Announcing is all that is needed, and it must be **only** announcing:
  # closing the channel would be `NewIncarnation` behaviour, and the whole
  # value of the distinction is that a runtime restart keeps the person's
  # authority while a world discontinuity does not.
  @impl true
  def handle_continue(:announce, st) do
    if Process.whereis(Ampd.Subscriptions), do: Ampd.Subscriptions.changed()
    {:noreply, st}
  end

  @doc """
  Announce that something a projection can show has changed, without any
  authority having moved.

  A **cast**, and it has to be. `Ampd.Bridge.reset/0` is called from inside
  a coordinator transaction — see `Ampd.Authority.advance_lineage/2` — so a
  bridge that called this process synchronously would deadlock against the
  transaction that is calling it.

  Called by `Ampd.Peer`, `Ampd.Bridge` and `Ampd.RefusalLog`: the three
  sources of projection-visible state that are not authority.
  """
  def touched do
    # **Ticked here, synchronously, by the caller.** This used to cast to
    # this process, which meant the number lagged the state it claimed to
    # version — and could not be advanced at all while this process was
    # busy assembling the very frame that was supposed to be coherent. See
    # `Ampd.ViewClock`.
    Ampd.ViewClock.tick()
    if Process.whereis(Ampd.Subscriptions), do: Ampd.Subscriptions.changed()
    :ok
  end

  @doc """
  Run `fun` inside the total order.

  Re-entrant by design: code already executing *inside* the coordinator is
  already ordered, so it runs directly instead of calling into itself and
  deadlocking.
  """
  def transact(fun, expected_world \\ nil, timeout \\ 15_000) do
    if self() == Process.whereis(__MODULE__) do
      # Re-entrant: the outer transaction was fenced, and this runs inside
      # it. Checking again would compare the world to itself.
      fun.()
    else
      GenServer.call(__MODULE__, {:tx, fun, expected_world}, timeout)
    end
  end

  @doc """
  How many ordered operations this **incarnation** has performed.

  Not "this world" — that was the wording, and it was wrong in the way that
  matters: the count starts at zero again when this process restarts, and
  the world does not. Read it with `epoch/0`, never alone.
  """
  def ops, do: GenServer.call(__MODULE__, :ops)

  @doc "This incarnation's epoch. A revision is only comparable within one."
  def epoch, do: GenServer.call(__MODULE__, :epoch)

  @doc """
  Epoch and revision **in one sample**, because separately they can tear.

  `Ampd.Projection.continuity/0` used to call `epoch/0` and `ops/0` as two
  GenServer calls. A restart landing between them yields the *old* epoch
  with the *new* revision — which a client reads as a revision going
  backwards inside an epoch that never changed, exactly the fault the epoch
  was introduced to make impossible. It is a narrow window and it is not a
  theoretical one: this process is restarted by its supervisor.

  One call, one `st`, no window.
  """
  def cursor, do: GenServer.call(__MODULE__, :cursor)

  @doc """
  Run `fun` **in** the total order without being one of its operations, and
  return `{cursor, result}` sampled in the same handler.

  This is the pessimistic half of `Ampd.Projection.framed/2`, and it exists
  because the optimistic half starves. A seqlock that samples the cursor,
  builds, and compares can be defeated by a world that moves during every
  attempt — measured with a process issuing back-to-back grant edits, where
  **40 of 40** projection reads failed to settle. A busy world that cannot
  be observed is not an acceptable trade for a coherent cursor, and the
  cockpit's only input is this frame.

  So: try optimistically, and if it will not settle, come in here once. The
  cursor and the content cannot disagree because nothing can linearize
  between them.

  **`seq` does not move and subscribers are not notified.** A read is not
  an ordered mutation; counting one would make every projection advance the
  revision it is reporting, which is a cursor that changes because it was
  looked at.

  The cost is honest and is why this is the fallback rather than the path:
  `fun` here walks a dozen registry processes, and every authority mutation
  waits behind it.
  """
  def observe(fun, timeout \\ 15_000) do
    if self() == Process.whereis(__MODULE__) do
      {%{"projection_epoch" => nil, "revision" => nil}, fun.()}
    else
      GenServer.call(__MODULE__, {:observe, fun}, timeout)
    end
  end

  @doc """
  Observe **exactly once**, for a computation that may not be re-executed.

  **EXECUTION MULTIPLICITY IS AN EFFECT PROPERTY, AND EVERY LAYER THAT CAN
  RE-EXECUTE THE COMPUTATION MUST RECEIVE IT OR DISCHARGE IT.**

  `Ampd.CommandSpec` declares `retry: :safe | :once` because
  `Ampd.Refusal.new/2` records into `Ampd.RefusalLog` as it constructs, so a
  read that can refuse writes as it decides. `Ampd.Control` routes a
  `retry: :once` read to `Ampd.Projection.framed_once/2`, which skips the
  optimistic loop in `Projection` — and then handed the function to
  `observe/1`, which speculated again. The constraint was declared at the
  top, enforced at compile time, carried through one layer, and dropped at
  the next. Measured: `framed_once` with a function that moves the clock ran
  it **three** times.

  This is the layer that can actually re-execute, so this is the layer that
  has to be told.

  **The cursor guarantee is not weakened, only its optimisation.** The
  unconditional property is that the cursor is never older than the state
  the content represents, and that comes from sampling *after* the content —
  see `sample_after/2`. `observe/1`'s bounded rebuild converts the common
  case from conservative to exact, and it is a real optimisation for a read
  with no side effect. For an `:once` operation, **at-most-once outranks
  cursor exactness**, so the rebuild is what gives way.
  """
  def observe_once(fun, timeout \\ 15_000) do
    if self() == Process.whereis(__MODULE__) do
      {%{"projection_epoch" => nil, "revision" => nil}, fun.()}
    else
      GenServer.call(__MODULE__, {:observe_once, fun}, timeout)
    end
  end

  @impl true
  def handle_call({:tx, fun, expected}, _from, st) do
    current = Ampd.World.lineage()

    if stale_incarnation?(expected, current) do
      # **The fence, and it has to be here.**
      #
      # Not at submission: a connection paused between resolving its peer
      # and issuing its command would sample the world that replaced its
      # own and launder itself into it. Here is the linearization point —
      # a reset queued ahead of this message has already run, so `current`
      # is the new world and `expected` is the one the channel was bound
      # in.
      #
      # Measured before this existed: `Ampd.Peer` suspended is not needed,
      # only ordering. A reset and a `kestrel` `request_grant` queued
      # behind it, and the request arrived in the world the reset created
      # — actor, capability and reason intact, in a world that never had a
      # kestrel. Killing the connection does not retract a message already
      # in another process's mailbox.
      {:reply, {:refused, stale_world(expected, current)}, st}
    else
      run(fun, st)
    end
  end


  def handle_call(:ops, _from, st), do: {:reply, st.seq, st}
  def handle_call(:epoch, _from, st), do: {:reply, st.epoch, st}

  def handle_call(:cursor, _from, st), do: {:reply, cursor_of(st), st}

  # No `st.seq + 1` and no `Ampd.Subscriptions.changed/0`: an observation is
  # ordered, not performed.
  #
  # **The cursor is sampled after the content, and this is the whole
  # correctness argument for the view clock.**
  #
  # Being inside the total order stops *authority* moving during the build.
  # It cannot stop `Ampd.Peer`, `Ampd.Bridge` or `Ampd.RefusalLog` moving,
  # because they are deliberately outside it — so a cursor sampled first
  # can name a view older than the content beside it, which is the one
  # direction that hurts: a client told `V` about content from `V+1`
  # believes it has already seen the newer state.
  #
  # Sampling after inverts that. The frame's `view_revision` is always
  # **≥** the version of everything in it. The loop then converts the
  # common case from safe to exact, without a lock over three processes
  # that would have to be held for the length of a projection.
  def handle_call({:observe, fun}, _from, st), do: {:reply, coherent(fun, st, 3), st}

  # **NOT `coherent(fun, st, 1)`.** That would be correct today and would
  # break silently the day anyone changes what the bound means — the
  # at-most-once guarantee would then depend on an integer read two
  # functions away. A computation that may run once gets a body with no
  # loop in it, so there is nothing to get wrong.
  def handle_call({:observe_once, fun}, _from, st), do: {:reply, once(fun, st), st}

  defp once(fun, st) do
    content = fun.()
    # Sampled AFTER the content, exactly as `coherent/3` does, because that
    # is where the guarantee comes from. What is given up is the retry that
    # made the label exact in the common case, not the bound that makes it
    # sound in every case.
    {sample_after(st, nil), content}
  end

  defp coherent(fun, st, attempts) do
    before = Ampd.ViewClock.read()
    content = fun.()
    cursor = sample_after(st, before)

    if cursor["view_revision"] == before or attempts <= 1,
      do: {cursor, content},
      else: coherent(fun, st, attempts - 1)
  end

  # **The sample point, on its own line, because it is the claim.** Taking
  # the cursor before `fun.()` is what produced `view_revision 2` beside
  # content belonging to view 3; taking it after makes the label a bound on
  # the content rather than a guess about it.
  defp sample_after(st, _before), do: cursor_of(st)

  # `revision` is the **authority** revision and keeps its name because it
  # is on the wire and in the vectors. `view_revision` is what a client
  # compares to decide whether it is looking at something new — see
  # `Ampd.Projection.continuity/0`. Keeping both means a frame still says
  # which durable authority state it is based on, as evidence, while the
  # stream is driven by what actually changed on screen.
  defp cursor_of(st),
    do: %{"projection_epoch" => st.epoch, "revision" => st.seq,
          "view_revision" => Ampd.ViewClock.read()}

  defp run(fun, st) do
    result = fun.()

    # Every authority mutation passes through here, so this is the one
    # place that can say "the world moved" without a poller. The re-entrant
    # path above returns before this clause, so a nested transaction does
    # not announce a second time — one ordered operation, one revision.
    #
    # `cast`, and after the work: a coordinator that blocked on notifying
    # subscribers would make the total order as slow as its slowest socket.
    if Process.whereis(Ampd.Subscriptions), do: Ampd.Subscriptions.changed()

    # Both clocks: an authority mutation is also, always, a visible change.
    Ampd.ViewClock.tick()
    {:reply, result, %{st | seq: st.seq + 1}}
  end

  # Named for what happened, not for what is missing. An operation that was
  # valid when it was issued and got overtaken by a world discontinuity is a
  # different thing from one that never had an identity, and `unknown-peer`
  # would have said the second.
  #
  # **The whole incarnation — installation *and* generation.**
  #
  # F.8.2.4 narrowed this to the installation, and the narrowing was wrong.
  # The reasoning offered was that a generation advance leaves the actor
  # named and the stores in place, so a channel could keep operating. But
  # `Ampd.World`'s own definition says generation moves only when durable
  # truth is **wholesale replaced or discontinuously changed** — restore,
  # import, factory re-initialization. That is precisely the statement that
  # the authority basis after the advance is not the one before it, so a
  # command formed against the old basis has nothing left to be true about.
  #
  # The consent argument was real and insufficient. Pre-discontinuity
  # *approvals* are already dead, per-approval, via the lineage inside the
  # intent digest — `test/lineage_test.exs` proves that and it still holds.
  # Stale *commands* are a different law:
  #
  #     old consent cannot survive a restore
  #       does not imply
  #     old work may safely cross one
  #
  # A queued `request_grant` has no approval to invalidate; it simply opens
  # a brand-new request in the restored world, on behalf of an actor that
  # world may never have named. A queued `request_effect` re-decides against
  # restored authority. Both are the F.8.2.3 bug with one lineage component
  # held constant.
  #
  # The hierarchy this buys is the one worth reasoning about:
  #
  #     installation_id changes   → a different world installation
  #     generation changes        → a discontinuous incarnation of this one
  #                                 · old channels invalid, authority reacquired
  #     projection_epoch changes  → same incarnation, new runtime · resnapshot
  #     revision changes          → ordinary mutation
  #
  # It is only safe because the other half shipped with it:
  # `Ampd.Authority.advance_lineage/2` now closes every channel bound to the
  # ending incarnation. Fencing on generation *without* that barrier would
  # leave live channels permanently unable to act with nothing torn down and
  # nothing told, which was F.8.2.4's stated reason for backing off. The
  # answer was to build the barrier, not to weaken the fence.
  defp stale_incarnation?(nil, _current), do: false
  defp stale_incarnation?(_expected, nil), do: true

  defp stale_incarnation?(expected, current) do
    expected["installation_id"] != current["installation_id"] or
      expected["generation"] != current["generation"]
  end

  defp stale_world(expected, current) do
    installation_changed = expected["installation_id"] != (current && current["installation_id"])

    Ampd.Refusal.new("world-incarnation-changed",
      component: "Ampd.AuthorityCoordinator",
      retryable: false,
      requires_human: false,
      public_message: "The world this channel belongs to no longer exists.",
      operator_detail: %{
        "expected_generation" => expected["generation"],
        "current_generation" => current && current["generation"],
        "installation_changed" => installation_changed,
        # Which half moved, because the remediations differ. A different
        # installation is a different world and there is nothing to
        # reacquire; a generation advance is this world's next incarnation,
        # and the host reattaches to it.
        "discontinuity" => if(installation_changed, do: "installation", else: "generation"),
        "hint" =>
          "this command was issued by a channel bound to an earlier incarnation of the " <>
            "world and reached the coordinator after that incarnation ended — it is " <>
            "refused rather than executed against a world that never granted it anything"
      }
    )
  end
end
