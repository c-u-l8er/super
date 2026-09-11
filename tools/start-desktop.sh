#!/usr/bin/env bash
# Launch on the native desktop backend, independent of a test runner's GDK setting.
set -euo pipefail
super_desktop_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
super_desktop_binary="$super_desktop_root/cockpit/target/release/super-cockpit"
[[ -x "$super_desktop_binary" ]] || { echo 'Build the Super desktop release first.' >&2; exit 1; }
export AMPD_DIR="$super_desktop_root/ampd"
# Native Wayland first, with X11 fallback for X11 desktops. Explicit troubleshooting
# overrides belong to this launcher; native-ui-test.sh continues to use Xvfb/X11.
export GDK_BACKEND="${SUPER_DESKTOP_BACKEND:-wayland,x11}"
exec "$super_desktop_binary" "$@"
