defmodule Ampd.Gateway do
  @moduledoc """
  The one door. No path reaches an adapter except through here:
  recovery seal → grant matching (named near-misses) → placement
  derivation (cited) → approval binding (exact intent digest + full
  identity) → **durable claim** → attempt → receipt.

  Two product entry points, deliberately distinct:

  * `preflight/4` — advisory eligibility. Creates nothing, stales nothing.
  * `perform/5` — the effect path: journal first, consume after the claim
    is durable, adapter after ATTEMPTED is durable. The only ordering that
    survives a crash between consuming consent and touching the world.

  `decide/4` is the ordered verdict and is `@doc false` — it may open a
  pending approval, so it belongs inside the total order.

  `authorize/4` used to live here as a third entry point. It consumes
  consent with no journal in front of it, which is the C1.0a shape C1.0b
  replaced — it is now `Ampd.Conformance.authorize/4`, along with
  `exercise/1`, `approve_last/0`, and `forge_pr_create/1`. Four
  test-shaped functions sitting beside the product ones were a second
  runtime API waiting to be discovered by someone in a hurry.
  """
  alias Ampd.{Core, CapabilityRegistry, GrantRegistry, Session, Approvals, Receipts, Effects}

  def ctx, do: Session.ctx()

  # ---------------------------------------------------------------- seal
  # A sealed registry holds no authority and says why. Checking it here,
  # at the one door, means a refusal is *named* rather than a crash loop —
  # an outage tells you nothing, and this system's doctrine is that every
  # refusal tells you what to fix.
  defp seal_refusal do
    case Ampd.seals() do
      [] ->
        nil

      [{mod, reason} | _] ->
        code = Ampd.Refusal.seal_code(reason)

        # `reason` names the world, its generation, and which store is
        # gone — useful to an operator, and topology an arbitrary local
        # agent has no business reading. It lives in operator_detail, and
        # `Ampd.Refusal.project_result/2` replaces it on the general
        # channel with the public message.
        %{"allow" => false, "reason" => reason, "sealed" => true,
          "refusal" =>
            Ampd.Refusal.new(code,
              component: inspect(mod),
              retryable: false,
              requires_human: true,
              operator_detail: %{"seal" => reason, "seals" => length(Ampd.seals())}
            )}
    end
  end

  # ------------------------------------------------------------ preflight
  @doc """
  `preflight@1` — advisory eligibility. **Creates nothing and stales
  nothing.**

  This exists because `decide/4` was never read-only: for approval-class
  capabilities it opens a pending approval and marks older ones stale, so
  a bare `decide` mutated approval state *outside* the total order. That
  contradicted the C1.0b.1 claim that approval mutations are ordered, and
  it contradicted its own docstring.

  A UI asks this to render "eligible now · approval required". It must not
  render "authorized" — the answer can be stale by the time the user
  clicks, which is why `perform/5` re-decides at the claim regardless.
  """
  def preflight(cap, resource, ctx, request \\ nil) do
    raw = seal_refusal() || do_decide(cap, resource, ctx, request, :preflight)

    %{
      "schema" => "preflight@1",
      "advisory" => true,
      "capability" => cap,
      "resource" => resource,
      "eligible" => raw["allow"] == true or raw["requires_approval"] == true,
      "requires_approval" => raw["requires_approval"] == true,
      "placement" => raw["placement"],
      "observed_authority_snapshot" => raw["authority_snapshot_at_entry"],
      "effect_key" => raw["effect_key"],
      "reason" => raw["reason"],
      "refusal" => raw["refusal"]
    }
  end

  # -------------------------------------------------------------- decide
  @doc false
  # The ordered decision. Not public: it may open a pending approval and
  # stale prior consent, so it belongs inside the total order. Callers
  # want `preflight/4` (advisory) or `perform/5` (acts).
  def decide(cap, resource, ctx, params_or_nil) do
    if Ampd.Ordered.inside?() do
      seal_refusal() || do_decide(cap, resource, ctx, params_or_nil, :ordered)
    else
      r = Ampd.Ordered.refusal(:decide, __MODULE__)
      %{"allow" => false, "reason" => r["public_message"], "refusal" => r}
    end
  end

  # Every refusal below carries both forms: the exact sentence the frozen
  # simulator produces (`reason`, which the vectors match on) and a
  # structured `refusal@1` (which the channel projection redacts). They
  # are built together so a refusal can never gain a reason without
  # gaining a class — the drift that would put a resource name back into
  # an agent's hands.
  defp refuse(code, reason, detail, opts \\ []) do
    %{"allow" => false, "reason" => reason,
      "refusal" =>
        Ampd.Refusal.new(code,
          component: "Ampd.Gateway",
          retryable: Keyword.get(opts, :retryable, false),
          requires_human: Keyword.get(opts, :requires_human, false),
          operator_detail: Map.put(detail, "reason", reason)
        )}
  end

  defp do_decide(cap, resource, ctx, params_or_nil, mode) do
    pk = CapabilityRegistry.get(Core.pack_of(cap))

    cond do
      pk == nil or pk["surface"] == nil ->
        refuse("capability-undeclared",
          "capability-undeclared · pack \"" <> Core.pack_of(cap) <> "\" declares no surface",
          %{"pack" => Core.pack_of(cap)})

      # A DISCOVERED pack already declares its full surface — that is what
      # makes it browsable before you install it. `installation` was read
      # only by the catalog UI, never here, so a grant minted against a
      # merely-available pack authorized against a pack nobody installed.
      # *Installation confers zero authority* is this system's oldest law;
      # unread, it ran the other way, and discovery conferred authority the
      # moment anyone granted against it.
      pk["installation"] not in ["installed", "builtin"] ->
        refuse("pack-not-installed",
          "pack-not-installed · " <> Core.pack_of(cap) <> " is " <> to_string(pk["installation"]) <>
            " — a declared surface is not an installed one",
          %{"pack" => Core.pack_of(cap), "installation" => pk["installation"]},
          requires_human: true)

      true ->
        decl = pk["surface"][Core.cap_key(cap)]
        grants = GrantRegistry.list()

        cond do
          decl == nil ->
            refuse("capability-undeclared",
              "capability-undeclared · " <> cap <> " is not in the pack surface",
              %{"capability" => cap, "pack" => Core.pack_of(cap)})

          decl["deny"] == true and
              not Enum.any?(grants, &(&1["status"] == "active" and &1["capability"] == cap)) ->
            refuse("denied-by-default",
              "denied-by-default · " <> cap <> " (class " <> decl["cls"] <> ") — narrow one-shot grants only",
              %{"capability" => cap, "class" => decl["cls"]},
              requires_human: true)

          true ->
            retired? = &Session.retired?/1

            case Core.grant_for(grants, cap, resource, ctx, retired?) do
              nil ->
                {code, detail} = Core.near_miss_class(grants, cap, resource, ctx, retired?)

                # The code stored is the true one. `Ampd.Refusal.agent_code/1`
                # is what decides whether an agent may read it.
                refuse(code, Core.near_miss(grants, cap, resource, ctx, retired?), detail,
                  requires_human: true)

              g ->
                pl = Core.derive_placement(pk, g, ctx)

                cond do
                  pl["ok"] != true ->
                    Map.put(
                      refuse("placement-denied", pl["reason"], %{"capability" => cap, "cited" => pl["cited"]}),
                      "placement", pl)

                  decl["approval"] == "every_effect" ->
                    approval_path(cap, resource, ctx, params_or_nil, pk, g, pl, mode)

                  true ->
                    req = params_or_nil || %{}

                    %{"allow" => true, "grant_ref" => g["id"],
                      "one_shot" => g["duration"] == "once", "placement" => pl,
                      "authority_snapshot_at_entry" => GrantRegistry.snapshot(),
                      "effect_key" =>
                        Core.effect_key(cap, resource, req["er"] || "er-" <> cap,
                          req["rev"] || 1, req["params"])}
                end
            end
        end
    end
  end

  defp approval_path(cap, resource, ctx, request, pk, g, pl, mode) do
    if request == nil or request["params"] == nil do
      refuse("request-missing",
        "request-missing · approval-class effects need an explicit intent — nothing hashes an empty request",
        %{"capability" => cap})
    else
      # Sampled once, before anything can be consumed: this is the
      # authority the effect is authorized *under*, and the value the
      # receipt must attest to.
      snapshot = GrantRegistry.snapshot()
      er = request["er"] || "er-" <> cap
      rev = request["rev"] || 1

      # What should happen — stable across authority churn *and* across
      # restore. `effect-intent@1` deliberately carries no world lineage:
      # the external world deduplicates on it, and an effect that survived
      # a recovery is still the same effect.
      ek = Core.effect_key(cap, resource, er, rev, request["params"])

      # Why this actor may make it happen now — bound to everything that
      # could change the answer, *including which world is answering*.
      #
      # SEALED is a discontinuity in trusted world knowledge. Consent given
      # before that discontinuity must never quietly become live after it:
      # the human approved one exact intent under an authority snapshot
      # that a restored world can no longer re-derive. Binding the lineage
      # into the digest makes "world lineage changed → prior consent is
      # stale" fall out of the existing exact-match, with no rule of its
      # own to forget to apply.
      #
      # This is the first field `approval-intent@1` carries that the frozen
      # browser simulator cannot produce — a page has no durable world, so
      # it has no lineage to bind. See `Ampd.WorldLineageTest` for the
      # assertion that pins the divergence to exactly these two fields.
      lin = Ampd.World.lineage() || %{}

      env = %{"schema" => "approval-intent@1",
              "effect_key" => ek,
              "pack" => Core.pack_of(cap) <> "@" <> pk["version"],
              "capability" => cap, "actor" => ctx["actor"], "resource" => resource,
              "grant" => g["id"], "authority_snapshot" => snapshot,
              "placement" => pl["site"],
              "world_installation_id" => lin["installation_id"],
              "world_generation" => lin["generation"],
              "request_id" => er, "request_revision" => rev,
              "request" => request["params"]}

      h = Core.intent_digest(env)

      exact = Enum.find(Approvals.all(), fn a ->
        a["status"] == "granted" and a["request_hash"] == h and
          a["capability"] == cap and a["actor"] == ctx["actor"] and
          a["grant_ref"] == g["id"] and a["pack_version"] == pk["version"] and
          a["snapshot"] == snapshot and a["placement"] == pl["site"] and
          a["world_installation_id"] == lin["installation_id"] and
          a["world_generation"] == lin["generation"]
      end)

      if exact do
        %{"allow" => true, "grant_ref" => g["id"], "approval_ref" => exact["id"],
          "request_hash" => h, "effect_key" => ek,
          "one_shot" => g["duration"] == "once", "placement" => pl,
          "authority_snapshot_at_entry" => snapshot, "intent_envelope" => env}
      else
        if mode == :preflight do
          # Eligible, but consent for this exact intent does not exist yet.
          # Reporting that is the whole job — opening the proposal belongs
          # to `request_effect`, and happens inside the order.
          Map.merge(
            refuse("approval-required",
              "approval-required · consent for this exact intent does not exist yet",
              %{"capability" => cap}, requires_human: true),
            %{"requires_approval" => true,
              "grant_ref" => g["id"], "request_hash" => h, "effect_key" => ek,
              "placement" => pl, "authority_snapshot_at_entry" => snapshot}
          )
        else
          Approvals.all()
          |> Enum.filter(fn a ->
            a["status"] == "granted" and a["grant_ref"] == g["id"] and
              a["capability"] == cap and get_in(a, ["envelope", "request_id"]) == er and
              a["request_hash"] != h
          end)
          |> Enum.each(fn a -> Approvals.mark(a["id"], "stale", "proposal revised since consent") end)

          pend =
            Enum.find(Approvals.all(), fn a -> a["status"] == "pending" and a["request_hash"] == h end) ||
              Approvals.new_pending(%{"request_hash" => h, "grant_ref" => g["id"],
                "capability" => cap, "actor" => ctx["actor"], "pack_version" => pk["version"],
                "snapshot" => snapshot, "placement" => pl["site"], "envelope" => env,
                "world_installation_id" => lin["installation_id"],
                "world_generation" => lin["generation"],
                "resource" => resource, "held_ctx" => ctx})

          %{"allow" => false, "held" => true, "approval_id" => pend["id"],
            "grant_ref" => g["id"], "request_hash" => h, "effect_key" => ek,
            "placement" => pl, "authority_snapshot_at_entry" => snapshot}
        end
      end
    end
  end

  # ------------------------------------------------------------- consume
  @doc false
  # Not a product entry point: consuming without a durable claim in front
  # of it is the C1.0a shape C1.0b replaced. `Ampd.Authority` calls this
  # once the claim is journalled; `Ampd.Conformance.authorize/4` calls it
  # to keep the frozen vectors runnable, and says why.
  def consume!(auth) do
    if auth["approval_ref"], do: Approvals.mark(auth["approval_ref"], "consumed")
    if auth["one_shot"], do: GrantRegistry.consume_one_shot(auth["grant_ref"])
    :ok
  end

  # ------------------------------------------------------------- perform
  @doc """
  The effect path. Ordering is the point:

      propose → decide → AUTHORIZED → **CLAIMED (durable)** → consume
              → **ATTEMPTED (durable)** → adapter → COMMITTED + receipt

  The claim is durable before consent is consumed, and the attempt is
  durable before the world is touched — so a crash anywhere leaves a
  journal entry that names what was intended, instead of a half-applied
  registry nobody can interpret.

  `adapter` is a 1-arity function; with no connectors yet the default does
  nothing and returns `nil`. That is the only simulated part of this path.
  """
  def perform(cap, resource, ctx, request, adapter \\ fn _ -> nil end) do
    # Decide + journal + claim + consume happen as one ordered step. The
    # adapter deliberately runs *outside* the order: it may be slow or
    # remote, and holding the authority lock across the network would make
    # every revocation wait on a stranger's TCP timeout. The lease taken at
    # CLAIM is what makes that safe.
    case Ampd.Authority.claim_and_consume(cap, resource, ctx, request) do
      # **Two different `{:refused, _}` meanings collide here, and only one
      # of them is a verdict.**
      #
      # `claim_and_consume/4` answers `{:refused, authorization@1}` when the
      # gateway decided no — a verdict, already shaped like a result, and
      # already safe to hand to an agent. But `Ampd.Authority.tx/1` can
      # refuse *before* the function ever runs, with a `refusal@1`: a sealed
      # store, an unordered mutation, or the world-incarnation fence. Those
      # arrive through the same tuple.
      #
      # Passing a `refusal@1` through as though it were a verdict produced a
      # result with no `allow` key and, worse, with `operator_detail` still
      # on it — `Ampd.Refusal.project_result/2` only projects a map that has
      # a `"refusal"` key, so a bare one sails past the dual-disclosure
      # boundary untouched. Measured on a fenced `request_effect`: the agent
      # received `expected_generation`, `current_generation` and
      # `discontinuity`, which is exactly the topology it is never supposed
      # to learn.
      #
      # This shipped in F.8.2.4. Its battery could not have caught it: the
      # only witness for the fence used `request_grant`, and every command
      # except this one is normalized by `Ampd.Control.settled/2`. Same
      # normalization, at the one call site that does not go through it.
      {:refused, %{"schema" => "refusal@1"} = r} ->
        %{"allow" => false, "reason" => r["public_message"], "refusal" => r}

      {:refused, auth} ->
        auth

      {:claimed, auth, e} ->
        {:ok, _e2, attempt} = Effects.attempt(e["id"], "none · no connector installed (C1.0b)")

        try do
          result = adapter.(attempt)
          Effects.commit(e["id"], result)
          rcpt = emit_receipt(cap, auth, e["id"], attempt, ctx)
          Map.merge(auth, %{"effect_id" => e["id"], "receipt" => rcpt})
        rescue
          err ->
            Effects.unknown(e["id"], "adapter raised: #{Exception.message(err)}")

            Map.merge(auth, %{"allow" => false, "effect_id" => e["id"],
              "reason" => "effect-unknown · the adapter raised after ATTEMPTED was durable — outcome unresolved"})
        end
    end
  end

  # ------------------------------------------------------------- receipt
  # `authority_snapshot_at_entry` is the value that authorized the effect;
  # `authority_snapshot_after` is what the world looks like once the
  # effect's own consumption has landed. A one-shot moves between them,
  # and the pair is the evidence: X authorized this, the effect consumed
  # its use, Y is what remains.
  defp emit_receipt(cap, auth, effect_id, attempt, ctx) do
    pk = Core.pack_of(cap)
    pv = (CapabilityRegistry.get(pk) || %{})["version"] || "0"

    # `actor` is on the receipt so a receipt can be projected to the actor
    # it belongs to. Without it the ledger is all-or-nothing: either every
    # agent reads every receipt on the machine, or none reads its own.
    Receipts.emit(%{"actor" => ctx["actor"], "capability" => cap, "pack" => pk <> "@" <> pv,
      "grant_ref" => auth["grant_ref"], "approval_ref" => auth["approval_ref"],
      "approval_digest" => auth["request_hash"], "placement" => auth["placement"],
      "effect_ref" => effect_id,
      "effect_key" => auth["effect_key"],
      "idempotency_key" => attempt["idempotency_key"],
      "authority_snapshot_at_entry" => auth["authority_snapshot_at_entry"],
      "authority_snapshot_after" => GrantRegistry.snapshot(),
      "secret_material_exposed_to_engine" => false})
  end
end
