defmodule Ampd.Bootstrap do
  @moduledoc """
  The explicit initialization transition.

  **Bootstrap may create authority state only through an explicit
  initialization transition. Recovery may never infer authority from
  defaults.**

  `new_world!/0` is the production path and it mints nothing: a fresh
  `ampd` boots with zero grants, zero approvals, zero receipts, and a
  `world-meta@1` manifest proving the world was created on purpose. Every
  demo grant lives in `Ampd.TestFixture` instead, so the runtime obeys its
  own first law — *installation confers zero authority* — and so does boot.

  Ordering is load-bearing. Each store is created **and seeded** first;
  the manifest is written **last**. That is what makes the manifest mean
  "every store existed here once", and therefore what lets a later
  absence be read as *lost* rather than *new*.
  """

  @doc "The zero-authority state of every required store, in creation order."
  def initial_states do
    [
      {"session", Ampd.Session.initial()},
      {"capability_registry", Ampd.CapabilityRegistry.initial()},
      {"grant_registry", Ampd.GrantRegistry.initial()},
      {"approvals", Ampd.Approvals.initial()},
      {"receipts", Ampd.Receipts.initial()},
      {"effects", Ampd.Effects.initial()},
      # Zero lanes and zero resources. A fresh world confers nothing, and
      # that includes conferring a position to confer things from.
      {"loci", Ampd.Loci.initial()},
      {"worktrees", Ampd.Worktree.initial()}
    ]
  end

  @doc """
  Create an empty world on this machine. Idempotent: an existing world is
  left alone, and an **orphaned** one — authority stores on disk with no
  manifest — is refused rather than seeded over, because "interrupted
  first boot" and "manifest was lost" are indistinguishable and only one
  of them is safe to overwrite.
  """
  def new_world! do
    case Ampd.World.may_initialize?() do
      :ok ->
        Enum.each(initial_states(), fn {name, s} -> Ampd.Store.seed!(name, s) end)
        Ampd.World.initialize!()

      {:error, :already_initialized} ->
        Ampd.World.read()

      {:error, {state, fields}} when state != :orphaned ->
        require Logger

        Logger.warning(
          "ampd: #{banner(state)} — world-meta@1 cannot be opened by this build " <>
            "(#{complaint(state, fields)}). Not overwriting it; " <>
            "the authority subsystem will start sealed."
        )

        {state, fields}

      {:error, {:orphaned, stores}} ->
        require Logger

        Logger.warning(
          "ampd: ORPHANED-WORLD — #{length(stores)} authority store(s) on disk with no world-meta@1. " <>
            "Not seeding. The authority subsystem will start sealed."
        )

        {:orphaned, stores}
    end
  end

  defp banner(:unsupported), do: "WORLD-META-UNSUPPORTED"
  defp banner(:migration_required), do: "WORLD-META-MIGRATION-REQUIRED"
  defp banner(_), do: "WORLD-META-UNTRUSTED"

  # A version problem is not a field problem. `invalid_fields/0` judges the
  # manifest against *this* build's shape, so run against a v1 file it
  # reports `generation` missing — which is true and useless: v1 called it
  # `store_generation`, on purpose. Naming the versions says the one thing
  # an operator can act on.
  defp complaint(state, fields) when state in [:migration_required, :unsupported] do
    m = Ampd.World.read_raw() || %{}
    "declares schema_version #{inspect(m["schema_version"])}; this build is at #{Ampd.World.schema_version()}"
    |> then(&if(state == :unsupported, do: &1 <> " — this world is newer than this build", else: &1))
    |> then(&(&1 <> " · fields differing from this build's shape: #{Enum.join(fields, ", ")}"))
  end

  defp complaint(_state, fields), do: "bad or missing: #{Enum.join(fields, ", ")}"

  @doc """
  Reset this machine to a freshly initialized, zero-authority world.
  Destroys the manifest and every store first, so `new_world!/0` runs the
  real first-boot path rather than loading yesterday's grants.
  """
  def reset_world! do
    Ampd.AuthorityCoordinator.transact(fn -> do_reset_world!() end)
  end

  defp do_reset_world! do
    # Every open channel was bound to the world being destroyed. A binding
    # that outlived its world would be a peer holding an actor identity in
    # a world that never granted it one — the stale-consent problem one
    # layer down, on the identity instead of the approval.
    #
    # **Channels first, and this was missing entirely.** The comment above
    # was already the argument for it and only `Ampd.Peer` was being reset,
    # so a production world reset left `Ampd.Bridge` still listing the old
    # channels with `control_open` still true. Measured: after
    # `reset_world!/0`, two sockets still open, two channels still listed,
    # and the person **refused a control channel in the world they had just
    # reset** — `control-channel-already-claimed`, held on behalf of a
    # connection to a world that no longer exists. World generation
    # changed; capability generation did not.
    #
    # Before `Ampd.Peer.reset/0`, deliberately: the bridge detaches each
    # identity as it disposes of its channel, and it can only do that while
    # the table that holds them is still the one that minted them.
    if Process.whereis(Ampd.Bridge), do: Ampd.Bridge.reset()
    if Process.whereis(Ampd.Peer), do: Ampd.Peer.reset()
    close_all!()
    dir = Ampd.Store.data_dir()
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    new_world!()
    reload_registries!()
  end

  # dets tracks openers *per process*: closing a table from a process that
  # never opened it fails quietly, leaving the table live on an inode we
  # are about to unlink — after which every "write" lands in a file that no
  # longer has a name. So each registry closes its own handle, and only
  # then do we drop the handles this process opened via `seed!`.
  defp close_all! do
    Enum.each(initial_states(), fn {name, _} ->
      reg = registry_for(name)
      if Process.whereis(reg), do: reg.close_store()
    end)

    Enum.each(Ampd.World.authority_stores(), fn name ->
      tab = :"ampd_#{name}"

      Enum.reduce_while(1..16, :ok, fn _, _ ->
        if :dets.info(tab) == :undefined do
          {:halt, :ok}
        else
          case :dets.close(tab) do
            :ok -> {:cont, :ok}
            _ -> {:halt, :ok}
          end
        end
      end)
    end)
  end

  @doc "Point every running registry at the world currently on disk."
  def reload_registries! do
    Enum.each(initial_states(), fn {name, s} -> registry_for(name).load_state(s) end)
    :ok
  end

  defp registry_for("session"), do: Ampd.Session
  defp registry_for("capability_registry"), do: Ampd.CapabilityRegistry
  defp registry_for("grant_registry"), do: Ampd.GrantRegistry
  defp registry_for("approvals"), do: Ampd.Approvals
  defp registry_for("receipts"), do: Ampd.Receipts
  defp registry_for("effects"), do: Ampd.Effects
  defp registry_for("loci"), do: Ampd.Loci
  defp registry_for("worktrees"), do: Ampd.Worktree
end
