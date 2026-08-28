#!/usr/bin/env node
/* Fails the release if proof literals appear outside sanctioned regions.
   The forbidden list is DERIVED from proof/latest.json — the artifact
   defines what counts as a transcribable figure.                       */
import { readFileSync } from 'node:fs';
const here = new URL('.', import.meta.url).pathname;
const P = JSON.parse(readFileSync(here+'../site/proof/latest.json','utf8'));
const esc = s => String(s).replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
const pats = [];
for (const v of Object.values(P.gates||{})) if (/^\d+\/\d+$/.test(String(v))) pats.push(new RegExp('\\b'+esc(v)+'\\b'));
if (P.totals && P.totals.passed!=null) pats.push(new RegExp('\\b'+esc(P.totals.passed+'/'+P.totals.attempted)+'\\b'));
if (P.run){
  if (P.run.cert_hash)   pats.push(new RegExp(esc(P.run.cert_hash),'i'));
  if (P.run.cert_streak!=null) pats.push(new RegExp('×\\s?'+esc(P.run.cert_streak)+'\\b'));
  if (P.run.grid_version) pats.push(new RegExp('\\b'+esc(P.run.grid_version)+'\\b'));
}
if (P.gates && P.gates.grid_entries!=null)  pats.push(new RegExp('\\b'+esc(P.gates.grid_entries)+'\\s+entries\\b','i'));
if (P.gates && P.gates.grid_citations!=null) pats.push(new RegExp('\\b'+esc(P.gates.grid_citations)+'\\s+citations\\b','i'));
const SANCTION = [
  /<script type="application\/json" id="proofEmbed">[\s\S]*?<\/script>/g,
  /<!--\s*proof:quoted[\s\S]*?-->[\s\S]*?<!--\s*\/proof:quoted\s*-->/g,
  /\/\*\s*proof:quoted[\s\S]*?\/\*\s*\/proof:quoted\s*\*\//g,
];
let violations=0;
for (const rel of ['../site/index.html','../site/app-prototype.html']){
  let scrub = readFileSync(here+rel,'utf8');
  for (const re of SANCTION) scrub = scrub.replace(re, m => '\n'.repeat(m.split('\n').length-1));
  scrub.split('\n').forEach((line,i)=>{ for (const re of pats) if (re.test(line)){
    console.error(`VIOLATION ${rel}:${i+1}  /${re.source}/  ${line.trim().slice(0,100)}`); violations++; } });
}
console.log(violations?`proof battery: ${violations} violation(s)`:`proof battery: clean — ${pats.length} artifact-derived literals checked`);
process.exit(violations?1:0);
