Code.require_file("../../tools/hypersurface/node_executor.exs", __DIR__)
Code.require_file("../../tools/hypersurface/reducer_bridge.exs", __DIR__)

defmodule HyperSurface.ReplacementTest do
  use ExUnit.Case, async: false
  alias Ampd.{Authority, Bridge, Control, Loci, Peer}
  alias Ampd.Carrier.Machine.Harness
  alias HyperSurface.ReducerBridge, as: Reducer

  @moduletag skip:
               is_nil(System.get_env("HS_TRVM_HOST")) or
                 is_nil(System.get_env("REPLACEMENT_OUTPUT_DIR"))

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

  defp fence_dir, do: Path.join(Ampd.Store.data_dir(), "replacement-fence")

  defp start_fence do
    {:ok, pid} = HyperSurface.ExecutionFence.start_link(fence_dir())
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp fixture(mode) do
    base = Path.join(Ampd.Store.data_dir(), "replace-#{mode}")
    driver = base <> ".js"

    File.write!(driver, """
    require('node:fs').writeFileSync(process.argv[2], String(process.pid));
    setInterval(() => {}, 100);
    setTimeout(() => process.exit(0), 10000);
    """)

    %{
      guardian: Path.expand("../../tools/hypersurface/node-guardian", __DIR__),
      node: System.find_executable("node"),
      driver: driver,
      host: base <> ".ready",
      scratch: Ampd.Store.data_dir(),
      timeout_ms: 5000,
      fence: true
    }
  end

  defp await_unfenced(lane, n \\ 200)
  defp await_unfenced(_, 0), do: false

  defp await_unfenced(lane, n) do
    if HyperSurface.ExecutionFence.reconcile(lane) == :ok,
      do: true,
      else:
        (
          Process.sleep(10)
          await_unfenced(lane, n - 1)
        )
  end

  test "replacement waits through bridge death and fence restart until guardian receipt", ctx do
    fence = start_fence()
    cfg = fixture("bridge")
    {:ok, first} = Reducer.start_link({:managed_node, cfg}, admission: :bounded)
    {:ok, _} = Reducer.submit(first, ctx.agent, ctx.lane["id"], "*")
    assert await_file(cfg.host)
    node = File.read!(cfg.host) |> String.to_integer()
    owner = :sys.get_state(first.pid).slot.pid
    {:os_pid, guardian} = Port.info(:sys.get_state(owner).port, :os_pid)
    {_, 0} = System.cmd("kill", ["-STOP", to_string(guardian)])

    try do
      Process.unlink(first.pid)
      Process.exit(first.pid, :kill)
      Process.sleep(30)
      {:ok, replacement} = Reducer.start_link({:managed_node, cfg}, admission: :bounded)

      assert {:refused, :execution_fenced} =
               Reducer.submit(replacement, ctx.agent, ctx.lane["id"], "*")

      GenServer.stop(fence)
      start_fence()

      assert {:refused, :execution_fenced} =
               Reducer.submit(replacement, ctx.agent, ctx.lane["id"], "*")

      assert File.exists?("/proc/#{node}")
      {_, 0} = System.cmd("kill", ["-CONT", to_string(guardian)])
      assert await_unfenced(ctx.lane["id"])
      assert await_node_exit(node)
      File.rm!(cfg.host)
      {:ok, op} = Reducer.submit(replacement, ctx.agent, ctx.lane["id"], "*")
      assert await_file(cfg.host)
      assert :ok = Reducer.cancel(replacement, ctx.agent, op)
      assert {:refused, :cancelled} = take_ready(replacement, ctx.agent, op)
      Reducer.stop(replacement)
    after
      System.cmd("kill", ["-CONT", to_string(guardian)], stderr_to_stdout: true)
    end
  end

  test "orphan guardian receipt releases after owner death and fence restart", ctx do
    fence = start_fence()
    cfg = fixture("owner")
    {:ok, first} = Reducer.start_link({:managed_node, cfg}, admission: :bounded)
    {:ok, _} = Reducer.submit(first, ctx.agent, ctx.lane["id"], "*")
    assert await_file(cfg.host)
    node = File.read!(cfg.host) |> String.to_integer()
    owner = :sys.get_state(first.pid).slot.pid
    {:os_pid, guardian} = Port.info(:sys.get_state(owner).port, :os_pid)
    {_, 0} = System.cmd("kill", ["-STOP", to_string(guardian)])

    try do
      Process.exit(owner, :kill)
      Process.sleep(30)
      {:ok, replacement} = Reducer.start_link({:managed_node, cfg}, admission: :bounded)

      assert {:refused, :execution_fenced} =
               Reducer.submit(replacement, ctx.agent, ctx.lane["id"], "*")

      GenServer.stop(fence)
      start_fence()

      assert {:refused, :execution_fenced} =
               Reducer.submit(replacement, ctx.agent, ctx.lane["id"], "*")

      assert File.exists?("/proc/#{node}")
      {_, 0} = System.cmd("kill", ["-CONT", to_string(guardian)])
      assert await_unfenced(ctx.lane["id"])
      assert await_node_exit(node)
      File.rm!(cfg.host)
      {:ok, op} = Reducer.submit(replacement, ctx.agent, ctx.lane["id"], "*")
      assert await_file(cfg.host)
      assert :ok = Reducer.cancel(replacement, ctx.agent, op)
      assert {:refused, :cancelled} = take_ready(replacement, ctx.agent, op)
      Reducer.stop(replacement)
      Reducer.stop(first)
    after
      System.cmd("kill", ["-CONT", to_string(guardian)], stderr_to_stdout: true)
    end
  end

  test "lost guardian proof remains fenced across service restart", ctx do
    fence = start_fence()
    cfg = fixture("guardian")
    {:ok, first} = Reducer.start_link({:managed_node, cfg})
    {:ok, _} = Reducer.submit(first, ctx.agent, ctx.lane["id"], "*")
    assert await_file(cfg.host)
    owner = :sys.get_state(first).slot.pid
    {:os_pid, guardian} = Port.info(:sys.get_state(owner).port, :os_pid)
    {_, 0} = System.cmd("kill", ["-KILL", to_string(guardian)])
    assert await_node_exit(File.read!(cfg.host) |> String.to_integer())
    GenServer.stop(fence)
    start_fence()
    {:ok, replacement} = Reducer.start_link({:managed_node, cfg})

    assert {:refused, :execution_fenced} =
             Reducer.submit(replacement, ctx.agent, ctx.lane["id"], "*")

    assert {:error, :execution_fenced} = HyperSurface.ExecutionFence.reconcile(ctx.lane["id"])
    Reducer.stop(first)
    Reducer.stop(replacement)
    if Process.alive?(owner), do: GenServer.stop(owner)
  end

  test "wrong receipt cannot clear a claim and missing pending store refuses boot" do
    fence = start_fence()
    {:ok, claim} = HyperSurface.ExecutionFence.claim("lane-test")
    File.write!(claim.receipt, "wrong-attempt")
    assert {:error, :execution_fenced} = HyperSurface.ExecutionFence.reconcile("lane-test")
    GenServer.stop(fence)
    File.rm!(Path.join(fence_dir(), "pending.dets"))

    assert {:error, {:fence_store_unavailable, :missing_store}} =
             GenServer.start(HyperSurface.ExecutionFence, fence_dir(),
               name: HyperSurface.ExecutionFence
             )

    assert {:error, :fence_unavailable} = HyperSurface.ExecutionFence.claim("lane-test")
  end

  test "fenced real Wasm succeeds repeatedly and unavailable fence refuses", ctx do
    cfg = %{
      fixture("real")
      | driver: Path.expand("../../tools/hypersurface/reduce-file.mjs", __DIR__),
        host: System.fetch_env!("HS_TRVM_HOST")
    }

    {:ok, bridge} = Reducer.start_link({:managed_node, cfg}, admission: :bounded)
    assert {:refused, :fence_unavailable} = Reducer.submit(bridge, ctx.agent, ctx.lane["id"], "*")
    start_fence()
    samples = for _ <- 1..10, do: timed_job(Reducer, bridge, ctx, "(λx.x λy.y)")

    File.write!(
      Path.join(System.fetch_env!("REPLACEMENT_OUTPUT_DIR"), "fenced-real.json"),
      JSON.encode!(samples)
    )

    Reducer.stop(bridge)
  end

  test "pending claim survives abrupt fence-owner death" do
    fence = start_fence()
    {:ok, _} = HyperSurface.ExecutionFence.claim("abrupt-owner")
    ref = Process.monitor(fence)
    Process.exit(fence, :kill)
    assert_receive {:DOWN, ^ref, :process, ^fence, :killed}
    assert wait_store_closed(100)
    start_fence()
    assert {:error, :execution_fenced} = HyperSurface.ExecutionFence.claim("abrupt-owner")
  end

  defp wait_store_closed(0), do: false

  defp wait_store_closed(n) do
    if :dets.info(HyperSurface.ExecutionFence) == :undefined,
      do: true,
      else:
        (
          Process.sleep(10)
          wait_store_closed(n - 1)
        )
  end
end
