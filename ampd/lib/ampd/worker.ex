defmodule Ampd.Worker do
  @moduledoc """
  `worker@1` and `carrier-attachment@1` — the difference between *being
  someone* and *being somewhere*.

  ## The sentence this module exists to make executable

  > A Carrier does not occupy a position because its identity is
  > associated with that position. It occupies a position because it
  > explicitly took up an assignment to stand there, that assignment is
  > still open, and nothing underneath it has moved since.

  D.1.1 answered a different question — can a position outlive its
  Carrier — and answered it with `peer.actor == lane.actor`. That was
  enough to bootstrap and it is not enough now, for a reason that only
  appears once one identity can hold more than one position:

      Travis / Opus actor
          ├── Lane A · implement Worker
          ├── Lane B · hostile review
          └── Lane C · alternate design

  Under actor equality a single Carrier authenticating as that actor
  occupied **all three at once**, and could exercise every capability
  established from any of them. That is ambient authority — authority
  *exercised* without being *selected* — reintroduced at the semantic
  layer by the very abstraction meant to remove it.

  ## What replaced it

      occupancy  =  identity  ∧  explicit current assignment

  Identity is retained as a **necessary** condition, not discarded. The
  working hypothesis D.1.2 was asked to test is that identity is necessary
  but not sufficient, and removing it would have tested something else.

  ## Where this is not new, stated plainly

  This is, structurally, **NIST RBAC session/role-activation semantics**:
  a session may exercise only the permissions of the roles it has
  *activated*, and the activatable set is bounded by — not equal to — the
  roles the user is assigned. `session_roles(s) ⊆ {r | (user(s), r) ∈ UA}`
  is the same subset relation as `occupied ⊆ associated` here, and
  `AddActiveRole` is `attach_worker`. See Ferraiolo, Sandhu, Gavrila, Kuhn
  & Chandramouli, *Proposed NIST Standard for Role-Based Access Control*,
  ACM TISSEC 4(3), 2001. The failure mode it avoids is Miller, Yee &
  Shapiro's Property D, *Capability Myths Demolished*, 2003 — "authority
  that is exercised, but not selected, by its user".

  Two places this genuinely departs from that standard are recorded at
  `exclusive?/0`, and one of them is a **known non-conformance**.

  ## Occupancy is not authority

  Attaching manufactures nothing. It establishes *position*, and position
  is a precondition every capability check already had:

      valid identity            ≠  valid occupancy
      valid occupancy           ≠  arbitrary authority
      occupancy ∧ current grant ∧ current lineage ∧ current basis
                                →  exercisable operation

  A `worker@1` record holds no grant, no capability, no rights and no
  reference to a resource, and `D2-11` reads the durable record back to
  prove it. `Ampd.Locus.check/2` is unchanged in what it re-derives; the
  only thing D.1.2 moved is what `occupies?/2` means.

  ## Re-derived on use, not trusted from attach

  `attach/2` validates and refuses by name, which is a courtesy to the
  caller and nothing more. **The attachment is not a credential.** Every
  field it binds is compared against live state on every use by
  `occupies?/2`, so a Worker closed, a world advanced or a peer epoch
  rotated after a valid attachment invalidates it without anything having
  to notify anyone. This is the same shape as `Ampd.Locus.check/2`, and for
  the same reason: a record that survived proves it was written.
  """

  alias Ampd.{Loci, Peer, Refusal, World}

  @doc """
  Is a **Locus** occupied by at most one Carrier, and a Carrier at at most
  one Locus?

  **Yes. Note that this is about the Locus and not the Worker**, and the
  first implementation of D.1.2 got that wrong in a way worth keeping
  written down: it enforced uniqueness on `worker_ref`, which is a weaker
  and different invariant. Two Workers may be open on one Lane, so two
  Carriers could hold two Workers and both stand at the same position.
  See `Ampd.Peer.attach_worker/3`.

  *At most one Carrier per Locus* is the ordinary meaning of a seat.

  *At most one Locus per Carrier* is the contentious half. NIST Core RBAC
  explicitly **requires** that a session may activate several roles at
  once: "core RBAC requires that users can simultaneously exercise
  permissions of multiple roles. This precludes products that restrict
  users to activation of one role at a time." This runtime does not conform
  to that clause and does not claim to, because a Lane is not simply an
  RBAC role — the semantics here are situated rather than set-theoretic:

      an actor        is associated with     many Loci
      a Carrier       is presently at        one Locus

  Parallelism across positions comes from **several logical Carriers**, not
  from one Carrier being everywhere at once. A single OS process could
  multiplex thousands of logical Carriers without disturbing that rule.

  ## The narrow form of the argument, which is the defensible one

  It would overclaim to say multiple simultaneous positions are *inherently*
  ambient. *Capability Myths Demolished* defines ambient authority as
  authority exercised without being selected; a design in which every
  operation named an unforgeable attachment capability —

      operation(attachment_cap, resource_cap, …)

  — would select explicitly and would not be ambient. So the claim is
  conditional on this grammar:

  > **Given Super's current grammar, in which a command names a
  > `locus_ref` string, single-Locus occupancy is what prevents that
  > argument from becoming a selector over an ambient set of activated
  > positions.**

  With one attachment `locus_ref` is a *check* — the caller designates, the
  attachment authorizes, and a disagreement is refused rather than
  resolved, which is Property A, "no designation without authority". With
  two it would be a choice, and the payload would be picking the authority
  again.

  A Carrier that wants a different position detaches and attaches again,
  which is an act rather than an accident.
  """
  def exclusive?, do: true

  @doc "Statuses a `worker@1` may hold. Two, and both are exercised."
  def statuses, do: ~w(open closed)

  # ------------------------------------------------------------- create
  @doc """
  Open a Worker on a Lane. **A person does this; no agent can.**

  Every ancestry field is copied from the Lane rather than accepted from
  the caller — `workspace_ref`, `goal_ref`, `locus_ref`, and the `actor`
  itself. That is referential closure by construction rather than by
  validation: there is no argument in which a caller could name a Workspace
  the Lane does not belong to, or an actor the Lane is not held by, so
  there is no check that could be forgotten. It is the same move
  `open_lane` makes when it takes `workspace_ref` from the Goal instead of
  from the operator.

  **`world_ref` is the exception and it is not ancestry.** A `lane@1` has
  no `world_ref` to copy — only `workspace@1` carries one — so this is
  sampled from `Ampd.World.lineage()` and means *the lineage this
  assignment was created in*. It is **creation provenance and not a
  freshness basis**: nothing compares it to anything, and a Worker survives
  a lineage advance exactly as its Lane does, because both are records and
  neither is authority. The attachment carries its own copy, and that one
  *is* compared — see `occupancy_of/3`. The prose here previously said
  every ancestry field came from the Lane, which was true of four fields
  and not of this one.

  The one consequence worth stating: **a Worker cannot be created for an
  actor other than the Lane's.** Assigning a different actor is opening a
  different Lane, which is a decision a person makes with `open_lane`.

  Must run inside the total order — `Ampd.Loci` refuses a create that did
  not come from the coordinator. `Ampd.Authority.open_worker/2` is the
  entry point.
  """
  def create(locus_ref, purpose) do
    lane = Loci.lane(locus_ref)

    cond do
      lane == nil ->
        {:refused, refuse("locus-unknown", %{"locus_ref" => locus_ref})}

      lane["actor"] == nil ->
        {:refused,
         refuse("locus-has-no-actor", %{
           "locus_ref" => locus_ref,
           "hint" => "a Lane nobody is named on is not a position anyone can be assigned to"
         })}

      true ->
        {:ok,
         Loci.create_worker(%{
           "world_ref" => World.lineage(),
           "workspace_ref" => lane["workspace_ref"],
           "goal_ref" => lane["goal_ref"],
           "locus_ref" => lane["id"],
           "actor" => lane["actor"],
           "purpose" => purpose,
           "generation" => 1,
           "status" => "open"
         })}
    end
  end

  @doc """
  Close a Worker. The assignment ends; the Lane and every capability
  established from it are untouched.

  **Advances `generation`.** See `reopen/1` for what that is defending
  against.
  """
  def close(worker_id), do: transition(worker_id, "closed", "worker-already-closed")

  @doc """
  Re-open a closed Worker as a **new incarnation of the same persistent
  assignment**.

  The wording is exact and the earlier wording was not. This does not
  create a new Worker: the id persists, the ancestry persists, and every
  reference to it stays valid. What changes is the incarnation, which is
  the same distinction `Ampd.World` already draws between an
  `installation_id` that persists and a `generation` that moves:

      Worker identity       persists
      Worker generation     advances
      prior attachment      does not survive

  `generation` advancing here is the whole point of the operation existing.
  `Ampd.Locus.grant_of/1` carries a measured scar from this exact shape one
  layer down: a revoked capability became usable again when an equivalent
  grant was minted, because the check asked whether *an* applicable grant
  existed rather than whether *the* one it was established from did.

  Occupancy has the same hole available to it. A Carrier attached, the
  Worker closed underneath it, the Worker reopened — and a design comparing
  only `status` would find the old attachment valid again, having survived
  the interval in which it was explicitly invalid.

  **A reopened position is grounds for a new attachment, never for reviving
  an old one.**
  """
  def reopen(worker_id), do: transition(worker_id, "open", "worker-already-open")

  defp transition(worker_id, to, already_code) do
    case Loci.worker(worker_id) do
      nil ->
        {:refused, refuse("worker-unknown", %{"worker_ref" => worker_id})}

      %{"status" => ^to} = w ->
        {:refused, refuse(already_code, %{"worker_ref" => worker_id, "status" => w["status"]})}

      w ->
        {:ok,
         Loci.put_worker(worker_id, %{
           "status" => to,
           "generation" => (w["generation"] || 1) + 1
         })}
    end
  end

  # ------------------------------------------------------------- attach
  @doc """
  Take up an assignment. This is the act that makes a Carrier present at a
  position.

  Returns `{:ok, %{"worker" => .., "attachment" => ..}}` or
  `{:refused, refusal}`.

  Nothing durable is written. Nothing is granted. The Carrier ends up in
  exactly one new state — *here* — and what may be done from here is still
  decided, on every use, by machinery this function does not touch.
  """
  def attach(peer, worker_id) do
    w = Loci.worker(worker_id)
    lane = w && Loci.lane(w["locus_ref"])

    cond do
      peer == nil or peer["actor"] == nil ->
        {:refused, no_actor(peer)}

      # **Unknown and not-yours are the same answer.** A Carrier that may
      # not attach to a Worker learns only that it may not — otherwise
      # `worker-unknown` versus `worker-actor-mismatch` distinguishes a
      # Worker that exists from one that does not, and a caller free to
      # guess ids can enumerate another actor's assignments one probe at a
      # time. Same rule, same reason, as the `capability-not-held` ordering
      # in `Ampd.Locus.check/2`.
      w == nil or w["actor"] != peer["actor"] ->
        {:refused,
         refuse("worker-not-assignable", %{
           "worker_ref" => worker_id,
           "bound_actor" => peer["actor"],
           "hint" =>
             "no Worker with that id is assigned to this Carrier's actor — " <>
               "knowing an id is not being assigned to it"
         })}

      w["status"] != "open" ->
        {:refused,
         refuse("worker-not-open", %{
           "worker_ref" => worker_id,
           "status" => w["status"],
           "hint" => "a closed assignment is not a position anyone stands at"
         })}

      lane == nil ->
        {:refused, refuse("locus-unknown", %{"locus_ref" => w["locus_ref"]})}

      # The Lane may have been re-actored under a Worker that outlived the
      # decision. Ancestry is copied at create and re-checked here, because
      # a copy is a claim about the past.
      lane["actor"] != w["actor"] ->
        {:refused,
         refuse("worker-lane-actor-drift", %{
           "worker_ref" => worker_id,
           "locus_ref" => lane["id"],
           "hint" => "the Lane is no longer held by the actor this Worker was assigned to"
         })}

      true ->
        bind(peer, w, lane)
    end
  end

  defp bind(peer, w, lane) do
    binding = %{
      "worker_ref" => w["id"],
      "locus_ref" => lane["id"],
      "actor" => peer["actor"],
      # Bound so a change can be detected. Compared on every use, never
      # trusted — `occupies?/2` is what makes these load-bearing.
      "world_ref" => World.lineage(),
      "worker_generation" => w["generation"] || 1
    }

    case Peer.attach_worker(peer["id"], binding, stale_on(lane)) do
      {:ok, att} ->
        {:ok, %{"worker" => w, "attachment" => att}}

      {:taken, :carrier} ->
        {:refused,
         refuse("carrier-already-attached", %{
           "worker_ref" => w["id"],
           "hint" =>
             "this Carrier already occupies a position — detach first. " <>
               "One Carrier is at one place, so a command's locus_ref is a check and not a choice"
         })}

      {:taken, :worker} ->
        {:refused,
         refuse("worker-already-occupied", %{
           "worker_ref" => w["id"],
           "hint" => "another live Carrier is fulfilling this assignment"
         })}

      {:taken, :locus} ->
        {:refused,
         refuse("locus-already-occupied", %{
           "locus_ref" => lane["id"],
           "worker_ref" => w["id"],
           "hint" =>
             "another live Carrier stands at this Lane through a different assignment — " <>
               "the position admits one occupant, and a second Worker on it is not a second place"
         })}

      {:taken, :unknown_peer} ->
        {:refused, refuse("carrier-unknown", %{"hint" => "this handle does not resolve"})}
    end
  end

  @doc """
  The peer ids whose attachment names `lane` and **no longer satisfies
  occupancy** — the rows that are reservations in appearance only.

  Exported because `Ampd.Peer` needs the answer and must not compute it:
  deciding whether an attachment is live means reading the world lineage,
  the Worker and the Lane, and a channel-identity module that did all that
  would be something you cannot reason about without the world.

  **This is what makes `close_worker` a supervision primitive rather than a
  request.** Without it, a Carrier that had lost every scrap of authority
  still held the position, because exclusivity was computed from table
  presence and its row was still present. It could block a replacement for
  as long as it declined to call `detach_worker`. Ending an occupancy and
  being unable to block the next one are the same event; they were not, and
  `D2-15` is the falsifier that says so.

  It is also **not** the only correctness mechanism, deliberately. Eagerly
  deleting the row inside `close_worker` would be a fine optimisation and a
  poor invariant: the durable close can commit and the process can die
  before any ephemeral cleanup runs, leaving a row that no cleanup will
  ever revisit. Computing staleness at admission time survives that,
  because it asks the question rather than trusting an earlier answer.
  """
  def stale_on(lane) when is_map(lane) do
    Peer.attachments()
    |> Enum.filter(&(&1["locus_ref"] == lane["id"]))
    |> Enum.filter(&(occupancy_of(&1, Peer.resolve(&1["peer_ref"]) || %{}, lane) != :ok))
    |> Enum.map(& &1["peer_ref"])
  end

  @doc "Vacate. The Worker and the Lane persist; the Carrier is no longer at either."
  def detach(peer) when is_map(peer) do
    att = Peer.attachment(peer["id"])
    :ok = Peer.detach_worker(peer["id"])
    {:ok, %{"released" => att != nil, "worker_ref" => att && att["worker_ref"]}}
  end

  def detach(_), do: {:ok, %{"released" => false, "worker_ref" => nil}}

  # ---------------------------------------------------------- occupancy
  @doc """
  Does `peer` occupy `lane`?

  **This is the D.1.2 replacement for actor equality**, and every clause is
  re-derived from live state rather than read off the attachment. The
  attachment supplies what to compare *to*; it never supplies the answer.
  """
  def occupies?(peer, lane) when is_map(peer) and is_map(lane),
    do: occupancy(peer, lane) == :ok

  def occupies?(_, _), do: false

  @doc """
  `:ok`, or `{:refused, refusal}` naming the first thing that is wrong.

  The refusal is **disclosure-graded on identity**, which is the one place
  identity still does work on its own:

      actor mismatch          `locus-not-occupied`, no detail
      no attachment           `carrier-not-attached`
      attached elsewhere      `carrier-attached-elsewhere`

  A stranger gets one answer whatever the real reason is. A Carrier whose
  actor *is* the Lane's is told which, because that is a fact about its own
  position and "attach first" is unactionable if it cannot be told apart
  from "you were never allowed here".

  **The grading is in the code, not only in `operator_detail`, and the
  first attempt got that wrong.** `Ampd.Refusal.project/2` strips
  `operator_detail` on an agent channel — correctly — so a distinction
  carried only there is a distinction the agent cannot act on, while the
  docstring claims it can. `D2-01` and `D2-02` caught it by asserting on
  what the agent actually receives rather than on what was constructed.

  The distinct codes disclose nothing further: they differ on the *caller's*
  relation to the Lane, and a caller already knows its own actor and can
  already enumerate its own Lanes through `list_loci`, which is
  ancestry-closed for exactly this reason.
  """
  def occupancy(peer, lane), do: occupancy_of(peer && Peer.attachment(peer["id"]), peer, lane)

  @doc """
  The same decision, with the attachment supplied rather than fetched.

  Split out for the reason `Ampd.Locus.check/2` takes a `cap` instead of a
  `cap_id`: the decision is worth having as a function of its inputs.
  Fetching is one line and deciding is twenty, and only the second is
  interesting to a falsifier.

  It is what lets `D2-07` and `D2-09` test the discontinuity clauses at
  all. Both are normally unreachable through the live table — `Peer.reset/0`
  empties it, so the natural path proves the channel closed rather than
  proving `occupancy_of/3` re-derives anything. Handing it a stale
  attachment tests the clause instead of the cleanup.
  """
  def occupancy_of(att, peer, lane) do
    cond do
      not is_map(peer) or peer["actor"] == nil ->
        {:refused, no_actor(peer)}

      # Identity remains **necessary**. The hypothesis under test is that it
      # is not sufficient, not that it is irrelevant.
      peer["actor"] != lane["actor"] ->
        {:refused, not_occupied(peer, lane, nil)}

      att == nil ->
        {:refused,
         refuse("carrier-not-attached", %{
           "locus_ref" => lane["id"],
           "bound_actor" => peer["actor"],
           "hint" =>
             "this Carrier's actor is the Lane's actor and that is not occupancy — " <>
               "attach to a Worker on this Lane first"
         })}

      att["locus_ref"] != lane["id"] ->
        {:refused,
         refuse("carrier-attached-elsewhere", %{
           "locus_ref" => lane["id"],
           "occupies_instead" => att["locus_ref"],
           "hint" =>
             "this Carrier is present at another Lane held by the same actor — " <>
               "an identity may be associated with many positions and stands at one"
         })}

      true ->
        still_standing(att, lane)
    end
  end

  # Everything from here on is a discontinuity: the attachment was
  # legitimate and something underneath it moved. Each returns a distinct
  # code, because "you are not there any more" and "you were never there"
  # are different facts and an operator reading a refusal log needs them
  # apart.
  defp still_standing(att, lane) do
    w = Loci.worker(att["worker_ref"])

    cond do
      att["peer_epoch"] != Peer.epoch() ->
        {:refused,
         stale("attachment-epoch-stale", %{
           "hint" => "the channel incarnation that took up this assignment has ended"
         })}

      att["world_ref"] != World.lineage() ->
        {:refused,
         stale("attachment-generation-stale", %{
           "attached_in" => att["world_ref"],
           "current" => World.lineage(),
           "hint" =>
             "occupancy does not cross a world discontinuity — re-attach on the far side"
         })}

      w == nil ->
        {:refused, stale("worker-unknown", %{"worker_ref" => att["worker_ref"]})}

      w["status"] != "open" ->
        {:refused,
         stale("worker-not-open", %{"worker_ref" => w["id"], "status" => w["status"]})}

      (w["generation"] || 1) != att["worker_generation"] ->
        {:refused,
         stale("attachment-worker-generation-stale", %{
           "worker_ref" => w["id"],
           "attached_under" => att["worker_generation"],
           "current" => w["generation"],
           "hint" =>
             "this assignment was closed and re-opened — a reopened position is grounds " <>
               "for a new attachment, never for reviving an old one"
         })}

      w["locus_ref"] != lane["id"] or w["actor"] != lane["actor"] ->
        {:refused,
         stale("worker-lane-actor-drift", %{
           "worker_ref" => w["id"],
           "locus_ref" => lane["id"]
         })}

      true ->
        :ok
    end
  end

  # ------------------------------------------------------------ project
  @doc """
  `"OCCUPIED"` or `"OFFLINE"` — what the cockpit renders beside a Worker.

  Derived from live attachments and re-validated through `occupancy/2`, so
  a Worker whose only attachment is stale renders `OFFLINE` rather than
  showing a person a position as filled when nothing can act from it. A
  status line that disagrees with what the runtime would refuse is worse
  than no status line.
  """
  def status_of(worker) when is_map(worker) do
    lane = Loci.lane(worker["locus_ref"])

    live? =
      lane != nil and
        Enum.any?(Peer.attachments(), fn att ->
          att["worker_ref"] == worker["id"] and
            occupancy(Peer.resolve(att["peer_ref"]) || %{}, lane) == :ok
        end)

    if live?, do: "OCCUPIED", else: "OFFLINE"
  end

  @doc """
  Add both statuses, as **two separate fields**.

  `occupancy` is D.1.2's question — does a Peer hold this position. `carrier`
  is D.1.3b's — is there a live execution process fulfilling it. They are not
  synonyms and merging them into one word would erase the ordinary state:

      occupancy OCCUPIED  ∧  carrier OFFLINE

  which is an actor holding a position with nothing running, and is what every
  Worker looks like before anything starts. A projection with a single status
  would have to call that either OCCUPIED (hiding that nothing runs) or
  OFFLINE (hiding that someone holds it), and both are wrong in a direction a
  cockpit would render as fact.
  """
  def projected(workers) when is_map(workers),
    do:
      Map.new(workers, fn {id, w} ->
        {id, w |> Map.put("occupancy", status_of(w)) |> Map.put("carrier", Ampd.Carrier.status_of(w))}
      end)

  # ------------------------------------------------------------ refusals
  defp no_actor(peer) do
    refuse("carrier-has-no-actor", %{
      "channel" => peer && peer["channel"],
      "hint" =>
        "the human control channel holds no actor and occupies nothing — " <>
          "a person is the source of consent, not an occupant of a position"
    })
  end

  # Keeps D.1.1's code word for the stranger case, so a caller that could
  # already handle `locus-not-occupied` still can, and the D.1.1 falsifiers
  # that assert it still hold. What changed is only *when* it is produced.
  defp not_occupied(peer, lane, _detail) do
    refuse("locus-not-occupied", %{
      "locus_ref" => lane["id"],
      "bound_actor" => peer && peer["actor"]
    })
  end

  defp stale(code, detail), do: refuse(code, detail)

  defp refuse(code, detail) do
    Refusal.new(code,
      component: "Ampd.Worker",
      retryable: false,
      requires_human:
        code in ~w(worker-not-open attachment-generation-stale
                   attachment-worker-generation-stale worker-lane-actor-drift),
      operator_detail: detail
    )
  end
end
