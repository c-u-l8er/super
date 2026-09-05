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

  **Three conditions, and the first one had to be added.** R11.2 is about
  the second: the start is appended before any Carrier is spawned, so a job
  that ran and left no trace of having begun is not representable.

      a JobBasis exists      there is work, over a named SourceBasis,
                             owned by a Lane, at a Worker generation
      a START is durable     execution was admitted
      no OUTCOME             it has not already been decided

  The JobBasis clause is R0b.R·1's, and it is here because this function
  said "may be handed to an executor" while asking only about receipts.
  A directly-emitted `validation_job_started@1` naming `vj_fake` made this
  answer **true** for a job that did not exist — no basis, no Lane, no
  Worker. `Ampd.Receipts` now refuses to mint that record at all, and this
  is the second lock: **a ledger row may not create executable work by
  itself.** Either one alone would close the measured hole; both are here
  because they answer different questions, and the executor deserves to be
  told about a job whose basis is gone rather than about one whose receipt
  merely looks right.

  R0b.1 extends this with execution-time facts — that the Worker generation
  is still current, that the SourceBasis resolves, that the materialization
  still proves itself, that the scope digest re-derives. Those are not
  pre-invented here: none of them has a producer yet.
  """
  def admissible?(job_ref) do
    Worktree.validation_job(job_ref) != nil and
      started(job_ref) != nil and
      outcome(job_ref) == nil
  end

  # ---------------------------------------------------------- validating
  @doc """
  Whether an outcome's `result` is well-formed. `:ok` or a named refusal.

  **Pure, and it stays here while the writing moved to `Ampd.Receipts`.**
  R0b.R·1 moved the append to the ledger, because invariants a caller can
  route around are not invariants. What did not move is the vocabulary: this
  module still says what a state, a verdict and a reason may be, and the
  store asks it rather than keeping a second copy — two implementations of
  one fact is the defect R2 and R5 were both about.

  ## The two shapes do not overlap

  A completed outcome carrying a `reason`, or a failed one carrying a
  `verdict`, is refused rather than stored with the extra field dropped.
  Silently dropping it would make the ledger disagree with its writer about
  what was recorded — and the second direction is the dangerous one: a failed
  job that also carried `verdict` would let a reader take the verdict and
  believe the predicate was evaluated.
  """
  def validate_result(result) when is_map(result) do
    state = result["state"]
    verdict = result["verdict"]
    reason = result["reason"]

    cond do
      state not in @states ->
        {:error, "validation-state-unknown", %{"state" => state, "known" => @states}}

      state == "completed" and verdict not in @verdicts ->
        {:error, "validation-verdict-unknown", %{"verdict" => verdict, "known" => @verdicts}}

      state == "completed" and reason != nil ->
        {:error, "validation-outcome-overspecified",
         %{"state" => state, "reason" => reason, "hint" => "a completed outcome carries a verdict"}}

      state == "failed" and reason not in @reasons ->
        {:error, "validation-reason-unknown", %{"reason" => reason, "known" => @reasons}}

      state == "failed" and verdict != nil ->
        {:error, "validation-outcome-overspecified",
         %{"state" => state, "verdict" => verdict, "hint" => "a failed outcome carries a reason"}}

      true ->
        :ok
    end
  end
end
