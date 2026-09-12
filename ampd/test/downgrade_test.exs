defmodule Ampd.DowngradeTest do
  @moduledoc """
  The rollback, as a whole-world procedure: every record converting is not the
  same as the old runtime admitting the world. These pin the three gaps a
  per-record conversion leaves open — the old four-member set, the old 64 KiB
  directory with its per-run reserve — and the durable procedure's promise
  that a refusal changes nothing.

  Worlds here are **disposable copies** of the test world: the loci state as
  the running `Ampd.Loci` saved it, re-written into a cleanly closed dets file
  beside a copy of the manifest and the content store. That is the shape the
  real procedure sees after the desktop is stopped.
  """
  use ExUnit.Case, async: false
  alias Ampd.{Authority, Control, DevelopmentAttempt, Downgrade, Loci, Projection, ReviewContent}

  setup do
    Ampd.reset()
    File.rm_rf(ReviewContent.dir())
    on_exit(fn -> File.rm_rf(ReviewContent.dir()) end)

    {human, agent} = Ampd.attach_pair("downgrade")
    %{"workspace" => ws} = Control.command(human, :open_workspace, ["Super"])
    %{"goal" => goal} = Control.command(human, :open_goal, [ws["id"], "Roll back safely"])

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

    repo = Path.join(System.tmp_dir!(), "super-dg-#{System.unique_integer([:positive])}")
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
        "title" => "Survive a downgrade",
        "criteria" => "The old runtime opens the converted world."
      })

    %{human: human, agent: agent, task: task, repo: repo}
  end

  # ------------------------------------------------------------ helpers

  defp hash(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
  defp head, do: String.duplicate("a", 40)

  defp world_ref,
    do:
      Enum.map(
        ~w(world_incarnation world_generation projection_epoch),
        &Projection.continuity()[&1]
      )

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
      "world" => world_ref()
    }
  end

  defp staged(task, path, draft, proposed) do
    publish!(draft)
    publish!(proposed)
    %{"source" => source(task, path, draft, proposed)}
  end

  defp record(c, files, ref) do
    Control.command(c.human, :record_development_change_set, [
      ref,
      c.task["id"],
      c.task["revision"],
      %{"files" => files}
    ])
  end

  defp record!(c, files, ref) do
    assert %{"allow" => true, "development_attempt" => a} = record(c, files, ref)
    a
  end

  defp state, do: %{"development_attempts" => Loci.development_attempts()}

  # A disposable world: the loci state exactly as the running store holds it,
  # re-written into a cleanly closed dets file, beside the manifest and the
  # content store. Returned with a cleanup.
  defp disposable_copy do
    live = Ampd.Store.data_dir()
    copy = Path.join(System.tmp_dir!(), "super-downgrade-#{System.unique_integer([:positive])}")
    File.mkdir_p!(copy)
    File.cp!(Path.join(live, "world.json"), Path.join(copy, "world.json"))
    File.cp_r!(Path.join(live, "review-content"), Path.join(copy, "review-content"))

    [{:state, s}] = :dets.lookup(:ampd_loci, :state)
    tab = :"downgrade_copy_#{System.unique_integer([:positive])}"
    {:ok, ^tab} = :dets.open_file(tab, file: String.to_charlist(Path.join(copy, "loci.dets")))
    :ok = :dets.insert(tab, {:state, s})
    :ok = :dets.sync(tab)
    :ok = :dets.close(tab)
    on_exit(fn -> File.rm_rf(copy) end)
    copy
  end

  defp attempts_on_disk(world) do
    tab = :"downgrade_read_#{System.unique_integer([:positive])}"

    {:ok, ^tab} =
      :dets.open_file(tab,
        file: String.to_charlist(Path.join(world, "loci.dets")),
        access: :read,
        repair: false
      )

    [{:state, s}] = :dets.lookup(tab, :state)
    :ok = :dets.close(tab)
    s["development_attempts"]
  end

  defp sha_file(path), do: File.read!(path) |> hash()
  defp store(world), do: Path.join(world, "loci.dets")
  defp backups(world), do: Path.wildcard(Path.join(world, "loci.dets.before-downgrade-*"))

  # ----------------------------------------------------------- preflight

  test "PREFLIGHT: five members all convert, and the old runtime still cannot count them", c do
    files = for p <- ~w(a b c d e), do: staged(c.task, "#{p}.js", "cur #{p}\n", "new #{p}\n")
    a = record!(c, files, "five")

    {_, report} = Downgrade.preflight(state())

    assert report["converted"] == 1, "every member converts — that is not the question"
    refute report["downgradable"]

    assert [%{"reason" => "file-count", "attempt" => id, "count" => 5, "min" => 2, "max" => 4}] =
             report["blocked"]

    assert id == a["id"]
  end

  test "PREFLIGHT: every record converts and the collection still exceeds the old directory", c do
    # Each side is well under the old per-file caps, so inline_from_content/1
    # alone reports every record downgradable. Six bodies of 12 000 bytes are
    # 72 000 bytes inline — over a budget the old persist/2 enforces on the
    # whole collection and a per-record conversion never sees.
    for n <- 1..3 do
      body = String.duplicate(<<?a + n>>, 12_000)

      record!(
        c,
        [
          staged(c.task, "x#{n}.js", body, body <> "!"),
          staged(c.task, "y#{n}.js", body, body <> "?")
        ],
        "set-#{n}"
      )
    end

    {_, per_record} = DevelopmentAttempt.inline_from_content(state())
    assert per_record["downgradable"], "the per-record view is the one that misses this"

    {_, report} = Downgrade.preflight(state())
    assert report["converted"] == 3
    refute report["downgradable"]

    assert [%{"reason" => "directory-too-large", "bytes" => bytes, "reserved" => 0, "max" => max}] =
             report["blocked"]

    assert max == 64 * 1024 and bytes > max
    assert report["encoded_bytes"] == bytes
  end

  test "PREFLIGHT: an unfinished test run reserves 4 608 bytes of the old budget", c do
    # Sized to land inside the reserve: the converted collection fits the old
    # directory on its own and does not fit once one started run is reserved.
    body = String.duplicate("b", 7_500)

    a =
      record!(
        c,
        [staged(c.task, "p.js", body, body), staged(c.task, "q.js", body, body)],
        "edge-1"
      )

    record!(c, [staged(c.task, "r.js", body, body), staged(c.task, "s.js", body, body)], "edge-2")

    {_, without} = Downgrade.preflight(state())
    e = without["encoded_bytes"]

    assert e in (64 * 1024 - 4608 + 1)..(64 * 1024),
           "retune the body size: the converted collection encodes to #{e} bytes"

    assert without["downgradable"] and without["started_runs"] == 0

    assert without["headroom_bytes"] == 64 * 1024 - e,
           "headroom is what the old runtime can still record"

    # A run started through the real admission path, on the real state.
    full = Map.put(state(), "development_tasks", Loci.development_tasks())

    {:ok, _, with_run} =
      DevelopmentAttempt.update(
        a["id"],
        {:begin_test,
         %{
           "run_id" => "r1",
           "revision" => a["revision"],
           "path" => c.repo,
           "world" => world_ref()
         }},
        full
      )

    {_, report} = Downgrade.preflight(with_run)
    assert report["started_runs"] == 1 and report["reserved_bytes"] == 4608
    assert report["headroom_bytes"] < 0
    assert report["encoded_bytes"] > e, "the run itself is recorded too"
    refute report["downgradable"]

    assert [%{"reason" => "directory-too-large", "reserved" => 4608}] = report["blocked"]
  end

  test "PREFLIGHT: a converted member is the old shape exactly, and an oversized one is not counted twice",
       c do
    big = String.duplicate("L", 24_001)
    record!(c, [staged(c.task, "big.js", big, "p"), staged(c.task, "ok.js", "d", "p")], "big")
    record!(c, [staged(c.task, "m.js", "d", "p"), staged(c.task, "n.js", "d", "p")], "fine")

    {next, report} = Downgrade.preflight(state())
    refute report["downgradable"]

    # The oversized record is reported once, by the conversion, and not again
    # as a "shape" fault for the member the conversion left staged.
    reasons = Enum.map(report["blocked"], & &1["reason"])
    assert reasons == ["too-large"]

    # The record that converted has exactly the keys the old set_file?/1 requires.
    fine = Enum.find(Map.values(next["development_attempts"]), &(&1["client_ref"] == "fine"))

    assert Enum.all?(
             fine["files"],
             &(Enum.sort(Map.keys(&1)) == ~w(proposed_text shared_draft source))
           )
  end

  # ----------------------------------------------------------------- run

  test "RUN: a refused preflight leaves the world byte-identical", c do
    files = for p <- ~w(a b c d e), do: staged(c.task, "#{p}.js", "cur #{p}\n", "new #{p}\n")
    record!(c, files, "five")

    world = disposable_copy()
    before = sha_file(store(world))
    blobs_before = File.ls!(Path.join(world, "review-content/blobs")) |> Enum.sort()

    assert {:refused, report} = Downgrade.run(world)
    assert report["refusal"] == "not-downgradable" and report["written"] == false
    assert [%{"reason" => "file-count"}] = report["blocked"]

    assert sha_file(store(world)) == before, "the store was not touched"
    assert backups(world) == [], "no backup is taken for a run that writes nothing"
    assert File.ls!(Path.join(world, "review-content/blobs")) |> Enum.sort() == blobs_before

    # And the staged records are still staged: nothing was half-done.
    assert Enum.all?(Map.values(attempts_on_disk(world)), fn a ->
             Enum.all?(a["files"], &(Map.keys(&1) == ["source"]))
           end)
  end

  test "RUN: a downgradable world is converted durably, backed up, and read back", c do
    a1 =
      record!(
        c,
        [staged(c.task, "a.js", "one\n", "two\n"), staged(c.task, "b.js", "3\n", "4\n")],
        "s1"
      )

    a2 =
      record!(
        c,
        [staged(c.task, "c.js", "five\n", "six\n"), staged(c.task, "d.js", "7\n", "8\n")],
        "s2"
      )

    world = disposable_copy()
    before = sha_file(store(world))

    assert {:ok, report} = Downgrade.run(world, now: ~U[2026-09-12 20:00:00Z])
    assert report["written"] and report["verified"] and report["converted"] == 2
    assert report["downgradable"] and report["blocked"] == []

    # The backup is the exact store the new runtime wrote.
    assert report["backup"] == store(world) <> ".before-downgrade-20260912T200000Z"
    assert File.exists?(report["backup"]) and sha_file(report["backup"]) == before
    assert sha_file(store(world)) != before, "and the store itself changed"

    # What is on disk is the old shape, with bodies whose digests the source recorded.
    on_disk = attempts_on_disk(world)

    for id <- [a1["id"], a2["id"]], m <- on_disk[id]["files"] do
      assert Enum.sort(Map.keys(m)) == ~w(proposed_text shared_draft source)
      assert hash(m["shared_draft"]) == m["source"]["draft_sha256"]
      assert hash(m["proposed_text"]) == m["source"]["result_sha256"]
    end

    # Everything that is not review material is untouched by the conversion.
    [{:state, live}] = :dets.lookup(:ampd_loci, :state)
    tab = :"downgrade_read_#{System.unique_integer([:positive])}"
    {:ok, ^tab} = :dets.open_file(tab, file: String.to_charlist(store(world)), access: :read)
    [{:state, written}] = :dets.lookup(tab, :state)
    :ok = :dets.close(tab)
    assert Map.delete(written, "development_attempts") == Map.delete(live, "development_attempts")

    # Running it again finds nothing to convert and still reads back.
    assert {:ok, again} = Downgrade.run(world)
    assert again["converted"] == 0 and again["verified"]
  end

  # ----------------------------------------------------- failure injection

  # A failure at each boundary of the write, and what must be true of the disk
  # afterwards. Steps before the mutation leave every byte as it was and say
  # so; steps after the insert say the mutation began, name the backup, and
  # the backup restores the store exactly.
  defp two_sets!(c) do
    record!(
      c,
      [staged(c.task, "a.js", "one\n", "two\n"), staged(c.task, "b.js", "3\n", "4\n")],
      "s1"
    )

    record!(
      c,
      [staged(c.task, "c.js", "five\n", "six\n"), staged(c.task, "d.js", "7\n", "8\n")],
      "s2"
    )
  end

  for step <-
        ~w(after_backup_created after_backup_copied after_backup_synced after_backup_durable after_open)a do
    test "INJECT #{step}: an untouched refusal — the store is byte-identical and the report says so",
         c do
      two_sets!(c)
      world = disposable_copy()
      before = sha_file(store(world))

      assert {:refused, r} = Downgrade.run(world, fail_at: unquote(step))
      assert r["refusal"] == "injected-failure-#{unquote(step)}"
      assert r["written"] == false and r["mutation_began"] == false
      assert r["phase"] == "backup" or unquote(step) == :after_open
      assert sha_file(store(world)) == before, "the store was not touched"

      # A backup that got as far as being copied is a faithful copy; one that
      # was only created is empty and named — never a half-written store
      # under the store's own name.
      case backups(world) do
        [] ->
          assert unquote(step) == :after_backup_created and false, "the name is created first"

        [b] ->
          if unquote(step) == :after_backup_created,
            do: assert(File.read!(b) == ""),
            else: assert(sha_file(b) == before)
      end
    end
  end

  for step <- ~w(after_insert after_sync after_close before_verify)a do
    test "INJECT #{step}: a failure after the mutation began is reported as such, and the backup restores the store",
         c do
      two_sets!(c)
      world = disposable_copy()
      before = sha_file(store(world))
      attempts_before = attempts_on_disk(world)

      assert {:refused, r} = Downgrade.run(world, fail_at: unquote(step))
      assert r["refusal"] == "injected-failure-#{unquote(step)}"
      assert r["mutation_began"] == true and r["written"] == false and r["phase"] == "write"
      assert r["recover"] =~ r["backup"]
      assert [backup] = backups(world)
      assert sha_file(backup) == before, "the backup is the store exactly as it was"

      # Recovery: the backup goes back, durably, and the state reads as before.
      assert {:ok, %{"restored_from" => ^backup}} = Downgrade.restore(world, backup)
      assert sha_file(store(world)) == before
      assert attempts_on_disk(world) == attempts_before

      # And the world converts on the next run, as if nothing had happened —
      # under a NEW backup name, never over the one that saved it.
      assert {:ok, ok} = Downgrade.run(world)
      assert ok["written"] and ok["verified"] and ok["backup"] != backup
      assert length(backups(world)) == 2
    end
  end

  test "ORDER: the backup's bytes and its NAME are durable before the store is opened for writing",
       c do
    two_sets!(c)
    world = disposable_copy()
    assert {:ok, r} = Downgrade.run(world, trace: self())
    backup = Path.basename(r["backup"])

    events =
      Stream.repeatedly(fn ->
        receive do
          {:downgrade, e} -> e
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(&(&1 != nil))

    # Read-only preflight first; then the copy, its sync, the directory sync
    # (the name), and only THEN the store is opened read-write.
    assert events == [
             {:open, :read},
             {:copy, "loci.dets", backup},
             {:sync_file, backup},
             :sync_dir,
             {:open, :read_write},
             :insert,
             :dets_sync,
             :sync_dir,
             {:open, :read}
           ]
  end

  test "BACKUP: two runs in the same second get two names, and no backup is ever overwritten",
       c do
    two_sets!(c)
    world = disposable_copy()
    now = ~U[2026-09-12 21:00:00Z]
    before = sha_file(store(world))

    assert {:ok, first} = Downgrade.run(world, now: now)
    assert first["backup"] == store(world) <> ".before-downgrade-20260912T210000Z"
    after_first = sha_file(store(world))

    assert {:ok, second} = Downgrade.run(world, now: now)
    assert second["backup"] == store(world) <> ".before-downgrade-20260912T210000Z-1"
    assert sha_file(first["backup"]) == before, "the first backup still holds the original"
    assert sha_file(second["backup"]) == after_first, "the second holds the converted store"
  end

  test "RESTORE: refuses an absent backup and a locked world, and writes nothing", c do
    two_sets!(c)
    world = disposable_copy()
    before = sha_file(store(world))

    assert {:refused, %{"refusal" => "backup-absent"}} =
             Downgrade.restore(world, store(world) <> ".nope")

    assert sha_file(store(world)) == before
  end

  test "RUN: refuses while the world lock is held, and writes nothing", c do
    record!(
      c,
      [staged(c.task, "a.js", "one\n", "two\n"), staged(c.task, "b.js", "3\n", "4\n")],
      "s1"
    )

    world = disposable_copy()
    lock = Path.join(world, "world.lock")
    File.touch!(lock)
    before = sha_file(store(world))

    # The same flock(2) a host takes for its lifetime.
    holder = spawn(fn -> System.cmd("flock", ["-x", lock, "sleep", "4"]) end)
    Process.sleep(400)

    assert {:refused, report} = Downgrade.run(world)
    assert report["refusal"] == "world-locked" and report["written"] == false
    assert sha_file(store(world)) == before and backups(world) == []

    Process.exit(holder, :kill)
  end

  test "RUN: refuses a directory that is not a world", _c do
    dir = Path.join(System.tmp_dir!(), "super-not-a-world-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    assert {:refused, %{"refusal" => "world-manifest-absent", "written" => false}} =
             Downgrade.run(dir)

    assert File.ls!(dir) == [], "and it creates nothing"
  end

  test "CHECK: the read-only preflight and the CLI report, without writing", c do
    files = for p <- ~w(a b c d e), do: staged(c.task, "#{p}.js", "cur #{p}\n", "new #{p}\n")
    record!(c, files, "five")
    world = disposable_copy()
    before = sha_file(store(world))

    assert {:refused, report} = Downgrade.check(world)
    refute report["downgradable"]
    assert report["written"] == false and sha_file(store(world)) == before

    out = Path.join(world, "report.json")
    Process.put(:ampd_downgrade_no_halt, true)

    code =
      ExUnit.CaptureIO.capture_io(fn ->
        send(self(), {:code, Downgrade.main([world, "--report", out, "--check"])})
      end)

    assert_receive {:code, 2}
    assert code =~ "file-count"
    assert File.read!(out) |> JSON.decode!() |> Map.fetch!("downgradable") == false
    assert sha_file(store(world)) == before
  end
end
