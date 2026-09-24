defmodule Ampd.Approvals do
  @moduledoc "Which exact effects await consent — approvals bound to intent digests."
  use GenServer
  @store "approvals"
  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  # ------------------------------------------------- participant boundary
  #
  # C1.0b·2·1. Inside `Ampd.AuthorityCoordinator`, a bare `GenServer.call`
  # that fails EXITS the caller — and the caller there is the total order,
  # so one participant's fault becomes `seq` back to zero, the projection
  # epoch re-minted, and every subscriber resnapshotting. The reachability
  # census (`tools/ordered-reachability.json`) proves this module is reached
  # while a transaction or an ordered observation is executing.
  #
  # The class is not optional and is not inferred: a crossing whose class
  # the author has not decided is a crossing whose failure cannot be
  # classified either. Every tag NOT named below is a read.
  @participant_mutations ~w(close_store load_state push new_pending mark mark_consumed fence_epoch fence_retire reset retire)a

  defp ask(msg, timeout \\ 5_000) do
    tag = if is_tuple(msg), do: elem(msg, 0), else: msg
    Ampd.Participant.call(__MODULE__, msg, class(tag), timeout: timeout)
  end

  @doc false
  # Public so the closure gate and the falsifiers read the classification
  # rather than infer it.
  def class(tag), do: if(tag in @participant_mutations, do: :mutate, else: :read)

  @impl true
  def init(:ok) do
    case Ampd.Store.boot(@store, &initial/0) do
      {:ok, tab, s} -> {:ok, %{tab: tab, s: s, sealed: nil}}
      {:sealed, reason} -> {:ok, %{tab: nil, s: sealed_state(), sealed: reason}}
    end
  end

  @doc """
  What a sealed registry serves: nothing. A sealed store's persisted
  truth is unknown or untrusted, so projecting `initial/0` would hand
  callers fabricated defaults — pack policies that were never
  installed, a workspace that was never opened. Neutral and empty is
  the only honest projection; `Ampd.Gateway` turns the seal into a
  named refusal before any of it is reachable.
  """
  def sealed_state, do: %{"approvals" => [], "seq" => 0}

  def sealed, do: ask(:sealed)
  def close_store, do: ask(:close_store)
  def load_state(s), do: ask({:load_state, s})
  def initial, do: %{"approvals" => [], "seq" => 36}
  def all, do: ask(:all)
  def push(m), do: ask({:push, m})

  def new_pending(fields) do
    ask({:new_pending, fields})
  end

  def mark(id, status, reason \\ nil), do: ask({:mark, id, status, reason})

  @doc """
  The mediated consumption of consent (E3-1): the ticket must be the
  journal owner's for `consume_approval` on this row; the row gains
  `consumed_by` (the effect) and `consumed_witness` (the ticket) in the
  same save as its status. `mark(id, "consumed")` remains the legacy,
  unmediated arity for `Ampd.Conformance.authorize/4` and records no
  witness. B3/B4 are not evidenced by the B2 experiment; this exists so
  every branch takes the same lease.
  """
  def mark_consumed(ticket) when is_map(ticket), do: ask({:mark_consumed, ticket})

  @doc "Journal-owner only: install this incarnation's fence (`Ampd.Fence`)."
  def fence_epoch(epoch, key), do: ask({:fence_epoch, epoch, key})
  @doc "This resource's fence as persisted — epoch and retired leases, never the key. A read."
  def fence, do: ask(:fence)

  @doc "Journal-owner only: retire a lease at this resource; replies with the landings held under it."
  def fence_retire(lease_id, reason), do: ask({:fence_retire, lease_id, reason})

  @doc """
  Coordinator only, inside the retirement transaction: drop the consumed
  approvals `ids` from the working list, indexed as archived in `batch`.
  Refuses the whole batch if any is absent or not consumed.
  """
  def retire(ids, batch), do: ask({:retire, ids, batch})

  @doc "A retired approval's compact entry — `[status, batch, consumed_by]` — or nil."
  def retired(id), do: ask({:retired, id})

  def last_pending do
    all() |> Enum.reverse() |> Enum.find(&(&1["status"] == "pending"))
  end

  def reset, do: ask(:reset)
  # --- ordered-authority boundary -------------------------------------
  # These mutations are served only when the caller IS the total order.
  @ordered_ops [:push, :new_pending, :mark, :mark_consumed, :reset, :load_state, :retire]
  @impl true
  # A call made for the open authority transaction (`Ampd.AuthorityLog.group/1`)
  # arrives wrapped with its origin, so this registry's writes join that
  # transaction's one record.
  def handle_call({:"$alog_origin", origin, msg}, from, st),
    do: Ampd.AuthorityLog.as_member(origin, fn -> handle_call(msg, from, st) end)

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
    if st.tab, do: Ampd.Store.close(st.tab)
    {:reply, :ok, %{st | tab: nil}}
  end

  def handle_call(:all, _f, %{s: s} = st), do: {:reply, s["approvals"], st}

  def handle_call({:retired, id}, _f, %{s: s} = st),
    do: {:reply, Map.get(Map.get(s, "retired", %{}), id), st}

  # A read of this resource's fence — epoch and retired set, never the key.
  def handle_call(:fence, _f, %{s: s} = st),
    do: {:reply, if(is_map(s["fence"]), do: Map.delete(s["fence"], "key"), else: nil), st}

  def handle_call({:fence_epoch, _, _} = msg, from, st),
    do: Ampd.Fence.handle_owner_call(msg, from, st, __MODULE__, &landed_under/2)

  def handle_call({:fence_retire, _, _} = msg, from, st),
    do: Ampd.Fence.handle_owner_call(msg, from, st, __MODULE__, &landed_under/2)

  defp landed_under(s, lease_id) do
    s["approvals"]
    |> Enum.map(& &1["consumed_witness"])
    |> Enum.filter(&(is_map(&1) and &1["lease_id"] == lease_id))
    |> Enum.map(&Map.put(&1, "op", "consume_approval"))
  end

  # --- ordered implementations (reached only via the guard above) ----
  def handle_ordered({:load_state, s}, st) do
    tab = st.tab || Ampd.Store.open!(@store)

    {:reply, :ok,
     %{st | tab: tab, s: Ampd.Store.save(tab, Ampd.Fence.carry(s, st.s)), sealed: nil}}
  end

  def handle_ordered({:retire, ids, batch}, %{tab: tab, s: s} = st) do
    rows = Enum.map(ids, fn id -> {id, Enum.find(s["approvals"], &(&1["id"] == id))} end)

    case Enum.find(rows, fn {_id, a} -> a == nil or a["status"] != "consumed" end) do
      {id, a} ->
        {:reply,
         {:refused,
          Ampd.Refusal.new("retire-not-settled",
            component: "Ampd.Approvals",
            retryable: true,
            requires_human: false,
            public_message: "An approval in the retirement batch is not consumed.",
            operator_detail: %{"approval" => id, "status" => a && a["status"]}
          )}, st}

      nil ->
        set = MapSet.new(ids)

        index =
          Map.merge(
            Map.get(s, "retired", %{}),
            Map.new(rows, fn {id, a} -> {id, [a["status"], batch, a["consumed_by"]]} end)
          )

        s2 =
          s
          |> Map.put("approvals", Enum.reject(s["approvals"], &MapSet.member?(set, &1["id"])))
          |> Map.put("retired", index)

        {:reply, {:ok, length(ids)}, %{st | s: Ampd.Store.save(tab, s2)}}
    end
  end

  def handle_ordered({:mark_consumed, ticket}, %{tab: tab, s: s} = st) do
    target = if is_map(ticket), do: ticket["target"], else: nil
    a = target && Enum.find(s["approvals"], &(&1["id"] == target))

    verdict =
      with :ok <- Ampd.Fence.check(s["fence"], ticket, "consume_approval", target) do
        cond do
          a == nil and Map.has_key?(Map.get(s, "retired", %{}), target) ->
            {:refused, "write-duplicate", "#{target} is already consumed (retired)"}

          a == nil ->
            {:refused, "write-unscoped", "no approval #{inspect(target)}"}

          a["consumed_by"] != nil or a["status"] == "consumed" ->
            {:refused, "write-duplicate", "#{target} is already consumed"}

          true ->
            :ok
        end
      end

    case verdict do
      {:refused, code, why} ->
        {:reply, {:refused, Ampd.Fence.refusal(s["fence"], code, why, ticket, "Ampd.Approvals")},
         st}

      :ok ->
        approvals =
          Enum.map(s["approvals"], fn x ->
            if x["id"] == target,
              do:
                Map.merge(x, %{
                  "status" => "consumed",
                  "consumed_by" => ticket["effect"],
                  "consumed_witness" => Ampd.Fence.witness_of(ticket)
                }),
              else: x
          end)

        st = %{st | s: Ampd.Store.save(tab, %{s | "approvals" => approvals})}

        witness = %{
          "ticket_id" => ticket["ticket_id"],
          "proof" => Ampd.Fence.proof(s["fence"], ticket, "landed")
        }

        {:reply, {:ok, witness}, st}
    end
  end

  def handle_ordered({:push, m}, %{tab: tab, s: s} = st),
    do: {:reply, m, %{st | s: Ampd.Store.save(tab, %{s | "approvals" => s["approvals"] ++ [m]})}}

  def handle_ordered({:new_pending, fields}, %{tab: tab, s: s} = st) do
    id = "ap_" <> String.pad_leading(Integer.to_string(s["seq"]), 4, "0")
    m = Map.merge(%{"id" => id, "status" => "pending"}, fields)

    {:reply, m,
     %{
       st
       | s:
           Ampd.Store.save(tab, %{s | "approvals" => s["approvals"] ++ [m], "seq" => s["seq"] + 1})
     }}
  end

  def handle_ordered({:mark, id, status, reason}, %{tab: tab, s: s} = st) do
    approvals =
      Enum.map(s["approvals"], fn a ->
        if a["id"] == id do
          a = %{a | "status" => status}
          if reason, do: Map.put(a, "stale_reason", reason), else: a
        else
          a
        end
      end)

    {:reply, :ok, %{st | s: Ampd.Store.save(tab, %{s | "approvals" => approvals})}}
  end

  def handle_ordered(:reset, %{tab: tab} = st),
    do: {:reply, :ok, %{st | s: Ampd.Store.save(tab, Ampd.Fence.carry(initial(), st.s))}}

  # ------------------------------------------------ consent from elsewhere
  #
  # DESIGN ONLY. Nothing calls these. They exist so that the gate in
  # `docs/app/MOBILE_CONSENT_DESIGN_2026_09_11.md` §4 has something to hold:
  # a device that is not the desktop cannot be allowed to decide an approval
  # until replay and staleness are refused by name, and a predicate nobody
  # can test is not a refusal.
  #
  # Pure. No store, no process, no clock of its own — every input arrives in
  # the claim, so the whole space is reachable from a test.
  #
  # **There is no default-allow branch.** `:ok` is returned from exactly one
  # place, after every condition has been checked.

  @consent_window_seconds 300

  @doc """
  What a device is shown when it asks for one approval, as an ordered map.

  Derived from the record, never from the requester. The point is that the
  digest of this object can be recomputed at decision time from the record
  as it stands *then*: if anything a person read has moved, the digest moves
  with it and the consent is refused rather than applied to a changed thing.

  `request` is the effect's own arguments. It is in the presentation because
  a person cannot consent to an action whose arguments they were not shown —
  and it is deliberately NOT in the ambient snapshot, which is polled every
  five seconds and held on a device that gets lost.
  """
  def presentation_of(%{} = a) do
    %{
      "schema" => "approval-presentation@1",
      "approval_id" => a["id"],
      "capability" => a["capability"],
      "actor" => a["actor"],
      "resource" => a["resource"],
      "placement" => a["placement"],
      "pack_version" => a["pack_version"],
      "request_id" => get_in(a, ["envelope", "request_id"]),
      "request_revision" => get_in(a, ["envelope", "request_revision"]),
      "request" => get_in(a, ["envelope", "request"]),
      "world_installation_id" => a["world_installation_id"],
      "world_generation" => a["world_generation"]
    }
  end

  @doc "The digest of what was displayed. `Ampd.Core.canon/1` orders the keys."
  def presentation_digest(%{} = a), do: Ampd.Core.intent_digest(presentation_of(a))

  @doc """
  May this claimed consent be admitted against this record?

  Returns `:ok` or `{:refused, reason}` where reason is one of

      approval-not-found · approval-not-pending · intent-changed
      presentation-mismatch · world-moved · presentation-expired
      consent-replayed · decision-unrecognised · claim-incomplete

  `nonce_seen` is supplied by the caller because remembering a nonce is
  durable state and this function has none. The caller owning the memory is
  not the caller owning the rule: a caller that forgets to pass it gets
  `claim-incomplete`, not an admission.
  """
  def admit_consent(approval, claim)

  def admit_consent(nil, _claim), do: {:refused, "approval-not-found"}

  def admit_consent(%{} = a, %{} = claim) do
    required =
      ~w(approval_id request_hash presentation_digest nonce presented_at now world nonce_seen decision)

    cond do
      Enum.any?(required, &(not Map.has_key?(claim, &1))) ->
        {:refused, "claim-incomplete"}

      a["id"] != claim["approval_id"] ->
        {:refused, "approval-not-found"}

      # `granted`, `denied` and `stale` all land here: a request that was
      # already resolved is not re-decidable, and a staled one is a request
      # whose authority state can no longer be re-derived.
      a["status"] != "pending" ->
        {:refused, "approval-not-pending"}

      a["request_hash"] != claim["request_hash"] ->
        {:refused, "intent-changed"}

      a["world_installation_id"] != get_in(claim, ["world", "installation_id"]) or
          a["world_generation"] != get_in(claim, ["world", "generation"]) ->
        {:refused, "world-moved"}

      # Recomputed from the record as it stands NOW, never taken from the
      # claim. A device can say anything; this is the half it cannot choose.
      presentation_digest(a) != claim["presentation_digest"] ->
        {:refused, "presentation-mismatch"}

      claim["nonce_seen"] == true ->
        {:refused, "consent-replayed"}

      not fresh?(claim["presented_at"], claim["now"]) ->
        {:refused, "presentation-expired"}

      claim["decision"] not in ["approve", "deny"] ->
        {:refused, "decision-unrecognised"}

      true ->
        :ok
    end
  end

  def admit_consent(_, _), do: {:refused, "claim-incomplete"}

  @doc "The window a presentation stays answerable for, in seconds."
  def consent_window_seconds, do: @consent_window_seconds

  # An unparseable or absent stamp is not fresh. A stamp in the future is not
  # fresh either: a clock that disagrees is a reason to refuse, not to admit
  # for longer than the window.
  defp fresh?(presented_at, now) do
    with {:ok, at, _} <- iso(presented_at),
         {:ok, t, _} <- iso(now) do
      delta = DateTime.diff(t, at)
      delta >= 0 and delta <= @consent_window_seconds
    else
      _ -> false
    end
  end

  defp iso(v) when is_binary(v), do: DateTime.from_iso8601(v)
  defp iso(_), do: :error
end
