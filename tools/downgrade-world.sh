#!/usr/bin/env bash
# downgrade-world — put review bodies back into a world so an OLDER runtime can
# open it, durably, or refuse and change nothing.
#
#   tools/downgrade-world.sh <world-dir> [--check] [--report <file>]
#
# Exit 0: converted, synced and read back (or --check: downgradable).
# Exit 2: refused — the report on stdout says why, and the world is untouched.
# Exit 3: bad invocation.  Exit 75: the world is locked (a host is running).
#
# The lock is the same flock(2) a host holds for its lifetime, taken here for
# the WHOLE run, so a host that starts meanwhile parks on it instead of racing
# the write. Stop the desktop first; this refuses rather than waits.
#
# Then, in order: the merge is reverted and the old runtime rebuilt, and only
# then is the desktop started on the converted world. If this exits 2, do not
# downgrade: each block in the report names the attempt, the path, the side and
# the reason, and `too-large` means a review the old shape cannot hold at all.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
if [[ $# -lt 1 || $1 == -* ]]; then
  echo "usage: tools/downgrade-world.sh <world-dir> [--check] [--report <file>]" >&2
  exit 3
fi
world=$(cd "$1" && pwd)
shift
if [[ ! -f $world/world.json ]]; then
  echo "downgrade-world: $world has no world.json — not a world, nothing done" >&2
  exit 2
fi
if [[ ! -e $world/world.lock ]]; then
  # A host creates this the first time it opens a world, so its absence means
  # no host ever has. It is the one file this script may add: the lock is what
  # keeps a host that starts meanwhile from racing the write.
  echo "downgrade-world: creating $world/world.lock (no host has opened this world)" >&2
fi
set +e
flock -n -E 75 "$world/world.lock" \
  env AMPD_DATA_DIR="$world" MIX_ENV="${MIX_ENV:-dev}" \
  sh -c 'cd "$1" && shift && exec mix run --no-start -e "Ampd.Downgrade.main(System.argv())" -- "$@"' \
  sh "$here/ampd" "$world" --lock-held "$@"
code=$?
set -e
if [[ $code -eq 75 ]]; then
  echo "downgrade-world: $world/world.lock is held — a host is running on this world. Stop it first; nothing done." >&2
fi
exit "$code"
