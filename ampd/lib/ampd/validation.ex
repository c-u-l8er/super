defmodule Ampd.Validation do
  @moduledoc """
  `validation-job-started@1` · `validation-job-outcome@1` — durable truth
  about a bounded validation job.

  R0b.R · R7. Two append-only records in `Ampd.Receipts`, never one record
  mutated from one state into another.

  ## Why append-only, stated as a property rather than a preference

  A record that is rewritten cannot be evidence of what was true earlier: a
  reader who saw `STARTED` and a reader who sees `COMPLETED` are looking at
  the same row and cannot both be right about the past. Two rows keep both
  facts, and the ledger's `seq` (R5) already orders them.

  It also makes the crash cuts expressible, which a mutable row would not.

  ## The failure cuts, classified BEFORE choosing any vocabulary

  A job runs across a durable write, a confined process, and a second
  durable write. A crash can land anywhere:

      A  before the started record        nothing in the ledger. The job did
                                          not start, and no reader is misled
      B  started, before the Carrier ran  started · no outcome
      C  started, during the scan         started · no outcome
      D  started, scan finished, before   started · no outcome
         the outcome record                — and here completion is
                                             GENUINELY unknowable
      E  outcome written                  resolved

  **B, C and D are indistinguishable from the ledger, and that is correct
  rather than a gap.** In cut D the work really did complete and nothing
  recorded what it found; no later reader can recover it, and neither can
  anything that might write a record afterwards.

  So there is **no `INDETERMINATE` value**. The unresolved state is
  expressed by the *absence* of an outcome, because absence is exactly what
  is known — and a value would have to be written by something that knows
  no more than a reader of the absence does. Inventing one would put a
  confident-looking word where the honest answer is silence.

  ## Two fields, because "did the work happen" and "what did it find" are
  ## different questions

      state    COMPLETED · FAILED · SOURCE_BASIS_MISMATCH
      verdict  HELD · REFUTED          present iff state is COMPLETED

  `SOURCE_BASIS_MISMATCH` is separated from `FAILED` for the reason this
  whole round keeps rediscovering: **a changed input is not a property
  becoming false.** A job whose per-file digest does not match the admitted
  scope manifest has not found a NUL byte and has not failed to run — it has
  been asked about bytes nobody admitted, and the only honest report is that
  its basis moved.

  And `REFUTED` is not `FAILED`. A source-hygiene job that finds a literal
  NUL ran perfectly and is telling the truth; collapsing the two would make
  "the job worked" and "the tree is clean" the same sentence, which is the
  ambiguity `committed` was dropped for.

  ## Terminal text is not the verdict

  The Carrier's stdout travels the frozen OBSERVE path and a person may read
  it. It is presentation. The verdict is the record here, and nothing
  downstream may derive one from the other.
  """

  alias Ampd.Receipts

  @started "validation-job-started@1"
  @outcome "validation-job-outcome@1"

  @doc "The kind of a start record."
  def started_kind, do: @started

  @doc "The kind of an outcome record."
  def outcome_kind, do: @outcome

  @doc """
  Every state an outcome may report. Three, and each is reachable.

  Deliberately closed: an outcome carrying an unlisted state is refused
  rather than stored, because a ledger that accepts an unknown state has a
  reader somewhere that will treat it as one of these.
  """
  @states ~w(COMPLETED FAILED SOURCE_BASIS_MISMATCH)
  def states, do: @states

  @doc "Every verdict a COMPLETED job may carry. Two."
  @verdicts ~w(HELD REFUTED)
  def verdicts, do: @verdicts

  @doc """
  Fields that identify what a validation record is about.

  **No physical path, and none derivable from these.** R10: the
  materialization is named by `source_basis_ref`, whose host path lives on
  the worktree resource where `Ampd.Locus.view/1` drops it. `scope_digest`
  identifies the admitted file set without listing a single absolute name.
  """
  @identity ~w(job_ref source_basis_ref scope_digest)
  def identity_fields, do: @identity

  @doc """
  Record that a job started.

  `worker_ref` is the subject — R8. **Not `actor`**, which is what the
  capability surface uses and what `worktree_created@1` pointedly does not.
  A Worker is the position the work is being done at, and the actor is
  derivable from it; carrying a second denormalized principal here would be
  the `locus_actor`/`actor` divergence again, invented on purpose this time.
  """
  def started(%{} = f) do
    with :ok <- require_identity(f) do
      {:ok,
       Receipts.emit(
         f
         |> Map.take(@identity ++ ["worker_ref", "job_kind"])
         |> Map.put("kind", @started)
       )}
    end
  end

  @doc """
  Record what a job found, or why it could not say.

  A second row. The started record is never touched — see the moduledoc for
  why a rewritten row cannot be evidence of what was true before it.
  """
  def outcome(%{} = f) do
    state = f["state"]
    verdict = f["verdict"]

    cond do
      state not in @states ->
        {:error, "validation-outcome-state-unknown", %{"state" => state}}

      state == "COMPLETED" and verdict not in @verdicts ->
        {:error, "validation-outcome-verdict-required",
         %{"state" => state, "verdict" => verdict}}

      state != "COMPLETED" and verdict != nil ->
        # A job that did not complete has no finding, and a verdict beside a
        # FAILED state is exactly the row a later reader would quote out of
        # context.
        {:error, "validation-outcome-verdict-not-permitted",
         %{"state" => state, "verdict" => verdict}}

      true ->
        with :ok <- require_identity(f) do
          {:ok,
           Receipts.emit(
             f
             |> Map.take(@identity ++ ["worker_ref", "job_kind", "state", "verdict", "detail"])
             |> Map.put("kind", @outcome)
           )}
        end
    end
  end

  @doc "Both records for one job, in append order."
  def of_job(job_ref) do
    Receipts.all()
    |> Enum.filter(&(&1["kind"] in [@started, @outcome] and &1["job_ref"] == job_ref))
  end

  @doc """
  What the ledger knows about a job.

      :unknown                      nothing was ever recorded — crash cut A
      :unresolved                   started, no outcome — cuts B, C and D
      {:completed, "HELD"}          it ran and the property holds
      {:completed, "REFUTED"}       it ran and the property does not hold
      {:failed, detail}
      {:basis_mismatch, detail}

  `:unresolved` is the absence of an outcome and not a stored value. See the
  moduledoc: in cut D the work completed and nothing recorded what it found,
  so the honest report is that this is not known.
  """
  def state_of(job_ref) do
    recs = of_job(job_ref)

    case Enum.find(recs, &(&1["kind"] == @outcome)) do
      nil ->
        if Enum.any?(recs, &(&1["kind"] == @started)), do: :unresolved, else: :unknown

      o ->
        case o["state"] do
          "COMPLETED" -> {:completed, o["verdict"]}
          "FAILED" -> {:failed, o["detail"]}
          "SOURCE_BASIS_MISMATCH" -> {:basis_mismatch, o["detail"]}
        end
    end
  end

  defp require_identity(f) do
    case Enum.find(@identity, &(f[&1] in [nil, ""])) do
      nil -> :ok
      missing -> {:error, "validation-identity-incomplete", %{"missing" => missing}}
    end
  end
end
