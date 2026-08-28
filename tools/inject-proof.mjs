#!/usr/bin/env node
/* Injects proof/latest.json into every #proofEmbed block, then asserts
   all embeds are byte-identical to the artifact. Stale embeds are a
   release failure, not a fallback.                                   */
import { readFileSync, writeFileSync } from 'node:fs';
const here = new URL('.', import.meta.url).pathname;
const artifact = readFileSync(here + '../site/proof/latest.json', 'utf8').trim();
const files = ['../site/index.html', '../site/app-prototype.html'];
const RE = /(<script type="application\/json" id="proofEmbed">)([\s\S]*?)(<\/script>)/;
let fail = false;
for (const rel of files){
  const path = here + rel;
  let html = readFileSync(path, 'utf8');
  if (!RE.test(html)){ console.error('MISSING proofEmbed:', rel); fail = true; continue; }
  html = html.replace(RE, (_, a, __, c) => a + artifact + c);
  writeFileSync(path, html);
  const back = readFileSync(path, 'utf8').match(RE)[2].trim();
  const ok = back === artifact;
  console.log((ok ? 'ok    ' : 'STALE ') + rel + '  embed==' + (ok ? 'latest.json' : 'DIVERGED'));
  if (!ok) fail = true;
}
process.exit(fail ? 1 : 0);
