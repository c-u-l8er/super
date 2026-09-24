defmodule Ampd.AuthorityLogTest do
  @moduledoc """
  The authority log (`Ampd.AuthorityLog`): what replay accepts, what it
  truncates, what it seals — and, through the real effect path, the four
  properties it was built for:

    1. an effect's claim and its consumption are ONE record;
    2. the syncs an effect costs are stated and counted;
    3. the bytes an effect writes do not grow with history;
    4. a torn last record is truncated and named, and the world stays open,
       while corruption with records after it still seals.
  """
  use ExUnit.Case, async: false
  alias Ampd.{AuthorityLog, Authority, Effects, Gateway, GrantRegistry, Receipts}
  alias Ampd.AuthorityLog.Delta

  @cap "github.pr.draft"
  @resource "traaviis/trvm"

  defp req,
    do: %{"er" => "er-github.pr.draft", "rev" => 1, "params" => Ampd.Core.params()["pr.draft"]}

  defp world! do
    Ampd.reset_demo()
    Authority.revoke_domain(@cap)
  end

  defp perform! do
    Authority.one_shot(@cap)
    r = Gateway.perform(@cap, @resource, Gateway.ctx(), req())
    assert r["allow"], inspect(Map.take(r, ["reason", "refusal"]))
    r
  end

  defp log_bin, do: File.read!(AuthorityLog.path())
  defp records, do: elem(AuthorityLog.records(log_bin()), 1)

  @registries [Ampd.GrantRegistry, Ampd.Approvals, Ampd.Receipts, Ampd.Effects]

  # Reboot the four registries onto whatever the file now says.
  defp reboot_registries! do
    AuthorityLog.close()
    Enum.each(@registries, fn mod -> Process.exit(Process.whereis(mod), :kill) end)

    Enum.each(@registries, fn mod ->
      Enum.reduce_while(1..200, nil, fn _, _ ->
        pid = Process.whereis(mod)

        up =
          pid != nil and
            try do
              mod.sealed()
              true
            catch
              :exit, _ -> false
            end

        if up, do: {:halt, :ok}, else: Process.sleep(20) && {:cont, nil}
      end)
    end)
  end

  # --------------------------------------------------------------- replay

  describe "replay: what a log file means" do
    defp log_of(records) do
      IO.iodata_to_binary([
        AuthorityLog.header()
        | Enum.with_index(records, 1)
          |> Enum.map(fn {r, t} -> AuthorityLog.frame(Map.put(r, "t", t)) end)
      ])
    end

    defp two,
      do: log_of([%{"ops" => [{:init, "s", %{"a" => 1}}]}, %{"ops" => [{:set, "s", "a", 2}]}])

    test "a whole log replays to its last state" do
      assert {:ok, images, 2, []} = AuthorityLog.replay(two())
      assert Delta.materialize(images["s"]) == %{"a" => 2}
    end

    test "a partial frame header at the end is a torn tail, at the last good offset" do
      bin = two()
      assert {:torn, images, 2, _, off, why} = AuthorityLog.replay(bin <> <<0, 0, 1>>)
      assert off == byte_size(bin) and why =~ "partial"
      assert Delta.materialize(images["s"]) == %{"a" => 2}
    end

    test "a frame shorter than it declares, at the end, is a torn tail" do
      bin = two()

      [f] = [
        AuthorityLog.frame(%{"t" => 3, "ops" => [{:set, "s", "a", 3}]}) |> IO.iodata_to_binary()
      ]

      assert {:torn, _, 2, _, off, _} =
               AuthorityLog.replay(bin <> binary_part(f, 0, byte_size(f) - 3))

      assert off == byte_size(bin)
    end

    test "a checksum mismatch on the LAST frame is a torn tail" do
      bin = two()
      <<head::binary-size(byte_size(bin) - 1), last>> = bin

      assert {:torn, images, 1, _, _, why} =
               AuthorityLog.replay(head <> <<Bitwise.bxor(last, 1)>>)

      assert why =~ "checksum"
      assert Delta.materialize(images["s"]) == %{"a" => 1}
    end

    test "a checksum mismatch with records after it is corruption, never a torn tail" do
      bin = two()
      at = byte_size(AuthorityLog.header()) + 8 + 2
      <<a::binary-size(at), b, rest::binary>> = bin
      assert {:damaged, why} = AuthorityLog.replay(a <> <<Bitwise.bxor(b, 1)>> <> rest)
      assert why =~ "not a torn tail"
    end

    test "a record sequence gap is corruption" do
      bin =
        IO.iodata_to_binary([
          AuthorityLog.header(),
          AuthorityLog.frame(%{"t" => 1, "ops" => [{:init, "s", %{}}]}),
          AuthorityLog.frame(%{"t" => 3, "ops" => []})
        ])

      assert {:damaged, why} = AuthorityLog.replay(bin)
      assert why =~ "gap"
    end

    test "a file that is not an authority log is corruption" do
      assert {:damaged, _} = AuthorityLog.replay("this is not the header\n")
    end
  end

  # ---------------------------------------------------------------- delta

  describe "delta: replaying the diffs reproduces every state" do
    # A registry-shaped state walked through appends, in-place updates, scalar
    # changes, removed fields, shrinks and insertions — every diff replayed onto
    # the image must materialize to exactly the state that produced it.
    test "2,000 random steps, three seeds" do
      for seed <- [1, 7, 42] do
        :rand.seed(:exsss, {seed, seed, seed})
        s0 = %{"items" => [], "seq" => 0, "fence" => %{"epoch" => "e1"}}
        images = Delta.apply_op({:init, "x", s0}, %{})

        Enum.reduce(1..2_000, {s0, images}, fn _, {s, images} ->
          s2 = step(s)
          ops = Delta.diff("x", s, s2)
          images = Enum.reduce(ops, images, &Delta.apply_op/2)

          assert Delta.materialize(images["x"]) == s2,
                 "seed #{seed}: replay diverged after #{inspect(ops)}"

          {s2, images}
        end)
      end
    end

    defp step(s) do
      items = s["items"]

      case :rand.uniform(7) do
        1 ->
          %{s | "items" => items ++ [%{"id" => "i#{s["seq"]}", "v" => 0}], "seq" => s["seq"] + 1}

        2 when items != [] ->
          %{
            s
            | "items" =>
                List.update_at(
                  items,
                  :rand.uniform(length(items)) - 1,
                  &Map.update!(&1, "v", fn v -> v + 1 end)
                )
          }

        3 ->
          Map.put(s, "fence", %{"epoch" => "e#{:rand.uniform(9)}"})

        4 when items != [] ->
          %{s | "items" => List.delete_at(items, :rand.uniform(length(items)) - 1)}

        5 ->
          %{
            s
            | "items" =>
                List.insert_at(items, :rand.uniform(length(items) + 1) - 1, %{
                  "id" => "n",
                  "v" => 9
                })
          }

        6 ->
          if Map.has_key?(s, "extra"),
            do: Map.delete(s, "extra"),
            else: Map.put(s, "extra", [1, 2])

        _ ->
          s
      end
    end

    test "an unchanged element costs nothing: only changed and appended elements are written" do
      prev = %{"items" => Enum.map(1..1_000, &%{"id" => &1})}

      cur = %{
        "items" => List.update_at(prev["items"], 500, &Map.put(&1, "x", 1)) ++ [%{"id" => :new}]
      }

      assert [{:list, "x", "items", 1_001, [{500, _}, {1_000, %{"id" => :new}}]}] =
               Delta.diff("x", prev, cur)
    end
  end

  # ------------------------------------------------------------ checkpoints

  describe "checkpoints" do
    setup do
      Application.put_env(:ampd, :authority_log_checkpoint_every, 10)
      on_exit(fn -> Application.delete_env(:ampd, :authority_log_checkpoint_every) end)
      world!()
      :ok
    end

    defp settled! do
      Enum.reduce_while(1..500, nil, fn _, _ ->
        if AuthorityLog.status()["checkpoint_running"] == nil,
          do: {:halt, :ok},
          else: Process.sleep(10) && {:cont, nil}
      end)
    end

    defp journal, do: Enum.map(Effects.all(), &Map.take(&1, ["id", "state", "grant_ref"]))

    test "the log is sealed at the cadence, the image written apart, the covered segments deleted, and a reboot comes back whole" do
      Enum.each(1..8, fn _ -> perform!() end)
      settled!()
      st = AuthorityLog.status()

      assert st["checkpoints"] >= 2, inspect(st)
      assert File.exists?(AuthorityLog.checkpoint_path())
      assert st["sealed_segments"] == 0, "a covered segment was left behind"
      {:ok, active} = AuthorityLog.records(log_bin())
      assert length(active) < 20, "the active log was not rotated: #{length(active)} records"

      before = journal()
      receipts = length(Receipts.all())
      reboot_registries!()

      assert Ampd.seals() == []
      assert journal() == before
      assert length(Receipts.all()) == receipts
      perform!()
    end

    test "a checkpoint that does not verify seals every store the log backs, and says why" do
      Enum.each(1..4, fn _ -> perform!() end)
      settled!()
      AuthorityLog.close()

      cp = File.read!(AuthorityLog.checkpoint_path())
      at = byte_size(cp) - 10
      <<a::binary-size(at), b, rest::binary>> = cp
      File.write!(AuthorityLog.checkpoint_path(), a <> <<Bitwise.bxor(b, 0xFF)>> <> rest)
      reboot_registries!()

      assert Map.new(Ampd.seals())[Ampd.Effects] =~ "checkpoint"
      Ampd.reset_demo()
    end

    test "a snapshot cut short is not a checkpoint, and is removed" do
      Enum.each(1..4, fn _ -> perform!() end)
      settled!()
      before = journal()
      AuthorityLog.close()
      File.write!(AuthorityLog.checkpoint_path() <> ".tmp", "half a snapshot")
      reboot_registries!()

      assert Ampd.seals() == []
      assert journal() == before
      refute File.exists?(AuthorityLog.checkpoint_path() <> ".tmp")
    end

    test "a segment sealed before its checkpoint became durable is replayed, not lost" do
      Enum.each(1..4, fn _ -> perform!() end)
      settled!()
      before = journal()
      t = AuthorityLog.status()["tseq"]
      AuthorityLog.close()

      # As if the process died right after sealing: the segment is there, its
      # checkpoint never landed, and the new active log holds only a header.
      File.rename!(AuthorityLog.path(), AuthorityLog.path() <> ".sealed-#{t}")
      File.write!(AuthorityLog.path(), AuthorityLog.header())
      reboot_registries!()

      assert Ampd.seals() == []
      assert journal() == before
      perform!()
    end
  end

  # --------------------------------------------------- through the effect path

  describe "through Gateway.perform" do
    test "claim and consume are ONE record, and the whole effect is four synced records" do
      world!()
      Authority.one_shot(@cap)
      before = AuthorityLog.status()
      n0 = length(records())

      r = Gateway.perform(@cap, @resource, Gateway.ctx(), req())
      assert r["allow"]
      e = Effects.get(r["effect_id"])
      assert e["state"] == "COMMITTED"

      new = Enum.drop(records(), n0)
      after_ = AuthorityLog.status()

      # 1 · the claim transaction: the effect's proposal, authorization and
      #     claim, AND the grant's consumption, together.
      [claim] =
        Enum.filter(new, fn rec ->
          Enum.any?(rec["ops"], &(elem(&1, 1) == "grant_registry")) and
            Enum.any?(rec["ops"], &(elem(&1, 1) == "effects"))
        end)

      assert inspect(claim["ops"]) =~ e["id"]
      assert inspect(claim["ops"]) =~ e["grant_ref"]
      assert after_["grouped_records"] == before["grouped_records"] + 1

      # 2 · stated, and counted: claim transaction · ATTEMPTED · COMMITTED · receipt.
      assert length(new) == 4,
             "records per effect: #{length(new)} — #{inspect(Enum.map(new, &Enum.map(&1["ops"], fn op -> elem(op, 1) end)))}"

      assert after_["syncs"] - before["syncs"] == 4
      assert after_["group_splits"] == before["group_splits"]
    end

    @tag timeout: 300_000
    test "the bytes an effect writes do not grow with history" do
      world!()

      bytes_of_one = fn ->
        b0 = AuthorityLog.status()["bytes"]
        perform!()
        AuthorityLog.status()["bytes"] - b0
      end

      early = Enum.map(1..5, fn _ -> bytes_of_one.() end) |> Enum.sum()
      Enum.each(1..300, fn _ -> perform!() end)
      late = Enum.map(1..5, fn _ -> bytes_of_one.() end) |> Enum.sum()

      # Whole-state saves made this grow ~160x between an empty journal and
      # 2,000 effects. A delta grows only with the one record it writes.
      assert late < early * 1.5, "bytes per effect grew from #{div(early, 5)} to #{div(late, 5)}"
      assert length(Effects.all()) == 310
    end

    test "a torn last record is truncated and NAMED, and the world stays open" do
      world!()
      r = perform!()
      size = byte_size(log_bin())

      AuthorityLog.close()
      # Half a frame: a write that was cut off, answered to nobody.
      File.write!(AuthorityLog.path(), <<0, 0, 4, 0, 1, 2, 3>>, [:append])
      reboot_registries!()

      assert Ampd.seals() == [], "an ordinary torn write sealed the world"
      assert Effects.get(r["effect_id"])["state"] == "COMMITTED"
      assert Enum.any?(Receipts.all(), &(&1["effect_ref"] == r["effect_id"]))

      [named] = AuthorityLog.status()["recovered"]
      assert named["torn_tail_bytes"] == 7 and named["at_offset"] == size

      # And the world keeps working after it.
      perform!()
    end

    test "corruption with records after it seals every store the log backs, by name" do
      world!()
      perform!()
      AuthorityLog.close()

      bin = log_bin()
      at = byte_size(AuthorityLog.header()) + 8 + 3
      <<a::binary-size(at), b, rest::binary>> = bin
      File.write!(AuthorityLog.path(), a <> <<Bitwise.bxor(b, 0xFF)>> <> rest)
      reboot_registries!()

      seals = Map.new(Ampd.seals())

      for mod <- @registries do
        assert seals[mod] =~ "RECOVERY-STATE-UNTRUSTED", "#{inspect(mod)}: #{inspect(seals[mod])}"
        assert seals[mod] =~ "authority log"
      end

      assert GrantRegistry.list() == [], "a sealed registry served authority"
      Ampd.reset_demo()
      assert Ampd.seals() == []
    end

    test "a delta for a store the log does not hold is refused, not built into a partial store" do
      world!()

      assert {:error, {:absent, "nosuch"}} =
               AuthorityLog.append("nosuch", [{:set, "nosuch", "k", 1}], nil)

      refute "nosuch" in AuthorityLog.present(Ampd.Store.data_dir())
    end

    test "a concurrent write touching what an open transaction holds forces the held record out first" do
      world!()
      :ok = AuthorityLog.append("probe", [{:init, "probe", %{"a" => 0}}], nil)
      splits = AuthorityLog.status()["group_splits"]

      AuthorityLog.group(fn ->
        assert :pending = AuthorityLog.append("probe", [{:set, "probe", "a", 1}], self())

        # Another process — not the transaction — writes the same field.
        t = Task.async(fn -> AuthorityLog.append("probe", [{:set, "probe", "a", 2}], nil) end)
        assert :ok = Task.await(t)
      end)

      assert AuthorityLog.status()["group_splits"] == splits + 1
      # On disk: the transaction's write, then the concurrent one — the order they happened in.
      probe = for rec <- records(), op <- rec["ops"], elem(op, 1) == "probe", do: op
      assert [{:init, _, _}, {:set, _, "a", 1}, {:set, _, "a", 2}] = probe
    end
  end
end
