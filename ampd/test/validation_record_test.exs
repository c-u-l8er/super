defmodule Ampd.ValidationRecordTest do
  @moduledoc """
  R0b.R · R7, R8 and R10 — durable truth about a validation job.

  The three questions this file keeps apart, because collapsing any pair of
  them is what the whole slice exists to prevent:

      did the work happen          state
      what did it find             verdict
      was it asked about the       SOURCE_BASIS_MISMATCH, which is neither
      bytes that were admitted
  """

  use ExUnit.Case, async: false

  alias Ampd.{Projection, Receipts, Validation}

  @id %{
    "job_ref" => "vj_0001",
    "source_basis_ref" => "sb_0001",
    "scope_digest" => String.duplicate("a", 64)
  }

  setup do
    Ampd.reset()
    Process.sleep(60)
    :ok
  end

  describe "R7 · append-only, two records" do
    test "a start and an outcome are two rows, and the start is never rewritten" do
      {:ok, s} = Validation.started(@id)
      {:ok, o} = Validation.outcome(Map.merge(@id, %{"state" => "COMPLETED", "verdict" => "HELD"}))

      assert s["kind"] == Validation.started_kind()
      assert o["kind"] == Validation.outcome_kind()
      refute s["id"] == o["id"]
      assert o["seq"] == s["seq"] + 1

      # The start record still says exactly what it said.
      stored = Enum.find(Receipts.all(), &(&1["id"] == s["id"]))
      assert stored == s
      refute Map.has_key?(stored, "state")
    end

    test "the ledger reports what it knows about a job, through the two rows" do
      assert Validation.state_of("vj_0001") == :unknown

      {:ok, _} = Validation.started(@id)
      assert Validation.state_of("vj_0001") == :unresolved

      {:ok, _} = Validation.outcome(Map.merge(@id, %{"state" => "COMPLETED", "verdict" => "REFUTED"}))
      assert Validation.state_of("vj_0001") == {:completed, "REFUTED"}
    end

    test "REFUTED is not FAILED — a job that finds a NUL byte ran perfectly" do
      {:ok, _} = Validation.started(@id)
      {:ok, _} = Validation.outcome(Map.merge(@id, %{"state" => "COMPLETED", "verdict" => "REFUTED"}))

      assert {:completed, "REFUTED"} = Validation.state_of("vj_0001")
      refute match?({:failed, _}, Validation.state_of("vj_0001"))
    end

    test "SOURCE_BASIS_MISMATCH is neither a failure nor a finding" do
      {:ok, _} = Validation.started(@id)

      {:ok, _} =
        Validation.outcome(
          Map.merge(@id, %{"state" => "SOURCE_BASIS_MISMATCH", "detail" => "README.md digest moved"})
        )

      assert {:basis_mismatch, "README.md digest moved"} = Validation.state_of("vj_0001")
    end

    test "cut D · a job that completed and recorded nothing reads as unresolved, not as a state" do
      # The crash cut where the work really did finish and the outcome row
      # never landed. Nothing can recover what it found, so nothing claims to.
      {:ok, _} = Validation.started(@id)

      assert Validation.state_of("vj_0001") == :unresolved
      refute Enum.any?(Receipts.all(), &(&1["state"] == "INDETERMINATE"))
      refute "INDETERMINATE" in Validation.states()
    end
  end

  describe "R7 · the closed vocabulary refuses rather than stores" do
    test "an unknown state is refused" do
      assert {:error, "validation-outcome-state-unknown", _} =
               Validation.outcome(Map.merge(@id, %{"state" => "INDETERMINATE"}))

      assert Receipts.of_kind(Validation.outcome_kind()) == []
    end

    test "COMPLETED without a verdict is refused — it would say nothing" do
      assert {:error, "validation-outcome-verdict-required", _} =
               Validation.outcome(Map.merge(@id, %{"state" => "COMPLETED"}))
    end

    test "a verdict beside a non-COMPLETED state is refused" do
      # The row a later reader would quote out of context.
      assert {:error, "validation-outcome-verdict-not-permitted", _} =
               Validation.outcome(Map.merge(@id, %{"state" => "FAILED", "verdict" => "HELD"}))
    end

    test "an unknown verdict is refused" do
      assert {:error, "validation-outcome-verdict-required", _} =
               Validation.outcome(Map.merge(@id, %{"state" => "COMPLETED", "verdict" => "PASS"}))
    end

    test "a record with no identity is refused, at both kinds" do
      for f <- ~w(job_ref source_basis_ref scope_digest) do
        partial = Map.delete(@id, f)
        assert {:error, "validation-identity-incomplete", %{"missing" => ^f}} =
                 Validation.started(partial)

        assert {:error, "validation-identity-incomplete", %{"missing" => ^f}} =
                 Validation.outcome(Map.merge(partial, %{"state" => "FAILED"}))
      end
    end
  end

  describe "R10 · no physical path, and none derivable" do
    test "neither record carries a path, or anything shaped like one" do
      {:ok, s} = Validation.started(Map.put(@id, "worker_ref", "wk_0001"))

      {:ok, o} =
        Validation.outcome(
          Map.merge(@id, %{"state" => "COMPLETED", "verdict" => "HELD", "worker_ref" => "wk_0001"})
        )

      for r <- [s, o] do
        for k <- ~w(path repo_path target root source_path worktree_root cwd host_path materialization) do
          refute Map.has_key?(r, k), "#{r["kind"]} must not carry #{k}"
        end

        for {k, v} <- r, is_binary(v) do
          refute String.starts_with?(v, "/"), "#{k} looks like an absolute path: #{v}"
        end
      end
    end

    test "a caller that supplies a path has it dropped, not stored" do
      # `Map.take/2` is the mechanism; this asserts the mechanism rather
      # than trusting that no caller ever tries.
      {:ok, s} = Validation.started(Map.put(@id, "path", "/home/travis/secret"))
      refute Map.has_key?(s, "path")
    end
  end

  describe "R8 · the subject is the Worker, resolved" do
    setup do
      # A Lane needs a registered repository — `open_lane` refuses
      # `repository-unknown` otherwise — and a Worker needs a Lane. The
      # subject under test is the Worker, so the chain above it has to be
      # real rather than stubbed.
      Ampd.Authority.install_worktree()
      {:ok, r} = Ampd.Authority.register_repository(init_repo!())

      {control, agent} = Ampd.attach_pair("kestrel")
      ws = Ampd.Control.command(control, :open_workspace, ["acme"])["workspace"]
      goal = Ampd.Control.command(control, :open_goal, [ws["id"], "validate"])["goal"]

      lane =
        Ampd.Control.command(control, :open_lane, [goal["id"], "kestrel", r["ref"], nil])["lane"]

      w = Ampd.Control.command(control, :open_worker, [lane["id"], "validate"])["worker"]
      assert w["id"], "the fixture did not produce a Worker"
      %{worker: w, control: control, agent: agent}
    end

    test "an agent sees a job done at its own Worker", ctx do
      {:ok, _} = Validation.started(Map.put(@id, "worker_ref", ctx.worker["id"]))
      assert Projection.agent("kestrel")["validations"]["total"] == 1
    end

    test "and not one done at somebody else's", ctx do
      {:ok, _} = Validation.started(Map.put(@id, "worker_ref", ctx.worker["id"]))
      assert Projection.agent("someone-else")["validations"]["total"] == 0
    end

    test "a record naming no Worker is visible to no agent" do
      {:ok, _} = Validation.started(@id)
      assert Projection.agent("kestrel")["validations"]["total"] == 0
      # The operator still sees it — an unattributed job is not a hidden one.
      assert Projection.operator()["validations"]["total"] == 1
    end

    test "the record carries no actor of its own", ctx do
      {:ok, s} = Validation.started(Map.put(@id, "worker_ref", ctx.worker["id"]))
      refute Map.has_key?(s, "actor")
      refute Map.has_key?(s, "locus_actor")
    end
  end

  describe "R6/R9 · it appears only in its own surface" do
    test "a validation record is in NEITHER the capability nor the worktree surface" do
      {:ok, _} = Validation.started(@id)
      {:ok, _} = Validation.outcome(Map.merge(@id, %{"state" => "FAILED", "detail" => "x"}))

      op = Projection.operator()
      assert op["receipts"]["total"] == 0
      assert op["worktree_receipts"]["total"] == 0
      assert op["validations"]["total"] == 2
    end

    test "and appending one leaves the capability surface untouched" do
      Receipts.emit(%{"kind" => Receipts.default_kind(), "capability" => "x"})
      before = Projection.operator()["receipts"]

      {:ok, _} = Validation.started(@id)

      assert Projection.operator()["receipts"] == before
    end

    test "start and outcome are windowed together, so an outcome never orphans its start" do
      {:ok, _} = Validation.started(@id)
      {:ok, _} = Validation.outcome(Map.merge(@id, %{"state" => "COMPLETED", "verdict" => "HELD"}))

      kinds =
        Projection.operator()["validations"]["recent"] |> Enum.map(& &1["kind"]) |> Enum.sort()

      assert kinds == [Validation.outcome_kind(), Validation.started_kind()] |> Enum.sort()
    end
  end

  defp init_repo! do
    dir = Path.join(Ampd.Store.data_dir(), "validation-fixture-repo")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "README"), "r0br\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.email", "r0br@example.invalid"],
          ["config", "user.name", "R0bR"],
          ["config", "commit.gpgsign", "false"],
          ["add", "-A"],
          ["commit", "-q", "-m", "init"]
        ] do
      {out, code} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
      assert code == 0, "fixture repo setup failed: #{out}"
    end

    dir
  end
end
