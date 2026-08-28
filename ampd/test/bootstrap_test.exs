defmodule Ampd.BootstrapTest do
  @moduledoc """
  Bootstrap truth. Two laws, one falsifier each:

  * **Installation confers zero authority — and so does boot.**
  * **Bootstrap may create authority state only through an explicit
    initialization transition. Recovery may never infer authority from
    defaults.**

  The second is the one that bites: before C1.0b, deleting a single DETS
  file re-ran `GrantRegistry.initial/0`, which minted three GitHub grants.
  Losing data *widened* authority.
  """
  use ExUnit.Case, async: false
  alias Ampd.{GrantRegistry, Gateway, Approvals, Receipts, Effects, World}

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

  test "a production world boots with zero authority" do
    Ampd.reset()

    assert GrantRegistry.list() == [], "a fresh world minted grants nobody asked for"
    assert Approvals.all() == []
    assert Receipts.all() == []
    assert Effects.all() == []

    auth = Ampd.Conformance.authorize("github.repo.read", "traaviis/trvm", Gateway.ctx(), nil)
    refute auth["allow"], "a fresh world authorized an effect"
    assert auth["reason"] =~ "authority-missing"
  end

  test "the demo world is reachable only by asking for it by name" do
    Ampd.reset()
    assert GrantRegistry.list() == []

    Ampd.reset_demo()
    active = Enum.filter(GrantRegistry.list(), &(&1["status"] == "active"))
    assert length(active) == 3, "the C0 fixture stopped seeding its three grants"
    assert Ampd.Conformance.authorize("github.repo.read", "traaviis/trvm", Gateway.ctx(), nil)["allow"]
  end

  test "the world manifest is written last, so its presence proves the stores existed" do
    Ampd.reset()
    meta = World.read()

    assert meta["schema"] == "world-meta@1"
    assert meta["schema_version"] == World.schema_version()
    assert String.starts_with?(meta["installation_id"], "w-")
    assert meta["initialized_at"] =~ ~r/^\d{4}-/

    dir = Application.get_env(:ampd, :data_dir)
    files = File.ls!(dir)

    Enum.each(World.authority_stores(), fn s ->
      assert "#{s}.dets" in files, "store #{s} missing though the manifest was written"
    end)
  end

  test "losing an authority store seals the gateway instead of reseeding defaults" do
    Ampd.reset_demo()
    Ampd.Authority.revoke_domain("github.repo.read")
    refute Ampd.Conformance.authorize("github.repo.read", "traaviis/trvm", Gateway.ctx(), nil)["allow"]

    # The disk loses exactly one authority store while the world lives on.
    dir = Application.get_env(:ampd, :data_dir)
    GrantRegistry.close_store()
    File.rm_rf!(Path.join(dir, "grant_registry.dets"))
    Process.exit(Process.whereis(GrantRegistry), :kill)
    wait_up(GrantRegistry, fn -> GrantRegistry.sealed() end)

    auth = Ampd.Conformance.authorize("github.repo.read", "traaviis/trvm", Gateway.ctx(), nil)

    refute auth["allow"], "data loss widened authority"
    assert auth["reason"] =~ "RECOVERY-STATE-MISSING",
           "the refusal did not name the recovery state: #{inspect(auth["reason"])}"
    assert auth["sealed"] == true
    assert Ampd.seals() != [], "the seal was invisible to Ampd.seals/0"

    # And it stays sealed for a capability that was never revoked — the
    # seal is a property of the store, not of one grant.
    refute Ampd.Conformance.authorize("github.pr.draft", "traaviis/trvm", Gateway.ctx(), nil)["allow"]
  end

  test "a sealed store refuses writes BY NAME, without taking the total order down with it" do
    Ampd.reset_demo()
    dir = Application.get_env(:ampd, :data_dir)
    GrantRegistry.close_store()
    File.rm_rf!(Path.join(dir, "grant_registry.dets"))
    Process.exit(Process.whereis(GrantRegistry), :kill)
    wait_up(GrantRegistry, fn -> GrantRegistry.sealed() end)

    assert GrantRegistry.sealed() =~ "RECOVERY-STATE-MISSING"

    coordinator = Process.whereis(Ampd.AuthorityCoordinator)

    assert {:refused, r} = Ampd.Authority.mint(%{"capability" => "github.pr.merge"})
    assert r["schema"] == "refusal@1"
    assert r["code"] == "recovery-state-missing"
    assert r["requires_human"] == true
    refute r["retryable"]

    # The seal must not become an outage: raising here would kill the
    # registry AND the coordinator that called it, so one lost store would
    # take the whole authority subsystem down.
    assert Process.whereis(Ampd.AuthorityCoordinator) == coordinator,
           "a sealed write killed the total order"

    assert Process.alive?(coordinator)
    assert GrantRegistry.list() == [], "a sealed registry served authority"

    # Cleanly re-establish a world for whatever runs next.
    Ampd.reset_demo()
    assert GrantRegistry.sealed() == nil
  end

  test "a sealed effect journal does not take the boot down with it" do
    Ampd.reset_demo()
    dir = Application.get_env(:ampd, :data_dir)
    Ampd.Effects.close_store()
    File.rm_rf!(Path.join(dir, "effects.dets"))
    Process.exit(Process.whereis(Ampd.Effects), :kill)
    wait_up(Ampd.Effects, fn -> Ampd.Effects.sealed() end)

    assert Ampd.Effects.sealed() =~ "RECOVERY-STATE-MISSING"

    # `recover!/0` runs from `Ampd.Application.start/2`, right after the
    # supervisor comes up. It is not an ordered op, so it never met the
    # seal guard the mutations got — and `Store.save/2` raises on a sealed
    # store by design. The raise killed Effects, which killed the start
    # callback, which killed the application: a sealed world could not boot
    # **at all**, and the named refusal the seal exists to produce never
    # got the chance to be produced. A seal that crash-loops is not a seal.
    #
    # Found by pointing the runtime at a real world.json left over from an
    # older build, which is also the only reason anyone would ever hit it.
    assert Ampd.Effects.recover!() == []
    assert Process.alive?(Process.whereis(Ampd.Effects))
    assert Ampd.Effects.all() == [], "a sealed journal served effects"

    Ampd.reset_demo()
    assert Ampd.Effects.sealed() == nil
  end
end
