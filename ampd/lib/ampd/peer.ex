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
    {:ok, %{peers: %{}, control_claimed: false, seq: 0, epoch: new_epoch(), owners: %{}}}
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

  # A new epoch too: a world reset invalidates every channel, and a handle
  # from before it must not resolve into the world that replaced it.
  def handle_call(:reset, _f, st) do
    touched()
    Enum.each(Map.keys(st.owners), &Process.demonitor(&1, [:flush]))
    {:reply, :ok, %{st | peers: %{}, control_claimed: false, epoch: new_epoch(), owners: %{}}}
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

    %{st | peers: Map.delete(st.peers, id),
           control_claimed: st.control_claimed and not freed,
           owners: owners}
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
