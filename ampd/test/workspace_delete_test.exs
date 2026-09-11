defmodule Ampd.WorkspaceDeleteTest do
  use ExUnit.Case, async: false
  alias Ampd.{Authority, Loci, Control}
  setup do
    Ampd.reset()
    {human, agent} = Ampd.attach_pair("workspace-delete-test")
    %{"workspace" => ws} = Control.command(human, :open_workspace, ["Disposable workspace"])
    %{"goal" => goal} = Control.command(human, :open_goal, [ws["id"], "Disposable goal"])
    %{human: human, agent: agent, ws: ws, goal: goal}
  end
  test "human deletion removes workspace and goals and never reuses identity", c do
    assert %{"allow" => true} = Control.command(c.human, :delete_workspace, [c.ws["id"]])
    assert Loci.workspace(c.ws["id"]) == nil
    assert Loci.goal(c.goal["id"]) == nil
    assert %{"allow" => false} = Control.command(c.human, :open_goal, [c.ws["id"], "stale"])
    %{"workspace" => next} = Control.command(c.human, :open_workspace, ["New"])
    refute next["id"] == c.ws["id"]
  end
  test "lane ancestry blocks deletion at the receiving store", c do
    lane = Authority.open_lane(%{"goal_ref" => c.goal["id"], "actor" => "test"})
    assert %{"allow" => false, "refusal" => %{"code" => "workspace-has-lanes"}} = Control.command(c.human, :delete_workspace, [c.ws["id"]])
    assert Loci.workspace(c.ws["id"]) == c.ws
    assert Loci.goal(c.goal["id"]) == c.goal
    assert Loci.lane(lane["id"]) == lane
  end
  test "agent and unordered callers cannot delete", c do
    assert %{"allow" => false} = Control.command(c.agent, :delete_workspace, [c.ws["id"]])
    assert {:refused, _} = GenServer.call(Loci, {:delete_workspace, c.ws["id"]})
    assert Loci.class(:delete_workspace) == :mutate
    assert Loci.workspace(c.ws["id"]) == c.ws
  end
end
