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

  # A finished plan's records become history, and history is bounded. Measured
  # on the live world 2026-09-19: the attempt directory was 141 381 bytes
  # against its 131 072 budget so no test run could start, the plan directory
  # 69 745 against 65 536 so no plan could be created, and the two were 92 % of
  # an operator projection frame at 228 538 of 262 144 — four more accepted
  # reviews from a runtime that could not answer a projection at all.
  test "closing a plan retires its attempts in the same write and keeps the evidence", c do
    t = create(c)

    a = %{
      "id" => "accepted-one",
      "task_ref" => t["id"],
      "task_revision" => 1,
      "status" => "accepted",
      "criteria" => String.duplicate("plan criteria, copied onto every attempt. ", 30),
      "acceptance" => %{"schema" => "development-acceptance@1", "task_revision" => 1},
      "history" => [%{"revision" => 1, "status" => "recorded", "note" => "Why this is right"}],
      "files" => [
        %{
          "source" => %{
            "path" => "a.ex",
            "result_sha256" => String.duplicate("a", 64),
            "result_bytes" => 12,
            "basis_id" => String.duplicate("b", 64),
            "draft_sha256" => String.duplicate("c", 64),
            "head" => String.duplicate("d", 40),
            "world" => [1, 2, 3]
          }
        }
      ],
      "test_runs" => %{
        "run-1" => %{
          "run_id" => "run-1",
          "profile" => "super-javascript-behavior@1",
          "state" => "completed",
          "started_at" => "2026-09-19T00:00:00Z",
          "path" => "/home/somebody/a/very/long/repository/path",
          "world" => [1, 2, 3],
          "revision" => 1,
          "outcome" => %{
            "verdict" => "pass",
            "test_count" => 49,
            "snapshot_sha256" => String.duplicate("e", 64),
            "output" => String.duplicate("TAP output that nothing can act on now. ", 10)
          }
        }
      }
    }

    open_plan = %{a | "id" => "still-open", "task_ref" => "dt_open"}

    state = %{
      "development_tasks" => %{
        t["id"] => t,
        "dt_open" => %{"id" => "dt_open", "status" => "planned"}
      },
      "development_attempts" => %{a["id"] => a, open_plan["id"] => open_plan}
    }

    assert {:ok, _completed, next} =
             DevelopmentTask.update(t["id"], {1, "completed", "Meets the plan criteria"}, state)

    # T14: a terminal attempt of a closed plan LEAVES the live directory in the
    # same write, retired on the way out. The test's subject is unchanged -- the
    # evidence survives -- but it survives in the archive, which
    # `@directory_bytes` does not count and which readers still see through
    # `Loci.development_attempts/0`.
    refute Map.has_key?(next["development_attempts"], "accepted-one")
    retired = next["development_attempts_archive"]["accepted-one"]

    # The evidence stays, whole.
    assert retired["acceptance"] == a["acceptance"]
    assert retired["history"] == a["history"]
    assert retired["status"] == "accepted" and retired["task_revision"] == 1
    assert retired["test_runs"]["run-1"]["outcome"]["verdict"] == "pass"
    assert retired["test_runs"]["run-1"]["outcome"]["test_count"] == 49

    assert retired["test_runs"]["run-1"]["outcome"]["snapshot_sha256"] ==
             String.duplicate("e", 64)

    assert retired["files"] == [
             %{
               "source" => %{
                 "path" => "a.ex",
                 "result_sha256" => String.duplicate("a", 64),
                 "result_bytes" => 12
               }
             }
           ]

    # The working material goes, and with it most of the bytes.
    refute Map.has_key?(retired, "criteria")
    refute Map.has_key?(retired["test_runs"]["run-1"], "path")
    refute Map.has_key?(retired["test_runs"]["run-1"]["outcome"], "output")

    assert byte_size(:erlang.term_to_binary(retired)) <
             div(byte_size(:erlang.term_to_binary(a)), 2)

    # An attempt on a plan that is still open is not touched, and retiring
    # twice is retiring once.
    assert next["development_attempts"]["still-open"] == open_plan
    assert Ampd.DevelopmentAttempt.retire(retired) == retired
  end

  test "a closed plan keeps the note it opened with and the last three", c do
    t = create(c)

    long =
      Enum.map(1..9, &%{"revision" => &1, "status" => "planned", "note" => "note #{&1}"})

    state = %{
      "development_tasks" => %{t["id"] => Map.put(t, "history", long)},
      "development_attempts" => %{}
    }

    assert {:ok, cancelled, _} =
             DevelopmentTask.update(t["id"], {1, "cancelled", "Superseded"}, state)

    notes = Enum.map(cancelled["history"], & &1["note"])
    assert notes == ["note 1", "note 8", "note 9", "Superseded"]

    # An open plan keeps every note; only a finished one is capped.
    assert {:ok, planned, _} =
             DevelopmentTask.update(t["id"], {1, "planned", "Still open"}, state)

    assert length(planned["history"]) == 10
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

    # Criteria are immutable, so a result accepted at an EARLIER revision of
    # the plan is a result for this plan. The revision the plan has moved to
    # since — a note, a blocker, an unblock — does not orphan it.
    older = %{a | "task_revision" => 0, "acceptance" => %{a["acceptance"] | "task_revision" => 0}}

    assert {:ok, done, _} =
             DevelopmentTask.update(
               t["id"],
               {1, "completed", "Meets the plan criteria"},
               put_in(state, ["development_attempts", a["id"]], older)
             )

    assert done["completion"]["accepted_attempt_refs"] == ["accepted-one"]

    assert {:ok, ^completed, ^next} =
             DevelopmentTask.update(t["id"], {1, "completed", "Meets the plan criteria"}, next)

    assert {:refused, %{"code" => "task-completed"}} =
             DevelopmentTask.update(t["id"], {2, "planned", "Reopen"}, next)
  end

  # ── T16: the plan directory's exit ───────────────────────────────────────────
  #
  # The attempt directory got one at T14 and settled at 11 % of its budget. The plan directory had
  # none and reached 80,527 bytes of 81,920 in the live world — 1,393 bytes of headroom against a
  # median plan record of 1,804 — so the next plan could not be created, and neither could the plan
  # for the work that would fix it.

  test "a cancelled plan LEAVES the live directory and is still read by everything that reads plans",
       c do
    t = create(c)
    assert map_size(Loci.development_tasks_live()) == 1
    Authority.update_development_task(t["id"], 1, "cancelled", "Changed priorities")

    assert map_size(Loci.development_tasks_live()) == 0, "a finished plan does not hold the bound"
    assert map_size(Loci.development_tasks_archive()) == 1
    # out of the BOUND, not out of view: every reader still sees it
    assert Loci.development_tasks()[t["id"]]["status"] == "cancelled"
    assert Projection.operator()["development_tasks"][t["id"]]["status"] == "cancelled"
  end

  # Without `plan/2` at the lookup this refuses `task-unknown`, which says the plan never existed
  # rather than that it is finished — a different fact, and the wrong one.
  test "an archived plan refuses further updates BY NAME, not as an unknown plan", c do
    t = create(c)
    Authority.update_development_task(t["id"], 1, "cancelled", "Changed priorities")

    assert {:refused, %{"code" => "task-cancelled"}} =
             Authority.update_development_task(t["id"], 2, "planned", "Revive")
  end

  # The obvious-but-wrong version searches only the live half and creates a TWIN with the same
  # client_ref, which every driver in this tree relies on not happening.
  test "creation stays idempotent by client_ref after the plan has been archived", c do
    t = create(c)
    Authority.update_development_task(t["id"], 1, "cancelled", "Changed priorities")

    again = create(c)

    assert again["id"] == t["id"],
           "a request whose plan was archived must not create a second one"

    assert map_size(Loci.development_tasks()) == 1
    assert map_size(Loci.development_tasks_live()) == 0
  end

  test "a plan that is still open stays live, and finishing one frees a slot rather than a byte only",
       c do
    open_plan = create(c)
    assert map_size(Loci.development_tasks_live()) == 1

    other =
      Authority.create_development_task(%{c.fields | "client_ref" => "request-two"})

    assert map_size(Loci.development_tasks_live()) == 2
    Authority.update_development_task(other["id"], 1, "completed-not-a-status", "nope")
    assert map_size(Loci.development_tasks_live()) == 2, "a refused update archives nothing"
    assert Loci.development_tasks_live()[open_plan["id"]]["status"] == "planned"
  end

  # ── T17: the frame carries the card, not the record ─────────────────────────
  #
  # T14 and T16 gave the two directories an exit, and each settled far under its
  # bound. Neither bounded the FRAME. `Loci.development_tasks/0` merges the
  # archive back for readers — which is why finishing a plan does not blank its
  # card — so every archived byte still travelled on every projection. Measured
  # on the live world the day before this change: the loci block alone weighed
  # 233,916 of the 262,144 a frame may carry (89.2 %), and 172,641 of that was
  # archive. Carding both archives puts the same block at 142,431 (54.3 %).

  test "T17 · an archived plan travels as a card that names what it left behind", c do
    t = create(c)
    Authority.update_development_task(t["id"], 1, "cancelled", "Changed priorities")

    card = Projection.operator()["development_tasks"][t["id"]]

    # Identity and outcome stay. This is still the plan, and every reference to
    # it still resolves — the property T16 exists to preserve.
    assert card["status"] == "cancelled"
    assert card["title"] == t["title"]
    assert card["lane_ref"] == t["lane_ref"]

    # The weight goes.
    refute Map.has_key?(card, "history")
    refute Map.has_key?(card, "criteria")

    # And the card SAYS it went. That sentence is the whole difference between
    # a card and a projection that lies by omission: a reader can tell "not
    # sent in this frame" from "never recorded", and is told where to ask.
    assert card["archived"] == %{
             "schema" => "archived-record-card@1",
             "omitted" => ["history", "criteria"],
             "read_with" => "read_development_task"
           }
  end

  test "T17 · a LIVE plan is untouched — the card is for the archive and nothing else", c do
    t = create(c)
    live = Projection.operator()["development_tasks"][t["id"]]

    assert live["criteria"] == c.fields["criteria"]
    assert is_list(live["history"])
    refute Map.has_key?(live, "archived")
  end

  # The rule this runtime already states for its history windows — *a cursor
  # with nothing to give it to is a promise the protocol does not keep* — in
  # the shape a card makes it.
  test "T17 · the door returns exactly what the card left behind", c do
    t = create(c)
    Authority.update_development_task(t["id"], 1, "cancelled", "Changed priorities")
    card = Projection.operator()["development_tasks"][t["id"]]

    assert %{"allow" => true, "development_task" => full} =
             Control.command(c.human, :read_development_task, [t["id"]])

    for key <- card["archived"]["omitted"] do
      assert Map.has_key?(full, key), "the door did not return #{key}, which the card promised"
    end

    assert full["criteria"] == c.fields["criteria"]
    assert List.last(full["history"])["note"] == "Changed priorities"
    assert full == Loci.development_tasks()[t["id"]]
  end

  # A card cannot tell its reader which of the two maps its record is in, so a
  # door that only opened onto the archive would ask the caller a question the
  # card does not answer.
  test "T17 · the door answers for a live plan too", c do
    t = create(c)

    assert %{"allow" => true, "development_task" => full} =
             Control.command(c.human, :read_development_task, [t["id"]])

    assert full["status"] == "planned"
  end

  test "T17 · a ref naming no plan is refused by name, not answered with an empty record", c do
    assert %{"allow" => false, "refusal" => %{"code" => "record-unknown"}} =
             Control.command(c.human, :read_development_task, ["dt_9999"])
  end

  test "T17 · the door is human control only, because the card is only in an operator projection",
       c do
    assert %{"allow" => false} = Control.command(c.agent, :read_development_task, ["dt_0001"])
  end

  # A card claiming to have withheld a field the record never had sends its
  # reader to a door for nothing, and "the plan has no criteria" and "the frame
  # is not carrying the criteria" are different answers to different questions.
  test "T17 · `omitted` names only the fields the record actually had" do
    cards =
      Projection.archived_cards(
        %{"dt_x" => %{"id" => "dt_x", "history" => [%{"note" => "opened"}]}},
        Projection.archived_plan_omits(),
        "read_development_task"
      )

    assert cards["dt_x"]["archived"]["omitted"] == ["history"]
  end

  # The pinning assertion. Re-adding either omitted field to the card fails it,
  # which is the failure mode this task exists to prevent recurring.
  test "T17 · the card weighs a fraction of the record" do
    record = %{
      "id" => "dt_x",
      "status" => "completed",
      "title" => "A finished plan",
      "criteria" => String.duplicate("c", 4_000),
      "history" =>
        for(
          _ <- 1..20,
          do: %{
            "at" => "2026-09-20T00:00:00Z",
            "status" => "planned",
            "note" => String.duplicate("n", 200)
          }
        )
    }

    cards =
      Projection.archived_cards(
        %{"dt_x" => record},
        Projection.archived_plan_omits(),
        "read_development_task"
      )

    {:ok, full_bytes} = Ampd.Frame.logical_size(record)
    {:ok, card_bytes} = Ampd.Frame.logical_size(cards["dt_x"])

    assert full_bytes > 8_000
    assert card_bytes < div(full_bytes, 10)
  end

  # ── T18a: the ceilings ride the projection, before they refuse ───────────────
  #
  # Every bound in this runtime has announced itself by refusing the work that
  # reached it — the attempt directory, the plan directory, the device test
  # history, and the frame, which did it while carrying the review of the change
  # that bounded the frame. This is the signal arriving earlier than that.

  test "T18a · the operator projection carries what this world has left", c do
    create(c)
    cap = Projection.operator()["capacity"]

    assert cap["schema"] == "world-capacity@1"
    assert cap["frame"]["max"] == Ampd.Frame.max_bytes()
    assert cap["plans"]["max"] == 80 * 1024
    assert cap["attempts"]["max"] == 128 * 1024
    assert cap["plans"]["bytes"] > 0 and cap["plans"]["records"] == 1

    # It says what it is not counting. A frame figure that silently excluded its
    # own block would be almost right, which is the worst kind of right.
    assert cap["frame"]["measures"] =~ "excluding the capacity block"
  end

  # The property T16 exists for, read off the bar a person looks at: finishing a
  # plan must move the number DOWN, or the surface would show a directory filling
  # up while the guard it is drawn from sees room.
  test "T18a · archiving a plan lowers the figure the plan guard is keyed to", c do
    t = create(c)
    before = Projection.operator()["capacity"]["plans"]

    Authority.update_development_task(t["id"], 1, "cancelled", "Changed priorities")
    now = Projection.operator()["capacity"]["plans"]

    assert now["bytes"] < before["bytes"]
    assert now["records"] == 0 and now["archived"] == 1
    assert Loci.development_tasks()[t["id"]], "the record itself is still readable"
  end

  # `with_capacity/1` is reached on exactly the state it exists to report, so it
  # must not raise there. A projection that will not encode is the emergency, and
  # a capacity block that crashed on it would remove the only warning.
  test "T18a · a projection too large to encode still gets a capacity block" do
    huge = %{"x" => String.duplicate("a", Ampd.Frame.max_bytes() + 1_000)}
    cap = Projection.with_capacity(huge)["capacity"]

    assert cap["frame"]["bytes"] > Ampd.Frame.max_bytes(),
           "the block must report the overflow, not hide it"
  end
end
