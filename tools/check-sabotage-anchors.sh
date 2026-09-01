#!/usr/bin/env bash
# check-sabotage-anchors — the cheap gate that says a probe still bites.
#
# `tools/sabotage-host.sh` couples to the source in two places, and **both
# fail silently**:
#
#   the sed expression   an edit moves the line and the patch matches nothing.
#                        The battery reports SABOTAGE MISSED — but only after
#                        rebuilding and re-running the host once per probe,
#                        which is the slowest gate in the release.
#
#   the expected check   a check is renamed and the probe can no longer find
#                        the row it was supposed to redden. It reports NOT A
#                        FALSIFIER, which reads like a defect in the probe
#                        rather than in the coupling.
#
# Neither needs the battery to discover. A sed either matches the file or it
# does not, and a check name either exists in the battery's own output or it
# does not — so this runs `verify` **once**, dry-runs every patch against a
# copy, and answers both questions in about the time one probe takes.
#
# It is not a replacement for the battery. It cannot tell you a probe fails to
# falsify for a real reason; it tells you the probe is still aimed at
# something. W.2.3.2 broke two of W.2.3.1's anchors and the complaint arrived
# an hour into a chain — this is the thing that would have said so first.
#
#   bash tools/check-sabotage-anchors.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

HOST=./host/target/release/super-host
[ -x "$HOST" ] || { echo "build the host first: cargo build --release --manifest-path host/Cargo.toml" >&2; exit 1; }

fail=0
ok () { printf '  \033[32mheld\033[0m  %s\n' "$1"; }
no () { printf '  \033[31mFAIL\033[0m  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

printf '\n  sabotage anchors · %s\n\n' "$(grep -c '^probe "' tools/sabotage-host.sh) host probes"

# **The battery's own output, not a grep of the source.** Several check names
# are built in a loop from a census table — `format!("a Carrier may NOT {what}
# …")` — so the literal string a probe waits for appears nowhere in
# `verify.rs`. Asking the artifact rather than the source is the same move
# `check-epoch-mint.sh` makes for the pinned-epoch door, and for the same
# reason: the source is not the thing the probe couples to.
out_file=$(mktemp)
if ! timeout 600 "$HOST" verify >"$out_file" 2>&1; then
  no "the acceptance battery is green before anchors are judged" \
     "super-host verify did not exit 0; every anchor below would be judged against a broken run"
  rm -f "$out_file"
  exit 1
fi
names=$(mktemp)
sed -n 's/^  [^ ]*held[^ ]*  *//p;s/^  [^ ]*FAILED[^ ]*  *//p' "$out_file" > "$names"
ok "the acceptance battery ran ($(grep -c . "$names") check names captured)"

work=$(mktemp -d)
trap 'rm -rf "$work" "$out_file" "$names"' EXIT

i=0
python3 - "$work" <<'PY' > "$work/probes.tsv"
import re, subprocess, sys
src = open('tools/sabotage-host.sh').read()
# Each invocation runs from `probe "` to the blank line before the next
# comment, echo or probe. The function DEFINITION starts `probe ()` and is
# excluded by requiring the quote.
for c in re.findall(r'^probe "(.*?)(?=\n(?:#|echo|probe|\n))', src, re.M | re.S):
    parts = subprocess.run(
        ['bash', '-c', 'printf "%s\\n" "' + c.replace('\\\n', ' ')],
        capture_output=True, text=True).stdout.split('\n')
    parts = [p for p in parts if p != '']
    if len(parts) < 4:
        print('PARSE\t' + c[:60].replace('\n', ' '))
        continue
    print('\t'.join(['P', parts[0], parts[1], parts[2]] + parts[3:]))
PY

while IFS=$'\t' read -r kind name expect file rest; do
  i=$((i + 1))
  if [ "$kind" != "P" ]; then
    no "probe $i parses" "the invocation could not be read: $name"
    continue
  fi

  if [ ! -f "$file" ]; then
    no "probe $i · $name" "target file $file does not exist"
    continue
  fi

  # 1 · the patch still matches
  cp "$file" "$work/t"
  # `rest` holds the remaining tab-separated sed expressions.
  IFS=$'\t' read -r -a exprs <<< "$rest"
  for e in "${exprs[@]}"; do
    [ -n "$e" ] && sed -i "$e" "$work/t"
  done
  if cmp -s "$file" "$work/t"; then
    no "probe $i · $name" "SED MISSED — the pattern no longer matches $file, so the probe patches nothing"
    continue
  fi

  # 2 · the check it waits for still exists
  if ! grep -qF "$expect" "$names"; then
    no "probe $i · $name" "no check in the battery contains '$expect' — the probe can never turn it red"
    continue
  fi

  ok "probe $i · $name"
done < "$work/probes.tsv"

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf '  sabotage anchors: \033[32mheld\033[0m — every probe still patches a line and names a check\n\n'
else
  printf '  sabotage anchors: \033[31m%d failed\033[0m\n\n' "$fail"
  exit 1
fi
