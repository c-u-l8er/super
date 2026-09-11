defmodule Ampd.DevelopmentTaskTest do
  use ExUnit.Case, async: false
  alias Ampd.{Authority, Control, DevelopmentTask, Loci, Projection}

  setup do
    Ampd.reset()
    {human, agent} = Ampd.attach_pair("task-tests")
    %{"workspace" => ws} = Control.command(human, :open_workspace, ["Super"])
    %{"goal" => goal} = Control.command(human, :open_goal, [ws["id"], "Improve Super"])

    bot =
      Authority.register_bot(%{
        "client_ref" => "builder",
        "workspace_ref" => ws["id"],
        "name" => "Builder",
        "role" => "Developer",
        "group" => "Super",
        "instructions" => "Reviewable work",
        "provider" => "ollama"
      })

    repo = Path.join(System.tmp_dir!(), "super-task-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "--quiet", repo])
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, registered} = Authority.register_repository(repo)

    %{"lane" => lane} =
      Control.command(human, :open_lane, [goal["id"], bot["actor"], registered["ref"], "HEAD"])

    fields = %{
      "client_ref" => "request-one",
      "lane_ref" => lane["id"],
      "title" => "Highlight changes",
      "criteria" => "Changed ranges are visible and the review preserves the draft."
    }

    %{human: human, agent: agent, ws: ws, goal: goal, bot: bot, lane: lane, fields: fields}
  end

  defp create(c), do: Authority.create_development_task(c.fields)

  test "human create binds ancestry without granting or executing", c do
    before = {Ampd.GrantRegistry.list(), Loci.workers(), Ampd.Worktree.resources()}

    assert %{"allow" => true, "development_task" => t} =
             Control.command(
               c.human,
               :create_development_task,
               Enum.map(DevelopmentTask.fields(), &c.fields[&1])
             )

    assert t["bot_ref"] == c.bot["id"] and t["goal_ref"] == c.goal["id"] and
             t["workspace_ref"] == c.ws["id"]

    assert t["repository_ref"] == c.lane["repository_ref"] and t["base_revision"] == "HEAD"
    assert t["status"] == "planned" and t["revision"] == 1
    assert Projection.operator()["development_tasks"][t["id"]] == t
    refute Map.has_key?(Projection.agent(c.bot["actor"]), "development_tasks")
    assert before == {Ampd.GrantRegistry.list(), Loci.workers(), Ampd.Worktree.resources()}
  end

  test "creation retries reuse identity; conflicting retries refuse", c do
    t = create(c)
    assert create(c) == t

    assert {:refused, %{"code" => "task-request-conflict"}} =
             Authority.create_development_task(%{c.fields | "title" => "Other"})

    assert map_size(Loci.development_tasks()) == 1
  end

  test "updates preserve history and detect stale edits; identical retries are idempotent", c do
    t = create(c)
    next = Authority.update_development_task(t["id"], 1, "blocked", "Need a provider")
    assert next["revision"] == 2 and length(next["history"]) == 2
    assert Authority.update_development_task(t["id"], 1, "blocked", "Need a provider") == next

    assert {:refused, %{"code" => "task-revision-stale"}} =
             Authority.update_development_task(t["id"], 1, "planned", "Ready")

    assert {:refused, _} =
             Authority.update_development_task(t["id"], nil, "blocked", "Need a provider")

    assert Loci.development_tasks()[t["id"]] == next
  end

  test "planning cannot assert execution or accepted results and cancellation is terminal", c do
    t = create(c)

    for status <- ["running", "accepted", "complete", "validated"] do
      assert {:refused, _} = Authority.update_development_task(t["id"], 1, status, "Unsupported")
    end

    assert %{"status" => "cancelled"} =
             Authority.update_development_task(t["id"], 1, "cancelled", "Changed priorities")

    assert {:refused, %{"code" => "task-cancelled"}} =
             Authority.update_development_task(t["id"], 2, "planned", "Revive")
  end

  test "missing ancestry and unsupported input preserve the directory", c do
    for fields <- [
          Map.put(c.fields, "actor", "other"),
          %{c.fields | "lane_ref" => "ln_missing"},
          %{c.fields | "criteria" => " "},
          %{c.fields | "title" => String.duplicate("x", 321)}
        ] do
      assert {:refused, _} = Authority.create_development_task(fields)
    end

    assert Loci.development_tasks() == %{}
  end

  test "only human control and ordered store mutations can change plans", c do
    assert {:refused, _} = Loci.create_development_task(c.fields)

    assert %{"allow" => false} =
             Control.command(
               c.agent,
               :create_development_task,
               Enum.map(DevelopmentTask.fields(), &c.fields[&1])
             )

    t = create(c)
    assert {:refused, _} = Loci.update_development_task(t["id"], 1, "blocked", "Direct call")

    assert %{"allow" => false} =
             Control.command(c.agent, :update_development_task, [
               t["id"],
               1,
               "blocked",
               "Agent call"
             ])

    assert Loci.development_tasks()[t["id"]] == t
  end

  test "plans survive store restart and legacy snapshots gain an empty collection", c do
    t = create(c)
    :ok = Supervisor.terminate_child(Ampd.Supervisor, Loci)
    {:ok, _} = Supervisor.restart_child(Ampd.Supervisor, Loci)
    assert Loci.development_tasks()[t["id"]] == t
    assert Loci.shape(Map.delete(Loci.initial(), "development_tasks"))["development_tasks"] == %{}
  end

  test "history limits preserve every earlier note", c do
    t = create(c)

    for revision <- 1..31,
        do:
          assert(
            is_map(
              Authority.update_development_task(t["id"], revision, "planned", "Note #{revision}")
            )
          )

    before = Loci.development_tasks()

    assert {:refused, %{"code" => "task-history-full"}} =
             Authority.update_development_task(t["id"], 32, "blocked", "Too many")

    assert Loci.development_tasks() == before
  end

  test "repository matching is read-only, current and path-redacted", c do
    t = create(c)
    path = Ampd.Worktree.repo(t["repository_ref"])["path"]

    world =
      Enum.map(
        ~w(world_incarnation world_generation projection_epoch),
        &Projection.continuity()[&1]
      )

    before = {Loci.development_tasks(), Ampd.Worktree.repos(), Ampd.GrantRegistry.list()}
    match = DevelopmentTask.repository_match(t["id"], 1, path, world)
    assert match["matched"] and match["repository_ref"] == t["repository_ref"]
    refute inspect(match) =~ path
    refute DevelopmentTask.repository_match(t["id"], 2, path, world)["matched"]
    refute DevelopmentTask.repository_match("dt_missing", 1, path, world)["matched"]
    refute DevelopmentTask.repository_match(t["id"], 1, System.tmp_dir!(), world)["matched"]
    refute DevelopmentTask.repository_match(t["id"], 1, path, [nil, nil, "old-epoch"])["matched"]
    assert before == {Loci.development_tasks(), Ampd.Worktree.repos(), Ampd.GrantRegistry.list()}
    Authority.update_development_task(t["id"], 1, "cancelled", "No longer needed")
    refute DevelopmentTask.repository_match(t["id"], 2, path, world)["matched"]
  end

  test "repository matching resolves aliases but rejects missing folders", c do
    t = create(c)
    path = Ampd.Worktree.repo(t["repository_ref"])["path"]
    alias_path = path <> "-alias"
    File.ln_s!(path, alias_path)
    on_exit(fn -> File.rm(alias_path) end)
    assert Ampd.Worktree.matches_repository?(t["repository_ref"], alias_path)
    refute Ampd.Worktree.matches_repository?(t["repository_ref"], path <> "-missing")
  end

  test "completion requires current accepted evidence and no unresolved review or run", c do
    t = create(c)

    assert {:refused, %{"code" => "task-completion-not-ready"}} =
             Authority.update_development_task(t["id"], 1, "completed", "Done")

    a = %{
      "id" => "accepted-one",
      "task_ref" => t["id"],
      "task_revision" => 1,
      "status" => "accepted",
      "acceptance" => %{"schema" => "development-acceptance@1", "task_revision" => 1}
    }

    state = %{"development_tasks" => %{t["id"] => t}, "development_attempts" => %{a["id"] => a}}

    for bad <- [
          Map.put(a, "task_revision", 0),
          Map.delete(a, "acceptance"),
          Map.put(a, "status", "recorded"),
          Map.put(a, "test_runs", %{"unfinished" => %{"state" => "started"}})
        ] do
      assert {:refused, _} =
               DevelopmentTask.update(
                 t["id"],
                 {1, "completed", "Done"},
                 put_in(state, ["development_attempts", a["id"]], bad)
               )
    end

    pending = %{
      "id" => "pending",
      "task_ref" => t["id"],
      "task_revision" => 1,
      "status" => "needs_changes"
    }

    assert {:refused, _} =
             DevelopmentTask.update(
               t["id"],
               {1, "completed", "Done"},
               put_in(state, ["development_attempts", "pending"], pending)
             )

    assert {:ok, completed, next} =
             DevelopmentTask.update(t["id"], {1, "completed", "Meets the plan criteria"}, state)

    assert completed["completion"]["accepted_attempt_refs"] == ["accepted-one"]
    assert completed["completion"]["task_revision"] == 1

    assert completed["revision"] == 2 and
             List.last(completed["history"])["note"] == "Meets the plan criteria"

    assert {:ok, ^completed, ^next} =
             DevelopmentTask.update(t["id"], {1, "completed", "Meets the plan criteria"}, next)

    assert {:refused, %{"code" => "task-completed"}} =
             DevelopmentTask.update(t["id"], {2, "planned", "Reopen"}, next)
  end
end
