#!/usr/bin/env bash
# The trvm.reduce harness (test/b2_trvm_reduce_test.exs) under each deliberately broken control.
#
#   The five B2 boundary controls (lib patches) must make the harness and/or the verifier go RED
#   on the trvm cases exactly as they do on the B2 cases — the composition is under the same eye.
#   The sixth, `no-reference-assert` (an ENV knob, no patch: B2_NO_REFERENCE_ASSERT=1 makes the
#   harness's reference comparison accept everything), must flip EXACTLY ONE case — F-D — and
#   leave the verifier's verdicts untouched, because result honesty is owned by that comparison
#   and by nothing in the boundary. A control under which nothing changes proves nothing.
#
#   B2_CONTROL_OUT=<dir> WEK_VERIFIER=<wek/r3/verify-cli.mjs> HS_TRVM_HOST=<host.mjs> \
#     bash tools/b2-controls/run-trvm-controls.sh
set -u
cd "$(dirname "$0")/../.."
OUT=${B2_CONTROL_OUT:?}; V=${WEK_VERIFIER:?}; : "${HS_TRVM_HOST:?}"; mkdir -p "$OUT"
REV=$(git rev-parse HEAD)
export MANAGED_OUTPUT_DIR="$OUT/managed"; mkdir -p "$MANAGED_OUTPUT_DIR"

run_one () {
  local name=$1; local envknob=$2; shift 2
  local dir="$OUT/$name"; rm -rf "$dir"; mkdir -p "$dir/evidence"
  for p in "$@"; do git apply "tools/b2-controls/$p.patch" || { echo "cannot apply $p"; exit 2; }; done
  mix compile --warnings-as-errors > "$dir/compile.log" 2>&1
  env $envknob B2_EVIDENCE_DIR="$dir/evidence" B2_SUBSTRATE_REVISION="$REV+control:$name" B2_SUBSTRATE_SOURCE="$(pwd)" \
    mix test test/b2_trvm_reduce_test.exs --seed 0 > "$dir/harness.log" 2>&1; local h=$?
  node "$V" --manifest "$dir/evidence/manifest.json" > "$dir/verify.json" 2> "$dir/verify.err"; local v=$?
  for p in "$@"; do git apply -R "tools/b2-controls/$p.patch"; done
  local tests; tests=$(grep -E "^[0-9]+ tests?, [0-9]+ failures?" "$dir/harness.log" | tail -1)
  local failing; failing=$(grep -E "^\s+[0-9]+\) test " "$dir/harness.log" | sed -E 's/^\s+[0-9]+\) test ([^·]+)·.*/\1/' | tr -d ' ' | tr '\n' ',' )
  local spec; spec=$(node -e "try{const d=require('$dir/verify.json');console.log(d.as_specified+'/'+d.total+' as specified; not: '+d.results.filter(r=>!r.as_specified).map(r=>r.case).join(','))}catch(e){console.log('verifier unreadable')}")
  echo "control=$name harness_exit=$h ($tests; failing: ${failing:-none}) verifier_exit=$v ($spec)" | tee -a "$OUT/SUMMARY.txt"
}
: > "$OUT/SUMMARY.txt"
run_one no-retired-check "" no-retired-check
run_one no-epoch-or-key-check "" no-epoch-or-key-check no-epoch-or-key-check-b
run_one no-gather-at-retirement "" no-gather-at-retirement
run_one no-s1 "" no-s1
run_one no-transition-legality "" no-transition-legality
run_one no-reference-assert "B2_NO_REFERENCE_ASSERT=1"
mix compile --warnings-as-errors > /dev/null 2>&1
git status --short lib test | grep -v '^??' | grep -v 'b2_trvm_reduce_test\|trvm_reduce.ex\|gateway.ex\|capability_registry.ex\|authority.ex' && echo "TREE DIRTY AFTER CONTROLS — check" || echo "tree restored"
