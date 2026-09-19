defmodule Ampd.Effects.Contract do
  @moduledoc """
  The substrate's copy of E3-1 — `wek/r3/contract.mjs` as Elixir data and
  pure functions.

  The verifier replays a trace through *its* copy and compares every
  verdict and every listing against what this copy produced. The two are
  kept in step by that comparison, not by trust: a divergence is a
  `disagreement` finding that fails the case. Nothing here reads a
  process, a store or a clock — every function takes the journal records
  and store rows it needs and returns a value.

  `authorize/6` is the journal owner's decision and checks in the ONE
  refusal order (`REFUSAL_ORDER`). `listing/2` is the read-only recovery
  listing (`classify()` + `listingOf()`), computed over the journal as
  found and the three participant stores as read.
  """

  @participants ~w(approvals grant_registry receipts)
  @stores ~w(grant_registry approvals receipts session capability_registry effects loci worktrees)

  @branches %{
    "B1" => %{
      "approval_bound" => false,
      "one_shot" => false,
      "declared" => ~w(receipts),
      "required_at_claim" => [],
      "required_on_commit" => ~w(receipts)
    },
    "B2" => %{
      "approval_bound" => false,
      "one_shot" => true,
      "declared" => ~w(grant_registry receipts),
      "required_at_claim" => ~w(grant_registry),
      "required_on_commit" => ~w(receipts)
    },
    "B3" => %{
      "approval_bound" => true,
      "one_shot" => false,
      "declared" => ~w(approvals receipts),
      "required_at_claim" => ~w(approvals),
      "required_on_commit" => ~w(receipts)
    },
    "B4" => %{
      "approval_bound" => true,
      "one_shot" => true,
      "declared" => ~w(approvals grant_registry receipts),
      "required_at_claim" => ~w(approvals grant_registry),
      "required_on_commit" => ~w(receipts)
    }
  }

  @ops %{
    "consume_approval" => "approvals",
    "consume_grant" => "grant_registry",
    "emit_receipt" => "receipts"
  }
  @op_of_store %{
    "approvals" => "consume_approval",
    "grant_registry" => "consume_grant",
    "receipts" => "emit_receipt"
  }

  # journal phase × op → "permitted" | refusal code
  @permissions %{
    "pre-claim" => %{
      "consume_approval" => "write-not-yet-permitted",
      "consume_grant" => "write-not-yet-permitted",
      "emit_receipt" => "write-not-yet-permitted"
    },
    "claimed" => %{
      "consume_approval" => "permitted",
      "consume_grant" => "permitted",
      "emit_receipt" => "write-not-yet-permitted"
    },
    "attempted" => %{
      "consume_approval" => "write-phase-closed",
      "consume_grant" => "write-phase-closed",
      "emit_receipt" => "write-not-yet-permitted"
    },
    "committed" => %{
      "consume_approval" => "write-phase-closed",
      "consume_grant" => "write-phase-closed",
      "emit_receipt" => "permitted"
    },
    "closed" => %{
      "consume_approval" => "write-lease-closed",
      "consume_grant" => "write-lease-closed",
      "emit_receipt" => "write-lease-closed"
    }
  }

  @transitions %{
    nil => ~w(PROPOSED),
    "PROPOSED" => ~w(AUTHORIZED),
    "AUTHORIZED" => ~w(APPROVED CLAIMED),
    "APPROVED" => ~w(CLAIMED),
    "CLAIMED" => ~w(ATTEMPTED FAILED UNKNOWN),
    "ATTEMPTED" => ~w(COMMITTED FAILED UNKNOWN),
    "COMMITTED" => ~w(FAILED UNKNOWN),
    "FAILED" => [],
    "UNKNOWN" => []
  }

  def participants, do: @participants
  def authority_stores, do: @stores
  def branches, do: @branches
  def ops, do: Map.keys(@ops)
  def store_of(op), do: @ops[op]
  def op_of_store(store), do: @op_of_store[store]
  def branch?(b), do: Map.has_key?(@branches, b)

  @doc "`decide/4`'s two booleans name the branch; nothing else does."
  def branch_of(approval_bound?, one_shot?) do
    case {approval_bound? == true, one_shot? == true} do
      {false, false} -> "B1"
      {false, true} -> "B2"
      {true, false} -> "B3"
      {true, true} -> "B4"
    end
  end

  @doc "The three declaration sets, DERIVED from the branch — never supplied."
  def sets(branch) do
    case @branches[branch] do
      nil -> %{"declared" => [], "required_at_claim" => [], "required_on_commit" => []}
      b -> Map.take(b, ~w(declared required_at_claim required_on_commit))
    end
  end

  def required_ops(branch) do
    s = sets(branch)
    Enum.map(s["required_at_claim"] ++ s["required_on_commit"], &@op_of_store[&1])
  end

  def legal_transition?(from, to), do: to in Map.get(@transitions, from, [])

  # ---------------------------------------------------------------- phase
  def has?(e, state), do: Enum.any?(e["history"] || [], &(&1["state"] == state))

  def phase(e) do
    cond do
      has?(e, "FAILED") or has?(e, "UNKNOWN") -> "closed"
      has?(e, "COMMITTED") -> "committed"
      has?(e, "ATTEMPTED") -> "attempted"
      has?(e, "CLAIMED") -> "claimed"
      true -> "pre-claim"
    end
  end

  @doc "The state the effect was in when the incarnation died: the state before the first `crashed while …` entry, or nil."
  def crash_phase(e) do
    h = e["history"] || []

    case Enum.find_index(h, &String.starts_with?(&1["reason"] || "", "crashed while ")) do
      nil -> nil
      0 -> nil
      i -> Enum.at(h, i - 1)["state"]
    end
  end

  def target_of(e, "consume_approval"), do: e["approval_ref"]
  def target_of(e, "consume_grant"), do: e["grant_ref"]
  def target_of(e, "emit_receipt"), do: e["id"]

  # ------------------------------------------------------------ authorize
  @doc """
  The journal owner's verdict, in `REFUSAL_ORDER`. `leases` is the owner's
  table (`lease_id → %{effect, epoch, branch, done, retired}`), `effect_of`
  resolves an effect id to its journal record, and `token_ok?` is the
  owner's check that the presented lease VALUE was minted by it (the
  value alone proves nothing; a reconstructed value is R4).
  """
  def authorize(epoch, leases, effect_of, token, op, target, token_ok?) do
    cond do
      not is_map(token) or not is_binary(token["lease_id"]) ->
        {:refused, "write-unmediated"}

      token["epoch"] != epoch ->
        {:refused, "write-lease-stale"}

      not token_ok?.(token) ->
        {:refused, "write-unmediated"}

      true ->
        case Map.get(leases, token["lease_id"]) do
          nil -> {:refused, "write-unmediated"}
          %{retired: "completed"} -> {:refused, "write-lease-retired"}
          %{retired: "closed"} -> {:refused, "write-lease-closed"}
          lease -> authorize_live(lease, effect_of.(lease.effect), op, target)
        end
    end
  end

  defp authorize_live(lease, e, op, target) do
    sets = sets(lease.branch)

    cond do
      e == nil -> {:refused, "write-unmediated"}
      not Map.has_key?(@ops, op) -> {:refused, "write-undeclared"}
      target != target_of(e, op) -> {:refused, "write-unscoped"}
      @ops[op] not in sets["declared"] -> {:refused, "write-undeclared"}
      (perm = @permissions[phase(e)][op]) != "permitted" -> {:refused, perm}
      MapSet.member?(lease.done, op) -> {:refused, "write-duplicate"}
      true -> {:ok, lease}
    end
  end

  # ------------------------------------------------------------- listing
  @doc """
  The read-only recovery listing over the journal as found and the stores
  as read. `stores` is `%{"approvals" => rows, "grants" => rows, "receipts" => rows}`.
  Late landings never appear here: the substrate prevents them; the
  verifier derives its own from the trace and compares.
  """
  def listing(effects, stores) do
    effects
    |> Enum.filter(&(&1["state"] in ~w(CLAIMED ATTEMPTED COMMITTED UNKNOWN)))
    |> Map.new(fn e ->
      row =
        Enum.reduce(@participants, %{"crash_phase" => crash_phase(e)}, fn p, acc ->
          Map.put(acc, p, classify(e, stores, p))
        end)

      {e["id"], row}
    end)
  end

  def classify(e, stores, p) do
    sets = sets(e["branch"])

    applicability =
      if p != "receipts" do
        cond do
          p not in sets["required_at_claim"] -> "NOT_REQUIRED"
          not has?(e, "CLAIMED") -> "NOT_YET_OWED"
          true -> :owed
        end
      else
        cond do
          "receipts" not in sets["required_on_commit"] -> "NOT_REQUIRED"
          has?(e, "COMMITTED") -> :owed
          has?(e, "FAILED") -> "NOT_OWED"
          has?(e, "ATTEMPTED") -> "INDETERMINATE"
          true -> "NOT_YET_OWED"
        end
      end

    case applicability do
      :owed -> decide(e, stores, p)
      outcome -> outcome
    end
  end

  defp decide(e, stores, "receipts") do
    rows = Enum.filter(stores["receipts"] || [], &(&1["effect_ref"] == e["id"]))

    cond do
      length(rows) > 1 -> "CONFLICT(duplicate-receipt)"
      length(rows) == 1 -> "COMPLETE"
      true -> "MISSING"
    end
  end

  defp decide(e, stores, "approvals") do
    case Enum.find(stores["approvals"] || [], &(&1["id"] == e["approval_ref"])) do
      nil ->
        "CONFLICT(absent-record)"

      a ->
        cond do
          not Map.has_key?(a, "consumed_by") ->
            "LEGACY_UNWITNESSED"

          has?(e, "ATTEMPTED") and a["consumed_by"] != e["id"] ->
            "CONFLICT(sequencing-violated)"

          a["status"] == "consumed" and a["consumed_by"] == nil ->
            "CONFLICT(unbound-consumption)"

          a["consumed_by"] != nil and a["consumed_by"] != e["id"] ->
            "CONFLICT(foreign-consumption)"

          a["consumed_by"] == e["id"] and a["status"] != "consumed" ->
            "CONFLICT(status-witness-disagree)"

          a["status"] == "consumed" and a["consumed_by"] == e["id"] ->
            "COMPLETE"

          true ->
            "MISSING"
        end
    end
  end

  defp decide(e, stores, "grant_registry") do
    case Enum.find(stores["grants"] || [], &(&1["id"] == e["grant_ref"])) do
      nil ->
        "CONFLICT(absent-record)"

      g ->
        cs = g["consumptions"]
        once? = g["duration"] == "once"

        cond do
          not Map.has_key?(g, "consumptions") ->
            "LEGACY_UNWITNESSED"

          has?(e, "ATTEMPTED") and e["id"] not in cs ->
            "CONFLICT(sequencing-violated)"

          g["uses_remaining"] == 0 and cs == [] ->
            "CONFLICT(unbound-consumption)"

          cs != [] and e["id"] not in cs ->
            "CONFLICT(foreign-consumption)"

          once? and length(cs) > 1 ->
            "CONFLICT(over-consumed)"

          once? and e["id"] in cs and (g["uses_remaining"] != 0 or g["status"] != "consumed") ->
            "CONFLICT(status-witness-disagree)"

          cs == [e["id"]] and g["uses_remaining"] == 0 and g["status"] == "consumed" ->
            "COMPLETE"

          true ->
            "MISSING"
        end
    end
  end
end
