defmodule Ampd.DevelopmentAttemptTest do
  use ExUnit.Case, async: false
  alias Ampd.{Authority, Control, DevelopmentAttempt, Loci, Projection}

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

    # Bound the way the host binds it (`workbench.rs` file_basis): the basis
    # is the digest of what it names, so a record cannot name one thing and
    # carry another. Single-file records check this since 2026-09-18, as
    # change-set members always did.
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

  test "human record preserves exact review material without execution or acceptance", c do
    f = fields(c)

    before =
      {Loci.development_tasks(), Loci.workers(), Ampd.GrantRegistry.list(),
       Ampd.Worktree.resources()}

    assert %{"allow" => true, "development_attempt" => a} =
             Control.command(
               c.human,
               :record_development_attempt,
               Enum.map(DevelopmentAttempt.fields(), &f[&1])
             )

    assert a["shared_draft"] == "before\r\n" and a["proposed_text"] == "after\n"
    assert a["status"] == "recorded" and a["revision"] == 1
    assert a["criteria"] == c.fields["criteria"] and a["bot_ref"] == c.bot["id"]
    # **The record keeps the material; the projection does not carry it.**
    # `development_attempts` is published in full on every frame, and two
    # recorded sets of the maximum permitted size exceed the frame. A STAGED
    # member is therefore published without its bodies. An INLINE record — this
    # one — keeps them: its bytes live in the record and nowhere else, and the
    # store's 64 KiB admission bounds every inline body that can exist. What is
    # added is a reference saying where each side is and whether it can be read.
    stored = Loci.development_attempts()[a["id"]]
    assert stored["shared_draft"] == "before\r\n" and stored["proposed_text"] == "after\n"

    published = Projection.operator()["development_attempts"][a["id"]]
    assert published["shared_draft"] == "before\r\n" and published["proposed_text"] == "after\n"
    assert Map.drop(published, ["content"]) == stored

    assert published["content"]["held"] == "inline"
    assert published["content"]["current"]["digest"] == stored["source"]["draft_sha256"]
    assert published["content"]["current"]["bytes"] == stored["source"]["draft_bytes"]
    assert published["content"]["proposed"]["digest"] == stored["source"]["result_sha256"]
    # Inline material is by definition readable: its bytes are in the record.
    assert published["content"]["current"]["state"] == "available"

    refute Map.has_key?(Projection.agent(c.bot["actor"]), "development_attempts")

    assert before ==
             {Loci.development_tasks(), Loci.workers(), Ampd.GrantRegistry.list(),
              Ampd.Worktree.resources()}
  end

  test "exact retries reuse the record and conflicting requests refuse", c do
    f = fields(c)
    a = Authority.record_development_attempt(f)
    assert Authority.record_development_attempt(f) == a
    altered = bind(%{f | "source" => Map.put(f["source"], "head", String.duplicate("b", 40))})

    assert {:refused, %{"code" => "attempt-request-conflict"}} =
             Authority.record_development_attempt(altered)

    assert map_size(Loci.development_attempts()) == 1
  end

  test "mismatched bytes, sizes and unsupported metadata refuse without writes", c do
    f = fields(c)

    for bad <- [
          Map.put(f, "proposed_text", "other"),
          Map.put(f, "grant", true),
          put_in(f, ["source", "result_bytes"], 0),
          put_in(f, ["source", "path"], "../outside"),
          put_in(f, ["source", "path"], ".git/config"),
          put_in(f, ["source", "disk_sha256"], nil)
        ] do
      assert {:refused, _} = Authority.record_development_attempt(bad)
    end

    assert Loci.development_attempts() == %{}
  end

  test "wrong repository, cancelled plan and stale world refuse", c do
    f = fields(c)

    assert {:refused, _} =
             Authority.record_development_attempt(
               put_in(f, ["source", "repository_ref"], "rp_other")
             )

    assert {:refused, _} =
             Authority.record_development_attempt(
               put_in(f, ["source", "world"], ["other", 1, "other"])
             )

    Authority.update_development_task(f["task_ref"], 1, "cancelled", "Stop")
    assert {:refused, _} = Authority.record_development_attempt(f)
    assert Loci.development_attempts() == %{}
  end

  test "only ordered human control records and updates reviews", c do
    f = fields(c)
    assert {:refused, _} = Loci.record_development_attempt(f)

    assert %{"allow" => false} =
             Control.command(
               c.agent,
               :record_development_attempt,
               Enum.map(DevelopmentAttempt.fields(), &f[&1])
             )

    a = Authority.record_development_attempt(f)
    assert {:refused, _} = Loci.update_development_attempt(a["id"], 1, "needs_changes", "Review")

    assert %{"allow" => false} =
             Control.command(c.agent, :update_development_attempt, [
               a["id"],
               1,
               "needs_changes",
               "Review"
             ])

    assert Loci.development_attempts()[a["id"]] == a
  end

  test "review notes are versioned and preserve immutable source and result", c do
    f = fields(c)
    a = Authority.record_development_attempt(f)
    next = Authority.update_development_attempt(a["id"], 1, "needs_changes", "Improve wording")
    assert next["revision"] == 2 and length(next["history"]) == 2
    assert Map.take(next, DevelopmentAttempt.fields()) == f

    assert Authority.update_development_attempt(a["id"], 1, "needs_changes", "Improve wording") ==
             next

    assert {:refused, _} =
             Authority.update_development_attempt(a["id"], 1, "dismissed", "Different stale note")

    for status <- ["running", "accepted", "validated", "complete"] do
      assert {:refused, _} =
               Authority.update_development_attempt(a["id"], 2, status, "Unsupported")
    end
  end

  test "dismissed attempts are terminal but history remains after plan cancellation", c do
    f = fields(c)
    a = Authority.record_development_attempt(f)
    Authority.update_development_task(f["task_ref"], 1, "cancelled", "Stop plan")
    dismissed = Authority.update_development_attempt(a["id"], 1, "dismissed", "Not pursuing")
    assert dismissed["status"] == "dismissed"
    assert {:refused, _} = Authority.update_development_attempt(a["id"], 2, "recorded", "Revive")
    assert Loci.development_attempts()[a["id"]] == dismissed
  end

  test "store restart retains draft, result and notes; legacy snapshots gain collection", c do
    a = Authority.record_development_attempt(fields(c))
    next = Authority.update_development_attempt(a["id"], 1, "needs_changes", "Retain this")
    :ok = Supervisor.terminate_child(Ampd.Supervisor, Loci)
    {:ok, _} = Supervisor.restart_child(Ampd.Supervisor, Loci)

    # As the world opens the inline bodies move to the content store; the
    # record keeps everything else and reads back the same bytes.
    restarted = Loci.development_attempts()[a["id"]]
    refute Map.has_key?(restarted, "shared_draft") or Map.has_key?(restarted, "proposed_text")

    assert Map.drop(restarted, ~w(shared_draft proposed_text)) ==
             Map.drop(next, ~w(shared_draft proposed_text))

    assert DevelopmentAttempt.member_content(restarted) ==
             {:ok, %{"current" => next["shared_draft"], "proposed" => next["proposed_text"]}}

    assert Loci.shape(Map.delete(Loci.initial(), "development_attempts"))["development_attempts"] ==
             %{}
  end

  test "JSON expansion is bounded before saving review material", c do
    f = fields(c)
    # 24 000 is the largest shared_draft CommandSpec admits, and each control
    # byte becomes a six-character JSON escape: 144 000 encoded against a
    # 131 072 budget, while the logical size stays far under it. That contrast
    # is the test - the encoded check is what catches this, not the logical one.
    draft = String.duplicate(<<1>>, 24000)

    source =
      f["source"]
      |> Map.put("disk_sha256", hash(draft))
      |> Map.put("draft_sha256", hash(draft))
      |> Map.put("draft_bytes", byte_size(draft))
      |> then(&bind(%{"source" => &1})["source"])

    oversized = %{f | "shared_draft" => draft, "source" => source}

    assert {:refused, %{"code" => "attempt-directory-full"}} =
             Authority.record_development_attempt(oversized)

    assert Loci.development_attempts() == %{}
  end

  test "history and aggregate limits preserve earlier records", c do
    f = fields(c)
    a = Authority.record_development_attempt(f)

    for rev <- 1..31,
        do:
          assert(
            is_map(Authority.update_development_attempt(a["id"], rev, "recorded", "Note #{rev}"))
          )

    before = Loci.development_attempts()

    assert {:refused, _} =
             Authority.update_development_attempt(a["id"], 32, "recorded", "Overflow")

    assert Loci.development_attempts() == before
    # Reuse a real retained record to exercise the receiver's aggregate refusal.
    s =
      Loci.initial()
      |> Map.put("development_attempts", %{
        a["id"] => Map.put(a, "criteria", String.duplicate("x", 140_000))
      })

    assert {:refused, %{"code" => "attempt-directory-full"}} =
             DevelopmentAttempt.update(a["id"], {1, "needs_changes", "Bounded"}, s)
  end

  # Retirement is an invariant of the directory, not a migration: it runs on
  # every write, so a world that is ALREADY over its budget heals on its next
  # one rather than being stuck at exactly the point where nothing can be
  # recorded. That was the live world on 2026-09-19 — 141 381 bytes against
  # 131 072, and no test run could start.
  # ------------------------------------------------------------------ T14
  # `retire_finished/2` compacted a finished plan's attempts and left them in
  # the live directory: 8-10 KB became 5-6 KB, about 40 %. Real work, and not a
  # bound -- compaction scales with the SIZE of a record while the problem
  # scales with the NUMBER of them, so ten accepted reviews on 2026-09-19 put
  # the directory back over (32 attempts, 146 455 bytes against 131 072) and no
  # round could run in the world at all. A directory with no exit has no bound
  # at any compaction ratio.

  test "T14 · attempts of a LIVE plan are never archived, whatever their age or the budget", c do
    # The obvious-but-wrong implementation -- evict oldest-first until under
    # budget -- passes every other case in this file and fails this one. A live
    # plan whose attempts were archived could then be neither tested nor
    # accepted, and the suite would still be green.
    f = fields(c)
    live = Authority.record_development_attempt(f)

    # the OLDEST records belong to an OPEN plan; the bulk that can be freed
    # belongs to a CLOSED one and is newer. Oldest-first eviction frees the
    # budget too -- by evicting the live plan's records, which is the bug.
    old_and_live =
      Map.new(1..3, fn n ->
        {"da_aaa_#{n}",
         live
         |> Map.put("id", "da_aaa_#{n}")
         |> Map.put("task_ref", "dt_open")
         |> Map.put("criteria", String.duplicate("a live plan's working material. ", 200))}
      end)

    bulk_done =
      Map.new(1..20, fn n ->
        {"da_zzz_#{n}",
         live
         |> Map.put("id", "da_zzz_#{n}")
         |> Map.put("task_ref", "dt_done")
         |> Map.put("status", "accepted")
         |> Map.put("criteria", String.duplicate("a closed plan's working material. ", 200))}
      end)

    s =
      Loci.initial()
      |> Map.put("development_tasks", %{
        "dt_open" => %{"id" => "dt_open", "status" => "in_progress"},
        "dt_done" => %{"id" => "dt_done", "status" => "completed"}
      })
      |> Map.put(
        "development_attempts",
        Map.merge(old_and_live, bulk_done)
        |> Map.put(live["id"], Map.put(live, "task_ref", "dt_open"))
      )

    assert {:ok, _r, next} =
             DevelopmentAttempt.update(live["id"], {1, "needs_changes", "Bounded"}, s)

    # every OLDEST record belongs to an open plan and is still live, whole
    for n <- 1..3 do
      assert Map.has_key?(next["development_attempts"], "da_aaa_#{n}"), "da_aaa_#{n} was evicted"
      assert next["development_attempts"]["da_aaa_#{n}"]["criteria"] != nil
    end

    # every record of the CLOSED plan left, and none of them is in the directory
    for n <- 1..20 do
      refute Map.has_key?(next["development_attempts"], "da_zzz_#{n}")
      assert Map.has_key?(next["development_attempts_archive"], "da_zzz_#{n}")
    end
  end

  test "T14 · archiving is idempotent and the archive accumulates rather than replacing", c do
    f = fields(c)
    a = Authority.record_development_attempt(f)
    tasks = %{"dt_done" => %{"id" => "dt_done", "status" => "completed"}}

    prior = %{
      "da_prior" => %{"id" => "da_prior", "task_ref" => "dt_done", "status" => "accepted"}
    }

    {live, archive} =
      DevelopmentAttempt.archive_finished(
        %{
          "da_x" =>
            Map.merge(a, %{"id" => "da_x", "task_ref" => "dt_done", "status" => "accepted"})
        },
        prior,
        tasks
      )

    assert live == %{}
    assert Map.keys(archive) |> Enum.sort() == ["da_prior", "da_x"]

    # running it again over the same archive changes nothing
    assert {%{}, ^archive} = DevelopmentAttempt.archive_finished(%{}, archive, tasks)
  end

  test "T14 · a cancelled plan's attempts archive too, and the evidence survives the move", c do
    f = fields(c)
    a = Authority.record_development_attempt(f)

    s =
      Loci.initial()
      |> Map.put("development_tasks", %{
        "dt_cancelled" => %{"id" => "dt_cancelled", "status" => "cancelled"},
        "dt_open" => %{"id" => "dt_open", "status" => "in_progress"}
      })
      |> Map.put("development_attempts", %{
        "da_c" =>
          Map.merge(a, %{
            "id" => "da_c",
            "task_ref" => "dt_cancelled",
            "status" => "accepted",
            "history" => [%{"revision" => 1, "status" => "recorded", "note" => "why"}]
          }),
        a["id"] => Map.put(a, "task_ref", "dt_open")
      })

    assert {:ok, _r, next} = DevelopmentAttempt.update(a["id"], {1, "needs_changes", "B"}, s)
    refute Map.has_key?(next["development_attempts"], "da_c")
    moved = next["development_attempts_archive"]["da_c"]
    assert moved["status"] == "accepted"
    assert moved["history"] == [%{"revision" => 1, "status" => "recorded", "note" => "why"}]
  end

  test "T14 · an attempt whose plan is ABSENT stays live — the predicate did not widen", c do
    # Recorded rather than fixed. Such a record can never be acted on and can
    # never release its bytes, but archiving on a missing plan would mean an
    # empty `development_tasks` archived EVERYTHING, so the predicate is left
    # exactly as it was and the residual is pinned here instead of discovered.
    f = fields(c)
    a = Authority.record_development_attempt(f)

    s =
      Loci.initial()
      |> Map.put("development_tasks", %{
        "dt_open" => %{"id" => "dt_open", "status" => "in_progress"}
      })
      |> Map.put("development_attempts", %{
        "da_orphan" => Map.merge(a, %{"id" => "da_orphan", "task_ref" => "dt_vanished"}),
        a["id"] => Map.put(a, "task_ref", "dt_open")
      })

    assert {:ok, _r, next} = DevelopmentAttempt.update(a["id"], {1, "needs_changes", "B"}, s)
    assert Map.has_key?(next["development_attempts"], "da_orphan")
    refute Map.has_key?(next["development_attempts_archive"] || %{}, "da_orphan")
  end

  test "a directory already over its budget heals on the next write", c do
    f = fields(c)
    a = Authority.record_development_attempt(f)

    bulky =
      Map.new(1..24, fn n ->
        id = "da_bulk_#{n}"

        {id,
         a
         |> Map.put("id", id)
         |> Map.put("task_ref", "dt_done")
         |> Map.put("status", "accepted")
         |> Map.put(
           "criteria",
           String.duplicate("working material that history cannot act on. ", 140)
         )}
      end)

    s =
      Loci.initial()
      |> Map.put("development_tasks", %{
        "dt_done" => %{"id" => "dt_done", "status" => "completed"}
      })
      |> Map.put("development_attempts", Map.put(bulky, a["id"], a))

    refute match?({:ok, _}, Ampd.Frame.logical_size(s["development_attempts"], 128 * 1024))

    assert {:ok, _record, next} =
             DevelopmentAttempt.update(a["id"], {1, "needs_changes", "Bounded"}, s)

    assert match?({:ok, _}, Ampd.Frame.logical_size(next["development_attempts"], 128 * 1024))

    # T14: the finished plan's attempts LEAVE the directory rather than being
    # compacted inside it. They are still in the world, retired, in a collection
    # `@directory_bytes` does not count and `Ampd.Projection` does not publish.
    refute Map.has_key?(next["development_attempts"], "da_bulk_1")
    assert Map.has_key?(next["development_attempts_archive"], "da_bulk_1")
    refute Map.has_key?(next["development_attempts_archive"]["da_bulk_1"], "criteria")
    assert map_size(next["development_attempts_archive"]) == 24

    # The attempt whose own plan is still open keeps everything, and stays.
    assert next["development_attempts"][a["id"]]["criteria"] == a["criteria"]
  end

  # What a record keeps across a world open: everything but the bodies, which
  # move to the content store on open and read back through `member_content/1`
  # (proved by "store restart retains draft, result and notes").
  defp durable(a), do: Map.drop(a, ~w(shared_draft proposed_text))

  defp proposal(f, text, path \\ "sample.json") do
    f
    |> Map.put("proposed_text", text)
    |> put_in(["source", "path"], path)
    |> put_in(["source", "result_sha256"], hash(text))
    |> put_in(["source", "result_bytes"], byte_size(text))
    |> bind()
  end

  # Re-derive the basis from what it names, as the host does, after a fixture
  # changes the path, head or current text it was bound to.
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

  test "human text checks derive from retained bytes and survive store restart", c do
    f = fields(c) |> proposal("{\"ok\": true}\n")
    a = Authority.record_development_attempt(f)
    before = {Loci.development_tasks(), Loci.workers(), Ampd.Validation.all()}

    assert %{"allow" => true, "development_attempt" => next} =
             Control.command(c.human, :check_development_attempt_text, [a["id"], 1])

    assert next["revision"] == 2 and next["status"] == "recorded"
    assert next["text_check"]["outcome"] == "pass"
    assert next["text_check"]["result_sha256"] == hash(f["proposed_text"])
    assert Enum.all?(next["text_check"]["checks"], &(&1["outcome"] == "pass"))
    assert Map.take(next, DevelopmentAttempt.fields()) == f
    assert before == {Loci.development_tasks(), Loci.workers(), Ampd.Validation.all()}
    :ok = Supervisor.terminate_child(Ampd.Supervisor, Loci)
    {:ok, _} = Supervisor.restart_child(Ampd.Supervisor, Loci)
    assert durable(Loci.development_attempts()[a["id"]]) == durable(next)
  end

  test "issues retain bounded line findings and JSON failure", c do
    text = "<<<<<<< branch\n{broken} \r\n" <> String.duplicate("x \n", 25)
    a = Authority.record_development_attempt(fields(c) |> proposal(text))
    next = Authority.check_development_attempt_text(a["id"], 1)
    assert next["text_check"]["outcome"] == "fail"
    [conflicts, whitespace, json] = next["text_check"]["checks"]
    assert conflicts["lines"] == [1]
    assert whitespace["count"] == 26 and length(whitespace["lines"]) == 20
    assert json["outcome"] == "fail"
    assert next["proposed_text"] == text
  end

  test "syntax is explicitly not applicable for other file types", c do
    a = Authority.record_development_attempt(fields(c) |> proposal("{broken}\n", "code.js"))
    next = Authority.check_development_attempt_text(a["id"], 1)
    assert next["text_check"]["outcome"] == "pass"
    assert List.last(next["text_check"]["checks"])["outcome"] == "not_applicable"
  end

  test "old passing results cannot transfer to changed proposal bytes", c do
    f = fields(c) |> proposal("{}\n")
    a = Authority.record_development_attempt(f)
    checked = Authority.check_development_attempt_text(a["id"], 1)
    changed = f |> proposal("{broken}\n") |> Map.put("client_ref", "changed")
    b = Authority.record_development_attempt(changed)
    refute b["text_check"]
    assert b["source"]["result_sha256"] != checked["text_check"]["result_sha256"]
    assert Authority.check_development_attempt_text(b["id"], 1)["text_check"]["outcome"] == "fail"
    assert Loci.development_attempts()[a["id"]] == checked
  end

  test "text check retries are stable and cannot be supplied by agents or direct store calls",
       c do
    a = Authority.record_development_attempt(fields(c))
    assert {:refused, _} = Loci.check_development_attempt_text(a["id"], 1)

    assert %{"allow" => false} =
             Control.command(c.agent, :check_development_attempt_text, [a["id"], 1])

    assert {:refused, _} = Authority.check_development_attempt_text(a["id"], 99)
    next = Authority.check_development_attempt_text(a["id"], 1)
    assert Authority.check_development_attempt_text(a["id"], 1) == next
    assert Authority.check_development_attempt_text(a["id"], 2) == next

    noted =
      Authority.update_development_attempt(a["id"], 2, "needs_changes", "Still needs review")

    assert Authority.check_development_attempt_text(a["id"], 1) == noted
    assert {:refused, _} = Authority.check_development_attempt_text(a["id"], 2)
    assert noted["text_check"] == next["text_check"]
  end

  test "dismissed and full histories refuse new checks without changing records", c do
    a = Authority.record_development_attempt(fields(c))
    dismissed = Authority.update_development_attempt(a["id"], 1, "dismissed", "Stop")
    assert {:refused, _} = Authority.check_development_attempt_text(a["id"], 2)
    assert Loci.development_attempts()[a["id"]] == dismissed

    s =
      Loci.initial()
      |> put_in(
        ["development_attempts", a["id"]],
        Map.put(a, "history", List.duplicate(hd(a["history"]), 32))
      )

    assert {:refused, _} = DevelopmentAttempt.update(a["id"], {:check_text, 1}, s)
  end

  test "native review lookup checks revision world plan and repository without mutating", c do
    f = fields(c)
    a = Authority.record_development_attempt(f)
    repo = Ampd.Worktree.repo(a["repository_ref"])
    world = f["source"]["world"]
    before = Loci.development_attempts()
    assert DevelopmentAttempt.for_local_tests(a["id"], 1, repo["path"], world)["attempt"] == a
    refute DevelopmentAttempt.for_local_tests(a["id"], 2, repo["path"], world)["matched"]
    refute DevelopmentAttempt.for_local_tests(a["id"], 1, "/wrong", world)["matched"]

    refute DevelopmentAttempt.for_local_tests(a["id"], 1, repo["path"], ["wrong", 1, "wrong"])[
             "matched"
           ]

    assert Loci.development_attempts() == before
    Authority.update_development_task(a["task_ref"], 1, "blocked", "Changed plan")

    assert DevelopmentAttempt.for_local_tests(a["id"], 1, repo["path"], world)["matched"],
           "a plan update changes nothing the review is judged against"

    Authority.update_development_task(a["task_ref"], 2, "cancelled", "Stop")
    refute DevelopmentAttempt.for_local_tests(a["id"], 1, repo["path"], world)["matched"]
  end

  test "a planning note does not orphan a review: recording, tests, acceptance and completion hold across plan revisions",
       c do
    a = Authority.record_development_attempt(fields(c))
    world = a["source"]["world"]
    repo = Ampd.Worktree.repo(a["repository_ref"])

    # The note moves the plan to revision 2. The review stays this plan's review.
    noted = Authority.update_development_task(a["task_ref"], 1, "planned", "Progress note")
    assert noted["revision"] == 2
    assert DevelopmentAttempt.for_local_tests(a["id"], 1, repo["path"], world)["matched"]

    # A review shared before the note still records, against the revision it was shared at.
    b = Authority.record_development_attempt(Map.put(fields(c), "client_ref", "attempt-two"))
    assert b["task_revision"] == 1

    # A revision the plan has never had refuses.
    future = fields(c) |> Map.put("client_ref", "attempt-future") |> Map.put("task_revision", 9)
    future = put_in(future, ["source", "task_revision"], 9)

    assert {:refused, %{"code" => "attempt-task-stale"}} =
             Authority.record_development_attempt(future)

    refute match?({:refused, _}, Authority.begin_development_test(a["id"], test_start(a)))
    Authority.finish_development_test(a["id"], "run-fixture", world, test_outcome(a))
    checked = Authority.prepare_development_acceptance(a["id"], acceptance_fields(a))
    token = checked["acceptance_check"]["token"]

    accepted =
      Authority.accept_development_attempt(
        a["id"],
        checked["revision"],
        token,
        "Meets criteria",
        world
      )

    assert accepted["status"] == "accepted" and accepted["acceptance"]["task_revision"] == 1

    # The unresolved second review still blocks completion; dismissed, it does not.
    assert {:refused, %{"code" => "task-completion-not-ready"}} =
             Authority.update_development_task(a["task_ref"], 2, "completed", "Done")

    Authority.update_development_attempt(
      b["id"],
      1,
      "dismissed",
      "Superseded by the accepted one"
    )

    completed = Authority.update_development_task(a["task_ref"], 2, "completed", "Done")
    assert completed["status"] == "completed"
    assert completed["completion"]["accepted_attempt_refs"] == [a["id"]]
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

  test "test admission and outcome are durable host records independent of review notes", c do
    a = Authority.record_development_attempt(fields(c))
    before = {Loci.development_tasks(), Ampd.Validation.all(), Loci.workers()}
    start = test_start(a)
    admitted = Authority.begin_development_test(a["id"], start)
    assert admitted["test_runs"]["run-fixture"]["state"] == "started"
    assert admitted["revision"] == a["revision"]
    assert Authority.begin_development_test(a["id"], start) == admitted
    noted = Authority.update_development_attempt(a["id"], 1, "needs_changes", "Keep reviewing")
    assert noted["test_runs"] == admitted["test_runs"]

    finished =
      Authority.finish_development_test(a["id"], "run-fixture", start["world"], test_outcome(a))

    assert finished["test_runs"]["run-fixture"]["state"] == "completed"
    assert finished["status"] == "needs_changes" and finished["revision"] == 2
    assert before == {Loci.development_tasks(), Ampd.Validation.all(), Loci.workers()}

    assert Authority.finish_development_test(
             a["id"],
             "run-fixture",
             start["world"],
             test_outcome(a)
           ) == finished

    :ok = Supervisor.terminate_child(Ampd.Supervisor, Loci)
    {:ok, _} = Supervisor.restart_child(Ampd.Supervisor, Loci)
    assert durable(Loci.development_attempts()[a["id"]]) == durable(finished)
    refute Map.has_key?(Projection.agent(c.bot["actor"]), "development_attempts")
  end

  test "unknown starts stale inputs and foreign results cannot acquire a verdict", c do
    a = Authority.record_development_attempt(fields(c))
    start = test_start(a)
    assert {:refused, _} = Loci.begin_development_test(a["id"], start)

    assert {:refused, _} =
             Authority.finish_development_test(
               a["id"],
               "missing",
               start["world"],
               test_outcome(a)
             )

    for bad <- [
          Map.put(start, "revision", 99),
          Map.put(start, "path", "/wrong"),
          Map.put(start, "world", ["other", 1, "other"]),
          Map.put(start, "verdict", "pass")
        ] do
      assert {:refused, _} = Authority.begin_development_test(a["id"], bad)
    end

    Authority.begin_development_test(a["id"], start)

    for bad <- [
          Map.put(test_outcome(a), "result_sha256", hash("foreign")),
          Map.put(test_outcome(a), "source_basis_id", hash("foreign")),
          Map.put(test_outcome(a), "snapshot_sha256", nil),
          Map.put(test_outcome(a), "test_count", 0),
          Map.put(test_outcome(a), "grant", true)
        ] do
      assert {:refused, _} =
               Authority.finish_development_test(a["id"], "run-fixture", start["world"], bad)
    end

    assert Loci.development_attempts()[a["id"]]["test_runs"]["run-fixture"]["state"] == "started"
  end

  test "terminal outcomes cannot be rewritten and cancellation has no passing verdict", c do
    a = Authority.record_development_attempt(fields(c))
    start = test_start(a)
    Authority.begin_development_test(a["id"], start)

    cancelled =
      test_outcome(a)
      |> Map.put("state", "failed")
      |> Map.put("verdict", nil)
      |> Map.put("reason", "cancelled")

    final = Authority.finish_development_test(a["id"], "run-fixture", start["world"], cancelled)
    assert final["test_runs"]["run-fixture"]["outcome"]["verdict"] == nil

    assert {:refused, _} =
             Authority.finish_development_test(
               a["id"],
               "run-fixture",
               start["world"],
               test_outcome(a)
             )

    assert {:refused, _} =
             Authority.finish_development_test(
               a["id"],
               "run-fixture",
               ["other", 1, "other"],
               cancelled
             )
  end

  test "test admission reserves result space and enforces per-review run limits", c do
    a = Authority.record_development_attempt(fields(c))

    for n <- 1..8,
        do: assert(is_map(Authority.begin_development_test(a["id"], test_start(a, "run-#{n}"))))

    assert {:refused, _} = Authority.begin_development_test(a["id"], test_start(a, "run-9"))
    before = Loci.development_attempts()[a["id"]]

    s =
      Loci.initial()
      |> put_in(
        ["development_attempts", a["id"]],
        # Sized so the RESERVE is what refuses it: 8 started runs hold back
        # 8 x 4608 = 36 864 bytes, and 100 000 of criteria encodes well under
        # the 131 072 budget on its own but not once the reserve is counted.
        Map.put(before, "criteria", String.duplicate("x", 100_000))
      )

    assert {:refused, _} =
             DevelopmentAttempt.update(
               a["id"],
               {1, "recorded", "Would consume reserved output space"},
               s
             )

    for n <- 1..8 do
      assert is_map(
               Authority.finish_development_test(
                 a["id"],
                 "run-#{n}",
                 a["source"]["world"],
                 test_outcome(a)
               )
             )
    end
  end

  test "recovery closes only unfinished older-runtime tests and preserves notes", c do
    a = Authority.record_development_attempt(fields(c))
    world = a["source"]["world"]
    older = test_start(a) |> Map.put("world", List.replace_at(world, 2, "previous-runtime"))
    Authority.begin_development_test(a["id"], older)
    Authority.begin_development_test(a["id"], test_start(a, "run-active"))
    Authority.update_development_attempt(a["id"], 1, "needs_changes", "Retained note")
    final = Authority.recover_development_tests(a["id"], world)
    run = final["test_runs"]["run-fixture"]
    assert run["outcome"]["reason"] == "interrupted"
    assert run["outcome"]["verdict"] == nil and run["outcome"]["test_count"] == 0
    assert final["test_runs"]["run-active"]["state"] == "started"
    assert final["revision"] == 2 and List.last(final["history"])["note"] == "Retained note"
    assert Authority.recover_development_tests(a["id"], world) == final

    assert {:refused, _} =
             Authority.finish_development_test(a["id"], "run-fixture", world, test_outcome(a))

    :ok = Supervisor.terminate_child(Ampd.Supervisor, Loci)
    {:ok, _} = Supervisor.restart_child(Ampd.Supervisor, Loci)
    assert durable(Loci.development_attempts()[a["id"]]) == durable(final)
  end

  test "recovery preserves finished results and refuses a foreign world", c do
    a = Authority.record_development_attempt(fields(c))
    start = test_start(a)
    Authority.begin_development_test(a["id"], start)

    final =
      Authority.finish_development_test(a["id"], "run-fixture", start["world"], test_outcome(a))

    assert Authority.recover_development_tests(
             a["id"],
             List.replace_at(start["world"], 2, "new-runtime")
           ) == final

    assert {:refused, _} = Authority.recover_development_tests(a["id"], ["foreign", 1, "epoch"])
    assert Loci.development_attempts()[a["id"]] == final
  end

  test "legacy starts without runtime identity remain unconfirmed", c do
    a = Authority.record_development_attempt(fields(c))
    admitted = Authority.begin_development_test(a["id"], test_start(a))
    legacy = update_in(admitted, ["test_runs", "run-fixture"], &Map.delete(&1, "runtime_epoch"))
    state = %{"development_attempts" => %{a["id"] => legacy}}

    assert {:ok, ^legacy, ^state} =
             DevelopmentAttempt.update(a["id"], {:recover_tests, a["source"]["world"]}, state)
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

  test "acceptance requires a native check and a human decision and retains exact evidence", c do
    a = Authority.record_development_attempt(fields(c))
    world = a["source"]["world"]
    assert {:refused, _} = Authority.prepare_development_acceptance(a["id"], acceptance_fields(a))
    Authority.begin_development_test(a["id"], test_start(a))
    Authority.finish_development_test(a["id"], "run-fixture", world, test_outcome(a))

    assert {:refused, _} =
             Authority.accept_development_attempt(a["id"], 1, "invented", "Meets criteria", world)

    checked = Authority.prepare_development_acceptance(a["id"], acceptance_fields(a))
    token = checked["acceptance_check"]["token"]

    agent_reply =
      Control.command(c.agent, :accept_development_attempt, [a["id"], 1, token, "Meets criteria"])

    refute agent_reply["allow"] == true

    reply =
      Control.command(c.human, :accept_development_attempt, [a["id"], 1, token, "Meets criteria"])

    assert reply["allow"] == true
    accepted = Loci.development_attempts()[a["id"]]
    assert accepted["status"] == "accepted" and accepted["revision"] == 2
    assert accepted["acceptance"]["snapshot_sha256"] == hash("snapshot")
    assert accepted["acceptance"]["result_sha256"] == a["source"]["result_sha256"]
    assert accepted["acceptance"]["run_id"] == "run-fixture"

    assert Authority.accept_development_attempt(a["id"], 1, token, "Meets criteria", world) ==
             accepted

    assert {:refused, _} = Authority.update_development_attempt(a["id"], 2, "recorded", "Rewrite")

    assert {:refused, _} =
             Authority.begin_development_test(a["id"], test_start(accepted, "later"))

    :ok = Supervisor.terminate_child(Ampd.Supervisor, Loci)
    {:ok, _} = Supervisor.restart_child(Ampd.Supervisor, Loci)
    assert durable(Loci.development_attempts()[a["id"]]) == durable(accepted)
  end

  test "acceptance refuses foreign content and invalidates checks when the plan changes", c do
    a = Authority.record_development_attempt(fields(c))
    world = a["source"]["world"]
    Authority.begin_development_test(a["id"], test_start(a))
    Authority.finish_development_test(a["id"], "run-fixture", world, test_outcome(a))

    for {field, value} <- [
          {"head", hash("other")},
          {"snapshot_sha256", hash("other")},
          {"result_sha256", hash("other")},
          {"path", "/wrong"},
          {"revision", 99}
        ] do
      assert {:refused, _} =
               Authority.prepare_development_acceptance(
                 a["id"],
                 Map.put(acceptance_fields(a), field, value)
               )
    end

    checked = Authority.prepare_development_acceptance(a["id"], acceptance_fields(a))
    token = checked["acceptance_check"]["token"]

    assert {:refused, _} =
             Authority.accept_development_attempt(
               a["id"],
               1,
               token,
               "Meets criteria",
               List.replace_at(world, 2, "new-runtime")
             )

    expired = put_in(checked, ["acceptance_check", "expires_at"], 0)

    assert {:refused, _} =
             DevelopmentAttempt.update(a["id"], {:accept, 1, token, "Meets criteria", world}, %{
               "development_attempts" => %{a["id"] => expired}
             })

    Authority.update_development_task(a["task_ref"], 1, "blocked", "New requirements")

    # Criteria are immutable: a plan note or status change is not a change to
    # what was tested, so the prepared acceptance still stands.
    accepted = Authority.accept_development_attempt(a["id"], 1, token, "Meets criteria", world)
    assert accepted["status"] == "accepted"
  end

  test "new unfinished or failed tests prevent acceptance of an older passing run", c do
    a = Authority.record_development_attempt(fields(c))
    world = a["source"]["world"]
    Authority.begin_development_test(a["id"], test_start(a))
    Authority.finish_development_test(a["id"], "run-fixture", world, test_outcome(a))
    Authority.begin_development_test(a["id"], test_start(a, "run-newer"))
    assert {:refused, _} = Authority.prepare_development_acceptance(a["id"], acceptance_fields(a))

    Authority.finish_development_test(
      a["id"],
      "run-newer",
      world,
      Map.put(test_outcome(a), "verdict", "fail")
    )

    assert {:refused, _} = Authority.prepare_development_acceptance(a["id"], acceptance_fields(a))

    assert {:refused, _} =
             Authority.prepare_development_acceptance(
               a["id"],
               Map.put(acceptance_fields(a), "run_id", "run-newer")
             )
  end

  test "Elixir outcomes require the admitted profile and pinned toolchain", c do
    a = Authority.record_development_attempt(fields(c))
    start = Map.put(test_start(a), "profile", "super-elixir-review@1")

    assert {:refused, _} =
             Authority.begin_development_test(
               a["id"],
               Map.put(start, "profile", "arbitrary-command")
             )

    admitted = Authority.begin_development_test(a["id"], start)
    assert admitted["test_runs"]["run-fixture"]["profile"] == "super-elixir-review@1"
    assert Authority.begin_development_test(a["id"], start) == admitted
    assert {:refused, _} = Authority.begin_development_test(a["id"], test_start(a))
    outcome = Map.put(test_outcome(a), "profile", "super-elixir-review@1")

    for bad <- [test_outcome(a), outcome, Map.put(outcome, "toolchain_sha256", "invalid")] do
      assert {:refused, _} =
               Authority.finish_development_test(a["id"], "run-fixture", start["world"], bad)
    end

    outcome = Map.put(outcome, "toolchain_sha256", hash("copied tools"))
    finished = Authority.finish_development_test(a["id"], "run-fixture", start["world"], outcome)
    assert finished["test_runs"]["run-fixture"]["outcome"] == outcome
    :ok = Supervisor.terminate_child(Ampd.Supervisor, Loci)
    {:ok, _} = Supervisor.restart_child(Ampd.Supervisor, Loci)
    assert durable(Loci.development_attempts()[a["id"]]) == durable(finished)
  end

  test "Rust outcomes require the admitted profile and pinned toolchain", c do
    a = Authority.record_development_attempt(fields(c))
    start = Map.put(test_start(a), "profile", "super-rust-review@1")

    assert {:refused, _} =
             Authority.begin_development_test(
               a["id"],
               Map.put(start, "profile", "arbitrary-command")
             )

    admitted = Authority.begin_development_test(a["id"], start)
    assert admitted["test_runs"]["run-fixture"]["profile"] == "super-rust-review@1"
    assert Authority.begin_development_test(a["id"], start) == admitted
    assert {:refused, _} = Authority.begin_development_test(a["id"], test_start(a))
    outcome = Map.put(test_outcome(a), "profile", "super-rust-review@1")

    for bad <- [test_outcome(a), outcome, Map.put(outcome, "toolchain_sha256", "invalid")] do
      assert {:refused, _} =
               Authority.finish_development_test(a["id"], "run-fixture", start["world"], bad)
    end

    outcome = Map.put(outcome, "toolchain_sha256", hash("copied tools"))
    finished = Authority.finish_development_test(a["id"], "run-fixture", start["world"], outcome)
    assert finished["test_runs"]["run-fixture"]["outcome"] == outcome
    :ok = Supervisor.terminate_child(Ampd.Supervisor, Loci)
    {:ok, _} = Supervisor.restart_child(Ampd.Supervisor, Loci)
    assert durable(Loci.development_attempts()[a["id"]]) == durable(finished)
  end

  test "required plan checks are immutable, validated and cannot be omitted at acceptance", c do
    js = "super-javascript-behavior@1"
    rust = "super-rust-review@1"

    for profiles <- [[], [js, js], ["unknown"]] do
      assert {:refused, _} =
               Authority.create_development_task(
                 Map.put(c.fields, "required_checks", %{"profiles" => profiles})
               )
    end

    c = %{c | fields: Map.put(c.fields, "required_checks", %{"profiles" => [js, rust]})}
    a = Authority.record_development_attempt(fields(c))
    task = Loci.development_tasks()[a["task_ref"]]
    assert task["required_checks"]["profiles"] == [js, rust]
    assert Authority.create_development_task(c.fields) == task

    assert {:refused, _} =
             Authority.create_development_task(Map.delete(c.fields, "required_checks"))

    world = a["source"]["world"]
    assert is_map(Authority.begin_development_test(a["id"], test_start(a)))

    assert is_map(
             Authority.finish_development_test(a["id"], "run-fixture", world, test_outcome(a))
           )

    assert {:refused, _} = Authority.prepare_development_acceptance(a["id"], acceptance_fields(a))

    for {id, verdict} <- [{"run-rust-1", "fail"}, {"run-rust-2", "pass"}] do
      assert is_map(
               Authority.begin_development_test(
                 a["id"],
                 Map.put(test_start(a, id), "profile", rust)
               )
             )

      outcome =
        Map.merge(test_outcome(a), %{
          "profile" => rust,
          "toolchain_sha256" => hash("tools"),
          "verdict" => verdict
        })

      assert is_map(Authority.finish_development_test(a["id"], id, world, outcome))

      result =
        Authority.prepare_development_acceptance(
          a["id"],
          Map.put(acceptance_fields(a), "run_id", id)
        )

      if verdict == "fail",
        do: assert(match?({:refused, _}, result)),
        else: assert(is_map(result))
    end
  end

  test "acceptance requires latest passing coverage for each used profile and records all refs",
       c do
    a = Authority.record_development_attempt(fields(c))
    world = a["source"]["world"]

    finish = fn id, profile, verdict, snapshot ->
      Authority.begin_development_test(a["id"], Map.put(test_start(a, id), "profile", profile))

      o =
        test_outcome(a)
        |> Map.merge(%{
          "profile" => profile,
          "verdict" => verdict,
          "snapshot_sha256" => hash(snapshot),
          "toolchain_sha256" => hash("tools")
        })

      Authority.finish_development_test(a["id"], id, world, o)
    end

    js = "super-javascript-behavior@1"
    rust = "super-rust-review@1"
    finish.("run-1", js, "fail", "snapshot")
    finish.("run-2", rust, "pass", "snapshot")
    f = Map.put(acceptance_fields(a), "run_id", "run-2")
    assert {:refused, _} = Authority.prepare_development_acceptance(a["id"], f)
    finish.("run-3", js, "pass", "changed")
    f = f |> Map.put("run_id", "run-3") |> Map.put("snapshot_sha256", hash("changed"))
    assert {:refused, _} = Authority.prepare_development_acceptance(a["id"], f)
    finish.("run-4", rust, "pass", "changed")
    f = Map.put(f, "run_id", "run-4")
    prepared = Authority.prepare_development_acceptance(a["id"], f)
    token = prepared["acceptance_check"]["token"]

    accepted =
      Authority.accept_development_attempt(a["id"], 1, token, "Both profiles reviewed", world)

    assert accepted["acceptance"]["profile_run_refs"] == %{js => "run-3", rust => "run-4"}
    :ok = Supervisor.terminate_child(Ampd.Supervisor, Loci)
    {:ok, _} = Supervisor.restart_child(Ampd.Supervisor, Loci)
    assert Loci.development_attempts()[a["id"]]["acceptance"] == accepted["acceptance"]
  end

  test "new profile failure between native preflight and acceptance invalidates the decision",
       c do
    a = Authority.record_development_attempt(fields(c))
    world = a["source"]["world"]
    Authority.begin_development_test(a["id"], test_start(a))
    Authority.finish_development_test(a["id"], "run-fixture", world, test_outcome(a))
    prepared = Authority.prepare_development_acceptance(a["id"], acceptance_fields(a))

    Authority.begin_development_test(
      a["id"],
      Map.put(test_start(a, "run-rust"), "profile", "super-rust-review@1")
    )

    outcome =
      test_outcome(a)
      |> Map.merge(%{
        "profile" => "super-rust-review@1",
        "toolchain_sha256" => hash("tools"),
        "verdict" => "fail"
      })

    Authority.finish_development_test(a["id"], "run-rust", world, outcome)

    assert {:refused, _} =
             Authority.accept_development_attempt(
               a["id"],
               1,
               prepared["acceptance_check"]["token"],
               "Stale coverage",
               world
             )
  end

  defp set_request(c) do
    f = fields(c)

    files =
      Enum.map(["index.html", "style.css"], fn path ->
        source = Map.put(f["source"], "path", path)

        source =
          Map.put(
            source,
            "basis_id",
            hash(
              JSON.encode!([
                "selected-file-basis@1",
                source["head"],
                path,
                source["disk_sha256"],
                source["draft_sha256"]
              ])
            )
          )

        %{
          "source" => source,
          "shared_draft" => f["shared_draft"],
          "proposed_text" => f["proposed_text"]
        }
      end)

    ["combined-one", f["task_ref"], f["task_revision"], %{"files" => files}]
  end

  test "combined reviews persist one bounded set, exact text and stable retries", c do
    args = set_request(c)

    assert %{"allow" => true, "development_attempt" => a} =
             Control.command(c.human, :record_development_change_set, args)

    assert a["schema"] == "development-review-set@1" and length(a["files"]) == 2
    assert Enum.at(a["files"], 1)["shared_draft"] == "before\r\n"
    assert a["source"]["scope"] == "selected-file-set-only"
    assert map_size(Loci.development_attempts()) == 1

    assert %{"development_attempt" => ^a} =
             Control.command(c.human, :record_development_change_set, args)

    assert a["test_runs"] == nil and a["acceptance"] == nil
  end

  test "combined recording is human-only and rejects request collisions", c do
    args = set_request(c)
    assert %{"allow" => false} = Control.command(c.agent, :record_development_change_set, args)
    assert Loci.development_attempts() == %{}
    assert %{"allow" => true} = Control.command(c.human, :record_development_change_set, args)
    changed = List.update_at(args, 3, fn m -> Map.update!(m, "files", &Enum.reverse/1) end)
    assert %{"allow" => false} = Control.command(c.human, :record_development_change_set, changed)
    assert map_size(Loci.development_attempts()) == 1
  end

  test "combined records refuse duplicate paths, invalid digests, mixed context and incomplete sets",
       c do
    args = set_request(c)
    files = List.last(args)["files"]

    changes = [
      [hd(files)],
      List.duplicate(hd(files), 5),
      [hd(files), hd(files)],
      List.update_at(files, 1, &put_in(&1, ["source", "result_sha256"], hash("different"))),
      List.update_at(files, 1, &put_in(&1, ["source", "task_ref"], "dt_other")),
      List.update_at(files, 1, &put_in(&1, ["source", "repository_ref"], "other")),
      List.update_at(files, 1, &put_in(&1, ["source", "world"], ["other", 1, "epoch"])),
      List.update_at(files, 1, &Map.put(&1, "proposed_text", String.duplicate("é", 16001)))
    ]

    for bad <- changes do
      assert %{"allow" => false} =
               Control.command(
                 c.human,
                 :record_development_change_set,
                 List.replace_at(args, 3, %{"files" => bad})
               )

      assert Loci.development_attempts() == %{}
    end
  end

  test "combined notes retain immutable material and legacy checks cannot certify the set", c do
    args = set_request(c)

    assert %{"development_attempt" => a} =
             Control.command(c.human, :record_development_change_set, args)

    assert %{"allow" => false} =
             Control.command(c.human, :check_development_attempt_text, [a["id"], 1])

    assert %{"allow" => false} =
             Control.command(c.human, :accept_development_attempt, [
               a["id"],
               1,
               "fake",
               "Looks good"
             ])

    for operation <- [
          {:begin_test, %{}},
          {:prepare_acceptance, %{}},
          {:accept, 1, "fake", "note", []}
        ] do
      assert {:refused, _} =
               DevelopmentAttempt.update(a["id"], operation, %{
                 "development_attempts" => %{a["id"] => a}
               })
    end

    assert %{"allow" => true, "development_attempt" => updated} =
             Control.command(c.human, :update_development_attempt, [
               a["id"],
               1,
               "needs_changes",
               "Review CSS contrast"
             ])

    assert updated["files"] == a["files"] and updated["source"] == a["source"]
    assert updated["revision"] == 2 and length(updated["history"]) == 2

    assert %{"allow" => false} =
             Control.command(c.human, :complete_development_task, [a["task_ref"], 1, "Done"])
  end

  test "combined tests and acceptance bind the whole set rather than one member", c do
    assert %{"development_attempt" => a} =
             Control.command(c.human, :record_development_change_set, set_request(c))

    world = a["source"]["world"]
    repo = Ampd.Worktree.repo(a["repository_ref"])["path"]
    assert DevelopmentAttempt.for_local_tests(a["id"], 1, repo, world)["attempt"] == a
    assert is_map(Authority.begin_development_test(a["id"], test_start(a)))
    member_hash = hd(a["files"])["source"]["result_sha256"]

    assert {:refused, _} =
             Authority.finish_development_test(
               a["id"],
               "run-fixture",
               world,
               Map.put(test_outcome(a), "result_sha256", member_hash)
             )

    assert is_map(
             Authority.finish_development_test(a["id"], "run-fixture", world, test_outcome(a))
           )

    assert {:refused, _} =
             Authority.prepare_development_acceptance(
               a["id"],
               Map.put(acceptance_fields(a), "result_sha256", member_hash)
             )

    checked = Authority.prepare_development_acceptance(a["id"], acceptance_fields(a))
    token = checked["acceptance_check"]["token"]

    assert %{"allow" => false} =
             Control.command(c.agent, :accept_development_attempt, [
               a["id"],
               1,
               token,
               "Whole set passes"
             ])

    assert %{"allow" => true, "development_attempt" => accepted} =
             Control.command(c.human, :accept_development_attempt, [
               a["id"],
               1,
               token,
               "Whole set passes"
             ])

    assert accepted["files"] == a["files"]
    assert accepted["acceptance"]["result_sha256"] == a["source"]["result_sha256"]
    refute accepted["acceptance"]["result_sha256"] == member_hash
  end

  test "combined deletion retains explicit absence and rejects empty-file substitutions", c do
    [client, task, revision, %{"files" => [a, b]}] = set_request(c)

    b = %{
      b
      | "proposed_text" => nil,
        "source" =>
          Map.merge(b["source"], %{
            "schema" => "selected-file-deletion-basis@1",
            "result_sha256" => hash(JSON.encode!(["deleted-file@1", b["source"]["path"]])),
            "result_bytes" => 0
          })
    }

    args = [client, task, revision, %{"files" => [a, b]}]

    assert %{"allow" => true, "development_attempt" => saved} =
             Control.command(c.human, :record_development_change_set, args)

    assert Enum.at(saved["files"], 1) == b

    assert %{"development_attempt" => ^saved} =
             Control.command(c.human, :record_development_change_set, args)

    for bad <- [
          Map.put(b, "proposed_text", ""),
          put_in(b, ["source", "schema"], "selected-file-basis@1"),
          put_in(b, ["source", "disk_sha256"], nil),
          put_in(b, ["source", "result_sha256"], hash(""))
        ] do
      assert %{"allow" => false} =
               Control.command(c.human, :record_development_change_set, [
                 "invalid-deletion",
                 task,
                 revision,
                 %{"files" => [a, bad]}
               ])
    end
  end

  # ── T16: the plan directory got an exit too, and it changes what "the plan directory" IS ──────
  #
  # T14's predicate is PLAN COMPLETION, read out of `s["development_tasks"]`. After T16 a finished
  # plan is not in that map any more — it is in `development_tasks_archive` — and `finished?(nil)`
  # is false. Handed only the live half, the attempt side would stop archiving the attempts of
  # every plan already closed, which is the exact opposite of what closing a plan does.

  test "T16 · attempts of a plan that is ARCHIVED still archive — the predicate reads the whole directory",
       c do
    f = fields(c)
    a = Authority.record_development_attempt(f)

    s =
      Loci.initial()
      # the closed plan is ONLY in the archive, which is where T16 puts it
      |> Map.put("development_tasks", %{
        "dt_open" => %{"id" => "dt_open", "status" => "in_progress"}
      })
      |> Map.put("development_tasks_archive", %{
        "dt_done" => %{"id" => "dt_done", "status" => "completed"}
      })
      |> Map.put("development_attempts", %{
        "da_done" =>
          Map.merge(a, %{"id" => "da_done", "task_ref" => "dt_done", "status" => "accepted"}),
        a["id"] => Map.put(a, "task_ref", "dt_open")
      })

    assert {:ok, _r, next} = DevelopmentAttempt.update(a["id"], {1, "needs_changes", "B"}, s)

    refute Map.has_key?(next["development_attempts"], "da_done"),
           "an attempt whose plan is archived was stranded in the live directory"

    assert Map.has_key?(next["development_attempts_archive"], "da_done")
    assert Map.has_key?(next["development_attempts"], a["id"]), "the open plan's attempt stays"
  end

  test "T16 · cancelling a plan archives the PLAN and its attempts in one write", c do
    f = fields(c)
    a = Authority.record_development_attempt(f)

    task = %{
      "id" => "dt_x",
      "status" => "planned",
      "revision" => 1,
      "history" => [%{"revision" => 1, "status" => "planned", "note" => "opened"}]
    }

    s =
      Loci.initial()
      |> Map.put("development_tasks", %{"dt_x" => task})
      |> Map.put("development_attempts", %{
        "da_x" => Map.merge(a, %{"id" => "da_x", "task_ref" => "dt_x", "status" => "dismissed"})
      })

    assert {:ok, _t, next} =
             Ampd.DevelopmentTask.update("dt_x", {1, "cancelled", "Changed priorities"}, s)

    refute Map.has_key?(next["development_tasks"], "dt_x"), "the finished plan held the bound"
    assert next["development_tasks_archive"]["dt_x"]["status"] == "cancelled"
    refute Map.has_key?(next["development_attempts"], "da_x")
    assert Map.has_key?(next["development_attempts_archive"], "da_x")
  end

  # ── T17: the frame carries the card, not the record ─────────────────────────
  #
  # T14 took finished attempts out of the DIRECTORY's bound and left them in
  # every reader's view, by merging the archive back in `Loci`. That is right —
  # a completed plan's card must still list the reviews that closed it — and it
  # is why 122,551 bytes of archived attempts travelled on every frame in the
  # live world. The card is what travels now; the record is a command away.

  defp archived_attempt(c) do
    f = fields(c)
    a = Authority.record_development_attempt(f)
    Authority.update_development_attempt(a["id"], 1, "dismissed", "Superseded by a later review")
    Authority.update_development_task(f["task_ref"], 1, "cancelled", "Changed priorities")
    {f, a}
  end

  test "T17 · an archived attempt travels as a card that names what it left behind", c do
    {_f, a} = archived_attempt(c)

    card = Projection.operator()["development_attempts"][a["id"]]
    assert card, "archiving must not take the attempt out of the frame — T14 exists to keep it"

    # Identity, outcome and the source the card's own summary line reads.
    assert card["status"] == "dismissed"
    assert card["task_ref"] == a["task_ref"]
    assert card["source"]["path"] == "index.html"

    refute Map.has_key?(card, "history")

    assert card["archived"]["schema"] == "archived-record-card@1"
    assert card["archived"]["read_with"] == "read_development_attempt"
    assert "history" in card["archived"]["omitted"]

    # `text_check` is in the omit list and this record has none, so it must
    # NOT be claimed as withheld: a door offered for nothing is worse than no
    # door.
    refute "text_check" in card["archived"]["omitted"]

    # And `test_runs` is not in the omit list at all — see the note on
    # `@archived_attempt_omits`. `reviewTestCoverage/2` reads a profile with
    # no run as `missing`, so an archived attempt without its runs would tell
    # a person the checks its plan completed on were never run.
    refute "test_runs" in Projection.archived_attempt_omits()
  end

  test "T17 · a LIVE attempt keeps its history, and carries no card marker", c do
    f = fields(c)
    a = Authority.record_development_attempt(f)

    live = Projection.operator()["development_attempts"][a["id"]]
    assert is_list(live["history"])
    refute Map.has_key?(live, "archived")
  end

  test "T17 · the door returns exactly what an archived attempt's card left behind", c do
    {_f, a} = archived_attempt(c)
    card = Projection.operator()["development_attempts"][a["id"]]

    assert %{"allow" => true, "development_attempt" => full} =
             Control.command(c.human, :read_development_attempt, [a["id"]])

    for key <- card["archived"]["omitted"] do
      assert Map.has_key?(full, key), "the door did not return #{key}, which the card promised"
    end

    assert List.last(full["history"])["note"] == "Superseded by a later review"
    assert full == Loci.development_attempts()[a["id"]]
  end

  test "T17 · a ref naming no attempt is refused by name", c do
    assert %{"allow" => false, "refusal" => %{"code" => "record-unknown"}} =
             Control.command(c.human, :read_development_attempt, ["da_9999"])
  end

  test "T17 · the attempt door is human control only", c do
    assert %{"allow" => false} = Control.command(c.agent, :read_development_attempt, ["da_0001"])
  end

  # **The card goes through `attempt_views/1`, not around it.** The two bounds
  # are independent: carding an archived record removes its history, and
  # `member_view/1` removes a staged member's bodies. A card that skipped the
  # view would put file bodies back on the frame while removing history from
  # it, which is a net loss dressed as a saving.
  test "T17 · an archived attempt's card is still a member view — no body rides back on", c do
    {_f, a} = archived_attempt(c)
    card = Projection.operator()["development_attempts"][a["id"]]

    assert card["content"], "the member view did not run over the card"
    assert card["archived"], "the card marker did not survive the member view"
  end

  test "T17 · the card weighs a fraction of the record" do
    record = %{
      "id" => "da_x",
      "status" => "accepted",
      "task_ref" => "dt_x",
      "acceptance" => %{"note" => String.duplicate("a", 900)},
      "text_check" => %{"detail" => String.duplicate("t", 1_500)},
      "test_runs" => %{"p" => %{"detail" => String.duplicate("r", 500)}},
      "history" =>
        for(
          _ <- 1..12,
          do: %{
            "at" => "2026-09-20T00:00:00Z",
            "status" => "recorded",
            "note" => String.duplicate("n", 150)
          }
        )
    }

    cards =
      Projection.archived_cards(
        %{"da_x" => record},
        Projection.archived_attempt_omits(),
        "read_development_attempt"
      )

    {:ok, full_bytes} = Ampd.Frame.logical_size(record)
    {:ok, card_bytes} = Ampd.Frame.logical_size(cards["da_x"])

    assert full_bytes > 5_000
    assert card_bytes < div(full_bytes, 2)

    # The acceptance is kept on purpose: it is why a finished plan is worth
    # showing at all. A card that dropped it would save bytes by removing the
    # point.
    assert cards["da_x"]["acceptance"] == record["acceptance"]
  end
end
