defmodule Ampd.LineageTest do
  @moduledoc """
  **SEALED is a discontinuity in trusted world knowledge, and consent from
  before a discontinuity must never automatically become live after it.**

  The human approved one exact intent under an authority snapshot. A
  restored world cannot re-derive that snapshot, so what survives on disk
  is a record of a decision, not a live permission. These falsifiers pin
  both halves of how that is enforced: the explicit stale mark, which is
  the *explanation*, and the lineage inside the approval digest, which is
  the *enforcement* and holds even when nobody got to write the mark.
  """
  use ExUnit.Case, async: false
  alias Ampd.{Approvals, Authority, Control, World, CapabilityRegistry}

  defp request do
    %{"er" => "er-github.pr.create", "rev" => 1, "params" => Ampd.Core.params()["pr.create"]}
  end

  defp grant_pr_create do
    Authority.set_draft("pr.create", true)
    Authority.commit(CapabilityRegistry.get("github")["surface"])
  end

  defp propose do
    Ampd.reset_demo()
    {human, agent} = Ampd.attach_pair()
    grant_pr_create()
    Control.command(agent, :request_effect, ["github.pr.create", "traaviis/trvm", request()])
    [p] = Approvals.all()
    {human, agent, p}
  end

  # ------------------------------------------------- consent binds to lineage
  test "an approval carries the world it was given in" do
    {_h, _a, p} = propose()
    lin = World.lineage()

    assert p["world_generation"] == lin["generation"]
    assert p["world_installation_id"] == lin["installation_id"]
    assert p["envelope"]["world_generation"] == lin["generation"]
    assert p["envelope"]["world_installation_id"] == lin["installation_id"]
  end

  test "advancing world lineage stales the consent taken under the old one" do
    {human, _a, p} = propose()
    assert p["status"] == "pending"
    assert World.lineage()["generation"] == 1

    {meta, staled} = Authority.advance_lineage("restore", %{"generation" => 1})

    assert meta["generation"] == 2
    assert meta["restored_from_generation"] == 1
    assert p["id"] in staled

    after_ = Enum.find(Approvals.all(), &(&1["id"] == p["id"]))
    assert after_["status"] == "stale"
    assert after_["stale_reason"] =~ "generation 2"

    # **The channel the person was holding does not survive the
    # discontinuity, and this assertion is the half F.8.2.4 was missing.**
    # This test used to reach straight for `human` here and read
    # `approval-not-pending` out of the new world, which quietly asserted
    # that a generation-1 control channel still speaks in generation 2.
    r = Control.command(human, :approve_effect, ["er-github.pr.create", p["id"]])
    refute r["allow"]
    assert r["refusal"]["code"] == "unknown-peer",
           "a control channel bound before the restore still resolved after it"

    # The person reacquires, and *then* the original claim holds: the
    # consent is stale, so there is nothing left to approve.
    {human2, _agent2} = Ampd.attach_pair()

    r2 = Control.command(human2, :approve_effect, ["er-github.pr.create", p["id"]])
    refute r2["allow"]
    assert r2["refusal"]["code"] == "approval-not-pending"
    assert Ampd.Receipts.count() == 0
  end

  test "the digest enforces it even when the stale mark never lands" do
    {_h, agent, p} = propose()

    # Consent given, and then the world's lineage moves.
    Authority.grant_approval(p["id"])
    {_meta, _staled} = Authority.advance_lineage("restore", %{"generation" => 1})

    # Now sabotage the *explanation*: put the approval back to granted, as
    # if the stale mark had been lost — which is exactly what happens when
    # the approvals store is the one that was damaged, and the mark is
    # refused by name at the moment recovery needs it.
    Authority.grant_approval(p["id"])
    assert Enum.find(Approvals.all(), &(&1["id"] == p["id"]))["status"] == "granted"

    # The engine's channel died with the incarnation it was bound to, so it
    # has to reattach before it can ask for anything. Both halves matter:
    # the old handle is gone, and the digest defence below is what holds for
    # the *new* one — which is the case F.8.2.4's narrowing left uncovered.
    assert Control.command(agent, :request_effect,
             ["github.pr.create", "traaviis/trvm", request()])["refusal"]["code"] == "unknown-peer"

    {_human2, agent2} = Ampd.attach_pair()

    # The effect is still refused, because the digest cannot match across
    # a lineage change. Enforcement does not depend on the label.
    r = Control.command(agent2, :request_effect, ["github.pr.create", "traaviis/trvm", request()])
    refute r["allow"]
    assert Ampd.Receipts.count() == 0

    # A *new* pending approval opens instead — the person is asked again,
    # under the world that now exists.
    fresh = Enum.filter(Approvals.all(), &(&1["status"] == "pending"))
    assert length(fresh) == 1
    assert hd(fresh)["world_generation"] == 2
  end

  test "the effect key is stable across a lineage change, because the outside world is" do
    {_h, _a, p} = propose()
    ek = p["envelope"]["effect_key"]

    Authority.advance_lineage("restore", %{"generation" => 1})

    same =
      Ampd.Core.effect_key("github.pr.create", "traaviis/trvm", "er-github.pr.create", 1,
        Ampd.Core.params()["pr.create"])

    assert same == ek,
           "effect-intent@1 must not carry world lineage — an external adapter " <>
             "deduplicates on it, and an effect that survived a recovery is the same effect"

    # `effect-intent@1` is the envelope that key is taken over; it has no
    # world in it at all.
    env = Ampd.Core.effect_intent("github.pr.create", "traaviis/trvm", "er", 1, %{})
    refute Map.has_key?(env, "world_generation")
    refute Map.has_key?(env, "world_installation_id")
  end

  # ------------------------------------------------ the pinned divergence
  test "approval-intent@1 diverges from the frozen simulator by exactly two fields" do
    {_h, _a, p} = propose()
    beam = p["envelope"] |> Map.keys() |> MapSet.new()

    js = js_envelope_keys()

    added = MapSet.difference(beam, js) |> Enum.sort()
    removed = MapSet.difference(js, beam) |> Enum.sort()

    assert removed == [],
           "the BEAM dropped a field the frozen simulator still emits: #{inspect(removed)}"

    # World lineage is the first thing `approval-intent@1` carries that the
    # frozen browser simulator *cannot* produce: a page has no durable
    # world, so it has no lineage to bind. The vectors are unaffected —
    # none of them asserts a runtime-computed approval digest — but the two
    # engines now genuinely differ here, and that divergence is allowed to
    # be exactly this and no more.
    assert added == ["world_generation", "world_installation_id"],
           "approval-intent@1 drifted from the frozen simulator: #{inspect(added)}"
  end

  # Read the envelope the frozen engine actually builds, rather than a
  # hand-copied list — a list copied into a test agrees with the engine
  # only until someone edits one of them.
  defp js_envelope_keys do
    # `site/` is the deployable website and the frozen simulator lives in it.
    path = Path.expand("../../site/app-prototype.html", __DIR__)
    src = File.read!(path)
    marker = "const env={ schema:'approval-intent@1'"

    case :binary.match(src, marker) do
      :nomatch ->
        flunk("the frozen simulator's approval-intent@1 envelope moved — #{path}")

      {i, _} ->
        rest = binary_part(src, i, byte_size(src) - i)
        {j, _} = :binary.match(rest, "};")
        block = binary_part(rest, 0, j)

        ~r/[{,]\s*([a-z_]+)\s*(?=[:,])/
        |> Regex.scan(block)
        |> Enum.map(&List.last/1)
        |> MapSet.new()
    end
  end
end
