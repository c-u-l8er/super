defmodule Ampd.DevelopmentTask do
  @moduledoc """
  Durable human-authored development plans in the loci store. A plan binds the
  existing lane ancestry; it starts no run, grants no tools, and certifies no result.
  Planning notes are operator-only until scoped execution observation is connected.
  """
  # Read-only host observation, framed with the task/repository state it reads.
  # A match is not a source snapshot, validation, or permission to execute.
  def repository_match(id, revision, path, expected_world) do
    frame =
      Ampd.Projection.framed(nil, fn ->
        task = Ampd.Loci.development_tasks()[id]

        matched =
          task != nil and task["revision"] == revision and
            task["status"] not in ~w(cancelled completed) and
            Ampd.Worktree.matches_repository?(task["repository_ref"], path)

        %{
          "matched" => matched,
          "task_ref" => id,
          "revision" => revision,
          "repository_ref" => if(matched, do: task["repository_ref"], else: nil)
        }
      end)

    actual_world = Enum.map(~w(world_incarnation world_generation projection_epoch), &frame[&1])

    if actual_world == expected_world,
      do: Map.put(frame, "world", actual_world),
      else: %{"matched" => false, "reason" => "world-changed"}
  end

  @fields ~w(client_ref lane_ref title criteria)
  def fields, do: @fields ++ ["required_checks"]
  @profiles ~w(super-javascript-behavior@1 super-elixir-review@1 super-rust-review@1)
  defp checks?(nil), do: true

  defp checks?(%{"profiles" => profiles} = checks) when is_list(profiles) do
    map_size(checks) == 1 and length(profiles) in 1..3 and
      Enum.uniq(profiles) == profiles and Enum.all?(profiles, &(&1 in @profiles))
  end

  defp checks?(_), do: false

  defp text?(v, limit),
    do:
      is_binary(v) and String.valid?(v) and byte_size(v) <= limit and String.trim(v) != "" and
        not String.contains?(v, <<0>>)

  defp refuse(code, message),
    do:
      {:refused,
       Ampd.Refusal.new(code,
         component: "development-task",
         requires_human: true,
         public_message: message
       )}

  def create(fields, s) when is_map(fields) do
    fields =
      if fields["required_checks"] == nil, do: Map.delete(fields, "required_checks"), else: fields

    valid =
      Enum.sort(Map.keys(Map.delete(fields, "required_checks"))) == Enum.sort(@fields) and
        checks?(fields["required_checks"]) and
        text?(fields["client_ref"], 100) and text?(fields["lane_ref"], 100) and
        text?(fields["title"], 320) and text?(fields["criteria"], 4000)

    lane = s["lanes"][fields["lane_ref"]]
    goal = lane && s["goals"][lane["goal_ref"]]

    bot =
      lane && Enum.find_value(s["bots"], fn {_id, b} -> if b["actor"] == lane["actor"], do: b end)

    old =
      Enum.find_value(s["development_tasks"], fn {_id, t} ->
        if t["client_ref"] == fields["client_ref"], do: t
      end)

    cond do
      not valid ->
        refuse(
          "task-fields-invalid",
          "Enter a title and acceptance criteria for an assigned lane."
        )

      old != nil ->
        if Map.take(old, fields()) == fields,
          do: {:ok, old, s},
          else:
            refuse(
              "task-request-conflict",
              "This creation request already identifies a different task."
            )

      lane == nil or goal == nil or bot == nil ->
        refuse(
          "task-assignment-missing",
          "Choose a lane assigned to a registered bot and an existing goal."
        )

      goal["workspace_ref"] != bot["workspace_ref"] or
          not Map.has_key?(s["workspaces"], bot["workspace_ref"]) ->
        refuse(
          "task-workspace-mismatch",
          "The lane, goal and bot must belong to the same workspace."
        )

      not is_binary(lane["repository_ref"]) or Ampd.Worktree.repo(lane["repository_ref"]) == nil ->
        refuse("task-repository-missing", "The lane needs a registered repository.")

      map_size(s["development_tasks"]) >= 50 ->
        refuse("task-limit", "This world supports up to 50 development plans.")

      true ->
        seq = s["seq"] + 1
        id = "dt_" <> String.pad_leading(Integer.to_string(seq), 4, "0")

        task =
          Map.merge(fields, %{
            "id" => id,
            "schema" => "development-task@1",
            "revision" => 1,
            "workspace_ref" => bot["workspace_ref"],
            "goal_ref" => goal["id"],
            "bot_ref" => bot["id"],
            "actor" => bot["actor"],
            "repository_ref" => lane["repository_ref"],
            "base_revision" => lane["base_revision"],
            "world_ref" => Ampd.World.lineage(),
            "status" => "planned",
            "history" => [
              %{
                "revision" => 1,
                "status" => "planned",
                "note" => "Plan created; execution has not started.",
                "at" => DateTime.to_iso8601(DateTime.utc_now())
              }
            ]
          })

        persist(task, s |> Map.put("seq", seq))
    end
  end

  def create(_, _), do: refuse("task-fields-invalid", "Task fields must be an object.")

  def update(id, {revision, status, note}, s) do
    task = s["development_tasks"][id]

    cond do
      task == nil ->
        refuse("task-unknown", "This development task is unavailable.")

      not is_integer(revision) or revision !== task["revision"] ->
        # Retrying the exact last transition is harmless; a differing stale edit refuses.
        if is_integer(revision) and task["revision"] == revision + 1 and task["status"] == status and
             List.last(task["history"])["note"] == note,
           do: {:ok, task, s},
           else:
             refuse(
               "task-revision-stale",
               "The task changed. Review its latest state before updating."
             )

      status not in ~w(planned blocked cancelled completed) or not text?(note, 1000) ->
        refuse(
          "task-update-invalid",
          "Choose a planning status and explain the update."
        )

      task["status"] == "cancelled" ->
        refuse(
          "task-cancelled",
          "Cancelled plans are retained as history. Create a new plan to continue."
        )

      task["status"] == "completed" ->
        refuse(
          "task-completed",
          "Completed plans are retained as history. Create a new plan for more work."
        )

      status == "completed" and completion_refs(task, s) == [] ->
        refuse(
          "task-completion-not-ready",
          "Accept a tested result for the current plan and resolve remaining reviews and test runs before completing it."
        )

      length(task["history"]) >= 32 ->
        refuse(
          "task-history-full",
          "This plan reached its 32-entry history limit. Existing history has been preserved."
        )

      true ->
        next = revision + 1

        event = %{
          "revision" => next,
          "status" => status,
          "note" => note,
          "at" => DateTime.to_iso8601(DateTime.utc_now())
        }

        persist(
          task
          |> Map.put("revision", next)
          |> Map.put("status", status)
          |> Map.update!("history", &(&1 ++ [event]))
          |> then(fn updated ->
            if status == "completed",
              do:
                Map.put(updated, "completion", %{
                  "schema" => "development-completion@1",
                  "task_revision" => revision,
                  "accepted_attempt_refs" => completion_refs(task, s),
                  "at" => event["at"]
                }),
              else: updated
          end),
          s
        )
    end
  end

  def update(_, _, _), do: refuse("task-update-invalid", "Use a versioned task update.")

  defp completion_refs(task, s) do
    attempts =
      s
      |> Map.get("development_attempts", %{})
      |> Map.values()
      |> Enum.filter(&(&1["task_ref"] == task["id"]))

    current = Enum.filter(attempts, &(&1["task_revision"] == task["revision"]))
    pending = Enum.any?(current, &(&1["status"] not in ~w(accepted dismissed)))

    running =
      Enum.any?(attempts, fn a ->
        Enum.any?(Map.values(a["test_runs"] || %{}), &(&1["state"] == "started"))
      end)

    accepted =
      Enum.filter(current, fn a ->
        a["status"] == "accepted" and
          get_in(a, ["acceptance", "schema"]) == "development-acceptance@1" and
          get_in(a, ["acceptance", "task_revision"]) == task["revision"]
      end)

    if pending or running, do: [], else: accepted |> Enum.map(& &1["id"]) |> Enum.sort()
  end

  defp persist(task, s) do
    tasks = Map.put(s["development_tasks"], task["id"], task)

    case Ampd.Frame.logical_size(tasks, 64 * 1024) do
      {:ok, _} ->
        {:ok, task, Map.put(s, "development_tasks", tasks)}

      _ ->
        refuse(
          "task-directory-full",
          "Development plans exceed the 64 KB directory limit. Existing records are preserved."
        )
    end
  end
end
