defmodule Ampd.CrashTest do
  @moduledoc """
  Crash falsifiers: OTP restarts must preserve truth, never widen authority.
  Each test kills a registry mid-state and asserts the semantics survive.
  """
  use ExUnit.Case, async: false
  alias Ampd.{CapabilityRegistry, GrantRegistry, Session, Approvals, Receipts, Gateway}

  defp kill_and_wait(mod, probe) do
    old = Process.whereis(mod)
    Process.exit(old, :kill)
    wait(mod, old, probe, 100)
  end
  defp wait(_mod, _old, _probe, 0), do: flunk("registry did not come back")
  defp wait(mod, old, probe, n) do
    pid = Process.whereis(mod)
    ok =
      pid != nil and pid != old and
        (try do
           probe.()
           true
         catch
           :exit, _ -> false
         end)
    if ok, do: :ok, else: (Process.sleep(20); wait(mod, old, probe, n - 1))
  end

  test "restart never resurrects revoked authority" do
    Ampd.reset_demo()
    Ampd.Authority.revoke_domain("github.repo.read")
    kill_and_wait(GrantRegistry, fn -> GrantRegistry.list() end)
    auth = Ampd.Conformance.authorize("github.repo.read", "traaviis/trvm", Gateway.ctx(), nil)
    refute auth["allow"], "revoked authority came back after restart"
    assert auth["reason"] =~ "authority-missing"
  end

  test "restart never revives a retired run" do
    Ampd.reset_demo()
    old_run = Ampd.Authority.end_run()
    assert old_run == "run-b51"
    kill_and_wait(Session, fn -> Session.run() end)
    assert Session.retired?("run-b51"), "retired run forgotten after restart"
    assert Session.run() == "run-b52", "current run identity regressed after restart"
  end

  test "committed receipts survive the ledger's death" do
    Ampd.reset_demo()
    auth = Ampd.Conformance.exercise("pr.draft")
    assert auth["allow"]
    assert Receipts.count() == 1
    kill_and_wait(Receipts, fn -> Receipts.count() end)
    assert Receipts.count() == 1, "a committed receipt vanished on restart"
    assert hd(Receipts.of_kind("capability-effect-receipt@1"))["capability"] == "github.pr.draft"
  end

  test "pending consent is neither invented nor lost by a crash" do
    Ampd.reset_demo()
    Ampd.Authority.set_draft("pr.create", true)
    Ampd.Authority.commit(CapabilityRegistry.get("github")["surface"])
    Ampd.Conformance.exercise("pr.create")
    assert [%{"status" => "pending"}] = Approvals.all()
    kill_and_wait(Approvals, fn -> Approvals.all() end)
    assert [%{"status" => "pending"}] = Approvals.all(),
           "consent state changed across the crash"
    auth = Ampd.Conformance.approve_last()
    assert auth["allow"], "surviving consent failed to execute"
    assert Receipts.count() == 1
  end
end
