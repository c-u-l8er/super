defmodule Ampd.Store do
  @moduledoc """
  Truth-preserving recovery. Every authority-bearing registry writes its
  state through here (DETS on disk) and loads it back on restart — so a
  crash can never resurrect revoked authority, revive a retired run,
  invent consent, or lose a committed receipt.

  Two rules distinguish this from "durable maps":

  1. **Bootstrap may create authority state only through an explicit
     initialization transition; recovery may never infer authority from
     defaults.** A store with no `:state` record is initialized *only*
     when `Ampd.World` says no world exists yet. If the world was
     initialized and the store is gone, the registry is **sealed** — it
     holds no authority and names why.

  2. **A repaired authority table is an unaudited mutation.** DETS opens
     with `repair: true` by default and will silently rewrite a table
     damaged by an unclean shutdown, dropping whatever it cannot parse.
     For an authority store that is indistinguishable from a partial
     revocation nobody ordered, so we open `repair: false` and treat
     damage as `RECOVERY-STATE-UNTRUSTED`.

  A sealed registry serves `[]` — fail-closed even if a caller forgets to
  ask — while `Ampd.Gateway` turns the seal into a named refusal.
  """

  @doc """
  Where this runtime's stores live.

  `AMPD_DATA_DIR` wins over the compiled config, because the host decides
  where a runtime's world lives and it decides at spawn time, not at
  compile time. It is also what lets a verification run start from a world
  it created rather than inheriting whatever the last one left — a battery
  that passes because of state it did not set up is not a battery.
  """
  def data_dir,
    do: System.get_env("AMPD_DATA_DIR") || Application.get_env(:ampd, :data_dir, "priv/data")

  @doc """
  Open a store, repairing nothing. `{:ok, tab}` or `{:damaged, why}`.

  The effect path's four stores (`Ampd.AuthorityLog.stores/0`) live in the
  authority log and open as `{:alog, name}`; every other store is still its
  own DETS table. The handle is opaque to the registries: they `save/2` and
  `close/1` it exactly as before.
  """
  def open(name) do
    if Ampd.AuthorityLog.backed?(name), do: open_logged(name), else: open_dets(name)
  end

  # The durable image becomes the base the next `save/2` diffs against. It is
  # kept in the opening (registry) process, which is the only writer of this
  # store's state.
  defp open_logged(name) do
    case Ampd.AuthorityLog.image(name) do
      {:damaged, why} ->
        {:damaged, why}

      {:present, s} ->
        Process.put(base_key(name), s)
        {:ok, {:alog, name}}

      :absent ->
        Process.put(base_key(name), :absent)
        {:ok, {:alog, name}}
    end
  end

  defp base_key(name), do: {__MODULE__, :base, name}

  defp open_dets(name) do
    dir = data_dir()
    File.mkdir_p!(dir)
    tab = :"ampd_#{name}"
    file = String.to_charlist(Path.join(dir, "#{name}.dets"))

    case :dets.open_file(tab, file: file, repair: false) do
      {:ok, ^tab} -> {:ok, tab}
      {:error, {:needs_repair, _}} -> {:damaged, "dets table needs repair"}
      {:error, {:not_closed, _}} -> {:damaged, "dets table was not closed cleanly"}
      {:error, reason} -> {:damaged, "dets open failed: #{inspect(reason)}"}
    end
  end

  @doc "Open or raise — used by world initialization, where damage is fatal."
  def open!(name) do
    case open(name) do
      {:ok, tab} -> tab
      {:damaged, why} -> raise "cannot initialize world: #{name} #{why}"
    end
  end

  @doc """
  Boot one registry. Returns `{:ok, tab, state}` or `{:sealed, reason}`.

  This is the single place where "no state on disk" is interpreted, and
  it never interprets it alone — `Ampd.World` decides whether absence
  means *fresh* or *lost*.
  """
  def boot(name, initial_fun) do
    case open(name) do
      {:damaged, why} ->
        case Ampd.World.verdict(name, :damaged) do
          # The world's wording is about a DETS table; a logged store's damage
          # is the log's, and the operator is told which record broke it.
          {:sealed, reason} ->
            if Ampd.AuthorityLog.backed?(name),
              do: {:sealed, reason <> " Cause: " <> why},
              else: {:sealed, reason}

          _ ->
            {:sealed, "RECOVERY-STATE-UNTRUSTED · #{name}: #{why}"}
        end

      {:ok, tab} ->
        on_disk = state_of(tab)
        state_on_disk = if on_disk == :absent, do: :absent, else: :present

        case Ampd.World.verdict(name, state_on_disk) do
          :present ->
            {:ok, tab, on_disk}

          :fresh ->
            s = initial_fun.()
            {:ok, tab, save(tab, s)}

          {:sealed, reason} ->
            # Release the handle we just took. A sealed registry keeps no
            # table, and a retained handle would pin this (empty) file open
            # for the life of the VM — so a later re-initialization would
            # write into an unlinked inode and silently produce no store.
            close(tab)
            {:sealed, reason}
        end
    end
  end

  @doc """
  Persist a registry's state. A sealed registry has no table, and writing
  authority into a sealed world is a bug, not a fallback — so it raises
  rather than quietly holding the write in memory.
  """
  def save(nil, _s),
    do:
      raise(
        "refusing to write authority into a sealed store — the world's recovery state is unresolved"
      )

  # A logged store writes only what changed since its last durable state, as
  # one record, synced before this returns — or held for the open transaction
  # this registry is serving (`Ampd.AuthorityLog.group/1`), which is answered
  # only after that transaction's commit.
  def save({:alog, name}, s) do
    base = Process.get(base_key(name), :absent)

    case Ampd.AuthorityLog.Delta.diff(name, base, s) do
      [] ->
        s

      ops ->
        case Ampd.AuthorityLog.append(name, ops, Process.get(:ampd_origin)) do
          r when r in [:ok, :pending] ->
            Process.put(base_key(name), s)
            s

          {:error, why} ->
            raise "refusing to acknowledge an authority write the log could not make durable " <>
                    "(#{name}): #{inspect(why)}"
        end
    end
  end

  def save(tab, s) do
    :ok = :dets.insert(tab, {:state, s})
    :ok = :dets.sync(tab)
    s
  end

  @doc "Release a store handle."
  def close({:alog, name}) do
    Process.delete(base_key(name))
    :ok
  end

  def close(tab), do: :dets.close(tab)

  defp state_of({:alog, name}), do: Process.get(base_key(name), :absent)

  defp state_of(tab) do
    case :dets.lookup(tab, :state) do
      [] -> :absent
      [{:state, s}] -> s
    end
  end

  @doc """
  Write a registry's state without consulting the world — the explicit
  initialization transition. Callers must have established that creating
  authority here is intended.
  """
  def seed!(name, s) do
    if Ampd.AuthorityLog.backed?(name),
      do: Ampd.AuthorityLog.seed!(name, s),
      else: seed_dets!(name, s)
  end

  defp seed_dets!(name, s) do
    tab = open!(name)
    save(tab, s)
    # Release immediately. dets counts openers per process, so a seeding
    # process that keeps its handle — the application master, say — pins
    # the table open for the life of the VM and makes the store
    # impossible to close and re-create later.
    :dets.close(tab)
    :ok
  end
end
