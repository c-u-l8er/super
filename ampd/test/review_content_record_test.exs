defmodule Ampd.ReviewContentRecordTest do
  @moduledoc """
  Recording a change set that names its files by digest, end to end: what is
  accepted, what is refused and by which name, what the projection carries, and
  what happens when the content behind a record goes away.
  """
  use ExUnit.Case, async: false
  alias Ampd.{Authority, Control, Frame, Loci, Projection, ReviewContent}

  setup do
    Ampd.reset()
    File.rm_rf(ReviewContent.dir())
    on_exit(fn -> File.rm_rf(ReviewContent.dir()) end)

    {human, agent} = Ampd.attach_pair("review-content")
    %{"workspace" => ws} = Control.command(human, :open_workspace, ["Super"])
    %{"goal" => goal} = Control.command(human, :open_goal, [ws["id"], "Review its own files"])

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

    repo = Path.join(System.tmp_dir!(), "super-rc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "--quiet", repo])
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, registered} = Authority.register_repository(repo)

    %{"lane" => lane} =
      Control.command(human, :open_lane, [goal["id"], bot["actor"], registered["ref"], "HEAD"])

    task =
      Authority.create_development_task(%{
        "client_ref" => "plan-one",
        "lane_ref" => lane["id"],
        "title" => "Publish content before naming it",
        "criteria" => "A change set names its files by digest."
      })

    %{human: human, agent: agent, bot: bot, task: task, repo: repo}
  end

  defp hash(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
  defp head, do: String.duplicate("a", 40)

  defp publish!(text) do
    d = hash(text)
    chunk = ReviewContent.chunk_bytes()
    parts = max(div(byte_size(text) - 1, chunk) + 1, 1)

    for i <- 0..(parts - 1) do
      slice = binary_part(text, i * chunk, min(chunk, byte_size(text) - i * chunk))
      {:ok, _} = ReviewContent.put(d, i * chunk, slice, i == parts - 1)
    end

    d
  end

  defp source(task, path, draft, proposed) do
    %{
      "schema" => "selected-file-basis@1",
      "scope" => "selected-file-only",
      "basis_id" =>
        hash(JSON.encode!(["selected-file-basis@1", head(), path, hash(draft), hash(draft)])),
      "head" => head(),
      "path" => path,
      "disk_sha256" => hash(draft),
      "draft_sha256" => hash(draft),
      "draft_bytes" => byte_size(draft),
      "unsaved" => false,
      "result_sha256" => hash(proposed),
      "result_bytes" => byte_size(proposed),
      "task_ref" => task["id"],
      "task_revision" => task["revision"],
      "repository_ref" => task["repository_ref"],
      "world" =>
        Enum.map(~w(world_incarnation world_generation projection_epoch), &Projection.continuity()[&1])
    }
  end

  defp staged_member(task, path, draft, proposed) do
    publish!(draft)
    publish!(proposed)
    %{"source" => source(task, path, draft, proposed)}
  end

  defp record(c, files, ref \\ "set-one") do
    Control.command(c.human, :record_development_change_set, [
      ref,
      c.task["id"],
      c.task["revision"],
      %{"files" => files}
    ])
  end

  # -------------------------------------------------- the thing it exists for

  test "a change set carries files far larger than a frame, and its request does not", c do
    big = File.read!(Path.expand(Path.join([__DIR__, "..", "..", "cockpit/ui/cockpit.js"])))
    other = File.read!(Path.expand(Path.join([__DIR__, "..", "..", "ampd/lib/ampd/projection.ex"])))

    files = [
      staged_member(c.task, "cockpit/ui/cockpit.js", big, big <> "\n// proposed\n"),
      staged_member(c.task, "ampd/lib/ampd/projection.ex", other, other <> "\n# proposed\n")
    ]

    assert byte_size(big) > 24_000, "this is the file the old caps excluded"
    request = JSON.encode!(%{"files" => files})

    assert byte_size(request) < 8_000,
           "a member is a path and its digests; the request must not grow with the files"

    assert %{"allow" => true, "development_attempt" => a} = record(c, files)
    assert a["schema"] == "development-review-set@1" and a["status"] == "recorded"
    assert length(a["files"]) == 2
    refute Enum.any?(a["files"], &Map.has_key?(&1, "shared_draft"))
  end

  test "the projection stays inside a frame at the supported attempt limit", c do
    files = [
      staged_member(c.task, "a.js", String.duplicate("x", 100_000), String.duplicate("y", 100_000)),
      staged_member(c.task, "b.js", String.duplicate("p", 100_000), String.duplicate("q", 100_000))
    ]

    assert %{"allow" => true} = record(c, files)
    published = Projection.operator()["development_attempts"]
    [one] = Map.values(published)

    # `attempt-limit` permits fifty. Fifty of THIS is what the world must stay
    # able to publish, and the old shape could not manage two.
    fifty = Map.new(1..50, &{"da_#{&1}", one})
    encoded = byte_size(JSON.encode!(%{"development_attempts" => fifty}))

    assert encoded < Frame.max_bytes(), """
    Fifty recorded change sets must still fit one frame; this encodes to #{encoded}
    of #{Frame.max_bytes()} bytes.
    """
  end

  test "THE REACHABLE BOUND is the store's 64 KiB guard, not the frame", c do
    # An earlier version of this work claimed a world could be made unviewable by
    # recording two maximal change sets. It cannot: `persist/2` caps the whole
    # persisted collection at 64 KiB encoded and refuses `attempt-directory-full`,
    # preserving what is already there. That guard is on shipped main. This is
    # what actually happens, through the real record path.
    # 6 KB a side, so a record is about 26 KB and two fit the 64 KiB budget
    # while the third does not. (At 20 KB a side the FIRST record is already
    # refused — one inline change set of two 20 KB files does not fit a world.)
    body = String.duplicate("i", 6_000)

    inline = fn path ->
      %{
        "source" => source(c.task, path, body, body),
        "shared_draft" => body,
        "proposed_text" => body
      }
    end

    outcome =
      Enum.reduce_while(1..10, :never_refused, fn n, _ ->
        case record(c, [inline.("a#{n}.js"), inline.("b#{n}.js")], "inline-#{n}") do
          %{"allow" => true} -> {:cont, :never_refused}
          %{"allow" => false, "refusal" => r} -> {:halt, r}
        end
      end)

    assert outcome != :never_refused, "the collection must be bounded"
    assert map_size(Loci.development_attempts()) < 10, "it refused before the tenth"
    assert outcome["code"] == "attempt-directory-full"
    assert outcome["public_message"] =~ "Existing records are preserved"

    # And what was already recorded is intact — the guard refuses, it does not
    # discard.
    assert map_size(Loci.development_attempts()) > 0
    assert Enum.all?(Loci.development_attempts(), fn {_, a} -> a["status"] == "recorded" end)
  end

  test "staging multiplies how many reviews one world can hold", c do
    # The 64 KiB budget is spent on BODIES when members are inline. With the
    # bodies published separately a record is its metadata, so the same budget
    # holds many more reviews. This is the benefit staging earns beyond making
    # a large submission possible at all.
    big = String.duplicate("s", 20_000)

    assert %{"allow" => true, "development_attempt" => a} =
             record(c, [
               staged_member(c.task, "a.js", big, big <> "x"),
               staged_member(c.task, "b.js", big, big <> "y")
             ])

    staged_bytes = byte_size(JSON.encode!(Loci.development_attempts()[a["id"]]))
    assert staged_bytes < 4_000, "a staged record is metadata: #{staged_bytes} bytes"

    assert div(64 * 1024, staged_bytes) >= 16, """
    At #{staged_bytes} bytes a record, the 64 KiB collection budget holds
    #{div(64 * 1024, staged_bytes)} reviews of two 20 KB files each. Inline, the
    same two files are 80 KB and one such record does not fit at all.
    """
  end

  test "an agent is never given review material, staged or otherwise", c do
    assert %{"allow" => true} = record(c, [
             staged_member(c.task, "a.js", "one", "two"),
             staged_member(c.task, "b.js", "three", "four")
           ])

    refute Map.has_key?(Projection.agent(c.bot["actor"]), "development_attempts")

    # And the command itself is not on the agent's channel.
    assert %{"allow" => false} =
             Control.command(c.agent, :record_development_change_set, [
               "from-an-agent",
               c.task["id"],
               c.task["revision"],
               %{"files" => []}
             ])
  end

  # ----------------------------------------------- four refusals, four names

  test "too few or too many files refuses by COUNT, naming the bounds", c do
    one = [staged_member(c.task, "a.js", "one", "two")]
    assert %{"allow" => false, "refusal" => r} = record(c, one)
    assert r["code"] == "review-file-count"

    many =
      for i <- 1..(Ampd.DevelopmentAttempt.max_members() + 1),
          do: staged_member(c.task, "f#{i}.js", "d#{i}", "p#{i}")

    assert %{"allow" => false, "refusal" => r2} = record(c, many, "set-many")
    assert r2["code"] == "review-file-count"
  end

  test "content that was never published refuses as UNAVAILABLE, naming the file and side", c do
    good = staged_member(c.task, "a.js", "one", "two")
    ghost = %{"source" => source(c.task, "b.js", "never", "published")}

    assert %{"allow" => false, "refusal" => r} = record(c, [good, ghost])
    assert r["code"] == "review-content-unavailable"
    assert r["operator_detail"]["path"] == "b.js"
    assert r["operator_detail"]["side"] == "current"
    assert r["operator_detail"]["state"] == "missing"
  end

  test "a member whose reported size disagrees with its content refuses as INVALID", c do
    m = staged_member(c.task, "a.js", "one", "two")
    lying = put_in(m["source"]["draft_bytes"], 999)

    assert %{"allow" => false, "refusal" => r} =
             record(c, [lying, staged_member(c.task, "b.js", "three", "four")])

    assert r["code"] == "review-content-invalid"
    assert r["operator_detail"]["path"] == "a.js"
  end

  test "a refusal never carries the file's contents back to the caller", c do
    secret = "a token nobody should see echoed back"
    m = staged_member(c.task, "a.js", secret, "two")
    lying = put_in(m["source"]["draft_bytes"], 1)

    assert %{"allow" => false, "refusal" => r} =
             record(c, [lying, staged_member(c.task, "b.js", "three", "four")])

    refute JSON.encode!(r) =~ "nobody should see"
  end

  # ------------------------------------------------------- stale source

  test "a basis that does not bind its own content is refused", c do
    m = staged_member(c.task, "a.js", "one", "two")
    forged = put_in(m["source"]["basis_id"], hash("a basis for something else"))

    assert %{"allow" => false, "refusal" => r} =
             record(c, [forged, staged_member(c.task, "b.js", "three", "four")])

    assert r["code"] == "review-content-invalid"
  end

  test "members from different source commits are refused as a mismatched set", c do
    a = staged_member(c.task, "a.js", "one", "two")
    b = staged_member(c.task, "b.js", "three", "four")
    moved = put_in(b["source"]["head"], String.duplicate("b", 40))
    moved = put_in(moved["source"]["basis_id"],
             hash(JSON.encode!(["selected-file-basis@1", String.duplicate("b", 40), "b.js",
                                hash("three"), hash("three")])))

    assert %{"allow" => false, "refusal" => r} = record(c, [a, moved])
    assert r["code"] == "attempt-source-mismatch"
  end

  test "a set recorded against a superseded plan revision is refused", c do
    files = [staged_member(c.task, "a.js", "one", "two"), staged_member(c.task, "b.js", "x", "y")]

    Authority.update_development_task(c.task["id"], c.task["revision"], "blocked", "waiting")

    assert %{"allow" => false, "refusal" => r} = record(c, files)
    assert r["code"] == "attempt-task-stale"
  end

  # --------------------------------------------- all or nothing, and after

  test "one bad member records NOTHING — a set is all of its files or none", c do
    good = staged_member(c.task, "a.js", "one", "two")
    ghost = %{"source" => source(c.task, "b.js", "never", "published")}

    assert %{"allow" => false} = record(c, [good, ghost])
    assert Loci.development_attempts() == %{}, "no partial set is left behind"

    # And the same request, once the missing half is published, records whole.
    publish!("never")
    publish!("published")
    assert %{"allow" => true, "development_attempt" => a} = record(c, [good, ghost])
    assert length(a["files"]) == 2
  end

  test "content that goes missing after recording blocks testing and acceptance", c do
    files = [staged_member(c.task, "a.js", "one", "two"), staged_member(c.task, "b.js", "x", "y")]
    assert %{"allow" => true, "development_attempt" => a} = record(c, files)
    assert Ampd.DevelopmentAttempt.content_state(a) == :ok

    File.rm!(Path.join(ReviewContent.blobs(), hash("one")))
    stored = Loci.development_attempts()[a["id"]]
    assert {:error, [fault]} = Ampd.DevelopmentAttempt.content_state(stored)
    assert fault["path"] == "a.js" and fault["state"] == "missing"

    # The projection says so rather than rendering a blank file.
    published = Projection.operator()["development_attempts"][a["id"]]
    current = Enum.find(published["files"], &(&1["source"]["path"] == "a.js"))["content"]["current"]
    assert current["state"] == "missing"

    # And a test run against it is refused rather than run on other bytes.
    assert {:refused, r} =
             Ampd.DevelopmentAttempt.update(
               a["id"],
               {:begin_test,
                # The real repository, so the only fault this exercises is the
                # missing content.
                %{"run_id" => "r1", "revision" => a["revision"], "path" => c.repo,
                  "world" => Enum.map(~w(world_incarnation world_generation projection_epoch),
                                      &Projection.continuity()[&1])}},
               %{"development_attempts" => %{a["id"] => stored},
                 "development_tasks" => %{c.task["id"] => Loci.development_tasks()[c.task["id"]]}}
             )

    assert r["code"] == "review-content-unavailable"
  end

  # ------------------------------------------------------ compatibility

  test "an inline set is still accepted, and its bodies still do not reach the projection", c do
    draft = "before\n"
    proposed = "after\n"

    inline = fn path ->
      %{
        "source" => source(c.task, path, draft, proposed),
        "shared_draft" => draft,
        "proposed_text" => proposed
      }
    end

    assert %{"allow" => true, "development_attempt" => a} =
             record(c, [inline.("a.js"), inline.("b.js")])

    stored = Loci.development_attempts()[a["id"]]
    assert Enum.all?(stored["files"], &(&1["shared_draft"] == draft))

    published = Projection.operator()["development_attempts"][a["id"]]
    refute Enum.any?(published["files"], &Map.has_key?(&1, "shared_draft"))
    assert Enum.all?(published["files"], &(&1["content"]["held"] == "inline"))
    assert Ampd.DevelopmentAttempt.content_state(stored) == :ok,
           "an inline member carries its bytes, so it is never unavailable"
  end

  test "migration: an inline record can be rewritten to name its content, in two phases", c do
    draft = "before\n"
    proposed = "after\n"

    inline = fn path ->
      %{
        "source" => source(c.task, path, draft, proposed),
        "shared_draft" => draft,
        "proposed_text" => proposed
      }
    end

    assert %{"allow" => true, "development_attempt" => a} =
             record(c, [inline.("a.js"), inline.("b.js")])

    state = %{"development_attempts" => Loci.development_attempts()}

    # Phase one writes only into the content store.
    report = ReviewContent.absorb(state["development_attempts"])
    assert report["published"] == 2 and report["refused"] == []
    assert ReviewContent.verify(hash(draft)) == :available
    assert Loci.development_attempts()[a["id"]]["files"] |> Enum.all?(&(&1["shared_draft"] == draft)),
           "phase one does not touch the record"

    # Phase two rewrites the members, and only because the content is there.
    {next, moved} = Ampd.DevelopmentAttempt.migrate_inline(state)
    assert moved["migrated"] == 1
    migrated = next["development_attempts"][a["id"]]
    refute Enum.any?(migrated["files"], &Map.has_key?(&1, "shared_draft"))
    assert Ampd.DevelopmentAttempt.content_state(migrated) == :ok

    # Nothing about the record's meaning changed: the same digests, the same
    # basis, the same everything but where the bytes live.
    assert Enum.map(migrated["files"], & &1["source"]) ==
             Enum.map(Loci.development_attempts()[a["id"]]["files"], & &1["source"])
  end

  test "migration refuses to rewrite a member whose content is not published", c do
    draft = "before\n"
    proposed = "after\n"

    inline = fn path ->
      %{
        "source" => source(c.task, path, draft, proposed),
        "shared_draft" => draft,
        "proposed_text" => proposed
      }
    end

    assert %{"allow" => true, "development_attempt" => a} =
             record(c, [inline.("a.js"), inline.("b.js")])

    # Phase two WITHOUT phase one. A half-migrated member would name content
    # that is not there, which is the one state this design exists to prevent.
    state = %{"development_attempts" => Loci.development_attempts()}
    {next, moved} = Ampd.DevelopmentAttempt.migrate_inline(state)
    assert moved["migrated"] == 0
    assert next == state, "nothing is rewritten while its content is absent"
    assert Enum.all?(next["development_attempts"][a["id"]]["files"], &(&1["shared_draft"] == draft))
  end

  # ---------------------------------------------------------- rollback

  test "ROLLBACK: a staged record converts back to inline, and is then valid to the old shape", c do
    draft = "before\n"
    proposed = "after\n"

    assert %{"allow" => true, "development_attempt" => a} =
             record(c, [
               staged_member(c.task, "a.js", draft, proposed),
               staged_member(c.task, "b.js", draft <> "b", proposed <> "b")
             ])

    state = %{"development_attempts" => Loci.development_attempts()}
    assert Enum.all?(state["development_attempts"][a["id"]]["files"],
                     &(Map.keys(&1) == ["source"])), "staged before conversion"

    {next, report} = Ampd.DevelopmentAttempt.inline_from_content(state)
    assert report["converted"] == 1 and report["blocked"] == [] and report["downgradable"]

    converted = next["development_attempts"][a["id"]]

    # The shape an older runtime requires: exactly these three keys, with bodies
    # whose digests are the ones the source already recorded.
    for m <- converted["files"] do
      assert Enum.sort(Map.keys(m)) == ~w(proposed_text shared_draft source)
      assert hash(m["shared_draft"]) == m["source"]["draft_sha256"]
      assert hash(m["proposed_text"]) == m["source"]["result_sha256"]
    end

    # And it round-trips: converting back forward gives what was there.
    {again, _} = Ampd.DevelopmentAttempt.migrate_inline(next)
    assert again["development_attempts"][a["id"]] == state["development_attempts"][a["id"]]
  end

  test "ROLLBACK: the files this change exists for CANNOT be downgraded, and it says so", c do
    big = String.duplicate("L", 30_000)

    assert %{"allow" => true, "development_attempt" => a} =
             record(c, [
               staged_member(c.task, "big.js", big, big <> "x"),
               staged_member(c.task, "small.js", "d", "p")
             ])

    {next, report} = Ampd.DevelopmentAttempt.inline_from_content(%{
      "development_attempts" => Loci.development_attempts()
    })

    refute report["downgradable"]
    assert report["converted"] == 0, "a record converts whole or not at all"
    assert [block | _] = report["blocked"]
    assert block["attempt"] == a["id"] and block["path"] == "big.js"
    assert block["reason"] == "too-large" and block["bytes"] == 30_000
    assert block["max"] == 24_000

    # Nothing is half-converted: the record is left exactly as it was.
    assert next["development_attempts"] == Loci.development_attempts()
  end

  test "ROLLBACK: a record whose content is gone is reported, not silently inlined as empty", c do
    assert %{"allow" => true, "development_attempt" => a} =
             record(c, [
               staged_member(c.task, "a.js", "one", "two"),
               staged_member(c.task, "b.js", "three", "four")
             ])

    File.rm!(Path.join(ReviewContent.blobs(), hash("one")))

    {_, report} = Ampd.DevelopmentAttempt.inline_from_content(%{
      "development_attempts" => Loci.development_attempts()
    })

    refute report["downgradable"]
    assert [%{"path" => "a.js", "side" => "current", "reason" => "missing", "attempt" => id}] =
             report["blocked"]

    assert id == a["id"]
  end

  test "ROLLBACK: an already-inline record needs no conversion and is reported downgradable", c do
    body = "before\n"

    inline = fn path ->
      %{"source" => source(c.task, path, body, body),
        "shared_draft" => body, "proposed_text" => body}
    end

    assert %{"allow" => true} = record(c, [inline.("a.js"), inline.("b.js")])

    state = %{"development_attempts" => Loci.development_attempts()}
    {next, report} = Ampd.DevelopmentAttempt.inline_from_content(state)
    assert report["downgradable"] and report["converted"] == 0
    assert next == state, "nothing to do, and nothing done"
  end

  test "an inline member over the old per-file cap still refuses, by SIZE not by count", c do
    big = String.duplicate("z", 24_001)

    over = %{
      "source" => source(c.task, "a.js", big, "after\n"),
      "shared_draft" => big,
      "proposed_text" => "after\n"
    }

    other = %{
      "source" => source(c.task, "b.js", "d", "p"),
      "shared_draft" => "d",
      "proposed_text" => "p"
    }

    assert %{"allow" => false, "refusal" => r} = record(c, [over, other])
    assert r["code"] == "review-file-too-large"
    assert r["operator_detail"]["path"] == "a.js"
  end
end
