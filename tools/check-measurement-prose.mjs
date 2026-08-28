/* check-measurement-prose — prose references measurements; it does not
   recreate them.

   `stamp-counts.mjs` protects three nouns because three numbers had already
   drifted: `vectors`, `tests`, `assertions`. The fourth was `text assets` —
   the brief said 110 while the shipped gate said 108 — and protecting it
   would have made a list of four. The list is the problem: it can only ever
   contain the mistakes already made.

   So this takes its nouns from `site/proof/measurements.json`, which every
   gate contributes to by reporting its own figure. A gate added tomorrow is
   guarded tomorrow, by nobody remembering anything.

   THE RULE. In a guarded document, a bare number immediately followed by a
   measured noun is refused. Two ways to satisfy it:

     reference   "see site/proof/measurements.json"  — always allowed
     stamp       <!--assertions-->188<!--/assertions--> — for the few figures
                 that have to read inline, written by stamp-counts

   Historical records are exempt by being outside the guarded set: a past
   round's measurement is a record, and rewriting it with today's numbers is
   the defect `stamp-counts` refuses two markers to prevent.               */

import { readFileSync } from 'node:fs';
const here = new URL('.', import.meta.url).pathname;

let receipt;
try {
  receipt = JSON.parse(readFileSync(here + '../site/proof/measurements.json', 'utf8'));
} catch {
  console.error('check-measurement-prose: no measurement receipt.');
  console.error('  Run the release chain, which pipes its log to emit-measurements.mjs.');
  console.error('  Without a receipt there is no noun list, and this check would silently');
  console.error('  pass over everything — which is worse than not running at all.');
  process.exit(1);
}

const rev = JSON.parse(readFileSync(here + '../release.json', 'utf8')).revision;
if (receipt.revision !== rev) {
  console.error(`check-measurement-prose: the receipt is for ${receipt.revision}, the tree says ${rev}.`);
  console.error('  A receipt from another revision would guard the wrong numbers and, worse,');
  console.error('  would look like it had guarded the right ones.');
  process.exit(1);
}

/* Each figure carries the shape prose may not contain. Written by the gate
   table in `emit-measurements.mjs`, never by a list here — which is the
   whole point, and also why this file must refuse a figure that arrives
   without one rather than skipping it. A guard that silently ignores what
   it does not understand is the shape of every defect this round found. */
const patterns = Object.entries(receipt.figures).map(([key, f]) => {
  if (!f.prose) {
    console.error(`check-measurement-prose: figure "${key}" carries no prose pattern.`);
    console.error('  It would be guarded by nothing while appearing to be guarded.');
    process.exit(1);
  }
  return { key, re: new RegExp(f.prose, 'g'), marker: f.marker };
});

const brief = `../docs/reviews/${rev.toUpperCase().replace(/\./g, '_')}_REVIEW_BRIEF.md`;
const targets = ['../README.md', '../ampd/README.md'];
try { readFileSync(here + brief); targets.push(brief); } catch { /* no brief yet */ }

const bad = [];
for (const p of targets) {
  let src = readFileSync(here + p, 'utf8');
  /* Stamped figures are the tool's own output and are not prose. */
  src = src.replace(/<!--(\w+)-->[\s\S]*?<!--\/\1-->/g, '');

  for (const { key, re, marker } of patterns) {
    for (const m of src.matchAll(re)) {
      const fix = marker ? `wrap it in <!--${marker}--> markers`
                         : 'reference site/proof/measurements.json instead';
      bad.push(`${p.replace('../', '')}: "${m[0].trim()}" recreates ${key} — ${fix}`);
    }
  }
}

if (bad.length) {
  console.error('check-measurement-prose: measurements recreated in prose');
  bad.forEach(b => console.error('  ' + b));
  console.error(`  Patterns are derived from the receipt (${patterns.length} figures), not from a`);
  console.error('  list in this file. Three rounds running, the number that drifted was the one');
  console.error('  nobody had thought to name.');
  process.exit(1);
}

console.log(`measurement prose: clean — ${targets.length} documents, ${patterns.length} derived patterns`);
