/* emit-measurements — ONE generated receipt, so prose can reference a
   measurement instead of recreating it.

   Three rounds running, a figure has been copied into prose and gone wrong:

     W.1.3.2   the brief said 148 browser assertions; the battery emitted 150
     W.1.3.2a  §10 said 184 beside its own stamped 188
     W.1.3.2b  the brief said 110 text assets; the shipped gate said 108

   Each time the fix was to protect one more noun — `vectors`, then `tests`,
   then `assertions` — and each time the next number to drift was one nobody
   had thought to name. An expanding vocabulary of regex-protected nouns is
   not a mechanism, it is a list of the mistakes already made.

   So the noun list is DERIVED. Every gate reports its own figures on a line
   this file knows how to read; the receipt records them; and the prose scan
   in `check-measurement-prose.mjs` takes its nouns FROM the receipt. Adding
   a gate extends the guard without anyone remembering to.

   The receipt is the artifact's own account of what it measured, bound to
   the revision that measured it. Prose points at it. Prose does not restate
   it — and `check-measurement-prose.mjs` is what makes that a rule rather
   than an intention.

   Usage:  bash tools/release.sh 2>&1 | tee log && node tools/emit-measurements.mjs log
   The chains do this for you.                                            */

import { readFileSync, writeFileSync } from 'node:fs';
const here = new URL('.', import.meta.url).pathname;

const log = readFileSync(process.argv[2] || '/dev/stdin', 'utf8');
const rev = JSON.parse(readFileSync(here + '../release.json', 'utf8')).revision;

/* Each entry: the gate that reports it, a pattern whose capture groups are
   [value, ...], and the nouns prose may not carry a bare number for.

   `required: false` marks a gate that is deliberately not in `release.sh`
   (the BEAM sabotage takes four and a half minutes) or not in the preview
   chain (mix and cargo). Its absence is recorded as `null` rather than
   silently omitted, so a receipt always says which half of the claim it is
   standing on. */
/* `bad` names the capture group that counts FAILURES, where the gate has
   one. It is explicit per figure rather than "the second number", because
   `count sabotage` reports `5 refused · 1 accepted · 1 restamped · 0
   unexpected` — its second number is a healthy 1 and its failure count is
   the fourth. Guessing which number means trouble is how a summary comes to
   report a figure correctly and the thing it counted wrongly, which is the
   defect that harness was just fixed for. */
/* `prose` IS NOT THE SAME PATTERN AS `re`, AND THE DIFFERENCE MATTERS.
 *
 * `re` reads the gate's line out of the release log. `prose` is what
 * `check-measurement-prose.mjs` refuses to find in a document — and the
 * first version of this file used `\d+ <noun>` for both, which flagged
 * three innocent sentences at once:
 *
 *     "100 refused claims, 100 …"        the host battery's WORKLOAD
 *     "leaked by 30 refused commands"    a description of a past defect
 *     "3 caught · 3 not"                 a labelled COUNTERFACTUAL, showing
 *                                        what the OLD bracket produces
 *
 * `refused` and `caught` are ordinary English. A guard that fires on them
 * teaches you to phrase around it, which is worse than no guard.
 *
 * So the distinctive nouns (`vectors`, `assertions`, `text assets`) keep the
 * bare form, and the generic ones require the GATE'S SUMMARY SHAPE — which
 * prose can only match by copying the gate's own line, which is precisely
 * the thing being forbidden. A sentence that happens to contain the word
 * "refused" is not recreating a measurement; `count sabotage: 5 refused ·`
 * is. */
const FIGURES = [
  /* **RENAMED AT W.1.4.2, BECAUSE THE OLD NAME DID NOT SAY WHICH SET.**
     `text_assets` was measured over the working tree and bound to an
     archive, and the two differed by one file — a previous round's sibling
     receipt, counted at stage 3 and deleted at stage 27. The noun now names
     its universe, `tools/release-scope.mjs` declares that universe once, and
     `tools/replay-artifact.mjs` proves the archive reproduces the figure.
     The old noun stays unguarded on purpose: it now refers only to a
     superseded universe, so a brief may quote what W.1.4.1 measured. */
  { key: 'source_text_assets', gate: 'check-source-hygiene', noun: 'source text assets', required: true,
    re: /^source hygiene: clean — (\d+) source text assets/m,
    prose: String.raw`\d+\s+source text assets` },
  { key: 'proof_literals',     gate: 'proof-battery',        noun: 'artifact-derived literals', required: true,
    re: /^proof battery: clean — (\d+) artifact-derived literals/m,
    prose: String.raw`\d+\s+artifact-derived literals` },
  { key: 'browser_assertions', gate: 'authority-battery',    noun: 'assertions', required: true, bad: 2,
    re: /^authority battery: (\d+) assertions · (\d+) failed$/m,
    prose: String.raw`\d+\s+assertions`, marker: 'assertions' },
  { key: 'bot_falsifiers',     gate: 'sabotage-bots',        noun: 'falsified', required: true, bad: 2,
    re: /^bot sabotage: (\d+) falsified · (\d+) not$/m,
    prose: String.raw`bot sabotage:\s*\d+|\d+\s+falsified\s+·\s+\d+\s+not\b` },
  { key: 'guard_falsifiers',   gate: 'sabotage-guard',       noun: 'caught', required: true, bad: 2,
    re: /^guard sabotage: (\d+) caught · (\d+) not$/m,
    prose: String.raw`guard sabotage:\s*\d+` },
  { key: 'scope_falsifiers',   gate: 'sabotage-scope',       noun: 'caught', required: true, bad: 2,
    re: /^scope sabotage: (\d+) caught · (\d+) not$/m,
    prose: String.raw`scope sabotage:\s*\d+` },
  { key: 'count_refusals',     gate: 'sabotage-counts',      noun: 'refused', required: true, bad: 4,
    re: /^count sabotage: (\d+) refused · (\d+) accepted · (\d+) restamped · (\d+) unexpected$/m,
    prose: String.raw`count sabotage:\s*\d+|\d+\s+refused\s+·\s+\d+\s+accepted` },
  { key: 'conformance_vectors', gate: 'stamp-counts',        noun: 'vectors', required: true,
    re: /^stamp-counts: (\d+) vectors/m,
    prose: String.raw`\d+\s+vectors`, marker: 'vectors' },
  { key: 'beam_tests',         gate: 'mix test',             noun: 'tests', required: false, bad: 2,
    re: /^(\d+) tests, (\d+) failures?$/m,
    prose: String.raw`\d+\s+tests\b`, marker: 'tests' },
  /* **THIS PATTERN HAS NO PREFIX, AND EVERY LATER `held · failed` GATE MUST
     HAVE ONE.** `super-host verify` prints a bare `  78 held · 0 failed`,
     so this matches the FIRST such line in the log. W.2 adds three gates
     that report the same shape — the cockpit battery, the intent surface
     and the fixture guard — and had any of them printed it bare, the figure
     filed under `host_acceptance` would have been whichever ran first. That
     is W.1.4.1's trap 4 exactly: `sabotage.sh` and `sabotage-host.sh`
     printed byte-identical summaries and one battery's number would have
     been recorded under the other's name. All three are prefixed. */
  { key: 'host_acceptance',    gate: 'super-host verify',    noun: 'held', required: false, bad: 2,
    re: /^\s*(\d+) held · (\d+) failed$/m,
    prose: String.raw`\d+\s+held\s+·\s+\d+\s+failed` },
  { key: 'cockpit_assertions', gate: 'cockpit-battery',      noun: 'held', required: false, bad: 2,
    re: /^cockpit battery: (\d+) held · (\d+) failed$/m,
    prose: String.raw`cockpit battery:\s*\d+` },
  { key: 'big_frame',          gate: 'cockpit-bigframe',     noun: 'held', required: false, bad: 2,
    re: /^big frame: (\d+) held · (\d+) failed$/m,
    prose: String.raw`big frame:\s*\d+` },
  { key: 'maintenance',        gate: 'cockpit-maintenance',  noun: 'held', required: false, bad: 2,
    re: /^maintenance: (\d+) held · (\d+) failed$/m,
    prose: String.raw`maintenance:\s*\d+` },
  { key: 'intent_surface',     gate: 'check-intent-surface', noun: 'held', required: false, bad: 2,
    re: /^intent surface: (\d+) held · (\d+) failed$/m,
    prose: String.raw`intent surface:\s*\d+` },
  { key: 'webview_acl',        gate: 'check-webview-acl',    noun: 'held', required: false, bad: 2,
    re: /^webview acl: (\d+) held · (\d+) failed$/m,
    prose: String.raw`webview acl:\s*\d+` },
  { key: 'fixture_guard',      gate: 'check-fixture-guard',  noun: 'held', required: false, bad: 2,
    re: /^fixture guard: (\d+) held · (\d+) failed$/m,
    prose: String.raw`fixture guard:\s*\d+` },
  { key: 'cockpit_falsifiers', gate: 'sabotage-cockpit',     noun: 'did not', required: false, bad: 2,
    re: /^cockpit sabotage: (\d+) falsified · (\d+) did not$/m,
    prose: String.raw`cockpit sabotage:\s*\d+` },
  { key: 'host_falsifiers',    gate: 'sabotage-host',        noun: 'did not', required: false, bad: 2,
    re: /^host sabotage: (\d+) falsified · (\d+) did not$/m,
    prose: String.raw`host sabotage:\s*\d+|\d+\s+falsified\s+·\s+\d+\s+did not` },
  /* **THE GATE THAT DISTINGUISHED THE BAD W.1.4 FROM THE GOOD W.1.4.1, AND
     WAS NOT IN THE RECEIPT.** That release passed every gate in `release.sh`
     and was still wrong: the out-of-chain BEAM battery found a dead
     falsifier. So `release.sh green` was demonstrably not `falsifiers
     green`, and the only record that the falsifiers had run was a sentence
     in a brief. It is a required gate now, and the figure is bound to the
     artifact like every other.

     `required: false` here means the same thing it means for `beam_tests` —
     `emit-measurements` does not refuse when it is absent, because
     `preview-release.sh` legitimately runs on a box with no `mix`.
     `release.sh` is what refuses, in the same breath as it refuses a
     missing `mix` or `cargo`. */
  { key: 'beam_falsifiers',    gate: 'ampd/tools/sabotage.sh', noun: 'falsified', required: false, bad: 2,
    re: /^beam sabotage: (\d+) falsified · (\d+) did not$/m,
    prose: String.raw`beam sabotage:\s*\d+` },
];

const figures = {};
const missing = [];
const failed = [];

for (const f of FIGURES) {
  const m = log.match(f.re);
  if (!m) {
    /* A not-run gate still contributes its `prose` pattern. Otherwise the
       preview chain — where mix and cargo are absent — would write a
       receipt that silently stops guarding the BEAM and host figures, and
       a document could recreate exactly the numbers nothing measured. */
    figures[f.key] = { value: null, gate: f.gate, noun: f.noun, reported: false,
                       prose: f.prose, ...(f.marker ? { marker: f.marker } : {}) };
    if (f.required) missing.push(f);
    continue;
  }
  const entry = { value: Number(m[1]), gate: f.gate, noun: f.noun, reported: true,
                  prose: f.prose, ...(f.marker ? { marker: f.marker } : {}) };
  if (f.bad !== undefined) {
    entry.failures = Number(m[f.bad]);
    if (entry.failures !== 0) failed.push([f.key, f.gate, entry.failures]);
  }
  figures[f.key] = entry;
}

if (missing.length) {
  console.error('emit-measurements: required gates did not report');
  for (const f of missing) console.error(`  ${f.gate} — expected a line matching ${f.re}`);
  console.error('  A gate that stops reporting its own figure is how a number becomes');
  console.error('  something a human types. The receipt refuses to be written without it.');
  process.exit(1);
}

/* A gate reporting a FAILURE must not be written into a receipt as though it
   were a measurement of health. The chains already refuse on these; this is
   the second door, because the receipt outlives the log that produced it. */
if (failed.length) {
  console.error('emit-measurements: a gate reported failures; not writing a receipt');
  for (const [k, g, n] of failed) console.error(`  ${k} (${g}): ${n} failure(s), expected 0`);
  process.exit(1);
}

const receipt = {
  schema: 'release-measurements@1',
  revision: rev,
  figures,
  note: 'Generated by tools/emit-measurements.mjs from the release log. ' +
        'Prose references these; prose does not restate them — see ' +
        'tools/check-measurement-prose.mjs, whose noun list is derived from this file.',
};

writeFileSync(here + '../site/proof/measurements.json', JSON.stringify(receipt, null, 2) + '\n');

const shown = Object.entries(figures)
  .map(([k, v]) => `${k}=${v.reported ? v.value : 'not-run'}`).join(' · ');
console.log(`measurements: ${rev} · ${shown}`);
