#!/usr/bin/env node
/* plan-steps-smoke — the plan detail is a wizard: a fresh plan opens on Prepare and shows
   only that step's sections; Finish exists but is off screen with its button hidden; the
   "Show every section" toggle brings the long view back; choosing a step narrows again.
   Real cockpit, throwaway world (SUPER_COCKPIT_CARRIER=1 seeds workspace/goal/repo).
     node tools/plan-steps-smoke.mjs                                          */
import {open} from './lib/cockpit-control.mjs';
process.env.SUPER_COCKPIT_CARRIER = '1'; process.env.GDK_BACKEND ??= 'x11';
let held = 0, failed = 0;
const check = (what, ok, detail = '') => { console.log(`  ${ok ? '\x1b[32mheld\x1b[0m' : '\x1b[31mFAILED\x1b[0m'}  ${what}${detail ? ' — ' + detail : ''}`); ok ? held++ : failed++; };
const q = s => JSON.stringify(s);
const TITLE = 'Plan steps smoke plan';
console.log('\nplan-steps (a plan shows where it is)\n');
let c;
try {
  c = await open();
  const ws = (await c.list('workspaces'))[0], repo = (await c.list('repositories'))[0], goal = (await c.list('goals'))[0];
  const bot = (await c.create('register_bot', {client_ref: 'plan-steps-smoke-bot', workspace_ref: ws.id, name: 'Plan steps bot', role: 'Reviewer', group: 'Smoke', provider: 'ollama', instructions: 'Holds the smoke lane.'}, {kind: 'bots', field: 'name', value: 'Plan steps bot'})).record;
  await c.intent('open_lane', {goal_ref: goal.id, actor: bot.actor, repository_ref: repo.ref});
  const lane = await c.until(async () => (await c.list('lanes')).find(l => l.actor === bot.actor), 20_000, 'lane');
  const plan = (await c.create('create_development_task', {client_ref: 'plan-steps-smoke', lane_ref: lane.id, title: TITLE, criteria: 'Steps render.', required_checks: {profiles: ['super-javascript-behavior@1']}}, {kind: 'development_tasks', field: 'title', value: TITLE})).record;
  await c.page(`document.querySelector('[data-rail-mode=nav]')?.click(); document.querySelector('#app-navigation [data-nav=development-tasks]').click();`);
  await c.until(() => c.page(`return !!document.querySelector('[data-development-task=${q(plan.id)}]')`), 15_000, 'plan listed');
  await c.page(`document.querySelector('[data-development-task=${q(plan.id)}]').click()`);
  await c.until(() => c.page(`return !!document.querySelector('#task-steps')`), 15_000, 'stepper');
  const states = await c.page(`return [...document.querySelectorAll('#task-steps li')].map(l=>l.dataset.step+':'+l.dataset.state).join(' ')`);
  check('a fresh plan shows five steps with Prepare current and the rest to do', states === 'prepare:current review:todo checks:todo accept:todo finish:todo', states);
  const visible = () => c.page(`return [...document.querySelectorAll('#development-task-detail [data-plan-panel]')].filter(n=>!n.hidden).map(n=>n.dataset.planPanel).join(' ')`);
  check('the wizard opens on the current step and shows only its sections', await visible() === 'head brief next prepare editor session history', await visible());
  check('attempts, evidence and Finish are not on screen at Prepare', await c.page(`return ['attempts','runs','fleet','screens','finish'].every(k=>document.querySelector('[data-plan-panel='+k+']').hidden)`));
  check('Finish this plan exists, hidden, with its button hidden and the reason read-only, saying which step comes first', await c.page(`const f=document.querySelector('#task-finish');return f?.dataset.finishable==='false'&&document.querySelector('#task-complete').hidden&&document.querySelector('#task-completion-reason').readOnly&&f.textContent.includes('Not yet: prepare file request first')`));
  check('to-do steps are not clickable; the current step is', await c.page(`return document.querySelector('#task-steps [data-step=finish] button').disabled&&!document.querySelector('#task-steps [data-step=prepare] button').disabled`));
  check('history and the planning note are one collapsed line', await c.page(`const h=document.querySelector('details.plan-history');return !!h&&!h.open&&h.querySelector('summary').textContent.startsWith('Plan history (1)')&&!!h.querySelector('#task-note')`));
  await c.page(`document.querySelector('#task-wizard-all').click()`);
  check('"Show every section" reveals all of them', await c.page(`return [...document.querySelectorAll('#development-task-detail [data-plan-panel]')].every(n=>!n.hidden)`) && await c.page(`return document.querySelector('#development-task-detail').dataset.wizardStep==='all'`));
  await c.page(`document.querySelector('#task-steps [data-step=prepare] button').click()`);
  check('choosing a step turns the long view back into that step', await visible() === 'head brief next prepare editor session history' && await c.page(`return document.querySelector('#development-task-detail').dataset.wizardStep==='prepare'`));
  check('the drafted reason is empty because nothing is accepted', await c.page(`return document.querySelector('#task-completion-reason').value===''`));
} catch (e) { check('the smoke ran to completion', false, String(e).slice(0, 300)); }
finally { if (c) { try { await c.close(); } catch {} } }
console.log(`\nplan-steps: ${held} held · ${failed} failed\n`);
process.exit(failed ? 1 : 0);
