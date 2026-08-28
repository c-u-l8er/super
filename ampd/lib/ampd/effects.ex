defmodule Ampd.Effects do
  @moduledoc """
  The durable effect journal — `effect-request@1` and `effect-attempt@1`.

  C1.0a left an honest gap: the gateway read grants, read approvals, then
  consumed both, across separate processes. A crash could preserve an
  impossible half-transition, and the moment a real adapter exists the
  interesting case appears —

      approval consumed → GitHub creates the PR → connection dies → no receipt

  — where **the world may have changed and Super does not know whether it
  changed.** That is this module's whole job.

      PROPOSED → AUTHORIZED → APPROVED → CLAIMED → ATTEMPTED
                                                    ├→ COMMITTED
                                                    ├→ FAILED
                                                    └→ UNKNOWN → RECONCILE

  Two properties make it work, and neither is a storage feature:

  1. **The claim is a single serialization point.** `claim/1` is one
     `GenServer.call`, so two racing exercises cannot both claim the same
     proposal — the second is refused by name. The TOCTOU window closes
     because one process owns the transition, not because the disk grew
     transactions.

  2. **The journal is written before the world is touched.** CLAIMED is
     durable before any grant or approval is consumed, and ATTEMPTED is
     durable before any adapter is called. Recovery therefore reads the
     journal as the authority on what was *intended*, and reconciles the
     registries to it, instead of guessing from their half-applied state.

  The idempotency key is the intent digest Super already computes. An
  external adapter that honours idempotency keys can then be replayed
  safely from an UNKNOWN outcome, which is the only reason UNKNOWN is
  recoverable at all: exactly-once does not survive a process boundary,
  so what crosses it must be a key the far side agrees to deduplicate.

  **There are no adapters yet.** ATTEMPTED currently wraps a supplied
  function; when the first real connector lands it plugs in here and
  nothing about these states changes.
  """
  use GenServer
  @store "effects"

  @terminal ~w(COMMITTED FAILED)
  @in_flight ~w(CLAIMED ATTEMPTED)

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    case Ampd.Store.boot(@store, &initial/0) do
      {:ok, tab, s} -> {:ok, %{tab: tab, s: s, sealed: nil}}
      {:sealed, reason} -> {:ok, %{tab: nil, s: sealed_state(), sealed: reason}}
    end
  end

  def initial, do: %{"effects" => [], "seq" => 1}

  @doc """
  What a sealed registry serves: nothing. A sealed store's persisted
  truth is unknown or untrusted, so projecting `initial/0` would hand
  callers fabricated defaults — pack policies that were never
  installed, a workspace that was never opened. Neutral and empty is
  the only honest projection; `Ampd.Gateway` turns the seal into a
  named refusal before any of it is reachable.
  """
  def sealed_state, do: %{"effects" => [], "seq" => 0}

  def sealed, do: GenServer.call(__MODULE__, :sealed)
  def close_store, do: GenServer.call(__MODULE__, :close_store)
  def load_state(s), do: GenServer.call(__MODULE__, {:load_state, s})
  def all, do: GenServer.call(__MODULE__, :all)
  def get(id), do: Enum.find(all(), &(&1["id"] == id))
  def count, do: length(all())

  @doc "Open a proposal. Nothing is authorized and nothing has happened."
  def propose(env), do: GenServer.call(__MODULE__, {:propose, env})

  @doc "Record that the gateway allowed this proposal under a frozen snapshot."
  def authorized(id, meta), do: GenServer.call(__MODULE__, {:to, id, "AUTHORIZED", meta})

  @doc "Record that human consent was bound to this exact proposal."
  def approved(id, meta), do: GenServer.call(__MODULE__, {:to, id, "APPROVED", meta})

  @doc """
  Take exclusive ownership of a proposal. Durable *before* any grant or
  approval is consumed, and refused if someone already holds it.
  """
  def claim(id), do: GenServer.call(__MODULE__, {:claim, id})

  @doc "Durable before the adapter is touched. After this, UNKNOWN is possible."
  def attempt(id, adapter), do: GenServer.call(__MODULE__, {:attempt, id, adapter})

  def commit(id, result), do: GenServer.call(__MODULE__, {:to, id, "COMMITTED", %{"result" => result}})
  def fail(id, why), do: GenServer.call(__MODULE__, {:to, id, "FAILED", %{"reason" => why}})
  def unknown(id, why), do: GenServer.call(__MODULE__, {:to, id, "UNKNOWN", %{"reason" => why}})

  @doc """
  Boot-time truth. Anything still CLAIMED or ATTEMPTED when the process
  died is, by definition, of unknown outcome — the world may have moved.
  Recovery never resolves these silently; it marks them and queues them.
  """
  def recover!, do: GenServer.call(__MODULE__, :recover)

  @doc "Effects whose real-world outcome is unresolved and must be reconciled."
  def reconcile_queue, do: Enum.filter(all(), &(&1["state"] == "UNKNOWN"))

  def terminal?(e), do: e["state"] in @terminal

  # --- ordered-authority boundary -------------------------------------
  # These mutations are served only when the caller IS the total order.
  @ordered_ops [:claim, :propose, :load_state]
  @impl true
  def handle_call(msg, from, st)
      when (is_tuple(msg) and elem(msg, 0) in @ordered_ops) or
             (is_atom(msg) and msg in @ordered_ops) do
    tag = if is_tuple(msg), do: elem(msg, 0), else: msg

    cond do
      not Ampd.Ordered.from_coordinator?(from) ->
        {:reply, {:refused, Ampd.Ordered.refusal(tag, __MODULE__)}, st}

      # A sealed store refuses by name. Raising here would kill the
      # coordinator too, turning one lost store into a node-wide outage.
      st.sealed != nil and tag != :load_state ->
        {:reply, {:refused, Ampd.Ordered.sealed_refusal(st.sealed, tag, __MODULE__)}, st}

      true ->
        handle_ordered(msg, st)
    end
  end
  @impl true
  def handle_call(:sealed, _f, st), do: {:reply, st.sealed, st}
  def handle_call(:close_store, _f, st) do
    if st.tab, do: :dets.close(st.tab)
    {:reply, :ok, %{st | tab: nil}}
  end
  def handle_call(:all, _f, %{s: s} = st), do: {:reply, s["effects"], st}



  def handle_call({:to, id, state, meta}, _f, %{tab: tab, s: s} = st) do
    {e, s2} = put_state(s, id, state, meta)
    {:reply, e, %{st | s: Ampd.Store.save(tab, s2)}}
  end


  def handle_call({:attempt, id, adapter}, _f, %{tab: tab, s: s} = st) do
    n = length((Enum.find(s["effects"], &(&1["id"] == id)) || %{"attempts" => []})["attempts"]) + 1

    a = %{
      "kind" => "effect-attempt@1",
      "id" => id <> "-a" <> Integer.to_string(n),
      "adapter" => adapter,
      "idempotency_key" => (Enum.find(s["effects"], &(&1["id"] == id)) || %{})["idempotency_key"],
      "started_at" => now(),
      "outcome" => nil
    }

    {e, s2} = put_state(s, id, "ATTEMPTED", %{"__attempt" => a})
    {:reply, {:ok, e, a}, %{st | s: Ampd.Store.save(tab, s2)}}
  end

  # A sealed effects store has no journal to reconcile, and `Store.save/2`
  # raises on a sealed store by design. `:recover` is not an ordered op, so
  # it never met the seal guard the mutations got — and it runs from
  # `Ampd.Application.start/2`. The result was that a sealed world could
  # not boot **at all**: the raise took down the supervisor, the supervisor
  # took down the application, and the named refusal the seal exists to
  # produce never got the chance to be produced. A seal that crash-loops is
  # not a seal.
  def handle_call(:recover, _f, %{sealed: reason} = st) when reason != nil, do: {:reply, [], st}

  def handle_call(:recover, _f, %{tab: tab, s: s} = st) do
    {effects, moved} =
      Enum.map_reduce(s["effects"], [], fn e, acc ->
        if e["state"] in @in_flight do
          why =
            "crashed while #{e["state"]} — the adapter may or may not have run; " <>
              "replay is safe only against idempotency key #{e["idempotency_key"]}"

          {e
           |> Map.put("state", "UNKNOWN")
           |> Map.put("reason", why)
           |> Map.put("needs_reconcile", true)
           |> Map.update("history", [], &(&1 ++ [%{"state" => "UNKNOWN", "at" => now(), "reason" => why}])),
           acc ++ [e["id"]]}
        else
          {e, acc}
        end
      end)

    {:reply, moved, %{st | s: Ampd.Store.save(tab, %{s | "effects" => effects})}}
  end

  defp put_state(s, id, state, meta) do
    {attempt, meta} = Map.pop(meta, "__attempt")
    updated = :erlang.make_ref()

    effects =
      Enum.map(s["effects"], fn e ->
        if e["id"] == id do
          e
          |> Map.merge(meta)
          |> Map.put("state", state)
          |> Map.put("__u", updated)
          |> Map.update("attempts", [], fn as -> if attempt, do: as ++ [attempt], else: as end)
          |> Map.update("history", [], &(&1 ++ [%{"state" => state, "at" => now()}]))
          |> then(fn e -> if state == "UNKNOWN", do: Map.put(e, "needs_reconcile", true), else: e end)
        else
          e
        end
      end)

    e = Enum.find(effects, &(&1["__u"] == updated))
    effects = Enum.map(effects, &Map.delete(&1, "__u"))
    {e && Map.delete(e, "__u"), %{s | "effects" => effects}}
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # --- ordered implementations (reached only via the guard above) ----
  def handle_ordered({:load_state, s}, st) do
    tab = st.tab || Ampd.Store.open!(@store)
    {:reply, :ok, %{st | tab: tab, s: Ampd.Store.save(tab, s), sealed: nil}}
  end

  def handle_ordered({:propose, env}, %{tab: tab, s: s} = st) do
    id = "ef_" <> String.pad_leading(Integer.to_string(s["seq"]), 4, "0")

    e = %{
      "kind" => "effect-request@1",
      "id" => id,
      "state" => "PROPOSED",
      # The external deduplication key is `effect-intent@1` — what should
      # happen — and deliberately NOT the approval digest, which changes
      # whenever authority does. Reconciling an UNKNOWN effect after an
      # unrelated grant change must present the far side with the same key.
      "idempotency_key" => env["effect_key"],
      "approval_digest" => env["approval_digest"],
      "capability" => env["capability"],
      "pack" => env["pack"],
      "actor" => env["actor"],
      "resource" => env["resource"],
      "request_id" => env["request_id"],
      "request_revision" => env["request_revision"],
      "request" => env["request"],
      "grant_ref" => nil,
      "approval_ref" => nil,
      "authority_snapshot_at_entry" => nil,
      "placement" => nil,
      "attempts" => [],
      "history" => [%{"state" => "PROPOSED", "at" => now()}]
    }

    {:reply, e, %{st | s: Ampd.Store.save(tab, %{s | "effects" => s["effects"] ++ [e], "seq" => s["seq"] + 1})}}
  end

  def handle_ordered({:claim, id}, %{tab: tab, s: s} = st) do
    case Enum.find(s["effects"], &(&1["id"] == id)) do
      nil ->
        {:reply, {:error, "effect-unknown · " <> id}, st}

      %{"state" => st_now} = e when st_now in @in_flight ->
        {:reply, {:error, "effect-already-claimed · " <> id <> " is " <> e["state"]}, st}

      %{"state" => st_now} when st_now in @terminal ->
        {:reply, {:error, "effect-settled · " <> id <> " is already " <> st_now}, st}

      # An UNKNOWN effect is the one case that looks claimable and is not.
      # Its adapter may already have changed the world; re-claiming it is
      # precisely the double-effect this machine exists to prevent. It has
      # to be reconciled against the far side first.
      %{"state" => "UNKNOWN"} = e ->
        {:reply,
         {:error,
          "effect-unreconciled · " <> id <> " is UNKNOWN — reconcile against idempotency key " <>
            to_string(e["idempotency_key"]) <> " before claiming it again"}, st}

      _ ->
        {e, s2} = put_state(s, id, "CLAIMED", %{})
        {:reply, {:ok, e}, %{st | s: Ampd.Store.save(tab, s2)}}
    end
  end
end
