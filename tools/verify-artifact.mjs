#!/usr/bin/env node
/* Validates the receipt artifact's completeness before packaging.
   Honest scope: gate replay happens upstream in the TRVM repo; this
   stage guarantees we only ever package a complete, parseable receipt. */
import { readFileSync } from 'node:fs';
const here = new URL('.', import.meta.url).pathname;
const res = readFileSync(here+'../site/proof/RESULTS.txt','utf8');
const brief = readFileSync(here+'../site/proof/BRIEF.md','utf8');
/* same patterns as emit-proof.mjs — the verifier and the emitter must agree */
const need = [
  [/NEGATIVE BATTERY:\s*(\d+\/\d+)/,'negative battery'],
  [/HARNESS SELFTEST:\s*(\d+\/\d+)/,'harness self-test'],
  [/RUNNER CONTRACT:\s*(\d+\/\d+)/,'runner contract'],
  [/DERIVE-BATTERY: PASS — (\d+\/\d+)/,'derive battery'],
  [/DERIVE-REALM: PASS — (\d+\/\d+)/,'realm battery'],
  [/BRIDGE-CHECK: PASS — (\d+\/\d+)/,'cross-plane bridge'],
  [/FILM-CHECK: PASS — (\d+\/\d+)/,'semantic film'],
  [/LOWERING-CHECK: PASS — (\d+\/\d+)/,'lowering'],
  [/registry valid \((\d+) entries\)/,'grid entries'],
  [/(\d+) citations resolved/,'grid citations'],
  [/coherent with v(\d+\.\d+\.\d+)/,'grid version'],
  [/checks attempted\s+(\d+)/,'totals attempted'],
  [/passed\s+(\d+)/,'totals passed'],
];
let fail=false;
for(const [re,name] of need){ if(!re.test(res)){ console.error('ARTIFACT INCOMPLETE:',name); fail=true; } }
if(!/cert[_ ]?id\s+([0-9a-f]{8})/i.test(brief)){ console.error('ARTIFACT INCOMPLETE: cert id (BRIEF.md)'); fail=true; }
console.log(fail?'verify-artifact: FAILED':'verify-artifact: receipt artifact complete (gate replay is upstream; packaging its receipts)');
process.exit(fail?1:0);
