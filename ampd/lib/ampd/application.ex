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

        ok

      other ->
        other
    end
  end
end
