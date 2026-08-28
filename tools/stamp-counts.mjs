/* stamp-counts — derive every conformance figure, type none of them.

   The README said "25 vectors / 25 tests" for two revisions after the
   corpus grew to 32, because both numbers were typed by hand. Same class
   of defect the proof battery exists to prevent, in a file the battery
   did not cover. So: the vector count comes from the exported corpus, the
   BEAM test count comes from counting the tests that actually exist, and
   both are written between markers. Editing the number by hand is
   reverted on the next release; disagreeing with the corpus fails it.   */

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
const here = new URL('.', import.meta.url).pathname;

const vectors = JSON.parse(readFileSync(here + '../conformance/authority-vectors.json', 'utf8'));
const nVectors = vectors.vectors.length;

/* Non-conformance suites declare plain `test "..." do`; the conformance
   suite generates one test per vector, so it is counted from the corpus. */
const testDir = here + '../ampd/test/';
const suites = readdirSync(testDir).filter(f => f.endsWith('_test.exs') && f !== 'conformance_test.exs');

const extra = suites.map(f => {
  const src = readFileSync(testDir + f, 'utf8');
  const n = (src.match(/^\s*test\s+"/gm) || []).length;
  return { file: f, n };
});

const nExtra = extra.reduce((a, b) => a + b.n, 0);
const nTests = nVectors + nExtra;

const parts = extra
  .map(e => `${e.n} ${e.file.replace('_test.exs', '')}`)
  .sort()
  .join(' + ');

/* THE ONE SUITE THIS TOOL DID NOT COVER, AND IT HAD DRIFTED IN BOTH
   DIRECTIONS AT ONCE.

   Vectors and BEAM tests were derived here from W.1 onward. The browser
   battery's count was typed by hand into whatever document was being
   written: the W.1.3.2 review brief said **148**, the blueprint's
   current-round line said **64** — a figure last true at W.1.3 — and the
   battery actually emitted **150**. Three numbers for one measurement, and
   the one sent to the reviewer was the one nothing checked.

   It is derived the same way the BEAM count is: by running the thing and
   reading what it reports, not by counting `t(` calls in a source file —
   an assertion inside a branch that never executes is written and not
   attempted, and the count that matters is the count that ran. */
const battery = execFileSync('node', [here + 'authority-battery.mjs'],
  { encoding: 'utf8', cwd: here + '..' });
const mAssert = battery.match(/^authority battery: (\d+) assertions · (\d+) failed$/m);
if (!mAssert) {
  console.error('stamp-counts: the authority battery did not report its own count.');
  console.error('  Expected a line "authority battery: N assertions · M failed".');
  console.error('  A count this tool cannot derive is a count that will be typed.');
  process.exit(1);
}
if (mAssert[2] !== '0') {
  console.error(`stamp-counts: the authority battery reports ${mAssert[2]} failure(s).`);
  process.exit(1);
}
const nAssertions = mAssert[1];

const FIELDS = {
  vectors: String(nVectors),
  tests: String(nTests),
  assertions: nAssertions,
  breakdown: `${nVectors} conformance vectors + ${parts}`
};

/* One marker set per file, and no more.

   The blueprint keeps a per-round record — "C1.0b: 35 vectors / 51 tests",
   "C1.0b.1: 39 / 72" — and every one of those lines was inside markers. So
   each release rewrote the *history* with today's numbers, and the C1.0b
   section came to claim 110 BEAM tests, which was never true at C1.0b. This
   tool exists to stop stale counts; pointed at a log it manufactured false
   ones instead, which is worse, because a stale number is visibly old and a
   restamped one is not.

   Historical records are frozen literals now. A second marker of the same
   kind in one file means a past round has been wrapped again — fail, rather
   than quietly overwrite what it says. */
function stamp(path) {
  let src = readFileSync(path, 'utf8');
  let hits = 0;

  for (const [key, val] of Object.entries(FIELDS)) {
    const re = new RegExp(`(<!--${key}-->)[\\s\\S]*?(<!--/${key}-->)`, 'g');
    const n = (src.match(re) || []).length;

    if (n > 1) {
      console.error(`stamp-counts: ${path.replace(here, '')} has ${n} <!--${key}--> markers`);
      console.error('  only the CURRENT round may be stamped; a past round\'s measurement is');
      console.error('  a record, and restamping it rewrites history with today\'s numbers.');
      console.error('  Freeze the older line as a plain literal outside the markers.');
      process.exit(1);
    }

    src = src.replace(re, (_m, a, b) => { hits++; return a + val + b; });
  }

  writeFileSync(path, src);
  return hits;
}

/* AND THE DOCUMENT THAT ACTUALLY REACHES THE REVIEWER.

   The W.1.3.2 review brief said 148 browser assertions. Nothing stamped
   it, nothing checked it, and it was the only one of the three numbers
   that a human read. A count derived into files nobody opens and typed
   into the file that gets sent is not a derived count.

   The path comes from `release.json` rather than a list, so the next
   round's brief is stamped without anyone remembering to add it — the
   list is exactly the mechanism that let the brief fall off. */
const rev = JSON.parse(readFileSync(here + '../release.json', 'utf8')).revision;
const briefPath = `../docs/reviews/${rev.toUpperCase().replace(/\./g, '_')}_REVIEW_BRIEF.md`;

let total = 0;
const targets = ['../README.md', '../ampd/README.md', '../site/AGENT_SUPER_APP_BLUEPRINT.md'];
try { readFileSync(here + briefPath); targets.push(briefPath); }
catch { console.log(`stamp-counts: no brief at ${briefPath.replace('../', '')} yet — nothing to stamp there`); }
for (const p of targets) {
  total += stamp(here + p);
}

/* A count that appears outside the markers is exactly the drift this tool
   exists to stop. Look for the figures written as bare literals.

   **AND THE BRIEF IS SCANNED, NOT MERELY STAMPED.** W.1.3.2a stamped the
   current review brief's marker and left it off this list, so the document
   that reaches the reviewer could still carry a bare count — and did: §10
   said `# 184 assertions` while the stamped table two hundred lines above
   said 188. The round whose entire §6 is about eliminating count drift
   shipped a drifted count, in the file written to explain the fix, and the
   release stayed green because this scan named two READMEs and stopped.

   Stamping a file and auditing it are different guarantees. A marker fixes
   the number you remembered to wrap; the scan is what catches the one you
   did not. */
const guarded = ['../README.md', '../ampd/README.md'];
try { readFileSync(here + briefPath); guarded.push(briefPath); } catch { /* no brief yet */ }
const bad = [];

for (const p of guarded) {
  const src = readFileSync(here + p, 'utf8');
  const stripped = src.replace(/<!--(vectors|tests|assertions|breakdown)-->[\s\S]*?<!--\/(vectors|tests|assertions|breakdown)-->/g, '');

  for (const m of stripped.matchAll(/(\d+)\s+(vectors|tests|assertions)\b/g)) {
    bad.push(`${p.replace('../', '')}: "${m[0]}" is a transcribed count — wrap it in <!--${m[2]}--> markers`);
  }
}

if (bad.length) {
  console.error('stamp-counts: transcribed conformance figures found');
  bad.forEach(b => console.error('  ' + b));
  process.exit(1);
}

console.log(`stamp-counts: ${nVectors} vectors · ${nTests} BEAM tests · ${nAssertions} browser assertions (${FIELDS.breakdown}) · ${total} marker(s) stamped`);
