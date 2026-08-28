defmodule Ampd.Projection do
  @moduledoc """
  One world, three projections.

  `projection@1` returned every active grant, every pending approval, the
  whole effect journal, every receipt, the reconcile queue, the authority
  snapshot, and the seal list — to whoever asked. That is the right answer
  for exactly one caller, the Super control room, and the wrong answer for
  every other one. A receipt names a resource and a placement; the grant
  list is a map of what every actor on this machine may do; the seal list
  is recovery topology.

  `refusal@1` already had this right — one underlying truth, two
  projections, chosen by channel rather than by trimming at the call site.
  This is the same move applied to the world state:

      operator-projection@1   the control room. Everything, plus the
                              things only an operator can act on: peers,
                              grant requests, seals, recent refusals.

      agent-projection@1      one actor's own world. Its identity, its
                              grants, its requests, its approvals, its
                              effects, its receipts, the current
                              workspace and run, and public health.
                              Nothing belonging to another actor, and no
                              recovery detail.

      runtime-status@1        health, for a caller with no identity at
                              all. Three words and a version.

  The filter is `actor`, and it is the actor the **runtime** assigned —
  see `Ampd.Peer`. An agent-projection is not a projection an agent asks
  for; it is the projection its channel is capable of receiving.
  """
  alias Ampd.{Approvals, Effects, GrantRegistry, Receipts, Session}

  # How much history rides along in a live projection. Not a guess at what
  # fits — a statement about what a control room can act on. The rest is a
  # cursor away.
  @history_window 50

  @doc "How many history entries a live projection carries."
  def history_window, do: @history_window

  @doc """
  The control room's view. Human control channel only.

  **Bounded, and explicit about it.** `operator-projection@1` carried every
  effect and every receipt this world had ever produced. Both grow without
  limit in a *healthy* world — a receipt is written for every committed
  effect and nothing ever removes one — so the live projection was on a
  path to exceeding one frame by ordinary use, at which point the channel
  received `frame-too-large` instead of a world. Refusing is honest and
  leaves an operator with nothing.

  Neither raising the limit nor quietly dropping the tail is the answer:
  the first postpones it, and the second is a projection that lies by
  omission. So the live projection carries **current actionable truth** in
  full — active grants, pending requests and approvals, in-flight effects,
  the reconcile queue, peers, seals — and history as a window that says how
  much it is a window onto:

      receipts: %{recent: [...], total: 18_421, next_cursor: "rcpt-18191"}

  A projection saying *total 18 421, showing the newest 50, more: true* is
  not lying by omission. It is an explicit bounded projection, and the rest
  is `list_receipts`.
  """
  def operator do
    %{
      "schema" => "operator-projection@2",
      "workspace" => Session.ctx()["workspace"],
      "run" => Session.run(),
      "world" => world_block(),

      # --- live: everything an operator can act on, in full -------------
      "grants" => Enum.filter(GrantRegistry.list(), &(&1["status"] == "active")),
      "grant_requests" => Enum.filter(GrantRegistry.requests(), &(&1["status"] == "pending")),
      # Resolved requests are provenance — "Kestrel asked, the person said
      # no" is exactly what this system exists to keep distinguishable — and
      # they also grow without a human ever acting, because an agent can
      # ask as often as it likes. So: kept, and windowed.
      "grant_requests_history" =>
        GrantRegistry.requests() |> Enum.reject(&(&1["status"] == "pending")) |> window(),
      "authority_snapshot" => GrantRegistry.snapshot(),
      "pending_approvals" => Enum.filter(Approvals.all(), &(&1["status"] == "pending")),
      "effects" => Enum.reject(Effects.all(), &Effects.terminal?/1),
      "reconcile_queue" => Enum.map(Effects.reconcile_queue(), & &1["id"]),
      "peers" => Ampd.Peer.list(),
      "channels" => Ampd.Bridge.list(),
      "recent_refusals" => Ampd.RefusalLog.recent(20),
      "seals" => Enum.map(Ampd.seals(), fn {m, reason} -> %{"registry" => inspect(m), "reason" => reason} end),
      "runtime" => runtime_status(),

      # --- history: a window, and the size of what it looks onto --------
      "receipts" => window(Receipts.all()),
      "effects_history" => window(Enum.filter(Effects.all(), &Effects.terminal?/1))
    }
  end

  @doc """
  A page of history, newest first.

  **`cursor` is the last item already seen**; a page returns entries
  strictly older than it. Absent means start at the newest.

  That is not the semantics this had, and the difference lost a record per
  page. `next_cursor` used to be the *first omitted* item while the fetch
  dropped everything `>= cursor` — which drops the cursor itself:

      page 1   rcpt-0120 … rcpt-0071   next_cursor: rcpt-0070
      page 2   rcpt-0069 … rcpt-0020   ← rcpt-0070 is gone

  Reproduced over 120 records: 118 returned, `rcpt-0070` and `rcpt-0019`
  skipped. The test that was supposed to catch it asserted the pages did
  not *overlap* and did not *repeat* — never that they did not have a hole
  in them, so it passed while evidence was being dropped.

  Evidence paging has to be lossless: concatenating every page must equal
  the history exactly once. There is a falsifier that asserts precisely
  that now, rather than the two weaker properties.

  **The cursor is not attached here.** This builds the page and nothing
  else; `Ampd.Control` assembles it under `framed/2`, which is the only
  thing that can promise the four continuity fields describe the page
  beside them. Merging `continuity/0` in at the bottom of this function is
  what it used to do, and it is the defect: the cursor was sampled before
  the caller had even fetched the list.

  A client still always knows **which world it paged** — a page from before
  a restore stitched onto one from after it would be a history that never
  happened — and now it also knows the revision on the frame is the
  revision of the frame.
  """
  def page(list, cursor, limit) do
    limit = limit |> min(200) |> max(1)
    sorted = Enum.sort_by(list, & &1["id"], :desc)

    from =
      case cursor do
        nil -> sorted
        c -> Enum.drop_while(sorted, &(&1["id"] >= c))
      end

    items = Enum.take(from, limit)
    more? = length(from) > limit

    %{
      "schema" => "history-page@1",
      "items" => items,
      "total" => length(sorted),
      "returned" => length(items),
      "more" => more?,
      # The last item handed over, so the next fetch resumes strictly after
      # it. `nil` when there is nothing after it to resume from.
      "next_cursor" => if(more?, do: List.last(items)["id"], else: nil)
    }
  end

  # The newest `@history_window`, and the honest size of the rest.
  #
  # `next_cursor` is the last item *shown*, matching `page/3` — the cursor
  # is always "what you have already seen", never "what comes next". The
  # two disagreeing is what lost a record per page.
  defp window(list) do
    sorted = Enum.sort_by(list, & &1["id"], :desc)
    recent = Enum.take(sorted, @history_window)
    more? = length(sorted) > @history_window

    %{
      "recent" => recent,
      "total" => length(sorted),
      "next_cursor" => if(more?, do: List.last(recent)["id"], else: nil),
      "more" => more?
    }
  end

  @doc """
  One actor's own world.

  Every list here is filtered by `actor`. The authority snapshot is
  **not** included: it is a digest over every grant on the machine, so
  watching it change is a side channel onto authority the caller cannot
  see. The snapshots that authorized this actor's own effects are on its
  own approvals and receipts, where they are evidence rather than a probe.
  """
  def agent(actor) when is_binary(actor) do
    mine = fn list -> Enum.filter(list, &(&1["actor"] == actor)) end

    %{
      "schema" => "agent-projection@2",
      "actor" => actor,
      "workspace" => Session.ctx()["workspace"],
      "run" => Session.run(),
      "grants" =>
        Enum.filter(GrantRegistry.list(), &(&1["status"] == "active" and &1["actor"] == actor)),
      # **Symmetric with the operator's**, and for the same reason. This
      # carried every request the actor had ever made, pending or resolved
      # — and an agent can request-and-resolve without limit, so it could
      # grow its own projection past the frame by itself. That is exactly
      # the healthy-world failure the windows exist to remove, left in the
      # one projection an untrusted party controls the size of.
      "grant_requests" =>
        GrantRegistry.requests() |> mine.() |> Enum.filter(&(&1["status"] == "pending")),
      "grant_requests_history" =>
        GrantRegistry.requests() |> mine.() |> Enum.reject(&(&1["status"] == "pending")) |> window(),
      "pending_approvals" =>
        Enum.filter(Approvals.all(), &(&1["status"] == "pending" and &1["actor"] == actor)),
      # Bounded for the same reason the operator's is: an agent's own
      # receipts also only ever grow.
      "effects" => Effects.all() |> mine.() |> Enum.reject(&Effects.terminal?/1),
      "effects_history" => Effects.all() |> mine.() |> Enum.filter(&Effects.terminal?/1) |> window(),
      "receipts" => Receipts.all() |> mine.() |> window(),
      "runtime" => runtime_status()
    }
  end

  @doc """
  One actor's history, for the paged commands. `nil` means the operator,
  who has no actor and therefore sees the world's.

  Every window a projection hands out has a `next_cursor`, and every one of
  them needs a command that can follow it — a cursor with nothing to give
  it to is a promise the protocol does not keep.
  """
  def history_for(:receipts, nil), do: Receipts.all()
  def history_for(:receipts, actor), do: Enum.filter(Receipts.all(), &(&1["actor"] == actor))

  def history_for(:effects, nil), do: Enum.filter(Effects.all(), &Effects.terminal?/1)

  def history_for(:effects, actor),
    do: Enum.filter(Effects.all(), &(Effects.terminal?(&1) and &1["actor"] == actor))

  def history_for(:grant_requests, nil),
    do: Enum.reject(GrantRegistry.requests(), &(&1["status"] == "pending"))

  def history_for(:grant_requests, actor),
    do:
      GrantRegistry.requests()
      |> Enum.reject(&(&1["status"] == "pending"))
      |> Enum.filter(&(&1["actor"] == actor))

  @doc """
  The **four** fields that say which world, and how current.

  They travel together on every frame that carries any of them, because
  none of them means anything alone:

      world_incarnation  WHICH world. H(installation ‖ generation).
      world_generation   the chapter within this installation.
      projection_epoch   this runtime incarnation. Changes on a restart.
      revision           ordered AUTHORITY mutations within this epoch.
      view_revision      everything a projection can SHOW, within this
                         epoch — authority, plus peers, channels and
                         refusals, which are not authority at all.

  **Two clocks, and the second is the one a client compares.** `revision`
  answers *which durable authority state is this based on* and rides along
  as evidence; `view_revision` answers *is this newer than what I am
  rendering*. They were one field, and the difference was a product bug:
  an agent channel opening changes `peers` and `channels` in
  `operator-projection@2` and performs no authority transaction, so the
  cockpit sat LIVE LOCAL rendering a topology that was no longer true.
  Making a connection count as an authority mutation would have fixed the
  symptom by rewriting authority history, which is the wrong direction:
  durable world truth sits above transient runtime presence.

  The client rule is total, and it is a hierarchy rather than a list:

      different incarnation         → a different world · discard everything,
                                      the authority you hold is not valid here
      same incarnation, new epoch   → same world, new runtime · resnapshot
      same incarnation and epoch    → view revisions are comparable
      lower or equal view_revision  → already seen · ignore

  This said *"the three fields"* and named `world_generation` as the
  identity for two revisions after F.8.2.4 made `world_incarnation` the
  first field and the identity. Stale prose becomes stale tests, so it is
  corrected rather than left to be discovered.

  **This is a cursor, unattached to any content.** A frame that carries
  both a cursor and a projection must be built by `framed/2`, which is the
  only thing that can promise they describe the same moment.
  """
  def continuity do
    # One read of the manifest for both world fields, and one call to the
    # coordinator for both runtime fields. Four independent samples is what
    # this was, and two of the four pairs could disagree with each other.
    lin = lineage()

    Map.merge(
      %{
        "world_incarnation" => Ampd.World.incarnation_of(lin),
        "world_generation" => lin && lin["generation"]
      },
      cursor()
    )
  end

  # A coordinator that is not running yet reads as epoch nil / revision 0
  # rather than crashing a caller that connected during boot.
  defp cursor do
    if Process.whereis(Ampd.AuthorityCoordinator),
      do: Ampd.AuthorityCoordinator.cursor(),
      else: %{"projection_epoch" => nil, "revision" => 0}
  end

  defp lineage do
    Ampd.World.lineage()
  rescue
    _ -> nil
  end

  @doc """
  Assemble a frame whose cursor describes the content beside it.

  **A cursor sampled before the content is a label, not a measurement.**
  `Ampd.Subscriptions.build/1` merged `continuity/0` with a separately
  built projection, and `page/3` did the same. Elixir evaluates the cursor
  first, so any ordered mutation landing during the build produces a frame
  whose revision is older than what it contains. Measured, with
  `Ampd.Session` suspended to park the build between the two:

      snapshot cursor revision : 1
      revision now             : 2
      the revoked grant        : absent from the projection

  A frame saying *revision 1* while showing revision 2's authority is worse
  than a stale frame. A client that trusts the cursor believes it has
  already seen this state, so the correction never arrives — and the
  correction here is a grant that was revoked.

  So: sample, build, sample again, and accept only if nothing moved. Every
  discontinuity is caught by the same comparison, which is the useful part
  — an ordered mutation moves `revision`, a coordinator restart moves
  `projection_epoch`, and a lineage advance moves `world_incarnation`.
  One primitive, used as a read-side seqlock.

  ## Optimistic, then once pessimistically — because a seqlock starves

  A retry loop alone is defeated by a world that moves during every
  attempt. Measured with one process issuing back-to-back grant edits:
  **40 of 40** projection reads failed to settle, and refusing them by name
  is not a fix. A busy world that cannot be observed is a worse product
  than a slow one, and the cockpit has no other input.

  So the last attempt is `Ampd.AuthorityCoordinator.observe/1`, which
  assembles the frame *inside* the total order — where nothing can
  linearize between the cursor and the content, so there is nothing to
  compare. It is the fallback rather than the path because it makes every
  authority mutation wait behind a dozen registry reads.

  This is also why there is no `projection-unstable` refusal. There was
  one, and the fallback made it unreachable: a code no input can produce is
  a promise to an operator that nothing keeps.

  `expected` is the peer's bind-time lineage, or `nil` for callers that are
  not a peer. When given, the incarnation is checked at entry, and again by
  the before/after comparison — a lineage advance moves `world_incarnation`
  and so fails it. Checking only at entry leaves the window where the world
  advances *during* the build and the frame is assembled out of the
  incarnation that replaced the caller's own.
  """
  @framed_attempts 3

  def framed(expected, fun), do: do_framed(expected, fun, @framed_attempts)

  @doc """
  Assemble a frame **without speculating** — straight to the ordered path.

  `kind: :read` was taken to mean *safe to re-run*, and it does not.
  `Ampd.Refusal.new/2` records into `Ampd.RefusalLog` as it constructs, so
  a read that can refuse is a read with a side effect, and the optimistic
  loop runs `fun` up to four times. Measured, for **one** client command
  under churn:

      preflight (denied)      refusals recorded by ONE command: 4
      inspect_refusal (404)   refusals recorded by ONE command: 4
      agent_projection        refusals recorded by ONE command: 0
      list_receipts           refusals recorded by ONE command: 0

  The ring is bounded so nothing grows without limit; what it destroys is
  the diagnostic meaning of the ring, and it evicts real refusals four
  times faster than the world produced them. It also breaks the implication
  the seqlock had just started relying on.

  So `Ampd.CommandSpec` declares `retry:` beside `kind:`, and a
  `retry: :once` read comes here: one execution, inside the total order,
  where the cursor and the content cannot disagree anyway. The
  speculation was only ever an optimisation, and it is the wrong one for a
  command that writes as it decides.
  """
  def framed_once(expected, fun), do: do_framed(expected, fun, 0)

  defp do_framed(expected, fun, attempts) do
    case fence(expected) do
      nil when attempts > 0 ->
        before = continuity()
        content = fun.()
        now = continuity()

        # Nothing moved: the cursor describes what is beside it.
        if now == before,
          do: Map.merge(before, content),
          else: do_framed(expected, fun, attempts - 1)

      nil ->
        # The ordered path samples its cursor *after* the content — see
        # `Ampd.AuthorityCoordinator.handle_call({:observe, …})`. So the
        # `view_revision` on the frame is never older than what is in it.
        #
        # **AND THE MULTIPLICITY CONSTRAINT TRAVELS WITH IT** — see
        # `ordered_observe/2` below.
        {cursor, content} = ordered_observe(attempts, fun)

        # The world half is still read outside the order — the manifest is
        # a file, not this process's state. It is re-fenced afterwards for
        # the same reason the optimistic path compares: a lineage advance
        # during the build must not be labelled as anything but itself.
        lin = lineage()

        case fence(expected) do
          nil ->
            Map.merge(
              %{
                "world_incarnation" => Ampd.World.incarnation_of(lin),
                "world_generation" => lin && lin["generation"]
              },
              Map.merge(cursor, content)
            )

          refused ->
            refused
        end

      refused ->
        refused
    end
  end

  # **THE ORDERED CALL IS ONE LINE PER CLAUSE, AND THAT IS THE POINT.**
  #
  # `attempts == 0` is how `framed_once/2` says *this function may not be
  # re-run*, and until W.1.4 that fact stopped at this call: the
  # coordinator's `observe/1` speculated three more times, one abstraction
  # boundary below the layer that had just refused to. A property declared
  # at the top and dropped at the next layer down is not a property, and
  # this arc has now found that shape three times — projection scope, claim
  # validity, and here.
  #
  # W.1.4's first attempt inlined the choice as a three-line `if` at the
  # call site, and `ampd/tools/sabotage.sh` came back **SABOTAGE MISSED**:
  # its probes are `sed -i` expressions, so a fix spread over three lines
  # cannot be stubbed by one, and the law "a busy world is observed
  # coherently" silently lost its falsifier. `cursorEq` and `stabilityToken`
  # are one line for the same reason. **A fix that must be falsifiable has
  # to fit on a line a probe can name.**
  defp ordered_observe(0, fun), do: Ampd.AuthorityCoordinator.observe_once(fun)
  defp ordered_observe(_, fun), do: Ampd.AuthorityCoordinator.observe(fun)

  @doc """
  Whether a peer bound to `expected` may be answered at all — `nil` when it
  may, a refusal result when its incarnation has ended.

  **The read fence, and it is a separate check from the authority one.**
  `Ampd.AuthorityCoordinator` refuses a stale *mutation* at the
  linearization point, which is the right place for a write and reaches
  nothing that does not call `Ampd.Authority.tx/1`. A projection, a
  preflight, a history page and a subscription all reach none of it, and
  commands on the `:both` channel did not even carry the peer's lineage
  into the process dictionary. So this held, deterministically, in the
  window a lineage advance opens between its durable bump and its channel
  barrier:

      GEN-1 CHANNEL
        ├── request_grant     → world-incarnation-changed
        └── agent_projection  → served, out of generation 2

  Refused for mutation and served for information is the exact asymmetry
  `Ampd.Subscriptions` already removed once, for a cached identity. This is
  the same law one level up: **a peer-bound command may return information
  only from the incarnation that peer belongs to.**
  """
  # **Answered from the manifest, never from the coordinator.**
  #
  # The first version of this compared against `continuity/0`, which calls
  # `Ampd.AuthorityCoordinator.cursor/0` — and that is exactly backwards:
  # the transaction most likely to have ended a channel's incarnation is a
  # lineage advance, and a lineage advance *holds the coordinator* while it
  # tears channels down. So a fence that has to ask the coordinator cannot
  # answer during the one operation it exists for; it blocks behind it.
  # Every queued-work witness in F.8.2.5 stopped reaching the coordinator
  # at all, because the fence in front of them was waiting on it.
  #
  # The incarnation is a file. Reading it needs no process to be free.
  def fence(nil), do: nil

  def fence(expected) do
    current = Ampd.World.incarnation()

    if Ampd.World.incarnation_of(expected) == current,
      do: nil,
      else: unstable(:incarnation, %{"world_incarnation" => current}, nil)
  end

  defp unstable(:incarnation, now, _) do
    %{
      "allow" => false,
      "reason" => "The world this channel belongs to no longer exists.",
      "refusal" =>
        Ampd.Refusal.new("world-incarnation-changed",
          component: "Ampd.Projection",
          retryable: false,
          requires_human: false,
          public_message: "The world this channel belongs to no longer exists.",
          operator_detail: %{
            "current_incarnation" => now["world_incarnation"],
            "discontinuity" => "generation",
            "hint" =>
              "a read is fenced to the incarnation its channel was bound to, exactly as a " <>
                "mutation is — a projection assembled out of the world that replaced this " <>
                "channel's own would be information crossing a boundary authority cannot"
          }
        )
    }
  end


  @doc """
  Health for a caller with no identity.

  `status` is `"healthy"` or `"sealed"`. `"down"` is in the vocabulary and
  is never returned: a runtime that answers is not down, so `"down"` is
  what a caller concludes from **no answer**. Naming it here is the
  difference between a client that knows silence is a state and one that
  hangs waiting for a fourth value.
  """
  def runtime_status do
    %{
      "schema" => "runtime-status@1",
      "status" => if(Ampd.seals() == [], do: "healthy", else: "sealed"),
      "version" => to_string(Application.spec(:ampd, :vsn) || "0"),
      "world_loaded" => Ampd.World.initialized?()
    }
  end

  # World identity and lineage — operator only. `installation_id` and
  # `generation` are what consent binds to, so they are also what tells an
  # observer when this machine was last restored.
  defp world_block do
    %{
      "manifest_state" => to_string(Ampd.World.manifest_state()),
      "lineage" => Ampd.World.lineage(),
      "schema_version" => Ampd.World.schema_version(),
      "invalid_fields" => Ampd.World.invalid_fields()
    }
  end
end
