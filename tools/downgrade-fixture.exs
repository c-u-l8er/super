# downgrade-fixture — build a DISPOSABLE world holding staged review content,
# with the current runtime, so the downgrade can be exercised against a world
# a runtime actually wrote rather than a state a test assembled.
#
#   cd ampd && MIX_ENV=test AMPD_DATA_DIR=<empty-dir> \
#     mix run ../tools/downgrade-fixture.exs <repo-dir> [--big]
#
# MIX_ENV=test selects the reference worktree effector (a lane needs one, and
# a test run has no host serving the possession channel); AMPD_DATA_DIR wins
# over the test config's per-pid scratch, so the world lands where you said.
# The repository is created at <repo-dir> and must outlive the world: the old
# runtime resolves the lane's repository at boot.
#
# Records: two staged sets that fit the old caps, one inline set, and with
# --big one staged set carrying a member over the old per-file cap — the case
# this feature exists for and the one a downgrade cannot represent.
alias Ampd.{Authority, Control, Loci, Projection, ReviewContent}

{opts, [repo], _} = OptionParser.parse(System.argv(), strict: [big: :boolean])
world = Ampd.Store.data_dir()

hash = fn s -> :crypto.hash(:sha256, s) |> Base.encode16(case: :lower) end
head = String.duplicate("a", 40)

publish! = fn text ->
  d = hash.(text)
  chunk = ReviewContent.chunk_bytes()
  parts = max(div(byte_size(text) - 1, chunk) + 1, 1)

  for i <- 0..(parts - 1) do
    slice = binary_part(text, i * chunk, min(chunk, byte_size(text) - i * chunk))
    {:ok, _} = ReviewContent.put(d, i * chunk, slice, i == parts - 1)
  end

  d
end

{human, _agent} = Ampd.attach_pair("fixture")
%{"workspace" => ws} = Control.command(human, :open_workspace, ["Super"])
%{"goal" => goal} = Control.command(human, :open_goal, [ws["id"], "Survive a downgrade"])

bot =
  Authority.register_bot(%{
    "client_ref" => "builder",
    "workspace_ref" => ws["id"],
    "name" => "Builder",
    "role" => "Developer",
    "group" => "Super",
    "instructions" => "Reviewable work",
    "provider" => "ollama"
  })

File.mkdir_p!(repo)
{_, 0} = System.cmd("git", ["init", "--quiet", repo])
{:ok, registered} = Authority.register_repository(repo)

%{"lane" => lane} =
  Control.command(human, :open_lane, [goal["id"], bot["actor"], registered["ref"], "HEAD"])

task =
  Authority.create_development_task(%{
    "client_ref" => "plan-one",
    "lane_ref" => lane["id"],
    "title" => "Survive a downgrade",
    "criteria" => "The old runtime opens the converted world."
  })

world_ref =
  Enum.map(~w(world_incarnation world_generation projection_epoch), &Projection.continuity()[&1])

source = fn path, draft, proposed ->
  %{
    "schema" => "selected-file-basis@1",
    "scope" => "selected-file-only",
    "basis_id" =>
      hash.(JSON.encode!(["selected-file-basis@1", head, path, hash.(draft), hash.(draft)])),
    "head" => head,
    "path" => path,
    "disk_sha256" => hash.(draft),
    "draft_sha256" => hash.(draft),
    "draft_bytes" => byte_size(draft),
    "unsaved" => false,
    "result_sha256" => hash.(proposed),
    "result_bytes" => byte_size(proposed),
    "task_ref" => task["id"],
    "task_revision" => task["revision"],
    "repository_ref" => task["repository_ref"],
    "world" => world_ref
  }
end

staged = fn path, draft, proposed ->
  publish!.(draft)
  publish!.(proposed)
  %{"source" => source.(path, draft, proposed)}
end

inline = fn path, draft, proposed ->
  %{"source" => source.(path, draft, proposed), "shared_draft" => draft, "proposed_text" => proposed}
end

record! = fn files, ref ->
  case Control.command(human, :record_development_change_set, [
         ref,
         task["id"],
         task["revision"],
         %{"files" => files}
       ]) do
    %{"allow" => true, "development_attempt" => a} -> a
    other -> raise "record #{ref} refused: #{inspect(other)}"
  end
end

body = fn tag, n -> String.duplicate("#{tag}\n", n) end

sets = [
  {"staged-1",
   record!.(
     [
       staged.("lib/alpha.ex", body.("alpha before", 400), body.("alpha after", 420)),
       staged.("lib/beta.ex", body.("beta before", 300), body.("beta after", 310))
     ],
     "staged-1"
   )},
  {"staged-2",
   record!.(
     [
       staged.("ui/gamma.js", body.("gamma before", 200), body.("gamma after", 210)),
       staged.("ui/delta.js", body.("delta before", 100), body.("delta after", 120)),
       staged.("ui/epsilon.css", body.("epsilon before", 50), body.("epsilon after", 60))
     ],
     "staged-2"
   )},
  {"inline-1",
   record!.(
     [
       inline.("docs/one.md", "one before\n", "one after\n"),
       inline.("docs/two.md", "two before\n", "two after\n")
     ],
     "inline-1"
   )}
]

sets =
  if opts[:big] do
    big = String.duplicate("a line the old cap cannot hold\n", 1_000)

    sets ++
      [
        {"staged-big",
         record!.(
           [staged.("cockpit/ui/big.js", big, big <> "// proposed\n"), staged.("ui/small.js", "s\n", "t\n")],
           "staged-big"
         )}
      ]
  else
    sets
  end

single =
  case Control.command(human, :record_development_attempt, [
         "single-1",
         task["id"],
         task["revision"],
         source.("docs/single.md", "single before\n", "single after\n"),
         "single before\n",
         "single after\n"
       ]) do
    %{"allow" => true, "development_attempt" => a} -> a
    other -> raise "record single-1 refused: #{inspect(other)}"
  end

sets = sets ++ [{"single-1", Map.put(single, "files", [single])}]

summary = %{
  "world" => world,
  "repository" => repo,
  "task" => task["id"],
  "task_revision" => task["revision"],
  "attempts" =>
    Map.new(sets, fn {ref, a} ->
      {ref, %{"id" => a["id"], "revision" => a["revision"], "files" => length(a["files"])}}
    end),
  "attempt_count" => map_size(Loci.development_attempts())
}

IO.puts(JSON.encode!(summary))
