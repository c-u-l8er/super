defmodule Ampd.AuthorityLogMigrationTest do
  @moduledoc """
  World `schema_version` 2 → 3 (`Ampd.AuthorityLog.Migration`): a version-2
  world — the four effect-path stores in DETS tables — is built on disk from
  the live registries' state, and then converted, refused, or finished.
  """
  use ExUnit.Case, async: false
  alias Ampd.{AuthorityLog, Authority, Effects, Gateway, GrantRegistry, Receipts, World}
  alias Ampd.AuthorityLog.Migration

  @cap "github.pr.draft"
  @registries [
    {"grant_registry", Ampd.GrantRegistry},
    {"approvals", Ampd.Approvals},
    {"receipts", Ampd.Receipts},
    {"effects", Ampd.Effects}
  ]

  setup do
    on_exit(fn -> Ampd.reset_demo() end)
    :ok
  end

  defp dir, do: Ampd.Store.data_dir()
  defp table(name), do: Path.join(dir(), "#{name}.dets")

  defp perform! do
    Authority.one_shot(@cap)

    r =
      Gateway.perform(@cap, "traaviis/trvm", Gateway.ctx(), %{
        "er" => "er-github.pr.draft",
        "rev" => 1,
        "params" => Ampd.Core.params()["pr.draft"]
      })

    assert r["allow"]
    r
  end

  # The world as version 2 left it: each store its own table, no log, the
  # manifest at 2 — built from exactly what the registries hold.
  defp as_version_2! do
    states = Map.new(@registries, fn {name, mod} -> {name, :sys.get_state(mod).s} end)
    AuthorityLog.close()
    File.rm!(AuthorityLog.path())

    for {name, s} <- states do
      {:ok, t} = :dets.open_file(make_ref(), file: String.to_charlist(table(name)))
      :ok = :dets.insert(t, {:state, s})
      :ok = :dets.close(t)
    end

    World.replace!(Map.put(World.read_raw(), "schema_version", 2))
    states
  end

  defp reboot_registries! do
    AuthorityLog.close()
    Enum.each(@registries, fn {_, mod} -> Process.exit(Process.whereis(mod), :kill) end)

    Enum.each(@registries, fn {_, mod} ->
      Enum.reduce_while(1..200, nil, fn _, _ ->
        up =
          Process.whereis(mod) != nil and
            try do
              mod.sealed()
              true
            catch
              :exit, _ -> false
            end

        if up, do: {:halt, :ok}, else: Process.sleep(20) && {:cont, nil}
      end)
    end)
  end

  test "a version-2 world is converted whole: one record, the manifest at 3, the tables set aside" do
    Ampd.reset_demo()
    Authority.revoke_domain(@cap)
    r = perform!()
    before = as_version_2!()

    assert {:migrated, stores} = Migration.run!()
    assert Enum.sort(stores) == Enum.sort(Map.keys(before))

    assert World.read_raw()["schema_version"] == World.schema_version()
    assert World.manifest_state() == :valid

    for {name, _} <- @registries do
      refute File.exists?(table(name)), "#{name}.dets was left beside the log"
      assert File.exists?(table(name) <> ".v2")
    end

    {:ok, [first]} = AuthorityLog.records(File.read!(AuthorityLog.path()))
    assert first["migrated"]["from_schema_version"] == 2

    reboot_registries!()
    assert Ampd.seals() == []

    # A reboot is a new incarnation: the journal owner mints a new epoch and
    # every participant takes the new fence. Everything else is the table.
    per_incarnation = ~w(fence epoch epoch_seq)

    for {name, mod} <- @registries do
      assert Map.drop(:sys.get_state(mod).s, per_incarnation) ==
               Map.drop(before[name], per_incarnation),
             "#{name} did not come back as the table held it"
    end

    assert Effects.get(r["effect_id"])["state"] == "COMMITTED"
    assert Enum.any?(Receipts.all(), &(&1["effect_ref"] == r["effect_id"]))

    # And the migrated world takes new work.
    perform!()
  end

  test "a damaged table stops the migration: the world stays at 2 and seals as needing migration" do
    Ampd.reset_demo()
    perform!()
    as_version_2!()
    File.write!(table("effects"), "not a dets table")

    assert {:refused, "effects", why} = Migration.run!()
    assert why =~ "repair"
    assert World.read_raw()["schema_version"] == 2
    refute File.exists?(AuthorityLog.path()), "a partial world was converted around the damage"

    reboot_registries!()
    assert GrantRegistry.sealed() =~ "MIGRATION-REQUIRED"
    assert GrantRegistry.list() == []
  end

  test "an interrupted migration (log written, manifest still at 2) converts again from the tables" do
    Ampd.reset_demo()
    perform!()
    before = as_version_2!()

    # A log from an attempt that never reached the manifest, holding something else.
    File.write!(AuthorityLog.path(), [
      AuthorityLog.header()
      | AuthorityLog.frame(%{
          "t" => 1,
          "ops" => [{:init, "effects", %{"effects" => [], "seq" => 1}}]
        })
    ])

    assert {:migrated, _} = Migration.run!()
    reboot_registries!()

    assert :sys.get_state(Ampd.Effects).s["effects"] == before["effects"]["effects"]
  end

  test "a manifest already at 3 with a table still in place (interrupted after the manifest) finishes the move" do
    Ampd.reset_demo()
    perform!()
    as_version_2!()
    assert {:migrated, _} = Migration.run!()

    # Put one table back, as if the last step had not run.
    File.rename!(table("receipts") <> ".v2", table("receipts"))
    log = File.read!(AuthorityLog.path())

    assert :ok = Migration.run!()
    refute File.exists?(table("receipts"))
    assert File.read!(AuthorityLog.path()) == log, "finishing the move touched the log"
  end
end
