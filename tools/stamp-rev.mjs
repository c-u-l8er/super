#!/usr/bin/env node
/* One revision source: release.json. Stamps README, blueprint, homepage footer. */
import { readFileSync, writeFileSync } from 'node:fs';
const here = new URL('.', import.meta.url).pathname;
const rev = JSON.parse(readFileSync(here + '../release.json','utf8')).revision;
const jobs = [
  /* **Any revision, not just an F one.** This was `/Rev F\.[0-9.]+ bundle/`,
     which could stamp forward *into* a new series exactly once and then
     never match its own output again: the first W.1 release rewrote
     `Rev F.8.2.5 bundle`, and the second refused the whole chain with
     STAMP TARGET MISSING. A stamper that cannot re-stamp the file it just
     wrote is a gate that fails on the second run of an unchanged tree. */
  ['../README.md', /Rev [A-Za-z0-9.]+ bundle/, `Rev ${rev} bundle`],
  ['../site/AGENT_SUPER_APP_BLUEPRINT.md', /\*\*Revision:\*\* [^\n]*/, `**Revision:** ${rev} (stamped from release.json)`],
  ['../site/index.html', /id="revlabel">[^<]*</, `id="revlabel">rev ${rev}<`],
];
let fail=false;
for (const [rel,re,rep] of jobs){
  const p=here+rel; let txt=readFileSync(p,'utf8');
  if(!re.test(txt)){ console.error('STAMP TARGET MISSING:',rel,re); fail=true; continue; }
  txt=txt.replace(re,rep); writeFileSync(p,txt);
  console.log('stamped',rel,'→',rev);
}
process.exit(fail?1:0);
