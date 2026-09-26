defmodule Ampd.ArchiveDigestTest do
  @moduledoc """
  The archive-integrity change (ProjectAmp2 `superlane/archive-row-check/
  ANALYSIS.md`, form B), against the outcome declared for it: **Super detects
  archived content that differs from what the authority log committed at
  retirement.**

    * the digest encoding is defined, versioned and total, and pinned here;
    * each store commits the digest of its WORKING row in the retirement
      record, and refuses a retirement whose working row is not the row that
      was archived;
    * valid archived rows read back verified on every read path, before and
      after a restart;
    * the benchmarking lane's two valid-CRC tamper controls — a receipt body
      and a grant's consumption altered with their ids kept, each re-framed
      with a valid CRC — are refused by Super's own reads, running and after
      a restart;
    * an orphan batch is never read, wherever it sits in the file;
    * rows retired before digests read as unverified, by name, and stay so;
    * a page that meets a batch that does not check stops, says why, keeps
      only rows it is sure of and offers no cursor; nothing seals.
  """
  use ExUnit.Case, async: false
  alias Ampd.{AuthorityCoordinator, AuthorityLog, Authority, Effects, Gateway, GrantRegistry}
  alias Ampd.{Projection, Receipts, Retention}
  alias Ampd.AuthorityLog.RowDigest

  @cap "github.pr.draft"
  @resource "traaviis/trvm"
  @ar_header "AMPD-AUTHORITY-ARCHIVE/1\n"
  @unverified "archive_unverified"

  defp req,
    do: %{"er" => "er-github.pr.draft", "rev" => 1, "params" => Ampd.Core.params()["pr.draft"]}

  setup do
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
    r["effect_id"]
  end

  defp performs!(n), do: for(_ <- 1..n, do: perform!())

  defp pass!(opts) do
    assert {:ok, r} = Retention.run_now(Keyword.merge([min_batch: 1], opts))
    r
  end

  @registries [Ampd.GrantRegistry, Ampd.Approvals, Ampd.Receipts, Ampd.Effects]

  # A restart of everything that holds authority state: the log forgets its
  # image and its archive offsets, the four registries reload from disk.
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

  defp no_seals!,
    do: assert(Enum.all?(Ampd.seals(), fn {_, s} -> s == nil end), inspect(Ampd.seals()))

  # Every id's effect, receipt and grant, as the working lists hold them now.
  defp snapshot(ids) do
    Map.new(ids, fn id ->
      e = Effects.get(id)

      {id,
       %{effect: e, receipt: Receipts.for_effect(id), grant: GrantRegistry.get(e["grant_ref"])}}
    end)
  end

  # ------------------------------------------------------------ the archive file
  #
  # The benchmarking lane's `wek/b2/trvm/tools/archive_tamper.exs`, in place:
  # decode every frame, alter rows, re-frame each with a VALID crc32.

  defp frames! do
    <<@ar_header, rest::binary>> = File.read!(AuthorityLog.archive_path())
    parse(rest, [])
  end

  defp parse(<<>>, acc), do: Enum.reverse(acc)

  defp parse(<<len::32, crc::32, p::binary-size(len), more::binary>>, acc) do
    assert :erlang.crc32(p) == crc
    parse(more, [:erlang.binary_to_term(p) | acc])
  end

  defp write_frames!(recs) do
    File.write!(
      AuthorityLog.archive_path(),
      IO.iodata_to_binary([@ar_header | Enum.map(recs, &AuthorityLog.frame/1)])
    )
  end

  # Alter every row of `store` for which `pred` holds, in every batch. With
  # `same_length: true` each frame must keep its length, so a RUNNING runtime's
  # offsets still point at it — the tamper lands under a live process.
  defp tamper!(store, pred, fun, opts \\ []) do
    before = frames!()
    size = File.stat!(AuthorityLog.archive_path()).size

    {recs, hits} =
      Enum.map_reduce(before, 0, fn %{"rows" => rows} = rec, hits ->
        {new, h} =
          Enum.map_reduce(Map.get(rows, store, []), 0, fn r, n ->
            if pred.(r), do: {fun.(r), n + 1}, else: {r, n}
          end)

        rows = if Map.has_key?(rows, store), do: Map.put(rows, store, new), else: rows
        {%{rec | "rows" => rows}, hits + h}
      end)

    assert hits > 0, "nothing in the archive matched"
    write_frames!(recs)

    if opts[:same_length] do
      assert File.stat!(AuthorityLog.archive_path()).size == size

      for {a, b} <- Enum.zip(before, recs),
          do:
            assert(
              IO.iodata_length(AuthorityLog.frame(a)) == IO.iodata_length(AuthorityLog.frame(b))
            )
    end

    hits
  end

  # One hex character of a "sha256:<hex>" field, changed: same length.
  defp flip_hex(<<"sha256:", c, rest::binary>>),
    do: <<"sha256:", if(c == ?0, do: ?1, else: ?0), rest::binary>>

  # An id's last digit, changed: same length.
  defp flip_last(id) do
    {head, <<d>>} = String.split_at(id, -1)
    head <> <<if(d == ?9, do: ?8, else: d + 1)>>
  end

  defp page_all(kind, limit) do
    Stream.unfold(nil, fn
      :done ->
        nil

      c ->
        p = Projection.history_page(kind, nil, c, limit)
        {p, if(p["more"], do: p["next_cursor"], else: :done)}
    end)
    |> Enum.to_list()
  end

  defp key(id), do: id |> String.replace(~r/^\D+/, "") |> String.to_integer()

  # ------------------------------------------------------------ the encoding

  describe "archive-row-digest@1" do
    test "is pinned: a fixed row has a fixed digest, stored as 48 printable bytes" do
      row = %{
        "id" => "ef_0001",
        "state" => "COMMITTED",
        "n" => 7,
        "neg" => -12,
        "ratio" => 0.5,
        "flag" => true,
        "none" => nil,
        "history" => [%{"at" => "2026-09-25T00:00:00Z", "state" => "PROPOSED"}],
        "nested" => %{"b" => [1, "two"], "a" => %{}}
      }

      d = RowDigest.of("effects", "id", "ef_0001", 3, row)
      # Recomputed from the table in the moduledoc alone by an independent
      # encoder (Python, ProjectAmp2 `superlane/archive-digest-1/ard1.py`).
      assert d == "ard1:iID0aHQKGZZEMzYXXxagrmHrFtOWg1f77CFczKvPtOo"
      assert byte_size(d) == 48 and String.starts_with?(d, RowDigest.version() <> ":")
    end

    test "names the store, the key field, the key, the batch and every value" do
      row = %{"id" => "ef_0001", "a" => %{"b" => [1, 2]}}
      d = RowDigest.of("effects", "id", "ef_0001", 3, row)

      for other <- [
            RowDigest.of("receipts", "id", "ef_0001", 3, row),
            RowDigest.of("effects", "effect_ref", "ef_0001", 3, row),
            RowDigest.of("effects", "id", "ef_0002", 3, row),
            RowDigest.of("effects", "id", "ef_0001", 4, row),
            RowDigest.of("effects", "id", "ef_0001", 3, %{row | "a" => %{"b" => [1, 3]}}),
            RowDigest.of("effects", "id", "ef_0001", 3, Map.put(row, "c", nil))
          ],
          do: refute(other == d)
    end

    test "keeps apart what JSON would merge" do
      pairs = [{:a, "a"}, {1, 1.0}, {[1], {1}}, {nil, "nil"}, {"1", 1}, {0.0, -0.0}, {[], %{}}]

      for {x, y} <- pairs,
          do:
            refute(
              RowDigest.of("s", "id", "k", 1, x) == RowDigest.of("s", "id", "k", 1, y),
              inspect({x, y})
            )
    end

    test "orders a map's pairs by the key's canonical bytes, whatever the runtime's map order" do
      # 40 keys: past 32 a map is a hash trie, and iterates in hash order.
      m = Map.new(1..40, &{"k#{&1}", &1})

      expected =
        IO.iodata_to_binary([
          <<?m, 40::32>>
          | m
            |> Enum.map(fn {k, v} -> {IO.iodata_to_binary(RowDigest.enc(k)), v} end)
            |> Enum.sort()
            |> Enum.map(fn {k, v} -> [k | RowDigest.enc(v)] end)
        ])

      assert IO.iodata_to_binary(RowDigest.enc(m)) == expected
      assert IO.iodata_to_binary(RowDigest.enc("k1")) == <<?b, 2::32, "k1">>
      assert IO.iodata_to_binary(RowDigest.enc(-12)) == <<?i, 3::32, "-12">>
      assert IO.iodata_to_binary(RowDigest.enc(nil)) == <<?a, 3::32, "nil">>
      assert IO.iodata_to_binary(RowDigest.enc([1])) == <<?l, 1::32, ?i, 1::32, "1">>
      assert IO.iodata_to_binary(RowDigest.enc(0.5)) == <<?f, 0.5::float-size(64)-big>>
    end

    test "is total: nothing a row could hold makes it raise" do
      for t <- [
            self(),
            make_ref(),
            fn -> :ok end,
            [1 | 2],
            [1, 2 | :t],
            <<1::3>>,
            {:a, [b: 1]},
            %{{1, 2} => [3]}
          ],
          do: assert("ard1:" <> _ = RowDigest.of("s", "id", "k", 1, %{"v" => t}))
    end

    test "a row with no digest is unverified; an unknown version is unverified; neither is verified" do
      assert {:unverified,
              "archive-row-unverified · effects ef_1 in batch 2 was retired without a content digest"} =
               RowDigest.check("effects", "id", "ef_1", 2, %{}, nil)

      assert {:unverified, why} = RowDigest.check("effects", "id", "ef_1", 2, %{}, "ard9:xyz")
      assert why =~ "cannot check (ard9)"
    end
  end

  # ------------------------------------------------------------ retirement

  describe "a retirement" do
    test "commits, in the record that removes each row, the digest of the WORKING row" do
      ids = performs!(6)
      before = snapshot(ids)
      r = pass!(keep_recent: 2)
      b = r["batch"]
      gone = Enum.take(ids, 4)

      for id <- gone do
        %{effect: e, receipt: rc, grant: g} = before[id]
        assert ["COMMITTED", ^b, d] = Effects.retired(id)
        assert d == RowDigest.of("effects", "id", id, b, e)
        assert [_rid, ^b, dr] = Receipts.retired_ref(id)
        assert dr == RowDigest.of("receipts", "effect_ref", id, b, rc)
        assert ["consumed", ^b, [^id], dg] = GrantRegistry.retired(g["id"])
        assert dg == RowDigest.of("grant_registry", "id", g["id"], b, g)
      end

      # One record: the digests arrive in the same `ops` as the removal.
      {:ok, recs} = AuthorityLog.records(File.read!(AuthorityLog.path()))
      ops = List.last(recs)["ops"]

      # The first retirement a store makes writes its index whole (`:set`); later
      # ones write what it gained (`:merge`).
      for store <- ~w(effects receipts grant_registry) do
        [added] =
          for {op, ^store, idx, a} <- ops,
              op in [:set, :merge],
              idx in ~w(retired retired_refs),
              do: a

        assert map_size(added) == 4, store
        assert Enum.all?(Map.values(added), &match?("ard1:" <> _, List.last(&1))), store
      end

      assert Enum.any?(ops, &(elem(&1, 1) == "effects" and elem(&1, 2) == "effects")),
             "the working list changes in the same record"
    end

    test "an approval's entry commits its digest too" do
      Ampd.Authority.set_draft("pr.create", true)
      Ampd.Authority.commit(Ampd.CapabilityRegistry.get("github")["surface"])
      Ampd.Conformance.exercise("pr.create")
      Ampd.Conformance.approve_last()
      [a] = Enum.filter(Ampd.Approvals.all(), &(&1["status"] == "consumed"))
      r = pass!(keep_recent: 0)
      assert r["approvals"] == 1, inspect(r)
      b = r["batch"]
      assert ["consumed", ^b, _by, d] = Ampd.Approvals.retired(a["id"])
      assert d == RowDigest.of("approvals", "id", a["id"], b, a)
    end

    test "is refused, by name, when a working row is not the row archived; the batch stays an orphan" do
      [id | _] = ids = performs!(3)
      %{effect: e, receipt: rc, grant: g} = snapshot(ids)[id]

      for {store, row, retire, still} <- [
            {"effects", e, &Effects.retire/2,
             fn -> Effects.retired(id) == nil and Enum.any?(Effects.all(), &(&1["id"] == id)) end},
            {"receipts", rc, &Receipts.retire/2, fn -> Receipts.retired_ref(id) == nil end},
            {"grant_registry", g, &GrantRegistry.retire/2,
             fn -> GrantRegistry.retired(g["id"]) == nil end}
          ] do
        changed = Map.put(row, "changed_after_archiving", true)
        assert {:ok, n} = AuthorityLog.archive(%{store => [changed]})

        assert {:refused, %{"code" => "retire-row-changed"}} =
                 AuthorityCoordinator.transact(fn -> retire.([changed], n) end),
               store

        assert still.(), store
      end

      # The orphans are never read, and the next pass retires the rows for real.
      p = pass!(keep_recent: 1)
      assert p["batch"] == 4

      assert Effects.get(id) == e and Receipts.for_effect(id) == rc and
               GrantRegistry.get(g["id"]) == g
    end
  end

  # ------------------------------------------------------------ valid rows

  describe "valid archived rows" do
    test "read back verified on every read path, before and after a restart" do
      ids = performs!(14)
      before = snapshot(ids)
      for _ <- 1..3, do: pass!(keep_recent: 2, max_batch: 4)
      retired = Enum.filter(ids, &Effects.retired/1)
      assert length(retired) == 12 and map_size(Effects.retired_batches()) == 3

      check = fn ->
        for id <- ids do
          assert Effects.get(id) == before[id].effect
          assert Receipts.for_effect(id) == before[id].receipt
          assert GrantRegistry.get(before[id].grant["id"]) == before[id].grant
        end

        want = fn f -> retired |> Enum.map(&f.(before[&1])) |> Enum.sort_by(& &1["id"]) end
        assert {:ok, es} = Effects.archived()
        assert Enum.sort_by(es, & &1["id"]) == want.(& &1.effect)
        assert {:ok, rs} = Receipts.archived()
        assert Enum.sort_by(rs, & &1["id"]) == want.(& &1.receipt)
        assert {:ok, gs} = GrantRegistry.archived()
        assert Enum.sort_by(gs, & &1["id"]) == want.(& &1.grant)
        assert {:ok, ^rs} = Receipts.archived_of_kind(Receipts.default_kind())

        for kind <- [:effects, :receipts] do
          pages = page_all(kind, 5)

          refute Enum.any?(
                   pages,
                   &(Map.has_key?(&1, "archive_error") or Map.has_key?(&1, @unverified))
                 )

          items = Enum.flat_map(pages, & &1["items"])
          assert length(items) == 14
          refute Enum.any?(items, &Map.has_key?(&1, @unverified))

          expect =
            ids
            |> Enum.sort_by(&key/1, :desc)
            |> Enum.map(&if(kind == :effects, do: before[&1].effect, else: before[&1].receipt))

          assert items == expect
        end
      end

      check.()
      reboot_registries!()
      no_seals!()
      check.()
    end
  end

  # ------------------------------------------------------------ tampering

  describe "the valid-CRC tamper controls" do
    test "running: a receipt body and a grant's consumption altered in place are refused by Super's own reads" do
      ids = performs!(10)
      before = snapshot(ids)
      %{"batch" => b} = pass!(keep_recent: 2)
      [a | _] = ids
      g = before[Enum.at(ids, 5)].grant

      tamper!(
        "receipts",
        &(&1["effect_ref"] == a),
        &Map.update!(&1, "authority_snapshot_after", fn s -> flip_hex(s) end),
        same_length: true
      )

      tamper!(
        "grant_registry",
        &(&1["id"] == g["id"]),
        &Map.update!(&1, "consumptions", fn [c] -> [flip_last(c)] end),
        same_length: true
      )

      assert_refused_exactly(ids, before, a, g, b)
    end

    test "after a restart: the benchmarking lane's own alterations (the grant reads unspent) are refused" do
      ids = performs!(10)
      before = snapshot(ids)
      %{"batch" => b} = pass!(keep_recent: 2)
      [a | _] = ids
      g = before[Enum.at(ids, 5)].grant

      tamper!(
        "receipts",
        &(&1["effect_ref"] == a),
        &Map.update!(&1, "authority_snapshot_after", fn s -> flip_hex(s) end)
      )

      tamper!("grant_registry", &(&1["id"] == g["id"]), fn r ->
        %{r | "status" => "active", "uses_remaining" => 1, "consumptions" => []}
      end)

      reboot_registries!()
      # It boots exactly as the measured copy did: nothing in the file is damaged.
      assert AuthorityLog.status()["archive_damaged"] == nil
      assert_refused_exactly(ids, before, a, g, b)

      # The archive says the grant is unspent; the index, which decides, does not.
      assert ["consumed", ^b | _] = GrantRegistry.retired(g["id"])
      refute Enum.any?(GrantRegistry.active(), &(&1["id"] == g["id"]))
    end
  end

  defp assert_refused_exactly(ids, before, a, g, b) do
    assert Receipts.for_effect(a) ==
             {:error,
              "archive-row-mismatch · receipts #{a} in batch #{b} does not match its retirement digest"}

    assert GrantRegistry.get(g["id"]) ==
             {:error,
              "archive-row-mismatch · grant_registry #{g["id"]} in batch #{b} does not match its retirement digest"}

    # Exactly those two: every other row, working or retired, reads back as it was.
    for id <- ids do
      assert Effects.get(id) == before[id].effect
      if id != a, do: assert(Receipts.for_effect(id) == before[id].receipt)

      if before[id].grant["id"] != g["id"],
        do: assert(GrantRegistry.get(before[id].grant["id"]) == before[id].grant)
    end

    assert {:ok, _} = Effects.archived()
    assert {:error, "archive-row-mismatch · receipts " <> _} = Receipts.archived()
    assert {:error, "archive-row-mismatch · grant_registry " <> _} = GrantRegistry.archived()

    # The receipts page stops at the batch and says why; the effects pages are whole.
    p = Projection.history_page(:receipts, nil, nil, 200)
    assert p["archive_error"] =~ "archive-row-mismatch · receipts #{a} in batch #{b}"
    assert p["incomplete"] == true and p["more"] == false and p["next_cursor"] == nil
    assert Enum.map(p["items"], & &1["effect_ref"]) == ids |> Enum.take(-2) |> Enum.reverse()

    refute Map.has_key?(Projection.history_page(:effects, nil, nil, 200), "archive_error")

    # Nothing sealed, and the effect path goes on.
    no_seals!()
    assert is_binary(perform!())
  end

  # ------------------------------------------------------------ orphans

  describe "an orphan batch" do
    test "holding a different row, BEFORE the batch that retired it, is never read" do
      [id | _] = ids = performs!(3)
      row = snapshot(ids)[id].effect

      # Archived and synced, then the process died before the retirement record.
      assert {:ok, 1} = AuthorityLog.archive(%{"effects" => [Map.put(row, "state", "FAILED")]})
      assert %{"batch" => 2} = pass!(keep_recent: 1)
      assert ["COMMITTED", 2, _] = Effects.retired(id)

      for _ <- 1..2 do
        assert Effects.get(id) == row
        assert {:ok, es} = Effects.archived()
        assert Enum.filter(es, &(&1["id"] == id)) == [row]
        items = Enum.flat_map(page_all(:effects, 2), & &1["items"])
        assert Enum.filter(items, &(&1["id"] == id)) == [row]
        reboot_registries!()
      end
    end

    test "appended AFTER the batch that retired its rows, with a valid CRC, is never read" do
      ids = performs!(4)
      before = snapshot(ids)
      %{"batch" => 1} = pass!(keep_recent: 1)
      gone = Enum.take(ids, 3)

      forged = fn f -> Enum.map(gone, &Map.put(f.(before[&1]), "forged", true)) end

      # The reader this replaces took "the latest batch that holds" an id.
      assert {:ok, 2} =
               AuthorityLog.archive(%{
                 "effects" => forged.(& &1.effect),
                 "receipts" => forged.(& &1.receipt),
                 "grant_registry" => forged.(& &1.grant)
               })

      for _ <- 1..2 do
        for id <- gone do
          assert Effects.get(id) == before[id].effect
          assert Receipts.for_effect(id) == before[id].receipt
          assert GrantRegistry.get(before[id].grant["id"]) == before[id].grant
        end

        for {:ok, rows} <- [Effects.archived(), Receipts.archived(), GrantRegistry.archived()],
            do: refute(Enum.any?(rows, & &1["forged"]))

        for kind <- [:effects, :receipts],
            do: refute(Enum.any?(Enum.flat_map(page_all(kind, 2), & &1["items"]), & &1["forged"]))

        reboot_registries!()
      end
    end
  end

  # ------------------------------------------------------------ before digests

  # What the installed build (`9fc4f87`) writes: the same entries, no digest.
  defp strip_digests! do
    legacy = fn idx ->
      Map.new(idx, fn {k, v} -> {k, Enum.reject(v, &match?("ard1:" <> _, &1))} end)
    end

    :ok =
      AuthorityLog.append(
        "effects",
        [{:set, "effects", "retired", legacy.(Effects.retired_index())}],
        nil
      )

    :ok =
      AuthorityLog.append(
        "receipts",
        [{:set, "receipts", "retired_refs", legacy.(Receipts.retired_refs())}],
        nil
      )

    :ok =
      AuthorityLog.append(
        "grant_registry",
        [{:set, "grant_registry", "retired", legacy.(GrantRegistry.retired_index())}],
        nil
      )

    reboot_registries!()
  end

  describe "rows retired before digests" do
    test "read as unverified, by name, on every read path, and are never upgraded" do
      ids = performs!(6)
      before = snapshot(ids)
      %{"batch" => b} = pass!(keep_recent: 2)
      old = Enum.take(ids, 4)
      strip_digests!()
      assert ["COMMITTED", ^b] = Effects.retired(hd(old))

      check_old = fn ->
        for id <- old do
          e = Effects.get(id)

          assert e[@unverified] ==
                   "archive-row-unverified · effects #{id} in batch #{b} was retired without a content digest"

          assert Map.delete(e, @unverified) == before[id].effect
          assert Receipts.for_effect(id)[@unverified] =~ "archive-row-unverified · receipts #{id}"

          assert GrantRegistry.get(before[id].grant["id"])[@unverified] =~
                   "archive-row-unverified · grant_registry"
        end

        assert {:ok, es} = Effects.archived()
        old_rows = Enum.filter(es, &(&1["id"] in old))
        assert length(old_rows) == 4 and Enum.all?(old_rows, &Map.has_key?(&1, @unverified))

        [p] = page_all(:effects, 200)
        refute Map.has_key?(p, "archive_error")
        assert p["archive_unverified"] == 4

        assert p["items"]
               |> Enum.filter(&Map.has_key?(&1, @unverified))
               |> Enum.map(& &1["id"])
               |> Enum.sort() == old
      end

      check_old.()

      # New retirements carry digests; the old entries are not given one.
      new = performs!(4)
      %{"batch" => b2} = pass!(keep_recent: 2)
      assert b2 == b + 1

      for id <- Enum.take(ids -- old, 2) ++ Enum.take(new, 2) do
        assert [_, ^b2, "ard1:" <> _] = Effects.retired(id)
        refute Map.has_key?(Effects.get(id), @unverified)
      end

      for id <- old, do: assert(["COMMITTED", ^b] = Effects.retired(id))
      check_old.()
      reboot_registries!()
      check_old.()
    end

    test "a tampered one is served as unverified — never as verified — which is all an entry without a digest allows" do
      [id | _] = ids = performs!(3)
      _ = snapshot(ids)
      pass!(keep_recent: 1)
      strip_digests!()

      tamper!(
        "receipts",
        &(&1["effect_ref"] == id),
        &Map.update!(&1, "authority_snapshot_after", fn s -> flip_hex(s) end)
      )

      reboot_registries!()
      assert Receipts.for_effect(id)[@unverified] =~ "without a content digest"
    end

    test "a digest of a version this build does not know is unverified, and named" do
      [id | _] = performs!(3)
      pass!(keep_recent: 1)
      [st, n, _] = Effects.retired(id)
      idx = Map.put(Effects.retired_index(), id, [st, n, "ard9:" <> String.duplicate("A", 43)])
      :ok = AuthorityLog.append("effects", [{:set, "effects", "retired", idx}], nil)
      reboot_registries!()
      assert Effects.get(id)[@unverified] =~ "cannot check (ard9)"
    end
  end

  # ------------------------------------------------------------ incomplete pages

  describe "a page that meets a batch that does not check" do
    setup do
      ids = performs!(30)
      for _ <- 1..6, do: pass!(keep_recent: 4, max_batch: 5)
      batches = Effects.retired_batches()
      assert map_size(batches) >= 4
      # A batch in the middle: pages before it are whole.
      {m, [_lo, hi | _]} = batches |> Enum.sort() |> Enum.at(2)
      victim = ids |> Enum.filter(&match?([_, ^m | _], Effects.retired(&1))) |> hd()
      {:ok, ids: ids, m: m, hi: hi, victim: victim}
    end

    defp assert_stops(ids, hi, why) do
      pages = page_all(:effects, 3)
      {whole, [last]} = Enum.split(pages, -1)
      refute Enum.any?(whole, &Map.has_key?(&1, "archive_error"))
      assert last["archive_error"] =~ why
      assert last["incomplete"] == true and last["more"] == false and last["next_cursor"] == nil

      # Only rows newer than anything the batch could hold, and none twice.
      shown = Enum.flat_map(pages, & &1["items"]) |> Enum.map(& &1["id"])
      assert Enum.all?(last["items"], &(key(&1["id"]) > hi))
      assert shown == Enum.uniq(shown)
      assert shown == ids |> Enum.sort_by(&key/1, :desc) |> Enum.take(length(shown))

      # The same request says the same thing; nothing sealed; the world goes on.
      assert Projection.history_page(
               :effects,
               nil,
               List.last(Enum.at(pages, -2)["items"])["id"],
               3
             )["archive_error"] =~ why

      no_seals!()
      assert is_binary(perform!())
    end

    test "a row altered in place: archive-row-mismatch", %{ids: ids, m: m, hi: hi, victim: v} do
      tamper!(
        "effects",
        &(&1["id"] == v),
        &Map.update!(&1, "resource", fn r -> String.reverse(r) end),
        same_length: true
      )

      assert_stops(ids, hi, "archive-row-mismatch · effects #{v} in batch #{m}")
    end

    test "a row taken out: archive-batch-incomplete", %{ids: ids, m: m, hi: hi, victim: v} do
      recs = frames!()

      write_frames!(
        Enum.map(recs, fn %{"b" => b, "rows" => rows} = rec ->
          if b == m,
            do: %{
              rec
              | "rows" => Map.update!(rows, "effects", &Enum.reject(&1, fn r -> r["id"] == v end))
            },
            else: rec
        end)
      )

      reboot_registries!()
      assert_stops(ids, hi, "archive-batch-incomplete · batch #{m} holds")
    end

    test "a row held twice: archive-row-duplicate", %{ids: ids, m: m, hi: hi, victim: v} do
      recs = frames!()

      write_frames!(
        Enum.map(recs, fn %{"b" => b, "rows" => rows} = rec ->
          if b == m,
            do: %{
              rec
              | "rows" =>
                  Map.update!(rows, "effects", fn rs ->
                    rs ++ Enum.filter(rs, &(&1["id"] == v))
                  end)
            },
            else: rec
        end)
      )

      reboot_registries!()

      assert_stops(
        ids,
        hi,
        "archive-row-duplicate · effects #{v} appears more than once in batch #{m}"
      )
    end

    test "a row retired in another batch, copied in: archive-row-unretired", %{
      ids: ids,
      m: m,
      hi: hi
    } do
      recs = frames!()
      [copied | _] = hd(recs)["rows"]["effects"]
      assert [_, 1 | _] = Effects.retired(copied["id"])

      write_frames!(
        Enum.map(recs, fn %{"b" => b, "rows" => rows} = rec ->
          if b == m,
            do: %{rec | "rows" => Map.update!(rows, "effects", &(&1 ++ [copied]))},
            else: rec
        end)
      )

      reboot_registries!()

      assert_stops(
        ids,
        hi,
        "archive-row-unretired · effects #{copied["id"]} is in batch #{m} but was not retired there"
      )
    end

    test "a frame that no longer verifies: archive-unreadable", %{ids: ids, m: m, hi: hi} do
      # One byte inside batch m's payload, with bytes after it: not a torn tail.
      {:ok, _path, off, _len} = AuthorityLog.archive_slot(m)
      bin = File.read!(AuthorityLog.archive_path())
      <<pre::binary-size(off + 20), x, post::binary>> = bin
      File.write!(AuthorityLog.archive_path(), <<pre::binary, Bitwise.bxor(x, 1), post::binary>>)
      assert_stops(ids, hi, "archive-unreadable · batch #{m} does not verify")
    end
  end

  describe "a page whose batches overlap" do
    test "keeps only rows newer than the batch that failed, never one from below the gap" do
      [_, b | _] = ids = performs!(12)

      # b's receipt goes missing, so b stays working (MISSING) while its
      # neighbours retire; once it is back, b retires in a LATER batch, with
      # newer effects: batch 2 = {b, 9, 10} reaches back over batch 1 = {1, 3..8}.
      full = :sys.get_state(Receipts).s
      [hidden] = Enum.filter(full["log"], &(&1["effect_ref"] == b))

      :ok =
        AuthorityCoordinator.transact(fn ->
          Receipts.load_state(%{
            full
            | "log" => Enum.reject(full["log"], &(&1["effect_ref"] == b))
          })
        end)

      assert %{"batch" => 1, "retired" => 7} = pass!(keep_recent: 4)
      now = :sys.get_state(Receipts).s

      :ok =
        AuthorityCoordinator.transact(fn ->
          Receipts.load_state(%{now | "log" => now["log"] ++ [hidden]})
        end)

      assert %{"batch" => 2, "retired" => 3} = pass!(keep_recent: 2)
      assert %{1 => [1, 8 | _], 2 => [2, 10 | _]} = Effects.retired_batches()

      # A row of batch 1 altered in place; batch 1 now fails its check.
      five = Enum.at(ids, 4)

      tamper!(
        "effects",
        &(&1["id"] == five),
        &Map.update!(&1, "resource", fn r -> String.reverse(r) end), same_length: true)

      p1 = Projection.history_page(:effects, nil, nil, 3)

      assert Enum.map(p1["items"], & &1["id"]) == [
               Enum.at(ids, 11),
               Enum.at(ids, 10),
               Enum.at(ids, 9)
             ]

      p2 = Projection.history_page(:effects, nil, p1["next_cursor"], 3)
      assert p2["archive_error"] =~ "archive-row-mismatch · effects #{five} in batch 1"
      assert p2["incomplete"] == true and p2["next_cursor"] == nil

      # 9 is newer than anything batch 1 could hold; b is not, and showing it
      # after 9 would present 3..8 as absent rather than unreadable.
      assert Enum.map(p2["items"], & &1["id"]) == [Enum.at(ids, 8)]
    end
  end

  # ------------------------------------------------------------ no unchecked path

  describe "the readers" do
    test "only the checked readers take rows out of the archive, and each checks what it takes" do
      {:ok, mods} = :application.get_key(:ampd, :modules)

      takers =
        for mod <- mods,
            {:ok, {_, [abstract_code: {:raw_abstract_v1, forms}]}} <-
              [:beam_lib.chunks(:code.which(mod), [:abstract_code])],
            {:function, _, name, arity, clauses} <- forms,
            calls?(clauses, mod, {Ampd.AuthorityLog, :store_rows, 2}),
            into: %{},
            do: {{mod, name, arity}, clauses}

      assert Map.keys(takers) |> Enum.sort() ==
               Enum.sort([
                 {Ampd.AuthorityLog, :archived_row, 5},
                 {Ampd.AuthorityLog, :archived_rows, 3},
                 {Ampd.Effects, :archived_batch, 1},
                 {Ampd.Receipts, :archived_batch, 1}
               ])

      for {{mod, _, _} = mfa, clauses} <- takers do
        assert calls?(clauses, mod, {Ampd.AuthorityLog, :check_batch, 6}) or
                 calls?(clauses, mod, {Ampd.AuthorityLog, :check_row, 6}),
               "#{inspect(mfa)} takes rows from the archive without checking them"
      end
    end
  end

  # Does this abstract code call `{m, f, a}` — remotely, or locally from `m`?
  defp calls?(t, self, {m, f, a} = target) do
    case t do
      {:call, _, {:remote, _, {:atom, _, ^m}, {:atom, _, ^f}}, args} when length(args) == a ->
        true

      {:call, _, {:atom, _, ^f}, args} when self == m and length(args) == a ->
        true

      t when is_tuple(t) ->
        t |> Tuple.to_list() |> calls?(self, target)

      [h | rest] ->
        calls?(h, self, target) or calls?(rest, self, target)

      _ ->
        false
    end
  end
end
