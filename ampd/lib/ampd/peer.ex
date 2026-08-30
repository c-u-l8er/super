defmodule Ampd.Peer do
  @moduledoc """
  `peer@1` — who is on the other end of a channel, decided by the runtime.

  ## The law

      Agent identity is assigned by the runtime, never claimed in a
      command payload.

  Until C1.1.1 the actor travelled *inside every command*: `preflight` and
  `request_effect` took a caller-supplied `ctx` carrying `actor`,
  `workspace`, and `run`. That was survivable only while nothing was
  networked — the moment a socket exists, a process could connect and say
  `actor = kestrel` and thereby exercise Kestrel's grants. The whole grant
  algebra is keyed on `ctx["actor"]`, so a caller-supplied actor is a
  caller-supplied authority.

  The fix is not to validate the claim. It is to **stop accepting one**.
  A peer is bound to an identity once, when its channel is created, and
  every command it later issues derives its context from that binding.
  A command payload has no `actor` field to lie in.

  ## Why binding at creation, and not `SO_PEERCRED`

  Every process here runs as the same OS user, so UID proves nothing. The
  obvious next reach is `SO_PEERCRED` — but its `pid` is a small integer
  that wraps, so a `pid → agent` table is racy by construction: the
  process you looked up may have exited and been replaced between the
  connect and the lookup. Linux 6.5 added `SO_PEERPIDFD` (glibc 2.39),
  which returns a pidfd that always refers to *one* process and closes
  that race.

  It still would not answer this question. A pidfd tells you *which*
  process, never *what* it is — turning a pid into "this is Kestrel"
  means a per-sandbox lookup that does not generalize. Flatpak, the
  Wayland compositors, and D-Bus all landed on the same answer instead:
  **hand each client its own socket with the identity already attached,
  and make that socket the only way in.** This module is that table. The
  Rust host will call `attach_agent/2` at the moment it spawns an engine
  and hands it the inherited channel — the binding happens where the
  process is created, which is the one place its identity is known.

  ## Not durable, on purpose

  A peer binding that survived a restart would be a connection that
  outlived its socket. Bindings die with the node; authority does not.

  ## The Carrier↔Worker attachment lives here — D.1.2

  A **Worker** is World-persistent and lives in `Ampd.Loci`. The fact that
  *this Carrier is currently fulfilling that Worker* is not: it is a
  property of a live channel, exactly like the identity binding beside it,
  and it must die when the channel does.

  So the attachment is a second map in this GenServer's state and it
  inherits, for free, every invalidation the bindings already have:

      detach/1                    the channel closed → attachment gone
      owner process death         `:DOWN` → `drop/2` → attachment gone
      reset/0                     new epoch → every attachment gone
      supervisor restart          fresh state → every attachment gone

  **That reuse is the WEK measurement.** D.1.2 could have introduced a
  `CarrierRegistry` — a supervised process holding occupancy, with its own
  lifecycle, its own crash semantics and its own way of being wrong about
  who is where. It would also have been a new privileged mechanism class
  for a fact that already has a home. Occupancy is Carrier-local, the
  Carrier is a peer binding, and a peer binding is this table.

  ## What this module decides about occupancy: almost nothing

  This module owns the *table* and the invariants a table can hold —
  at most one attachment per Carrier, at most one Carrier per Worker, and
  both checked inside the same `handle_call` so two racing attachments
  cannot both win.

  It does **not** decide whether an attachment is legitimate. Whether the
  Worker exists, is open, sits on the right Lane and is held by the right
  actor is `Ampd.Worker`'s question, and the answer is re-derived on every
  use rather than trusted from attach time. This module cannot answer it
  and should not try: the moment identity machinery starts ruling on
  product semantics, the two grow into each other and the channel layer
  becomes something you cannot reason about without the world.

  ## What is still unenforced

  Anything inside this BEAM can call `attach_agent/2`, because this module
  *is* the runtime and something has to be trusted to say who connected.
  What C1.1.1 removes is the per-command claim: the transport now has to
  be right in exactly one place — at attach — instead of on every message.
  `claim_control_channel/0` narrows it further: the human control channel
  can be claimed **once**, so an engine that starts after the host can
  never obtain one even by calling the same function.
  """
  use GenServer

  @schema "peer@1"

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    # Every incarnation gets a fresh epoch, and every handle carries it. A
    # supervisor restart therefore invalidates every outstanding handle by
    # construction — a handle minted before the crash cannot resolve
    # afterwards, even if the id space happened to collide.
    #
    # Fail-closed is the whole point: after a `Peer` crash the transport
    # has to close its channels and reattach, and the alternative — a stale
    # handle that still resolves — is an identity outliving the channel
    # that established it, which is the thing this module exists to
    # prevent one level down.
    {:ok,
     %{
       peers: %{},
       control_claimed: false,
       seq: 0,
       epoch: new_epoch(),
       owners: %{},
       # peer_id => carrier-attachment@1. Carrier-local by construction:
       # it is in this process's state and nothing writes it to disk.
       attachments: %{},
       # peer_id => carrier-incarnation@1 — the LIVE OS execution Carrier.
       #
       # **Two different objects share the word "Carrier" and this is the
       # seam.** `attachments` holds D.1.2's `carrier-attachment@1`, which is
       # a *peer/session* occupying a Locus. `carriers` holds D.1.3b's
       # execution process. An occupied Worker with no live process is
       # ordinary, not broken.
       #
       # Ephemeral for the same reason the attachments are, and it buys the
       # same four invalidations for free: `detach/1`, owner `:DOWN`,
       # `reset/0`, and supervisor restart. That is the whole of the
       # "losing the runtime incarnation terminates the Carrier" rule — it
       # is a consequence of where the map lives, not a policy anything has
       # to remember to apply.
       carriers: %{}
     }}
  end

  defp new_epoch, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  @doc "This incarnation's epoch. Every live handle carries it as a prefix."
  def epoch, do: GenServer.call(__MODULE__, :epoch)

  @doc """
  Bind a newly created channel to an agent identity. Returns an opaque
  peer handle; the handle is what a command is issued against.

  `opts[:engine]` records what kind of engine holds it, for the operator
  projection. It is a label, not a credential.
  """
  # The timeout is a parameter because it has to be *smaller* than the
  # deadline of whatever is waiting on the connection that calls this. Two
  # equal five-second deadlines is a race, and F.8.2.1 shipped one — see
  # `Ampd.Transport.Connection`.
  def attach_agent(actor, opts \\ [], timeout \\ 5_000) when is_binary(actor),
    do: GenServer.call(__MODULE__, {:attach, :agent, actor, opts}, timeout)

  @doc """
  Claim the human control channel. **At most one is active at a time.**

  The wording matters, and the earlier wording was wrong: this said
  "succeeds once", which reads as though reopening should be forbidden —
  while the product deliberately requires close-and-reopen to reach the
  same durable world, and that is one of C1.1's acceptance criteria. The
  invariant is about concurrency, not about a lifetime.

  The Rust host takes it at boot, before any agent engine exists. A second
  claim *while it is held* is refused by name, so "there is exactly one
  channel that may speak for the person, and it was established before
  anything else was running" is a mechanical property rather than a
  convention. Closing it releases it — see `Ampd.Bridge.channel_closed/1`
  for the two places that had to be taught to agree about when.
  """
  def claim_control_channel(opts \\ [], timeout \\ 5_000),
    do: GenServer.call(__MODULE__, {:claim_control, opts}, timeout)

  @doc "Resolve a handle to its `peer@1` record, or `nil`."
  def resolve(nil), do: nil
  def resolve(id), do: GenServer.call(__MODULE__, {:resolve, id})

  @doc "Drop a binding — its channel closed."
  def detach(id), do: GenServer.call(__MODULE__, {:detach, id})

  @doc "Every live binding, for the operator projection."
  def list, do: GenServer.call(__MODULE__, :list)

  # ------------------------------------------------- carrier attachment
  @attachment_schema "carrier-attachment@1"
  def attachment_schema, do: @attachment_schema

  @doc """
  Record that `peer_id` is now fulfilling a Worker.

  `binding` is the already-validated `carrier-attachment@1` body —
  `Ampd.Worker.attach/2` builds it and is the only sanctioned caller.
  This function adds the three fields only this process can know
  (`schema`, `peer_ref`, `peer_epoch`) and enforces the table invariants.

  `reap` is the list of peer ids whose attachment on the **same Locus** the
  caller has determined is no longer live. See below for why that list is
  computed elsewhere and why passing it is safe.

  Returns `{:ok, attachment}`, or `{:taken, :carrier}` / `{:taken, :worker}`
  / `{:taken, :locus}` so the caller can refuse by the right name. Returns
  `{:taken, :unknown_peer}` if the handle does not resolve in this
  incarnation.

  ## Exclusivity is on the Locus, and the first version got that wrong

  This checked for a conflicting `worker_ref`. Since more than one Worker
  may be open on one Lane, two Carriers could hold two Workers whose
  `locus_ref` was identical and **both satisfied occupancy for the same
  Lane at once** — the invariant the ontology claims, silently absent.

      Lane L
      ├── Worker W1  ←  Carrier C1
      └── Worker W2  ←  Carrier C2          both occupy L

  "One Carrier per Worker" and "one Carrier per Locus" are separate
  invariants, and only the second is the one being claimed: the position is
  the Lane, and the Worker is an assignment at it. `D2-10c` is the
  falsifier. The `worker_ref` case survives only to give the more specific
  refusal when the conflict really is the same assignment.

  ## A raw row is not a reservation

  The second half of the same defect: a *stale* attachment still reserved
  the position. A Carrier whose Worker had been closed had lost all
  authority — occupancy is re-derived — and kept **denial power**, because
  exclusivity was computed from table presence. It could block a
  replacement indefinitely by staying connected and declining to detach,
  which contradicts the one thing `close_worker` exists to guarantee: that
  a person can end an occupancy without the Carrier's cooperation.

      raw attachment row   ≠   live reservation

  So liveness decides, and liveness is `Ampd.Worker`'s question, not this
  module's — deciding it here would mean the channel layer reasoning about
  worlds and Workers. The caller computes which rows on the target Locus
  are stale and passes them as `reap`.

  **Why handing this process a caller-computed list is safe *under the
  sanctioned path*.** Staleness is *monotonic*: world lineage only
  advances, a peer epoch is never restored, a Worker's generation only
  advances, and closed→open advances it too. An attachment that has failed
  occupancy can therefore never satisfy it again, so a row that
  `Ampd.Worker.stale_on/1` reported is still stale when this process reads
  it. Reaping it cannot revoke a live occupancy. `D2-16` is the falsifier
  for the monotonicity itself.

  ## TRUSTED-BEAM PRECONDITION — this process does not check the witness

  The monotonicity argument is a property of `stale_on/1`'s **output**, not
  of this function's **input**. Stated exactly:

      Peer.attach_worker/3 assumes `reap` was produced by
      Ampd.Worker.stale_on/1. This process serializes the mutation but
      does not authenticate semantic staleness.

  Mechanically, a caller passing `reap = [live_peer]` both excludes that
  row from the conflict scan and drops it on admission, so it **does**
  displace a live occupant. That was measured by calling this function
  directly, bypassing `Ampd.Worker.attach/2`; the sanctioned path refused
  the same attach `locus-already-occupied`.

  This is a **trusted-BEAM seam, not an agent-channel authority path.**
  Worker code has no BEAM or process execution, no command in the grammar
  reaches this function with a caller-supplied list, and `Ampd.Peer` is
  already trusted runtime surface — the same surface that, as `attach/2`
  records, cannot defend identity attachment against arbitrary code already
  executing inside the BEAM. Closing it means having the owner of the
  reservation verify the witness independently rather than receive it,
  which is a design question for a later slice and not a patch to this one.

  It is recorded rather than absorbed because an unstated assumption in the
  trusted base is the thing that later gets quoted as a guarantee.

  **And the race still closes here.** Two Carriers attaching to two
  different Workers on one Lane both compute their reap lists before
  either arrives; neither list can name the other's row, because neither
  row existed yet. This process serializes, the first inserts, and the
  second finds a live conflict it may not reap. Exactly one wins.
  """
  def attach_worker(peer_id, binding, reap \\ [])
      when is_binary(peer_id) and is_map(binding) and is_list(reap),
      do: GenServer.call(__MODULE__, {:attach_worker, peer_id, binding, reap})

  @doc """
  The live attachment for `peer_id`, or `nil`.

  Returns `nil` for a handle from another incarnation even if the id
  somehow collides — the same epoch check `resolve/1` applies, for the same
  reason and deliberately redundant with the table being emptied on reset.
  """
  def attachment(nil), do: nil
  def attachment(peer_id), do: GenServer.call(__MODULE__, {:attachment, peer_id})

  @doc "Release the attachment `peer_id` holds. `:ok` either way — releasing nothing is not an error."
  def detach_worker(peer_id) when is_binary(peer_id),
    do: GenServer.call(__MODULE__, {:detach_worker, peer_id})

  @doc """
  Every live attachment, for the operator projection and for rendering
  `Worker · OCCUPIED`.

  This is what makes occupancy *visible to a person* rather than only
  enforceable. A position nobody can see the occupancy of is a position
  nobody can supervise.
  """
  def attachments, do: GenServer.call(__MODULE__, :attachments)

  @doc """
  Install the live execution Carrier for a peer. Exactly one per peer.

  Refuses rather than replaces: a second incarnation arriving for a peer that
  already has one means two admissions raced, and the survivable direction is
  for the second to be told so while the first keeps running.
  """
  def attach_carrier(peer_id, inc), do: GenServer.call(__MODULE__, {:attach_carrier, peer_id, inc})

  @doc "The live execution Carrier for a peer, or nil."
  def carrier(peer_id), do: GenServer.call(__MODULE__, {:carrier, peer_id})

  @doc "Every live execution Carrier in this incarnation."
  def carriers, do: GenServer.call(__MODULE__, :carriers)

  @doc "Drop the live execution Carrier. Does not stop the process."
  def detach_carrier(peer_id), do: GenServer.call(__MODULE__, {:detach_carrier, peer_id})

  @doc """
  Tear down every binding and free the control claim.

  This is a world-lifecycle operation, not a test hook: resetting or
  re-initializing a world invalidates every open channel, and a channel
  bound to a world that no longer exists is exactly the stale consent
  problem one layer down.
  """
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc """
  The context a peer's commands run under — **derived, never supplied.**

  `workspace` and `run` come from the session the runtime holds, and
  `actor` comes from the binding. The only thing the caller contributes is
  a placement *preference*, which is a request parameter: it can only ever
  narrow what the grant and the pack policy already allow, and
  `Ampd.Core.derive_placement/3` refuses it by name when it does not.
  """
  def authoritative_context(peer, request \\ nil)

  def authoritative_context(%{"actor" => actor}, request) do
    s = Ampd.Session.ctx()

    %{
      "actor" => actor,
      "workspace" => s["workspace"],
      "run" => s["run"],
      "placement" => (request || %{})["placement"]
    }
  end

  def authoritative_context(_, _), do: nil

  # ------------------------------------------------------------- server
  @impl true
  def handle_call(:epoch, _f, st), do: {:reply, st.epoch, st}

  def handle_call({:attach, kind, actor, opts}, {from, _} = _f, st) do
    if dead?(from) do
      {:reply, {:refused, owner_gone()}, st}
    else
      id = "pr-" <> st.epoch <> "-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

      peer = %{
        "schema" => @schema,
        "id" => id,
        "channel" => kind,
        "actor" => actor,
        "engine" => opts[:engine],
        "attached_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "seq" => st.seq,
        # **Captured here, at bind time, and this is the whole point.**
        # Sampling the current world when a command is submitted launders
        # an old-world command into the new one: a connection paused
        # between `resolve/1` and its authority call would read the world
        # that replaced its own. A channel belongs to the incarnation it
        # was bound in, for its whole life.
        "world_lineage" => Ampd.World.lineage()
      }

      touched()

      {:reply, {:ok, id},
       %{st | peers: Map.put(st.peers, id, peer), seq: st.seq + 1, owners: own(st.owners, from, id)}}
    end
  end

  def handle_call({:claim_control, opts}, _f, %{control_claimed: true} = st) do
    _ = opts

    {:reply,
     {:refused,
      Ampd.Refusal.new("control-channel-already-claimed",
        component: "Ampd.Peer",
        retryable: false,
        requires_human: true,
        public_message: "The human control channel is not available.",
        operator_detail: %{
          "hint" =>
            "the control channel is claimed once, by the host, before any engine starts — " <>
              "a second claim is a process trying to become the person"
        }
      )}, st}
  end

  def handle_call({:claim_control, opts}, {from, _} = _f, st) do
    if dead?(from), do: {:reply, {:refused, owner_gone()}, st}, else: claim(opts, from, st)
  end


  # A handle from another incarnation can never resolve, whatever the map
  # happens to contain. The epoch check is redundant with `peers` being
  # empty after a restart, and it is there so that stays true if the table
  # ever gains a persistence path by accident.
  def handle_call({:resolve, id}, _f, st) when is_binary(id) do
    if String.contains?(id, "-" <> st.epoch <> "-"),
      do: {:reply, Map.get(st.peers, id), st},
      else: {:reply, nil, st}
  end

  def handle_call({:resolve, _id}, _f, st), do: {:reply, nil, st}

  def handle_call({:detach, id}, _f, st) do
    touched()
    {:reply, :ok, drop(id, st)}
  end

  def handle_call(:list, _f, st), do: {:reply, Map.values(st.peers), st}

  def handle_call({:attach_worker, peer_id, binding, reap}, _f, st) do
    # The conflict is any *other* row on the same Locus that the caller did
    # not establish is stale.
    #
    # **`reap` is a trusted witness and this process does not check it.**
    # Naming a live row here both hides it from this scan and drops it on
    # the admission below, so an in-BEAM caller bypassing
    # `Ampd.Worker.attach/2` displaces a live occupant. This comment
    # previously claimed the subtraction order prevented that; it does not,
    # and a direct call measured the displacement. The precondition is
    # documented at `attach_worker/3` and carried in the TCB ledger rather
    # than enforced here — see there for why enforcing it is a design
    # question and not a patch.
    conflict =
      Enum.find_value(st.attachments, fn {pid, a} ->
        if pid != peer_id and a["locus_ref"] == binding["locus_ref"] and pid not in reap,
          do: a
      end)

    cond do
      # A handle that does not resolve cannot occupy anything. Checked
      # here rather than trusted from the caller, because this is the
      # process that knows what resolving means.
      Map.get(st.peers, peer_id) == nil or not String.contains?(peer_id, "-" <> st.epoch <> "-") ->
        {:reply, {:taken, :unknown_peer}, st}

      Map.has_key?(st.attachments, peer_id) ->
        {:reply, {:taken, :carrier}, st}

      # Same position, and the more specific answer when it is also the
      # same assignment.
      conflict != nil ->
        {:reply,
         {:taken, if(conflict["worker_ref"] == binding["worker_ref"], do: :worker, else: :locus)},
         st}

      true ->
        att =
          Map.merge(binding, %{
            "schema" => @attachment_schema,
            "peer_ref" => peer_id,
            "peer_epoch" => st.epoch,
            "attached_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          })

        touched()

        # Reaped only on admission. A refused attach mutates nothing, so a
        # Carrier cannot use a failing attach to clear rows it dislikes.
        {:reply, {:ok, att},
         %{st | attachments: st.attachments |> Map.drop(reap) |> Map.put(peer_id, att)}}
    end
  end

  def handle_call({:attachment, peer_id}, _f, st) when is_binary(peer_id) do
    if String.contains?(peer_id, "-" <> st.epoch <> "-"),
      do: {:reply, Map.get(st.attachments, peer_id), st},
      else: {:reply, nil, st}
  end

  def handle_call({:attachment, _peer_id}, _f, st), do: {:reply, nil, st}

  def handle_call({:detach_worker, peer_id}, _f, st) do
    if Map.has_key?(st.attachments, peer_id), do: touched()
    {:reply, :ok, %{st | attachments: Map.delete(st.attachments, peer_id)}}
  end

  def handle_call(:attachments, _f, st), do: {:reply, Map.values(st.attachments), st}

  def handle_call({:attach_carrier, peer_id, inc}, _f, st) do
    cond do
      # A handle that does not resolve in this epoch cannot carry anything,
      # for the same reason it cannot occupy anything.
      Map.get(st.peers, peer_id) == nil or not String.contains?(peer_id, "-" <> st.epoch <> "-") ->
        {:reply, {:taken, :unknown_peer}, st}

      Map.has_key?(st.carriers, peer_id) ->
        {:reply, {:taken, :carrier_live}, st}

      # No occupancy, no execution. The position is what a Carrier embodies,
      # so a Carrier without one would be a process fulfilling nothing.
      not Map.has_key?(st.attachments, peer_id) ->
        {:reply, {:taken, :not_attached}, st}

      true ->
        touched()
        {:reply, {:ok, inc}, %{st | carriers: Map.put(st.carriers, peer_id, inc)}}
    end
  end

  def handle_call({:carrier, peer_id}, _f, st) when is_binary(peer_id) do
    if String.contains?(peer_id, "-" <> st.epoch <> "-"),
      do: {:reply, Map.get(st.carriers, peer_id), st},
      else: {:reply, nil, st}
  end

  def handle_call({:carrier, _}, _f, st), do: {:reply, nil, st}

  def handle_call(:carriers, _f, st), do: {:reply, Map.values(st.carriers), st}

  def handle_call({:detach_carrier, peer_id}, _f, st) do
    if Map.has_key?(st.carriers, peer_id), do: touched()
    {:reply, :ok, %{st | carriers: Map.delete(st.carriers, peer_id)}}
  end

  # A new epoch too: a world reset invalidates every channel, and a handle
  # from before it must not resolve into the world that replaced it.
  def handle_call(:reset, _f, st) do
    touched()
    Enum.each(Map.keys(st.owners), &Process.demonitor(&1, [:flush]))

    {:reply, :ok,
     %{
       st
       | peers: %{},
         control_claimed: false,
         epoch: new_epoch(),
         owners: %{},
         # Carrier death takes occupancy with it. The Worker and the Lane
         # are untouched — they are in dets and this process has never
         # been able to reach them.
         attachments: %{},
         carriers: %{}
     }}
  end

  # **An identity exists only while the process that asked for it does.**
  #
  # `GenServer.call`'s timeout is the *client's*, not the server's: a call
  # that times out is still sitting in this mailbox, and this process will
  # perform it whenever it gets there. Measured — `Ampd.Peer` suspended
  # past the connection's deadline, the host told `channel-bind-failed`,
  # and then a live `kestrel` binding appearing the moment the suspension
  # lifted. **The runtime committed an identity the host had been told did
  # not exist**, which is worse than any descriptor leak: the host and the
  # world disagree about who is in it.
  #
  # Two halves, and both are needed. A caller already gone gets nothing, so
  # a late call cannot commit; and a caller that dies later takes its
  # identity with it, so nothing has to remember to clean up. The
  # supervision-restart rule this module was built on — a handle cannot
  # outlive the incarnation that minted it — now holds one level down: a
  # handle cannot outlive the *connection* that claimed it.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, st) do
    case Map.pop(st.owners, ref) do
      {nil, _} -> {:noreply, st}
      {id, rest} -> touched(); {:noreply, drop(id, %{st | owners: rest})}
    end
  end

  def handle_info(_msg, st), do: {:noreply, st}

  defp claim(opts, from, st) do
    id = "pc-" <> st.epoch <> "-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

    peer = %{
      "schema" => @schema,
      "id" => id,
      "channel" => :human_control,
      # The person is not an actor: they hold no grants and exercise no
      # capabilities. They are the only source of consent.
      "actor" => nil,
      "engine" => opts[:engine] || "host",
      "attached_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "seq" => st.seq,
      "world_lineage" => Ampd.World.lineage()
    }

    touched()

    {:reply, {:ok, id},
     %{st | peers: Map.put(st.peers, id, peer), control_claimed: true, seq: st.seq + 1,
            owners: own(st.owners, from, id)}}
  end

  # **`peers` is in the operator projection, and nothing here is an
  # authority mutation.** A binding appearing or disappearing changes what
  # the cockpit shows and moves no authority, which is exactly the case
  # `Ampd.AuthorityCoordinator`'s second clock exists for.
  defp touched, do: Ampd.AuthorityCoordinator.touched()

  defp own(owners, pid, id), do: Map.put(owners, Process.monitor(pid), id)

  defp dead?(pid), do: is_pid(pid) and not Process.alive?(pid)

  # Closing the control channel frees the claim — the host may restart and
  # take it again. Nothing else can, while it is held.
  defp drop(id, st) do
    freed = match?(%{"channel" => :human_control}, Map.get(st.peers, id))

    owners =
      case Enum.find(st.owners, fn {_ref, held} -> held == id end) do
        {ref, _} -> Process.demonitor(ref, [:flush]) && Map.delete(st.owners, ref)
        nil -> st.owners
      end

    # The attachment goes with the binding, in the one place every way of
    # losing a channel already converges — `detach/1` and the `:DOWN`
    # handler both arrive here. Releasing it at the call sites instead
    # would mean a Carrier whose process died silently kept occupying a
    # position no live channel could vacate.
    %{st | peers: Map.delete(st.peers, id),
           control_claimed: st.control_claimed and not freed,
           owners: owners,
           attachments: Map.delete(st.attachments, id),
           # The execution Carrier goes with the session that admitted it.
           # Dropping it here — the one place every way of losing a channel
           # converges — is what makes "losing the runtime incarnation
           # terminates the Carrier" true by construction rather than by
           # remembering to call something.
           carriers: Map.delete(st.carriers, id)}
  end

  defp owner_gone do
    Ampd.Refusal.new("channel-owner-gone",
      component: "Ampd.Peer",
      retryable: true,
      requires_human: false,
      public_message: "The runtime could not bind that channel.",
      operator_detail: %{
        "reason" =>
          "the connection that asked for this identity was gone before the binding was made — " <>
            "a call that times out is still in this mailbox, and committing it would name a " <>
            "channel nobody is holding"
      }
    )
  end
end
