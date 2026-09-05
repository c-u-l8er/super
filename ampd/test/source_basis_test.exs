defmodule Ampd.SourceBasisTest do
  @moduledoc """
  Phase A · `source-basis@1` — an exact source snapshot a job is authorized
  to inspect.

  ## The thing a basis is not

  R0b.0 proposed deriving one from `/proc/self/exe` ancestry, so that a
  Worker would operate on "the source this Super was built from". That was
  rejected and this suite is written to keep it rejected: the host can
  canonicalize a directory and it cannot prove that directory produced the
  running binary, so a basis that claimed build provenance would be
  asserting something nothing here can check.

  What a basis says instead is narrow and checkable: **this exact commit,
  materialized here, is what this job may read.**

  ## What is under test

  Establishment already gives an opaque repository ref, a detached exact
  materialization, and a resource record whose host path
  `Ampd.Locus.view/1` drops in one place. A basis adds one fact — which
  immutable object the materialization is *required to be* — and this file
  is mostly the refusals around it, because the interesting failures of a
  basis are all the ways it could come to mean something looser than it
  says.
  """

  use ExUnit.Case, async: false

  alias Ampd.{Authority, Control, Locus, Worktree}

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
    goal = ok!(Control.command(control, :open_goal, [ws["id"], "bind a source basis"]), "goal")
    lane = ok!(Control.command(control, :open_lane, [goal["id"], "kestrel", r["ref"], nil]), "lane")

    # A person opens the assignment; the Carrier takes it up. D.1.2 made
    # that a precondition of establishing anything.
    worker = ok!(Control.command(control, :open_worker, [lane["id"], "implement"]), "worker")
    ok!(Control.command(agent, :attach_worker, [worker["id"]]), "worker")

    grant_worktree!(lane["id"])

    est = Control.command(agent, :establish_worktree, [lane["id"], "basis-a"])
    assert est["allow"] == true, "establishment refused: #{inspect(est["refusal"])}"

    %{repo: repo, resource: est["resource"], lane: lane, control: control, agent: agent}
  end

  describe "binding" do
    test "binds the exact commit the effector observed", ctx do
      {:ok, b} = Authority.bind_source_basis(%{"resource_ref" => ctx.resource["ref"]})

      assert b["schema"] == "source-basis@1"
      assert String.starts_with?(b["ref"], "sb_")
      assert b["resource_ref"] == ctx.resource["ref"]

      # The point of the whole object: an exact object name, resolved, not
      # a selection that would mean something else tomorrow.
      assert Worktree.exact_oid?(b["commit_oid"])
      assert b["commit_oid"] == ctx.resource["head"]
    end

    test "is durable and readable by ref", ctx do
      {:ok, b} = Authority.bind_source_basis(%{"resource_ref" => ctx.resource["ref"]})
      assert Worktree.source_basis(b["ref"]) == b
      assert Map.has_key?(Worktree.source_bases(), b["ref"])
    end

    test "carries no host path, and no field from which one could be built", ctx do
      {:ok, b} = Authority.bind_source_basis(%{"resource_ref" => ctx.resource["ref"]})

      # A3's rule, asserted on the object rather than on the call sites that
      # happen to serialize it today. A field added later that carried a
      # path would fail here before it reached a wire.
      for k <- ~w(path repo_path target root source_path worktree_root cwd host_path) do
        refute Map.has_key?(b, k), "source-basis@1 must not carry #{k}"
      end

      # And nothing that merely looks like one.
      for {k, v} <- b, is_binary(v) do
        refute String.starts_with?(v, "/"), "#{k} looks like an absolute path: #{v}"
      end
    end

    test "the stated commit may agree, and is then redundant rather than authoritative", ctx do
      head = ctx.resource["head"]
      {:ok, b} = Authority.bind_source_basis(%{"resource_ref" => ctx.resource["ref"], "commit_oid" => head})
      assert b["commit_oid"] == head
    end
  end

  describe "refusals — the ways a basis could come to mean something looser" do
    test "refuses a resource that does not exist" do
      assert {:error, "resource-unknown", _} =
               Authority.bind_source_basis(%{"resource_ref" => "wt_9999"})
    end

    test "refuses a resource nobody has vouched for", ctx do
      # REQUESTED, not COMMITTED_READY: a directory may not even exist. A
      # basis over it would name a snapshot no one has observed.
      res =
        Ampd.AuthorityCoordinator.transact(fn ->
          Worktree.request(%{"repository_ref" => "rp_0001", "name" => "unvouched"})
        end)

      assert {:error, "source-basis-resource-not-ready", d} =
               Authority.bind_source_basis(%{"resource_ref" => res["ref"]})

      assert d["state"] == "REQUESTED"
      _ = ctx
    end

    test "refuses a symbolic revision — the whole point of the object", ctx do
      for sym <- ~w(HEAD main HEAD~1 origin/main @) do
        assert {:error, "source-basis-revision-not-exact", d} =
                 Authority.bind_source_basis(%{
                   "resource_ref" => ctx.resource["ref"],
                   "commit_oid" => sym
                 })

        assert d["revision"] == sym
      end
    end

    test "refuses an abbreviated oid, which resolves but is not an object name", ctx do
      short = String.slice(ctx.resource["head"], 0, 12)

      assert {:error, "source-basis-revision-not-exact", _} =
               Authority.bind_source_basis(%{
                 "resource_ref" => ctx.resource["ref"],
                 "commit_oid" => short
               })
    end

    test "refuses a stated commit that disagrees with what was observed", ctx do
      other = String.duplicate("a", 40)

      assert {:error, "source-basis-revision-mismatch", d} =
               Authority.bind_source_basis(%{
                 "resource_ref" => ctx.resource["ref"],
                 "commit_oid" => other
               })

      assert d["stated"] == other
      assert d["observed"] == ctx.resource["head"]
    end

    test "refuses an uppercase oid — one object name, one spelling", ctx do
      assert {:error, "source-basis-revision-not-exact", _} =
               Authority.bind_source_basis(%{
                 "resource_ref" => ctx.resource["ref"],
                 "commit_oid" => String.upcase(ctx.resource["head"])
               })
    end
  end

  describe "ordering" do
    test "binding is an ordered operation" do
      assert :bind_basis in Worktree.ordered_ops()
    end
  end

  # ------------------------------------------------------------- fixtures
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

  defp init_repo! do
    dir = Path.join(Ampd.Store.data_dir(), "source-basis-fixture-repo")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "README"), "phase-a\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.email", "phasea@example.invalid"],
          ["config", "user.name", "PhaseA"],
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
