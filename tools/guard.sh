#!/usr/bin/env bash
# guard — the tree-integrity bracket around an adversarial gate.
#
# Extracted from `release.sh` at W.1.3.2a so that something other than the
# release can run it. W.1.3.1 wrote "the guard has its own falsifier" in a
# review brief and there was no such harness: the sentence was the proof.
# `tools/sabotage-guard.sh` is the harness now, and it found that two of
# the three cases the bracket claims to catch were not caught.
#
# Sourced, not executed. `guarded` calls `exit` on refusal, so a caller
# that wants to survive a refusal runs it in a subshell.

# `*.orig` is excluded from the fingerprint on purpose — a sabotage
# harness's own backup is not a modification of the source. Which is why
# the presence of one has to be part of the verdict separately: "restored
# the source, left the backup" fingerprints IDENTICAL.
fingerprint () { find "$@" -type f \! -name '*.orig' -print0 |
  sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1; }

guarded () {                       # guarded <label> <paths…> -- <command…>
  local label="$1"; shift
  local paths=(); while [ "$1" != "--" ]; do paths+=("$1"); shift; done; shift
  local before; before=$(fingerprint "${paths[@]}")

  # **THE BRACKET DID NOT SURVIVE THE CASE IT WAS BUILT FOR.**
  #
  # `release.sh` runs under `set -e` and this ran the harness as a bare
  # `"$@"`, so a harness that died — killed, or exiting nonzero because one
  # probe came back NOT — took the whole script with it BEFORE the
  # post-fingerprint line executed. Packaging stopped, which is the outcome
  # you want; the bracket never looked at the tree, which is the thing it
  # exists to do. A dirty tree and no report is the F.8.1 shape one level
  # up: the check that could see the damage never ran.
  local had_e=0; case $- in *e*) had_e=1;; esac
  local rc=0
  set +e; "$@"; rc=$?; [ "$had_e" = 1 ] && set -e

  local after; after=$(fingerprint "${paths[@]}")
  local orig;  orig=$(find "${paths[@]}" -name '*.orig' -print 2>/dev/null)

  if [ "$before" != "$after" ] || [ -n "$orig" ]; then
    echo "RELEASE REFUSED · $label left the source tree modified." >&2
    echo "  A sabotage harness edits sources in place and restores them. This one" >&2
    echo "  did not restore, so the tree is no longer what the suites tested and" >&2
    echo "  this is not a release. (harness exit status: $rc)" >&2
    [ "$before" != "$after" ] && echo "  fingerprint moved: $before -> $after" >&2
    [ -n "$orig" ] && { echo "  leftover backups:" >&2; echo "$orig" | sed 's/^/    /' >&2; }
    exit 1
  fi
  if [ "$rc" -ne 0 ]; then
    echo "RELEASE REFUSED · $label exited $rc." >&2
    echo "  The tree is clean — the bracket checked, which is the part that was" >&2
    echo "  broken — but a harness reporting a law it could not falsify is a" >&2
    echo "  failed gate, not a warning." >&2
    exit "$rc"
  fi
  echo "tree integrity: $label restored what it sabotaged"
}
