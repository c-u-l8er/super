defmodule Ampd.BotIdentityTest do
  use ExUnit.Case, async: false
  alias Ampd.{Authority, BotIdentity, Control, Loci, Projection}

  setup do
    Ampd.reset()
    {human, agent} = Ampd.attach_pair("bot-identity-test")
    %{"workspace" => ws} = Control.command(human, :open_workspace, ["Bot workspace"])

    fields = %{
      "client_ref" => "local-builder",
      "workspace_ref" => ws["id"],
      "name" => "Builder",
      "role" => "Implementation",
      "instructions" => "Build reviewable changes.",
      "group" => "Super",
      "provider" => "ollama"
    }

    %{human: human, agent: agent, ws: ws, fields: fields}
  end

  defp values(f), do: Enum.map(BotIdentity.fields(), &f[&1])

  defp create(c) do
    assert %{"allow" => true, "bot" => bot} =
             Control.command(c.human, :register_bot, values(c.fields))

    bot
  end

  test "registration mints a stable actor but no authority or assignments", c do
    before =
      {Ampd.GrantRegistry.list(), Loci.lanes(), Loci.workers(), Ampd.World.authority_stores()}

    b = create(c)
    assert b["schema"] == "bot@1" and b["revision"] == 1
    assert String.starts_with?(b["actor"], "bot_")
    assert Projection.operator()["bots"][b["id"]] == b

    assert before ==
             {Ampd.GrantRegistry.list(), Loci.lanes(), Loci.workers(),
              Ampd.World.authority_stores()}

    refute Map.has_key?(b, "grants")
  end

  test "duplicate registration is idempotent, conflicting identity is refused", c do
    b = create(c)
    assert create(c) == b
    assert map_size(Loci.bots()) == 1

    assert {:refused, %{"code" => "bot-already-registered"}} =
             Authority.register_bot(%{c.fields | "name" => "Other"})
  end

  test "versioned edits preserve identity and reject stale overwrite", c do
    b = create(c)
    next = %{c.fields | "name" => "Builder two"}

    assert %{"bot" => changed} =
             Control.command(c.human, :update_bot, [b["id"], 1 | values(next)])

    assert changed["actor"] == b["actor"] and changed["revision"] == 2

    assert {:refused, %{"code" => "bot-revision-stale"}} =
             Authority.update_bot(b["id"], c.fields, 1)

    assert Loci.bot(b["id"])["name"] == "Builder two"
  end

  test "agent channels cannot register, update or remove identities", c do
    b = create(c)

    for {command, args} <- [
          {:register_bot, values(%{c.fields | "client_ref" => "other"})},
          {:update_bot, [b["id"], 1 | values(c.fields)]},
          {:remove_bot, [b["id"]]}
        ] do
      assert %{"allow" => false} = Control.command(c.agent, command, args)
    end

    assert Loci.bot(b["id"]) == b
  end

  test "receiving store refuses unordered creation and patch", c do
    assert {:refused, _} = Loci.create_bot(c.fields)
    b = create(c)
    assert {:refused, _} = Loci.update_bot(b["id"], c.fields, 1)
    assert {:refused, _} = Loci.remove_bot(b["id"])
    assert Loci.class(:create) == :mutate and Loci.class(:patch) == :mutate
  end

  test "profile cannot smuggle identity or authority fields", c do
    assert {:refused, _} = Authority.register_bot(Map.put(c.fields, "actor", "kestrel"))
    assert {:refused, _} = Authority.register_bot(Map.put(c.fields, "grants", ["*"]))
    b = create(c)

    assert {:refused, _} =
             Authority.update_bot(b["id"], %{c.fields | "client_ref" => "replacement"}, 1)

    assert {:refused, _} = Authority.update_bot(b["id"], Map.put(c.fields, "actor", "kestrel"), 1)
    assert Loci.bot(b["id"]) == b
  end

  test "missing workspace, invalid text and unsupported provider are refused", c do
    for fields <- [
          %{c.fields | "workspace_ref" => "ws_9999"},
          %{c.fields | "name" => " "},
          %{c.fields | "instructions" => <<0>>},
          %{c.fields | "provider" => "unknown"}
        ] do
      assert {:refused, _} = Authority.register_bot(fields)
    end

    assert Loci.bots() == %{}
  end

  test "agent projection contains only its own identity", c do
    b = create(c)
    other = Authority.register_bot(%{c.fields | "client_ref" => "other", "name" => "Reviewer"})
    assert Projection.agent(b["actor"])["bot_identity"] == b
    refute inspect(Projection.agent(b["actor"])) =~ other["actor"]
    assert Projection.agent("unregistered")["bot_identity"] == nil
    assert Projection.agent(b["actor"])["grants"] == []
  end

  test "older and sealed loci states gain no bots", _c do
    old = Loci.initial() |> Map.delete("bots")
    assert Loci.shape(old)["bots"] == %{}
    assert Loci.sealed_state()["bots"] == %{}
  end

  test "store restart retains bot identity and profile", c do
    b = create(c)
    pid = Process.whereis(Loci)
    :ok = Loci.close_store()
    Process.exit(pid, :kill)

    Enum.reduce_while(1..100, nil, fn _, _ ->
      if Process.whereis(Loci) not in [nil, pid] do
        {:halt, :ok}
      else
        Process.sleep(20)
        {:cont, nil}
      end
    end)

    assert Loci.sealed() == nil
    assert Loci.bot(b["id"]) == b
  end

  test "workspace deletion cannot orphan a bot; removal preserves local reference independence",
       c do
    b = create(c)

    assert %{"allow" => false, "refusal" => %{"code" => "workspace-has-bots"}} =
             Control.command(c.human, :delete_workspace, [c.ws["id"]])

    assert %{"allow" => true} = Control.command(c.human, :remove_bot, [b["id"]])
    assert Loci.bot(b["id"]) == nil
    replacement = create(c)
    refute replacement["id"] == b["id"]
    refute replacement["actor"] == b["actor"]
  end

  test "lane assignment cannot widen a registered bot workspace", c do
    b = create(c)

    assert {:refused, %{"code" => "bot-workspace-mismatch"}} =
             Authority.open_lane(%{"actor" => b["actor"], "workspace_ref" => "ws_9999"})

    assert Loci.lanes() == %{}
  end

  test "a lane prevents removal of the actor identity", c do
    b = create(c)
    Authority.open_lane(%{"actor" => b["actor"], "workspace_ref" => c.ws["id"]})
    assert {:refused, %{"code" => "bot-in-use"}} = Authority.remove_bot(b["id"])
    assert Loci.bot(b["id"]) == b
  end

  test "active grants block identity removal until revoked", c do
    b = create(c)

    grant =
      Authority.mint(%{
        "capability" => "github.repo.read",
        "actor" => b["actor"],
        "resource" => "*",
        "duration" => "workspace"
      })

    assert {:refused, %{"code" => "bot-in-use"}} = Authority.remove_bot(b["id"])
    Authority.revoke_one(grant["id"])
    assert %{"bot_ref" => _} = Authority.remove_bot(b["id"])
  end

  test "the directory budget refuses oversized growth without damaging existing identities", c do
    for n <- 1..4 do
      assert %{"id" => _} =
               Authority.register_bot(%{
                 c.fields
                 | "client_ref" => "large-#{n}",
                   "instructions" => String.duplicate("x", 15000)
               })
    end

    before = Loci.bots()

    assert {:refused, %{"code" => "bot-directory-full"}} =
             Authority.register_bot(%{
               c.fields
               | "client_ref" => "too-large",
                 "instructions" => String.duplicate("x", 15000)
             })

    assert Loci.bots() == before
    assert BotIdentity.within_budget?(before)
  end
end
