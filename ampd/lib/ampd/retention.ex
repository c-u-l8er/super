defmodule Ampd.Retention do
  @moduledoc """
  Retention for the authority stores: completed work leaves the WORKING lists,
  and its history is kept in the authority archive (`Ampd.AuthorityLog`).

  Ruled by Travis 2026-09-24 (ProjectAmp2 `SUPER_BUILDS_LANE.md` §5): retire
  completed items from the in-memory working lists while preserving durable
  history; keep the compact indexes receipt lookup, recovery, deduplication
  and refusing a used grant need; never retire what an unfinished operation
  still needs; and measure the benefit afterwards — bounded lists alone do not
  establish flat cost.

  ## What is retired, and only together

  A **settled bundle**. An effect is retirable when it is terminal
  (`COMMITTED` or `FAILED`), holds no live lease, is not among the newest
  `keep_recent` terminal effects, and its recovery row — computed by
  `Ampd.Effects.Contract.classify/3`, the same verdict the listing gives an
  operator — is settled for every participant: `COMPLETE`, `NOT_REQUIRED`,
  `NOT_OWED` or `NOT_YET_OWED`. With it go:

    * every receipt naming it;
    * its grant, only if the grant is no longer active and every effect that
      consumed it is retired or in this batch;
    * its approval, only if that approval was consumed by this effect.

  An effect whose row reads `MISSING`, `CONFLICT(…)`, `LEGACY_UNWITNESSED` or
  `INDETERMINATE` is never retired: that is what an operator has to see. An
  `UNKNOWN` effect is not terminal and never qualifies.

  ## One pass, one record

  `Ampd.Authority.retire_settled/1` runs `pass/1` inside the total order and
  inside ONE authority-log transaction (`Ampd.AuthorityLog.group/1`). The rows
  are archived and synced first; then Effects, Receipts, Approvals and the
  grant registry drop them and index them, and the four stores' changes are
  written as one record. A crash before that record leaves an orphan archive
  batch and every row still live — the next pass archives them again, and no
  reader takes a row from a batch no index entry names.

  Each index entry commits a digest of the row it retires
  (`Ampd.AuthorityLog.RowDigest`), computed by the store from its own working
  row after checking that row is the one archived, so a reader can tell the
  archive holding anything else from the row the log retired.

  The drops run in that order so that a refusal part-way (which the group
  would still commit) leaves nothing pointing at a row that is gone: an
  effect whose receipt had left first would read `MISSING`; a receipt whose
  effect left first is read by nothing.

  ## When

  After a perform (`poke/0`, which only counts; every `check_every` pokes it
  looks), and every `interval_ms`. A pass runs only when the terminal
  effects beyond `keep_recent` number at least `min_batch`, and retires at
  most `max_batch`. Settings: `config :ampd, authority_retention: [...]`.
  """
  use GenServer
  require Logger

  alias Ampd.{Approvals, AuthorityLog, Effects, GrantRegistry, Receipts}
  alias Ampd.Effects.Contract

  @settled ~w(COMPLETE NOT_REQUIRED NOT_OWED NOT_YET_OWED)

  @doc "The listing verdicts that mean nothing is owed and nothing disagrees."
  def settled_verdicts, do: @settled

  def config do
    o = Application.get_env(:ampd, :authority_retention, [])

    %{
      enabled: Keyword.get(o, :enabled, true),
      keep_recent: Keyword.get(o, :keep_recent, 256),
      min_batch: Keyword.get(o, :min_batch, 256),
      max_batch: Keyword.get(o, :max_batch, 2048),
      interval_ms: Keyword.get(o, :interval_ms, 30_000),
      check_every: Keyword.get(o, :check_every, 64)
    }
  end

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Count one completed perform; every `check_every` of them, look for a batch."
  def poke do
    if pid = Process.whereis(__MODULE__), do: GenServer.cast(pid, :poke)
    :ok
  end

  @doc """
  Run one pass now, whatever the counters say, with `opts` over the
  configuration (`keep_recent`, `min_batch`, `max_batch`). For tools and tests.
  """
  def run_now(opts \\ []) do
    cfg = Map.merge(config(), Map.new(opts))
    Ampd.Authority.retire_settled(cfg)
  end

  @table :ampd_retention_status

  @doc """
  Counters since this process started, read from a public table — never a
  call, so it answers while a pass holds this process (and the total order)
  and a harness can take it around every effect without waiting on one:

      "pokes"        performs counted
      "passes"       passes that completed (retired or not)
      "retired"      effects retired by them
      "errors"       passes that did not complete
      "running"      nil, or the monotonic µs at which the current pass began
      "last"         the last pass's summary (or its error, inspected)
      "last_us"      how long the last pass held the order, in µs

  `nil` when retention is not running.
  """
  def status do
    case :ets.whereis(@table) do
      :undefined -> nil
      _ -> Map.new(:ets.tab2list(@table))
    end
  end

  defp put(k, v), do: :ets.insert(@table, {k, v})
  defp bump(k, n), do: :ets.update_counter(@table, k, n)

  # ------------------------------------------------------------------- pass

  @doc false
  # Runs INSIDE the total order and the open authority transaction — called
  # only by `Ampd.Authority.retire_settled/1`.
  def pass(cfg) do
    cands = Effects.retirable(cfg.keep_recent, cfg.max_batch)

    if length(cands) < cfg.min_batch do
      {:ok, %{"retired" => 0, "candidates" => length(cands)}}
    else
      bundle(cands)
    end
  end

  defp bundle(cands) do
    receipts = Enum.group_by(Enum.filter(Receipts.all(), & &1["effect_ref"]), & &1["effect_ref"])
    grants = Map.new(GrantRegistry.list(), &{&1["id"], &1})
    approvals = Map.new(Approvals.all(), &{&1["id"], &1})

    settled =
      Enum.filter(cands, fn e ->
        stores = %{
          "receipts" => Map.get(receipts, e["id"], []),
          "grants" => List.wrap(grants[e["grant_ref"]]),
          "approvals" => List.wrap(approvals[e["approval_ref"]])
        }

        Enum.all?(Contract.participants(), &(Contract.classify(e, stores, &1) in @settled))
      end)

    ids = MapSet.new(settled, & &1["id"])

    gone_grants =
      settled
      |> Enum.map(&grants[&1["grant_ref"]])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1["id"])
      |> Enum.filter(fn g ->
        g["status"] != "active" and
          Enum.all?(g["consumptions"] || [], &(MapSet.member?(ids, &1) or Effects.retired(&1) != nil))
      end)

    gone_approvals =
      Enum.flat_map(settled, fn e ->
        id = e["id"]

        case approvals[e["approval_ref"]] do
          %{"status" => "consumed", "consumed_by" => ^id} = a -> [a]
          _ -> []
        end
      end)

    gone_receipts = Enum.flat_map(settled, &Map.get(receipts, &1["id"], []))

    if settled == [] do
      {:ok, %{"retired" => 0, "candidates" => length(cands), "unsettled" => length(cands)}}
    else
      rows = %{
        "effects" => settled,
        "receipts" => gone_receipts,
        "grant_registry" => gone_grants,
        "approvals" => gone_approvals
      }

      summary = %{
        "retired" => length(settled),
        "candidates" => length(cands),
        "unsettled" => length(cands) - length(settled),
        "receipts" => length(gone_receipts),
        "grants" => length(gone_grants),
        "approvals" => length(gone_approvals)
      }

      case AuthorityLog.archive(rows) do
        {:ok, batch} ->
          case drop_effects(batch, settled, gone_receipts, gone_approvals, gone_grants) do
            :ok -> {:ok, Map.put(summary, "batch", batch)}
            err -> err
          end

        {:error, why} ->
          {:error, why}
      end
    end
  end

  # The drops, in order, as literal calls — no computed module, no fun value,
  # no `with … else` (whose else compiles to a closure): the ordered-
  # reachability census follows every one of these. Nothing to drop is not a
  # call, because an empty retirement would still be a round trip in the order.
  #
  # Each store is handed the rows exactly as they went into batch `b`. It
  # checks them against its own working rows and commits a digest of its OWN
  # row (`Ampd.AuthorityLog.RowDigest`), so the index can never commit to a row
  # other than the one archived.
  defp drop_effects(b, effects, receipts, approvals, grants) do
    case Effects.retire(effects, b) do
      {:ok, _} -> drop_receipts(b, receipts, approvals, grants)
      other -> failed(other)
    end
  end

  defp drop_receipts(b, [], approvals, grants), do: drop_approvals(b, approvals, grants)

  defp drop_receipts(b, receipts, approvals, grants) do
    case Receipts.retire(receipts, b) do
      {:ok, _} -> drop_approvals(b, approvals, grants)
      other -> failed(other)
    end
  end

  defp drop_approvals(b, [], grants), do: drop_grants(b, grants)

  defp drop_approvals(b, approvals, grants) do
    case Approvals.retire(approvals, b) do
      {:ok, _} -> drop_grants(b, grants)
      other -> failed(other)
    end
  end

  defp drop_grants(_b, []), do: :ok

  defp drop_grants(b, grants) do
    case GrantRegistry.retire(grants, b) do
      {:ok, _} -> :ok
      other -> failed(other)
    end
  end

  defp failed({:refused, r}), do: {:error, r}
  defp failed({:error, why}), do: {:error, why}
  defp failed(other), do: {:error, other}

  # ----------------------------------------------------------------- server

  @impl true
  def init(:ok) do
    cfg = config()

    if :ets.whereis(@table) == :undefined,
      do: :ets.new(@table, [:named_table, :public, read_concurrency: true])

    :ets.insert(@table, [
      {"pokes", 0},
      {"passes", 0},
      {"retired", 0},
      {"errors", 0},
      {"running", nil},
      {"last", nil},
      {"last_us", nil}
    ])

    Process.send_after(self(), :tick, cfg.interval_ms)
    {:ok, %{pokes: 0}}
  end

  @impl true
  def handle_cast(:poke, st) do
    cfg = config()
    st = %{st | pokes: st.pokes + 1}
    bump("pokes", 1)

    if cfg.enabled and rem(st.pokes, max(cfg.check_every, 1)) == 0,
      do: {:noreply, run(st, cfg)},
      else: {:noreply, st}
  end

  @impl true
  def handle_info(:tick, st) do
    cfg = config()
    Process.send_after(self(), :tick, cfg.interval_ms)
    {:noreply, if(cfg.enabled, do: run(st, cfg), else: st)}
  end

  def handle_info(:again, st) do
    cfg = config()
    {:noreply, if(cfg.enabled, do: run(st, cfg), else: st)}
  end

  defp run(st, cfg) do
    t0 = System.monotonic_time(:microsecond)
    put("running", t0)

    result =
      try do
        Ampd.Authority.retire_settled(cfg)
      catch
        kind, why -> {:error, {kind, why}}
      end

    put("running", nil)
    put("last_us", System.monotonic_time(:microsecond) - t0)

    case result do
      {:ok, %{"retired" => n} = r} ->
        bump("passes", 1)
        bump("retired", n)
        put("last", r)
        # A full batch means more may be waiting; look again without waiting
        # for the next poke.
        if n >= cfg.max_batch, do: send(self(), :again)
        st

      other ->
        Logger.warning("ampd: a retention pass did not complete: #{inspect(other)}")
        bump("errors", 1)
        put("last", inspect(other))
        st
    end
  end
end
