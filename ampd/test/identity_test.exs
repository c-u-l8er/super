defmodule Ampd.IdentityTest do
  @moduledoc """
  **Connection determines actor; payload never does.**

  The grant algebra is keyed on `ctx["actor"]`. While the actor travelled
  inside the command, a caller-supplied actor *was* a caller-supplied
  authority — survivable only because nothing was networked yet. These are
  the falsifiers for the rule that replaced it, and for the projection
  boundary that rule makes possible.
  """
  use ExUnit.Case, async: false
  alias Ampd.{Control, Authority, Peer, Projection, GrantRegistry, CapabilityRegistry}

  defp request(over \\ %{}) do
    Map.merge(
      %{"er" => "er-github.pr.create", "rev" => 1, "params" => Ampd.Core.params()["pr.create"]},
      over
    )
  end

  defp grant_pr_create do
    Authority.set_draft("pr.create", true)
    Authority.commit(CapabilityRegistry.get("github")["surface"])
  end

  # ------------------------------------------------------- actor forgery
  test "a command payload has no actor to lie in, and overrides are ignored" do
    Ampd.reset_demo()
    {_human, kestrel} = Ampd.attach_pair("kestrel")

    # Everything a caller could once have asserted, asserted at once.
    forged =
      request(%{
        "actor" => "root",
        "workspace" => "someone-elses-workspace",
        "run" => "run-b9999",
        "ctx" => %{"actor" => "root"}
      })

    r = Control.command(kestrel, :preflight, ["github.repo.read", "traaviis/trvm", forged])

    # The runtime answered about Kestrel, under the session it holds.
    assert r["eligible"] == true

    ctx = Peer.authoritative_context(Peer.resolve(kestrel), forged)
    assert ctx["actor"] == "kestrel"
    assert ctx["workspace"] == "trvm"
    assert ctx["run"] == "run-b51"

    # The only thing a caller contributes is a placement *preference*, and
    # it can only narrow — `derive_placement/3` refuses it by name when it
    # does not.
    assert ctx["placement"] == nil
    assert Peer.authoritative_context(Peer.resolve(kestrel), %{"placement" => "cloud"})["placement"] == "cloud"
  end

  test "a peer bound to another identity cannot exercise Kestrel's grants" do
    Ampd.reset_demo()
    {:ok, mallory} = Peer.attach_agent("mallory")

    r = Control.command(mallory, :preflight, ["github.repo.read", "traaviis/trvm", nil])

    refute r["eligible"]
    # And it is not told that the capability is held by someone — see below.
    assert r["refusal"]["code"] == "authority-missing"
  end

  # --------------------------------------------- the human control claim
  test "the human control channel can be claimed once" do
    Ampd.reset_demo()
    assert {:ok, _first} = Peer.claim_control_channel()

    # An engine that starts after the host cannot become the person by
    # calling the same function.
    assert {:refused, r} = Peer.claim_control_channel()
    assert r["code"] == "control-channel-already-claimed"
  end

  # ------------------------------------------------ cross-agent leakage
  test "an agent projection contains no other actor's grants, approvals, or receipts" do
    Ampd.reset_demo()
    grant_pr_create()
    {human, kestrel} = Ampd.attach_pair("kestrel")

    # Kestrel does real work: a proposal, consent, a receipt.
    Control.command(kestrel, :request_effect, ["github.pr.create", "traaviis/trvm", request()])
    [p] = Ampd.Approvals.all()
    assert Control.command(human, :approve_effect, ["er-github.pr.create", p["id"]])["allow"]

    {:ok, mallory} = Peer.attach_agent("mallory")
    mine = Control.command(mallory, :agent_projection, [])

    assert mine["actor"] == "mallory"
    assert mine["grants"] == []
    assert mine["pending_approvals"] == []
    assert mine["receipts"]["recent"] == []
    assert mine["receipts"]["total"] == 0
    assert mine["effects"] == []

    # Not merely empty for Mallory — non-empty for Kestrel, from the same
    # world at the same moment. An empty projection because nothing
    # happened would prove nothing.
    his = Control.command(kestrel, :agent_projection, [])
    assert length(his["grants"]) > 0
    assert length(his["receipts"]["recent"]) == 1

    # And the global facts are absent from both.
    refute Map.has_key?(mine, "authority_snapshot")
    refute Map.has_key?(mine, "seals")
    refute Map.has_key?(mine, "reconcile_queue")
    refute Map.has_key?(his, "authority_snapshot")

    # The operator sees all of it.
    o = Control.command(human, :operator_projection, [])
    assert length(o["receipts"]["recent"]) == 1
    assert o["receipts"]["total"] == 1
    assert Map.has_key?(o, "authority_snapshot")
    assert Map.has_key?(o, "seals")
  end

  test "an agent cannot ask for another agent's projection" do
    Ampd.reset_demo()
    {_human, kestrel} = Ampd.attach_pair("kestrel")

    # There is no argument for it. `agent_projection` takes none, and the
    # actor is read off the binding — so "project mallory" is not a request
    # that can be phrased, let alone refused.
    p = Control.command(kestrel, :agent_projection, ["mallory"])
    assert p["actor"] == "kestrel"
  end

  # ---------------------------------------------------- preflight oracle
  test "preflight names the class of mismatch and not the authority behind it" do
    Ampd.reset_demo()
    {human, kestrel} = Ampd.attach_pair("kestrel")

    r = Control.command(kestrel, :preflight, ["github.repo.read", "other/repo", nil])

    refute r["eligible"]
    assert r["refusal"]["code"] == "scope-mismatch"
    assert r["refusal"]["public_message"] == "No applicable grant covers the requested resource."

    # The near-miss sentence names the resource the real grant covers.
    # The agent must not receive it, in `reason` or anywhere else.
    refute r["reason"] =~ "traaviis/trvm"
    refute Map.has_key?(r["refusal"], "operator_detail")

    # The operator gets the comparison, which is the useful half.
    id = r["refusal"]["correlation_id"]
    seen = Control.command(human, :inspect_refusal, [id])
    assert seen["refusal"]["operator_detail"]["grant_resource"] == "traaviis/trvm"
    assert seen["refusal"]["operator_detail"]["requested"] == "other/repo"
  end

  test "actor-mismatch reads as authority-missing to an agent, and as itself to an operator" do
    Ampd.reset_demo()
    {human, _k} = Ampd.attach_pair("kestrel")
    {:ok, mallory} = Peer.attach_agent("mallory")

    r = Control.command(mallory, :preflight, ["github.repo.read", "traaviis/trvm", nil])

    # Told apart from authority-missing, `actor-mismatch` says "somebody
    # else holds this" — and an agent that may ask about arbitrary
    # capabilities can enumerate the rest of the machine's authority one
    # bit at a time. So the two collapse for the agent.
    assert r["refusal"]["code"] == "authority-missing"

    seen = Control.command(human, :inspect_refusal, [r["refusal"]["correlation_id"]])
    assert seen["refusal"]["code"] == "actor-mismatch"
    assert seen["refusal"]["operator_detail"]["held_by"] == "kestrel"

    # The stored truth keeps both, and the agent's copy carries neither
    # the true code nor the field it was hidden behind.
    refute Map.has_key?(r["refusal"], "public_code")
  end

  # ------------------------------------------------------- grant request
  test "an agent's grant request creates a pending object, not a ticked box" do
    Ampd.reset_demo()
    {human, kestrel} = Ampd.attach_pair("kestrel")

    before_grants = GrantRegistry.list()
    before_draft = Control.command(human, :operator_projection, [])

    r = Control.command(kestrel, :request_grant, ["github.pr.create", "traaviis/trvm",
          %{"duration" => "workspace", "reason" => "close the argv boundary"}])

    refute r["allow"]
    q = r["grant_request"]
    assert q["schema"] == "grant-request@1"
    assert q["status"] == "pending"
    assert q["actor"] == "kestrel"
    assert q["capability"] == "github.pr.create"
    assert q["reason"] == "close the argv boundary"

    # Authority is untouched...
    assert GrantRegistry.list() == before_grants

    # ...and so is the editor the human composes consent in. This is the
    # confused deputy the split exists to prevent: an agent pre-ticking a
    # box someone else is about to click commit on.
    refute Ampd.Conformance.authorize("github.pr.create", "traaviis/trvm", Ampd.Gateway.ctx(), nil)["allow"]
    assert Control.command(human, :operator_projection, [])["grants"] == before_draft["grants"]

    # The operator sees the request, with provenance.
    assert [^q] = Control.command(human, :operator_projection, [])["grant_requests"]

    # And only a human turns it into authority.
    ok = Control.command(human, :approve_grant_request, [q["id"], "workspace"])
    assert ok["allow"]
    assert ok["granted"]["capability"] == "github.pr.create"
    assert ok["granted"]["actor"] == "kestrel"

    # A resolved request leaves the live queue and stays in the windowed
    # history: "Kestrel asked, the person said yes" is provenance, and
    # provenance is history rather than something to act on.
    op = Control.command(human, :operator_projection, [])
    assert op["grant_requests"] == []
    [resolved] = op["grant_requests_history"]["recent"]
    assert resolved["status"] == "granted"
  end

  test "an agent cannot resolve its own grant request" do
    Ampd.reset_demo()
    {_human, kestrel} = Ampd.attach_pair("kestrel")

    q = Control.command(kestrel, :request_grant, ["github.pr.create", "traaviis/trvm", %{}])["grant_request"]

    r = Control.command(kestrel, :approve_grant_request, [q["id"], "workspace"])
    refute r["allow"]
    assert r["refusal"]["code"] == "human-consent-required"

    assert hd(GrantRegistry.requests())["status"] == "pending"
  end

  # ---------------------------------------------------------- projection
  test "the runtime-status projection is the same three facts for everyone" do
    Ampd.reset_demo()
    {human, kestrel} = Ampd.attach_pair("kestrel")

    anon = Control.command(nil, :runtime_status, [])
    assert anon == Projection.runtime_status()
    assert Control.command(kestrel, :agent_projection, [])["runtime"]["status"] == "healthy"
    assert Control.command(human, :operator_projection, [])["runtime"]["status"] == "healthy"
  end
end
