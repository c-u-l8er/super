#!/usr/bin/env bash
# suite-evidence — run the BEAM suite at N seeds and KEEP WHAT HAPPENED.
#
# **Written because a red run was thrown away.** D.1.3b·2f's freeze battery
# ran `mix test --seed 909090` through a `grep` for the summary line, saw
# `586 tests, 4 failures`, and discarded everything that would have said
# which four. The same seed then passed five times. The finding is
# permanently unattributable and the review had to say so.
#
# That is `tools/sabotage-host.sh`'s evidence lesson arriving a second time
# in a different file:
#
#   > Every execution writes its own immutable log, and a rerun may not
#   > erase the run that caused it. C1.0b·2·1 lost a battery log exactly
#   > that way.
#
# So this file is the same discipline for the suite. One directory per
# execution, named by second and commit, created with `set -C` so a
# collision REFUSES rather than clobbers, holding:
#
#   meta.json   commit · tree · seed · started_at · finished_at · exit
#               status · summary · dirty paths · the BEAMs that were
#               already running when it started and were still there after
#   stdout.log  in full
#   stderr.log  in full
#
# and one line appended to INDEX. A failing run stays inspectable after
# every rerun it provokes.
#
# **Output goes to FILES, never to a command substitution.** `out=$(mix
# test)` reads the pipe until EOF, and EOF does not arrive while a child
# the suite started still holds it — the host battery measured 1h46m of
# that, and this is the same trap with a different suite in it.
#
#   bash tools/suite-evidence.sh                 the default seed battery
#   bash tools/suite-evidence.sh 1 2 3           these seeds
#   SUITE_TIMEOUT=900 bash tools/suite-evidence.sh …
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

# The default battery. Three seeds because that is what every freeze in this
# lane has reported; `909090` is kept deliberately — it is the seed whose
# evidence was lost, and dropping it would be quietly retiring the question.
DEFAULT_SEEDS=(0 424242 909090)
SEEDS=("$@")
[ ${#SEEDS[@]} -eq 0 ] && SEEDS=("${DEFAULT_SEEDS[@]}")

TIMEOUT=${SUITE_TIMEOUT:-1200}
RUNS="$ROOT/.suite-runs"
mkdir -p "$RUNS"

sha=$(git rev-parse --short=12 HEAD 2>/dev/null || echo nogit)
tree=$(git rev-parse HEAD^{tree} 2>/dev/null || echo notree)
dirty=$(git status --short | tr '\n' ';')

# **The BEAM census, before and after.** The lost run happened moments after
# a killed background suite, and three orphaned `mix run --no-halt` runtimes
# from cockpit measurements were on the machine. That is a hypothesis this
# harness cannot test retroactively and can record from now on. It is
# evidence, not an explanation — a run that is clean with orphans present
# says the orphans are not sufficient, which is worth knowing either way.
beams () { pgrep -af 'beam.smp' 2>/dev/null | grep -c 'mix run --no-halt' || true; }

# **And WHERE they are, because a count alone is not attributable.** A run at
# `6e5a54e` recorded `orphans 0→1` while two other batteries were running, and
# the honest reading needed a second measurement: the counted runtime's cwd was
# `.super-sabotage-<sha>-<stamp>/ampd`, the host battery's own isolated
# worktree. It was not an orphan this suite left; it was another battery's live
# process, and this census greps the whole machine. Recording the directories
# turns a number a reader has to guess about into one they can attribute.
beam_where () {
  for pid in $(pgrep -f 'mix run --no-halt' 2>/dev/null); do
    readlink "/proc/$pid/cwd" 2>/dev/null
  done | sort -u | tr '\n' ';'
}

json_escape () { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

overall=0
echo "suite evidence · $sha · seeds: ${SEEDS[*]} · retained under .suite-runs/"
echo

for seed in "${SEEDS[@]}"; do
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  dir="$RUNS/$stamp-$sha-seed$seed"

  # `mkdir` without `-p` is the refusal: it fails if the directory exists,
  # which is the same guarantee `set -C` gives the sabotage batteries' logs.
  if ! mkdir "$dir" 2>/dev/null; then
    echo "REFUSING: $dir already exists — evidence is append-only" >&2
    exit 1
  fi

  before=$(beams)
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  start_s=$(date +%s)

  ( cd "$ROOT/ampd" && timeout "$TIMEOUT" mix test --seed "$seed" ) \
    >"$dir/stdout.log" 2>"$dir/stderr.log"
  rc=$?

  finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  dur=$(( $(date +%s) - start_s ))
  after=$(beams)

  # The summary line, from the retained file rather than from a pipe. If it
  # is missing that is itself recorded: a run with no summary is what a
  # killed suite looks like, and the lost run may well have been one.
  summary=$(grep -aE '^[0-9]+ tests?, [0-9]+ failures?' "$dir/stdout.log" | tail -1)
  [ -z "$summary" ] && summary="(no summary line — the suite did not finish printing)"

  {
    printf '{\n'
    printf '  "commit":      "%s",\n' "$(git rev-parse HEAD 2>/dev/null || echo nogit)"
    printf '  "tree":        "%s",\n' "$tree"
    printf '  "dirty":       %s,\n'   "$(printf '%s' "$dirty" | json_escape)"
    printf '  "seed":        "%s",\n' "$seed"
    printf '  "started_at":  "%s",\n' "$started"
    printf '  "finished_at": "%s",\n' "$finished"
    printf '  "duration_s":  %s,\n'   "$dur"
    printf '  "exit_status": %s,\n'   "$rc"
    printf '  "timed_out":   %s,\n'   "$([ "$rc" -eq 124 ] && echo true || echo false)"
    printf '  "summary":     %s,\n'   "$(printf '%s' "$summary" | json_escape)"
    printf '  "orphan_runtimes_before": %s,\n' "$before"
    printf '  "runtime_cwds_after": %s,\n' "$(printf '%s' "$(beam_where)" | json_escape)"
    printf '  "orphan_runtimes_after":  %s,\n' "$after"
    printf '  "stdout_bytes": %s,\n'  "$(wc -c <"$dir/stdout.log")"
    printf '  "stderr_bytes": %s\n'   "$(wc -c <"$dir/stderr.log")"
    printf '}\n'
  } >"$dir/meta.json"

  # Append-only, and the failing runs are the ones a reader scans for.
  printf '%s  %s  seed=%-8s rc=%-3s %s  orphans %s→%s  %s\n' \
    "$stamp" "$sha" "$seed" "$rc" "$summary" "$before" "$after" "$(basename "$dir")" \
    >>"$RUNS/INDEX"

  if [ "$rc" -eq 0 ] && grep -qaE '^[0-9]+ tests?, 0 failures?' "$dir/stdout.log"; then
    printf '  \033[32mgreen\033[0m  seed %-8s %s   (%ss, orphans %s→%s)\n' "$seed" "$summary" "$dur" "$before" "$after"
  else
    overall=1
    printf '  \033[31mRED\033[0m    seed %-8s %s   rc=%s\n' "$seed" "$summary" "$rc"
    printf '         evidence RETAINED at %s\n' "${dir#$ROOT/}"
    # The names, here, so a reader does not have to be told to go and look.
    grep -aE '^\s+[0-9]+\) test ' "$dir/stdout.log" | head -20 | sed 's/^/         /'
  fi
done

echo
echo "suite evidence: $(ls -1d "$RUNS"/*/ 2>/dev/null | wc -l) run(s) retained · INDEX at .suite-runs/INDEX"
exit $overall
