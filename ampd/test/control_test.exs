defmodule Ampd.ControlTest do
  @moduledoc """
  The projection boundary: who may speak for the person, and how much of a
  refusal each channel is allowed to read.

  Every local process here runs as the same OS user — the Super UI, Claude
  Code, Codex, plugins, shells. So the split cannot be "same UID means
  human"; it has to be structural. An agent may *ask* for anything and may
  never *give* consent.
  """
  use ExUnit.Case, async: false
  alias Ampd.{Control, Authority, Approvals, GrantRegistry, CapabilityRegistry, Receipts}

  defp request do
    %{"er" => "er-github.pr.create", "rev" => 1, "params" => Ampd.Core.params()["pr.create"]}
  end

  defp grant_pr_create do
    Authority.set_draft("pr.create", true)
    Authority.commit(CapabilityRegistry.get("github")["surface"])
  end

  defp fresh do
    Ampd.reset_demo()
    Ampd.attach_pair()
  end

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

  # ------------------------------------------------- the impersonation gate
  test "the agent channel cannot approve an effect" do
    {_human, agent} = fresh()
    grant_pr_create()
    Control.command(agent, :request_effect, ["github.pr.create", "traaviis/trvm", request()])

    [p] = Approvals.all()
    assert p["status"] == "pending"

    r = Control.command(agent, :approve_effect, ["er-github.pr.create", p["id"]])

    refute r["allow"]
    assert r["refusal"]["code"] == "human-consent-required"
    assert r["refusal"]["requires_human"] == true

    assert Enum.find(Approvals.all(), &(&1["id"] == p["id"]))["status"] == "pending",
           "an agent granted consent"

    assert Receipts.count() == 0
  end

  test "an agent may request an effect and wait — that is the whole point" do
    {human, agent} = fresh()
    grant_pr_create()

    r = Control.command(agent, :request_effect, ["github.pr.create", "traaviis/trvm", request()])

    refute r["allow"]
    assert length(Approvals.all()) == 1
    assert Receipts.count() == 0

    # ...and the human, on their own channel, may complete it.
    [p] = Approvals.all()
    ok = Control.command(human, :approve_effect, ["er-github.pr.create", p["id"]])
    assert ok["allow"]
    assert Receipts.count() == 1
  end

  test "revocation is a human-control command" do
    {human, agent} = fresh()

    g = Enum.find(GrantRegistry.list(), &(&1["capability"] == "github.pr.draft"))

    r = Control.command(agent, :revoke_grant, [g["id"]])
    refute r["allow"]
    assert r["refusal"]["code"] == "human-consent-required"

    assert Ampd.Conformance.authorize("github.pr.draft", "traaviis/trvm", Ampd.Gateway.ctx(), nil)["allow"],
           "an agent-channel revoke took effect"

    assert Control.command(human, :revoke_grant, [g["id"]])["revoked"] == g["id"]
    refute Ampd.Conformance.authorize("github.pr.draft", "traaviis/trvm", Ampd.Gateway.ctx(), nil)["allow"]
  end

  test "a command from an unbound handle has no actor and is refused" do
    Ampd.reset_demo()

    r = Control.command("pr-not-a-real-peer", :preflight, ["github.repo.read", "traaviis/trvm"])

    refute r["allow"]
    assert r["refusal"]["code"] == "unknown-peer"
    refute Map.has_key?(r["refusal"], "operator_detail")
  end

  # ------------------------------------------------------ approve identity
  test "approve_effect requires the two identities to agree" do
    {human, _agent} = fresh()
    grant_pr_create()
    Ampd.Conformance.exercise("pr.create")
    [p] = Approvals.all()

    # The failure mode approve_last/0 could not even express: approving a
    # proposal the human is not looking at.
    r = Control.command(human, :approve_effect, ["er-some-other-proposal", p["id"]])

    refute r["allow"]
    assert r["refusal"]["code"] == "approval-identity-mismatch"
    assert Receipts.count() == 0
    assert Enum.find(Approvals.all(), &(&1["id"] == p["id"]))["status"] == "pending"

    ok = Control.command(human, :approve_effect, ["er-github.pr.create", p["id"]])
    assert ok["allow"]
  end

  test "approve_effect refuses an approval that is not pending" do
    {human, _agent} = fresh()
    grant_pr_create()
    Ampd.Conformance.exercise("pr.create")
    [p] = Approvals.all()

    assert Control.command(human, :approve_effect, ["er-github.pr.create", p["id"]])["allow"]

    again = Control.command(human, :approve_effect, ["er-github.pr.create", p["id"]])
    refute again["allow"]
    assert again["refusal"]["code"] == "approval-not-pending"
    assert again["refusal"]["operator_detail"]["status"] == "consumed"
    assert Receipts.count() == 1
  end

  test "approve_effect refuses an approval that does not exist" do
    {human, _agent} = fresh()
    r = Control.command(human, :approve_effect, ["er-x", "ap_nope"])
    refute r["allow"]
    assert r["refusal"]["code"] == "approval-unknown"
  end

  # --------------------------------------------------- refusal projection
  test "a sealed refusal tells an agent what to do without handing it the topology" do
    {human, agent} = fresh()
    dir = Application.get_env(:ampd, :data_dir)
    GrantRegistry.close_store()
    File.rm_rf!(Path.join(dir, "grant_registry.dets"))
    Process.exit(Process.whereis(GrantRegistry), :kill)
    wait_up(GrantRegistry, fn -> GrantRegistry.sealed() end)

    general = Control.command(agent, :preflight, ["github.repo.read", "traaviis/trvm"])
    operator = Control.command(human, :operator_projection, [])

    # The agent learns enough to stop retrying and escalate...
    assert general["refusal"]["code"] == "recovery-state-missing"
    assert general["refusal"]["retryable"] == false
    assert general["refusal"]["requires_human"] == true
    assert general["refusal"]["public_message"] =~ "human recovery"
    assert general["refusal"]["correlation_id"] =~ ~r/^rf-[0-9a-f]{12}$/

    # ...and nothing about the world's identity or which store is gone.
    refute Map.has_key?(general["refusal"], "operator_detail")
    refute general["reason"] =~ "w-"
    refute general["reason"] =~ "grant_registry"

    # The operator gets the whole thing.
    seal = hd(operator["seals"])
    assert seal["reason"] =~ "grant_registry"
    assert seal["reason"] =~ "generation"

    Ampd.reset_demo()
  end

  test "an unknown command is refused rather than ignored" do
    {_human, agent} = fresh()
    r = Control.command(agent, :drop_all_grants, [])
    refute r["allow"]
    assert r["refusal"]["code"] == "unknown-command"
  end

  # ------------------------------------------------------------ read-only
  test "both projections are read-only and mutate nothing" do
    {human, agent} = fresh()
    ops = Ampd.AuthorityCoordinator.ops()

    o = Control.command(human, :operator_projection, [])
    a = Control.command(agent, :agent_projection, [])

    assert o["schema"] == "operator-projection@2"
    assert a["schema"] == "agent-projection@2"
    assert o["authority_snapshot"] =~ ~r/^sha256:/
    assert is_list(o["grants"])
    assert Ampd.AuthorityCoordinator.ops() == ops, "reading a projection changed authority"
  end

  # ------------------------------------------ every command means its name
  test "recovery_status reports, and says plainly that it cannot recover" do
    {human, _agent} = fresh()
    r = Control.command(human, :recovery_status, [])

    assert r["schema"] == "recovery-status@1"
    assert r["seals"] == []
    assert r["recoverable"] == false
    assert r["world"]["manifest_state"] == "valid"

    # The old name is gone, not aliased: a command called `recover_world`
    # that only describes damage is a name making a promise the code does
    # not keep.
    refute :recover_world in (Control.human_commands() ++ Control.agent_commands())
    assert Control.command(human, :recover_world, [])["refusal"]["code"] == "unknown-command"
  end

  test "inspect_refusal resolves a correlation id, projected per channel" do
    {human, agent} = fresh()

    # A refusal an agent actually received...
    r = Control.command(agent, :preflight, ["github.pr.merge", "traaviis/trvm", nil])
    id = r["refusal"]["correlation_id"]
    assert is_binary(id)
    assert r["refusal"]["code"] == "denied-by-default"

    # ...is retrievable by that id, and is still redacted for the agent.
    back = Control.command(agent, :inspect_refusal, [id])
    assert back["schema"] == "refusal-lookup@1"
    assert back["refusal"]["correlation_id"] == id
    assert back["refusal"]["code"] == "denied-by-default"
    refute Map.has_key?(back["refusal"], "operator_detail")

    # The operator pastes the same id and sees everything.
    seen = Control.command(human, :inspect_refusal, [id])
    assert seen["refusal"]["operator_detail"]["class"] == "destructive_admin"

    unknown = Control.command(agent, :inspect_refusal, ["rf-000000000000"])
    assert unknown["refusal"]["code"] == "refusal-unknown"
  end

  test "runtime_status answers a caller with no identity at all" do
    Ampd.reset_demo()

    s = Control.command(nil, :runtime_status, [])

    assert s["schema"] == "runtime-status@1"
    assert s["status"] == "healthy"
    assert s["world_loaded"] == true

    # And nothing else: no grants, no seals, no actor.
    assert Map.keys(s) |> Enum.sort() == ~w(schema status version world_loaded)
  end
end
