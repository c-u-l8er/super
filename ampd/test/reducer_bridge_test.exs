Code.require_file("../../tools/hypersurface/reducer_bridge.exs", __DIR__)

defmodule HyperSurface.ReducerBridgeTest do
  use ExUnit.Case, async: false
  alias Ampd.{Authority, Bridge, Control, Loci, Peer}
  alias Ampd.Carrier.Machine.Harness
  alias HyperSurface.ReducerBridge, as: Reducer

  @moduletag skip: is_nil(System.get_env("HS_TRVM_HOST"))

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

  defp start_reducer(executor), do: {:ok, start_supervised!({Reducer, executor})}

  defp real_reduce(input) do
    host = System.fetch_env!("HS_TRVM_HOST")
    driver = Path.expand("../../tools/hypersurface/reduce-file.mjs", __DIR__)
    path = Path.join(Ampd.Store.data_dir(), "reducer-#{System.unique_integer([:positive])}.txt")
    File.write!(path, input)

    try do
      {out, code} = System.cmd(System.find_executable("node"), [driver, host, path])
      assert code == 0, out
      result = JSON.decode!(out)
      assert result["workerExited"] == true
      assert result["status"] == "candidate"
      result
    after
      File.rm!(path)
    end
  end

  test "occupied Worker receives real checked reducer output exactly once", ctx do
    {:ok, server} = start_reducer(&real_reduce/1)
    {:ok, op} = Reducer.submit(server, ctx.agent, ctx.lane["id"], "(λx.x λy.y)")
    assert {:ok, r} = take_ready(server, ctx.agent, op)
    assert r.candidate["output"] == "λa.a"
    assert r.occupancy_epoch == Peer.attachment(ctx.agent)["occupancy_epoch"]
    assert {:refused, :operation_unknown} = Reducer.take(server, ctx.agent, op)
  end

  test "same actor without occupancy never reaches executor", ctx do
    owner = self()
    {:ok, server} = start_reducer(fn _ -> send(owner, :ran) end)
    {:ok, stranger} = Peer.attach_agent("kestrel")
    assert {:refused, _} = Reducer.submit(server, stranger, ctx.lane["id"], "*")
    refute_received :ran
  end

  test "detach and reattach same Worker invalidates a real completed result", ctx do
    owner = self()

    {:ok, server} =
      start_reducer(fn input ->
        result = real_reduce(input)
        send(owner, {:computed, self()})

        receive do
          :release -> result
        after
          5000 -> raise "test release timed out"
        end
      end)

    old_epoch = Peer.attachment(ctx.agent)["occupancy_epoch"]
    {:ok, op} = Reducer.submit(server, ctx.agent, ctx.lane["id"], "*")
    assert_receive {:computed, executor}, 5000
    assert Control.command(ctx.agent, :detach_worker, [])["allow"]
    assert Control.command(ctx.agent, :attach_worker, [ctx.worker["id"]])["allow"]
    refute old_epoch == Peer.attachment(ctx.agent)["occupancy_epoch"]
    send(executor, :release)
    assert {:refused, :owner_changed} = take_ready(server, ctx.agent, op)
  end

  test "cancellation drops a held real result and keeps the slot until exit", ctx do
    owner = self()

    {:ok, server} =
      start_reducer(fn input ->
        result = real_reduce(input)
        send(owner, {:computed, self()})

        receive do
          :release -> result
        after
          5000 -> raise "test release timed out"
        end
      end)

    {:ok, op} = Reducer.submit(server, ctx.agent, ctx.lane["id"], "*")
    assert_receive {:computed, executor}, 5000
    assert :ok = Reducer.cancel(server, ctx.agent, op)
    assert {:refused, :busy} = Reducer.submit(server, ctx.agent, ctx.lane["id"], "*")
    send(executor, :release)
    assert {:refused, :cancelled} = take_ready(server, ctx.agent, op)
  end

  test "another Peer cannot take or cancel an operation", ctx do
    {:ok, server} = start_reducer(fn _ -> %{"status" => "candidate"} end)
    {:ok, op} = Reducer.submit(server, ctx.agent, ctx.lane["id"], "*")
    {:ok, stranger} = Peer.attach_agent("kestrel")
    assert {:refused, :operation_unknown} = Reducer.take(server, stranger, op)
    assert {:refused, :operation_unknown} = Reducer.cancel(server, stranger, op)
    assert {:ok, _} = take_ready(server, ctx.agent, op)
  end

  test "invalid input and control channel never reach executor", ctx do
    owner = self()
    {:ok, server} = start_reducer(fn _ -> send(owner, :ran) end)
    assert {:refused, :agent_required} = Reducer.submit(server, ctx.control, ctx.lane["id"], "*")
    assert {:refused, :input_limit} = Reducer.submit(server, ctx.agent, ctx.lane["id"], :bad)

    assert {:refused, :input_limit} =
             Reducer.submit(server, ctx.agent, ctx.lane["id"], String.duplicate("x", 65537))

    refute_received :ran
  end

  test "executor failure yields no candidate and permits the next operation", ctx do
    {:ok, server} = start_reducer(fn _ -> exit(:experiment_failure) end)
    {:ok, op} = Reducer.submit(server, ctx.agent, ctx.lane["id"], "*")
    assert {:refused, :executor_failed} = take_ready(server, ctx.agent, op)
    assert {:ok, _} = Reducer.submit(server, ctx.agent, ctx.lane["id"], "*")
  end
end
