defmodule Ampd.Carrier.Terminal do
  @moduledoc """
  D.1.3c·2b — the grammar of an attach answer, and the one place a
  descriptor count is a semantic fact.

  ## Why this is not in `Ampd.Worktree.EffectChannel`

  That module knows `SCM_RIGHTS`, framing, correlation and ownership. It
  does not know what a terminal is, and teaching it would make the
  descriptor-carrying transport specific to the one operation that uses it
  today.

      EffectChannel        SCM_RIGHTS transport, ownership, correlation
      this module          what a terminal attach answer is allowed to be

  ## The cardinality is a rule, and it was previously only a sentence

  The frozen contract says:

      success   → exactly one descriptor
      refusal   → exactly zero descriptors

  and until this module existed nothing enforced it. `request_with_fd/5`
  returned whatever list arrived, so a host answering *attached* with no
  descriptor, or *refused* with one, or *attached* with two, would have
  handed a plausible-looking result to the code that is about to decide
  possession. The valid cases were tested; the malformed ones were not
  refused.

  **Every rejection closes every adopted socket.** They are already managed
  by the time they get here, so disposal is `:socket.close/1` and not a
  descriptor sink — but a rejection that returned without closing would be a
  protocol error that leaks, which is the shape this lane keeps finding.

  ## No socket list crosses into ORDERED B

  The success return is one socket, not a list of one. A caller holding a
  list has to decide what a second element would mean, and the answer —
  *this response was invalid* — belongs here, once.
  """

  alias Ampd.{AuthorityCoordinator, Loci, Peer, Worker, World}
  alias Ampd.Worktree.EffectChannel

  @attach_request "carrier-pty-attach-request@1"
  @attach_observation "carrier-pty-attach-observation@1"

  @doc "The schema a host attach answer must carry."
  def observation_schema, do: @attach_observation

  @doc """
  Ask the host to attach to a Carrier's terminal.

  Addressed by `carrier_ref` and `carrier_epoch` — the Carrier's incarnation,
  never a pathname and never a terminal. Returns exactly what
  `interpret/2` returns.
  """
  def attach(carrier_ref, carrier_epoch)
      when is_binary(carrier_ref) and is_binary(carrier_epoch) do
    case Ampd.Bridge.carrier_endpoint() do
      nil ->
        {:error,
         "no host carrier channel is possessed — refusing to resolve and execute the host by name instead"}

      %{sock: sock, incarnation: inc} ->
        body = %{
          "schema" => @attach_request,
          "op" => "pty-attach",
          "carrier_ref" => carrier_ref,
          "carrier_epoch" => carrier_epoch
        }

        case EffectChannel.request_with_fd(
               sock,
               inc,
               body,
               EffectChannel.deadline_ms(),
               @attach_observation
             ) do
          {:ok, obs, sockets} -> interpret(obs, sockets)
          {:error, why} -> {:error, why}
        end
    end
  end

  @doc """
  The attach grammar, as a total function over an observation and the
  sockets that came with it.

  Pure and separately callable so the malformed shapes can be falsified
  without a host willing to produce them — a real host never will, which is
  exactly why nothing had checked.

      {:ok, observation, socket}    attached, one stream, valid identity
      {:refused, observation}       refused, and no stream
      {:error, reason}              anything else — sockets closed

  ## A field that is absent is not a field that is false

  The first version read the two answer fields as booleans over a shape it
  assumed:

      refused? = is_binary(obs["refused"]) and obs["refused"] != ""

  which makes **every malformed `refused` silently equal to absent**. An
  answer carrying `refused: 0`, `refused: %{}` or `refused: true` alongside
  `attached: true` and one descriptor passed as a clean success. So the
  shapes are read into three-valued judgements — `:absent`, `:present`,
  `:malformed` — and a malformed field is a protocol failure rather than a
  default. `attached` gets the same treatment for the same reason.

  ## Cardinality was checked; identity was not

  Descriptor count was a semantic fact here from the start. The identities
  the host establishes were not, so this passed:

      %{"attached" => true, "attachment_ref" => nil,
        "attachment_epoch" => nil, "pty_epoch" => nil}   + one socket

  No semantic consumer existed yet, so it was not yet an authority defect —
  it was one the moment this answer became a `terminal-attachment@1`. The
  host mints all three (`host/src/attach.rs`) and their widths are already
  measured by the host's own acceptance battery; this is the runtime
  refusing to *believe* an answer that does not carry them.

      attachment_ref     "ta_" + 32 lowercase hex
      attachment_epoch   32 lowercase hex
      pty_epoch          32 lowercase hex

  `carrier_ref` and `carrier_epoch` are **not** required to be echoed. They
  came from the request and are held by ORDERED A; demanding them back
  would be asking the machine to confirm something the World already knows,
  which is symmetry rather than evidence.
  """
  def interpret(obs, sockets) when is_map(obs) and is_list(sockets) do
    case {shape(obs["attached"], true), shape(obs["refused"], :string), sockets} do
      {:present, :absent, [sock]} ->
        case malformed_identity(obs) do
          [] -> {:ok, obs, sock}
          bad -> reject(sockets, "the host reported an attachment whose physical identity is not " <>
                   "well formed: #{Enum.join(bad, ", ")}")
        end

      {:absent, :present, []} ->
        {:refused, obs}

      # Everything below is a protocol failure, and each is named rather
      # than collapsed, because "the host answered wrongly" is not a repair
      # instruction and these have different ones.
      {:malformed, _, _} ->
        reject(sockets, "the `attached` field is present and is not a boolean")

      {_, :malformed, _} ->
        reject(sockets, "the `refused` field is present and is not a non-empty string")

      {:present, :absent, []} ->
        reject(sockets, "the host reported an attachment and sent no stream descriptor")

      {:present, :absent, many} ->
        reject(
          sockets,
          "the host reported one attachment and sent #{length(many)} stream descriptors"
        )

      {:absent, :present, some} ->
        reject(
          sockets,
          "the host refused the attach and sent #{length(some)} stream descriptor(s) with the refusal"
        )

      {:present, :present, _} ->
        reject(sockets, "the host answered both attached and refused")

      {:absent, :absent, _} ->
        reject(sockets, "the host answered neither attached nor refused")
    end
  end

  # Three-valued, because two-valued is how a malformed field becomes a
  # default. `:present` means "present and well formed *and* true" for the
  # boolean — `attached: false` is an absent claim, not a malformed one,
  # since a host that sets it explicitly alongside a refusal is being
  # explicit rather than wrong.
  defp shape(nil, _), do: :absent
  defp shape(false, true), do: :absent
  defp shape(true, true), do: :present
  defp shape(v, :string) when is_binary(v) and v != "", do: :present
  defp shape(_, _), do: :malformed

  @doc false
  # Public for the falsifiers: a host that produces these does not exist,
  # which is exactly why the check has to be drivable without one.
  def malformed_identity(obs) do
    []
    |> check(obs, "attachment_ref", &prefixed_hex?/1, ~s(want "ta_" + 32 lowercase hex))
    |> check(obs, "attachment_epoch", &hex32?/1, "want 32 lowercase hex")
    |> check(obs, "pty_epoch", &hex32?/1, "want 32 lowercase hex")
    |> Enum.reverse()
  end

  defp check(acc, obs, key, ok?, want) do
    v = obs[key]
    if ok?.(v), do: acc, else: ["#{key}=#{inspect(v)} (#{want})" | acc]
  end

  defp hex32?(v), do: is_binary(v) and byte_size(v) == 32 and v =~ ~r/\A[0-9a-f]{32}\z/

  defp prefixed_hex?(v),
    do: is_binary(v) and byte_size(v) == 35 and v =~ ~r/\Ata_[0-9a-f]{32}\z/

  defp reject(sockets, why) do
    Enum.each(sockets, &:socket.close/1)
    {:error, "the attach answer was not a valid #{@attach_observation}: #{why}"}
  end
  # ==========================================================================
  # D.1.3c·2b·1 — semantic terminal possession
  # ==========================================================================

  @ticket_schema "terminal-attachment-ticket@1"
  @record_schema "terminal-attachment@1"
  @resize_request "carrier-pty-resize-request@1"
  @resize_observation "carrier-pty-resize-observation@1"

  @doc "The schemas this module owns."
  def schemas, do: [@attach_request, @attach_observation, @ticket_schema, @record_schema]

  # ------------------------------------------------------------------ ORDERED A
  @doc """
  ORDERED A. Agree on **which Carrier** may be attached to, and mint an
  ephemeral ticket recording what that agreement rests on.

  Returns `{:ok, ticket}` or `{:refused, refusal}`. On refusal the host is
  never asked, exactly as in `Ampd.Carrier.admit_start/2`.

  ## `pty_epoch` is not here, and putting it here was our own error

  The earlier design for this slice had ORDERED A binding

      peer · locus · worker · carrier · pty_epoch

  and that is not constructible. The World-side `carrier-incarnation@1`
  carries the Carrier's identity, its Worker, its Locus, its Peer and its
  generation — and nothing about a terminal. `pty_epoch` first exists in the
  runtime when `carrier-pty-attach-observation@1` comes back from the host,
  because the host is the only thing that knows which PTY the Carrier
  currently owns.

  So the ticket agrees to:

      attach to the terminal presently possessed by Carrier Cₙ

  and the machine answers:

      that terminal was Pₖ, and the physical attachment is Aₘ

  Fabricating an expected `pty_epoch` on the World side to make the ticket
  look symmetrical would be the World attesting to a fact it cannot observe
  — the same `agreement ≠ attestation` confusion that put an
  admission-bound payload identity into the Carrier ticket in the first
  place, run backwards.

  ## The ticket is evidence, and it is not durable

  A Carrier start writes its attempt to disk before the machine is asked,
  because a machine process can outlive the runtime that spawned it and boot
  has to find out. A terminal attachment has no such residue: the runtime
  dying closes the socket endpoint, the host's pump ends, and c·2a·1 makes
  the next attach reclaim the slot by re-deriving liveness rather than
  remembering it. There is nothing for a boot sweep to reconcile, so there
  is no ledger — apart from the accepted `recvmsg`→adopt seam, which can
  strand one physical attempt and cannot produce a semantic attachment.
  """
  def admit_attach(peer_ref) when is_binary(peer_ref) do
    AuthorityCoordinator.transact(fn -> admit(Peer.resolve(peer_ref)) end)
  end

  defp admit(nil), do: {:refused, refuse("terminal-peer-gone", %{})}

  defp admit(peer) do
    att = Peer.attachment(peer["id"])
    lane = att && Loci.lane(att["locus_ref"])

    with :ok <- occupied(att),
         :ok <- lane_known(lane),
         # The whole of occupancy, from the one module that knows what
         # occupying a Locus means. Re-deriving any part of it here would be
         # a second opinion on D.1.2's question.
         :ok <- Worker.occupancy(peer, lane),
         {:ok, worker} <- current_worker(att),
         {:ok, carrier} <- embodying_carrier(peer, worker),
         :ok <- no_terminal(peer),
         :ok <- owner_present(peer) do
      {:ok,
       %{
         "schema" => @ticket_schema,
         "ticket_id" => mint("tt_"),
         "peer_ref" => peer["id"],
         "peer_epoch" => att["peer_epoch"],
         "actor" => peer["actor"],
         "world_ref" => World.lineage(),
         "locus_ref" => att["locus_ref"],
         "worker_ref" => worker["id"],
         "worker_generation" => worker["generation"] || 1,
         "carrier_ref" => carrier["carrier_ref"],
         "carrier_epoch" => carrier["carrier_epoch"],
         "admitted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end
  end

  defp occupied(nil), do: {:refused, refuse("carrier-not-attached", %{})}
  defp occupied(_), do: :ok

  defp lane_known(nil), do: {:refused, refuse("locus-unknown", %{})}
  defp lane_known(_), do: :ok

  defp current_worker(att) do
    case Loci.worker(att["worker_ref"]) do
      nil -> {:refused, refuse("worker-unknown", %{"worker_ref" => att["worker_ref"]})}
      %{"status" => s} = _w when s != "open" -> {:refused, refuse("worker-not-open", %{})}
      w -> {:ok, w}
    end
  end

  # The Carrier must be the one currently embodying **this** Worker for
  # **this** Peer, not merely a live Carrier the peer happens to hold.
  # `still_current?/2` is the existing predicate for that and is reused
  # rather than restated.
  defp embodying_carrier(peer, worker) do
    case Peer.carrier(peer["id"]) do
      nil ->
        {:refused, refuse("terminal-no-live-carrier", %{"peer_ref" => peer["id"]})}

      c ->
        if Ampd.Carrier.still_current?(c, worker),
          do: {:ok, c},
          else: {:refused, refuse("terminal-carrier-not-current", %{"carrier_ref" => c["carrier_ref"]})}
    end
  end

  # At most one terminal attachment per Peer in this slice. Refusing rather
  # than replacing is the `attach_carrier/2` rule: a second admission for a
  # peer that already possesses one means two commits raced.
  defp no_terminal(peer) do
    case Peer.terminal_attachment(peer["id"]) do
      nil -> :ok
      r -> {:refused, refuse("terminal-already-attached", %{"attachment_ref" => r["attachment_ref"]})}
    end
  end

  defp owner_present(peer) do
    case Peer.owner_pid(peer["id"]) do
      nil -> {:refused, refuse("terminal-peer-owner-gone", %{"peer_ref" => peer["id"]})}
      pid -> if Process.alive?(pid), do: :ok, else: {:refused, refuse("terminal-peer-owner-gone", %{})}
    end
  end

  # ------------------------------------------------------------------ machine
  @doc """
  The machine phase. **Not ordered**, and it decides nothing.

  Asks the host to attach to the Carrier the ticket agreed on, and returns
  the physical identity the host established together with the one adopted
  socket. The duration is unbounded, which is the whole reason it is outside
  the total order.
  """
  def machine_attach(ticket) when is_map(ticket),
    do: attach(ticket["carrier_ref"], ticket["carrier_epoch"])

  @doc """
  Start a PROVISIONAL owner for the adopted socket and hand the stream over.

  Returns `{:ok, pid, identity}`. **Any failure closes the socket and
  publishes nothing** — there is no state in which this half-succeeds,
  because the only thing it produces is a process that owns a descriptor.

  The transfer is performed here rather than inside the supervisor because
  `{:otp, :controlling_process}` may only be set by the socket's current
  owner, which is whoever adopted it.
  """
  def own_stream(ticket, obs, sock) when is_map(ticket) and is_map(obs) do
    identity = %{
      # Host-established physical identity, bound at the moment it is
      # learned. Nothing in the World predicted these.
      "attachment_ref" => obs["attachment_ref"],
      "attachment_epoch" => obs["attachment_epoch"],
      "pty_epoch" => obs["pty_epoch"],
      # World-agreed, carried from the ticket. Not read back off the answer:
      # the machine echoing our own request is not evidence.
      "carrier_ref" => ticket["carrier_ref"],
      "carrier_epoch" => ticket["carrier_epoch"]
    }

    case Ampd.TerminalAttachment.Supervisor.start_owner(%{
           sock: sock,
           setup: self(),
           identity: identity
         }) do
      {:ok, pid} ->
        case :socket.setopt(sock, {:otp, :controlling_process}, pid) do
          :ok ->
            {:ok, pid, identity}

          {:error, why} ->
            # The child exists and does not own the stream. Stopping it is
            # not enough — we are still the owner, so we close.
            _ = Ampd.TerminalAttachment.close(pid)
            _ = :socket.close(sock)
            {:error, {:transfer_failed, why}}
        end

      {:error, why} ->
        _ = :socket.close(sock)
        {:error, {:owner_start_failed, why}}
    end
  end

  # --------------------------------------------------------------- ORDERED B1
  @doc """
  ORDERED B1. Re-derive every basis, bind the physical identity the machine
  established, and install a **`COMMITTING`** record.

  Returns `{:ok, record}` or `{:refused, refusal}`.

  **On refusal this disposes of `pid`.** A public function that kills its
  argument is worth saying out loud: nothing was installed, so there is no
  record to remove, but the provisional owner exists and holds the Carrier's
  single attachment slot. Leaving that to the caller made "B1 refuses and
  the stream closes" a property of one call path rather than of B1. The kill
  skips `terminate/2` and therefore its explicit `:socket.close/1`; the
  socket dies with its owner, measured on OTP 28.2, which is what makes that
  acceptable rather than merely convenient.

  `COMMITTING` is not possession and is not a weaker possession. Nothing may
  be read, written or resized through it and it is not projected as an
  attachment. It exists so the interval between "the World has a record" and
  "the World says the record is current" is a state with a name, rather than
  a gap in which a half-built attachment is indistinguishable from a real
  one.
  """
  def commit_b1(ticket, obs, pid) when is_map(ticket) and is_map(obs) and is_pid(pid),
    do: AuthorityCoordinator.transact(fn -> b1(ticket, obs, pid) end)

  defp b1(ticket, obs, pid) do
    do_b1(ticket, obs, pid)
  rescue
    # **A participant failure skipped the disposal, and a comment downstream
    # said it had not.**
    #
    # `moved/1` makes five participant reads before the `reason ->` branch
    # that kills the owner is reachable at all. A failure in any of them
    # unwound straight past it, leaving a provisional owner holding the
    # Carrier's single attachment slot with nothing referring to it — while
    # `commit/4` matched the refusal under the words "b1/3 has already killed
    # the owner. Nothing was published."
    #
    # The disposal belongs to every way out of this function, so it is here
    # rather than in one branch of it. The failure is re-raised because its
    # class is the caller's answer and must not become a plain refusal.
    e in Ampd.Participant.Failure ->
      kill_owner(pid)
      reraise e, __STACKTRACE__
  end

  defp do_b1(ticket, obs, pid) do
    case moved(ticket) do
      nil ->
        record = %{
          "schema" => @record_schema,
          "attachment_ref" => obs["attachment_ref"],
          "attachment_epoch" => obs["attachment_epoch"],
          "peer_ref" => ticket["peer_ref"],
          "peer_epoch" => ticket["peer_epoch"],
          "locus_ref" => ticket["locus_ref"],
          "worker_ref" => ticket["worker_ref"],
          "worker_generation" => ticket["worker_generation"],
          "carrier_ref" => ticket["carrier_ref"],
          "carrier_epoch" => ticket["carrier_epoch"],
          # Machine-established physical identity, bound at commit. The World
          # never predicted it and never claimed to.
          "pty_epoch" => obs["pty_epoch"]
        }

        case Peer.install_terminal(ticket["peer_ref"], record, pid) do
          {:ok, stored} -> {:ok, stored}
          {:refused, why} -> {:refused, refuse("terminal-commit-refused", %{"reason" => to_string(why)})}
        end

      reason ->
        # **The stream goes with the refusal, and it goes from here.** Nothing
        # was installed, so there is no record to remove — but the provisional
        # owner exists and holds the Carrier's single attachment slot, and a
        # refusal that left it running would be a refusal the host has to wait
        # out. Putting this in the caller, which is what the first version
        # did, makes "B1 refuses and the stream closes" a property of one call
        # path rather than of B1.
        kill_owner(pid)
        {:refused, refuse(reason, ticket)}
    end
  end

  # --------------------------------------------------------------- ORDERED B2
  @doc """
  ORDERED B2. Re-derive **every basis again**, prove the stream owner is
  still the one the record was installed for, and finalise `ACTIVE`.

  Returns `{:ok, record}` or `{:refused, refusal}`. A refusal leaves nothing
  behind: the `COMMITTING` record is removed and the stream converges closed.

  ## Why a second re-derivation is not bureaucracy

  Between B1 and the owner transition the World can move — a Worker closes,
  a Carrier is replaced, the Peer loses occupancy, the world lineage
  advances. Without B2 the sequence

      B1 verifies occupancy · installs COMMITTING
      Worker closes · Carrier replaced · Peer loses occupancy
      owner activates
      record marked ACTIVE

  launders an authorisation granted under one World state into a different
  one. That is precisely the class of defect the ordered re-derivations
  exist for, and it is cheap to close: B2 is BEAM-local state re-derivation
  and performs no machine I/O at all.
  """
  def commit_b2(ticket, record, pid) when is_map(ticket) and is_map(record) and is_pid(pid),
    do: AuthorityCoordinator.transact(fn -> b2(ticket, record, pid) end)

  defp b2(ticket, record, pid) do
    peer_ref = ticket["peer_ref"]
    current = Peer.terminal_attachment(peer_ref)
    owner = Peer.owner_pid(peer_ref)

    # **One bounded call, before the `cond`.** See `safely/1`: a
    # `GenServer.call` to a process that dies mid-call exits the caller, and
    # inside a transaction the caller is the total order.
    #
    # Two calls with the five-second default was the first version, and it
    # put ten seconds of a fifteen-second budget in front of *every* refusal
    # — including the ones that never look at the answers. One snapshot,
    # bounded at a second, is the same evidence.
    snap = safely(fn -> Ampd.TerminalAttachment.snapshot(pid) end)
    held = if is_map(snap), do: snap.record, else: snap
    bound_owner = if is_map(snap), do: snap.owner, else: snap

    reason =
      cond do
        # The same World bases as B1, in the same disclosure-graded order.
        (m = moved_again(ticket)) != nil ->
          m

        current == nil ->
          "terminal-record-gone"

        current["status"] != "COMMITTING" ->
          "terminal-record-not-committing"

        current["attachment_ref"] != record["attachment_ref"] ->
          "terminal-record-cross-attachment"

        current["attachment_epoch"] != record["attachment_epoch"] ->
          "terminal-record-cross-attachment"

        # The physical identity the World holds and the identity the stream
        # owner was created for must be the same five fields. Disagreeing
        # here means a record describing another attachment, which is the
        # defect `Ampd.TerminalAttachment.prepare/3` refuses one layer down
        # and which is worth refusing from both sides.
        held == :unreachable ->
          "terminal-owner-unreachable"

        held == :gone or not Process.alive?(pid) ->
          "terminal-owner-gone"

        disagrees_physically(current, held) != [] ->
          "terminal-owner-identity-mismatch"

        # **The lifetime witness is proved, not assumed.** A prepared
        # attachment monitoring the wrong process is indistinguishable from a
        # correct one until the process it should have been watching dies.
        #
        # `owner == nil` is ordered after `moved_again/1`, which refuses
        # `terminal-peer-gone` first for every peer this can be true of. It
        # is kept as the statement that this transaction will not activate
        # without a witness, and it is reachable through `commit/4` before
        # `prepare/3` — not here.
        owner == nil ->
          "terminal-peer-owner-gone"

        bound_owner != owner ->
          "terminal-owner-not-peer-owner"

        true ->
          nil
      end

    if reason do
      # **The convergence is here, not in the caller.** A refusal at B2 must
      # leave nothing behind — no COMMITTING record, no open stream — and a
      # caller that has to remember to do that is a caller that can forget.
      # `K.11` found this the only way it is findable: the refusal was
      # correct, by the right name, and the record it refused was still
      # sitting in `Ampd.Peer` afterwards.
      converge(peer_ref, current, record, pid)
      {:refused, refuse(reason, ticket)}
    else
      # **The World first, then the stream.** Reversed, a failure to finalise
      # the stream would leave a usable descriptor under a record that still
      # says COMMITTING. This way the worst case is an ACTIVE record over a
      # PREPARED stream, which refuses every byte and is removed by the
      # monitor the moment the owner goes.
      case Peer.activate_terminal(peer_ref, record["attachment_ref"], record["attachment_epoch"]) do
        {:ok, active} ->
          finalise_stream(peer_ref, record, pid, active)

        {:refused, why} ->
          {:refused, refuse("terminal-commit-refused", %{"reason" => inspect(why)})}
      end
    end
  end

  # **The one ordered operation in this tree that mutates two independently
  # failing participants, so its failure cut is stated for each of them
  # rather than assumed.**
  #
  #     Ampd.Peer                activate_terminal   COMMITTING → ACTIVE
  #     Ampd.TerminalAttachment  activate            PREPARED   → ACTIVE
  #
  # There is no rollback layer here and this does not invent one. It proves
  # the cut for each way the second participant can fail:
  #
  #     replied :ok         both applied
  #     replied otherwise   the stream refused. The record is removed by
  #                         identity — a compensation, and a sound one,
  #                         because the participant ANSWERED
  #     never delivered     `:noproc`; the owner is gone, and a gone owner
  #                         holds no stream. Remove
  #     died                whatever it did before dying, the stream died
  #                         with it. Remove
  #     did not answer      **INDETERMINATE, and nothing is compensated.**
  #
  # The last one is the whole reason this function exists. `safely/1` mapped
  # a timeout to `:unreachable` and fell into the same arm as a refusal, so a
  # stream owner that was merely busy — queued behind a `:socket.send` on a
  # full buffer — had its World record removed while its activation was
  # still in the mailbox. That leaves an ACTIVE stream with nothing in the
  # World naming it: unrevokable, and invisible to the projection.
  #
  # Leaving the record is the safe direction, and it is not a new state: an
  # ACTIVE record over a PREPARED stream is the worst case the ordering
  # above was already chosen to tolerate — it refuses every byte, and the
  # owner's monitor removes it the moment the owner goes.
  #
  # The class is read off `Ampd.Participant.Failure.reason`, which is what
  # the mechanism MEASURED, rather than re-derived from `Process.alive?/1`
  # out here — an answer that is stale the instant it returns.
  defp finalise_stream(peer_ref, record, pid, active) do
    case ask_activate(pid, record) do
      :ok ->
        {:ok, active}

      {:indeterminate, why} ->
        {:refused,
         refuse("terminal-activation-indeterminate", %{
           "reason" => why,
           "attachment_ref" => record["attachment_ref"]
         })}

      {:gone, why} ->
        undo_activation(peer_ref, record, why)

      {:refused_by_owner, other} ->
        undo_activation(peer_ref, record, inspect(other))
    end
  end

  # **The rescue wraps the crossing and nothing else, and the first version
  # did not.** Attached to the whole of `finalise_stream/4` it also covered
  # `undo_activation/3` — which crosses a SECOND participant,
  # `Ampd.Peer.remove_terminal/3`. So a failure there re-entered the same
  # rescue, removed the record a second time, and if that second failure
  # happened to be a timeout reported it as an ACTIVATION that was
  # indeterminate. Two participants, one handler, and the mislabel this
  # function exists to remove reintroduced through the branch that was
  # supposed to be the safe one.
  defp ask_activate(pid, record) do
    case Ampd.Participant.call(
           pid,
           {:activate, record["attachment_ref"], record["attachment_epoch"]},
           :mutate
         ) do
      :ok -> :ok
      other -> {:refused_by_owner, other}
    end
  rescue
    e in Ampd.Participant.Failure ->
      # **`reason`, not `outcome`, and the difference is the whole point.**
      # `outcome` is `:indeterminate` for a timeout AND for a death, because
      # `Ampd.Participant` will not narrow a death without a witness — and it
      # is right not to. What follows narrows one of them on DOMAIN grounds,
      # and the ground is deliberately not "the mutation did not happen":
      #
      #   timeout  the owner is ALIVE and still holds the request. The
      #            activation may be queued behind a `:socket.send` blocked on
      #            a full buffer. Nothing may be compensated.
      #   gone     never reached, or died. Whatever it did before dying, THE
      #            STREAM DIED WITH IT — so the World record must not go on
      #            naming a possession whose stream no longer exists. The
      #            record is removed because the RESOURCE is gone, not
      #            because the mutation was not applied.
      #
      # A `:witness` would be the mechanism's way to narrow the death, and it
      # is not used because a witness answers "did my mutation land" and the
      # question here is "is there anything left for the record to name".
      if e.reason == :timeout,
        do: {:indeterminate, Exception.message(e)},
        else: {:gone, Exception.message(e)}
  end

  defp undo_activation(peer_ref, record, why) do
    _ = Peer.remove_terminal(peer_ref, record["attachment_ref"], record["attachment_epoch"])
    {:refused, refuse("terminal-owner-refused-activation", %{"reason" => why})}
  end

  # **Every call this transaction makes to a stream owner goes through here.**
  #
  # A `GenServer.call` to a process that dies mid-call exits the caller, and
  # inside `AuthorityCoordinator.transact/1` the caller **is** the total
  # order — so an ordinary disconnect, landing in the microseconds between
  # `Process.alive?/1` and the message that follows it, would take the
  # coordinator down: `seq` back to zero, the projection epoch re-minted,
  # every subscriber resnapshotting. One lost attachment becomes a
  # control-plane outage.
  #
  # `Ampd.Peer` is deliberately outside the total order, and its `:DOWN`
  # handling kills stream owners. So this race is not exotic; it is the
  # ordinary path, and `Process.alive?/1` cannot close it because the answer
  # is stale the instant it is returned.
  #
  # ## Why only the stream owner, and what that leaves open
  #
  # An earlier version of this comment said `Ampd.Peer` dying "invalidates
  # this whole incarnation" and so needed no wrapping. **That is false, and
  # worth correcting rather than deleting:** the application supervisor is
  # `:one_for_one` and starts `Ampd.Peer` *before* the coordinator, so a
  # `Ampd.Peer` crash restarts `Ampd.Peer` alone and leaves the coordinator
  # running — with, if it was mid-call, an exit signal on the way.
  #
  # The real distinction is the one that justifies the line being drawn
  # here: **a `TerminalAttachment` dying is the normal path** — it is
  # `:temporary`, it is killed by the Carrier-removal funnel, it dies with
  # its owner — whereas `Ampd.Peer` and `Ampd.Loci` dying is a fault. Every
  # ordered transaction in this tree calls both bare, and has since C1.0b.1;
  # wrapping them here alone would protect one transaction and misrepresent
  # the rest as protected too.
  #
  # **So this is an accepted residual with a stated scope**, not a closed
  # question: a registry crash can still exit a transaction, in this module
  # exactly as in `Ampd.Carrier`. Closing it is a tree-wide change to how
  # ordered transactions call registries, and it does not belong in a slice
  # about terminals.
  #
  # A timeout is not a death and is not reported as one. The two are told
  # apart because "the owner is gone" and "the owner did not answer in time"
  # want different refusals and, one layer up in `stream_phase/1`, opposite
  # conclusions.
  defp safely(fun) do
    fun.()
  catch
    :exit, {:timeout, _} -> :unreachable
    :exit, _ -> :gone
  end

  # Remove exactly what this commit installed and nothing else.
  #
  # **A transaction converges what it created.** What B1 created is a record
  # in state COMMITTING; anything else in the slot was put there by somebody
  # else, and removing it would make a failed commit destroy a live
  # possession.
  #
  #     ours and COMMITTING   remove the record, close the stream
  #     ours and ACTIVE       a duplicate B2 — change nothing
  #     anything else         close only this transaction's own stream
  defp converge(peer_ref, current, record, pid) do
    ours? =
      is_map(current) and
        current["attachment_ref"] == record["attachment_ref"] and
        current["attachment_epoch"] == record["attachment_epoch"]

    cond do
      ours? and current["status"] == "COMMITTING" ->
        # Drops the record, demonitors, and kills the owner — the socket dies
        # with it. One call, so the two halves cannot be left out of step.
        # Addressed by identity even though `ours?` has just established it,
        # because the removal crosses a process boundary and the slot can be
        # replaced in between.
        _ = Peer.remove_terminal(peer_ref, record["attachment_ref"], record["attachment_epoch"])
        :ok

      # A duplicate B2. The possession it is refusing to re-establish was
      # legitimately established by the first one — `K.18` failed the version
      # of this function that tore it down.
      #
      # **Keyed on the status, with no `ours?` catch-all under it.** The
      # version that had one claimed in a comment to make a third status
      # visible and did not: the catch-all silently preserved it. A status
      # this function has not been taught about now falls to the last clause
      # and converges only this transaction's own stream, which is the
      # conservative act.
      ours? and current["status"] == "ACTIVE" ->
        :ok

      true ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        :ok
    end
  end

  # **B2's re-derivation has a name of its own, and that is deliberate.**
  # Removing B1's re-derivation and removing B2's are different defects with
  # different consequences, and a sabotage probe cannot tell them apart if
  # both are the same call to the same function in the same shape. This is
  # the anchor for the second one.
  defp moved_again(ticket), do: moved(ticket)

  # Every World basis the ticket agreed on, re-derived. Returns the name of
  # the first thing that moved, or nil. Disclosure-graded: cheapest
  # structural facts first, authority basis last — the `Ampd.Carrier.commit/2`
  # convention.
  defp moved(ticket) do
    peer = Peer.resolve(ticket["peer_ref"])
    att = peer && Peer.attachment(peer["id"])
    worker = Loci.worker(ticket["worker_ref"])
    lane = Loci.lane(ticket["locus_ref"])
    carrier = peer && Peer.carrier(peer["id"])

    cond do
      peer == nil -> "terminal-peer-gone"
      att == nil -> "carrier-not-attached"
      lane == nil -> "locus-unknown"
      worker == nil -> "worker-unknown"
      att["peer_epoch"] != ticket["peer_epoch"] -> "attachment-epoch-stale"
      att["locus_ref"] != ticket["locus_ref"] -> "carrier-attached-elsewhere"
      att["worker_ref"] != ticket["worker_ref"] -> "terminal-worker-drift"
      World.lineage() != ticket["world_ref"] -> "terminal-world-generation-stale"
      (worker["generation"] || 1) != ticket["worker_generation"] -> "terminal-worker-generation-stale"
      worker["status"] != "open" -> "worker-not-open"
      peer["actor"] != ticket["actor"] -> "terminal-actor-drift"
      carrier == nil -> "terminal-no-live-carrier"
      carrier["carrier_ref"] != ticket["carrier_ref"] -> "terminal-carrier-replaced"
      carrier["carrier_epoch"] != ticket["carrier_epoch"] -> "terminal-carrier-replaced"
      true -> nil
    end
  end

  @physical ~w(attachment_ref attachment_epoch carrier_ref carrier_epoch pty_epoch)

  defp disagrees_physically(_a, nil), do: @physical

  defp disagrees_physically(a, b),
    do: Enum.filter(@physical, fn k -> Map.get(a, k) != Map.get(b, k) end)

  # ------------------------------------------------------------------- whole
  @doc """
  Ordered A → machine → provisional ownership → B1 → prepare → B2.

  Returns `{:ok, record}` with `status` `ACTIVE`, or `{:refused, refusal}`,
  or `{:error, reason}` when the machine could not answer.

  **The commit is two ordered transactions with a local owner transition
  between them, and that cut is exposed rather than hidden.** The semantic
  record lives in `Ampd.Peer` and the stream lives in
  `Ampd.TerminalAttachment`; those cannot change atomically, and a single
  "Transaction B" that claimed otherwise would be a name papering over a
  real interval. B1 and B2 may be called the commit phase in prose. In the
  source they are two functions because they are two linearization points.
  """
  def acquire(peer_ref) when is_binary(peer_ref) do
    with {:ok, ticket} <- admit_attach(peer_ref) do
      case machine_attach(ticket) do
        {:ok, obs, sock} ->
          case own_stream(ticket, obs, sock) do
            {:ok, pid, identity} -> commit(ticket, obs, pid, identity)
            {:error, why} -> {:error, why}
          end

        {:refused, obs} ->
          {:refused, refuse("terminal-machine-refused", %{"reason" => obs["refused"]})}

        {:error, why} ->
          {:error, why}
      end
    end
  end

  defp commit(ticket, obs, pid, identity) do
    case commit_b1(ticket, obs, pid) do
      {:ok, record} ->
        case Peer.owner_pid(ticket["peer_ref"]) do
          nil ->
            abandon(ticket, record, pid)
            {:refused, refuse("terminal-peer-owner-gone", ticket)}

          owner ->
            case safely(fn -> Ampd.TerminalAttachment.prepare(pid, Map.merge(record, identity), owner) end) do
              :ok ->
                # **B2 converges its own refusal**, so there is nothing to do
                # here on that path. A second removal from out here — outside
                # the order, and unaddressed — could drop a record a *later*
                # commit had already installed in the slot this one vacated.
                commit_b2(ticket, record, pid)

              other ->
                abandon(ticket, record, pid)
                {:refused, refuse("terminal-owner-identity-mismatch", %{"reason" => inspect(other)})}
            end
        end

      # `b1/3` disposes of the owner on every way out — the refusal branch and
      # a participant failure alike. Nothing was published.
      {:refused, r} ->
        {:refused, r}
    end
  end

  # The one convergence `commit/4` still owns: B1 installed a record and the
  # owner transition never happened.
  #
  # **Addressed by identity, and inside the order.** The unaddressed version
  # of this ran outside `transact` and removed whatever was in the slot, so a
  # commit that had already converged its own failure could then drop a
  # record a subsequent commit had legitimately installed in the same slot.
  # Removal now takes the same two identity arguments finalisation does, for
  # the same reason.
  defp abandon(ticket, record, pid) do
    _ =
      AuthorityCoordinator.transact(fn ->
        Peer.remove_terminal(ticket["peer_ref"], record["attachment_ref"], record["attachment_epoch"])
      end)

    kill_owner(pid)
  end

  # Total, and it never raises. `Process.exit/2` on a dead pid is a no-op,
  # where `GenServer.stop/3` exits `:noproc` — and the one path that reaches
  # this with a **guaranteed** dead pid is `install_terminal` answering
  # `{:refused, :owner_gone}`, which it answers precisely because the process
  # is gone. The socket dies with its owner, measured on OTP 28.2, so this is
  # disposal and not merely termination.
  defp kill_owner(pid) do
    Process.exit(pid, :kill)
    :ok
  end

  @doc """
  Release a peer's terminal attachment. `:ok` either way.

  Voluntary. Losing the Carrier does this without being asked, because the
  terminal relation is subordinate to the Carrier relation.
  """
  def release(peer_ref) when is_binary(peer_ref) do
    # **Addressed, like every other removal.** "Whatever this peer has" is
    # the right meaning for a caller that holds the peer and nothing else —
    # and it is the wrong meaning by the time this transaction runs, because
    # the `{:tx, _}` message queues. Between the call and the turn, the
    # attachment this caller meant can die, its record can be cleared by
    # `Ampd.Peer`'s monitor, and a fresh acquisition can install a
    # replacement in the same slot. An unaddressed removal then kills a live
    # possession nobody asked to release.
    #
    # Reading the record and removing by its identity happen in the same
    # transaction, and every install is ordered, so nothing can be
    # substituted between them.
    AuthorityCoordinator.transact(fn ->
      case Peer.terminal_attachment(peer_ref) do
        nil -> :ok
        r -> Peer.remove_terminal(peer_ref, r["attachment_ref"], r["attachment_epoch"])
      end
    end)
  end

  # ------------------------------------------------------------------ resize
  @doc """
  Resize the terminal this peer possesses.

  **Only an ACTIVE semantic attachment may ask.** A `COMMITTING` record is
  not possession, and resizing is an act of possession in exactly the way
  writing is.

  The request is addressed by the epoch triple the host requires —
  `carrier_epoch`, `pty_epoch`, `attachment_epoch` — read off the current
  record rather than supplied, so a caller cannot name a terminal it does
  not hold. The payload carries rows and columns and no `TIOCSWINSZ`: the
  host owns the ioctl and the Carrier's floor attests that it does.
  """
  def resize(peer_ref, rows, cols) when is_binary(peer_ref) and is_integer(rows) and is_integer(cols) do
    case Peer.terminal_attachment(peer_ref) do
      nil -> {:refused, refuse("terminal-not-attached", %{"peer_ref" => peer_ref})}
      record -> resize_record(record, rows, cols)
    end
  end

  @doc false
  # The seam a stale record can be pushed through. A caller holding the
  # record of attachment A1 must not be able to resize the replacement A2
  # that now occupies the same peer, so currency is re-derived from the
  # record's own identity rather than from the peer alone.
  def resize_record(record, rows, cols) when is_map(record) do
    current = Peer.terminal_attachment(record["peer_ref"])

    cond do
      current == nil ->
        {:refused, refuse("terminal-not-attached", %{"peer_ref" => record["peer_ref"]})}

      current["attachment_ref"] != record["attachment_ref"] or
          current["attachment_epoch"] != record["attachment_epoch"] ->
        {:refused,
         refuse("terminal-attachment-stale", %{
           "held" => record["attachment_ref"],
           "current" => current["attachment_ref"]
         })}

      current["status"] != "ACTIVE" ->
        {:refused, refuse("terminal-not-possessed", %{"status" => current["status"]})}

      # **Possession is the conjunction, and resize is the one operation that
      # could have been granted on half of it.** Bytes go through
      # `Ampd.TerminalAttachment`, so its phase gates them on its own; a
      # resize goes to the host addressed by epochs and never touches the
      # stream owner, so nothing would have consulted it.
      #
      # The window is real and small: B2 finalises the World record and then
      # the stream, and between those two calls the record says ACTIVE while
      # the owner is still PREPARED. A resize arriving there would be
      # performed under a possession that had not finished becoming one — and
      # if the second call then fails, performed under one that never does.
      stream_phase(current["peer_ref"]) != :active ->
        {:refused,
         refuse("terminal-stream-not-active", %{
           "status" => current["status"],
           "reason" => "the World record is ACTIVE and the stream owner has not finished becoming so"
         })}

      rows < 1 or cols < 1 ->
        {:refused, refuse("terminal-resize-degenerate", %{"rows" => rows, "cols" => cols})}

      true ->
        ask_resize(current, rows, cols)
    end
  end

  # The stream owner's phase, or `:gone`. The pid is runtime machinery and
  # does not leave this module — what crosses the boundary is a phase.
  #
  # **A busy owner is an ACTIVE owner, and reading a timeout as "not yet
  # active" was a real regression.** `read/1` and `write/2` run
  # `:socket.recv/3` and `:socket.send/2` synchronously inside the
  # attachment process, so an owner with output flowing through it can take
  # arbitrarily long to answer — and PROVISIONAL and PREPARED cannot,
  # because they refuse bytes without blocking. There is exactly one phase
  # that can fail to answer in time, so a timeout *is* the answer.
  #
  # The first version treated it as `:gone` and refused a legitimate resize
  # of a terminal that was merely busy, with a message saying the stream had
  # not finished becoming active. That is the ordinary case — someone
  # resizing a window while the terminal is printing.
  defp stream_phase(peer_ref) do
    case Peer.terminal_owner(peer_ref) do
      nil ->
        :gone

      pid ->
        case safely(fn -> Ampd.TerminalAttachment.state(pid, 1_000) end) do
          :unreachable -> :active
          phase -> phase
        end
    end
  end

  defp ask_resize(record, rows, cols) do
    case Ampd.Bridge.carrier_endpoint() do
      nil ->
        {:error,
         "no host carrier channel is possessed — refusing to resolve and execute the host by name instead"}

      %{sock: sock, incarnation: inc} ->
        body = %{
          "schema" => @resize_request,
          "op" => "pty-resize",
          "carrier_ref" => record["carrier_ref"],
          "carrier_epoch" => record["carrier_epoch"],
          "pty_epoch" => record["pty_epoch"],
          "attachment_epoch" => record["attachment_epoch"],
          "rows" => rows,
          "cols" => cols
        }

        EffectChannel.request(sock, inc, body, EffectChannel.deadline_ms(), @resize_observation)
    end
  end

  # ------------------------------------------------------------------ helpers
  defp mint(prefix), do: prefix <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

  defp refuse(code, detail) do
    Ampd.Refusal.new(code,
      component: "Ampd.Carrier.Terminal",
      retryable: code in ~w(terminal-already-attached terminal-carrier-replaced),
      requires_human: false,
      operator_detail:
        %{
          "ticket_id" => detail["ticket_id"],
          "peer_ref" => detail["peer_ref"],
          "carrier_ref" => detail["carrier_ref"],
          "attachment_ref" => detail["attachment_ref"],
          "reason" => detail["reason"],
          "status" => detail["status"],
          "held" => detail["held"],
          "current" => detail["current"]
        }
        |> Enum.reject(fn {_, v} -> v == nil end)
        |> Map.new()
    )
  end
end
