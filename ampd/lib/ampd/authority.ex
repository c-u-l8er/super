defmodule Ampd.Authority do
  @moduledoc """
  The linearized authority API — the only supported way to change what may
  be exercised, and the only way to claim an effect.

  The registry modules still expose raw primitives, because the
  coordinator has to call *something* once it holds the order. Those
  primitives are not the public surface: calling `GrantRegistry.revoke_domain/1`
  directly is unordered with respect to a concurrent claim, which is
  exactly the defect this module exists to remove. C1.1's typed projection
  commands (`request_grant`, `revoke_grant`, `approve_effect`,
  `deny_effect`) enter here.
  """
  alias Ampd.{AuthorityCoordinator, GrantRegistry, Session, CapabilityRegistry,
              Approvals, Effects, Gateway, Core}

  # **Every authority operation executes only in the world incarnation to
  # which its authority-bearing channel was bound.**
  #
  # Two chokepoints, and the reason it is done this way rather than by
  # threading a lineage through forty function heads: `Ampd.Control.command/3`
  # is the only way a peer reaches this module, and `tx/1` is the only way
  # this module reaches the coordinator. One place sets the expectation and
  # one place reads it, so a command added later cannot forget to carry it
  # — which is the failure mode every round of this arc has been about.
  #
  # The value travels in the process dictionary because the frames in
  # between are `Ampd.Authority`'s own public API, and widening all of them
  # to take a world would make "which world" an argument callers can pass
  # wrongly. This is caller-scoped context, not data.
  @fence :ampd_expected_world

  @doc """
  Run `fun` as work belonging to `lineage`.

  Set by `Ampd.Control.command/3` from the peer record, which captured it
  when the channel was bound. `nil` means unfenced — bootstrap, fixtures,
  and the conformance harness, none of which are a peer.
  """
  def in_world(lineage, fun) do
    prev = Process.get(@fence)
    Process.put(@fence, lineage)

    try do
      fun.()
    after
      if prev, do: Process.put(@fence, prev), else: Process.delete(@fence)
    end
  end

  defp tx(fun), do: AuthorityCoordinator.transact(fun, Process.get(@fence))

  # ---------------------------------------------------------------- grants
  def mint(fields), do: tx(fn -> GrantRegistry.mint(fields) end)
  def one_shot(cap), do: tx(fn -> GrantRegistry.one_shot(cap) end)
  def revoke_domain(cap), do: tx(fn -> GrantRegistry.revoke_domain(cap) end)
  def set_draft(k, v), do: tx(fn -> GrantRegistry.set_draft(k, v) end)

  @doc """
  Record an agent's request for authority. **Creates no authority.**

  The request is a pending object with the asking actor on it; a human
  turns it into a grant with `approve_grant_request/2` or refuses it. That
  separation is what keeps "an agent asked" distinguishable from "the
  person chose", which sharing the grant draft destroyed.
  """
  def request_grant(fields), do: tx(fn -> GrantRegistry.request_grant(fields) end)

  @doc """
  Revoke one grant, by id — **human control only**.

  See `Ampd.GrantRegistry.revoke_one/1` for why this is not a capability.
  """
  def revoke_one(id), do: tx(fn -> GrantRegistry.revoke_one(id) end)

  @doc """
  Revoke exactly `expected_ids` — human control only, and deliberately
  harder to say than `revoke_one/1`.

  Note what this function does **not** do: sample the world, compare, and
  then mutate. Both happen inside `GrantRegistry.revoke_matching/2`, which
  is one message to one process, so the confirmation the operator gave and
  the set that is revoked cannot be two different worlds. Doing the
  comparison out here — where it used to live, one layer further up — left
  a writable gap between the two.
  """
  def revoke_matching(filter, expected_ids) when is_list(expected_ids),
    do: tx(fn -> GrantRegistry.revoke_matching(filter, expected_ids) end)

  @doc """
  Grant an agent's request — **human control only**, enforced by
  `Ampd.Control`.

  The grant is minted from the request's own fields, so what is granted is
  what was asked for. Three things are checked before anything is minted,
  and each closes a way authority could widen without anyone deciding to:

  1. **The duration must be enforceable.** An agent could request
     `"forever"`; approving without overriding it wrote that straight onto
     the grant, and the scope check honoured it, because it ended in
     `_ -> true`.

  2. **Approval may narrow, never widen.** A request for `once` resolved as
     `workspace` is not an approval of that request — it is a broader grant
     the person authored, and it should have to be authored, not arrive as
     the side effect of clicking approve on something narrower.

  3. **The capability must be declared by an *installed* pack, now.** A
     grant for a capability nothing declares sits dormant and harmless
     until the pack that declares it is installed — at which point
     installation activates authority nobody granted afterwards, which is
     the one law this system has held since C0.
  """
  def approve_grant_request(id, duration \\ nil) do
    tx(fn ->
      q = Enum.find(GrantRegistry.requests(), &(&1["id"] == id and &1["status"] == "pending"))
      dur = duration || (q && q["requested_duration"]) || "workspace"

      cond do
        q == nil ->
          {:refused, refuse("grant-request-unknown", "No such pending grant request.", %{"id" => id})}

        not Core.duration?(dur) ->
          {:refused,
           refuse("invalid-grant-duration", "That is not a grant duration this system can enforce.",
             %{"given" => inspect(dur), "allowed" => Core.durations()})}

        # **The request's own duration must be rankable before it is
        # ranked.** `Core.duration_rank/1` returns `nil` for anything
        # outside the enum, and `nil` sorts above every integer in Elixir's
        # term order — so `rank(dur) > nil` is `false` and the widening
        # guard below was silently open for every approval of a malformed
        # request. `request_grant` now refuses such a request at creation,
        # which means new ones cannot reach here; this clause is for the
        # ones already on disk in a store written before that rule existed.
        not Core.duration?(q["requested_duration"] || "workspace") ->
          {:refused,
           refuse("invalid-grant-duration",
             "That request asks for a duration this system cannot enforce.",
             %{"requested" => inspect(q["requested_duration"]), "allowed" => Core.durations(),
               "hint" =>
                 "the request predates the rule that refuses these at creation — deny it and " <>
                   "let the agent ask again"})}

        Core.duration_rank(dur) > Core.duration_rank(q["requested_duration"] || "workspace") ->
          {:refused,
           refuse("grant-widening-refused",
             "Approving a request may narrow it, never widen it.",
             %{"requested" => q["requested_duration"], "attempted" => dur,
               "hint" => "a broader grant is a new grant the person authors, not an approval"})}

        stale_pack(q) != nil ->
          {:refused, stale_pack(q)}

        not declared_and_installed?(q["capability"]) ->
          {:refused,
           refuse("capability-undeclared",
             "No installed pack declares that capability.",
             %{"capability" => q["capability"],
               "hint" =>
                 "minting it now would lie dormant until the pack is installed, and then " <>
                   "installation would activate authority nobody granted afterwards"})}

        true ->
          fields = %{"capability" => q["capability"], "resource" => q["resource"],
                     "actor" => q["actor"], "duration" => dur}

          fields = if dur == "once", do: Map.put(fields, "uses_remaining", 1), else: fields

          case GrantRegistry.mint(fields) do
            {:refused, _} = r ->
              r

            g ->
              GrantRegistry.resolve_request(id, "granted", "granted as #{dur} · #{g["id"]}")
              {:ok, g}
          end
      end
    end)
  end

  @doc "Refuse an agent's request for authority — human control only."
  def deny_grant_request(id, why),
    do: tx(fn -> GrantRegistry.resolve_request(id, "denied", why) end)

  @doc false
  # **Was the contract still the one that was asked about?**
  #
  # A `grant-request@1` records the pack version and a digest over its
  # authority-relevant surface at the moment the agent asked. A pending
  # request can outlive an update: GitHub 1.5 → 2.0 can redefine what
  # `github.issue.write` reaches, or move where its secret may live, and
  # the human then approves a capability *name* whose meaning changed
  # since it was requested.
  #
  # This is the grant-level form of the rule `approval-intent@1` already
  # holds for effects — consent binds to an exact contract, not to a label
  # that happens to still read the same.
  #
  # Returns a refusal, or `nil`. The request stays **pending** on refusal,
  # because a refused approval must not consume the thing it refused —
  # the same reason `grant-widening-refused` leaves it pending. The
  # operator's next move is `deny_grant_request`, and the agent asks again
  # against the contract that is actually installed.
  #
  # Requests written before this binding existed carry no digest, and are
  # not treated as stale: absence of evidence is not evidence of a change,
  # and refusing every pre-existing request on an upgrade would be a
  # migration failure wearing a security refusal's name.
  defp stale_pack(q) do
    was = q["pack_digest"]
    pk = q["pack"] && CapabilityRegistry.get(q["pack"])

    cond do
      was == nil -> nil
      pk == nil -> nil
      Core.pack_digest(pk) == was -> nil
      true ->
        refuse("grant-request-stale",
          "The pack that declares this capability changed after the request was made.",
          %{"pack" => q["pack"],
            "requested_under_version" => q["pack_version"],
            "installed_version" => pk["version"],
            "requested_under_digest" => was,
            "installed_digest" => Core.pack_digest(pk),
            "hint" =>
              "approving would grant a capability whose contract is not the one that was asked " <>
                "about — deny this request and let the agent ask again"})
    end
  end

  # Declared *and* installed, sampled now. A discovered pack ships its whole
  # surface — that is what makes it browsable — so "declared" alone is a
  # weaker test than it reads.
  defp declared_and_installed?(cap) do
    pk = CapabilityRegistry.get(Core.pack_of(cap))

    pk != nil and pk["installation"] in ["installed", "builtin"] and
      is_map(pk["surface"]) and Map.has_key?(pk["surface"], Core.cap_key(cap))
  end

  defp refuse(code, msg, detail) do
    Ampd.Refusal.new(code,
      component: "Ampd.Authority",
      retryable: false,
      requires_human: true,
      public_message: msg,
      operator_detail: detail
    )
  end
  def set_dur(d) do
    if Core.duration?(d) do
      tx(fn -> GrantRegistry.set_dur(d) end)
    else
      {:refused,
       refuse("invalid-grant-duration", "That is not a grant duration this system can enforce.",
         %{"given" => inspect(d), "allowed" => Core.durations()})}
    end
  end
  def commit(surface), do: tx(fn -> GrantRegistry.commit(surface) end)

  # --------------------------------------------------------------- session
  def end_run, do: tx(fn -> Session.end_run() end)
  def set_world(w), do: tx(fn -> Session.set_world(w) end)

  # ---------------------------------------------------------- pack surface
  # Policy is authority: `source_data` and secret residency decide *where*
  # an effect may run, so changing them is ordered like a grant change.
  def install_postgres, do: tx(fn -> CapabilityRegistry.install_postgres() end)
  def update_github, do: tx(fn -> CapabilityRegistry.update_github() end)

  # -------------------------------------------------------------- consent
  def grant_approval(id), do: tx(fn -> Approvals.mark(id, "granted") end)
  def deny_approval(id, why), do: tx(fn -> Approvals.mark(id, "denied", why) end)
  def stale_approval(id, why), do: tx(fn -> Approvals.mark(id, "stale", why) end)

  # --------------------------------------------------------- world lineage
  @doc """
  Advance world lineage: end this incarnation, close every channel bound to
  it, and stale every consent taken under it.

  **A generation change is a discontinuity, and authority does not cross a
  discontinuity — it is reacquired on the other side.** That is the product
  sentence `CLOUD_V1.md` §1 already ruled ("state moves; authority does
  not"), and until F.8.2.5 the runtime did not obey it: a restore moved the
  generation and left every channel open, so a command formed against the
  ending world could still linearize into the one that replaced it.

  Two laws, and F.8.2.4 shipped only the first:

      no consent given under generation N is live in N+1
      no channel bound under generation N is valid in N+1

  The second does not follow from the first. A queued `request_grant` has
  no approval to invalidate — it would simply open a new request in the
  restored world, on behalf of an actor that world may never have named.

  ## Order, and why this one

      1. bump the manifest      the discontinuity, made durable
      2. close every channel    Ampd.Bridge, then Ampd.Peer
      3. stale prior consent    the explanation; the digest is the enforcement

  The bump is first for two reasons. If it raises — no world, unwritable
  manifest — nothing has been torn down, so a failed advance is not also a
  denial of service. And the interval between (1) and (2) is safe *because*
  of the fence rather than in spite of it: this whole body runs inside the
  coordinator, so a command that resolves a still-live handle during the
  teardown cannot linearize until after it, and arrives carrying generation
  N against a current generation N+1. The barrier closes the door; the
  fence catches whoever was already through it.

  `Ampd.Bootstrap.reset_world!/0` tears down *before* it touches the world,
  and the asymmetry is deliberate: a factory reset deletes the manifest, so
  there is an interval with no world at all, and the bridge can only detach
  each identity while the table that minted it is still the live one.

  Returns `{meta, staled_ids}`. The channel barrier is deliberately not
  reported in the return value — `Ampd.Bridge.list/0` and `Ampd.Peer.list/0`
  are the evidence, and a test that reads a count this function chose to
  print would be measuring the report instead of the effect.

  If the approvals store is itself sealed the marks are refused by name and
  `staled_ids` is empty, which is survivable: the lineage is also inside
  every approval digest, so `Ampd.Gateway`'s exact-match cannot match an
  approval from another generation whether or not anyone got to relabel it.
  """
  def advance_lineage(reason, restored_from \\ nil) do
    tx(fn ->
      meta = Ampd.World.bump_generation!(reason, restored_from)
      close_channels!()
      {meta, stale_prior_consent(meta, reason)}
    end)
  end

  # The channel barrier. Bridge before Peer, for the same reason
  # `Ampd.Bootstrap.do_reset_world!/0` has that order: the bridge detaches
  # each identity as it disposes of the channel holding it, and it can only
  # do that while the peer table is still the one that minted them.
  #
  # `Ampd.Peer.reset/0` also mints a fresh peer epoch, so every outstanding
  # handle stops resolving rather than merely being absent from a map. After
  # this returns, the person's control claim is free and every engine has to
  # reattach — which is what "authority is re-established" means in the one
  # place it is mechanical rather than aspirational.
  defp close_channels! do
    if Process.whereis(Ampd.Bridge), do: Ampd.Bridge.reset()
    if Process.whereis(Ampd.Peer), do: Ampd.Peer.reset()
  end

  # **SEALED is a discontinuity in trusted world knowledge, and consent from
  # before a discontinuity must never automatically become live after it.**
  # The human approved one exact intent under an authority snapshot; a
  # restored world cannot re-derive that snapshot, so what survives on disk
  # is a record of a decision, not a live permission.
  #
  # Staling happens here, at the trusted recovery — not at the moment a
  # store seals. At seal time one of the stores involved may be the damaged
  # one, and a recovery step whose first act is to write to the thing that
  # just failed is a recovery step that cannot run when it is needed. So the
  # seal only refuses; the lineage advance is what expires consent.
  defp stale_prior_consent(meta, reason) do
    gen = meta["generation"]
    iid = meta["installation_id"]

    Approvals.all()
    |> Enum.filter(fn a ->
      a["status"] in ["pending", "granted"] and
        (a["world_generation"] != gen or a["world_installation_id"] != iid)
    end)
    |> Enum.filter(fn a ->
      Approvals.mark(a["id"], "stale",
        "world lineage advanced to generation #{gen} (#{reason}) — " <>
          "the authority state this consent was given under can no longer be re-derived") == :ok
    end)
    |> Enum.map(& &1["id"])
  end

  # ---------------------------------------------------------------- claim
  @doc """
  Decide, journal, claim, and consume — all inside the total order.

  The decision is taken **here**, not by the caller, which is what makes a
  revocation that returned before this call always win. Returns
  `{:refused, auth}` or `{:claimed, auth, effect}`.
  """
  def claim_and_consume(cap, resource, ctx, request) do
    tx(fn ->
      auth = Gateway.decide(cap, resource, ctx, request)

      if auth["allow"] != true do
        {:refused, auth}
      else
        pk = CapabilityRegistry.get(Core.pack_of(cap)) || %{}
        req = request || %{}

        e =
          Effects.propose(%{
            "effect_key" => auth["effect_key"],
            "approval_digest" => auth["request_hash"],
            "capability" => cap,
            "pack" => Core.pack_of(cap) <> "@" <> (pk["version"] || "0"),
            "actor" => ctx["actor"],
            "resource" => resource,
            "request_id" => req["er"],
            "request_revision" => req["rev"] || 1,
            "request" => req["params"]
          })

        Effects.authorized(e["id"], %{
          "grant_ref" => auth["grant_ref"],
          "authority_snapshot_at_entry" => auth["authority_snapshot_at_entry"],
          "placement" => auth["placement"]
        })

        if auth["approval_ref"],
          do: Effects.approved(e["id"], %{"approval_ref" => auth["approval_ref"]})

        case Effects.claim(e["id"]) do
          {:error, why} ->
            {:refused, Map.merge(auth, %{"allow" => false, "reason" => why})}

          {:ok, claimed} ->
            # The lease begins here. Consent is spent only now, with the
            # claim already durable and the order already held.
            Gateway.consume!(auth)
            {:claimed, auth, claimed}
        end
      end
    end)
  end
end
