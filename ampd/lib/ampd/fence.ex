defmodule Ampd.Fence do
  @moduledoc """
  The participant-side write fence — the fencing token, checked **by the
  resource**, in the same process and the same `Ampd.Store.save/2` as the
  mutation it guards.

  The journal owner (`Ampd.Effects`) mints one epoch and one random key per
  incarnation and pushes both to every participant before it serves
  anything. A ticket is a permission the owner signs under that key; a
  participant recomputes the signature, so "this ticket was issued by the
  journal owner of this epoch, for this operation, on this target" is
  decided here without a call back into the owner — which is what keeps
  the call graph acyclic (`Ampd.Effects` → participants, never the reverse).

  The fence is a map the participant keeps INSIDE the state map it already
  persists:

      %{"epoch" => e, "key" => k, "retired" => [lease ids retired in e]}

  so the epoch, the retired set, the mutated row and its witness are one
  `:dets` object and one sync — none of them can be present without the
  others. A participant with no fence has never been synchronized by a
  journal owner and refuses every ticket: fail-closed, not fail-open.

  Order of the participant's refusals, evaluated BEFORE any mutation:

      write-unmediated      no ticket, a malformed ticket, or no fence
      write-lease-stale     the ticket names another epoch (the owner restarted)
      write-unmediated      the signature does not verify (never issued here)
      write-lease-closed    the lease was retired at this resource (S-3 acked)
      write-lease-retired   (the same, when the owner said `completed`)
      write-unscoped        the ticket is for another op or another row

  `write-duplicate` is the participant's own: it reads the witness already
  on the row, and lives beside the mutation in the participant.
  """

  @ticket_fields ~w(ticket_id lease_id effect op target epoch)

  def new(epoch, key) when is_binary(epoch) and is_binary(key),
    do: %{"epoch" => epoch, "key" => key, "retired" => %{}}

  @doc "Retire a lease at this resource. Idempotent."
  def retire(%{"retired" => r} = fence, lease_id, reason),
    do: %{fence | "retired" => Map.put(r, lease_id, reason)}

  def retired?(%{"retired" => r}, lease_id), do: Map.has_key?(r, lease_id)

  # ------------------------------------------------------------- signing
  def mint_key, do: :crypto.strong_rand_bytes(32)

  defp canon(map, fields), do: Enum.map_join(fields, "\n", &"#{&1}=#{map[&1]}")
  defp mac(key, msg), do: :crypto.mac(:hmac, :sha256, key, msg) |> Base.encode16(case: :lower)

  @doc "The owner signs a ticket: every field a participant will read is under the MAC."
  def sign_ticket(key, ticket),
    do: Map.put(ticket, "mac", mac(key, "ticket\n" <> canon(ticket, @ticket_fields)))

  def ticket_valid?(key, ticket) when is_map(ticket) and is_binary(key) do
    is_binary(ticket["mac"]) and
      Enum.all?(@ticket_fields, &is_binary(ticket[&1])) and
      secure_eq?(ticket["mac"], mac(key, "ticket\n" <> canon(ticket, @ticket_fields)))
  end

  def ticket_valid?(_, _), do: false

  @doc "The owner signs a lease token the same way; a value reconstructed from data will not verify (R4)."
  def sign_lease(key, lease),
    do: Map.put(lease, "mac", mac(key, "lease\n" <> canon(lease, ~w(lease_id effect epoch))))

  def lease_valid?(key, lease) when is_map(lease) and is_binary(key) do
    is_binary(lease["mac"]) and
      secure_eq?(lease["mac"], mac(key, "lease\n" <> canon(lease, ~w(lease_id effect epoch))))
  end

  def lease_valid?(_, _), do: false

  @doc """
  What a participant signs when it reports a terminal: the owner accepts
  a `landed` or `refused` only with the resource's own proof, so a caller
  cannot report a landing that did not happen at the resource.
  """
  def proof(%{"key" => key}, %{"ticket_id" => t, "lease_id" => l, "op" => op}, verdict),
    do: mac(key, "#{verdict}\n#{t}\n#{l}\n#{op}")

  def proof_valid?(key, %{"ticket_id" => t, "lease_id" => l, "op" => op}, verdict, proof)
      when is_binary(proof) and is_binary(t) and is_binary(l) and is_binary(op),
      do: secure_eq?(proof, mac(key, "#{verdict}\n#{t}\n#{l}\n#{op}"))

  def proof_valid?(_, _, _, _), do: false

  @doc """
  What a row keeps of the ticket that landed on it: enough to refuse a
  re-presentation and to name the lease at retirement — and nothing more.
  v1 stored the whole signed ticket; measured at 1000 rows that was most of
  the added bytes in every whole-state save.
  """
  def witness_of(%{"ticket_id" => t, "lease_id" => l}), do: %{"ticket_id" => t, "lease_id" => l}

  # --------------------------------------------------------------- check
  @doc """
  The fence decision for one ticket presented to one resource for `op` on
  the row `target`. `:ok`, or `{:refused, code, why}`. Pure; mutates
  nothing; the participant mutates only after `:ok`.
  """
  def check(fence, ticket, op, target) do
    cond do
      not is_map(ticket) or not Enum.all?(@ticket_fields, &is_binary(ticket[&1])) ->
        {:refused, "write-unmediated", "no ticket, or a malformed one"}

      not is_map(fence) or not is_binary(fence["epoch"]) ->
        {:refused, "write-unmediated",
         "this resource has not been synchronized by a journal owner"}

      ticket["epoch"] != fence["epoch"] ->
        {:refused, "write-lease-stale",
         "ticket epoch #{ticket["epoch"]} is not this resource's epoch #{fence["epoch"]} — the journal owner restarted since it was issued"}

      not ticket_valid?(fence["key"], ticket) ->
        {:refused, "write-unmediated",
         "the ticket was not issued by the journal owner of this epoch"}

      retired?(fence, ticket["lease_id"]) ->
        code =
          if fence["retired"][ticket["lease_id"]] == "completed",
            do: "write-lease-retired",
            else: "write-lease-closed"

        {:refused, code,
         "lease #{ticket["lease_id"]} was retired at this resource before this write arrived"}

      ticket["op"] != op ->
        {:refused, "write-unscoped", "ticket is for #{ticket["op"]}, presented for #{op}"}

      ticket["target"] != target ->
        {:refused, "write-unscoped",
         "ticket targets #{ticket["target"]}, presented for #{target}"}

      true ->
        :ok
    end
  end

  @doc """
  The refusal a participant returns. `component` names the participant.
  It carries the resource's own proof of the refusal, so the journal owner
  can record `refused` for that ticket on the resource's word, not the
  caller's.
  """
  def refusal(fence, code, why, ticket, component) do
    tid = ticket_id(ticket)

    Ampd.Refusal.new(code,
      component: component,
      retryable: false,
      requires_human: false,
      public_message: "The write was refused by the resource's lease fence.",
      operator_detail: %{
        "ticket_id" => tid,
        "lease_id" => if(is_map(ticket), do: ticket["lease_id"], else: nil),
        "op" => if(is_map(ticket), do: ticket["op"], else: nil),
        "why" => why,
        "proof" =>
          if(
            is_map(fence) and is_binary(fence["key"]) and tid != nil and
              is_binary(ticket["lease_id"]) and
              is_binary(ticket["op"]),
            do: proof(fence, ticket, "refused"),
            else: nil
          )
      }
    )
  end

  # ------------------------------------------ the shared participant side
  @doc """
  The two fence messages every participant serves, guarded the same way:
  only the journal owner may move a fence, a sealed store cannot persist
  one, and the new fence is saved with the state before the reply.

  `fence_epoch` installs the incarnation's epoch and key and empties the
  retired set (every lease of an older epoch is refused by epoch already).
  `fence_retire` records the retirement and replies with the landings this
  resource already holds under that lease — `landed_under.(state, lease_id)`
  is the participant's own read of its witnesses — each with a proof, so
  the owner records them BEFORE the retirement.
  """
  def handle_owner_call(msg, from, st, mod, landed_under) do
    tag = elem(msg, 0)

    cond do
      not Ampd.Ordered.from_journal_owner?(from) ->
        {:reply, {:refused, Ampd.Ordered.owner_refusal(tag, mod)}, st}

      st.sealed != nil ->
        {:reply, {:refused, Ampd.Ordered.sealed_refusal(st.sealed, tag, mod)}, st}

      # Between `close_store` and `load_state` (a world reset) there is no
      # table to persist a fence into. Refuse by name; the owner retries.
      # Raising here — `Store.save(nil, _)` does — took the participant down
      # when a restarting owner's push met a reset in progress.
      st.tab == nil ->
        {:reply,
         {:refused,
          Ampd.Refusal.new("store-closed",
            component: inspect(mod),
            retryable: true,
            requires_human: false,
            public_message: "The resource's store is closed; the fence cannot be persisted now.",
            operator_detail: %{"operation" => inspect(tag)}
          )}, st}

      true ->
        case msg do
          {:fence_epoch, epoch, key} ->
            s2 = Map.put(st.s, "fence", new(epoch, key))
            {:reply, :ok, %{st | s: Ampd.Store.save(st.tab, s2)}}

          {:fence_retire, lease_id, reason} ->
            case st.s["fence"] do
              nil ->
                {:reply, {:error, :unfenced}, st}

              fence ->
                fence = retire(fence, lease_id, reason)
                s2 = Map.put(st.s, "fence", fence)
                st = %{st | s: Ampd.Store.save(st.tab, s2)}

                # `landed_under.(state, lease_id)` returns compact witnesses with the
                # op this resource serves; the reply signs (ticket, lease, op).
                landed =
                  Enum.map(landed_under.(s2, lease_id), fn w ->
                    %{"ticket" => w, "proof" => proof(fence, w, "landed")}
                  end)

                {:reply, {:ok, landed}, st}
            end
        end
    end
  end

  @doc "A participant's `load_state` installs a world; the fence is not part of a world and is carried over."
  def carry(new_state, old_state) do
    case {new_state["fence"], (old_state || %{})["fence"]} do
      {nil, nil} -> new_state
      {nil, f} -> Map.put(new_state, "fence", f)
      _ -> new_state
    end
  end

  def ticket_id(%{"ticket_id" => t}) when is_binary(t), do: t
  def ticket_id(_), do: nil

  # Constant-time, and without a dependency (`ampd` has `deps: []`).
  defp secure_eq?(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  defp secure_eq?(_, _), do: false
end
