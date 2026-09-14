defmodule Ampd.FleetTest do
  use ExUnit.Case, async: false
  alias Ampd.Fleet
  test "saved device settings survive launches and explicit overrides win" do
    dir = Path.join(System.tmp_dir!(), "fleet-settings-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "super"))
    on_exit(fn -> File.rm_rf!(dir) end)
    env = %{"XDG_CONFIG_HOME" => dir}
    path = Path.join(dir, "super/fleet.json")
    assert Fleet.snapshot_path(env) == nil
    File.write!(path, JSON.encode!(%{"schema" => "super-device-fleet@1", "snapshotPath" => "/device/snapshot.json"}))
    assert Fleet.snapshot_path(env) == "/device/snapshot.json"
    assert Fleet.snapshot_path(Map.put(env, "SUPER_FLEET_SNAPSHOT", "")) == nil
    assert Fleet.snapshot_path(Map.put(env, "SUPER_FLEET_SNAPSHOT", "/override")) == "/override"
    for bytes <- ["{", JSON.encode!(%{"schema" => "wrong", "snapshotPath" => "/device/snapshot.json"}), JSON.encode!(%{"schema" => "super-device-fleet@1", "snapshotPath" => "relative"}), String.duplicate("x", 65_537)] do
      File.write!(path, bytes)
      assert Fleet.snapshot_path(env) == nil
    end
    assert Fleet.snapshot_path(%{"XDG_CONFIG_HOME" => "relative"}) == nil
  end
  defp host do
    %{"id" => "freebsd", "label" => "FreeBSD research", "status" => "observed", "observedAt" => 100_000,
      "reason" => "", "nextStep" => "Prepare a bhyve guest", "inventory" => %{"hostname" => "cd-floor-01", "os" => "FreeBSD", "release" => "15.1", "hypervisor" => "bhyve", "logicalCpus" => 16, "memoryBytes" => 30_000_000_000, "guests" => [%{"id" => "wifibox", "label" => "Wifibox", "status" => "present"}]}}
  end
  defp snapshot(hosts), do: %{"schema" => "fleet-snapshot@1", "hosts" => hosts}
  test "observations never confer worker readiness or pass unknown fields" do
    [h] = Fleet.normalize(snapshot([Map.put(host(), "workerReady", true)]), 100_000)["hosts"]
    assert h["workerReady"] == false
    assert h["inventory"]["hypervisor"] == "bhyve"
    assert h["inventory"]["guests"] |> hd() |> Map.get("status") == "present"
  end
  test "expiry withdraws current guest state" do
    [h] = Fleet.normalize(snapshot([host()]), 190_001)["hosts"]
    assert h["status"] == "stale"
    assert hd(h["inventory"]["guests"])["status"] == "unknown"
  end
  test "failed observation cannot keep previous inventory" do
    h = host() |> Map.put("status", "unavailable")
    [row] = Fleet.normalize(snapshot([h]), 100_000)["hosts"]
    refute Map.has_key?(row, "inventory")
  end
  test "malformed, oversized, duplicate and future observations fail closed" do
    for input <- [nil, snapshot(List.duplicate(host(),9)), snapshot([host(),host()]), snapshot([Map.put(host(),"observedAt",106_000)]), snapshot([Map.put(host(),"label",String.duplicate("x",101))]), snapshot([Map.put(host(),"inventory",%{})])] do
      assert Fleet.normalize(input,100_000)["status"] == "unavailable"
      assert Fleet.normalize(input,100_000)["hosts"] == []
    end
  end
  test "passive reads do not generate refusals or view traffic" do
    before = Ampd.RefusalLog.recent()
    for _ <- 1..20, do: assert(is_map(Fleet.projection()))
    assert Ampd.RefusalLog.recent() == before
  end
end
