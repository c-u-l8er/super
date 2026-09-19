Code.require_file("../../tools/hypersurface/resident_executor.exs", __DIR__)
Code.require_file("../../tools/hypersurface/reducer_bridge.exs", __DIR__)

defmodule HyperSurface.RemoteResidentTest do
  @moduledoc """
  T3 -- the remote resident kind's OWN cases, beside the witness harness (which runs its seven cases through this kind
  under `B2_TRVM_EXECUTOR=remote`). What is different by construction, asserted rather than papered over: the daemon is
  on another host and this runtime did not start it, so there is NO kernel witness. A lost daemon under a job is
  `stop_unconfirmed`, never a result and never `executor_failed`; an unreachable endpoint refuses before anything is
  admitted; a cancel is confirmed only by the host's own word. The daemon here is TRVM's `residentd.mjs` on a loopback
  TCP port of the kernel's choosing (`B2_REMOTE_RESIDENT=host:port` points the cases at a lab host instead); the
  bridge sees the same thing either way.
  Requires HS_TRVM_HOST (the resident files are beside it) and REPLACEMENT_OUTPUT_DIR; skips otherwise.
  """
  use ExUnit.Case, async: false
  alias Ampd.{Authority, Bridge, Control, Loci, Peer}
  alias Ampd.Carrier.Machine.Harness
  alias HyperSurface.ReducerBridge, as: Reducer

  @moduletag skip:
               is_nil(System.get_env("HS_TRVM_HOST")) or
                 is_nil(System.get_env("REPLACEMENT_OUTPUT_DIR"))

  @compute System.get_env("B2_COMPUTE_DIR") || "/home/travis/ProjectAmp2/wek/b2/compute"
  @term_name "corpus-exp_2p16"
  @nf_sha256 "2318bd828467fea8f7ecb2e214a0a9fc736c23c08e62feacfa1c7d57d5118eb6"

  setup do
    if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()
    Ampd.reset()
    Bridge.reset()
    Peer.reset()
    Harness.reset()
    Application.delete_env(:ampd, :profile_overrides)
    Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Effector.Host)
    Application.put_env(:ampd, :carrier_machine, Harness)
    Ampd.Carrier.Machine.Gate.sync()

    on_exit(fn ->
      Application.delete_env(:ampd, :carrier_machine)
      Harness.reset()
    end)

    if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()
    Ampd.AuthorityCoordinator.transact(fn -> Loci.reset() end)
    Process.sleep(120)
    Authority.install_worktree()
    repo = init_repo!()
    {:ok, r} = Authority.register_repository(repo)
    {control, agent} = Ampd.attach_pair("kestrel")
    ws = ok!(Control.command(control, :open_workspace, ["acme"]), "workspace")
    goal = ok!(Control.command(control, :open_goal, [ws["id"], "reduce remotely"]), "goal")

    lane =
      ok!(Control.command(control, :open_lane, [goal["id"], "kestrel", r["ref"], nil]), "lane")

    w = ok!(Control.command(control, :open_worker, [lane["id"], "work"]), "worker")
    ok!(Control.command(agent, :attach_worker, [w["id"]]), "worker")
    %{agent: agent, lane: lane}
  end

  defp ok!(result, key) do
    assert result["allow"] == true,
           "expected #{key} to be allowed, got: #{inspect(Map.take(result, ["allow", "reason", "refusal"]))}"

    result[key]
  end

  defp init_repo! do
    dir = Path.join(Ampd.Store.data_dir(), "fixture-repo-remote-resident")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "README"), "remote\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.email", "remote@example.invalid"],
          ["config", "user.name", "Remote"],
          ["config", "commit.gpgsign", "false"],
          ["add", "-A"],
          ["commit", "-q", "-m", "init"]
        ] do
      {out, code} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
      assert code == 0, "fixture repo setup failed: git #{Enum.join(args, " ")} -> #{out}"
    end

    dir
  end

  # ---------------------------------------------------------------- the daemon (as a lab host would run it: no guardian)
  defp term(name), do: File.read!(Path.join([@compute, "terms", name <> ".ic"]))
  defp chain30, do: term("chain30-epoch-1")

  defp start_daemon do
    host = System.fetch_env!("HS_TRVM_HOST")
    residentd = Path.join(Path.dirname(host), "../resident/residentd.mjs") |> Path.expand()

    port =
      Port.open({:spawn_executable, System.find_executable("node")}, [
        :binary,
        :exit_status,
        {:line, 4096},
        args: [residentd, "--port", "0", "--bind", "127.0.0.1", "--pool", "1", "--max-queue", "2"]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    announce =
      receive do
        {^port, {:data, {:eol, line}}} -> JSON.decode!(line)
      after
        15_000 -> flunk("residentd did not announce")
      end

    [h, p] = String.split(announce["residentd"], ":")
    on_exit(fn -> System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true) end)

    %{
      port: port,
      os_pid: os_pid,
      host: h,
      tcp_port: String.to_integer(p),
      module: announce["module_sha256"]
    }
  end

  defp start_remote(d, timeout_ms \\ 3000) do
    {:ok, ex} = HyperSurface.RemoteResident.start_link(%{host: d.host, port: d.tcp_port})
    Process.unlink(ex)

    {:ok, bridge} =
      Reducer.start_link({:remote_resident, %{executor: ex, timeout_ms: timeout_ms}})

    Process.unlink(bridge)
    on_exit(fn -> for p <- [bridge, ex], Process.alive?(p), do: GenServer.stop(p) end)
    %{executor: ex, bridge: bridge}
  end

  defp signal(sig, pid), do: {_, 0} = System.cmd("kill", ["-#{sig}", to_string(pid)])

  defp await_take(server, peer, op, remaining \\ 500)
  defp await_take(_, _, _, 0), do: flunk("the slot never settled")

  defp await_take(server, peer, op, remaining) do
    case Reducer.take(server, peer, op) do
      :pending ->
        Process.sleep(10)
        await_take(server, peer, op, remaining - 1)

      result ->
        result
    end
  end

  defp gone?(pid, n \\ 300)
  defp gone?(_, 0), do: false

  defp gone?(pid, n) do
    case File.read("/proc/#{pid}/stat") do
      {:error, :enoent} ->
        true

      {:ok, stat} ->
        if String.contains?(stat, ") Z "),
          do: true,
          else:
            (
              Process.sleep(10)
              gone?(pid, n - 1)
            )
    end
  end

  defp record(name, map) do
    dir = System.fetch_env!("REPLACEMENT_OUTPUT_DIR")
    File.mkdir_p!(dir)
    path = Path.join(dir, "remote-resident.json")

    existing =
      case File.read(path) do
        {:ok, s} -> JSON.decode!(s)
        _ -> %{}
      end

    File.write!(path, JSON.encode!(Map.put(existing, name, map)))
  end

  # ------------------------------------------------------------------------------------------------ cases
  test "G1r · the sealed world over TCP: the same digest as the witness's receipt, and the candidate names the executor, the host and the module",
       ctx do
    d = start_daemon()
    r = start_remote(d)
    {:ok, op} = Reducer.submit(r.bridge, ctx.agent, ctx.lane["id"], chain30())
    assert {:ok, result} = await_take(r.bridge, ctx.agent, op)
    c = result.candidate
    assert c["status"] == "candidate" and c["jobRetired"] == true and c["workerExited"] == false
    assert :crypto.hash(:sha256, c["output"]) |> Base.encode16(case: :lower) == @nf_sha256
    assert c["executor"] == "remote" and c["host"] == d.host and c["port"] == d.tcp_port
    assert c["module_sha256"] == d.module
    record("g1r", %{"host" => d.host, "port" => d.tcp_port, "module_sha256" => d.module})
  end

  test "R-U · an endpoint nobody listens on: refused executor_unavailable at submit, nothing admitted",
       ctx do
    {:ok, ex} =
      HyperSurface.RemoteResident.start_link(%{
        host: "127.0.0.1",
        port: 1,
        connect_timeout_ms: 300
      })

    {:ok, bridge} = Reducer.start_link({:remote_resident, %{executor: ex, timeout_ms: 3000}})

    assert {:refused, :executor_unavailable} =
             Reducer.submit(bridge, ctx.agent, ctx.lane["id"], term(@term_name))

    assert {:error, {:not_ready, _}} = HyperSurface.RemoteResident.socket(ex)
    GenServer.stop(bridge)
    GenServer.stop(ex)
  end

  test "R-C · a cancel is a cancel frame confirmed by the host's own workerExited; the slot is cancelled, never a result",
       ctx do
    d = start_daemon()
    r = start_remote(d)
    signal("STOP", d.os_pid)
    {:ok, op} = Reducer.submit(r.bridge, ctx.agent, ctx.lane["id"], chain30())
    assert :pending = Reducer.take(r.bridge, ctx.agent, op)
    signal("CONT", d.os_pid)

    # the daemon reads the frame and the cancel together; the host confirms whichever it did (a cancel of a queued or
    # running job answers cancelled with workerExited after terminate; a job already retired answers :ok at once)
    assert :ok = Reducer.cancel(r.bridge, ctx.agent, op)
    assert {:refused, :cancelled} = await_take(r.bridge, ctx.agent, op)
  end

  test "R-L · the daemon dies under a job (SIGKILL on its host): no host word and no kernel witness here -> stop_unconfirmed, never a result, the bridge stays busy",
       ctx do
    d = start_daemon()
    r = start_remote(d)
    signal("STOP", d.os_pid)
    {:ok, op} = Reducer.submit(r.bridge, ctx.agent, ctx.lane["id"], chain30())
    assert :pending = Reducer.take(r.bridge, ctx.agent, op)
    signal("KILL", d.os_pid)
    assert gone?(d.os_pid)
    assert {:refused, :stop_unconfirmed} = await_take(r.bridge, ctx.agent, op)
    assert {:error, :stop_unconfirmed} = Reducer.cancel(r.bridge, ctx.agent, op)
    assert {:refused, :busy} = Reducer.submit(r.bridge, ctx.agent, ctx.lane["id"], chain30())
    # the executor's own account: it cannot kill what it does not own
    assert {:error, :stop_unconfirmed} = HyperSurface.RemoteResident.kill(r.executor)
    record("daemon_lost", %{"slot" => "stop_unconfirmed", "kernel_witness" => false})
  end

  test "R-N · a fresh executor over a fresh daemon serves the same Lane: the lost one fenced nothing (no guardian receipt exists to wait for)",
       ctx do
    d1 = start_daemon()
    r1 = start_remote(d1)
    signal("STOP", d1.os_pid)
    {:ok, op} = Reducer.submit(r1.bridge, ctx.agent, ctx.lane["id"], chain30())
    signal("KILL", d1.os_pid)
    assert {:refused, :stop_unconfirmed} = await_take(r1.bridge, ctx.agent, op)
    d2 = start_daemon()
    r2 = start_remote(d2)
    {:ok, op2} = Reducer.submit(r2.bridge, ctx.agent, ctx.lane["id"], chain30())

    assert {:ok, %{candidate: %{"jobRetired" => true, "port" => p}}} =
             await_take(r2.bridge, ctx.agent, op2)

    assert p == d2.tcp_port and p != d1.tcp_port
  end
end
