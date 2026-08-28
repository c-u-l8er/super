defmodule Ampd.WorldTest do
  @moduledoc """
  World identity: the four recovery states, and lineage.

  The state that motivated this file is the fourth one — a manifest that
  is *absent* beside authority stores that are *present*. It looks exactly
  like a first boot and is not one, and seeding over it would destroy the
  evidence and replace it with defaults.
  """
  use ExUnit.Case, async: false
  alias Ampd.{World, GrantRegistry, Gateway, Bootstrap}

  defp dir, do: Application.get_env(:ampd, :data_dir)

  defp wait_up(mod, probe, n \\ 100)
  defp wait_up(_mod, _probe, 0), do: flunk("registry did not come back")

  defp wait_up(mod, probe, n) do
    ok =
      Process.whereis(mod) != nil and
        (try do
           probe.()
           true
         catch
           :exit, _ -> false
         end)

    if ok, do: :ok, else: (Process.sleep(20); wait_up(mod, probe, n - 1))
  end

  # ------------------------------------------------------ the truth table
  test "no manifest and no stores is a first boot: initialization may create state" do
    Ampd.reset()
    assert World.initialized?()
    assert World.read()["generation"] == 1
    assert World.stores_on_disk() |> length() == length(World.authority_stores())
  end

  test "manifest plus every store is an existing world: truth is loaded, not reseeded" do
    Ampd.reset_demo()
    Ampd.Authority.revoke_domain("github.repo.read")

    GrantRegistry.close_store()
    Process.exit(Process.whereis(GrantRegistry), :kill)
    wait_up(GrantRegistry, fn -> GrantRegistry.list() end)

    assert GrantRegistry.sealed() == nil, "an intact world sealed itself"

    refute Ampd.Conformance.authorize("github.repo.read", "traaviis/trvm", Gateway.ctx(), nil)["allow"],
           "restart reseeded defaults over persisted truth"
  end

  test "manifest plus a missing store seals" do
    Ampd.reset_demo()
    GrantRegistry.close_store()
    File.rm_rf!(Path.join(dir(), "grant_registry.dets"))
    Process.exit(Process.whereis(GrantRegistry), :kill)
    wait_up(GrantRegistry, fn -> GrantRegistry.sealed() end)

    assert GrantRegistry.sealed() =~ "RECOVERY-STATE-MISSING"
    Ampd.reset_demo()
  end

  @tag :capture_log
  test "no manifest beside real authority stores is an ORPHANED WORLD, and is not seeded over" do
    Ampd.reset_demo()
    Ampd.Authority.revoke_domain("github.repo.read")

    # The manifest is lost; every authority store survives.
    File.rm!(Path.join(dir(), "world.json"))
    refute World.initialized?()
    assert World.stores_on_disk() != []

    assert {:error, {:orphaned, stores}} = World.may_initialize?()
    assert "grant_registry" in stores

    # Initialization must refuse rather than overwrite the evidence.
    assert {:orphaned, _} = Bootstrap.new_world!()
    refute World.initialized?(), "a manifest was written over an orphaned world"

    assert File.exists?(Path.join(dir(), "grant_registry.dets")),
           "an orphaned world's authority store was destroyed"

    # And a registry booting into it seals rather than inventing defaults.
    GrantRegistry.close_store()
    Process.exit(Process.whereis(GrantRegistry), :kill)
    wait_up(GrantRegistry, fn -> GrantRegistry.sealed() end)

    assert GrantRegistry.sealed() =~ "ORPHANED-WORLD"
    auth = Ampd.Conformance.authorize("github.repo.read", "traaviis/trvm", Gateway.ctx(), nil)
    refute auth["allow"]
    assert auth["reason"] =~ "ORPHANED-WORLD"

    Ampd.reset_demo()
  end

  @tag :capture_log
  test "a manifest that is present but INVALID is untrusted, not initialized" do
    Ampd.reset_demo()

    # Presence is not validity: this parses to a non-empty map and used to
    # count as a fully initialized world.
    File.write!(Path.join(dir(), "world.json"), ~s({"foo":"bar"}))

    assert World.manifest_state() == :malformed
    refute World.initialized?(), "a junk manifest counted as an initialized world"
    assert World.read() == nil
    assert World.read_raw() == %{"foo" => "bar"}
    assert "schema" in World.invalid_fields()
    assert "generation" in World.invalid_fields()

    # Initialization must not overwrite it — it might be a real world's.
    assert {:error, {:malformed, _}} = World.may_initialize?()
    assert {:malformed, _} = Bootstrap.new_world!()
    assert World.read_raw() == %{"foo" => "bar"}, "an unreadable manifest was overwritten"

    GrantRegistry.close_store()
    Process.exit(Process.whereis(GrantRegistry), :kill)
    wait_up(GrantRegistry, fn -> GrantRegistry.sealed() end)

    assert GrantRegistry.sealed() =~ "WORLD-META-UNTRUSTED"
    auth = Ampd.Conformance.authorize("github.repo.read", "traaviis/trvm", Gateway.ctx(), nil)
    refute auth["allow"]

    Ampd.reset_demo()
  end

  test "a truncated manifest missing one required field is also untrusted" do
    Ampd.reset_demo()
    good = World.read()

    # Everything correct except `generation`.
    File.write!(Path.join(dir(), "world.json"),
      ~s({"initialized_at":"#{good["initialized_at"]}","installation_id":"#{good["installation_id"]}","schema":"world-meta@1","schema_version":2}))

    assert World.manifest_state() == :malformed
    assert World.invalid_fields() == ["generation"]
    Ampd.reset_demo()
  end

  # -------------------------------- valid shape is not understood semantics
  @tag :capture_log
  test "a perfectly shaped manifest from a NEWER build is unsupported, not valid" do
    Ampd.reset_demo()
    good = World.read()

    # Every field correct. Nothing corrupt. A version this build has never
    # met — so its fields mean whatever that build decided they mean, and
    # reading them here is a guess about world identity and lineage.
    File.write!(Path.join(dir(), "world.json"),
      ~s({"generation":1,"initialized_at":"#{good["initialized_at"]}","installation_id":"#{good["installation_id"]}","schema":"world-meta@1","schema_version":999}))

    assert World.manifest_state() == :unsupported
    refute World.valid?(World.read_raw()), "schema_version >= 1 counted 999 as valid"
    refute World.initialized?()

    # It must not be seeded over: this is a *newer* world, and overwriting
    # it destroys an identity this build could not even read.
    assert {:error, {:unsupported, _}} = World.may_initialize?()
    assert {:unsupported, _} = Bootstrap.new_world!()
    assert World.read_raw()["schema_version"] == 999, "a future world's manifest was overwritten"

    GrantRegistry.close_store()
    Process.exit(Process.whereis(GrantRegistry), :kill)
    wait_up(GrantRegistry, fn -> GrantRegistry.sealed() end)

    assert GrantRegistry.sealed() =~ "WORLD-META-UNSUPPORTED"
    assert GrantRegistry.sealed() =~ "999"

    auth = Ampd.Conformance.authorize("github.repo.read", "traaviis/trvm", Gateway.ctx(), nil)
    refute auth["allow"]
    assert auth["refusal"]["code"] == "world-meta-unsupported"

    Ampd.reset_demo()
  end

  @tag :capture_log
  test "an OLDER manifest reports as needing migration, not as corruption" do
    Ampd.reset_demo()
    good = World.read()

    # This is the real v1 shape: `store_generation`, no `generation`. Read
    # shape-first it looks corrupt, and sends an operator hunting for
    # damage that is not there. Shape is versioned, so the version is read
    # before the shape.
    File.write!(Path.join(dir(), "world.json"),
      ~s({"initialized_at":"#{good["initialized_at"]}","installation_id":"#{good["installation_id"]}","schema":"world-meta@1","schema_version":1,"store_generation":1}))

    assert World.manifest_state() == :migration_required
    assert {:error, {:migration_required, _}} = World.may_initialize?()

    GrantRegistry.close_store()
    Process.exit(Process.whereis(GrantRegistry), :kill)
    wait_up(GrantRegistry, fn -> GrantRegistry.sealed() end)

    r = GrantRegistry.sealed()
    assert r =~ "WORLD-META-MIGRATION-REQUIRED"
    assert r =~ "carries no migration path"

    auth = Ampd.Conformance.authorize("github.repo.read", "traaviis/trvm", Gateway.ctx(), nil)
    assert auth["refusal"]["code"] == "world-meta-migration-required"

    Ampd.reset_demo()
  end

  test "the world-meta refusal code is reachable at all" do
    Ampd.reset_demo()

    # It was not. `seal_code/1` tested `String.contains?(reason, "UNTRUSTED")`
    # first, and every `WORLD-META-UNTRUSTED · …` reason contains that
    # substring — so an invalid manifest reported itself as a damaged
    # store, sending an operator to repair a .dets file that was fine.
    assert Ampd.Refusal.seal_code("WORLD-META-UNTRUSTED · x: …") == "world-meta-untrusted"
    assert Ampd.Refusal.seal_code("WORLD-META-UNSUPPORTED · x: …") == "world-meta-unsupported"
    assert Ampd.Refusal.seal_code("WORLD-META-MIGRATION-REQUIRED · x: …") == "world-meta-migration-required"
    assert Ampd.Refusal.seal_code("ORPHANED-WORLD · x: …") == "orphaned-world"
    assert Ampd.Refusal.seal_code("RECOVERY-STATE-UNTRUSTED · x: …") == "recovery-state-untrusted"
    assert Ampd.Refusal.seal_code("RECOVERY-STATE-MISSING · x: …") == "recovery-state-missing"
  end

  # -------------------------------------------------------- sealed reads
  test "a sealed registry projects nothing rather than fabricated defaults" do
    Ampd.reset_demo()
    reg = Ampd.CapabilityRegistry
    reg.close_store()
    File.rm_rf!(Path.join(dir(), "capability_registry.dets"))
    Process.exit(Process.whereis(reg), :kill)
    wait_up(reg, fn -> reg.sealed() end)

    assert reg.sealed() =~ "RECOVERY-STATE-MISSING"

    assert reg.all() == %{},
           "a sealed capability registry served pack definitions that are not installed"

    assert reg.get("github") == nil,
           "a sealed registry projected a pack surface and its placement policy"

    Ampd.reset_demo()
  end

  # ------------------------------------------------------------- lineage
  test "generation is world lineage: it advances on wholesale replacement" do
    Ampd.reset()
    assert World.read()["generation"] == 1

    m = World.bump_generation!("factory-reinitialize")
    assert m["generation"] == 2
    assert m["generation_reason"] == "factory-reinitialize"
  end

  test "restoring an older snapshot moves lineage FORWARD and records where it came from" do
    Ampd.reset()

    Enum.each(2..7, fn _ -> World.bump_generation!("test-advance") end)
    assert World.read()["generation"] == 7

    m = World.bump_generation!("restore", %{"generation" => 3, "snapshot" => "sha256:deadbeef"})

    assert m["generation"] == 8,
           "restoring generation 3 into generation 7 must not move lineage backward"

    assert m["restored_from_generation"] == 3
    assert m["restored_from_snapshot"] == "sha256:deadbeef"

    reread = World.read()
    assert reread["generation"] == 8
    assert reread["restored_from_generation"] == 3
  end

  test "a schema migration is not a generation change" do
    Ampd.reset()
    before = World.read()
    assert before["schema_version"] == World.schema_version()
    assert before["generation"] == 1
    # Nothing in initialization couples the two; this pins that they are
    # separate fields with separate meanings.
    refute Map.has_key?(before, "generation_reason")
  end

  test "the sealed reason names the world, its generation, and what is missing" do
    Ampd.reset_demo()
    GrantRegistry.close_store()
    File.rm_rf!(Path.join(dir(), "grant_registry.dets"))
    Process.exit(Process.whereis(GrantRegistry), :kill)
    wait_up(GrantRegistry, fn -> GrantRegistry.sealed() end)

    r = GrantRegistry.sealed()
    assert r =~ "grant_registry"
    assert r =~ "generation 1"
    assert r =~ ~r/w-[0-9a-f]{16}/
    assert r =~ "Refusing to infer authority from defaults"

    Ampd.reset_demo()
  end
end
