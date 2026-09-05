defmodule Ampd.ValidationJobTest do
  @moduledoc """
  R0b.R · R7–R11 — **the durable vocabulary for validation work, before any
  validation runs.**

  Super is about to validate its own source. This suite is what "the ledger
  can hold the answer honestly" means, written one round before there is an
  answer, because R6 measured what happens otherwise: `worktree_created@1`
  was introduced without a projection of its own and was invisible to its own
  agent from that day until this round — silently, because a filter returning
  nothing looks exactly like there being nothing to return.

  ## The three things kept apart, and the falsifier for each

      kind             the RECORD's type       routing
      validation_kind  the WORK's type         a closed enum
      state / verdict  how it WENT             two orthogonal fields

  The last is the one worth the most. A `source-hygiene` job that runs
  correctly and finds a NUL byte **did its work** — `completed` + `fail`.
  A job whose snapshot moved underneath it did not — `failed` + a typed
  reason. Recording the second as `fail` would be a false statement about
  bytes nobody read, so it is refused rather than stored.
  """

  use ExUnit.Case, async: false

  alias Ampd.{Authority, Control, Locus, Projection, Receipts, Validation, Worktree}

  @digest String.duplicate("ab", 32)

  setup do
    Ampd.reset()
    Ampd.Bridge.reset()
    Ampd.Peer.reset()
    Application.delete_env(:ampd, :profile_overrides)
    Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Effector.Host)
    Process.sleep(120)

    Authority.install_worktree()
    repo = init_repo!()
    {:ok, r} = Authority.register_repository(repo)

    {control, agent} = Ampd.attach_pair("kestrel")
    ws = ok!(Control.command(control, :open_workspace, ["acme"]), "workspace")
    goal = ok!(Control.command(control, :open_goal, [ws["id"], "validate my own source"]), "goal")
    lane = ok!(Control.command(control, :open_lane, [goal["id"], "kestrel", r["ref"], nil]), "lane")
    worker = ok!(Control.command(control, :open_worker, [lane["id"], "implement"]), "worker")
    ok!(Control.command(agent, :attach_worker, [worker["id"]]), "worker")

    grant_worktree!(lane["id"])
    est = Control.command(agent, :establish_worktree, [lane["id"], "hygiene-a"])
    assert est["allow"] == true, "establishment refused: #{inspect(est["refusal"])}"

    {:ok, basis} = Authority.bind_source_basis(%{"resource_ref" => est["resource"]["ref"]})

    %{repo: repo, ws: ws, lane: lane, worker: worker, basis: basis, control: control, agent: agent}
  end

  defp fields(ctx, over \\ %{}) do
    Map.merge(
      %{
        "validation_kind" => "source-hygiene",
        "source_basis_ref" => ctx.basis["ref"],
        "worker_ref" => ctx.worker["id"],
        "scope_digest" => @digest
      },
      over
    )
  end

  defp start!(ctx, over \\ %{}) do
    {:ok, %{"job" => job, "started" => started}} =
      Authority.start_validation_job(fields(ctx, over))

    {job, started}
  end

  # ====================================================================== R11
  describe "R11 · the JobBasis — what work exists, over what exact input" do
    test "names the semantic input and nothing about how to run it", ctx do
      {job, _} = start!(ctx)

      assert job["schema"] == "validation-job@1"
      assert String.starts_with?(job["ref"], "vj_")
      assert job["validation_kind"] == "source-hygiene"
      assert job["source_basis_ref"] == ctx.basis["ref"]
      assert job["scope_digest"] == @digest

      # Implementation identity is ExecutionBasis's and the installed
      # payload's. A job that carried it would be making a claim about what
      # ran, which is measured through the Carrier's own /proc instead.
      for k <- ~w(executable argv env command payload payload_digest cmd script) do
        refute Map.has_key?(job, k), "validation-job@1 must not carry #{k}"
      end
    end

    test "a caller that supplies a path does not get it stored", ctx do
      # Ported from the parallel R7 implementation on `main` (`a43ccfc`),
      # whose vocabulary was retired in favour of GPT's but whose coverage
      # was not. Its version proved the field was DROPPED by a `Map.take`;
      # here the records are built field by field, so the same guarantee
      # holds by construction — and this is what says so out loud, because
      # "the constructor is explicit" is the kind of property a refactor
      # removes without noticing.
      {job, started} = start!(ctx, %{"path" => "/etc/passwd", "materialization" => "/tmp/x"})

      {:ok, out} =
        Authority.record_validation_outcome(
          job["ref"],
          Map.merge(pass(), %{"path" => "/etc/shadow", "detail" => "/var/log"})
        )

      for r <- [job, started, out], k <- ~w(path materialization detail) do
        refute Map.has_key?(r, k), "#{k} reached a validation record"
      end
    end

    test "generic emit cannot mint a validation START", ctx do
      _ = ctx
      # **This test used to be the bug.** Its ancestor emitted a
      # `validation_job_started@1` through the generic path and then asserted
      # the record was part of `Validation.all/0` — normalising the very
      # bypass R0b.R·1 exists to close. A forged start made a job that never
      # existed report `admissible? == true`.
      assert {:error, "receipt-kind-requires-typed-admission", d} =
               Receipts.emit(%{"kind" => Validation.started_kind(), "job_ref" => "vj_fake"})

      assert d["kind"] == Validation.started_kind()
      assert Validation.started_kind() in d["protected"]

      # Refused, not silently re-kinded and not dropped: nothing was written.
      assert Validation.started("vj_fake") == nil
      refute Enum.any?(Receipts.all(), &(&1["job_ref"] == "vj_fake"))
    end

    test "generic emit cannot mint a validation OUTCOME", ctx do
      _ = ctx

      assert {:error, "receipt-kind-requires-typed-admission", _} =
               Receipts.emit(%{
                 "kind" => Validation.outcome_kind(),
                 "job_ref" => "vj_fake",
                 "state" => "completed",
                 "verdict" => "pass"
               })

      assert Validation.outcome("vj_fake") == nil
    end

    test "a forged start cannot make an unknown job admissible", ctx do
      _ = ctx
      # The measured bug, as a falsifier. Two independent locks: the ledger
      # will not mint the record, and `admissible?/1` requires a JobBasis
      # even if one somehow existed.
      Receipts.emit(%{"kind" => Validation.started_kind(), "job_ref" => "vj_fake"})
      refute Validation.admissible?("vj_fake")
      assert Worktree.validation_job("vj_fake") == nil
    end

    test "a durable START whose JobBasis is gone is not admissible", ctx do
      _ = ctx
      # **The JobBasis clause, isolated.** With `emit/1` guarded, a forged
      # START cannot be appended, so the two locks are redundant for the test
      # above and stubbing either one leaves it green — which the sabotage
      # battery reported as NOT A FALSIFIER, correctly.
      #
      # This is the state that makes the clause load-bearing, and it is not
      # hypothetical: `Ampd.Worktree` can SEAL, and a sealed worktree store
      # serves `sealed_state/0` — an empty `jobs` table — while the receipts
      # ledger still holds every START ever appended. The two stores diverge,
      # and the executor must be told about the job whose basis is gone
      # rather than about the receipt that still looks right.
      #
      # Injected through `load_state/1`, the same ordered fixture path
      # `receipts_ledger_test.exs` uses, because a state this round has just
      # made unreachable through the API is exactly the state worth pinning.
      probe = Receipts.emit(%{"kind" => "shape@1"})
      assert probe["id"] == "rcpt-" <> String.pad_leading(to_string(probe["seq"]), 4, "0")

      Ampd.AuthorityCoordinator.transact(fn ->
        Receipts.load_state(%{
          "log" => [
            %{
              "kind" => Validation.started_kind(),
              "id" => "rcpt-0000",
              "seq" => 0,
              "job_ref" => "vj_orphaned",
              "actor" => "kestrel"
            }
          ],
          "seq" => 1
        })
      end)

      # The START is genuinely durable — this is not the forged-emit case.
      assert Validation.started("vj_orphaned") != nil
      assert Validation.outcome("vj_orphaned") == nil

      # And the job is not. So it is not executable work.
      assert Worktree.validation_job("vj_orphaned") == nil
      refute Validation.admissible?("vj_orphaned")
    end

    test "a ledger row alone does not create executable work", ctx do
      # A real job, a real durable start — and then the JobBasis clause
      # checked directly, because `admissible?/1` claims to answer whether a
      # job may be handed to an executor and a receipt is not a job.
      {job, _} = start!(ctx)
      assert Validation.admissible?(job["ref"])

      # An unrelated ref with a real-looking shape is not admissible, and
      # neither is one whose receipts exist but whose basis does not.
      refute Validation.admissible?("vj_0099")
      refute Validation.admissible?(job["ref"] <> "x")
    end

    test "an ordinary receipt is unaffected by the protection", ctx do
      _ = ctx
      # The guard is on two kinds, not on the ledger. R2's rule — the kind
      # stays the producer's — still holds everywhere else.
      r = Receipts.emit(%{"kind" => "test@1", "actor" => "kestrel"})
      assert r["kind"] == "test@1"
      assert String.starts_with?(r["id"], "rcpt-")

      d = Receipts.emit(%{"actor" => "kestrel", "capability" => "github.pr.create"})
      assert d["kind"] == Receipts.default_kind()
    end

    test "carries no host path, and nothing from which one could be built", ctx do
      {job, started} = start!(ctx)

      for record <- [job, started], {k, v} <- record, is_binary(v) do
        refute String.starts_with?(v, "/"), "#{k} looks like an absolute path: #{v}"
      end

      for record <- [job, started],
          k <- ~w(path target root source_path worktree_root cwd host_path materialization) do
        refute Map.has_key?(record, k), "#{k} must not appear on a validation record"
      end
    end

    test "is durable and readable by ref", ctx do
      {job, _} = start!(ctx)
      assert Worktree.validation_job(job["ref"]) == job
      assert Map.has_key?(Worktree.validation_jobs(), job["ref"])
    end

    test "binds the Worker's generation, not only its ref", ctx do
      {job, started} = start!(ctx)

      # Derived from `Ampd.Worker.reopen/1`: a reopened position is grounds
      # for a new attachment, never for reviving an old one. A job naming
      # only `worker_ref` would let a close/reopen between start and outcome
      # read as one continuous position having done the work.
      assert job["worker_generation"] == ctx.worker["generation"] || 1
      assert is_integer(started["worker_generation"])

      {:ok, _} = Authority.close_worker(ctx.worker["id"])
      {:ok, reopened} = Authority.reopen_worker(ctx.worker["id"])

      assert reopened["generation"] > job["worker_generation"],
             "reopen must advance the generation, or binding it proves nothing"
    end

    test "the Actor is the Lane's, never the caller's", ctx do
      {job, started} = start!(ctx, %{"actor" => "mallory"})
      assert job["actor"] == "kestrel"
      assert started["actor"] == "kestrel"
    end
  end

  describe "R11 · refusals — a job is over one Lane's own snapshot" do
    test "refuses a validation kind outside the closed enum", ctx do
      assert {:error, "validation-kind-unknown", d} =
               Authority.start_validation_job(fields(ctx, %{"validation_kind" => "type-check"}))

      assert d["known"] == ["source-hygiene"]
    end

    test "refuses a basis that does not exist", ctx do
      assert {:error, "source-basis-unknown", _} =
               Authority.start_validation_job(fields(ctx, %{"source_basis_ref" => "sb_9999"}))
    end

    test "refuses a worker that does not exist", ctx do
      assert {:error, "worker-unknown", _} =
               Authority.start_validation_job(fields(ctx, %{"worker_ref" => "wk_9999"}))
    end

    test "refuses a closed worker — work has a position or nowhere to happen", ctx do
      {:ok, _} = Authority.close_worker(ctx.worker["id"])

      assert {:error, "worker-not-open", _} =
               Authority.start_validation_job(fields(ctx))
    end

    test "refuses a scope digest that could never match", ctx do
      for bad <- [nil, "", "not-a-digest", String.duplicate("A", 64), String.duplicate("a", 63)] do
        assert {:error, "scope-digest-malformed", _} =
                 Authority.start_validation_job(fields(ctx, %{"scope_digest" => bad})),
               "#{inspect(bad)} is not a 64-char lowercase hex digest"
      end
    end

    test "refuses a Worker whose Lane does not own the basis", ctx do
      # A second Lane, a second worktree, a second basis — and then a job
      # crossing them. The check is not cosmetic: without it, minting a job
      # is enough to cause a read capability over another Lane's snapshot.
      goal = ok!(Control.command(ctx.control, :open_goal, [ctx.ws["id"], "a second goal"]), "goal")

      {:ok, repo2} = Authority.register_repository(init_repo!("second"))
      lane2 = ok!(Control.command(ctx.control, :open_lane,
                    [goal["id"], "kestrel", repo2["ref"], nil]), "lane")
      w2 = ok!(Control.command(ctx.control, :open_worker, [lane2["id"], "implement"]), "worker")

      grant_worktree!(lane2["id"])

      # One Carrier occupies one position at a time, so the agent leaves the
      # first Worker before taking up the second. Lane 1's basis is already
      # bound and outlives the detach — which is the point: a snapshot is not
      # held open by whoever happens to be attached.
      a2 = ctx.agent
      ok!(Control.command(a2, :detach_worker, []), "released")
      ok!(Control.command(a2, :attach_worker, [w2["id"]]), "worker")
      est2 = Control.command(a2, :establish_worktree, [lane2["id"], "hygiene-b"])
      assert est2["allow"] == true, "second establishment refused: #{inspect(est2["refusal"])}"

      # Lane 1's basis, Lane 2's Worker.
      assert {:error, "validation-job-lane-mismatch", d} =
               Authority.start_validation_job(fields(ctx, %{"worker_ref" => w2["id"]}))

      assert d["basis_locus"] == ctx.lane["id"]
      assert d["worker_locus"] == lane2["id"]
    end
  end

  # ====================================================================== R7
  describe "R7 · two records, never one mutated record" do
    test "a start is a durable historical fact with its own kind", ctx do
      {job, started} = start!(ctx)

      assert started["kind"] == "validation_job_started@1"
      assert started["job_ref"] == job["ref"]
      assert started["validation_kind"] == "source-hygiene"
      assert is_integer(started["seq"])

      # The three vocabularies stay three. `kind` is the row shape;
      # `validation_kind` is the work. Overloading one field for both is how
      # a ledger loses the ability to tell a start from an outcome.
      refute started["kind"] == started["validation_kind"]
    end

    test "a start with no outcome is a truthful state, not a missing row", ctx do
      {job, _} = start!(ctx)

      assert Validation.started(job["ref"]) != nil
      assert Validation.outcome(job["ref"]) == nil
      assert Validation.admissible?(job["ref"])
    end

    test "nothing mutates a start into an outcome — they are two appends", ctx do
      {job, started} = start!(ctx)
      {:ok, out} = Authority.record_validation_outcome(job["ref"], pass())

      # The start is byte-identical afterwards, still in the ledger, and the
      # outcome is a separate record with its own id and a later seq.
      assert Validation.started(job["ref"]) == started
      refute out["id"] == started["id"]
      assert out["seq"] > started["seq"]
      assert length(Validation.all()) == 2
    end

    test "a second start for one job_ref is refused", ctx do
      {job, _} = start!(ctx)

      assert {:error, "validation-job-already-started", _} =
               Ampd.AuthorityCoordinator.transact(
                 fn -> Receipts.record_validation_start(job["ref"]) end,
                 nil
               )
    end
  end

  # ==================================================================== R7.2
  describe "R7.2 · execution outcome is not predicate verdict" do
    test "ran, and the property holds — completed · pass", ctx do
      {job, _} = start!(ctx)
      {:ok, out} = Authority.record_validation_outcome(job["ref"], pass())

      assert out["kind"] == "validation_job_outcome@1"
      assert out["state"] == "completed"
      assert out["verdict"] == "pass"
      refute Map.has_key?(out, "reason")
    end

    test "ran, and found a NUL — completed · fail, NOT failed", ctx do
      {job, _} = start!(ctx)

      {:ok, out} =
        Authority.record_validation_outcome(job["ref"], %{
          "state" => "completed",
          "verdict" => "fail"
        })

      # **The load-bearing assertion of the whole round.** Finding a NUL is
      # the job succeeding at its purpose. If this were `failed`, then "the
      # property does not hold" and "we could not ask" would be one value,
      # and every reader downstream would have to know which members of the
      # enum are verdicts and which are excuses.
      assert out["state"] == "completed"
      assert out["verdict"] == "fail"
      refute Map.has_key?(out, "reason")
    end

    test "the snapshot moved — failed · typed reason, NOT a verdict", ctx do
      {job, _} = start!(ctx)

      {:ok, out} =
        Authority.record_validation_outcome(job["ref"], %{
          "state" => "failed",
          "reason" => "source-basis-materialization-dirty"
        })

      assert out["state"] == "failed"
      assert out["reason"] == "source-basis-materialization-dirty"

      # A basis mismatch recorded as `fail` would assert a property of bytes
      # that were never read. The field is absent, not false.
      refute Map.has_key?(out, "verdict")
    end

    test "a source-basis mismatch cannot be recorded as a predicate fail", ctx do
      {job, _} = start!(ctx)

      # Both halves of the confusion, refused in both directions.
      assert {:error, "validation-outcome-overspecified", _} =
               Authority.record_validation_outcome(job["ref"], %{
                 "state" => "completed",
                 "verdict" => "fail",
                 "reason" => "source-basis-materialization-dirty"
               })

      assert {:error, "validation-outcome-overspecified", _} =
               Authority.record_validation_outcome(job["ref"], %{
                 "state" => "failed",
                 "reason" => "source-basis-revision-moved",
                 "verdict" => "fail"
               })

      # Neither attempt wrote anything.
      assert Validation.outcome(job["ref"]) == nil
    end

    test "every failure reason is one a line of code can actually produce", ctx do
      # Quoted, not invented. Five are `format!`/early-returns in
      # host/src/effect.rs and host/src/lib.rs; one is this runtime's own.
      assert Validation.reasons() == ~w(source-basis-unknown
                                        source-basis-revision-not-exact
                                        source-basis-materialization-absent
                                        source-basis-materialization-unresolvable
                                        source-basis-revision-moved
                                        source-basis-materialization-dirty)

      # And a reason outside the set is refused, or the enum is a comment.
      {job, _} = start!(ctx)

      for bad <- ["scope-mismatch", "carrier-failure", "indeterminate", nil, "fail"] do
        assert {:error, "validation-reason-unknown", _} =
                 Authority.record_validation_outcome(job["ref"], %{
                   "state" => "failed",
                   "reason" => bad
                 }),
               "#{inspect(bad)} has no producer and must not be recordable"
      end
    end

    test "there is no INDETERMINATE — an interrupted job is a start with no outcome", ctx do
      {job, _} = start!(ctx)

      refute "indeterminate" in Validation.states()
      assert Validation.states() == ~w(completed failed)

      assert {:error, "validation-state-unknown", _} =
               Authority.record_validation_outcome(job["ref"], %{"state" => "indeterminate"})

      # The honest representation, unchanged and still true.
      assert Validation.started(job["ref"]) != nil
      assert Validation.outcome(job["ref"]) == nil
    end
  end

  # ==================================================================== R7.3
  describe "R7.3 · the append-only relation between start and outcome" do
    test "an outcome for a job that never durably started is refused", ctx do
      {:ok, job} = mint_only!(ctx)

      # The job exists in the store and has no ledger start. This is the
      # residue R11.2 designs for, and it must not be executable.
      assert Worktree.validation_job(job["ref"]) != nil
      assert Validation.started(job["ref"]) == nil
      refute Validation.admissible?(job["ref"])

      assert {:error, "validation-job-not-started", _} =
               Authority.record_validation_outcome(job["ref"], pass())
    end

    test "a typed START for a JobBasis that does not exist is refused", ctx do
      _ = ctx
      # The typed path resolves the ref itself, so this is the store failing
      # to find a job rather than a caller failing to supply one — which is
      # the whole point of taking a ref and never a job map.
      assert {:error, "validation-job-unknown", d} =
               Ampd.AuthorityCoordinator.transact(
                 fn -> Receipts.record_validation_start("vj_9999") end,
                 nil
               )

      assert d["job_ref"] == "vj_9999"
      assert Validation.all() == []
    end

    test "a typed OUTCOME for a JobBasis that does not exist is refused", ctx do
      _ = ctx
      assert {:error, "validation-job-unknown", _} =
               Authority.record_validation_outcome("vj_9999", pass())
    end

    test "an outcome for a job_ref naming nothing is refused", ctx do
      _ = ctx
      assert {:error, "validation-job-unknown", _} =
               Authority.record_validation_outcome("vj_9999", pass())
    end

    test "two contradictory terminal outcomes for one job are refused", ctx do
      {job, _} = start!(ctx)
      {:ok, _} = Authority.record_validation_outcome(job["ref"], pass())

      assert {:error, "validation-job-already-decided", d} =
               Authority.record_validation_outcome(job["ref"], %{
                 "state" => "completed",
                 "verdict" => "fail"
               })

      assert d["state"] == "completed"

      # And the ledger still holds exactly one outcome, the first.
      assert length(Receipts.of_kind(Validation.outcome_kind())) == 1
      assert Validation.outcome(job["ref"])["verdict"] == "pass"
    end

    test "the single-outcome rule is decided where the append happens", ctx do
      {job, _} = start!(ctx)
      {:ok, first} = Authority.record_validation_outcome(job["ref"], pass())

      # Both checks — a start exists, no outcome yet — are performed inside
      # `Ampd.Receipts`' own `handle_call`, against the log it is about to
      # append to. A process handles one message at a time, so check and
      # append cannot interleave; a caller-side check would be two round
      # trips with a window between them, and two concurrent outcomes could
      # both observe "none yet".
      for attempt <- [pass(), %{"state" => "completed", "verdict" => "fail"},
                      %{"state" => "failed", "reason" => "source-basis-revision-moved"}] do
        assert {:error, "validation-job-already-decided", _} =
                 Authority.record_validation_outcome(job["ref"], attempt)
      end

      assert length(Receipts.of_kind(Validation.outcome_kind())) == 1
      assert Validation.outcome(job["ref"])["id"] == first["id"]
    end

    test "a retry is a new job with its own identity, not a second attempt", ctx do
      {a, _} = start!(ctx)
      {:ok, _} = Authority.record_validation_outcome(a["ref"], pass())
      {b, _} = start!(ctx)

      refute a["ref"] == b["ref"]
      assert Validation.outcome(a["ref"])["job_ref"] == a["ref"]
      assert Validation.outcome(b["ref"]) == nil
    end

    test "the outcome's subject is copied from the start, never from the caller", ctx do
      {job, _} = start!(ctx)

      {:ok, out} =
        Authority.record_validation_outcome(
          job["ref"],
          Map.merge(pass(), %{"actor" => "mallory", "worker_ref" => "wk_9999"})
        )

      assert out["actor"] == "kestrel"
      assert out["worker_ref"] == ctx.worker["id"]
    end
  end

  # ==================================================================== R11.2
  describe "R11.2 · a durable start precedes execution admission" do
    test "a job is admissible only once its start is durable", ctx do
      {:ok, unstarted} = mint_only!(ctx)
      refute Validation.admissible?(unstarted["ref"])

      {started_job, _} = start!(ctx)
      assert Validation.admissible?(started_job["ref"])

      {:ok, _} = Authority.record_validation_outcome(started_job["ref"], pass())
      refute Validation.admissible?(started_job["ref"]),
             "a decided job is not awaiting execution"
    end
  end

  # ===================================================================== R12
  describe "R12 · the ordered boundary is preserved structurally" do
    test "minting a job outside the coordinator is refused, not served", ctx do
      # `:open_job` is in `Ampd.Worktree`'s `@ordered_ops`, so a raw registry
      # call is refused by name rather than quietly applied out of order.
      assert {:refused, r} = Worktree.open_validation_job(fields(ctx))
      assert r["code"] == "unordered-authority-mutation"
      assert r["operator_detail"]["operation"] == ":open_job"
      assert Worktree.validation_jobs() == %{}
    end

    test "recording an outcome outside the coordinator is refused", ctx do
      {job, _} = start!(ctx)

      # `Receipts.emit` is deliberately NOT an ordered op — an ordinary
      # ledger append is not an authority mutation. The two validation
      # appends ARE, because they decide whether a job may be handed to an
      # executor, so the store refuses them by name to a caller that is not
      # the total order.
      assert {:refused, r} = Receipts.record_validation_outcome(job["ref"], pass())
      assert r["code"] == "unordered-authority-mutation"
      assert r["operator_detail"]["operation"] == ":validation_outcome"

      assert Validation.outcome(job["ref"]) == nil
      assert {:ok, _} = Authority.record_validation_outcome(job["ref"], pass())
    end

    test "recording a start outside the coordinator is refused", ctx do
      {:ok, job} = mint_only!(ctx)

      assert {:refused, r} = Receipts.record_validation_start(job["ref"])
      assert r["code"] == "unordered-authority-mutation"
      assert r["operator_detail"]["operation"] == ":validation_start"
      assert Validation.started(job["ref"]) == nil
    end

    test ":open_job is classified a MUTATION at the participant boundary", ctx do
      _ = ctx
      # The classification is what decides whether a lost reply means
      # "nothing happened" (retryable) or "a human must look". `open_job`
      # writes, so it is `:mutate`. `bind_basis` had this exact bug from the
      # commit that introduced it until this round, and
      # `tools/check-ordered-boundary.mjs` names the failure — nothing ran it.
      assert Worktree.class(:open_job) == :mutate
      assert Worktree.class(:bind_basis) == :mutate
      assert Worktree.class(:get) == :read

      # R0b.R·1's two, same argument: both write, so a lost reply must mean
      # "a human has to look", never "nothing happened, retry".
      assert Receipts.class(:validation_start) == :mutate
      assert Receipts.class(:validation_outcome) == :mutate
      assert Receipts.class(:all) == :read
    end
  end

  # ==================================================================== R8/R9
  describe "R8/R9 · typed projection, correct subject, no renderer" do
    test "validation records route ONLY to the validation surface", ctx do
      {job, _} = start!(ctx)
      {:ok, _} = Authority.record_validation_outcome(job["ref"], pass())

      op = Projection.operator()

      assert length(op["validations"]["recent"]) == 2
      assert Enum.map(op["validations"]["recent"], & &1["kind"]) |> Enum.sort() ==
               ["validation_job_outcome@1", "validation_job_started@1"]

      # Not capability history, not worktree history.
      for r <- op["receipts"]["recent"], do: refute(r["kind"] in Validation.kinds())
      for r <- op["worktree_receipts"]["recent"], do: refute(r["kind"] in Validation.kinds())
    end

    test "appending a validation record leaves the capability surface alone", ctx do
      before_caps = Projection.operator()["receipts"]
      before_wt = Projection.operator()["worktree_receipts"]

      {job, _} = start!(ctx)
      {:ok, _} = Authority.record_validation_outcome(job["ref"], pass())

      assert Projection.operator()["receipts"] == before_caps
      assert Projection.operator()["worktree_receipts"] == before_wt
      refute Projection.operator()["validations"]["total"] == 0
    end

    test "appending a capability receipt leaves the validation surface alone", ctx do
      {job, _} = start!(ctx)
      before_v = Projection.operator()["validations"]

      Receipts.emit(%{"actor" => "kestrel", "capability" => "github.pr.create"})

      assert Projection.operator()["validations"] == before_v
      _ = job
    end

    test "an agent sees its own validations", ctx do
      {job, _} = start!(ctx)
      {:ok, _} = Authority.record_validation_outcome(job["ref"], pass())

      mine = Projection.agent("kestrel")["validations"]
      assert mine["total"] == 2
      assert Enum.all?(mine["recent"], &(&1["actor"] == "kestrel"))
    end

    test "the agent filter matches nobody rather than everybody on a missing subject", ctx do
      _ = ctx
      # What the removed forged-record test was actually reaching for. It
      # needed a malformed validation row in the real ledger to get at it;
      # the filter is a pure function and can be asked directly.
      unattributed = [%{"kind" => Validation.started_kind(), "job_ref" => "vj_x"}]
      assert Enum.filter(unattributed, &(&1["actor"] == "kestrel")) == []
      assert Enum.filter(unattributed, &(&1["actor"] == nil)) == unattributed
    end

    test "another actor's validations are not in this actor's projection", ctx do
      {job, _} = start!(ctx)
      {:ok, _} = Authority.record_validation_outcome(job["ref"], pass())

      theirs = Projection.agent("mallory")["validations"]
      assert theirs["recent"] == []
      assert theirs["total"] == 0
    end

    test "worktree receipts are still routed by locus_actor", ctx do
      _ = ctx
      # R6's finding, re-asserted here because R7 added a record kind that
      # DOES use top-level `actor`, and the tempting move is to make both
      # kinds agree. They must not: `locus_actor` is the actor a Lane belongs
      # to, `actor` is the principal who performed work.
      wt = Projection.agent("kestrel")["worktree_receipts"]
      assert wt["total"] >= 1
      assert Enum.all?(wt["recent"], &(&1["locus_actor"] == "kestrel"))
      assert Enum.all?(wt["recent"], &(&1["kind"] == Locus.receipt_kind()))
    end

    test "history_for is typed the same way the frame is", ctx do
      {job, _} = start!(ctx)
      {:ok, _} = Authority.record_validation_outcome(job["ref"], pass())

      assert length(Projection.history_for(:validations, nil)) == 2
      assert length(Projection.history_for(:validations, "kestrel")) == 2
      assert Projection.history_for(:validations, "mallory") == []

      # A paged command and a frame must not disagree about what a surface
      # contains, which is the property R6 established for the other kinds.
      assert Enum.map(Projection.history_for(:validations, "kestrel"), & &1["id"]) ==
               Projection.agent("kestrel")["validations"]["recent"]
               |> Enum.map(& &1["id"])
               |> Enum.reverse()
    end
  end

  # Mints a JobBasis WITHOUT appending a start — the residue R11.2 designs
  # for. It has to go through the coordinator like every other ordered
  # mutation; `Ampd.AuthorityCoordinator.transact/1` is the seam
  # `Ampd.Authority.start_validation_job/1` uses, minus the ledger append.
  defp mint_only!(ctx),
    do: Ampd.AuthorityCoordinator.transact(fn -> Worktree.open_validation_job(fields(ctx)) end, nil)

  # ================================================================= cursors
  describe "the windows have doors — a cursor with nothing to redeem it" do
    test "an agent can page its own validations", ctx do
      {job, _} = start!(ctx)
      {:ok, _} = Authority.record_validation_outcome(job["ref"], pass())

      page = Control.command(ctx.agent, :list_validations, [nil, 50])
      assert page["returned"] == 2
      assert Enum.all?(page["items"], &(&1["kind"] in Validation.kinds()))
      assert Enum.all?(page["items"], &(&1["actor"] == "kestrel"))
    end

    test "an agent can page the establishment of its own worktree", ctx do
      # R6 found this record had been invisible to its own agent, gave the
      # frame a window, and gave it no command. This is the door.
      page = Control.command(ctx.agent, :list_worktree_receipts, [nil, 50])
      assert page["returned"] >= 1
      assert Enum.all?(page["items"], &(&1["locus_actor"] == "kestrel"))
      assert Enum.all?(page["items"], &(&1["kind"] == Locus.receipt_kind()))
    end

    test "an actor with no records pages an empty window, not the world's", ctx do
      {job, _} = start!(ctx)
      {:ok, _} = Authority.record_validation_outcome(job["ref"], pass())

      assert Control.command(ctx.control, :list_validations, [nil, 50])["returned"] == 2

      {:ok, mallory} = Ampd.Peer.attach_agent("mallory")
      theirs = Control.command(mallory, :list_validations, [nil, 50])

      # The filter is `history_for/2`'s, reused rather than restated — a
      # second copy of a filter is a second thing that can be wrong.
      assert theirs["items"] == []
      assert theirs["returned"] == 0
    end

    test "every window a projection hands out now has a command", ctx do
      _ = ctx
      # The rule `Ampd.Projection` states in its own docs, asserted rather
      # than trusted: a window with a `next_cursor` and no command is a
      # promise the protocol does not keep. R6 made one and R7 would have
      # made a second.
      windowed =
        Projection.agent("kestrel")
        |> Enum.filter(fn {_, v} -> is_map(v) and Map.has_key?(v, "next_cursor") end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      assert "validations" in windowed
      assert "worktree_receipts" in windowed

      commands = Ampd.CommandSpec.commands()

      for key <- windowed do
        expected =
          case key do
            "grant_requests_history" -> "list_grant_requests"
            "effects_history" -> "list_effect_history"
            other -> "list_" <> other
          end

        assert expected in commands,
               "the `#{key}` window has a next_cursor and no `#{expected}` command"
      end
    end
  end

  defp pass, do: %{"state" => "completed", "verdict" => "pass"}

  defp ok!(result, key) do
    assert result["allow"] == true,
           "expected #{key} to be allowed, got: #{inspect(Map.take(result, ["allow", "reason", "refusal"]))}"

    result[key]
  end

  defp grant_worktree!(lane_id, actor \\ "kestrel") do
    g =
      Authority.mint(%{
        "capability" => Locus.create_capability(),
        "resource" => lane_id,
        "actor" => actor,
        "duration" => "workspace"
      })

    refute match?({:refused, _}, g), "the grant was refused: #{inspect(g)}"
    g
  end

  defp init_repo!(suffix \\ "a") do
    dir = Path.join(Ampd.Store.data_dir(), "validation-fixture-repo-#{suffix}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "README"), "r0b-r\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.email", "r0br@example.invalid"],
          ["config", "user.name", "R0bR"],
          ["config", "commit.gpgsign", "false"],
          ["add", "-A"],
          ["commit", "-q", "-m", "init"]
        ] do
      {out, code} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
      assert code == 0, "fixture repo setup failed: git #{Enum.join(args, " ")} → #{out}"
    end

    dir
  end
end
