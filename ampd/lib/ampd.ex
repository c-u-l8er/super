defmodule Ampd do
  @moduledoc """
  ampd — the [&] Super authority runtime (C1).

  Registries + gateway + effect journal on OTP; semantics conformant to
  the frozen simulator via `conformance/authority-vectors.json`.

  Two resets, deliberately named apart:

  * `reset/0` — a production world. **Zero authority.**
  * `reset_demo/0` — the C0 conformance world, explicitly seeded.

  Boot never takes the second path. That separation is the runtime
  obeying its own first law rather than merely publishing it.
  """

  @doc "A fresh, explicitly initialized, zero-authority world."
  def reset do
    Ampd.Bootstrap.reset_world!()
    :ok
  end

  @doc "The known C0 conformance world — demo grants, seeded on purpose."
  def reset_demo do
    Ampd.TestFixture.seed_demo!()
    :ok
  end

  @doc """
  Bind a channel to an agent identity, and one to the person.

  This is what the Rust host will do at boot: claim the single control
  channel first, then bind an agent channel as it spawns each engine. It
  returns `{control_peer, agent_peer}` for the common one-agent case.

  It is here rather than in a test helper because the ordering is the
  point — the control channel is claimed **before** any engine exists, so
  an engine that starts later cannot claim one.
  """
  def attach_pair(actor \\ "kestrel") do
    {:ok, control} = Ampd.Peer.claim_control_channel()
    {:ok, agent} = Ampd.Peer.attach_agent(actor)
    {control, agent}
  end

  @doc """
  Every unresolved recovery seal on this machine, by registry. Empty means
  the world's authority state is fully accounted for.
  """
  def seals do
    [
      {Ampd.Session, Ampd.Session.sealed()},
      {Ampd.CapabilityRegistry, Ampd.CapabilityRegistry.sealed()},
      {Ampd.GrantRegistry, Ampd.GrantRegistry.sealed()},
      {Ampd.Approvals, Ampd.Approvals.sealed()},
      {Ampd.Receipts, Ampd.Receipts.sealed()},
      {Ampd.Effects, Ampd.Effects.sealed()},
      # Both joined `Ampd.World.authority_stores/0` in D.1.1, so both can
      # seal. A seals report that omitted them would report a fully
      # accounted-for world while every Lane and every worktree resource
      # was unreachable — the exact shape of incompleteness this function
      # exists to make impossible.
      {Ampd.Loci, Ampd.Loci.sealed()},
      {Ampd.Worktree, Ampd.Worktree.sealed()}
    ]
    |> Enum.reject(&(elem(&1, 1) == nil))
  end
end
