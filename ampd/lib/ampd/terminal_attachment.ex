defmodule Ampd.TerminalAttachment do
  @moduledoc """
  D.1.3c·2b — the process that owns one terminal attachment's stream, and
  the state that says it is not yet a possession.

  ## The third distinction

  This slice exists because "possession" turned out to be three facts, not
  one:

      the kernel installed a descriptor
          ≠  a runtime process owns it
          ≠  the World says a Peer possesses the attachment

  The first gap is closed in `Ampd.Worktree.EffectChannel.request_with_fd/5`,
  which adopts at the receive. **This module closes the second.** A process
  that owns the stream is not yet an attachment anybody has; it is a
  descriptor with an owner and no meaning.

      PROVISIONAL   the socket is owned. Nothing else is true.
                    no bytes out, no projection, no record
      ACTIVE        ORDERED B re-derived every basis and committed
      CLOSED        the socket is gone and this process is ending

  It is the same shape as `process spawned ≠ Carrier admitted`, one layer
  down, and it is enforced rather than documented: `read/1` and `write/2`
  refuse while provisional.

  ## Why bytes that have already arrived are still not observations

  The kernel socket buffers whatever the terminal produced from the instant
  the host attached, which is *before* ORDERED B has said whether this Peer
  may have it. Those bytes are physically present and semantically nobody's.
  Surfacing them because they happen to be readable would make the commit
  decorative.

  ## Ownership, and the four cuts it has to survive

  Measured on OTP 28.2, because the choreography rests on all of it:

      transfer performed BY the owner       :ok
      transfer by anyone else               {:error, {:invalid, :not_owner}}
      creator dies AFTER the transfer       the socket STAYS OPEN
      the new owner dies                    the socket closes

  The third line is the one that needs a state machine. Before the transfer,
  the caller's death closes the socket on its own and this process merely
  notices. **After** the transfer it does not — this process owns it now, so
  nothing in OTP will close it, and a provisional attachment whose setup
  caller has died would otherwise hold the host's single attachment slot open
  until the VM exits. The monitor is what closes it.

      caller dies before transfer   caller owned it   → closes → we stop
      child dies before transfer    caller owns it    → caller closes
      caller dies after transfer    WE own it         → monitor → we close
      ORDERED B refuses             we close, nothing is published
      ORDERED B commits             activate/3, exactly once

  ## Two lifetimes, and they are not the same one

  The first version of this module monitored the setup caller and kept that
  monitor after activation, which quietly made an *active* attachment die
  with the transaction that created it. Those are different things:

      PROVISIONAL   lives as long as the setup transaction
      ACTIVE        lives as long as the owning Peer/session incarnation

  A setup transaction that did its job and returned would otherwise have
  closed a perfectly good attachment out from under its owner. So the
  monitor is **swapped** at activation — the new one established before the
  old one is dropped, because the reverse order leaves an interval in which
  nothing is watching, and a death inside it strands a socket on a process
  nobody is waiting on.

  If it ever turns out that the setup caller and the owning Peer are
  necessarily the same process, that equality should be encoded and
  falsified rather than relied on by call-path inspection.

  ## The abort floor is mechanical, not cooperative

  Closing this socket is sufficient. c·2a·1 made the host re-derive an
  attachment's liveness from its pump rather than remember it, so the far end
  going away ends the pump, and the next attach reclaims the slot — without
  killing the Carrier and without anybody acknowledging a detach. A typed
  `pty-detach` is an accelerant; correctness does not wait for it.

  ## What this process does not hold

  No authority. It is `restart: :temporary` because a restarted attachment
  would be a process claiming possession of a descriptor that died with its
  predecessor — there is nothing to restart into. `Ampd.Peer` holds the
  semantic relation; this holds the stream. Neither holds the other's job.
  """
  use GenServer, restart: :temporary

  require Logger

  @doc """
  How long a provisional attachment may remain unactivated.

  Bounded because the alternative is a caller that wandered off holding the
  host's only attachment slot for that Carrier. Generous relative to
  ORDERED B, which is BEAM-local re-derivation and does no I/O.
  """
  def setup_deadline_ms, do: 15_000

  # ------------------------------------------------------------------ api

  @doc """
  Start a **provisional** owner for an already-adopted socket.

  `sock` must be adopted (see `Ampd.Worktree.EffectChannel.request_with_fd/5`)
  and is still owned by `setup` at this point. The caller transfers ownership
  immediately after this returns — only the current owner may — and this
  process is monitoring it either way.
  """
  def start_link(%{sock: _, setup: _, identity: _} = args),
    do: GenServer.start_link(__MODULE__, args)

  @doc """
  PROVISIONAL → ACTIVE. Exactly once; a second call is refused.

  `owner` is the process whose life the **active** attachment is bound to —
  the owning Peer/session incarnation, not the transaction that set it up.
  See the lifetime note in the moduledoc: those are not the same thing, and
  binding an active attachment to the setup caller was a real defect.

  `record` must describe **this** attachment. It is checked field by field
  against the identity this process was created for, because the alternative
  is a process that physically owns stream A while claiming to be
  attachment B — a mistake a trusted caller should not make and which
  nothing would otherwise catch.
  """
  def activate(pid, record, owner) when is_map(record) and is_pid(owner),
    do: GenServer.call(pid, {:activate, record, owner})

  @doc "Close the stream and end. Safe from any state, including twice."
  def close(pid), do: GenServer.stop(pid, :normal, 5_000)

  @doc "The attachment's current state — `:provisional`, `:active` or `:closed`."
  def state(pid), do: GenServer.call(pid, :state)

  @doc "The `terminal-attachment@1` record, or `nil` while provisional."
  def record(pid), do: GenServer.call(pid, :record)

  @doc """
  Bytes toward the terminal. **Refused while provisional.**

  Not "returns an error because the socket is not ready" — the socket is
  perfectly ready. Refused because writing to a terminal is an act of
  possession and this process does not yet represent one.
  """
  def write(pid, data) when is_binary(data), do: GenServer.call(pid, {:write, data})

  @doc "Bytes from the terminal, up to `n`. **Refused while provisional.**"
  def read(pid, n \\ 4096, timeout \\ 0), do: GenServer.call(pid, {:read, n, timeout})

  # ----------------------------------------------------------------- impl

  @impl true
  def init(%{sock: sock, setup: setup, identity: identity}) do
    # Monitor before anything can go wrong. If the setup caller is already
    # gone, `Process.monitor/1` still delivers a `:DOWN`, so the closing path
    # is the same one and there is no special case for "died first".
    ref = Process.monitor(setup)
    timer = Process.send_after(self(), :setup_deadline, setup_deadline_ms())

    {:ok,
     %{
       phase: :provisional,
       sock: sock,
       setup: setup,
       setup_ref: ref,
       timer: timer,
       identity: identity,
       owner: nil,
       owner_ref: nil,
       record: nil
     }}
  end

  @impl true
  def handle_call({:activate, record, owner}, _from, %{phase: :provisional} = s) do
    case disagrees(record, s.identity) do
      [] ->
        # **The ACTIVE monitor is established BEFORE the setup one is
        # dropped.** Reversed, there would be an interval — however short —
        # in which nothing was watching, and a death inside it would leave
        # an attachment owned by a process nobody is waiting on.
        owner_ref = Process.monitor(owner)
        Process.demonitor(s.setup_ref, [:flush])
        Process.cancel_timer(s.timer)

        {:reply, :ok,
         %{
           s
           | phase: :active,
             record: record,
             owner: owner,
             owner_ref: owner_ref,
             setup_ref: nil,
             timer: nil
         }}

      bad ->
        {:reply, {:error, {:identity_mismatch, bad}}, s}
    end
  end

  def handle_call({:activate, _, _}, _from, s),
    do: {:reply, {:error, {:not_provisional, s.phase}}, s}

  def handle_call(:state, _from, s), do: {:reply, s.phase, s}
  def handle_call(:record, _from, s), do: {:reply, s.record, s}

  # **The refusal is the feature.** A provisional attachment owns a socket
  # with real bytes in it and must not be a way to read them.
  def handle_call({:write, _}, _from, %{phase: :provisional} = s),
    do: {:reply, {:error, :provisional}, s}

  def handle_call({:read, _, _}, _from, %{phase: :provisional} = s),
    do: {:reply, {:error, :provisional}, s}

  def handle_call({:write, data}, _from, %{phase: :active} = s),
    do: {:reply, :socket.send(s.sock, data), s}

  def handle_call({:read, n, timeout}, _from, %{phase: :active} = s),
    do: {:reply, :socket.recv(s.sock, n, timeout), s}

  def handle_call({:write, _}, _from, s), do: {:reply, {:error, s.phase}, s}
  def handle_call({:read, _, _}, _from, s), do: {:reply, {:error, s.phase}, s}

  @impl true
  # **Two lifetimes, and they are not the same one.**
  #
  # A provisional attachment lives as long as the transaction setting it up;
  # an active one lives as long as the Peer that possesses it. Binding the
  # active phase to the setup caller was the first version of this module and
  # it was wrong: a setup transaction that returned and exited would have
  # closed a perfectly good attachment out from under its owner.
  #
  # The monitor is swapped at activation rather than kept, so only one of
  # these clauses can match at a time and the phase is not consulted to
  # decide which lifetime just ended.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{setup_ref: ref} = s)
      when not is_nil(ref) do
    Logger.debug(fn ->
      "ampd: a provisional terminal attachment's setup owner went away " <>
        "(#{inspect(reason)}); closing the stream and publishing nothing"
    end)

    {:stop, :normal, s}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{owner_ref: ref} = s)
      when not is_nil(ref) do
    Logger.debug(fn ->
      "ampd: the peer possessing a terminal attachment went away " <>
        "(#{inspect(reason)}); closing the stream"
    end)

    {:stop, :normal, s}
  end

  def handle_info(:setup_deadline, %{phase: :provisional} = s) do
    Logger.warning(
      "ampd: a terminal attachment was not activated within " <>
        "#{setup_deadline_ms()}ms; closing it rather than holding the carrier's slot"
    )

    {:stop, :normal, %{s | timer: nil}}
  end

  def handle_info(:setup_deadline, s), do: {:noreply, s}
  def handle_info(_, s), do: {:noreply, s}

  # The five fields that say *which* attachment this is. Physical identity,
  # not authority: agreeing on them does not make a record permitted, it
  # makes it about this stream.
  @bound ~w(attachment_ref attachment_epoch carrier_ref carrier_epoch pty_epoch)

  defp disagrees(record, identity) do
    Enum.filter(@bound, fn k -> Map.get(record, k) != Map.get(identity, k) end)
  end

  @impl true
  # One disposal, on every exit. `:socket.close/1` is attempted whether or
  # not the transfer happened: if it did we own it, and if it did not the
  # socket is already gone with the caller and the extra call answers
  # `{:error, :closed}`, which is not a hazard.
  def terminate(_reason, s) do
    _ = :socket.close(s.sock)
    :ok
  end
end

defmodule Ampd.TerminalAttachment.Supervisor do
  @moduledoc """
  The dynamic supervisor for terminal attachment owners.

  **The first `DynamicSupervisor` in this tree**, and the argument for it is
  the one `Ampd.Carrier.Reaper` had to make: the thing being added is a
  *lifetime*, not a fact. An attachment's stream must close when its owner
  dies, and "closes when a process dies" is what a process is for. There is
  no existing home — `Ampd.Peer` is a leaf `GenServer` holding maps, and
  giving it descriptors would make one process's death close every
  attachment.

  Children are `restart: :temporary` and the strategy is `:one_for_one`:
  attachments are independent, and a dead one cannot be restarted into
  anything because the descriptor it owned died with it.
  """
  use DynamicSupervisor

  def start_link(_ \\ []), do: DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Start a provisional owner and hand it the socket.

  **The transfer is performed by the caller and cannot be performed here.**
  `{:otp, :controlling_process}` may only be set by the socket's current
  owner, and the current owner is whoever adopted it — measured: anyone else
  gets `{:error, {:invalid, :not_owner}}`. So this returns the child and the
  caller completes the handover, which is also the only ordering under which
  a failure to start leaves the socket with someone who can close it.
  """
  def start_owner(%{sock: _, setup: _, identity: _} = args),
    do: DynamicSupervisor.start_child(__MODULE__, {Ampd.TerminalAttachment, args})
end
