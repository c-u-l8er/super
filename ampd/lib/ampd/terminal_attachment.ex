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
      PREPARED      identity bound, lifetime transferred to the owning Peer,
                    and still not a possession. no bytes out.
      ACTIVE        ORDERED B2 re-derived every basis and finalised
      CLOSED        the socket is gone and this process is ending

  ## Why PREPARED exists, and why the two-state count was not worth keeping

  The semantic record lives in `Ampd.Peer` and the stream lives here. Those
  are two GenServers and they cannot change atomically, so a commit that
  claimed to move both at once would be hiding a transition rather than
  performing one. With two states the hidden transition is visible as a
  window:

      B1 installs COMMITTING in Ampd.Peer
      activate() makes THIS process ACTIVE   ← bytes flow here
      B2 finalises ACTIVE in Ampd.Peer

  Between the second and third lines the stream is usable and the World says
  the attachment is still committing. That is possession without an
  authorisation, which is the whole thing ORDERED B exists to prevent, so the
  state got added rather than the count defended. `prepare/3` does everything
  the old `activate/3` did — bind identity, swap the lifetime — and grants
  nothing; `activate/3` grants, and only after B2 has re-derived every basis
  a second time.

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
  How long an attachment may remain unfinalised.

  **Derived from the coordinator's budget, not chosen.** The commit this
  deadline has to survive is *two* ordered transactions —

      own_stream → transact(B1) → prepare → transact(B2)

  — and each of those may take the full `AuthorityCoordinator.budget_ms/0`.
  A flat 15_000 was the same number as one of them, so a busy coordinator
  could reap the stream owner while B1 was still enqueued or while B2 was
  executing: the timer would fire, the process would stop, and the
  `GenServer.call` in flight from inside the total order would exit.

  So this is the sum of every wait the commit can contain, plus margin —
  the same ordering discipline `Ampd.Worktree`'s deadline chain keeps,
  pointing the other way. It bounds a caller that wandered off holding the
  host's only attachment slot; it must not bound a commit that is merely
  waiting its turn.

      transact(B1) client timeout      budget_ms
      Peer.owner_pid/1                 5_000, the GenServer default
      prepare/3                        5_000
      transact(B2) client timeout      budget_ms
                                       ─────────
                                       2 × budget + 10_000

  The first arithmetic here was `2 × budget + 5_000`, which is **less than
  that sum**: it forgot the two ordinary calls between the transactions, so
  a commit could be reaped five seconds before its own worst case. The
  margin is a third interval on top, not a rounding.
  """
  def setup_deadline_ms, do: 2 * Ampd.AuthorityCoordinator.budget_ms() + 3 * 5_000

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
  PROVISIONAL → PREPARED. Exactly once; a second call is refused.

  `owner` is the process whose life the attachment is bound to from here on
  — the owning Peer/session incarnation, not the transaction that set it up.
  See the lifetime note in the moduledoc: those are not the same thing, and
  binding an active attachment to the setup caller was a real defect.

  `record` must describe **this** attachment. It is checked field by field
  against the identity this process was created for, because the alternative
  is a process that physically owns stream A while claiming to be
  attachment B — a mistake a trusted caller should not make and which
  nothing would otherwise catch.

  **Grants nothing.** A prepared attachment refuses bytes exactly as a
  provisional one does.
  """
  def prepare(pid, record, owner) when is_map(record) and is_pid(owner),
    do: GenServer.call(pid, {:prepare, record, owner})

  @doc """
  PREPARED → ACTIVE, addressed by the attachment identity. Exactly once.

  Called by ORDERED B2 and by nothing else. The two identity arguments are
  not decoration: this process must not be finalisable by a caller that has
  a pid and no idea which attachment it belongs to, which is the same rule
  `prepare/3` applies to the record and `Ampd.Peer.activate_terminal/3`
  applies one layer up.
  """
  def activate(pid, attachment_ref, attachment_epoch)
      when is_binary(attachment_ref) and is_binary(attachment_epoch),
      do: GenServer.call(pid, {:activate, attachment_ref, attachment_epoch})

  @doc """
  The process this attachment's lifetime is bound to, or `nil` while
  provisional.

  Exists so ORDERED B2 can **prove** the lifetime witness is the Peer
  binding's current owner rather than infer it from the call path. A wrong
  pid reaching `prepare/3` is otherwise undetectable — it monitors
  successfully, it just watches the wrong thing.
  """
  def owner(pid), do: GenServer.call(pid, :owner)

  @doc """
  Close the stream and end. Safe from any state, including twice.

  The catch is what makes that sentence true. `GenServer.stop/3` on a process
  that has already gone exits the **caller** with `:noproc`, and the callers
  here include code running inside the total order, where an exit is not a
  failed disposal but a control-plane outage.

  **It therefore cannot report a failed disposal.** A target that is still
  running after five seconds answers `:ok` like one that stopped. That is
  the right trade here — every caller either owns the descriptor itself or
  is relying on the deadline — but it is a real loss and not a free catch.
  """
  def close(pid) do
    GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  @doc """
  The attachment's current state — `:provisional`, `:prepared` or `:active`.

  The timeout is a parameter because the callers that matter are inside an
  ordered transaction, where the `GenServer` default of five seconds is a
  third of the whole budget.
  """
  def state(pid, timeout \\ 5_000), do: GenServer.call(pid, :state, timeout)

  @doc """
  Phase, record and owner in **one** bounded call.

  Two separate calls is what ORDERED B2 did first, and it cost twice: two
  round trips on every path including the ones that were going to refuse
  anyway, each with the five-second default in front of a fifteen-second
  budget. One call, bounded, is the same evidence for a tenth of the worst
  case.
  """
  def snapshot(pid, timeout \\ 1_000), do: GenServer.call(pid, :snapshot, timeout)

  @doc "The `terminal-attachment@1` record, or `nil` while provisional. Bound at `prepare/3`."
  def record(pid), do: GenServer.call(pid, :record)

  @doc """
  Bytes toward the terminal. **Refused before ACTIVE.**

  Not "returns an error because the socket is not ready" — the socket is
  perfectly ready. Refused because writing to a terminal is an act of
  possession and this process does not yet represent one. That is true in
  PREPARED as well as PROVISIONAL: a prepared attachment has an identity and
  a lifetime and no authorisation.
  """
  def write(pid, data) when is_binary(data), do: GenServer.call(pid, {:write, data})

  @doc "Bytes from the terminal, up to `n`. **Refused before ACTIVE.**"
  def read(pid, n \\ 4096, timeout \\ 0), do: GenServer.call(pid, {:read, n, timeout})

  # ----------------------------------------------------------------- impl

  @impl true
  def init(%{sock: sock, setup: setup, identity: identity}) do
    # Monitor before anything can go wrong. If the setup caller is already
    # gone, `Process.monitor/1` still delivers a `:DOWN`, so the closing path
    # is the same one and there is no special case for "died first".
    ref = Process.monitor(setup)
    timer = Process.send_after(self(), :setup_deadline, setup_deadline_ms())

    # **A third lifetime, and it is not an ownership.**
    #
    # `Ampd.Peer` holds the semantic record. Its state is ephemeral by
    # design, so a crash takes every `terminal-attachment@1` with it — and a
    # stream owner that survived that would hold the host's single attachment
    # slot for its Carrier with nothing in the runtime referring to it. That
    # is the orphaned-process shape `pending_reaps` exists to close one
    # object up, and there is no reaper for attachments.
    #
    # `Ampd.Transport.Connection` monitors the same process for the same
    # reason: an identity that can no longer be proved is not an identity.
    #
    # This is emphatically **not** the ownership monitor. Binding an ACTIVE
    # attachment's lifetime to the singleton registry is the defect
    # `owner_ref` exists to avoid — the registry outlives every binding in
    # it. This one says *my record is gone*, which is a different fact
    # arriving from a different process death.
    # `nil` if the registry is between restarts at this instant, and it is
    # not established later. That case is benign rather than handled: with no
    # `Ampd.Peer` there is nothing to install a record into, so this
    # attachment reaches its deadline and closes without ever having meant
    # anything. Reconnecting the monitor would be machinery for a window in
    # which the thing it protects cannot exist.
    registry_ref = case Process.whereis(Ampd.Peer) do
      nil -> nil
      p -> Process.monitor(p)
    end

    {:ok,
     %{
       phase: :provisional,
       sock: sock,
       setup: setup,
       setup_ref: ref,
       registry_ref: registry_ref,
       timer: timer,
       identity: identity,
       owner: nil,
       owner_ref: nil,
       record: nil
     }}
  end

  @impl true
  def handle_call({:prepare, record, owner}, _from, %{phase: :provisional} = s) do
    case disagrees(record, s.identity) do
      [] ->
        # **The new monitor is established BEFORE the setup one is dropped.**
        # Reversed, there would be an interval — however short — in which
        # nothing was watching, and a death inside it would leave an
        # attachment owned by a process nobody is waiting on.
        #
        # The setup deadline is deliberately **not** cancelled here. A
        # prepared attachment is still unfinished, and the caller that was
        # going to run B2 can die between the two; without the timer the
        # owning Peer's own liveness would be the only thing left holding the
        # Carrier's single attachment slot, which could be hours.
        owner_ref = Process.monitor(owner)
        Process.demonitor(s.setup_ref, [:flush])

        {:reply, :ok,
         %{s | phase: :prepared, record: record, owner: owner, owner_ref: owner_ref, setup_ref: nil}}

      bad ->
        {:reply, {:error, {:identity_mismatch, bad}}, s}
    end
  end

  def handle_call({:prepare, _, _}, _from, s),
    do: {:reply, {:error, {:not_provisional, s.phase}}, s}

  def handle_call({:activate, aref, aepoch}, _from, %{phase: :prepared} = s) do
    if s.record["attachment_ref"] == aref and s.record["attachment_epoch"] == aepoch do
      Process.cancel_timer(s.timer)
      {:reply, :ok, %{s | phase: :active, timer: nil}}
    else
      {:reply, {:error, {:identity_mismatch, s.record["attachment_ref"]}}, s}
    end
  end

  def handle_call({:activate, _, _}, _from, s),
    do: {:reply, {:error, {:not_prepared, s.phase}}, s}

  def handle_call(:state, _from, s), do: {:reply, s.phase, s}
  def handle_call(:record, _from, s), do: {:reply, s.record, s}
  def handle_call(:owner, _from, s), do: {:reply, s.owner, s}

  def handle_call(:snapshot, _from, s),
    do: {:reply, %{phase: s.phase, record: s.record, owner: s.owner}, s}

  # **The refusal is the feature.** A provisional attachment owns a socket
  # with real bytes in it and must not be a way to read them — and a prepared
  # one, which has an identity and a lifetime, still has no authorisation.
  def handle_call({:write, _}, _from, %{phase: p} = s) when p in [:provisional, :prepared],
    do: {:reply, {:error, p}, s}

  def handle_call({:read, _, _}, _from, %{phase: p} = s) when p in [:provisional, :prepared],
    do: {:reply, {:error, p}, s}

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

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{registry_ref: ref} = s)
      when not is_nil(ref) do
    Logger.debug(fn ->
      "ampd: the peer registry holding this terminal attachment's record went away " <>
        "(#{inspect(reason)}); the record is gone, so the stream is too"
    end)

    {:stop, :normal, s}
  end

  def handle_info(:setup_deadline, %{phase: p} = s) when p in [:provisional, :prepared] do
    Logger.warning(
      "ampd: a terminal attachment was still #{p} after " <>
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
