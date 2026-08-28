defmodule Ampd.Subscriptions do
  @moduledoc """
  **The runtime is authoritative; the UI reacts.**

  A control room that polls is a control room that is wrong for the length
  of its polling interval, and "revoke this grant" is exactly the operation
  where being wrong for 500 ms is visible. Two of C1.1's three remaining
  acceptance criteria — *UI updates without reload* and *close/reopen →
  same world* — are subscription properties, not request/response ones.

  So a channel may ask to be pushed its own projection when the world
  moves. What arrives is what `Ampd.Projection` would answer on that
  channel anyway: an agent gets `agent-projection@1` filtered to itself, the
  control room gets `operator-projection@1`. **Subscribing grants no read
  the channel did not already have** — which is why `subscribe` is on
  `:both` in `Ampd.CommandSpec` rather than needing a channel rule of its
  own.

  ## Where a revision comes from

  Not from a clock, and not from a counter this module invents.
  `Ampd.AuthorityCoordinator` is the total order every authority mutation
  passes through, and it already counts them. That count *is* the
  revision: "revision 137" means "after the 137th ordered mutation", which
  is a fact about the world rather than about this process's bookkeeping.

  Pushes are coalesced over a short window; revisions are not. A burst of
  twelve mints sends one frame, and its revision has moved by twelve — so a
  client can always tell how much happened, even though it is not told
  twelve times. Coalescing the *number* would lose that.

  ## Why a snapshot and not a delta

  At this size, resending the whole projection is correct and a delta
  protocol is a second source of truth for the same state — one that can
  disagree with the first, silently, in the direction of showing authority
  that is no longer there. The frame limit in `Ampd.Frame` is the honest
  bound on how long that stays true, and it refuses by name rather than
  going quiet when it stops being true.

  ## What a reconnecting client must throw away, and what it must retake

  Every frame carries all four continuity fields — see
  `Ampd.Projection.continuity/0`, which is where the hierarchy is stated.
  This section used to name `world_generation` as the thing to compare,
  and that was already stale when F.8.2.4 made `world_incarnation` the
  identity. Stale prose becomes stale tests.

      different incarnation         → a different world · discard the
                                      projection **and** the channel: the
                                      authority this subscription was
                                      granted under is gone
      same incarnation, new epoch   → same world, new runtime · resnapshot
      same incarnation and epoch    → revisions are comparable

  The first row is not merely a bigger version of the second, and the
  distinction is F.8.2.5's: a restore closes every channel bound to the
  ending incarnation, so a client that sees one does not reconnect — it
  reacquires. `Ampd.Projection.framed/2` fences every build here to the
  peer's own incarnation so a push can never be the thing that tells it
  otherwise.
  """
  use GenServer

  # Long enough to collapse a burst, short enough that no one perceives it.
  @coalesce_ms 15

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: {:ok, %{subs: %{}, monitors: %{}, timer: nil}}

  @doc """
  Subscribe the calling process to `peer`'s own projection.

  Returns the current snapshot, so a client is never in the position of
  having subscribed but not yet knowing what it subscribed to — the gap
  between "subscribed" and "first push" is a window in which the client
  renders nothing or renders something stale.

  **Only the `peer_id` is kept.** This module used to store the whole
  `peer@1` record and build every push from it, which made a subscription
  an *independent copy of an identity* — and identity is exactly the thing
  that must have one source. When `Ampd.Peer` crashed, the binding was
  gone and the connection's commands correctly refused `unknown-peer`,
  while the cached record went on producing Kestrel's projection for a
  channel that was no longer Kestrel's. Reproduced before it was fixed:

      a COMMAND on the old socket → unknown-peer
      an unrelated mutation       → the same socket received
                                    agent-projection@1 for actor "kestrel"

  Invalid for commands and still valid for information flow is the precise
  asymmetry the projection work exists to remove.
  """
  # **A subscription is a live lease, not a command that once succeeded.**
  #
  # The supervisor is `:one_for_one`, so this process can restart while
  # every connection stays up — and its `subs` table is in memory. Measured
  # before this existed:
  #
  #     subscribers before: 1
  #     Ampd.Subscriptions killed
  #     subscribers after restart: 0
  #     an authority mutation
  #     pushes: 0 · the control connection is still alive: true
  #
  # No EOF, no frame, no error. The host stays LIVE LOCAL forever, holding
  # a badge that means "I am being told when the world moves" while nothing
  # will ever tell it again. That is the exact failure the badge exists to
  # make impossible, and polling for it would be the wrong cure.
  #
  # So the subscriber watches this process from its own side. When this one
  # dies, the connection dies, the host sees EOF, and W.1's reacquisition
  # path — which already works — does the rest:
  #
  #     Subscriptions restart → channel closes → EOF → reacquire
  #       → resubscribe → fresh snapshot → LIVE LOCAL
  #
  # A monitor rather than a link, and in this direction only: a link would
  # mean one dying connection takes the subscription server down for
  # everyone.
  def subscribe(peer) when is_map(peer) do
    case GenServer.call(__MODULE__, {:subscribe, peer["id"], self()}) do
      %{"refusal" => _} = refused ->
        refused

      snapshot ->
        watch()
        snapshot
    end
  end

  @doc false
  # Held in the process dictionary because the watcher is the *caller* —
  # `Ampd.Transport.Connection`, which owns the mailbox the `DOWN` will
  # arrive in — and threading a ref back through `Ampd.Control.command/3`
  # would put a transport concern in the command surface.
  def watch do
    if Process.get(:ampd_subs_monitor) == nil do
      Process.put(:ampd_subs_monitor, Process.monitor(__MODULE__))
    end

    :ok
  end

  def unsubscribe(peer_id) do
    case Process.get(:ampd_subs_monitor) do
      nil -> :ok
      ref -> Process.demonitor(ref, [:flush]) && Process.delete(:ampd_subs_monitor)
    end

    GenServer.call(__MODULE__, {:unsubscribe, peer_id})
  end

  @doc "The current snapshot for a peer, without subscribing."
  def snapshot(peer) when is_map(peer), do: build(peer["id"])

  @doc """
  Announce that an ordered mutation completed.

  Called by `Ampd.AuthorityCoordinator` after every transaction, which is
  the one chokepoint all authority changes pass through. A `cast`, because
  a coordinator that blocked on notifying subscribers would make the total
  order as slow as its slowest listener — and a listener is a socket.
  """
  def changed, do: GenServer.cast(__MODULE__, :changed)

  @doc "How many subscribers are live. Diagnostic only."
  def count, do: GenServer.call(__MODULE__, :count)

  # ------------------------------------------------------------- server
  @impl true
  def handle_call({:subscribe, id, pid}, _from, st) do
    case build(id) do
      :gone ->
        {:reply, gone_refusal(id), st}

      snapshot ->
        ref = Process.monitor(pid)

        st = %{
          st
          | subs: Map.put(st.subs, id, %{pid: pid, ref: ref}),
            monitors: Map.put(st.monitors, ref, id)
        }

        {:reply, snapshot, st}
    end
  end

  def handle_call({:unsubscribe, id}, _from, st) do
    {:reply, %{"schema" => "unsubscribed@1", "peer" => id}, drop(st, id)}
  end

  def handle_call(:count, _from, st), do: {:reply, map_size(st.subs), st}

  @impl true
  def handle_cast(:changed, %{timer: nil} = st),
    do: {:noreply, %{st | timer: Process.send_after(self(), :flush, @coalesce_ms)}}

  def handle_cast(:changed, st), do: {:noreply, st}

  # **The binding is re-resolved here, every time.** A subscription is a
  # standing request to be told about a world; it is not a licence to keep
  # being told after the identity it was granted under has gone. If the
  # peer no longer resolves, the subscriber is dropped rather than served
  # from a cached name.
  @impl true
  def handle_info(:flush, st) do
    st =
      Enum.reduce(st.subs, st, fn {id, %{pid: pid}}, acc ->
        case build(id) do
          :gone -> drop(acc, id)
          snapshot -> send(pid, {:ampd_push, snapshot}) && acc
        end
      end)

    {:noreply, %{st | timer: nil}}
  end

  # A subscriber that died took its channel with it. Dropping the binding
  # here as well as in the connection's own teardown is deliberate: the
  # teardown runs only on an orderly close, and a socket process that was
  # killed never ran one.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, st) do
    case Map.fetch(st.monitors, ref) do
      {:ok, id} -> {:noreply, drop(st, id)}
      :error -> {:noreply, st}
    end
  end

  def handle_info(_, st), do: {:noreply, st}

  defp drop(st, id) do
    case Map.fetch(st.subs, id) do
      {:ok, %{ref: ref}} ->
        Process.demonitor(ref, [:flush])
        %{st | subs: Map.delete(st.subs, id), monitors: Map.delete(st.monitors, ref)}

      :error ->
        st
    end
  end

  # **The cursor and the projection are assembled together, or not at all.**
  #
  # This merged `continuity/0` with a separately built projection. Elixir
  # evaluates the cursor first, so any ordered mutation landing during the
  # build produced a frame whose revision was older than its own content.
  # Measured, with `Ampd.Session` suspended to park the build between the
  # two: cursor `revision 1`, content `revision 2`, and the grant the
  # mutation revoked already absent from the list.
  #
  # That is worse than a stale frame. A client comparing cursors sees
  # `revision 1`, decides it has already rendered this state, and the
  # correction never arrives — and here the correction is a revoked grant
  # still on the screen.
  #
  # `framed/2` also fences the peer's incarnation, which this path needs on
  # its own account: a push is a *standing* read, so it outlives the moment
  # it was authorized in by design. The peer is re-resolved every flush and
  # a handle from an ended incarnation no longer resolves — but between the
  # durable generation bump and the channel barrier it still does, and this
  # is the path that would push a new world's projection down an old
  # world's socket.
  defp build(peer_id) do
    case Ampd.Peer.resolve(peer_id) do
      nil ->
        :gone

      peer ->
        Ampd.Projection.framed(peer["world_lineage"], fn ->
          %{
            "schema" => "projection-snapshot@1",
            "channel" => to_string(peer["channel"]),
            "projection" => project_for(peer)
          }
        end)
    end
  end

  defp project_for(%{"channel" => :human_control}), do: Ampd.Projection.operator()
  defp project_for(%{"channel" => :agent, "actor" => a}) when is_binary(a), do: Ampd.Projection.agent(a)
  defp project_for(_), do: Ampd.Projection.runtime_status()

  defp gone_refusal(id) do
    %{
      "allow" => false,
      "reason" => "This channel is not bound to an identity.",
      "refusal" =>
        Ampd.Refusal.new("unknown-peer",
          component: "Ampd.Subscriptions",
          retryable: false,
          requires_human: false,
          public_message: "This channel is not bound to an identity.",
          operator_detail: %{
            "peer" => id,
            "hint" =>
              "a subscription is a standing request to be told about a world, not a licence " <>
                "to keep being told after the identity it was granted under has gone"
          }
        )
    }
  end
end
