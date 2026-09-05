#!/usr/bin/env bash
# check-runtime-dir-sweep — what the startup sweep may and may not remove.
#
# `Runtime::start` deletes stale `$XDG_RUNTIME_DIR/ampd-<pid>-<stamp>`
# directories before adding one of its own. 502 of them had accumulated;
# `Runtime::release` is the only other thing that removes one, so every
# unclean exit — a sabotage SIGKILL, a harness timeout, a session interrupt —
# left one behind permanently.
#
# **A sweep is a deletion, so the interesting cases are all the ones it must
# NOT do**, and this box is worked on by many concurrent sessions sharing one
# checkout. Six of the seven assertions below are refusals.
#
# The fixtures are planted in a base directory this file owns, which is why
# `super-host sweep-runtime-dirs <base>` exists: the sweep is called from
# `Runtime::start` against the real runtime directory, and a test may not
# plant anything there.
#
#     bash tools/check-runtime-dir-sweep.sh
set -uo pipefail
cd "$(dirname "$0")/.."

HOST=./host/target/release/super-host
[ -x "$HOST" ] || { echo "build the host first" >&2; exit 1; }

base=$(mktemp -d)
trap 'rm -rf "$base"' EXIT

pass=0; fail=0
say () { printf '  \033[32mheld\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

old () { touch -d '3 hours ago' "$1"; }   # past the one-hour grace period

# A pid that is certainly gone. `$$` is alive, so a value above the maximum
# cannot name a live process; if the box ever allows it, the fixture below
# proves the sweep still refuses a LIVE pid, which is the direction that
# matters.
deadpid=$(( $(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 4194304) - 1 ))
while [ -d "/proc/$deadpid" ]; do deadpid=$((deadpid-1)); done

# --- the fixtures ---------------------------------------------------------
mkdir -p "$base/ampd-$deadpid-1788000000000000000"; old "$base/ampd-$deadpid-1788000000000000000"
mkdir -p "$base/ampd-$$-1788000000000000001";       old "$base/ampd-$$-1788000000000000001"
mkdir -p "$base/ampd-$deadpid-1788000000000000002/held.sock"
                                                     old "$base/ampd-$deadpid-1788000000000000002"
mkdir -p "$base/ampd-$deadpid-1788000000000000003"   # fresh: no `old`
mkdir -p "$base/ampd-pair-abc123";                   old "$base/ampd-pair-abc123"
mkdir -p "$base/ampd-pair-def456/live.sock";         old "$base/ampd-pair-def456"
mkdir -p "$base/something-else";                     old "$base/something-else"
mkdir -p "$base/ampd-notanumber-123";                old "$base/ampd-notanumber-123"
: > "$base/ampd-$deadpid-1788000000000000004"        # a FILE, not a directory
old "$base/ampd-$deadpid-1788000000000000004"

left=$("$HOST" sweep-runtime-dirs "$base")
gone () { ! grep -qxF "$1" <<<"$left"; }
kept () {   grep -qxF "$1" <<<"$left"; }

echo "runtime-dir sweep — one removal, and every refusal around it"
echo

gone "ampd-$deadpid-1788000000000000000" \
  && say "removes an empty, aged directory whose pid is gone" \
  || bad "did NOT remove the one directory it exists to remove"

kept "ampd-$$-1788000000000000001" \
  && say "refuses one whose pid is ALIVE — a parallel session keeps its own" \
  || bad "removed a live process's directory"

kept "ampd-$deadpid-1788000000000000002" \
  && say "refuses a NON-EMPTY directory, dead pid or not" \
  || bad "removed a directory with content in it"

kept "ampd-$deadpid-1788000000000000003" \
  && say "refuses one inside the grace period, however dead its pid" \
  || bad "removed a freshly created directory"

kept "ampd-pair-abc123" && kept "ampd-pair-def456" \
  && say "does not touch ampd-pair-* — those are the BEAM's, and hold real sockets" \
  || bad "removed an ampd-pair directory"

kept "something-else" && kept "ampd-notanumber-123" \
  && say "refuses anything not named ampd-<digits>-<digits>" \
  || bad "removed an unrelated entry"

kept "ampd-$deadpid-1788000000000000004" \
  && say "refuses a plain FILE with a matching name" \
  || bad "removed a file"

echo
printf 'runtime-dir sweep: %d held · %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
