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
  @participant_mutations ~w(close_store load_state emit reset)a

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
  def sealed_state, do: %{"log" => [], "seq" => 0}

  def sealed, do: ask(:sealed)
  def close_store, do: ask(:close_store)
  def load_state(s), do: ask({:load_state, s})
  def initial, do: %{"log" => [], "seq" => 7}
  def emit(m), do: ask({:emit, m})
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
  def reset, do: ask(:reset)
  # --- ordered-authority boundary -------------------------------------
  # These mutations are served only when the caller IS the total order.
  @ordered_ops [:reset, :load_state]
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
  def handle_call({:emit, m}, _f, %{tab: tab, s: s} = st) do
    seq = s["seq"]
    id = "rcpt-" <> String.pad_leading(Integer.to_string(seq), 4, "0")

    m =
      %{"kind" => @default_kind}
      |> Map.merge(m)
      |> Map.merge(%{"id" => id, "seq" => seq})

    {:reply, m, %{st | s: Ampd.Store.save(tab, %{s | "log" => s["log"] ++ [m], "seq" => seq + 1})}}
  end
  def handle_call(:all, _f, %{s: s} = st), do: {:reply, s["log"], st}

  # --- ordered implementations (reached only via the guard above) ----
  def handle_ordered({:load_state, s}, st) do
    tab = st.tab || Ampd.Store.open!(@store)
    {:reply, :ok, %{st | tab: tab, s: Ampd.Store.save(tab, s), sealed: nil}}
  end

  def handle_ordered(:reset, %{tab: tab} = st), do: {:reply, :ok, %{st | s: Ampd.Store.save(tab, initial())}}
end
