#!/usr/bin/env bash
# check-fixture-build — the canonical builder produces a FRESH artifact, and
# says no when it cannot.
#
# The acceptance battery asks whether the installed payload is statically
# linked. That is embodiment. This asks the other question — **provenance**:
# did this binary come from this invocation of this source, or was it merely
# already there and the right shape?
#
# The distinction is not theoretical. The first builder only forced a
# recompile when the existing artifact looked dynamic, so a planted *static*
# binary passed: cargo calls itself up to date by fingerprint and never
# rebuilt it. The third case below is that exact hole.
set -uo pipefail
cd "$(dirname "$0")/.."

out=carrier-fixture/target/release/super-carrier-fixture
fail=0
ok () { printf '  \033[32mheld\033[0m  %s\n' "$1"; }
no () { printf '  \033[31mFAIL\033[0m  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

printf '\n  D.1.3c·2b·0a · the Carrier payload'"'"'s provenance\n'

bash tools/build-carrier-fixture.sh >/dev/null 2>&1 || { no "the builder runs" "non-zero exit"; exit 1; }
good=$(sha256sum "$out" | cut -d' ' -f1)
ok "the canonical builder produces an artifact ($(printf '%.12s' "$good"))"

# ------------------------------------------------ 1 · a dynamic replacement
dyn=$(mktemp); printf 'int main(void){return 0;}' > "$dyn.c"
if cc -o "$dyn" "$dyn.c" 2>/dev/null && file "$dyn" | grep -q 'dynamically linked'; then
  cp "$dyn" "$out"
  bash tools/build-carrier-fixture.sh >/dev/null 2>&1
  now=$(sha256sum "$out" | cut -d' ' -f1)
  if [ "$now" = "$good" ]; then
    ok "a planted DYNAMIC binary is replaced by a fresh build"
  else
    no "a planted DYNAMIC binary is replaced by a fresh build" "digest is $now"
  fi
else
  no "a dynamic stand-in could be compiled" "no working cc; this case went untested"
fi

# ------------------------------------------------- 2 · a static replacement
#
# The case the previous builder passed. A different STATIC executable is the
# right shape and the wrong provenance, and "not dynamically linked" cannot
# tell them apart.
stat_bin=$(mktemp)
if cc -static -o "$stat_bin" "$dyn.c" 2>/dev/null && ! file "$stat_bin" | grep -q 'dynamically linked'; then
  cp "$stat_bin" "$out"
  bash tools/build-carrier-fixture.sh >/dev/null 2>&1
  now=$(sha256sum "$out" | cut -d' ' -f1)
  if [ "$now" = "$good" ]; then
    ok "a planted STATIC binary is replaced by a fresh build"
  else
    no "a planted STATIC binary is replaced by a fresh build" "digest is $now — provenance not enforced"
  fi
else
  no "a static stand-in could be compiled" "no working static cc; this case went untested"
fi
rm -f "$dyn" "$dyn.c" "$stat_bin"

# --------------------------------------------- 3 · and it is the real thing
#
# Shape and provenance are still not identity: the artifact must also be the
# fixture. It answers `READY <incarnation>` on fd 3, so the cheapest proof
# that it is the right program is that the acceptance battery can drive it —
# asserted here only as "the host still resolves and starts it".
if [ -x host/target/release/super-host ]; then
  # Through a file, not a pipe. `grep -q` exits on its first match and
  # SIGPIPEs the producer, and under `pipefail` that non-zero status becomes
  # the pipeline's — so a check that MATCHED reported failure. The same
  # reasoning as `sabotage-host.sh`'s note about command substitution: the
  # harness's own plumbing is a place defects hide.
  vout=$(mktemp)
  timeout 300 ./host/target/release/super-host verify >"$vout" 2>&1
  if grep -q 'held.*the Carrier payload is STATICALLY linked' "$vout"; then
    ok "the acceptance battery accepts the installed payload"
  else
    no "the acceptance battery accepts the installed payload" "the linkage check did not hold"
  fi
  rm -f "$vout"
else
  printf '  ---   host not built; skipping the acceptance cross-check\n'
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '  fixture build: \033[32mheld\033[0m\n'
else
  printf '  fixture build: \033[31m%s failed\033[0m\n' "$fail"
fi
[ "$fail" -eq 0 ]
