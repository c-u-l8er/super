defmodule Ampd.ReceiptsLedgerTest do
  @moduledoc """
  R0b.R · R2 and R5 — the ledger's own identity, and the order it hands it
  back in.

  Both defects are the same shape: a property that was true for the first
  ten thousand records, or true for the two producers that happen to exist,
  and that nothing asserted. R0b.R exists because a third kind is about to
  arrive, and a ledger that cannot keep two kinds apart cannot keep three.
  """

  use ExUnit.Case, async: false

  alias Ampd.{Projection, Receipts}

  setup do
    Ampd.reset()
    Process.sleep(60)
    :ok
  end

  describe "R2 · the store mints its own identity" do
    test "a caller cannot choose the id" do
      r = Receipts.emit(%{"kind" => "test@1", "id" => "rcpt-forged"})

      refute r["id"] == "rcpt-forged"
      assert String.starts_with?(r["id"], "rcpt-")
      assert [^r] = Enum.filter(Receipts.all(), &(&1["kind"] == "test@1"))
    end

    test "a caller cannot choose the sequence" do
      r = Receipts.emit(%{"kind" => "test@1", "seq" => 999_999})
      refute r["seq"] == 999_999
      assert is_integer(r["seq"])
    end

    test "two records cannot claim one identity, however hard a caller tries" do
      a = Receipts.emit(%{"kind" => "test@1", "id" => "rcpt-0001", "seq" => 1})
      b = Receipts.emit(%{"kind" => "test@1", "id" => "rcpt-0001", "seq" => 1})

      refute a["id"] == b["id"]
      refute a["seq"] == b["seq"]
      assert b["seq"] == a["seq"] + 1
    end

    test "the reserved set is declared, not implied" do
      assert "id" in Receipts.reserved_fields()
      assert "seq" in Receipts.reserved_fields()
      # `kind` is the record's semantics and belongs to the producer.
      refute "kind" in Receipts.reserved_fields()
    end

    test "a caller MAY choose the kind — that is the point of the slice" do
      assert Receipts.emit(%{"kind" => "validation-result@1"})["kind"] ==
               "validation-result@1"
    end

    test "a producer that says nothing gets the default kind" do
      assert Receipts.emit(%{"actor" => "kestrel"})["kind"] == Receipts.default_kind()
    end

    test "`committed` is not minted onto every record any more" do
      # It was store-defaulted to true and read by nothing. A validation job
      # that ran correctly and found a NUL byte has no honest value for it.
      refute Map.has_key?(Receipts.emit(%{"kind" => "test@1"}), "committed")
    end
  end

  describe "R3/R4 · one kind cannot be mistaken for another" do
    test "a reader of capability receipts is not fooled by a later foreign record" do
      cap = Receipts.emit(%{"kind" => "capability-effect-receipt@1", "capability" => "github.pr.draft"})

      # The shape of the whole slice, in one line: a different kind, appended
      # afterwards. Every migrated reader used to take `List.last(all())` and
      # would now be holding this instead.
      _later = Receipts.emit(%{"kind" => "validation-result@1", "verdict" => "PASS"})

      assert Receipts.last_of_kind("capability-effect-receipt@1")["id"] == cap["id"]
      assert List.last(Receipts.all())["kind"] == "validation-result@1"
    end

    test "and symmetrically, a validation reader is not fooled by a later capability effect" do
      job = Receipts.emit(%{"kind" => "validation-result@1", "verdict" => "PASS"})
      _later = Receipts.emit(%{"kind" => "capability-effect-receipt@1", "capability" => "x"})

      assert Receipts.last_of_kind("validation-result@1")["id"] == job["id"]
    end

    test "of_kind selects, and does not merely filter the newest" do
      a = Receipts.emit(%{"kind" => "worktree_created@1"})
      _b = Receipts.emit(%{"kind" => "capability-effect-receipt@1"})
      c = Receipts.emit(%{"kind" => "worktree_created@1"})

      assert Enum.map(Receipts.of_kind("worktree_created@1"), & &1["id"]) == [a["id"], c["id"]]
    end

    test "count/1 counts one kind and count/0 counts the ledger" do
      Receipts.emit(%{"kind" => "capability-effect-receipt@1"})
      Receipts.emit(%{"kind" => "validation-result@1"})
      Receipts.emit(%{"kind" => "validation-result@1"})

      assert Receipts.count("validation-result@1") == 2
      assert Receipts.count("capability-effect-receipt@1") == 1
      assert Receipts.count() == 3
    end

    test "an absent kind is empty, not an error" do
      assert Receipts.of_kind("never-emitted@1") == []
      assert Receipts.count("never-emitted@1") == 0
      assert Receipts.last_of_kind("never-emitted@1") == nil
    end
  end

  describe "R5 · ordering survives the 10 000th record" do
    setup do
      # **Injected, not emitted, and the shape is verified against a real
      # emit first.** Twelve thousand `emit/1` calls is twelve thousand
      # GenServer round trips and a store save each — two minutes of suite
      # time to exercise a sort. So one real record establishes what the
      # store mints, the rest are built to that shape, and `load_state/1`
      # puts them in. If `emit/1` ever changes its id or `seq` shape this
      # setup fails on the assertion below rather than testing a fiction.
      probe = Receipts.emit(%{"kind" => "shape@1"})
      assert probe["id"] == "rcpt-" <> String.pad_leading(to_string(probe["seq"]), 4, "0")

      log =
        for n <- 0..12_010 do
          %{
            "kind" => "seeded@1",
            "id" => "rcpt-" <> String.pad_leading(Integer.to_string(n), 4, "0"),
            "seq" => n,
            "n" => n
          }
        end

      Ampd.AuthorityCoordinator.transact(fn ->
        Receipts.load_state(%{"log" => log, "seq" => 12_011})
      end)

      %{seeded: log}
    end

    test "the newest record is the one appended last", ctx do
      newest = List.last(ctx.seeded)
      page = Projection.page(Receipts.all(), nil, 5)

      assert hd(page["items"])["id"] == newest["id"],
             "lexical ordering reports rcpt-9999 as newest once ids reach five digits"
    end

    test "ids really do straddle the boundary, or this suite proves nothing", ctx do
      ids = Enum.map(ctx.seeded, & &1["id"])
      assert Enum.any?(ids, &String.match?(&1, ~r/^rcpt-9999$/))
      assert Enum.any?(ids, &String.match?(&1, ~r/^rcpt-10\d\d\d$/))

      # And the defect is real for the naive comparison, so the assertions
      # above are not passing for some unrelated reason.
      assert "rcpt-10000" < "rcpt-9999"
    end

    test "paging the whole ledger is lossless across the rollover" do
      all = Receipts.all()
      walked = walk(all, nil, [])

      assert length(walked) == length(all)
      assert Enum.uniq(walked) == walked, "a record was returned twice"
      assert MapSet.new(walked) == MapSet.new(Enum.map(all, & &1["id"])),
             "a record was skipped"
    end

    test "pages descend in true append order, with no interleaving" do
      seqs =
        Receipts.all()
        |> Projection.page(nil, 200)
        |> Map.fetch!("items")
        |> Enum.map(& &1["seq"])

      assert seqs == Enum.sort(seqs, :desc)
    end

    test "the cursor stays an opaque id and still resumes correctly" do
      p1 = Projection.page(Receipts.all(), nil, 50)
      assert String.starts_with?(p1["next_cursor"], "rcpt-")

      p2 = Projection.page(Receipts.all(), p1["next_cursor"], 50)

      last1 = List.last(p1["items"])
      first2 = hd(p2["items"])
      assert first2["seq"] == last1["seq"] - 1, "the page after the cursor is not contiguous"
    end
  end

  # Follow every cursor to exhaustion and return the ids, in order.
  defp walk(all, cursor, acc) do
    p = Projection.page(all, cursor, 97)
    acc = acc ++ Enum.map(p["items"], & &1["id"])

    case p["next_cursor"] do
      nil -> acc
      c -> walk(all, c, acc)
    end
  end
end
