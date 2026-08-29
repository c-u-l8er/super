defmodule Ampd.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # The world manifest is written before any registry opens, so a store
    # that is absent afterwards is *lost*, not new.
    Ampd.Bootstrap.new_world!()

    # Before any child that can tick it — see `Ampd.ViewClock`.
    Ampd.ViewClock.init()

    children = [
      # Neither of these holds authority, and neither is durable. The
      # refusal ring is a bounded diagnostic; a peer binding is a live
      # channel, and one that survived a restart would be a connection
      # that outlived its socket. They start first because everything
      # below can mint a refusal on the way up.
      Ampd.RefusalLog,
      Ampd.Peer,
      Ampd.AuthorityCoordinator,
      # Subscriptions holds no authority either: it pushes each channel the
      # projection that channel could already ask for. It starts after the
      # coordinator because the coordinator notifies it, and a notification
      # to a process that is not up yet is checked for rather than assumed.
      Ampd.Subscriptions,
      Ampd.Session,
      Ampd.CapabilityRegistry,
      Ampd.GrantRegistry,
      Ampd.Approvals,
      Ampd.Receipts,
      Ampd.Effects,
      # The semantic objects, and the trusted edge that resolves one of
      # them to a directory. After the registries because establishing a
      # capability reads the grant table, and before the bridge because a
      # Lane must be answerable the moment a channel can ask about one.
      Ampd.Loci,
      Ampd.Worktree,
      # **Not an authority store.** It caches a measurement of the machine
      # that performs effects — which host binary, which git, under which
      # hardening policy — so that `Ampd.Locus.check/2` can bind that into
      # the embodiment basis without forking on every authority check.
      # Losing it costs one re-measurement, which is why it holds no dets
      # table and is absent from `Ampd.World.authority_stores/0`.
      Ampd.Embodiment,
      # Last: the bridge creates the sockets the outside world arrives on,
      # and nothing should be reachable before the registries that answer
      # it are up. A channel that accepted a connection during boot would
      # be a channel answering out of a half-built world.
      {Ampd.Bridge, bridge_fd: System.get_env("AMPD_BRIDGE_FD")}
    ]

    result =
      Supervisor.start_link(children,
        strategy: :one_for_one,
        name: Ampd.Supervisor,
        max_restarts: 100,
        max_seconds: 5
      )

    # Anything caught mid-flight by the last shutdown is UNKNOWN, not lost
    # and not committed. Queue it rather than guess.
    case result do
      {:ok, _} = ok ->
        moved = Ampd.Effects.recover!()

        if moved != [] do
          require Logger
          Logger.warning("ampd: #{length(moved)} effect(s) recovered as UNKNOWN — reconcile required: #{inspect(moved)}")
        end

        # Same rule, one layer out — and it takes all three durable stores
        # to apply. Establishment writes to `worktrees`, `receipts` and
        # `loci`, so the state a crash leaves is a *combination* that no
        # single store can see. `Ampd.Locus.reconcile/0` is the only place
        # that can, and it never promotes: a cut it cannot interpret
        # becomes RECOVERY_REQUIRED for a person, not `active`.
        unresolved = Ampd.Authority.reconcile_worktrees()

        if unresolved != [] do
          require Logger

          Logger.warning(
            "ampd: #{length(unresolved)} worktree(s) need recovery — " <>
              Enum.map_join(unresolved, "; ", fn {ref, state, why} -> "#{ref} #{state}: #{why}" end)
          )
        end

        ok

      other ->
        other
    end
  end
end
