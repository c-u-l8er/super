defmodule Ampd.ReviewContentTest do
  @moduledoc """
  The store: publication, durability, retention, and every way content can fail
  to be there.

  The ceiling that made it necessary is measured first, on its own, because it
  is a property of the runtime as it shipped rather than of anything here.
  """
  use ExUnit.Case, async: false
  alias Ampd.{Frame, ReviewContent}

  setup do
    Ampd.reset()
    File.rm_rf(ReviewContent.dir())
    on_exit(fn -> File.rm_rf(ReviewContent.dir()) end)
    :ok
  end

  defp sha(b), do: :crypto.hash(:sha256, b) |> Base.encode16(case: :lower)

  defp stage(bytes, chunk \\ 64 * 1024) do
    digest = sha(bytes)
    parts = chunks(bytes, chunk)
    last = length(parts) - 1

    result =
      parts
      |> Enum.with_index()
      |> Enum.reduce({:ok, nil}, fn {part, i}, acc ->
        case acc do
          {:ok, _} -> ReviewContent.put(digest, i * chunk, part, i == last)
          other -> other
        end
      end)

    {digest, result}
  end

  defp chunks(<<>>, _), do: [<<>>]

  defp chunks(b, n) do
    whole = for <<c::binary-size(n) <- b>>, do: c
    rest = rem(byte_size(b), n)
    if rest == 0, do: whole, else: whole ++ [binary_part(b, byte_size(b) - rest, rest)]
  end

  # ------------------------------------------- the ceiling that was there

  defp maximal_inline_member(path) do
    %{
      "shared_draft" => String.duplicate("a", 24_000),
      "proposed_text" => String.duplicate("b", 32_000),
      "source" => %{
        "schema" => "selected-file-basis@1",
        "path" => path,
        "head" => String.duplicate("0", 40)
      }
    }
  end

  defp maximal_inline_attempt(id),
    do:
      {id,
       %{
         "id" => id,
         "schema" => "development-review-set@1",
         "files" => Enum.map(1..4, &maximal_inline_member("f#{&1}.js"))
       }}

  # **These two are ARITHMETIC, not reachability, and an earlier version of this
  # file claimed otherwise.** `Ampd.DevelopmentAttempt.persist/2` — on shipped
  # main, before any of this — caps the whole persisted `development_attempts`
  # collection at 64 KiB encoded plus a reserve per unfinished test run, and
  # refuses `attempt-directory-full` while preserving what is already recorded.
  # So a world never reaches a projection of this size: the store refuses first.
  # These tests encode synthetic maps and go nowhere near admission, which is
  # exactly why they cannot establish a shipped failure. What they do show is
  # how little inline material fits a frame, which is why the 64 KiB guard has
  # to exist and must be kept. `review_content_record_test.exs` has the
  # reachable version, through the real record path.
  test "ARITHMETIC ONLY: one maximal inline change set would occupy most of a frame" do
    one = JSON.encode!(%{"development_attempts" => Map.new([maximal_inline_attempt("da_0001")])})
    assert byte_size(one) > 224_000
    assert byte_size(one) < Frame.max_bytes(), "one still fits, which is why it was not noticed"
  end

  test "ARITHMETIC ONLY: two of them would not encode inside one frame" do
    two =
      JSON.encode!(%{
        "development_attempts" =>
          Map.new([maximal_inline_attempt("da_0001"), maximal_inline_attempt("da_0002")])
      })

    assert byte_size(two) > Frame.max_bytes(), """
    Two inline sets of the maximum per-file size do not encode inside a frame.
    This is arithmetic about the SHAPE, not a reachable state: persist/2 refuses
    at 64 KiB long before, so the world is protected by the guard rather than by
    luck. The conclusion to draw is about how little inline material fits, not
    that a shipped world can be made unviewable.
    """
  end

  test "the guard that actually bounds it is on shipped main and is far tighter" do
    # 64 KiB, not 256 KiB — and it counts the whole collection, not one record.
    # Recorded on 2026-09-12: one real three-file inline change set (`da_0030`)
    # was 30 632 bytes, which is 47% of the entire budget for a world.
    assert 64 * 1024 < Frame.max_bytes()

    four = JSON.encode!(Map.new([maximal_inline_attempt("da_0001")]))
    assert byte_size(four) > 64 * 1024,
           "even ONE maximal inline set exceeds the collection budget, so it is " <>
             "the store that refuses, with attempt-directory-full"
  end

  # --------------------------------------------------------- publication

  test "a file far larger than a frame is published and reads back byte for byte" do
    bytes = String.duplicate("review content ", 40_000)
    {digest, {:ok, done}} = stage(bytes)
    assert done["complete"] and done["bytes"] == byte_size(bytes)
    assert byte_size(bytes) > Frame.max_bytes(), "the point: this could not travel in one frame"
    assert ReviewContent.fetch(digest) == {:ok, bytes}
    assert ReviewContent.status(digest) == :available
    assert ReviewContent.verify(digest) == :available
  end

  test "the real files this exists for publish without trouble" do
    for path <- ["cockpit/ui/cockpit.js", "ampd/lib/ampd/projection.ex"] do
      bytes = File.read!(Path.expand(Path.join([__DIR__, "..", "..", path])))
      {digest, {:ok, done}} = stage(bytes)
      assert done["complete"], "#{path} did not publish"
      assert ReviewContent.fetch(digest) == {:ok, bytes}
    end
  end

  test "bytes that do not answer to their name are refused and kept nowhere" do
    lie = sha("something else")
    {:refused, r} = ReviewContent.put(lie, 0, "these bytes", true)
    assert r["code"] == "review-content-invalid"
    assert r["operator_detail"]["hashed_to"] == sha("these bytes")
    assert ReviewContent.status(lie) == :missing
    refute File.exists?(Path.join(ReviewContent.staging(), lie <> ".partial"))
  end

  test "content that is not text is refused AT PUBLICATION, so a present blob is a valid one" do
    for bad <- [<<0xFF, 0xFE, 0xFD>>, "text with a \0 in it"] do
      {digest, result} = stage(bad)
      assert {:refused, r} = result
      assert r["code"] == "review-content-invalid"
      assert ReviewContent.status(digest) == :missing
    end
  end

  test "an empty file is publishable — it is a real case and a loop would skip it" do
    {digest, {:ok, done}} = stage("")
    assert done["complete"] and done["bytes"] == 0
    assert ReviewContent.fetch(digest) == {:ok, ""}
  end

  # ------------------------------------------------------------- bounds

  test "exactly at the chunk limit is accepted; one byte over is refused by its own name" do
    at = String.duplicate("x", ReviewContent.chunk_bytes())
    assert {:ok, done} = ReviewContent.put(sha(at), 0, at, true)
    assert done["complete"]

    over = String.duplicate("x", ReviewContent.chunk_bytes() + 1)
    assert {:refused, r} = ReviewContent.put(sha(over), 0, over, true)
    assert r["code"] == "review-content-chunk-too-large"
    assert r["operator_detail"]["max"] == ReviewContent.chunk_bytes()
  end

  test "a file over the per-file limit is refused, and its partial is discarded" do
    d = sha("never completed")
    chunk = String.duplicate("y", ReviewContent.chunk_bytes())
    steps = div(ReviewContent.file_bytes(), ReviewContent.chunk_bytes())

    result =
      Enum.reduce_while(0..steps, nil, fn i, _ ->
        case ReviewContent.put(d, i * ReviewContent.chunk_bytes(), chunk, false) do
          {:ok, _} -> {:cont, nil}
          refused -> {:halt, refused}
        end
      end)

    assert {:refused, r} = result
    assert r["code"] == "review-file-too-large"
    assert r["operator_detail"]["max"] == ReviewContent.file_bytes()
    refute File.exists?(Path.join(ReviewContent.staging(), d <> ".partial"))
  end

  test "a name that is not a digest is refused before anything is written" do
    for bad <- ["../../etc/passwd", "", "ABCDEF", String.duplicate("z", 64)] do
      assert {:refused, r} = ReviewContent.put(bad, 0, "x", true)
      assert r["code"] == "review-content-invalid"
    end

    refute File.exists?(Path.join(ReviewContent.dir(), "../../etc/passwd"))
  end

  # ------------------------------------------------ interrupted uploads

  test "a writer that has lost its place is refused rather than silently seeking" do
    d = sha("abcdef")
    {:ok, _} = ReviewContent.put(d, 0, "abc", false)
    {:refused, r} = ReviewContent.put(d, 99, "def", true)
    assert r["code"] == "review-content-offset"
    assert r["operator_detail"] == %{"expected" => 3, "given" => 99}
  end

  test "an interrupted upload resumes from where it stopped" do
    bytes = String.duplicate("q", 100)
    d = sha(bytes)
    {:ok, part} = ReviewContent.put(d, 0, binary_part(bytes, 0, 40), false)
    assert part["bytes"] == 40 and not part["complete"]
    assert ReviewContent.status(d) == :missing, "nothing is published until it is complete"
    {:ok, done} = ReviewContent.put(d, 40, binary_part(bytes, 40, 60), true)
    assert done["complete"]
    assert ReviewContent.fetch(d) == {:ok, bytes}
  end

  test "recovery discards interrupted uploads and keeps every published blob" do
    {kept, {:ok, _}} = stage("this one finished")
    d = sha("this one did not")
    {:ok, _} = ReviewContent.put(d, 0, "this one", false)

    report = ReviewContent.recover()
    assert report["discarded"] == 1 and report["bytes"] == 8
    assert ReviewContent.status(d) == :missing
    assert ReviewContent.status(kept) == :available, "a published blob is never swept"
  end

  # --------------------------------------------------- missing & corrupt

  test "missing and corrupt are different answers, and neither is a fallback" do
    {d, {:ok, _}} = stage("the original")
    assert ReviewContent.verify(d) == :available

    File.write!(Path.join(ReviewContent.blobs(), d), "something else entirely")
    assert ReviewContent.verify(d) == :corrupt
    assert ReviewContent.fetch(d) == {:error, :corrupt}

    File.rm!(Path.join(ReviewContent.blobs(), d))
    assert ReviewContent.verify(d) == :missing
    assert ReviewContent.fetch(d) == {:error, :missing}
  end

  test "status is bounded and does not read the file; verify does" do
    # `status/1` runs inside the ordered transaction, so it must not read up to
    # four megabytes per member. It answers from a stat, which is why tampering
    # is caught by `verify/1` in the host instead.
    {d, {:ok, _}} = stage("some content")
    File.write!(Path.join(ReviewContent.blobs(), d), "tampered")
    assert ReviewContent.status(d) == :available, "stat cannot see a changed body"
    assert ReviewContent.verify(d) == :corrupt, "and this is what does"
  end

  # ------------------------------------------------ retention and collection

  defp attempt_referencing(digests) do
    %{
      "da_0001" => %{
        "files" =>
          Enum.map(digests, fn {draft, proposed} ->
            %{
              "source" => %{
                "draft_sha256" => draft,
                "result_sha256" => proposed,
                "schema" => "selected-file-basis@1"
              }
            }
          end)
      }
    }
  end

  test "content an attempt references is retained; content nothing references is collected" do
    {referenced, {:ok, _}} = stage("kept, because a record names it")
    {orphan, {:ok, _}} = stage("named by nothing")
    attempts = attempt_referencing([{referenced, referenced}])

    # Inside the grace period nothing is collected, because content is
    # published a moment BEFORE the record that names it.
    fresh = ReviewContent.collect(attempts)
    assert fresh["collected"] == 0 and fresh["kept"] == 2

    later = System.system_time(:millisecond) + ReviewContent.grace_ms() + 1
    done = ReviewContent.collect(attempts, later)
    assert done["collected"] == 1
    assert ReviewContent.status(referenced) == :available
    assert ReviewContent.status(orphan) == :missing
  end

  test "an inline attempt references nothing, and does not keep unrelated content alive" do
    {orphan, {:ok, _}} = stage("not referenced by an inline record")

    inline = %{
      "da_0001" => %{
        "files" => [
          %{
            "shared_draft" => "a",
            "proposed_text" => "b",
            "source" => %{"draft_sha256" => orphan, "result_sha256" => orphan}
          }
        ]
      }
    }

    assert ReviewContent.referenced(inline) |> MapSet.size() == 0
    later = System.system_time(:millisecond) + ReviewContent.grace_ms() + 1
    assert ReviewContent.collect(inline, later)["collected"] == 1
  end

  test "the report tells a person what is referenced and what is not there" do
    {ok_digest, {:ok, _}} = stage("present")
    gone = sha("never staged")
    report = ReviewContent.report(attempt_referencing([{ok_digest, gone}]))
    assert report["referenced"] == 2 and report["available"] == 1
    assert report["missing"] == [gone] and report["corrupt"] == []
  end

  # ----------------------------------------------------------- the wire

  test "the wire form is base64, and a chunk that is not base64 is refused" do
    d = sha("hello")
    assert {:ok, done} = ReviewContent.put_encoded(d, 0, Base.encode64("hello"), true)
    assert done["complete"]
    assert {:refused, r} = ReviewContent.put_encoded(sha("x"), 0, "not base64!!", true)
    assert r["code"] == "review-content-invalid"
  end

  test "re-publishing content that is already there keeps it and does not truncate" do
    bytes = String.duplicate("z", 1000)
    {digest, {:ok, _}} = stage(bytes)
    assert {:ok, again} = ReviewContent.put(digest, 0, "z", true)
    assert again["kept"]
    assert ReviewContent.fetch(digest) == {:ok, bytes}
  end

  test "a backup that takes only the stores takes the attempts and not their material" do
    assert ReviewContent.paths() == [ReviewContent.blobs()]

    assert String.starts_with?(ReviewContent.blobs(), Ampd.Store.data_dir()),
           "content lives under the world, so whatever copies a world copies it"
  end

  test "publication refuses a storage path that cannot be a directory" do
    File.mkdir_p!(ReviewContent.dir())
    File.write!(ReviewContent.blobs(), "not a directory")
    assert {:refused, r} = ReviewContent.put(sha("body"), 0, "body", true)
    assert r["code"] == "review-content-storage-error"
  end

  test "republication does not acknowledge corrupt content as complete" do
    {digest, {:ok, _}} = stage("reviewed")
    File.write!(Path.join(ReviewContent.blobs(), digest), "damaged")
    assert {:refused, r} = ReviewContent.put(digest, 0, "reviewed", true)
    assert r["code"] == "review-content-unavailable"
    assert r["operator_detail"]["state"] == "corrupt"
  end

  test "republication refuses when its directory durability cannot be established" do
    {digest, {:ok, _}} = stage("reviewed")
    File.rmdir!(ReviewContent.staging())
    File.write!(ReviewContent.staging(), "not a directory")
    assert {:refused, r} = ReviewContent.put(digest, 0, "reviewed", true)
    assert r["code"] == "review-content-storage-error"
    assert ReviewContent.fetch(digest) == {:ok, "reviewed"}
  end

  test "submission restarted at zero replays confirmed chunks without duplicating them" do
    bytes = String.duplicate("x", ReviewContent.chunk_bytes()) <> "tail"
    digest = sha(bytes)
    chunk = binary_part(bytes, 0, ReviewContent.chunk_bytes())
    assert {:ok, _} = ReviewContent.put(digest, 0, chunk, false)
    assert {:ok, replay} = ReviewContent.put(digest, 0, chunk, false)
    assert replay["bytes"] == byte_size(chunk)
    assert {:ok, _} = ReviewContent.put(digest, byte_size(chunk), "tail", true)
    assert ReviewContent.fetch(digest) == {:ok, bytes}
  end

  test "a replay with different bytes refuses without changing the partial" do
    digest = sha("abcdef")
    assert {:ok, _} = ReviewContent.put(digest, 0, "abc", false)
    assert {:refused, r} = ReviewContent.put(digest, 0, "xyz", false)
    assert r["code"] == "review-content-offset"
    assert {:ok, _} = ReviewContent.put(digest, 3, "def", true)
    assert ReviewContent.fetch(digest) == {:ok, "abcdef"}
  end
end
