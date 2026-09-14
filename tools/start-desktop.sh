#!/usr/bin/env bash
# Launch on the native desktop backend, independent of a test runner's GDK setting.
set -euo pipefail
super_desktop_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
super_desktop_binary="$super_desktop_root/cockpit/target/release/super-cockpit"
[[ -x "$super_desktop_binary" ]] || { echo 'Build the Super desktop release first.' >&2; exit 1; }
export AMPD_DIR="$super_desktop_root/ampd"
# The embedded GTK/WebKit overlay is verified on X11 (including XWayland).
# Native Wayland currently corrupts the reparented view on the target desktop.
# Keep the product launcher on the same rendering path as the native checks.
export GDK_BACKEND="${SUPER_DESKTOP_BACKEND:-x11}"
export WEBKIT_DISABLE_COMPOSITING_MODE="${WEBKIT_DISABLE_COMPOSITING_MODE:-1}"
# The road is the desktop shell; Super lives in its sign. Tests can opt out.
export SUPER_ROAD="${SUPER_ROAD:-1}"
exec "$super_desktop_binary" "$@"
