defmodule Ampd.Carrier do
  @moduledoc """
  D.1.3b·2 — under what conditions a running process becomes a Worker's
  execution Carrier.

  D.1.3b·1 built a real confined OS process. It proves nothing about
  membership: the process exists, and existence is not authority. This module
  is the admission.

  ## Peer is not Carrier

  D.1.2 used the word *Carrier* for the authenticated peer/session that
  occupies a Locus. D.1.3b·1 produced an actual OS execution process and the
  same word would now name two different objects. The distinction, from here
  on:

      Peer     an authenticated control/session incarnation, which is what
               establishes explicit occupancy of a Locus

      Carrier  an ephemeral OS execution embodiment fulfilling the Worker
               assigned at that occupied Locus

      Actor → Peer/session → (occupancy) → Locus → Worker → Carrier → Motor

  D.1.2's identifiers are frozen and are not renamed here; `Ampd.Peer`'s
  `carrier-attachment@1` keeps its name. What changes is that new code means
  *execution* by "Carrier", and that

      Worker · OCCUPIED     ∧     Carrier · OFFLINE

  is a **legitimate and expected state**, not a fault: an actor holds the
  position and no execution process is presently running. Occupancy and
  execution are not synonyms and the cockpit must not render them as one.

  ## Ordered admit → unordered machine → ordered commit

  `Ampd.Worktree` names this shape in prose and declines to build it, because
  doing it there would mean moving `:create` out of `@ordered_ops` and
  changing the ordered-authority boundary itself. A Carrier can be built in
  the right shape from the start, and must be: a worktree creation takes
  seconds, a Carrier may live for days, and nothing that long-lived can sit
  inside a 15-second total order.

      TRANSACTION A          admit_start/2      ordered
        ↓                    a start ticket, durable
      MACHINE PHASE          machine_start/1    NOT ordered
        ↓                    spawn, handshake, observe
      TRANSACTION B          commit_start/2     ordered
                             re-derive, then join or refuse

  **Two ordinary ordered operations, not a coordinator primitive.** There is
  exactly one consumer of this shape today. Teaching
  `Ampd.AuthorityCoordinator` a generic `prepare/resume/commit/abort` protocol
  now would be designing for Worktree creation, Motor startup and future
  machine effects before knowing which parts they actually share. If the next
  two reproduce this structure independently, extract it then.

  ## The ticket is evidence, never permission

  `carrier-start-ticket@1` records what was true at admission. `commit_start/2`
  **re-reads every basis** and compares; it never trusts the snapshot. The
  ticket exists so that the commit can tell *what changed*, not so that it can
  skip looking.

  This is the same law three slices have now needed:

      existence is not authority          D.1.1
      identity is not position            D.1.2
      naming is not possession            D.1.3a
      a successful spawn is not admission D.1.3b

  ## Losing the runtime incarnation terminates the Carrier

  A live Carrier belongs to the `Ampd.Peer` incarnation that admitted it. If
  that incarnation is lost — supervisor restart, world reset, lineage advance
  — the Carrier's membership ends and the host reaps the process. There is
  deliberately **no survival across a control-plane restart** and therefore no
  persistent Carrier-recovery registry: replacement requires a new Peer, a new
  explicit occupancy, a new admission and a new incarnation. A recovery
  protocol can be designed when something needs one.
  """

  alias Ampd.{AuthorityCoordinator, Core, Loci, Locus, Peer, Refusal, Worker, World}

  @ticket_schema "carrier-start-ticket@1"
  @incarnation_schema "carrier-incarnation@1"
  @collection "carrier_attempts"

  # The durable attempt states.
  #
  # `RUNNING` is deliberately absent: a durable record must never be able to
  # make a process current. Currency lives in `Ampd.Peer`, is ephemeral, and
  # dies with the incarnation that admitted it — `E14` writes a COMMITTED
  # attempt straight to disk and asserts the projection still reads OFFLINE.
  #
  # `OBSERVED` was here and is gone. Nothing ever wrote it: the machine phase
  # returns an observation to the caller rather than parking it in the store,
  # so there is no instant at which an attempt is observed-but-not-decided.
  # A state with no executable distinction is a state a reader has to be told
  # to ignore.
  @attempt_states ~w(START_ADMITTED COMMITTED STALE FAILED INDETERMINATE)
  def attempt_states, do: @attempt_states

  # Projected Carrier status. `OFFLINE` is the answer for an occupied Worker
  # with no live Carrier, which is ordinary.
  @statuses ~w(OFFLINE STARTING RUNNING)
  def statuses, do: @statuses

  @doc "The schema names this module owns."
  def schemas, do: [@ticket_schema, @incarnation_schema]
  def collection, do: @collection

  # ------------------------------------------------------------------ A
  @doc """
  Transaction A. Re-derive every basis, mint a ticket, persist the attempt,
  and release the order.

  Returns `{:ok, ticket}` or `{:refused, refusal}`. **On refusal no machine
  request is made at all** — the host is never asked to spawn anything, which
  is the property falsifier `E1` exists to prove. The alternative shape, where
  the host is asked and then told to stop, would make a refusal something the
  machine has to be trusted to honour.
  """
  def admit_start(peer_ref, lane_ref) when is_binary(peer_ref) and is_binary(lane_ref) do
    AuthorityCoordinator.transact(fn -> admit(Peer.resolve(peer_ref), lane_ref) end)
  end

  defp admit(nil, _lane_ref), do: {:refused, refuse("carrier-peer-gone", %{})}

  defp admit(peer, lane_ref) do
    lane = Loci.lane(lane_ref)

    with :ok <- lane_known(lane),
         # Occupancy first, and the whole of it. `Ampd.Worker.occupancy/2` is
         # the one place that knows what occupying a Locus means, and it
         # already grades disclosure so a stranger learns only that they do
         # not hold it. Re-implementing any part of it here would be a second
         # opinion on the question D.1.2 exists to answer.
         :ok <- Worker.occupancy(peer, lane),
         {:ok, worker} <- current_worker(peer, lane),
         :ok <- no_live_carrier(peer),
         :ok <- no_pending_attempt(worker["id"]) do
      att = Peer.attachment(peer["id"])

      ticket = %{
        "schema" => @ticket_schema,
        "ticket_id" => mint("ct_"),
        "carrier_ref" => mint("cr_"),
        # Minted here and echoed by the Carrier, never chosen by it — the
        # same reason D.1.3a mints the channel epoch host-side.
        "carrier_epoch" => :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower),
        "worker_ref" => worker["id"],
        "locus_ref" => lane["id"],
        "peer_ref" => peer["id"],
        "peer_epoch" => att["peer_epoch"],
        "actor" => peer["actor"],
        "world_ref" => World.lineage(),
        "worker_generation" => worker["generation"] || 1,
        # Two bases, not one. `profile_basis` is the worktree/host embodiment
        # profile and stays what it is; the Carrier runs under a confinement
        # floor that is a different object with its own version, and
        # conflating them would mean a change to either silently stood for a
        # change to the other.
        "profile_basis" => Locus.profile_digest(),
        "floor_basis" => Ampd.Carrier.Floor.digest(),
        "state" => "START_ADMITTED",
        "admitted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      # Durable **before** the machine is asked, and for the reason
      # `Ampd.Worktree` writes CREATING before invoking its effector: if the
      # VM dies on the next line, boot finds an admitted attempt and calls it
      # INDETERMINATE rather than losing the fact that a process may exist.
      case Loci.create_attempt(ticket) do
        {:ok, stored} -> {:ok, stored}
        {:refused, r} -> {:refused, r}
      end
    end
  end

  # ------------------------------------------------------------ machine
  @doc """
  The machine phase. **Not ordered.**

  Takes a ticket and returns an observation, or an error. It decides nothing:
  a host that could promote its own child would be a host deciding product
  authority, which D.1.3a proved this one does not do.

  The duration is unbounded on purpose — that is the entire reason this phase
  is outside the total order. Nothing here may touch authority state.
  """
  def machine_start(ticket) when is_map(ticket) do
    Ampd.Carrier.Machine.Gate.start(ticket)
  end

  @doc """
  The machine implementation, selected the way the effector is.

  Compiled default is the possessed channel. A test may select the harness
  explicitly; that is a selection a person writes, not a state the runtime
  falls into, and falsifier `E12` asserts the unconfigured default so the
  selection cannot quietly become the rule.
  """
  def machine, do: Application.get_env(:ampd, :carrier_machine, Ampd.Carrier.Machine.Channel)

  # ------------------------------------------------------------------ B
  @doc """
  Transaction B. Re-read every basis, compare it to the ticket, and either
  join the Carrier to the World or refuse it.

  Returns `{:ok, incarnation}`, or `{:refused, refusal}` **with the attempt
  marked terminal**. A refusal here does not stop the process — that happens
  outside the order, in `reap_refused/2`, because a coordinator waiting for a
  process to die is machine latency back inside the total order by another
  route.
  """
  def commit_start(ticket, observation) when is_map(ticket) and is_map(observation) do
    AuthorityCoordinator.transact(fn -> commit(ticket, observation) end)
  end

  defp commit(ticket, obs) do
    lane = Loci.lane(ticket["locus_ref"])
    worker = Loci.worker(ticket["worker_ref"])
    peer = Peer.resolve(ticket["peer_ref"])
    att = peer && Peer.attachment(peer["id"])

    # Every clause is a *discontinuity*, named so the refusal says which basis
    # moved. Order is disclosure-graded like `Worker.still_standing/2`: the
    # cheapest structural facts first, the authority basis last.
    reason =
      cond do
        lane == nil -> "locus-unknown"
        worker == nil -> "worker-unknown"
        peer == nil -> "carrier-peer-gone"
        att == nil -> "carrier-not-attached"
        att["peer_epoch"] != ticket["peer_epoch"] -> "attachment-epoch-stale"
        att["locus_ref"] != ticket["locus_ref"] -> "carrier-attached-elsewhere"
        World.lineage() != ticket["world_ref"] -> "carrier-world-generation-stale"
        (worker["generation"] || 1) != ticket["worker_generation"] -> "carrier-worker-generation-stale"
        worker["status"] != "open" -> "worker-not-open"
        peer["actor"] != ticket["actor"] -> "carrier-actor-drift"
        Locus.profile_digest() != ticket["profile_basis"] -> "carrier-profile-basis-changed"
        # The observation must be *this* start. A stale observation from a
        # prior Carrier satisfying a later one is the cross-incarnation
        # acceptance D.1.3a refused one layer down.
        obs["carrier_ref"] != ticket["carrier_ref"] -> "carrier-observation-cross-incarnation"
        obs["carrier_epoch"] != ticket["carrier_epoch"] -> "carrier-observation-cross-incarnation"
        # Bind the floor VERSION as well as the result: changing the floor
        # must invalidate an admission accepted under the previous one rather
        # than silently applying a new rule to it.
        Ampd.Carrier.Floor.digest() != ticket["floor_basis"] -> "carrier-floor-basis-changed"
        floor_failures(obs) != nil -> "carrier-confinement-unacceptable"
        true -> nil
      end

    if reason do
      state = if reason == "carrier-confinement-unacceptable", do: "FAILED", else: "STALE"

      _ =
        Loci.patch_attempt(ticket["ticket_id"], %{
          "state" => state,
          "refused_as" => reason,
          # Which rows, not just that it failed. "Confinement unacceptable" is
          # not a diagnosis, and this is where a person finds out which of
          # seventeen things it was.
          "floor_failures" => floor_failures(obs)
        })

      {:refused, refuse(reason, ticket)}
    else
      inc = %{
        "schema" => @incarnation_schema,
        "carrier_ref" => ticket["carrier_ref"],
        "carrier_epoch" => ticket["carrier_epoch"],
        "worker_ref" => ticket["worker_ref"],
        "locus_ref" => ticket["locus_ref"],
        "peer_ref" => ticket["peer_ref"],
        "peer_epoch" => ticket["peer_epoch"],
        "worker_generation" => ticket["worker_generation"],
        "world_ref" => ticket["world_ref"],
        # An opaque handle. **Not identity** — the host holds pid, pidfd and
        # start time as embodiment facts, and a Carrier that used its pid as
        # its name would confuse OS-process continuity with assignment
        # continuity, which is the D.1.1 error in a new setting.
        "host_process_ref" => obs["host_process_ref"],
        "observed_profile_digest" => Core.intent_digest(obs["observed"] || %{}),
        "status" => "RUNNING"
      }

      case Peer.attach_carrier(ticket["peer_ref"], inc) do
        {:ok, stored} ->
          _ = Loci.patch_attempt(ticket["ticket_id"], %{"state" => "COMMITTED"})
          {:ok, stored}

        {:taken, why} ->
          _ = Loci.patch_attempt(ticket["ticket_id"], %{"state" => "STALE", "refused_as" => to_string(why)})
          {:refused, refuse("carrier-already-live", ticket)}
      end
    end
  end

  # ------------------------------------------------------------- whole
  @doc """
  Admit, run the machine, commit — in that order, with the machine phase
  outside the total order.

  On a commit refusal the process is reaped **after** the coordinator is
  released. The machine may well have started something; the point of the
  refusal is that it does not become a Carrier, not that it never ran.
  """
  def start(peer_ref, lane_ref) do
    with {:ok, ticket} <- admit_start(peer_ref, lane_ref) do
      case machine_start(ticket) do
        {:ok, obs} ->
          case commit_start(ticket, obs) do
            {:ok, inc} ->
              {:ok, inc}

            {:refused, r} ->
              reap_refused(ticket, obs)
              {:refused, r}
          end

        {:error, why} ->
          # The machine could not tell us whether a process exists. It is
          # never retried and never duplicated — the same policy the effect
          # channel holds for the same reason, which is that a second attempt
          # against an unknown first one is how you get two.
          #
          # Wrapped in its own transaction: `carrier_attempts` is a collection
          # of an ordered store, so a bare `patch_attempt` from out here is
          # refused as an unordered authority mutation and the record silently
          # stays START_ADMITTED. Measured — `E9` read it back as admitted and
          # the boot sweep would then have reported a phantom in-flight attempt
          # forever.
          AuthorityCoordinator.transact(fn ->
            Loci.patch_attempt(ticket["ticket_id"], %{"state" => "INDETERMINATE", "refused_as" => why})
          end)

          {:refused, refuse("carrier-start-indeterminate", ticket)}
      end
    end
  end

  @doc """
  Stop a process that was started but refused membership. Outside the order.
  """
  def reap_refused(ticket, obs) do
    Ampd.Carrier.Machine.Gate.terminate_carrier(ticket, obs)
  end

  @doc """
  Stop a live Carrier and drop its incarnation.

  **A lost stop confirmation is not a stop.** The membership is dropped either
  way — the runtime has decided this process is no longer its Carrier — but if
  the host could not confirm the process is gone, an unresolved attempt is
  recorded and a replacement is refused until `reconcile/1` establishes
  absence.

  The alternative, returning `:ok` on an unconfirmed stop, would let a lost
  confirmation manufacture a second process for the same Worker by exactly the
  route `unresolved/0` exists to close on the start side. Start and stop get
  the same rule because they have the same ambiguity.
  """
  def stop(peer_ref) do
    case Peer.carrier(peer_ref) do
      nil ->
        :ok

      inc ->
        result = Ampd.Carrier.Machine.Gate.terminate_carrier(inc, %{"host_process_ref" => inc["host_process_ref"]})
        Peer.detach_carrier(peer_ref)

        case result do
          :ok ->
            :ok

          {:error, why} ->
            _ = record_ambiguous_stop(inc, why)
            {:indeterminate, why}
        end
    end
  end

  # A stop whose outcome is unknown becomes an unresolved attempt against the
  # same Worker, which is what blocks a replacement. It is a *new* record
  # rather than a mutation of the start attempt: the start committed, and
  # rewriting a committed fact to describe a later event would lose both.
  defp record_ambiguous_stop(inc, why) do
    AuthorityCoordinator.transact(fn ->
      Loci.create_attempt(%{
        "schema" => @ticket_schema,
        "ticket_id" => mint("ct_"),
        "carrier_ref" => inc["carrier_ref"],
        "carrier_epoch" => inc["carrier_epoch"],
        "worker_ref" => inc["worker_ref"],
        "locus_ref" => inc["locus_ref"],
        "state" => "INDETERMINATE",
        "refused_as" => "stop was not confirmed: #{why}",
        "admitted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end)
  end

  @doc """
  Reconcile an unresolved start or stop attempt by **establishing physical
  absence**, not by relabelling it.

  ```text
  ticket carrier_ref
        ↓
  host stop-if-present
        ↓
  confirmed absent  →  ordered transition to RESOLVED
  still ambiguous   →  stays INDETERMINATE, no replacement
  ```

  There is deliberately no "mark it fine" path. A reconciliation that only
  changed a string would make `INDETERMINATE` a log entry rather than a safety
  state, and the whole reason a Worker can wedge is that the state means
  something.

  Human control only. An agent that could clear its own ambiguous attempt
  could clear the thing standing between it and a second process.
  """
  def reconcile(ticket_id) when is_binary(ticket_id) do
    case Loci.attempt(ticket_id) do
      nil ->
        {:refused, refuse("carrier-attempt-unknown", %{"ticket_id" => ticket_id})}

      %{"state" => s} = a when s in ~w(COMMITTED STALE FAILED RESOLVED) ->
        {:ok, a}

      a ->
        # Outside the order: this asks a machine to do something and waits.
        case Ampd.Carrier.Machine.Gate.terminate_carrier(a, %{}) do
          :ok ->
            AuthorityCoordinator.transact(fn ->
              Loci.patch_attempt(ticket_id, %{
                "state" => "RESOLVED",
                "resolved_as" => "the host confirmed no such carrier is running"
              })
            end)

          {:error, why} ->
            {:refused,
             refuse("carrier-reconcile-indeterminate", Map.put(a, "reason", why))}
        end
    end
  end

  @doc """
  Reap a Carrier whose owning Peer is gone.

  `Ampd.Peer` drops the incarnation the moment a channel dies — that is
  semantic membership ending, and it is immediate and correct. It does **not**
  make the process stop, and review caught the source claiming it did: the
  host's `serve_carrier` map still held the child, so the OS process kept
  running with no runtime record of it.

      semantic membership ended  ≠  process ended

  This is the other half. It is called from outside `Ampd.Peer` and never
  inside it: making a channel-close path wait on machine latency would put an
  8-second timeout in front of every disconnect.
  """
  def reap_orphans(incarnations) when is_list(incarnations) do
    Enum.map(incarnations, fn inc ->
      case Ampd.Carrier.Machine.Gate.terminate_carrier(inc, %{"host_process_ref" => inc["host_process_ref"]}) do
        :ok -> {:ok, inc["carrier_ref"]}
        {:error, why} -> {:error, inc["carrier_ref"], why}
      end
    end)
  end

  # ------------------------------------------------------------ reading
  @doc """
  The Carrier status of a Worker, for projection.

  `RUNNING` requires the live incarnation to exist **and** still match the
  Worker's current generation. A live map entry alone is not enough: the
  incarnation is dropped by the Peer on channel loss, but a Worker generation
  can advance underneath one that is still in the map, and a projection that
  reported RUNNING on that basis would be reporting a pid.
  """
  def status_of(worker) when is_map(worker) do
    Peer.carriers()
    |> Enum.find(fn c -> c["worker_ref"] == worker["id"] end)
    |> case do
      nil -> "OFFLINE"
      c -> if (worker["generation"] || 1) == c["worker_generation"], do: c["status"], else: "OFFLINE"
    end
  end

  @doc """
  Attempts for which a physical Carrier **may exist**.

  `INDETERMINATE` is in this set, and that is the correction review forced.
  It gated on `START_ADMITTED` alone, so an ambiguous start stopped blocking
  the moment it was recorded as ambiguous — which meant the one state that
  exists to say *a process may be out there* was the state that permitted
  starting a second one.

  > If a physical Carrier may exist, a second is not admitted until the
  > absence of the first has been established.

  This can wedge a Worker, and that is the intended trade: an ambiguous
  machine effect gives up availability to keep uniqueness. `reconcile/1` is
  how it is un-wedged, and it un-wedges by establishing absence rather than
  by relabelling the record.
  """
  def unresolved do
    Loci.attempts()
    |> Enum.filter(&(&1["state"] in ~w(START_ADMITTED INDETERMINATE)))
  end

  @doc "Deprecated alias retained so no caller silently changes meaning."
  def in_flight, do: unresolved()

  @doc """
  Boot-time sweep: an attempt that was in flight when the runtime stopped
  cannot be resolved by looking at it.

  Marked INDETERMINATE rather than FAILED, and **never** retried. The process
  it admitted may or may not exist; a sweep that assumed either way would be
  the automatic-duplicate-spawn this whole shape exists to prevent. It is
  reported and a person decides.
  """
  def recover! do
    stale = Loci.attempts() |> Enum.filter(&(&1["state"] == "START_ADMITTED"))

    Enum.each(stale, fn a ->
      AuthorityCoordinator.transact(fn ->
        Loci.patch_attempt(a["ticket_id"], %{
          "state" => "INDETERMINATE",
          "refused_as" => "the runtime stopped between admission and commit"
        })
      end)
    end)

    length(stale)
  end

  # ------------------------------------------------------------ private
  defp lane_known(nil), do: {:refused, refuse("locus-unknown", %{})}
  defp lane_known(_), do: :ok

  defp current_worker(peer, lane) do
    att = Peer.attachment(peer["id"])

    case att && Loci.worker(att["worker_ref"]) do
      nil -> {:refused, refuse("carrier-not-attached", %{})}
      w -> {:ok, w}
    end
    |> case do
      {:ok, w} -> if w["locus_ref"] == lane["id"], do: {:ok, w}, else: {:refused, refuse("worker-lane-actor-drift", %{})}
      other -> other
    end
  end

  # Exactly one live Carrier per Peer, checked here and again inside
  # `Ampd.Peer` under its own lock. This one is for the message; that one is
  # the invariant, because only the Peer serializes the mutation.
  defp no_live_carrier(peer) do
    if Peer.carrier(peer["id"]), do: {:refused, refuse("carrier-already-live", %{})}, else: :ok
  end

  defp no_pending_attempt(worker_ref) do
    if Enum.any?(unresolved(), &(&1["worker_ref"] == worker_ref)),
      do: {:refused, refuse("carrier-start-unreconciled", %{})},
      else: :ok
  end

  # Delegated to `Ampd.Carrier.Floor`, which is versioned and names the rows
  # it failed. This was four inline booleans and review found the hole: they
  # did not require Landlock, so a process with no filesystem confinement at
  # all satisfied the check that D.1.3b·1 existed to make meaningful.
  defp floor_failures(obs) do
    case Ampd.Carrier.Floor.verify(obs) do
      :ok -> nil
      {:error, rows} -> rows
    end
  end

  defp mint(prefix), do: prefix <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))

  defp refuse(code, ticket) do
    Refusal.new(code,
      component: "Ampd.Carrier",
      retryable: false,
      requires_human: false,
      operator_detail:
        %{"ticket_id" => ticket["ticket_id"], "carrier_ref" => ticket["carrier_ref"]}
        |> Enum.reject(fn {_, v} -> v == nil end)
        |> Map.new()
    )
  end
end
