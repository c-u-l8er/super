# D.1.3c·2c·1a · A2 — what an operator projection costs when terminals print.
#
#     MIX_ENV=test mix run probes/projection_latency.exs
#
# **The question.** `Ampd.Worker.projected/1` builds one row per Worker and
# `Ampd.Projection.operator/0` builds it over the WHOLE Worker table, with no
# window and no cap. For one commit each row asked
# `Ampd.Carrier.Terminal.stream_phase/1`, which asks the process that owns
# that terminal's bytes and waits one second before reading silence as
# `:active` — a correct rule for one presentation.
#
# Two facts make that multiply rather than add:
#
#   1  the table is unbounded — `Ampd.Loci.workers/0` is a whole-table read
#   2  `Ampd.Projection.framed/2` falls back to
#      `Ampd.AuthorityCoordinator.observe/1`, which runs the closure INSIDE
#      the coordinator, and `coherent/3` may re-run it up to three times
#
# So the cost is (busy Workers) × (one second) × (up to three), spent inside
# the total order, to render a status badge. This measures it.
#
# **The old shape is reconstructed, not restored.** Nothing is edited. The
# `legacy` column runs the same primitives HEAD ran — `stream_phase/1` once
# per possessed Worker on top of the semantic derivation — so both columns
# are measured on this host, in this run, against the same fixture.

alias Ampd.{Authority, Carrier, Control, Loci, Peer, Worker}
alias Ampd.Carrier.Machine.Harness
alias Ampd.Carrier.Terminal, as: T
alias Ampd.Terminal.Presentation, as: P
alias Ampd.TerminalAttachment, as: TA

Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Effector.Host)
Application.put_env(:ampd, :carrier_machine, Harness)

defmodule Probe do
  @moduledoc false

  def pad(s, n), do: String.pad_trailing(to_string(s), n)

  def ms(fun) do
    {us, v} = :timer.tc(fun)
    {div(us, 1000), v}
  end

  # A stream owner blocked inside synchronous terminal I/O. `handle_call({:read,
  # …})` runs `:socket.recv/3` in the attachment process and nothing is ever
  # written to the far end of the fixture socketpair, so the owner cannot
  # answer `:state` for the whole window. Unlinked, and it swallows its own
  # client-side timeout: the SERVER stays blocked for the full window whatever
  # the caller does, which is the condition being measured.
  def busy(pid, window_ms) do
    spawn(fn ->
      try do
        Ampd.TerminalAttachment.read(pid, 4096, window_ms)
      catch
        :exit, _ -> :ok
      end
    end)
  end
end

# ------------------------------------------------------------------ fixture
IO.puts("\n  building fixture …")

Ampd.reset()
Ampd.Bridge.reset()
Peer.reset()
Harness.reset()
Ampd.Carrier.Machine.Gate.sync()
Ampd.AuthorityCoordinator.transact(fn -> Loci.reset() end)
Process.sleep(150)
Authority.install_worktree()

repo_dir = Path.join(System.tmp_dir!(), "ampd-projlat-#{:erlang.unique_integer([:positive])}")
File.mkdir_p!(repo_dir)
{_, 0} = System.cmd("git", ["init", "-q", repo_dir])
{_, 0} = System.cmd("git", ["-C", repo_dir, "commit", "-q", "--allow-empty", "-m", "root"])
{:ok, _r} = Authority.register_repository(repo_dir)

hex = fn n -> Base.encode16(:crypto.strong_rand_bytes(div(n, 2)), case: :lower) end

obs = fn ->
  %{
    "schema" => "carrier-pty-attach-observation@1",
    "attached" => true,
    "attachment_ref" => "ta_" <> hex.(32),
    "attachment_epoch" => hex.(32),
    "pty_epoch" => hex.(32)
  }
end

# --------------------------------------------------------------- the shapes

# What HEAD did, rebuilt from the same primitives: the semantic derivation
# for every Worker, and then — for every Worker that has a terminal — the
# question HEAD's `status_of/1` also asked. `stream_phase/1` is public, so
# this needs no edit to the module under measurement.
legacy = fn rows ->
  workers = Loci.workers()

  Map.new(workers, fn {id, w} ->
    semantic = P.status_of(w)

    phase =
      case Enum.find(rows, &(&1.worker["id"] == id and &1.pid != nil)) do
        nil -> :none
        row -> T.stream_phase(row.peer)
      end

    {id, {semantic, phase}}
  end)
end

repaired = fn _rows -> Worker.projected(Loci.workers()) end

# `Ampd.Projection.framed/2`'s fallback, which is what a churning world
# produces and what the cockpit's own subscription path takes.
ordered = fn fun ->
  try do
    {t, _} = Probe.ms(fn -> Ampd.AuthorityCoordinator.observe(fun) end)
    t
  catch
    :exit, {:timeout, _} -> :budget_exceeded
    :exit, _ -> :died
  end
end

# ----------------------------------------------------------------- the runs
window = 40_000

run = fn label, total, busy_n, kind_at ->
  Ampd.reset()
  Ampd.Bridge.reset()
  Peer.reset()
  Harness.reset()
  Ampd.Carrier.Machine.Gate.sync()
  Ampd.AuthorityCoordinator.transact(fn -> Loci.reset() end)
  Process.sleep(120)
  Authority.install_worktree()
  {:ok, r2} = Authority.register_repository(repo_dir)
  {:ok, ctl} = Peer.claim_control_channel()
  %{"allow" => true, "workspace" => ws2} = Control.command(ctl, :open_workspace, ["acme"])

  %{"allow" => true, "goal" => g2} =
    Control.command(ctl, :open_goal, [ws2["id"], "measure the projection"])

  # **One Lane holds one occupant**, so every Worker needs its own Lane and
  # its own agent identity. `kind` decides how far the fixture is taken:
  #
  #     :possessed   Worker + Carrier + an ACTIVE terminal with a live owner
  #     :idle        Worker + Carrier, no terminal
  #     :unoccupied  Worker, and nothing standing at it
  build2 = fn i, kind ->
    actor = "kestrel#{i}"

    %{"allow" => true, "lane" => lane} =
      Control.command(ctl, :open_lane, [g2["id"], actor, r2["ref"], nil])

    %{"allow" => true, "worker" => w} =
      Control.command(ctl, :open_worker, [lane["id"], "w#{i}"])

    if kind == :unoccupied do
      %{worker: w, kind: kind, pid: nil, peer: nil}
    else
      {:ok, agent} = Peer.attach_agent(actor)
      %{"allow" => true} = Control.command(agent, :attach_worker, [w["id"]])
      {:ok, _inc} = Carrier.start(agent, lane["id"])

      if kind == :idle do
        %{worker: w, kind: kind, pid: nil, peer: agent}
      else
        {:ok, ticket} = T.admit_attach(agent)
        {mine, theirs} = Ampd.Transport.socketpair(:stream)
        o = obs.()
        {:ok, pid, identity} = T.own_stream(ticket, o, mine)
        {:ok, record} = T.commit_b1(ticket, o, pid)
        :ok = TA.prepare(pid, Map.merge(record, identity), Peer.owner_pid(agent))
        {:ok, _active} = T.commit_b2(ticket, record, pid)
        %{worker: w, kind: kind, pid: pid, peer: agent, far: theirs}
      end
    end
  end

  rows = for i <- 1..total, do: build2.(i, kind_at.(i))
  possessed = Enum.filter(rows, &(&1.pid != nil))
  for row <- Enum.take(possessed, busy_n), do: Probe.busy(row.pid, window)
  Process.sleep(200)

  {t_rep, _} = Probe.ms(fn -> repaired.(rows) end)
  {t_leg, _} = Probe.ms(fn -> legacy.(rows) end)
  o_rep = ordered.(fn -> repaired.(rows) end)
  o_leg = ordered.(fn -> legacy.(rows) end)

  for row <- rows, row[:far], do: :socket.close(row.far)

  IO.puts(
    "  " <>
      Probe.pad(label, 30) <>
      Probe.pad(total, 8) <>
      Probe.pad(busy_n, 7) <>
      Probe.pad("#{t_rep} ms", 12) <>
      Probe.pad("#{t_leg} ms", 12) <>
      Probe.pad("#{o_rep}", 16) <>
      "#{o_leg}"
  )

  {t_rep, t_leg, o_rep, o_leg}
end

IO.puts("\n  === operator projection latency · repaired vs the shape it replaced ===\n")

IO.puts(
  "  " <>
    Probe.pad("configuration", 30) <>
    Probe.pad("workers", 8) <>
    Probe.pad("busy", 7) <>
    Probe.pad("repaired", 12) <>
    Probe.pad("legacy", 12) <>
    Probe.pad("repaired/ordered", 16) <>
    "legacy/ordered"
)

IO.puts("  " <> String.duplicate("-", 105))

all = fn _ -> :possessed end

results = [
  {"1 busy terminal", run.("1 busy terminal", 1, 1, all)},
  {"4 busy terminals", run.("4 busy terminals", 4, 4, all)},
  {"16 busy terminals", run.("16 busy terminals", 16, 16, all)},
  {"64 workers, mixed",
   run.("64 workers, mixed", 64, 16, fn i ->
     cond do
       rem(i, 4) == 0 -> :possessed
       rem(i, 4) == 1 -> :possessed
       rem(i, 4) == 2 -> :idle
       true -> :unoccupied
     end
   end)}
]

IO.puts("""

  budget            Ampd.AuthorityCoordinator.budget_ms/0 = #{Ampd.AuthorityCoordinator.budget_ms()} ms
  stream probe      Ampd.Carrier.Terminal.stream_probe_ms/0 = #{Ampd.Carrier.Terminal.stream_probe_ms()} ms

  `repaired` and `legacy` are the same projection built two ways in the same
  run. `*/ordered` is the same build inside `Ampd.AuthorityCoordinator.observe/1`
  — the path `Ampd.Projection.framed/2` takes when the optimistic seqlock
  loses, which is what a busy world produces and what the cockpit's own
  subscription path takes. `budget_exceeded` means the coordinator call did
  not return inside its own transaction budget: a projection that cannot be
  built is not a slow badge, it is an operator with no view.
""")

for {label, {a, b, c, d}} <- results do
  IO.puts(
    "  #{Probe.pad(label, 24)} direct #{a} → #{b} ms   ordered #{inspect(c)} → #{inspect(d)}"
  )
end

File.rm_rf!(repo_dir)
IO.puts("")
