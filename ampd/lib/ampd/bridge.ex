defmodule Ampd.Bridge do
  @moduledoc """
  The runtime **adopts** channels. It does not create, publish, or listen
  for them.

  This is where `Ampd.Peer`'s law stops being a convention:

      Agent identity is assigned by the runtime, never claimed in a
      command payload.

  `Ampd.Peer` made a command's actor come from a binding rather than from
  its arguments. The first C1.1 transport made that binding a socket file:
  a listener created *for* Kestrel, in a `0700` directory, accepting once.
  Which meant the law actually said **first connector wins**, and every
  process on the machine runs as the same user and can `readdir`.

  Now there is nothing to find. The host passes a descriptor, labelled,
  over a bridge it was born holding — see `Ampd.Transport` — and this
  module associates the label with the channel. **Possession of the
  descriptor is the capability.**

  ## What is still not enforced, stated plainly

  Inside the BEAM, any code can call `adopt_channel/3` and bind a
  descriptor to any actor. That is not a hole this layer can close: the
  runtime *is* the thing trusted to name identities, and a runtime that
  could not name them would have none to enforce.

  The boundary has moved as far as it can go — from *every message*
  (C1.1.0), to *every attach* (C1.1.1), to *the moment a channel is
  created* (C1.1), to **a capability that cannot be obtained by any process
  the host did not hand it to** (here). Beyond this is peer-credential
  mythology: a `pid → agent` table that races, or a same-UID claim that
  proves nothing.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    # The bridge descriptor the host handed us at spawn. Its number is
    # passed in the environment because a number is not a secret — holding
    # the descriptor is the capability, and an integer naming one you do
    # not hold is worth nothing.
    #
    # It goes through the same adoption as a received one. It arrives
    # *inheritable* — the host clears `FD_CLOEXEC` deliberately so it
    # survives `exec` into us — so adopting it confines it and closes the
    # raw number, and the runtime holds exactly one, close-on-exec
    # reference to the bridge rather than two of unclear ownership.
    case bridge_fd(opts) do
      nil ->
        {:ok, %{channels: %{}, control_open: false, bridge: nil, effect: nil}}

      fd ->
        if admissible?(fd, Ampd.NativeFd.available?()) do
          bridge =
            case Ampd.NativeFd.adopt_socket(fd) do
              {:ok, sock} ->
                {:ok, pid} = Ampd.Transport.HostBridge.start(sock)
                pid

              :error ->
                nil
            end

          {:ok, %{channels: %{}, control_open: false, bridge: bridge, effect: nil}}
        else
          IO.puts(:stderr, """
          AMPD REFUSES TO OPEN THE BRIDGE — there is no descriptor sink.

          `Ampd.NativeFd` did not load, and it is the only thing in this
          runtime that can dispose of a descriptor received over
          SCM_RIGHTS: OTP will not close what it did not create. Opening
          the bridge without it means every channel, every surplus
          descriptor and every rejected command leaks one, permanently.

          Rebuild: `mix compile` (priv/ampd_fd_nif.so).
          """)

          {:stop, :no_descriptor_sink}
        end
    end
  end

  @doc false
  # **The bridge is the only source of raw descriptors inside the runtime,
  # and the sink is the only disposal.** One without the other is a
  # runtime that leaks a descriptor per command and cannot say so, which
  # is precisely the state F.8.1 shipped in. Refuse instead.
  def admissible?(fd, sink_available?), do: is_integer(fd) and fd >= 0 and sink_available?

  defp bridge_fd(opts) do
    case Keyword.get(opts, :bridge_fd) || System.get_env("AMPD_BRIDGE_FD") do
      nil -> nil
      n when is_integer(n) -> n
      s when is_binary(s) -> case Integer.parse(s) do
                               {n, ""} -> n
                               _ -> nil
                             end
    end
  end

  @doc """
  Bind a descriptor to an identity and start serving it.

  `kind` is `:agent` (with an `actor`) or `:human_control`. Returns
  `{:ok, pid, peer_id}` or `{:refused, refusal@1}`.

  Nothing read from the descriptor contributes to the identity. The label
  arrives beside the descriptor, from the host, and this is the only place
  the two are associated.

  **This call consumes its channel argument exactly once**, into a live
  connection or into a sink, and that holds for every refusal as well as
  every success. A caller hands over the channel; it does not get it back
  and must not close it. F.8.2 held this everywhere except one refusal —
  see `handle_call/3`.
  """
  def adopt_channel(fd_or_socket, kind, actor \\ nil),
    do: GenServer.call(__MODULE__, {:adopt, fd_or_socket, kind, actor}, 10_000)

  @doc "Every channel this bridge is serving, for the operator projection."
  def list, do: GenServer.call(__MODULE__, :list)

  # =================================================== D.1.3a · the effect endpoint
  @doc """
  Take possession of the **host effect endpoint** and record the
  incarnation it belongs to.

  This module already holds the descriptors that carry *identity*. D.1.3a
  gives it the one that carries *mechanism*, and deliberately does not
  build a second place to keep descriptors: a `EffectChannelRegistry`
  would have been a new supervised process, a new descriptor owner and a
  new disposal path for a fact that already had an owner. The WEK
  measurement is that it is not there.

  `incarnation` is an `effect-channel@1` map minted by whoever created the
  pair — the host in production, the harness in a test. It is **ephemeral
  and is not authority**: it dies with the channel, nothing durable
  references it, and a replacement channel gets a new one. Its only job is
  to let an observation from a previous incarnation be recognised and
  refused rather than accidentally satisfying a request on this one.

  Consumes the argument exactly once, like `adopt_channel/3`: an endpoint
  that replaces an existing one disposes of the one it replaces, because a
  bridge holding two effect endpoints has no way to say which is current.
  """
  def bind_effect_endpoint(fd_or_socket, incarnation) when is_map(incarnation),
    do: GenServer.call(__MODULE__, {:bind_effect, fd_or_socket, incarnation}, 10_000)

  @doc """
  The possessed endpoint and its incarnation, or `nil`.

  **In-BEAM this is reachable by name and that is not claimed otherwise.**
  `Ampd.Bridge`'s own moduledoc has said since C1.1 that any code inside
  the runtime can bind a descriptor to any actor; the same is true here,
  and for the same reason — the runtime *is* the thing trusted to hold
  descriptors. What D.1.3a moves is the **production effect path**, which
  no longer resolves an executable by pathname. Same-UID in-process
  reachability is D.1.3b's question and is not answered here.
  """
  def effect_endpoint, do: GenServer.call(__MODULE__, :effect_endpoint)

  @doc """
  Drop the effect endpoint — the channel is gone.

  **Never a reason to replay.** This closes ampd's end and forgets the
  incarnation; it says nothing about whether an effect submitted on it
  happened. `Ampd.Worktree.EffectChannel` is where that rule lives.
  """
  def drop_effect_endpoint, do: GenServer.call(__MODULE__, :drop_effect)

  @doc """
  Close every channel and free the control claim.

  A world-lifecycle operation, not a test hook — the same one
  `Ampd.Peer.reset/0` is: re-initializing a world invalidates every open
  channel, and a channel bound to a world that no longer exists is the
  stale-consent problem one layer down.
  """
  # **The caller's deadline must exceed the server's own budget.**
  #
  # This was a bare `GenServer.call/2` — a 5 s client deadline in front of a
  # handler that waits up to 2 s *per channel*. Three wedged channels is
  # already 6 s, so the caller times out and **raises inside the
  # transaction that called it**. Measured while building W.1's witnesses:
  # `Ampd.Authority.advance_lineage/2` bumped the generation, called here,
  # and died — leaving a world at generation 2 whose channels were never
  # closed, which is precisely the state F.8.2.5's barrier exists to make
  # unreachable.
  #
  # So the wait is now one budget for the whole teardown rather than a
  # fresh one per channel, and the call is given room above it. A stuck
  # client can no longer make a world advance fail; it can only make the
  # advance stop waiting for it, which is the correct trade — the socket is
  # closed either way, and it is closed by the process that owns it.
  @reset_budget_ms 3_000

  def reset, do: GenServer.call(__MODULE__, :reset, @reset_budget_ms + 7_000)

  @doc false
  # **Called by a connection when it ends, and this is not optional.**
  #
  # "There is an active human control channel" is held in two places, freed
  # by two different events: `Ampd.Peer`'s claim goes when the peer
  # detaches, and this module's `control_open` used to be cleared only by
  # an explicit close. So a host that simply closed its socket — which is
  # what closing a window is — freed one and not the other, and could never
  # take the control channel again.
  #
  # Found by running it: the Elixir tests closed the channel by hand, so
  # the two locks never had a chance to disagree. A separate OS process
  # just closed its descriptor, the way a real host does.
  def channel_closed(pid), do: GenServer.cast(__MODULE__, {:closed, pid})

  # ------------------------------------------------------------- server
  #
  # **One clause, because the law is about exits.**
  #
  #     Every `adopt_channel/3` call consumes its channel argument exactly
  #     once: into a live connection, or into a sink.
  #
  # This was two clauses, and the first one — the fast refusal when the
  # control channel is already claimed — read the descriptor as `_fd` and
  # returned. Discarded syntactically, not physically: the descriptor was
  # already in this process's table, courtesy of `SCM_RIGHTS`, and nothing
  # ever closed it. **A leak per refused claim, measured at 100 for 100**,
  # on a path an adversary reaches by asking for something it is not
  # allowed to have.
  #
  # F.8.2 called the sink "one sink, three call sites, no fourth exit" and
  # this was the fourth. A second clause is how it got there, so there is
  # no longer a second clause: the refusal is a branch inside the one
  # function that owns the argument, and disposal is the first thing it
  # does.
  @impl true
  def handle_call({:adopt, fd_or_socket, kind, actor}, _f, st) do
    if kind == :human_control and st.control_open do
      dispose(fd_or_socket)
      {:reply, {:refused, control_taken()}, st}
    else
      case as_socket(fd_or_socket) do
        {:ok, sock} ->
          case Ampd.Transport.Connection.start(sock, kind, actor) do
            {:ok, pid, peer_id, ref} ->
              Ampd.AuthorityCoordinator.touched()

              meta = %{"kind" => to_string(kind), "actor" => actor, "peer" => peer_id,
                       "opened_at" => DateTime.utc_now() |> DateTime.to_iso8601()}

              {:reply, {:ok, pid, peer_id},
               %{st | channels: Map.put(st.channels, pid, %{meta: meta, sock: sock,
                                                            ref: ref, peer: peer_id,
                                                            kind: kind}),
                      control_open: st.control_open or kind == :human_control}}

            # **Rolled back before this returned**, by `Connection.start/3`
            # itself: the socket is closed and any identity the startup
            # created is detached. F.8.2.1 said ownership had moved to the
            # connection process and left this branch empty — but a socket
            # is owned by its `{otp, controlling_process}`, and that is
            # still this GenServer.
            {:refused, r} ->
              {:reply, {:refused, r}, st}
          end

        # `Ampd.NativeFd.adopt_socket/1` sinks the descriptor on every
        # failure before it returns, so there is nothing left to dispose.
        :error ->
          {:reply,
           {:refused,
            Ampd.Refusal.new("channel-adopt-failed",
              component: "Ampd.Bridge",
              retryable: false,
              requires_human: false,
              public_message: "The runtime could not adopt that channel.",
              operator_detail: %{"reason" => "not a usable descriptor"})}, st}
      end
    end
  end

  def handle_call(:list, _f, st),
    do: {:reply, Enum.map(Map.values(st.channels), & &1.meta), st}

  # ------------------------------------------- D.1.3a · the effect endpoint
  #
  # One clause, and disposal is unconditional on every exit — the law
  # `{:adopt, ...}` learned the hard way. A refused or replaced endpoint
  # that is merely dropped from the map is a descriptor this process still
  # holds and nothing will ever close.
  def handle_call({:bind_effect, fd_or_socket, incarnation}, _f, st) do
    case as_socket(fd_or_socket) do
      {:ok, sock} ->
        # A replacement disposes of what it replaces. Two endpoints and no
        # way to say which is current is the state the incarnation exists
        # to make impossible, so it must not be reachable here either.
        if st.effect, do: dispose(st.effect.sock)

        # Visible in the operator projection as an embodiment change, and
        # `identity_probe/0` is keyed on the epoch, so binding a new
        # incarnation re-measures the basis. That is correct: a different
        # endpoint may be a different machine.
        Ampd.AuthorityCoordinator.touched()

        {:reply, {:ok, incarnation}, %{st | effect: %{sock: sock, incarnation: incarnation}}}

      :error ->
        {:reply,
         {:refused,
          Ampd.Refusal.new("effect-endpoint-adopt-failed",
            component: "Ampd.Bridge",
            retryable: false,
            requires_human: false,
            public_message: "The runtime could not adopt that effect endpoint.",
            operator_detail: %{"reason" => "not a usable descriptor"})}, st}
    end
  end

  def handle_call(:effect_endpoint, _f, st), do: {:reply, st.effect, st}

  def handle_call(:drop_effect, _f, st) do
    if st.effect do
      dispose(st.effect.sock)
      Ampd.AuthorityCoordinator.touched()
    end

    {:reply, :ok, %{st | effect: nil}}
  end

  # **A barrier, not a broadcast.**
  #
  # This demonitored every channel — dropping the backstop F.8.2.2 exists
  # to provide — then sent each connection `:stop` and returned without
  # waiting for any of them. Fire-and-forget is wrong for a *world*
  # operation in a way it is not wrong for a single close: the caller is
  # about to destroy the world these channels are bound to, and it has to
  # be able to know they are gone first.
  #
  # `Ampd.Bridge` owns these sockets, so it does not have to ask. It
  # terminates and disposes, in this process, before replying. A graceful
  # `:stop` would have been nicer to the peer and is not available: it ends
  # in `Wire.send_frame/2`, whose `socket:send/2` waits forever on a peer
  # that is not reading — so a single stuck client could hold a world reset
  # open indefinitely. Closing the socket delivers EOF, which is the honest
  # signal for a channel whose world no longer exists.
  def handle_call(:reset, _f, st) do
    # The resource barrier and the *process* barrier are different claims,
    # and F.8.2.3 only made the first one. Erlang exit signals are
    # asynchronous: `Process.exit(pid, :kill)` returning does not mean the
    # process is gone. Watch each one out rather than assume it — the
    # monitors are still held here for exactly that, and dropped after.
    refs =
      Enum.map(st.channels, fn {pid, ch} ->
        Process.exit(pid, :kill)
        {pid, ch.ref}
      end)

    # One deadline for the whole teardown, not one per channel. Per-channel
    # made the handler's worst case grow with the number of open channels
    # while the caller's deadline stayed fixed — see `reset/0`.
    deadline = System.monotonic_time(:millisecond) + @reset_budget_ms

    Enum.each(refs, fn {pid, ref} ->
      left = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        left -> :ok
      end

      Process.demonitor(ref, [:flush])
    end)

    Enum.each(st.channels, fn {_pid, ch} ->
      Ampd.Transport.Connection.rollback(ch.sock, ch.peer)
    end)

    # **The effect endpoint goes with the world, like every channel does.**
    # Re-initializing a world invalidates every open channel; an endpoint
    # that survived one would be a possessed mechanism bound to a world
    # that no longer exists, which is the stale-consent problem with a
    # descriptor attached. The incarnation dies here and a replacement gets
    # a new epoch — which is also what makes `C12` true, because there is
    # no path on which losing a channel refreshes or widens anything.
    if st.effect, do: dispose(st.effect.sock)

    Ampd.AuthorityCoordinator.touched()
    {:reply, :ok, %{st | channels: %{}, control_open: false, effect: nil}}
  end

  # The disposal half of the contract. An integer is a raw descriptor and
  # goes to the one sink; a socket handle the caller adopted before calling
  # is closed here, because refusing a channel does not make it stop
  # existing.
  defp dispose(fd) when is_integer(fd), do: Ampd.NativeFd.discard(fd)
  defp dispose({:"$socket", _} = sock), do: :socket.close(sock)
  defp dispose(_), do: :ok

  @impl true
  def handle_cast({:closed, pid}, st), do: {:noreply, forget(pid, st, :graceful)}

  # **The backstop, and the reason this GenServer monitors at all.**
  #
  # A connection that exits abnormally never reaches its own `shutdown` —
  # no `:socket.close`, no `Peer.detach`, no `channel_closed`. Measured
  # before it was fixed: killing a bound connection left the socket open,
  # the bridge still listing the channel and the peer still resolving; and
  # killing the *human control* connection left `control-channel-already-
  # claimed` set forever, so one crash took the person's authority away and
  # never gave it back.
  #
  # The socket is this process's to close — it is the controlling process —
  # so this is not defensive tidying, it is the owner doing its job.
  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, st) do
    case st.channels[pid] do
      %{ref: ^ref} -> {:noreply, forget(pid, st, :died)}
      _ -> {:noreply, st}
    end
  end

  def handle_info(_msg, st), do: {:noreply, st}

  # One removal path, two entrances. `:graceful` means the connection has
  # already closed the socket and detached itself; `:died` means nothing
  # has, and this is the only thing that will.
  defp forget(pid, st, how) do
    case Map.pop(st.channels, pid) do
      {nil, _} ->
        st

      {ch, rest} ->
        # `channels` is in the operator projection; a channel closing is a
        # visible change and is not an authority mutation.
        Ampd.AuthorityCoordinator.touched()
        Process.demonitor(ch.ref, [:flush])
        if how == :died, do: Ampd.Transport.Connection.rollback(ch.sock, ch.peer)

        %{st | channels: rest, control_open: st.control_open and ch.kind != :human_control}
    end
  end

  # **The receiver owns what it receives** — see `Ampd.NativeFd`.
  #
  # This said `dup: false — take ownership of the descriptor` and `one
  # descriptor, one owner`, and both were false. `dup => false` is
  # documented to mean *do not duplicate*; it says nothing about ownership,
  # and OTP will not close a descriptor it did not create. So the handle
  # owned nothing, `:socket.close/1` returned `:ok` without a `close(2)`,
  # and every channel this runtime ever opened left a descriptor behind.
  #
  # F.8.1 measured that residue and reported it as bounded and acceptable.
  # It was neither: the same false model was in `HostBridge.close_fd/1`,
  # where it leaks per *command* rather than per channel.
  defp as_socket(fd) when is_integer(fd), do: Ampd.NativeFd.adopt_socket(fd)

  defp as_socket({:"$socket", _} = sock), do: {:ok, sock}
  defp as_socket(_), do: :error

  # The wording matters, and the old wording was wrong. "Succeeds once per
  # world" reads as though reopening should be forbidden — while the
  # product deliberately requires close-and-reopen to reach the same
  # durable world. The invariant is about concurrency, not about a lifetime.
  defp control_taken do
    Ampd.Refusal.new("control-channel-already-claimed",
      component: "Ampd.Bridge",
      retryable: true,
      requires_human: true,
      public_message: "A human control channel is already active.",
      operator_detail: %{
        "hint" =>
          "at most one human control channel is active at a time — the host takes it before " <>
            "any engine starts, and a second request while it is held is a process trying to " <>
            "become the person. Closing the active one releases it."
      }
    )
  end
end
