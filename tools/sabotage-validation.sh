#!/usr/bin/env bash
# sabotage-validation — R0b.R's falsifiers, falsified.
#
# R13's rule, stated plainly: **do not count a green functional test as
# proof until stubbing the mechanism makes the intended row red.** A suite
# that stays green when its subject is removed is measuring something else,
# and this tree has a measured scar for that — `sabotage-counts.sh` found a
# gate that had never refused anything at all.
#
# So each case here removes exactly ONE mechanism from a COPY of the tree,
# runs the R7 suite against the copy, and requires a NAMED test to fail. A
# case that merely makes the suite red somewhere is not a catch: a stub that
# breaks compilation would otherwise score as evidence for every row at once.
#
#     bash tools/sabotage-validation.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

CAUGHT=0; NOT=0; BROKE=0; UNAPPLIED=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The copy carries `ampd/_build` (2.8 MB) and `host/target` (24 MB)
# deliberately — a rebuild per case would dominate the runtime, and the Rust
# host is not what is being sabotaged.
#
# **`cockpit/target` is excluded and that is not an optimisation.** It is
# 1.1 GB, `$WORK` is under `/tmp`, and `/tmp` on this machine is a 16 GB
# tmpfs that runs chronically near full. MASTER plus one live copy would be
# 2.2 GB of it, per case, for a binary no case touches — and a tmpfs that
# fills does not fail this harness cleanly, it fails everything on the box.
# The cockpit is not sabotaged here and the ExUnit suite does not need it.
#
# `priv/data` goes too: it is a world, not source, and a stale one copied 22
# times is 22 chances to measure the wrong ledger.
MASTER="$WORK/master"; mkdir -p "$MASTER"
tar -cf - --exclude=./ampd/.elixir_ls --exclude='./*.zip' \
          --exclude=./ampd/erl_crash.dump --exclude=./old_scrap \
          --exclude=./cockpit/target --exclude=./ampd/priv/data . \
  | tar -xf - -C "$MASTER"

fresh () { rm -rf "$WORK/t"; cp -a "$MASTER" "$WORK/t"; T="$WORK/t"; }

# **The data dir is one fixed absolute path for every checkout on this
# machine** (`config/config.exs` sets `/tmp/ampd-test-data` and `rm -rf`s it
# at config load). Two suites running at once therefore delete each other's
# world mid-run, and the failures that produces look like ordinary red rows.
# Each case gets its own directory so a case cannot be scored against
# another case's wreckage.
run_suite () {                        # run_suite <dir> → stdout of the suite
  ( cd "$1/ampd" && AMPD_DATA_DIR="$WORK/data-$$-$RANDOM" \
      mix test test/validation_job_test.exs 2>&1 )
}

# case_ <label> <want-failure-text> <file> <old-substring> <new-substring>
#
# **The edit is proven, not assumed.** The first version of this harness
# embedded Python in the shell string and the quoting did not survive; every
# stub silently failed to apply, the suite stayed green, and eighteen cases
# were scored NOT A FALSIFIER. A harness that cannot tell "the mechanism was
# removed and nothing noticed" from "the mechanism was never removed" is
# reporting the wrong verdict with total confidence — which is the same
# defect it exists to find. So the substitution is exact, and a miss is
# `UNAPPLIED`, never a verdict about the suite.
case_ () {
  local label="$1" want="$2" file="$3" old="$4" new="$5"
  fresh
  if ! OLD="$old" NEW="$new" python3 -c '
import os, sys
p = sys.argv[1]
s = open(p).read()
old, new = os.environ["OLD"], os.environ["NEW"]
if old not in s:
    sys.exit(3)
open(p, "w").write(s.replace(old, new, 1))
' "$T/$file"; then
    printf '  \033[35mUNAPPLIED\033[0m  %s\n' "$label"
    printf '           the substring is not in %s — the stub never landed\n' "$file"
    UNAPPLIED=$((UNAPPLIED+1)); return
  fi

  local out; out=$(run_suite "$T")

  if grep -q 'Compilation failed\|(CompileError)\|(SyntaxError)' <<<"$out"; then
    printf '  \033[33mBROKE\033[0m  %s — the stub did not compile, so it proves nothing\n' "$label"
    BROKE=$((BROKE+1)); return
  fi
  if grep -qF "$want" <<<"$out"; then
    printf '  \033[32mcaught\033[0m  %s\n' "$label"
    printf '           → %s\n' "$want"
    CAUGHT=$((CAUGHT+1))
  else
    printf '  \033[31mNOT A FALSIFIER\033[0m  %s\n' "$label"
    printf '           the suite stayed green with the mechanism removed\n'
    printf '           wanted a failure naming: %s\n' "$want"
    NOT=$((NOT+1))
  fi
}

echo
echo "sabotage-validation — R0b.R · one mechanism removed per case"
echo

# ---------------------------------------------------- R0b.R·1 · admission
case_ 'the protected-kind guard is removed from emit' \
      'generic emit cannot mint a validation START' \
      ampd/lib/ampd/receipts.ex \
      '    if m["kind"] in protected_kinds() do' \
      '    if false do'

case_ 'emit protects only the START kind, not the OUTCOME' \
      'generic emit cannot mint a validation OUTCOME' \
      ampd/lib/ampd/receipts.ex \
      '  def protected_kinds, do: Ampd.Validation.kinds()' \
      '  def protected_kinds, do: [Ampd.Validation.started_kind()]'

case_ 'admissibility stops requiring a JobBasis' \
      'a durable START whose JobBasis is gone is not admissible' \
      ampd/lib/ampd/validation.ex \
      '    Worktree.validation_job(job_ref) != nil and
      started(job_ref) != nil and' \
      '    started(job_ref) != nil and'

case_ 'the typed START trusts a ref that names no job' \
      'a typed START for a JobBasis that does not exist is refused' \
      ampd/lib/ampd/receipts.ex \
      '    case Ampd.Worktree.validation_job(job_ref) do
      nil -> {:error, "validation-job-unknown", %{"job_ref" => job_ref}}
      job -> ask({:validation_start, job})
    end' \
      '    ask({:validation_start, Ampd.Worktree.validation_job(job_ref) || %{"ref" => job_ref}})'

case_ 'the handler stops checking for an existing start' \
      'an outcome for a job that never durably started is refused' \
      ampd/lib/ampd/receipts.ex \
      '    start = find(s, Ampd.Validation.started_kind(), job["ref"])' \
      '    start = find(s, Ampd.Validation.started_kind(), job["ref"]) || %{}'

case_ 'the handler stops checking for an existing outcome' \
      'the single-outcome rule is decided where the append happens' \
      ampd/lib/ampd/receipts.ex \
      '    decided = find(s, Ampd.Validation.outcome_kind(), job["ref"])' \
      '    decided = nil'

case_ 'the typed appends are classified reads' \
      ':open_job is classified a MUTATION at the participant boundary' \
      ampd/lib/ampd/receipts.ex \
      'emit reset validation_start validation_outcome)a' \
      'emit reset)a'

case_ 'the typed appends are served to any caller' \
      'recording a start outside the coordinator is refused' \
      ampd/lib/ampd/receipts.ex \
      '@ordered_ops [:reset, :load_state, :validation_start, :validation_outcome]' \
      '@ordered_ops [:reset, :load_state]'

# ------------------------------------------------------------------- R7.3
case_ 'the start-exists check is removed from the outcome handler' \
      'an outcome for a job that never durably started is refused' \
      ampd/lib/ampd/receipts.ex \
      '      start == nil ->' \
      '      false ->'

case_ 'the single-outcome check is removed from the handler' \
      'two contradictory terminal outcomes for one job are refused' \
      ampd/lib/ampd/receipts.ex \
      '      decided != nil ->' \
      '      false ->'

case_ 'an outcome may name a job that does not exist' \
      'an outcome for a job_ref naming nothing is refused' \
      ampd/lib/ampd/receipts.ex \
      '      nil ->
        {:error, "validation-job-unknown", %{"job_ref" => job_ref}}

      job ->' \
      '      _unused ->
        {:error, "unreachable", %{}}

      job = Ampd.Worktree.validation_job(job_ref) ->'

# ------------------------------------------------------------------- R7.2
case_ 'a completed outcome may also carry a failure reason' \
      'a source-basis mismatch cannot be recorded as a predicate fail' \
      ampd/lib/ampd/validation.ex \
      '      state == "completed" and reason != nil ->' \
      '      false ->'

case_ 'a failed outcome may also carry a verdict' \
      'a source-basis mismatch cannot be recorded as a predicate fail' \
      ampd/lib/ampd/validation.ex \
      '      state == "failed" and verdict != nil ->' \
      '      false ->'

case_ 'the failure-reason enum accepts anything' \
      'every failure reason is one a line of code can actually produce' \
      ampd/lib/ampd/validation.ex \
      '      state == "failed" and reason not in @reasons ->' \
      '      false ->'

case_ 'the state enum accepts anything' \
      'there is no INDETERMINATE' \
      ampd/lib/ampd/validation.ex \
      '      state not in @states ->' \
      '      false ->'

case_ 'the outcome takes its subject from the caller' \
      'the outcome'\''s subject is copied from the start, never from the caller' \
      ampd/lib/ampd/receipts.ex \
      '          "actor" => start["actor"],' \
      '          "actor" => result["actor"] || start["actor"],'

case_ 'an outcome may be recorded outside the coordinator' \
      'recording an outcome outside the coordinator is refused' \
      ampd/lib/ampd/receipts.ex \
      '@ordered_ops [:reset, :load_state, :validation_start, :validation_outcome]' \
      '@ordered_ops [:reset, :load_state, :validation_start]'

# ------------------------------------------------------------------ R11.2
case_ 'admissibility ignores whether a start is durable' \
      'a durable START whose JobBasis is gone is not admissible' \
      ampd/lib/ampd/validation.ex \
      '      started(job_ref) != nil and
      outcome(job_ref) == nil' \
      '      outcome(job_ref) == nil'

# -------------------------------------------------------------------- R11
case_ 'the Lane-ownership check is removed from open_job' \
      'refuses a Worker whose Lane does not own the basis' \
      ampd/lib/ampd/worktree.ex \
      '      owning_lane != lane["id"] ->' \
      '      false ->'

case_ 'the validation-kind enum accepts anything' \
      'refuses a validation kind outside the closed enum' \
      ampd/lib/ampd/worktree.ex \
      '      kind not in Ampd.Validation.validation_kinds() ->' \
      '      false ->'

case_ 'the scope digest is not shape-checked' \
      'refuses a scope digest that could never match' \
      ampd/lib/ampd/worktree.ex \
      '      not scope_digest?(f["scope_digest"]) ->' \
      '      false ->'

case_ 'the job takes its actor from the caller, not the Lane' \
      'the Actor is the Lane'\''s, never the caller'\''s' \
      ampd/lib/ampd/worktree.ex \
      '          "actor" => lane["actor"],' \
      '          "actor" => f["actor"] || lane["actor"],'

case_ 'the Worker generation is not bound to the job' \
      'binds the Worker'\''s generation, not only its ref' \
      ampd/lib/ampd/worktree.ex \
      '          "worker_generation" => worker["generation"] || 1' \
      '          "worker_generation" => nil'

case_ 'a closed Worker may still be given work' \
      'refuses a closed worker' \
      ampd/lib/ampd/worktree.ex \
      '      worker["status"] != "open" ->' \
      '      false ->'

# -------------------------------------------------------------------- R12
case_ 'open_job is classified a read at the participant boundary' \
      ':open_job is classified a MUTATION at the participant boundary' \
      ampd/lib/ampd/worktree.ex \
      'recover bind_basis open_job)a' \
      'recover bind_basis)a'

case_ 'open_job is served to any caller, not only the coordinator' \
      'minting a job outside the coordinator is refused, not served' \
      ampd/lib/ampd/worktree.ex \
      ':bind_basis, :open_job, :reset' \
      ':bind_basis, :reset'

# ------------------------------------------------------------- the cursors
case_ 'list_validations pages the world, not the caller'\''s own' \
      'an actor with no records pages an empty window, not the world'\''s' \
      ampd/lib/ampd/control.ex \
      '    do: Projection.page(Projection.history_for(:validations, peer["actor"]), cursor, limit)' \
      '    do: Projection.page(Projection.history_for(:validations, nil), cursor, limit)'

case_ 'list_worktree_receipts pages validations instead' \
      'an agent can page the establishment of its own worktree' \
      ampd/lib/ampd/control.ex \
      '    do: Projection.page(Projection.history_for(:worktree_receipts, peer["actor"]), cursor, limit)' \
      '    do: Projection.page(Projection.history_for(:validations, peer["actor"]), cursor, limit)'

case_ 'the list_validations command is removed' \
      'every window a projection hands out now has a command' \
      ampd/lib/ampd/command_spec.ex \
      '    "list_validations" => %{
      cmd: :list_validations,' \
      '    "list_validationsX" => %{
      cmd: :list_validationsX,'

# ------------------------------------------------------------------ R8/R9
case_ 'the validation surface is the whole ledger' \
      'validation records route ONLY to the validation surface' \
      ampd/lib/ampd/projection.ex \
      '  def validation_records, do: Ampd.Validation.all()' \
      '  def validation_records, do: Ampd.Receipts.all()'

case_ 'an agent'\''s validations are not filtered by actor' \
      'another actor'\''s validations are not in this actor'\''s projection' \
      ampd/lib/ampd/projection.ex \
      '      "validations" => validation_records() |> mine.() |> window(),' \
      '      "validations" => validation_records() |> window(),'

case_ 'history_for(:validations) ignores the actor' \
      'history_for is typed the same way the frame is' \
      ampd/lib/ampd/projection.ex \
      '    do: Enum.filter(validation_records(), &(&1["actor"] == actor))' \
      '    do: validation_records()'

case_ 'worktree receipts are re-subjected by actor like validations' \
      'worktree receipts are still routed by locus_actor' \
      ampd/lib/ampd/projection.ex \
      '        |> Enum.filter(&(&1["locus_actor"] == actor))' \
      '        |> Enum.filter(&(&1["actor"] == actor))'


echo
printf 'sabotage-validation: %d caught · %d NOT A FALSIFIER · %d did not compile · %d unapplied\n' \
  "$CAUGHT" "$NOT" "$BROKE" "$UNAPPLIED"
[ "$NOT" -eq 0 ] && [ "$BROKE" -eq 0 ] && [ "$UNAPPLIED" -eq 0 ]
