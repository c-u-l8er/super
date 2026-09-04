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
      an attestation is not an agreement  D.1.3b·2c

  The last one is the one review had to force. Three bases are re-read by
  `commit_start/2` — the host profile, the confinement floor, and now the
  Carrier execution identity — and until `carrier_basis` existed the third was
  missing while these docs claimed it was covered. What stood in its place was
  a host attestation that *some* payload digest had been produced, which
  answers "what did the host say ran" and never "did the World agree to that".
  Both are needed:

      attested payload identity  ≠  admission-bound payload identity

  ## Losing the runtime incarnation terminates the Carrier

  A live Carrier belongs to the `Ampd.Peer` incarnation that admitted it. If
  that incarnation is lost — channel death, world reset, lineage advance — the
  Carrier's membership ends and the host reaps the process. There is
  deliberately **no survival across a control-plane restart** and therefore no
  persistent Carrier-recovery registry: replacement requires a new Peer, a new
  explicit occupancy, a new admission and a new incarnation. A recovery
  protocol can be designed when something needs one.

  ## The one exception, and how it is closed — `E29`

  This paragraph used to list **supervisor restart** beside the others and say
  the host reaps. Measured: it did not.

  ```text
  Ampd.Peer is killed
      ↓
  the supervisor restarts it with empty state
      ↓
  membership is gone            ← Peer.carriers() == []
  pending reaps are gone        ← they lived in the process that died
  nothing was announced         ← terminate/2 does not run on :kill
      ↓
  the OS process is still running
  ```

  It is the same shape D.1.3b·2a found and closed for channel death —
  *semantic membership ended ≠ process ended* — surviving in the one path
  nothing had ever measured, under a docstring asserting the opposite.

  **The `pending_reaps` ledger cannot close it**, and it is worth being exact
  about why rather than filing this as "more of the same". That ledger lives
  in `Ampd.Peer` so it survives a `Ampd.Carrier.Reaper` restart; when
  `Ampd.Peer` is the process that dies, the ledger dies with it, *and so does
  every record of which Carriers existed* — a crash ends membership for all of
  them at once without pending any. A ledger elsewhere would still not know
  what to sweep.

  The information survives in one place: the host's `serve_carrier` map. So
  the closure gives that map an owner on this side —
  `Ampd.Carrier.Machine.Gate`, which already survives `Ampd.Peer` under
  `:one_for_one` and already owns every lifecycle submission:

      Peer incarnation dies (or re-mints its epoch in place)
            ↓
      Gate FENCES carrier lifecycle
            ↓
      drain: the physical set is established EMPTY
            ↓
      the replacement incarnation is bound
            ↓
      Gate READY, and only now may a Carrier start

  and the host holds the same invariant independently, refusing a start whose
  runtime epoch is not the one its non-empty set belongs to. **No victims are
  named** — the records that named them are what died — so the operation
  empties the set rather than reaping a list.

  Deliberately **not** `:rest_for_one`: restarting the fourteen children after
  `Ampd.Peer` would restart authority coordinators, durable registries, Loci,
  Worktree and the Bridge — a World reboot to express one relationship. What
  is preserved is

      Peer restart             ≠  World restart
      Peer incarnation death   →  Carrier physical death

  `E29` is the falsifier and it was written the other way up: it asserted the
  leak, review ruled that a blocker, and it now asserts the invariant.
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
  #
  # **`RESOLVED` was missing and was being written anyway.** `reconcile/1`
  # has always ended at `"state" => "RESOLVED"` and this list has never named
  # it, so a public vocabulary and the durable records disagreed — in the
  # direction where the records are right and the declaration is the lie. The
  # inverse error of `OBSERVED`, which was declared and never written, and the
  # reason `E28` now drives every state and asserts membership rather than
  # asserting a list against itself.
  @attempt_states ~w(START_ADMITTED COMMITTED STALE FAILED INDETERMINATE RESOLVED)
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
         :ok <- no_pending_attempt(worker["id"]),
         :ok <- machine_synchronized(),
         {:ok, basis} <- execution_basis() do
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
        # Three bases now, and the third is the one review found missing.
        #
        # `profile_basis` binds the host embodiment; `floor_basis` binds the
        # rules a Carrier must satisfy. Neither binds **what is going to be
        # run**, and without that "an implementation admitted as A cannot
        # silently become B" was a sentence the source did not support — the
        # only payload identity anywhere was a digest the host produced
        # *after* the spawn, which is an attestation about the outcome and not
        # a term of the agreement.
        #
        #     attested payload identity  ≠  admission-bound payload identity
        #
        # Both are needed and this is the second one. It is the Carrier
        # equivalent of D.1.1's embodiment-basis problem, one object down.
        "carrier_basis" => basis,
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
        # **Before the floor, not after.** The floor asks whether this is a
        # Carrier; this asks whether it is the one we agreed to. Asking the
        # cheaper, more specific question first means a payload swap is
        # refused as a payload swap rather than as whichever floor row the
        # replacement happened to also miss.
        basis_moved(ticket, obs) != nil -> "carrier-execution-basis-changed"
        floor_failures(obs) != nil -> "carrier-confinement-unacceptable"
        true -> nil
      end

    if reason do
      state = if reason == "carrier-confinement-unacceptable", do: "FAILED", else: "STALE"

      if reason == "carrier-confinement-unacceptable" do
        require Logger
        Logger.warning("ampd: carrier floor refused #{inspect(floor_failures(obs))}")
      end

      _ =
        Loci.patch_attempt(ticket["ticket_id"], %{
          "state" => state,
          "refused_as" => reason,
          # Which rows, not just that it failed. "Confinement unacceptable" is
          # not a diagnosis, and this is where a person finds out which of
          # twenty things it was.
          "floor_failures" => floor_failures(obs),
          # And which *field* of the basis moved, for the same reason. "The
          # execution basis changed" does not distinguish a redeployed payload
          # from a protocol version bump, and those want different responses
          # from the person reading it.
          "basis_moved" => basis_moved(ticket, obs)
        })

      {:refused, refuse(reason, Map.put(ticket, "basis_moved", basis_moved(ticket, obs)))}
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
          # **Membership is the authority fact; the attempt ledger is
          # recovery bookkeeping, and losing the second does not un-make the
          # first.**
          #
          # `attach_carrier` has replied. This Carrier IS a member of the
          # World. If `Ampd.Loci` then fails, letting that failure become the
          # transaction's result would refuse a start that committed — and
          # `settle_commit/3` would reap the process while `Peer.carriers/0`
          # still reports it RUNNING, which is the inverted orphan one class
          # of refusal further along than the one that was already closed.
          #
          # The attempt stays START_ADMITTED, which `unresolved/0` reports and
          # which `reconcile/1` now settles by consulting membership rather
          # than by terminating what it finds — the correction that repair
          # needed, because `START_ADMITTED` is not in `reconcile/1`'s
          # short-circuit set and it would otherwise have killed the Carrier
          # this branch exists to preserve.
          _ = record_committed(ticket)
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
              settle_commit(ticket, obs, r)
          end

        {:error, why} ->
          # The machine could not tell us whether a process exists. It is
          # never retried and never duplicated — the same policy the effect
          # channel holds for the same reason, which is that a second attempt
          # against an unknown first one is how you get two.
          #
          require Logger

          Logger.warning(
            "ampd: carrier start #{ticket["carrier_ref"]} is INDETERMINATE — #{why}"
          )

          # Wrapped in its own transaction: `carrier_attempts` is a collection
          # of an ordered store, so a bare `patch_attempt` from out here is
          # refused as an unordered authority mutation and the record silently
          # stays START_ADMITTED. Measured — `E9` read it back as admitted and
          # the boot sweep would then have reported a phantom in-flight attempt
          # forever.
          AuthorityCoordinator.transact(fn ->
            Loci.patch_attempt(ticket["ticket_id"], %{"state" => "INDETERMINATE", "refused_as" => why})
          end)

          # The machine's own words, carried through. A refusal that says only
          # "indeterminate" is not a diagnosis — the same argument
          # `floor_failures` makes one clause down, and the reason the
          # production join check could not say why it was failing.
          {:refused,
           refuse("carrier-start-indeterminate", Map.put(ticket, "machine_reason", why))}
      end
    end
  end

  # Deliberately narrow, deliberately local, and deliberately not a policy:
  # this rescue exists for one call whose failure must not undo a commit that
  # already happened.
  defp record_committed(ticket) do
    Loci.patch_attempt(ticket["ticket_id"], %{"state" => "COMMITTED"})
  rescue
    e in Ampd.Participant.Failure ->
      require Logger

      Logger.warning(
        "ampd: carrier #{ticket["carrier_ref"]} committed and its attempt could not be " <>
          "marked (#{Exception.message(e)}) — it stays START_ADMITTED for the boot sweep"
      )

      :ok
  end

  @doc false
  # **A refusal is a decision; an indeterminate commit is not one.**
  #
  # Reaping is an ACTION taken on the assumption that membership was not
  # granted. C1.0b·2 introduced a refusal class where that assumption is
  # exactly what is unknown: a participant may have applied `attach_carrier`
  # and lost only its reply, in which case this Carrier **is** a member, and
  # reaping it leaves the runtime holding a live incarnation whose process is
  # dead — the inverse of the orphan `pending_reaps` exists to close.
  #
  # So an indeterminate commit leaves the process alone and marks the attempt,
  # which is the same treatment the machine phase gives its own unknown one
  # clause up, for the same reason: a second action against an unknown first
  # one is how you get two. `Ampd.Carrier.Reaper` and `reconcile/1` own the
  # convergence from here.
  #
  # Split out from `start/2` for the reason `Ampd.Worker.occupancy_of/3` is
  # split from `occupancy/2`: the decision is worth having as a function of
  # its inputs. Reaching this state through a real participant failure means
  # racing a registry death against one call in the middle of a transaction;
  # the decision itself is three lines and is what a falsifier is about.
  def settle_commit(ticket, obs, refusal) do
    if refusal["code"] == "participant-indeterminate" do
      require Logger

      Logger.warning(
        "ampd: carrier start #{ticket["carrier_ref"]} could not establish whether it " <>
          "committed — the process is NOT reaped, because reaping assumes it did not"
      )

      _ =
        AuthorityCoordinator.transact(fn ->
          Loci.patch_attempt(ticket["ticket_id"], %{
            "state" => "INDETERMINATE",
            "refused_as" => "the commit's participant did not answer"
          })
        end)
    else
      reap_refused(ticket, obs)
    end

    {:refused, refusal}
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

      # **A live member is not an unresolved attempt, and reconciling one
      # would kill it.**
      #
      # `reconcile/1` exists for an attempt whose process may or may not be
      # running with nothing in the runtime referring to it. It reached that
      # conclusion from the attempt's state alone — so an attempt left
      # `START_ADMITTED` by a *committed* start whose ledger write was lost
      # fell to the branch below and was terminated, while `Ampd.Peer` still
      # held its incarnation and `status_of/1` still reported RUNNING over a
      # dead process. The inverted orphan, arrived at by the button the
      # operator projection offers for exactly this attempt.
      #
      # The runtime KNOWS whether it is a member; it does not have to infer it
      # from a durable record it failed to write. So membership is consulted
      # first, and a reconcile of a live member records what is true rather
      # than acting on what was assumed.
      a ->
        case live_member(a) do
          nil -> reconcile_absent(ticket_id, a)
          _inc -> reconcile_committed(ticket_id, a)
        end
    end
  end

  defp live_member(%{"carrier_ref" => ref}) when is_binary(ref) do
    Enum.find(Peer.carriers(), &(&1["carrier_ref"] == ref))
  end

  defp live_member(_), do: nil

  # The ledger write that was lost, performed now that its store is reachable.
  # Nothing is asked of the machine: the process is a member and is running.
  defp reconcile_committed(ticket_id, a) do
    require Logger

    Logger.warning(
      "ampd: attempt #{ticket_id} was unresolved and its carrier #{a["carrier_ref"]} is a " <>
        "live member — recording the commit rather than terminating it"
    )

    AuthorityCoordinator.transact(fn ->
      Loci.patch_attempt(ticket_id, %{
        "state" => "COMMITTED",
        "resolved_as" => "the runtime holds this carrier as a live member"
      })
    end)
  end

  defp reconcile_absent(ticket_id, a) do
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
        {:refused, refuse("carrier-reconcile-indeterminate", Map.put(a, "reason", why))}
    end
  end

  @doc """
  End the membership of every Carrier whose admitting relationship has ceased
  to exist, and schedule physical termination.

  ## The invariant

  > Every event that invalidates the live relationship under which a Carrier
  > was admitted ends semantic membership immediately and schedules physical
  > termination. Ambiguous termination blocks replacement until reconciled.

  Review found this scattered rather than converged: `Ampd.Peer.drop/2` handled
  channel death, and `detach_worker`, `close_worker` and `Peer.reset/0` each
  handled *half* — they invalidated the basis and left the process running,
  because each remembered occupancy and none remembered execution.

  So there is one operation, and every path calls it. It takes no argument
  naming which Carrier to kill: it **re-derives** which live incarnations are
  no longer current, using the same predicate the projection uses. A caller
  that had to name the victim would be a caller that could get it wrong, and
  four callers naming victims is four chances.

  Never blocks: the announcement is a cast and `Ampd.Carrier.Reaper` does the
  waiting. Called from `Ampd.Control` after an occupancy or Worker mutation,
  and from `Ampd.Peer` when a channel dies.
  """
  def converge(reason \\ "the admitting relationship ended") do
    stale =
      Enum.filter(Peer.carriers(), fn c ->
        w = Loci.worker(c["worker_ref"])
        w == nil or not still_current?(c, w)
      end)

    Enum.each(stale, fn c ->
      # Membership first and unconditionally. Whether the process can be
      # confirmed dead is a separate question with its own answer; leaving
      # membership in place until it is answered would mean a Carrier stayed
      # RUNNING because the host was slow.
      #
      # One call, not two: `detach_carrier_pending/1` ends the membership and
      # records the reap debt in the same message, so this process dying
      # between them cannot lose the only reference to a running Carrier.
      # `Ampd.Carrier.Reaper` may be down — the announcement below is
      # conditional and always was — and the debt is what survives that.
      Peer.detach_carrier_pending(c["peer_ref"])
      if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.orphaned(c)
    end)

    {length(stale), reason}
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
      c -> if still_current?(c, worker), do: c["status"], else: "OFFLINE"
    end
  end

  @doc """
  Is the relationship that admitted this Carrier still the relationship?

  **The map entry is not the answer.** An earlier version compared only the
  Worker generation, which left this reachable:

      occupancy OFFLINE   ∧   Carrier RUNNING

  after an ordinary `detach_worker` — because the incarnation is still in the
  map until the reaper converges. The legitimate asymmetry is the other one,
  `OCCUPIED ∧ OFFLINE`: a position held with nothing running. A Carrier
  running at a position nobody occupies is the ambient-authority shape the
  whole lane exists to refuse, rendered as fact on a person's screen.

  `RUNNING` is a statement about a current relationship, not about a table
  having a row in it. No machine I/O happens here — the read predicate says
  what is true now, and `Ampd.Carrier.Reaper` makes the process agree.
  """
  def still_current?(c, worker) when is_map(c) and is_map(worker) do
    peer = Peer.resolve(c["peer_ref"])
    att = peer && Peer.attachment(peer["id"])

    peer != nil and
      att != nil and
      att["peer_epoch"] == c["peer_epoch"] and
      att["locus_ref"] == c["locus_ref"] and
      att["worker_ref"] == c["worker_ref"] and
      worker["status"] == "open" and
      (worker["generation"] || 1) == c["worker_generation"] and
      World.lineage() == c["world_ref"]
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

  # The fields of `carrier-execution-basis@1` that are bound, named exactly.
  #
  # A whole-map comparison would bind whatever the host happened to include,
  # which makes the set of things that can invalidate an admission a property
  # of the host's current JSON rather than a decision. Comparing a named
  # subset means adding a field to the basis is a deliberate act with a
  # falsifier attached, and an unknown field cannot silently start refusing
  # every start after a host upgrade.
  @basis_fields ~w(schema payload_digest carrier_protocol carrier_protocol_version)
  def basis_fields, do: @basis_fields

  @doc """
  Which bound fields of the Carrier execution basis differ between what was
  admitted and what actually ran, or `nil` if they agree.

  `nil` is only returned when both bases are present and every bound field
  matches. **An absent basis on either side is a mismatch, not a skip** — the
  whole point of the object is that there is no path where nothing is
  compared, and a `nil == nil` that read as agreement would be exactly that
  path.
  """
  def basis_moved(ticket, obs) do
    admitted = ticket["carrier_basis"]
    actual = get_in(obs, ["attested", "execution_basis"])

    cond do
      not is_map(admitted) -> ["admitted-basis-absent"]
      not is_map(actual) -> ["actual-basis-absent"]
      true -> Enum.reject(@basis_fields, &(Map.get(admitted, &1) == Map.get(actual, &1)))
    end
    |> case do
      [] -> nil
      moved -> moved
    end
  end

  # Is the machine side synchronized to the runtime incarnation that is
  # asking?
  #
  # **Checked before the ticket is persisted, and that placement is the
  # point.** During the window in which `Ampd.Carrier.Machine.Gate` is
  # draining after a Peer-registry restart, every innocent start would
  # otherwise write a durable `START_ADMITTED`, reach a fenced Gate, come back
  # INDETERMINATE, and wedge its Worker until a person reconciled it — a
  # reconciliation requirement manufactured by the runtime's own recovery.
  #
  # `ready_for?/1` reads a published term. No message to the Gate, which may
  # be in the middle of an 8-second drain; no host round trip. The same
  # argument `execution_basis/0` makes one clause down, for the same reason.
  defp machine_synchronized do
    epoch = peer_epoch()

    if epoch != nil and Ampd.Carrier.Machine.Gate.ready_for?(epoch) do
      :ok
    else
      {:refused,
       refuse("carrier-runtime-incarnation-unready", %{
         "reason" =>
           "the carrier machine has not established an empty physical carrier set since the " <>
             "runtime incarnation changed"
       })}
    end
  end

  # **An exception is not an exit, and this `catch` stopped firing.**
  #
  # It was written when `Peer.epoch/0` was a bare `GenServer.call` that exited
  # its caller. Inside the order that call now raises instead, so the exit
  # clause became unreachable and an absent registry produced
  # `participant-unavailable` rather than the
  # `carrier-runtime-incarnation-unready` this function exists to reach.
  #
  # Both are kept: the exit for callers outside the order, where the
  # degradation to `GenServer.call` is deliberate, and the rescue for inside.
  defp peer_epoch do
    Peer.epoch()
  rescue
    _ in Ampd.Participant.Failure -> nil
  catch
    :exit, _ -> nil
  end

  # The basis the selected machine would launch. Reads channel metadata; makes
  # no request to the machine and takes no deadline — see the callback docs.
  #
  # **That was the whole argument for it being safe inside the order, and it
  # was incomplete.** It makes no request to the MACHINE and it does make one
  # to `Ampd.Bridge`: `Ampd.Carrier.Machine.Channel.execution_basis/0` calls
  # `Bridge.carrier_endpoint/0`. Before C1.0b·2·1 that was a bare
  # `GenServer.call` with no catch anywhere between here and the coordinator,
  # so a Bridge that was absent or mid-restart exited the total order — the
  # exact fault this comment claimed could not happen. The C1.0b·2·1
  # reachability census is what found it; no test did.
  #
  # `Ampd.Bridge` is a participant now, so its absence arrives as a
  # classified `Ampd.Participant.Failure` that the coordinator catches by
  # struct. The refusal is `participant-unavailable` rather than
  # `carrier-execution-basis-unavailable` in that one case — a real loss of
  # diagnosis, and a smaller one than losing the control plane. The
  # channel-present-but-empty case still refuses by the name below.
  defp execution_basis do
    case machine().execution_basis() do
      {:ok, b} when is_map(b) ->
        {:ok, b}

      {:error, why} ->
        {:refused, refuse("carrier-execution-basis-unavailable", %{"reason" => why})}

      # Anything else is a machine that answered the wrong shape, and it
      # refuses rather than raising. A raise here would be inside
      # `AuthorityCoordinator.transact/1`, and a crash masks a probe.
      other ->
        {:refused,
         refuse("carrier-execution-basis-unavailable", %{"reason" => inspect(other)})}
    end
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
        %{
          "ticket_id" => ticket["ticket_id"],
          "carrier_ref" => ticket["carrier_ref"],
          "reason" => ticket["machine_reason"] || ticket["reason"],
          "floor_failures" => ticket["floor_failures"],
          "basis_moved" => ticket["basis_moved"]
        }
        |> Enum.reject(fn {_, v} -> v == nil end)
        |> Map.new()
    )
  end
end
