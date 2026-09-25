#!/usr/bin/env node
/* recheck — re-evaluate a finished battery's saved reports with the current check.mjs.
 *
 *   node tools/kill-battery/recheck.mjs <results-dir>
 *
 * Every recovery report and every acknowledgement file is kept, so a check can be corrected without
 * re-running a kill. The events a kill is checked against are rebuilt exactly: the lineage's
 * acknowledgements before the `boot` line of the reboot that followed it. The first result is kept as
 * result.first-check.json; result.json is rewritten.
 */
import {readFileSync, writeFileSync, existsSync, copyFileSync} from 'node:fs';
import {join, resolve} from 'node:path';
import {check} from './check.mjs';

const OUT = resolve(process.argv[2]);
const lines = f => readFileSync(f, 'utf8').split('\n').filter(Boolean).flatMap(l => { try { return [JSON.parse(l)]; } catch { return []; } });
if (!existsSync(join(OUT, 'result.first-check.json'))) copyFileSync(join(OUT, 'result.json'), join(OUT, 'result.first-check.json'));
const res = JSON.parse(readFileSync(join(OUT, 'result.first-check.json'), 'utf8'));
for (const row of res.rows) {
  for (const k of ['acked', 'effects', 'receipts', 'lost', 'invented', 'unrecorded', 'split', 'open_preclaim', 'inflight']) delete row[k];
  if (row.outcome !== 'CONTINUED') continue;
  const ev = lines(join(OUT, `acks-L${row.lineage}.jsonl`));
  const bootAt = ev.map((e, i) => e.event === 'boot' ? i : -1).filter(i => i >= 0)[row.boot];
  const rep = JSON.parse(readFileSync(join(OUT, `report-L${row.lineage}-b${row.boot}.json`), 'utf8'));
  Object.assign(row, check(rep, ev.slice(0, bootAt)));
}
const count = f => res.rows.filter(f).length;
res.check = 'check.mjs (rechecked offline from the saved reports and acknowledgements)';
res.counts = {
  continued: count(r => r.outcome === 'CONTINUED'), sealed_running: count(r => r.outcome === 'SEALED'), boot_refused: count(r => r.outcome === 'BOOT-REFUSED'),
  any_dirty_table: count(r => r.dirty_tables.length), lost_acknowledged: res.rows.reduce((n, r) => n + (r.lost?.length ?? 0), 0),
  invented: res.rows.reduce((n, r) => n + (r.invented?.length ?? 0), 0), kills_with_torn_witness: count(r => r.witness_torn?.length),
  recoveries_with_split_claim: count(r => r.split?.length), recoveries_with_conflict_listing: count(r => r.split?.some(x => x.includes('CONFLICT'))),
  recoveries_with_open_preclaim: count(r => r.open_preclaim?.length),
};
writeFileSync(join(OUT, 'result.json'), JSON.stringify(res, null, 1));
for (const r of res.rows) console.log(`kill ${r.kill} L${r.lineage}b${r.boot} acked ${r.acked_before_kill} dirty [${r.dirty_tables}] ${r.outcome}` +
  (r.outcome === 'CONTINUED' ? ` lost ${r.lost.length} invented ${r.invented.length}${r.invented.length ? ' ' + JSON.stringify(r.invented) : ''}${r.lost.length ? ' ' + JSON.stringify(r.lost.slice(0, 2)) : ''} split ${JSON.stringify(r.split)} unrecorded ${JSON.stringify(r.unrecorded)} in-flight ${JSON.stringify(r.inflight.map(x => `${x.effect}:${x.state}/${x.crash_phase ?? '-'}/${x.grant_status}`))}` : ''));
console.log(JSON.stringify(res.counts));
