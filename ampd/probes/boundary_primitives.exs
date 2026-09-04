# boundary_primitives — what the OTHER cross-process primitives do to their
# caller when the participant is absent, dies mid-call, or does not answer.
#
# C1.0b·2 measured `GenServer.call` and `:gen_server.send_request`. The
# reachability census turned up three more primitives inside the total order
# — `GenServer.cast/2`, `:dets.*`, and a `GenServer.call` addressed to a
# **pid** rather than a name — and a decision to exclude any of them from the
# participant boundary is worth nothing unless it rests on what they do.
#
#     elixir probes/boundary_primitives.exs

defmodule Victim do
  use GenServer
  def start(name), do: GenServer.start(__MODULE__, :ok, name: name)
  def init(:ok), do: {:ok, %{n: 0}}
  def handle_call(:ping, _f, s), do: {:reply, :pong, s}
  def handle_call(:boom, _f, _s), do: exit(:boom)
  def handle_call(:slow, _f, s), do: (Process.sleep(3_000); {:reply, :late, s})
  def handle_cast(_, s), do: {:noreply, s}
end

row = fn label, f ->
  {survived, result} =
    try do
      {true, f.()}
    catch
      kind, why -> {false, {kind, why}}
    end

  IO.puts(
    String.pad_trailing(label, 46) <>
      String.pad_trailing(inspect(result, limit: 3), 44) <>
      if(survived, do: "caller LIVED", else: "caller DIED")
  )
end

IO.puts("\n  === GenServer.cast to a name that does not exist ===")
row.("cast, absent name", fn -> GenServer.cast(:no_such_participant_at_all, :x) end)

{:ok, v1} = Victim.start(:probe_victim_1)
row.("cast, live participant", fn -> GenServer.cast(:probe_victim_1, :x) end)
GenServer.stop(v1, :normal)
Process.sleep(50)
row.("cast, name whose process has died", fn -> GenServer.cast(:probe_victim_1, :x) end)
row.("cast, dead pid", fn -> GenServer.cast(v1, :x) end)

IO.puts("\n  === GenServer.call addressed to a PID (not a name) ===")
{:ok, v2} = Victim.start(:probe_victim_2)
row.("call pid, alive", fn -> GenServer.call(v2, :ping) end)
GenServer.stop(v2, :normal)
Process.sleep(50)
row.("call DEAD pid", fn -> GenServer.call(v2, :ping, 200) end)

IO.puts("\n  === :gen_server.send_request addressed to a PID ===")
{:ok, v3} = Victim.start(:probe_victim_3)

row.("send_request pid, alive", fn ->
  id = :gen_server.send_request(v3, :ping)
  :gen_server.receive_response(id, 1_000)
end)

row.("send_request pid, dies during", fn ->
  id = :gen_server.send_request(v3, :boom)
  :gen_server.receive_response(id, 1_000)
end)

Process.sleep(50)

row.("send_request DEAD pid", fn ->
  id = :gen_server.send_request(v3, :ping)
  :gen_server.receive_response(id, 500)
end)

{:ok, v4} = Victim.start(:probe_victim_4)

row.("send_request pid, timeout", fn ->
  id = :gen_server.send_request(v4, :slow)
  :gen_server.receive_response(id, 200)
end)

IO.puts("\n  === :dets, whose table is served by a process ===")
dir = Path.join(System.tmp_dir!(), "ampd_probe_dets_#{:erlang.unique_integer([:positive])}")
File.mkdir_p!(dir)
file = Path.join(dir, "t.dets") |> String.to_charlist()

{:ok, tab} = :dets.open_file(:probe_tab, file: file, type: :set)
row.("dets.insert, open table", fn -> :dets.insert(tab, {:k, 1}) end)
row.("dets.lookup, open table", fn -> :dets.lookup(tab, :k) end)
:dets.close(tab)
row.("dets.insert, CLOSED table", fn -> :dets.insert(:probe_tab, {:k, 2}) end)
row.("dets.lookup, CLOSED table", fn -> :dets.lookup(:probe_tab, :k) end)
row.("dets.sync, CLOSED table", fn -> :dets.sync(:probe_tab) end)
row.("dets.close, CLOSED table", fn -> :dets.close(:probe_tab) end)
row.("dets.insert, never-opened table", fn -> :dets.insert(:probe_never, {:k, 1}) end)

{:ok, tab2} = :dets.open_file(:probe_tab_2, file: file, type: :set)
owner = :dets.info(tab2, :pid)
IO.puts("    (the table is served by #{inspect(owner)} — a process)")
Process.exit(owner, :kill)
Process.sleep(100)
row.("dets.insert after the SERVER was killed", fn -> :dets.insert(:probe_tab_2, {:k, 3}) end)

File.rm_rf!(dir)

IO.puts("\n  === what a cast reports about delivery ===")
IO.puts("    GenServer.cast/2 returns :ok for a name nothing is registered")
IO.puts("    under, so a cast CANNOT report whether it was delivered and")
IO.puts("    cannot fail the caller. It is not a participant crossing.\n")
