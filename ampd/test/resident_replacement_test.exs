Code.require_file("../../tools/hypersurface/resident_executor.exs", __DIR__)
Code.require_file("../../tools/hypersurface/reducer_bridge.exs", __DIR__)

defmodule HyperSurface.ResidentReplacementTest do
  @moduledoc """
  F-X for the RESIDENT executor kind (`{:managed_resident, …}`), beside `replacement_test.exs`'s shape: the same Lane a
  Worker occupies, the same guardian, the same questions -- what does the slot say when the executor dies under a job,
  and what is a replacement. The answers differ from the one-shot kind in exactly the way `RESIDENT_EXECUTOR.md` §2
  says the kind differs: the executor is the daemon, not the job, so a daemon killed mid-job takes EVERY job's kernel
  witness with it, and a replacement is a NEW daemon with an EMPTY pool (TRVM `runtime/wasm/resident/README.md` §6.4).

  A corpus term reduces in under 20 ms on this host, so "mid-job" is made deterministic by SIGSTOP on the daemon
  before the submit: the job's connection completes into the kernel's backlog, its frame sits unread, the bridge's
  slot is pending, and the kill lands with that job in the slot. The kill is SIGKILL to the daemon (its guardian
  reaps it: status 42 if the stop byte won the race, 67 if the guardian's own poll did) or SIGKILL to the guardian
  (PDEATHSIG kills the daemon, but no reap receipt exists: the one-shot kind's "lost guardian proof").

  Requires HS_TRVM_HOST and REPLACEMENT_OUTPUT_DIR (skips otherwise); writes `resident-replacement.json` there.
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
    goal = ok!(Control.command(control, :open_goal, [ws["id"], "run a resident"]), "goal")

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
    dir = Path.join(Ampd.Store.data_dir(), "fixture-repo-resident-fx")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "README"), "resident-fx\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.email", "resident@example.invalid"],
          ["config", "user.name", "Resident"],
          ["config", "commit.gpgsign", "false"],
          ["add", "-A"],
          ["commit", "-q", "-m", "init"]
        ] do
      {out, code} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
      assert code == 0, "fixture repo setup failed: git #{Enum.join(args, " ")} -> #{out}"
    end

    dir
  end

  # ------------------------------------------------------------ the resident executor
  defp term, do: File.read!(Path.join([@compute, "terms", @term_name <> ".ic"]))

  defp resident_config do
    host = System.fetch_env!("HS_TRVM_HOST")

    %{
      guardian: Path.expand("../../tools/hypersurface/node-guardian", __DIR__),
      node: System.find_executable("node"),
      driver: Path.expand("../../tools/hypersurface/resident-serve.mjs", __DIR__),
      host: Path.join(Path.dirname(host), "../resident/resident.mjs") |> Path.expand(),
      scratch: Ampd.Store.data_dir(),
      pool: 2
    }
  end

  # One executor (one daemon) and one bridge over it; readiness learned by connecting, as the executor does.
  defp start_resident(timeout_ms \\ 3000) do
    {:ok, ex} = HyperSurface.ResidentExecutor.start_link(resident_config())
    Process.unlink(ex)
    {:ok, sock} = HyperSurface.ResidentExecutor.socket(ex)

    {:ok, bridge} =
      Reducer.start_link({:managed_resident, %{executor: ex, timeout_ms: timeout_ms}})

    Process.unlink(bridge)
    on_exit(fn -> for p <- [bridge, ex], Process.alive?(p), do: GenServer.stop(p) end)
    guardian = guardian_pid(ex)
    %{executor: ex, bridge: bridge, sock: sock, guardian: guardian, daemon: daemon_pid(guardian)}
  end

  defp guardian_pid(ex) do
    {:os_pid, pid} = Port.info(:sys.get_state(ex).port, :os_pid)
    pid
  end

  # the guardian's one child is `node resident-serve.mjs`; workers are threads inside it, not processes
  defp daemon_pid(guardian) do
    {out, 0} = System.cmd("pgrep", ["-P", to_string(guardian)])
    [pid] = out |> String.split("\n", trim: true)
    String.to_integer(pid)
  end

  defp signal(sig, pid), do: {_, 0} = System.cmd("kill", ["-#{sig}", to_string(pid)])

  # the daemon's own account of its pool, over the same wire a job uses
  defp stats(sock) do
    {:ok, s} = :gen_tcp.connect({:local, sock}, 0, [:binary, packet: 4, active: false], 500)
    :ok = :gen_tcp.send(s, JSON.encode!(%{op: "stats"}))
    {:ok, data} = :gen_tcp.recv(s, 0, 2000)
    :gen_tcp.close(s)
    JSON.decode!(data)
  end

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

  defp await_exit_status(ex, n \\ 300)
  defp await_exit_status(_, 0), do: nil

  defp await_exit_status(ex, n) do
    case :sys.get_state(ex).exit_status do
      nil ->
        Process.sleep(10)
        await_exit_status(ex, n - 1)

      status ->
        status
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
    path = Path.join(dir, "resident-replacement.json")

    existing =
      case File.read(path) do
        {:ok, s} -> JSON.decode!(s)
        _ -> %{}
      end

    File.write!(path, JSON.encode!(Map.put(existing, name, map)))
  end

  # ----------------------------------------------------------------------- cases

  test "warm path first: a job on a live daemon is a result with jobRetired, and the pool is warm",
       ctx do
    r = start_resident()
    s0 = stats(r.sock)
    assert s0["served"] == 0 and s0["spawned"] == 2 and s0["live"] == 2
    {:ok, op} = Reducer.submit(r.bridge, ctx.agent, ctx.lane["id"], term())
    assert {:ok, result} = await_take(r.bridge, ctx.agent, op)
    assert result.candidate["status"] == "candidate"
    assert result.candidate["jobRetired"] == true and result.candidate["workerExited"] == false
    s1 = stats(r.sock)
    assert s1["served"] == 1 and s1["replaced"] == 0 and s1["live"] == 2
    record("warm", %{"stats_before" => s0, "stats_after" => s1})
  end

  test "daemon killed with a job in the slot: never a result; the reaped status confirms the absence and spends the executor",
       ctx do
    r = start_resident()
    signal("STOP", r.daemon)
    {:ok, op} = Reducer.submit(r.bridge, ctx.agent, ctx.lane["id"], term())
    # the frame is in the kernel's buffer, unread; the slot is pending
    assert :pending = Reducer.take(r.bridge, ctx.agent, op)
    Process.sleep(50)
    assert :pending = Reducer.take(r.bridge, ctx.agent, op)

    signal("KILL", r.daemon)
    assert gone?(r.daemon)

    # the job's connection closed with no host word; the executor's guardian reaped the daemon (42 if the job's stop
    # byte reached it first, 67 if its own poll saw the SIGKILLed child first -- both are a wait, both confirm)
    status = await_exit_status(r.executor)
    assert status in [42, 67], "guardian status #{inspect(status)}"

    # the slot: confirmed absent, no result, and NOT stop_unconfirmed -- the kernel's witness was available and used
    assert {:refused, :executor_failed} = await_take(r.bridge, ctx.agent, op)
    assert {:refused, :operation_unknown} = Reducer.take(r.bridge, ctx.agent, op)

    # the executor is spent: the same bridge admits nothing more through it
    assert {:refused, :executor_unavailable} =
             Reducer.submit(r.bridge, ctx.agent, ctx.lane["id"], term())

    assert {:error, :daemon_exited} = HyperSurface.ResidentExecutor.socket(r.executor)
    record("daemon_killed", %{"guardian_status" => status})
  end

  test "guardian killed with a job in the slot: the proof is lost; stop_unconfirmed, and the bridge stays busy",
       ctx do
    r = start_resident()
    signal("STOP", r.daemon)
    {:ok, op} = Reducer.submit(r.bridge, ctx.agent, ctx.lane["id"], term())
    assert :pending = Reducer.take(r.bridge, ctx.agent, op)

    signal("KILL", r.guardian)

    # PDEATHSIG: the daemon dies with its guardian (SIGKILL reaches a stopped process), but nobody waited for it
    assert gone?(r.daemon)
    status = await_exit_status(r.executor)
    assert status == 137, "port status for a SIGKILLed guardian: #{inspect(status)}"

    assert {:refused, :stop_unconfirmed} = await_take(r.bridge, ctx.agent, op)
    assert {:error, :stop_unconfirmed} = Reducer.cancel(r.bridge, ctx.agent, op)
    assert {:refused, :stop_unconfirmed} = Reducer.take(r.bridge, ctx.agent, op)
    # the slot is never released: this bridge is done
    assert {:refused, :busy} = Reducer.submit(r.bridge, ctx.agent, ctx.lane["id"], term())
    record("guardian_killed", %{"port_status" => status})
  end

  test "daemon dies between jobs: the guardian's own poll reaps it (67) and the next job is refused, not lost",
       ctx do
    r = start_resident()

    # no job is connected, so no stop byte races the guardian: the status is the poll's, a non-zero child exit
    signal("KILL", r.daemon)
    assert gone?(r.daemon)
    status = await_exit_status(r.executor)
    assert status == 67, "guardian status #{inspect(status)}"

    assert {:refused, :executor_unavailable} =
             Reducer.submit(r.bridge, ctx.agent, ctx.lane["id"], term())

    # nothing was admitted: the bridge has no slot, and a replacement bridge over a fresh executor serves the Lane
    new = start_resident()
    {:ok, op} = Reducer.submit(new.bridge, ctx.agent, ctx.lane["id"], term())
    assert {:ok, %{candidate: %{"jobRetired" => true}}} = await_take(new.bridge, ctx.agent, op)
    record("daemon_died_idle", %{"guardian_status" => status})
  end

  test "replacement is a new daemon with an empty pool; the old executor cannot be reused; the Lane is NOT fenced",
       ctx do
    old = start_resident()
    # one job served, so the old pool is warm and its counters are non-zero
    {:ok, op} = Reducer.submit(old.bridge, ctx.agent, ctx.lane["id"], term())
    assert {:ok, _} = await_take(old.bridge, ctx.agent, op)
    assert stats(old.sock)["served"] == 1

    signal("STOP", old.daemon)
    {:ok, op} = Reducer.submit(old.bridge, ctx.agent, ctx.lane["id"], term())
    assert :pending = Reducer.take(old.bridge, ctx.agent, op)
    signal("KILL", old.daemon)
    assert gone?(old.daemon)
    assert {:refused, :executor_failed} = await_take(old.bridge, ctx.agent, op)

    # a NEW bridge over the OLD executor: refused, the daemon is gone and the executor says so
    {:ok, stale} =
      Reducer.start_link({:managed_resident, %{executor: old.executor, timeout_ms: 3000}})

    assert {:refused, :executor_unavailable} =
             Reducer.submit(stale, ctx.agent, ctx.lane["id"], term())

    GenServer.stop(stale)

    # the replacement: a new guardian, a new daemon, a new socket, an EMPTY pool
    new = start_resident()
    assert new.guardian != old.guardian and new.daemon != old.daemon and new.sock != old.sock
    s0 = stats(new.sock)
    assert s0["served"] == 0 and s0["replaced"] == 0 and s0["spawned"] == 2
    {:ok, op} = Reducer.submit(new.bridge, ctx.agent, ctx.lane["id"], term())
    assert {:ok, result} = await_take(new.bridge, ctx.agent, op)
    assert result.candidate["jobRetired"] == true
    assert stats(new.sock)["served"] == 1

    # the old executor's scratch (socket directory) goes with it
    old_dir = Path.dirname(old.sock)
    HyperSurface.ResidentExecutor.stop(old.executor)
    refute File.exists?(old_dir)

    record("replacement", %{
      "old" => %{"guardian" => old.guardian, "daemon" => old.daemon},
      "new" => %{"guardian" => new.guardian, "daemon" => new.daemon, "stats_empty" => s0},
      "lane_fenced_between_executors" => false
    })
  end
end
