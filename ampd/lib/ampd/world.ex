defmodule Ampd.World do
  @moduledoc """
  `world-meta@1` — the durable proof that this machine's world was
  explicitly initialized, and the record of its lineage.

  Without it, a store that is merely *absent* is indistinguishable from a
  store that was *lost*, and "initialize defaults" silently becomes
  "re-mint authority nobody granted". The manifest is written **last** on
  first initialization: every required store is created and seeded first,
  so a manifest on disk means every store was, at some point, real.

  Five states, and only one of them may create authority:

      manifest absent  + no authority store   →  FIRST BOOT   (may initialize)
      manifest valid   + every store present  →  EXISTING     (load truth)
      manifest valid   + store missing/damaged→  SEALED       (refuse, named)
      manifest absent  + any store present    →  ORPHANED     (refuse, named)
      manifest present but INVALID            →  UNTRUSTED    (refuse, named)

  The fourth is the one that looks like the first. A world whose manifest
  was deleted still has its authority on disk, and seeding over it would
  destroy the evidence *and* replace it with defaults — the same widening
  the manifest exists to prevent, arriving from the other direction.

  The fifth exists because **presence is not validity**: `{"foo":"bar"}`
  parses to a non-empty map, and once counted as an initialized world. A
  file that cannot be trusted must not vouch for world identity — least of
  all now, when that identity is about to carry local trust and restore
  lineage.

  ## Generation is world lineage, not a write counter

  `generation` increments only when durable truth is wholesale replaced or
  its lineage discontinuously changes — restore, factory re-initialization,
  importing a world. A semantics-preserving schema migration moves
  `schema_version`, not `generation`.

  Restoring an older snapshot never moves generation backward: restoring a
  generation-3 snapshot into a generation-7 world produces **generation 8**
  carrying `restored_from`, so a stale client can never read a rollback as
  continuity.
  """

  @schema "world-meta@1"
  @schema_version 2

  # Stores whose absence is an authority question, not a cache miss.
  # `capability_registry` is in the list because pack *policies* govern
  # placement: losing a tightened `source_data: private` and reseeding the
  # default would widen where an effect may run.
  @authority_stores ~w(grant_registry approvals receipts session capability_registry effects)

  def authority_stores, do: @authority_stores
  def schema_version, do: @schema_version

  defp dir, do: Ampd.Store.data_dir()

  defp path do
    File.mkdir_p!(dir())
    Path.join(dir(), "world.json")
  end

  @doc "Whatever is on disk, unvalidated. Diagnostics only."
  def read_raw do
    case File.read(path()) do
      {:ok, bin} -> decode(bin)
      {:error, _} -> nil
    end
  end

  @doc """
  The manifest — **only if it is valid**. `nil` covers both "absent" and
  "unusable"; `manifest_state/0` distinguishes them.

  Presence is not validity. `{"foo":"bar"}` parses to a non-empty map and
  used to count as an initialized world, which would let a corrupt or
  truncated file stand in for world identity right as that identity starts
  carrying local trust and ComputeDriven restore lineage.
  """
  def read do
    case read_raw() do
      nil -> nil
      m -> if valid?(m), do: m, else: nil
    end
  end

  @doc """
  `:absent` · `:valid` · `:migration_required` · `:unsupported` · `:malformed`.

  The last three extend "presence is not validity" one step further:
  **valid shape is not understood semantics.** A manifest whose shape is
  perfect and whose `schema_version` is 999 is a world written by
  something this build has never met. Accepting it means reading fields
  whose meaning is a guess — and the guess would be about world identity
  and lineage, the two facts everything else is anchored to.

      schema_version == 2   →  :valid
      schema_version <  2   →  :migration_required   (no migration engine yet)
      schema_version >  2   →  :unsupported
      shape wrong           →  :malformed

  `:migration_required` is separate from `:unsupported` because the
  remediations differ: one is "run the migration this build knows how to
  run", the other is "this build is older than this world, and no amount
  of local repair changes that."
  """
  def manifest_state do
    case read_raw() do
      nil ->
        :absent

      m ->
        # Version is read **before** shape, because shape is versioned.
        # Checking shape first reports a v1 manifest as corrupt — it has
        # `store_generation` where v2 has `generation` — and sends an
        # operator hunting for a damaged file that is merely old. Only the
        # two fields that must be stable across every version are judged
        # ahead of the version itself.
        cond do
          m["schema"] != @schema -> :malformed
          not is_integer(m["schema_version"]) -> :malformed
          m["schema_version"] > @schema_version -> :unsupported
          m["schema_version"] < @schema_version -> :migration_required
          not shape_ok?(m) -> :malformed
          true -> :valid
        end
    end
  end

  @untrusted ~w(malformed migration_required unsupported)a

  @doc "The manifest states from which authority must never be inferred."
  def untrusted_states, do: @untrusted

  @doc """
  Every field a trustworthy `world-meta@1` must carry, in the right shape
  **and at a version this build understands**.
  """
  def valid?(m) when is_map(m), do: shape_ok?(m) and m["schema_version"] == @schema_version
  def valid?(_), do: false

  # Shape alone — a well-formed manifest, whatever version it declares.
  # Kept apart from `valid?/1` so an unreadable *version* is reported as a
  # version problem instead of being flattened into "malformed", which
  # would send an operator hunting for corruption that is not there.
  defp shape_ok?(m) when is_map(m) do
    m["schema"] == @schema and
      is_integer(m["schema_version"]) and m["schema_version"] >= 1 and
      is_binary(m["installation_id"]) and
      Regex.match?(~r/^w-[0-9a-f]{16}$/, m["installation_id"]) and
      is_binary(m["initialized_at"]) and
      match?({:ok, _, _}, DateTime.from_iso8601(m["initialized_at"])) and
      is_integer(m["generation"]) and m["generation"] >= 1
  end

  defp shape_ok?(_), do: false

  @doc "What is wrong with the manifest on disk, for the operator."
  def invalid_fields do
    m = read_raw() || %{}

    [
      {"schema", m["schema"] == @schema},
      {"schema_version", is_integer(m["schema_version"]) and m["schema_version"] == @schema_version},
      {"installation_id", is_binary(m["installation_id"]) and Regex.match?(~r/^w-[0-9a-f]{16}$/, m["installation_id"] || "")},
      {"initialized_at", is_binary(m["initialized_at"]) and match?({:ok, _, _}, DateTime.from_iso8601(m["initialized_at"] || ""))},
      {"generation", is_integer(m["generation"])}
    ]
    |> Enum.reject(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  defp decode(bin) do
    # No JSON dep: the manifest is a flat string/integer map we write ourselves.
    bin
    |> String.trim()
    |> String.trim_leading("{")
    |> String.trim_trailing("}")
    |> String.split(",")
    |> Enum.reduce(%{}, fn pair, acc ->
      case String.split(pair, ":", parts: 2) do
        [k, v] -> Map.put(acc, unq(k), unq(v))
        _ -> acc
      end
    end)
    |> case do
      m when map_size(m) == 0 -> nil
      m -> m
    end
  end

  defp unq(s) do
    s = String.trim(s)

    if String.starts_with?(s, "\"") do
      String.trim(s, "\"")
    else
      case Integer.parse(s) do
        {n, ""} -> n
        _ -> s
      end
    end
  end

  defp encode(m) do
    inner =
      m
      |> Map.to_list()
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn
        {k, v} when is_integer(v) -> "\"#{k}\":#{v}"
        {k, v} -> "\"#{k}\":\"#{v}\""
      end)

    "{" <> inner <> "}"
  end

  @doc "Authority stores that physically exist on disk right now."
  def stores_on_disk do
    case File.ls(dir()) do
      {:ok, files} ->
        Enum.filter(@authority_stores, &("#{&1}.dets" in files))

      {:error, _} ->
        []
    end
  end

  @doc """
  Write the manifest. Callers must have created and seeded every required
  store first — this is the *last* step of initialization, so that a
  manifest on disk is proof every store was, at some point, real.
  See `Ampd.Bootstrap.new_world!/0`, which owns that ordering.

  `initialized_at` is injected rather than sampled so a world can be
  reconstructed byte-identically in a test.
  """
  def initialize!(now \\ nil) do
    meta = %{
      "schema" => @schema,
      "schema_version" => @schema_version,
      "installation_id" => installation_id(),
      "initialized_at" => now || DateTime.utc_now() |> DateTime.to_iso8601(),
      "generation" => 1
    }

    File.write!(path(), encode(meta))
    meta
  end

  defp installation_id do
    "w-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  @doc """
  **Which world this is** — one opaque token, and the reason it exists.

  `generation` counts *within* an installation, so it is not an identity.
  A factory reset destroys the manifest and calls `initialize!/1` again,
  which mints a new `installation_id` and sets `generation` back to 1 — so
  two entirely different worlds are both "generation 1", and a client
  comparing generations sees the second as the first. Measured:

      before  w-0d840f34…  gen 1  epoch cf7320ae  revision 3
      after   w-0e2b4559…  gen 1  epoch cf7320ae  revision 4

  Same generation, same epoch, revision merely advanced — because the
  coordinator survives a world reset. A client comparing the continuity
  triple classifies a brand-new world as the next revision of the old one.
  Textbook ABA, and it would have been the ground the cockpit stood on.

  Hashed rather than sent raw: `installation_id` is operator-only — it is
  the stable name of this installation across every world it ever holds —
  while continuity frames go to agents too. An agent needs to know *that*
  the world changed, never *which* installation it is talking to.

  **128 bits, not 64.** This truncated SHA-256 to 8 bytes, which is
  defensible for a local opaque token whose input is not attacker-selected
  and indefensible to leave in place a moment longer than that stays true.
  It is about to become the identity a restored world is recognised by
  across machines, and 16 bytes costs nothing here.
  """
  def incarnation, do: incarnation_of(lineage())

  @doc """
  The incarnation of a lineage already in hand — so a caller that has read
  the manifest once does not read it again to hash it.

  `continuity/0` sampled `incarnation/0` and `generation` as two separate
  reads of the same file, which can disagree if a lineage advance lands
  between them: an incarnation from before the bump beside a generation
  from after it. One read, both fields derived.
  """
  def incarnation_of(%{"installation_id" => id, "generation" => g}) when is_binary(id) do
    :crypto.hash(:sha256, id <> "/" <> to_string(g))
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  def incarnation_of(_), do: nil

  @doc """
  Advance world lineage. `reason` is recorded; `restored_from` (a map with
  at least `generation`) is recorded when this is a restore.

  Generation is monotonic **by construction** — restoring an older world
  moves it forward, never back.
  """
  def bump_generation!(reason, restored_from \\ nil) do
    meta = read() || raise "cannot advance lineage: this machine has no world"
    next = (meta["generation"] || 1) + 1

    meta =
      meta
      |> Map.put("generation", next)
      |> Map.put("generation_reason", reason)
      |> Map.put("generation_at", DateTime.utc_now() |> DateTime.to_iso8601())

    meta =
      case restored_from do
        nil ->
          Map.drop(meta, ["restored_from_generation", "restored_from_snapshot"])

        rf ->
          meta
          |> Map.put("restored_from_generation", rf["generation"] || rf[:generation])
          |> Map.put("restored_from_snapshot", rf["snapshot"] || rf[:snapshot] || "unknown")
      end

    File.write!(path(), encode(meta))
    meta
  end

  @doc "True once this machine has an explicitly initialized world."
  def initialized?, do: read() != nil

  @doc """
  Whether initialization is allowed to create authority right now.

  `:ok` only on a genuine first boot. A missing manifest beside a real
  authority store is an **orphaned world** — refuse, and do not overwrite
  the evidence.
  """
  def may_initialize? do
    st = manifest_state()

    cond do
      st == :valid ->
        {:error, :already_initialized}

      # A manifest we cannot read might still be a real world's — and one
      # written by a *newer* build certainly is. Refuse rather than
      # overwrite it. This is the branch that stops "unsupported version"
      # from being read as "no world here, seed defaults", which would
      # destroy a future world's identity with a fresh one.
      st in @untrusted ->
        {:error, {st, invalid_fields()}}

      stores_on_disk() == [] ->
        :ok

      true ->
        {:error, {:orphaned, stores_on_disk()}}
    end
  end

  @doc """
  This world's lineage — what consent is bound to.

  `nil` when there is no trustworthy world, which is itself the answer:
  consent taken under a world we cannot identify is consent we cannot
  honour. See `Ampd.Gateway`'s approval envelope.
  """
  def lineage do
    case read() do
      nil -> nil
      m -> %{"installation_id" => m["installation_id"], "generation" => m["generation"]}
    end
  end

  @doc """
  The recovery verdict for one store, given the manifest.

  * `:fresh`   — no world yet and no orphaned state; initialization may create state.
  * `:present` — world and store both exist; load the persisted truth.
  * `{:sealed, reason}` — authority must not be inferred.
  """
  def verdict(name, store_state) do
    meta = read()

    cond do
      manifest_state() in @untrusted and name in @authority_stores ->
        {:sealed, untrusted_meta_reason(name, manifest_state())}

      meta == nil and stores_on_disk() != [] and name in @authority_stores ->
        {:sealed, orphan_reason(name)}

      meta == nil ->
        :fresh

      store_state == :present ->
        :present

      name not in @authority_stores ->
        :fresh

      store_state == :damaged ->
        {:sealed, sealed_reason(name, meta, "damaged")}

      true ->
        {:sealed, sealed_reason(name, meta, "missing")}
    end
  end

  defp untrusted_meta_reason(name, :unsupported) do
    m = read_raw() || %{}

    "WORLD-META-UNSUPPORTED · #{name}: world-meta@1 declares schema_version " <>
      "#{m["schema_version"]}; this build understands #{@schema_version}. The shape is valid and " <>
      "the semantics are not: this world was written by a newer build, and reading its identity " <>
      "or lineage here would be a guess. Refusing to infer authority from defaults, and refusing " <>
      "to overwrite a manifest this build did not write."
  end

  defp untrusted_meta_reason(name, :migration_required) do
    m = read_raw() || %{}

    "WORLD-META-MIGRATION-REQUIRED · #{name}: world-meta@1 declares schema_version " <>
      "#{m["schema_version"]}; this build is at #{@schema_version} and carries no migration path " <>
      "from that version. A migration is an explicit, verified transition — not something to " <>
      "infer field by field at boot. Refusing to infer authority from defaults."
  end

  defp untrusted_meta_reason(name, _malformed) do
    "WORLD-META-UNTRUSTED · #{name}: world-meta@1 is present but not valid " <>
      "(bad or missing: #{Enum.join(invalid_fields(), ", ")}). Presence is not validity, and a " <>
      "manifest that cannot be trusted cannot vouch for this world's identity or lineage. " <>
      "Refusing to infer authority from defaults."
  end

  defp orphan_reason(name) do
    "ORPHANED-WORLD · #{name}: authority stores exist on disk (#{Enum.join(stores_on_disk(), ", ")}) " <>
      "but world-meta@1 is absent. This is either an interrupted first initialization or a world " <>
      "whose manifest was lost, and those are indistinguishable. Refusing to seed over existing " <>
      "authority state."
  end

  defp sealed_reason(name, meta, kind) do
    code = if kind == "damaged", do: "RECOVERY-STATE-UNTRUSTED", else: "RECOVERY-STATE-MISSING"

    tail =
      if kind == "damaged",
        do: "its store needs repair — a repaired authority table is an unaudited mutation",
        else: "its authority store is absent"

    "#{code} · #{name}: world #{meta["installation_id"]} (generation #{meta["generation"]}) " <>
      "was initialized at #{meta["initialized_at"]} but #{tail}. " <>
      "Refusing to infer authority from defaults."
  end
end
