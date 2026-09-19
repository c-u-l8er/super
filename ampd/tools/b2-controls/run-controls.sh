#!/usr/bin/env bash
# Run the B2 harness + the WEK verifier under each deliberately broken control.
# Every control must make the harness FAIL and the verifier exit non-zero;
# a control under which both stay green is a control that proves nothing.
#   B2_CONTROL_OUT=<dir> WEK_VERIFIER=<path to wek/r3/verify-cli.mjs> bash tools/b2-controls/run-controls.sh
set -u
cd "$(dirname "$0")/../.."
OUT=${B2_CONTROL_OUT:?}; V=${WEK_VERIFIER:?}; mkdir -p "$OUT"
REV=$(git rev-parse HEAD)
run_one () {
  local name=$1; shift
  local dir="$OUT/$name"; rm -rf "$dir"; mkdir -p "$dir/evidence"
  for p in "$@"; do git apply "tools/b2-controls/$p.patch" || { echo "cannot apply $p"; exit 2; }; done
  mix compile --warnings-as-errors > "$dir/compile.log" 2>&1
  B2_EVIDENCE_DIR="$dir/evidence" B2_SUBSTRATE_REVISION="$REV+control:$name" B2_SUBSTRATE_SOURCE="$(pwd)" \
    mix test test/b2_write_boundary_test.exs --seed 0 > "$dir/harness.log" 2>&1; local h=$?
  node "$V" --manifest "$dir/evidence/manifest.json" > "$dir/verify.json" 2> "$dir/verify.err"; local v=$?
  for p in "$@"; do git apply -R "tools/b2-controls/$p.patch"; done
  local tests; tests=$(grep -E "^[0-9]+ tests?, [0-9]+ failures?" "$dir/harness.log" | tail -1)
  local spec; spec=$(node -e "const d=require('$dir/verify.json');console.log(d.as_specified+'/'+d.total+' as specified; not: '+d.results.filter(r=>!r.as_specified).map(r=>r.case.split('-')[0]+':'+r.outcome+'['+r.reasons[0]+']').join(' | '))" 2>/dev/null)
  echo "control=$name harness_exit=$h ($tests) verifier_exit=$v ($spec)" | tee -a "$OUT/SUMMARY.txt"
}
: > "$OUT/SUMMARY.txt"
run_one no-retired-check no-retired-check
run_one no-epoch-or-key-check no-epoch-or-key-check no-epoch-or-key-check-b
run_one no-gather-at-retirement no-gather-at-retirement
run_one no-s1 no-s1
run_one no-transition-legality no-transition-legality
mix compile --warnings-as-errors > /dev/null 2>&1
git status --short lib test | grep -v '^??' && echo "TREE DIRTY AFTER CONTROLS — check" || echo "tree restored"
