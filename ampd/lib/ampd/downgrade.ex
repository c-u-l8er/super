defmodule Ampd.Downgrade do
  @moduledoc """
  Prepare a world for an **older** runtime — the rollback of staged review
  content, made durable and checked against the constraints the older runtime
  actually enforces.

  `Ampd.DevelopmentAttempt.inline_from_content/1` puts bodies back into staged
  members, one record at a time, and that is necessary but not sufficient. The
  older runtime (main at `#{"cf3931f"}`) admits the **whole collection** under
  rules that a per-record conversion never looks at:

    * a change set holds **2 to 4** members, not 2 to 12;
    * the persisted `development_attempts` collection encodes to at most
      **64 KiB**, *after* reserving 4 608 bytes for every unfinished test run
      — so a world whose records each convert can still be one the old
      `persist/2` would never have admitted, and one whose next mutation it
      would refuse as `attempt-directory-full`;
    * at most 50 attempts;
    * every member has exactly `shared_draft`, `proposed_text` and `source`,
      within the old caps, with a `basis_id` that binds its source.

  `preflight/1` applies all of them in memory and writes nothing. `run/2` is
  the durable procedure: it refuses while the world is locked, reads the
  `loci` store read-only, preflights, and **only if the world is downgradable**
  backs the store up, writes the converted state, syncs it and its directory,
  and reads it back. A refused preflight leaves every byte of the world as it
  was, and the report says why.

  The rules here are **copied from the older runtime, not imported from the
  current one**, on purpose: the current `DevelopmentAttempt` admits up to
  twelve members, and a preflight that asked it would pass a set the old
  runtime cannot count. `tools/downgrade-world.sh` is the entry point, and the
  proof that the rules are the right ones is the old runtime opening a world
  this converted — `tools/old-runtime-check.exs`, run under that runtime.
  """

  alias Ampd.{DevelopmentAttempt, Frame}

  @old_runtime "cf3931f"
  @old_members 2..4
  @old_draft 24_000
  @old_proposed 32_000
  @old_attempts 50
  @old_directory 64 * 1024
  @old_reserve 4608

  # A private table name, so this never shares a handle with a running
  # `Ampd.Loci` in the same VM. dets tables are VM-global by name.
  @tab :ampd_downgrade_loci

  def old_runtime, do: @old_runtime
  def directory_budget, do: @old_directory
  def reserve_per_run, do: @old_reserve

  # ------------------------------------------------------------ preflight

  @doc """
  Convert, then check the whole collection against the old runtime's rules.

  Returns `{converted_state, report}`. The state is only meaningful when
  `report["downgradable"]` is true; nothing is written by this function.
  Performs the same filesystem reads `inline_from_content/1` does.

  Every fault is a map with a `"reason"`, and where it applies an
  `"attempt"`, `"path"` and `"side"`, so an operator can act on each one:

  | reason | meaning |
  |---|---|
  | `missing` / `corrupt` | no bytes to put back — stage the content again |
  | `too-large` | a member over the old per-file caps — cannot be downgraded |
  | `file-count` | a set of more than #{4} members — cannot be downgraded |
  | `shape` | a converted member the old `set_file?/1` would not accept |
  | `attempt-limit` | more than #{50} attempts |
  | `directory-too-large` | the converted collection, plus the reserve for unfinished runs, over #{64 * 1024} bytes |
  """
  def preflight(%{"development_attempts" => attempts} = s) when is_map(attempts) do
    {next, conversion} = DevelopmentAttempt.inline_from_content(s)
    converted = next["development_attempts"]

    already = MapSet.new(conversion["blocked"], & &1["attempt"])
    started = started_runs(converted)
    reserved = started * @old_reserve

    faults =
      conversion["blocked"] ++
        limit_faults(converted) ++
        record_faults(converted, already)

    {encoded, directory} = directory_faults(converted, reserved)
    faults = faults ++ directory

    {next,
     %{
       "old_runtime" => @old_runtime,
       "attempts" => map_size(converted),
       "converted" => conversion["converted"],
       "started_runs" => started,
       "reserved_bytes" => reserved,
       "encoded_bytes" => encoded,
       "budget_bytes" => @old_directory,
       # What the old runtime can still record after the downgrade. Its
       # `persist/2` refuses every further review, test start and acceptance
       # once this is spent — measured: a converted world at 38 KiB refused a
       # test start after one re-recorded set and two acceptances.
       "headroom_bytes" => if(encoded, do: @old_directory - encoded - reserved, else: nil),
       "blocked" => faults,
       "downgradable" => faults == []
     }}
  end

  defp started_runs(attempts) do
    attempts
    |> Map.values()
    |> Enum.flat_map(&(Map.get(&1, "test_runs", %{}) |> Map.values()))
    |> Enum.count(&(&1["state"] == "started"))
  end

  defp limit_faults(attempts) when map_size(attempts) > @old_attempts,
    do: [%{"reason" => "attempt-limit", "count" => map_size(attempts), "max" => @old_attempts}]

  defp limit_faults(_), do: []

  defp record_faults(attempts, already) do
    attempts
    |> Enum.reject(fn {id, _} -> MapSet.member?(already, id) end)
    |> Enum.flat_map(fn {id, a} -> Enum.map(attempt_faults(a), &Map.put(&1, "attempt", id)) end)
  end

  defp attempt_faults(%{"files" => files}) when is_list(files) do
    count =
      if length(files) in @old_members,
        do: [],
        else: [
          %{
            "reason" => "file-count",
            "count" => length(files),
            "min" => @old_members.first,
            "max" => @old_members.last
          }
        ]

    count ++
      Enum.flat_map(files, fn m ->
        if legacy_member?(m),
          do: [],
          else: [%{"reason" => "shape", "path" => path_of(m)}]
      end)
  end

  defp attempt_faults(%{"source" => _} = a) do
    # A single-file attempt is its own member; the old runtime checked it with
    # the same body caps and the same source binding.
    if legacy_single?(a), do: [], else: [%{"reason" => "shape", "path" => path_of(a)}]
  end

  defp attempt_faults(_), do: []

  defp path_of(%{"source" => %{"path" => p}}), do: p
  defp path_of(_), do: nil

  # ---- the old runtime's `set_file?/1`, verbatim from cf3931f. Kept here rather
  # than shared with the current module so that a later relaxation of the
  # current rules cannot quietly relax the downgrade check.

  @source_fields ~w(schema scope basis_id head path disk_sha256 draft_sha256 draft_bytes unsaved result_sha256 result_bytes task_ref task_revision repository_ref world)

  defp legacy_member?(row) when is_map(row) do
    Enum.sort(Map.keys(row)) == ~w(proposed_text shared_draft source) and
      legacy_body?(row)
  end

  defp legacy_member?(_), do: false

  defp legacy_single?(a) when is_map(a),
    do: is_map(a["source"]) and legacy_body?(a)

  defp legacy_body?(row) do
    text?(row["shared_draft"], @old_draft) and
      (row["proposed_text"] == nil or text?(row["proposed_text"], @old_proposed)) and
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

  defp digest(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
  defp hash?(s), do: is_binary(s) and Regex.match?(~r/\A[0-9a-f]{64}\z/, s)

  defp text?(s, cap),
    do:
      is_binary(s) and String.valid?(s) and byte_size(s) <= cap and not String.contains?(s, <<0>>)

  defp nonempty?(s, cap), do: text?(s, cap) and String.trim(s) != ""
  defp result_digest(nil, path), do: digest(JSON.encode!(["deleted-file@1", path]))
  defp result_digest(text, _), do: digest(text)
  defp result_size(nil), do: 0
  defp result_size(text), do: byte_size(text)

  # ---- the old `persist/2` budget, over the whole collection

  defp directory_faults(attempts, reserved) do
    with {:ok, _} <- Frame.logical_size(attempts, @old_directory),
         {:ok, encoded} <- Frame.encode(attempts),
         true <- byte_size(encoded) + reserved <= @old_directory do
      {byte_size(encoded), []}
    else
      {:over, n} ->
        {nil,
         [
           %{
             "reason" => "directory-too-large",
             "bytes" => nil,
             "logical_bytes" => n,
             "reserved" => reserved,
             "max" => @old_directory
           }
         ]}

      {:error, _, %{"bytes" => n}} ->
        {n,
         [
           %{
             "reason" => "directory-too-large",
             "bytes" => n,
             "reserved" => reserved,
             "max" => @old_directory
           }
         ]}

      false ->
        {:ok, encoded} = Frame.encode(attempts)

        {byte_size(encoded),
         [
           %{
             "reason" => "directory-too-large",
             "bytes" => byte_size(encoded),
             "reserved" => reserved,
             "max" => @old_directory
           }
         ]}
    end
  end

  # ------------------------------------------------------------------ run

  @doc """
  The durable procedure, against a world directory.

  Returns `{:ok, report}` when the converted state was written, synced and
  read back, or `{:refused, report}` when nothing was written. `report`
  always carries `"written"` and, when refused, `"refusal"`.

  Order, and why:

    1. **Refuse while the world is locked.** A host holds `world.lock` with
       `flock(2)` for its lifetime; converting under it would race the
       coordinator. `tools/downgrade-world.sh` holds the same lock around this
       whole run, which closes the window between this check and the write.
    2. **Refuse a manifest this build does not trust**, for the reasons
       `Ampd.World.may_initialize?/0` gives — and never create one.
    3. **Read the store read-only.** A `loci.dets` that was not closed cleanly
       is refused, not repaired: repair is the running runtime's decision.
    4. **Preflight.** Not downgradable → close, report, and every byte of the
       world is as it was.
    5. **Back up** `loci.dets` to `loci.dets.before-downgrade-<utc>` — a name
       created exclusively, so no backup is ever overwritten — sync the copy,
       then sync the directory so the NAME is durable before anything changes.
    6. **Write** the converted state, `dets` sync, close, and sync the world
       directory so the rename-free rewrite is durable.
    7. **Read back** and compare the attempts to what was meant to be written.

  The report says which of three things happened: `mutation_began: false`
  (an untouched refusal — every byte as it was), `mutation_began: true,
  written: false` (a failure after the write started — restore from the named
  backup with `restore/2` before any runtime opens the world), or `written:
  true, verified: true`.

  Runs with `AMPD_DATA_DIR` pointed at `world` for its duration, because
  `Ampd.ReviewContent` resolves its blobs from `Ampd.Store.data_dir/0`. The
  previous value is restored afterwards.
  """
  def run(world, opts \\ []) when is_binary(world) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    Process.put(:ampd_downgrade_trace, Keyword.get(opts, :trace))

    with_data_dir(world, fn ->
      with :ok <- lock_free(world, Keyword.get(opts, :lock, :probe)),
           :ok <- manifest_trusted(),
           {:ok, s} <- read_state(world),
           {next, report} <- preflight(s),
           :ok <- downgradable(report) do
        write_and_verify(world, next, report, now, opts)
      else
        {:refused, refusal, report} ->
          {:refused,
           Map.merge(report, %{
             "written" => false,
             "mutation_began" => false,
             "refusal" => refusal
           })}
      end
    end)
  end

  defp downgradable(%{"downgradable" => true}), do: :ok
  defp downgradable(report), do: {:refused, "not-downgradable", report}

  # `:probe` takes `flock -n` on the world's lock and refuses if anyone holds
  # it. `:held` is the caller asserting that IT holds the lock for the whole
  # run — which is what `tools/downgrade-world.sh` does, and the only way to
  # close the window between a probe and the write. A probe from under a held
  # lock cannot tell an ancestor's lock from a host's, so the wrapper says so.
  defp lock_free(_world, :held), do: :ok

  defp lock_free(world, :probe) do
    lock = Path.join(world, "world.lock")

    cond do
      not File.exists?(lock) ->
        :ok

      System.find_executable("flock") == nil ->
        {:refused, "lock-unverifiable", %{"lock" => lock}}

      true ->
        case System.cmd("flock", ["-n", lock, "true"], stderr_to_stdout: true) do
          {_, 0} -> :ok
          {out, _} -> {:refused, "world-locked", %{"lock" => lock, "detail" => String.trim(out)}}
        end
    end
  end

  defp manifest_trusted do
    case Ampd.World.manifest_state() do
      :valid -> :ok
      state -> {:refused, "world-manifest-#{state}", %{"fields" => Ampd.World.invalid_fields()}}
    end
  end

  defp store(world), do: Path.join(world, "loci.dets")

  defp open(world, access) do
    trace({:open, access})
    file = String.to_charlist(store(world))

    case :dets.open_file(@tab, file: file, repair: false, access: access) do
      {:ok, @tab} -> {:ok, @tab}
      {:error, {:needs_repair, _}} -> {:error, "loci-store-needs-repair"}
      {:error, {:not_closed, _}} -> {:error, "loci-store-not-closed"}
      {:error, reason} -> {:error, "loci-store-#{inspect(reason)}"}
    end
  end

  defp read_state(world) do
    if File.exists?(store(world)) do
      case open(world, :read) do
        {:ok, tab} ->
          found = :dets.lookup(tab, :state)
          :ok = :dets.close(tab)

          case found do
            [{:state, %{"development_attempts" => _} = s}] -> {:ok, s}
            [{:state, s}] when is_map(s) -> {:ok, Map.put(s, "development_attempts", %{})}
            _ -> {:refused, "loci-state-absent", %{}}
          end

        {:error, why} ->
          {:refused, why, %{}}
      end
    else
      {:refused, "loci-store-absent", %{"store" => store(world)}}
    end
  end

  # The write, in phases, and the report says which phase failed.
  #
  #   backup   copy the store to a NEW name (exclusive create — never over an
  #            existing backup), sync the copy, then sync the directory so the
  #            NAME is durable too. Nothing about the world has changed yet:
  #            a failure here is an untouched refusal.
  #   write    open read-write, insert, sync, close, sync the directory.
  #            From the insert on, the store may differ from the backup: a
  #            failure here is reported as `mutation_began: true` with the
  #            backup path and the phase, never as "nothing changed".
  #   verify   re-open read-only and compare.
  #
  # `fail_at` is failure injection for the tests of exactly those boundaries.
  # It returns the error the real step would; the bytes on disk up to that
  # point are the bytes a crash there would leave.
  defp write_and_verify(world, next, report, now, opts) do
    fail_at = Keyword.get(opts, :fail_at)

    with {:ok, backup} <- make_backup(world, now, fail_at),
         report = Map.put(report, "backup", backup),
         :ok <- inject(fail_at, :after_backup_durable),
         {:ok, tab} <- open(world, :read_write),
         :ok <- inject(fail_at, :after_open) do
      # From here the store is being mutated.
      report = Map.put(report, "mutation_began", true)

      with :ok <- :dets.insert(tab, {:state, next}),
           _ = trace(:insert),
           :ok <- inject(fail_at, :after_insert),
           :ok <- :dets.sync(tab),
           _ = trace(:dets_sync),
           :ok <- inject(fail_at, :after_sync),
           :ok <- :dets.close(tab),
           :ok <- inject(fail_at, :after_close),
           :ok <- sync_dir(world),
           :ok <- inject(fail_at, :before_verify),
           {:ok, again} <- read_state(world) do
        if again["development_attempts"] == next["development_attempts"] do
          {:ok, Map.merge(report, %{"written" => true, "verified" => true, "phase" => "done"})}
        else
          {:refused,
           Map.merge(report, %{
             "written" => true,
             "verified" => false,
             "refusal" => "read-back-mismatch",
             "phase" => "verify"
           })}
        end
      else
        # The store may be partly written. Say so, and say what to do.
        {:error, why} ->
          _ = :dets.close(tab)
          {:refused, after_mutation(report, why)}

        {:refused, why, detail} ->
          {:refused, after_mutation(Map.merge(report, detail), why)}
      end
    else
      {:error, why} ->
        {:refused,
         Map.merge(report, %{
           "written" => false,
           "mutation_began" => false,
           "refusal" => to_string(why),
           "phase" => "backup"
         })}
    end
  end

  defp after_mutation(report, why) do
    Map.merge(report, %{
      "written" => false,
      "mutation_began" => true,
      "verified" => false,
      "refusal" => to_string(why),
      "phase" => "write",
      "recover" =>
        "The store may be partly written. Restore it from #{report["backup"]} " <>
          "(Ampd.Downgrade.restore/2, or tools/downgrade-world.sh --restore) before any runtime opens it."
    })
  end

  defp inject(nil, _), do: :ok
  defp inject(at, at), do: {:error, "injected-failure-#{at}"}
  defp inject(_, _), do: :ok

  # `trace: pid` receives every durability step in the order it happens, so a
  # test can pin the ORDER — backup contents, backup name, then the store —
  # which no inspection of the disk afterwards can show.
  defp trace(event) do
    case Process.get(:ampd_downgrade_trace) do
      pid when is_pid(pid) -> send(pid, {:downgrade, event})
      _ -> :ok
    end
  end

  # A backup under a name that did not exist: exclusive create, so two runs in
  # one second — or a re-run after a failure — can never overwrite the copy
  # that a recovery depends on. Contents synced, then the directory, so the
  # name survives a crash as surely as the bytes.
  defp make_backup(world, now, fail_at) do
    stamp = now |> DateTime.truncate(:second) |> DateTime.to_iso8601(:basic)
    base = store(world) <> ".before-downgrade-#{stamp}"

    with {:ok, backup} <- create_exclusive(base, 0),
         :ok <- inject(fail_at, :after_backup_created),
         :ok <- copy_into(store(world), backup),
         :ok <- inject(fail_at, :after_backup_copied),
         :ok <- sync_file(backup),
         :ok <- inject(fail_at, :after_backup_synced),
         :ok <- sync_dir(world) do
      {:ok, backup}
    else
      {:error, why} when is_binary(why) -> {:error, why}
      {:error, why} -> {:error, "backup-failed-#{inspect(why)}"}
    end
  end

  defp create_exclusive(base, n) when n < 1000 do
    path = if n == 0, do: base, else: "#{base}-#{n}"

    case :file.open(String.to_charlist(path), [:write, :exclusive, :raw, :binary]) do
      {:ok, fd} ->
        :ok = :file.close(fd)
        {:ok, path}

      {:error, :eexist} ->
        create_exclusive(base, n + 1)

      {:error, why} ->
        {:error, "backup-create-failed-#{inspect(why)}"}
    end
  end

  defp create_exclusive(_, _), do: {:error, "backup-create-failed-too-many-backups"}

  defp copy_into(from, to) do
    trace({:copy, Path.basename(from), Path.basename(to)})

    case File.cp(from, to) do
      :ok -> :ok
      {:error, why} -> {:error, "backup-copy-failed-#{inspect(why)}"}
    end
  end

  defp sync_file(path) do
    trace({:sync_file, Path.basename(path)})

    with {:ok, fd} <- :file.open(String.to_charlist(path), [:read, :write, :raw, :binary]),
         :ok <- :file.sync(fd),
         :ok <- :file.close(fd) do
      :ok
    else
      {:error, why} -> {:error, "file-sync-failed-#{inspect(why)}"}
    end
  end

  @doc """
  Put a backup back, durably: copy over the store, sync the file and the
  directory, then re-open the store read-only and prove it holds a state.

  For the case the report names: a failure after the mutation began. The
  backup is the store exactly as the newer runtime last wrote it.
  """
  def restore(world, backup) when is_binary(world) and is_binary(backup) do
    with_data_dir(world, fn ->
      with true <- File.exists?(backup) or {:error, "backup-absent"},
           :ok <- lock_free(world, :probe),
           :ok <- copy_into(backup, store(world)),
           :ok <- sync_file(store(world)),
           :ok <- sync_dir(world),
           {:ok, s} <- read_state(world) do
        {:ok, %{"restored_from" => backup, "attempts" => map_size(s["development_attempts"])}}
      else
        {:error, why} ->
          {:refused, %{"refusal" => to_string(why), "restored_from" => backup}}

        {:refused, why, detail} ->
          {:refused, Map.merge(detail, %{"refusal" => why, "restored_from" => backup})}
      end
    end)
  end

  defp sync_dir(dir) do
    trace(:sync_dir)

    with {:ok, fd} <- :file.open(String.to_charlist(dir), [:read, :raw, :directory]),
         :ok <- :file.sync(fd),
         :ok <- :file.close(fd) do
      :ok
    else
      {:error, why} -> {:error, "directory-sync-failed-#{inspect(why)}"}
    end
  end

  defp with_data_dir(world, fun) do
    before = System.get_env("AMPD_DATA_DIR")
    System.put_env("AMPD_DATA_DIR", world)

    try do
      fun.()
    after
      if before,
        do: System.put_env("AMPD_DATA_DIR", before),
        else: System.delete_env("AMPD_DATA_DIR")
    end
  end

  # ------------------------------------------------------------------ cli

  @doc """
  `mix run --no-start -e 'Ampd.Downgrade.main(System.argv())' -- <world> [--report <file>] [--check] [--lock-held] [--restore <backup>]`

  Prints the report as JSON. Exit 0 when written and verified, 2 when refused,
  3 on a bad invocation. `--check` runs the preflight only and writes nothing.
  `--lock-held` is passed by `tools/downgrade-world.sh`, which holds the
  world's `flock(2)` around the whole run; without it the lock is probed.
  """
  def main(argv) do
    {opts, args, _} =
      OptionParser.parse(argv,
        strict: [report: :string, check: :boolean, lock_held: :boolean, restore: :string]
      )

    case args do
      [world] ->
        result =
          cond do
            opts[:restore] -> restore(Path.expand(world), Path.expand(opts[:restore]))
            opts[:check] -> check(Path.expand(world))
            true -> run(Path.expand(world), lock: if(opts[:lock_held], do: :held, else: :probe))
          end

        {status, report} = result
        json = JSON.encode!(report)
        IO.puts(json)
        if opts[:report], do: File.write!(opts[:report], json <> "\n")
        halt(if status == :ok, do: 0, else: 2)

      _ ->
        IO.puts(:stderr, "usage: <world-dir> [--report <file>] [--check]")
        halt(3)
    end
  end

  @doc "Preflight a world directory without writing. `{:ok | :refused, report}`."
  def check(world) when is_binary(world) do
    with_data_dir(world, fn ->
      with :ok <- manifest_trusted(),
           {:ok, s} <- read_state(world) do
        {_, report} = preflight(s)
        report = Map.put(report, "written", false)
        if report["downgradable"], do: {:ok, report}, else: {:refused, report}
      else
        {:refused, refusal, report} ->
          {:refused, Map.merge(report, %{"written" => false, "refusal" => refusal})}
      end
    end)
  end

  defp halt(code) do
    if Process.get(:ampd_downgrade_no_halt), do: code, else: System.halt(code)
  end
end
