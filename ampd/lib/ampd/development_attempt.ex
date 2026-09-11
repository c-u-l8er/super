defmodule Ampd.DevelopmentAttempt do
  @moduledoc """
  Human-recorded, immutable single-file and combined review material with versioned notes.
  Digests establish content consistency, not native attestation, validation,
  execution authority or acceptance. The operator's UI rechecks native source
  before recording; these records never grant permission to restore old edits.
  """
  # Read-only native-host observation; never an execution grant or validation receipt.
  def for_local_tests(id, revision, path, expected_world) do
    frame =
      Ampd.Projection.framed(nil, fn ->
        attempt = Ampd.Loci.development_attempts()[id]
        task = if attempt, do: Ampd.Loci.development_tasks()[attempt["task_ref"]]

        matched =
          attempt != nil and task != nil and
            attempt["revision"] == revision and
            attempt["status"] != "dismissed" and task["status"] not in ~w(cancelled completed) and
            task["revision"] == attempt["task_revision"] and
            Ampd.Worktree.matches_repository?(attempt["repository_ref"], path)

        %{"matched" => matched, "attempt" => if(matched, do: attempt, else: nil)}
      end)

    world = Enum.map(~w(world_incarnation world_generation projection_epoch), &frame[&1])
    if world == expected_world, do: frame, else: %{"matched" => false}
  end

  @fields ~w(client_ref task_ref task_revision source shared_draft proposed_text)
  @source_fields ~w(schema scope basis_id head path disk_sha256 draft_sha256 draft_bytes unsaved result_sha256 result_bytes task_ref task_revision repository_ref world)
  def fields, do: @fields
  defp digest(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
  defp hash?(s), do: is_binary(s) and Regex.match?(~r/\A[0-9a-f]{64}\z/, s)

  defp text?(s, cap),
    do:
      is_binary(s) and String.valid?(s) and byte_size(s) <= cap and not String.contains?(s, <<0>>)

  defp nonempty?(s, cap), do: text?(s, cap) and String.trim(s) != ""

  defp refuse(code, message),
    do:
      {:refused,
       Ampd.Refusal.new(code,
         component: "development-attempt",
         requires_human: true,
         public_message: message
       )}

  defp result_digest(nil, path), do: digest(JSON.encode!(["deleted-file@1", path]))
  defp result_digest(text, _), do: digest(text)
  defp result_size(nil), do: 0
  defp result_size(text), do: byte_size(text)

  defp source?(source, draft, proposed) when is_map(source) do
    path = source["path"]
    head = source["head"]

    Enum.sort(Map.keys(source)) == Enum.sort(@source_fields) and
      ((source["schema"] == "selected-file-basis@1" and is_binary(proposed)) or
         (source["schema"] == "selected-file-deletion-basis@1" and proposed == nil and
            hash?(source["disk_sha256"]))) and source["scope"] == "selected-file-only" and
      nonempty?(path, 1024) and not String.starts_with?(path, "/") and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", "..", ".git"])) and
      is_binary(head) and Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, head) and
      hash?(source["basis_id"]) and (source["disk_sha256"] == nil or hash?(source["disk_sha256"])) and
      is_boolean(source["unsaved"]) and source["draft_sha256"] == digest(draft) and
      source["result_sha256"] == result_digest(proposed, path) and
      source["draft_bytes"] === byte_size(draft) and
      source["result_bytes"] === result_size(proposed) and
      source["unsaved"] == (source["disk_sha256"] != source["draft_sha256"])
  end

  defp source?(_, _, _), do: false

  # No call back into the ordering coordinator from its receiving store.
  # Epoch is retained as observed context; the UI rechecks it before submission.
  defp current_world?([incarnation, generation, epoch]) do
    lineage = Ampd.World.lineage()

    incarnation == Ampd.World.incarnation_of(lineage) and generation == lineage["generation"] and
      nonempty?(epoch, 100)
  end

  defp current_world?(_), do: false

  def create(%{"schema" => "development-change-set-request@1"} = fields, s),
    do: create_set(fields, s)

  def create(fields, s) when is_map(fields) do
    task = s["development_tasks"][fields["task_ref"]]
    source = fields["source"]

    old =
      Enum.find_value(s["development_attempts"], fn {_, a} ->
        if a["client_ref"] == fields["client_ref"], do: a
      end)

    valid =
      Enum.sort(Map.keys(fields)) == Enum.sort(@fields) and nonempty?(fields["client_ref"], 100) and
        text?(fields["shared_draft"], 24000) and text?(fields["proposed_text"], 32000) and
        source?(source, fields["shared_draft"], fields["proposed_text"])

    cond do
      not valid ->
        refuse(
          "attempt-fields-invalid",
          "The review material or its content identities are invalid."
        )

      old != nil ->
        if Map.take(old, @fields) == fields,
          do: {:ok, old, s},
          else:
            refuse(
              "attempt-request-conflict",
              "This request already identifies different review material."
            )

      task == nil or task["revision"] !== fields["task_revision"] or
          task["status"] in ~w(cancelled completed) ->
        refuse("attempt-task-stale", "Reopen the current plan and prepare a fresh review.")

      source["task_ref"] != task["id"] or source["task_revision"] !== task["revision"] or
          source["repository_ref"] != task["repository_ref"] ->
        refuse(
          "attempt-source-mismatch",
          "The source record belongs to a different plan or repository."
        )

      not current_world?(source["world"]) ->
        refuse("attempt-world-stale", "The runtime changed. Recheck the source before recording.")

      map_size(s["development_attempts"]) >= 50 ->
        refuse(
          "attempt-limit",
          "This world supports up to 50 review attempts. Existing records are preserved."
        )

      true ->
        seq = s["seq"] + 1
        id = "da_" <> String.pad_leading(Integer.to_string(seq), 4, "0")

        record =
          Map.merge(fields, %{
            "id" => id,
            "schema" => "development-review-attempt@1",
            "revision" => 1,
            "workspace_ref" => task["workspace_ref"],
            "bot_ref" => task["bot_ref"],
            "repository_ref" => task["repository_ref"],
            "plan_title" => task["title"],
            "criteria" => task["criteria"],
            "world_ref" => task["world_ref"],
            "status" => "recorded",
            "provenance" => "human-recorded-review-material",
            "history" => [
              event(
                1,
                "recorded",
                "Proposal recorded for review. No validation or acceptance is claimed."
              )
            ]
          })

        persist(record, Map.put(s, "seq", seq))
    end
  end

  def create(_, _), do: refuse("attempt-fields-invalid", "Review fields must be an object.")

  defp create_set(f, s) do
    task = s["development_tasks"][f["task_ref"]]
    files = if is_map(f["material"]), do: f["material"]["files"], else: nil
    keys = ~w(schema client_ref task_ref task_revision material)

    valid =
      Enum.sort(Map.keys(f)) == Enum.sort(keys) and nonempty?(f["client_ref"], 100) and
        is_map(f["material"]) and Map.keys(f["material"]) == ["files"] and is_list(files) and
        length(files) in 2..4 and Enum.all?(files, &set_file?/1)

    old =
      Enum.find_value(s["development_attempts"], fn {_, a} ->
        if a["client_ref"] == f["client_ref"], do: a
      end)

    cond do
      not valid ->
        refuse(
          "attempt-fields-invalid",
          "A change set needs two to four complete, valid file replacements."
        )

      old != nil ->
        if old["schema"] == "development-review-set@1" and old["task_ref"] == f["task_ref"] and
             old["task_revision"] === f["task_revision"] and old["files"] == files,
           do: {:ok, old, s},
           else:
             refuse(
               "attempt-request-conflict",
               "This request already identifies different review material."
             )

      task == nil or task["revision"] !== f["task_revision"] or
          task["status"] in ~w(cancelled completed) ->
        refuse("attempt-task-stale", "Reopen the current plan before recording this change set.")

      not coherent_set?(files, task) ->
        refuse(
          "attempt-source-mismatch",
          "Every file must belong to the same current plan, repository, world and source commit, with a distinct path."
        )

      map_size(s["development_attempts"]) >= 50 ->
        refuse("attempt-limit", "This world supports up to 50 review attempts.")

      true ->
        first = hd(files)["source"]
        basis = Enum.map(files, fn row -> [row["source"]["path"], row["source"]["basis_id"]] end)

        result =
          Enum.map(files, fn row -> [row["source"]["path"], row["source"]["result_sha256"]] end)

        source =
          Map.take(first, ~w(head task_ref task_revision repository_ref world))
          |> Map.merge(%{
            "schema" => "selected-file-set-basis@1",
            "scope" => "selected-file-set-only",
            "basis_id" => digest(JSON.encode!(["selected-file-set-basis@1", basis])),
            "result_sha256" => digest(JSON.encode!(["selected-file-set-result@1", result]))
          })

        seq = s["seq"] + 1

        record = %{
          "id" => "da_" <> String.pad_leading(Integer.to_string(seq), 4, "0"),
          "schema" => "development-review-set@1",
          "client_ref" => f["client_ref"],
          "task_ref" => task["id"],
          "task_revision" => task["revision"],
          "revision" => 1,
          "workspace_ref" => task["workspace_ref"],
          "bot_ref" => task["bot_ref"],
          "repository_ref" => task["repository_ref"],
          "world_ref" => task["world_ref"],
          "plan_title" => task["title"],
          "criteria" => task["criteria"],
          "files" => files,
          "source" => source,
          "status" => "recorded",
          "provenance" => "human-recorded-review-material",
          "history" => [
            event(
              1,
              "recorded",
              "Combined review recorded. No files saved, tests run or result accepted."
            )
          ]
        }

        persist(record, Map.put(s, "seq", seq))
    end
  end

  defp set_file?(row) when is_map(row) do
    Enum.sort(Map.keys(row)) == ~w(proposed_text shared_draft source) and
      text?(row["shared_draft"], 24000) and
      (row["proposed_text"] == nil or text?(row["proposed_text"], 32000)) and
      source?(row["source"], row["shared_draft"], row["proposed_text"]) and
      row["source"]["basis_id"] ==
        digest(
          JSON.encode!([
            "selected-file-basis@1",
            row["source"]["head"],
            row["source"]["path"],
            row["source"]["disk_sha256"],
            row["source"]["draft_sha256"]
          ])
        )
  end

  defp set_file?(_), do: false

  defp coherent_set?(files, task) do
    first = hd(files)["source"]
    paths = Enum.map(files, & &1["source"]["path"])

    length(Enum.uniq(paths)) == length(paths) and
      Enum.all?(files, fn row ->
        source = row["source"]

        source["task_ref"] == task["id"] and source["task_revision"] === task["revision"] and
          source["repository_ref"] == task["repository_ref"] and source["head"] == first["head"] and
          source["world"] == first["world"] and current_world?(source["world"])
      end)
  end

  # Fixed, non-executing checks derived here from immutable retained bytes.
  # This is not a Carrier validation receipt or a test of the current checkout.
  def update(id, operation, %{"development_attempts" => attempts} = s)
      when is_map_key(attempts, id) and is_map_key(:erlang.map_get(id, attempts), "files") and
             tuple_size(operation) > 0 and
             elem(operation, 0) in [:check_text] do
    _ = s

    refuse(
      "change-set-checks-unavailable",
      "Standalone text checks are not available for combined reviews. Run the selected test profile against the complete set."
    )
  end

  def update(id, {:begin_test, fields}, s) when is_map(fields) do
    a = s["development_attempts"][id]
    profile = Map.get(fields, "profile", "super-javascript-behavior@1")
    run_id = fields["run_id"]
    runs = if a, do: Map.get(a, "test_runs", %{}), else: %{}
    old = runs[run_id]
    task = if a, do: s["development_tasks"][a["task_ref"]]

    cond do
      Enum.sort(Map.keys(Map.delete(fields, "profile"))) !=
        Enum.sort(~w(run_id revision path world)) or
        profile not in ~w(super-javascript-behavior@1 super-elixir-review@1 super-rust-review@1) or
          not nonempty?(run_id, 100) ->
        refuse("test-start-invalid", "Invalid test-start request.")

      not current_world?(fields["world"]) ->
        refuse("test-world-stale", "The runtime world changed.")

      a == nil ->
        refuse("attempt-unknown", "The saved review is unavailable.")

      old != nil ->
        if old["requested_revision"] === fields["revision"] and old["profile"] == profile,
          do: {:ok, a, s},
          else: refuse("test-start-conflict", "This run already belongs to a different request.")

      a["revision"] !== fields["revision"] or a["status"] in ["dismissed", "accepted"] or
        task == nil or
        task["revision"] !== a["task_revision"] or task["status"] in ~w(cancelled completed) ->
        refuse("test-review-stale", "Reopen the latest plan and review before testing.")

      not is_binary(fields["path"]) or
          not Ampd.Worktree.matches_repository?(a["repository_ref"], fields["path"]) ->
        refuse("test-repository-mismatch", "Select this review's registered repository.")

      map_size(runs) >= 8 ->
        refuse("test-run-limit", "This review retains up to eight test runs.")

      true ->
        run = %{
          "schema" => "development-test-run@1",
          "run_id" => run_id,
          "attempt_ref" => id,
          "requested_revision" => fields["revision"],
          "state" => "started",
          "revision" => 1,
          "runtime_epoch" => Enum.at(fields["world"], 2),
          "profile" => profile,
          "provenance" => "native-host-reported-tests",
          "source_basis_id" => a["source"]["basis_id"],
          "result_sha256" => a["source"]["result_sha256"],
          "world" => Enum.take(fields["world"], 2),
          "started_at" => DateTime.to_iso8601(DateTime.utc_now())
        }

        persist(Map.put(a, "test_runs", Map.put(runs, run_id, run)), s)
    end
  end

  # The host bridge supplies the current coordinator epoch before entering the
  # ordered receiver. Never query that coordinator from inside this handler.
  def update(id, {:recover_tests, world}, s) do
    a = s["development_attempts"][id]

    cond do
      not current_world?(world) ->
        refuse("test-world-stale", "The runtime world changed.")

      a == nil ->
        refuse("attempt-unknown", "The saved review is unavailable.")

      true ->
        runs = Map.get(a, "test_runs", %{})

        recovered =
          Map.new(runs, fn {id, run} ->
            if run["state"] == "started" and is_binary(run["runtime_epoch"]) and
                 run["runtime_epoch"] != Enum.at(world, 2) do
              outcome = %{
                "state" => "failed",
                "verdict" => nil,
                "reason" => "interrupted",
                "source_basis_id" => run["source_basis_id"],
                "result_sha256" => run["result_sha256"],
                "snapshot_sha256" => nil,
                "node_sha256" => nil,
                "test_count" => 0,
                "output" =>
                  "The runtime restarted before a final outcome was confirmed. Tests were not rerun.",
                "output_omitted" => false
              }

              {id,
               run
               |> Map.put("state", "failed")
               |> Map.put("revision", 2)
               |> Map.put("finished_at", DateTime.to_iso8601(DateTime.utc_now()))
               |> Map.put("outcome", outcome)}
            else
              {id, run}
            end
          end)

        if recovered == runs,
          do: {:ok, a, s},
          else: persist(Map.put(a, "test_runs", recovered), s)
    end
  end

  def update(id, {:finish_test, run_id, world, outcome}, s) do
    a = s["development_attempts"][id]
    run = if a, do: Map.get(a, "test_runs", %{})[run_id]

    cond do
      not current_world?(world) ->
        refuse("test-world-stale", "The runtime world changed.")

      run == nil ->
        refuse("test-not-started", "No runtime start exists for this test run.")

      not test_outcome?(outcome, run) ->
        refuse(
          "test-outcome-invalid",
          "The outcome does not match the admitted review or supported test profile."
        )

      run["state"] != "started" ->
        if run["outcome"] == outcome,
          do: {:ok, a, s},
          else: refuse("test-outcome-conflict", "This run already has a different final outcome.")

      true ->
        final =
          run
          |> Map.put("revision", 2)
          |> Map.put("state", outcome["state"])
          |> Map.put("finished_at", DateTime.to_iso8601(DateTime.utc_now()))
          |> Map.put("outcome", outcome)

        persist(put_in(a, ["test_runs", run_id], final), s)
    end
  end

  def update(id, {:prepare_acceptance, f}, s) when is_map(f) do
    a = s["development_attempts"][id]
    run = if a, do: Map.get(a, "test_runs", %{})[f["run_id"]]

    cond do
      Enum.sort(Map.keys(f)) !=
          Enum.sort(~w(revision run_id path world snapshot_sha256 result_sha256 head)) ->
        refuse("acceptance-invalid", "Invalid acceptance check.")

      not current_world?(f["world"]) or not acceptance_ready?(a, run, f["revision"], s) ->
        refuse(
          "acceptance-stale",
          "Every profile run on this review needs its latest passing result on the same snapshot. Reopen the review and rerun missing coverage."
        )

      not is_binary(f["path"]) or
          not Ampd.Worktree.matches_repository?(a["repository_ref"], f["path"]) ->
        refuse("acceptance-repository", "Choose this review's registered repository.")

      f["snapshot_sha256"] != run["outcome"]["snapshot_sha256"] or
        f["result_sha256"] != a["source"]["result_sha256"] or f["head"] != a["source"]["head"] ->
        refuse("acceptance-content", "The current files do not match the tested result.")

      true ->
        check = %{
          "schema" => "native-acceptance-check@1",
          "token" => Base.encode16(:crypto.strong_rand_bytes(24), case: :lower),
          "revision" => f["revision"],
          "run_id" => f["run_id"],
          "world" => f["world"],
          "snapshot_sha256" => f["snapshot_sha256"],
          "result_sha256" => f["result_sha256"],
          "checked_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "expires_at" => System.system_time(:millisecond) + 15000
        }

        persist(Map.put(a, "acceptance_check", check), s)
    end
  end

  def update(id, {:accept, revision, token, note, world}, s) do
    a = s["development_attempts"][id]
    check = if a, do: a["acceptance_check"]
    run = if check, do: Map.get(a, "test_runs", %{})[check["run_id"]]

    cond do
      a != nil and a["acceptance"] != nil and a["acceptance"]["token"] == token and
        a["acceptance"]["requested_revision"] == revision and a["acceptance"]["note"] == note ->
        {:ok, a, s}

      not nonempty?(note, 1000) or not is_binary(token) ->
        refuse("acceptance-invalid", "Explain why this tested result meets the review criteria.")

      check == nil or check["token"] != token or check["revision"] != revision or
        check["world"] != world or not current_world?(world) or
          check["expires_at"] < System.system_time(:millisecond) ->
        refuse(
          "acceptance-check-stale",
          "The native file check is missing or expired. Try acceptance again."
        )

      not acceptance_ready?(a, run, revision, s) ->
        refuse(
          "acceptance-stale",
          "The plan, review or test profile coverage changed. Reopen the review."
        )

      true ->
        decision = %{
          "schema" => "development-acceptance@1",
          "provenance" => "human-control-decision",
          "scope" => "captured-tested-result",
          "requested_revision" => revision,
          "token" => token,
          "note" => note,
          "run_id" => check["run_id"],
          "profile_run_refs" =>
            Map.new(
              latest_profile_runs(a),
              &{&1["profile"] || "super-javascript-behavior@1", &1["run_id"]}
            ),
          "snapshot_sha256" => check["snapshot_sha256"],
          "result_sha256" => check["result_sha256"],
          "source_basis_id" => a["source"]["basis_id"],
          "task_revision" => a["task_revision"],
          "native_checked_at" => check["checked_at"],
          "accepted_at" => DateTime.to_iso8601(DateTime.utc_now())
        }

        persist(
          a
          |> Map.delete("acceptance_check")
          |> Map.put("acceptance", decision)
          |> Map.put("status", "accepted")
          |> Map.put("revision", revision + 1)
          |> Map.update!("history", &(&1 ++ [event(revision + 1, "accepted", note)])),
          s
        )
    end
  end

  def update(id, {:check_text, revision}, s) do
    attempt = s["development_attempts"][id]

    cond do
      attempt == nil ->
        refuse("attempt-unknown", "This review attempt is unavailable.")

      not is_integer(revision) ->
        refuse("attempt-revision-stale", "Reopen the latest review.")

      attempt["text_check"] != nil and
          revision in [attempt["revision"], attempt["text_check"]["requested_revision"]] ->
        {:ok, attempt, s}

      revision !== attempt["revision"] ->
        refuse("attempt-revision-stale", "This review changed. Reopen it before checking.")

      attempt["status"] in ["dismissed", "accepted"] ->
        refuse("attempt-dismissed", "Dismissed reviews remain read-only history.")

      length(attempt["history"]) >= 32 ->
        refuse("attempt-history-full", "This review reached its 32-event limit.")

      true ->
        check = text_check(attempt) |> Map.put("requested_revision", revision)
        next = revision + 1

        persist(
          attempt
          |> Map.put("revision", next)
          |> Map.put("text_check", check)
          |> Map.update!(
            "history",
            &(&1 ++
                [
                  event(
                    next,
                    attempt["status"],
                    "Proposed-text checks: " <> check["outcome"] <> ". App tests were not run."
                  )
                ])
          ),
          s
        )
    end
  end

  def update(id, {revision, status, note}, s) do
    attempt = s["development_attempts"][id]

    cond do
      attempt == nil ->
        refuse("attempt-unknown", "This review attempt is unavailable.")

      not is_integer(revision) or revision !== attempt["revision"] ->
        if is_integer(revision) and attempt["revision"] == revision + 1 and
             attempt["status"] == status and List.last(attempt["history"])["note"] == note,
           do: {:ok, attempt, s},
           else:
             refuse(
               "attempt-revision-stale",
               "This review changed. Reopen its latest notes before updating."
             )

      status not in ~w(recorded needs_changes dismissed) or not nonempty?(note, 1000) ->
        refuse(
          "attempt-update-invalid",
          "Choose a review status and explain it. Acceptance uses the separate tested-result action."
        )

      attempt["status"] in ["dismissed", "accepted"] ->
        refuse(
          "attempt-dismissed",
          "Dismissed attempts remain read-only history. Record a new proposal to continue."
        )

      length(attempt["history"]) >= 32 ->
        refuse(
          "attempt-history-full",
          "This review reached its 32-note limit. Earlier notes are preserved."
        )

      true ->
        next = revision + 1

        persist(
          attempt
          |> Map.put("revision", next)
          |> Map.put("status", status)
          |> Map.update!("history", &(&1 ++ [event(next, status, note)])),
          s
        )
    end
  end

  def update(_, _, _), do: refuse("attempt-update-invalid", "Use a versioned review update.")

  defp latest_profile_runs(a) do
    a
    |> Map.get("test_runs", %{})
    |> Map.values()
    |> Enum.group_by(&(&1["profile"] || "super-javascript-behavior@1"))
    |> Enum.map(fn {_profile, runs} -> Enum.max_by(runs, &{&1["started_at"], &1["run_id"]}) end)
  end

  defp acceptance_ready?(a, run, revision, s) do
    task = if a, do: s["development_tasks"][a["task_ref"]]
    runs = if a, do: Map.values(Map.get(a, "test_runs", %{})), else: []
    latest = Enum.max_by(runs, &{&1["started_at"], &1["run_id"]}, fn -> nil end)

    a != nil and run != nil and task != nil and a["revision"] == revision and
      a["status"] not in ["dismissed", "accepted"] and length(a["history"]) < 32 and
      task["revision"] == a["task_revision"] and task["status"] not in ~w(cancelled completed) and
      latest == run and run["state"] == "completed" and run["outcome"]["verdict"] == "pass" and
      Enum.all?(get_in(task, ["required_checks", "profiles"]) || [], fn profile ->
        Enum.any?(
          latest_profile_runs(a),
          &((&1["profile"] || "super-javascript-behavior@1") == profile)
        )
      end) and
      Enum.all?(runs, &(&1["state"] != "started")) and
      Enum.all?(latest_profile_runs(a), fn other ->
        other["state"] == "completed" and other["outcome"]["verdict"] == "pass" and
          other["outcome"]["snapshot_sha256"] == run["outcome"]["snapshot_sha256"]
      end)
  end

  defp test_outcome?(o, run) when is_map(o) do
    fields =
      ~w(state verdict reason source_basis_id result_sha256 snapshot_sha256 node_sha256 test_count output output_omitted)

    identity =
      o["source_basis_id"] == run["source_basis_id"] and
        o["result_sha256"] == run["result_sha256"]

    shape =
      Enum.sort(Map.keys(Map.drop(o, ~w(profile toolchain_sha256)))) == Enum.sort(fields) and
        identity and
        Map.get(o, "profile", "super-javascript-behavior@1") == run["profile"] and
        (o["toolchain_sha256"] == nil or hash?(o["toolchain_sha256"])) and
        text?(o["output"], 1024) and
        is_boolean(o["output_omitted"]) and is_integer(o["test_count"]) and
        o["test_count"] in 0..64 and
        (o["snapshot_sha256"] == nil or hash?(o["snapshot_sha256"])) and
        (o["node_sha256"] == nil or hash?(o["node_sha256"]))

    terminal =
      (o["state"] == "completed" and o["verdict"] in ~w(pass fail) and o["reason"] == nil and
         hash?(o["snapshot_sha256"]) and hash?(o["node_sha256"]) and o["test_count"] > 0 and
         (run["profile"] not in ~w(super-elixir-review@1 super-rust-review@1) or
            hash?(o["toolchain_sha256"]))) or
        (o["state"] == "failed" and o["verdict"] == nil and
           o["reason"] in ~w(cancelled timeout launcher-unavailable terminated runner-did-not-complete snapshot-changed runner-error interrupted))

    with true <- shape and terminal,
         {:ok, bytes} <- Ampd.Frame.encode(o),
         true <- byte_size(bytes) <= 4096,
         do: true,
         else: (_ -> false)
  end

  defp test_outcome?(_, _), do: false

  defp text_check(attempt) do
    text = attempt["proposed_text"]
    lines = String.split(text, "\n")

    checks = [
      line_check(
        "conflict-markers",
        "Conflict markers",
        lines,
        &Regex.match?(~r/\A(?:<{7}|={7}|>{7}|\|{7})(?:\s|\z)/, &1)
      ),
      line_check(
        "trailing-whitespace",
        "Trailing spaces or tabs",
        lines,
        &Regex.match?(~r/[ \t]+\r?\z/, &1)
      )
    ]

    json =
      if String.downcase(Path.extname(attempt["source"]["path"])) == ".json" do
        case JSON.decode(text) do
          {:ok, _} ->
            %{
              "id" => "json-syntax",
              "label" => "JSON syntax",
              "outcome" => "pass",
              "message" => "Valid JSON."
            }

          {:error, _} ->
            %{
              "id" => "json-syntax",
              "label" => "JSON syntax",
              "outcome" => "fail",
              "message" => "Invalid JSON. Review the proposed text."
            }
        end
      else
        %{
          "id" => "json-syntax",
          "label" => "JSON syntax",
          "outcome" => "not_applicable",
          "message" => "Only .json files are checked for syntax."
        }
      end

    checks = checks ++ [json]

    %{
      "schema" => "proposed-text-check@1",
      "scope" => "retained-proposed-text-only",
      "provenance" => "runtime-derived-text-check",
      "result_sha256" => digest(text),
      "result_bytes" => byte_size(text),
      "path" => attempt["source"]["path"],
      "at" => DateTime.to_iso8601(DateTime.utc_now()),
      "checks" => checks,
      "outcome" => if(Enum.any?(checks, &(&1["outcome"] == "fail")), do: "fail", else: "pass")
    }
  end

  defp line_check(id, label, lines, predicate) do
    matches = lines |> Enum.with_index(1) |> Enum.filter(fn {line, _} -> predicate.(line) end)

    %{
      "id" => id,
      "label" => label,
      "outcome" => if(matches == [], do: "pass", else: "fail"),
      "count" => length(matches),
      "lines" => matches |> Enum.take(20) |> Enum.map(&elem(&1, 1)),
      "message" =>
        if(matches == [],
          do: "No findings.",
          else: "Review the listed lines; up to 20 are shown."
        )
    }
  end

  defp event(revision, status, note),
    do: %{
      "revision" => revision,
      "status" => status,
      "note" => note,
      "at" => DateTime.to_iso8601(DateTime.utc_now())
    }

  defp persist(record, s) do
    attempts = Map.put(s["development_attempts"], record["id"], record)

    # Reserve a bounded final outcome for every admitted, unfinished run.
    reserved =
      attempts
      |> Map.values()
      |> Enum.flat_map(&(Map.get(&1, "test_runs", %{}) |> Map.values()))
      |> Enum.count(&(&1["state"] == "started"))
      |> Kernel.*(4608)

    # Bound serialized bytes too: control characters can expand in JSON frames.
    with {:ok, _} <- Ampd.Frame.logical_size(attempts, 64 * 1024),
         {:ok, encoded} <- Ampd.Frame.encode(attempts),
         true <- byte_size(encoded) + reserved <= 64 * 1024 do
      {:ok, record, Map.put(s, "development_attempts", attempts)}
    else
      _ ->
        refuse(
          "attempt-directory-full",
          "Review material exceeds this world's 64 KB limit. Existing records are preserved."
        )
    end
  end
end
