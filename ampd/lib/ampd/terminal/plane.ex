defmodule Ampd.Terminal.Plane do
  @moduledoc """
  D.1.3c·2c·1b — the **data plane**: lossless ordered terminal bytes on a
  descriptor of their own, and nothing else.

      AUTHORITY   ordered semantic state            Ampd.AuthorityCoordinator
      CONTROL     coalescible projection frames     the valve, W.2
      DATA        lossless ordered terminal bytes   this

  ## Why terminal bytes are not projection frames

  The control plane coalesces and it is right to: a projection frame
  supersedes its predecessor, so dropping the older one loses nothing. A byte
  supersedes nothing. Put terminal output on the valve and the first slow
  page turns `ls -R /` into a plausible-looking, wrong transcript — with no
  error anywhere, because coalescing is that plane's correct behaviour.

  So this is a second descriptor, obtained the way every other descriptor in
  this runtime is obtained: `Ampd.Transport.HostBridge`, `SCM_RIGHTS`,
  `Ampd.NativeFd.adopt_socket/1`. The page never receives it. A descriptor is
  not authority on its own — what makes this one a presentation is the
  ticket that `Ampd.Terminal.Presentations` redeemed to create it.

  ## The wire, and why it is not JSON

      OUT      <<1, seq::big-64, len::big-32, bytes::binary-size(len)>>
      CLOSE    <<3, len::big-16, code::binary-size(len)>>

      OUT_ACK  <<2, seq::big-64>>                        toward this process

  Terminal output is arbitrary bytes — control sequences, partial UTF-8, NUL.
  JSON would have to escape or base64 it, which is a cost per byte on the one
  plane whose whole job is bytes, and an encoding that can fail on a plane
  that must not lose anything.

  `seq` starts at 1 and increments by one per chunk. It is scoped to **this
  presentation incarnation** and does not continue across a reopen, because a
  reopened presentation is a different one — there is no server-side
  scrollback for it to continue from.

  ## The ack is the mechanism, not a receipt

  `OUT_ACK` is cumulative and it is flow control. The page acks after xterm
  has *consumed* the bytes, not on arrival, so the credit reflects the
  renderer rather than the transport. With credits exhausted:

      page stops acking
        → this stops forwarding
        → Ampd.TerminalAttachment stops selecting on its socket
        → the socketpair from the host fills                (SO_RCVBUF)
        → the host's pump stops draining the PTY master
        → the Carrier blocks in write(2)

  Every link in that chain is a process declining to read, and none of them
  is a buffer that grows. `probes/terminal_backpressure.exs` measures it —
  bytes produced, delivered, max outstanding, BEAM memory delta, time to
  upstream stall, bytes lost — rather than inferring it from the shape.

  ## The lifetime is a binding to eight things

      World incarnation · Worker ref · Worker generation
      occupying Peer incarnation · Carrier incarnation
      terminal attachment incarnation · the stream owner process
      the control-channel incarnation that opened it

  If any of them moves, this closes. **It never migrates.** A replacement
  occupant at the same Worker is a different assignment, possibly a different
  actor, and following it would show the operator someone else's execution
  under the row they clicked.

  Three of those are process deaths and arrive as monitors, immediately. The
  rest are World facts with no death attached — `close_worker`, a generation
  advance, an occupant leaving — so they are noticed by re-deriving. That
  runs on a tick, and only when the authority revision has actually moved, so
  an idle plane costs one `Ampd.AuthorityCoordinator.cursor/0` per tick and a
  busy one costs a semantic re-derivation per *change*, not per byte.

  **The residual is stated rather than hidden:** up to `revalidate_ms/0` of
  output can reach the page after the authority to watch it ended. Those
  bytes come from the same PTY the presentation was opened over — this is
  bound to a stream owner process, and that process cannot become another
  Worker's terminal — so it is a bounded tail of a stream the operator was
  entitled to a moment earlier, not a cross-terminal disclosure. `B.9`
  measures the actual latency rather than trusting the interval.
  """
  use GenServer
  require Logger

  alias Ampd.Terminal.{Presentation, Presentations}
  alias Ampd.TerminalAttachment, as: TA

  @out 1
  @ack 2
  @close 3

  @credits 8
  @revalidate_ms 100

  @doc """
  How many chunks may be outstanding toward the page at once.

  Counted in chunks because `Ampd.TerminalAttachment.chunk_bytes/0` gives a
  chunk a size; the memory this bounds is the product. Eight of 4 KiB is
  32 KiB in flight, which is a window and not a buffer: it does not grow when
  the page stops, it stops.
  """
  def credits, do: @credits

  @doc "How often the basis is re-derived when the authority revision has moved."
  def revalidate_ms, do: @revalidate_ms

  @doc """
  Claim the parked endpoint `endpoint_ref` names and make it the data plane
  for `presentation`.

  Called from `Ampd.Control`'s `terminal_bind`, **after**
  `Ampd.Terminal.Presentation.resolve/3` has authorised the request against
  the bound human-control connection. This function performs no authority
  check of its own and must not: a second check here would be a second
  policy, and the reason `resolve/3` is the only caller is that it is the
  only place a peer exists.

  **Every path below closes the socket exactly once.** A caller that cannot
  tell whether its descriptor was taken has to guess, and both guesses leak —
  guessing "taken" leaves a live socket nobody closes, guessing "not taken"
  double-closes a number the runtime may have reissued.
  """
  def open(endpoint_ref, presentation) do
    case Presentations.claim_endpoint(endpoint_ref) do
      {:error, reason} ->
        {:error, reason}

      # **The two failure paths close it in different places, and which is
      # which is stated in the code rather than in a comment.** Before the
      # child exists, this function owns the socket. From the moment
      # `start_child/2` is called, `init/1` does — and a `{:stop, _}` from
      # `init/1` does NOT run `terminate/2`, so `init/1` closes there itself.
      # Closing in both would be a double close on a number the runtime may
      # already have reissued.
      {:ok, sock} ->
        # **The authority question first, then the runtime one, and the
        # order is a diagnosis rather than a preference.** `close_worker`
        # reaps the Carrier, so a Worker that was closed between `resolve/3`
        # and here usually has a dead stream owner too — and asking about the
        # owner first answers `terminal-stream-gone` for a position the
        # operator may no longer see at all. Two true statements, and only
        # one of them is the reason.
        case still_current(presentation) do
          {:error, reason} ->
            _ = :socket.close(sock)
            {:error, reason}

          :ok ->
            case stream_owner(presentation) do
              {:error, reason} ->
                _ = :socket.close(sock)
                {:error, reason}

              {:ok, owner} ->
                handed(sock, presentation, owner)
            end
        end
    end
  end

  # **Re-derived here, not trusted from `resolve/3`.** `terminal_bind` is a
  # mutation and mutations are not run inside the total order, so between the
  # authority holding and the plane binding to it another transaction can
  # close the Worker or replace the occupant. Without this the plane would
  # stream a stale basis until the first revalidation tick, which is
  # `revalidate_ms/0` of output the operator is no longer entitled to.
  defp still_current(p) do
    if Presentation.current?(p), do: :ok, else: {:error, :presentation_stale}
  end

  defp handed(sock, p, owner) do
    case DynamicSupervisor.start_child(
           __MODULE__.Supervisor,
           {__MODULE__, %{sock: sock, presentation: p, owner: owner}}
         ) do
      {:ok, pid} -> {:ok, pid, Presentation.presentable(p)}
      {:error, {:shutdown, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_owner(p) do
    case Ampd.Peer.terminal_owner(p["peer_ref"]) do
      nil -> {:error, :terminal_stream_gone}
      pid -> {:ok, pid}
    end
  end

  def child_spec(arg),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @doc "Close a plane. The possession it was watching is untouched."
  def close(pid), do: GenServer.stop(pid, :normal, 1_000)

  @doc false
  def info(pid), do: GenServer.call(pid, :info, 2_000)

  # ------------------------------------------------------------------ impl

  @impl true
  def init(%{sock: sock, presentation: p, owner: owner}) do
    # The claim is taken BEFORE anything is read, so a second presentation
    # cannot pull a single byte in the window before it is refused.
    with :ok <- Presentations.claim(p["attachment_ref"], self()),
         {:ok, _chunk} <- TA.subscribe(owner, self(), @credits) do
      owner_ref = Process.monitor(owner)
      control_ref = watch_control(p)
      timer = Process.send_after(self(), :revalidate, @revalidate_ms)

      {:ok,
       %{
         sock: sock,
         presentation: p,
         owner: owner,
         owner_ref: owner_ref,
         control_ref: control_ref,
         timer: timer,
         cursor: cursor(),
         seq: 0,
         acked: 0,
         select: nil,
         inbuf: <<>>,
         # Measurement, and it is in the process rather than in a probe
         # because the probe cannot see inside a mailbox that never grew.
         bytes_out: 0,
         max_outstanding: 0
       }, {:continue, :read_acks}}
    else
      {:error, reason} ->
        _ = :socket.close(sock)
        {:stop, {:shutdown, reason}}
    end
  end

  # **The control channel's own liveness, and it is a monitor rather than a
  # lookup.** A presentation is opened by an operator over a bound
  # connection; when that connection ends, the person who was watching is
  # gone. `Ampd.Peer.owner_pid/1` is the process that holds the socket, so
  # its death is the channel closing.
  defp watch_control(p) do
    case p["control_owner"] do
      pid when is_pid(pid) -> Process.monitor(pid)
      _ -> nil
    end
  end

  @impl true
  def handle_continue(:read_acks, s), do: {:noreply, pull_acks(s)}

  @impl true
  def handle_call(:info, _from, s) do
    {:reply,
     %{
       seq: s.seq,
       acked: s.acked,
       outstanding: s.seq - s.acked,
       max_outstanding: s.max_outstanding,
       bytes_out: s.bytes_out,
       presentation: Presentation.presentable(s.presentation)
     }, s}
  end

  @impl true
  # Bytes from the attachment. One frame per chunk, in order, never merged —
  # merging would make `seq` describe something other than what was sent.
  def handle_info({:terminal_out, owner, seq, data}, %{owner: owner} = s) do
    frame = <<@out, seq::big-64, byte_size(data)::big-32, data::binary>>

    case :socket.send(s.sock, frame) do
      :ok ->
        out = seq - s.acked

        {:noreply,
         %{
           s
           | seq: seq,
             bytes_out: s.bytes_out + byte_size(data),
             max_outstanding: max(s.max_outstanding, out)
         }}

      {:error, _} ->
        {:stop, :normal, s}
    end
  end

  def handle_info({:terminal_closed, owner, _why}, %{owner: owner} = s),
    do: {:stop, :normal, tell(s, "terminal-stream-ended")}

  def handle_info({:"$socket", sock, :select, _ref}, %{sock: sock} = s),
    do: {:noreply, pull_acks(%{s | select: nil})}

  def handle_info({:"$socket", _sock, :abort, _info}, s), do: {:stop, :normal, s}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = s),
    do: {:stop, :normal, tell(s, "terminal-stream-gone")}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{control_ref: ref} = s)
      when not is_nil(ref),
      do: {:stop, :normal, tell(s, "control-channel-closed")}

  # **The cursor first, the derivation only if it moved.** Re-deriving on
  # every tick would put a semantic chain on a 100 ms timer for every open
  # plane; reading the authority revision is one call and answers "could
  # anything have changed" exactly.
  def handle_info(:revalidate, s) do
    now = cursor()

    cond do
      now == s.cursor ->
        {:noreply, %{s | timer: Process.send_after(self(), :revalidate, @revalidate_ms)}}

      Presentation.current?(s.presentation) ->
        {:noreply,
         %{s | cursor: now, timer: Process.send_after(self(), :revalidate, @revalidate_ms)}}

      true ->
        {:stop, :normal, tell(s, "presentation-basis-moved")}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  # ------------------------------------------------------------- the acks

  # The same `:nowait` discipline as the attachment's pull, for the same
  # reason: a plane that blocks reading acks cannot deliver the bytes the
  # acks are for.
  defp pull_acks(%{select: sel} = s) when not is_nil(sel), do: s

  defp pull_acks(s) do
    case :socket.recv(s.sock, 0, [], :nowait) do
      {:ok, data} ->
        pull_acks(consume(%{s | inbuf: s.inbuf <> data}))

      {:select, {info, data}} when is_binary(data) ->
        consume(%{s | inbuf: s.inbuf <> data, select: info})

      {:select, info} ->
        %{s | select: info}

      {:error, :closed} ->
        send(self(), {:"$socket", s.sock, :abort, :closed}) && s

      {:error, _} ->
        s
    end
  end

  defp consume(%{inbuf: <<@ack, seq::big-64, rest::binary>>} = s) do
    # An ack for something never sent is a page inventing credit. It is
    # refused by ending the presentation rather than by ignoring the frame:
    # the page and this process no longer agree about what was delivered, and
    # a stream whose two ends disagree about ordering has already failed.
    if seq > s.seq or seq < s.acked do
      send(self(), {:"$socket", s.sock, :abort, :bad_ack})
      %{s | inbuf: rest}
    else
      TA.ack(s.owner, seq)
      consume(%{s | inbuf: rest, acked: seq})
    end
  end

  defp consume(s), do: s

  defp tell(s, code) do
    _ = :socket.send(s.sock, <<@close, byte_size(code)::big-16, code::binary>>)
    s
  end

  defp cursor do
    c = Ampd.AuthorityCoordinator.cursor()
    {c["projection_epoch"], c["revision"]}
  catch
    :exit, _ -> :unavailable
  end

  @impl true
  # One disposal on every exit, and the possession is deliberately not one of
  # the things disposed: closing a presentation leaves the terminal ACTIVE.
  # `Ampd.TerminalAttachment` drops the reader binding on this process's
  # `DOWN` and keeps streaming to nobody, which is what a terminal with no
  # one watching is.
  def terminate(_reason, s) do
    _ = :socket.close(s.sock)
    :ok
  end
end

defmodule Ampd.Terminal.Plane.Supervisor do
  @moduledoc """
  Planes, and they are `:temporary`.

  A data plane that died must not be restarted: it was bound to one
  presentation incarnation over one descriptor, and both are gone. A restart
  would produce a process with the same name and no socket, watching nothing.
  """
  use DynamicSupervisor

  def start_link(_), do: DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
end
