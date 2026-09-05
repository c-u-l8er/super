#!/usr/bin/env bash
# check-sabotage-scoring — the scorer, scored.
#
# `tools/sabotage-scoring.sh` decides what a sabotage probe is entitled to
# conclude. Until E0 it was three lines inside a 90-minute battery, which is
# to say it was never tested: the only way to exercise it was to run the
# thing it judges, and then its verdict was the only record of whether it had
# judged correctly. That is how it came to print "'X' passed with the fix
# disabled" about a check that had not run.
#
# So the scorer now takes canned verify output and this file feeds it every
# state it can reach, including the two that are not states at all — an empty
# file and a malformed one. The requirement those two exist for is the sharp
# one: **no input may produce FALSIFIED except output that actually contains
# the named check, FAILED.** A scorer that goes green on a truncated pipe
# would award the strongest possible result for the harness breaking.
#
#     bash tools/check-sabotage-scoring.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source tools/sabotage-scoring.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0; fail=0

# case <name> <expected-verdict> <expect-string> <file-content>
case_is () {
  local name="$1" want="$2" expect="$3" body="$4"
  local f="$tmp/out"
  printf '%s' "$body" > "$f"
  local got
  got=$(score_verdict "$expect" "$f")
  if [ "$got" = "$want" ]; then
    printf '  \033[32mheld\033[0m  %-46s → %s\n' "$name" "$got"
    pass=$((pass+1))
  else
    printf '  \033[31mFAIL\033[0m  %-46s → %s, wanted %s\n' "$name" "$got" "$want"
    fail=$((fail+1))
  fi
}

E=$'\033'   # verify colours its verdict words; the scorer must see past that

echo "sabotage scorer — three states, and the two non-states"
echo

# --- the three real states ------------------------------------------------
case_is "check appears FAILED" FALSIFIED "fork is refused inside a Carrier" \
"  ${E}[32mheld${E}[0m         a confined Carrier starts
  ${E}[31mFAILED${E}[0m       fork is refused inside a Carrier — fork returned 0
"

case_is "check appears held" NOT_A_FALSIFIER "fork is refused inside a Carrier" \
"  ${E}[32mheld${E}[0m         a confined Carrier starts
  ${E}[32mheld${E}[0m         fork is refused inside a Carrier
"

# The one the old scorer got wrong, and the reason for this file. The
# sabotage removed a prerequisite, the Carrier never started, and the
# in-Carrier check is simply absent. The old code called this "passed".
case_is "check absent — prerequisite destroyed" DID_NOT_RUN "fork is refused inside a Carrier" \
"  ${E}[31mFAILED${E}[0m       a confined Carrier starts — carrier-execution-basis-changed
  ${E}[31mFAILED${E}[0m       the committed Carrier is a live OS process, not a record
"

# --- the two non-states ---------------------------------------------------
case_is "empty output"    DID_NOT_RUN "fork is refused inside a Carrier" ""
case_is "whitespace only" DID_NOT_RUN "fork is refused inside a Carrier" $'\n\n  \n'
case_is "truncated mid-line" DID_NOT_RUN "fork is refused inside a Carrier" \
"  ${E}[32mheld${E}[0m         a confined Carrier st"
case_is "unrelated noise" DID_NOT_RUN "fork is refused inside a Carrier" \
"thread 'main' panicked at src/lib.rs:1:1
note: run with RUST_BACKTRACE=1
"

# --- the adversarial ones -------------------------------------------------
#
# The word FAILED appearing somewhere else in the output must not make an
# absent check green. This is the shape of the original defect generalised:
# a scorer that answers a question about check X by looking at text about Y.
case_is "FAILED present, named check absent" DID_NOT_RUN "fork is refused inside a Carrier" \
"  ${E}[31mFAILED${E}[0m       something else entirely — reason
  104 held · 22 failed
"

# `FAILED.*$expect` is a single-line match under grep, so a FAILED on one
# line and the name on another must NOT be read as the name being FAILED.
case_is "FAILED on a different line than the name" NOT_A_FALSIFIER "fork is refused inside a Carrier" \
"  ${E}[31mFAILED${E}[0m       an unrelated check
  ${E}[32mheld${E}[0m         fork is refused inside a Carrier
"

# A summary line mentioning the count must not be mistaken for the check.
case_is "only the summary line" DID_NOT_RUN "fork is refused inside a Carrier" \
"  299 held · 0 failed
"

echo
printf 'sabotage scoring: %d held · %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
