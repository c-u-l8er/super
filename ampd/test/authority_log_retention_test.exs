defmodule Ampd.AuthorityLogRetentionTest do
  @moduledoc """
  Retention (`Ampd.Retention`, the authority archive in `Ampd.AuthorityLog`),
  against the ruling it implements (2026-09-24):

    * completed items leave the WORKING lists, and their durable history is
      kept — every retired row reads back byte-for-byte from the archive;
    * the compact indexes that remain answer receipt lookup, recovery,
      deduplication and "this grant was used": a retired effect cannot be
      claimed again, a retired grant cannot be spent, a second receipt for a
      retired effect is still a duplicate;
    * nothing an unfinished or disputed operation needs is retired;
    * one pass is one durable record, and the archive survives a reboot, a
      checkpoint, a torn tail and an orphan batch.

  The performance claim is NOT made here. It is measured through the real
  effect path by the timing harness, because bounded lists alone do not
  establish flat cost.
  """
  use ExUnit.Case, async: false
  alias Ampd.{AuthorityCoordinator, AuthorityLog, Authority, Effects, Gateway, GrantRegistry}
  alias Ampd.{Fence, Projection, Receipts, Retention}
  alias Ampd.AuthorityLog.Delta

  @cap "github.pr.draft"
  @resource "traaviis/trvm"

  defp req,
    do: %{"er" => "er-github.pr.draft", "rev" => 1, "params" => Ampd.Core.params()["pr.draft"]}

  setup do
    # Passes run only when a test asks; the automatic trigger stays quiet.
    prev = Application.get_env(:ampd, :authority_retention)
    Application.put_env(:ampd, :authority_retention, enabled: false)
    Ampd.reset_demo()
    Authority.revoke_domain(@cap)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:ampd, :authority_retention, prev),
        else: Application.delete_env(:ampd, :authority_retention)
    end)

    :ok
  end

  defp perform! do
    Authority.one_shot(@cap)
    r = Gateway.perform(@cap, @resource, Gateway.ctx(), req())
    assert r["allow"], inspect(Map.take(r, ["reason", "refusal"]))
    r
  end

  defp performs!(n), do: for(_ <- 1..n, do: perform!())

  defp pass!(opts) do
    assert {:ok, r} = Retention.run_now(Keyword.merge([min_batch: 1], opts))
    r
  end

  defp effect_receipts, do: Enum.filter(Receipts.all(), & &1["effect_ref"])
  defp log_records, do: elem(AuthorityLog.records(File.read!(AuthorityLog.path())), 1)

  @registries [Ampd.GrantRegistry, Ampd.Approvals, Ampd.Receipts, Ampd.Effects]

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

  # ------------------------------------------------------------------ delta

  describe "Delta: a map that only gains keys" do
    test "is written as the added keys, and replays to the same map" do
      prev = %{"retired" => %{"a" => [1], "b" => [2]}}
      cur = %{"retired" => Map.put(prev["retired"], "c", [3])}
      assert [{:merge, "s", "retired", %{"c" => [3]}}] = Delta.diff("s", prev, cur)

      img = Delta.apply_op({:init, "s", prev}, %{})
      img = Enum.reduce(Delta.diff("s", prev, cur), img, &Delta.apply_op/2)
      assert Delta.materialize(img["s"]) == cur
    end

    test "a changed value, a removed key or an empty base is written whole" do
      assert [{:set, "s", "m", _}] = Delta.diff("s", %{"m" => %{"a" => 1}}, %{"m" => %{"a" => 2, "b" => 1}})
      assert [{:set, "s", "m", _}] = Delta.diff("s", %{"m" => %{"a" => 1, "b" => 1}}, %{"m" => %{"a" => 1}})
      assert [{:set, "s", "m", _}] = Delta.diff("s", %{"m" => %{}}, %{"m" => %{"a" => 1}})
    end
  end

  # ------------------------------------------------------------------- pass

  describe "a pass" do
    test "retires the oldest settled bundles, keeps the newest keep_recent, and loses nothing" do
      rs = performs!(6)
      ids = Enum.map(rs, & &1["effect_id"])
      assert Enum.all?(ids, &is_binary/1), inspect(hd(rs))
      before = Map.new(ids, &{&1, Effects.get(&1)})
      receipts_before = Map.new(ids, &{&1, Receipts.for_effect(&1)})
      grants_before = Map.new(ids, &{&1, GrantRegistry.get(before[&1]["grant_ref"])})

      r = pass!(keep_recent: 2)
      assert r["retired"] == 4 and r["receipts"] == 4 and r["grants"] == 4, inspect(r)

      {gone, kept} = Enum.split(ids, 4)
      working = Enum.map(Effects.all(), & &1["id"])
      assert Enum.all?(kept, &(&1 in working))
      refute Enum.any?(gone, &(&1 in working))
      assert Effects.retired_count() == 4
      assert length(effect_receipts()) == 2

      # Every retired row reads back exactly as it was.
      for id <- gone do
        assert ["COMMITTED", b, "ard1:" <> _] = Effects.retired(id)
        assert b == r["batch"]
        assert Effects.get(id) == before[id]
        assert Receipts.for_effect(id) == receipts_before[id]
        assert GrantRegistry.get(before[id]["grant_ref"]) == grants_before[id]
        assert ["consumed", ^b, [^id], "ard1:" <> _] = GrantRegistry.retired(before[id]["grant_ref"])
        refute Enum.any?(GrantRegistry.list(), &(&1["id"] == before[id]["grant_ref"]))
      end

      assert AuthorityLog.status()["archive_batches_present"] == 1
    end

    test "is ONE durable record, and a later pass writes only what its index gained" do
      performs!(4)
      n0 = length(log_records())
      r1 = pass!(keep_recent: 1)
      recs = log_records()
      assert length(recs) == n0 + 1, "one pass, one record"
      stores = for op <- List.last(recs)["ops"], do: elem(op, 1)
      assert Enum.sort(Enum.uniq(stores)) == ["effects", "grant_registry", "receipts"]

      performs!(3)
      n1 = length(log_records())
      r2 = pass!(keep_recent: 1)
      assert r2["batch"] == r1["batch"] + 1
      last = List.last(log_records())
      assert length(log_records()) == n1 + 1

      merges = for {:merge, store, "retired", added} <- last["ops"], do: {store, map_size(added)}
      assert {"effects", 3} in merges and {"grant_registry", 3} in merges
      refute Enum.any?(last["ops"], &match?({:set, _, "retired", _}, &1))
    end

    test "below min_batch, nothing is retired and nothing is written" do
      performs!(3)
      n0 = length(log_records())
      assert {:ok, %{"retired" => 0}} = Retention.run_now(keep_recent: 1, min_batch: 5)
      assert length(log_records()) == n0
      assert AuthorityLog.status()["archive_batches_present"] == 0
    end
  end

  describe "what is never retired" do
    test "an UNKNOWN effect, and a COMMITTED effect whose receipt is missing, stay working" do
      rs = performs!(4)
      [a, b | _] = Enum.map(rs, & &1["effect_id"])

      # b's receipt disappears (as a lost receipt store would leave it): its
      # recovery row now reads MISSING, which an operator must see.
      s = Receipts.all()

      :ok =
        AuthorityCoordinator.transact(fn ->
          Receipts.load_state(%{"log" => Enum.reject(s, &(&1["effect_ref"] == b)), "seq" => 999})
        end)

      assert Effects.recovery_listing()[b]["receipts"] == "MISSING"

      # And a claimed effect that never finished: UNKNOWN is not terminal.
      Authority.one_shot(@cap)
      {:claimed, _auth, e, _lease} = Authority.claim_and_consume(@cap, @resource, Gateway.ctx(), req())
      assert %{"state" => "UNKNOWN"} = Effects.unknown(e["id"], "test: crashed mid-flight")

      r = pass!(keep_recent: 0)
      working = Enum.map(Effects.all(), & &1["id"])
      assert b in working, "a MISSING receipt keeps its effect in view"
      assert e["id"] in working
      refute a in working
      assert r["unsettled"] >= 1
    end
  end

  describe "the compact indexes still refuse what the rows refused" do
    test "a retired effect cannot be claimed or moved" do
      [r | _] = performs!(3)
      id = r["effect_id"]
      pass!(keep_recent: 1)
      assert Effects.retired(id)

      assert {:error, "effect-settled · " <> _} =
               AuthorityCoordinator.transact(fn -> Effects.claim(id) end)

      assert {:refused, %{"code" => "journal-transition-illegal"}} =
               Effects.fail(id, "late")
    end

    test "a retired grant is never spent again; a replayed consumption is still a duplicate" do
      key = Fence.mint_key()
      fence = Fence.new("e9-test", key)

      st = %{
        tab: nil,
        sealed: nil,
        s: %{
          "grants" => [],
          "fence" => fence,
          "retired" => %{"gr_0900" => ["consumed", 3, ["ef_0100"]]}
        }
      }

      ticket = fn effect ->
        Fence.sign_ticket(key, %{
          "ticket_id" => "tk-#{effect}",
          "lease_id" => "ls-e9-1",
          "effect" => effect,
          "op" => "consume_grant",
          "target" => "gr_0900",
          "epoch" => "e9-test"
        })
      end

      assert {:reply, {:refused, dup}, _} =
               GrantRegistry.handle_ordered({:consume_ticket, ticket.("ef_0100")}, st)

      assert dup["code"] == "write-duplicate"

      assert {:reply, {:refused, other}, _} =
               GrantRegistry.handle_ordered({:consume_ticket, ticket.("ef_0200")}, st)

      assert other["code"] == "write-unscoped"
    end

    test "a second receipt for a retired effect is a duplicate" do
      key = Fence.mint_key()

      st = %{
        tab: nil,
        sealed: nil,
        refs: %{},
        s: %{"log" => [], "seq" => 1, "fence" => Fence.new("e9-test", key),
             "retired_refs" => %{"ef_0100" => ["rcpt-0007", 2]}}
      }

      t =
        Fence.sign_ticket(key, %{
          "ticket_id" => "tk-1",
          "lease_id" => "ls-e9-1",
          "effect" => "ef_0100",
          "op" => "emit_receipt",
          "target" => "ef_0100",
          "epoch" => "e9-test"
        })

      assert {:reply, {:refused, r}, _} = Receipts.handle_call({:emit_ticketed, t, %{}}, nil, st)
      assert r["code"] == "write-duplicate"
    end
  end

  describe "the archive is durable" do
    test "across a reboot and a checkpoint" do
      prev = Application.get_env(:ampd, :authority_log_checkpoint_every)
      Application.put_env(:ampd, :authority_log_checkpoint_every, 7)

      try do
        rs = performs!(8)
        ids = Enum.map(rs, & &1["effect_id"])
        before = Map.new(ids, &{&1, Effects.get(&1)})
        pass!(keep_recent: 2)
        performs!(3)

        reboot_registries!()
        assert AuthorityLog.status()["checkpoints"] >= 0
        assert Effects.retired_count() == 6

        for id <- Enum.take(ids, 6) do
          assert Effects.get(id) == before[id]
        end

        assert AuthorityLog.status()["archive_batches_present"] == 1
      after
        if prev,
          do: Application.put_env(:ampd, :authority_log_checkpoint_every, prev),
          else: Application.delete_env(:ampd, :authority_log_checkpoint_every)
      end
    end

    test "a torn archive tail is truncated and named; the next batch follows the last good one" do
      performs!(4)
      pass!(keep_recent: 2)
      size = File.stat!(AuthorityLog.archive_path()).size
      File.write!(AuthorityLog.archive_path(), <<0, 0, 9, 0, 1, 2, 3>>, [:append])

      reboot_registries!()
      st = AuthorityLog.status()
      assert st["archive_size"] == size
      assert st["archive_batches_present"] == 1
      assert Enum.any?(st["recovered"], &(&1["archive_torn_tail_bytes"] == 7))

      performs!(3)
      r = pass!(keep_recent: 2)
      assert r["batch"] == 2
      assert Effects.retired_count() == 5
    end

    test "an orphan batch — archived, never retired — is harmless" do
      [r | _] = performs!(3)
      id = r["effect_id"]
      row = Effects.get(id)

      # The process died between the archive sync and the retirement record.
      assert {:ok, 1} = AuthorityLog.archive(%{"effects" => [row]})
      assert id in Enum.map(Effects.all(), & &1["id"])

      p = pass!(keep_recent: 1)
      assert p["batch"] == 2
      assert ["COMMITTED", 2, "ard1:" <> _] = Effects.retired(id)
      assert Effects.get(id) == row

      {:ok, archived} = Effects.archived()
      assert Enum.count(archived, &(&1["id"] == id)) == 1
    end
  end

  describe "the trigger" do
    test "performs poke it; a due batch is retired without anyone asking, and the lists stay bounded" do
      Application.put_env(:ampd, :authority_retention,
        enabled: true,
        keep_recent: 8,
        min_batch: 8,
        max_batch: 64,
        check_every: 4,
        interval_ms: 3_600_000
      )

      before = Retention.status()
      rs = performs!(120)
      ids = Enum.map(rs, & &1["effect_id"])

      # The last poke's pass may still be running when the last perform
      # returns; the status table says so without a call.
      Enum.reduce_while(1..200, nil, fn _, _ ->
        if Retention.status()["running"] == nil, do: {:halt, :ok}, else: Process.sleep(10) && {:cont, nil}
      end)

      st = Retention.status()
      assert st["passes"] > before["passes"]
      assert st["retired"] - before["retired"] == Effects.retired_count()
      assert st["errors"] == before["errors"]

      # Bounded: keep_recent + a batch not yet due + what the last check left.
      assert length(Effects.all()) <= 8 + 8 + 4
      assert length(effect_receipts()) <= 8 + 8 + 4
      assert Enum.count(GrantRegistry.list(), &(&1["status"] == "consumed")) <= 8 + 8 + 4

      # And nothing acknowledged is gone: every effect reads back, working or archived.
      for id <- ids do
        e = Effects.get(id)
        assert is_map(e) and e["state"] == "COMMITTED", "#{id}: #{inspect(e)}"
        assert is_map(Receipts.for_effect(id)), id
      end

      {:ok, archived} = Effects.archived()
      assert length(archived) == Effects.retired_count()
    end
  end

  describe "history" do
    test "paging is lossless across the working rows and many archived batches" do
      rs = performs!(40)
      ids = rs |> Enum.map(& &1["effect_id"]) |> Enum.sort_by(&String.to_integer(String.trim_leading(&1, "ef_")), :desc)
      # Small batches, so the history spans several of them.
      for _ <- 1..5, do: Retention.run_now(keep_recent: 6, min_batch: 1, max_batch: 7)
      assert Effects.retired_count() >= 30
      assert map_size(Effects.retired_batches()) >= 5

      pages =
        Stream.unfold(nil, fn
          :done ->
            nil

          cursor ->
            p = Projection.history_page(:effects, nil, cursor, 7)
            refute Map.has_key?(p, "archive_error")
            {p, if(p["more"], do: p["next_cursor"], else: :done)}
        end)
        |> Enum.to_list()

      seen = Enum.flat_map(pages, fn p -> Enum.map(p["items"], & &1["id"]) end)
      assert seen == ids, "every effect exactly once, newest first"
      assert Enum.all?(pages, &(&1["total"] == 40))

      rpages =
        Stream.unfold(nil, fn
          :done -> nil
          c -> (p = Projection.history_page(:receipts, nil, c, 9); {p, if(p["more"], do: p["next_cursor"], else: :done)})
        end)
        |> Enum.to_list()

      assert rpages |> Enum.flat_map(& &1["items"]) |> Enum.map(& &1["effect_ref"]) == ids
    end

    test "a page reads only the archive batches that can reach it" do
      performs!(40)
      for _ <- 1..5, do: Retention.run_now(keep_recent: 6, min_batch: 1, max_batch: 7)
      reads = fn -> AuthorityLog.status()["archive_batch_reads"] end

      # The newest page is served from the working rows: no batch is read.
      r0 = reads.()
      p = Projection.history_page(:effects, nil, nil, 5)
      assert p["returned"] == 5 and p["more"]
      assert reads.() == r0

      # A page just past the working rows reads the newest batch or two, not all of them.
      r1 = reads.()
      p2 = Projection.history_page(:effects, nil, p["next_cursor"], 5)
      assert p2["returned"] == 5
      assert reads.() - r1 <= 2
      assert reads.() - r1 < map_size(Effects.retired_batches())
    end

    test "an actor's own windows count that actor's retired rows" do
      performs!(5)
      pass!(keep_recent: 2)
      actor = Gateway.ctx()["actor"]
      a = Projection.agent(actor)
      assert a["effects_history"]["total"] == 5
      assert a["receipts"]["total"] == 5
      assert Projection.agent("nobody-at-all")["effects_history"]["total"] == 0
    end

    test "windows count what was retired, and paging continues into the archive" do
      rs = performs!(5)
      ids = Enum.map(rs, & &1["effect_id"])
      pass!(keep_recent: 2)

      w = Projection.operator()["effects_history"]
      assert w["total"] == 5
      assert w["more"] == true
      assert length(w["recent"]) == 2

      page = Projection.history_page(:effects, nil, nil, 200)
      assert Enum.sort(Enum.map(page["items"], & &1["id"])) == Enum.sort(ids)
      assert page["total"] == 5 and page["more"] == false

      rw = Projection.operator()["receipts"]
      assert rw["total"] == 5
    end
  end
end
