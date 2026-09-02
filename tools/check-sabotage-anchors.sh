#!/usr/bin/env bash
# check-sabotage-anchors — the cheap gate that says a probe still bites.
#
# **BOTH batteries, since D.1.3c·2b·1.** This read `tools/sabotage-host.sh`
# and nothing else for its whole existence, so the 97 probes in
# `ampd/tools/sabotage.sh` had no anchor gate at all — and one of them broke
# the moment `Ampd.Peer.own/3` changed shape. The break cost a full battery
# run to discover, which is precisely the cost this file exists to avoid. A
# gate that covers one of two coupled things is a gate whose name overstates
# it.
#
# The two batteries couple differently and are judged differently:
#
#   host   probe "<name>" "<expected check>" <file> <sed>…
#          the sed must bite AND the named check must exist in verify's output
#   beam   probe "<name>" <test file> <sed> <file> …
#          the sed must bite AND the named test file must exist. There is no
#          check name: a BEAM probe reddens a whole ExUnit file.
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

printf '\n  sabotage anchors · %s host + %s beam probes\n\n' \
  "$(grep -c '^probe "' tools/sabotage-host.sh)" \
  "$(grep -c '^probe "' ampd/tools/sabotage.sh)"

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

# ------------------------------------------------------------------ beam
#
# Same two questions, different couplings. A BEAM probe names an ExUnit file
# rather than a check, and carries (sed, file) PAIRS rather than one file and
# a list of expressions — so it gets its own parse rather than a flag on the
# host one.
printf '\n'
python3 - <<'PY' > "$work/beam.tsv"
import re, subprocess
src = open('ampd/tools/sabotage.sh').read()
for c in re.findall(r'^probe "(.*?)(?=\n(?:#|echo|probe|\n))', src, re.M | re.S):
    parts = subprocess.run(
        ['bash', '-c', 'printf "%s\\n" "' + c.replace('\\\n', ' ')],
        capture_output=True, text=True).stdout.split('\n')
    parts = [p for p in parts if p != '']
    if len(parts) < 4 or (len(parts) - 2) % 2 != 0:
        print('PARSE\t' + c[:60].replace('\n', ' '))
        continue
    print('\t'.join(['B', parts[0], parts[1]] + parts[2:]))
PY

j=0
while IFS=$'\t' read -r kind name tf rest; do
  j=$((j + 1))
  if [ "$kind" != "B" ]; then
    no "beam probe $j parses" "the invocation could not be read: $name"
    continue
  fi

  if [ ! -f "ampd/$tf" ]; then
    no "beam probe $j · $name" "test file ampd/$tf does not exist"
    continue
  fi

  # **Each expression against a PRISTINE copy, not cumulatively.**
  #
  # Per-expression is the strict question and the one worth asking: a probe
  # with two patches, one of which has gone stale, is carried by the other
  # under a whole-file comparison and reports held while proving half of what
  # it claims. Probe 47 is exactly that — its first expression stopped
  # matching `bridge.ex` at some earlier revision and its second still does.
  #
  # But cumulative application makes that check wrong in the other direction.
  # Probe 55 patches the same field at two indentations, and `sed s@…@…@`
  # without `g` still matches the deeper line as a substring — so the first
  # expression legitimately does both, and comparing after it reports the
  # second as stale when it is merely subsumed. Against a pristine copy both
  # bite, which is the true answer.
  #
  # The case this cannot see is an expression that only matches *after* an
  # earlier one has run. No probe in either battery is written that way, and
  # one that were would be reported here rather than passing silently.
  IFS=$'\t' read -r -a toks <<< "$rest"
  n=${#toks[@]}
  k=0
  missed=""
  while [ "$k" -lt "$n" ]; do
    e="${toks[$k]}"; f="ampd/${toks[$((k + 1))]}"
    k=$((k + 2))
    if [ ! -f "$f" ]; then missed="target file $f does not exist"; break; fi
    cp "$f" "$work/b.probe"
    sed -i "$e" "$work/b.probe"
    if cmp -s "$f" "$work/b.probe"; then
      missed="SED MISSED — '${e:0:60}' no longer matches $f, so the probe patches nothing"
      break
    fi
  done

  if [ -n "$missed" ]; then
    no "beam probe $j · $name" "$missed"
  else
    ok "beam probe $j · $name"
  fi
done < "$work/beam.tsv"

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf '  sabotage anchors: \033[32mheld\033[0m — every probe still patches a line and names a check\n\n'
else
  printf '  sabotage anchors: \033[31m%d failed\033[0m\n\n' "$fail"
  exit 1
fi
