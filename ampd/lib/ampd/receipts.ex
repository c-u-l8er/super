defmodule Ampd.Receipts do
  @moduledoc "The durable effect ledger — feeds Evidence; never a second audit system."
  use GenServer
  @store "receipts"

  @doc """
  The kind a producer gets when it does not say. `Ampd.Gateway` relies on
  it; `Ampd.Locus` passes `worktree_created@1` explicitly.
  """
  @default_kind "capability-effect-receipt@1"
  def default_kind, do: @default_kind

  @doc """
  Fields the store mints and a caller may never supply.

  Declared rather than implied, so that "the caller cannot forge ledger
  identity" is a list something can be tested against instead of a property
  of one `Map.merge/2` argument order.
  """
  @reserved ~w(id seq)
  def reserved_fields, do: @reserved
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
  @participant_mutations ~w(close_store load_state emit emit_ticketed fence_epoch fence_retire reset validation_start validation_outcome retire)a

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
      {:ok, tab, s} ->
        {:ok, %{tab: tab, s: s, refs: refs(s), sealed: nil}}

      {:sealed, reason} ->
        {:ok, %{tab: nil, s: sealed_state(), refs: %{}, sealed: reason}}
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
  def sealed_state, do: %{"log" => [], "seq" => 0}

  def sealed, do: ask(:sealed)
  def close_store, do: ask(:close_store)
  def load_state(s), do: ask({:load_state, s})
  def initial, do: %{"log" => [], "seq" => 7}

  @doc """
  Append a record.

  **The mediated boundary (E3-1), stated exactly.** A record that names an
  effect — `effect_ref` present — is that effect's receipt witness, and it
  is appended ONLY through `emit/2` with a ticket the journal owner signed
  for `emit_receipt` on that effect. `emit/1` refuses such a record
  `write-unmediated`, in this process, before anything is written. A record
  naming no effect (`worktree_created@1`, a validation record through its
  typed admission, a test kind) is an ordinary ledger append and stays
  unmediated: it attests to no effect and no listing reads it as one.
  """
  def emit(m) when is_map(m), do: ask({:emit, m})

  @doc "The mediated append: `{:ok, record, witness}` or `{:refused, refusal@1}`. The row carries `landed_by` = the ticket."
  def emit(ticket, m) when is_map(ticket) and is_map(m), do: ask({:emit_ticketed, ticket, m})

  @doc "Journal-owner only: install this incarnation's fence (`Ampd.Fence`)."
  def fence_epoch(epoch, key), do: ask({:fence_epoch, epoch, key})
  @doc "This resource's fence as persisted — epoch and retired leases, never the key. A read."
  def fence, do: ask(:fence)

  @doc "Journal-owner only: retire a lease at this resource; replies with the landings held under it."
  def fence_retire(lease_id, reason), do: ask({:fence_retire, lease_id, reason})

  @doc """
  **Every record of every kind, in append order.**

  Kept, and the name is now doing work it was not before: this is the whole
  ledger, and after R0b.R that means more than one semantics. A caller whose
  subject is capability effects wants `of_kind/1`; a caller measuring the
  world's total footprint wants this.

  The distinction is not academic. Six readers took
  `List.last(Receipts.all())` and immediately read `effect_ref` or
  `capability` off it, which is only correct while one kind exists.
  """
  def all, do: ask(:all)

  @doc """
  The receipt naming `effect_ref`, or nil — looked up in this process, not by
  copying the ledger out and filtering it (that copy grew with every receipt
  ever emitted). At most one exists: uniqueness per effect is enforced at the
  append.
  """
  def for_effect(effect_ref) do
    case ask({:for_effect, effect_ref}) do
      {:archived, batch} ->
        case Ampd.AuthorityLog.archived_row(batch, @store, effect_ref, "effect_ref") do
          {:ok, r} -> r
          {:error, _} = err -> err
        end

      other ->
        other
    end
  end

  @doc """
  Coordinator only, inside the retirement transaction: every record naming
  one of `effect_refs` leaves the working ledger, indexed as archived in
  `batch`. Records naming no effect (worktree, validation) are never retired.
  """
  def retire(effect_refs, batch), do: ask({:retire, effect_refs, batch})

  @doc "A retired receipt's compact entry — `[receipt_id, batch]` — for an effect, or nil."
  def retired_ref(effect_ref), do: ask({:retired_ref, effect_ref})

  @doc "Every retired batch's `%{kind => [lowest seq, highest seq, rows, %{actor => rows}]}`, by batch."
  def retired_batches, do: ask(:retired_batches)

  @doc "How many records of `kind` were retired: all of them (`nil`), or one actor's."
  def retired_count(kind, actor \\ nil), do: ask({:retired_count, kind, actor})

  @doc "Every retired record of `kind`, from the archive — paged history only."
  def archived_of_kind(kind) do
    with {:ok, rows} <- Ampd.AuthorityLog.archived_rows(@store),
         do: {:ok, Enum.filter(rows, &(&1["kind"] == kind))}
  end

  @doc "Every record of one kind, in append order."
  def of_kind(kind), do: Enum.filter(all(), &(&1["kind"] == kind))

  @doc """
  How many records the ledger holds, of every kind.

  Left alone deliberately where a caller means the world's footprint. Where
  a caller meant "how many capability effects", it now says `count/1`.
  """
  def count, do: length(all())

  @doc "How many records of one kind."
  def count(kind), do: length(of_kind(kind))

  @doc """
  The newest record of one kind.

  Exists because `List.last(Receipts.all())` is the shape of a bug that
  cannot happen yet: it means "the newest record is mine", which is true
  only while one producer exists. A reader that says which kind it wants
  keeps working when another kind is appended after it.
  """
  def last_of_kind(kind), do: kind |> of_kind() |> List.last()
  # ============================================ typed validation admission
  #
  # **R0b.R·1. The invariants have to hold at the ledger, not at the polite
  # constructor.** Before this, `Ampd.Validation` enforced the whole
  # lifecycle — a job must exist, a start must be durable, an outcome must be
  # the only one — and then read that truth back out of this store *by kind
  # alone*. Anything that could call `emit/1` could choose the kind, so:
  #
  #     Receipts.emit(%{"kind" => "validation_job_started@1",
  #                     "job_ref" => "vj_fake"})
  #
  # minted a durable validation START for a job that does not exist, over no
  # SourceBasis, owned by no Lane, at no Worker — and `admissible?/1`, which
  # asked only *is there a start and no outcome*, then answered **true** for
  # it. A receipt created executable work. The round's own test suite
  # contained that call, which is how the hole was found rather than argued.
  #
  # "The intended caller goes through the boundary" is not the same sentence
  # as "the boundary enforces the property", and this file is the boundary.
  #
  # ## Why this is not a flag
  #
  # Nothing here consults a `producer` field, an `internal: true`, the
  # process dictionary, or the calling module. Every one of those is
  # something a caller can supply or arrange, which makes the guard a
  # convention wearing a check's clothes. The protection is structural
  # instead: the protected kinds are reachable only through a **different
  # message**, and `{:emit, m}` refuses them by name.
  #
  # ## Why only a REFERENCE crosses the message boundary
  #
  # The first cut of this closure resolved the JobBasis and validated the
  # result shape in the *interface functions*, then sent the resolved map
  # across. GPT's review named what that actually bought, and the distinction
  # is worth keeping: **an interface function and its receiving callback are
  # two different validation locations.** Resolving in the caller made the
  # generic path protected and the typed *interface* invariant-preserving; it
  # did not make the receiving admission point establish anything, because
  # the handler took the job's existence on faith from its own message.
  #
  # So the messages carry `job_ref` and, for an outcome, the caller's raw
  # `result`. Everything else the handlers derive or check for themselves.
  #
  # ## Restore is an EXPLICIT TRUSTED EXCEPTION, and its bound is authority
  #
  # `load_state/1` installs a whole log and is **not** an admission point. It
  # is the restore path — a boot reading `dets` back, or a fixture standing a
  # world up — and it can install records these appends would refuse. That is
  # deliberate: a runtime that could not restore a world it had already
  # written would not survive a restart.
  #
  # What bounds it is that it is `@ordered_ops` and coordinator-only. **That
  # its argument is a world rather than a record is a description, not a
  # check** — accepting a whole world establishes nothing about that world's
  # validity, and an earlier comment here listed it as though it did.
  #
  # So the guarantee is scoped, and the scope is one sentence:
  #
  #     Generic emission refuses protected validation kinds; typed admission
  #     enforces their declared JobBasis, lifecycle, and result-shape
  #     invariants. Trusted restore is outside that guarantee.
  #
  # Deliberate on both sides: it does not claim `emit/1` validates every
  # record's semantics — it refuses two kinds and is otherwise the
  # general-purpose append R2 made it — and it does not fold restore in by
  # omission.

  @doc """
  Every kind `emit/1` refuses. These carry semantic invariants the ledger
  itself now enforces, so they have their own admission points below.
  """
  def protected_kinds, do: Ampd.Validation.kinds()

  @doc """
  Append `validation_job_started@1` for an existing JobBasis.

  Takes a **reference**. The handler resolves the JobBasis itself and takes
  every semantic field from it — `validation_kind`, `actor`, `worker_ref`,
  `worker_generation`, `source_basis_ref`, `scope_digest`. There is no
  parameter through which a different value could arrive, and no resolved
  map crosses the message boundary for the handler to trust.

  Refuses `validation-job-unknown` if the ref names nothing and
  `validation-job-already-started` if a start is already durable. **Both are
  established at the receiving admission point**, against the same store
  state the append is about to extend, so neither can be interleaved with
  it.
  """
  def record_validation_start(job_ref) when is_binary(job_ref),
    do: ask({:validation_start, job_ref})

  @doc """
  Append `validation_job_outcome@1`.

  Takes a **reference** and the caller's raw `result`. The handler resolves
  the job, checks that a START is durable and that no OUTCOME is, and
  shape-checks `result` with `Ampd.Validation.validate_result/1` — the pure
  vocabulary check, reused rather than reimplemented. Everything else — the
  subject, the basis, the scope — is copied from the durable START, so an
  outcome cannot be filed against a different actor or a different snapshot
  than the start it belongs to.

  All four checks happen at the receiving admission point, alongside the
  append, so two concurrent outcomes cannot both observe "none yet".
  """
  def record_validation_outcome(job_ref, result) when is_binary(job_ref) and is_map(result),
    do: ask({:validation_outcome, job_ref, result})

  def reset, do: ask(:reset)
  # --- ordered-authority boundary -------------------------------------
  # These mutations are served only when the caller IS the total order.
  # `validation_start` and `validation_outcome` are ordered for the reason
  # `bind_basis` is: they decide, durably, whether a job may be handed to an
  # executor. `emit` is deliberately NOT — an ordinary ledger append is not
  # an authority mutation, and routing every receipt through the total order
  # would buy nothing.
  @ordered_ops [:reset, :load_state, :validation_start, :validation_outcome, :retire]

  @doc """
  Operations served only when the caller IS the total order.

  Public so a falsifier reads the classification rather than restating it —
  the same reason `Ampd.Worktree.ordered_ops/0` is. Note that `load_state`
  is here beside the two typed appends and is **not** an admission point:
  see the typed-admission section above for why restore is a separate claim.
  """
  def ordered_ops, do: @ordered_ops
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

  @doc """
  Append a record. **The store's identity is minted here and cannot be
  supplied.**

  ## The merge order was backwards, and that is a forgery surface

  It was one call:

      Map.merge(%{"kind" => …, "id" => id, "committed" => true}, m)

  `Map.merge/2` lets the *second* map win, so every one of those was a
  **default the caller could overwrite** — including `id`, the ledger's own
  identity. Both current producers happen not to, which is exactly why
  nothing noticed. A ledger whose entries can name themselves is a ledger
  where two records can claim one identity, and no reader downstream can
  tell which is which.

  So the construction is now three layers with the reserved one last, and
  the ordering is the guarantee rather than a convention a test watches:

      %{"kind" => default}     a default the caller MAY override
      |> Map.merge(m)          the caller's semantic fields
      |> Map.merge(reserved)   the store's identity — always wins

  `kind` stays caller-supplied on purpose: it is the record's *semantics*,
  and R0b.R exists precisely so more than one kind can live here honestly.
  `id` and `seq` are the store's, and no argument makes them otherwise.

  ## `seq`, and why an integer had to be added

  Ordering and paging sorted **lexically on the id string**, and ids are
  `pad_leading(…, 4, "0")`. That is correct until the ten-thousandth record
  and then silently wrong:

      append order    rcpt-9998 rcpt-9999 rcpt-10000 rcpt-10001
      lexical :desc   rcpt-9999 rcpt-9998 rcpt-10001 rcpt-10000

  `rcpt-9999` reports as the newest record while three newer ones sort
  beneath a thousand older ones, and `total` stays correct throughout — so
  a count-only check goes green over it. The store already had the integer;
  it simply was not written down. Now it is, and `Ampd.Projection` orders on
  it.

  ## `committed` is gone

  It was store-defaulted to `true` on every record and **read by nothing** —
  audited across `ampd/lib`, `ampd/test`, `host/src`, `cockpit/`,
  `conformance/` and `site/`; the only textual match is
  `Ampd.Worktree.committed/1`, an unrelated state transition. Keeping an
  ambiguous universal boolean would have made it a lie the moment a
  validation result arrives: there is no honest value of `committed` for a
  job that ran correctly and found a NUL byte. Each typed kind says what
  happened in its own vocabulary instead.
  """
  def handle_call({:emit, %{"effect_ref" => ref} = m}, _f, %{s: s} = st) when ref != nil do
    # E3-1: a record naming an effect is a mediated write. Refused here, by
    # name, before the append — see `emit/1`.
    {:reply,
     {:refused,
      Ampd.Fence.refusal(
        s["fence"],
        "write-unmediated",
        "a receipt naming effect #{ref} must be appended through emit/2 with the journal owner's ticket",
        nil,
        "Ampd.Receipts"
      )}, st}
    |> then(fn r ->
      _ = m
      r
    end)
  end

  def handle_call({:emit_ticketed, ticket, m}, _f, %{s: s} = st) do
    target = if is_map(ticket), do: ticket["target"], else: nil

    verdict =
      with :ok <- Ampd.Fence.check(s["fence"], ticket, "emit_receipt", target) do
        cond do
          m["kind"] in protected_kinds() ->
            {:refused, "write-unscoped", "kind #{m["kind"]} has its own typed admission"}

          m["effect_ref"] not in [nil, target] ->
            {:refused, "write-unscoped",
             "the record names #{m["effect_ref"]}; the ticket targets #{target}"}

          Map.has_key?(refs_of(st), target) ->
            {:refused, "write-duplicate", "a receipt for #{target} is already in the ledger"}

          Map.has_key?(Map.get(s, "retired_refs", %{}), target) ->
            {:refused, "write-duplicate",
             "a receipt for #{target} is already in the ledger (retired to the archive)"}

          true ->
            :ok
        end
      end

    case verdict do
      {:refused, code, why} ->
        {:reply, {:refused, Ampd.Fence.refusal(s["fence"], code, why, ticket, "Ampd.Receipts")},
         st}

      :ok ->
        {record, st} =
          append(
            st,
            %{"kind" => @default_kind}
            |> Map.merge(m)
            |> Map.merge(%{"effect_ref" => target, "landed_by" => Ampd.Fence.witness_of(ticket)})
          )

        witness = %{
          "ticket_id" => ticket["ticket_id"],
          "proof" => Ampd.Fence.proof(s["fence"], ticket, "landed")
        }

        {:reply, {:ok, record, witness}, st}
    end
  end

  def handle_call({:fence_epoch, _, _} = msg, from, st),
    do: Ampd.Fence.handle_owner_call(msg, from, st, __MODULE__, &landed_under/2)

  def handle_call({:fence_retire, _, _} = msg, from, st),
    do: Ampd.Fence.handle_owner_call(msg, from, st, __MODULE__, &landed_under/2)

  def handle_call({:emit, m}, _f, st) do
    # **R0b.R·1.** `kind` is still the producer's — that is the whole point of
    # R2 — with exactly two exceptions, and they are exceptions because they
    # are no longer arbitrary rows. A `validation_job_started@1` means a job
    # exists, is owned by a Lane, sits at a Worker generation, and may be
    # handed to an executor. A caller that could mint one by naming it could
    # make all four of those true by assertion.
    #
    # **Refused by name, not silently defaulted and not dropped.** Rewriting
    # the kind would file the caller's record somewhere it did not ask for;
    # dropping it would lose a write with no explanation. The caller has to
    # learn that this kind has an admission point.
    if m["kind"] in protected_kinds() do
      {:reply,
       {:error, "receipt-kind-requires-typed-admission",
        %{
          "kind" => m["kind"],
          "protected" => protected_kinds(),
          "hint" =>
            "use Ampd.Receipts.record_validation_start/1 or " <>
              "record_validation_outcome/2 — this kind's invariants are the ledger's"
        }}, st}
    else
      {record, st} = append(st, %{"kind" => @default_kind} |> Map.merge(m))
      {:reply, record, st}
    end
  end

  def handle_call(:all, _f, %{s: s} = st), do: {:reply, s["log"], st}
  def handle_call({:for_effect, ref}, _f, st) do
    reply =
      case Map.get(refs_of(st), ref) do
        nil ->
          case Map.get(Map.get(st.s, "retired_refs", %{}), ref) do
            [_rid, batch | _] -> {:archived, batch}
            _ -> nil
          end

        r ->
          r
      end

    {:reply, reply, st}
  end

  def handle_call(:retired_batches, _f, st),
    do: {:reply, Map.get(st.s, "retired_batches", %{}), st}

  def handle_call({:retired_ref, ref}, _f, st),
    do: {:reply, Map.get(Map.get(st.s, "retired_refs", %{}), ref), st}

  def handle_call({:retired_count, kind, actor}, _f, st),
    do:
      {:reply,
       st.s |> Map.get("retired_count", %{}) |> Map.get(kind, %{}) |> Map.get(actor || "*", 0),
       st}

  # A read of this resource's fence — epoch and retired set, never the key.
  def handle_call(:fence, _f, %{s: s} = st),
    do: {:reply, if(is_map(s["fence"]), do: Map.delete(s["fence"], "key"), else: nil), st}

  defp landed_under(s, lease_id) do
    s["log"]
    |> Enum.map(& &1["landed_by"])
    |> Enum.filter(&(is_map(&1) and &1["lease_id"] == lease_id))
    |> Enum.map(&Map.put(&1, "op", "emit_receipt"))
  end

  @doc false
  # The one place a row is minted. `id` and `seq` are applied LAST and are
  # not overridable — R2's ordering guarantee, now shared by every admission
  # point rather than living inside one clause.
  defp append(%{tab: tab, s: s} = st, fields) do
    seq = s["seq"]
    id = "rcpt-" <> String.pad_leading(Integer.to_string(seq), 4, "0")
    record = Map.merge(fields, %{"id" => id, "seq" => seq})

    st = %{st | s: Ampd.Store.save(tab, %{s | "log" => s["log"] ++ [record], "seq" => seq + 1})}
    ref = record["effect_ref"]
    {record, if(ref, do: %{st | refs: Map.put(refs_of(st), ref, record)}, else: st)}
  end

  # Receipt uniqueness per effect is checked against this index, not by
  # scanning the ledger: the scan grew with every receipt ever emitted. The
  # ledger is append-only, so an indexed record never goes stale. Derived from
  # the log, never persisted — the log stays the authority.
  defp refs(s),
    do: for(r <- s["log"] || [], r["effect_ref"] != nil, into: %{}, do: {r["effect_ref"], r})

  defp refs_of(%{refs: refs}), do: refs
  defp refs_of(%{s: s}), do: refs(s)

  # The log is the authority for "has this already happened", and it is read
  # here rather than through `of_kind/1` because a `GenServer.call` to
  # ourselves from inside a handler is a deadlock.
  defp find(s, kind, job_ref),
    do: Enum.find(s["log"], &(&1["kind"] == kind and &1["job_ref"] == job_ref))

  # --- ordered implementations (reached only via the guard above) ----
  @doc false
  # **Check and append in one message, so they cannot interleave.** The
  # single-start and single-outcome rules are read-then-write over this
  # store's own log. Performed by a caller — even one inside the total order
  # — they would be two round trips with a window between them; performed
  # here they are one `handle_call`, and the BEAM gives the atomicity for
  # free because a process handles one message at a time.
  #
  # `Ampd.AuthorityCoordinator` is still required (these are in
  # `@ordered_ops`) and that is not redundant: ordering is about the world's
  # total order across stores, atomicity here is about this store's log.
  # Neither subsumes the other.
  def handle_ordered({:validation_start, job_ref}, %{s: s} = st) do
    # **Resolved HERE, from a reference.** R0b.R·1's first cut resolved the
    # JobBasis in the interface function and sent the resolved map across, so
    # this handler took the job's existence on faith from whatever arrived in
    # the message. That supported a narrower claim than the one being made:
    # the generic path was protected and the typed *interface* preserved the
    # invariants. It did not make the receiving admission point establish
    # them. A reference is the only thing that crosses now.
    #
    # `Ampd.Worktree.validation_job/1` is safe to call from inside this
    # handler: `Ampd.Worktree` never calls `Ampd.Receipts` — checked, not
    # assumed — and its `{:get, …}` clause is a map lookup with no I/O and no
    # onward call, so there is no callback cycle to deadlock on.
    job = Ampd.Worktree.validation_job(job_ref)

    cond do
      job == nil ->
        {:reply, {:error, "validation-job-unknown", %{"job_ref" => job_ref}}, st}

      find(s, Ampd.Validation.started_kind(), job_ref) != nil ->
        {:reply, {:error, "validation-job-already-started", %{"job_ref" => job_ref}}, st}

      true ->
        {record, st} =
          append(st, %{
            "kind" => Ampd.Validation.started_kind(),
            "job_ref" => job["ref"],
            "validation_kind" => job["validation_kind"],
            "actor" => job["actor"],
            "worker_ref" => job["worker_ref"],
            "worker_generation" => job["worker_generation"],
            "source_basis_ref" => job["source_basis_ref"],
            "scope_digest" => job["scope_digest"]
          })

        {:reply, {:ok, record}, st}
    end
  end

  def handle_ordered({:validation_outcome, job_ref, result}, %{s: s} = st) do
    # Same correction, and one more: the SHAPE of `result` is validated here
    # too. It was checked in the interface function, which meant this handler
    # appended whatever arrived. `Ampd.Validation.validate_result/1` is the
    # pure vocabulary check and is reused rather than reimplemented — two
    # implementations of one fact is the defect R2 and R5 were both about.
    job = Ampd.Worktree.validation_job(job_ref)
    start = find(s, Ampd.Validation.started_kind(), job_ref)
    decided = find(s, Ampd.Validation.outcome_kind(), job_ref)
    shape = Ampd.Validation.validate_result(result)

    cond do
      job == nil ->
        {:reply, {:error, "validation-job-unknown", %{"job_ref" => job_ref}}, st}

      start == nil ->
        {:reply, {:error, "validation-job-not-started", %{"job_ref" => job_ref}}, st}

      decided != nil ->
        {:reply,
         {:error, "validation-job-already-decided",
          %{"job_ref" => job_ref, "state" => decided["state"]}}, st}

      shape != :ok ->
        {:reply, shape, st}

      true ->
        # The subject comes off the START, never off `result`. A
        # caller-supplied actor here would file one job's history into
        # another agent's projection.
        base = %{
          "kind" => Ampd.Validation.outcome_kind(),
          "job_ref" => job_ref,
          "validation_kind" => start["validation_kind"],
          "actor" => start["actor"],
          "worker_ref" => start["worker_ref"],
          "worker_generation" => start["worker_generation"],
          "source_basis_ref" => start["source_basis_ref"],
          "scope_digest" => start["scope_digest"],
          "state" => result["state"]
        }

        fields =
          case result["state"] do
            "completed" -> Map.put(base, "verdict", result["verdict"])
            "failed" -> Map.put(base, "reason", result["reason"])
          end

        {record, st} = append(st, fields)
        {:reply, {:ok, record}, st}
    end
  end

  def handle_ordered({:retire, effect_refs, batch}, %{tab: tab, s: s} = st) do
    set = MapSet.new(effect_refs)
    {gone, keep} = Enum.split_with(s["log"], &MapSet.member?(set, &1["effect_ref"]))

    refs_index =
      Map.merge(
        Map.get(s, "retired_refs", %{}),
        Map.new(gone, &{&1["effect_ref"], [&1["id"], batch]})
      )

    counts =
      Enum.reduce(gone, Map.get(s, "retired_count", %{}), fn r, c ->
        k = r["kind"] || @default_kind
        per = c |> Map.get(k, %{}) |> Map.update("*", 1, &(&1 + 1))
        per = if is_binary(r["actor"]), do: Map.update(per, r["actor"], 1, &(&1 + 1)), else: per
        Map.put(c, k, per)
      end)

    ranges =
      gone
      |> Enum.group_by(&(&1["kind"] || @default_kind))
      |> Map.new(fn {k, rs} ->
        ns = Enum.map(rs, & &1["seq"])

        {k,
         [
           Enum.min(ns),
           Enum.max(ns),
           length(rs),
           Enum.frequencies(for r <- rs, is_binary(r["actor"]), do: r["actor"])
         ]}
      end)

    s2 =
      s
      |> Map.put("log", keep)
      |> Map.put("retired_refs", refs_index)
      |> Map.put("retired_count", counts)
      |> Map.put("retired_batches", Map.put(Map.get(s, "retired_batches", %{}), batch, ranges))

    st = %{st | s: Ampd.Store.save(tab, s2)}
    st = if Map.has_key?(st, :refs), do: %{st | refs: Map.drop(st.refs, effect_refs)}, else: st
    {:reply, {:ok, length(gone)}, st}
  end

  def handle_ordered({:load_state, s}, st) do
    tab = st.tab || Ampd.Store.open!(@store)

    s = Ampd.Store.save(tab, Ampd.Fence.carry(s, st.s))
    {:reply, :ok, Map.merge(st, %{tab: tab, s: s, refs: refs(s), sealed: nil})}
  end

  def handle_ordered(:reset, %{tab: tab} = st) do
    s = Ampd.Store.save(tab, Ampd.Fence.carry(initial(), st.s))
    {:reply, :ok, Map.merge(st, %{s: s, refs: refs(s)})}
  end
end
