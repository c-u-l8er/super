#!/usr/bin/env bash
# Start the private HTTPS front (private-connector.mjs) for tailscale serve, with his Tailscale login and his phone's
# tailnet addresses read now from `tailscale status --json` (tailnet-owner.mjs). Neither is written into the unit or
# any file: the login is his email. Run by units/super-mobile-front.service. If Tailscale is not up yet or the phone
# is not found, this exits 1 and the unit tries again.
set -euo pipefail
super_mobile_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
node=${SUPER_MOBILE_NODE:-}
[[ "$node" == /* && -x "$node" ]] || { echo 'Set SUPER_MOBILE_NODE to an absolute path to node.' >&2; exit 1; }
owner=$("$node" "$super_mobile_dir/tailnet-owner.mjs")
login=${owner%%$'\n'*}
devices=${owner#*$'\n'}
[[ -n "$login" && -n "$devices" && "$devices" != "$owner" ]] || { echo 'Not starting the private front: no owner was read.' >&2; exit 1; }
export SUPER_MOBILE_TAILSCALE_LOGIN="$login" SUPER_MOBILE_OWNER_DEVICES="$devices"
unset owner login devices
exec "$node" "$super_mobile_dir/private-connector.mjs"
