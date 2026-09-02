#!/usr/bin/env bash
# verify-artifact → emit → inject → stamp → proof-battery → authority-battery
# → render/check preview → export-vectors → stamp-counts → mix test → BEAM
# falsifiers → host gates → package → REPLAY → receipt.
# Every stage is a gate; the revision and the zip name derive from
# release.json, and every conformance figure derives from the corpus.
#
# The last two stages are W.1.4.2. Packaging used to be the end of the
# chain, so the figures a receipt carried had been measured over the
# working tree and were then bound to an archive nobody had re-read. They
# differed. `replay-artifact.mjs` extracts what was just built and re-derives
# them from it, and `release-scope.mjs` is the one declaration both the
# packager and the gates now walk.
set -euo pipefail
cd "$(dirname "$0")/.."
REV=$(node -p "require('./release.json').revision")

# **THE CHAIN KEEPS ITS OWN LOG, BECAUSE THE RECEIPT IS BUILT FROM IT.**
#
# Every gate already reports its own figures. Until W.1.3.2b those figures
# went to a terminal and were then RETYPED into a review brief — three
# rounds running, and three times the retyped number was wrong. So the
# chain records what its gates said and `emit-measurements.mjs` turns that
# into `site/proof/measurements.json`, which prose references.
#
# The tee is at the top so a gate that fails is in the log too: a receipt
# is refused when a gate reports failures, and it can only refuse what it
# can see.
LOG=$(mktemp); trap 'rm -f "$LOG"' EXIT
exec > >(tee -a "$LOG") 2>&1
# **The sabotage harnesses edit the source tree in place, and they run AFTER
# the suites that would notice a bad restore.**
#
# `mix test` is stage 12; `sabotage-host.sh` — which sed-edits
# `ampd/lib/*.ex` and `host/src/*.rs` and restores them — is stage 15. A
# failed restore, or a harness killed mid-probe, leaves a sabotage in the
# tree with every gate that could see it already run. That is F.8.1's shape
# exactly: the chain that packages the zip never running the one check that
# could catch what it ships. It has happened for real once — F.8.2.3, where
# a multi-pair backup wrote a sabotage into `bridge.ex` permanently, and it
# was caught only because a duplicate `mv` errored.
#
# So each adversarial gate is BRACKETED rather than the whole chain: the
# generative stages (`inject-proof`, `stamp-rev`, `export-vectors`,
# `stamp-counts`) rewrite files in these same paths on purpose, and a
# whole-chain fingerprint would refuse every legitimate round.
# The bracket lives in `tools/guard.sh` so that `tools/sabotage-guard.sh`
# can run it against a tree it is allowed to damage. W.1.3.1's claim that
# "the guard has its own falsifier" was a sentence in a review brief with
# no harness under it, and when one was finally written it found two of the
# three cases the bracket claims to catch were not caught.
. tools/guard.sh

# The bracket is checked BEFORE anything relies on it. It runs against a
# scratch tree it owns, so it cannot damage this one, and it is first
# because every later `guarded` line is only worth what this proves.
bash tools/sabotage-guard.sh

# And the artifact/measurement boundary, for the same reason: W.1.4.1 bound
# a figure to an archive that did not contain the set it counted, and the
# repair is only worth what a harness says it is. Runs against a scratch
# tree it owns and exercises the shipped `release-scope` / `package` /
# `replay-artifact` code paths.
bash tools/sabotage-scope.sh

# Before any suite reads the source: the browser battery must be running the
# browser's source. One literal NUL in `app-prototype.html` meant it was not.
node tools/check-source-hygiene.mjs

node tools/verify-artifact.mjs
node tools/emit-proof.mjs > /dev/null
node tools/inject-proof.mjs
node tools/stamp-rev.mjs
node tools/proof-battery.mjs
node tools/authority-battery.mjs
# The browser battery had no proof any of its assertions could fail. This is
# the same argument as `sabotage-host.sh`: an invariant check labelled a
# falsifier is a number that means less than it says, and this arc has
# mislabelled three. Cheap enough to stay in the chain — unlike
# `ampd/tools/sabotage.sh`, which recompiles per probe.
guarded sabotage-bots site/app-prototype.html -- bash tools/sabotage-bots.sh
if node -e "const f=require('fs');const P=JSON.parse(f.readFileSync('site/proof/latest.json'));let M;try{M=JSON.parse(f.readFileSync('site/preview/preview-meta.json'))}catch(e){process.exit(1)};process.exit(M.source_sha256===P.sha256&&M.frac===P.totals.passed+'/'+P.totals.attempted&&M.cert_streak===P.run.cert_streak?0:1)" 2>/dev/null; then
  echo "preview: already rendered from this artifact — skipping re-render (check-preview still gates)"
elif python3 -c "import numpy, PIL" 2>/dev/null; then
  python3 tools/render-preview.py
else
  echo "preview: renderer deps missing — validating existing preview-meta against the artifact"
fi
node tools/check-preview.mjs
node tools/export-vectors.mjs
node tools/stamp-counts.mjs
# The tool that stops figures being typed had never refused anything, and the
# W.1.3.2a brief shipped `# 184 assertions` beside its own stamped 188 because
# the bare-count scan named two READMEs and not the document being reviewed.
guarded sabotage-counts README.md ampd/README.md site docs tools -- bash tools/sabotage-counts.sh

# The BEAM replay is a LOAD-BEARING gate, not an optional one. A release
# that skipped it and still printed "every gate green" would be exactly the
# kind of transcribed truth the proof battery exists to prevent — so this
# refuses rather than degrades. Use tools/preview-release.sh on a box
# without Elixir; it is not allowed to call itself a release.
if ! command -v mix >/dev/null 2>&1; then
  echo "RELEASE REFUSED · mix is not on PATH." >&2
  echo "  The Elixir runtime is half of the conformance claim: the vectors were" >&2
  echo "  validated against the frozen JS engine, but not replayed on the BEAM." >&2
  echo "  Install Elixir, or run tools/preview-release.sh (which cannot package)." >&2
  exit 1
fi
(cd ampd && MIX_ENV=test mix test --seed 0)

# **THE BEAM FALSIFIERS ARE IN THE CHAIN NOW, AND W.1.4 IS THE ARGUMENT.**
#
# This script used to end by printing that it had NOT run
# `ampd/tools/sabotage.sh` — four and a half minutes, one recompile per
# probe — on the reasoning that a gate that slow would get skipped rather
# than run. The reasoning was sound and the conclusion was wrong, and the
# round that proved it is the one immediately before this line was written.
#
# W.1.4 passed every gate in this file. It printed a release line. It was
# nevertheless a bad release: the out-of-chain BEAM battery found that one
# of its falsifiers had gone dead, and the round had to be re-minted as
# W.1.4.1. So `release.sh green` was demonstrably not `falsifiers green`,
# and the ONLY evidence that the falsifiers had run was a sentence in a
# review brief — for the single property that distinguished the bad
# artifact from the good one.
#
# A gate whose absence has already shipped a bad release is not optional
# latency. It refuses here exactly as `mix` and `cargo` do, and
# `tools/preview-release.sh` remains the honest degraded path that cannot
# package. Bracketed like every other harness that writes to the source
# tree: it sed-edits `ampd/lib/*.ex` and restores them, and F.8.2.3 is the
# round where a restore silently did not.
guarded sabotage-beam ampd/lib -- bash ampd/tools/sabotage.sh

# The host batteries are LOAD-BEARING, and F.8.1 is the argument for it.
#
# That release ran this chain, printed "every gate green" on 42 vectors,
# 171 BEAM tests and 39 falsifiers, and shipped a runtime that leaked a
# descriptor on every rejected bridge command. It could not have been
# caught here: a descriptor with no Erlang owner exists only after an
# `SCM_RIGHTS` receive, so no suite that runs inside the BEAM can construct
# one, and the chain that packaged the zip never ran the one battery that
# could. A gate chain whose measurement boundary stops at the language
# boundary will keep certifying whatever lies outside it.
if ! command -v cargo >/dev/null 2>&1; then
  echo "RELEASE REFUSED · cargo is not on PATH." >&2
  echo "  Super is a Rust host and an Elixir runtime, and the descriptor" >&2
  echo "  ownership between them is measurable from exactly one side. A" >&2
  echo "  package built without running it would be asserting a property" >&2
  echo "  nothing checked. Install Rust, or run tools/preview-release.sh" >&2
  echo "  (which cannot package)." >&2
  exit 1
fi
cargo build --release --manifest-path host/Cargo.toml

# **The Carrier payload is built here, and by exactly one thing.**
#
# It was not built at all: this script assumed a binary was already sitting
# in `carrier-fixture/target/release/`, which is how a stale or wrongly
# linked one survives a release. `--manifest-path` is deliberately NOT used
# — cargo reads `.cargo/config.toml` from the working directory, and the
# fixture's pins `+crt-static`, without which Landlock refuses the `execve`
# and nineteen acceptance checks go red saying nothing about why.
bash tools/build-carrier-fixture.sh

./host/target/release/super-host verify
guarded sabotage-host ampd/lib host/src -- bash tools/sabotage-host.sh

# ------------------------------------------------------------ W.2 · the cockpit
#
# **THE SAME ARGUMENT AS THE HOST BATTERIES, ONE BOUNDARY FURTHER OUT.**
#
# F.8.1 shipped green because the measurement boundary stopped at the
# language boundary. W.1 ends at a `CockpitFrame` and a `super-host verify`
# that proves the loop's state machine is right — and the property W.2 adds
# lives in a DOM, on the far side of an IPC hop, and cannot be observed from
# either the BEAM or the Rust that feeds it. A chain that packaged a desktop
# app without driving one would be certifying whatever lies outside it, for
# the third time.
#
# It refuses rather than degrades, exactly as `mix` and `cargo` do.
# `tools/preview-release.sh` is the honest degraded path and cannot package.
if ! command -v tauri-driver >/dev/null 2>&1; then
  echo "RELEASE REFUSED · tauri-driver is not on PATH." >&2
  echo "  The W.2 claim is about a DOM: that a successful intent moves nothing" >&2
  echo "  on screen until a frame says so. It is observable in a real WebView" >&2
  echo "  and nowhere else. Install it (cargo install tauri-driver) or run" >&2
  echo "  tools/preview-release.sh (which cannot package)." >&2
  exit 1
fi
if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  echo "RELEASE REFUSED · no display." >&2
  echo "  The cockpit battery drives a real WebKit WebView. A headless box can" >&2
  echo "  build this artifact but cannot measure the claim it makes." >&2
  exit 1
fi
cargo build --release --manifest-path cockpit/Cargo.toml
# The OUTER authority gate, and W.2 shipped without it: application
# commands registered through `invoke_handler` are reachable from every
# webview in the process unless they are declared to the ACL. Static, and
# cheap, so it runs before the battery that proves it at runtime.
node tools/check-webview-acl.mjs
node tools/check-intent-surface.mjs
bash tools/check-fixture-guard.sh
node tools/cockpit-battery.mjs
# **W.2.3 · the OTHER Tauri Channel transport.** A payload under 8192 bytes
# goes to the page by `webview.eval`; anything larger is parked and fetched,
# and the page-side failure of that fetch ends in `.catch(console.error)`.
# Every fixture frame the flagship has ever measured is 2,342 bytes, so one
# of the two transports had never executed in this project. The projection
# grows with receipts, refusals and histories; the day it crosses 8192 is
# not a day anything here changes.
node tools/cockpit-bigframe.mjs
# **W.2.3.3 · the deadline the shipped depth cannot reach.** The cockpit has
# two ways to stop claiming a projection while the link is healthy: the host
# stating it has abandoned a frame (`exhausted`), and a whole lease passing
# with nothing attesting the projection. At RETRY_LIMIT=3 the first fires at
# ~2.4 s and the second, at 6 s, can never run — so its falsifier could
# never run either, and a mechanism whose falsifier cannot run is a claim.
# This gate runs the SAME code at `SUPER_COCKPIT_RETRY=64`, a depth and not
# a mode, where the host is still visibly retrying and only the second
# deadline can end the stale claim.
node tools/cockpit-maintenance.mjs
# Bracketed like every other harness that writes to the source tree: it
# sed-edits `cockpit/src/*.rs`, `cockpit/ui/*`, `cockpit/build.rs` and
# `cockpit/capabilities/*` and restores them.
# **Seconds, and it goes first.** Every probe is anchored on a line of
# source, and a later round that rewrites that line silently turns the probe
# into a no-op — it still runs, still looks like a probe, and proves
# nothing. The harness has always reported that as SABOTAGE MISSED, but the
# price of hearing it was a rebuild and a battery per probe: W.2.3.2 broke
# two of W.2.3.1's anchors and the first complaint arrived an hour into a
# chain. The dry run asks only whether every pattern still matches.
SABOTAGE_DRYRUN=1 bash tools/sabotage-cockpit.sh
guarded sabotage-cockpit cockpit/src cockpit/ui cockpit/build.rs cockpit/capabilities -- bash tools/sabotage-cockpit.sh

# Every gate has now reported. Turn the log into the receipt, then refuse
# any document that recreated a figure instead of pointing at it. `sync` is
# because the tee runs in a subshell and the last lines may still be in
# flight when this reads the file.
sync; sleep 0.2
node tools/emit-measurements.mjs "$LOG"
node tools/check-measurement-prose.mjs

ZIP=$(node -p "'and-super-rev-'+require('./release.json').revision.toLowerCase().replace(/\./g,'')+'.zip'")
# **NO BACKUP FILE HAS EVER BEEN PART OF A RELEASE.** The brackets refuse a
# harness that leaves one, but a `.orig` can also arrive from a hand-run
# probe or an interrupted edit, and until W.1.3.2a neither packager
# excluded them — a file the integrity check deliberately ignores was
# shipping inside the artifact it was checking.
STRAY=$(find . -name '*.orig' -not -path './old_scrap/*' -not -path './host/target/*' -not -path './cockpit/target/*' -print)
if [ -n "$STRAY" ]; then
  echo "RELEASE REFUSED · backup files in the tree:" >&2
  echo "$STRAY" | sed 's/^/    /' >&2
  echo "  These are sabotage backups. Restore or delete them; a release does not" >&2
  echo "  get to decide which half of a half-restored file is the product." >&2
  exit 1
fi
# **THE PREVIOUS ARTIFACT IS DELETED HERE, AND MEASURED NOWHERE.**
#
# W.1.4.1's receipt said 113 text assets about an archive containing 112,
# and this line is where the missing one went: an old sibling receipt sat
# in the tree, `check-source-hygiene` counted it at stage 3, and this `rm`
# removed it at stage 27 — after every measurement and before the bytes the
# measurements were bound to.
#
# The obvious repair is to move this `rm` above the gates. That fixes the
# ordering and keeps the class: a receipt can arrive in the tree by other
# routes — a hand-run probe, an interrupted round, a copy made to compare
# two revisions — and would move the figure again. It would also mean a
# release that fails at stage 12 has destroyed the last good artifact on
# its way to failing.
#
# So the fix is in the SCOPE, not the schedule: `tools/release-scope.mjs`
# excludes `*.zip` and `and-super-rev-*.receipt.json` from every walk, so no
# gate can see them whenever they arrive. This `rm` stays late, where a
# failed release leaves the previous artifact intact, and it is now a
# tidiness step rather than a load-bearing one.
rm -f ./and-super-rev-*.zip ./and-super-rev-*.receipt.json

# ONE packager, over ONE declaration. There were two, chosen on whether the
# `zip` binary was installed, and they excluded different sets — see the
# note at the top of `tools/package.mjs`.
#
# `$MANIFEST` is the PRE-PACKAGE content manifest: one `sha256 size path`
# line per shipped file, taken from the tree the gates just ran against,
# with the canonical digest on the first line. It lives outside the tree
# because a file describing the content digest would be part of the content
# it describes.
MANIFEST=$(mktemp); trap 'rm -f "$LOG" "$MANIFEST"' EXIT
node tools/package.mjs "$ZIP" "$MANIFEST"

# **AND THE ARCHIVE MUST BE THE BYTES THE GATES TESTED.**
#
# W.1.4.2 had a replay here and it proved a SET property while its receipt
# claimed a BYTE property. It derived the expected file list by walking the
# EXTRACTED ARCHIVE, so a file missing from the archive could never appear
# in the list of files the archive was missing — and an archive with one
# line of `app-prototype.html` reverted to a known-bad `stabilityToken`
# passed it while that same archive's own authority battery failed six
# assertions.
#
# The expected side is `$MANIFEST` now; the actual side is hashed from the
# raw ZIP entries. Neither is inferred from the other.
node tools/replay-artifact.mjs "$ZIP" "$MANIFEST"
# **A REVISION MUST NAME ONE BYTE HISTORY.**
#
# W.1.3.2a shipped twice. The second bundle carried new tools, a modified
# prototype, modified release scripts and regenerated proof artifacts, and
# still called itself W.1.3.2a — two substantially different archives with
# one name. In a system whose whole subject is identity, citation, basis and
# provenance, the review artifacts cannot themselves be ambiguous about
# which bytes a revision refers to.
#
# The archive cannot contain its own hash, so the binding is a SIBLING. It
# is written after packaging, from the file that was actually produced, and
# it carries the measurement receipt with it so the figures and the bytes
# they describe travel together.
#
# W.1.4.2 adds `files` and `artifact_replay`. The figures used to travel
# beside the hash with nothing establishing that they described THOSE bytes
# — which is how 113 came to sit beside the SHA-256 of an archive containing
# 112. Reaching this line now means `replay-artifact.mjs` extracted the
# archive and re-derived them from it.
SHA=$(sha256sum "./$ZIP" | cut -d' ' -f1)
node - "$ZIP" "$SHA" "$MANIFEST" <<'PY'
const [,, zip, sha, manifest] = process.argv;
const fs = require('fs');
const { execFileSync } = require('child_process');
const rev = JSON.parse(fs.readFileSync('./release.json','utf8')).revision;
const m = JSON.parse(fs.readFileSync('./site/proof/measurements.json','utf8'));
if (m.revision !== rev) { console.error(`receipt: measurements say ${m.revision}, tree says ${rev}`); process.exit(1); }
const content = fs.readFileSync(manifest,'utf8').split('\n')[0];
const files = Number(execFileSync('python3', ['-c',
  'import sys,zipfile;print(sum(1 for n in zipfile.ZipFile(sys.argv[1]).namelist() if not n.endswith("/")))',
  './' + zip], { encoding: 'utf8' }).trim());
fs.writeFileSync(`./and-super-rev-${rev.toLowerCase().replace(/\./g,'')}.receipt.json`,
  JSON.stringify({ schema:'release-receipt@3', revision: rev, artifact: zip,
                   sha256: sha, bytes: fs.statSync('./'+zip).size, files,
                   /* The digest of the CONTENT — sorted (path, size, sha256(bytes)) — as
                      opposed to `sha256`, which is of the archive container. The container
                      hash changes when a timestamp does; this one does not, so it is the
                      value that means "the same code". */
                   release_content_sha256: content,
                   artifact_replay: { scope: 'matched', content: 'byte-identical' },
                   measurements: m.figures,
                   /* **THIS WORDING IS THE W.1.4.2 CORRECTION.** That receipt said every
                      figure had been "re-derived FROM this archive", and only four of them
                      were — the rest are behavioural results captured from the gated run.
                      Claiming re-derivation the tooling does not perform is the same
                      prose-over-evidence gap the proof battery exists to close. */
                   note: 'The archive cannot contain its own hash. Measurements were produced '
                       + 'by the gated release run; post-package replay then proved the shipped '
                       + 'path set and every file\'s bytes are identical to that gated tree '
                       + '(release_content_sha256). The behavioural figures are therefore bound '
                       + 'to the exact bytes whose execution produced them — they were not '
                       + 're-executed from the archive.' }, null, 2) + '\n');
console.log(`receipt: ${rev} -> sha256:${sha.slice(0,16)}… (${zip}, ${files} files, content:${content.slice(0,16)}…)`);
PY

echo "RELEASE OK → $ZIP (revision $REV · every gate in the chain green)"
echo "  Includes the BEAM falsifiers, which were out of the chain until W.1.4.2 —"
echo "  the round before it shipped green here and was still wrong."
