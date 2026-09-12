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
import {selectRepository, carriedPlan, refOf} from './lib/dogfood-selection.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const REAL = process.argv.includes('--real');

// Task titles and criteria are real open work, three of them found by Travis
// using the app. A dogfood whose tasks are invented teaches nothing about
// whether the product can carry work.
const WORKSPACE = 'Super';
// The repository this dogfood is about, by the name the projection publishes.
const REPOSITORY = 'ProjectAmp2/super';
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
  {title: 'A repository is offered as a bare reference with nothing to recognise it by',
   criteria:
     'Ampd.Projection publishes repositories as {ref} and discards the stored record, which ' +
     'holds the path. So the Repositories page titles a record with its own id and the lane ' +
     "form offers rp_0001 and rp_0002 — while choosing repository_ref is deciding which source " +
     'tree a bot may work in. Done when a person choosing a repository is shown something they ' +
     'recognise it by, without the reference being taken away, and without putting a home ' +
     'directory into a frame several surfaces read.'},
  {title: 'A change set cannot carry Super\u2019s own larger files',
   criteria:
     'A change set carries whole file text, not a diff, under three independent ceilings: ' +
     'shared_draft <= 24000 and proposed_text <= 32000 per file (command_spec.ex:340-341, ' +
     'development_attempt.ex:267-268), material <= 240000, and a bridge frame of 262144 bytes. ' +
     'Measured 2026-09-12 submitting the second held dogfood proposal against this repository: ' +
     'seven files refused with "frame of 336202 bytes exceeds the 262144 byte limit" before the ' +
     'validator saw them, and a two-file subset — a legal count — refused on the per-file caps. ' +
     'ampd/lib/ampd/projection.ex is 34282 bytes, cockpit/ui/cockpit.js is 72809 and ' +
     'cockpit/ui/cockpit.css is 35044, so Super cannot review a change to its own projection, ' +
     'its own UI entry point or its own stylesheet. Done when a review of a file this size is ' +
     'either carried or refused with a reason a person can act on, and the limit is stated ' +
     'before the material is composed rather than after it is submitted.'},
  {title: 'A refusal about size says the count is wrong',
   criteria:
     'Submitting two files whose bytes exceed the per-file caps is refused with ' +
     '"A change set needs two to four complete, valid file replacements." The count was two. ' +
     'set_file?/1 folds membership, byte caps, text validity and every digest into one boolean, ' +
     'so every failure returns the sentence about counting. A person reads it and counts their ' +
     'files. Done when a refusal names which of those conditions failed, and for which file, ' +
     'without disclosing the file contents back to the caller.'},
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
  /* `?? repos[0]` stood here, and on the first real run it opened the lane
     against the wrong repository. The missing labels made the list confusing;
     THE GUESS is what bound the lane, and no command closes a lane. There is no
     fallback now: an explicit unambiguous match, or this stops.
     `tools/dogfood-selection-test.mjs` holds the rule. */
  const wanted = (process.argv.find(a => a.startsWith('--repo=')) ?? '').slice('--repo='.length);
  const chosen = selectRepository({repos, wanted, name: REPOSITORY});
  const repo = chosen.repo;
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
  if (repo) note('kept', `repository · ${refOf(repo)}${repo.name ? ` · ${repo.name}` : ' · unnamed'}`);
  else note('needs-a-person', `repository · ${chosen.refusal.replace('the folder', ROOT)}`);

  /* A lane is (goal, actor, repository). Matching on the actor alone made an
     existing lane on a DIFFERENT repository read as this one already being
     set up. */
  let lane = (await cockpit.list('lanes')).find(
    l => l.actor === bot.record.actor && l.goal_ref === goal.record.id &&
         l.repository_ref === (repo && refOf(repo)));
  if (lane) note('kept', `lane · ${lane.id} · ${lane.repository_ref}`);
  else if (!repo) note('blocked', 'lane · a lane names a repository, and none is registered');
  else {
    await cockpit.intent('open_lane',
      {goal_ref: goal.record.id, actor: bot.record.actor,
       repository_ref: refOf(repo), base_revision: 'main'});
    lane = await cockpit.until(async () => (await cockpit.list('lanes')).find(
      l => l.actor === bot.record.actor && l.goal_ref === goal.record.id &&
           l.repository_ref === refOf(repo)), 20_000, `lane on ${refOf(repo)}`);
    note('created', `lane · ${bot.record.actor} on ${GOAL} · ${lane.id}`);
  }

  if (lane) {
    const worker = await cockpit.create('open_worker',
      {locus_ref: lane.id, purpose: WORKER_PURPOSE},
      {kind: 'workers', field: 'locus_ref', value: lane.id});
    note(worker.created ? 'created' : 'kept', `worker · ${WORKER_PURPOSE} · ${worker.record.id}`);

    /* Keyed on (lane, title, not cancelled) rather than title alone. Title
       alone matched a plan on a DIFFERENT lane — and, after a recovery, one
       that had been cancelled — so a plan this lane does not have read as
       already set up. */
    const planOn = async title =>
      carriedPlan({tasks: await cockpit.list('development_tasks'), lane: lane.id, title});
    for (const [n, t] of TASKS.entries()) {
      const already = await planOn(t.title);
      if (already) { note('kept', `task · ${t.title} · ${already.id}`); continue; }
      await cockpit.intent('create_development_task',
        {client_ref: `dogfood-task-${n + 1}-${lane.id}`, lane_ref: lane.id,
         title: t.title, criteria: t.criteria});
      const made = await cockpit.until(() => planOn(t.title), 20_000, `task ${t.title}`);
      note('created', `task · ${t.title} · ${made.id}`);
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
