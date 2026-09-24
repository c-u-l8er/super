defmodule Ampd.Effects do
  @moduledoc """
  The durable effect journal — `effect-request@1` and `effect-attempt@1` —
  and, since B2, the **journal owner** of E3-1: the process that issues
  leases, signs tickets, retires leases with every declared participant's
  acknowledgment, and writes the single-writer witness log.

      PROPOSED → AUTHORIZED → APPROVED → CLAIMED → ATTEMPTED
                                                    ├→ COMMITTED
                                                    ├→ FAILED
                                                    └→ UNKNOWN → RECONCILE

  Two properties make the journal work, and neither is a storage feature:

  1. **The claim is a single serialization point.** `claim/1` is one
     `GenServer.call`, so two racing exercises cannot both claim the same
     proposal — the second is refused by name.

  2. **CLAIMED is durable before consent is consumed, and ATTEMPTED is
     durable before any adapter is called.** (That is the guarantee at its
     real width — `WEK_R3_ADMISSION_PROPOSAL.md` §3.2 withdrew "the journal
     is written before the world is touched".)

  ## The write boundary (B2, `SUPER_B2_WRITE_BOUNDARY_DESIGN.md`)

  Re-checking permission in the writing process does not close the
  authorisation-to-write race; it moves it. So the safety property lives
  **in the resource**: each participant keeps a persisted fence
  (`Ampd.Fence`) and refuses, in the same `Store.save` as its mutation, any
  ticket whose epoch is not the fence's, whose signature it cannot verify,
  or whose lease it has already retired. This process:

  * mints an **epoch** and a random **key** per incarnation, persists the
    epoch sequence in its own store, and pushes both to every participant
    **before serving anything** (`init` and the ordered `load_state`);
  * issues a **lease** inside `{:claim}` (coordinator-only) and signs the
    lease token — the table is process memory, the durable fact is the
    journal record with its `branch`;
  * answers `authorize_write/3` with a signed single-use **ticket** or the
    first refusal in `REFUSAL_ORDER` (`Ampd.Effects.Contract.authorize/7`);
  * accepts a **terminal** (`landed/2`, `refused/3`) only with the
    participant's own proof, and appends it to the log; the landing that
    completes the last required op retires the lease `completed`;
  * on `FAILED` / `UNKNOWN` runs the **acknowledged retirement**: each
    declared participant persists the retirement and replies with the
    landings it already holds under that lease — those are logged
    *before* the transition, so log order is mutation order, not report
    arrival order — and only then is the transition journaled and the lease
    retired `closed`;
  * takes the lease on `attempt/2` (S-1 enforced: every `required_at_claim`
    op must have landed) and `commit/2`; `fail/2` and `unknown/2` take the
    effect id, because recovery calls them when no lease exists.

  Restart: the new incarnation's epoch reaches every participant before this
  process serves a message, so every old-epoch ticket is `write-lease-stale`
  from then on; no per-lease retirement is needed after a restart and none
  is attempted. `recover!/0` moves CLAIMED / ATTEMPTED to UNKNOWN as before.

  Call order (acyclic, and the reason there is no deadlock): the
  coordinator → this process → participants → nothing that calls back. A
  participant never calls this process; a report travels with the caller
  that performed the write.

  A persistence or log-append failure raises inside this process: the
  transition is then never acknowledged (the caller sees an exit, or an
  `Ampd.Participant.Failure` inside the total order), which is the only
  honest answer for a durable transition that did not complete.
  """
  use GenServer
  alias Ampd.Effects.{Contract, Witness}
  alias Ampd.Fence
  @store "effects"

  @terminal ~w(COMMITTED FAILED)
  @in_flight ~w(CLAIMED ATTEMPTED)

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  # ------------------------------------------------- participant boundary
  #
  # C1.0b·2·1. Inside `Ampd.AuthorityCoordinator`, a bare `GenServer.call`
  # that fails EXITS the caller — and the caller there is the total order.
  # Every tag NOT named below is a read. `authorize_write`, `landed` and
  # `refused` mutate the lease table and append to the log: a timeout on
  # them is INDETERMINATE, not a refusal.
  @participant_mutations ~w(close_store load_state propose to claim attempt commit recover
                            authorize_write landed refused witness_state witness_listing
                            flush_deferred)a

  defp ask(msg, timeout \\ 5_000) do
    tag = if is_tuple(msg), do: elem(msg, 0), else: msg
    Ampd.Participant.call(__MODULE__, msg, class(tag), timeout: timeout)
  end

  @doc false
  def class(tag), do: if(tag in @participant_mutations, do: :mutate, else: :read)

  @impl true
  def init(:ok) do
    case Ampd.Store.boot(@store, &initial/0) do
      {:ok, tab, s} ->
        {:ok, incarnate(%{tab: tab, s: s, ix: index(s), sealed: nil, inc: nil})}

      {:sealed, reason} ->
        {:ok, %{tab: nil, s: sealed_state(), ix: %{}, sealed: reason, inc: nil}}
    end
  end

  def initial, do: %{"effects" => [], "seq" => 1}
  def sealed_state, do: %{"effects" => [], "seq" => 0}

  def sealed, do: ask(:sealed)
  def close_store, do: ask(:close_store)
  def load_state(s), do: ask({:load_state, s})
  def all, do: ask(:all)

  # Looked up here, not by copying every effect out of this process to find
  # one: the copy grew with history (0.1 ms at an empty journal, 15–21 ms at
  # 2,000, measured).
  def get(id), do: ask({:get, id})
  def count, do: length(all())

  @doc """
  Open a proposal. `env["branch"]` is the one declaration field the
  journal takes: `Ampd.Authority` computes it from `decide/4`'s two
  booleans (T2). The three obligation sets are DERIVED from it, never
  supplied. A missing or unknown branch is `intent-invalid`.
  """
  def propose(env), do: ask({:propose, env})

  def authorized(id, meta), do: ask({:to, id, "AUTHORIZED", meta})
  def approved(id, meta), do: ask({:to, id, "APPROVED", meta})

  @doc """
  Take exclusive ownership of a proposal and receive its lease. Durable
  *before* any grant or approval is consumed. `{:ok, effect, lease}`,
  `{:error, why}` or `{:refused, refusal@1}`.
  """
  def claim(id), do: ask({:claim, id})

  @doc "Durable before the adapter is touched; refused unless every `required_at_claim` op has landed (S-1)."
  def attempt(lease, adapter), do: ask({:attempt, lease, adapter})

  def commit(lease, result), do: ask({:commit, lease, result})
  def fail(id, why), do: ask({:to, id, "FAILED", %{"reason" => why}})
  def unknown(id, why), do: ask({:to, id, "UNKNOWN", %{"reason" => why}})

  @doc "A signed single-use ticket for `op` on `target` under `lease`, or the first refusal in REFUSAL_ORDER."
  def authorize_write(lease, op, target), do: ask({:authorize_write, lease, op, target})

  @doc "Report a landing. `witness` is what the participant replied (`%{\"ticket_id\", \"proof\"}`)."
  def landed(ticket, witness), do: ask({:landed, ticket, witness})

  @doc "Report a participant's refusal after authorisation, with the participant's proof."
  def refused(ticket, code, proof), do: ask({:refused, ticket, code, proof})

  @doc false
  # Write the witness lines held for a committed authority transaction.
  def flush_deferred, do: ask(:flush_deferred)

  @doc "Boot-time truth: anything still CLAIMED or ATTEMPTED is UNKNOWN."
  def recover!, do: ask(:recover)

  def reconcile_queue, do: Enum.filter(all(), &(&1["state"] == "UNKNOWN"))
  def terminal?(e), do: e["state"] in @terminal

  @doc "The current incarnation: epoch, log position, log path. A read."
  def incarnation, do: ask(:incarnation)

  @doc """
  The read-only recovery listing (decision 6): a pure read over the journal
  as found on disk and the three participant stores as read now. It lists;
  it never repairs. Callable before or after `recover!/0` — the crash phase
  it reports comes from the `crashed while …` entry `recover!` appends.
  """
  def recovery_listing, do: Contract.listing(all(), stores())

  @doc false
  # The three participant stores, read fresh. Used by the listing and, in
  # evidence mode, for the harness's snapshots. Reads only.
  def stores do
    %{
      "approvals" => Ampd.Approvals.all(),
      "grants" => Ampd.GrantRegistry.list(),
      "receipts" => Ampd.Receipts.all()
    }
  end

  @doc false
  # EVIDENCE MODE, harness-only: append a `state` / `post_crash_state` read,
  # or the listing, to the single-writer log. Production never calls these.
  def witness_state(type) when type in ["state", "post_crash_state"],
    do: ask({:witness_state, type})

  def witness_listing, do: ask(:witness_listing)

  # --- ordered-authority boundary -------------------------------------
  @ordered_ops [:claim, :propose, :load_state]
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
    if st.inc, do: Witness.close(st.inc.log)
    {:reply, :ok, %{st | tab: nil, inc: nil}}
  end

  def handle_call(:all, _f, %{s: s} = st), do: {:reply, s["effects"], st}

  def handle_call({:get, id}, _f, st), do: {:reply, lookup(st, id), st}

  # The witness lines of an authority transaction's writes wait for its commit
  # (`Ampd.AuthorityLog.group/1`), because a witness line follows the durable
  # fact it witnesses. The transaction's owner calls this once it committed.
  def handle_call(:flush_deferred, _f, %{inc: %{deferred: [_ | _]} = inc} = st) do
    st = %{st | inc: %{inc | deferred: []}}
    {:reply, :ok, Enum.reduce(Enum.reverse(inc.deferred), st, &append_witness(&2, &1))}
  end

  def handle_call(:flush_deferred, _f, st), do: {:reply, :ok, st}

  def handle_call(:incarnation, _f, %{inc: nil} = st), do: {:reply, nil, st}

  def handle_call(:incarnation, _f, %{inc: inc} = st),
    do:
      {:reply, %{"epoch" => inc.epoch, "tseq" => inc.tseq, "path" => Witness.path(inc.epoch)}, st}

  # Every unordered mutation below refuses by name on a sealed journal —
  # raising would take the caller down with a store that is merely absent.
  def handle_call(msg, _f, %{sealed: reason} = st) when reason != nil and msg != :recover do
    tag = if is_tuple(msg), do: elem(msg, 0), else: msg
    {:reply, {:refused, Ampd.Ordered.sealed_refusal(reason, tag, __MODULE__)}, st}
  end

  # Between `close_store` and `load_state` there is no incarnation: no epoch,
  # no key, no log. The lease operations refuse by name rather than crash.
  def handle_call(msg, _f, %{inc: nil} = st)
      when is_tuple(msg) and
             elem(msg, 0) in [
               :authorize_write,
               :landed,
               :refused,
               :attempt,
               :commit,
               :witness_state
             ] do
    {:reply, {:refused, owner_refusal("journal-owner-not-incarnated", nil, nil, nil, nil)}, st}
  end

  def handle_call(:witness_listing, _f, %{inc: nil} = st),
    do:
      {:reply, {:refused, owner_refusal("journal-owner-not-incarnated", nil, nil, nil, nil)}, st}

  # ---------------------------------------------------- lifecycle writes
  def handle_call({:to, id, state, meta}, _f, st) when state in ["AUTHORIZED", "APPROVED"] do
    case transition(st, id, state, meta) do
      {:ok, e, st} -> {:reply, e, st}
      {:refused, r} -> {:reply, {:refused, r}, st}
    end
  end

  # S-3. The edge is ADMITTED first (`admit/3`, the same check `transition/4`
  # makes), the acknowledged retirement second, the durable transition
  # third. A FAILED / UNKNOWN that the journal would refuse must not retire
  # anything at any participant.
  def handle_call({:to, id, state, meta}, _f, st) when state in ["FAILED", "UNKNOWN"] do
    with {:ok, _} <- admit(st, id, state),
         st = retire_at_participants(st, id),
         {:ok, e, st} <- transition(st, id, state, meta) do
      {:reply, e, close_leases(st, id)}
    else
      {:refused, r} -> {:reply, {:refused, r}, st}
    end
  end

  def handle_call({:attempt, lease, adapter}, _f, st) do
    with {:ok, l} <- live_lease(st, lease),
         :ok <- sequencing(l) do
      e0 = lookup(st, l.effect) || %{"attempts" => []}
      n = length(e0["attempts"]) + 1

      a = %{
        "kind" => "effect-attempt@1",
        "id" => l.effect <> "-a" <> Integer.to_string(n),
        "adapter" => adapter,
        "idempotency_key" => e0["idempotency_key"],
        "started_at" => now(),
        "outcome" => nil
      }

      case transition(st, l.effect, "ATTEMPTED", %{"__attempt" => a}) do
        {:ok, e, st} -> {:reply, {:ok, e, a}, st}
        {:refused, r} -> {:reply, {:refused, r}, st}
      end
    else
      {:refused, r} -> {:reply, {:refused, r}, st}
    end
  end

  def handle_call({:commit, lease, result}, _f, st) do
    with {:ok, l} <- live_lease(st, lease),
         {:ok, e, st} <- transition(st, l.effect, "COMMITTED", %{"result" => result}) do
      {:reply, e, st}
    else
      {:refused, r} -> {:reply, {:refused, r}, st}
    end
  end

  # ----------------------------------------------------- lease authority
  def handle_call({:authorize_write, lease, op, target}, _f, %{inc: inc} = st) do
    effect_of = fn id -> lookup(st, id) end
    token_ok? = fn token -> Fence.lease_valid?(inc.key, token) end

    ticket_id = "tk-#{inc.epoch}-#{inc.n_ticket + 1}"
    inc = %{inc | n_ticket: inc.n_ticket + 1}
    st = %{st | inc: inc}
    st = snapshot(st, ticket_id, "before")

    # What the log says was presented. A value that names another epoch is
    # logged as presented (the verifier derives `write-lease-stale` from the
    # epoch). A current-epoch value whose signature does not verify was
    # never issued by this owner — in E3-1 a lease is a reference, and a
    # value reconstructed from data is a different reference (R4) — so it
    # is logged as no lease, which is what the owner concluded.
    presented? =
      is_map(lease) and (lease["epoch"] != inc.epoch or Fence.lease_valid?(inc.key, lease))

    lease_id = if presented?, do: lease["lease_id"], else: nil
    lease_epoch = if presented?, do: lease["epoch"], else: nil

    base = %{
      "type" => "ticket_authorized",
      "ticket_id" => ticket_id,
      "lease_id" => lease_id,
      "lease_epoch" => lease_epoch,
      "op" => op,
      "store" => Contract.store_of(op),
      "target" => target,
      "epoch" => inc.epoch
    }

    case Contract.authorize(inc.epoch, inc.leases, effect_of, lease, op, target, token_ok?) do
      {:ok, l} ->
        ticket =
          Fence.sign_ticket(inc.key, %{
            "ticket_id" => ticket_id,
            "lease_id" => l.id,
            "effect" => l.effect,
            "op" => op,
            "target" => target,
            "epoch" => inc.epoch
          })

        st = log(st, Map.merge(base, %{"verdict" => "ok", "code" => nil}))
        {:reply, {:ok, ticket}, st}

      {:refused, code} ->
        st = log(st, Map.merge(base, %{"verdict" => "refused", "code" => code}))
        st = snapshot(st, ticket_id, "after")
        {:reply, {:refused, owner_refusal(code, lease, op, target, ticket_id)}, st}
    end
  end

  def handle_call({:landed, ticket, witness}, _f, %{inc: inc} = st) do
    cond do
      not Fence.ticket_valid?(inc.key, ticket) ->
        {:reply,
         {:refused, owner_refusal("write-unmediated", nil, nil, nil, Fence.ticket_id(ticket))},
         st}

      not (is_map(witness) and
               Fence.proof_valid?(inc.key, ticket, "landed", witness["proof"])) ->
        {:reply,
         {:refused,
          owner_refusal(
            "landing-unproven",
            nil,
            ticket["op"],
            ticket["target"],
            ticket["ticket_id"]
          )}, st}

      true ->
        {:reply, :ok, record_landing(st, ticket)}
    end
  end

  def handle_call({:refused, ticket, code, proof}, _f, %{inc: inc} = st) do
    tid = Fence.ticket_id(ticket)

    cond do
      tid == nil or not Fence.proof_valid?(inc.key, ticket, "refused", proof) ->
        {:reply, {:refused, owner_refusal("refusal-unproven", nil, nil, nil, tid)}, st}

      MapSet.member?(inc.terminals, tid) ->
        {:reply, :ok, st}

      true ->
        st = %{st | inc: %{inc | terminals: MapSet.put(inc.terminals, tid)}}
        st = log(st, %{"type" => "refused", "ticket_id" => tid, "code" => code})
        {:reply, :ok, snapshot(st, tid, "after")}
    end
  end

  # ------------------------------------------------------------ recovery
  def handle_call(:recover, _f, %{sealed: reason} = st) when reason != nil, do: {:reply, [], st}

  def handle_call(:recover, _f, %{tab: tab, s: s} = st) do
    {effects, moved} =
      Enum.map_reduce(s["effects"], [], fn e, acc ->
        # Only the in-flight states move, and both edges are in TRANSITIONS;
        # checked here with the same table rather than assumed.
        if e["state"] in @in_flight and Contract.legal_transition?(e["state"], "UNKNOWN") do
          why =
            "crashed while #{e["state"]} — the adapter may or may not have run; " <>
              "replay is safe only against idempotency key #{e["idempotency_key"]}"

          {e
           |> Map.put("state", "UNKNOWN")
           |> Map.put("reason", why)
           |> Map.put("needs_reconcile", true)
           |> Map.update(
             "history",
             [],
             &(&1 ++ [%{"state" => "UNKNOWN", "at" => now(), "reason" => why}])
           ), acc ++ [{e["id"], why}]}
        else
          {e, acc}
        end
      end)

    st = %{st | s: Ampd.Store.save(tab, %{s | "effects" => effects})}
    st = %{st | ix: index(st.s)}

    st =
      Enum.reduce(moved, st, fn {id, why}, st ->
        log(st, %{"type" => "journal", "effect" => id, "state" => "UNKNOWN", "reason" => why})
      end)

    {:reply, Enum.map(moved, &elem(&1, 0)), st}
  end

  # -------------------------------------------------- evidence mode only
  def handle_call({:witness_state, type}, _f, st),
    do: {:reply, :ok, log(st, %{"type" => type, "state" => stores()})}

  def handle_call(:witness_listing, _f, %{s: s} = st) do
    listing = Contract.listing(s["effects"], stores())
    {:reply, listing, log(st, %{"type" => "recovery_listing", "listing" => listing})}
  end

  # --- ordered implementations (reached only via the guard above) ----
  def handle_ordered({:load_state, s}, st) do
    tab = st.tab || Ampd.Store.open!(@store)
    if st.inc, do: Witness.close(st.inc.log)
    s = Ampd.Store.save(tab, s)
    {:reply, :ok, incarnate(%{st | tab: tab, s: s, ix: index(s), sealed: nil, inc: nil})}
  end

  def handle_ordered({:propose, env}, %{tab: tab, s: s} = st) do
    branch = env["branch"]

    if not Contract.branch?(branch) do
      {:reply,
       {:error,
        "intent-invalid · branch #{inspect(branch)} is not one of #{Enum.join(Map.keys(Contract.branches()), " / ")}"},
       st}
    else
      id = "ef_" <> String.pad_leading(Integer.to_string(s["seq"]), 4, "0")

      e = %{
        "kind" => "effect-request@1",
        "id" => id,
        "state" => "PROPOSED",
        "idempotency_key" => env["effect_key"],
        "approval_digest" => env["approval_digest"],
        "capability" => env["capability"],
        "pack" => env["pack"],
        "actor" => env["actor"],
        "resource" => env["resource"],
        "request_id" => env["request_id"],
        "request_revision" => env["request_revision"],
        "request" => env["request"],
        # T2: written from decide/4's booleans by Ampd.Authority, never by a caller.
        "branch" => branch,
        "grant_ref" => env["grant_ref"],
        "approval_ref" => env["approval_ref"],
        "authority_snapshot_at_entry" => nil,
        "placement" => nil,
        "attempts" => [],
        "history" => [%{"state" => "PROPOSED", "at" => now()}]
      }

      st = %{
        st
        | s: Ampd.Store.save(tab, %{s | "effects" => s["effects"] ++ [e], "seq" => s["seq"] + 1}),
          ix: Map.put(st.ix, id, e)
      }

      st =
        log(
          st,
          Map.merge(
            %{
              "type" => "journal",
              "effect" => id,
              "state" => "PROPOSED",
              "branch" => branch,
              "grant_ref" => e["grant_ref"],
              "approval_ref" => e["approval_ref"]
            },
            Contract.sets(branch)
          )
        )

      {:reply, e, st}
    end
  end

  def handle_ordered({:claim, id}, %{inc: inc} = st) do
    case lookup(st, id) do
      nil ->
        {:reply, {:error, "effect-unknown · " <> id}, st}

      %{"state" => st_now} = e when st_now in @in_flight ->
        {:reply, {:error, "effect-already-claimed · " <> id <> " is " <> e["state"]}, st}

      %{"state" => st_now} when st_now in @terminal ->
        {:reply, {:error, "effect-settled · " <> id <> " is already " <> st_now}, st}

      %{"state" => "UNKNOWN"} = e ->
        {:reply,
         {:error,
          "effect-unreconciled · " <>
            id <>
            " is UNKNOWN — reconcile against idempotency key " <>
            to_string(e["idempotency_key"]) <> " before claiming it again"}, st}

      e0 ->
        # PROPOSED → CLAIMED is not an edge: AUTHORIZED must come first. The
        # guard below is the same one every other transition passes.
        case transition(st, id, "CLAIMED", %{}) do
          {:refused, r} -> {:reply, {:refused, r}, st}
          {:ok, e, st} -> issue_lease(st, e0, e, id, inc)
        end
    end
  end

  defp issue_lease(st, e0, e, id, inc) do
    lease_id = "ls-#{inc.epoch}-#{inc.n_lease + 1}"

    lease = %{
      id: lease_id,
      effect: id,
      epoch: inc.epoch,
      branch: e0["branch"],
      done: MapSet.new(),
      retired: nil
    }

    inc = %{
      st.inc
      | n_lease: inc.n_lease + 1,
        leases: Map.put(st.inc.leases, lease_id, lease)
    }

    st =
      log(%{st | inc: inc}, %{
        "type" => "lease_issued",
        "lease_id" => lease_id,
        "effect" => id,
        "epoch" => inc.epoch
      })

    token =
      Fence.sign_lease(inc.key, %{
        "lease_id" => lease_id,
        "effect" => id,
        "epoch" => inc.epoch
      })

    {:reply, {:ok, e, token}, st}
  end

  # ---------------------------------------------------------- internals

  # A new incarnation: mint the epoch and key, persist the epoch sequence,
  # open this incarnation's log, and push the fence to every participant
  # BEFORE this process serves anything. A push that fails raises: the
  # supervisor restarts this process, and nothing was served meanwhile.
  defp incarnate(%{tab: tab, s: s} = st) do
    seq = (s["epoch_seq"] || 0) + 1
    prev = s["epoch"]
    epoch = "e#{seq}-" <> (:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower))
    key = Fence.mint_key()
    # The sequence is durable BEFORE the push, so a crash after the push
    # cannot mint the same sequence again; the nonce keeps the label unique
    # across worlds whose sequences restart. The log opens only once every
    # participant holds the epoch, so a failed push leaves no file.
    s = s |> Map.put("epoch_seq", seq) |> Map.put("epoch", epoch)
    s = Ampd.Store.save(tab, s)
    push_fences!(epoch, key)

    inc = %{
      epoch: epoch,
      key: key,
      leases: %{},
      terminals: MapSet.new(),
      tseq: 0,
      n_lease: 0,
      n_ticket: 0,
      deferred: [],
      log: Witness.open(epoch)
    }

    st = %{st | s: s, inc: inc}

    if prev,
      do: log(st, %{"type" => "journal_restart", "old_epoch" => prev, "new_epoch" => epoch}),
      else: st
  end

  # Every participant must hold the new epoch before this process serves a
  # message. A participant that is absent, restarting, or closed for a
  # world reset is retried under the SAME epoch — for up to `@fence_wait_ms`
  # — rather than turned into a restart storm that mints an epoch per
  # attempt. After that this process raises, and the supervisor restarts it.
  @fence_wait_ms 5_000
  @fence_retry_ms 50

  defp push_fences!(epoch, key) do
    Enum.each(Contract.participants(), fn p ->
      push_fence!(participant(p), epoch, key, @fence_wait_ms)
    end)
  end

  defp push_fence!(mod, epoch, key, budget) do
    result =
      try do
        {:ok, GenServer.call(mod, {:fence_epoch, epoch, key}, 1_000)}
      catch
        :exit, why -> {:exit, why}
      end

    case result do
      {:ok, :ok} ->
        :ok

      # **A sealed participant is not waited for, and is not a reason to stop.**
      # It refuses every ticket by name, whatever its fence says, so there is
      # nothing to fence. Raising here took the whole runtime down instead: a
      # dirty `receipts` or `grant_registry` store made this process fail to
      # start and the application with it (6 of 72 random kills,
      # `evidence/kill-battery/`), where `Ampd.Store` promises a sealed
      # registry that refuses by name while the rest of the world stays
      # reachable — and `Ampd.seals/0` names it.
      {:ok, {:refused, %{"operator_detail" => %{"seal" => seal}}}} when is_binary(seal) ->
        require Logger
        Logger.warning("ampd: #{inspect(mod)} is sealed and was not fenced for #{epoch}: #{seal}")
        :ok

      other when budget > 0 ->
        _ = other
        Process.sleep(@fence_retry_ms)
        push_fence!(mod, epoch, key, budget - @fence_retry_ms)

      other ->
        raise "journal owner cannot fence #{inspect(mod)} for epoch #{epoch}: #{inspect(other)}"
    end
  end

  defp participant("approvals"), do: Ampd.Approvals
  defp participant("grant_registry"), do: Ampd.GrantRegistry
  defp participant("receipts"), do: Ampd.Receipts

  defp log(%{inc: nil} = st, _event), do: st

  # While this process serves the open authority transaction, the facts it
  # just wrote are not durable yet — they are, together, at the commit. Their
  # lines wait (in order) so that no line ever precedes its fact.
  defp log(%{inc: inc} = st, event) do
    if Ampd.AuthorityLog.member?(),
      do: %{st | inc: %{inc | deferred: [event | inc.deferred]}},
      else: append_witness(st, event)
  end

  defp append_witness(%{inc: inc} = st, event) do
    tseq = inc.tseq + 1
    Witness.append!(inc.log, tseq, event)
    %{st | inc: %{inc | tseq: tseq}}
  end

  defp snapshot(st, ticket_id, which) do
    if Application.get_env(:ampd, :witness_snapshots, false) do
      log(st, %{
        "type" => "snapshot",
        "ticket_id" => ticket_id,
        "which" => which,
        "state" => stores()
      })
    else
      st
    end
  end

  # THE ONE ADMISSION CHECK. Every post-creation journal write — AUTHORIZED,
  # APPROVED, CLAIMED, ATTEMPTED, COMMITTED, FAILED, UNKNOWN — passes through
  # `transition/4`, and `transition/4` admits the edge first: the effect
  # must exist and `Contract.legal_transition?/2` must hold for its CURRENT
  # state. Before this existed the table was declared and never consulted;
  # `COMMITTED → ATTEMPTED` and `CLAIMED → COMMITTED` were accepted through
  # the public API with a live lease (reproduced at 58c224e, recorded in
  # wek/b2). A refused edge changes nothing: no save, no witness line, no
  # attempt record, no lease-table change — the caller sees `{:refused, r}`.
  # Creation is not a transition: `{:propose, _}` constructs the record with
  # PROPOSED hard-coded and does not pass through here; `nil → PROPOSED` is
  # safe by construction and tested apart (effect_lifecycle_test).
  def admit(st, id, state) do
    case lookup(st, id) do
      nil ->
        {:refused, transition_refusal("effect-unknown", id, nil, state)}

      e ->
        if Contract.legal_transition?(e["state"], state),
          do: {:ok, e},
          else:
            {:refused, transition_refusal("journal-transition-illegal", id, e["state"], state)}
    end
  end

  defp transition(%{tab: tab, s: s} = st, id, state, meta) do
    with {:ok, e0} <- admit(st, id, state) do
      {e, s2} = put_state(s, e0, state, meta)
      st = %{st | s: Ampd.Store.save(tab, s2), ix: Map.put(st.ix, id, e)}

      event = %{"type" => "journal", "effect" => id, "state" => state}
      event = if meta["reason"], do: Map.put(event, "reason", meta["reason"]), else: event
      {:ok, e, log(st, event)}
    end
  end

  defp transition_refusal(code, id, from, to) do
    Ampd.Refusal.new(code,
      component: "Ampd.Effects",
      retryable: false,
      requires_human: false,
      public_message: "The journal refused the transition.",
      operator_detail: %{"effect" => id, "from" => from, "to" => to}
    )
  end

  defp live_lease(%{inc: inc}, lease) do
    cond do
      not is_map(lease) or not is_binary(lease["lease_id"]) ->
        {:refused, owner_refusal("write-unmediated", lease, nil, nil, nil)}

      lease["epoch"] != inc.epoch ->
        {:refused, owner_refusal("write-lease-stale", lease, nil, nil, nil)}

      not Fence.lease_valid?(inc.key, lease) ->
        {:refused, owner_refusal("write-unmediated", lease, nil, nil, nil)}

      true ->
        case Map.get(inc.leases, lease["lease_id"]) do
          nil ->
            {:refused, owner_refusal("write-unmediated", lease, nil, nil, nil)}

          %{retired: "completed"} ->
            {:refused, owner_refusal("write-lease-retired", lease, nil, nil, nil)}

          %{retired: "closed"} ->
            {:refused, owner_refusal("write-lease-closed", lease, nil, nil, nil)}

          l ->
            {:ok, l}
        end
    end
  end

  # S-1, enforced: ATTEMPTED may be journaled only when every
  # required_at_claim op has LANDED for this effect.
  defp sequencing(l) do
    missing =
      Contract.sets(l.branch)["required_at_claim"]
      |> Enum.map(&Contract.op_of_store/1)
      |> Enum.reject(&MapSet.member?(l.done, &1))

    if missing == [],
      do: :ok,
      else:
        {:refused,
         Ampd.Refusal.new("sequencing-violated",
           component: "Ampd.Effects",
           retryable: false,
           requires_human: true,
           public_message: "The effect cannot be attempted before its consumption has landed.",
           operator_detail: %{"effect" => l.effect, "lease_id" => l.id, "outstanding" => missing}
         )}
  end

  defp record_landing(%{inc: inc} = st, ticket) do
    tid = ticket["ticket_id"]

    if MapSet.member?(inc.terminals, tid) do
      st
    else
      inc = %{inc | terminals: MapSet.put(inc.terminals, tid)}
      st = %{st | inc: inc}
      st = log(st, %{"type" => "landed", "ticket_id" => tid, "epoch_at_landing" => inc.epoch})
      st = snapshot(st, tid, "after")

      case Map.get(inc.leases, ticket["lease_id"]) do
        nil ->
          st

        l ->
          l = %{l | done: MapSet.put(l.done, ticket["op"])}

          complete? =
            l.retired == nil and
              Enum.all?(Contract.required_ops(l.branch), &MapSet.member?(l.done, &1))

          l = if complete?, do: %{l | retired: "completed"}, else: l
          st = %{st | inc: %{st.inc | leases: Map.put(st.inc.leases, l.id, l)}}

          if complete?,
            do:
              log(st, %{"type" => "lease_retired", "lease_id" => l.id, "reason" => "completed"}),
            else: st
      end
    end
  end

  # The acknowledged retirement. For every live lease of the effect and
  # every participant its branch declares: the participant persists the
  # retirement and replies with the landings it already holds under that
  # lease. Those landings are recorded FIRST — they happened at the
  # resource before its acknowledgment, so they precede the retirement in
  # the single-writer log by construction, whatever a delayed report says.
  defp retire_at_participants(%{inc: inc} = st, id) do
    inc.leases
    |> Enum.filter(fn {_, l} -> l.effect == id and l.retired == nil end)
    |> Enum.reduce(st, fn {lease_id, l}, st ->
      Enum.reduce(Contract.sets(l.branch)["declared"], st, fn p, st ->
        case participant(p).fence_retire(lease_id, "closed") do
          {:ok, landed} when is_list(landed) ->
            Enum.reduce(landed, st, fn w, st ->
              ticket = w["ticket"]

              # A gathered landing is the resource's word: a compact ticket
              # (ticket_id, lease_id, op) under the resource's proof. The original
              # ticket's MAC is not on the row and is not needed — the proof binds
              # exactly the fields record_landing reads.
              if is_map(ticket) and Fence.proof_valid?(st.inc.key, ticket, "landed", w["proof"]),
                do: record_landing(st, ticket),
                else: st
            end)

          other ->
            raise "journal owner cannot retire #{lease_id} at #{p}: #{inspect(other)}"
        end
      end)
    end)
  end

  defp close_leases(%{inc: inc} = st, id) do
    inc.leases
    |> Enum.filter(fn {_, l} -> l.effect == id and l.retired == nil end)
    |> Enum.reduce(st, fn {lease_id, l}, st ->
      st = %{
        st
        | inc: %{st.inc | leases: Map.put(st.inc.leases, lease_id, %{l | retired: "closed"})}
      }

      log(st, %{"type" => "lease_retired", "lease_id" => lease_id, "reason" => "closed"})
    end)
  end

  defp owner_refusal(code, lease, op, target, ticket_id) do
    Ampd.Refusal.new(code,
      component: "Ampd.Effects",
      retryable: false,
      requires_human: false,
      public_message: "The journal owner refused the write.",
      operator_detail: %{
        "lease_id" => if(is_map(lease), do: lease["lease_id"], else: nil),
        "op" => op,
        "target" => target,
        "ticket_id" => ticket_id
      }
    )
  end

  # The record changes; the journal's other records are the same terms they
  # were. It was `Enum.map/2` over every effect, twice, to change one — the
  # largest per-transition cost left once the store stopped rewriting history
  # (measured with `:eprof` at ~2,000 retained effects). The element is found
  # by IDENTITY (`lookup/2` returns the term the list holds), so the walk is a
  # pointer comparison per record, and nothing after it is copied.
  defp put_state(s, e, state, meta) do
    {attempt, meta} = Map.pop(meta, "__attempt")

    e2 =
      e
      |> Map.merge(meta)
      |> Map.put("state", state)
      |> Map.update("attempts", [], fn as -> if attempt, do: as ++ [attempt], else: as end)
      |> Map.update("history", [], &(&1 ++ [%{"state" => state, "at" => now()}]))
      |> then(fn e -> if state == "UNKNOWN", do: Map.put(e, "needs_reconcile", true), else: e end)

    {e2, %{s | "effects" => replace(s["effects"], e, e2, [])}}
  end

  defp replace([x | rest], old, new, acc) when x === old, do: :lists.reverse(acc, [new | rest])
  defp replace([x | rest], old, new, acc), do: replace(rest, old, new, [x | acc])

  # The index is this process's own; a record it points at is always in the
  # list. Reaching the end means they disagree, which is a bug, not a state.
  defp replace([], old, _new, _acc),
    do: raise("effect #{inspect(old["id"])} is indexed but not in the journal")

  # The effects by id, beside the list the store persists — the list stays
  # the durable shape; the map is what lookups use instead of scanning it.
  defp index(s), do: Map.new(s["effects"] || [], &{&1["id"], &1})

  # A state without an index (a test handing `admit/3` a hand-built state)
  # is still answered, by the scan the index replaced.
  defp lookup(%{ix: ix}, id), do: Map.get(ix, id)
  defp lookup(%{s: s}, id), do: Enum.find(s["effects"], &(&1["id"] == id))

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
