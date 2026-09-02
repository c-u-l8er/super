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
       # monitor_ref => {peer_id, owner_pid}.
       #
       # **The pid used to be discarded here and that made one question
       # unanswerable.** `own/3` passed it to `Process.monitor/1` and kept
       # only the reference, so the runtime monitored the process that
       # established each binding without ever being able to *name* it. That
       # is enough to drop a binding when its owner dies and not enough to
       # answer "which process currently owns this peer_ref?" — which is
       # exactly what an ACTIVE terminal attachment has to bind its lifetime
       # to. Storing the pid alongside the id makes `owner_pid/1` a lookup
       # instead of an inference from the call path.
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
       carriers: %{},
       # carrier_ref => carrier-incarnation@1, for Carriers whose membership
       # has ended and whose *process* has not yet been established absent.
       #
       # ## The race this closes
       #
       # Every announcement to `Ampd.Carrier.Reaper` was guarded by
       # `if Process.whereis(Reaper)`, which is correct — a crash must not
       # mask a probe — and silently lossy:
       #
       #     Reaper crashes
       #         ↓
       #     before the supervisor restarts it
       #         ↓
       #     a Peer loses its Carrier
       #         ↓
       #     membership removed, announcement dropped on the floor
       #         ↓
       #     a live OS process with nothing in the runtime referring to it
       #
       # A restarted Reaper could not converge it either, because
       # `Ampd.Carrier.converge/1` re-derives victims from `carriers` and the
       # incarnation has already left that map. Removal is immediate by
       # design and must stay immediate, so the thing that has to survive the
       # gap is a *separate* record of the debt.
       #
       # **It lives here rather than in the Reaper for one structural reason**:
       # `Ampd.Peer` is started before `Ampd.Carrier.Reaper` under a
       # `:one_for_one` supervisor, so a Reaper restart cannot take this with
       # it. It is still ephemeral — losing `Ampd.Peer` loses every
       # incarnation anyway, which is the existing "no survival across a
       # control-plane restart" rule and not a new hole.
       #
       # **Deliberately not durable.** A disk-backed pending-reap queue would
       # be a second recovery protocol with its own boot sweep and its own
       # ambiguity, built on the strength of a race nothing has yet observed
       # in the wild. `E27` is the falsifier; if it ever proves insufficient,
       # build the queue then.
       pending_reaps: %{},
       # peer_id => %{record: terminal-attachment@1, pid: owner, ref: monitor}
       #
       # **The semantic relation, and the ephemeral machinery that carries
       # it, in one entry rather than two maps.** The published object is
       # `record` alone — `terminal_attachment/1` projects it out and nothing
       # else escapes. The pid and the monitor reference are how this process
       # knows the stream still has an owner; they are not part of what a
       # Peer possesses, and a semantic record carrying a pid would be a
       # World fact that changes when the BEAM reschedules.
       #
       # Two maps would have been the obvious shape and it is the shape that
       # desynchronises: the record and its monitor must appear and disappear
       # together, and the only structural way to guarantee that is for them
       # to be the same entry.
       #
       # Ephemeral, like everything else here, and deliberately so — see
       # `Ampd.Carrier.Terminal` for why a terminal attachment needs no
       # durable attempt ledger while a Carrier start does.
       terminals: %{}
     }}
  end

  # **128 bits, and the width is load-bearing since D.1.3b·2d.**
  #
  # This was four bytes for as long as the epoch only prefixed a handle: a
  # freshness token, where a collision costs one stale handle resolving that
  # should not have. `Ampd.Carrier.Machine.Gate` and the Rust host then made
  # it the fence between *physical Carrier universes* — the value on which
  # "an old physical set must be drained before a replacement incarnation may
  # execute" depends — and thirty-two random bits is not a scale on which to
  # rest an absolute lifetime claim. It now matches the discipline
  # `Ampd.Worktree.EffectChannel.new_epoch/0` and `carrier_epoch` already
  # use.
  #
  # **The width is the second line, not the first.** The Gate drains on a
  # *witnessed* discontinuity regardless of what the replacement mints, so a
  # collision cannot by itself defeat the fence; see `converge/1` there. What
  # 128 bits buys is the residue that has no witness — a Gate that restarted
  # across the transition and has only the published term to compare.
  defp new_epoch, do: mint_epoch()

  if Mix.env() == :test do
    # **Test-controlled minting, compiled out of every other environment.**
    #
    # The fence's invariant is "a witnessed discontinuity drains regardless
    # of the token", and the only way to falsify that on purpose is to make
    # the replacement mint the value that died. 128 bits will not collide on
    # request, and a falsifier that waits for one is not a falsifier. See
    # `E30` in `test/carrier_test.exs`.
    #
    # **A door that forges runtime identity, so prose is not its gate.**
    # `Mix.env()` is evaluated at compile time, so outside `:test` the clause
    # below is the whole function and the atom is not in the module at all —
    # `tools/check-epoch-mint.sh` measures that in the built BEAM rather than
    # reading this comment, and measures the `:test` build too, because a
    # check that would pass against a module with no door is not a check.
    defp mint_epoch do
      case :persistent_term.get({__MODULE__, :forced_epoch}, nil) do
        nil -> :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
        forced when is_binary(forced) -> forced
      end
    end
  else
    defp mint_epoch, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

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
  End a Carrier's membership **and** record that its process is owed a reap,
  in one call.

  For every path that ends membership because the admitting relationship
  died — as opposed to `Ampd.Carrier.stop/1`, which ends it because somebody
  asked and does its own terminating. Two separate calls would leave a window
  in which the caller could die between them, having removed the only
  reference to a running process; this is one message to one process, so
  there is no window.
  """
  def detach_carrier_pending(peer_id),
    do: GenServer.call(__MODULE__, {:detach_carrier_pending, peer_id})

  @doc "Carriers whose membership has ended and whose process is not yet established absent."
  def pending_reaps, do: GenServer.call(__MODULE__, :pending_reaps)

  @doc """
  The reap of this Carrier has been settled — confirmed, or recorded as
  unconfirmed against the Worker. Either way the debt is discharged and a
  later sweep must not act on it again.
  """
  def reap_settled(carrier_ref), do: GenServer.call(__MODULE__, {:reap_settled, carrier_ref})

  # ------------------------------------------------------- terminal possession
  @terminal_schema "terminal-attachment@1"

  @doc "The schema of the semantic terminal relation this module holds."
  def terminal_schema, do: @terminal_schema

  @doc """
  Which process currently owns `peer_id`'s binding, or `nil`.

  **The one thing an ACTIVE terminal attachment may bind its lifetime to.**

  It is emphatically *not* `Process.whereis(Ampd.Peer)`. This module is a
  singleton registry: it holds every binding and outlives all of them, so an
  attachment monitoring it would survive the death of the very connection
  that established the Peer it belongs to —

      transport connection for peer P dies
          → Ampd.Peer drops P
          → Ampd.Peer itself is still alive
          → an attachment monitoring Ampd.Peer does NOT close

  — which is a stream owned on behalf of a peer that no longer exists. The
  binding's owner is the process that called `attach_agent/3` or
  `claim_control_channel/2`, which today is an `Ampd.Transport.Connection`.
  Nothing here depends on it being that: this returns whichever process the
  binding was actually established by, and the commit re-reads it rather than
  assuming the caller happens to be it.
  """
  def owner_pid(nil), do: nil
  def owner_pid(peer_id) when is_binary(peer_id), do: GenServer.call(__MODULE__, {:owner_pid, peer_id})

  @doc """
  The `terminal-attachment@1` a peer possesses, or `nil`.

  The record only. No pid, no descriptor, no `/dev/pts` path — those are how
  the runtime carries the relation, not what the relation is.
  """
  def terminal_attachment(nil), do: nil

  def terminal_attachment(peer_id) when is_binary(peer_id),
    do: GenServer.call(__MODULE__, {:terminal_attachment, peer_id})

  @doc "Every semantic terminal relation in this incarnation, as `peer_id => record`."
  def terminal_attachments, do: GenServer.call(__MODULE__, :terminal_attachments)

  @doc """
  Install a `COMMITTING` terminal relation and start watching its stream owner.

  Refuses rather than replaces, the same way `attach_carrier/2` does and for
  the same reason: a second attachment arriving for a peer that already has
  one means two commits raced, and the survivable direction is for the second
  to be told so.

  **`COMMITTING` is not possession.** Nothing may read, write or resize
  through it. It exists so that the interval between installing the record and
  finalising it is a state the World can name, rather than a gap in which a
  half-built attachment is indistinguishable from a real one.
  """
  def install_terminal(peer_id, record, pid)
      when is_binary(peer_id) and is_map(record) and is_pid(pid),
      do: GenServer.call(__MODULE__, {:install_terminal, peer_id, record, pid})

  @doc """
  `COMMITTING` → `ACTIVE`, addressed by the exact attachment identity.

  Refused if the current record is a different attachment, is already ACTIVE,
  or is absent. The identity is required rather than implied so that a commit
  cannot finalise whatever happens to be in the slot — which is the same rule
  `Ampd.TerminalAttachment` applies to its own five physical fields, one layer
  up.
  """
  def activate_terminal(peer_id, attachment_ref, attachment_epoch)
      when is_binary(peer_id) and is_binary(attachment_ref) and is_binary(attachment_epoch),
      do: GenServer.call(__MODULE__, {:activate_terminal, peer_id, attachment_ref, attachment_epoch})

  @doc """
  End a peer's terminal relation and converge its stream. `:ok` either way.

  For a refused commit and for a voluntary release. Carrier loss does not go
  through here — it goes through the Carrier-removal funnel, because the
  terminal relation is subordinate to the Carrier relation rather than being
  a peer of it.
  """
  def remove_terminal(peer_id) when is_binary(peer_id),
    do: GenServer.call(__MODULE__, {:remove_terminal, peer_id})

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
    {:reply, :ok, release_carrier(st, peer_id)}
  end

  def handle_call({:detach_carrier_pending, peer_id}, _f, st) do
    case Map.get(st.carriers, peer_id) do
      nil ->
        {:reply, {:ok, nil}, st}

      inc ->
        touched()
        {:reply, {:ok, inc}, pend(release_carrier(st, peer_id), inc)}
    end
  end

  def handle_call(:pending_reaps, _f, st), do: {:reply, Map.values(st.pending_reaps), st}

  def handle_call({:reap_settled, ref}, _f, st),
    do: {:reply, :ok, %{st | pending_reaps: Map.delete(st.pending_reaps, ref)}}

  # ------------------------------------------------------- terminal possession
  def handle_call({:owner_pid, peer_id}, _f, st) do
    pid =
      case Enum.find(st.owners, fn {_ref, {held, _pid}} -> held == peer_id end) do
        {_ref, {_id, pid}} -> pid
        nil -> nil
      end

    {:reply, pid, st}
  end

  def handle_call({:terminal_attachment, peer_id}, _f, st),
    do: {:reply, st.terminals[peer_id] && st.terminals[peer_id].record, st}

  def handle_call(:terminal_attachments, _f, st),
    do: {:reply, Map.new(st.terminals, fn {id, t} -> {id, t.record} end), st}

  def handle_call({:install_terminal, peer_id, record, pid}, _f, st) do
    cond do
      not Map.has_key?(st.peers, peer_id) ->
        {:reply, {:refused, :peer_gone}, st}

      Map.has_key?(st.terminals, peer_id) ->
        {:reply, {:refused, :terminal_live}, st}

      not Process.alive?(pid) ->
        {:reply, {:refused, :owner_gone}, st}

      true ->
        touched()
        rec = Map.put(record, "status", "COMMITTING")
        ref = Process.monitor(pid)
        {:reply, {:ok, rec}, %{st | terminals: Map.put(st.terminals, peer_id, %{record: rec, pid: pid, ref: ref})}}
    end
  end

  def handle_call({:activate_terminal, peer_id, aref, aepoch}, _f, st) do
    t = Map.get(st.terminals, peer_id)
    r = t && t.record

    cond do
      t == nil ->
        {:reply, {:refused, :no_terminal}, st}

      # Exactly once. A second finalisation of the same record would be a
      # commit deciding again about something already decided, and the only
      # way to reach it is a caller that has lost track of which transaction
      # it is in.
      r["status"] == "ACTIVE" ->
        {:reply, {:refused, :already_active}, st}

      r["attachment_ref"] != aref or r["attachment_epoch"] != aepoch ->
        {:reply, {:refused, {:identity_mismatch, r["attachment_ref"]}}, st}

      true ->
        touched()
        rec = Map.put(r, "status", "ACTIVE")
        {:reply, {:ok, rec}, %{st | terminals: Map.put(st.terminals, peer_id, %{t | record: rec})}}
    end
  end

  def handle_call({:remove_terminal, peer_id}, _f, st) do
    if Map.has_key?(st.terminals, peer_id), do: touched()
    {:reply, :ok, release_terminal(st, peer_id)}
  end

  # A new epoch too: a world reset invalidates every channel, and a handle
  # from before it must not resolve into the world that replaced it.
  def handle_call(:reset, _f, st) do
    touched()
    Enum.each(Map.keys(st.owners), &Process.demonitor(&1, [:flush]))

    # Every Carrier relation ends here, so every terminal relation does too.
    # The owners are killed rather than asked: this runs inside the `Ampd.Peer`
    # GenServer and a reset must not wait on anything.
    Enum.each(Map.keys(st.terminals), fn id -> kill_terminal(st, id) end)

    # **Announced before they are dropped, not silently cleared.** `reset/0`
    # emptied this map and told nobody, so the invariant it claims — losing
    # the runtime incarnation terminates the Carrier — held only when some
    # higher caller happened to close the Bridge first. An invariant that
    # depends on a caller remembering a second teardown is not an invariant.
    #
    # A cast, from inside this GenServer, to a different process: nothing
    # about resetting identity may wait on a machine deadline.
    #
    # Recorded first, and for the same reason as `announce_orphan/2`: a world
    # reset does not make a running process stop existing, so if the Reaper is
    # not up to hear this, the debt has to be somewhere a restarted one can
    # find it.
    pending = Enum.reduce(Map.values(st.carriers), st.pending_reaps, &Map.put(&2, &1["carrier_ref"], &1))

    if Process.whereis(Ampd.Carrier.Reaper) do
      for {_id, inc} <- st.carriers, do: Ampd.Carrier.Reaper.orphaned(inc)
    end

    # **A fresh epoch is an incarnation change even though nothing died.**
    # `Ampd.Carrier.Machine.Gate` watches this process with a monitor, and a
    # monitor cannot see a registry that re-mints its identity in place — so
    # the Gate would stay bound to an epoch no handle carries and refuse every
    # admission until something else nudged it. A cast, for the same reason as
    # the orphan announcements above.
    if Process.whereis(Ampd.Carrier.Machine.Gate) do
      Ampd.Carrier.Machine.Gate.peer_incarnation_changed()
    end

    {:reply, :ok,
     %{
       st
       # **Deliberately survives the reset.** Everything else here is identity
       # and identity is what a reset invalidates; a pending reap is a fact
       # about the OS, and the OS did not attend the reset.
       | pending_reaps: pending,
         peers: %{},
         control_claimed: false,
         epoch: new_epoch(),
         owners: %{},
         # Carrier death takes occupancy with it. The Worker and the Lane
         # are untouched — they are in dets and this process has never
         # been able to reach them.
         attachments: %{},
         carriers: %{},
         terminals: %{}
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
      {{id, _pid}, rest} ->
        touched()
        {:noreply, drop(id, %{st | owners: rest})}

      # **The reverse direction of the terminal dependency, and it has to be
      # a monitor.** `Ampd.TerminalAttachment` monitors the process whose
      # life an ACTIVE attachment is bound to; this is the other way round —
      # the stream owner dying must remove the semantic record, or a World
      # that says a Peer possesses a terminal outlives the process that
      # owned the terminal's only descriptor.
      #
      # `terminate/2` cannot carry this. A `:kill` skips it, and `:kill` is
      # precisely the case a record must not survive.
      {nil, _} ->
        case Enum.find(st.terminals, fn {_id, t} -> t.ref == ref end) do
          nil ->
            {:noreply, st}

          {id, _} ->
            touched()
            {:noreply, %{st | terminals: Map.delete(st.terminals, id)}}
        end
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

  defp own(owners, pid, id), do: Map.put(owners, Process.monitor(pid), {id, pid})

  defp dead?(pid), do: is_pid(pid) and not Process.alive?(pid)

  # ------------------------------------------------- the carrier-removal funnel
  #
  # **This funnel did not exist and had to be built.** Four independent sites
  # wrote `st.carriers` on removal — `detach_carrier`, `detach_carrier_pending`,
  # `drop/2` and `reset/0` — and only the last two shared any code. `drop/2`'s
  # comment says it is "the one place every way of losing a channel already
  # converges", which is true and is a narrower claim than it reads as: losing
  # a *channel* converges there, losing a *Carrier* does not.
  #
  # That was survivable while the only thing subordinate to Carrier membership
  # was the membership itself. It stops being survivable the moment a terminal
  # attachment hangs off it, because then "the Carrier relation ended" has a
  # consequence, and a consequence scattered across four callers is a
  # consequence three of them can forget.
  #
  # So: one place a Peer stops having a current execution Carrier, and the
  # terminal relation ends there because it is subordinate to it — not because
  # each caller remembered.
  defp release_carrier(st, peer_id) do
    %{st | carriers: Map.delete(st.carriers, peer_id)}
    |> release_terminal(peer_id)
  end

  # Remove the semantic record, stop watching the stream owner, and end it.
  #
  # The kill is what converges the physical side. `Ampd.TerminalAttachment`
  # owns its socket, and a `:socket` dies with its owner immediately — measured
  # on OTP 28.2 — so the descriptor is gone when this returns even though
  # `terminate/2` never runs. Asking politely would mean a `GenServer.stop`
  # from inside this process, which is a synchronous wait on another process
  # in the middle of a disconnect.
  defp release_terminal(st, peer_id) do
    case Map.get(st.terminals, peer_id) do
      nil ->
        st

      t ->
        Process.demonitor(t.ref, [:flush])
        Process.exit(t.pid, :kill)
        %{st | terminals: Map.delete(st.terminals, peer_id)}
    end
  end

  defp kill_terminal(st, peer_id) do
    case Map.get(st.terminals, peer_id) do
      nil -> :ok
      t -> Process.demonitor(t.ref, [:flush]); Process.exit(t.pid, :kill); :ok
    end
  end

  # Closing the control channel frees the claim — the host may restart and
  # take it again. Nothing else can, while it is held.
  defp drop(id, st) do
    freed = match?(%{"channel" => :human_control}, Map.get(st.peers, id))

    owners =
      case Enum.find(st.owners, fn {_ref, {held, _pid}} -> held == id end) do
        {ref, _} -> Process.demonitor(ref, [:flush]) && Map.delete(st.owners, ref)
        nil -> st.owners
      end

    inc = Map.get(st.carriers, id)

    # The attachment goes with the binding, in the one place every way of
    # losing a channel already converges — `detach/1` and the `:DOWN`
    # handler both arrive here. Releasing it at the call sites instead
    # would mean a Carrier whose process died silently kept occupying a
    # position no live channel could vacate.
    %{st | peers: Map.delete(st.peers, id),
           control_claimed: st.control_claimed and not freed,
           owners: owners,
           attachments: Map.delete(st.attachments, id),
           # The execution Carrier's *membership* goes with the session that
           # admitted it. Dropping it here — the one place every way of losing
           # a channel converges — is what makes that true by construction.
           #
           # **Membership ending is not the process ending, and the source
           # used to claim it was.** Review caught it: the host's
           # `serve_carrier` map still held the child, so the OS process kept
           # running with nothing in the runtime referring to it. `orphaned/1`
           # hands the incarnation to whoever will do the reaping.
           #
           # It is announced rather than performed. This function runs inside
           # the `Ampd.Peer` GenServer and on the `:DOWN` path; submitting a
           # machine request from here would put an 8-second timeout in front
           # of every disconnect.
           carriers: Map.delete(st.carriers, id)}
    # The terminal relation is subordinate to the Carrier relation, and this
    # is one of the four places the Carrier relation ends. It is released
    # unconditionally rather than through `release_carrier/2`, because here
    # the *binding* is going too: a terminal attachment held by a peer that
    # no longer exists is not merely stale, it is unaddressable.
    |> release_terminal(id)
    |> announce_orphan(inc)
  end

  # Cast, not call: nothing about a channel closing should wait for a
  # process to die. `Ampd.Carrier.Reaper` owns the retry and the ambiguity.
  #
  # **Recorded before it is announced**, because the announcement can be lost
  # and the debt cannot be allowed to go with it — see `pending_reaps` in
  # `init/1`. The order matters: pending first, then the cast. Announcing
  # first would leave an interval in which a Reaper that answered immediately
  # settled a debt that had not been written yet, and the entry would outlive
  # the reap it describes.
  defp announce_orphan(st, nil), do: st

  defp announce_orphan(st, inc) do
    st = pend(st, inc)
    if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.orphaned(inc)
    st
  end

  defp pend(st, %{"carrier_ref" => ref} = inc) when is_binary(ref),
    do: %{st | pending_reaps: Map.put(st.pending_reaps, ref, inc)}

  defp pend(st, _), do: st

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
