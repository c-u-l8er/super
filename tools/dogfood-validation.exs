# dogfood-validation — Super names one bounded validation job over ITS OWN
# SOURCE, and durably records that it started and how it ended.
#
# R0b.R's success criterion, executed rather than described. Nothing here
# runs the predicate: R0b.1 does that. What runs here is the whole chain
# that has to exist BEFORE a predicate has anywhere honest to land.
#
#     repository → Lane → Worker → worktree → SourceBasis
#                → scope manifest → JobBasis → STARTED → OUTCOME
#
# The scope digest is the REAL one, derived by `tools/scope-manifest.mjs`
# over the materialization Super itself established — not a fixture, not a
# constant. That is the difference between a demonstration and a shape.
#
#     cd ampd && mix run ../tools/dogfood-validation.exs
alias Ampd.{Authority, Control, Locus, Projection, Validation, Worktree}

root = Path.expand("..", File.cwd!())
say = fn s -> IO.puts("  " <> s) end
IO.puts("\ndogfood-validation — Super validates its own source\n")

Ampd.reset()
Ampd.Bridge.reset()
Ampd.Peer.reset()
Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Effector.Host)
Process.sleep(150)

Authority.install_worktree()
{:ok, repo} = Authority.register_repository(root)
say.("repository        #{repo["ref"]}  ← #{root}")

{control, agent} = Ampd.attach_pair("kestrel")
ws = Control.command(control, :open_workspace, ["super"])["workspace"]
goal = Control.command(control, :open_goal, [ws["id"], "validate my own source"])["goal"]
lane = Control.command(control, :open_lane, [goal["id"], "kestrel", repo["ref"], nil])["lane"]
worker = Control.command(control, :open_worker, [lane["id"], "implement"])["worker"]
Control.command(agent, :attach_worker, [worker["id"]])

Authority.mint(%{
  "capability" => Locus.create_capability(),
  "resource" => lane["id"],
  "actor" => "kestrel",
  "duration" => "workspace"
})

est = Control.command(agent, :establish_worktree, [lane["id"], "self-hygiene"])

unless est["allow"] do
  IO.puts("  establishment refused: #{inspect(est["refusal"])}")
  System.halt(1)
end

res = est["resource"]
say.("worktree          #{res["ref"]}  @ #{String.slice(res["head"], 0, 12)}")

{:ok, basis} = Authority.bind_source_basis(%{"resource_ref" => res["ref"]})
say.("source basis      #{basis["ref"]}  commit #{String.slice(basis["commit_oid"], 0, 12)}")

# The materialization path is operator-facing and is deliberately NOT put on
# any record below. It is used here, once, to derive the digest — and then
# only the digest travels.
path = Worktree.resource(res["ref"])["path"]

{out, 0} =
  System.cmd("node", [Path.join(root, "tools/scope-manifest.mjs"), path],
    cd: root, stderr_to_stdout: true)

[digest] = Regex.run(~r/scope_digest ([0-9a-f]{64})/, out, capture: :all_but_first)
[count] = Regex.run(~r/scope manifest: (\d+) file/, out, capture: :all_but_first)
say.("scope manifest    #{count} files · #{String.slice(digest, 0, 16)}…")

{:ok, %{"job" => job, "started" => started}} =
  Authority.start_validation_job(%{
    "validation_kind" => "source-hygiene",
    "source_basis_ref" => basis["ref"],
    "worker_ref" => worker["id"],
    "scope_digest" => digest
  })

say.("job               #{job["ref"]}  #{job["validation_kind"]}")
say.("STARTED           #{started["id"]} · seq #{started["seq"]} · #{started["kind"]}")
say.("admissible?       #{Validation.admissible?(job["ref"])}   ← a durable start exists")

# The predicate is not run here. But the canonical checker exists, so the
# verdict this job WOULD carry is derived the honest way — by asking it —
# and then recorded as an outcome exactly as R0b.1's Carrier will.
{hy_out, hy_rc} =
  System.cmd("node", [Path.join(root, "tools/check-source-hygiene.mjs"), path],
    cd: root, stderr_to_stdout: true)

verdict = if hy_rc == 0, do: "pass", else: "fail"
say.("predicate         canonical checker says #{verdict} — #{String.trim(List.last(String.split(hy_out, "\n", trim: true)))}")

{:ok, outcome} =
  Authority.record_validation_outcome(job["ref"], %{"state" => "completed", "verdict" => verdict})

say.("OUTCOME           #{outcome["id"]} · seq #{outcome["seq"]} · #{outcome["state"]} · #{outcome["verdict"]}")
say.("admissible?       #{Validation.admissible?(job["ref"])}   ← decided, not awaiting execution")

IO.puts("")
IO.puts("  the ledger, by surface:")
op = Projection.operator()
mine = Projection.agent("kestrel")

for {label, w} <- [
      {"validations   (operator)", op["validations"]},
      {"validations   (kestrel) ", mine["validations"]},
      {"validations   (mallory) ", Projection.agent("mallory")["validations"]},
      {"receipts      (operator)", op["receipts"]},
      {"worktree      (operator)", op["worktree_receipts"]}
    ] do
  kinds = w["recent"] |> Enum.map(& &1["kind"]) |> Enum.uniq() |> Enum.join(", ")
  IO.puts("    #{label}  total #{String.pad_leading(to_string(w["total"]), 2)}  #{kinds}")
end

IO.puts("")
IO.puts("  no host path anywhere in the validation records:")

for r <- [job, started, outcome], {k, v} <- r, is_binary(v), String.starts_with?(v, "/") do
  IO.puts("    LEAK  #{k} = #{v}")
end

IO.puts("    (none)")
IO.puts("")
