#!/usr/bin/env node
/* verify → proof/latest.json
   Parses the review pack's RESULTS.txt and emits the proof artifact the
   homepage reads. The site never hard-codes a count: this artifact is
   the only place figures come from.                                */
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const here = new URL('.', import.meta.url).pathname;
const src = process.argv[2] || here + '../site/proof/RESULTS.txt';
const txt = readFileSync(src, 'utf8');
const sha256 = createHash('sha256').update(txt).digest('hex');
const g = (re, cast=String) => { const m = txt.match(re); return m ? cast(m[1]) : null; };

let cert = { hash: null, streak: null, source: null };
try {
  const brief = readFileSync(here + '../site/proof/BRIEF.md', 'utf8');
  const h = brief.match(/cert_id ([0-9a-f]{6,})/i);
  const words = { first:1,second:2,third:3,fourth:4,fifth:5,sixth:6,seventh:7,eighth:8,ninth:9 };
  const ord = brief.match(/\*\*([a-z-]+)\*\* consecutive round/i);
  let streak = null;
  if (ord) {
    const w = ord[1].toLowerCase();                    // e.g. "thirty-ninth"
    const m2 = w.match(/^([a-z]+)ty(?:-([a-z]+))?$/);  // tens-ordinal
    const tens = { twen:20, thir:30, for:40, fif:50, six:60, seven:70, eigh:80, nine:90 };
    if (m2 && tens[m2[1]] != null) streak = tens[m2[1]] + (m2[2] ? (words[m2[2]] ?? 0) : 0);
  }
  if (h || streak != null) cert = { hash: h ? h[1] : null, streak, source: 'proof/BRIEF.md' };
} catch {}

const proof = {
  schema: 'proof@1',
  generated_at: new Date().toISOString(),
  source: 'proof/RESULTS.txt',
  sha256,
  run: {
    id: 'b5.1-' + sha256.slice(0, 8),
    grid_version: g(/coherent with v(\d+\.\d+\.\d+)/),
    cert_hash: cert.hash,
    cert_streak: cert.streak,
    cert_source: cert.source,
    replayed_at: g(/replayed ([0-9TZ:\-]+)/),
    verifier: g(/on node (v[\d.]+)/),
  },
  upstream: {
    repo: null, commit: null,
    note: 'repo+commit not recorded in RESULTS.txt — the upstream emitter should add them',
  },
  gates: {
    negative_battery:  g(/NEGATIVE BATTERY:\s*(\d+\/\d+)/),
    harness_self_test: g(/HARNESS SELFTEST:\s*(\d+\/\d+)/),
    runner_contract:   g(/RUNNER CONTRACT:\s*(\d+\/\d+)/),
    derive_battery:    g(/DERIVE-BATTERY: PASS — (\d+\/\d+)/),
    realm_battery:     g(/DERIVE-REALM: PASS — (\d+\/\d+)/),
    cross_plane_bridge:g(/BRIDGE-CHECK: PASS — (\d+\/\d+)/),
    semantic_film:     g(/FILM-CHECK: PASS — (\d+\/\d+)/),
    lowering:          g(/LOWERING-CHECK: PASS — (\d+\/\d+)/),
    grid_entries:      g(/registry valid \((\d+) entries\)/, Number),
    grid_citations:    g(/(\d+) citations resolved/, Number),
  },
  totals: {
    attempted: g(/checks attempted\s+(\d+)/, Number),
    passed:    g(/passed\s+(\d+)/, Number),
    failed:    g(/failed\s+(\d+)/, Number) ?? 0,
    skipped:   g(/skipped\s+(\d+)/, Number) ?? 0,
  },
};

const out = here + '../site/proof/latest.json';
writeFileSync(out, JSON.stringify(proof, null, 2) + '\n');
console.log(JSON.stringify(proof, null, 2));
