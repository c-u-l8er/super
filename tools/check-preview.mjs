#!/usr/bin/env node
/* The social preview's figures must match the artifact. Divergence fails
   the release; a missing meta means the preview was never generated from
   this artifact — regenerate with tools/render-preview.py.            */
import { readFileSync, existsSync } from 'node:fs';
const here = new URL('.', import.meta.url).pathname;
const P = JSON.parse(readFileSync(here+'../site/proof/latest.json','utf8'));
const metaPath = here+'../site/preview/preview-meta.json';
if (!existsSync(metaPath)){ console.error('check-preview: preview-meta.json missing — run tools/render-preview.py'); process.exit(1); }
const M = JSON.parse(readFileSync(metaPath,'utf8'));
const want = { sha:P.sha256, frac:P.totals.passed+'/'+P.totals.attempted, streak:P.run.cert_streak };
let fail=false;
if (M.source_sha256!==want.sha){ console.error(`check-preview: sha mismatch (${M.source_sha256?.slice(0,8)}… vs ${want.sha.slice(0,8)}…)`); fail=true; }
if (M.frac!==want.frac){ console.error(`check-preview: totals mismatch (${M.frac} vs ${want.frac})`); fail=true; }
if (M.cert_streak!==want.streak){ console.error(`check-preview: streak mismatch (${M.cert_streak} vs ${want.streak})`); fail=true; }
console.log(fail?'check-preview: FAILED':'check-preview: preview figures match the artifact');
process.exit(fail?1:0);
