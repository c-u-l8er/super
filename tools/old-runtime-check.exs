# old-runtime-check — run UNDER THE OLDER RUNTIME against a converted world, and
# say whether its reviews are readable and usable there.
#
#   cd <old-checkout>/ampd && MIX_ENV=test AMPD_DATA_DIR=<converted-world> \
#     mix run <this-checkout>/tools/old-runtime-check.exs
#
# Uses nothing the old runtime does not have. Four checks, each a fail-stop:
#
#   1. the world opens with no seal;
#   2. every member of every attempt carries its bodies, and the projection —
#      which the old runtime publishes WHOLE, bodies included — encodes in a
#      frame;
#   3. usable: the old runtime's own text check runs over the bodies and
#      records its outcome;
#   4. admitted: the converted members, re-submitted as a new change set, pass
#      the old runtime's own set_file?/1 — the predicate this conversion targets.
#
# Run it against the UNCONVERTED copy too: it must fail at 2, which is GPT's
# premise ("an old runtime reads nil") made observable rather than assumed.
alias Ampd.{Control, Frame, Loci, Projection}

fail = fn msg ->
  IO.puts(:stderr, "FAIL #{msg}")
  System.halt(1)
end

held = fn msg -> IO.puts("held  #{msg}") end

# 1 --------------------------------------------------------------------
sealed = Ampd.seals() |> Enum.reject(fn {_, s} -> s == nil end)
if sealed != [], do: fail.("the world opened sealed: #{inspect(sealed)}")
held.("the world opens under the old runtime with no seal (#{Ampd.Store.data_dir()})")

# 2 --------------------------------------------------------------------
attempts = Loci.development_attempts()
if map_size(attempts) == 0, do: fail.("no development attempts in this world")

members =
  for {id, a} <- attempts, m <- List.wrap(a["files"] || a), do: {id, m}

for {id, m} <- members do
  path = get_in(m, ["source", "path"]) || "?"
  is_binary(m["shared_draft"]) || fail.("#{id} #{path}: no current body — the old runtime reads nil here")

  m["proposed_text"] == nil or is_binary(m["proposed_text"]) ||
    fail.("#{id} #{path}: proposed body is #{inspect(m["proposed_text"])}")

  keys = Enum.sort(Map.keys(m))

  (Map.has_key?(m, "files") or keys == ~w(proposed_text shared_draft source) or
     Map.has_key?(m, "id")) ||
    fail.("#{id} #{path}: keys #{inspect(keys)} are not the old member shape")
end

held.("every member carries its bodies (#{length(members)} members in #{map_size(attempts)} attempts)")

frame = Projection.operator()
published = frame["development_attempts"] || %{}
if map_size(published) != map_size(attempts), do: fail.("projection publishes #{map_size(published)} of #{map_size(attempts)} attempts")

for {id, a} <- published, m <- List.wrap(a["files"] || a) do
  is_binary(m["shared_draft"]) || fail.("#{id}: the projection carries no body for #{get_in(m, ["source", "path"])}")
end

case Frame.encode(frame) do
  {:ok, bytes} -> held.("the whole projection encodes in #{byte_size(bytes)} bytes (max #{Frame.max_bytes()}), bodies included")
  {:error, code, d} -> fail.("projection does not encode: #{code} #{inspect(d)}")
end

{human, _} = Ampd.attach_pair("old-runtime-check")
sets = for {id, %{"files" => files} = a} <- attempts, a["status"] == "recorded", do: {id, files, a}
if sets == [], do: fail.("no recorded change set to exercise")

# 3 --------------------------------------------------------------------
# Usable, in the old runtime's own terms: a change set is tested and accepted
# through its test-run and acceptance records (its standalone text check is
# refused for sets by policy — `change-set-checks-unavailable`), and a
# single-file attempt through the text check, which reads the bodies.
alias Ampd.Authority

hash = fn s -> :crypto.hash(:sha256, s) |> Base.encode16(case: :lower) end

world_ref =
  Enum.map(~w(world_incarnation world_generation projection_epoch), &Projection.continuity()[&1])

refused? = fn
  {:refused, _} -> true
  r when is_map(r) -> Map.has_key?(r, "code") or r["allow"] == false
  _ -> false
end

accepted =
  for {id, files, a} <- sets do
    repo_path = Ampd.Worktree.repo(a["repository_ref"])["path"]
    run_id = "old-runtime-#{id}"
    start = %{"run_id" => run_id, "revision" => a["revision"], "path" => repo_path, "world" => world_ref}

    admitted = Authority.begin_development_test(id, start)
    if refused?.(admitted), do: fail.("#{id}: begin_test refused: #{inspect(admitted)}")
    run = admitted["test_runs"][run_id]
    run["state"] == "started" || fail.("#{id}: run not started: #{inspect(run)}")

    outcome = %{
      "state" => "completed",
      "verdict" => "pass",
      "reason" => nil,
      "source_basis_id" => run["source_basis_id"],
      "result_sha256" => run["result_sha256"],
      "snapshot_sha256" => hash.("snapshot"),
      "node_sha256" => hash.("node"),
      "test_count" => length(files),
      "output" => "#{length(files)} converted members ran under the old runtime",
      "output_omitted" => false
    }

    finished = Authority.finish_development_test(id, run_id, world_ref, outcome)
    if refused?.(finished), do: fail.("#{id}: finish_test refused: #{inspect(finished)}")
    finished["test_runs"][run_id]["state"] == "completed" || fail.("#{id}: run did not complete")

    prepared =
      Authority.prepare_development_acceptance(id, %{
        "revision" => finished["revision"],
        "run_id" => run_id,
        "path" => repo_path,
        "world" => world_ref,
        "snapshot_sha256" => hash.("snapshot"),
        "result_sha256" => get_in(a, ["source", "result_sha256"]),
        "head" => get_in(a, ["source", "head"])
      })

    if refused?.(prepared), do: fail.("#{id}: prepare_acceptance refused: #{inspect(prepared)}")
    token = prepared["acceptance_check"]["token"]

    done =
      Authority.accept_development_attempt(
        id,
        prepared["revision"],
        token,
        "Accepted under the old runtime, after the downgrade conversion.",
        world_ref
      )

    if refused?.(done), do: fail.("#{id}: accept refused: #{inspect(done)}")
    done["status"] == "accepted" || fail.("#{id}: status #{done["status"]} after accept")
    held.("#{id}: begin_test → finish_test(pass) → prepare_acceptance → accept under the old runtime; status #{done["status"]}")
    id
  end

singles = for {id, a} <- attempts, not Map.has_key?(a, "files"), a["status"] == "recorded", do: {id, a}

checked =
  for {id, a} <- singles do
    case Control.command(human, :check_development_attempt_text, [id, a["revision"]]) do
      %{"allow" => true, "development_attempt" => next} ->
        held.("#{id}: the old runtime's text check read the single-file bodies → status #{next["status"]}, revision #{next["revision"]}")
        id

      other ->
        fail.("text check refused for single #{id}: #{inspect(other["refusal"] || other)}")
    end
  end

# 4 last: it records a whole copy of a set's bodies into the same 64 KiB the
# old runtime budgets for everything above. Smallest set first, so what is
# proved is admission, not headroom. --------------------------------------
sets = for {id, %{"files" => files} = a} <- attempts, a["status"] == "recorded", do: {id, files, a}
if sets == [], do: fail.("no recorded change set to re-admit")
{one_id, files, one} =
  Enum.min_by(sets, fn {_, files, _} ->
    Enum.sum(Enum.map(files, &(byte_size(&1["shared_draft"]) + byte_size(&1["proposed_text"] || ""))))
  end)
task = Loci.development_tasks()[one["task_ref"]] || fail.("task #{one["task_ref"]} is gone")

readmit =
  Control.command(human, :record_development_change_set, [
    "old-runtime-readmit",
    task["id"],
    task["revision"],
    %{"files" => Enum.map(files, &Map.take(&1, ~w(source shared_draft proposed_text)))}
  ])

case readmit do
  %{"allow" => true, "development_attempt" => r} ->
    held.("the old runtime admits the converted members of #{one_id} through its own set_file?/1 (new record #{r["id"]})")

  other ->
    fail.("the old runtime refused the converted members of #{one_id}: #{inspect(other["refusal"] || other)}")
end

budget = 64 * 1024
{:ok, encoded} = Frame.encode(Loci.development_attempts())
headroom = budget - byte_size(encoded)
held.("the old runtime's directory now holds #{byte_size(encoded)} of #{budget} bytes (#{headroom} headroom) after everything this check recorded")

IO.puts(
  JSON.encode!(%{
    "old_runtime_world" => Ampd.Store.data_dir(),
    "attempts" => map_size(attempts),
    "members" => length(members),
    "readmitted" => one_id,
    "accepted" => accepted,
    "text_checked" => checked,
    "old_directory_bytes" => byte_size(encoded),
    "old_directory_headroom" => headroom
  })
)
