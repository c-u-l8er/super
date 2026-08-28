defmodule Ampd.TestFixture do
  @moduledoc """
  The C0 conformance world — a *fixture*, explicitly seeded, never a boot
  default.

  The three GitHub grants the conformance vectors rely on
  (`repo.read`, `issue.read`, `pr.draft`) live here because they are demo
  authority. Production boot goes through `Ampd.Bootstrap.new_world!/0`
  and mints nothing; this function is the only thing that hands a fresh
  world any authority, and it says so in its name.
  """

  @doc "Reset to a zero-authority world, then seed the known C0 conformance world."
  def seed_demo! do
    Ampd.AuthorityCoordinator.transact(fn ->
      Ampd.Bootstrap.reset_world!()
      Ampd.GrantRegistry.load_state(Ampd.GrantRegistry.demo_state())
    end)

    :ok
  end
end
