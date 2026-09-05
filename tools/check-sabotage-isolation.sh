#!/usr/bin/env bash
# check-sabotage-isolation — kill a mutating battery mid-sabotage and prove
# the canonical checkout did not move.
#
# **This is the falsifier for the claim `tools/sabotage-isolated.sh` makes.**
# That file argues the canonical tree is safe because it is not the mutation
# target, rather than because a trap restores it. An argument of that shape is
# worth exactly as much as the attempt to break it, so this file makes the
# attempt in the way that actually happened:
#
#     start a battery that mutates source
#     wait until it is genuinely inside its window — a `.orig` exists beside
#       a real source file and a rebuild is running against the sabotaged copy
#     SIGKILL it, which no trap can catch
#     then assert the canonical checkout is byte-identical
#
# `SIGKILL` and not `SIGTERM` deliberately. A trap can catch TERM; the whole
# reason this phase exists is that R0a's battery died in a way no trap could
# have caught, and a falsifier that only fires signals the design can survive
# is not testing the design.
#
# The disposable worktree is ALLOWED to be left dirty and leaked. That is the
# trade being asserted: a temporary directory survives the kill instead of the
# canonical source doing so.
#
# Three process-control traps cost R0b.0 an hour and are avoided here:
#   · bash defers a trap until the foreground child returns, so a signal to
#     the script alone appears to do nothing while `cargo build` runs — this
#     file signals the process GROUP.
#   · `setsid cmd & p=$!` does not yield the command's PGID (setsid re-forks),
#     so the group is read from `ps -o pgid=` on the real process.
#   · `pgrep -f <pat>` matches this script's own command line, so the pattern
#     below is anchored on the worktree path, which this script never has in
#     its own argv.
#
#     bash tools/check-sabotage-isolation.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

pass=0; fail=0
say () { printf '  \033[32mheld\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

echo "sabotage isolation — killed mid-window, uncatchably"
echo

if [ -n "$(git status --porcelain)" ]; then
  echo "REFUSING: canonical tree is dirty; this falsifier needs a clean baseline" >&2
  exit 1
fi

head_before=$(git rev-parse HEAD)
tree_before=$(git rev-parse HEAD^{tree})
# The bytes, not just git's opinion of them: `git status` can be fooled by a
# stale index, and the claim here is about the files.
sum_before=$(git ls-files -z | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1)

wt="$ROOT/../.super-isolation-probe-$$"
rm -rf "$wt"
git worktree add --detach "$wt" "$head_before" >/dev/null 2>&1 || {
  echo "could not create the probe worktree" >&2; exit 1; }

# Built once so the battery reaches its first real rebuild quickly.
( cd "$wt" && bash tools/build-payloads.sh >/dev/null 2>&1 \
    && cargo build --release --manifest-path cockpit/Cargo.toml >/dev/null 2>&1 )

# `sabotage-cockpit.sh` is the subject deliberately: it is the battery with no
# trap of any kind, the one that caused the R0a accident. If isolation holds
# for the worst-behaved battery in the tree it holds for the other seven.
( cd "$wt" && exec bash tools/sabotage-cockpit.sh ) >"$wt/battery.log" 2>&1 &

# Wait for a real source `.orig` to appear — that is the window, and polling
# for it is what makes this deterministic rather than a race against a timer.
src_orig () {
  find "$wt/cockpit/ui" "$wt/cockpit/src" "$wt/cockpit/capabilities" \
       "$wt/cockpit/build.rs" "$wt/dogfood/src" -name '*.orig' 2>/dev/null | head -1
}
inside=""
for _ in $(seq 1 600); do
  inside=$(src_orig); [ -n "$inside" ] && break
  sleep 0.1
done

if [ -z "$inside" ]; then
  bad "the battery never entered a mutation window; nothing was tested"
  pkill -KILL -f "$wt" 2>/dev/null
  git worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  echo; printf 'sabotage isolation: %d held · %d failed\n' "$pass" "$fail"
  exit 1
fi
say "the battery is inside its window — $(basename "$inside") exists beside its source"

# SIGKILL to the whole process group. Anchored on the worktree path so this
# script's own argv cannot match.
victim=$(pgrep -f "$wt/tools/sabotage-cockpit.sh" | head -1)
if [ -z "$victim" ]; then victim=$(pgrep -f "$wt" | head -1); fi
pg=$(ps -o pgid= -p "$victim" 2>/dev/null | tr -d ' ')
if [ -n "$pg" ] && [ "$pg" != "$(ps -o pgid= -p $$ | tr -d ' ')" ]; then
  kill -KILL "-$pg" 2>/dev/null
else
  kill -KILL "$victim" 2>/dev/null
fi
sleep 2
pkill -KILL -f "$wt" 2>/dev/null
sleep 1
say "killed with SIGKILL, which no EXIT trap can catch"

# --- the assertions, all about the CANONICAL tree ------------------------
[ "$(git rev-parse HEAD)" = "$head_before" ] \
  && say "canonical HEAD unmoved · ${head_before:0:12}" \
  || bad "canonical HEAD moved"

[ "$(git rev-parse HEAD^{tree})" = "$tree_before" ] \
  && say "canonical tree object unmoved" || bad "canonical tree object moved"

[ -z "$(git status --porcelain)" ] \
  && say "canonical checkout clean — git reports no modification" \
  || { bad "canonical checkout is DIRTY after an isolated run"; git status --short; }

sum_after=$(git ls-files -z | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1)
[ "$sum_after" = "$sum_before" ] \
  && say "canonical bytes identical — sha256 over every tracked file" \
  || bad "canonical bytes CHANGED"

n_orig=$(find . -path ./cockpit/target -prune -o -name '*.orig' -print 2>/dev/null | wc -l)
[ "$n_orig" -eq 0 ] \
  && say "canonical .orig count = 0" || bad "canonical tree carries $n_orig .orig file(s)"

# The disposable tree is allowed to be wrecked. Showing it is the point: this
# is the damage that would otherwise have landed on the canonical checkout.
if [ -d "$wt" ]; then
  d=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l)
  o=$(find "$wt" -path "$wt/cockpit/target" -prune -o -name '*.orig' -print 2>/dev/null | wc -l)
  printf '  \033[33mnote\033[0m  the disposable worktree absorbed it — %s dirty path(s), %s .orig\n' "$d" "$o"
  if [ "$d" -eq 0 ] && [ "$o" -eq 0 ]; then
    printf '  \033[33mnote\033[0m  it happened to be clean; the kill landed between mutations.\n'
    printf '        Isolation still held, but this run did not exercise the damage.\n'
  fi
fi

git worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
git worktree prune >/dev/null 2>&1

echo
printf 'sabotage isolation: %d held · %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
