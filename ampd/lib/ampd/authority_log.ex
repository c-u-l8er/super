defmodule Ampd.AuthorityLog do
  @moduledoc """
  The durable form of the effect path's authority stores: **one framed,
  append-only log per world**, `<data_dir>/authority.log`.

  ## Why this replaced a DETS table per store

  `Ampd.Store.save/2` rewrote a registry's whole state into its own DETS
  table on every transition, and each DETS save is two syncs. Measured
  through `Gateway.perform` (`wek/b2/trvm/RESIDENT_TIMING.md` §7): 7 whole-
  state saves and 25 sync requests per effect, 185 KB written at an empty
  journal and 29.9 MB with 2,000 effects retained. Worse, a SIGKILL between
  a save's insert and its sync leaves the table `needs_repair`, and a
  damaged authority table seals the world — measured through Super itself
  (`evidence/kill-battery/`): 15 of 36 random kills on ext4 and 29 of 36 on
  tmpfs ended the world, 6 of them with a runtime that would not start.

  ## What is here instead

  * **One writer** (this process), **one file**, frames of
    `<<len::32, crc32::32, payload::binary>>` after a fixed header. A payload
    is one record: `%{"t" => tseq, "ops" => [op]}`, `tseq` gapless from 1.
  * **One record per durable point, one `fdatasync` per record.** A record
    carries only what changed (`Ampd.AuthorityLog.Delta`), so the bytes
    written no longer grow with history.
  * **One record per transaction where a transaction spans stores.**
    `group/1` makes everything the calling process's transaction writes —
    through any of the four registries — one record, so `claim_and_consume`
    is durable whole or not at all. Writes the transaction did not cause
    (another effect's attempt or commit, running concurrently) are never
    held back: they are written and synced before their caller is answered,
    exactly as before.
  * **This process holds the replayed image** of every store it backs; a
    registry that boots or reopens reads its state from here.

  ## Recovery, and what seals

      a bad LAST frame                       a torn write nobody was answered for:
                                             truncated, and NAMED by a durable
                                             `recovered` record (see `status/0`)
      a bad frame with bytes after it        corruption: every store here seals
      a tseq gap, an unreadable header       corruption: every store here seals

  A store the log has never held is ABSENT, and `Ampd.World` decides whether
  that means fresh or lost — this module never interprets absence itself.

  ## Checkpoints

  Every `checkpoint_every/0` records (10,000 by default) the active log is
  sealed as `authority.log.sealed-<t>` and a new one begun, and the image at
  `t` is written apart from this process to `authority.checkpoint` (one
  frame: the image, its SHA-256, the recoveries named so far; temp file,
  sync, rename). Once it is durable the segments it covers are deleted. Boot
  is the checkpoint, then any sealed segment after it (a crash between the
  seal and the checkpoint), then the active log. A checkpoint that does not
  verify seals like a bad frame does; a torn tail can only be the active
  log's. A world reset waits for a running snapshot, so an old world's
  checkpoint can never be renamed into a new world's directory.

  ## Retention: the archive

  Completed work leaves the working lists (`Ampd.Retention`), and what leaves
  is kept here first: `authority.archive`, append-only, the same frames as the
  log (`<<len::32, crc32::32, payload>>` after its own header), one frame per
  retirement batch — `%{"b" => n, "rows" => %{store => [row]}}`, `n` gapless
  from 1. This process appends and syncs a batch BEFORE the record that
  removes those rows from the working lists, so a row is always in one or
  the other: a crash between leaves an orphan batch whose rows are still
  live, and the next pass archives them again. Each store keeps a compact
  index of what it retired (id → final status, batch) in its own state, so
  the index is carried by this log and its checkpoints; the archive holds the
  rows and is never covered or deleted by a checkpoint.

  Boot reads only the frame headers. A torn LAST frame (short, or a bad
  checksum with nothing after it) is an unacknowledged batch — no retirement
  record can name it, because the record is written after the sync — so it is
  truncated and named like a torn log tail. A frame that does not verify when
  it is READ is named in the reader's answer; it never seals the authority
  stores, whose decisions read the index, not the archive.

  Readers read the file themselves, by the offsets this process hands out,
  so a history read never holds up an append.

  **Each retired row's index entry also commits a digest of the row**
  (`Ampd.AuthorityLog.RowDigest`), taken by the retiring store from its
  working row and written in the same record, and every reader checks the
  rows it returns against it (`archived_row/5`, `check_batch/6`,
  `archived_rows/3`). The CRC catches an accident; the digest catches an
  archive that holds something other than what the log retired, including a
  frame rewritten with a valid CRC.

  ## Worlds written before this

  World `schema_version` 3 is this layout. A version-2 world is converted
  once, at boot, by `Ampd.AuthorityLog.Migration`.

  The witness log (`Ampd.Effects.Witness`, `wek-r3-trace@3`) is unchanged
  and separate. Whether an authority record may *be* the witness line is
  WEK's decision, not this module's.
  """
  use GenServer
  require Logger

  alias Ampd.AuthorityLog.{Delta, RowDigest}

  @stores ~w(effects receipts grant_registry approvals)
  @registries %{
    Ampd.Effects => "effects",
    Ampd.Receipts => "receipts",
    Ampd.GrantRegistry => "grant_registry",
    Ampd.Approvals => "approvals"
  }
  @file_name "authority.log"
  @header "AMPD-AUTHORITY-LOG/1\n"
  @cp_file "authority.checkpoint"
  @cp_header "AMPD-AUTHORITY-CHECKPOINT/1\n"
  @ar_file "authority.archive"
  @ar_header "AMPD-AUTHORITY-ARCHIVE/1\n"
  @group_table :ampd_authority_log_group

  @doc "The stores this log backs. Every other authority store is still a DETS table."
  def stores, do: @stores
  def backed?(name), do: name in @stores
  def path(dir \\ Ampd.Store.data_dir()), do: Path.join(dir, @file_name)
  def checkpoint_path(dir \\ Ampd.Store.data_dir()), do: Path.join(dir, @cp_file)
  def archive_path(dir \\ Ampd.Store.data_dir()), do: Path.join(dir, @ar_file)
  def header, do: @header

  # A log that reached the checkpoint cadence is renamed to this and a new
  # `authority.log` begins; it is deleted once a checkpoint covering it is
  # durable. `t` is the last record it holds.
  defp sealed_path(dir, t), do: Path.join(dir, "#{@file_name}.sealed-#{t}")

  defp sealed_segments(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        for f <- files,
            [_, t] <- [Regex.run(~r/^authority\.log\.sealed-(\d+)$/, f)],
            do: {String.to_integer(t), Path.join(dir, f)}

      _ ->
        []
    end
    |> Enum.sort()
  end

  @doc """
  Records between checkpoints. A checkpoint is the whole image at one record,
  so boot replays at most this many records past it. Super's choice, and a
  setting (`config :ampd, authority_log_checkpoint_every: n`).
  """
  def checkpoint_every, do: Application.get_env(:ampd, :authority_log_checkpoint_every, 10_000)

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  # ------------------------------------------------------------------ API

  # **Every client call crosses through `Ampd.Participant`.** Several are made
  # from inside the total order — a reset seeds and closes the log, a claim
  # opens and commits a transaction — and a bare `GenServer.call` there that
  # exits would take the coordinator down with this process (C1.0b·2·1).
  # Through the participant boundary a dead or stuck log is a typed failure the
  # order survives. Outside the order it is `GenServer.call/3` and nothing else.
  defp call(msg, class), do: Ampd.Participant.call(__MODULE__, msg, class, timeout: 60_000)

  @doc "The durable state of `name`: `{:present, s}`, `:absent`, or `{:damaged, why}`."
  def image(name), do: call({:image, name}, :read)

  @doc """
  Make `ops` durable for `name`. `:ok` once the record is synced; `:pending`
  when it belongs to the open transaction of `origin` (durable at that
  transaction's commit, which `group/1` awaits); `{:error, why}` otherwise.
  """
  def append(name, ops, origin), do: call({:append, name, ops, origin}, :mutate)

  @doc "Close the file and forget the image — a world reset removes the directory under it."
  def close do
    if Process.whereis(__MODULE__), do: call(:close, :mutate), else: :ok
  end

  @doc """
  Stores that exist in this world's log right now (for
  `Ampd.World.stores_on_disk/0`). A damaged log holds all of them: they
  exist, and cannot be trusted. Read offline when this process is not
  running yet — `Ampd.Bootstrap.new_world!/0` asks before the supervision
  tree starts.
  """
  def present(dir) do
    cond do
      not (File.exists?(path(dir)) or File.exists?(checkpoint_path(dir)) or
               sealed_segments(dir) != []) ->
        []

      Process.whereis(__MODULE__) ->
        call({:present, dir}, :read)

      true ->
        case read_all(dir) do
          :fresh -> []
          {:damaged, _} -> @stores
          r -> Map.keys(elem(r, 1))
        end
    end
  end

  @doc """
  The explicit initialization transition for a logged store: its whole
  state, durable. Through this process when it runs; written directly when
  it does not — `Ampd.Bootstrap.new_world!/0` seeds the world from
  `Ampd.Application.start/2`, before the supervision tree exists, and only
  when there is no world yet, so no other writer can be present.
  """
  def seed!(name, s) do
    ops = [{:init, name, s}]

    if Process.whereis(__MODULE__) do
      # Inside a reset this runs in the coordinator; a failure is typed, never a
      # match error that would take the order down.
      case append(name, ops, nil) do
        :ok ->
          :ok

        other ->
          raise Ampd.Participant.Failure.new(:indeterminate, __MODULE__, {:seed, name}, other)
      end
    else
      offline_append!(path(), ops)
    end

    :ok
  end

  defp offline_append!(p, ops) do
    File.mkdir_p!(Path.dirname(p))

    {tseq, size} =
      case File.read(p) do
        {:error, :enoent} ->
          File.write!(p, @header)
          {0, byte_size(@header)}

        {:ok, bin} ->
          case replay(bin) do
            {:ok, _, t, _} -> {t, byte_size(bin)}
            other -> raise "cannot seed the authority log at #{p}: #{inspect(elem(other, 0))}"
          end
      end

    {:ok, fd} = :file.open(p, [:read, :write, :raw, :binary])

    try do
      :ok = :file.pwrite(fd, size, frame(%{"t" => tseq + 1, "ops" => ops}))

      :ok = :file.datasync(fd)
    after
      :file.close(fd)
    end
  end

  @doc """
  Counters and the named recoveries, for measurement and for the operator:
  records and syncs written, bytes, the torn tails this log has truncated,
  and how many transactions had to be split because a concurrent write
  touched the same field (expected: zero).
  """
  def status, do: call(:status, :read)

  # ---------------------------------------------------------------- archive

  @doc """
  Append one retirement batch — `%{store => [row]}` — to the archive and sync
  it. `{:ok, n}` once durable, `{:error, why}` otherwise (nothing then names
  the batch: the caller must not retire its rows).
  """
  def archive(rows) when is_map(rows),
    do: call({:archive, rows}, :mutate)

  @doc "Where batch `n` is: `{:ok, path, offset, length}` or `{:error, why}`."
  def archive_slot(n), do: call({:archive_slot, n}, :read)

  # ------------------------------------------------- reading archived rows
  #
  # **Every archived row a reader is given has been checked against the log.**
  # The frame's CRC-32 says the bytes are what was written; the digest the
  # retiring store committed (`Ampd.AuthorityLog.RowDigest`) says they are the
  # row the log retired. A reader gets one of three answers per row:
  #
  #   verified     the row, as it is
  #   unverified   the row with `"archive_unverified"` set to the reason: it
  #                was retired without a digest. Named, and never upgraded
  #                from what the archive holds
  #   refused      `{:error, "archive-row-mismatch · …"}` (or absent,
  #                duplicate, incomplete): the archive holds something other
  #                than what the log committed
  #
  # **The index decides which batch holds a row, not the archive.** A batch
  # appended and synced whose retirement record never followed (an orphan:
  # the process died between the two) is named by no index entry, so no
  # reader takes a row from it, whatever position it has in the file.
  #
  # A refused read seals nothing. The authority stores decide from their
  # indexes, never from the archive, so a damaged archive loses history
  # reads, and only those.

  @unverified "archive_unverified"

  @doc "The field an unverified archived row carries, holding the reason."
  def unverified_key, do: @unverified

  @doc false
  # The rows of `store` in batch `n` AS THE FILE HOLDS THEM: the frame's CRC
  # and batch number are checked, the rows are NOT. Two callers only, each of
  # which passes every row it keeps through `check_batch/6`: the readers in
  # this module, and the stores' `archived_batch/1`, which must ask their own
  # index which keys batch `n` retired before they can check. A test reads the
  # compiled callers so that stays true (`archive_digest_test.exs`).
  def store_rows(n, store) do
    case archive_slot(n) do
      {:ok, path, off, len} ->
        case read_frame(path, off, len, n) do
          {:ok, rows} -> {:ok, Map.get(rows, store, [])}
          err -> err
        end

      err ->
        err
    end
  end

  @doc """
  One archived row, checked: the row of `store` whose `field` is `key` in
  batch `n`, the batch its retirement index entry names, against `committed`,
  the digest that entry holds (`nil` for a row retired before digests).
  `{:ok, row}` (marked when unverified) or `{:error, why}`.
  """
  def archived_row(n, store, key, field, committed) do
    case store_rows(n, store) do
      {:ok, rows} ->
        case Enum.filter(rows, &(&1[field] == key)) do
          [] -> {:error, "archive-row-absent · #{store} #{key} is not in batch #{n}"}
          [row] -> check_row(n, store, field, key, row, committed)
          _ -> {:error, duplicate(n, store, key)}
        end

      err ->
        err
    end
  end

  @doc """
  The rows of batch `n` that `store`'s index retired there, each checked.

  `entries` maps the keys the index names in batch `n` to their committed
  digests (`nil` for none); `expected` is how many rows of `store` the
  retirement recorded for that batch. A store's retirement is all or
  nothing, so a batch its index names holds exactly the rows it retired
  there. `{:ok, rows}` in archive order, unverified rows marked, or `{:error,
  why}` for a key held twice, a row that was not retired in this batch, a
  batch holding fewer rows than its retirement recorded, or the first row
  that does not match its digest.
  """
  def check_batch(n, store, field, rows, entries, expected) do
    case first_duplicate(Enum.map(rows, & &1[field]), MapSet.new()) do
      {:duplicate, k} ->
        {:error, duplicate(n, store, k)}

      nil ->
        case Enum.find(rows, &(not Map.has_key?(entries, &1[field]))) do
          nil when length(rows) != expected ->
            {:error,
             "archive-batch-incomplete · batch #{n} holds #{length(rows)} of the #{expected} " <>
               "#{store} rows its retirement recorded"}

          nil ->
            check_rows(n, store, field, rows, entries)

          r ->
            {:error,
             "archive-row-unretired · #{store} #{r[field]} is in batch #{n} but was not retired there"}
        end
    end
  end

  defp check_rows(n, store, field, rows, entries) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      k = row[field]

      case check_row(n, store, field, k, row, Map.fetch!(entries, k)) do
        {:ok, r} -> {:cont, {:ok, [r | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  @doc """
  Every archived row of `store`, oldest batch first, each read from the batch
  its index entry names and checked. `index` maps a key to `{batch,
  committed}`, the store's whole retirement index: this reads every batch it
  names, so it is for tools and tests, never for a decision or a page.
  `{:ok, rows}` or `{:error, why}` at the first batch that does not check,
  including one that lacks a row its index names.
  """
  def archived_rows(store, field, index) do
    index
    |> Enum.group_by(fn {_k, {n, _}} -> n end, fn {k, {_n, d}} -> {k, d} end)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {n, named}, {:ok, acc} ->
      entries = Map.new(named)

      case store_rows(n, store) do
        {:ok, rows} ->
          case check_batch(n, store, field, rows, entries, map_size(entries)) do
            {:ok, got} -> {:cont, {:ok, [got | acc]}}
            err -> {:halt, err}
          end

        err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, per_batch} -> {:ok, per_batch |> Enum.reverse() |> Enum.concat()}
      err -> err
    end
  end

  defp check_row(n, store, field, key, row, committed) do
    case RowDigest.check(store, field, key, n, row, committed) do
      :verified -> {:ok, row}
      {:unverified, why} -> {:ok, Map.put(row, @unverified, why)}
      {:mismatch, why} -> {:error, why}
    end
  end

  defp duplicate(n, store, key),
    do: "archive-row-duplicate · #{store} #{key} appears more than once in batch #{n}"

  defp first_duplicate([], _seen), do: nil

  defp first_duplicate([k | more], seen) do
    if MapSet.member?(seen, k),
      do: {:duplicate, k},
      else: first_duplicate(more, MapSet.put(seen, k))
  end

  defp read_frame(path, off, len, n) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, fd} ->
        try do
          verify_frame(:file.pread(fd, off, len), n)
        after
          :file.close(fd)
        end

      {:error, why} ->
        {:error, "archive-unreadable · #{inspect(why)}"}
    end
  end

  defp verify_frame({:ok, <<plen::32, crc::32, payload::binary-size(plen)>>}, n) do
    if :erlang.crc32(payload) != crc do
      {:error, "archive-unreadable · batch #{n} does not verify (checksum)"}
    else
      case decode(payload) do
        {:ok, %{"b" => ^n, "rows" => rows}} -> {:ok, rows}
        _ -> {:error, "archive-unreadable · batch #{n} is not the batch it claims"}
      end
    end
  end

  defp verify_frame(_, n), do: {:error, "archive-unreadable · batch #{n} is incomplete"}

  # ----------------------------------------------------------- transactions

  @doc """
  Run `fun` as ONE durable record: every registry write it causes, in any of
  the four stores, is held and written together when it returns, synced once.

  The caller's answer comes after the commit, so nothing inside was
  acknowledged before it was durable. `Ampd.Effects` holds the witness lines
  of those writes until the commit too (a witness line follows the fact it
  witnesses), and writes them when `group/1` tells it to.

  Re-entrant. A commit that fails kills the four registries, so each
  restarts from what is actually durable rather than from memory that got
  ahead of the disk.
  """
  def group(fun) do
    cond do
      Process.whereis(__MODULE__) == nil ->
        fun.()

      group_owner() == self() ->
        fun.()

      true ->
        case call({:open_group, self()}, :mutate) do
          :ok ->
            :ok

          other ->
            raise Ampd.Participant.Failure.new(:not_applied, __MODULE__, :open_group, other)
        end

        try do
          fun.()
        after
          case call({:commit_group, self()}, :mutate) do
            :ok ->
              if Process.whereis(Ampd.Effects), do: Ampd.Effects.flush_deferred()

            {:error, why} ->
              Enum.each(Map.keys(@registries), fn mod ->
                if pid = Process.whereis(mod), do: Process.exit(pid, :kill)
              end)

              # Typed, so the order that called this survives it: the registries
              # restart from what is durable, and the transaction's outcome is
              # not known to the caller.
              raise Ampd.Participant.Failure.new(:indeterminate, __MODULE__, :commit_group, why)
          end
        end
    end
  end

  @doc "The process whose transaction is open, or nil."
  def group_owner do
    case :ets.whereis(@group_table) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(@group_table, :owner) do
          [{:owner, pid}] -> pid
          _ -> nil
        end
    end
  end

  @doc "Who a registry is serving: the transaction origin carried on the call, or this process."
  def origin, do: Process.get(:ampd_origin) || self()

  @doc "Is the current work part of the open transaction?"
  def member? do
    case group_owner() do
      nil -> false
      owner -> origin() == owner
    end
  end

  @doc """
  The message to send `server`: wrapped with the transaction's origin when the
  sender is working for the open transaction and `server` is one of the four
  registries; unchanged otherwise.
  """
  def wrap(server, msg) do
    if Map.has_key?(@registries, server) and member?(),
      do: {:"$alog_origin", origin(), msg},
      else: msg
  end

  @doc "Serve `fun` on behalf of `origin` (the registries' unwrapping clause)."
  def as_member(origin, fun) do
    prev = Process.put(:ampd_origin, origin)

    try do
      fun.()
    after
      if prev, do: Process.put(:ampd_origin, prev), else: Process.delete(:ampd_origin)
    end
  end

  # ---------------------------------------------------------------- server

  @impl true
  def init(:ok) do
    :ets.new(@group_table, [:named_table, :public, read_concurrency: true])
    :ets.insert(@group_table, {:owner, nil})
    {:ok, closed()}
  end

  defp closed,
    do: %{
      dir: nil,
      fd: nil,
      size: 0,
      tseq: 0,
      images: %{},
      damaged: nil,
      recovered: [],
      group: nil,
      # The checkpoint: the record it covers, the one being written (a
      # snapshot writer runs apart from this process), and a generation that
      # tells a writer's report from an older world's apart.
      cp_t: 0,
      cp_running: nil,
      cp_last: nil,
      cp_retry_at: 0,
      gen: nil,
      # The archive: its handle, size, batch count and where each batch is.
      ar_fd: nil,
      ar_size: 0,
      ar_n: 0,
      ar_slots: %{},
      ar_damaged: nil,
      counters: %{
        "records" => 0,
        "archive_batches" => 0,
        # Batch lookups by readers: how many archive batches pages and
        # by-id reads asked for, so "a page reads only what it needs" is
        # measured, not assumed.
        "archive_batch_reads" => 0,
        "archive_bytes" => 0,
        "archive_sync_us_total" => 0,
        "syncs" => 0,
        "bytes" => 0,
        "grouped_records" => 0,
        "group_splits" => 0,
        "checkpoints" => 0,
        # Each datasync's own duration: the total, the slowest, and a log2
        # histogram in microseconds (bucket b counts syncs of 2^(b-1)..2^b µs).
        # So a latency that grows can be attributed to the device, or ruled out.
        "sync_us_total" => 0,
        "sync_us_max" => 0,
        "sync_us_hist" => %{}
      }
    }

  @impl true
  def handle_call(:close, _f, st) do
    st = if st.group, do: commit_group(st), else: st

    # A world reset removes this directory and makes a new world at the same
    # path. A snapshot writer still running would then rename an OLD world's
    # checkpoint into the NEW world. So its report is awaited here.
    st = await_checkpoint(st)
    if st.fd, do: :file.close(st.fd)
    if st.ar_fd, do: :file.close(st.ar_fd)
    {:reply, :ok, %{closed() | counters: st.counters}}
  end

  def handle_call({:present, dir}, _f, st) do
    st = ensure_open(st, dir)
    {:reply, if(st.damaged, do: @stores, else: Map.keys(st.images)), st}
  end

  def handle_call(:status, _f, st) do
    st = ensure_open(st)

    {:reply,
     Map.merge(st.counters, %{
       "checkpoint_t" => st.cp_t,
       "checkpoint_running" => st.cp_running,
       "checkpoint_last" => st.cp_last,
       "sealed_segments" => st.dir && length(sealed_segments(st.dir)),
       "path" => st.dir && path(st.dir),
       "tseq" => st.tseq,
       "size" => st.size,
       "damaged" => st.damaged,
       "recovered" => Enum.reverse(st.recovered),
       "stores" => Map.keys(st.images),
       "group_open" => st.group != nil,
       "archive_path" => st.dir && archive_path(st.dir),
       "archive_size" => st.ar_size,
       "archive_batches_present" => st.ar_n,
       "archive_damaged" => st.ar_damaged
     }), st}
  end

  def handle_call({:image, name}, _f, st) do
    st = ensure_open(st)

    # A registry that reopens while the open transaction holds writes for it
    # (it crashed and restarted mid-transaction) must read those writes, or
    # its memory and the disk part at the commit. Commit what is held first.
    st =
      if st.group && MapSet.member?(st.group.stores, name),
        do: flush_group(st, "group_splits"),
        else: st

    reply =
      cond do
        st.damaged -> {:damaged, st.damaged}
        img = st.images[name] -> {:present, Delta.materialize(img)}
        true -> :absent
      end

    {:reply, reply, st}
  end

  def handle_call({:append, name, ops, origin}, _f, st) do
    st = ensure_open(st)

    cond do
      st.damaged ->
        {:reply, {:error, {:damaged, st.damaged}}, st}

      # A delta needs the state it is a delta of. A store the log does not
      # hold can only begin with its whole state; anything else would build a
      # partial store out of fragments — authority nobody initialized.
      not based?(st, name, ops) ->
        {:reply, {:error, {:absent, name}}, st}

      st.group != nil and origin != nil and origin == st.group.owner ->
        g = st.group

        g = %{
          g
          | ops: [ops | g.ops],
            stores: MapSet.put(g.stores, name),
            keys: Delta.keys(ops, g.keys)
        }

        {:reply, :pending, %{st | group: g}}

      true ->
        # A write the transaction did not cause. If it touches something the
        # transaction has already changed, the transaction's record must reach
        # the disk first, or replay would apply them in the wrong order.
        st =
          if st.group != nil and Delta.conflicts?(ops, st.group.keys),
            do: flush_group(st, "group_splits"),
            else: st

        case write_record(st, %{"ops" => ops}) do
          {:ok, st} -> {:reply, :ok, st}
          {:error, why, st} -> {:reply, {:error, why}, st}
        end
    end
  end

  def handle_call({:archive, rows}, _f, st) do
    st = ensure_open(st)

    cond do
      st.damaged ->
        {:reply, {:error, {:damaged, st.damaged}}, st}

      st.ar_damaged ->
        {:reply, {:error, {:archive_damaged, st.ar_damaged}}, st}

      true ->
        st = ensure_archive(st)
        n = st.ar_n + 1
        fr = frame(%{"b" => n, "rows" => rows})
        len = IO.iodata_length(fr)

        with :ok <- :file.pwrite(st.ar_fd, st.ar_size, fr),
             {:ok, us} <- timed_datasync(st.ar_fd) do
          c = st.counters

          {:reply, {:ok, n},
           %{
             st
             | ar_n: n,
               ar_size: st.ar_size + len,
               ar_slots: Map.put(st.ar_slots, n, {st.ar_size, len}),
               counters: %{
                 c
                 | "archive_batches" => c["archive_batches"] + 1,
                   "archive_bytes" => c["archive_bytes"] + len,
                   "archive_sync_us_total" => c["archive_sync_us_total"] + us
               }
           }}
        else
          {:error, why} ->
            # Take back whatever part reached the file, as for the log.
            case :file.position(st.ar_fd, st.ar_size) do
              {:ok, _} ->
                _ = :file.truncate(st.ar_fd)
                {:reply, {:error, why}, st}

              _ ->
                {:reply, {:error, why},
                 %{st | ar_damaged: "a failed archive write could not be taken back"}}
            end
        end
    end
  end

  def handle_call({:archive_slot, n}, _f, st) do
    st = ensure_open(st)

    reply =
      case Map.get(st.ar_slots, n) do
        {off, len} -> {:ok, archive_path(st.dir), off, len}
        nil -> {:error, "archive-unreadable · no batch #{n} in this world's archive"}
      end

    {:reply, reply, bump(st, "archive_batch_reads")}
  end

  def handle_call(:archive_slots, _f, st) do
    st = ensure_open(st)

    slots =
      st.ar_slots |> Enum.sort() |> Enum.map(fn {n, {off, len}} -> {n, off, len} end)

    {:reply, {:ok, archive_path(st.dir), slots}, st}
  end

  def handle_call({:open_group, owner}, _f, st) do
    st = ensure_open(st)

    cond do
      st.group != nil and st.group.owner != owner ->
        {:reply, {:error, :group_open}, st}

      true ->
        :ets.insert(@group_table, {:owner, owner})

        {:reply, :ok,
         %{st | group: %{owner: owner, ops: [], stores: MapSet.new(), keys: Delta.no_keys()}}}
    end
  end

  def handle_call({:commit_group, owner}, _f, %{group: %{owner: owner}} = st) do
    :ets.insert(@group_table, {:owner, nil})

    case flush_group(st, "grouped_records") do
      %{damaged: nil} = st -> {:reply, :ok, %{st | group: nil}}
      st -> {:reply, {:error, {:damaged, st.damaged}}, %{st | group: nil}}
    end
  end

  def handle_call({:commit_group, _owner}, _f, st), do: {:reply, :ok, st}

  # ------------------------------------------------------------- internals

  defp based?(st, name, ops) do
    Map.has_key?(st.images, name) or match?([{:init, ^name, _} | _], ops) or
      (st.group != nil and
         Enum.any?(st.group.ops, fn held -> Enum.any?(held, &match?({:init, ^name, _}, &1)) end))
  end

  defp commit_group(st) do
    :ets.insert(@group_table, {:owner, nil})
    %{flush_group(st, "grouped_records") | group: nil}
  end

  # Write what the open transaction holds as one record, and keep the group
  # open (empty). `counter` names why: its commit, or a forced split.
  defp flush_group(%{group: %{ops: []}} = st, _counter), do: st

  defp flush_group(%{group: g} = st, counter) do
    ops = g.ops |> Enum.reverse() |> Enum.concat()

    case write_record(st, %{"ops" => ops}) do
      {:ok, st} ->
        st = bump(st, counter)
        %{st | group: %{g | ops: [], keys: Delta.no_keys()}}

      {:error, why, st} ->
        %{st | damaged: st.damaged || "authority log write failed: #{inspect(why)}"}
    end
  end

  defp bump(st, k), do: %{st | counters: Map.update!(st.counters, k, &(&1 + 1))}

  defp ensure_open(st, dir \\ Ampd.Store.data_dir()) do
    if st.dir == dir,
      do: st,
      else: load(%{closed() | counters: st.counters}, dir) |> load_archive()
  end

  # Load the checkpoint, replay what follows it (sealed segments, then the
  # active log), truncate a torn last frame of the ACTIVE log and name it, and
  # position for the next append.
  defp load(st, dir) do
    File.mkdir_p!(dir)
    p = path(dir)
    st = %{st | dir: dir, gen: make_ref()}
    # A snapshot a crash cut short, never renamed into place: not a checkpoint.
    File.rm(checkpoint_path(dir) <> ".tmp")

    case read_all(dir) do
      :fresh ->
        create(st, p)

      {:ok, images, tseq, recovered, cp_t, active_size} ->
        st = %{st | images: compact(images), tseq: tseq, recovered: recovered, cp_t: cp_t}
        st = if active_size, do: open_for_append(st, p, active_size), else: create(st, p)
        drop_covered(st)

      {:torn, images, tseq, recovered, cp_t, good, total, reason} ->
        st = %{st | images: compact(images), tseq: tseq, recovered: recovered, cp_t: cp_t}

        # Not even the header survived: start the file again.
        st =
          if good < byte_size(@header),
            do: create(st, p),
            else: open_for_append(st, p, good)

        :ok = :file.truncate(st.fd)
        :ok = :file.datasync(st.fd)
        torn = total - good

        event = %{
          "torn_tail_bytes" => torn,
          "at_offset" => good,
          "reason" => reason,
          "at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        Logger.warning(
          "ampd: authority log had a torn last record (#{torn} bytes at offset #{good}, " <>
            "#{reason}) — a write nobody was answered for; truncated and recorded"
        )

        case write_record(drop_covered(st), %{"ops" => [], "recovered" => event}) do
          {:ok, st} ->
            %{st | recovered: [event | st.recovered]}

          {:error, why, st} ->
            %{st | damaged: "authority log: recording a torn tail failed: #{inspect(why)}"}
        end

      {:damaged, why} ->
        Logger.error("ampd: authority log is untrusted — #{why}; every store it backs is sealed")
        %{st | damaged: "authority log: " <> why}
    end
  end

  defp compact(images), do: Map.new(images, fn {n, img} -> {n, Delta.compact(img)} end)

  # The archive at boot: its frame headers only — where each batch is — with
  # the LAST frame verified, because a torn write can only be the last one.
  defp load_archive(%{dir: dir} = st) do
    p = archive_path(dir)

    case File.stat(p) do
      {:error, :enoent} ->
        st

      {:ok, %{size: size}} ->
        {:ok, fd} = :file.open(p, [:read, :write, :raw, :binary])
        st = %{st | ar_fd: fd}
        hs = byte_size(@ar_header)

        cond do
          size < hs ->
            torn_archive(st, 0, size, 1, %{}, "partial header")

          true ->
            case :file.pread(fd, 0, hs) do
              {:ok, @ar_header} ->
                scan_archive(st, hs, size, 1, %{})

              _ ->
                %{st | ar_size: size, ar_damaged: "the archive does not begin with its header"}
            end
        end
    end
  end

  defp scan_archive(st, off, size, n, slots) when off == size,
    do: %{st | ar_size: size, ar_n: n - 1, ar_slots: slots}

  defp scan_archive(st, off, size, n, slots) when size - off < 8,
    do: torn_archive(st, off, size, n, slots, "partial frame header")

  defp scan_archive(st, off, size, n, slots) do
    {:ok, <<len::32, crc::32>>} = :file.pread(st.ar_fd, off, 8)
    next = off + 8 + len

    cond do
      next > size ->
        torn_archive(st, off, size, n, slots, "frame declares #{len} bytes, #{size - off - 8} present")

      next == size ->
        case :file.pread(st.ar_fd, off + 8, len) do
          {:ok, payload} when byte_size(payload) == len ->
            if :erlang.crc32(payload) == crc,
              do: scan_archive(st, next, size, n + 1, Map.put(slots, n, {off, 8 + len})),
              else: torn_archive(st, off, size, n, slots, "checksum mismatch on the last frame")

          _ ->
            torn_archive(st, off, size, n, slots, "the last frame cannot be read whole")
        end

      true ->
        scan_archive(st, next, size, n + 1, Map.put(slots, n, {off, 8 + len}))
    end
  end

  # An unacknowledged batch: its retirement record is written only after the
  # batch is synced, so nothing can name it. Truncated, and named by a durable
  # `recovered` record exactly as a torn log tail is.
  defp torn_archive(st, off, size, n, slots, reason) do
    hs = byte_size(@ar_header)

    st =
      if off < hs do
        {:ok, _} = :file.position(st.ar_fd, 0)
        :ok = :file.truncate(st.ar_fd)
        :ok = :file.pwrite(st.ar_fd, 0, @ar_header)
        %{st | ar_size: hs}
      else
        {:ok, _} = :file.position(st.ar_fd, off)
        :ok = :file.truncate(st.ar_fd)
        %{st | ar_size: off}
      end

    :ok = :file.datasync(st.ar_fd)
    st = %{st | ar_n: n - 1, ar_slots: slots}

    event = %{
      "archive_torn_tail_bytes" => size - off,
      "at_offset" => off,
      "reason" => reason,
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Logger.warning(
      "ampd: authority archive had a torn last batch (#{size - off} bytes at offset #{off}, " <>
        "#{reason}) — a batch no retirement record named; truncated and recorded"
    )

    if st.damaged == nil and st.fd != nil do
      case write_record(st, %{"ops" => [], "recovered" => event}) do
        {:ok, st} -> %{st | recovered: [event | st.recovered]}
        {:error, _why, st} -> %{st | recovered: [event | st.recovered]}
      end
    else
      %{st | recovered: [event | st.recovered]}
    end
  end

  defp ensure_archive(%{ar_fd: nil, dir: dir} = st) do
    {:ok, fd} = :file.open(archive_path(dir), [:read, :write, :raw, :binary])
    :ok = :file.pwrite(fd, 0, @ar_header)
    {:ok, _} = :file.position(fd, byte_size(@ar_header))
    :ok = :file.truncate(fd)
    :ok = :file.datasync(fd)
    %{st | ar_fd: fd, ar_size: byte_size(@ar_header), ar_n: 0, ar_slots: %{}}
  end

  defp ensure_archive(st), do: st

  @doc false
  # Everything durable in `dir`, without writing: the checkpoint, the sealed
  # segments after it, the active log. `:fresh`, `{:damaged, why}`,
  # `{:ok, images, tseq, recovered, checkpoint_t, active_size | nil}`, or
  # `{:torn, images, tseq, recovered, checkpoint_t, good, total, why}` — a torn
  # tail is only ever the ACTIVE log's: a sealed segment was complete when it
  # was sealed, so one that is not is corruption.
  def read_all(dir) do
    sealed = sealed_segments(dir)

    with {:ok, cp_t, images, rec} <- read_checkpoint(dir),
         {:ok, images, tseq, rec} <-
           replay_sealed(Enum.filter(sealed, fn {t, _} -> t > cp_t end), cp_t, images, rec) do
      case File.read(path(dir)) do
        {:error, :enoent} when cp_t == 0 and sealed == [] ->
          :fresh

        {:error, :enoent} ->
          {:ok, images, tseq, rec, cp_t, nil}

        {:ok, bin} ->
          case replay_from(bin, tseq, images, rec) do
            {:ok, images, tseq, rec} ->
              {:ok, images, tseq, rec, cp_t, byte_size(bin)}

            {:torn, images, tseq, rec, off, why} ->
              {:torn, images, tseq, rec, cp_t, off, byte_size(bin), why}

            {:damaged, why} ->
              {:damaged, why}
          end
      end
    end
  end

  defp replay_sealed([], tseq, images, rec), do: {:ok, images, tseq, rec}

  defp replay_sealed([{_t, p} | more], tseq, images, rec) do
    case replay_from(File.read!(p), tseq, images, rec) do
      {:ok, images, tseq, rec} ->
        replay_sealed(more, tseq, images, rec)

      {:torn, _, _, _, off, why} ->
        {:damaged, "sealed segment #{Path.basename(p)} is incomplete at offset #{off} (#{why})"}

      {:damaged, why} ->
        {:damaged, "sealed segment #{Path.basename(p)}: #{why}"}
    end
  end

  # ------------------------------------------------------------ checkpoints
  #
  # At the cadence the active log is sealed (renamed) and a new one begun —
  # cheap, and done here — and the image at that record is handed to a
  # snapshot writer apart from this process, so appends do not wait for it.
  # Once the checkpoint is durable, the segments it covers are deleted.

  defp maybe_checkpoint(st) do
    if st.cp_running == nil and st.group == nil and st.damaged == nil and
         st.tseq - st.cp_t >= checkpoint_every() and st.tseq >= st.cp_retry_at,
       do: rotate(st),
       else: st
  end

  defp rotate(%{dir: dir, tseq: t} = st) do
    :ok = :file.close(st.fd)

    case File.rename(path(dir), sealed_path(dir, t)) do
      :ok ->
        st = create(%{st | fd: nil}, path(dir))
        owner = self()
        gen = st.gen
        images = st.images
        rec = st.recovered
        spawn(fn -> send(owner, {:checkpoint, gen, t, write_checkpoint(dir, t, images, rec)}) end)
        %{st | cp_running: t}

      {:error, why} ->
        Logger.warning(
          "ampd: authority log could not be sealed for a checkpoint: #{inspect(why)}"
        )

        retry_later(open_for_append(%{st | fd: nil}, path(dir), st.size))
    end
  end

  defp retry_later(st), do: %{st | cp_retry_at: st.tseq + max(1, div(checkpoint_every(), 10))}

  # The snapshot, timed by phase so a slow log sync can be lined up against a
  # running write: serializing the image, writing it, syncing it, renaming it.
  # With `:authority_log_checkpoint_chunk_bytes` set, it is written in chunks of
  # that size with a datasync after each, which bounds how much of its dirty
  # data any one of the log's own datasyncs can be made to wait behind in the
  # filesystem's journal. Unset (the default), it is one write and one sync.
  defp write_checkpoint(dir, t, images, rec) do
    t0 = now_us()
    bin = :erlang.term_to_binary(images)

    cp = %{
      "t" => t,
      "images" => bin,
      "sha256" => Base.encode16(:crypto.hash(:sha256, bin), case: :lower),
      "recovered" => rec
    }

    data = IO.iodata_to_binary([@cp_header | frame(cp)])
    t1 = now_us()
    tmp = checkpoint_path(dir) <> ".tmp"
    chunk = Application.get_env(:ampd, :authority_log_checkpoint_chunk_bytes)

    with {:ok, fd} <- :file.open(tmp, [:write, :raw, :binary]),
         {:ok, write_us, sync_us} <- write_synced(fd, data, chunk, 0, 0, 0),
         :ok <- :file.close(fd),
         t2 = now_us(),
         :ok <- File.rename(tmp, checkpoint_path(dir)) do
      t3 = now_us()

      {:ok,
       %{
         "t" => t,
         "bytes" => byte_size(data),
         "chunk_bytes" => chunk,
         "serialize_us" => t1 - t0,
         "write_us" => write_us,
         "sync_us" => sync_us,
         "rename_us" => t3 - t2,
         "total_us" => t3 - t0,
         "started_at_tseq" => t
       }}
    else
      {:error, why} -> {:error, why}
    end
  end

  defp write_synced(fd, data, chunk, off, w, s) when is_integer(chunk) and chunk > 0 do
    if off >= byte_size(data) do
      {:ok, w, s}
    else
      n = min(chunk, byte_size(data) - off)
      a = now_us()

      with :ok <- :file.write(fd, binary_part(data, off, n)),
           b = now_us(),
           :ok <- :file.datasync(fd) do
        write_synced(fd, data, chunk, off + n, w + (b - a), s + (now_us() - b))
      end
    end
  end

  defp write_synced(fd, data, _whole, _off, _w, _s) do
    a = now_us()

    with :ok <- :file.write(fd, data),
         b = now_us(),
         :ok <- :file.datasync(fd) do
      {:ok, b - a, now_us() - b}
    end
  end

  defp now_us, do: System.monotonic_time(:microsecond)

  defp read_checkpoint(dir) do
    case File.read(checkpoint_path(dir)) do
      {:error, :enoent} ->
        {:ok, 0, %{}, []}

      {:ok, <<@cp_header, len::32, crc::32, payload::binary-size(len)>>} ->
        # Nested cases, not `with … else`: its else compiles to a closure, and
        # this is reachable inside the order (`present/1`, read offline).
        bad = {:damaged, "the checkpoint does not verify (checksum or digest)"}

        if :erlang.crc32(payload) != crc do
          bad
        else
          case decode(payload) do
            {:ok, %{"t" => t, "images" => bin, "sha256" => sha} = cp} ->
              if Base.encode16(:crypto.hash(:sha256, bin), case: :lower) == sha do
                case decode(bin) do
                  {:ok, images} -> {:ok, t, images, cp["recovered"] || []}
                  _ -> bad
                end
              else
                bad
              end

            _ ->
              bad
          end
        end

      {:ok, _} ->
        {:damaged, "the checkpoint is not a whole checkpoint file"}

      {:error, why} ->
        {:damaged, "the checkpoint cannot be read: #{inspect(why)}"}
    end
  end

  defp checkpoint_done(%{gen: gen} = st, gen, t, {:ok, info}) do
    st = %{st | cp_running: nil, cp_t: t, cp_last: Map.put(info, "finished_at_tseq", st.tseq)}
    bump(drop_covered(st), "checkpoints")
  end

  defp checkpoint_done(%{gen: gen} = st, gen, t, {:error, why}) do
    Logger.warning(
      "ampd: authority log checkpoint at #{t} failed: #{inspect(why)}; retrying later"
    )

    retry_later(%{st | cp_running: nil})
  end

  defp checkpoint_done(st, _other_gen, _t, _result), do: st

  defp drop_covered(%{dir: dir, cp_t: cp_t} = st) do
    for {t, p} <- sealed_segments(dir), t <= cp_t, do: File.rm(p)
    st
  end

  defp await_checkpoint(%{cp_running: nil} = st), do: st

  defp await_checkpoint(%{gen: gen} = st) do
    receive do
      {:checkpoint, ^gen, t, result} -> checkpoint_done(st, gen, t, result)
    after
      120_000 ->
        Logger.error("ampd: an authority log checkpoint did not report within 120 s")
        st
    end
  end

  @impl true
  def handle_info({:checkpoint, gen, t, result}, st),
    do: {:noreply, checkpoint_done(st, gen, t, result)}

  defp create(st, p) do
    {:ok, fd} = :file.open(p, [:read, :write, :raw, :binary])
    :ok = :file.pwrite(fd, 0, @header)
    {:ok, _} = :file.position(fd, byte_size(@header))
    :ok = :file.truncate(fd)
    :ok = :file.datasync(fd)
    %{st | fd: fd, size: byte_size(@header)}
  end

  defp open_for_append(st, p, size) do
    {:ok, fd} = :file.open(p, [:read, :write, :raw, :binary])
    {:ok, _} = :file.position(fd, size)
    %{st | fd: fd, size: size}
  end

  defp timed_datasync(fd) do
    t0 = System.monotonic_time(:microsecond)

    case :file.datasync(fd) do
      :ok -> {:ok, System.monotonic_time(:microsecond) - t0}
      err -> err
    end
  end

  defp sync_census(c, us) do
    b = if us <= 1, do: 0, else: ceil(:math.log2(us))

    %{
      c
      | "sync_us_total" => c["sync_us_total"] + us,
        "sync_us_max" => max(c["sync_us_max"], us),
        "sync_us_hist" => Map.update(c["sync_us_hist"], b, 1, &(&1 + 1))
    }
  end

  defp write_record(%{fd: fd, size: size, tseq: tseq} = st, rec) do
    rec = Map.put(rec, "t", tseq + 1)
    frame = frame(rec)
    n = IO.iodata_length(frame)

    with :ok <- :file.pwrite(fd, size, frame),
         {:ok, sync_us} <- timed_datasync(fd) do
      images = Enum.reduce(rec["ops"], st.images, &Delta.apply_op/2)
      c = sync_census(st.counters, sync_us)

      {:ok,
       maybe_checkpoint(%{
         st
         | size: size + n,
           tseq: tseq + 1,
           images: images,
           counters: %{
             c
             | "records" => c["records"] + 1,
               "syncs" => c["syncs"] + 1,
               "bytes" => c["bytes"] + n
           }
       })}
    else
      {:error, why} ->
        # Take back whatever part of the frame reached the file, so the next
        # record does not land after a partial one (which would read as
        # corruption, not as a torn tail). If that fails too, stop writing.
        case :file.position(fd, size) do
          {:ok, _} ->
            _ = :file.truncate(fd)
            {:error, why, st}

          _ ->
            {:error, why,
             %{st | damaged: "authority log: a failed write could not be taken back"}}
        end
    end
  end

  @doc false
  # One record as it is written: the frame header and the payload. Pure.
  def frame(rec) do
    payload = :erlang.term_to_binary(rec)
    [<<byte_size(payload)::32, :erlang.crc32(payload)::32>>, payload]
  end

  @doc false
  # Every record of a log binary, in order — read-only, for tools and tests.
  # `{:ok, records}`, or `{:error, why}` at the first frame that does not verify.
  def records(<<@header, rest::binary>>), do: collect(rest, [])
  def records(_), do: {:error, :header}

  defp collect(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp collect(<<len::32, crc::32, payload::binary-size(len), rest::binary>>, acc) do
    if :erlang.crc32(payload) == crc,
      do: collect(rest, [:erlang.binary_to_term(payload) | acc]),
      else: {:error, {:checksum, length(acc) + 1}}
  end

  defp collect(_, acc), do: {:error, {:partial, length(acc) + 1}}

  @doc false
  # Replay a whole log binary from nothing. Exposed for tests and tools.
  def replay(bin), do: replay_from(bin, 0, %{}, [])

  # Replay onto a base (a checkpoint, earlier segments). Records the base
  # already holds (t <= tseq) are read, checked for sequence, and skipped;
  # the first record may not leave a gap after the base.
  defp replay_from(bin, tseq, images, rec) do
    hs = byte_size(@header)

    case bin do
      <<@header, rest::binary>> -> frames(rest, hs, images, tseq, rec, nil)
      _ when byte_size(bin) < hs -> {:torn, images, tseq, rec, 0, "partial header"}
      _ -> {:damaged, "the file does not begin with #{inspect(@header)}"}
    end
  end

  defp frames(<<>>, _off, images, tseq, rec, _seen), do: {:ok, images, tseq, rec}

  defp frames(rest, off, images, tseq, rec, _seen) when byte_size(rest) < 8,
    do: {:torn, images, tseq, rec, off, "partial frame header"}

  defp frames(<<len::32, crc::32, body::binary>>, off, images, tseq, rec, seen) do
    cond do
      byte_size(body) < len ->
        {:torn, images, tseq, rec, off, "frame declares #{len} bytes, #{byte_size(body)} present"}

      true ->
        <<payload::binary-size(len), rest::binary>> = body

        cond do
          :erlang.crc32(payload) != crc and rest == <<>> ->
            {:torn, images, tseq, rec, off, "checksum mismatch on the last frame"}

          :erlang.crc32(payload) != crc ->
            {:damaged,
             "checksum mismatch at offset #{off} with #{byte_size(rest)} bytes after it — not a torn tail"}

          true ->
            case decode(payload) do
              {:ok, %{"t" => t, "ops" => ops} = r} ->
                cond do
                  (seen == nil and t > tseq + 1) or (seen != nil and t != seen + 1) ->
                    {:damaged,
                     "record sequence gap at offset #{off}: expected #{(seen || tseq) + 1}, found #{t}"}

                  t <= tseq ->
                    frames(rest, off + 8 + len, images, tseq, rec, t)

                  true ->
                    images = Enum.reduce(ops, images, &Delta.apply_op/2)
                    rec = if r["recovered"], do: [r["recovered"] | rec], else: rec
                    frames(rest, off + 8 + len, images, t, rec, t)
                end

              _ ->
                {:damaged, "an unreadable record at offset #{off} under a valid checksum"}
            end
        end
    end
  end

  defp decode(payload) do
    {:ok, :erlang.binary_to_term(payload)}
  rescue
    _ -> :error
  end
end
