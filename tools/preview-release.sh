#!/usr/bin/env bash
# preview-release — every gate that does not need the BEAM.
#
# This exists so a box without Elixir can still check the browser engine,
# the proof artifact, the batteries, and the preview. It deliberately
# CANNOT package and deliberately never says "every gate green", because
# on such a box half the conformance claim — the Elixir runtime replaying
# the same vectors — has not been tested. `tools/release.sh` refuses
# outright rather than degrade; this is the honest degraded path, and it
# is named so nobody mistakes its output for a release.
set -euo pipefail
cd "$(dirname "$0")/.."
. tools/guard.sh
REV=$(node -p "require('./release.json').revision")

# The same log-and-receipt as `release.sh`. The receipt this chain writes
# records `beam_tests`, `host_acceptance` and `host_falsifiers` as not-run
# rather than omitting them — a receipt always says which half of the
# conformance claim it is standing on.
LOG=$(mktemp); trap 'rm -f "$LOG"' EXIT
exec > >(tee -a "$LOG") 2>&1

# **THIS SCRIPT RAN THE SABOTAGE UNBRACKETED.** `release.sh` wrapped
# `sabotage-bots.sh` in `guarded` at W.1.3.1 and this one — the path a box
# without Elixir actually uses — called it bare, so a harness that died
# mid-probe left `site/app-prototype.html` sabotaged with nothing saying
# so. The bracket is not a packaging concern; it is a source-tree concern,
# and it belongs on every script that lets an adversarial harness write.
bash tools/sabotage-guard.sh
bash tools/sabotage-scope.sh
node tools/check-source-hygiene.mjs

node tools/verify-artifact.mjs
node tools/emit-proof.mjs > /dev/null
node tools/inject-proof.mjs
node tools/stamp-rev.mjs
node tools/proof-battery.mjs
node tools/authority-battery.mjs
guarded sabotage-bots site/app-prototype.html -- bash tools/sabotage-bots.sh
node tools/check-preview.mjs
node tools/export-vectors.mjs
node tools/stamp-counts.mjs
guarded sabotage-counts README.md ampd/README.md site docs tools -- bash tools/sabotage-counts.sh

sync; sleep 0.2
node tools/emit-measurements.mjs "$LOG"
node tools/check-measurement-prose.mjs

echo
echo "PREVIEW OK → revision $REV · browser gates green, artifact bound, vectors exported."
if command -v mix >/dev/null 2>&1; then
  echo "NOT A RELEASE: mix IS available here — run tools/release.sh to replay on the BEAM and package."
else
  echo "NOT A RELEASE: the BEAM conformance replay did not run (mix absent), so the"
  echo "  Elixir half of the conformance claim is UNVERIFIED on this machine."
  echo "  Vectors were validated against the frozen JS engine only."
fi
echo "No artifact was produced. Packaging requires tools/release.sh."
