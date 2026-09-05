#!/usr/bin/env bash
# sabotage-isolated — run a mutating battery where the canonical tree is not.
#
# **The invariant, and it is a structural one rather than a hopeful one:**
#
#     the canonical checkout is never the mutation target
#
# not
#
#     the canonical checkout is the mutation target, but bash puts it back.
#
# ## Why a trap is not the safety basis
#
# Every sabotage battery in this tree mutates the file it is testing, builds,
# runs a check, and moves the original back. Seven of the eight carry an EXIT
# trap; `tools/sabotage-cockpit.sh` carries none at all — it restores inline
# at five separate success-path returns, so restoration exists only on the
# path where nothing went wrong. R0a's generator ran that battery, was killed
# externally, and left `dogfood/src/main.rs` sabotaged in the working tree
# with its `.orig` beside it: the payload whose entire claim is that its bytes
# are its own, silently altered, one `git add -A` from being committed.
#
# The obvious repair is to give that file the trap its siblings have. R0b.0
# wrote that patch and then **failed three times to prove it works**, each
# failure teaching the same thing:
#
#   1. bash defers a trap until the current foreground command returns, and
#      these batteries spend their lives inside `cargo build`. A direct
#      `kill -TERM` looks like nothing happened. (Documented at
#      `sabotage-host.sh`'s own trap, and re-derived the hard way.)
#   2. `setsid cmd & p=$!` does not give you the command's process group;
#      setsid re-forks, so `kill -- -$p` signals a group without the script.
#   3. `pgrep -f <pattern>` matches the harness's own command line, so the
#      group kill lands on your own shell.
#
# Three careful attempts could not make a trap fire reliably. That is not a
# comment on the harness; it is the argument. A trap is deferred by foreground
# children, depends on correct process-group targeting, and **cannot catch
# SIGKILL at all**. It is a fine convenience and a bad proof.
#
# A disposable worktree needs none of that reasoning. The canonical tree is
# not modified because it is not the file being modified. A SIGKILL may leak
# a temporary directory — an inconvenience with an `rm -rf` — and cannot
# reach the canonical source, because nothing in the run ever names it.
#
# ## Usage
#
#     bash tools/sabotage-isolated.sh sabotage-host.sh
#     bash tools/sabotage-isolated.sh sabotage-cockpit.sh
#     SABOTAGE_ONLY='fork left' bash tools/sabotage-isolated.sh sabotage-host.sh
#
# `KEEP=1` leaves the worktree behind for inspection.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

battery="${1:-}"
[ -n "$battery" ] || { echo "usage: sabotage-isolated.sh <battery.sh> [args…]" >&2; exit 2; }
[ -f "tools/$battery" ] || { echo "no such battery: tools/$battery" >&2; exit 2; }
shift

# **Refuse a dirty canonical tree, and say why.**
#
# Not fastidiousness: the worktree is created at HEAD, so uncommitted work
# would silently not be under test. A battery that measured a tree the author
# is not looking at is worse than one that refuses.
if [ -n "$(git status --porcelain)" ]; then
  echo "REFUSING: the canonical checkout is dirty." >&2
  echo "  This runner builds a worktree at HEAD, so uncommitted changes would" >&2
  echo "  NOT be under test and the result would be about something else." >&2
  git status --short >&2
  exit 1
fi

head=$(git rev-parse HEAD)
short=$(git rev-parse --short=12 HEAD)
# Recorded so the post-run assertion can say WHICH paths moved, and so a
# clean tree at the end is a comparison rather than a coincidence.
canon_before=$(git status --porcelain)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
wt="$ROOT/../.super-sabotage-$short-$stamp-$$"
evidence="$ROOT/.sabotage-runs"
mkdir -p "$evidence"

# Convenience only. The safety argument above does not rest on this line, and
# the falsifier in `check-sabotage-isolation.sh` kills the run in a way that
# never lets it fire.
cleanup () {
  if [ -n "${KEEP:-}" ]; then
    echo "KEEP=1 — worktree left at $wt" >&2
    return
  fi
  git worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
}
trap cleanup EXIT

echo "# isolated sabotage · $battery · HEAD $short · $stamp"
echo "# worktree  $wt"
git worktree add --detach "$wt" "$head" >/dev/null 2>&1 || {
  echo "could not create the worktree" >&2; exit 1; }

# The battery needs a built host and the installed artifacts. Built INSIDE the
# worktree, so nothing reaches back into the canonical target directories —
# a shared CARGO_TARGET_DIR would put this run's sabotaged object files where
# the next canonical build would trust them.
(
  cd "$wt" || exit 1
  bash tools/build-payloads.sh >/dev/null 2>&1 || { echo "payload build failed" >&2; exit 1; }
  cargo build --release --manifest-path host/Cargo.toml >/dev/null 2>&1 \
    || { echo "host build failed" >&2; exit 1; }
) || exit 1

( cd "$wt" && bash "tools/$battery" "$@" )
rc=$?

# Retained before the worktree goes, because the worktree goes.
if [ -d "$wt/.sabotage-runs" ]; then
  cp -a "$wt/.sabotage-runs/." "$evidence/" 2>/dev/null
  echo "# evidence retained under .sabotage-runs/"
fi

# **The canonical tree is asserted, not assumed.** The whole point is that
# this cannot have changed; a runner that claimed isolation without checking
# would be the same shape as a probe that claimed a check passed without
# looking at it.
canon_after=$(git -C "$ROOT" status --porcelain)
if [ "$canon_after" != "$canon_before" ]; then
  # **Two different facts, and this line used to print one sentence for
  # both** — the same conflation `tools/sabotage-scoring.sh` exists to
  # repair, one layer up. A battery cannot reach the canonical tree: every
  # path it edits is inside the worktree, and this runner never passes it
  # `$ROOT`. So the overwhelmingly likely cause is somebody working in the
  # checkout while the battery ran, which is ordinary on a box where many
  # sessions share one tree.
  #
  # It is still reported and still fails, because "probably that" is not a
  # measurement. The diff below is what tells them apart: paths the battery
  # sabotages are source files under `ampd/lib`, `host/src`, `cockpit/`;
  # anything else is a person.
  echo "CANONICAL TREE MOVED during an isolated run" >&2
  echo "  This is NOT evidence the battery reached it — it edits only inside" >&2
  echo "  the worktree and is never given the canonical path. Concurrent" >&2
  echo "  editing is the usual cause on a shared checkout. The paths:" >&2
  diff <(printf '%s\n' "$canon_before") <(printf '%s\n' "$canon_after") >&2
  exit 1
fi
echo "# canonical checkout unchanged · $(git -C "$ROOT" rev-parse --short=12 HEAD)"
exit $rc
