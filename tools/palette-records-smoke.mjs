#!/usr/bin/env node
/* palette-records-smoke — Ctrl+K finds records, not only pages, and jumps to them.
   ────────────────────────────────────────────────────────────────────────

   THE GAP THIS PINS (dt_0063)

     The palette filtered `screens` by title and printed "No matching pages."
     A person holding a record id — dt_0052, bt_0034, rp_0003 — had nowhere to
     type it, and the Development tasks list hides plans outside the selected
     workspace. Now `findRecords` (cockpit/ui/record-finder.js) lists matching
     plans, attempts, workspaces, goals, lanes, bots, repositories and workers
     under a "Records" group; a plan row clears the workspace filter and opens
     the plan through development-tasks.js's own document handler; any other
     row opens its record page.

   HOW IT GETS RECORDS WITHOUT A CHOOSER

     `SUPER_COCKPIT_CARRIER=1` seeds a workspace, goal, lane, worker and the
     repository `d13b2f-repo`. A plan needs a lane whose actor is a registered
     bot, so the smoke registers one and opens a lane for it — the same three
     intents the app's own forms send — then creates the plan.

     node tools/palette-records-smoke.mjs                                    */
import {open} from './lib/cockpit-control.mjs';

process.env.SUPER_COCKPIT_CARRIER = '1';
process.env.GDK_BACKEND ??= 'x11';

let held = 0, failed = 0;
const check = (what, ok, detail = '') => {
  console.log(`  ${ok ? '\x1b[32mheld\x1b[0m' : '\x1b[31mFAILED\x1b[0m'}  ${what}${detail ? ' — ' + detail : ''}`);
  ok ? held++ : failed++;
};
const q = s => JSON.stringify(s);
const TITLE = 'Palette smoke plan';

console.log('\npalette-records (Ctrl+K finds records and jumps to them)\n');
let c;
try {
  c = await open();
  const lane = await c.until(async () => (await c.list('lanes'))[0], 60_000, 'a lane in the fixture world');
  const ws = (await c.list('workspaces'))[0], repo = (await c.list('repositories'))[0];
  check('the carrier witness seeded a workspace, a lane and a repository', !!ws && !!lane && !!repo, `${ws?.id} ${lane?.id} ${repo?.ref}`);
  // a plan needs a lane whose actor is a registered bot; the carrier lane's actor is not, so make both
  const goal = (await c.list('goals'))[0];
  const bot = (await c.create('register_bot', {client_ref: 'palette-smoke-bot', workspace_ref: ws.id, name: 'Palette smoke bot', role: 'Reviewer', group: 'Smoke', provider: 'ollama', instructions: 'Exists so a plan can be created in this throwaway world.'}, {kind: 'bots', field: 'name', value: 'Palette smoke bot'})).record;
  await c.intent('open_lane', {goal_ref: goal.id, actor: bot.actor, repository_ref: repo.ref});
  const botLane = await c.until(async () => (await c.list('lanes')).find(l => l.actor === bot.actor), 20_000, 'a lane held by the smoke bot');
  const plan = (await c.create('create_development_task', {client_ref: 'palette-smoke', lane_ref: botLane.id, title: TITLE, criteria: 'Found from the palette by id and by title.', required_checks: {profiles: ['super-javascript-behavior@1']}}, {kind: 'development_tasks', field: 'title', value: TITLE})).record;
  check('a plan exists to be found', /^dt_\d+$/.test(plan.id), plan.id);

  // pin the workspace filter to a value that would hide nothing here but proves the clearing path runs
  await c.page(`const w=document.querySelector('#workspace-picker'); w.value=${q(ws.id)}; w.dispatchEvent(new Event('change'));`);
  await c.page(`document.querySelector('#open-navigation').click()`);
  await c.until(() => c.page(`return document.querySelector('#navigation-dialog').open`), 10_000, 'palette open');
  check('the palette announces records as well as pages', await c.page(`return document.querySelector('#navigation-title').textContent`) === 'Go to a page or record' && (await c.page(`return document.querySelector('#navigation-search').placeholder`)).includes('record'));
  const type = async text => { await c.page(`const s=document.querySelector('#navigation-search'); s.value=${q(text)}; s.dispatchEvent(new Event('input',{bubbles:true}));`); };

  await type('d');
  check('one character searches pages only', await c.page(`return !document.querySelector('#navigation-results .palette-group')`));
  await type(plan.id);
  const rows = await c.until(() => c.page(`const r=[...document.querySelectorAll('#navigation-results .palette-result')].filter(b=>b.dataset.recordId);return r.length?r.map(b=>b.textContent):null;`), 10_000, 'record rows');
  check('typing a plan id lists it under Records with kind, id and title', rows.length === 1 && rows[0].startsWith(`Development plan · ${plan.id} · ${TITLE}`), rows[0]);
  check('the Records group label is present and Pages is absent when no page matches', await c.page(`const g=[...document.querySelectorAll('#navigation-results .palette-group')].map(p=>p.textContent);return JSON.stringify(g)`) === '["Records"]');

  await type(TITLE.slice(0, 7).toUpperCase());
  const byTitle = await c.until(() => c.page(`const r=[...document.querySelectorAll('#navigation-results .palette-result')].filter(b=>b.dataset.recordId===${q(plan.id)});return r.length?r.length:null;`), 10_000, 'title match');
  check('a title fragment, any case, finds the same plan', byTitle === 1);

  await type(repo.ref);
  const repoRow = await c.until(() => c.page(`return document.querySelector('#navigation-results .palette-result[data-record-kind="Repository"]')?.textContent ?? null`), 10_000, 'repository row');
  check('a repository ref lists the repository', repoRow.startsWith(`Repository · ${repo.ref} · ${repo.name}`), repoRow);
  await c.page(`document.querySelector('#navigation-results .palette-result[data-record-kind="Repository"]').click()`);
  await c.until(() => c.page(`return !document.querySelector('#navigation-dialog').open`), 10_000, 'palette closed');
  const recordKey = await c.until(() => c.page(`return document.querySelector('[data-screen=record]:not([hidden])')?.dataset.recordKey ?? null`), 10_000, 'record page');
  check('activating a repository row opens its record page', recordKey.endsWith(repo.ref), recordKey);

  await c.page(`document.querySelector('#open-navigation').click()`);
  await c.until(() => c.page(`return document.querySelector('#navigation-dialog').open`), 10_000, 'palette open again');
  await type(plan.id);
  await c.until(() => c.page(`return !!document.querySelector('#navigation-results .palette-result[data-development-task=${q(plan.id)}]')`), 10_000, 'plan row');
  await c.page(`document.querySelector('#navigation-results .palette-result[data-development-task=${q(plan.id)}]').click()`);
  await c.until(() => c.page(`return !document.querySelector('#navigation-dialog').open`), 10_000, 'palette closed');
  const detail = await c.until(() => c.page(`const d=document.querySelector('#development-task-detail');return d&&!document.querySelector('#development-tasks').hidden&&d.textContent.includes(${q(TITLE)})?d.textContent.slice(0,80):null;`), 10_000, 'plan detail');
  check('activating a plan row opens that plan on the Development tasks page', !!detail, detail);
  check('and the workspace filter was cleared so the plan cannot be hidden', await c.page(`return document.querySelector('#workspace-picker').value`) === '');

  await type('zzqx-nothing');
  await c.page(`document.querySelector('#open-navigation').click()`); await type('zzqx-nothing');
  check('no match reads "No matching pages or records."', (await c.until(() => c.page(`return document.querySelector('#navigation-results .empty')?.textContent ?? null`), 10_000, 'empty state')) === 'No matching pages or records.');
} catch (e) {
  check('the smoke ran to completion', false, String(e).slice(0, 300));
} finally {
  if (c) { try { await c.close(); } catch {} }
}
console.log(`\npalette-records: ${held} held · ${failed} failed\n`);
process.exit(failed ? 1 : 0);
