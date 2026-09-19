defmodule Ampd.DevelopmentAttempt do
  @moduledoc """
  Human-recorded, immutable single-file and combined review material with versioned notes.
  Digests establish content consistency, not native attestation, validation,
  execution authority or acceptance. The operator's UI rechecks native source
  before recording; these records never grant permission to restore old edits.
  """
  # Read-only native-host observation; never an execution grant or validation receipt.
  def for_local_tests(id, revision, path, expected_world) do
    frame =
      Ampd.Projection.framed(nil, fn ->
        attempt = Ampd.Loci.development_attempts()[id]
        task = if attempt, do: Ampd.Loci.development_tasks()[attempt["task_ref"]]

        matched =
          attempt != nil and task != nil and
            attempt["revision"] == revision and
            attempt["status"] != "dismissed" and task["status"] not in ~w(cancelled completed) and
            Ampd.Worktree.matches_repository?(attempt["repository_ref"], path)

        %{"matched" => matched, "attempt" => if(matched, do: attempt, else: nil)}
      end)

    world = Enum.map(~w(world_incarnation world_generation projection_epoch), &frame[&1])
    if world == expected_world, do: frame, else: %{"matched" => false}
  end

  @fields ~w(client_ref task_ref task_revision source shared_draft proposed_text)
  @bodies ~w(shared_draft proposed_text)
  @source_fields ~w(schema scope basis_id head path disk_sha256 draft_sha256 draft_bytes unsaved result_sha256 result_bytes task_ref task_revision repository_ref world)
  def fields, do: @fields
  defp digest(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
  defp hash?(s), do: is_binary(s) and Regex.match?(~r/\A[0-9a-f]{64}\z/, s)

  defp text?(s, cap),
    do:
      is_binary(s) and String.valid?(s) and byte_size(s) <= cap and not String.contains?(s, <<0>>)

  defp nonempty?(s, cap), do: text?(s, cap) and String.trim(s) != ""

  defp refuse(code, message), do: refuse(code, message, %{})

  # `operator_detail` carries WHICH file and WHICH side failed. It never
  # carries file content: a refusal that quotes the bytes it refused would
  # disclose them back to a caller that may not read them.
  defp refuse(code, message, detail),
    do:
      {:refused,
       Ampd.Refusal.new(code,
         component: "development-attempt",
         requires_human: true,
         public_message: message,
         operator_detail: detail
       )}

  defp result_digest(nil, path), do: digest(JSON.encode!(["deleted-file@1", path]))
  defp result_digest(text, _), do: digest(text)
  defp result_size(nil), do: 0
  defp result_size(text), do: byte_size(text)

  defp source?(source, draft, proposed) when is_map(source) do
    path = source["path"]
    head = source["head"]

    Enum.sort(Map.keys(source)) == Enum.sort(@source_fields) and
      ((source["schema"] == "selected-file-basis@1" and is_binary(proposed)) or
         (source["schema"] == "selected-file-deletion-basis@1" and proposed == nil and
            hash?(source["disk_sha256"]))) and source["scope"] == "selected-file-only" and
      nonempty?(path, 1024) and not String.starts_with?(path, "/") and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", "..", ".git"])) and
      is_binary(head) and Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, head) and
      hash?(source["basis_id"]) and (source["disk_sha256"] == nil or hash?(source["disk_sha256"])) and
      is_boolean(source["unsaved"]) and source["draft_sha256"] == digest(draft) and
      source["result_sha256"] == result_digest(proposed, path) and
      source["draft_bytes"] === byte_size(draft) and
      source["result_bytes"] === result_size(proposed) and
      source["unsaved"] == (source["disk_sha256"] != source["draft_sha256"])
  end

  defp source?(_, _, _), do: false

  # No call back into the ordering coordinator from its receiving store.
  # Epoch is retained as observed context; the UI rechecks it before submission.
  defp current_world?([incarnation, generation, epoch]) do
    lineage = Ampd.World.lineage()

    incarnation == Ampd.World.incarnation_of(lineage) and generation == lineage["generation"] and
      nonempty?(epoch, 100)
  end

  defp current_world?(_), do: false

  def create(%{"schema" => "development-change-set-request@1"} = fields, s),
    do: create_set(fields, s)

  def create(fields, s) when is_map(fields) do
    # A record is STAGED or INLINE, exactly as a change-set member is. Staged,
    # the command's two body fields arrive as nil and are dropped here, so the
    # record is its source basis alone and every consumer — `member_content/1`,
    # the projection, the host's resolver, the downgrade — already reads it.
    # Inline is the older shape, still accepted and still bounded by its caps.
    fields = Map.reject(fields, fn {k, v} -> k in @bodies and v == nil end)
    task = s["development_tasks"][fields["task_ref"]]
    source = fields["source"]
    keys = Enum.sort(Map.keys(fields))

    old =
      Enum.find_value(s["development_attempts"], fn {_, a} ->
        if a["client_ref"] == fields["client_ref"], do: a
      end)

    fault =
      cond do
        keys not in [Enum.sort(@fields), Enum.sort(@fields -- @bodies)] or
          not nonempty?(fields["client_ref"], 100) or not is_map(source) ->
          {"attempt-fields-invalid", "The review material or its content identities are invalid.",
           %{}}

        true ->
          member_fault(Map.take(fields, ["source" | @bodies]))
      end

    cond do
      fault != nil ->
        {code, message, detail} = fault
        refuse(code, message, detail)

      old != nil ->
        if Map.take(old, @fields) == fields,
          do: {:ok, old, s},
          else:
            refuse(
              "attempt-request-conflict",
              "This request already identifies different review material."
            )

      # The plan must be open and the revision one it has had. Not the CURRENT
      # revision: a plan's title and criteria are immutable, so a note or a
      # status change between sharing a file and recording its review changes
      # nothing the review is judged against (ruled 2026-09-18; the equality
      # this replaces refused a real review as `attempt-task-stale` on 09-16).
      task == nil or task["status"] in ~w(cancelled completed) or
        not is_integer(fields["task_revision"]) or
          fields["task_revision"] > task["revision"] ->
        refuse("attempt-task-stale", "Reopen the current plan and prepare a fresh review.")

      source["task_ref"] != task["id"] or source["task_revision"] !== fields["task_revision"] or
          source["repository_ref"] != task["repository_ref"] ->
        refuse(
          "attempt-source-mismatch",
          "The source record belongs to a different plan or repository."
        )

      not current_world?(source["world"]) ->
        refuse("attempt-world-stale", "The runtime changed. Recheck the source before recording.")

      map_size(s["development_attempts"]) >= 50 ->
        refuse(
          "attempt-limit",
          "This world supports up to 50 review attempts. Existing records are preserved."
        )

      true ->
        seq = s["seq"] + 1
        id = "da_" <> String.pad_leading(Integer.to_string(seq), 4, "0")

        record =
          Map.merge(fields, %{
            "id" => id,
            "schema" => "development-review-attempt@1",
            "revision" => 1,
            "workspace_ref" => task["workspace_ref"],
            "bot_ref" => task["bot_ref"],
            "repository_ref" => task["repository_ref"],
            "plan_title" => task["title"],
            "criteria" => task["criteria"],
            "world_ref" => task["world_ref"],
            "status" => "recorded",
            "provenance" => "human-recorded-review-material",
            "history" => [
              event(
                1,
                "recorded",
                "Proposal recorded for review. No validation or acceptance is claimed."
              )
            ]
          })

        persist(record, Map.put(s, "seq", seq))
    end
  end

  def create(_, _), do: refuse("attempt-fields-invalid", "Review fields must be an object.")

  # A set may hold up to this many members. Higher than the four an inline set
  # allowed, because the limit is now what a person can actually read in one
  # review rather than what a frame could carry.
  @max_members 12

  def max_members, do: @max_members

  defp create_set(f, s) do
    task = s["development_tasks"][f["task_ref"]]
    files = if is_map(f["material"]), do: f["material"]["files"], else: nil
    keys = ~w(schema client_ref task_ref task_revision material)

    envelope? =
      Enum.sort(Map.keys(f)) == Enum.sort(keys) and nonempty?(f["client_ref"], 100) and
        is_map(f["material"]) and Map.keys(f["material"]) == ["files"] and is_list(files)

    old =
      Enum.find_value(s["development_attempts"], fn {_, a} ->
        if a["client_ref"] == f["client_ref"], do: a
      end)

    cond do
      not envelope? ->
        refuse(
          "attempt-fields-invalid",
          "A change set needs a client reference, a plan revision and a list of files."
        )

      # Four distinct answers where there was one boolean. A two-file set that
      # was too large used to be refused with a sentence about counting files,
      # and a person read it and counted their files.
      length(files) not in 2..@max_members ->
        refuse(
          "review-file-count",
          "A change set holds 2 to #{@max_members} files; this one has #{length(files)}.",
          %{"count" => length(files), "min" => 2, "max" => @max_members}
        )

      (bad = Enum.find_value(files, &member_fault/1)) != nil ->
        {code, message, detail} = bad
        refuse(code, message, detail)

      (total = set_bytes(files)) > set_limit() ->
        refuse(
          "review-set-too-large",
          "A change set carries at most #{set_limit()} bytes; this one carries #{total}.",
          %{"bytes" => total, "max" => set_limit()}
        )

      old != nil ->
        if old["schema"] == "development-review-set@1" and old["task_ref"] == f["task_ref"] and
             old["task_revision"] === f["task_revision"] and old["files"] == files,
           do: {:ok, old, s},
           else:
             refuse(
               "attempt-request-conflict",
               "This request already identifies different review material."
             )

      task == nil or task["status"] in ~w(cancelled completed) or
        not is_integer(f["task_revision"]) or f["task_revision"] > task["revision"] ->
        refuse("attempt-task-stale", "Reopen the current plan before recording this change set.")

      not coherent_set?(files, task, f["task_revision"]) ->
        refuse(
          "attempt-source-mismatch",
          "Every file must belong to the same current plan, repository, world and source commit, with a distinct path."
        )

      map_size(s["development_attempts"]) >= 50 ->
        refuse("attempt-limit", "This world supports up to 50 review attempts.")

      true ->
        first = hd(files)["source"]
        basis = Enum.map(files, fn row -> [row["source"]["path"], row["source"]["basis_id"]] end)

        result =
          Enum.map(files, fn row -> [row["source"]["path"], row["source"]["result_sha256"]] end)

        source =
          Map.take(first, ~w(head task_ref task_revision repository_ref world))
          |> Map.merge(%{
            "schema" => "selected-file-set-basis@1",
            "scope" => "selected-file-set-only",
            "basis_id" => digest(JSON.encode!(["selected-file-set-basis@1", basis])),
            "result_sha256" => digest(JSON.encode!(["selected-file-set-result@1", result]))
          })

        seq = s["seq"] + 1

        record = %{
          "id" => "da_" <> String.pad_leading(Integer.to_string(seq), 4, "0"),
          "schema" => "development-review-set@1",
          "client_ref" => f["client_ref"],
          "task_ref" => task["id"],
          "task_revision" => f["task_revision"],
          "revision" => 1,
          "workspace_ref" => task["workspace_ref"],
          "bot_ref" => task["bot_ref"],
          "repository_ref" => task["repository_ref"],
          "world_ref" => task["world_ref"],
          "plan_title" => task["title"],
          "criteria" => task["criteria"],
          "files" => files,
          "source" => source,
          "status" => "recorded",
          "provenance" => "human-recorded-review-material",
          "history" => [
            event(
              1,
              "recorded",
              "Combined review recorded. No files saved, tests run or result accepted."
            )
          ]
        }

        persist(record, Map.put(s, "seq", seq))
    end
  end

  # ------------------------------------------------------------ members
  #
  # A member is STAGED or INLINE.
  #
  #   staged   `%{"source" => …}` alone. Its content is already published in
  #            `Ampd.ReviewContent` under the digests its own source records:
  #            `draft_sha256` IS the current text's content address and
  #            `result_sha256` the proposed text's. A member therefore needs no
  #            second pair of fields to say where its content is, and the record
  #            cannot name one thing and carry another.
  #
  #   inline   `%{"source" =>, "shared_draft" =>, "proposed_text" =>}`, the
  #            shape recorded before staging existed. Still accepted, still
  #            validated exactly as before, still subject to the old byte caps —
  #            because those caps are the only thing bounding a member that
  #            carries its own bytes.
  #
  # `member_fault/1` returns `nil` for a good member and `{code, message,
  # detail}` for a bad one, so each way of being wrong is answered by its own
  # name instead of one boolean for all of them.

  @inline_draft 24_000
  @inline_proposed 32_000

  # How much review material one world may retain, in total.
  #
  # 64 KiB was too small to be usable: `Ampd.CommandSpec` admits a single
  # attempt of 24 000 + 32 000 bytes of file text, so one real review could
  # exceed the whole directory, and recording an 18 KB file against a
  # directory already holding 46 715 bytes was refused outright.
  #
  # It cannot simply be made large either. `Ampd.Frame` caps ONE frame at
  # 256 KiB and the whole projection travels as one frame; `encode!/1` turns
  # an oversized projection into a refusal, so the app goes blind rather than
  # stale. The bound, from the live world:
  #
  #     development_attempts   131 072   this cap
  #     development_tasks       65 536   its own cap, development_task.ex
  #     everything else         16 318   measured
  #     --------------------------------
  #     worst case             212 926   under the 262 144 frame cap
  #
  # About 49 KB of headroom. 160 KiB would leave about 22 KB and is too tight.
  # The 50-attempt count cap above still bounds how many records there can be.
  #
  # Since 2026-09-18 no body lives in a record: single-file reviews are
  # recorded by digest like change-set members, and `stage_inline/1` moves the
  # bodies of records written before that out as the world opens. Measured on
  # the live world the day it was ruled: the five inline records held 130 720
  # of the 131 072 bytes; their metadata alone is about 25 KB. So this cap now
  # bounds metadata, and is not the thing that decides how much can be reviewed.
  @directory_bytes 128 * 1024

  def set_limit, do: @max_members * Ampd.ReviewContent.file_bytes()

  defp staged?(row), do: is_map(row) and Map.keys(row) == ["source"]

  defp inline?(row),
    do: is_map(row) and Enum.sort(Map.keys(row)) == ~w(proposed_text shared_draft source)

  defp member_fault(row) when is_map(row) do
    cond do
      staged?(row) ->
        staged_fault(row["source"])

      inline?(row) ->
        inline_fault(row)

      true ->
        {"attempt-fields-invalid",
         "A file is neither a staged nor a complete inline replacement.", %{}}
    end
  end

  defp member_fault(_),
    do: {"attempt-fields-invalid", "A file must be an object.", %{}}

  defp staged_fault(source) when is_map(source) do
    path = source["path"]
    draft = source["draft_sha256"]
    proposed = source["result_sha256"]
    deletion? = source["schema"] == "selected-file-deletion-basis@1"
    # Bound before the cond: a size read inside a short-circuiting `and` is not
    # in scope in the branch that uses it.
    draft_size = Ampd.ReviewContent.size(draft) || 0
    proposed_size = Ampd.ReviewContent.size(proposed) || 0

    cond do
      not shape?(source) ->
        {"attempt-fields-invalid", "A staged file carries an incomplete source basis.",
         %{"path" => path}}

      Ampd.ReviewContent.status(draft) != :available ->
        unavailable(path, "current", draft)

      not deletion? and Ampd.ReviewContent.status(proposed) != :available ->
        unavailable(path, "proposed", proposed)

      draft_size > Ampd.ReviewContent.file_bytes() ->
        too_large(path, "current", draft_size)

      not deletion? and proposed_size > Ampd.ReviewContent.file_bytes() ->
        too_large(path, "proposed", proposed_size)

      # Sizes are re-derived from what is stored, never taken from the caller.
      source["draft_bytes"] !== draft_size ->
        {"review-content-invalid", "A staged file reports a size its content does not have.",
         %{"path" => path, "side" => "current"}}

      not deletion? and source["result_bytes"] !== proposed_size ->
        {"review-content-invalid", "A staged file reports a size its content does not have.",
         %{"path" => path, "side" => "proposed"}}

      not basis_bound?(source) ->
        {"review-content-invalid", "A staged file's basis does not bind its own content.",
         %{"path" => path}}

      true ->
        nil
    end
  end

  defp staged_fault(_),
    do: {"attempt-fields-invalid", "A staged file carries no source basis.", %{}}

  defp unavailable(path, side, digest) do
    state = Ampd.ReviewContent.status(digest)

    {"review-content-unavailable",
     "The #{side} content of #{path} is #{state}. Stage it again; nothing is accepted without it.",
     %{"path" => path, "side" => side, "digest" => digest, "state" => to_string(state)}}
  end

  defp too_large(path, side, bytes) do
    {"review-file-too-large",
     "#{path} is #{bytes} bytes; one file carries at most #{Ampd.ReviewContent.file_bytes()}.",
     %{"path" => path, "side" => side, "bytes" => bytes, "max" => Ampd.ReviewContent.file_bytes()}}
  end

  # Content is checked to be UTF-8 text at PUBLICATION, on the bytes already
  # being read to hash them, so nothing here reads a blob to find out. That
  # matters because every check in this module runs inside the ordered
  # transaction, where an unbounded read would block the world.

  # The same predicate the inline shape uses, minus the two body fields.
  defp shape?(source) do
    Enum.sort(Map.keys(source)) == Enum.sort(@source_fields) and
      source["schema"] in ~w(selected-file-basis@1 selected-file-deletion-basis@1) and
      source["scope"] == "selected-file-only" and
      nonempty?(source["path"], 1024) and not String.starts_with?(source["path"], "/") and
      Enum.all?(String.split(source["path"], "/"), &(&1 not in ["", ".", "..", ".git"])) and
      is_binary(source["head"]) and
      Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, source["head"]) and
      hash?(source["basis_id"]) and hash?(source["draft_sha256"]) and
      (source["disk_sha256"] == nil or hash?(source["disk_sha256"])) and
      is_boolean(source["unsaved"]) and
      source["unsaved"] == (source["disk_sha256"] != source["draft_sha256"])
  end

  defp basis_bound?(source),
    do:
      source["basis_id"] ==
        digest(
          JSON.encode!([
            "selected-file-basis@1",
            source["head"],
            source["path"],
            source["disk_sha256"],
            source["draft_sha256"]
          ])
        )

  defp inline_fault(row) do
    cond do
      not text?(row["shared_draft"], @inline_draft) ->
        too_large(row["source"]["path"], "current", byte_size(row["shared_draft"] || ""))

      row["proposed_text"] != nil and not text?(row["proposed_text"], @inline_proposed) ->
        too_large(row["source"]["path"], "proposed", byte_size(row["proposed_text"] || ""))

      not source?(row["source"], row["shared_draft"], row["proposed_text"]) ->
        {"review-content-invalid", "An inline file's content identities do not match its bytes.",
         %{"path" => row["source"]["path"]}}

      not basis_bound?(row["source"]) ->
        {"review-content-invalid", "An inline file's basis does not bind its own content.",
         %{"path" => row["source"]["path"]}}

      true ->
        nil
    end
  end

  # What the SET weighs, from what is stored rather than from what was said.
  defp set_bytes(files) do
    Enum.reduce(files, 0, fn row, acc ->
      acc +
        if staged?(row) do
          s = row["source"]

          (Ampd.ReviewContent.size(s["draft_sha256"]) || 0) +
            (Ampd.ReviewContent.size(s["result_sha256"]) || 0)
        else
          byte_size(row["shared_draft"] || "") + byte_size(row["proposed_text"] || "")
        end
    end)
  end

  @doc """
  The current and proposed text of one member, or why it cannot be read.

  The single place any consumer resolves a member's content, so an inline
  member and a staged one read the same to a caller — and so **there is one
  place that can return `:missing` or `:corrupt`**. It never falls back to other
  bytes: a member whose content is gone answers `{:error, state}` and the caller
  must refuse.
  """
  def member_content(%{"source" => source} = row) do
    cond do
      is_binary(row["shared_draft"]) ->
        {:ok, %{"current" => row["shared_draft"], "proposed" => row["proposed_text"]}}

      true ->
        deletion? = source["schema"] == "selected-file-deletion-basis@1"

        with {:ok, current} <- Ampd.ReviewContent.fetch(source["draft_sha256"]),
             {:ok, proposed} <- fetch_proposed(deletion?, source["result_sha256"]) do
          {:ok, %{"current" => current, "proposed" => proposed}}
        end
    end
  end

  def member_content(_), do: {:error, :missing}

  defp fetch_proposed(true, _), do: {:ok, nil}
  defp fetch_proposed(false, digest), do: Ampd.ReviewContent.fetch(digest)

  @doc """
  Whether every member of an attempt can still be read, and what is wrong.

  Bound at acceptance: a result may not be accepted against content that is
  missing or that no longer hashes to what was reviewed.
  """
  # Bounded on purpose: this runs inside the ordered transaction at test and
  # acceptance time, so it asks whether each blob is PRESENT rather than
  # re-hashing up to twelve four-megabyte files while the world waits. The full
  # verification happens in the host, in `resolve_review_bodies`, before any
  # runner sees a byte — so corrupt content fails the acceptance preflight and
  # never reaches an accepted result.
  def content_state(%{"files" => files}) when is_list(files) do
    faults = Enum.flat_map(files, &member_fault_state/1)
    if faults == [], do: :ok, else: {:error, faults}
  end

  def content_state(%{"source" => _} = a) do
    case member_fault_state(a) do
      [] -> :ok
      faults -> {:error, faults}
    end
  end

  def content_state(_), do: :ok

  defp member_fault_state(%{"source" => source} = row) when is_map(source) do
    if is_binary(row["shared_draft"]) do
      []
    else
      deletion? = source["schema"] == "selected-file-deletion-basis@1"

      [{"current", source["draft_sha256"]}]
      |> then(&if deletion?, do: &1, else: &1 ++ [{"proposed", source["result_sha256"]}])
      |> Enum.reject(fn {_, d} -> Ampd.ReviewContent.status(d) == :available end)
      |> Enum.map(fn {side, d} ->
        %{
          "path" => source["path"],
          "side" => side,
          "state" => to_string(Ampd.ReviewContent.status(d))
        }
      end)
    end
  end

  defp member_fault_state(_), do: []

  @doc """
  Rewrite inline members to name their content, for members whose content is
  already published.

  **Phase two of the migration.** Both phases run as the world opens, from
  `Ampd.Loci` through `stage_inline/1`, since 2026-09-18 — until then this was
  deliberately unwired, and the five inline records on the live world held
  130 KB of the directory's 128 KiB budget. Compatibility is what fixes the problem: inline bodies stopped reaching the
  projection the moment `Ampd.Projection` began publishing members without
  them, so an existing record already costs a frame nothing. What migrating
  buys is the space those bodies take in the `loci` authority store, which
  `Ampd.Store.save/2` rewrites whole on every unrelated mutation — a real cost,
  but a bounded one that only applies to records written before staging existed.

  It is a pure transform over the state so it can be tested, reviewed and
  wired later as its own proposal, through the mechanism this change adds.

  A member is rewritten **only** if both of its bodies are published and
  readable. Anything else is left exactly as it is: a half-migrated member
  would name content that is not there, which is the one state this whole
  design exists to make impossible.
  """
  def migrate_inline(%{"development_attempts" => attempts} = s) do
    migrated = Map.new(attempts, fn {id, a} -> {id, migrate_attempt(a)} end)

    moved =
      Enum.count(migrated, fn {id, a} -> a != attempts[id] end)

    {Map.put(s, "development_attempts", migrated), %{"migrated" => moved}}
  end

  @doc """
  Both phases, as the world opens: publish every inline body, then rewrite
  the members whose bodies are verifiably published.

  Safe to run on every open. Publication is addressed by bytes, so a body
  already published is a no-op; a member is rewritten only when both of its
  sides read back under their digests; anything the store refuses is left
  inline and named in the report. The record's meaning never changes — the
  same digests, the same basis — only where the bytes live. The inverse is
  `inline_from_content/1`, which `Ampd.Downgrade` runs for an older runtime.
  """
  def stage_inline(%{"development_attempts" => attempts} = s) when is_map(attempts) do
    published = Ampd.ReviewContent.absorb(attempts)
    {next, moved} = migrate_inline(s)
    {next, Map.merge(published, moved)}
  end

  def stage_inline(s),
    do: {s, %{"published" => 0, "bytes" => 0, "refused" => [], "migrated" => 0}}

  defp migrate_attempt(%{"files" => files} = a) when is_list(files),
    do: Map.put(a, "files", Enum.map(files, &migrate_member/1))

  defp migrate_attempt(%{"source" => _} = a), do: migrate_member(a)
  defp migrate_attempt(a), do: a

  defp migrate_member(%{"source" => source} = row) when is_map(source) do
    deletion? = source["schema"] == "selected-file-deletion-basis@1"

    both_there? =
      Ampd.ReviewContent.verify(source["draft_sha256"]) == :available and
        (deletion? or Ampd.ReviewContent.verify(source["result_sha256"]) == :available)

    if is_binary(row["shared_draft"]) and both_there?,
      do: Map.drop(row, ["shared_draft", "proposed_text"]),
      else: row
  end

  defp migrate_member(row), do: row

  @doc """
  Put the bodies back into staged members, so records survive a downgrade.

  **The inverse of `migrate_inline/1`, and the thing that makes a rollback a
  rollback.** Reverting the code alone does not undo a deployment: an older
  runtime publishes a staged record with no bodies and its UI, test runner and
  acceptance check all read `nil` where the reviewed text should be. The record
  is present and unusable, which is worse than either working or being absent.

  Performs filesystem I/O — it reads every referenced blob — so it is
  maintenance, run deliberately with the world quiet, never on a hot path.

  **A record is converted only if ALL of its members convert.** Two reasons a
  member cannot:

    * its content is missing or corrupt, so there is nothing to put back;
    * it is larger than the old inline caps (#{@inline_draft} current,
      #{@inline_proposed} proposed) — which is the case this whole change
      exists to make possible, so the files it was built for are exactly the
      ones a downgrade cannot represent.

  Both are reported per member rather than counted, because the operator has to
  decide what to do with each: a missing blob can be staged again, and an
  oversized one cannot be downgraded at all and has to be exported or kept.
  """
  def inline_from_content(%{"development_attempts" => attempts} = s) do
    {converted, blocked} =
      Enum.reduce(attempts, {%{}, []}, fn {id, a}, {acc, blocks} ->
        case convert_attempt(a) do
          {:ok, next} ->
            {Map.put(acc, id, next), blocks}

          {:blocked, why} ->
            {Map.put(acc, id, a), blocks ++ Enum.map(why, &Map.put(&1, "attempt", id))}
        end
      end)

    moved = Enum.count(converted, fn {id, a} -> a != attempts[id] end)

    {Map.put(s, "development_attempts", converted),
     %{"converted" => moved, "blocked" => blocked, "downgradable" => blocked == []}}
  end

  defp convert_attempt(%{"files" => files} = a) when is_list(files) do
    results = Enum.map(files, &convert_member/1)

    case Enum.flat_map(results, fn {_, why} -> why end) do
      [] -> {:ok, Map.put(a, "files", Enum.map(results, &elem(&1, 0)))}
      why -> {:blocked, why}
    end
  end

  defp convert_attempt(%{"source" => _} = a) do
    case convert_member(a) do
      {next, []} -> {:ok, next}
      {_, why} -> {:blocked, why}
    end
  end

  defp convert_attempt(a), do: {:ok, a}

  defp convert_member(%{"source" => source} = row) when is_map(source) do
    cond do
      is_binary(row["shared_draft"]) ->
        {row, []}

      true ->
        deletion? = source["schema"] == "selected-file-deletion-basis@1"
        current = Ampd.ReviewContent.fetch(source["draft_sha256"])

        proposed =
          if deletion?, do: {:ok, nil}, else: Ampd.ReviewContent.fetch(source["result_sha256"])

        case {current, proposed} do
          {{:ok, c}, {:ok, p}} ->
            over =
              cond do
                byte_size(c) > @inline_draft ->
                  [block(source, "current", byte_size(c), @inline_draft, "too-large")]

                p != nil and byte_size(p) > @inline_proposed ->
                  [block(source, "proposed", byte_size(p), @inline_proposed, "too-large")]

                true ->
                  []
              end

            if over == [],
              do: {Map.merge(row, %{"shared_draft" => c, "proposed_text" => p}), []},
              else: {row, over}

          {{:error, state}, _} ->
            {row, [block(source, "current", nil, nil, to_string(state))]}

          {_, {:error, state}} ->
            {row, [block(source, "proposed", nil, nil, to_string(state))]}
        end
    end
  end

  defp convert_member(row), do: {row, []}

  defp block(source, side, bytes, max, reason),
    do: %{
      "path" => source["path"],
      "side" => side,
      "bytes" => bytes,
      "max" => max,
      "reason" => reason
    }

  defp unavailable_message(faults) do
    listed =
      faults
      |> Enum.map(fn f -> "#{f["path"]} (#{f["state"]})" end)
      |> Enum.join(", ")

    "Review content is unavailable: #{listed}. Stage it again; nothing is tested or accepted without it."
  end

  defp coherent_set?(files, task, revision) do
    first = hd(files)["source"]
    paths = Enum.map(files, & &1["source"]["path"])

    length(Enum.uniq(paths)) == length(paths) and
      Enum.all?(files, fn row ->
        source = row["source"]

        source["task_ref"] == task["id"] and source["task_revision"] === revision and
          source["repository_ref"] == task["repository_ref"] and source["head"] == first["head"] and
          source["world"] == first["world"] and current_world?(source["world"])
      end)
  end

  # Fixed, non-executing checks derived here from immutable retained bytes.
  # This is not a Carrier validation receipt or a test of the current checkout.
  def update(id, operation, %{"development_attempts" => attempts} = s)
      when is_map_key(attempts, id) and is_map_key(:erlang.map_get(id, attempts), "files") and
             tuple_size(operation) > 0 and
             elem(operation, 0) in [:check_text] do
    _ = s

    refuse(
      "change-set-checks-unavailable",
      "Standalone text checks are not available for combined reviews. Run the selected test profile against the complete set."
    )
  end

  def update(id, {:begin_test, fields}, s) when is_map(fields) do
    a = s["development_attempts"][id]
    profile = Map.get(fields, "profile", "super-javascript-behavior@1")
    run_id = fields["run_id"]
    runs = if a, do: Map.get(a, "test_runs", %{}), else: %{}
    old = runs[run_id]
    task = if a, do: s["development_tasks"][a["task_ref"]]

    cond do
      Enum.sort(Map.keys(Map.delete(fields, "profile"))) !=
        Enum.sort(~w(run_id revision path world)) or
        profile not in ~w(super-javascript-behavior@1 super-elixir-review@1 super-rust-review@1 repository-document-review@1) or
          not nonempty?(run_id, 100) ->
        refuse("test-start-invalid", "Invalid test-start request.")

      not current_world?(fields["world"]) ->
        refuse("test-world-stale", "The runtime world changed.")

      a == nil ->
        refuse("attempt-unknown", "The saved review is unavailable.")

      old != nil ->
        if old["requested_revision"] === fields["revision"] and old["profile"] == profile,
          do: {:ok, a, s},
          else: refuse("test-start-conflict", "This run already belongs to a different request.")

      a["revision"] !== fields["revision"] or a["status"] in ["dismissed", "accepted"] or
        task == nil or task["status"] in ~w(cancelled completed) ->
        refuse("test-review-stale", "Reopen the latest plan and review before testing.")

      not is_binary(fields["path"]) or
          not Ampd.Worktree.matches_repository?(a["repository_ref"], fields["path"]) ->
        refuse("test-repository-mismatch", "Select this review's registered repository.")

      map_size(runs) >= 8 ->
        refuse("test-run-limit", "This review retains up to eight test runs.")

      # Same reason as acceptance: a test run against content that cannot be
      # read is a run against something other than the review.
      (content = content_state(a)) != :ok ->
        {:error, faults} = content
        refuse("review-content-unavailable", unavailable_message(faults), %{"files" => faults})

      true ->
        run = %{
          "schema" => "development-test-run@1",
          "run_id" => run_id,
          "attempt_ref" => id,
          "requested_revision" => fields["revision"],
          "state" => "started",
          "revision" => 1,
          "runtime_epoch" => Enum.at(fields["world"], 2),
          "profile" => profile,
          "provenance" => "native-host-reported-tests",
          "source_basis_id" => a["source"]["basis_id"],
          "result_sha256" => a["source"]["result_sha256"],
          "world" => Enum.take(fields["world"], 2),
          "started_at" => DateTime.to_iso8601(DateTime.utc_now())
        }

        persist(Map.put(a, "test_runs", Map.put(runs, run_id, run)), s)
    end
  end

  # The host bridge supplies the current coordinator epoch before entering the
  # ordered receiver. Never query that coordinator from inside this handler.
  def update(id, {:recover_tests, world}, s) do
    a = s["development_attempts"][id]

    cond do
      not current_world?(world) ->
        refuse("test-world-stale", "The runtime world changed.")

      a == nil ->
        refuse("attempt-unknown", "The saved review is unavailable.")

      true ->
        runs = Map.get(a, "test_runs", %{})

        recovered =
          Map.new(runs, fn {id, run} ->
            if run["state"] == "started" and is_binary(run["runtime_epoch"]) and
                 run["runtime_epoch"] != Enum.at(world, 2) do
              outcome = %{
                "state" => "failed",
                "verdict" => nil,
                "reason" => "interrupted",
                "source_basis_id" => run["source_basis_id"],
                "result_sha256" => run["result_sha256"],
                "snapshot_sha256" => nil,
                "node_sha256" => nil,
                "test_count" => 0,
                "output" =>
                  "The runtime restarted before a final outcome was confirmed. Tests were not rerun.",
                "output_omitted" => false
              }

              {id,
               run
               |> Map.put("state", "failed")
               |> Map.put("revision", 2)
               |> Map.put("finished_at", DateTime.to_iso8601(DateTime.utc_now()))
               |> Map.put("outcome", outcome)}
            else
              {id, run}
            end
          end)

        if recovered == runs,
          do: {:ok, a, s},
          else: persist(Map.put(a, "test_runs", recovered), s)
    end
  end

  def update(id, {:finish_test, run_id, world, outcome}, s) do
    a = s["development_attempts"][id]
    run = if a, do: Map.get(a, "test_runs", %{})[run_id]

    cond do
      not current_world?(world) ->
        refuse("test-world-stale", "The runtime world changed.")

      run == nil ->
        refuse("test-not-started", "No runtime start exists for this test run.")

      not test_outcome?(outcome, run) ->
        refuse(
          "test-outcome-invalid",
          "The outcome does not match the admitted review or supported test profile."
        )

      run["state"] != "started" ->
        if run["outcome"] == outcome,
          do: {:ok, a, s},
          else: refuse("test-outcome-conflict", "This run already has a different final outcome.")

      true ->
        final =
          run
          |> Map.put("revision", 2)
          |> Map.put("state", outcome["state"])
          |> Map.put("finished_at", DateTime.to_iso8601(DateTime.utc_now()))
          |> Map.put("outcome", outcome)

        persist(put_in(a, ["test_runs", run_id], final), s)
    end
  end

  def update(id, {:prepare_acceptance, f}, s) when is_map(f) do
    a = s["development_attempts"][id]
    run = if a, do: Map.get(a, "test_runs", %{})[f["run_id"]]

    cond do
      Enum.sort(Map.keys(f)) !=
          Enum.sort(~w(revision run_id path world snapshot_sha256 result_sha256 head)) ->
        refuse("acceptance-invalid", "Invalid acceptance check.")

      not current_world?(f["world"]) or not acceptance_ready?(a, run, f["revision"], s) ->
        refuse(
          "acceptance-stale",
          "Every profile run on this review needs its latest passing result on the same snapshot. Reopen the review and rerun missing coverage."
        )

      not is_binary(f["path"]) or
          not Ampd.Worktree.matches_repository?(a["repository_ref"], f["path"]) ->
        refuse("acceptance-repository", "Choose this review's registered repository.")

      f["snapshot_sha256"] != run["outcome"]["snapshot_sha256"] or
        f["result_sha256"] != a["source"]["result_sha256"] or f["head"] != a["source"]["head"] ->
        refuse("acceptance-content", "The current files do not match the tested result.")

      true ->
        check = %{
          "schema" => "native-acceptance-check@1",
          "token" => Base.encode16(:crypto.strong_rand_bytes(24), case: :lower),
          "revision" => f["revision"],
          "run_id" => f["run_id"],
          "world" => f["world"],
          "snapshot_sha256" => f["snapshot_sha256"],
          "result_sha256" => f["result_sha256"],
          "checked_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "expires_at" => System.system_time(:millisecond) + 15000
        }

        persist(Map.put(a, "acceptance_check", check), s)
    end
  end

  def update(id, {:accept, revision, token, note, world}, s) do
    a = s["development_attempts"][id]
    check = if a, do: a["acceptance_check"]
    run = if check, do: Map.get(a, "test_runs", %{})[check["run_id"]]

    cond do
      a != nil and a["acceptance"] != nil and a["acceptance"]["token"] == token and
        a["acceptance"]["requested_revision"] == revision and a["acceptance"]["note"] == note ->
        {:ok, a, s}

      not nonempty?(note, 1000) or not is_binary(token) ->
        refuse("acceptance-invalid", "Explain why this tested result meets the review criteria.")

      check == nil or check["token"] != token or check["revision"] != revision or
        check["world"] != world or not current_world?(world) or
          check["expires_at"] < System.system_time(:millisecond) ->
        refuse(
          "acceptance-check-stale",
          "The native file check is missing or expired. Try acceptance again."
        )

      not acceptance_ready?(a, run, revision, s) ->
        refuse(
          "acceptance-stale",
          "The plan, review or test profile coverage changed. Reopen the review."
        )

      # Acceptance is bound to the EXACT content that was reviewed. A member
      # whose bytes are gone, or whose bytes no longer hash to what the record
      # names, is not a result anyone can accept — and the alternative, reading
      # whatever is on disk now, would accept something nobody reviewed.
      (content = content_state(a)) != :ok ->
        {:error, faults} = content
        refuse("review-content-unavailable", unavailable_message(faults), %{"files" => faults})

      true ->
        decision = %{
          "schema" => "development-acceptance@1",
          "provenance" => "human-control-decision",
          "scope" => "captured-tested-result",
          "requested_revision" => revision,
          "token" => token,
          "note" => note,
          "run_id" => check["run_id"],
          "profile_run_refs" =>
            Map.new(
              latest_profile_runs(a),
              &{&1["profile"] || "super-javascript-behavior@1", &1["run_id"]}
            ),
          "snapshot_sha256" => check["snapshot_sha256"],
          "result_sha256" => check["result_sha256"],
          "source_basis_id" => a["source"]["basis_id"],
          "task_revision" => a["task_revision"],
          "native_checked_at" => check["checked_at"],
          "accepted_at" => DateTime.to_iso8601(DateTime.utc_now())
        }

        persist(
          a
          |> Map.delete("acceptance_check")
          |> Map.put("acceptance", decision)
          |> Map.put("status", "accepted")
          |> Map.put("revision", revision + 1)
          |> Map.update!("history", &(&1 ++ [event(revision + 1, "accepted", note)])),
          s
        )
    end
  end

  def update(id, {:check_text, revision}, s) do
    attempt = s["development_attempts"][id]

    cond do
      attempt == nil ->
        refuse("attempt-unknown", "This review attempt is unavailable.")

      not is_integer(revision) ->
        refuse("attempt-revision-stale", "Reopen the latest review.")

      attempt["text_check"] != nil and
          revision in [attempt["revision"], attempt["text_check"]["requested_revision"]] ->
        {:ok, attempt, s}

      revision !== attempt["revision"] ->
        refuse("attempt-revision-stale", "This review changed. Reopen it before checking.")

      attempt["status"] in ["dismissed", "accepted"] ->
        refuse("attempt-dismissed", "Dismissed reviews remain read-only history.")

      length(attempt["history"]) >= 32 ->
        refuse("attempt-history-full", "This review reached its 32-event limit.")

      # The proposed text is read through the one resolver, so a staged record
      # checks the bytes its digest names — bounded by the per-file cap — and
      # a record whose bytes are gone refuses by name rather than checking "".
      (content = member_content(attempt)) == {:error, :missing} or
          match?({:error, _}, content) ->
        {:error, state} = content

        refuse(
          "review-content-unavailable",
          "The proposed content of #{attempt["source"]["path"]} is #{state}. Stage it again; nothing is checked without it.",
          %{
            "path" => attempt["source"]["path"],
            "side" => "proposed",
            "state" => to_string(state)
          }
        )

      true ->
        {:ok, %{"proposed" => text}} = member_content(attempt)
        check = text_check(attempt, text) |> Map.put("requested_revision", revision)
        next = revision + 1

        persist(
          attempt
          |> Map.put("revision", next)
          |> Map.put("text_check", check)
          |> Map.update!(
            "history",
            &(&1 ++
                [
                  event(
                    next,
                    attempt["status"],
                    "Proposed-text checks: " <> check["outcome"] <> ". App tests were not run."
                  )
                ])
          ),
          s
        )
    end
  end

  def update(id, {revision, status, note}, s) do
    attempt = s["development_attempts"][id]

    cond do
      attempt == nil ->
        refuse("attempt-unknown", "This review attempt is unavailable.")

      not is_integer(revision) or revision !== attempt["revision"] ->
        if is_integer(revision) and attempt["revision"] == revision + 1 and
             attempt["status"] == status and List.last(attempt["history"])["note"] == note,
           do: {:ok, attempt, s},
           else:
             refuse(
               "attempt-revision-stale",
               "This review changed. Reopen its latest notes before updating."
             )

      status not in ~w(recorded needs_changes dismissed) or not nonempty?(note, 1000) ->
        refuse(
          "attempt-update-invalid",
          "Choose a review status and explain it. Acceptance uses the separate tested-result action."
        )

      attempt["status"] in ["dismissed", "accepted"] ->
        refuse(
          "attempt-dismissed",
          "Dismissed attempts remain read-only history. Record a new proposal to continue."
        )

      length(attempt["history"]) >= 32 ->
        refuse(
          "attempt-history-full",
          "This review reached its 32-note limit. Earlier notes are preserved."
        )

      true ->
        next = revision + 1

        persist(
          attempt
          |> Map.put("revision", next)
          |> Map.put("status", status)
          |> Map.update!("history", &(&1 ++ [event(next, status, note)])),
          s
        )
    end
  end

  def update(_, _, _), do: refuse("attempt-update-invalid", "Use a versioned review update.")

  defp latest_profile_runs(a) do
    a
    |> Map.get("test_runs", %{})
    |> Map.values()
    |> Enum.group_by(&(&1["profile"] || "super-javascript-behavior@1"))
    |> Enum.map(fn {_profile, runs} -> Enum.max_by(runs, &{&1["started_at"], &1["run_id"]}) end)
  end

  defp acceptance_ready?(a, run, revision, s) do
    task = if a, do: s["development_tasks"][a["task_ref"]]
    runs = if a, do: Map.values(Map.get(a, "test_runs", %{})), else: []
    latest = Enum.max_by(runs, &{&1["started_at"], &1["run_id"]}, fn -> nil end)

    a != nil and run != nil and task != nil and a["revision"] == revision and
      a["status"] not in ["dismissed", "accepted"] and length(a["history"]) < 32 and
      task["status"] not in ~w(cancelled completed) and
      latest == run and run["state"] == "completed" and run["outcome"]["verdict"] == "pass" and
      Enum.all?(get_in(task, ["required_checks", "profiles"]) || [], fn profile ->
        Enum.any?(
          latest_profile_runs(a),
          &((&1["profile"] || "super-javascript-behavior@1") == profile)
        )
      end) and
      Enum.all?(runs, &(&1["state"] != "started")) and
      Enum.all?(latest_profile_runs(a), fn other ->
        other["state"] == "completed" and other["outcome"]["verdict"] == "pass" and
          other["outcome"]["snapshot_sha256"] == run["outcome"]["snapshot_sha256"]
      end)
  end

  defp test_outcome?(o, run) when is_map(o) do
    fields =
      ~w(state verdict reason source_basis_id result_sha256 snapshot_sha256 node_sha256 test_count output output_omitted)

    identity =
      o["source_basis_id"] == run["source_basis_id"] and
        o["result_sha256"] == run["result_sha256"]

    shape =
      Enum.sort(Map.keys(Map.drop(o, ~w(profile toolchain_sha256)))) == Enum.sort(fields) and
        identity and
        Map.get(o, "profile", "super-javascript-behavior@1") == run["profile"] and
        (o["toolchain_sha256"] == nil or hash?(o["toolchain_sha256"])) and
        text?(o["output"], 1024) and
        is_boolean(o["output_omitted"]) and is_integer(o["test_count"]) and
        o["test_count"] in 0..64 and
        (o["snapshot_sha256"] == nil or hash?(o["snapshot_sha256"])) and
        (o["node_sha256"] == nil or hash?(o["node_sha256"]))

    terminal =
      (o["state"] == "completed" and o["verdict"] in ~w(pass fail) and o["reason"] == nil and
         hash?(o["snapshot_sha256"]) and hash?(o["node_sha256"]) and o["test_count"] > 0 and
         (run["profile"] not in ~w(super-elixir-review@1 super-rust-review@1) or
            hash?(o["toolchain_sha256"]))) or
        (o["state"] == "failed" and o["verdict"] == nil and
           o["reason"] in ~w(cancelled timeout launcher-unavailable terminated runner-did-not-complete snapshot-changed runner-error interrupted))

    with true <- shape and terminal,
         {:ok, bytes} <- Ampd.Frame.encode(o),
         true <- byte_size(bytes) <= 4096,
         do: true,
         else: (_ -> false)
  end

  defp test_outcome?(_, _), do: false

  defp text_check(attempt, text) when is_binary(text) do
    lines = String.split(text, "\n")

    checks = [
      line_check(
        "conflict-markers",
        "Conflict markers",
        lines,
        &Regex.match?(~r/\A(?:<{7}|={7}|>{7}|\|{7})(?:\s|\z)/, &1)
      ),
      line_check(
        "trailing-whitespace",
        "Trailing spaces or tabs",
        lines,
        &Regex.match?(~r/[ \t]+\r?\z/, &1)
      )
    ]

    json =
      if String.downcase(Path.extname(attempt["source"]["path"])) == ".json" do
        case JSON.decode(text) do
          {:ok, _} ->
            %{
              "id" => "json-syntax",
              "label" => "JSON syntax",
              "outcome" => "pass",
              "message" => "Valid JSON."
            }

          {:error, _} ->
            %{
              "id" => "json-syntax",
              "label" => "JSON syntax",
              "outcome" => "fail",
              "message" => "Invalid JSON. Review the proposed text."
            }
        end
      else
        %{
          "id" => "json-syntax",
          "label" => "JSON syntax",
          "outcome" => "not_applicable",
          "message" => "Only .json files are checked for syntax."
        }
      end

    checks = checks ++ [json]

    %{
      "schema" => "proposed-text-check@1",
      "scope" => "retained-proposed-text-only",
      "provenance" => "runtime-derived-text-check",
      "result_sha256" => digest(text),
      "result_bytes" => byte_size(text),
      "path" => attempt["source"]["path"],
      "at" => DateTime.to_iso8601(DateTime.utc_now()),
      "checks" => checks,
      "outcome" => if(Enum.any?(checks, &(&1["outcome"] == "fail")), do: "fail", else: "pass")
    }
  end

  defp line_check(id, label, lines, predicate) do
    matches = lines |> Enum.with_index(1) |> Enum.filter(fn {line, _} -> predicate.(line) end)

    %{
      "id" => id,
      "label" => label,
      "outcome" => if(matches == [], do: "pass", else: "fail"),
      "count" => length(matches),
      "lines" => matches |> Enum.take(20) |> Enum.map(&elem(&1, 1)),
      "message" =>
        if(matches == [],
          do: "No findings.",
          else: "Review the listed lines; up to 20 are shown."
        )
    }
  end

  defp event(revision, status, note),
    do: %{
      "revision" => revision,
      "status" => status,
      "note" => note,
      "at" => DateTime.to_iso8601(DateTime.utc_now())
    }

  defp persist(record, s) do
    attempts = Map.put(s["development_attempts"], record["id"], record)

    # Reserve a bounded final outcome for every admitted, unfinished run.
    reserved =
      attempts
      |> Map.values()
      |> Enum.flat_map(&(Map.get(&1, "test_runs", %{}) |> Map.values()))
      |> Enum.count(&(&1["state"] == "started"))
      |> Kernel.*(4608)

    # Bound serialized bytes too: control characters can expand in JSON frames.
    with {:ok, _} <- Ampd.Frame.logical_size(attempts, @directory_bytes),
         {:ok, encoded} <- Ampd.Frame.encode(attempts),
         true <- byte_size(encoded) + reserved <= @directory_bytes do
      {:ok, record, Map.put(s, "development_attempts", attempts)}
    else
      _ ->
        refuse(
          "attempt-directory-full",
          "Review material exceeds this world's #{div(@directory_bytes, 1024)} KB limit. Existing records are preserved."
        )
    end
  end
end
