#!/usr/bin/env bash
# Start the opt-in, read-only companion with the existing desktop build.
set -euo pipefail
super_mobile_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
super_mobile_binary="$super_mobile_dir/../cockpit/target/release/super-cockpit"
[[ -x "$super_mobile_binary" ]] || { echo 'Build the Super desktop release first.' >&2; exit 1; }
export AMPD_DIR="$super_mobile_dir/../ampd"
# An absolute path, resolved here. The cockpit refuses a relative or empty one
# and then simply does not start the gateway, so a launcher whose PATH lacks
# node (a desktop launcher, a systemd unit, anything but a login shell) leaves
# port 4318 refusing connections with no error that names the cause.
super_mobile_node="${SUPER_MOBILE_NODE:-$(command -v node || true)}"
[[ -n "$super_mobile_node" ]] || super_mobile_node=$(ls -1d "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | sort -V | tail -1 || true)
[[ -x "$super_mobile_node" ]] || { echo 'No executable node found; set SUPER_MOBILE_NODE to an absolute path.' >&2; exit 1; }
export SUPER_MOBILE_NODE="$(readlink -f "$super_mobile_node")"
export SUPER_MOBILE_GATEWAY="$super_mobile_dir/server.mjs"
super_mobile_pair_dir=$(mktemp -d "${TMPDIR:-/tmp}/super-mobile-pair.XXXXXX")
export SUPER_MOBILE_PAIR_FILE="$super_mobile_pair_dir/code"
echo "Mobile pairing file: $SUPER_MOBILE_PAIR_FILE (one use, expires after 10 minutes)." >&2

# SUPER_MOBILE_PANEL=1 shows the code in a window instead of leaving it in a
# file nobody can read without a terminal. Started before the desktop, because
# the gateway writes the code a moment after launching; the panel waits for it.
if [[ "${SUPER_MOBILE_PANEL:-0}" == 1 ]]; then
  "$super_mobile_dir/pairing-panel.sh" "$SUPER_MOBILE_PAIR_FILE" &
fi

exec "$super_mobile_dir/../tools/start-desktop.sh" "$@"
