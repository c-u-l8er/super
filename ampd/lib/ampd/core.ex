defmodule Ampd.Core do
  @moduledoc """
  Pure parity core. Every function here mirrors the frozen JS simulator
  byte-for-byte where it matters: canonicalization, digests, placement
  derivation, refusal strings. The conformance vectors are the contract.
  """

  @sites ["local", "fleet", "cloud"]
  def sites, do: @sites

  def params do
    %{"pr.draft"  => %{"repo" => "traaviis/trvm", "branch" => "lane-a", "title" => "close the argv boundary"},
      "pr.create" => %{"repo" => "traaviis/trvm", "branch" => "lane-a", "title" => "close the argv boundary"}}
  end

  # ---------- canonical form: JS JSON.stringify parity ----------
  def canon(v) when is_map(v) do
    inner =
      v |> Map.keys() |> Enum.sort()
        |> Enum.map(fn k -> jstr(k) <> ":" <> canon(Map.get(v, k)) end)
        |> Enum.join(",")
    "{" <> inner <> "}"
  end
  def canon(v) when is_list(v), do: "[" <> Enum.map_join(v, ",", &canon/1) <> "]"
  def canon(true), do: "true"
  def canon(false), do: "false"
  def canon(nil), do: "null"
  def canon(v) when is_integer(v), do: Integer.to_string(v)
  def canon(v) when is_binary(v), do: jstr(v)

  defp jstr(s) do
    body =
      s |> String.to_charlist()
        |> Enum.map(fn
          ?"  -> "\\\""
          ?\\ -> "\\\\"
          ?\n -> "\\n"
          ?\r -> "\\r"
          ?\t -> "\\t"
          8   -> "\\b"
          12  -> "\\f"
          c when c < 0x20 -> "\\u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0")
          c -> <<c::utf8>>
        end)
        |> IO.iodata_to_binary()
    "\"" <> body <> "\""
  end

  def sha256_hex(msg), do: :crypto.hash(:sha256, msg) |> Base.encode16(case: :lower)
  def intent_digest(env), do: "sha256:" <> sha256_hex(canon(env))

  # ---------- effect identity ≠ consent identity ----------
  # `effect-intent@1` says *what should happen*. `approval-intent@1` says
  # *why this actor may make it happen now* — and embeds the effect key.
  #
  # They must be separate because the external world deduplicates on the
  # first and Super reasons about the second. If the idempotency key
  # carried the authority snapshot, then an UNKNOWN effect reconciled after
  # an unrelated grant change would present the far side with a *different*
  # key for the same desired effect — and deduplicate against nothing.
  def effect_intent(cap, resource, er, rev, params) do
    %{"schema" => "effect-intent@1", "capability" => cap, "resource" => resource,
      "request_id" => er, "request_revision" => rev, "request" => params}
  end

  def effect_key(cap, resource, er, rev, params),
    do: "sha256:" <> sha256_hex(canon(effect_intent(cap, resource, er, rev, params)))

  # ---------- placement is derived, not asserted ----------
  def pack_policy_deny(pack, site) do
    pol = Map.get(pack, "policy", %{})
    cond do
      site == "cloud" and Map.get(pol, "source_data") == "private" ->
        "data-policy: source_data private — hosted cloud excluded"
      is_map(pol["secret"]) and not Enum.member?(pol["secret"]["residency"] || @sites, site) ->
        "secret " <> pol["secret"]["ref"] <> " residency: " <> Enum.join(pol["secret"]["residency"], "·")
      true -> nil
    end
  end

  def derive_placement(pack, g, ctx) do
    gsites = Map.get(g, "placement", ["local", "fleet"])
    {eligible, denied} =
      Enum.reduce(@sites, {[], %{}}, fn site, {el, dn} ->
        pd = pack_policy_deny(pack, site)
        ge = Enum.member?(gsites, site)
        cond do
          pd != nil ->
            cause = pd <> if(ge, do: "", else: " · grant " <> g["id"] <> " eligibility: " <> Enum.join(gsites, "·"))
            {el, Map.put(dn, site, cause)}
          not ge ->
            {el, Map.put(dn, site, "grant " <> g["id"] <> " eligibility: " <> Enum.join(gsites, "·"))}
          true -> {el ++ [site], dn}
        end
      end)
    cited =
      ["grant " <> g["id"] <> " eligibility: " <> Enum.join(gsites, "·")] ++
        Enum.map(denied, fn {k, v} -> k <> " denied: " <> v end)
    req = ctx["placement"]
    cond do
      is_binary(req) and not Enum.member?(eligible, req) ->
        %{"ok" => false, "cited" => cited,
          "reason" => "placement-denied · " <> req <> " — " <> Map.get(denied, req, "ineligible for this grant")}
      is_binary(req) -> %{"ok" => true, "site" => req, "cited" => cited}
      eligible == [] -> %{"ok" => false, "cited" => cited, "reason" => "placement-denied · no eligible site"}
      true -> %{"ok" => true, "site" => hd(eligible), "cited" => cited}
    end
  end

  # ---------- grant matching + named near-misses ----------
  @durations ~w(once run agent workspace)

  @doc """
  The closed set of grant durations, narrowest first.

  It has to be closed, and it has to be ordered.

  **Closed**, because the last clause used to be `_ -> true`: any string at
  all satisfied every scope check there is. A grant minted with duration
  `"forever"` outlived its run, survived a workspace change, and never
  spent a use — an unbounded grant produced by a typo, or by an agent
  asking for one and a human clicking approve.

  **Ordered**, because a human answering an agent's request may only
  *narrow* it. Widening a request into something broader than what was
  asked for is not an approval of that request; it is a new grant the
  person authored, and it should have to say so.

  `agent` is the widest: it checks actor equality and nothing else. `once`
  is the narrowest — unscoped, but spent on first use.
  """
  def durations, do: @durations

  def duration_rank(d), do: Enum.find_index(@durations, &(&1 == d))

  @doc "True when `d` is a duration this system can enforce."
  def duration?(d), do: d in @durations

  def duration_ok(g, ctx, retired?) do
    case g["duration"] do
      "once" -> (g["uses_remaining"] || 0) > 0
      "run" -> g["run"] == ctx["run"] and not retired?.(g["run"])
      "workspace" -> g["workspace"] == ctx["workspace"]
      "agent" -> true
      # Not a duration. A grant carrying one cannot be enforced, so it
      # cannot be honoured — refusing here means even a grant that got
      # past minting (an older store, a hand-edited dets) is inert.
      _ -> false
    end
  end

  def grant_for(grants, cap, resource, ctx, retired?) do
    Enum.find(grants, fn g ->
      g["status"] == "active" and g["capability"] == cap and
        g["actor"] == ctx["actor"] and g["resource"] == resource and
        duration_ok(g, ctx, retired?)
    end)
  end

  def near_miss(grants, cap, resource, ctx, retired?) do
    c = Enum.filter(grants, fn g -> g["status"] == "active" and g["capability"] == cap end)
    cond do
      c == [] -> "authority-missing · " <> cap
      not Enum.any?(c, &(&1["actor"] == ctx["actor"])) ->
        "actor-mismatch · grant is not " <> ctx["actor"] <> "'s"
      not Enum.any?(c, &(&1["resource"] == resource)) ->
        "scope-mismatch · grant is for " <> hd(c)["resource"] <> ", not " <> resource
      not Enum.any?(c, &duration_ok(&1, ctx, retired?)) ->
        case hd(c)["duration"] do
          "once" -> "one-shot-consumed · " <> cap
          "run" -> "run-expired · grant was scoped to " <> hd(c)["run"]
          _ -> "workspace-mismatch · grant lives in " <> hd(c)["workspace"]
        end
      true -> "authority-missing · " <> cap
    end
  end

  @doc """
  The same near-miss decision as `near_miss/5`, as a class and a
  comparison instead of a sentence.

  `near_miss/5` returns the exact string the frozen simulator returns, and
  must keep doing so — it is what the conformance vectors match on. But
  that string *is* the near-miss: `"scope-mismatch · grant is for
  traaviis/trvm, not other/repo"` tells a caller with no authority at all
  the name of a resource somebody else may reach. Splitting the class from
  the comparison lets the channel projection redact one and keep the
  other, instead of choosing between a useful refusal and a safe one.
  """
  def near_miss_class(grants, cap, resource, ctx, retired?) do
    c = Enum.filter(grants, fn g -> g["status"] == "active" and g["capability"] == cap end)

    cond do
      c == [] ->
        {"authority-missing", %{"capability" => cap}}

      not Enum.any?(c, &(&1["actor"] == ctx["actor"])) ->
        # Told apart from authority-missing this says "someone else holds
        # it", so the agent projection collapses the two — see
        # `Ampd.Refusal.new/2`'s `public_code`.
        {"actor-mismatch",
         %{"capability" => cap, "asked_as" => ctx["actor"], "held_by" => hd(c)["actor"]}}

      not Enum.any?(c, &(&1["resource"] == resource)) ->
        {"scope-mismatch",
         %{"capability" => cap, "requested" => resource, "grant_resource" => hd(c)["resource"]}}

      not Enum.any?(c, &duration_ok(&1, ctx, retired?)) ->
        case hd(c)["duration"] do
          "once" -> {"one-shot-consumed", %{"capability" => cap}}
          "run" -> {"run-expired", %{"capability" => cap, "grant_run" => hd(c)["run"]}}
          _ -> {"workspace-mismatch", %{"capability" => cap, "grant_workspace" => hd(c)["workspace"]}}
        end

      true ->
        {"authority-missing", %{"capability" => cap}}
    end
  end

  def snapshot_of(grants, packs) do
    gs =
      grants
      |> Enum.filter(&(&1["status"] == "active"))
      |> Enum.map(fn g ->
        %{"id" => g["id"], "actor" => g["actor"], "capability" => g["capability"],
          "resource" => g["resource"], "duration" => g["duration"],
          "placement" => g["placement"], "workspace" => g["workspace"], "run" => g["run"],
          "uses_remaining" => Map.get(g, "uses_remaining", nil)}
      end)
      |> Enum.sort_by(& &1["id"])
    env = %{"schema" => "authority-snapshot@1", "grants" => gs,
      "pack_versions" => Map.new(packs, fn {k, p} -> {k, Map.get(p, "version", nil)} end),
      "policies" => Map.new(packs, fn {k, p} -> {k, Map.get(p, "policy", nil)} end)}
    "sha256:" <> sha256_hex(canon(env))
  end

  @doc """
  A digest over the **authority-relevant** part of a pack.

  Version, declared surface, and policy — the three things that decide what
  a capability reaches and where its data may go. Not the display fields,
  and not `installation`: whether a pack is installed is checked directly
  at mint and at the gateway, and folding it in here would make every
  install and uninstall look like a contract change.

  This is what a pending `grant-request@1` binds to, so that a request made
  under GitHub 1.5 cannot be approved after 2.0 redefined the capability
  the human is reading the name of.
  """
  def pack_digest(pack) when is_map(pack) do
    env = %{
      "schema" => "pack-contract@1",
      "version" => Map.get(pack, "version"),
      "surface" => Map.get(pack, "surface", %{}),
      "policy" => Map.get(pack, "policy")
    }

    "sha256:" <> sha256_hex(canon(env))
  end

  def pack_of(cap), do: cap |> String.split(".") |> hd()
  def cap_key(cap), do: cap |> String.split(".", parts: 2) |> List.last()
end
