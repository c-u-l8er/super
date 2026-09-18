# B2 write boundary — the cost campaign. Runs on the baseline AND on the
# candidate unchanged: it uses only the public effect path
# (`Ampd.Gateway.perform/5`, `Ampd.Authority.one_shot/1`, `Ampd.reset_demo/0`).
#
#   MIX_ENV=test B2_BENCH_OUT=/path/out.json [B2_BENCH_N=200] [B2_BENCH_JOURNAL=0,200,1000] \
#     mix run tools/b2_cost_bench.exs
#
# Progress is COMPLETED, ACCEPTED EFFECTS (allow == true with a receipt) —
# never CPU, never event counts. Persistence operations are counted by
# tracing `:dets.sync/1` and `:file.sync/1` calls in every process during
# the timed window, not inferred from the code. Startup (the first
# `warmup` effects of a phase) is reported apart from steady state.
#
# Guarantee difference, so the numbers are never read as like-for-like:
# the baseline has no fence — a receipt for a retired or restarted effect
# LANDS (reproduced 2026-09-16, F1/F3); the candidate refuses it at the
# resource and writes one witness line per lifecycle event.
alias Ampd.{Authority, Effects, Gateway}

defmodule B2Bench do
  @cap "github.pr.draft"
  @resource "traaviis/trvm"

  def req,
    do: %{"er" => "er-github.pr.draft", "rev" => 1, "params" => Ampd.Core.params()["pr.draft"]}

  def world! do
    Ampd.reset_demo()
    Authority.revoke_domain(@cap)
    :ok
  end

  # pre-populate the journal with `n` completed effects (journal growth is a known cost)
  def grow!(0), do: :ok

  def grow!(n) do
    for _ <- 1..n do
      Authority.one_shot(@cap)
      %{"allow" => true} = Gateway.perform(@cap, @resource, Gateway.ctx(), req())
    end

    :ok
  end

  def stats([]), do: %{n: 0}

  def stats(list) do
    l = Enum.sort(list)
    k = length(l)
    mean = Enum.sum(l) / k
    var = Enum.reduce(l, 0, fn x, a -> a + (x - mean) * (x - mean) end) / max(k - 1, 1)

    %{
      n: k,
      p50_us: Enum.at(l, div(k, 2)) / 1000,
      p90_us: Enum.at(l, div(k * 9, 10)) / 1000,
      p99_us: Enum.at(l, min(k - 1, div(k * 99, 100))) / 1000,
      min_us: hd(l) / 1000,
      max_us: List.last(l) / 1000,
      mean_us: mean / 1000,
      stddev_us: :math.sqrt(var) / 1000
    }
  end

  def timed(f) do
    s = System.monotonic_time(:nanosecond)
    r = f.()
    {System.monotonic_time(:nanosecond) - s, r}
  end

  # ---- persistence-operation tracing --------------------------------
  def trace_start do
    :erlang.trace_pattern({:dets, :sync, 1}, true, [:global])
    :erlang.trace_pattern({:file, :sync, 1}, true, [:global])
    :erlang.trace(:all, true, [:call, {:tracer, self()}])
    :erlang.trace(:new_processes, true, [:call, {:tracer, self()}])
    :ok
  end

  def trace_stop do
    :erlang.trace(:all, false, [:call])
    :erlang.trace(:new_processes, false, [:call])
    :erlang.trace_pattern({:dets, :sync, 1}, false, [:global])
    :erlang.trace_pattern({:file, :sync, 1}, false, [:global])
    drain(%{dets_sync: 0, file_sync: 0})
  end

  defp drain(acc) do
    receive do
      {:trace, _, :call, {:dets, :sync, _}} -> drain(%{acc | dets_sync: acc.dets_sync + 1})
      {:trace, _, :call, {:file, :sync, _}} -> drain(%{acc | file_sync: acc.file_sync + 1})
      {:trace, _, _, _} -> drain(acc)
    after
      0 -> acc
    end
  end

  def load,
    do:
      File.read!("/proc/loadavg")
      |> String.split()
      |> Enum.take(3)
      |> Enum.map(&String.to_float/1)

  # ---- one sequential phase: n effects, each mint + perform ----------
  def sequential(n, warmup) do
    world!()
    trace_start()

    rows =
      for _ <- 1..n do
        {mint, _} = timed(fn -> Authority.one_shot(@cap) end)
        {t, r} = timed(fn -> Gateway.perform(@cap, @resource, Gateway.ctx(), req()) end)
        %{mint: mint, perform: t, ok: r["allow"] == true and r["receipt"] != nil}
      end

    ops = trace_stop()
    {startup, steady} = Enum.split(rows, warmup)
    completed = Enum.count(rows, & &1.ok)

    %{
      n: n,
      completed: completed,
      refused: n - completed,
      startup: %{
        perform: stats(Enum.map(startup, & &1.perform)),
        mint: stats(Enum.map(startup, & &1.mint))
      },
      steady: %{
        perform: stats(Enum.map(steady, & &1.perform)),
        mint: stats(Enum.map(steady, & &1.mint))
      },
      persistence_ops_total: ops,
      persistence_ops_per_effect: %{
        dets_sync: ops.dets_sync / n,
        file_sync: ops.file_sync / n
      },
      throughput_effects_per_s:
        completed / (Enum.sum(Enum.map(rows, &(&1.mint + &1.perform))) / 1.0e9)
    }
  end

  # ---- retirement: the failure path, adapter raises → UNKNOWN ----------
  def retirement(n) do
    world!()

    rows =
      for _ <- 1..n do
        Authority.one_shot(@cap)

        {t, r} =
          timed(fn ->
            Gateway.perform(@cap, @resource, Gateway.ctx(), req(), fn _ ->
              raise "adapter refused"
            end)
          end)

        %{
          t: t,
          unknown: r["allow"] == false and Effects.get(r["effect_id"])["state"] == "UNKNOWN"
        }
      end

    %{
      n: n,
      unknown: Enum.count(rows, & &1.unknown),
      perform_to_unknown: stats(Enum.map(rows, & &1.t))
    }
  end

  # ---- concurrency: c performers, each its own mint+perform loop ---------
  def concurrent(c, per) do
    world!()

    {wall, results} =
      timed(fn ->
        1..c
        |> Task.async_stream(
          fn _ ->
            for _ <- 1..per do
              Authority.one_shot(@cap)
              {t, r} = timed(fn -> Gateway.perform(@cap, @resource, Gateway.ctx(), req()) end)
              {t, r["allow"] == true and r["receipt"] != nil}
            end
          end,
          max_concurrency: c,
          timeout: 300_000,
          ordered: false
        )
        |> Enum.flat_map(fn {:ok, rows} -> rows end)
      end)

    completed = Enum.count(results, &elem(&1, 1))

    %{
      performers: c,
      per_performer: per,
      completed: completed,
      refused: c * per - completed,
      wall_ms: wall / 1.0e6,
      throughput_effects_per_s: completed / (wall / 1.0e9),
      latency: stats(Enum.map(results, &elem(&1, 0)))
    }
  end
end

n = String.to_integer(System.get_env("B2_BENCH_N") || "200")
warmup = 20

journals =
  (System.get_env("B2_BENCH_JOURNAL") || "0,200,1000")
  |> String.split(",")
  |> Enum.map(&String.to_integer/1)

load_before = B2Bench.load()

by_journal =
  for j <- journals do
    result =
      (fn ->
         Ampd.reset_demo()
         Authority.revoke_domain("github.pr.draft")
         B2Bench.grow!(j)
         B2Bench.trace_start()

         rows =
           for _ <- 1..n do
             {mint, _} = B2Bench.timed(fn -> Authority.one_shot("github.pr.draft") end)

             {t, r} =
               B2Bench.timed(fn ->
                 Gateway.perform("github.pr.draft", "traaviis/trvm", Gateway.ctx(), B2Bench.req())
               end)

             %{mint: mint, perform: t, ok: r["allow"] == true and r["receipt"] != nil}
           end

         ops = B2Bench.trace_stop()
         {startup, steady} = Enum.split(rows, warmup)
         completed = Enum.count(rows, & &1.ok)

         %{
           journal_prepopulated: j,
           n: n,
           completed: completed,
           refused: n - completed,
           startup_perform: B2Bench.stats(Enum.map(startup, & &1.perform)),
           steady_perform: B2Bench.stats(Enum.map(steady, & &1.perform)),
           steady_mint: B2Bench.stats(Enum.map(steady, & &1.mint)),
           persistence_ops_total: ops,
           persistence_ops_per_effect: %{
             dets_sync: ops.dets_sync / n,
             file_sync: ops.file_sync / n
           },
           throughput_effects_per_s:
             completed / (Enum.sum(Enum.map(rows, &(&1.mint + &1.perform))) / 1.0e9)
         }
       end).()

    result
  end

retire = B2Bench.retirement(min(n, 100))
conc1 = B2Bench.concurrent(1, div(n, 2))
conc8 = B2Bench.concurrent(8, div(n, 8))
load_after = B2Bench.load()

out = %{
  host: %{
    schedulers: System.schedulers_online(),
    otp: System.otp_release(),
    elixir: System.version(),
    load_before: load_before,
    load_after: load_after,
    data_dir: Ampd.Store.data_dir()
  },
  settings: %{n: n, warmup: warmup, journals: journals},
  sequential_by_journal_size: by_journal,
  retirement: retire,
  concurrent_1: conc1,
  concurrent_8: conc8,
  note:
    "progress = completed accepted effects; persistence ops counted by tracing :dets.sync/1 and :file.sync/1 in all processes during the timed window (dets sync may itself call file:sync — both raw counts are reported); startup = the first #{warmup} effects of a phase; the mint is inside the total order and is not part of the effect path but every effect needs a fresh one-shot grant"
}

File.write!(System.fetch_env!("B2_BENCH_OUT"), JSON.encode!(out))

IO.puts(
  Enum.map_join(by_journal, "\n", fn r ->
    "journal #{r.journal_prepopulated}: perform steady p50 #{Float.round(r.steady_perform.p50_us, 0)} us · p90 #{Float.round(r.steady_perform.p90_us, 0)} · mean #{Float.round(r.steady_perform.mean_us, 0)} · sd #{Float.round(r.steady_perform.stddev_us, 0)} · dets_sync/effect #{Float.round(r.persistence_ops_per_effect.dets_sync, 2)} · file_sync/effect #{Float.round(r.persistence_ops_per_effect.file_sync, 2)} · #{r.completed}/#{r.n} completed · #{Float.round(r.throughput_effects_per_s, 1)} eff/s"
  end) <>
    "\nretirement (adapter raise → UNKNOWN) p50 #{Float.round(retire.perform_to_unknown.p50_us, 0)} us · #{retire.unknown}/#{retire.n} UNKNOWN" <>
    "\nconcurrent 1: #{Float.round(conc1.throughput_effects_per_s, 1)} eff/s · #{conc1.completed} completed · p50 #{Float.round(conc1.latency.p50_us, 0)} us" <>
    "\nconcurrent 8: #{Float.round(conc8.throughput_effects_per_s, 1)} eff/s · #{conc8.completed} completed · p50 #{Float.round(conc8.latency.p50_us, 0)} us · p99 #{Float.round(conc8.latency.p99_us, 0)}" <>
    "\nload before #{inspect(load_before)} after #{inspect(load_after)}"
)
