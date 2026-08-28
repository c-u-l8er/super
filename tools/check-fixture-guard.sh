#!/usr/bin/env bash
# The demo fixture may write into a world this program created and into no
# other.
#
# `SUPER_COCKPIT_FIXTURE=1` mints authority — through ordinary commands on
# ordinary channels, but authority all the same. A launch that took that
# flag against the world a person actually uses would put demo grants in
# their world, and a fixture that *can* do that eventually will, on the
# wrong launch, with the wrong environment inherited from a shell.
#
# The judgement is `worker::fixture_allowed`, extracted from the I/O so it
# can be exercised without booting a runtime against somebody's world in
# order to watch it not be touched — a gate only runnable in production is
# a gate nobody runs twice. `super-cockpit --fixture-check` prints that
# function's answer for the environment it is given, and this asks it under
# both.
#
# `XDG_STATE_HOME` is redirected throughout, so even the persistent branch
# names a directory under /tmp rather than the caller's real world.
set -uo pipefail
cd "$(dirname "$0")/.."

APP=./cockpit/target/release/super-cockpit
[ -x "$APP" ] || { echo "build the cockpit first" >&2; exit 2; }

held=0; failed=0
check () {
  if [ "$2" = "yes" ]; then
    printf '  \033[32mheld\033[0m         %s\n' "$1"; held=$((held+1))
  else
    printf '  \033[31mFAILED\033[0m       %s\n' "$1"
    [ -n "${3:-}" ] && printf '               %s\n' "$3"
    failed=$((failed+1))
  fi
}

probe_home=$(mktemp -d)
trap 'rm -rf "$probe_home"' EXIT

echo "[&] Super — cockpit fixture guard"
echo

eph=$(SUPER_WORLD_MODE=ephemeral XDG_STATE_HOME="$probe_home" "$APP" --fixture-check)
per=$(XDG_STATE_HOME="$probe_home" "$APP" --fixture-check)

case "$eph" in
  *'"fixture_allowed":true'*) ok=yes ;;
  *) ok=no ;;
esac
check "the fixture is allowed against an ephemeral world" "$ok" "$eph"

case "$per" in
  *'"fixture_allowed":false'*) ok=yes ;;
  *) ok=no ;;
esac
check "the fixture is refused against a persistent world" "$ok" "$per"

case "$per" in
  *"$probe_home"*) ok=yes ;;
  *) ok=no ;;
esac
check "a persistent world is the one XDG_STATE_HOME names" "$ok" "$per"

echo
# Prefixed — see the note in `tools/cockpit-battery.mjs`. A bare
# `N held · M failed` here is a figure `emit-measurements` would file under
# `super-host verify` if this ever ran first.
echo "fixture guard: $held held · $failed failed"
[ "$failed" -eq 0 ]
