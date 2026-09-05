#!/usr/bin/env bash
# sabotage-scoring — what a sabotage probe is entitled to conclude.
#
# **Extracted because the old scorer printed a sentence that was not true.**
#
# It was one `if`:
#
#     if grep -q "FAILED.*$expect"; then  falsified
#     else  "NOT A FALSIFIER — '$expect' passed with the fix disabled"
#
# and the `else` branch asserts the named check *passed*. It fires
# identically when the check never appeared in the output at all. Those are
# different facts and the battery printed the same sentence for both.
#
# For the D.1.3b confinement probes that is not a corner case, it is the
# normal case. Disabling `no_new_privs`, the seccomp filter, or the ruleset
# descriptor stops any Carrier from starting, so every downstream *in-Carrier*
# check cannot execute. Measured at `ace5f69` by applying the `no_new_privs`
# sabotage and reading the verify output:
#
#     a confined Carrier starts            present, and FAILED   ← correct
#     fork is refused inside a Carrier     ABSENT — never ran
#     memfd_create is refused …            ABSENT — never ran
#
# So the battery said "'fork is refused inside a Carrier' passed with the fix
# disabled" about a check that did not run. That is the precise inverse of the
# truth, printed in red, in the block whose own comment calls these "the ones
# most able to go green over nothing".
#
# Three states, because there are three facts:
#
#     FALSIFIED         the named check appears AND is FAILED
#                       the fix was disabled and the check noticed
#
#     NOT_A_FALSIFIER   the named check appears AND is not FAILED
#                       the fix was disabled and the check did not notice.
#                       This is the real one — the probe reached its question
#                       and got the wrong answer.
#
#     DID_NOT_RUN       the named check does not appear at all
#                       the probe could not ask its question. It proves
#                       NOTHING — not that the check works, not that it
#                       doesn't. It must never be scored as either.
#
# A probe that cannot reach its question is not evidence. It is the absence
# of evidence, and the whole reason this file exists is that the two used to
# look identical in the log.
#
# In its own file so it can be tested against canned output without running
# a 90-minute battery: `tools/check-sabotage-scoring.sh` covers all three
# states plus empty and malformed input. A scorer that is only ever exercised
# by the thing it scores is a scorer nobody has checked.

# score_verdict <expect> <output-file>
#
# Echoes exactly one of FALSIFIED · NOT_A_FALSIFIER · DID_NOT_RUN.
#
# `$expect` is matched as a regex in both tests, deliberately: the two
# questions must agree about what "the named check" means, and a presence
# test with different matching semantics from the redness test is a third
# way to get a wrong answer. No expect string in this tree contains a regex
# metacharacter; if one ever does, both tests change together or neither.
#
# The redness test tolerates the ANSI colour run between the word and the
# name — verify prints `\e[31mFAILED\e[0m       <name>` — which is why it is
# `FAILED.*$expect` and not `FAILED  $expect`.
score_verdict () {
  local expect="$1" out="$2"

  # An unreadable or empty file is DID_NOT_RUN, never green. A verify that
  # produced nothing proves nothing, and the failure mode this guards is a
  # harness that treats a truncated pipe as a passing run.
  [ -s "$out" ] || { echo DID_NOT_RUN; return; }

  if grep -q "FAILED.*$expect" "$out"; then
    echo FALSIFIED
  elif grep -q "$expect" "$out"; then
    echo NOT_A_FALSIFIER
  else
    echo DID_NOT_RUN
  fi
}

# score_line <verdict> <name> <expect> <output-file>
#
# The one place each verdict's sentence is spelled, so a state cannot be
# renamed in the log without being renamed here.
score_line () {
  local v="$1" name="$2" expect="$3" out="$4"
  case "$v" in
    FALSIFIED)
      echo "  falsified        $name"
      echo "                   → $(grep -o "FAILED.*$expect[^—]*—[^\"]*" "$out" | head -1 | cut -c1-150)"
      ;;
    NOT_A_FALSIFIER)
      echo "  NOT A FALSIFIER  $name — '$expect' ran and stayed green with the fix disabled"
      ;;
    DID_NOT_RUN)
      echo "  CHECK DID NOT RUN  $name — '$expect' never appeared in the output."
      echo "                     The sabotage removed a prerequisite this check needs, so the"
      echo "                     probe could not ask its question. It proves NOTHING either way."
      echo "                     Retarget it at a check that still executes under this sabotage."
      ;;
  esac
}
