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

  ## Worlds written before this

  World `schema_version` 3 is this layout. A version-2 world is converted
  once, at boot, by `Ampd.AuthorityLog.Migration`.

  The witness log (`Ampd.Effects.Witness`, `wek-r3-trace@3`) is unchanged
  and separate. Whether an authority record may *be* the witness line is
  WEK's decision, not this module's.
  """
  use GenServer
  require Logger

  alias Ampd.AuthorityLog.Delta

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
  @group_table :ampd_authority_log_group

  @doc "The stores this log backs. Every other authority store is still a DETS table."
  def stores, do: @stores
  def backed?(name), do: name in @stores
  def path(dir \\ Ampd.Store.data_dir()), do: Path.join(dir, @file_name)
  def checkpoint_path(dir \\ Ampd.Store.data_dir()), do: Path.join(dir, @cp_file)
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

  @doc "The durable state of `name`: `{:present, s}`, `:absent`, or `{:damaged, why}`."
  def image(name), do: GenServer.call(__MODULE__, {:image, name}, 60_000)

  @doc """
  Make `ops` durable for `name`. `:ok` once the record is synced; `:pending`
  when it belongs to the open transaction of `origin` (durable at that
  transaction's commit, which `group/1` awaits); `{:error, why}` otherwise.
  """
  def append(name, ops, origin),
    do: GenServer.call(__MODULE__, {:append, name, ops, origin}, 60_000)

  @doc "Close the file and forget the image — a world reset removes the directory under it."
  def close do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :close, 60_000), else: :ok
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
        GenServer.call(__MODULE__, {:present, dir}, 60_000)

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
      :ok = append(name, ops, nil)
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
  def status, do: GenServer.call(__MODULE__, :status, 60_000)

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
        :ok = GenServer.call(__MODULE__, {:open_group, self()}, 60_000)

        try do
          fun.()
        after
          case GenServer.call(__MODULE__, {:commit_group, self()}, 60_000) do
            :ok ->
              if Process.whereis(Ampd.Effects), do: Ampd.Effects.flush_deferred()

            {:error, why} ->
              Enum.each(Map.keys(@registries), fn mod ->
                if pid = Process.whereis(mod), do: Process.exit(pid, :kill)
              end)

              raise "authority log: a transaction's commit failed (#{inspect(why)}); " <>
                      "the registries restart from the durable image"
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
      cp_retry_at: 0,
      gen: nil,
      counters: %{
        "records" => 0,
        "syncs" => 0,
        "bytes" => 0,
        "grouped_records" => 0,
        "group_splits" => 0,
        "checkpoints" => 0
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
       "sealed_segments" => st.dir && length(sealed_segments(st.dir)),
       "path" => st.dir && path(st.dir),
       "tseq" => st.tseq,
       "size" => st.size,
       "damaged" => st.damaged,
       "recovered" => Enum.reverse(st.recovered),
       "stores" => Map.keys(st.images),
       "group_open" => st.group != nil
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
    if st.dir == dir, do: st, else: load(%{closed() | counters: st.counters}, dir)
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

  defp write_checkpoint(dir, t, images, rec) do
    bin = :erlang.term_to_binary(images)

    cp = %{
      "t" => t,
      "images" => bin,
      "sha256" => Base.encode16(:crypto.hash(:sha256, bin), case: :lower),
      "recovered" => rec
    }

    tmp = checkpoint_path(dir) <> ".tmp"

    with :ok <- File.write(tmp, [@cp_header | frame(cp)]),
         {:ok, fd} <- :file.open(tmp, [:read, :raw]),
         :ok <- :file.datasync(fd),
         :ok <- :file.close(fd),
         :ok <- File.rename(tmp, checkpoint_path(dir)) do
      :ok
    else
      {:error, why} -> {:error, why}
    end
  end

  defp read_checkpoint(dir) do
    case File.read(checkpoint_path(dir)) do
      {:error, :enoent} ->
        {:ok, 0, %{}, []}

      {:ok, <<@cp_header, len::32, crc::32, payload::binary-size(len)>>} ->
        with true <- :erlang.crc32(payload) == crc,
             {:ok, %{"t" => t, "images" => bin, "sha256" => sha} = cp} <- decode(payload),
             true <- Base.encode16(:crypto.hash(:sha256, bin), case: :lower) == sha,
             {:ok, images} <- decode(bin) do
          {:ok, t, images, cp["recovered"] || []}
        else
          _ -> {:damaged, "the checkpoint does not verify (checksum or digest)"}
        end

      {:ok, _} ->
        {:damaged, "the checkpoint is not a whole checkpoint file"}

      {:error, why} ->
        {:damaged, "the checkpoint cannot be read: #{inspect(why)}"}
    end
  end

  defp checkpoint_done(%{gen: gen} = st, gen, t, :ok) do
    st = %{st | cp_running: nil, cp_t: t}
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

  defp write_record(%{fd: fd, size: size, tseq: tseq} = st, rec) do
    rec = Map.put(rec, "t", tseq + 1)
    frame = frame(rec)
    n = IO.iodata_length(frame)

    with :ok <- :file.pwrite(fd, size, frame),
         :ok <- :file.datasync(fd) do
      images = Enum.reduce(rec["ops"], st.images, &Delta.apply_op/2)
      c = st.counters

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
