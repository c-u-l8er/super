defmodule Ampd.ConformanceTest do
  @moduledoc """
  Runs the language-neutral authority vectors exported from the frozen JS
  simulator. Passing here means the BEAM runtime and the simulator agree
  on every refusal, hold, receipt, placement, and digest.
  """
  use ExUnit.Case, async: false
  alias Ampd.{Core, CapabilityRegistry, GrantRegistry, Approvals, Receipts, Gateway}

  {doc, _} = Code.eval_file("test/fixtures/vectors.exs")
  @doc_fixture doc

  defp step(acc, ["install_pack", "postgres"]) do
    Ampd.Authority.install_postgres(); acc
  end
  defp step(acc, ["mint", m]) do
    if m["duration"] == "once" do
      Ampd.Authority.one_shot(m["cap"])
    else
      Ampd.Authority.mint(%{"capability" => m["cap"],
        "duration" => m["duration"] || "workspace",
        "resource" => m["resource"] || "traaviis/trvm"})
    end
    acc
  end
  defp step(acc, ["revoke_domain", cap]), do: (Ampd.Authority.revoke_domain(cap); acc)
  defp step(acc, ["draft", k, v]), do: (Ampd.Authority.set_draft(k, v); acc)
  defp step(acc, ["dur", d]), do: (Ampd.Authority.set_dur(d); acc)
  defp step(acc, ["commit"]) do
    Ampd.Authority.commit(CapabilityRegistry.get("github")["surface"]); acc
  end
  defp step(acc, ["world", w]), do: (Ampd.Authority.set_world(w); acc)
  defp step(acc, ["end_run"]), do: %{acc | last_retired: Ampd.Authority.end_run()}
  defp step(acc, ["update_github"]), do: (Ampd.Authority.update_github(); acc)
  defp step(acc, ["forge_pr_create", over]), do: (Ampd.Conformance.forge_pr_create(over); acc)
  defp step(acc, ["auth", a]) do
    over = a["ctx"] || %{}
    ctx = Map.merge(Gateway.ctx(), over)
    ctx = if over["run"] == "RETIRED", do: Map.put(ctx, "run", acc.last_retired), else: ctx
    request =
      case a["params"] do
        "PR_CREATE" ->
          %{"er" => "er-github.pr.create", "rev" => 1, "params" => Core.params()["pr.create"]}
        %{"er" => _} = r -> r
        nil -> nil
        other -> %{"er" => "er-" <> a["cap"], "rev" => 1, "params" => other}
      end
    %{acc | last: Ampd.Conformance.authorize(a["cap"], a["resource"], ctx, request)}
  end
  defp step(acc, ["exercise", cap_short]), do: (Ampd.Conformance.exercise(cap_short); %{acc | last: nil})
  defp step(acc, ["approve_last"]), do: (Ampd.Conformance.approve_last(); acc)
  defp step(acc, ["digest", "ENV"]),
    do: %{acc | digest: Core.intent_digest(@doc_fixture["digest_env"])}
  defp step(acc, ["effect_key", name]) do
    ek = Core.effect_key("github.pr.draft", "traaviis/trvm", "er-github.pr.draft", 1,
           Core.params()["pr.draft"])
    %{acc | eks: Map.put(acc.eks, name, ek)}
  end
  defp step(acc, ["effect_key_of", "FIXED"]) do
    e = @doc_fixture["effect_env"]
    %{acc | ekfix: Core.effect_key(e["capability"], e["resource"], e["request_id"],
                     e["request_revision"], e["request"])}
  end
  defp step(acc, ["snap", name]),
    do: %{acc | snaps: Map.put(acc.snaps, name, GrantRegistry.snapshot())}
  defp step(acc, ["snapshot_of", "FIXED"]),
    do: %{acc | snapfix: Core.snapshot_of(@doc_fixture["snap_list"], CapabilityRegistry.all())}
  defp step(acc, ["approve_hold"]) do
    case Approvals.last_pending() do
      nil -> acc
      p -> Ampd.Authority.grant_approval(p["id"]); acc
    end
  end

  defp check!(name, expect, acc) do
    last = acc.last
    approvals = Approvals.all()
    pending = Enum.count(approvals, &(&1["status"] == "pending"))
    last_ap = List.last(approvals)
    rx = fn pat, str -> str != nil and Regex.match?(Regex.compile!(pat), str) end

    if Map.has_key?(expect, "allow"),
      do: assert(last != nil and last["allow"] == expect["allow"],
            "#{name}: allow=#{inspect(last && last["allow"])} want #{expect["allow"]} (#{inspect(last && last["reason"])})")
    if expect["held"] == true,
      do: assert(pending >= 1, "#{name}: expected a pending approval (held)")
    if Map.has_key?(expect, "reason"),
      do: assert(rx.(expect["reason"], last && last["reason"]),
            "#{name}: reason #{inspect(last && last["reason"])} !~ #{expect["reason"]}")
    if Map.has_key?(expect, "reason_also"),
      do: assert(rx.(expect["reason_also"], last && last["reason"]),
            "#{name}: reason #{inspect(last && last["reason"])} !~ #{expect["reason_also"]}")
    if Map.has_key?(expect, "receipts"),
      do: assert(Receipts.count() == expect["receipts"],
            "#{name}: receipts=#{Receipts.count()} want #{expect["receipts"]}")
    if Map.has_key?(expect, "pending"),
      do: assert(pending == expect["pending"],
            "#{name}: pending=#{pending} want #{expect["pending"]}")
    if Map.has_key?(expect, "last_approval"),
      do: assert(last_ap != nil and last_ap["status"] == expect["last_approval"],
            "#{name}: last approval #{inspect(last_ap && last_ap["status"])} want #{expect["last_approval"]}")
    if Map.has_key?(expect, "has_stale"),
      do: assert(Enum.any?(approvals, &(&1["status"] == "stale")) == expect["has_stale"],
            "#{name}: stale presence mismatch")
    if Map.has_key?(expect, "stale_reason") do
      st = Enum.find(Enum.reverse(approvals), &(&1["status"] == "stale"))
      assert(st != nil and rx.(expect["stale_reason"], st["stale_reason"]),
        "#{name}: stale_reason #{inspect(st && st["stale_reason"])} !~ #{expect["stale_reason"]}")
    end
    if Map.has_key?(expect, "placement_site"),
      do: assert(last != nil and last["placement"]["site"] == expect["placement_site"],
            "#{name}: placement site #{inspect(last && last["placement"] && last["placement"]["site"])}")
    if Map.has_key?(expect, "cited"),
      do: assert(last != nil and Enum.any?(last["placement"]["cited"], &rx.(expect["cited"], &1)),
            "#{name}: no cited line matches #{expect["cited"]}")
    if Map.has_key?(expect, "granted_count"),
      do: assert(Enum.count(approvals, &(&1["status"] == "granted")) == expect["granted_count"],
            "#{name}: granted count mismatch")
    if Map.has_key?(expect, "snap_hex"),
      do: assert(rx.("^sha256:[0-9a-f]{64}$", acc.snaps[expect["snap_hex"]]),
            "#{name}: snapshot not 64-hex sha256")
    if Map.has_key?(expect, "snap_neq") do
      [x, y] = expect["snap_neq"]
      assert(acc.snaps[x] != acc.snaps[y], "#{name}: snapshots should differ")
    end
    if Map.has_key?(expect, "snap_eq") do
      [x, y] = expect["snap_eq"]
      assert(acc.snaps[x] == acc.snaps[y], "#{name}: snapshots should be byte-identical")
    end
    # A receipt attests to the authority that authorized the effect, not to
    # whatever the world looked like once the effect had spent it.
    if Map.has_key?(expect, "receipt_at_entry") do
      r = List.last(Receipts.all())
      want = acc.snaps[expect["receipt_at_entry"]]
      assert(r != nil and r["authority_snapshot_at_entry"] == want,
        "#{name}: receipt at_entry #{inspect(r && r["authority_snapshot_at_entry"])} want #{inspect(want)}")
    end
    if Map.has_key?(expect, "receipt_after") do
      r = List.last(Receipts.all())
      want = acc.snaps[expect["receipt_after"]]
      assert(r != nil and r["authority_snapshot_after"] == want,
        "#{name}: receipt after #{inspect(r && r["authority_snapshot_after"])} want #{inspect(want)}")
    end
    # Effect identity must outlive authority change; consent identity must not.
    if Map.has_key?(expect, "ek_eq") do
      [x, y] = expect["ek_eq"]
      assert(acc.eks[x] != nil and acc.eks[x] == acc.eks[y],
        "#{name}: effect key changed when authority did — external dedup would break")
    end
    if Map.has_key?(expect, "receipt_key_is_effect_key") do
      r = List.last(Receipts.all())
      assert(r != nil and r["idempotency_key"] != nil and
               r["idempotency_key"] == r["effect_key"],
        "#{name}: the receipt's idempotency key is not the effect key")
    end
    if Map.has_key?(expect, "effect_key"),
      do: assert(acc.ekfix == expect["effect_key"],
            "#{name}: effect key #{inspect(acc.ekfix)} != JS #{inspect(expect["effect_key"])} — cross-language mismatch")
    if Map.has_key?(expect, "active") do
      spec = expect["active"]
      m = Enum.filter(GrantRegistry.list(),
            &(&1["status"] == "active" and &1["capability"] == spec["cap"]))
      assert(length(m) == spec["n"], "#{name}: active count #{length(m)} want #{spec["n"]}")
      if spec["duration"],
        do: assert(Enum.all?(m, &(&1["duration"] == spec["duration"])),
              "#{name}: active duration mismatch")
    end
    if Map.has_key?(expect, "snapshot"),
      do: assert(acc.snapfix == expect["snapshot"],
            "#{name}: snapshot parity #{inspect(acc.snapfix)} != JS #{inspect(expect["snapshot"])}")
    if Map.has_key?(expect, "digest"),
      do: assert(acc.digest == expect["digest"],
            "#{name}: digest #{inspect(acc.digest)} != JS #{inspect(expect["digest"])} — cross-language canon/sha mismatch")
  end

  for {vec, i} <- Enum.with_index(doc["vectors"]) do
    @vec vec
    test "#{String.pad_leading(Integer.to_string(i + 1), 2, "0")} · #{vec["name"]}" do
      Ampd.reset_demo()
      acc = Enum.reduce(@vec["steps"],
              %{last: nil, last_retired: nil, digest: nil, snaps: %{}, snapfix: nil, eks: %{}, ekfix: nil},
              &step(&2, &1))
      check!(@vec["name"], @vec["expect"], acc)
    end
  end
end
