#!/usr/bin/env bash
# sabotage-scope — the artifact/measurement boundary, falsified.
#
# W.1.4.1's receipt recorded `113 text assets` and bound it to the SHA-256
# of an archive containing 112. Nothing was transcribed and nothing was
# typed: both numbers came out of the same tool on the same tree within the
# same minute. The gap was in the SET. `check-source-hygiene` counted the
# working tree at stage 3, which still held the previous round's sibling
# receipt; `rm -f and-super-rev-*` deleted it at stage 27; the archive was
# built at stage 28.
#
# The law that closes it:
#
#   A RELEASE MEASUREMENT MUST QUANTIFY THE SAME ARTIFACT SET THE RECEIPT
#   BINDS. Measurement scope is part of artifact identity.
#
# `tools/release-scope.mjs` is the one declaration, and
# `tools/replay-artifact.mjs` re-derives the figures from the shipped bytes.
# This harness is what says either of those can refuse anything — which is
# the lesson of `sabotage-counts.sh`, whose subject gate had never refused
# anything at all, and of W.1.3.1, where "the guard has its own falsifier"
# was a sentence in a brief with no harness under it.
#
# Every case runs against a scratch tree this harness owns and runs the
# COPY's tools, so the real tree is never touched and the code under test
# is the code that ships.
set -uo pipefail
cd "$(dirname "$0")/.."

CAUGHT=0; NOT=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Build the pristine copy once. `_build`, `host/target` and any existing
# archive are excluded because they are large and irrelevant; the crash
# dump is excluded because the scope declaration excludes it, and a harness
# that carried it would be testing a tree the packager would refuse.
MASTER="$WORK/master"; mkdir -p "$MASTER"
tar -cf - --exclude=./ampd/_build --exclude=./host/target --exclude=./ampd/.elixir_ls \
          --exclude='./*.zip' --exclude='./ampd/erl_crash.dump' --exclude=./old_scrap . \
  | tar -xf - -C "$MASTER"

fresh () {                            # fresh → $T is a clean copy of the tree
  rm -rf "$WORK/t"; cp -a "$MASTER" "$WORK/t"; T="$WORK/t"
}

# **A NONZERO EXIT IS NOT A VERDICT** — the rule `sabotage-guard.sh` learned
# the hard way. Each case names the SENTENCE the gate has to produce, so a
# gate that dies for an unrelated reason is not scored as a catch.
caught_ () {                          # caught_ <name> <sentence> -- <cmd…>
  local name="$1" want="$2"; shift 2; [ "$1" = "--" ] && shift
  local out; out=$( "$@" 2>&1 )
  if grep -qF "$want" <<<"$out"; then
    echo "caught     $name"; CAUGHT=$((CAUGHT+1))
  else
    echo "NOT        $name — never said '$want'"
    echo "$out" | sed 's/^/           /'
    NOT=$((NOT+1))
  fi
}

hygiene_count () { node "$T/tools/check-source-hygiene.mjs" 2>&1 |
                   sed -n 's/^source hygiene: clean — \([0-9]*\) source text assets.*/\1/p'; }

# Rewrite a valid archive, dropping or editing one entry. The result is a
# well-formed ZIP — this is a SEMANTIC tamper, not a corrupt file, which is
# the case W.1.4.2's replay could not see.
variant () {                          # variant <src> <dst> drop|tamper <path>
  python3 - "$@" <<'PY'
import sys, zipfile
src, dst, mode, target = sys.argv[1:5]
zin = zipfile.ZipFile(src)
with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as zout:
    for it in zin.infolist():
        if it.filename.endswith('/'): continue
        data = zin.read(it.filename)
        if it.filename == target:
            if mode == 'drop': continue
            # One byte-length-preserving edit, so path count and NUL absence
            # are untouched and only the CONTENT differs.
            data = data.replace(b'projection_digest;', b'projection_digestX', 1)
        zout.writestr(it, data)
PY
}

# A measurements receipt the scratch tree owns, so replay has something to
# reproduce without this harness depending on where the real chain got to.
seed_measurements () {
  local n; n=$(hygiene_count)
  node -e '
    const fs=require("fs"), [p,n]=process.argv.slice(1);
    const m=JSON.parse(fs.readFileSync(p,"utf8"));
    m.figures.source_text_assets={value:Number(n),gate:"check-source-hygiene",
      noun:"source text assets",reported:true,prose:"\\d+\\s+source text assets"};
    fs.writeFileSync(p, JSON.stringify(m,null,2)+"\n");
  ' "$T/site/proof/measurements.json" "$n"
}

# ── 1. THE W.1.4.1 DEFECT ITSELF ─────────────────────────────────────────
# A previous round's sibling receipt in the tree must not move the figure.
# This is an EQUALITY, not a refusal: the correct behaviour is that nothing
# happens, which is exactly the kind of property that never gets checked.
fresh
BEFORE=$(hygiene_count)
cp "$T/site/proof/measurements.json" "$T/and-super-rev-w999.receipt.json"
AFTER=$(hygiene_count)
if [ "$BEFORE" = "$AFTER" ] && [ -n "$BEFORE" ]; then
  echo "caught     a stray sibling receipt does not move the figure ($BEFORE = $AFTER)"
  CAUGHT=$((CAUGHT+1))
else
  echo "NOT        a stray sibling receipt moved the figure: $BEFORE -> $AFTER"
  echo "           This is W.1.4.1 exactly, and it is not fixed."
  NOT=$((NOT+1))
fi

# ── 2 & 3. THE WIDENED UNIVERSE IS REAL ──────────────────────────────────
# Both files shipped in W.1.4.1 and neither could be seen by the gate whose
# stated purpose is "no NUL in any text asset": `.c` matched no extension in
# the old TEXT pattern, and the old walker skipped every directory named
# `preview`. A gate that cannot see a file cannot protect it.
fresh
printf '\0' >> "$T/ampd/c_src/ampd_fd_nif.c"
caught_ "a NUL in the shipped C source (invisible to the old gate)" \
        "ampd/c_src/ampd_fd_nif.c" -- node "$T/tools/check-source-hygiene.mjs"

fresh
printf '\0' >> "$T/site/preview/preview-meta.json"
caught_ "a NUL in the shipped preview JSON (invisible to the old gate)" \
        "site/preview/preview-meta.json" -- node "$T/tools/check-source-hygiene.mjs"

# ── 4. NOTHING SHIPS UNCLASSIFIED ────────────────────────────────────────
# `ampd/erl_crash.dump` rode along for four revisions — five megabytes,
# gitignored, 40% of the archive — because no list mentioned it either way.
# Silence is not a decision.
fresh
printf 'opaque bytes\n' > "$T/stray.bin"
caught_ "a file the scope declaration does not classify is refused" \
        "files the scope declaration does not classify" \
        -- node "$T/tools/package.mjs" and-super-rev-probe.zip

# ── 5. THE ARCHIVE IS THE MEASURED SET ───────────────────────────────────
# **THIS IS W.1.4.1'S SHAPE.** A file arriving between the gate and the
# packager is in the archive and not in the figures; W.1.4.1's receipt lost
# a file the other way round. Either direction, the number describes a set
# the hash does not.
#
# The first version of this case added the file AFTER packaging and expected
# a refusal. It did not get one, correctly: an archive built at T2 is not
# wrong about a file that appeared at T3, and the release is the archive.
# Testing that would have been testing something that is not a law.
fresh
seed_measurements
printf '# arrived between the gate and the packager\n' > "$T/docs/late.md"
node "$T/tools/package.mjs" and-super-rev-probe.zip "$WORK/man" > /dev/null
caught_ "a file added between measurement and packaging makes the replay refuse" \
        "source_text_assets: the receipt says" \
        -- node "$T/tools/replay-artifact.mjs" and-super-rev-probe.zip "$WORK/man"

# ── 5a. FALSIFIER A · A DECLARED FILE MISSING FROM THE ARCHIVE ───────────
# **W.1.4.2's replay accepted this.** It derived the expected file list by
# walking the extracted archive, so a file absent from the archive could
# never appear in the list of files the archive was missing — the branch was
# dead code that read like a check. The only opaque file in the release is
# the one used here, because dropping it leaves every text count identical.
fresh
seed_measurements
node "$T/tools/package.mjs" and-super-rev-probe.zip "$WORK/man" > /dev/null
variant "$T/and-super-rev-probe.zip" "$T/dropped.zip" drop site/preview/hero-light-preview.png
caught_ "a declared file removed from a valid archive is refused" \
        "the archive does not contain" \
        -- node "$T/tools/replay-artifact.mjs" dropped.zip "$WORK/man"

# ── 5b. FALSIFIER B · SAME PATHS, SAME COUNTS, DIFFERENT BYTES ───────────
# **The one that matters.** W.1.4.2 accepted an archive whose
# `app-prototype.html` had `stabilityToken` reverted to returning the view
# clock instead of the projection digest — same paths, same count, no NUL —
# and that archive's own authority battery failed six of its assertions,
# beside a receipt recording zero. A measurement is evidence about bytes.
fresh
seed_measurements
node "$T/tools/package.mjs" and-super-rev-probe.zip "$WORK/man" > /dev/null
variant "$T/and-super-rev-probe.zip" "$T/tampered.zip" tamper site/app-prototype.html
caught_ "an archive edited to differ only in CONTENT is refused" \
        "BYTES differ from the ones the gates tested" \
        -- node "$T/tools/replay-artifact.mjs" tampered.zip "$WORK/man"

# ── 6. THE ARCHIVE'S ACCOUNT OF ITSELF IS THE ONE BEING BOUND ────────────
fresh
seed_measurements
node "$T/tools/package.mjs" and-super-rev-probe.zip "$WORK/man" > /dev/null
node -e '
  const fs=require("fs"), p=process.argv[1];
  const m=JSON.parse(fs.readFileSync(p,"utf8"));
  m.figures.source_text_assets.value += 1;
  fs.writeFileSync(p, JSON.stringify(m,null,2)+"\n");
' "$T/site/proof/measurements.json"
caught_ "a measurements.json edited after packaging makes the replay refuse" \
        "different measurements.json" \
        -- node "$T/tools/replay-artifact.mjs" and-super-rev-probe.zip "$WORK/man"

# ── 7. A GATE THAT REFUSES EVERYTHING IS NOT A GATE ──────────────────────
# `sabotage-counts.sh` carries the same case for the same reason.
fresh
seed_measurements
CLEAN=$( { node "$T/tools/check-source-hygiene.mjs" &&
           node "$T/tools/package.mjs" and-super-rev-probe.zip "$WORK/man" &&
           node "$T/tools/replay-artifact.mjs" and-super-rev-probe.zip "$WORK/man"; } 2>&1 )
if grep -q 'byte-identical to the gated tree' <<<"$CLEAN"; then
  echo "caught     a clean tree packages and replays (the gate is not a brick)"
  CAUGHT=$((CAUGHT+1))
else
  echo "NOT        a clean tree was refused — the gate refuses everything"
  echo "$CLEAN" | sed 's/^/           /'
  NOT=$((NOT+1))
fi

echo
echo "scope sabotage: $CAUGHT caught · $NOT not"
[ "$NOT" -eq 0 ]
