#!/usr/bin/env bash
# sabotage-counts — the count-derivation gate, falsified.
#
# `stamp-counts.mjs` is the tool that stops conformance figures being typed.
# Nothing checked that it could refuse anything. W.1.3.2a is the argument for
# this harness existing: that round's §6 is entirely about eliminating count
# drift, and the brief it shipped carried `# 184 assertions` in §10 while its
# own stamped table said 188 — because the bare-count scan named two READMEs
# and did not include the brief. The gate was green over the exact defect the
# round claimed to close.
#
# An enforcement that has never refused anything is an enforcement in name.
#
# Files are backed up ONCE however many probes target them, and the EXIT trap
# owns restoration — the two signal traps terminate rather than merely clean
# up, which `sabotage-bots.sh` had to relearn at W.1.3.2a.
set -uo pipefail
cd "$(dirname "$0")/.."

REV=$(node -p "require('./release.json').revision")
BRIEF="docs/reviews/$(printf '%s' "$REV" | tr 'a-z.' 'A-Z_')_REVIEW_BRIEF.md"

# Every file any probe writes to is in here, including the battery itself —
# a harness that sabotages a file it cannot restore is the F.8.2.3 shape.
TARGETS=(README.md ampd/README.md site/AGENT_SUPER_APP_BLUEPRINT.md
         site/app-prototype.html tools/authority-battery.mjs)
[ -f "$BRIEF" ] && TARGETS+=("$BRIEF")

BACKUP=$(mktemp -d)
for f in "${TARGETS[@]}"; do mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; done
restore(){ for f in "${TARGETS[@]}"; do cp "$BACKUP/$f" "$f"; done; }
cleanup(){ restore; rm -rf "$BACKUP"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# **THE TALLY MUST NAME WHAT ACTUALLY HAPPENED.**
#
# The first version of this harness counted every met expectation into a
# variable called `REFUSED` and summarised "7 refused · 0 not" — while its
# own output contained the line
#
#     refused    a clean tree (accepted, as it must)
#
# which is a contradiction printed in full and read past. Three of these
# cases are not refusals: the baseline is an ACCEPT, and the hand-edited
# marker is a RESTAMP. Collapsing three outcomes into the name of one is
# the same defect as calling four claim kinds "stale" — a summary that
# reports a number correctly and the thing it counted wrongly.
PASSED=0; NOT=0
N_REFUSED=0; N_ACCEPTED=0; N_RESTAMPED=0

# A refusal must name the RIGHT reason. `sabotage-guard.sh` learned this the
# hard way at W.1.3.2a: a nonzero exit is not a verdict, because a tool that
# dies for an unrelated reason also exits nonzero. Every refusing case names
# the sentence `stamp-counts` has to print.
probe(){
  local name="$1" want="$2" why="${3:-}"
  local out rc
  out=$(node tools/stamp-counts.mjs 2>&1); rc=$?
  restore

  if [ "$want" = accept ]; then
    if [ "$rc" -eq 0 ]; then echo "accepted   $name"
                             PASSED=$((PASSED+1)); N_ACCEPTED=$((N_ACCEPTED+1))
    else echo "NOT        $name — stamp-counts refused a clean tree"
         echo "$out" | sed 's/^/           /'; NOT=$((NOT+1)); fi
  elif [ "$rc" -eq 0 ]; then
    echo "NOT        $name — stamp-counts accepted it"; NOT=$((NOT+1))
  elif ! grep -qF "$why" <<<"$out"; then
    echo "NOT        $name — refused, but never said '$why'"
    echo "$out" | sed 's/^/           /'; NOT=$((NOT+1))
  else
    echo "refused    $name"; PASSED=$((PASSED+1)); N_REFUSED=$((N_REFUSED+1))
  fi
}

# A sed that matches nothing is reported as MISSED and counted as a failure,
# never as a pass — three probes went stale against a refactor in W.1.2 and
# that was only harmless because missing scores as failing.
edited(){ cmp -s "$1" "$BACKUP/$1" && { echo "MISSED     $2 — the pattern matched nothing"
                                        NOT=$((NOT+1)); restore; return 1; }; return 0; }

# The baseline. A gate that refuses everything is not a gate.
probe "a clean tree" accept

# GPT'S CASE. A bare count in the CURRENT review brief, outside the markers —
# the document that actually reaches the reviewer. Green until now.
if [ -f "$BRIEF" ]; then
  printf '\nThe battery reports 999 assertions.\n' >> "$BRIEF"
  probe "a bare assertion count in the current review brief" refuse "is a transcribed count"
else
  echo "NOT        no brief at $BRIEF — the case cannot run"; NOT=$((NOT+1))
fi

# The pre-existing halves of the same law, which had never been probed either.
printf '\nThe corpus holds 999 vectors.\n' >> README.md
probe "a bare vector count in the README" refuse "is a transcribed count"

printf '\nThe suite runs 999 tests.\n' >> ampd/README.md
probe "a bare test count in the ampd README" refuse "is a transcribed count"

# A HAND-EDITED MARKER IS NOT A REFUSAL — IT IS A REWRITE. `stamp-counts` is
# documented as reverting a hand-edited number rather than failing on it, and
# the difference is load-bearing: the marker is the tool's own output and it
# owns it. Measured rather than assumed.
perl -0pi -e 's@<!--assertions-->\d+<!--/assertions-->@<!--assertions-->999<!--/assertions-->@' \
  site/AGENT_SUPER_APP_BLUEPRINT.md
if edited site/AGENT_SUPER_APP_BLUEPRINT.md "a hand-edited marker is restamped, not refused"; then
  out=$(node tools/stamp-counts.mjs 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && ! grep -q 'assertions-->999<' site/AGENT_SUPER_APP_BLUEPRINT.md; then
    echo "restamped  a hand-edited marker is restamped, not refused"
    PASSED=$((PASSED+1)); N_RESTAMPED=$((N_RESTAMPED+1))
  else
    echo "NOT        a hand-edited marker is restamped, not refused — rc=$rc"; NOT=$((NOT+1))
  fi
  restore
fi

# **THE ONE THAT MATTERS MOST.** `stamp-counts` derives the browser count by
# RUNNING the battery, so a red battery must stop it stamping — otherwise a
# failing suite's number is written into the README as though it passed,
# which is worse than a stale count because it is a fresh one.
perl -0pi -e 's@^function claimStale\(c, basis\)\{ return !VALIDITY_HOLDS\[claimValidity\(c, basis\)\]; \}$@function claimStale(c, basis){ return false; }@m' \
  site/app-prototype.html
if edited site/app-prototype.html "a failing battery still gets its number stamped"; then
  probe "a failing battery still gets its number stamped" refuse "reports"
fi

# And a battery that stops reporting a count at all — the shape this takes
# after a refactor rather than a sabotage. The backtick is matched as `.` so
# nothing here needs a `$` the shell would eat.
perl -0pi -e 's@^console\.log\(.authority battery: .*\n@@m' tools/authority-battery.mjs
if edited tools/authority-battery.mjs "a battery that stops reporting its count"; then
  probe "a battery that stops reporting its count" refuse "did not report its own count"
fi

echo
echo "count sabotage: $N_REFUSED refused · $N_ACCEPTED accepted · $N_RESTAMPED restamped · $NOT unexpected"
[ "$NOT" -eq 0 ]
