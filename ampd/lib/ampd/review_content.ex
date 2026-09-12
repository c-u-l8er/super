defmodule Ampd.ReviewContent do
  @moduledoc """
  Durable review material, addressed by the SHA-256 of its bytes.

  ## Why content does not travel inside a change set

  A change set carried whole file text, so its frame grew with the files it
  described, and `development_attempts` is published **in full on every frame**.
  Two ceilings met that: the encoded frame (`Ampd.Frame.max_bytes/0`, enforced by
  the socket driver *before* the bytes reach the VM) and the per-field caps.
  Measured: two change sets of the maximum permitted size exceed the frame, so
  the projection stops being publishable and the world stops being viewable —
  over material already recorded. `docs/app/REVIEW_CONTENT_LIMITS_2026_09_12.md`
  has the numbers and the option that was not taken.

  ## This is NOT a cache

  An earlier draft of this module said losing the directory was "a cache miss".
  **That was wrong, and the correction is the reason this module looks the way
  it does.** A digest *identifies* content; it cannot reconstitute it. If the
  bytes behind a recorded attempt are gone, the review cannot be read, the test
  cannot be run and the result cannot be accepted — so this is durable review
  material with retention rules, not a rebuildable cache.

  What it is *not* is an **authority** store. `Ampd.World.authority_stores/0`
  holds the stores whose absence is indistinguishable from an order nobody gave;
  absence here is distinguishable, named, and **blocks** rather than permits:
  `status/1` answers `:missing` or `:corrupt`, and every consumer must refuse on
  either. The failure mode is a refusal, never a fallback to other bytes.

  ## Durability, exactly as far as it goes

  Publication is: append chunks to `staging/`, **fsync the file**, hash what was
  actually written, and only then rename into `blobs/`. The bytes are on the
  device before the name exists, so a published blob is never a half-written one.

  **The parent directory is not fsynced, because Erlang cannot open a directory**
  — `:file.open/2` answers `{:error, :eisdir}` with and without `:raw`. So a
  crash in the window between the rename and the filesystem committing it can
  lose the *name* of a blob whose *bytes* were durable. That is why content is
  published **before** the attempt that references it is recorded, and why a
  missing blob is a first-class reported state rather than an assertion failure:
  the recovery path is to stage it again, and nothing accepts in the meantime.

  ## Retention and collection

  Content referenced by any recorded attempt is retained for as long as that
  attempt exists. `collect/2` removes **only** blobs that no attempt references
  and that are older than `grace_ms/0` — the grace period exists because content
  is legitimately published a moment before the record that references it, and a
  collector that did not wait would delete exactly the upload in flight.

  ## Backup

  Everything lives under `Ampd.Store.data_dir()`, so whatever copies a world
  copies its review content. A backup that takes only `*.dets` takes the
  attempts and not the material they are about; `paths/0` is what a backup must
  include.
  """
  @chunk_bytes 64 * 1024
  @file_bytes 4 * 1024 * 1024
  @store_bytes 256 * 1024 * 1024
  @grace_ms 60 * 60 * 1000
  @digest ~r/\A[0-9a-f]{64}\z/

  def chunk_bytes, do: @chunk_bytes
  def file_bytes, do: @file_bytes
  def store_bytes, do: @store_bytes
  def grace_ms, do: @grace_ms

  def dir, do: Path.join(Ampd.Store.data_dir(), "review-content")
  def blobs, do: Path.join(dir(), "blobs")
  def staging, do: Path.join(dir(), "staging")

  @doc "What a backup of this world must include beyond its stores."
  def paths, do: [blobs()]

  defp blob(d), do: Path.join(blobs(), d)
  defp partial(d), do: Path.join(staging(), d <> ".partial")
  defp named?(d), do: is_binary(d) and Regex.match?(@digest, d)
  defp hash(b), do: :crypto.hash(:sha256, b) |> Base.encode16(case: :lower)

  defp refuse(code, message, detail \\ %{}),
    do:
      {:refused,
       Ampd.Refusal.new(code,
         component: "review-content",
         requires_human: true,
         public_message: message,
         operator_detail: detail
       )}

  # =========================================================== reading

  @doc """
  Whether a blob is present, **without reading it**.

  This is what runs inside the ordered coordinator, so it must be bounded: a
  full re-hash of twelve four-megabyte members would be an unbounded host round
  trip inside the transaction that decides the world's order, which is the
  crossing `tools/check-dispatch-partition.mjs` exists to refuse. A `stat` is
  bounded.

  What makes that safe is that a blob is only ever published **after** its bytes
  have been hashed and checked to be text — see `publish/1` — so a present blob
  is a verified blob unless something outside this module edited the disk.
  `verify/1` is the answer to that, and it runs where an unbounded read is fine:
  in the host, before any test or acceptance check uses the bytes.
  """
  def status(digest) do
    if named?(digest) and File.exists?(blob(digest)), do: :available, else: :missing
  end

  @doc """
  `:available`, `:missing` or `:corrupt` — the full check, re-reading the bytes.

  Corrupt is kept apart from missing on purpose. They call for different things:
  missing content can be staged again from the same source, corrupt content
  means the bytes on this machine disagree with what was reviewed, and a person
  should be told which happened.
  """
  def verify(digest) do
    cond do
      not named?(digest) -> :missing
      not File.exists?(blob(digest)) -> :missing
      digest_of_blob(digest) == digest -> :available
      true -> :corrupt
    end
  end

  def available?(digest), do: status(digest) == :available

  @doc """
  The bytes behind a digest, re-verified on the way out.

  A blob sits on a disk between publication and reading, and this module is not
  the only thing that can reach a disk. A store that answers with whatever is in
  the file is a store that can be edited from outside and believed.
  """
  def fetch(digest) do
    cond do
      not named?(digest) -> {:error, :missing}
      not File.exists?(blob(digest)) -> {:error, :missing}
      true -> verified_read(digest)
    end
  end

  defp verified_read(digest) do
    case File.read(blob(digest)) do
      {:ok, bytes} -> if hash(bytes) == digest, do: {:ok, bytes}, else: {:error, :corrupt}
      {:error, _} -> {:error, :missing}
    end
  end

  defp digest_of_blob(digest) do
    blob(digest)
    |> File.stream!([], @chunk_bytes)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  rescue
    _ -> nil
  end

  def size(digest) do
    case File.stat(blob(digest)) do
      {:ok, %{size: n}} -> n
      _ -> nil
    end
  end

  # =========================================================== writing

  @doc """
  Append one chunk of content being published under `digest`.

  `offset` is where the caller believes it is. A mismatch refuses rather than
  seeking: a writer that has lost its place would otherwise build a blob that
  hashes to nothing and fail only at the end, having done all the work.

  `final?` closes it — the file is fsynced, the bytes written are hashed, and the
  result must equal `digest` or nothing is published. **The name is never taken
  on trust.**
  """
  def put(digest, offset, chunk, final?) do
    cond do
      not named?(digest) ->
        refuse("review-content-invalid", "A content name must be a SHA-256 digest in lower-case hex.")

      not is_binary(chunk) ->
        refuse("review-content-invalid", "A chunk must be binary content.")

      byte_size(chunk) > @chunk_bytes ->
        refuse(
          "review-content-chunk-too-large",
          "One upload carries at most #{@chunk_bytes} bytes.",
          %{"bytes" => byte_size(chunk), "max" => @chunk_bytes}
        )

      not (is_integer(offset) and offset >= 0) ->
        refuse("review-content-invalid", "An offset must be a non-negative integer.")

      # Already published under its own name, byte for byte. Re-publishing is
      # not an error and must not truncate what is there.
      File.exists?(blob(digest)) ->
        {:ok, %{"digest" => digest, "bytes" => size(digest), "complete" => true, "kept" => true}}

      true ->
        File.mkdir_p!(blobs())
        File.mkdir_p!(staging())
        append(digest, offset, chunk, final?)
    end
  end

  defp append(digest, offset, chunk, final?) do
    written = staged_bytes(digest)

    cond do
      offset != written ->
        refuse(
          "review-content-offset",
          "This upload continues from #{written} bytes, not #{offset}.",
          %{"expected" => written, "given" => offset}
        )

      written + byte_size(chunk) > @file_bytes ->
        discard(digest)

        refuse("review-file-too-large", "One file is at most #{@file_bytes} bytes.", %{
          "bytes" => written + byte_size(chunk),
          "max" => @file_bytes
        })

      stored() + byte_size(chunk) > @store_bytes ->
        refuse(
          "review-content-store-full",
          "Review content is at most #{@store_bytes} bytes. Collect what nothing references.",
          %{"stored" => stored(), "max" => @store_bytes}
        )

      true ->
        write_chunk(digest, chunk)
        if final?, do: publish(digest), else: {:ok, progress(digest, false)}
    end
  end

  # fsync on every chunk, not only at the end. A 4 MB upload that is only
  # durable at its last byte is an upload that a crash turns into nothing,
  # and the offset discipline above exists so it can be resumed instead.
  defp write_chunk(digest, chunk) do
    {:ok, fd} = :file.open(String.to_charlist(partial(digest)), [:append, :binary, :raw])

    try do
      :ok = :file.write(fd, chunk)
      :ok = :file.sync(fd)
    after
      :file.close(fd)
    end
  end

  # Hash what was WRITTEN, never what was claimed, and publish by rename so a
  # reader never sees a partial blob under a real name.
  defp publish(digest) do
    actual =
      partial(digest)
      |> File.stream!([], @chunk_bytes)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual == digest do
      # Text is checked HERE, once, on bytes that are already being read to be
      # hashed — so nothing downstream has to read a blob again to find out
      # whether it is text, and a present blob is a valid one by construction.
      case File.read(partial(digest)) do
        {:ok, bytes} ->
          if String.valid?(bytes) and not String.contains?(bytes, <<0>>) do
            File.rename!(partial(digest), blob(digest))
            {:ok, %{"digest" => digest, "bytes" => size(digest), "complete" => true, "kept" => false}}
          else
            discard(digest)

            refuse(
              "review-content-invalid",
              "Review content must be complete UTF-8 text without NUL.",
              %{"published_as" => digest}
            )
          end

        {:error, reason} ->
          discard(digest)
          refuse("review-content-invalid", "The staged file could not be read back.", %{
            "reason" => to_string(reason)
          })
      end
    else
      discard(digest)

      refuse(
        "review-content-invalid",
        "The uploaded bytes do not hash to the name they were published under.",
        %{"published_as" => digest, "hashed_to" => actual}
      )
    end
  end

  defp progress(d, complete?),
    do: %{"digest" => d, "bytes" => staged_bytes(d), "complete" => complete?, "kept" => false}

  defp staged_bytes(d) do
    case File.stat(partial(d)) do
      {:ok, %{size: n}} -> n
      _ -> 0
    end
  end

  defp discard(d), do: File.rm(partial(d))

  @doc "Bytes published. Partial uploads are not counted; they are swept."
  def stored do
    case File.ls(blobs()) do
      {:ok, names} -> Enum.reduce(names, 0, &(&2 + (size(&1) || 0)))
      _ -> 0
    end
  end

  # =========================================================== lifecycle

  @doc """
  Discard interrupted uploads. Run when a world opens.

  A `.partial` after a restart belongs to an uploader that is gone. It cannot be
  verified — its digest is only meaningful once complete — and it cannot be
  resumed, because the caller that knew the offset died with it. Published blobs
  are never touched.
  """
  def recover do
    case File.ls(staging()) do
      {:ok, names} ->
        {n, bytes} =
          Enum.reduce(names, {0, 0}, fn name, {n, b} ->
            path = Path.join(staging(), name)
            size = (File.stat(path) |> elem(1) |> Map.get(:size, 0)) || 0
            File.rm(path)
            {n + 1, b + size}
          end)

        %{"discarded" => n, "bytes" => bytes}

      _ ->
        %{"discarded" => 0, "bytes" => 0}
    end
  end

  @doc """
  Every digest any recorded attempt depends on.

  Both member shapes are read: the content-addressed one, whose digests are the
  `source` fields themselves, and the legacy inline one, which references
  nothing because it carries its bytes.
  """
  def referenced(attempts) when is_map(attempts) do
    attempts
    |> Map.values()
    |> Enum.flat_map(&digests_of/1)
    |> MapSet.new()
  end

  defp digests_of(%{"files" => files}) when is_list(files),
    do: Enum.flat_map(files, &member_digests/1)

  defp digests_of(%{"source" => _} = a), do: member_digests(a)
  defp digests_of(_), do: []

  # One clause, because two of them got this wrong: a `%{"source" => s}` head
  # matches an INLINE row too — `shared_draft` is on the row, not on the source
  # — so the inline check never ran and an inline member was reported as
  # referencing content it does not depend on. A member that carries its own
  # bytes references nothing; a staged one is named by the digests its source
  # already records, so it needs no second pair of fields to say where its
  # content is.
  defp member_digests(row) when is_map(row) do
    source = row["source"]

    cond do
      is_binary(row["shared_draft"]) or is_binary(row["proposed_text"]) -> []
      is_map(source) -> Enum.filter([source["draft_sha256"], source["result_sha256"]], &named?/1)
      true -> []
    end
  end

  defp member_digests(_), do: []

  @doc """
  Remove published blobs that no attempt references and that are older than
  `grace_ms/0`.

  The grace period is not politeness. Content is legitimately published a moment
  before the record that references it, and a collector without one would delete
  exactly the upload in flight.
  """
  def collect(attempts, now \\ System.system_time(:millisecond)) do
    keep = referenced(attempts)

    case File.ls(blobs()) do
      {:ok, names} ->
        Enum.reduce(names, %{"collected" => 0, "bytes" => 0, "kept" => 0}, fn name, acc ->
          cond do
            MapSet.member?(keep, name) ->
              %{acc | "kept" => acc["kept"] + 1}

            not young?(name, now) ->
              size = size(name) || 0
              File.rm(Path.join(blobs(), name))
              %{acc | "collected" => acc["collected"] + 1, "bytes" => acc["bytes"] + size}

            true ->
              %{acc | "kept" => acc["kept"] + 1}
          end
        end)

      _ ->
        %{"collected" => 0, "bytes" => 0, "kept" => 0}
    end
  end

  defp young?(name, now) do
    case File.stat(Path.join(blobs(), name), time: :posix) do
      {:ok, %{mtime: t}} -> now - t * 1000 < @grace_ms
      _ -> true
    end
  end

  @doc "What a person is owed about this store: size, count, and what is missing."
  def report(attempts) do
    keep = referenced(attempts)
    # `verify/1` here, not `status/1`: this is the diagnostic a person reads to
    # find out whether their review material is intact, and answering it from a
    # `stat` would report corrupt content as available.
    states = Map.new(keep, &{&1, verify(&1)})

    %{
      "schema" => "review-content-report@1",
      "bytes" => stored(),
      "max_bytes" => @store_bytes,
      "referenced" => MapSet.size(keep),
      "available" => Enum.count(states, &(elem(&1, 1) == :available)),
      "missing" => for({d, :missing} <- states, do: d),
      "corrupt" => for({d, :corrupt} <- states, do: d)
    }
  end

  @doc """
  Publish the bodies an INLINE attempt carries, so its members can be rewritten
  to name them.

  Phase one of migrating a record written before content was published
  separately. It only writes into this store — it does not touch the attempt —
  so it is safe to run repeatedly and safe to run and then not proceed. Content
  is addressed by its bytes, so publishing something already published is a
  no-op.

  Phase two is `Ampd.DevelopmentAttempt.migrate_inline/1`, which rewrites the
  records and refuses to rewrite any member whose content this did not manage
  to publish.
  """
  def absorb(attempts) when is_map(attempts) do
    attempts
    |> Map.values()
    |> Enum.flat_map(&inline_bodies/1)
    # Content is addressed by its bytes, so two members with identical text are
    # one blob. Counting calls rather than blobs would report work that did not
    # happen.
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.reduce(%{"published" => 0, "bytes" => 0, "refused" => []}, fn {digest, body}, acc ->
      case put(digest, 0, body, true) do
        {:ok, _} ->
          %{acc | "published" => acc["published"] + 1, "bytes" => acc["bytes"] + byte_size(body)}

        {:refused, r} ->
          %{acc | "refused" => acc["refused"] ++ [%{"digest" => digest, "code" => r["code"]}]}
      end
    end)
  end

  defp inline_bodies(%{"files" => files}) when is_list(files),
    do: Enum.flat_map(files, &inline_bodies/1)

  defp inline_bodies(%{"source" => source} = row) when is_map(source) do
    [{source["draft_sha256"], row["shared_draft"]}, {source["result_sha256"], row["proposed_text"]}]
    |> Enum.filter(fn {d, body} -> named?(d) and is_binary(body) end)
  end

  defp inline_bodies(_), do: []

  @doc "`put/4` with a base64 chunk, which is how one arrives over the wire."
  def put_encoded(digest, offset, chunk, final?) do
    case Base.decode64(chunk) do
      {:ok, bytes} -> put(digest, offset, bytes, final?)
      :error -> refuse("review-content-invalid", "A chunk must be base64.")
    end
  end
end
