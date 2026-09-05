#!/usr/bin/env bash
# gates — run every STATIC gate in this tree, in one command.
#
# **Written because `tools/check-ordered-boundary.mjs` was RED for the whole
# of Phase A and nobody knew.** It had caught a real defect —
# `Ampd.Worktree`'s `:bind_basis` is served only for the coordinator and was
# classified a read, so a lost reply to the one operation that mints source
# authority would have been reported as "nothing was mutated, retry" — and
# it sat there from the commit that introduced SourceBasis until R0b.R,
# because no `verify`, no `release.sh` and no battery ever invoked it.
#
# A gate nobody runs is not a gate. It is a file that would have caught
# something.
#
# So this exists to make "which gates hold?" a command rather than a memory
# of which ones a review happened to cite. Adding a gate here is the last
# step of writing one.
#
# Static only: no BEAM suite (`mix test`), no host battery, no sabotage
# harness. Those are minutes-to-hours and have their own evidence
# discipline — `tools/suite-evidence.sh` keeps what happened for the first.
# These are seconds, and there is no excuse for not running them.
#
#     bash tools/gates.sh
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0; SKIP=0; FAILED=(); SKIPPED=()

# **Compile first, because a gate that shells to `mix` parses its stdout.**
# `check-dispatch-partition.mjs` runs `mix run --no-start -e IO.write(...)`
# to read `Ampd.Control`'s partition out of the runtime rather than out of a
# regex. On a stale `_build` that invocation prints the compiler's output
# first, the parse takes `Compiling 2 files (.ex)` as data, and the gate
# reports a count it never measured — observed here as `22 reads · 10 held ·
# 1 failed`, deterministic 15/11/0 on the very next run.
#
# A false RED is cheaper than a false green and still corrosive: it is how a
# gate earns the reputation that stops anyone running it.
mix_quiet () { ( cd ampd && mix compile >/dev/null 2>&1 ); }
mix_quiet

# **`CANNOT RUN` is not `held` and is not `FAIL`.** A gate whose subject is
# absent — an unbuilt binary, a missing fixture — has measured nothing, and
# scoring that as either verdict is a lie in one of the two directions. The
# Phase A battery reports `0 CHECK DID NOT RUN` on its own line for exactly
# this reason, and the summary below refuses while any gate is in that state.
gate () {                             # gate <label> <cmd…>
  local label="$1"; shift
  local out; out=$( "$@" 2>&1 ); local rc=$?
  if [ $rc -eq 2 ]; then
    printf '  \033[35mCANNOT RUN\033[0m  %-30s %s\n' "$label" \
      "$(head -1 <<<"$out" | cut -c1-70)"
    SKIP=$((SKIP+1)); SKIPPED+=("$label"); return
  fi
  if [ $rc -eq 0 ]; then
    printf '  \033[32mheld\033[0m  %-34s %s\n' "$label" \
      "$(grep -oE '[0-9]+ (held|passed|checks?|laws?)[^|]*$' <<<"$out" | tail -1)"
    PASS=$((PASS+1))
  else
    printf '  \033[31mFAIL\033[0m  %-34s exit %d\n' "$label" "$rc"
    sed 's/^/           /' <<<"$out" | tail -6
    FAIL=$((FAIL+1)); FAILED+=("$label")
  fi
}

echo
echo "gates — every static gate in this tree"
echo

gate "ordered boundary"   node tools/check-ordered-boundary.mjs
gate "ordered closure"    node tools/check-ordered-closure.mjs
gate "dispatch partition" node tools/check-dispatch-partition.mjs
gate "webview acl"        node tools/check-webview-acl.mjs
gate "intent surface"     node tools/check-intent-surface.mjs
gate "measurement prose"  node tools/check-measurement-prose.mjs
gate "source hygiene"     node tools/check-source-hygiene.mjs
gate "preview"            node tools/check-preview.mjs

echo
printf 'gates: %d held · %d failed · %d could not run\n' "$PASS" "$FAIL" "$SKIP"
[ $FAIL -gt 0 ] && printf '  failed:      %s\n' "${FAILED[*]}"
[ $SKIP -gt 0 ] && printf '  cannot run:  %s\n' "${SKIPPED[*]}"
echo
[ $FAIL -eq 0 ] && [ $SKIP -eq 0 ]
