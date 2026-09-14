defmodule Ampd.FleetTest do
  use ExUnit.Case, async: false
  alias Ampd.Fleet
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
