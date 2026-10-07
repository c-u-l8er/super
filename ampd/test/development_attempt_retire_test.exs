# T47 (superlane/t47/TASK.md revision 5; plan dt_0193, client_ref t-task-t47): an accept retires the
# older rounds it replaces. Bot-proposed through Super from TASK.md and amendment 2. Each test's name
# opens with the law it holds (L1-L16, H1-H3), so the plant run can tell which law caught a plant.
#
# How the laws run. X is always a real attempt: recorded, tested and checked through
# `Ampd.Authority` in this test's world. The other rounds are synthetic records carrying what the
# rule reads (id, plan, status, paths, runs, history). The accept itself is
# `Ampd.DevelopmentAttempt.update/3` -- the function `Ampd.Loci` calls inside the ordered patch --
# applied to the world's development state read back from `Ampd.Loci`, with the synthetic rounds
# added. A refusal therefore carries no state (nothing is written), and a success returns the one
# candidate state the write would install. The only whole-world load is the move of `seq` that gives
# X its id, and it runs inside the coordinator's order.
defmodule Ampd.DevelopmentAttemptRetireTest do
  use ExUnit.Case, async: false
  alias Ampd.{Authority, Control, DevelopmentAttempt, DevelopmentTask, Loci, Projection}

  @p "index.html"
  @js "super-javascript-behavior@1"
  @head String.duplicate("a", 40)
  @note "The tested result meets the plan's criteria."
  @ts "2026-10-01T00:00:00.000000Z"
  @dirs ~w(development_attempts development_attempts_archive)

  # ------------------------------------------------------------------
  # Setup and helpers, verbatim from ampd/test/development_attempt_test.exs (f2975ad).

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

  defp hash(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)

  defp fields(c) do
    task = Authority.create_development_task(c.fields)
    draft = "before\r\n"
    proposed = "after\n"

    head = String.duplicate("a", 40)

    source = %{
      "schema" => "selected-file-basis@1",
      "scope" => "selected-file-only",
      "basis_id" =>
        hash(
          JSON.encode!(["selected-file-basis@1", head, "index.html", hash(draft), hash(draft)])
        ),
      "head" => head,
      "path" => "index.html",
      "disk_sha256" => hash(draft),
      "draft_sha256" => hash(draft),
      "draft_bytes" => byte_size(draft),
      "unsaved" => false,
      "result_sha256" => hash(proposed),
      "result_bytes" => byte_size(proposed),
      "task_ref" => task["id"],
      "task_revision" => 1,
      "repository_ref" => task["repository_ref"],
      "world" =>
        Enum.map(
          ~w(world_incarnation world_generation projection_epoch),
          &Projection.continuity()[&1]
        )
    }

    %{
      "client_ref" => "attempt-one",
      "task_ref" => task["id"],
      "task_revision" => 1,
      "source" => source,
      "shared_draft" => draft,
      "proposed_text" => proposed
    }
  end

  defp bind(%{"source" => source} = f) do
    put_in(
      f,
      ["source", "basis_id"],
      hash(
        JSON.encode!([
          "selected-file-basis@1",
          source["head"],
          source["path"],
          source["disk_sha256"],
          source["draft_sha256"]
        ])
      )
    )
  end

  defp test_start(a, run_id \\ "run-fixture") do
    %{
      "run_id" => run_id,
      "revision" => a["revision"],
      "path" => Ampd.Worktree.repo(a["repository_ref"])["path"],
      "world" => a["source"]["world"]
    }
  end

  defp test_outcome(a) do
    %{
      "state" => "completed",
      "verdict" => "pass",
      "reason" => nil,
      "source_basis_id" => a["source"]["basis_id"],
      "result_sha256" => a["source"]["result_sha256"],
      "snapshot_sha256" => hash("snapshot"),
      "node_sha256" => hash("node"),
      "test_count" => 1,
      "output" => "one test passed",
      "output_omitted" => false
    }
  end

  defp acceptance_fields(a) do
    start = test_start(a)

    Map.merge(Map.drop(start, ["run_id"]), %{
      "run_id" => "run-fixture",
      "snapshot_sha256" => hash("snapshot"),
      "result_sha256" => a["source"]["result_sha256"],
      "head" => a["source"]["head"]
    })
  end

  # ------------------------------------------------------------------
  # The world, and X.

  defp world do
    %{
      "workspaces" => Loci.workspaces(),
      "goals" => Loci.goals(),
      "lanes" => Loci.lanes(),
      "workers" => Loci.workers(),
      "bots" => Loci.bots(),
      "development_tasks" => Loci.development_tasks_live(),
      "development_tasks_archive" => Loci.development_tasks_archive(),
      "development_attempts" => Loci.development_attempts_live(),
      "development_attempts_archive" => Loci.development_attempts_archive(),
      "caps" => Loci.caps(),
      "carrier_attempts" => Map.new(Loci.attempts(), &{&1["ticket_id"], &1})
    }
  end

  # Moves the world's `seq`, so the next attempt is `da_` + (seq + 1). The whole world is loaded
  # only inside the coordinator's order.
  defp load_seq!(seq) do
    s = Map.put(world(), "seq", seq)
    result = Ampd.AuthorityCoordinator.transact(fn -> Loci.load_state(s) end)
    refute match?({:refused, _}, result), "loading the world refused: #{inspect(result)}"
  end

  defp id_of(seq), do: "da_" <> String.pad_leading(Integer.to_string(seq), 4, "0")

  defp ok!(%{"id" => _} = record), do: record
  defp ok!({:ok, %{"id" => _} = record}), do: record
  defp ok!({:ok, %{"id" => _} = record, _}), do: record
  defp ok!(other), do: flunk("Ampd.Authority did not return a record: #{inspect(other)}")

  # X: recorded, tested and (unless `prepare: false`) checked through `Ampd.Authority`.
  # Returns {x, plan, state} with the state read back from `Ampd.Loci`.
  defp real_x(c, opts \\ []) do
    seq = Keyword.get(opts, :seq, 999)
    prepare? = Keyword.get(opts, :prepare, true)
    %{"id" => task_ref} = Authority.create_development_task(c.fields)
    load_seq!(seq)

    request =
      case Keyword.get(opts, :set) do
        nil -> fields(c)
        paths -> set_request(c, task_ref, paths)
      end

    a = ok!(Authority.record_development_attempt(request))
    assert a["id"] == id_of(seq + 1), "X should be #{id_of(seq + 1)}, got #{inspect(a["id"])}"
    ok!(Authority.begin_development_test(a["id"], test_start(a)))

    ok!(
      Authority.finish_development_test(
        a["id"],
        "run-fixture",
        a["source"]["world"],
        test_outcome(a)
      )
    )

    if prepare?, do: ok!(Authority.prepare_development_acceptance(a["id"], acceptance_fields(a)))

    s = world()
    x = s["development_attempts"][a["id"]]
    assert x["status"] == "recorded"
    assert is_map(x["acceptance_check"]) == prepare?
    {x, s["development_tasks"][task_ref], s}
  end

  defp set_request(c, task_ref, paths) do
    base = fields(c)

    %{
      "schema" => "development-change-set-request@1",
      "client_ref" => "x-set",
      "task_ref" => task_ref,
      "task_revision" => 1,
      "material" => %{
        "files" =>
          Enum.map(paths, fn path ->
            bind(%{
              "source" => Map.put(base["source"], "path", path),
              "shared_draft" => base["shared_draft"],
              "proposed_text" => base["proposed_text"]
            })
          end)
      }
    }
  end

  # ------------------------------------------------------------------
  # Synthetic rounds: what the rule reads, nothing more.

  defp ev(revision, status, note),
    do: %{"revision" => revision, "status" => status, "note" => note, "at" => @ts}

  defp src(id, path),
    do: %{
      "schema" => "selected-file-basis@1",
      "scope" => "selected-file-only",
      "path" => path,
      "head" => @head,
      "basis_id" => hash("basis #{id} #{path}"),
      "result_sha256" => hash("result #{id} #{path}"),
      "result_bytes" => 1
    }

  # A single-file round when `paths` is a string, a `development-review-set@1` when it is a list.
  defp review(id, plan, paths, attrs \\ %{}) do
    shape =
      if is_binary(paths) do
        %{"schema" => "development-review-attempt@1", "source" => src(id, paths)}
      else
        %{
          "schema" => "development-review-set@1",
          "files" => Enum.map(paths, &%{"source" => src(id, &1)}),
          "source" => %{
            "schema" => "selected-file-set-basis@1",
            "scope" => "selected-file-set-only",
            "head" => @head,
            "basis_id" => hash("set #{id}"),
            "result_sha256" => hash("set result #{id}")
          }
        }
      end

    %{
      "id" => id,
      "client_ref" => "round-#{id}",
      "task_ref" => plan["id"],
      "task_revision" => 1,
      "revision" => 1,
      "workspace_ref" => plan["workspace_ref"],
      "bot_ref" => plan["bot_ref"],
      "repository_ref" => plan["repository_ref"],
      "world_ref" => plan["world_ref"],
      "plan_title" => plan["title"],
      "criteria" => plan["criteria"],
      "status" => "recorded",
      "provenance" => "human-recorded-review-material",
      "history" => [
        ev(1, "recorded", "Proposal recorded for review. No validation or acceptance is claimed.")
      ]
    }
    |> Map.merge(shape)
    |> Map.merge(attrs)
  end

  defp accepted(id, plan, paths, attrs \\ %{}) do
    review(
      id,
      plan,
      paths,
      Map.merge(
        %{
          "status" => "accepted",
          "revision" => 2,
          "history" => [ev(1, "recorded", "Recorded."), ev(2, "accepted", "Accepted.")],
          "acceptance" => %{
            "schema" => "development-acceptance@1",
            "provenance" => "human-control-decision",
            "requested_revision" => 1,
            "note" => "Accepted.",
            "accepted_at" => @ts
          }
        },
        attrs
      )
    )
  end

  defp history(n),
    do: %{"revision" => n, "history" => Enum.map(1..n, &ev(&1, "recorded", "Note #{&1}."))}

  defp started(run_id),
    do: %{
      "schema" => "development-test-run@1",
      "run_id" => run_id,
      "state" => "started",
      "revision" => 1,
      "profile" => @js,
      "started_at" => @ts
    }

  defp finished(run_id),
    do:
      Map.merge(started(run_id), %{
        "state" => "completed",
        "revision" => 2,
        "finished_at" => @ts,
        "outcome" => %{"state" => "completed", "verdict" => "pass", "test_count" => 1}
      })

  # Another plan, never in the plan directory.
  defp other(plan), do: Map.put(plan, "id", "dt_0990")

  defp put(s, records),
    do:
      Map.update!(s, "development_attempts", fn live ->
        Enum.reduce(records, live, &Map.put(&2, &1["id"], &1))
      end)

  # ------------------------------------------------------------------
  # The accept, the expected transitions, and the control.

  defp accept(s, x, note \\ @note) do
    check = x["acceptance_check"]

    DevelopmentAttempt.update(
      x["id"],
      {:accept, x["revision"], check["token"], note, check["world"]},
      s
    )
  end

  defp accept!(s, x, note \\ @note) do
    assert {:ok, x2, s2} = accept(s, x, note)
    assert x2["status"] == "accepted"
    {x2, s2}
  end

  defp note(witnesses, x_id),
    do:
      "Superseded by accepted " <>
        Enum.join(witnesses, ", ") <> ": retired on the accept of " <> x_id <> " (T47)"

  # The transition a manual dismissal makes.
  defp dismissed(y, note) do
    next = y["revision"] + 1
    event = %{"revision" => next, "status" => "dismissed", "note" => note, "at" => now()}

    y
    |> Map.put("revision", next)
    |> Map.put("status", "dismissed")
    |> Map.update!("history", &(&1 ++ [event]))
  end

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())

  defp loose_last(%{"history" => history} = record) do
    {last, prefix} = List.pop_at(history, -1)
    assert {:ok, _, _} = DateTime.from_iso8601(last["at"])
    Map.put(record, "history", prefix ++ [Map.put(last, "at", :loose)])
  end

  defp loose_x(record) do
    assert {:ok, _, _} = DateTime.from_iso8601(record["acceptance"]["accepted_at"])
    record |> loose_last() |> put_in(["acceptance", "accepted_at"], :loose)
  end

  defp assert_retired(s, y, note) do
    id = y["id"]
    refute Map.has_key?(s["development_attempts"], id), "#{id} should have left the live directory"
    got = s["development_attempts_archive"][id]
    assert got, "#{id} should be in the archive"
    assert got["status"] == "dismissed"
    assert got["revision"] == y["revision"] + 1
    assert length(got["history"]) == length(y["history"]) + 1
    assert List.last(got["history"])["revision"] == y["revision"] + 1
    assert List.last(got["history"])["note"] == note
    assert loose_last(got) == loose_last(DevelopmentAttempt.retire(dismissed(y, note)))
  end

  defp assert_untouched(s, y) do
    id = y["id"]
    assert s["development_attempts"][id] == y, "#{id} should stay live and untouched"
    refute Map.has_key?(s["development_attempts_archive"], id)
  end

  # The base accept's record (b3a2570's accept clause), restated here from X's checked record --
  # never a second run of the changed module.
  defp base_accepted(x, note) do
    check = x["acceptance_check"]
    at = now()
    next = x["revision"] + 1

    latest =
      x
      |> Map.get("test_runs", %{})
      |> Map.values()
      |> Enum.group_by(&(&1["profile"] || @js))
      |> Enum.map(fn {_, runs} -> Enum.max_by(runs, &{&1["started_at"], &1["run_id"]}) end)

    decision = %{
      "schema" => "development-acceptance@1",
      "provenance" => "human-control-decision",
      "scope" => "captured-tested-result",
      "requested_revision" => x["revision"],
      "token" => check["token"],
      "note" => note,
      "run_id" => check["run_id"],
      "profile_run_refs" => Map.new(latest, &{&1["profile"] || @js, &1["run_id"]}),
      "snapshot_sha256" => check["snapshot_sha256"],
      "result_sha256" => check["result_sha256"],
      "source_basis_id" => x["source"]["basis_id"],
      "task_revision" => x["task_revision"],
      "native_checked_at" => check["checked_at"],
      "accepted_at" => at
    }

    x
    |> Map.delete("acceptance_check")
    |> Map.put("acceptance", decision)
    |> Map.put("status", "accepted")
    |> Map.put("revision", next)
    |> Map.update!(
      "history",
      &(&1 ++ [%{"revision" => next, "status" => "accepted", "note" => note, "at" => at}])
    )
  end

  defp assert_base_accept(x2, x, note) do
    assert loose_x(x2) == loose_x(base_accepted(x, note))
    assert Enum.drop(x2["history"], -1) == x["history"]
  end

  # The same accept without T47: X's accepted record put into the input, then
  # `archive_finished/3`, which is all `persist/2` did before.
  defp control(s, x_accepted) do
    {live, archive} =
      DevelopmentAttempt.archive_finished(
        Map.put(s["development_attempts"], x_accepted["id"], x_accepted),
        s["development_attempts_archive"],
        DevelopmentTask.plans(s)
      )

    s
    |> Map.put("development_attempts", live)
    |> Map.put("development_attempts_archive", archive)
  end

  defp usage(live), do: DevelopmentAttempt.directory_usage(live)["bytes"]
  defp cap, do: DevelopmentAttempt.directory_usage(%{})["max"]

  # L8: one filler record of another plan (recorded, so no write archives it) whose length puts the
  # cap where the case needs it. U0 is the input, U1 the ordinary accept with Y kept (the base
  # transition, then `archive_finished/3`), U2 the same with Y retired.
  defp place_cap(s0, x, plan, y, text, first, fits?) do
    cap = cap()

    measure = fn pad ->
      filler =
        review("da_0100", other(plan), "l8/filler.txt", %{
          "criteria" => String.duplicate("f", pad)
        })

      s = put(s0, [y, filler])
      kept = control(s, base_accepted(x, text))["development_attempts"]
      {s, usage(s["development_attempts"]), usage(kept), usage(Map.delete(kept, y["id"]))}
    end

    {_, _, u1, u2} = measure.(0)
    start = first.(u1, u2, cap)

    found =
      Enum.find_value(0..64, fn d ->
        Enum.find_value(Enum.uniq([start + d, start - d]), fn pad ->
          if pad >= 0 do
            m = measure.(pad)
            if fits?.(m, cap), do: m
          end
        end)
      end)

    assert found, "no filler length places the cap as this case needs (start #{start})"
    {s, _, _, _} = found
    assert {:ok, _} = Ampd.Frame.logical_size(s["development_attempts"], cap)
    found
  end

  # L16: three rounds of P and one acceptance; da_0900 and da_0901 qualify, da_0902 does not.
  defp l16_rounds(plan) do
    {[
       review("da_0900", plan, @p),
       review("da_0901", plan, [@p, "l16/b.txt"]),
       accepted("da_0950", plan, "l16/b.txt"),
       review("da_0902", plan, "l16/c.txt")
     ],
     %{
       "da_0900" => note(["da_1000"], "da_1000"),
       "da_0901" => note(["da_0950", "da_1000"], "da_1000")
     }}
  end

  # ------------------------------------------------------------------
  # The laws.

  test "L1 basic: an older recorded single-file round on X's path is dismissed and archived in X's accept write",
       c do
    {x, plan, s0} = real_x(c)
    y = review("da_0900", plan, @p)
    s = put(s0, [y])
    {x2, s2} = accept!(s, x)

    assert s2["development_attempts"]["da_1000"] == x2
    assert_retired(s2, y, note(["da_1000"], "da_1000"))

    got = s2["development_attempts_archive"]["da_0900"]

    assert [%{"revision" => 1, "status" => "recorded"}, %{"revision" => 2, "status" => "dismissed"}] =
             got["history"]

    # The bytes freed, measured with Ampd.Frame.encode as ../a47/MEASURE.md did.
    {:ok, before_bytes} = Ampd.Frame.encode(control(s, x2)["development_attempts"])
    {:ok, after_bytes} = Ampd.Frame.encode(s2["development_attempts"])
    assert byte_size(before_bytes) - byte_size(after_bytes) > 0
  end

  test "L2 all paths: a set with a member no witness covers stays live and untouched", c do
    {x, plan, s0} = real_x(c)
    y = review("da_0900", plan, [@p, "l2/other.txt"])
    pos = review("da_0901", plan, @p)
    {_, s2} = accept!(put(s0, [y, pos]), x)

    assert_untouched(s2, y)
    assert_retired(s2, pos, note(["da_1000"], "da_1000"))
  end

  test "L3 age, numerically: da_9999 is older than X da_10000 and is retired; a newer round is untouched",
       c do
    {x, plan, s0} = real_x(c, seq: 9999)
    assert x["id"] == "da_10000"
    older = review("da_9999", plan, @p)
    newer = review("da_10001", plan, @p)
    {_, s2} = accept!(put(s0, [older, newer]), x)

    assert_retired(s2, older, note(["da_10000"], "da_10000"))
    assert_untouched(s2, newer)
  end

  test "L4 (a) one plan: an otherwise eligible round of another plan stays untouched", c do
    {x, plan, s0} = real_x(c)
    foreign = review("da_0900", other(plan), @p)
    pos = review("da_0901", plan, @p)
    {_, s2} = accept!(put(s0, [foreign, pos]), x)

    assert_untouched(s2, foreign)
    assert_retired(s2, pos, note(["da_1000"], "da_1000"))
  end

  test "L4 (b) one plan: another plan's newer acceptance is no witness", c do
    {x, plan, s0} = real_x(c)
    y = review("da_0900", plan, [@p, "l4/b.txt"])
    w = accepted("da_0950", other(plan), "l4/b.txt")
    {_, s2} = accept!(put(s0, [y, w]), x)

    assert_untouched(s2, y)
    assert s2["development_attempts"]["da_0950"] == w
  end

  test "L5 started run: a covered round with a started run stays untouched, also with two runs, one started",
       c do
    {x, plan, s0} = real_x(c)
    one = review("da_0900", plan, @p, %{"test_runs" => %{"z1" => started("z1")}})

    two =
      review("da_0901", plan, @p, %{
        "test_runs" => %{"z1" => finished("z1"), "z2" => started("z2")}
      })

    pos = review("da_0902", plan, @p)
    {_, s2} = accept!(put(s0, [one, two, pos]), x)

    for y <- [one, two] do
      assert_untouched(s2, y)
      got = s2["development_attempts"][y["id"]]

      assert {got["status"], got["revision"], got["history"], got["test_runs"]} ==
               {y["status"], y["revision"], y["history"], y["test_runs"]}
    end

    assert_retired(s2, pos, note(["da_1000"], "da_1000"))
  end

  test "L6 accepted stay: X is the base accept's record, an older accepted W stays, completion names the same refs",
       c do
    {x, plan, s0} = real_x(c)
    w = accepted("da_0950", plan, @p)
    y = review("da_0900", plan, @p)
    s = put(s0, [w, y])
    {x2, s2} = accept!(s, x)

    assert_base_accept(x2, x, @note)
    assert s2["development_attempts"]["da_1000"] == x2

    # W: older, accepted, on X's path, no started run, 2 events, a note that would fit.
    assert s2["development_attempts"]["da_0950"] == w
    refute Map.has_key?(s2["development_attempts_archive"], "da_0950")
    assert_retired(s2, y, note(["da_1000"], "da_1000"))

    # The real completion path. The control still holds Y open, so Y is dismissed by hand there
    # first, as it would have to be without T47.
    assert {:ok, _, ctl} =
             DevelopmentAttempt.update(
               "da_0900",
               {1, "dismissed", "Dismissed by hand."},
               control(s, x2)
             )

    complete = fn state ->
      current = DevelopmentTask.plan(state, plan["id"])

      assert {:ok, done, _} =
               DevelopmentTask.update(
                 plan["id"],
                 {current["revision"], "completed", "Every round is settled."},
                 state
               )

      done["completion"]["accepted_attempt_refs"]
    end

    assert complete.(s2) == complete.(ctl)
    assert complete.(s2) == ["da_0950", "da_1000"]
  end

  test "L7 statuses: needs_changes is retired like recorded; dismissed and accepted records are not rewritten",
       c do
    {x, plan, s0} = real_x(c)

    nc =
      review("da_0900", plan, @p, %{
        "status" => "needs_changes",
        "revision" => 2,
        "history" => [ev(1, "recorded", "Recorded."), ev(2, "needs_changes", "Needs changes.")]
      })

    gone =
      review("da_0901", plan, @p, %{
        "status" => "dismissed",
        "revision" => 2,
        "history" => [ev(1, "recorded", "Recorded."), ev(2, "dismissed", "Dismissed by hand.")]
      })

    w = accepted("da_0902", plan, @p)
    {_, s2} = accept!(put(s0, [nc, gone, w]), x)

    assert_retired(s2, nc, note(["da_1000"], "da_1000"))

    # The settled dismissal leaves by the existing step (T25), with its history as it was.
    refute Map.has_key?(s2["development_attempts"], "da_0901")
    assert s2["development_attempts_archive"]["da_0901"] == DevelopmentAttempt.retire(gone)

    assert s2["development_attempts"]["da_0902"] == w
  end

  test "L8 (a) one candidate state: a refused accept (acceptance-stale) returns the refusal and retires nothing",
       c do
    {x, plan, s0} = real_x(c)
    y = review("da_0900", plan, @p)

    # Y qualifies: the same accept, unrefused, retires it.
    {_, ok} = accept!(put(s0, [y]), x)
    assert_retired(ok, y, note(["da_1000"], "da_1000"))

    # A later run, still started, makes X's coverage stale.
    late = Map.put(started("run-late"), "started_at", "9999-12-31T00:00:00.000000Z")
    stale_x = put_in(x, ["test_runs", "run-late"], late)
    s = put(s0, [y, stale_x])

    assert {:refused, %{"code" => "acceptance-stale"}} = accept(s, stale_x)
  end

  test "L8 (b) one candidate state: U0 <= C < U2 refuses attempt-directory-full and leaves the input",
       c do
    {x, plan, s0} = real_x(c)
    text = String.duplicate("n", 1000)
    y = review("da_0900", plan, @p, %{"criteria" => "c"})

    # Y qualifies on this accept when the directory has room.
    {_, ok} = accept!(put(s0, [y]), x, text)
    assert_retired(ok, y, note(["da_1000"], "da_1000"))

    {s, u0, _u1, u2} =
      place_cap(
        s0,
        x,
        plan,
        y,
        text,
        fn _u1, u2, cap -> cap - u2 + 1 end,
        fn {_, u0, _, u2}, cap -> u0 <= cap and cap < u2 end
      )

    assert u0 <= cap() and cap() < u2
    assert {:refused, %{"code" => "attempt-directory-full"}} = accept(s, x, text)
  end

  test "L8 (c) one candidate state: U0 <= C, U1 > C >= U2 succeeds with Y retired", c do
    {x, plan, s0} = real_x(c)
    text = "Meets the criteria."
    y = review("da_0900", plan, @p, %{"criteria" => String.duplicate("y", 4000)})

    {s, u0, u1, u2} =
      place_cap(
        s0,
        x,
        plan,
        y,
        text,
        fn u1, _u2, cap -> cap - u1 + 1 end,
        fn {_, u0, u1, u2}, cap -> u0 <= cap and u1 > cap and cap >= u2 end
      )

    assert u0 <= cap() and u1 > cap() and cap() >= u2
    {_, s2} = accept!(s, x, text)
    assert_retired(s2, y, note(["da_1000"], "da_1000"))
    assert usage(s2["development_attempts"]) <= cap()
  end

  test "L9 sets: a set retires only when every member path has a witness; an accepted set witnesses through any member",
       c do
    {x, plan, s0} = real_x(c)
    # First member covered by X, second by nothing: stays.
    gap = review("da_0900", plan, [@p, "l9/u.txt"])
    # First member covered only through W's second member, second member by X: retired.
    late = review("da_0901", plan, ["l9/w.txt", @p])
    w = accepted("da_0950", plan, ["l9/z.txt", "l9/w.txt"])
    {_, s2} = accept!(put(s0, [gap, late, w]), x)

    assert_untouched(s2, gap)
    assert_retired(s2, late, note(["da_0950", "da_1000"], "da_1000"))
    assert s2["development_attempts"]["da_0950"] == w
  end

  test "L10 (a) witness newer than Y: an older acceptance on Y's path does not witness it", c do
    {x, plan, s0} = real_x(c)
    w = accepted("da_0850", plan, "l10/q.txt")
    y = review("da_0900", plan, "l10/q.txt")
    {_, s2} = accept!(put(s0, [w, y]), x)

    assert_untouched(s2, y)
  end

  test "L10 (b) witness newer than Y: a set covered by X on one member and by an older W on the other stays",
       c do
    {x, plan, s0} = real_x(c)
    w = accepted("da_0850", plan, "l10/b.txt")
    y = review("da_0900", plan, [@p, "l10/b.txt"])
    {_, s2} = accept!(put(s0, [w, y]), x)

    assert_untouched(s2, y)
  end

  test "L11 pooled coverage and the named witnesses: X with a newer W, X preferred, else the newest",
       c do
    {x, plan, s0} = real_x(c)
    pooled = review("da_0900", plan, [@p, "l11/b.txt"])
    w = accepted("da_0950", plan, "l11/b.txt")
    both = review("da_0901", plan, @p)
    w2 = accepted("da_0960", plan, @p)
    pair = review("da_0902", plan, [@p, "l11/c.txt"])
    w3_old = accepted("da_0955", plan, "l11/c.txt")
    w3_new = accepted("da_0965", plan, "l11/c.txt")
    {_, s2} = accept!(put(s0, [pooled, w, both, w2, pair, w3_old, w3_new]), x)

    assert_retired(s2, pooled, note(["da_0950", "da_1000"], "da_1000"))
    # X and W2 both witness index.html: the note names X.
    assert_retired(s2, both, note(["da_1000"], "da_1000"))
    # W3 old and new both witness l11/c.txt, X does not: the note names the newer.
    assert_retired(s2, pair, note(["da_0965", "da_1000"], "da_1000"))

    for kept <- [w, w2, w3_old, w3_new], do: assert(s2["development_attempts"][kept["id"]] == kept)
  end

  test "L12 X must witness: a round fully witnessed by earlier acceptances but not by X stays", c do
    {x, plan, s0} = real_x(c)
    y = review("da_0900", plan, "l12/a.txt")
    w = accepted("da_0950", plan, "l12/a.txt")
    {_, s2} = accept!(put(s0, [y, w]), x)

    assert_untouched(s2, y)
  end

  test "L13 history: at 31 events event 32 is appended; at 32 the round is untouched and the accept succeeds",
       c do
    {x, plan, s0} = real_x(c)
    assert length(x["history"]) < 32
    y31 = review("da_0900", plan, @p, history(31))
    y32 = review("da_0901", plan, @p, history(32))
    {x2, s2} = accept!(put(s0, [y31, y32]), x)

    assert x2["status"] == "accepted"
    assert_retired(s2, y31, note(["da_1000"], "da_1000"))
    got = s2["development_attempts_archive"]["da_0900"]
    assert length(got["history"]) == 32
    assert Enum.take(got["history"], 31) == y31["history"]
    assert %{"revision" => 32, "status" => "dismissed"} = List.last(got["history"])

    assert_untouched(s2, y32)
  end

  test "L14 replay: an exact replay of X's accept returns the same result, appends nothing, retires nothing",
       c do
    {x, plan, s0} = real_x(c)
    z = review("da_0900", plan, @p, %{"test_runs" => %{"z1" => started("z1")}})
    {x2, s2} = accept!(put(s0, [z]), x)
    assert_untouched(s2, z)

    # Z's run finishes; Z would now qualify on a fresh accept, not on a replay.
    z_done = put_in(z, ["test_runs", "z1"], finished("z1"))
    s3 = put(s2, [z_done])

    assert {:ok, ^x2, ^s3} = accept(s3, x)
    assert s3["development_attempts"]["da_0900"] == z_done
  end

  test "L15 prepare: prepare_acceptance of X leaves a round X's accept would retire live and untouched",
       c do
    {x, plan, s0} = real_x(c, prepare: false)
    y = review("da_0900", plan, @p)
    s = put(s0, [y])

    assert {:ok, x2, s2} =
             DevelopmentAttempt.update(x["id"], {:prepare_acceptance, acceptance_fields(x)}, s)

    assert is_map(x2["acceptance_check"])
    assert_untouched(s2, y)

    # The accept that follows does retire it.
    {_, s3} = accept!(s2, x2)
    assert_retired(s3, y, note(["da_1000"], "da_1000"))
  end

  test "L16 (a) record diff against the control: only the expected retired ids differ", c do
    {x, plan, s0} = real_x(c)
    {rounds, notes} = l16_rounds(plan)

    # An archivable record of another plan, as a restored or never-written world may hold. The
    # existing step moves it on any write, with or without T47.
    stale =
      review("da_0800", other(plan), "l16/d.txt", %{
        "status" => "dismissed",
        "revision" => 2,
        "history" => [ev(1, "recorded", "Recorded."), ev(2, "dismissed", "Dismissed.")]
      })

    s = put(s0, [stale | rounds])
    expected = ["da_0900", "da_0901"]
    {x2, t47} = accept!(s, x)

    # X first verified as in L6, then put into the control.
    assert_base_accept(x2, x, @note)
    ctl = control(s, x2)
    assert Map.has_key?(ctl["development_attempts_archive"], "da_0800")

    assert Map.drop(ctl["development_attempts"], expected) == t47["development_attempts"]
    assert Enum.sort(Map.keys(ctl["development_attempts"]) -- Map.keys(t47["development_attempts"])) == expected
    assert Map.drop(t47["development_attempts_archive"], expected) == ctl["development_attempts_archive"]

    assert Enum.sort(
             Map.keys(t47["development_attempts_archive"]) --
               Map.keys(ctl["development_attempts_archive"])
           ) == expected

    for id <- expected do
      want = DevelopmentAttempt.retire(dismissed(s["development_attempts"][id], notes[id]))
      assert loose_last(t47["development_attempts_archive"][id]) == loose_last(want)
    end

    assert Map.drop(t47, @dirs) == Map.drop(ctl, @dirs)
  end

  test "L16 (b) record diff on a normalized input: exactly the expected ids and X change", c do
    {x, plan, s0} = real_x(c)
    {rounds, notes} = l16_rounds(plan)
    s = put(s0, rounds)
    live = s["development_attempts"]
    archive = s["development_attempts_archive"]
    expected = ["da_0900", "da_0901"]

    # Normalized: archive_finished/3 of the input's live directory is the identity.
    assert DevelopmentAttempt.archive_finished(live, archive, DevelopmentTask.plans(s)) ==
             {live, archive}

    {x2, t47} = accept!(s, x)
    assert_base_accept(x2, x, @note)
    t_live = t47["development_attempts"]
    t_archive = t47["development_attempts_archive"]

    assert Enum.sort(Map.keys(live) -- Map.keys(t_live)) == expected
    assert Map.keys(t_live) -- Map.keys(live) == []
    assert t_live["da_1000"] == x2
    refute x2 == live["da_1000"]
    assert Map.drop(t_live, ["da_1000"]) == Map.drop(live, ["da_1000" | expected])

    assert Map.take(t_archive, Map.keys(archive)) == archive
    assert Enum.sort(Map.keys(t_archive) -- Map.keys(archive)) == expected

    for id <- expected do
      want = DevelopmentAttempt.retire(dismissed(live[id], notes[id]))
      assert loose_last(t_archive[id]) == loose_last(want)
    end

    # Every plan record, and everything else in the state, unchanged.
    assert Map.drop(t47, @dirs) == Map.drop(s, @dirs)
  end

  test "H1 (a) odd ids: an id that is not da_ followed by digits only is neither a candidate nor a witness",
       c do
    {x, plan, s0} = real_x(c)
    odd_round = review("da_0901x", plan, @p)
    covered_by_odd = review("da_0900", plan, [@p, "h1/b.txt"])
    odd_witness = accepted("da_0950x", plan, "h1/b.txt")
    pos = review("da_0902", plan, @p)
    {_, s2} = accept!(put(s0, [odd_round, covered_by_odd, odd_witness, pos]), x)

    assert_untouched(s2, odd_round)
    assert_untouched(s2, covered_by_odd)
    assert s2["development_attempts"]["da_0950x"] == odd_witness
    assert_retired(s2, pos, note(["da_1000"], "da_1000"))
  end

  test "H1 (b) odd ids: an X with such an id retires nothing", c do
    {x, plan, s0} = real_x(c)
    odd = "da_1000x"

    odd_x =
      x
      |> Map.put("id", odd)
      |> Map.update("test_runs", %{}, fn runs ->
        Map.new(runs, fn {k, r} -> {k, Map.put(r, "attempt_ref", odd)} end)
      end)

    y = review("da_0900", plan, @p)

    s =
      s0
      |> Map.update!("development_attempts", &Map.delete(&1, x["id"]))
      |> put([odd_x, y])

    {x2, s2} = accept!(s, odd_x)
    assert x2["id"] == odd
    assert_untouched(s2, y)
  end

  test "H2 the note's bound: a 251-character note leaves the round untouched; exactly 250 retires it",
       c do
    {x, plan, s0} = real_x(c, seq: Integer.pow(10, 61) - 1)
    xid = x["id"]
    assert String.length(xid) == 65

    w250 = accepted("da_5" <> String.duplicate("0", 58), plan, "h2/a.txt")
    w251 = accepted("da_5" <> String.duplicate("0", 59), plan, "h2/b.txt")
    y250 = review("da_0900", plan, [@p, "h2/a.txt"])
    y251 = review("da_0901", plan, [@p, "h2/b.txt"])
    n250 = note([w250["id"], xid], xid)
    n251 = note([w251["id"], xid], xid)
    assert String.length(n250) == 250
    assert String.length(n251) == 251

    {_, s2} = accept!(put(s0, [w250, w251, y250, y251]), x)

    assert_retired(s2, y250, n250)
    assert_untouched(s2, y251)
  end

  test "H3 an accepted set as X: it retires an older round on any one of its member paths", c do
    {x, plan, s0} = real_x(c, set: ["h3/a.txt", "h3/b.txt"])
    assert x["schema"] == "development-review-set@1"
    on_b = review("da_0900", plan, "h3/b.txt")
    on_a = review("da_0901", plan, "h3/a.txt")
    elsewhere = review("da_0902", plan, @p)
    {_, s2} = accept!(put(s0, [on_b, on_a, elsewhere]), x)

    assert_retired(s2, on_b, note(["da_1000"], "da_1000"))
    assert_retired(s2, on_a, note(["da_1000"], "da_1000"))
    assert_untouched(s2, elsewhere)
  end
end
