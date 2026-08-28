defmodule Ampd.Ordered do
  @moduledoc """
  Makes "all authority mutations go through the coordinator" an enforced
  invariant instead of a convention.

  C1.0b.1 moved every authority-changing command behind `Ampd.Authority`,
  but the raw registry primitives stayed publicly callable inside the
  BEAM — so `GrantRegistry.revoke_domain/1` still bypassed the total order,
  and only code review stood between the architecture and that mistake.

  A GenServer receives its caller in `handle_call/3`, so the rule is
  mechanical: an authority-bearing mutation is served **only** when the
  caller is the `AuthorityCoordinator` process, which is where every
  `Ampd.Authority.*` function's work actually runs. Anything else is
  refused as `unordered-authority-mutation` and the state is untouched.

  Bootstrap has a privileged path — creating a world is authority
  creation, so it runs inside the coordinator too, which means it satisfies
  the same rule rather than being excepted from it.
  """

  @doc "The coordinator's pid, or nil before it starts."
  def coordinator, do: Process.whereis(Ampd.AuthorityCoordinator)

  @doc "True when the current process *is* the total order."
  def inside?, do: self() == coordinator()

  @doc """
  True when a `handle_call/3` `from` originates in the coordinator.

  Before the coordinator exists (very early boot) nothing is ordered and
  nothing may mutate authority.
  """
  def from_coordinator?({pid, _ref}) do
    c = coordinator()
    c != nil and pid == c
  end

  def from_coordinator?(_), do: false

  @doc """
  The refusal a mutation gets when the registry is sealed.

  This is why a sealed registry refuses rather than raising: the mutation
  now arrives *from the coordinator*, so a raise would kill the total
  order along with the registry — one lost store would become a
  node-wide outage. Refusing by name keeps the seal a seal.
  """
  def sealed_refusal(reason, op, mod) do
    # One mapping, in `Ampd.Refusal.seal_code/1`. This copy never knew
    # about `WORLD-META` at all, so an invalid manifest refused a mutation
    # under a code that pointed at the wrong file.
    code = Ampd.Refusal.seal_code(reason)

    Ampd.Refusal.new(code,
      component: inspect(mod),
      retryable: false,
      requires_human: true,
      operator_detail: %{"operation" => inspect(op), "seal" => reason}
    )
  end

  @doc "The refusal an unordered mutation gets back."
  def refusal(op, mod) do
    Ampd.Refusal.new("unordered-authority-mutation",
      component: inspect(mod),
      retryable: false,
      requires_human: false,
      public_message:
        "Authority may only be changed through Ampd.Authority, which serializes it.",
      operator_detail: %{
        "operation" => inspect(op),
        "module" => inspect(mod),
        "hint" =>
          "call Ampd.Authority.* (or run inside AuthorityCoordinator.transact/1) — " <>
            "a raw registry mutation is unordered against a concurrent effect claim"
      }
    )
  end
end
