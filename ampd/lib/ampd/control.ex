defmodule Ampd.Control do
  @moduledoc """
  The command surface, and the two laws that decide what a command means.

      Connection determines actor; payload never does.
      Grant request ≠ human grant draft.

  Every process on this machine runs as the same OS user: the Super UI,
  Claude Code, Codex, plugins, shells. "Same UID" proves nothing, and a
  single local socket cannot tell *the human* from *an agent the human is
  supervising*. So a command is issued **against a peer handle**, and the
  peer's binding — assigned by the runtime when its channel was created,
  see `Ampd.Peer` — decides both which commands it may issue and whose
  authority it is asking about.

      AGENT CHANNEL              HUMAN CONTROL CHANNEL
      ─────────────              ─────────────────────
      agent_projection           operator_projection
      preflight (advisory)       approve_effect
      request_effect             deny_effect
      request_grant              approve_grant_request
                                 deny_grant_request
                                 revoke_grant
                                 recovery_status

      either channel:                  inspect_refusal
      no identity at all:              runtime_status

  `inspect_refusal` is open to both on purpose: it is the dual projection
  checked from the other direction. The agent that received a `code` and a
  `public_message` can come back with the correlation id and *still* not
  learn the topology; the operator pastes the same id and sees everything.
  One stored object, two answers, provable twice.

  An agent may *ask* for anything — `request_effect` opens a proposal and
  parks it on consent, `request_grant` opens a `grant-request@1` and parks
  it on a person. It may never *give* consent, and it may never write into
  the editor where the person composes one.

  `preflight` is agent-only because it needs an actor and the person is
  not one: they hold no grants and exercise no capabilities. The control
  room renders eligibility from the operator projection instead.

  ## What C1.1.1 changed, and what it did not

  Until now the actor travelled *inside* the command — `preflight` and
  `request_effect` took a caller-supplied `ctx` — and the channel was a
  bare atom the caller also supplied. Both are gone: the context is
  derived from the binding, and there is no `origin` argument to assert.

  What remains unenforced is the binding itself. Anything inside this
  BEAM can call `Ampd.Peer.attach_agent/2`, because something has to be
  trusted to say who connected, and until the Rust host exists that
  something is any caller. The difference is where the trust has to hold:
  **once, at attach, instead of on every message.** That is the shape a
  transport can actually secure, and it is why this is C1.1's last
  interface change rather than another deferral.
  """
  alias Ampd.{Authority, Approvals, Gateway, Peer, Projection, Refusal}

  # **Derived, not declared here.** These used to be four hand-written
  # lists, and `Ampd.Wire` built its vocabulary from them — two maintained
  # sources for one fact, where a command added to one and forgotten in the
  # other was either unreachable or unchecked. `Ampd.CommandSpec` is the
  # single declaration; reading it at compile time makes the dependency
  # real, so the drift axis is gone rather than tested for.
  @agent Ampd.CommandSpec.exclusive_to(:agent)
  @human Ampd.CommandSpec.exclusive_to(:human_control)
  @both Ampd.CommandSpec.exclusive_to(:both)
  @open Ampd.CommandSpec.exclusive_to(:open)

  # Which commands may be assembled under the continuity seqlock. Declared
  # in `Ampd.CommandSpec` beside the command, for the same reason the
  # channel classes are: a second maintained list here is a list that
  # eventually disagrees, and this one would disagree in the direction of
  # serving a projection whose cursor does not describe it.
  @reads Ampd.CommandSpec.reads()
  @retry_once Ampd.CommandSpec.retry_once()

  def agent_commands, do: @agent ++ @both
  def human_commands, do: @human ++ @both
  def open_commands, do: @open

  @doc """
  Issue `cmd` against the channel bound to `peer_id`.

  `runtime_status` is answered before the peer is resolved: a caller with
  no binding still deserves to learn whether this runtime is healthy,
  sealed, or not answering, and nothing in that answer is anyone's
  authority.
  """
  def command(peer_id, cmd, args \\ [])

  def command(_peer_id, :runtime_status, _args), do: Projection.runtime_status()

  def command(peer_id, cmd, args) do
    case Peer.resolve(peer_id) do
      nil ->
        Refusal.project_result(
          %{"allow" => false, "refusal" => unknown_peer_refusal(cmd)},
          :general
        )

      peer ->
        channel = peer["channel"]

        cond do
          cmd in @human and channel != :human_control ->
            project(%{"allow" => false, "refusal" => impersonation_refusal(cmd)}, channel)

          cmd in @agent and channel != :agent ->
            project(
              %{"allow" => false, "refusal" => wrong_channel_refusal(cmd, channel)},
              channel
            )

          cmd not in @human and cmd not in @agent and cmd not in @both and cmd not in @open ->
            project(
              %{
                "allow" => false,
                "refusal" => Refusal.new("unknown-command", component: to_string(cmd))
              },
              channel
            )

          true ->
            peer |> served(cmd, args) |> project(channel)
        end
    end
  end

  # **One gate for every peer-bound command, reads included.**
  #
  # The `:both` commands used to be answered by their own branch above,
  # before this one — so `subscribe`, `inspect_refusal` and the three
  # history pages never even entered `in_world/2`, and the read commands
  # that did entered it to no effect, because `in_world/2` only parks a
  # value that `Ampd.Authority.tx/1` later reads. A command that never
  # reaches the coordinator was never fenced by it.
  #
  # Two things happen here and they are different laws:
  #
  #   * `Ampd.Projection.fence/1` — may this channel be answered at all.
  #     Its incarnation, checked before anything is assembled.
  #   * `Ampd.Projection.framed/2` — for a read, assemble under the
  #     continuity seqlock so the cursor on the frame describes the content
  #     on the frame. A mutation must not be retried, which is why
  #     `Ampd.CommandSpec` declares the difference rather than this list
  #     being maintained here.
  # The two fences are complementary rather than redundant, and both
  # witnesses are in `test/incarnation_test.exs`:
  #
  #   entry fence        catches a command issued *after* the world moved —
  #                      the interval a lineage advance opens between its
  #                      durable bump and its channel barrier. It is the
  #                      only one that can see a read, because a read
  #                      reaches no coordinator.
  #   coordinator fence  catches a command issued *before* the world moved
  #                      and linearizing after it. The entry fence cannot
  #                      see that one: at entry, the manifest had not moved.
  #
  # One binding for both, deliberately. `lineage` is the channel's, sampled
  # when the channel was bound, and the whole of W.1 and F.8.2.5 is that it
  # is not `Ampd.World.lineage()`.
  defp served(peer, cmd, args) do
    lineage = peer["world_lineage"]

    case Projection.fence(lineage) do
      nil -> in_lineage(peer, lineage, cmd, args)
      refused -> refused
    end
  end

  defp in_lineage(peer, lineage, cmd, args) do
    Ampd.Authority.in_world(lineage, fn ->
      run = fn -> dispatch(peer, cmd, args) end

      cond do
        # A read that constructs a refusal writes as it decides, so it is
        # assembled once on the ordered path rather than speculated on.
        cmd in @retry_once -> Projection.framed_once(lineage, run)
        cmd in @reads -> Projection.framed(lineage, run)
        true -> run.()
      end
    end)
  end

  defp project(result, :human_control), do: Refusal.project_result(result, :human_control)
  defp project(result, _agent), do: Refusal.project_result(result, :general)

  defp unknown_peer_refusal(cmd) do
    Refusal.new("unknown-peer",
      component: to_string(cmd),
      retryable: false,
      requires_human: false,
      public_message: "This channel is not bound to an identity.",
      operator_detail: %{
        "command" => to_string(cmd),
        "hint" =>
          "a peer is bound by the runtime when its channel is created; a command from an " <>
            "unbound handle has no actor and therefore no authority to reason about"
      }
    )
  end

  defp impersonation_refusal(cmd) do
    Refusal.new("human-consent-required",
      component: to_string(cmd),
      retryable: false,
      requires_human: true,
      public_message:
        "This command speaks for the person and may only arrive on the human control channel.",
      operator_detail: %{
        "command" => to_string(cmd),
        "hint" =>
          "an agent may request an effect and wait on consent; it may never grant that consent"
      }
    )
  end

  defp wrong_channel_refusal(cmd, channel) do
    Refusal.new("wrong-channel",
      component: to_string(cmd),
      retryable: false,
      requires_human: false,
      public_message: "That command is not available on this channel.",
      operator_detail: %{
        "command" => to_string(cmd),
        "channel" => inspect(channel),
        "hint" =>
          "preflight and request_effect need an actor, and the human control channel has none — " <>
            "the person is the source of consent, not a holder of grants"
      }
    )
  end

  # --------------------------------------------------------------- agent
  # Note what is *absent* from every signature below: a context. The actor
  # comes from the binding, the workspace and run come from the session
  # the runtime holds, and the only thing the caller contributes is a
  # placement preference, which lives in the request where it belongs.
  defp dispatch(peer, :preflight, [cap, resource, request]),
    do: Gateway.preflight(cap, resource, Peer.authoritative_context(peer, request), request)

  defp dispatch(peer, :preflight, [cap, resource]),
    do: dispatch(peer, :preflight, [cap, resource, nil])

  defp dispatch(peer, :agent_projection, _), do: Projection.agent(peer["actor"])

  defp dispatch(peer, :request_effect, [cap, resource, request]),
    do: Gateway.perform(cap, resource, Peer.authoritative_context(peer, request), request)

  defp dispatch(peer, :request_grant, [cap, resource, opts]) do
    Authority.request_grant(%{
      "actor" => peer["actor"],
      "capability" => cap,
      "resource" => resource,
      "requested_duration" => opts["duration"] || "workspace",
      "reason" => opts["reason"]
    })
    |> settled(fn q ->
      %{
        "allow" => false,
        "held" => true,
        "grant_request" => q,
        "reason" => "grant-requested · a person decides this, not the runtime"
      }
    end)
  end

  defp dispatch(peer, :request_grant, [cap, resource]),
    do: dispatch(peer, :request_grant, [cap, resource, %{}])

  defp dispatch(_peer, :inspect_refusal, [id]), do: inspect_refusal(id)

  # ------------------------------------------------------------ loci · D.1.1
  # The Carrier is `peer`, and it is the runtime's record of the binding
  # rather than anything the caller sent. That is the whole of F8: a fresh
  # Carrier attaching as somebody else reaches no capability, however well
  # it knows the ids.
  defp dispatch(peer, :establish_worktree, [locus_ref, name]) do
    Authority.establish_worktree(peer, locus_ref, name)
    |> settled(fn r -> Map.put(r, "allow", true) end)
  end

  defp dispatch(peer, :observe_worktree, [cap_ref]) do
    Ampd.Locus.observe(peer, cap_ref)
    |> settled(fn v -> %{"allow" => true, "resource" => v} end)
  end

  defp dispatch(peer, :attach_locus, [locus_ref]) do
    Ampd.Locus.reconstruct(peer, locus_ref)
    |> settled(fn r -> Map.put(r, "allow", true) end)
  end

  # ---------------------------------------------------- workers · D.1.2
  #
  # **Taking up an assignment is the Carrier's own act.** It is not
  # ordered, because it writes nothing durable — the attachment is a
  # property of a live channel and dies with it. What it returns is a
  # position, not a permission: no capability is reconstructed here, and a
  # Carrier that wants to know what it can now do asks `attach_locus`,
  # which re-derives the set from scratch.
  defp dispatch(peer, :attach_worker, [worker_ref]) do
    Ampd.Worker.attach(peer, worker_ref)
    |> settled(fn r ->
      %{
        "allow" => true,
        "worker" => r["worker"],
        "attachment" => r["attachment"],
        "occupancy" => "OCCUPIED"
      }
    end)
  end

  # Admit → machine → commit, with the machine phase outside the total order.
  # This call can therefore take as long as starting a process takes without
  # holding the coordinator, which is the entire point of the shape.
  defp dispatch(_peer, :reconcile_carrier_attempt, [ticket_id]) do
    case Ampd.Carrier.reconcile(ticket_id) do
      {:refused, r} -> %{"allow" => false, "refusal" => r}
      {:ok, a} -> %{"allow" => true, "attempt" => a}
      other -> %{"allow" => true, "attempt" => other}
    end
  end

  defp dispatch(peer, :start_carrier, [locus_ref]) do
    case Ampd.Carrier.start(peer["id"], locus_ref) do
      {:ok, inc} ->
        # The incarnation, minus nothing — it carries no authority-shaped key
        # by construction and `E2` reads it back recursively to prove it.
        %{"allow" => true, "carrier" => inc}

      {:refused, r} ->
        %{"allow" => false, "refusal" => r}
    end
  end

  # **`:ok = ...` raised on the one outcome the closure just introduced.**
  # `Carrier.stop/1` now legitimately returns `{:indeterminate, why}` when the
  # host does not confirm the process is gone, and a match on `:ok` turned
  # that expected safety state into a MatchError through the public command
  # path. A fail-closed state that crashes is not fail-closed.
  defp dispatch(peer, :stop_carrier, _) do
    case Ampd.Carrier.stop(peer["id"]) do
      :ok ->
        %{"allow" => true, "carrier" => nil}

      {:indeterminate, why} ->
        %{
          "allow" => false,
          "refusal" =>
            Ampd.Refusal.new("carrier-stop-indeterminate",
              component: "Ampd.Carrier",
              retryable: false,
              requires_human: true,
              public_message: "The runtime could not confirm the carrier stopped.",
              operator_detail: %{
                "reason" => why,
                "hint" =>
                  "membership has ended, but a process may still exist — a replacement " <>
                    "is refused until reconcile_carrier_attempt establishes absence"
              }
            )
        }
    end
  end

  # **Detaching ends the occupancy that authorized the execution.** A Carrier
  # left RUNNING at a position nobody occupies is exactly the state
  # `Carrier.still_current?/2` refuses to report, and leaving the process alive
  # would make that refusal cosmetic.
  defp dispatch(peer, :detach_worker, _) do
    r =
      Ampd.Worker.detach(peer)
      |> settled(fn r -> Map.merge(%{"allow" => true, "occupancy" => "OFFLINE"}, r) end)

    Ampd.Carrier.converge("the occupancy was detached")
    r
  end

  # Ancestry-closed, exactly like `list_loci` and for the same reason: an
  # agent that cannot see another actor's Lane must not be handed that
  # actor's assignments, which name the Lane in `locus_ref`. The operator
  # sees the world, because the operator is who the world is for.
  defp dispatch(peer, :list_workers, _) do
    all = Ampd.Loci.workers()

    mine =
      if peer["channel"] == :human_control,
        do: all,
        else: Map.filter(all, fn {_, w} -> w["actor"] == peer["actor"] end)

    %{
      "allow" => true,
      "workers" => Ampd.Worker.projected(mine),
      "count" => map_size(mine)
    }
  end

  # **Ancestry-closed, not table-wide.**
  #
  # This filtered `lanes` by actor and then returned `Ampd.Loci.workspaces()`
  # and `Ampd.Loci.goals()` whole — so an agent could not see another
  # actor's Lane and could see every Workspace and every Goal in the World,
  # including their titles. That is the W.1.3.2 class exactly: **visibility
  # is scoped authority**, and a projection that filters the leaf while
  # serving the tree has not scoped anything.
  #
  # The projection is now the closure of what the caller can legitimately
  # observe — visible lanes, then their goals, then those goals'
  # workspaces — rather than a whole-table read with one filter on top.
  # The operator's projection stays world-complete, because the operator is
  # who the world is for.
  defp dispatch(peer, :list_loci, _) do
    all_lanes = Ampd.Loci.lanes()
    operator? = peer["channel"] == :human_control

    lanes =
      if operator?,
        do: all_lanes,
        else: Map.filter(all_lanes, fn {_, l} -> l["actor"] == peer["actor"] end)

    {goals, workspaces} =
      if operator? do
        {Ampd.Loci.goals(), Ampd.Loci.workspaces()}
      else
        goal_refs = lanes |> Map.values() |> MapSet.new(& &1["goal_ref"])
        goals = Map.filter(Ampd.Loci.goals(), fn {id, _} -> MapSet.member?(goal_refs, id) end)

        ws_refs = goals |> Map.values() |> MapSet.new(& &1["workspace_ref"])
        {goals, Map.filter(Ampd.Loci.workspaces(), fn {id, _} -> MapSet.member?(ws_refs, id) end)}
      end

    %{
      "allow" => true,
      "workspaces" => workspaces,
      "goals" => goals,
      "lanes" => lanes,
      "count" => map_size(lanes)
    }
  end

  # ------------------------------------------------------- human control
  defp dispatch(_peer, :operator_projection, _), do: Projection.operator()

  # Opening a Lane names the actor that may occupy it. That is a person
  # deciding who stands where, and it is the only place the association is
  # made — an agent cannot open a Lane and cannot name itself into one.
  defp dispatch(_peer, :open_workspace, [name]) do
    Authority.open_workspace(%{"name" => name, "world_ref" => Ampd.World.lineage()})
    |> settled(fn w -> %{"allow" => true, "workspace" => w} end)
  end

  # **Referential closure, enforced at the authority boundary.**
  #
  # A Locus's surroundings are supposed to be load-bearing — that is the
  # whole claim of the position — and a phantom ancestor cannot be an
  # established surrounding. `open_goal` accepted any `workspace_ref` that
  # merely had the right prefix, so a Goal could be created under a
  # Workspace that has never existed, and a Lane could then stand on it.
  defp dispatch(_peer, :open_goal, [workspace_ref, title]) do
    if Ampd.Loci.workspace(workspace_ref) == nil do
      refuse("workspace-unknown", "No such workspace.", %{"workspace_ref" => workspace_ref})
    else
      Authority.open_goal(%{"workspace_ref" => workspace_ref, "title" => title})
      |> settled(fn g -> %{"allow" => true, "goal" => g} end)
    end
  end

  defp dispatch(_peer, :open_lane, [goal_ref, actor, repository_ref, base_revision]) do
    goal = Ampd.Loci.goal(goal_ref)

    cond do
      goal == nil ->
        refuse("goal-unknown", "No such goal.", %{"goal_ref" => goal_ref})

      # The repository was checked at establishment and not at open, so a
      # Lane could be opened naming a repository that does not resolve and
      # only discover it much later — with the Lane already durable and
      # already presented as a position someone occupies.
      Ampd.Worktree.repo(repository_ref) == nil ->
        refuse("repository-unknown", "No such repository.", %{
          "repository_ref" => repository_ref
        })

      true ->
        Authority.open_lane(%{
          "workspace_ref" => goal["workspace_ref"],
          "goal_ref" => goal_ref,
          "actor" => actor,
          "repository_ref" => repository_ref,
          "base_revision" => base_revision,
          "status" => "open"
        })
        |> settled(fn l -> %{"allow" => true, "lane" => l} end)
    end
  end

  # **A person assigns; nobody assigns themselves.** `open_worker` is on the
  # human control channel for the same reason `open_lane` is: it decides who
  # stands where, and a runtime in which an agent could create its own
  # assignment has moved the decision from the person to the process.
  #
  # Referential closure is enforced before the mutation, not inside it, so
  # a Worker naming a Lane that never existed cannot become durable.
  defp dispatch(_peer, :open_worker, [locus_ref, purpose]) do
    Authority.open_worker(locus_ref, purpose)
    |> settled(fn w -> %{"allow" => true, "worker" => w} end)
  end

  # **`close_worker` is a supervision primitive and must now supervise
  # execution too.** It was established as the way a person ends a live
  # occupancy; with a Carrier in the picture, ending the occupancy while the
  # process keeps running would make the supervision primitive supervise half
  # the thing. Closing advances the generation, so `converge/1` finds the
  # incarnation stale by re-derivation rather than by being told.
  defp dispatch(_peer, :close_worker, [worker_ref]) do
    r =
      Authority.close_worker(worker_ref) |> settled(fn w -> %{"allow" => true, "worker" => w} end)

    Ampd.Carrier.converge("the worker was closed")
    r
  end

  defp dispatch(_peer, :reopen_worker, [worker_ref]) do
    Authority.reopen_worker(worker_ref)
    |> settled(fn w -> %{"allow" => true, "worker" => w} end)
  end

  # **D.1.3c·2c·1b — the one place a terminal data plane is authorised, and
  # `peer` is the bound connection rather than an argument.**
  #
  # Everything the page may say is in the head: the position it designates,
  # the incarnation of it that it saw, and the endpoint its own process
  # parked over the bridge. The Peer, the Carrier, the attachment and the
  # stream owner are derived by `Ampd.Terminal.Presentation.resolve/3` from
  # those, and none of them is returned — `presentable/1` hands back the two
  # identifiers the page already had. A derived identifier crossing to a page
  # is how an unguessable name becomes a bearer token.
  #
  # **The endpoint is claimed only after the authority holds.** Ordered the
  # other way, a refused request would still have consumed the descriptor,
  # and a page could exhaust a cockpit's endpoints by asking for Workers it
  # may not see.
  defp dispatch(peer, :terminal_bind, [worker_ref, expected_generation, endpoint_ref]) do
    case Ampd.Terminal.Presentation.resolve(peer, worker_ref, expected_generation) do
      {:refused, r} ->
        %{"allow" => false, "refusal" => r}

      {:ok, presentation} ->
        case Ampd.Terminal.Plane.open(endpoint_ref, presentation) do
          {:ok, _pid, presentable} ->
            %{"allow" => true, "presentation" => presentable}

          {:error, reason} ->
            %{"allow" => false, "refusal" => plane_refusal(reason)}
        end
    end
  end

  defp dispatch(_peer, :approve_effect, [request_id, approval_id]),
    do: approve_effect(request_id, approval_id)

  defp dispatch(_peer, :deny_effect, [approval_id, why]) do
    Authority.deny_approval(approval_id, why)
    |> settled(fn _ -> %{"allow" => false, "denied" => approval_id} end)
  end

  # One grant, by id, because the person is looking at one grant object.
  # This used to take a *capability* and revoke every actor's grant for it:
  # an operator revoking Kestrel's `github.repo.read` took Mallory's too.
  defp dispatch(_peer, :revoke_grant, [grant_id]) do
    Authority.revoke_one(grant_id)
    |> settled(fn g -> %{"allow" => true, "revoked" => g["id"], "grant" => g} end)
  end

  # Bulk revocation, deliberately harder to say.
  #
  # **The identity check and the mutation share one linearization point.**
  # This used to read `GrantRegistry.matching(scope)` *here*, compare a
  # count, and then call `Authority.revoke_matching(scope)` — which enters
  # the coordinator. Two samples of the world, and the gap between them is
  # writable:
  #
  #     operator is shown   [gr_A, gr_B]
  #     ...                 gr_B revoked, gr_C minted   ← anyone's write
  #     scope now matches   [gr_A, gr_C]     count still 2
  #     bulk revoke         gr_A and gr_C
  #
  # Reproduced exactly that way before it was fixed: six shown, six
  # matched, and the set revoked contained a grant the operator never saw.
  # A count cannot detect it, so the confirmation is now the **exact set of
  # grant ids**, and it is compared inside the transaction that revokes —
  # see `Ampd.GrantRegistry.revoke_matching/2`. Nothing about the world is
  # sampled in this function.
  #
  # The scope still has to be bounded, and that check stays here because it
  # reads only the argument: `%{}` is unbounded whatever the world holds.
  defp dispatch(_peer, :revoke_capability_domain, [scope, expected_ids]) do
    scope = Map.take(scope || %{}, ["actor", "capability", "resource"])

    if scope == %{} or Enum.all?(scope, fn {_, v} -> v == nil end) do
      refuse(
        "bulk-scope-unbounded",
        "A bulk revocation must name at least one of actor, capability, or resource.",
        %{"scope" => scope}
      )
    else
      Authority.revoke_matching(scope, expected_ids)
      |> settled(fn ids -> %{"allow" => true, "revoked" => ids, "count" => length(ids)} end)
    end
  end

  # A channel asking to be pushed its own projection when the world moves.
  # Not an authority operation: what arrives is what this channel could
  # already ask for, so subscribing grants no read it did not have.
  defp dispatch(peer, :subscribe, _),
    do: Ampd.Subscriptions.subscribe(peer)

  defp dispatch(peer, :unsubscribe, _),
    do: Ampd.Subscriptions.unsubscribe(peer["id"])

  # History is paged, not pushed. The filter is the peer's own actor — the
  # operator has none and therefore sees the world's, an agent sees only
  # its own. That is the same rule the projections apply, reused rather
  # than restated, because a second copy of a filter is a second thing that
  # can be wrong.
  defp dispatch(peer, :list_receipts, [cursor, limit]),
    do: Projection.page(Projection.history_for(:receipts, peer["actor"]), cursor, limit)

  defp dispatch(peer, :list_effect_history, [cursor, limit]),
    do: Projection.page(Projection.history_for(:effects, peer["actor"]), cursor, limit)

  defp dispatch(peer, :list_grant_requests, [cursor, limit]),
    do: Projection.page(Projection.history_for(:grant_requests, peer["actor"]), cursor, limit)

  defp dispatch(_peer, :approve_grant_request, [id]),
    do: dispatch(nil, :approve_grant_request, [id, nil])

  defp dispatch(_peer, :approve_grant_request, [id, duration]) do
    Authority.approve_grant_request(id, duration)
    |> settled(fn g -> %{"allow" => true, "granted" => g} end)
  end

  defp dispatch(_peer, :deny_grant_request, [id, why]) do
    Authority.deny_grant_request(id, why)
    |> settled(fn q -> %{"allow" => false, "denied" => q} end)
  end

  # Reports seals. It does **not** recover: there is no recovery
  # transition yet, and a command called `recover_world` that only
  # describes the damage is a name making a promise the code does not
  # keep. When the transition exists it gets its own name and its own
  # falsifier — `Ampd.Authority.advance_lineage/2` is the runtime half of
  # it, and it is deliberately not on a channel until the restore that
  # calls it exists.
  defp dispatch(_peer, :recovery_status, _) do
    %{
      "schema" => "recovery-status@1",
      "seals" =>
        Enum.map(Ampd.seals(), fn {m, reason} ->
          %{"registry" => inspect(m), "reason" => reason}
        end),
      "world" => %{
        "manifest_state" => to_string(Ampd.World.manifest_state()),
        "lineage" => Ampd.World.lineage()
      },
      "recoverable" => false,
      "note" => "reporting only — no recovery transition is implemented yet"
    }
  end

  # The plane's failures are runtime facts rather than authority ones — an
  # endpoint that expired, a stream owner that died between the derivation
  # and the bind, a terminal something else is already presenting. They get
  # their own names for the same reason every link in the resolution chain
  # does: `terminal-already-presented` and `terminal-endpoint-unknown` call
  # for opposite responses from whoever reads them.
  defp plane_refusal(reason) do
    code =
      case reason do
        :unknown_terminal_endpoint -> "terminal-endpoint-unknown"
        :terminal_already_presented -> "terminal-already-presented"
        :terminal_stream_gone -> "terminal-stream-gone"
        other -> "terminal-plane-refused-#{other}"
      end

    Ampd.Refusal.new(code,
      component: "Ampd.Terminal.Plane",
      retryable: false,
      requires_human: false,
      operator_detail: %{"reason" => to_string(reason)}
    )
  end

  @doc """
  Look a refusal up by the `correlation_id` it was handed out with.

  Both channels may ask; each gets its own projection of the same stored
  object. That is the dual disclosure checked from the other direction:
  the agent that received `code` and `public_message` can come back with
  the correlation id and still not learn the topology, while the operator
  can paste the same id and see everything.
  """
  def inspect_refusal(id) do
    case Ampd.RefusalLog.get(id) do
      nil ->
        refuse(
          "refusal-unknown",
          "No refusal with that correlation id is still in the ring.",
          %{"correlation_id" => id, "ring_capacity" => Ampd.RefusalLog.capacity()}
        )

      r ->
        %{"allow" => false, "schema" => "refusal-lookup@1", "refusal" => r}
    end
  end

  @doc """
  Approve **the object the human is looking at.**

  With more than one effect in flight, "approve whatever is last" is
  exactly the wrong identity semantics — the human is looking at one
  proposal, and consent must bind to that one. Both identities are
  required and must agree, so a UI that has drifted from the runtime
  refuses instead of approving a neighbour.
  """
  def approve_effect(request_id, approval_id) do
    a = Enum.find(Approvals.all(), &(&1["id"] == approval_id))

    cond do
      a == nil ->
        refuse("approval-unknown", "No such approval.", %{"approval_id" => approval_id})

      a["status"] != "pending" ->
        refuse("approval-not-pending", "That approval is no longer awaiting a decision.", %{
          "approval_id" => approval_id,
          "status" => a["status"]
        })

      get_in(a, ["envelope", "request_id"]) != request_id ->
        refuse(
          "approval-identity-mismatch",
          "That approval does not belong to the effect you are approving.",
          %{
            "approval_id" => approval_id,
            "asked_for" => request_id,
            "belongs_to" => get_in(a, ["envelope", "request_id"])
          }
        )

      true ->
        Authority.grant_approval(approval_id)

        auth =
          Gateway.perform(a["capability"], a["resource"], a["held_ctx"], %{
            "er" => a["envelope"]["request_id"],
            "rev" => a["envelope"]["request_revision"],
            "params" => a["envelope"]["request"]
          })

        if auth["allow"] do
          auth
        else
          reason = auth["reason"] || "state changed under the approval"

          # **Only claim the mark that actually landed.** `stale_approval/2`
          # is an ordered mutation and can be refused — a sealed approvals
          # store, or the world-incarnation fence when this channel belongs
          # to an incarnation that has ended. Announcing `surfaced_stale`
          # regardless tells the person the approval was expired when
          # nothing wrote to it, which is the same class of defect as the
          # three commands this module's `settled/2` exists to prevent.
          case Authority.stale_approval(approval_id, reason) do
            {:refused, _} -> auth
            _ -> Map.put(auth, "surfaced_stale", reason)
          end
        end
    end
  end

  @doc """
  **The response reports the result of the transition, not the command the
  caller attempted.**

  Every ordered mutation can come back `{:refused, refusal@1}` — the store
  is sealed, the caller was not the coordinator, the duration was not a
  duration. Three commands ignored that and answered as though the write
  had landed: `revoke_grant` replied `"revoked"` into a sealed registry,
  `request_grant` handed back a `grant_request` that was really a refusal
  tuple, and `approve_grant_request` crashed indexing one.

  That is the failure C1.1.0 spent a whole round preventing at the store —
  a sealed registry stays alive precisely so it can *return a named
  refusal* — undone one layer up by callers who never looked.

  So: every mutating dispatch goes through here, and a refusal becomes a
  refusal.
  """
  def settled(result, on_ok)

  def settled({:refused, r}, _on_ok),
    do: %{"allow" => false, "reason" => r["public_message"], "refusal" => r}

  def settled({:ok, v}, on_ok), do: on_ok.(v)
  def settled(v, on_ok), do: on_ok.(v)

  defp refuse(code, msg, detail) do
    %{
      "allow" => false,
      "reason" => msg,
      "refusal" =>
        Refusal.new(code,
          component: "approvals",
          requires_human: true,
          public_message: msg,
          operator_detail: detail
        )
    }
  end
end
