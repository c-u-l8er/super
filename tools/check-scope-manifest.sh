#!/usr/bin/env bash
# check-scope-manifest — the two edges a validation job stands on.
#
# Phase A · A8/A15. Freezes the vectors R0b.1's native predicate will have
# to match, and proves the manifest separates two questions that a single
# green suite would let drift into one:
#
#     SCOPE MEMBERSHIP   is this file part of the snapshot the job reads
#     THE PREDICATE      does a file in scope contain a literal NUL
#
# A checker that got scope wrong and predicate right looks exactly like a
# checker that got both right, until the day it does not. So each is moved
# independently here and the other is held still.
#
# **Why the canonical checker is the reference and not a Rust port.** R0b.0
# costed running `check-source-hygiene.mjs` inside a Carrier: node needs four
# more Landlock grants against a floor cap of four, plus reversing the
# `clone` denial. Refused. The alternative — reimplementing it natively —
# splits into an irreducible dozen-line predicate and a hundred lines of
# accumulated scope judgement, and only the first is safe to rewrite. These
# vectors are what will hold the two implementations to the same answer.
#
#     bash tools/check-scope-manifest.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

pass=0; fail=0
say () { printf '  \033[32mheld\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

# A disposable materialization. Never the canonical checkout: this file
# plants NUL bytes, and E0 established that the tree a battery mutates must
# not be the one anybody is working in.
if [ -n "$(git status --porcelain)" ]; then
  echo "REFUSING: the canonical checkout is dirty; this needs a clean HEAD to materialize" >&2
  exit 1
fi
wt="$ROOT/../.super-scope-vectors-$$"
rm -rf "$wt"
git worktree add --detach "$wt" HEAD >/dev/null 2>&1 || {
  echo "could not materialize" >&2; exit 1; }
cleanup () { git worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"; }
trap cleanup EXIT

hygiene () { (cd "$ROOT" && node tools/check-source-hygiene.mjs "$wt" 2>&1); }
digest  () { (cd "$ROOT" && node tools/scope-manifest.mjs "$wt" 2>/dev/null | tail -1 \
              | sed 's/.*scope_digest //'); }
count   () { (cd "$ROOT" && node tools/scope-manifest.mjs "$wt" 2>/dev/null | tail -1 \
              | sed 's/scope manifest: \([0-9]*\) file.*/\1/'); }

echo "scope manifest — the two edges, moved one at a time"
echo

# ---------------------------------------------------------------- vector 1
base_out=$(hygiene); base_rc=$?
base_digest=$(digest)
base_count=$(count)

[ "$base_rc" -eq 0 ] \
  && say "clean basis · canonical checker GREEN — $(sed 's/.*clean — //' <<<"$base_out")" \
  || bad "clean basis should be green, got: $base_out"

[ -n "$base_digest" ] && [ ${#base_digest} -eq 64 ] \
  && say "clean basis · scope_digest is a 64-char digest over $base_count file(s)" \
  || bad "no scope digest: $base_digest"

# ---------------------------------------------------------------- vector 2
#
# A NUL in an IN-SCOPE file. `.md` matches TEXT and README.md is shipped,
# so its membership is not in question — which is what makes this vector
# about the predicate alone.
target="README.md"
printf 'a\000b\n' >> "$wt/$target"

nul_out=$(hygiene); nul_rc=$?
nul_digest=$(digest)
nul_count=$(count)

[ "$nul_rc" -ne 0 ] \
  && say "NUL in an in-scope file · canonical checker RED" \
  || bad "a NUL in $target must turn the checker red"

grep -q "$target" <<<"$nul_out" \
  && say "…and it names the offending file — $target" \
  || bad "the refusal must name the file: $nul_out"

[ "$nul_digest" != "$base_digest" ] \
  && say "…and the scope_digest MOVES, so the basis is visibly not the admitted one" \
  || bad "editing an in-scope file must change the scope digest"

[ "$nul_count" = "$base_count" ] \
  && say "…while the file COUNT is unchanged — content moved, membership did not" \
  || bad "count changed ($base_count → $nul_count) when only content did"

git -C "$wt" checkout -- "$target" 2>/dev/null

# ---------------------------------------------------------------- vector 3
#
# A NUL in an OUT-OF-SCOPE file. `.orig` is in SKIP_EXT deterministically,
# so this is membership alone with the predicate held still. Both suites
# must ignore it, and a checker that started reading it would go red here
# without any in-scope file having changed.
out_of_scope="$wt/README.md.orig"
printf 'x\000y\n' > "$out_of_scope"

oos_out=$(hygiene); oos_rc=$?
oos_digest=$(digest)
oos_count=$(count)

[ "$oos_rc" -eq 0 ] \
  && say "NUL in an out-of-scope file (.orig) · canonical checker still GREEN" \
  || bad "an out-of-scope NUL must not turn the checker red: $oos_out"

[ "$oos_digest" = "$base_digest" ] \
  && say "…and the scope_digest is UNCHANGED — it is not in the snapshot" \
  || bad "an out-of-scope file must not move the scope digest"

[ "$oos_count" = "$base_count" ] \
  && say "…and the file count is unchanged — $base_count" \
  || bad "count moved ($base_count → $oos_count) for an out-of-scope file"

rm -f "$out_of_scope"

# ---------------------------------------------------------------- vector 4
#
# Membership moving on its own: a NEW in-scope file, no NUL anywhere. The
# predicate stays true and the basis still changes, which is the case a
# digest-free manifest could not express at all.
printf 'new and clean\n' > "$wt/PHASE_A_VECTOR.md"
add_digest=$(digest); add_count=$(count); add_out=$(hygiene); add_rc=$?

[ "$add_rc" -eq 0 ] \
  && say "a new clean in-scope file · checker GREEN — the predicate is still true" \
  || bad "adding a clean file must not turn the checker red: $add_out"

[ "$add_digest" != "$base_digest" ] && [ "$add_count" -eq $((base_count + 1)) ] \
  && say "…and BOTH the digest and the count move — membership changed, not content" \
  || bad "a new in-scope file must move digest and count ($base_count → $add_count)"

rm -f "$wt/PHASE_A_VECTOR.md"

# ---------------------------------------------------------------- vector 5
final_digest=$(digest)
[ "$final_digest" = "$base_digest" ] \
  && say "every mutation reverted · scope_digest returns to the admitted value" \
  || bad "the digest did not return to baseline: $base_digest → $final_digest"

echo
echo "  frozen vectors for R0b.1 — the native predicate must match all of these:"
echo "    clean                        GREEN · digest $base_digest"
echo "    NUL in README.md             RED   · names README.md · digest moves"
echo "    NUL in README.md.orig        GREEN · digest unchanged"
echo "    new clean .md                GREEN · digest and count both move"
echo
printf 'scope manifest: %d held · %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
