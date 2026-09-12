#!/usr/bin/env node
/* Stand up the structure Super needs in order to be built from Super.
 *
 *   node tools/dogfood-setup.mjs            a throwaway world (default)
 *   node tools/dogfood-setup.mjs --real     THE REAL WORLD
 *
 * This drives a real cockpit through `lib/cockpit-control.mjs`, which submits
 * `invoke('intent', {name, args})` — the same call every form in the page
 * makes, through the same webview grant, the same `:human_control` channel and
 * the same `CommandSpec` validation. A refusal is thrown, never swallowed.
 *
 * `--real` refuses to start while the world lock is held: a second cockpit
 * parks and writes nothing, which is indistinguishable from success.
 *
 * Idempotent by name throughout — nothing here creates a second of anything.
 *
 * One step is not scripted and cannot honestly be: registering a repository
 * opens a native chooser that accepts no path, so the folder a person selects
 * is the entire input. Without one, the lane, worker and tasks say what they
 * are waiting for rather than being invented.
 */
import {resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {open, Refused} from './lib/cockpit-control.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const REAL = process.argv.includes('--real');

// Task titles and criteria are real open work, three of them found by Travis
// using the app. A dogfood whose tasks are invented teaches nothing about
// whether the product can carry work.
const WORKSPACE = 'Super';
const GOAL = 'Build Super from Super';
const BOT = {
  name: 'Super builder',
  role: 'Proposes and revises changes to Super under review',
  group: 'General',
  provider: 'claude',
  instructions:
    'You are working on Super itself, in the repository this lane names. Propose exact file ' +
    'changes for review against the task criteria. You do not accept your own work.',
};
const WORKER_PURPOSE = 'Carry development tasks for Super itself';
const TASKS = [
  {title: 'A local bot profile cannot be deleted',
   criteria:
     'Creating a bot makes a conversational profile on the device. Nothing in bot-directory.js or ' +
     'bot-roster.js removes one, so a profile made by mistake is permanent. "Remove runtime ' +
     'registration" appears only once a bot IS registered, and removes the registration rather ' +
     'than the profile. Done when a local profile can be deleted, the control says which of the ' +
     'two it removes, and deleting a registered bot is either refused or removes both on purpose.'},
  {title: 'Register in workspace is disabled with no reason given',
   criteria:
     'The button is disabled whenever the workspace picker is empty, and the picker is empty ' +
     'whenever the held projection carries no workspaces. A person sees a dead button and no ' +
     'cause. Done when the disabled state names which condition is unmet.'},
  {title: 'Attaching a bot to a repository is only reachable through a lane',
   criteria:
     'A bot is bound to a repository by opening a lane, and the lane form lives on the bot Work ' +
     'tab, which needs runtime registration first. Nothing on the bot page says so, so the ' +
     'relationship looks absent. Done when the bot page states that a repository is attached by ' +
     'opening a lane, and links to where that happens.'},
  {title: 'README describes the prototype in the present tense',
   criteria:
     'The README bullet for site/app-prototype.html says a Bot explains, Nav organizes and ' +
     'Runtime proves — present tense — so a mockup reads as the product. This has already cost ' +
     'one session. Done when the bullet names it as a design reference and the page says so ' +
     'where a reader arrives.'},
];

const G = '\x1b[32m', Y = '\x1b[33m', R = '\x1b[31m', X = '\x1b[0m';
const done = [];
const note = (verb, what) => {
  console.log(`  ${verb === 'created' ? G : verb === 'kept' ? Y : R}${verb.padEnd(15)}${X}${what}`);
  done.push({verb, what});
};

console.log(`\ndogfood setup — ${REAL ? `${R}THE REAL WORLD${X}` : 'a throwaway world'}\n`);

let cockpit, failed = null;
try {
  cockpit = await open({real: REAL});

  const ws = await cockpit.create('open_workspace', {name: WORKSPACE},
    {kind: 'workspaces', field: 'name', value: WORKSPACE});
  note(ws.created ? 'created' : 'kept', `workspace · ${WORKSPACE} · ${ws.record.id}`);

  const goal = await cockpit.create('open_goal', {workspace_ref: ws.record.id, title: GOAL},
    {kind: 'goals', field: 'title', value: GOAL});
  note(goal.created ? 'created' : 'kept', `goal · ${GOAL} · ${goal.record.id}`);

  // The bot registers through the intent the page's own button sends. That
  // button is disabled until a provider is connected — a presentation gate,
  // not an authority one; the host accepts the same arguments either way. The
  // provider named here still has to be connected before the bot can work.
  const bot = await cockpit.create('register_bot',
    {client_ref: 'dogfood-super-builder', workspace_ref: ws.record.id,
     name: BOT.name, role: BOT.role, group: BOT.group,
     provider: BOT.provider, instructions: BOT.instructions},
    {kind: 'bots', field: 'name', value: BOT.name});
  note(bot.created ? 'created' : 'kept', `bot · ${BOT.name} · ${bot.record.actor}`);

  const repos = await cockpit.list('repositories');
  const repo = repos.find(r => /\/super$/.test(r.name ?? '')) ?? repos[0];
  // Evidence for the second held proposal, taken live rather than asserted:
  // a repository published without a name is the defect; with one, the fix.
  // The option text is read from the page because that is where a person makes
  // the choice, and an unnamed option is what made the choice unmakeable.
  if (repos.length) {
    const options = await cockpit.page(
      `const s=document.querySelector('[data-draft=lane_repo]');
       return s ? JSON.stringify([...s.options].map(o => o.textContent)) : '[]';`);
    console.log(`  repositories: ${repos.map(r => `${r.ref ?? r.id}=${r.name ?? '(no name published)'}`).join(', ')}`);
    console.log(`  lane form offers: ${options}`);
  }
  if (repo) note('kept', `repository · ${repo.ref ?? repo.id}${repo.name ? ` · ${repo.name}` : ' · unnamed'}`);
  else note('needs-a-person',
    `repository · none registered. Nav → Repositories → choose ${ROOT}. ` +
    `The chooser takes no path from a script, which is the point of it.`);

  let lane = await cockpit.find('lanes', 'actor', bot.record.actor);
  if (lane) note('kept', `lane · ${lane.id}`);
  else if (!repo) note('blocked', 'lane · a lane names a repository, and none is registered');
  else {
    const made = await cockpit.create('open_lane',
      {goal_ref: goal.record.id, actor: bot.record.actor,
       repository_ref: repo.ref ?? repo.id, base_revision: 'main'},
      {kind: 'lanes', field: 'actor', value: bot.record.actor});
    lane = made.record;
    note('created', `lane · ${bot.record.actor} on ${GOAL} · ${lane.id}`);
  }

  if (lane) {
    const worker = await cockpit.create('open_worker',
      {locus_ref: lane.id, purpose: WORKER_PURPOSE},
      {kind: 'workers', field: 'locus_ref', value: lane.id});
    note(worker.created ? 'created' : 'kept', `worker · ${WORKER_PURPOSE} · ${worker.record.id}`);

    for (const [n, t] of TASKS.entries()) {
      const task = await cockpit.create('create_development_task',
        {client_ref: `dogfood-task-${n + 1}`, lane_ref: lane.id,
         title: t.title, criteria: t.criteria},
        {kind: 'development_tasks', field: 'title', value: t.title});
      note(task.created ? 'created' : 'kept', `task · ${t.title}`);
    }
  } else {
    note('blocked', `worker and ${TASKS.length} tasks · both need a lane`);
  }

  const made = done.filter(d => d.verb === 'created').length;
  const kept = done.filter(d => d.verb === 'kept').length;
  console.log(`\n${made} created · ${kept} kept · ${done.length - made - kept} not done\n`);
} catch (e) {
  failed = e;
  console.error(`\n${R}failed${X}: ${e instanceof Refused ? `${e.intent} refused — ${e.code}` : e.message}\n`);
} finally {
  if (cockpit) await cockpit.close();
}
process.exit(failed ? 1 : 0);
