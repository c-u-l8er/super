defmodule Ampd.AuthorityLog.Migration do
  @moduledoc """
  World `schema_version` 2 → 3: the effect path's four stores move from a
  DETS table each into `authority.log`. Run from `Ampd.Bootstrap.new_world!/0`
  at boot, before any registry opens a store.

  In this order, each step leaving a world the next boot can finish:

  1. Read each of the four tables **read-only, `repair: false`**. A table
     that does not open cleanly is damaged, and the migration refuses: the
     world stays version 2, which this build seals as
     `WORLD-META-MIGRATION-REQUIRED`. It does not convert around damage — the
     damaged table was going to seal the world anyway, and carrying its
     neighbours across while leaving it behind would be a partial world.
  2. Write every table's state as ONE record to `authority.log.migrating`,
     sync it, and rename it to `authority.log`. A crash before the rename
     leaves no log; after it, the manifest still says 2, and the next boot
     converts again from the tables it never touched.
  3. Replace the manifest with the same identity at version 3
     (`Ampd.World.replace!/1`: a whole file, renamed over the old one).
  4. Rename each converted table to `<name>.dets.v2`. A version-3 manifest
     with a table still in place (a crash between 3 and 4) finishes here on
     the next boot: the log is the authority, and a table beside it would be
     a second, stale copy.

  A table that is absent is not converted and not invented: the store stays
  absent, and `Ampd.World` seals it as MISSING exactly as it did before.

  There is no downgrade from 3 yet; an older build refuses a version-3
  world by name.
  """
  require Logger

  alias Ampd.{AuthorityLog, World}

  @from 2

  def run! do
    m = World.read_raw()

    cond do
      is_map(m) and m["schema"] == "world-meta@1" and m["schema_version"] == @from and
          World.shape_ok_any_version?(m) ->
        migrate!(m)

      is_map(m) and m["schema_version"] == World.schema_version() ->
        set_tables_aside!()

      true ->
        :noop
    end
  end

  defp dir, do: Ampd.Store.data_dir()
  defp table(name), do: Path.join(dir(), "#{name}.dets")

  defp migrate!(m) do
    read = Enum.map(AuthorityLog.stores(), &{&1, read_table(&1)})

    case Enum.find(read, &match?({_, {:damaged, _}}, &1)) do
      {name, {:damaged, why}} ->
        Logger.error(
          "ampd: not migrating world #{m["installation_id"]} to schema_version " <>
            "#{World.schema_version()}: #{name} #{why}. The world stays at version #{@from} " <>
            "and its authority stores are sealed until a human recovers it."
        )

        {:refused, name, why}

      nil ->
        present = for {name, {:ok, s}} <- read, do: {name, s}
        write_log!(present)
        World.replace!(Map.put(m, "schema_version", World.schema_version()))
        set_tables_aside!()

        Logger.info(
          "ampd: world #{m["installation_id"]} migrated from schema_version #{@from} to " <>
            "#{World.schema_version()} (#{Enum.map_join(present, ", ", &elem(&1, 0))} into authority.log)"
        )

        {:migrated, Enum.map(present, &elem(&1, 0))}
    end
  end

  defp read_table(name) do
    file = table(name)

    if File.exists?(file) do
      case :dets.open_file(make_ref(),
             file: String.to_charlist(file),
             access: :read,
             repair: false
           ) do
        {:ok, tab} ->
          r =
            case :dets.lookup(tab, :state) do
              [{:state, s}] -> {:ok, s}
              [] -> :absent
            end

          :dets.close(tab)
          r

        {:error, why} ->
          {:damaged, "could not be read without repair: #{inspect(why)}"}
      end
    else
      :absent
    end
  end

  defp write_log!(present) do
    final = AuthorityLog.path()
    tmp = final <> ".migrating"

    rec = %{
      "t" => 1,
      "ops" => for({name, s} <- present, do: {:init, name, s}),
      "migrated" => %{
        "from_schema_version" => @from,
        "stores" => Enum.map(present, &elem(&1, 0)),
        "at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }

    File.write!(tmp, [AuthorityLog.header() | AuthorityLog.frame(rec)])
    {:ok, fd} = :file.open(tmp, [:read, :raw])
    :ok = :file.datasync(fd)
    :ok = :file.close(fd)
    File.rename!(tmp, final)
  end

  defp set_tables_aside! do
    if File.exists?(AuthorityLog.path()) do
      for name <- AuthorityLog.stores(), File.exists?(table(name)) do
        File.rename!(table(name), table(name) <> ".v2")
      end
    end

    :ok
  end
end
