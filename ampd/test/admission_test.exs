Code.require_file("../../tools/hypersurface/reducer_bridge.exs", __DIR__)

defmodule HyperSurface.AdmissionTest do
  use ExUnit.Case, async: false
  alias Ampd.{Authority, Bridge, Control, Loci, Peer}
  alias Ampd.Carrier.Machine.Harness
  alias HyperSurface.ReducerBridge, as: Reducer

  @moduletag skip:
               is_nil(System.get_env("HS_TRVM_HOST")) or
                 is_nil(System.get_env("ADMISSION_OUTPUT_DIR"))

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

  @tag timeout: 30_000
  test "bounded burst against one occupied bridge", ctx do
    parent = self()

    records =
      for rep <- 1..5, mode <- [:legacy, :bounded] do
        executor_fun = fn _ ->
          send(parent, {:held, self()})

          receive do
            :release -> %{"output" => "λa.a"}
          after
            10_000 -> raise "fixture gate expired"
          end
        end

        {:ok, server} =
          if mode == :bounded,
            do: Reducer.start_link(executor_fun, admission: :bounded),
            else: Reducer.start_link(executor_fun)

        pid = if mode == :bounded, do: server.pid, else: server
        {:ok, op} = Reducer.submit(server, ctx.agent, ctx.lane["id"], "*")
        assert_receive {:held, executor}, 3000
        ops_before = Ampd.AuthorityCoordinator.ops()

        clients =
          for _ <- 1..256 do
            Task.async(fn ->
              send(parent, {:ready, self()})

              receive do
                :go -> :ok
              end

              start = System.monotonic_time(:nanosecond)
              result = Reducer.submit(server, ctx.agent, ctx.lane["id"], "*")
              assert result in [{:refused, :busy}, {:refused, :overloaded}]
              %{ms: (System.monotonic_time(:nanosecond) - start) / 1.0e6, result: elem(result, 1)}
            end)
          end

        for _ <- clients, do: assert_receive({:ready, _}, 3000)
        start = System.monotonic_time(:nanosecond)
        Enum.each(clients, &send(&1.pid, :go))
        Process.sleep(2)
        {:message_queue_len, observed_queue} = Process.info(pid, :message_queue_len)
        cancel_start = System.monotonic_time(:nanosecond)
        assert :ok = Reducer.cancel(server, ctx.agent, op)
        cancel_ms = (System.monotonic_time(:nanosecond) - cancel_start) / 1.0e6
        latencies = Enum.map(clients, &Task.await(&1, 10_000))
        elapsed_ms = (System.monotonic_time(:nanosecond) - start) / 1.0e6
        ops_after = Ampd.AuthorityCoordinator.ops()
        assert :pending = Reducer.take(server, ctx.agent, op)
        send(executor, :release)
        assert {:refused, :cancelled} = take_ready(server, ctx.agent, op)
        Reducer.stop(server)

        %{
          mode: mode,
          rep: rep,
          offered: 256,
          replies: length(latencies),
          elapsed_ms: elapsed_ms,
          refusal_ms: latencies,
          cancel_ms: cancel_ms,
          observed_bridge_queue: observed_queue,
          authority_ops_during_burst: ops_after - ops_before
        }
      end

    File.write!(
      Path.join(System.fetch_env!("ADMISSION_OUTPUT_DIR"), "overload.json"),
      JSON.encode!(records)
    )
  end

  test "one reserved submission while suspended; bypass and stale tokens refuse", ctx do
    {:ok, handle} = Reducer.start_link(fn _ -> %{"output" => "λa.a"} end, admission: :bounded)
    :sys.suspend(handle.pid)

    tasks =
      for _ <- 1..256,
          do: Task.async(fn -> Reducer.submit(handle, ctx.agent, ctx.lane["id"], "*") end)

    Process.sleep(100)
    {:messages, messages} = Process.info(handle.pid, :messages)

    assert Enum.count(messages, &match?({:"$gen_call", _, {:reserved_submit, _, _, _, _}}, &1)) ==
             1

    :sys.resume(handle.pid)
    replies = Enum.map(tasks, &Task.await/1)
    assert Enum.count(replies, &match?({:ok, _}, &1)) == 1
    assert Enum.count(replies, &(&1 == {:refused, :overloaded})) == 255

    assert {:refused, :admission_required} =
             Reducer.submit(handle.pid, ctx.agent, ctx.lane["id"], "*")

    assert {:refused, :overloaded} =
             GenServer.call(
               handle.pid,
               {:reserved_submit, make_ref(), ctx.agent, ctx.lane["id"], "*"}
             )

    Reducer.stop(handle)

    assert {:refused, :bridge_unavailable} =
             Reducer.submit(handle, ctx.agent, ctx.lane["id"], "*")
  end

  test "dead pre-enqueue reservation is recovered; admission preserves authorization", ctx do
    {:ok, handle} = Reducer.start_link(fn _ -> %{"output" => "λa.a"} end, admission: :bounded)
    parent = self()

    holder =
      spawn(fn ->
        true = :ets.insert_new(handle.admission, {:permit, make_ref(), self()})
        send(parent, :reserved)
      end)

    ref = Process.monitor(holder)
    assert_receive :reserved
    assert_receive {:DOWN, ^ref, :process, ^holder, _}
    # A server-handled sweep, rather than a client timeout, reclaims it.
    send(handle.pid, :sweep_admission)
    :sys.get_state(handle.pid)
    assert :ets.lookup(handle.admission, :permit) == []
    assert {:refused, :agent_required} = Reducer.submit(handle, ctx.control, ctx.lane["id"], "*")
    assert {:refused, :input_limit} = Reducer.submit(handle, ctx.agent, ctx.lane["id"], :bad)
    {:ok, stranger} = Peer.attach_agent("kestrel")
    assert {:refused, _} = Reducer.submit(handle, stranger, ctx.lane["id"], "*")
    assert {:ok, op} = Reducer.submit(handle, ctx.agent, ctx.lane["id"], "*")
    assert {:ok, _} = take_ready(handle, ctx.agent, op)
    assert {:refused, :operation_unknown} = Reducer.take(handle, ctx.agent, op)
    Reducer.stop(handle)
  end

  test "bounded admission composes with confirmed physical cancellation", ctx do
    driver = Path.join(Ampd.Store.data_dir(), "bounded-node.js")
    ready = Path.join(Ampd.Store.data_dir(), "bounded-node-ready")

    File.write!(driver, """
    require('node:fs').writeFileSync(process.argv[2], String(process.pid));
    setInterval(() => {}, 100);
    setTimeout(() => process.exit(0), 10000);
    """)

    cfg = %{
      guardian: Path.expand("../../tools/hypersurface/node-guardian", __DIR__),
      node: System.find_executable("node"),
      driver: driver,
      host: ready,
      scratch: Ampd.Store.data_dir(),
      timeout_ms: 3000
    }

    {:ok, handle} = Reducer.start_link({:managed_node, cfg}, admission: :bounded)
    {:ok, op} = Reducer.submit(handle, ctx.agent, ctx.lane["id"], "*")
    assert wait_ready(ready, 100)

    tasks =
      for _ <- 1..256,
          do: Task.async(fn -> Reducer.submit(handle, ctx.agent, ctx.lane["id"], "*") end)

    Process.sleep(2)
    started = System.monotonic_time(:nanosecond)
    assert :ok = Reducer.cancel(handle, ctx.agent, op)
    elapsed_ms = (System.monotonic_time(:nanosecond) - started) / 1.0e6
    replies = Enum.map(tasks, &Task.await/1)
    assert Enum.all?(replies, &(&1 in [{:refused, :busy}, {:refused, :overloaded}]))
    assert {:refused, :cancelled} = take_ready(handle, ctx.agent, op)
    # The guardian acknowledged reaping, so the child cannot be alive here.
    refute File.exists?("/proc/" <> File.read!(ready))

    File.write!(
      Path.join(System.fetch_env!("ADMISSION_OUTPUT_DIR"), "managed-burst.json"),
      JSON.encode!(%{
        cancel_ms: elapsed_ms,
        refused: length(replies),
        physical_exit_confirmed: true
      })
    )

    Reducer.stop(handle)
  end

  defp wait_ready(_, 0), do: false

  defp wait_ready(path, n) do
    if File.exists?(path),
      do: true,
      else:
        (
          Process.sleep(10)
          wait_ready(path, n - 1)
        )
  end
end
