#!/usr/bin/env bash
# Real native dialogs on an isolated authenticated display, with automatic cleanup.
set -euo pipefail
if [[ $# -eq 0 ]]; then
  echo "Usage: tools/native-ui-test.sh node tools/development-plan-file-smoke.mjs" >&2
  exit 2
fi
if [[ -n ${SUPER_XVFB_BIN_DIR:-} ]]; then export PATH="$SUPER_XVFB_BIN_DIR:$PATH"; fi
for dependency in Xvfb xvfb-run xauth; do
  command -v "$dependency" >/dev/null || { echo "Install $dependency or set SUPER_XVFB_BIN_DIR to the test display tools." >&2; exit 2; }
done
temporary_root=0
if [[ -z ${DEVELOPMENT_TEST_ROOT:-} ]]; then
  temporary_root=1
  DEVELOPMENT_TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/super-native-tests.XXXXXX")
fi
TMPDIR=$(mktemp -d "$DEVELOPMENT_TEST_ROOT/runtime.XXXXXX")
export TMPDIR
export DEVELOPMENT_TEST_ROOT GDK_BACKEND=x11 GDK_SCALE=1 GDK_DPI_SCALE=1 SUPER_NATIVE_NO_WINDOW_MANAGER=1
cleanup() {
  result=$?
  if [[ $temporary_root -eq 1 && $result -eq 0 ]]; then
    rm -rf -- "$DEVELOPMENT_TEST_ROOT"
  elif [[ $temporary_root -eq 1 ]]; then
    echo "Failed-test artifacts retained in $DEVELOPMENT_TEST_ROOT" >&2
  fi
}
trap cleanup EXIT
xvfb-run -a -s '-screen 0 1600x1100x24 -nolisten tcp' "$@"
