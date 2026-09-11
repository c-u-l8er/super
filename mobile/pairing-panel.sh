#!/usr/bin/env bash
# Show the one-use pairing code in a window instead of a file.
#
# The gateway writes its code to a 0600 file and never logs it, so the only way
# to read it was `cat`. This is a native GTK window over that same file: no HTTP
# listener and no code in a URL, both of which would be weaker than the file
# they replace. The code reaches yad on STDIN, never argv, so `ps` cannot show
# it to another process on the machine.
#
#   ./mobile/pairing-panel.sh [PAIR_FILE]     PAIR_FILE, or $SUPER_MOBILE_PAIR_FILE
#   SUPER_MOBILE_PANEL=1 ./mobile/start-local.sh    launch it with the observer
#   ./mobile/pairing-panel.sh --demo          a placeholder code, for screenshots
#
# A new code needs a fresh observer launch, so this window offers no button that
# would claim otherwise. Its lifetime is the code's: the drain bar at the bottom
# is the ten minutes, and it closes when the code is dead.
set -euo pipefail
super_mobile_panel_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
super_mobile_panel_lifetime=600
super_mobile_panel_port="${SUPER_MOBILE_PORT:-4318}"
# ASCII on purpose: `import -window "<title>"` cannot match a non-ASCII title,
# and screenshotting this window is how it gets documented.
super_mobile_panel_title='Super Mobile - pair a device'
# X11 rather than Wayland for the same reason; a Wayland surface is not in the
# X server and cannot be captured by an X screenshot tool.
export GDK_BACKEND="${SUPER_MOBILE_PANEL_BACKEND:-x11}"

super_mobile_panel_demo=0
[[ "${1:-}" == '--demo' ]] && { super_mobile_panel_demo=1; shift; }
super_mobile_panel_file="${1:-${SUPER_MOBILE_PAIR_FILE:-}}"

# Four-character groups. Forty-eight hex characters read off a monitor and typed
# into a phone is where this goes wrong; the app strips the spaces back out.
super_mobile_panel_group(){ sed -E 's/(.{4})/\1 /g;s/ $//' | fold -w 20 | sed -E 's/^ +| +$//g'; }

# Bash's own socket, so this adds no dependency to read a port.
super_mobile_panel_listening(){ (exec 3<>"/dev/tcp/127.0.0.1/$super_mobile_panel_port") 2>/dev/null; }

super_mobile_panel_health(){
  if super_mobile_panel_listening; then
    printf '<span foreground="#7fbf3f">✓</span> observer listening on %s' "$super_mobile_panel_port"
  else
    printf '<span foreground="#e06c5a">✗</span> nothing on %s — the observer is not up, and this code will not pair' "$super_mobile_panel_port"
  fi
}

if (( super_mobile_panel_demo )); then
  super_mobile_panel_file=$(mktemp)
  printf '%s\n' '00001111222233334444555566667777888899990000aaaa' > "$super_mobile_panel_file"
  trap 'rm -f "$super_mobile_panel_file"' EXIT
fi

[[ -n "$super_mobile_panel_file" ]] || {
  echo 'pairing-panel: pass the pairing file, or set SUPER_MOBILE_PAIR_FILE.' >&2; exit 2; }

# The desktop writes the file a moment after it starts, so a panel launched
# alongside it waits rather than reporting a missing code that is on its way.
for _ in $(seq 1 60); do [[ -r "$super_mobile_panel_file" ]] && break; sleep 1; done
[[ -r "$super_mobile_panel_file" ]] || {
  echo "pairing-panel: no pairing file at $super_mobile_panel_file after 60s." >&2; exit 1; }

super_mobile_panel_born=$(stat -c %Y "$super_mobile_panel_file")
super_mobile_panel_left=$(( super_mobile_panel_lifetime - ( $(date +%s) - super_mobile_panel_born ) ))
super_mobile_panel_expires=$(date -d "@$(( super_mobile_panel_born + super_mobile_panel_lifetime ))" +%H:%M:%S)

if (( super_mobile_panel_left <= 5 )); then
  echo 'pairing-panel: that code has expired. Relaunch the observer for a new one.' >&2; exit 1
fi

# Without yad there is still an answer, and it is the one the README gave before
# this script existed — just formatted to be typed.
if ! command -v yad >/dev/null; then
  echo "pairing-panel: yad is not installed; printing the code here instead." >&2
  echo "one use, expires at $super_mobile_panel_expires"
  super_mobile_panel_group < "$super_mobile_panel_file"
  exit 0
fi

super_mobile_panel_group < "$super_mobile_panel_file" | yad \
  --title="$super_mobile_panel_title" --window-icon=phone --width=560 --height=400 \
  --text="<span font='15' weight='bold'>Type this on your phone's Host screen.</span>

Super → Host tab → <i>One-use code from the desktop observer</i>.
Spaces are only to read by; the app strips them.

<span font='11'>One use · expires at <b>$super_mobile_panel_expires</b> · a new code needs a fresh observer launch</span>

<span font='10'>$(super_mobile_panel_health)</span>" \
  --text-info --fontname='Monospace Bold 20' --wrap --margins=10 \
  --timeout="$super_mobile_panel_left" --timeout-indicator=bottom \
  --button='Done:0' || true
