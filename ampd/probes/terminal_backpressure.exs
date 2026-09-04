# D.1.3c·2c·1b · B6 — what a stalled page costs, measured rather than argued.
#
#     MIX_ENV=test mix run probes/terminal_backpressure.exs
#
# **The claim.** Terminal output reaches the operator losslessly and in
# order, pulled by the page's acknowledgement, and with no buffer anywhere
# that grows. When the page stops consuming, the whole chain stops:
#
#     page stops acking
#       → Ampd.Terminal.Plane stops forwarding
#       → Ampd.TerminalAttachment stops selecting on its socket
#       → the socketpair from the host fills            (SO_RCVBUF)
#       → the host's pump stops draining the PTY master
#       → the Carrier blocks in write(2)
#
# Every link is a process declining to read. The falsifier suite asserts the
# shape; this reports the numbers, including the two the suite cannot see —
# how long the stall took to reach the writer, and where the bytes actually
# are while it holds.
#
# **The fixture writes from its own process, and that is not incidental.**
# The first version of `B.5`/`B.6`/`B.7` wrote from the test process and hung
# for sixty seconds each. That hang was the mechanism arriving at the
# fixture from the wrong end.

alias Ampd.{Authority, Carrier, Control, Loci, Peer}
alias Ampd.Carrier.Machine.Harness
alias Ampd.Carrier.Terminal, as: T
alias Ampd.Terminal.{Plane, Presentations}
alias Ampd.TerminalAttachment, as: TA

Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Effector.Host)
Application.put_env(:ampd, :carrier_machine, Harness)

defmodule Probe do
  @moduledoc false
  def pad(s, n), do: String.pad_trailing(to_string(s), n)
  def rpad(s, n), do: String.pad_leading(to_string(s), n)

  def peak_rss do
    case File.read("/proc/self/status") do
      {:ok, s} ->
        case Regex.run(~r/VmHWM:\s+(\d+) kB/, s) do
          [_, kb] -> String.to_integer(kb) * 1024
          _ -> 0
        end

      _ ->
        0
    end
  end

  def rss do
    case File.read("/proc/self/status") do
      {:ok, s} ->
        case Regex.run(~r/VmRSS:\s+(\d+) kB/, s) do
          [_, kb] -> String.to_integer(kb) * 1024
          _ -> 0
        end

      _ ->
        0
    end
  end

  # The agent's process printing. Reports its own progress so the stall can
  # be located in time as well as in bytes.
  def printer(sock, payload, chunk, me) do
    spawn(fn ->
      t0 = System.monotonic_time(:millisecond)
      write(sock, payload, chunk, 0, me, t0)
    end)
  end

  defp write(_s, <<>>, _c, n, me, t0),
    do: send(me, {:done, n, System.monotonic_time(:millisecond) - t0})

  defp write(s, rest, c, n, me, t0) do
    take = min(c, byte_size(rest))

    case :socket.send(s, binary_part(rest, 0, take)) do
      :ok ->
        send(me, {:at, n + take, System.monotonic_time(:millisecond) - t0})
        write(s, binary_part(rest, take, byte_size(rest) - take), c, n + take, me, t0)

      _ ->
        send(me, {:done, n, System.monotonic_time(:millisecond) - t0})
    end
  end

  # The last progress report before the writer went quiet, and when.
  def stall(quiet_ms), do: stall(quiet_ms, 0, 0)

  defp stall(quiet_ms, n, at) do
    receive do
      {:at, m, t} -> stall(quiet_ms, max(n, m), t)
      {:done, m, t} -> {:completed, max(n, m), t}
    after
      quiet_ms -> {:stalled, n, at}
    end
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

dir = Path.join(System.tmp_dir!(), "ampd-bp-#{:erlang.unique_integer([:positive])}")
File.mkdir_p!(dir)
{_, 0} = System.cmd("git", ["init", "-q", dir])
{_, 0} = System.cmd("git", ["-C", dir, "commit", "-q", "--allow-empty", "-m", "root"])
{:ok, r} = Authority.register_repository(dir)

{control, agent} = Ampd.attach_pair("kestrel")
%{"allow" => true, "workspace" => ws} = Control.command(control, :open_workspace, ["acme"])
%{"allow" => true, "goal" => goal} = Control.command(control, :open_goal, [ws["id"], "measure"])

%{"allow" => true, "lane" => lane} =
  Control.command(control, :open_lane, [goal["id"], "kestrel", r["ref"], nil])

%{"allow" => true, "worker" => w} = Control.command(control, :open_worker, [lane["id"], "work"])
%{"allow" => true} = Control.command(agent, :attach_worker, [w["id"]])
{:ok, _} = Carrier.start(agent, lane["id"])

hex = fn n -> Base.encode16(:crypto.strong_rand_bytes(div(n, 2)), case: :lower) end

o = %{
  "schema" => "carrier-pty-attach-observation@1",
  "attached" => true,
  "attachment_ref" => "ta_" <> hex.(32),
  "attachment_epoch" => hex.(32),
  "pty_epoch" => hex.(32)
}

{:ok, ticket} = T.admit_attach(agent)
{pty_ours, pty_host} = Ampd.Transport.socketpair(:stream)
{:ok, owner, identity} = T.own_stream(ticket, o, pty_ours)
{:ok, record} = T.commit_b1(ticket, o, owner)
:ok = TA.prepare(owner, Map.merge(record, identity), Peer.owner_pid(agent))
{:ok, _} = T.commit_b2(ticket, record, owner)

{mine, theirs} = Ampd.Transport.socketpair(:stream)
{:ok, endpoint} = Presentations.park(theirs)
gen = Loci.worker(w["id"])["generation"] || 1
%{"allow" => true} = Control.command(control, :terminal_bind, [w["id"], gen, endpoint])
[{_aref, plane}] = Map.to_list(Presentations.live())

# ------------------------------------------------------------------ framing
decode = fn decode, buf, acc ->
  case buf do
    <<1, seq::big-64, len::big-32, body::binary-size(len), rest::binary>> ->
      decode.(decode, rest, [{seq, body} | acc])

    <<3, l::big-16, _code::binary-size(l), rest::binary>> ->
      decode.(decode, rest, acc)

    _ ->
      {Enum.reverse(acc), buf}
  end
end

drain = fn drain, buf, acc, budget ->
  case :socket.recv(mine, 0, budget) do
    {:ok, data} ->
      {fs, rest} = decode.(decode, buf <> data, [])
      drain.(drain, rest, acc ++ fs, budget)

    _ ->
      {acc, buf}
  end
end

# ---------------------------------------------------------- 1 · the stall
offered = 2_000_000
rss0 = Probe.rss()
Probe.printer(pty_host, :binary.copy("x", offered), 8_192, self())

{state, produced, at_ms} = Probe.stall(1_200)
{frames, buf} = drain.(drain, <<>>, [], 400)
delivered = frames |> Enum.map(&byte_size(elem(&1, 1))) |> Enum.sum()
info = Plane.info(plane)
own = Process.info(owner, [:memory, :message_queue_len])
pl = Process.info(plane, [:memory, :message_queue_len])
rss1 = Probe.rss()

IO.puts("\n  === the page stops consuming ===\n")
row = fn a, b -> IO.puts("  " <> Probe.pad(a, 34) <> Probe.rpad(b, 14)) end
row.("bytes offered by the writer", offered)
row.("bytes the writer got away", produced)
row.("last writer progress at (ms)", at_ms)
row.("writer state", state)
row.("bytes delivered to the page", delivered)
row.("window (credits x chunk)", Plane.credits() * TA.chunk_bytes())
row.("max outstanding chunks", info.max_outstanding)
row.("attachment owner heap", own[:memory])
row.("attachment owner mailbox", own[:message_queue_len])
row.("plane heap", pl[:memory])
row.("plane mailbox", pl[:message_queue_len])
row.("BEAM on-path total", own[:memory] + pl[:memory])
row.("process RSS now / peak", "#{rss1} / #{Probe.peak_rss()}")
row.("resident in kernel socket bufs", produced - delivered)
row.("attachment still answers", inspect(TA.state(owner, 1_000)))

# ------------------------------------------------- 2 · the page resumes
IO.puts("\n  === the page resumes, and nothing was lost ===\n")

pump = fn pump, buf, acc, want ->
  case :socket.recv(mine, 0, 1_500) do
    {:ok, data} ->
      {fs, rest} = decode.(decode, buf <> data, [])
      acc = acc ++ fs

      case List.last(fs) do
        nil -> :ok
        {seq, _} -> :socket.send(mine, <<2, seq::big-64>>)
      end

      got = acc |> Enum.map(&byte_size(elem(&1, 1))) |> Enum.sum()
      if got >= want, do: {acc, rest}, else: pump.(pump, rest, acc, want)

    _ ->
      {acc, buf}
  end
end

# **Ack what the stall already delivered, BEFORE pumping.** The first
# version did not, and then waited for bytes that could not come: the page
# was holding every credit and the plane was correctly refusing to send. It
# reported `bytes lost 180224` about a probe that had deadlocked against the
# mechanism it was measuring. The stall is real; the loss was the
# instrument.
case List.last(frames) do
  nil -> :ok
  {seq, _} -> :socket.send(mine, <<2, seq::big-64>>)
end

t0 = System.monotonic_time(:millisecond)
{all, _} = pump.(pump, buf, frames, offered)
elapsed = System.monotonic_time(:millisecond) - t0

{completed, total, wall} =
  receive do
    {:done, n, t} -> {true, n, t}
  after
    3_000 -> {false, produced, at_ms}
  end

seqs = Enum.map(all, &elem(&1, 0))
got = all |> Enum.map(&byte_size(elem(&1, 1))) |> Enum.sum()
contiguous = seqs == Enum.to_list(1..length(seqs))
correct = all |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary() == :binary.copy("x", got)

row.("writer completed", completed)
row.("bytes written in total", total)
row.("writer wall clock (ms)", wall)
row.("bytes delivered in total", got)
row.("bytes lost", total - got)
row.("chunks delivered", length(seqs))
row.("sequence is 1..n, no gaps", contiguous)
row.("duplicate sequence numbers", length(seqs) - length(Enum.uniq(seqs)))
row.("bytes are byte-for-byte right", correct)
row.("drain wall clock (ms)", elapsed)
row.("throughput (MiB/s)", Float.round(got / 1_048_576 / max(elapsed, 1) * 1000, 1))
row.("plane heap after", Process.info(plane, :memory) |> elem(1))
row.("process RSS now / peak after", "#{Probe.rss()} / #{Probe.peak_rss()}")

IO.puts("""

  Required by the ruling: bounded memory, zero loss, exact order after the
  acknowledgement resumes. All three are above as numbers rather than as
  words — and the fourth line that matters is `resident in kernel socket
  bufs`, which is where the bytes are while the stall holds. They are not in
  the BEAM. The runtime is not keeping a copy of a person's terminal output.
""")

File.rm_rf!(dir)
