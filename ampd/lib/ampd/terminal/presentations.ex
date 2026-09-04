defmodule Ampd.Terminal.Presentations do
  @moduledoc """
  D.1.3c·2c·1b — **parked descriptors waiting to become a data plane**, and
  the cardinality of the planes they become.

  ## The descriptor and the authority arrive on different sockets

  Neither can carry both, and which one is authoritative is not a matter of
  taste:

      the control channel   IS the identity. The human-control role is
                            possession of this socket and nothing else, and
                            every operator command in the runtime is
                            authorised by holding it. It is read with a
                            plain `:socket.recv/2`, so a descriptor sent on
                            it is discarded by the kernel — silently.

      the bridge            CAN carry a descriptor: SEQPACKET, and every arm
                            of `Ampd.Transport.HostBridge` already receives
                            rights and sinks the surplus. It is the host's
                            channel, not a person's. It carries no operator
                            identity and it never will.

  So **the descriptor comes first and means nothing.**
  `bind_terminal_endpoint` hands ampd a socket over the bridge; this module
  adopts it, parks it under an `endpoint_ref`, and that is all that has
  happened — no Worker has been named, no authority consulted, the endpoint
  bound to nothing.

  **The authority comes second, on the socket that carries it.**
  `terminal_bind` is a `:human_control` mutation, so `Ampd.Control` has
  already resolved the bound peer before it dispatches, and
  `Ampd.Terminal.Presentation.resolve/3` runs the whole chain against *that*
  peer. Only then is a parked endpoint claimed and a plane started.

  ## What the ordering buys

  *Can any caller obtain a presentation basis without passing the
  human-control role check?* No — and not because the bridge is trusted to
  behave. **The bridge arm cannot name a Worker.** Its entire vocabulary is
  "here is a socket", and its reply is an opaque reference to a socket the
  caller already owns the other end of. There is no argument it could supply
  that would make it a presentation.

  The reverse ordering — resolve on the control channel, mint a ticket,
  present the ticket on the bridge with the descriptor — was the first design
  and is worse in a way that matters: the ticket has to travel back through
  `Ampd.Control`'s reply, which is the wire that ends in JavaScript. An
  identifier that must never reach a page should not be put on the one
  channel that reaches pages.

  ## The endpoint_ref is not a credential

  It designates a socket, not a permission. Every socket it can name was
  created by the cockpit process, which holds the control channel and can
  therefore already open any presentation it likes — naming one adds nothing
  to that. It is short-lived because an adopted descriptor nobody claims is a
  leak, not because it is dangerous.

  ## Cardinality

  **One live plane per terminal attachment** (D.1.3c·2c·1b B4). A second open
  is refused by name rather than queued or fanned out. Two readers of one
  terminal stream is not spectatorship — `Ampd.TerminalAttachment` hands each
  reader whichever bytes it happened to receive, so both would see an
  arbitrary half. Fan-out is a mechanism that copies, and this slice does not
  have one.
  """
  use GenServer
  require Logger

  @ttl_ms 5_000

  @doc """
  How long a parked endpoint may sit unbound before it is closed.

  Short on purpose. The whole interval it covers is one Tauri command in one
  process: create a socketpair, send one end on the bridge, submit
  `terminal_bind` on the control channel. Anything longer is an adopted
  descriptor with no owner and no exit, which is the one thing
  `Ampd.NativeFd`'s adoption contract exists to make hard to write.
  """
  def ttl_ms, do: @ttl_ms

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Park an adopted socket and return the reference a later `terminal_bind`
  claims it by. Nothing about a Worker is known here.
  """
  def park(sock), do: ask({:park, sock})

  @doc """
  Claim a parked socket, exactly once. `{:ok, sock}` or `{:error, reason}`.

  The caller owns it from here and must close it on every path — including
  the ones where the authority check that follows refuses.
  """
  def claim_endpoint(ref) when is_binary(ref), do: ask({:claim_endpoint, ref})

  @doc "Register a live plane against its attachment. Refuses a second one."
  def claim(attachment_ref, plane) when is_binary(attachment_ref) and is_pid(plane),
    do: ask({:claim, attachment_ref, plane})

  @doc "Every live plane, as `attachment_ref => pid`."
  def live, do: ask(:live)

  @doc "Close every parked endpoint and every plane. A world reset ends both."
  def reset, do: ask(:reset)

  # **The ordered boundary, and the census is what put it here.**
  #
  # `Ampd.Bootstrap.reset_world!/0` runs inside the total order, so a
  # `GenServer.call` from it can exit the coordinator if this process is
  # slow or gone — `Ampd.AuthorityCoordinator` IS the caller there, and
  # taking it down means `seq` to zero and every subscriber resnapshotting.
  # `Ampd.Participant` is the boundary that turns that into a classified
  # failure instead.
  #
  # The classification is a list rather than a judgement at each call site,
  # for the reason `Ampd.Peer` states: a crossing whose class the caller
  # forgot to decide would silently default to the safer-looking one. Every
  # tag not named here is a read — and note that `park` IS a mutation, not
  # because it changes authority but because a lost reply means the runtime
  # may be holding an adopted descriptor the caller believes it still owns.
  @mutations ~w(park claim_endpoint claim reset)a

  defp ask(msg, timeout \\ 5_000) do
    tag = if is_tuple(msg), do: elem(msg, 0), else: msg
    Ampd.Participant.call(__MODULE__, msg, class(tag), timeout: timeout)
  end

  @doc false
  # Public so the census gate and the falsifiers read the classification
  # rather than infer it.
  def class(tag), do: if(tag in @mutations, do: :mutate, else: :read)

  # ------------------------------------------------------------------ impl

  @impl true
  def init(:ok), do: {:ok, %{parked: %{}, planes: %{}, monitors: %{}}}

  @impl true
  def handle_call({:park, sock}, _from, st) do
    ref = "te_" <> hex(32)
    Process.send_after(self(), {:expire, ref}, @ttl_ms)
    {:reply, {:ok, ref}, %{st | parked: Map.put(st.parked, ref, sock)}}
  end

  # **`Map.pop` rather than read-then-delete**, because the single claim is
  # the property. Two calls with a lookup between them is a window in which
  # two planes adopt one descriptor, and then two processes close it.
  def handle_call({:claim_endpoint, ref}, _from, st) do
    case Map.pop(st.parked, ref) do
      {nil, _} -> {:reply, {:error, :unknown_terminal_endpoint}, st}
      {sock, rest} -> {:reply, {:ok, sock}, %{st | parked: rest}}
    end
  end

  def handle_call({:claim, attachment_ref, plane}, _from, st) do
    case Map.get(st.planes, attachment_ref) do
      nil ->
        mref = Process.monitor(plane)

        {:reply, :ok,
         %{
           st
           | planes: Map.put(st.planes, attachment_ref, plane),
             monitors: Map.put(st.monitors, mref, attachment_ref)
         }}

      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          {:reply, {:error, :terminal_already_presented}, st}
        else
          # The monitor will arrive; do not wait for it to admit the
          # replacement. A dead holder is not a holder.
          mref = Process.monitor(plane)

          {:reply, :ok,
           %{
             st
             | planes: Map.put(st.planes, attachment_ref, plane),
               monitors: Map.put(st.monitors, mref, attachment_ref)
           }}
        end
    end
  end

  def handle_call(:live, _from, st), do: {:reply, st.planes, st}

  def handle_call(:reset, _from, st) do
    # **Killed rather than asked, and this runs inside the total order.**
    # `GenServer.stop(pid, :normal, 1_000)` is a wait per plane, and the
    # thing waiting is `Ampd.AuthorityCoordinator` in the middle of a world
    # reset. `Ampd.Peer.reset/0` makes the same call for the same reason and
    # says so: a reset must not wait on anything.
    #
    # The socket dies with the process. `Ampd.NativeFd.adopt_socket/1` uses
    # `dup: true` precisely so that the handle OTP created is the handle OTP
    # closes when its owner goes — which is what makes a kill safe here and
    # is the whole of that module's argument.
    for {_ref, pid} <- st.planes, do: Process.exit(pid, :kill)
    for {mref, _} <- st.monitors, do: Process.demonitor(mref, [:flush])
    for {_ref, sock} <- st.parked, do: :socket.close(sock)
    {:reply, :ok, %{parked: %{}, planes: %{}, monitors: %{}}}
  end

  @impl true
  # **Expiry CLOSES the socket**, which is the whole reason the timer exists.
  # Forgetting the reference would leave an adopted descriptor with no owner
  # and no exit.
  def handle_info({:expire, ref}, st) do
    case Map.pop(st.parked, ref) do
      {nil, _} ->
        {:noreply, st}

      {sock, rest} ->
        _ = :socket.close(sock)
        {:noreply, %{st | parked: rest}}
    end
  end

  # **Keyed on the monitor, then checked by identity.** A plane that died and
  # was replaced would otherwise have its successor's registration deleted by
  # its own `DOWN`.
  def handle_info({:DOWN, mref, :process, pid, _reason}, st) do
    case Map.pop(st.monitors, mref) do
      {nil, _} ->
        {:noreply, st}

      {attachment_ref, monitors} ->
        planes =
          if Map.get(st.planes, attachment_ref) == pid,
            do: Map.delete(st.planes, attachment_ref),
            else: st.planes

        {:noreply, %{st | planes: planes, monitors: monitors}}
    end
  end

  def handle_info(_, st), do: {:noreply, st}

  defp hex(n), do: Base.encode16(:crypto.strong_rand_bytes(div(n, 2)), case: :lower)
end
