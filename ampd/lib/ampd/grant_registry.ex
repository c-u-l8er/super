defmodule Ampd.GrantRegistry do
  @moduledoc "What may be exercised: grant objects binding actor+capability+resource+duration."
  use GenServer
  @store "grant_registry"
  alias Ampd.Session
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
  @participant_mutations ~w(close_store load_state mint draft request_grant resolve_request dur revoke_domain revoke_one revoke_matching consume consume_ticket fence_epoch fence_retire commit reset retire)a

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
  A new world holds **no authority**. Installation confers zero authority,
  and so does boot: the three GitHub grants that used to appear here made
  a fresh `ampd` contradict its own first law, and made losing this store
  a way to *widen* authority. The C0 conformance world is a fixture now —
  see `Ampd.TestFixture.seed_demo!/0`.
  """
  def initial do
    %{
      "grants" => [],
      "seq" => 193,
      "dur" => "workspace",
      "requests" => [],
      "req_seq" => 1,
      "draft" => %{
        "repo.read" => false,
        "issue.read" => false,
        "pr.draft" => false,
        "pr.create" => false,
        "pr.merge" => false
      }
    }
  end

  @doc false
  def demo_state do
    base = %{
      "grants" => [],
      "seq" => 193,
      "dur" => "workspace",
      "requests" => [],
      "req_seq" => 1,
      "draft" => %{
        "repo.read" => true,
        "issue.read" => true,
        "pr.draft" => true,
        "pr.create" => false,
        "pr.merge" => false
      }
    }

    Enum.reduce(["github.repo.read", "github.issue.read", "github.pr.draft"], base, fn cap, s ->
      elem(do_mint(s, %{"capability" => cap}), 1)
    end)
  end

  @doc """
  What a sealed registry serves: nothing. A sealed store's persisted
  truth is unknown or untrusted, so projecting `initial/0` would hand
  callers fabricated defaults — pack policies that were never
  installed, a workspace that was never opened. Neutral and empty is
  the only honest projection; `Ampd.Gateway` turns the seal into a
  named refusal before any of it is reachable.
  """
  def sealed_state,
    do: %{
      "grants" => [],
      "seq" => 0,
      "dur" => nil,
      "draft" => %{},
      "requests" => [],
      "req_seq" => 0
    }

  def sealed, do: ask(:sealed)
  def close_store, do: ask(:close_store)
  def load_state(s), do: ask({:load_state, s})

  defp do_mint(s, f) do
    g =
      Map.merge(
        %{
          "id" => "gr_" <> String.pad_leading(Integer.to_string(s["seq"]), 4, "0"),
          "actor" => "kestrel",
          "resource" => "traaviis/trvm",
          "duration" => "workspace",
          "status" => "active",
          "placement" => ["local", "fleet"],
          "workspace" => "trvm",
          "run" => Session.run_or("run-b51"),
          # The consumption witness (E3-1): which effects spent this grant,
          # by ticket. Present from mint so a row is never LEGACY_UNWITNESSED.
          "consumptions" => []
        },
        f
      )

    {g, %{s | "grants" => s["grants"] ++ [g], "seq" => s["seq"] + 1}}
  end

  def mint(f), do: ask({:mint, f})

  # ------------------------------------------------------------ the index
  #
  # id → {position, grant}, and the active ids, derived from the grant list
  # and kept in this process. It is refreshed against the list it was built
  # from by walking both together: an unchanged grant is the same term, so
  # that is a pointer comparison per grant, and only changed or appended rows
  # are re-indexed. A list that shrank or moved an id is rebuilt whole. It
  # is never persisted; the list stays the authority.
  @view {__MODULE__, :view}

  defp view(grants) do
    {built_from, v} = Process.get(@view, {[], %{by_id: %{}, active: %{}}})

    v =
      if built_from === grants,
        do: v,
        else:
          (try do
             refresh(built_from, grants, 0, v)
           catch
             :rebuild -> refresh([], grants, 0, %{by_id: %{}, active: %{}})
           end)

    Process.put(@view, {grants, v})
    v
  end

  defp refresh([o | os], [n | ns], i, v) when o === n, do: refresh(os, ns, i + 1, v)

  defp refresh([o | os], [n | ns], i, v) do
    if o["id"] != n["id"], do: throw(:rebuild)
    refresh(os, ns, i + 1, index_row(v, i, n))
  end

  defp refresh([], [n | ns], i, v), do: refresh([], ns, i + 1, index_row(v, i, n))
  defp refresh([], [], _i, v), do: v
  defp refresh([_ | _], [], _i, _v), do: throw(:rebuild)

  defp index_row(v, i, g) do
    id = g["id"]

    %{
      by_id: Map.put(v.by_id, id, {i, g}),
      active:
        if(g["status"] == "active", do: Map.put(v.active, id, i), else: Map.delete(v.active, id))
    }
  end

  defp active_of(grants) do
    v = view(grants)

    v.active
    |> Enum.sort_by(fn {_id, i} -> i end)
    |> Enum.map(fn {id, _} -> elem(Map.fetch!(v.by_id, id), 1) end)
  end

  defp get_of(grants, id) do
    case Map.get(view(grants).by_id, id) do
      {_i, g} -> g
      nil -> nil
    end
  end

  defp pos_of(grants, id), do: elem(Map.fetch!(view(grants).by_id, id), 0)

  defp retired_entry(s, id), do: Map.get(Map.get(s || %{}, "retired", %{}), id)

  def one_shot(cap),
    do: mint(%{"capability" => cap, "duration" => "once", "uses_remaining" => 1})

  def list, do: ask(:list)

  @doc """
  The ACTIVE grants, in list order (the order `Ampd.Core.grant_for/5` takes
  the first match in). Everything a decision reads filters to active grants
  first, so this answers it without copying every grant ever kept out of
  this process — the copy that grew with history, twice per decision.
  """
  def active, do: ask(:active)

  @doc """
  One grant by id, or nil — a retired grant is read from the archive by the
  caller and checked against the digest its retirement committed.
  """
  def get(id) do
    case ask({:get, id}) do
      {:archived, batch, committed} ->
        case Ampd.AuthorityLog.archived_row(batch, @store, id, "id", committed) do
          {:ok, g} -> g
          {:error, _} = err -> err
        end

      other ->
        other
    end
  end

  @doc """
  A retired grant's compact entry — `[status, batch, consumptions, digest]`,
  or `[status, batch, consumptions]` if retired before digests — or nil.
  What stays in the working state so a used grant can never be spent again,
  and a replayed consumption is still refused as the duplicate it is.
  """
  def retired(id), do: ask({:retired, id})

  @doc false
  # The whole retired index (id → entry), for tools. Copies it out.
  def retired_index, do: ask(:retired_index)

  @doc """
  Every retired grant, read from the batch its index entry names and checked
  — tools and tests only: it reads every batch. `{:ok, rows}` or `{:error,
  why}`.
  """
  def archived do
    refs =
      Map.new(retired_index(), fn {id, [_status, n, _cs | more]} -> {id, {n, List.first(more)}} end)

    Ampd.AuthorityLog.archived_rows(@store, "id", refs)
  end

  @doc """
  Coordinator only, inside the retirement transaction: drop the used grants
  `archived` (the rows just written to archive batch `batch`) from the
  working list, indexed as archived there, each entry committing the digest
  of the WORKING row. Refuses the whole batch if any is absent, still
  active, or not the row that was archived.
  """
  def retire(archived, batch), do: ask({:retire, archived, batch})

  def snapshot do
    # `snapshot_of/2` keeps only active grants; handing it only those is the
    # same digest.
    Ampd.Core.snapshot_of(active(), Ampd.CapabilityRegistry.all())
  end

  def set_draft(k, v), do: ask({:draft, k, v})

  @doc """
  `grant-request@1` — an agent asking for authority it does not have.

  This is deliberately **not** `set_draft/2`. An agent's `request_grant`
  used to write straight into the grant draft — the same draft the human's
  editor works on — so "Kestrel asked for this" and "the person selected
  this" became one indistinguishable checkbox state. It created no
  authority, so the safety boundary held, but the *provenance* was gone,
  and an agent silently pre-ticking boxes in a human's editor is a
  confused deputy waiting for someone to click commit without reading.

  A request is its own object with its own lifecycle, and only a
  human-control action turns one into a grant.
  """
  def request_grant(fields), do: ask({:request_grant, fields})

  @doc "Resolve a request: `\"granted\"` (by a human) or `\"denied\"`."
  def resolve_request(id, status, note \\ nil),
    do: ask({:resolve_request, id, status, note})

  def requests, do: ask(:requests)
  def set_dur(d), do: ask({:dur, d})
  def revoke_domain(cap), do: ask({:revoke_domain, cap})

  @doc """
  Revoke **one grant, by id.**

  `revoke_domain/1` takes a capability and revokes every active grant that
  names it, for every actor and every resource. As the implementation of a
  product command called `revoke_grant`, that is the same identity mistake
  `approve_last/0` made: the person is looking at one grant object, and an
  operator revoking Kestrel's `github.repo.read` silently took Mallory's
  too. Measured on two actors holding the same capability before it was
  split.
  """
  def revoke_one(id), do: ask({:revoke_one, id})

  @doc """
  Revoke exactly `expected_ids`, and only if they are still exactly what
  `filter` matches.

  **The comparison and the mutation are one message to one process**, which
  is the whole point. The previous shape compared a count in `Ampd.Control`
  and then called in here to revoke by scope — two samples of the world
  with a writable gap between them, so a grant minted in that gap was
  revoked without anyone having seen it. Reproduced before it was fixed.

  `expected_ids` is what the operator was shown. If the set the scope
  matches *now* differs in any way — one added, one gone, or both, leaving
  the count identical — this refuses `bulk-scope-changed` and names the
  difference in both directions. Nothing is revoked.
  """
  def revoke_matching(filter, expected_ids) when is_list(expected_ids),
    do: ask({:revoke_matching, filter, expected_ids})

  @doc "What `revoke_matching/2` *would* revoke. Read-only, for the confirmation the operator sees."
  def matching(filter) do
    Enum.filter(list(), fn g ->
      g["status"] == "active" and
        Enum.all?(filter, fn {k, v} -> v == nil or g[k] == v end)
    end)
  end

  @doc """
  Spend one use of a one-shot grant.

  **Two arities, one boundary.** `consume_one_shot(ticket)` is the mediated
  write of E3-1: the ticket must have been signed by the journal owner of
  this epoch for `consume_grant` on this row, the lease must not be retired
  here, and the consumption must not already be witnessed — all checked by
  `Ampd.Fence.check/4` in this process, before the mutation, and persisted
  with it in one `Store.save`. The row gains the effect in `consumptions`
  and the ticket in `consumption_witness`.

  `consume_one_shot(id)` is the LEGACY, UNMEDIATED arity. It survives for
  exactly one caller — `Ampd.Conformance.authorize/4`, the journal-less
  C1.0a interface the frozen vectors are written against — and it records
  no witness. It is coordinator-only like every other authority mutation,
  and it is OUTSIDE E3-1's claim: E3-1 covers `Ampd.Gateway.perform/5`,
  which never calls it.
  """
  def consume_one_shot(ticket) when is_map(ticket), do: ask({:consume_ticket, ticket})
  def consume_one_shot(id) when is_binary(id), do: ask({:consume, id})

  @doc "Journal-owner only: install this incarnation's fence (`Ampd.Fence`)."
  def fence_epoch(epoch, key), do: ask({:fence_epoch, epoch, key})
  @doc "This resource's fence as persisted — epoch and retired leases, never the key. A read."
  def fence, do: ask(:fence)

  @doc "Journal-owner only: retire a lease at this resource; replies with the landings held under it."
  def fence_retire(lease_id, reason), do: ask({:fence_retire, lease_id, reason})
  def commit(surface), do: ask({:commit, surface})
  def reset, do: ask(:reset)
  # --- ordered-authority boundary -------------------------------------
  # These mutations are served only when the caller IS the total order.
  @ordered_ops [
    :mint,
    :draft,
    :dur,
    :revoke_domain,
    :consume,
    :consume_ticket,
    :commit,
    :reset,
    :load_state,
    :request_grant,
    :resolve_request,
    :revoke_one,
    :revoke_matching,
    :retire
  ]
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

  def handle_call(:list, _f, %{s: s} = st), do: {:reply, s["grants"], st}
  def handle_call(:active, _f, %{s: s} = st), do: {:reply, active_of(s["grants"]), st}
  def handle_call({:get, id}, _f, %{s: s} = st) do
    reply =
      case get_of(s["grants"], id) do
        nil ->
          case retired_entry(s, id) do
            [_status, batch, _cs | more] -> {:archived, batch, List.first(more)}
            _ -> nil
          end

        g ->
          g
      end

    {:reply, reply, st}
  end

  def handle_call({:retired, id}, _f, %{s: s} = st), do: {:reply, retired_entry(s, id), st}
  def handle_call(:retired_index, _f, %{s: s} = st), do: {:reply, Map.get(s, "retired", %{}), st}

  # The write fence (E3-1). Guarded by "from the journal owner", not by the
  # total order — see `Ampd.Ordered.from_journal_owner?/1`.
  def handle_call({:fence_epoch, _, _} = msg, from, st),
    do: Ampd.Fence.handle_owner_call(msg, from, st, __MODULE__, &landed_under/2)

  def handle_call({:fence_retire, _, _} = msg, from, st),
    do: Ampd.Fence.handle_owner_call(msg, from, st, __MODULE__, &landed_under/2)

  def handle_call(:requests, _f, %{s: s} = st), do: {:reply, Map.get(s, "requests", []), st}

  # A read of this resource's fence — epoch and retired set, never the key.
  def handle_call(:fence, _f, %{s: s} = st),
    do: {:reply, if(is_map(s["fence"]), do: Map.delete(s["fence"], "key"), else: nil), st}

  defp landed_under(s, lease_id) do
    s["grants"]
    |> Enum.flat_map(&(&1["consumption_witness"] || []))
    |> Enum.filter(&(&1["lease_id"] == lease_id))
    |> Enum.map(&Map.put(&1, "op", "consume_grant"))
  end

  # --- ordered implementations (reached only via the guard above) ----
  def handle_ordered({:load_state, s}, st) do
    tab = st.tab || Ampd.Store.open!(@store)

    {:reply, :ok,
     %{st | tab: tab, s: Ampd.Store.save(tab, Ampd.Fence.carry(s, st.s)), sealed: nil}}
  end

  # A grant whose duration this system cannot enforce must never reach the
  # store. `Core.duration_ok/3` used to end in `_ -> true`, so a grant
  # minted with `"forever"` satisfied every scope check there is; both ends
  # are closed now, and this is the one that stops it being written down.
  def handle_ordered({:mint, f}, %{tab: tab, s: s} = st) do
    dur = f["duration"] || s["dur"] || "workspace"
    cap = f["capability"]

    cond do
      not Ampd.Core.duration?(dur) ->
        {:reply, {:refused, invalid_duration(dur)}, st}

      # A capability no *installed* pack declares must not be grantable.
      # Refusing it at the gateway alone leaves the dormant grant on disk,
      # waiting for the install that would activate it — and *installation
      # confers zero authority* is the oldest law here.
      cap != nil and not installed_surface?(cap) ->
        {:reply, {:refused, undeclared_capability(cap)}, st}

      true ->
        {g, s2} = do_mint(s, Map.put(f, "duration", dur))
        {:reply, g, %{st | s: Ampd.Store.save(tab, s2)}}
    end
  end

  def handle_ordered({:revoke_one, id}, %{tab: tab, s: s} = st) do
    case Enum.find(s["grants"], &(&1["id"] == id and &1["status"] == "active")) do
      nil ->
        {:reply, {:refused, unknown_grant(id)}, st}

      g ->
        grants =
          Enum.map(s["grants"], fn x ->
            if x["id"] == id, do: %{x | "status" => "revoked"}, else: x
          end)

        {:reply, %{g | "status" => "revoked"},
         %{st | s: Ampd.Store.save(tab, %{s | "grants" => grants})}}
    end
  end

  # The linearization point. `current` is sampled here, inside the ordered
  # transaction, from the same state the write below lands on — so no other
  # write can interleave between the confirmation and the revocation.
  def handle_ordered({:revoke_matching, filter, expected_ids}, %{tab: tab, s: s} = st) do
    current =
      s["grants"]
      |> Enum.filter(fn g ->
        g["status"] == "active" and Enum.all?(filter, fn {k, v} -> v == nil or g[k] == v end)
      end)
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    expected = Enum.sort(expected_ids)

    if current != expected do
      {:reply, {:refused, bulk_scope_changed(filter, expected, current)}, st}
    else
      hit = MapSet.new(current)

      grants =
        Enum.map(s["grants"], fn g ->
          if MapSet.member?(hit, g["id"]), do: %{g | "status" => "revoked"}, else: g
        end)

      {:reply, current, %{st | s: Ampd.Store.save(tab, %{s | "grants" => grants})}}
    end
  end

  def handle_ordered({:draft, k, v}, %{tab: tab, s: s} = st),
    do: {:reply, :ok, %{st | s: Ampd.Store.save(tab, put_in(s, ["draft", k], v))}}

  # `Map.get`/`Map.put` rather than the `%{s | …}` update syntax: a store
  # written before `requests` existed has no such key, and a registry that
  # crashes on a field it added in a later build is a store that upgrades
  # by breaking.
  # A request an agent may make, but not one the runtime cannot express.
  #
  # Two things are refused here rather than at approval, and both are
  # refused for the same reason: a durable pending object that can never
  # become a valid grant is a trap with a human's click at the end of it.
  #
  # 1. **An unenforceable duration.** `"forever"` used to create a request.
  #    Approving it was then supposed to be caught by the narrowing guard —
  #    except `Core.duration_rank("forever")` is `nil`, and in Elixir's term
  #    order `nil` sorts *above* every integer, so `rank(any) > nil` is
  #    `false` and the guard was silently open for **every** approval of a
  #    malformed request, not merely the widening ones. Reproduced: a
  #    request for `"forever"` approved as `"once"` minted a grant, and so
  #    would `"workspace"`. An agent asking for something this runtime
  #    cannot express does not need a durable object; it needs an answer.
  #
  # 2. **A capability no installed pack declares.** `mint` already refuses
  #    it, so the request could only ever end in a refusal a person had to
  #    click to discover.
  def handle_ordered({:request_grant, f}, %{tab: tab, s: s} = st) do
    n = Map.get(s, "req_seq", 1)
    id = "gq_" <> String.pad_leading(Integer.to_string(n), 4, "0")
    dur = Map.get(f, "requested_duration") || "workspace"
    cap = f["capability"]

    cond do
      not Ampd.Core.duration?(dur) ->
        {:reply, {:refused, invalid_duration(dur)}, st}

      cap != nil and not installed_surface?(cap) ->
        {:reply, {:refused, undeclared_capability(cap)}, st}

      true ->
        q =
          Map.merge(
            %{
              "schema" => "grant-request@1",
              "id" => id,
              "status" => "pending",
              "resource" => "traaviis/trvm",
              "reason" => nil,
              "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            },
            f
          )
          |> Map.put("requested_duration", dur)
          |> Map.merge(pack_binding(cap))

        s2 =
          s
          |> Map.put("requests", Map.get(s, "requests", []) ++ [q])
          |> Map.put("req_seq", n + 1)

        {:reply, q, %{st | s: Ampd.Store.save(tab, s2)}}
    end
  end

  def handle_ordered({:resolve_request, id, status, note}, %{tab: tab, s: s} = st) do
    rs =
      Enum.map(Map.get(s, "requests", []), fn q ->
        if q["id"] == id and q["status"] == "pending" do
          q |> Map.put("status", status) |> Map.put("resolution_note", note)
        else
          q
        end
      end)

    found = Enum.find(rs, &(&1["id"] == id))
    {:reply, found, %{st | s: Ampd.Store.save(tab, Map.put(s, "requests", rs))}}
  end

  def handle_ordered({:dur, d}, %{tab: tab, s: s} = st),
    do: {:reply, :ok, %{st | s: Ampd.Store.save(tab, %{s | "dur" => d})}}

  def handle_ordered({:revoke_domain, cap}, %{tab: tab, s: s} = st) do
    grants =
      Enum.map(s["grants"], fn g ->
        if g["capability"] == cap and g["status"] == "active",
          do: %{g | "status" => "revoked"},
          else: g
      end)

    {:reply, :ok, %{st | s: Ampd.Store.save(tab, %{s | "grants" => grants})}}
  end

  # The mediated consumption. Fence first, then the row's own witness,
  # then the mutation and the witness in ONE save.
  def handle_ordered({:consume_ticket, ticket}, %{tab: tab, s: s} = st) do
    target = if is_map(ticket), do: ticket["target"], else: nil
    g = target && get_of(s["grants"], target)

    verdict =
      with :ok <- Ampd.Fence.check(s["fence"], ticket, "consume_grant", target) do
        cond do
          g == nil ->
            case retired_entry(s, target) do
              [status, _batch, cs | _] ->
                if ticket["effect"] in cs,
                  do:
                    {:refused, "write-duplicate",
                     "#{ticket["effect"]}'s consumption of #{target} is already witnessed (retired)"},
                  else:
                    {:refused, "write-unscoped",
                     "grant #{target} is #{status} and retired; it can never be spent again"}

              _ ->
                {:refused, "write-unscoped", "no grant #{inspect(target)}"}
            end

          ticket["effect"] in (g["consumptions"] || []) or
              Enum.any?(g["consumption_witness"] || [], &(&1["ticket_id"] == ticket["ticket_id"])) ->
            {:refused, "write-duplicate",
             "#{ticket["effect"]}'s consumption of #{target} is already witnessed"}

          true ->
            :ok
        end
      end

    case verdict do
      {:refused, code, why} ->
        {:reply,
         {:refused, Ampd.Fence.refusal(s["fence"], code, why, ticket, "Ampd.GrantRegistry")}, st}

      :ok ->
        left = (g["uses_remaining"] || 0) - 1

        g2 =
          g
          |> Map.put("uses_remaining", left)
          |> Map.put("status", if(left == 0, do: "consumed", else: g["status"]))
          |> Map.put("consumptions", (g["consumptions"] || []) ++ [ticket["effect"]])
          |> Map.put(
            "consumption_witness",
            (g["consumption_witness"] || []) ++ [Ampd.Fence.witness_of(ticket)]
          )

        grants = List.replace_at(s["grants"], pos_of(s["grants"], target), g2)

        st = %{st | s: Ampd.Store.save(tab, %{s | "grants" => grants})}

        witness = %{
          "ticket_id" => ticket["ticket_id"],
          "proof" => Ampd.Fence.proof(s["fence"], ticket, "landed")
        }

        {:reply, {:ok, witness}, st}
    end
  end

  def handle_ordered({:retire, archived, batch}, %{tab: tab, s: s} = st) do
    ids = Enum.map(archived, & &1["id"])
    rows = Enum.map(ids, &{&1, get_of(s["grants"], &1)})
    moved = Enum.find(Enum.zip(rows, archived), fn {{_id, g}, a} -> g !== a end)

    case Enum.find(rows, fn {_id, g} -> g == nil or g["status"] == "active" end) do
      {id, g} ->
        {:reply,
         {:refused,
          Ampd.Refusal.new("retire-not-settled",
            component: "Ampd.GrantRegistry",
            retryable: true,
            requires_human: false,
            public_message: "A grant in the retirement batch is not used up.",
            operator_detail: %{"grant" => id, "status" => g && g["status"]}
          )}, st}

      # The archive holds a grant this list no longer has; see `Ampd.Effects`.
      nil when moved != nil ->
        {{id, _g}, _a} = moved

        {:reply,
         {:refused,
          Ampd.Refusal.new("retire-row-changed",
            component: "Ampd.GrantRegistry",
            retryable: true,
            requires_human: false,
            public_message: "A grant changed after it was archived for retirement.",
            operator_detail: %{"grant" => id, "batch" => batch}
          )}, st}

      nil ->
        set = MapSet.new(ids)

        # Each entry commits the digest of the WORKING row, in the same record
        # that removes it from the list.
        index =
          Map.merge(
            Map.get(s, "retired", %{}),
            Map.new(rows, fn {id, g} ->
              {id,
               [
                 g["status"],
                 batch,
                 g["consumptions"] || [],
                 Ampd.AuthorityLog.RowDigest.of(@store, "id", id, batch, g)
               ]}
            end)
          )

        s2 =
          s
          |> Map.put("grants", Enum.reject(s["grants"], &MapSet.member?(set, &1["id"])))
          |> Map.put("retired", index)

        {:reply, {:ok, length(ids)}, %{st | s: Ampd.Store.save(tab, s2)}}
    end
  end

  # LEGACY, UNMEDIATED (see `consume_one_shot/1`): no witness is recorded.
  def handle_ordered({:consume, id}, %{tab: tab, s: s} = st) do
    grants =
      Enum.map(s["grants"], fn g ->
        if g["id"] == id do
          left = (g["uses_remaining"] || 0) - 1

          %{
            g
            | "uses_remaining" => left,
              "status" => if(left == 0, do: "consumed", else: g["status"])
          }
        else
          g
        end
      end)

    {:reply, :ok, %{st | s: Ampd.Store.save(tab, %{s | "grants" => grants})}}
  end

  def handle_ordered({:commit, surface}, %{tab: tab, s: s} = st) do
    {s, changed} =
      Enum.reduce(Map.keys(surface), {s, []}, fn key, {s, ch} ->
        if surface[key]["deny"] do
          {s, ch}
        else
          cap = "github." <> key
          want = !!get_in(s, ["draft", key])

          domain =
            Enum.filter(s["grants"], fn g ->
              g["status"] == "active" and g["capability"] == cap and
                g["actor"] == "kestrel" and g["resource"] == "traaviis/trvm"
            end)

          cond do
            not want and domain != [] ->
              ids = Enum.map(domain, & &1["id"]) |> MapSet.new()

              grants =
                Enum.map(s["grants"], fn g ->
                  if MapSet.member?(ids, g["id"]), do: %{g | "status" => "revoked"}, else: g
                end)

              {%{s | "grants" => grants}, ch ++ ["-" <> cap]}

            not want ->
              {s, ch}

            true ->
              keep =
                Enum.find(domain, fn g ->
                  g["duration"] == s["dur"] and
                    (g["duration"] != "once" or (g["uses_remaining"] || 0) > 0) and
                    g["placement"] == ["local", "fleet"]
                end)

              drop = Enum.filter(domain, &(&1 != keep)) |> Enum.map(& &1["id"]) |> MapSet.new()

              grants =
                Enum.map(s["grants"], fn g ->
                  if MapSet.member?(drop, g["id"]), do: %{g | "status" => "revoked"}, else: g
                end)

              s = %{s | "grants" => grants}
              ch = ch ++ if(MapSet.size(drop) > 0, do: ["~" <> cap], else: [])

              if keep do
                {s, ch}
              else
                f =
                  if s["dur"] == "once",
                    do: %{"capability" => cap, "duration" => "once", "uses_remaining" => 1},
                    else: %{"capability" => cap, "duration" => s["dur"]}

                {g, s2} = do_mint(s, f)
                {s2, ch ++ ["+" <> g["id"]]}
              end
          end
        end
      end)

    {:reply, changed, %{st | s: Ampd.Store.save(tab, s)}}
  end

  def handle_ordered(:reset, %{tab: tab} = st),
    do: {:reply, :ok, %{st | s: Ampd.Store.save(tab, Ampd.Fence.carry(initial(), st.s))}}

  # --- what the ordered implementations check and raise ---------------

  # **Which pack contract was this asked under.**
  #
  # A request for `github.issue.write` created while GitHub 1.5 is
  # installed can sit pending while the pack goes to 2.0 and redefines what
  # that capability reaches or where its data may go. The human then
  # approves a sentence whose meaning changed underneath it.
  #
  # So the request records the pack, its version, and a digest over the
  # authority-relevant part of its surface. `Ampd.Authority` compares the
  # digest at approval and refuses `grant-request-stale` if it moved. This
  # is the same rule as `approval-intent@1`'s exact-match, one level up:
  # consent binds to a contract, not to a capability name.
  defp pack_binding(nil), do: %{}

  defp pack_binding(cap) do
    name = Ampd.Core.pack_of(cap)

    case Ampd.CapabilityRegistry.get(name) do
      nil ->
        %{}

      pk ->
        %{
          "pack" => name,
          "pack_version" => pk["version"],
          "pack_digest" => Ampd.Core.pack_digest(pk)
        }
    end
  end

  defp installed_surface?(cap) do
    pk = Ampd.CapabilityRegistry.get(Ampd.Core.pack_of(cap))

    pk != nil and pk["installation"] in ["installed", "builtin"] and
      is_map(pk["surface"]) and Map.has_key?(pk["surface"], Ampd.Core.cap_key(cap))
  end

  defp invalid_duration(dur) do
    Ampd.Refusal.new("invalid-grant-duration",
      component: "Ampd.GrantRegistry",
      retryable: false,
      requires_human: true,
      operator_detail: %{
        "given" => inspect(dur),
        "allowed" => Ampd.Core.durations(),
        "hint" =>
          "an unenforceable duration is an unbounded grant: it outlives its run, " <>
            "survives a workspace change, and never spends a use"
      }
    )
  end

  defp undeclared_capability(cap) do
    Ampd.Refusal.new("capability-undeclared",
      component: "Ampd.GrantRegistry",
      retryable: false,
      requires_human: true,
      public_message: "No installed pack declares that capability.",
      operator_detail: %{
        "capability" => cap,
        "hint" =>
          "a grant for an undeclared capability lies dormant until the pack is installed, " <>
            "and then installation activates authority nobody granted afterwards"
      }
    )
  end

  # Names the difference in both directions. "The set changed" is not
  # actionable; "gr_0199 appeared and gr_0194 is gone" is what tells the
  # operator whether to re-read and confirm again or to stop and look at
  # who else is holding this world open.
  defp bulk_scope_changed(filter, expected, current) do
    Ampd.Refusal.new("bulk-scope-changed",
      component: "Ampd.GrantRegistry",
      retryable: true,
      requires_human: true,
      public_message: "The set of grants this would revoke is not the set you confirmed.",
      operator_detail: %{
        "scope" => filter,
        "confirmed" => expected,
        "matches_now" => current,
        "appeared" => current -- expected,
        "gone" => expected -- current,
        "hint" =>
          "a count cannot detect this: two grants revoked and two minted between the render " <>
            "and the click leaves the count identical and the set completely different"
      }
    )
  end

  defp unknown_grant(id) do
    Ampd.Refusal.new("grant-unknown",
      component: "Ampd.GrantRegistry",
      retryable: false,
      requires_human: true,
      public_message: "No such active grant.",
      operator_detail: %{"grant_id" => id}
    )
  end
end
