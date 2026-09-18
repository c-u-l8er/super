Code.require_file("../../tools/hypersurface/node_executor.exs", __DIR__)
Code.require_file("../../tools/hypersurface/reducer_bridge.exs", __DIR__)

defmodule HyperSurface.ManagedNodeTest do
  use ExUnit.Case, async: false
  alias Ampd.{Authority, Bridge, Control, Loci, Peer}
  alias Ampd.Carrier.Machine.Harness
  alias HyperSurface.ReducerBridge, as: Reducer

  @moduletag skip:
               is_nil(System.get_env("HS_TRVM_HOST")) or
                 is_nil(System.get_env("MANAGED_OUTPUT_DIR"))

  setup do
    # **Drain first, then reset.**
    #
    # The reaper is a cast by design — nothing about a channel closing should
    # wait on machine latency — so the previous test's `Peer.reset/0` may have
    # announced an orphan that has not been processed yet. Draining *after*
    # `Ampd.reset()` writes that orphan's unresolved attempt into the freshly
    # reset world, where it blocks a Worker it has nothing to do with. Draining
    # first flushes it into the world it belongs to, which the reset then
    # clears.
    if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()

    Ampd.reset()
    Bridge.reset()
    Peer.reset()
    Harness.reset()
    Application.delete_env(:ampd, :profile_overrides)
    Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Effector.Host)
    Application.put_env(:ampd, :carrier_machine, Harness)

    # The resets above minted a fresh peer epoch, which fences the Gate until
    # it has established the physical carrier set empty under the new one.
    # Convergence is asynchronous in production — it is a recovery, not a
    # request path — so a test that wants to observe the settled state needs
    # the barrier, exactly as it needs `Reaper.drain/1`.
    Ampd.Carrier.Machine.Gate.sync()

    on_exit(fn ->
      Application.delete_env(:ampd, :carrier_machine)
      Harness.reset()
    end)

    # And once more after the resets, since `Peer.reset/0` above announces the
    # carriers it just dropped.
    if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()
    Ampd.AuthorityCoordinator.transact(fn -> Loci.reset() end)

    Process.sleep(120)
    Authority.install_worktree()

    repo = init_repo!()
    {:ok, r} = Authority.register_repository(repo)

    {control, agent} = Ampd.attach_pair("kestrel")
    ws = ok!(Control.command(control, :open_workspace, ["acme"]), "workspace")
    goal = ok!(Control.command(control, :open_goal, [ws["id"], "run a carrier"]), "goal")

    lane =
      ok!(Control.command(control, :open_lane, [goal["id"], "kestrel", r["ref"], nil]), "lane")

    worker = occupy!(control, agent, lane["id"])

    %{control: control, agent: agent, goal: goal, lane: lane, worker: worker, repo_ref: r["ref"]}
  end

  defp occupy!(control, agent, lane_id, purpose \\ "work") do
    w = ok!(Control.command(control, :open_worker, [lane_id, purpose]), "worker")
    ok!(Control.command(agent, :attach_worker, [w["id"]]), "worker")
    w
  end

  defp ok!(result, key) do
    assert result["allow"] == true,
           "expected #{key} to be allowed, got: #{inspect(Map.take(result, ["allow", "reason", "refusal"]))}"

    result[key]
  end

  defp init_repo! do
    dir = Path.join(Ampd.Store.data_dir(), "fixture-repo-d13b2")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "README"), "d13b2\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.email", "d13b2@example.invalid"],
          ["config", "user.name", "D13B2"],
          ["config", "commit.gpgsign", "false"],
          ["add", "-A"],
          ["commit", "-q", "-m", "init"]
        ] do
      {out, code} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
      assert code == 0, "fixture repo setup failed: git #{Enum.join(args, " ")} -> #{out}"
    end

    dir
  end

  defp take_ready(server, peer, op, remaining \\ 100)
  defp take_ready(_, _, _, 0), do: flunk("executor did not finish")

  defp take_ready(server, peer, op, remaining) do
    case Reducer.take(server, peer, op) do
      :pending ->
        Process.sleep(10)
        take_ready(server, peer, op, remaining - 1)

      result ->
        result
    end
  end

  defp await_take(mod, server, peer, op, count \\ 0) do
    if count > 1_000_000, do: raise("poll budget exceeded")

    case mod.take(server, peer, op) do
      :pending ->
        Process.sleep(1)
        await_take(mod, server, peer, op, count + 1)

      result ->
        {result, count}
    end
  end

  defp timed_job(mod, server, ctx, input) do
    t0 = System.monotonic_time(:nanosecond)
    {:ok, op} = mod.submit(server, ctx.agent, ctx.lane["id"], input)
    t1 = System.monotonic_time(:nanosecond)
    {{:ok, result}, polls} = await_take(mod, server, ctx.agent, op)
    t2 = System.monotonic_time(:nanosecond)
    assert result.candidate["output"] == "λa.a"
    assert {:refused, :operation_unknown} = mod.take(server, ctx.agent, op)

    %{
      submit_ms: (t1 - t0) / 1.0e6,
      wait_collect_ms: (t2 - t1) / 1.0e6,
      total_ms: (t2 - t0) / 1.0e6,
      pending_polls: polls
    }
  end

  defp await_file(path, n \\ 300)
  defp await_file(_, 0), do: false

  defp await_file(path, n) do
    if File.exists?(path),
      do: true,
      else:
        (
          Process.sleep(10)
          await_file(path, n - 1)
        )
  end

  defp pulse(path) do
    case File.read(path) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp await_node_exit(pid, n \\ 300)
  defp await_node_exit(_, 0), do: false

  defp await_node_exit(pid, n) do
    running =
      case File.read("/proc/#{pid}/stat") do
        {:ok, stat} -> not String.contains?(stat, ") Z ")
        {:error, :enoent} -> false
        _ -> true
      end

    if running,
      do:
        (
          Process.sleep(20)
          await_node_exit(pid, n - 1)
        ),
      else: true
  end

  defp config do
    %{
      guardian: Path.expand("../../tools/hypersurface/node-guardian", __DIR__),
      node: System.find_executable("node"),
      driver: Path.expand("../../tools/hypersurface/reduce-file.mjs", __DIR__),
      host: System.fetch_env!("HS_TRVM_HOST"),
      scratch: Ampd.Store.data_dir(),
      timeout_ms: 3000
    }
  end

  test "managed real Wasm yields only a checked result after physical exit", ctx do
    {:ok, server} = Reducer.start_link({:managed_node, config()})
    samples = for _ <- 1..20, do: timed_job(Reducer, server, ctx, "(λx.x λy.y)")
    GenServer.stop(server)

    File.write!(
      Path.join(System.fetch_env!("MANAGED_OUTPUT_DIR"), "real.json"),
      JSON.encode!(samples)
    )
  end

  test "managed completed results still require current occupancy", ctx do
    {:ok, server} = Reducer.start_link({:managed_node, config()})
    {:ok, op} = Reducer.submit(server, ctx.agent, ctx.lane["id"], "(λx.x λy.y)")
    assert wait_exited(server, 300)
    assert Control.command(ctx.agent, :detach_worker, [])["allow"]
    assert Control.command(ctx.agent, :attach_worker, [ctx.worker["id"]])["allow"]
    assert {:refused, :owner_changed} = Reducer.take(server, ctx.agent, op)
    GenServer.stop(server)
  end

  defp wait_exited(_, 0), do: false

  defp wait_exited(server, remaining) do
    if :sys.get_state(server).slot.exited do
      true
    else
      Process.sleep(10)
      wait_exited(server, remaining - 1)
    end
  end

  test "invalid Node results never become candidates", ctx do
    for {name, body} <- [
          {"invalid", "process.stdout.write('not JSON')"},
          {"unchecked",
           "process.stdout.write(JSON.stringify({status:'candidate', workerExited:false}))"},
          {"failed", "process.exit(1)"},
          {"oversized", "process.stdout.write('x'.repeat(2200000))"}
        ] do
      driver = Path.join(Ampd.Store.data_dir(), name <> ".js")
      File.write!(driver, body)
      {:ok, server} = Reducer.start_link({:managed_node, %{config() | driver: driver}})
      {:ok, op} = Reducer.submit(server, ctx.agent, ctx.lane["id"], "*")
      assert {:refused, :executor_failed} = take_ready(server, ctx.agent, op)
      assert {:refused, :operation_unknown} = Reducer.take(server, ctx.agent, op)
      GenServer.stop(server)
    end
  end

  test "missing guardian refuses without killing the bridge", ctx do
    cfg = %{config() | guardian: Path.join(Ampd.Store.data_dir(), "missing-guardian")}
    {:ok, server} = Reducer.start_link({:managed_node, cfg})

    assert {:refused, :executor_unavailable} =
             Reducer.submit(server, ctx.agent, ctx.lane["id"], "*")

    assert Process.alive?(server)
    assert :sys.get_state(server).slot == nil
    GenServer.stop(server)
  end

  @tag timeout: 30_000
  test "physical cleanup and lost-confirmation fences", ctx do
    records =
      for mode <- [:cancel, :bridge_kill, :owner_kill, :owner_stop, :deadline, :guardian_kill] do
        base = Path.join(Ampd.Store.data_dir(), "managed-#{mode}")
        driver = base <> ".js"

        File.write!(driver, """
        const fs = require('node:fs');
        const base = process.argv[2];
        fs.writeFileSync(base + '.ready', String(process.pid));
        let ticks = 0;
        setInterval(() => fs.writeFileSync(base + '.pulse', String(++ticks)), 20);
        // Independent watchdog bounds a failing test, not the tested stop path.
        setTimeout(() => process.exit(0), 10000);
        """)

        cfg = %{
          config()
          | driver: driver,
            host: base,
            timeout_ms: if(mode == :deadline, do: 750, else: 5000)
        }

        {:ok, server} = Reducer.start_link({:managed_node, cfg})
        {:ok, op} = Reducer.submit(server, ctx.agent, ctx.lane["id"], "*")
        assert await_file(base <> ".ready")
        node_pid = File.read!(base <> ".ready") |> String.to_integer()
        owner = :sys.get_state(server).slot.pid
        input_dir = :sys.get_state(owner).dir
        port = :sys.get_state(owner).port
        {:os_pid, guardian_pid} = Port.info(port, :os_pid)
        started = System.monotonic_time(:nanosecond)

        case mode do
          :cancel ->
            assert :ok = Reducer.cancel(server, ctx.agent, op)

          :bridge_kill ->
            Process.unlink(server)
            Process.exit(server, :kill)

          :owner_kill ->
            Process.exit(owner, :kill)

          :owner_stop ->
            GenServer.stop(owner)

          :deadline ->
            :ok

          :guardian_kill ->
            {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(guardian_pid)])
        end

        # Must stop long before the fixture's ten-second watchdog.
        assert await_node_exit(node_pid, 100), "Node survived #{mode}"
        stop_ms = (System.monotonic_time(:nanosecond) - started) / 1.0e6
        before = pulse(base <> ".pulse")
        Process.sleep(100)
        assert pulse(base <> ".pulse") == before

        outcome =
          case mode do
            :cancel ->
              assert {:refused, :cancelled} = take_ready(server, ctx.agent, op)
              "cancelled"

            :deadline ->
              assert {:refused, :executor_failed} = take_ready(server, ctx.agent, op)
              "executor_failed"

            :bridge_kill ->
              "bridge_dead"

            _ ->
              Process.sleep(20)
              assert {:refused, :stop_unconfirmed} = Reducer.take(server, ctx.agent, op)
              assert {:refused, :busy} = Reducer.submit(server, ctx.agent, ctx.lane["id"], "*")
              assert {:error, :stop_unconfirmed} = Reducer.cancel(server, ctx.agent, op)
              "stop_unconfirmed_slot_retained"
          end

        if mode != :guardian_kill, do: refute(File.exists?(input_dir))
        if Process.alive?(server), do: GenServer.stop(server)
        if Process.alive?(owner), do: GenServer.stop(owner)

        %{
          mode: mode,
          node_stopped: true,
          heartbeat_stopped: true,
          stop_observed_ms: stop_ms,
          outcome: outcome,
          node_pid: node_pid,
          guardian_pid: guardian_pid
        }
      end

    File.write!(
      Path.join(System.fetch_env!("MANAGED_OUTPUT_DIR"), "lifecycle.json"),
      JSON.encode!(records)
    )
  end
end
