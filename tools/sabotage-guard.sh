#!/usr/bin/env bash
# sabotage-guard — the tree-integrity bracket, falsified.
#
# W.1.3.1 wrote, in a review brief: "The guard has its own falsifier: a
# harness that does not restore is refused and its leftover `.orig` named."
# There was no such harness. The sentence was the proof, which is the exact
# defect `proof-battery.mjs` fails the release for, four levels up: a claim
# about a measurement, with no measurement.
#
# When the harness was finally written it found that two of the three cases
# the bracket claims to catch were NOT caught:
#
#   * a harness that exits nonzero — `release.sh` runs under `set -e` and
#     `guarded` inherited the status from a bare `"$@"`, so the script died
#     BEFORE the post-fingerprint. The tree could be dirty and the bracket
#     never said so.
#   * a harness that restores the source and leaves its `.orig` behind —
#     `fingerprint` excludes `*.orig` by design, so this case fingerprints
#     IDENTICAL and printed "tree integrity restored". Neither packager
#     excluded `.orig`, so the backup shipped inside the artifact.
#
# Each case is run against a scratch tree the harness owns, so a failure
# here damages nothing real. `guarded` exits on refusal; each case runs in
# a subshell so this script survives to report.
set -uo pipefail
cd "$(dirname "$0")/.."
. tools/guard.sh

CAUGHT=0; NOT=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# **A NONZERO EXIT IS NOT A VERDICT.**
#
# The first version of this harness asserted only that the bracket exited
# nonzero, and under the OLD bracket the two death cases passed it — `set
# -e` killed the subshell at the harness call, which is a nonzero exit that
# reports nothing. That is precisely the thing GPT identified: packaging
# stops, which is the outcome you want, and the bracket never looked at the
# tree. So each case names the SENTENCE the bracket has to produce, and the
# call runs under `set -e` because that is how `release.sh` invokes it.
case_() {
  local name="$1" want="$2"; shift 2
  rm -rf "$WORK/t"; mkdir -p "$WORK/t"
  printf 'the product\n' > "$WORK/t/source.txt"

  local out
  out=$( ( set -e; guarded probe "$WORK/t" -- "$@" ) 2>&1 )

  if grep -qF "$want" <<<"$out"; then
    echo "caught     $name"
    CAUGHT=$((CAUGHT+1))
  else
    echo "NOT        $name — the bracket never said '$want'"
    echo "$out" | sed 's/^/           /'
    NOT=$((NOT+1))
  fi
}

# A harness that behaves: edits, restores, cleans up after itself.
clean_harness ()      { cp "$1/source.txt" "$1/source.txt.orig"
                        printf 'sabotaged\n' > "$1/source.txt"
                        cp "$1/source.txt.orig" "$1/source.txt"
                        rm -f "$1/source.txt.orig"; }
# The case the bracket was built for and did catch.
no_restore ()         { printf 'sabotaged\n' > "$1/source.txt"; }
# GPT's case. Source restored, backup left behind — IDENTICAL fingerprint.
leaves_backup ()      { cp "$1/source.txt" "$1/source.txt.orig"
                        printf 'sabotaged\n' > "$1/source.txt"
                        cp "$1/source.txt.orig" "$1/source.txt"; }
# The mid-probe death. Under the old bracket `set -e` killed the release
# here and the tree was never inspected.
dies_clean ()         { clean_harness "$1"; return 3; }
# The one that matters most: dies AND leaves the tree damaged.
dies_dirty ()         { printf 'sabotaged\n' > "$1/source.txt"; return 3; }

case_ "a harness that restores cleanly is not refused" \
      "tree integrity: probe restored what it sabotaged"  clean_harness "$WORK/t"
case_ "a harness that does not restore is named" \
      "left the source tree modified"                     no_restore    "$WORK/t"
case_ "a harness that leaves its .orig behind is named" \
      "leftover backups:"                                 leaves_backup "$WORK/t"
case_ "a harness killed mid-probe is REPORTED, not merely fatal" \
      "RELEASE REFUSED · probe exited 3"                  dies_clean    "$WORK/t"
case_ "a harness that dies dirty has its tree inspected anyway" \
      "harness exit status: 3"                            dies_dirty    "$WORK/t"

# And the bracket must survive being run under `set -e`, which is how
# `release.sh` calls it — the option is restored, not silently left off.
( set -e; ( guarded probe "$WORK/t" -- clean_harness "$WORK/t" ) >/dev/null 2>&1
  case $- in *e*) exit 0;; *) exit 1;; esac )
if [ $? -eq 0 ]; then
  echo "caught     the bracket restores set -e after running the harness"
  CAUGHT=$((CAUGHT+1))
else
  echo "NOT        the bracket restores set -e after running the harness"
  NOT=$((NOT+1))
fi

echo
echo "guard sabotage: $CAUGHT caught · $NOT not"
[ "$NOT" -eq 0 ]
