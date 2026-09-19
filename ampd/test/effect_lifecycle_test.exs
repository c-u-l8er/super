defmodule Ampd.EffectLifecycleTest do
  @moduledoc """
  The journal's transition table, enforced — table-driven, through the
  public API, on the real participants.

  Review of `58c224e` reproduced two forbidden edges through the public API
  with a live, valid lease: `COMMITTED → ATTEMPTED` appended a second attempt
  and `CLAIMED → COMMITTED` committed with no ATTEMPTED record.
  `Ampd.Effects.Contract.legal_transition?/2` existed and nothing called
  it. Every post-creation journal write now passes `Ampd.Effects.admit/3`
  inside `transition/4` — PROPOSED is created by the proposal constructor,
  which hard-codes it, and is tested apart. These tests exercise every legal
  edge and the illegal edges
  the review named, and for every refusal assert that the journal, the
  attempts, the result, the lease, the participant stores and the witness
  position are unchanged.
  """
  use ExUnit.Case, async: false
  alias Ampd.{Authority, AuthorityCoordinator, Effects, Gateway}

  @cap "github.pr.draft"
  @resource "traaviis/trvm"

  defp req,
    do: %{"er" => "er-github.pr.draft", "rev" => 1, "params" => Ampd.Core.params()["pr.draft"]}

  defp world! do
    Ampd.reset_demo()
    Authority.revoke_domain(@cap)
    Authority.one_shot(@cap)
    :ok
  end

  # Drive one effect to `state` through the public API; return {effect_id, lease | nil}.
  defp effect_in(state) do
    world!()

    case state do
      s when s in ["PROPOSED", "AUTHORIZED", "APPROVED"] ->
        AuthorityCoordinator.transact(fn ->
          auth = Gateway.decide(@cap, @resource, Gateway.ctx(), req())

          e =
            Effects.propose(%{
              "effect_key" => auth["effect_key"],
              "capability" => @cap,
              "pack" => "github@1.4.2",
              "actor" => "kestrel",
              "resource" => @resource,
              "request_id" => "er-github.pr.draft",
              "request_revision" => 1,
              "request" => Ampd.Core.params()["pr.draft"],
              "branch" => "B2",
              "grant_ref" => auth["grant_ref"],
              "approval_ref" => nil
            })

          if s in ["AUTHORIZED", "APPROVED"],
            do: Effects.authorized(e["id"], %{"grant_ref" => auth["grant_ref"]})

          if s == "APPROVED", do: Effects.approved(e["id"], %{"approval_ref" => "ap_test"})
          {e["id"], nil}
        end)

      "CLAIMED" ->
        {:claimed, _auth, e, lease} =
          Authority.claim_and_consume(@cap, @resource, Gateway.ctx(), req())

        {e["id"], lease}

      "ATTEMPTED" ->
        {id, lease} = effect_in("CLAIMED")
        {:ok, _, _} = Effects.attempt(lease, "lifecycle")
        {id, lease}

      "COMMITTED" ->
        {id, lease} = effect_in("ATTEMPTED")
        %{"state" => "COMMITTED"} = Effects.commit(lease, nil)
        {id, lease}

      "FAILED" ->
        {id, lease} = effect_in("ATTEMPTED")
        %{"state" => "FAILED"} = Effects.fail(id, "lifecycle")
        {id, lease}

      "UNKNOWN" ->
        {id, lease} = effect_in("ATTEMPTED")
        %{"state" => "UNKNOWN"} = Effects.unknown(id, "lifecycle")
        {id, lease}
    end
  end

  # The public entry point for each target state.
  defp go(to, id, lease) do
    case to do
      "AUTHORIZED" -> Effects.authorized(id, %{})
      "APPROVED" -> Effects.approved(id, %{"approval_ref" => "ap_none"})
      "CLAIMED" -> AuthorityCoordinator.transact(fn -> Effects.claim(id) end)
      "ATTEMPTED" -> Effects.attempt(lease, "lifecycle-again")
      "COMMITTED" -> Effects.commit(lease, :again)
      "FAILED" -> Effects.fail(id, "lifecycle-again")
      "UNKNOWN" -> Effects.unknown(id, "lifecycle-again")
    end
  end

  # Everything a refused edge must leave alone.
  defp observe(id) do
    e = Effects.get(id)

    %{
      journal: e && Enum.map(e["history"], & &1["state"]),
      state: e && e["state"],
      attempts: e && e["attempts"],
      result: e && e["result"],
      reason: e && e["reason"],
      effects: Effects.all(),
      stores: Effects.stores(),
      fences: {Ampd.GrantRegistry.fence(), Ampd.Receipts.fence(), Ampd.Approvals.fence()},
      tseq: Effects.incarnation()["tseq"],
      leases: owner_leases()
    }
  end

  # The journal owner's in-memory lease table and its counters, read for the
  # unchanged assertion (a refused edge may not touch them either).
  defp owner_leases do
    inc = :sys.get_state(Effects).inc
    {inc.leases, inc.n_lease, inc.n_ticket, inc.terminals}
  end

  defp refused?({:refused, %{"code" => code}}, expected), do: code == expected
  defp refused?(_, _), do: false

  # ---------------------------------------------------------- legal edges
  @legal [
    {"PROPOSED", "AUTHORIZED"},
    {"AUTHORIZED", "CLAIMED"},
    {"AUTHORIZED", "APPROVED"},
    {"APPROVED", "CLAIMED"},
    {"CLAIMED", "ATTEMPTED"},
    {"CLAIMED", "FAILED"},
    {"CLAIMED", "UNKNOWN"},
    {"ATTEMPTED", "COMMITTED"},
    {"ATTEMPTED", "FAILED"},
    {"ATTEMPTED", "UNKNOWN"},
    {"COMMITTED", "FAILED"},
    {"COMMITTED", "UNKNOWN"}
  ]

  for {from, to} <- @legal do
    test "legal · #{from} → #{to} is admitted and journaled" do
      {id, lease} = effect_in(unquote(from))
      before = observe(id)
      r = go(unquote(to), id, lease)
      refute match?({:refused, _}, r), "legal edge refused: #{inspect(r)}"
      after_ = observe(id)
      assert after_.journal == before.journal ++ [unquote(to)]
      assert after_.state == unquote(to)
      assert after_.tseq > before.tseq, "a legal transition writes a witness line"
    end
  end

  # Creation is not a transition. `nil → PROPOSED` is the table's first edge and
  # the proposal constructor hard-codes PROPOSED: nothing else can be created,
  # so the edge is safe by construction rather than by `transition/4`, which
  # creation does not pass. Claimed narrowly and tested here.
  test "creation · a proposal is created PROPOSED, and PROPOSED is the only edge from nothing" do
    {id, _} = effect_in("PROPOSED")
    e = Effects.get(id)
    assert e["state"] == "PROPOSED"
    assert Enum.map(e["history"], & &1["state"]) == ["PROPOSED"]
    assert Ampd.Effects.Contract.legal_transition?(nil, "PROPOSED")

    refute Enum.any?(
             ~w(AUTHORIZED APPROVED CLAIMED ATTEMPTED COMMITTED FAILED UNKNOWN),
             &Ampd.Effects.Contract.legal_transition?(nil, &1)
           )

    # and the constructor cannot be asked for another state: it takes no state argument
    assert {:propose, 1} in Ampd.Effects.__info__(:functions)
  end

  # -------------------------------------------------------- illegal edges
  # {from, to, the code the refusal must name}
  @illegal [
    {"PROPOSED", "COMMITTED", "write-unmediated"},
    {"PROPOSED", "CLAIMED", "journal-transition-illegal"},
    {"AUTHORIZED", "AUTHORIZED", "journal-transition-illegal"},
    {"CLAIMED", "COMMITTED", "journal-transition-illegal"},
    {"CLAIMED", "AUTHORIZED", "journal-transition-illegal"},
    {"COMMITTED", "ATTEMPTED", "journal-transition-illegal"},
    {"COMMITTED", "COMMITTED", "journal-transition-illegal"},
    {"COMMITTED", "AUTHORIZED", "journal-transition-illegal"},
    {"FAILED", "AUTHORIZED", "journal-transition-illegal"},
    {"FAILED", "FAILED", "journal-transition-illegal"},
    {"FAILED", "UNKNOWN", "journal-transition-illegal"},
    {"UNKNOWN", "AUTHORIZED", "journal-transition-illegal"},
    {"UNKNOWN", "FAILED", "journal-transition-illegal"},
    {"UNKNOWN", "UNKNOWN", "journal-transition-illegal"}
  ]

  for {from, to, code} <- @illegal do
    test "illegal · #{from} → #{to} is refused (#{code}) and changes nothing" do
      {id, lease} = effect_in(unquote(from))
      before = observe(id)
      r = go(unquote(to), id, lease)
      assert refused?(r, unquote(code)), "expected #{unquote(code)}, got #{inspect(r, limit: 8)}"
      assert observe(id) == before, "a refused edge changed observable state"
    end
  end

  # PROPOSED → COMMITTED has no lease to present (issuance is at CLAIM), so the
  # public path refuses it as unmediated before the journal is consulted. The
  # journal's own answer for that edge is checked here directly.
  test "illegal · PROPOSED → COMMITTED at the journal is journal-transition-illegal" do
    {id, _} = effect_in("PROPOSED")

    assert {:refused, %{"code" => "journal-transition-illegal"}} =
             Effects.admit(:sys.get_state(Effects), id, "COMMITTED")
  end

  # ATTEMPTED → ATTEMPTED (a second attempt on a live lease) and FAILED / UNKNOWN
  # after retirement: the lease refuses first, the journal would refuse second.
  test "illegal · ATTEMPTED → ATTEMPTED is refused and appends no attempt" do
    {id, lease} = effect_in("ATTEMPTED")
    before = observe(id)
    assert refused?(Effects.attempt(lease, "again"), "journal-transition-illegal")
    assert observe(id) == before
    assert length(Effects.get(id)["attempts"]) == 1
  end

  test "illegal · FAILED → ATTEMPTED and UNKNOWN → COMMITTED are refused by the lease (closed), journal untouched" do
    {id, lease} = effect_in("FAILED")
    before = observe(id)
    assert refused?(Effects.attempt(lease, "again"), "write-lease-closed")
    assert observe(id) == before
    {id2, lease2} = effect_in("UNKNOWN")
    before2 = observe(id2)
    assert refused?(Effects.commit(lease2, :x), "write-lease-closed")
    assert observe(id2) == before2
  end

  test "illegal · an unknown effect id is refused by name and changes nothing" do
    world!()
    before = observe("ef_9999")
    assert refused?(Effects.fail("ef_9999", "x"), "effect-unknown")
    assert refused?(Effects.unknown("ef_9999", "x"), "effect-unknown")
    assert refused?(Effects.authorized("ef_9999", %{}), "effect-unknown")
    assert observe("ef_9999") == before
  end

  # The refused FAILED / UNKNOWN must not have retired anything at a participant.
  test "illegal · a refused FAILED retires nothing at the participants" do
    {id, lease} = effect_in("FAILED")
    r = Effects.fail(id, "again")
    assert refused?(r, "journal-transition-illegal")
    # the lease was retired once, by the legal FAILED; the fences hold exactly that
    assert Map.keys(Ampd.Receipts.fence()["retired"]) == [lease["lease_id"]]
    assert Map.keys(Ampd.GrantRegistry.fence()["retired"]) == [lease["lease_id"]]
  end
end
