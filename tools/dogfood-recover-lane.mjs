#!/usr/bin/env node
/* Move this dogfood's development tasks off a lane bound to the wrong repository.
 *
 *   node tools/dogfood-recover-lane.mjs --real --from=ln_0016 --to=ln_0023
 *
 * Why this exists, and why it is not simply "delete and redo": on the first
 * real run of `dogfood-setup.mjs` the projection published repositories as
 * `{ref}` alone, the setup's `?? repos[0]` picked the first of two, and the
 * lane was opened against `ProjectAmp2/computedriven.com` instead of
 * `ProjectAmp2/super`. Nothing undoes that. There is no `close_lane`;
 * `delete_workspace` refuses a workspace that holds lanes on purpose
 * ("Lanes retain their ancestry"). So the wrong lane stays, and the honest
 * recovery is to re-create the plans on the right lane and CANCEL the
 * originals with a note that says what happened.
 *
 * New plans are created before any original is cancelled, so a refusal
 * leaves the work reachable rather than stranded. Both halves are idempotent:
 * a plan already carried on the target lane is kept, and a plan already
 * cancelled is left alone.
 */
import {open, Refused} from './lib/cockpit-control.mjs';
import {carriedPlan, livePlans} from './lib/dogfood-selection.mjs';

const arg = n => (process.argv.find(a => a.startsWith(`--${n}=`)) ?? '').slice(n.length + 3);
const REAL = process.argv.includes('--real');
const FROM = arg('from'), TO = arg('to');
if (!FROM || !TO) throw new Error('usage: --from=<lane> --to=<lane> [--real]');

const NOTE =
  'Re-created on the lane bound to ProjectAmp2/super. This plan was opened on a lane bound to ' +
  'ProjectAmp2/computedriven.com because the projection published repositories without a name ' +
  'and the setup took the first of two. No command closes a lane, so the plan is cancelled here ' +
  'rather than moved.';

const G = '\x1b[32m', Y = '\x1b[33m', R = '\x1b[31m', X = '\x1b[0m';
const note = (verb, what) =>
  console.log(`  ${verb === 'created' || verb === 'cancelled' ? G : verb === 'kept' ? Y : R}${verb.padEnd(12)}${X}${what}`);

console.log(`\nrecover lane — ${FROM} → ${TO}${REAL ? ` ${R}THE REAL WORLD${X}` : ''}\n`);

let cockpit, failed = null;
try {
  cockpit = await open({real: REAL});

  const lanes = await cockpit.list('lanes');
  const from = lanes.find(l => l.id === FROM), to = lanes.find(l => l.id === TO);
  if (!from) throw new Error(`no lane ${FROM}`);
  if (!to) throw new Error(`no lane ${TO}`);
  console.log(`  from ${from.id} · ${from.repository_ref}\n  to   ${to.id} · ${to.repository_ref}\n`);

  const all = () => cockpit.list('development_tasks');
  const stranded = livePlans({tasks: await all(), lane: FROM});
  if (!stranded.length) { note('kept', 'nothing stranded on the source lane'); }

  // 1. re-create, before anything is cancelled
  for (const t of stranded) {
    /* A CANCELLED plan on the target lane is not this plan carried forward —
       it is the record of work that was moved or abandoned. Matching one meant
       skipping the re-create and then cancelling the source, which loses the
       work this script exists to save. */
    const already = carriedPlan({tasks: await all(), lane: TO, title: t.title});
    if (already) { note('kept', `plan · ${t.title} · ${already.id}`); continue; }
    await cockpit.intent('create_development_task', {
      client_ref: `dogfood-recovered-${t.id}`, lane_ref: TO, title: t.title, criteria: t.criteria});
    const made = await cockpit.until(
      async () => carriedPlan({tasks: await all(), lane: TO, title: t.title}),
      20_000, `plan ${t.title} on ${TO}`);
    note('created', `plan · ${t.title} · ${made.id}`);
  }

  // 2. only now cancel the originals
  for (const t of stranded) {
    const carried = carriedPlan({tasks: await all(), lane: TO, title: t.title});
    if (!carried) { note('left', `plan · ${t.title} · not carried forward, NOT cancelled`); continue; }
    const now = (await all()).find(x => x.id === t.id);
    try {
      await cockpit.intent('update_development_task',
        {task_ref: t.id, revision: now.revision, status: 'cancelled', note: NOTE});
      note('cancelled', `plan · ${t.id} · ${t.title}`);
    } catch (e) {
      note('refused', `plan · ${t.id} · ${e instanceof Refused ? e.code : e.message}`);
    }
  }

  // 3. the worker on the wrong lane has nothing left to carry
  for (const w of await cockpit.list('workers')) {
    if (w.locus_ref !== FROM || w.status === 'closed') continue;
    try { await cockpit.intent('close_worker', {worker_ref: w.id}); note('closed', `worker · ${w.id}`); }
    catch (e) { note('refused', `worker · ${w.id} · ${e instanceof Refused ? e.code : e.message}`); }
  }

  note('left', `lane · ${FROM} · no command closes a lane; its ancestry stays on record`);
  console.log('');
} catch (e) {
  failed = e;
  console.error(`\n${R}failed${X}: ${e instanceof Refused ? `${e.intent} refused — ${e.code}` : e.message}\n`);
} finally {
  if (cockpit) await cockpit.close();
}
process.exit(failed ? 1 : 0);
