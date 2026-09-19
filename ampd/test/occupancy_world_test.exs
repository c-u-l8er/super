Code.require_file("../../tools/hypersurface/reducer_bridge.exs", __DIR__)

defmodule Ampd.OccupancyWorldTest do
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

  test "the four-arity decision validates against the lineage it is handed", ctx do
    {peer, att} = Peer.occupancy_snapshot(ctx.agent)
    lane = Loci.lane(ctx.lane["id"])
    world = Ampd.World.lineage()
    assert world != nil
    assert {:ok, w} = Ampd.Worker.occupancy_worker(att, peer, lane, world)
    assert w["id"] == att["worker_ref"]
    assert Ampd.Worker.occupancy_worker(att, peer, lane) == {:ok, w}

    other = %{world | "generation" => world["generation"] + 1}
    assert {:refused, ref} = Ampd.Worker.occupancy_worker(att, peer, lane, other)
    assert ref["code"] == "attachment-generation-stale"
    assert ref["operator_detail"]["current"] == other
    assert ref["operator_detail"]["attached_in"] == world

    assert {:refused, %{"code" => "attachment-generation-stale"}} =
             Ampd.Worker.occupancy_worker(att, peer, lane, nil)
  end

  test "the after bridge records the lineage its decision validated", ctx do
    {:ok, p} =
      HyperSurface.ReducerBridge.start_link(fn input ->
        %{"digest" => :crypto.hash(:sha256, input)}
      end)

    {:ok, op} = HyperSurface.ReducerBridge.submit(p, ctx.agent, ctx.lane["id"], "hello")

    assert {:ok, %{candidate: %{"digest" => _}}} =
             HyperSurface.ReducerBridge.await(p, ctx.agent, op)

    assert %{slot: nil} = :sys.get_state(p)
    GenServer.stop(p)
  end
end
