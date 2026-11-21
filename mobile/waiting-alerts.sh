#!/usr/bin/env bash
# One "Waiting on you" alert pass, for systemd (units/super-waiting-alerts.*). Finds node the way start-local.sh does,
# because a user unit's PATH has no nvm.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
node_bin="${SUPER_MOBILE_NODE:-$(command -v node || true)}"
[[ -n "$node_bin" ]] || node_bin=$(ls -1d "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | sort -V | tail -1 || true)
[[ -x "$node_bin" ]] || { echo 'No executable node found; set SUPER_MOBILE_NODE to an absolute path.' >&2; exit 1; }
exec "$node_bin" "$here/waiting-alerts.mjs" pass
