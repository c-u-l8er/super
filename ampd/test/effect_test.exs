defmodule Ampd.EffectTest do
  @moduledoc """
  Effect atomicity. The question C1.0a left open was not "is the store
  durable" but:

  > What durable state exists if the process dies halfway through
  > consuming human consent?

  These falsifiers answer it. The journal is written before the world is
  touched, so a crash always leaves a record that names what was
  *intended* — never a half-applied registry nobody can interpret.
  """
  use ExUnit.Case, async: false
  alias Ampd.{CapabilityRegistry, Receipts, Effects, Approvals}

  defp grant_pr_create do
    Ampd.Authority.set_draft("pr.create", true)
    Ampd.Authority.commit(CapabilityRegistry.get("github")["surface"])
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

  test "a committed effect walks the whole ladder in order" do
    Ampd.reset_demo()
    grant_pr_create()
    Ampd.Conformance.exercise("pr.create")
    Ampd.Conformance.approve_last()

    e = List.last(Effects.all())
    states = Enum.map(e["history"], & &1["state"])

    assert states == ~w(PROPOSED AUTHORIZED APPROVED CLAIMED ATTEMPTED COMMITTED),
           "effect ladder was #{inspect(states)}"

    assert e["state"] == "COMMITTED"
    assert Receipts.count() == 1
    assert Receipts.last_of_kind("capability-effect-receipt@1")["effect_ref"] == e["id"]
  end

  test "the attempt record is durable before the adapter, and carries the idempotency key" do
    Ampd.reset_demo()
    grant_pr_create()
    Ampd.Conformance.exercise("pr.create")
    Ampd.Conformance.approve_last()

    e = List.last(Effects.all())
    [attempt] = e["attempts"]

    assert attempt["kind"] == "effect-attempt@1"
    assert attempt["idempotency_key"] == e["idempotency_key"]
    assert String.starts_with?(e["idempotency_key"], "sha256:"),
           "the idempotency key must be the real intent digest, not a label"

    # The key an external adapter would deduplicate on is the same digest
    # consent was bound to — that is the only reason UNKNOWN is recoverable.
    assert attempt["idempotency_key"] == Receipts.last_of_kind("capability-effect-receipt@1")["idempotency_key"]
  end

  test "an effect in flight at crash time recovers as UNKNOWN, never as committed or absent" do
    Ampd.reset_demo()
    grant_pr_create()
    Ampd.Conformance.exercise("pr.create")
    Ampd.Conformance.approve_last()
    e = List.last(Effects.all())

    # Re-enter ATTEMPTED, then die there.
    Effects.attempt(e["id"], "github.rest")
    Process.exit(Process.whereis(Effects), :kill)
    wait_up(Effects, fn -> Effects.all() end)

    recovered = Effects.get(e["id"])
    assert recovered != nil, "the effect vanished with the process"
    assert recovered["state"] == "ATTEMPTED", "the durable state before recovery should be what was written"

    moved = Effects.recover!()
    assert e["id"] in moved

    after_recover = Effects.get(e["id"])
    assert after_recover["state"] == "UNKNOWN"
    assert after_recover["needs_reconcile"] == true
    assert after_recover["reason"] =~ "may or may not have run"
    assert Effects.reconcile_queue() |> Enum.map(& &1["id"]) == [e["id"]]
  end

  test "an UNKNOWN effect cannot be re-claimed — that is the double-effect bug" do
    Ampd.reset_demo()
    grant_pr_create()
    Ampd.Conformance.exercise("pr.create")
    Ampd.Conformance.approve_last()
    e = List.last(Effects.all())

    Effects.attempt(e["id"], "github.rest")
    Effects.recover!()
    assert Effects.get(e["id"])["state"] == "UNKNOWN"

    assert {:error, why} =
             Ampd.AuthorityCoordinator.transact(fn -> Effects.claim(e["id"]) end)

    assert why =~ "effect-unreconciled"
    assert why =~ e["idempotency_key"], "the refusal must name the key to reconcile against"

    # And the claim is itself an ordered operation: reaching it outside the
    # coordinator is refused before the effect's own state is consulted.
    assert {:refused, r} = Effects.claim(e["id"])
    assert r["code"] == "unordered-authority-mutation"
  end

  test "a claim is exclusive: the second one is refused by name" do
    Ampd.reset_demo()
    grant_pr_create()
    Ampd.Conformance.exercise("pr.create")
    Ampd.Conformance.approve_last()
    e = List.last(Effects.all())

    assert {:error, why} =
             Ampd.AuthorityCoordinator.transact(fn -> Effects.claim(e["id"]) end)

    assert why =~ "effect-settled"
  end

  test "consent is spent only after the claim is durable" do
    Ampd.reset_demo()
    grant_pr_create()
    Ampd.Conformance.exercise("pr.create")

    [pending] = Approvals.all()
    assert pending["status"] == "pending"

    Ampd.Conformance.approve_last()
    e = List.last(Effects.all())

    claimed_at = Enum.find_index(e["history"], &(&1["state"] == "CLAIMED"))
    attempted_at = Enum.find_index(e["history"], &(&1["state"] == "ATTEMPTED"))

    assert claimed_at < attempted_at,
           "the claim must be durable before anything external is attempted"

    assert List.last(Approvals.all())["status"] == "consumed"
    assert e["approval_ref"] == List.last(Approvals.all())["id"]
  end

  test "the effect journal survives its own process death" do
    Ampd.reset_demo()
    grant_pr_create()
    Ampd.Conformance.exercise("pr.create")
    Ampd.Conformance.approve_last()
    n = Effects.count()
    assert n == 1

    Process.exit(Process.whereis(Effects), :kill)
    wait_up(Effects, fn -> Effects.count() end)

    assert Effects.count() == n, "the effect journal lost an entry on restart"
    assert List.last(Effects.all())["state"] == "COMMITTED"
  end
end
