defmodule Ampd.Validation do
  @moduledoc """
  `validation_job_started@1` / `validation_job_outcome@1` — **the durable
  vocabulary for validation work, before any validation runs.**

  R0b.R · R7. Super is about to validate its own source. This module is the
  place that says what may be written down about that, and it exists one
  round *before* the first predicate executes on purpose: R6 found that a
  record kind introduced without a home gets read as some other kind's, and
  it found it by discovering that `worktree_created@1` had been invisible to
  its own agent since the day it was introduced.

  ## Three vocabularies, kept apart

  The word "kind" was available to mean all three of these, and one field
  meaning three things is how a ledger stops being able to answer questions
  about itself:

      kind             the RECORD's type    validation_job_started@1
      validation_kind  the WORK's type      source-hygiene
      state / verdict  how it WENT          completed · pass

  `kind` belongs to `Ampd.Receipts` and names a row shape. `validation_kind`
  names what was checked. Collapsing them — writing `kind = source-hygiene`
  — would leave no way to tell a start from an outcome at the ledger layer,
  and no room for the progress or evidence records a later round may add.

  ## Two records, never one mutated record

  A start and an outcome are separate appends sharing a `job_ref`. Nothing
  turns STARTED into COMPLETED, because the ledger is append-only and
  because **a start with no outcome is itself a true statement**: execution
  began and this ledger does not know how it ended. That is the honest
  representation of a Carrier that died mid-job, and it is strictly more
  informative than an `INDETERMINATE` outcome invented to fill the row —
  which would additionally be a *claim*, made by a process that was not
  there, about a moment nothing observed.

  So there is no `INDETERMINATE` in this vocabulary. If a later round finds
  an execution cut where a durable outcome is genuinely required despite the
  truth being unknowable, it can name one then, with the cut as its
  argument.

  ## `state` and `verdict` are orthogonal, and that is the whole design

  The predicate being false is not the job failing. A `source-hygiene` job
  that runs correctly and finds a NUL byte **did its work**:

      ran · no NUL found            state completed · verdict pass
      ran · a NUL in an in-scope file   state completed · verdict fail
      the snapshot moved underneath it  state failed    · reason …
      the Carrier died                  STARTED, and no outcome

  Flattening these into one enum — `PASS | FAIL | SOURCE_BASIS_MISMATCH` —
  puts "the property does not hold" and "we could not ask" at the same
  semantic level, and then every reader downstream has to know which members
  are verdicts and which are excuses. Worse, a basis mismatch recorded as
  `fail` is a **false statement about the source**: it asserts a property of
  bytes that were never read.

  ## The failure reasons are quoted, not invented

  Every member of `reasons/0` is a failure a line of code in this tree can
  actually produce today. They are the cuts `host/src/effect.rs`
  `verify_source_basis` takes, plus the resolution step above it, plus the
  runtime's own — a job may name a basis this store cannot resolve, which is
  reachable whenever the worktree store is sealed between a start and an
  execution.

  Deliberately absent, and each for the same reason — **nothing can produce
  it yet, so admitting it would make the enum a wish list**:

    * `scope-mismatch` — nothing re-derives a scope manifest at execution
      time until R0b.1. When it does, the cut is real and gets a name then.
    * `carrier-failure` — this round starts no Carrier. A death during
      execution is already represented, as a start with no outcome.

  A reason outside the enum is **refused**, not recorded. An enum that
  accepts anything is a comment.
  """

  alias Ampd.{Receipts, Worktree}

  @started_kind "validation_job_started@1"
  @outcome_kind "validation_job_outcome@1"

  @doc "The record kind for a durable execution start."
  def started_kind, do: @started_kind

  @doc "The record kind for a durable execution outcome."
  def outcome_kind, do: @outcome_kind

  @doc "Both kinds. The set `Ampd.Projection` routes to the validation surface."
  def kinds, do: [@started_kind, @outcome_kind]

  # The work's type. One member, closed. `source-hygiene` is the predicate
  # `tools/check-source-hygiene.mjs` evaluates and `tools/scope-manifest.mjs`
  # scopes; Phase A froze its vectors.
  @validation_kinds ~w(source-hygiene)
  def validation_kinds, do: @validation_kinds

  @states ~w(completed failed)
  def states, do: @states

  @verdicts ~w(pass fail)
  def verdicts, do: @verdicts

  # Each one is a `format!` or an early return that exists right now:
  #
  #   source-basis-unknown                       this module, below
  #   source-basis-revision-not-exact            host/src/effect.rs
  #   source-basis-materialization-absent        host/src/effect.rs
  #   source-basis-revision-moved                host/src/effect.rs
  #   source-basis-materialization-dirty         host/src/effect.rs
  #   source-basis-materialization-unresolvable  host/src/lib.rs
  @reasons ~w(source-basis-unknown
              source-basis-revision-not-exact
              source-basis-materialization-absent
              source-basis-materialization-unresolvable
              source-basis-revision-moved
              source-basis-materialization-dirty)
  def reasons, do: @reasons

  # ------------------------------------------------------------- reading
  @doc "Every validation record, of both kinds, in ledger order."
  def all, do: Enum.filter(Receipts.all(), &(&1["kind"] in kinds()))

  @doc "The durable start for one job, or `nil`."
  def started(job_ref),
    do: Enum.find(Receipts.of_kind(@started_kind), &(&1["job_ref"] == job_ref))

  @doc "The durable outcome for one job, or `nil`."
  def outcome(job_ref),
    do: Enum.find(Receipts.of_kind(@outcome_kind), &(&1["job_ref"] == job_ref))

  @doc """
  Whether a job may be handed to an executor.

  **A job is admissible only once its start is durable.** R11.2: the append
  happens before any Carrier is spawned, so a job that ran and left no trace
  of having begun is not representable. This is the predicate that makes
  that ordering checkable now, one round before there is an executor to
  check it against.
  """
  def admissible?(job_ref), do: started(job_ref) != nil and outcome(job_ref) == nil

  # ------------------------------------------------------------- writing
  @doc """
  Append `validation_job_started@1` for an already-minted JobBasis.

  Called inside the ordered transaction that mints the job. The fields are
  the job's own semantic identity — nothing is re-derived here, because two
  places deriving one fact is what R2 and R5 were both about.

  Refuses if a start for this `job_ref` is already durable. A second start
  would mean one `job_ref` naming two executions, and `Ampd.Worktree` mints
  a job per execution precisely so that never has to be disambiguated after
  the fact.
  """
  def record_start(job) when is_map(job) do
    cond do
      started(job["ref"]) != nil ->
        {:error, "validation-job-already-started", %{"job_ref" => job["ref"]}}

      true ->
        {:ok,
         Receipts.emit(%{
           "kind" => @started_kind,
           "job_ref" => job["ref"],
           "validation_kind" => job["validation_kind"],
           "actor" => job["actor"],
           "worker_ref" => job["worker_ref"],
           "worker_generation" => job["worker_generation"],
           "source_basis_ref" => job["source_basis_ref"],
           "scope_digest" => job["scope_digest"]
         })}
    end
  end

  @doc """
  Append `validation_job_outcome@1`.

  `result` is `%{"state" => "completed", "verdict" => "pass"}` or
  `%{"state" => "failed", "reason" => <typed>}`. The two shapes do not
  overlap: a completed outcome carrying a `reason`, or a failed one carrying
  a `verdict`, is refused rather than stored with the extra field dropped.
  Silently dropping it would make the ledger disagree with its writer about
  what was recorded.

  ## What is checked, and why each check is not decoration

      the job exists                a job_ref naming nothing is a record
                                    about no work
      a start is durable            an outcome for an execution that never
                                    durably began is a claim with no
                                    subject — R7.3
      no outcome yet                one attempt, one terminal fact. A
                                    second is refused rather than appended,
                                    because two contradictory outcomes for
                                    one job_ref cannot both be true and the
                                    ledger cannot choose
      state / verdict / reason      closed enums, checked against the sets
                                    above

  **Single-attempt is stated, not assumed.** `Ampd.Worktree` mints one job
  per `open_validation_job/1` call, so a retry is a new `vj_` with its own
  start and its own outcome, and the two attempts stay distinguishable in
  history. Nothing in this round needs a multi-attempt job, and giving one
  `job_ref` two executions would be exactly the collapse R7 exists to
  refuse.
  """
  def record_outcome(job_ref, result) when is_binary(job_ref) and is_map(result) do
    state = result["state"]
    verdict = result["verdict"]
    reason = result["reason"]

    cond do
      Worktree.validation_job(job_ref) == nil ->
        {:error, "validation-job-unknown", %{"job_ref" => job_ref}}

      started(job_ref) == nil ->
        {:error, "validation-job-not-started", %{"job_ref" => job_ref}}

      outcome(job_ref) != nil ->
        {:error, "validation-job-already-decided",
         %{"job_ref" => job_ref, "state" => outcome(job_ref)["state"]}}

      state not in @states ->
        {:error, "validation-state-unknown", %{"state" => state, "known" => @states}}

      state == "completed" and verdict not in @verdicts ->
        {:error, "validation-verdict-unknown", %{"verdict" => verdict, "known" => @verdicts}}

      state == "completed" and reason != nil ->
        # A completed job has no failure reason. Accepting one would let a
        # basis mismatch ride into the ledger wearing a verdict.
        {:error, "validation-outcome-overspecified",
         %{"state" => state, "reason" => reason, "hint" => "a completed outcome carries a verdict"}}

      state == "failed" and reason not in @reasons ->
        {:error, "validation-reason-unknown", %{"reason" => reason, "known" => @reasons}}

      state == "failed" and verdict != nil ->
        # The inverse, and the more dangerous direction: a failed job that
        # also carried `verdict` would let a reader take the verdict and
        # believe the predicate was evaluated.
        {:error, "validation-outcome-overspecified",
         %{"state" => state, "verdict" => verdict, "hint" => "a failed outcome carries a reason"}}

      true ->
        start = started(job_ref)

        # The subject is copied from the START, not from the caller. A
        # caller-supplied actor on the outcome would let one job's history
        # end up in two agents' projections.
        base = %{
          "kind" => @outcome_kind,
          "job_ref" => job_ref,
          "validation_kind" => start["validation_kind"],
          "actor" => start["actor"],
          "worker_ref" => start["worker_ref"],
          "worker_generation" => start["worker_generation"],
          "source_basis_ref" => start["source_basis_ref"],
          "scope_digest" => start["scope_digest"],
          "state" => state
        }

        fields =
          case state do
            "completed" -> Map.put(base, "verdict", verdict)
            "failed" -> Map.put(base, "reason", reason)
          end

        {:ok, Receipts.emit(fields)}
    end
  end
end
