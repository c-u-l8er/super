#!/usr/bin/env node
/* Stand up the structure Super needs in order to be built from Super.
 *
 * There is no other door. The world is reachable only through the cockpit's
 * human-control channel — ampd is a child of the cockpit on an inherited
 * socketpair fd, it is not a distributed node, and there is no CLI. So this
 * drives the real page with the real controls: it navigates the rail, fills
 * the same draft fields a person types into, and clicks the same buttons, so
 * every record is created by `open_workspace`, `open_goal`, `register_bot`,
 * `open_lane`, `open_worker` and `create_development_task` exactly as the
 * forms submit them. Nothing reaches around the page.
 *
 *   node tools/dogfood-setup.mjs            a throwaway world (default)
 *   node tools/dogfood-setup.mjs --real     THE REAL WORLD — see below
 *
 * `--real` takes the world lock, so the desktop must be stopped first and
 * every paired phone session dies with it. It REFUSES to start if something
 * already holds the lock, rather than parking silently and writing nothing —
 * which is what a second cockpit does, and it looks identical to success.
 *
 * Idempotent by name. A workspace, goal, bot, lane, worker or task that is
 * already there is reported `kept` and left alone.
 *
 * The repository step is the one that is not scripted input: `choose_repository`
 * accepts no page-supplied path by design and opens a native chooser. The
 * chooser opens on the driver's working directory, which is this repository,
 * so it is confirmed rather than typed into.
 */
import {spawn, execFileSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, existsSync} from 'node:fs';
import {resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const REAL = process.argv.includes('--real');
const port = Number(process.env.DOGFOOD_PORT ?? 4491);
const base = `http://127.0.0.1:${port}`;

// ---------------------------------------------------------------- the plan
// Task titles and criteria are real open work. A dogfood whose tasks are
// invented teaches nothing about whether the product can carry work.
const WORKSPACE = 'Super';
const GOAL = 'Build Super from Super';
const BOT = {
  name: 'Super builder',
  role: 'Proposes and revises changes to Super under review',
  instructions:
    'You are working on Super itself, in the repository this lane names. Propose exact file ' +
    'changes for review against the task criteria. You do not accept your own work.',
};
const WORKER_PURPOSE = 'Carry development tasks for Super itself';
const TASKS = [
  {title: 'README describes the prototype in the present tense',
   criteria:
     "The README bullet for site/app-prototype.html says a Bot explains, Nav organizes and Runtime " +
     'proves — present tense — so a mockup reads as the product. This has already cost one session. ' +
     'Done when the bullet names it as a design reference and the page says so where a reader arrives.'},
  {title: 'Retained accepted builds are never cleaned up',
   criteria:
     'Accepted builds accumulate with no retention rule and no way to remove one. Done when a ' +
     'superseded build can be removed, the rule is stated where builds are listed, and an ' +
     'abnormally terminated preview cannot leave a build that nothing can clean.'},
  {title: 'android-test.sh run walks tabs that no longer exist',
   criteria:
     'Its tab coordinates predate the Needs me / Plans / Stack / Host shell, so it taps an Activity ' +
     'and a Capture tab that are gone and reports nothing wrong. Done when it either asserts what it ' +
     'walked or defers to android-regression.sh and says so.'},
];

// ------------------------------------------------------------------ report
const G = '\x1b[32m', Y = '\x1b[33m', R = '\x1b[31m', X = '\x1b[0m';
const done = [];
function note(verb, what) {
  console.log(`  ${verb === 'created' ? G : verb === 'kept' ? Y : R}${verb.padEnd(8)}${X}${what}`);
  done.push({verb, what});
}

// ------------------------------------------------------------- refuse first
const stateHome = process.env.XDG_STATE_HOME ?? process.env.HOME + '/.local/state';
const lock = `${stateHome}/super/worlds/default/world.lock`;
if (REAL && existsSync(lock)) {
  let holder = '';
  try { holder = execFileSync('fuser', [lock], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore']}).trim(); } catch {}
  if (holder) {
    console.error(`\n${R}refusing${X}: the world lock is held by pid${holder}.\n` +
      `A second cockpit parks and writes nothing, and that looks exactly like success.\n` +
      `Stop it first:  systemctl --user stop super-desktop\n`);
    process.exit(2);
  }
}

const temp = mkdtempSync('/tmp/super-dogfood-');
mkdirSync(temp, {recursive: true});
const worldEnv = REAL
  ? {AMPD_DIR: root + '/ampd'}
  : {AMPD_DIR: root + '/ampd', XDG_DATA_HOME: temp + '/data', XDG_STATE_HOME: temp + '/state',
     SUPER_WORLD_MODE: 'ephemeral'};

console.log(`\ndogfood setup — ${REAL ? `${R}THE REAL WORLD${X}` : 'a throwaway world'}\n`);

const driver = spawn('tauri-driver',
  ['--port', String(port), '--native-port', String(port + 1), '--native-driver', '/usr/bin/WebKitWebDriver'],
  {cwd: root, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
   env: {...process.env, GDK_BACKEND: 'x11', SUPER_COCKPIT_PANE: '0',
         // A throwaway run uses the cockpit's provider fixture, because
         // `register_bot` requires a provider and a rehearsal must not depend
         // on a live Claude or Ollama being connected. The real run must NOT:
         // a bot registered against a stub provider is a bot that cannot work.
         SUPER_COCKPIT_FIXTURE: REAL ? '0' : '1',
         WEBKIT_DISABLE_COMPOSITING_MODE: '1', ...worldEnv}});
let log = '', session = null;
driver.stdout.on('data', b => (log = (log + b).slice(-8000)));
driver.stderr.on('data', b => (log = (log + b).slice(-8000)));

const sleep = ms => new Promise(r => setTimeout(r, ms));
async function wd(method, path, body) {
  const r = await fetch(base + path, {method, headers: {'content-type': 'application/json'},
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(60000)});
  const j = await r.json();
  if (!r.ok || j.value?.error) throw new Error(JSON.stringify(j).slice(0, 300));
  return j.value;
}
const script = (code, args = []) => wd('POST', `/session/${session}/execute/sync`, {script: code, args});
async function until(fn, ms = 30000, what = 'a condition') {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    try { const v = await fn(); if (v) return v; last = v; } catch (e) { last = e.message; }
    await sleep(250);
  }
  throw new Error(`timed out waiting for ${what} (last seen: ${String(last).slice(0, 160)})`);
}
const click = sel => script(
  `const e=document.querySelector(arguments[0]); if(!e) return 'missing'; if(e.disabled) return 'disabled'; e.click(); return 'ok';`,
  [sel]).then(r => { if (r !== 'ok') throw new Error(`${sel}: ${r}`); });
const type = (sel, text) => script(
  `const e=document.querySelector(arguments[0]); if(!e) return 'missing';
   e.value=arguments[1]; e.dispatchEvent(new Event('input',{bubbles:true})); return 'ok';`,
  [sel, text]).then(r => { if (r !== 'ok') throw new Error(`${sel}: ${r}`); });
const setDraft = (key, value) => script(
  `const e=document.querySelector('[data-draft='+arguments[0]+']'); if(!e) return 'missing';
   e.value=arguments[1]; e.dispatchEvent(new Event(e.tagName==='SELECT'?'change':'input',{bubbles:true})); return 'ok';`,
  [key, value]).then(r => { if (r !== 'ok') throw new Error(`draft ${key}: ${r}`); });
const setId = (id, value) => script(
  `const e=document.getElementById(arguments[0]); if(!e) return 'missing';
   e.value=arguments[1]; e.dispatchEvent(new Event('change',{bubbles:true})); return 'ok';`,
  [id, value]).then(r => { if (r !== 'ok') throw new Error(`#${id}: ${r}`); });
const projection = expr => script(`const p=window.cockpit.frame.projection; return JSON.stringify(${expr} ?? null);`)
  .then(s => JSON.parse(s));

let failed = null;
try {
  await until(() => fetch(base + '/status').then(r => r.ok).catch(() => false), 30000, 'tauri-driver');
  session = (await wd('POST', '/session', {capabilities: {alwaysMatch:
    {'tauri:options': {application: `${root}/cockpit/target/release/super-cockpit`}}}})).sessionId;
  await until(() => script('return !!window.cockpit?.frame?.projection'), 60000, 'the runtime to publish a frame');
  await wd('POST', `/session/${session}/window/rect`, {width: 1280, height: 900});

  // ------------------------------------------------------------- workspace
  let ws = await projection(`Object.values(p.workspaces??{}).find(w=>w.name===${JSON.stringify(WORKSPACE)})`);
  if (ws) note('kept', `workspace · ${WORKSPACE}`);
  else {
    await click('#app-navigation [data-nav=positions]');
    await click('[data-screen=positions] [data-nav=new-workspace]');
    await type('[data-draft=workspace_name]', WORKSPACE);
    await click('[data-id=open-workspace] button');
    ws = await until(() => projection(`Object.values(p.workspaces??{}).find(w=>w.name===${JSON.stringify(WORKSPACE)})`),
      20000, 'the workspace');
    note('created', `workspace · ${WORKSPACE}`);
  }

  // ------------------------------------------------------------------ goal
  let goal = await projection(`Object.values(p.goals??{}).find(g=>g.title===${JSON.stringify(GOAL)})`);
  if (goal) note('kept', `goal · ${GOAL}`);
  else {
    await click('#app-navigation [data-nav=goals]');
    await click('[data-screen=goals] [data-setup-form=open-goal]');
    await setDraft('goal_ws', ws.id);
    await type('[data-draft=goal_title]', GOAL);
    await click('[data-id=open-goal] button');
    goal = await until(() => projection(`Object.values(p.goals??{}).find(g=>g.title===${JSON.stringify(GOAL)})`),
      20000, 'the goal');
    note('created', `goal · ${GOAL}`);
  }

  // ------------------------------------------------------------ repository
  // Not scripted input. `choose_repository` accepts no path from the page; the
  // host opens a native chooser, and the chooser opens on the driver's working
  // directory — this repository. The helper confirms it.
  const repoCount = () => projection('Object.keys(p.repositories??{}).length');
  if (await repoCount()) note('kept', `repository · ${await repoCount()} already registered`);
  else {
    await click('#app-navigation [data-nav=repositories]');
    await click('[data-host-action=choose-repository]');
    await sleep(900);
    // Say whether the dialog is even on screen. Without this, "the chooser did
    // not register one" cannot be told apart from "the chooser never opened",
    // and those need different fixes.
    try {
      const titles = execFileSync('python3', [`${process.env.HOME}/.cache/super-session/wins.py`],
        {encoding: 'utf8', env: {...process.env, DISPLAY: ':0'}});
      if (!/Register a local Git repository/.test(titles)) {
        note('absent', 'repository · the native chooser did not open (no window with that title)');
      }
    } catch {}
    for (const attempt of [1, 2]) {
      try {
        execFileSync('/usr/bin/python3', [`${root}/tools/development-choose-folder.py`],
          {env: {...process.env, SUPER_CHOOSER_TITLE: 'Register a local Git repository'}, stdio: 'ignore'});
      } catch {}
      await sleep(1200);
      if (await repoCount()) break;
      if (attempt === 2) break;
    }
    if (await repoCount()) note('created', `repository · ${root}`);
    // The dialog opens — the window-title probe above confirms it — and
    // confirming it from outside does not register anything. `choose_repository`
    // accepts no page-supplied path by design, so the folder a person selects in
    // that window is the whole input, and driving it is the one step this script
    // has no honest way to perform.
    else note('needs-a-person', 'repository · the chooser opens; choose the folder in it yourself');
  }
  const repo = await projection('Object.values(p.repositories??{})[0]');

  // ------------------------------------------------------------------- bot
  let bot = await projection(`Object.values(p.bots??{}).find(b=>b.name===${JSON.stringify(BOT.name)})`);
  if (bot) note('kept', `bot · ${BOT.name}`);
  else {
    await click('[data-rail-mode=bots]');
    await click('#rail-bots [data-nav=new-bot]');
    await type('#new-bot-name', BOT.name);
    await type('#new-bot-role', BOT.role);
    await type('#new-bot-instructions', BOT.instructions);
    await click('#create-bot-submit');
    // `#create-bot-submit` creates a CONVERSATIONAL PROFILE on this device, not
    // a runtime identity — the form says so. `register_bot` is the second
    // click, and without it the bot never appears in the projection at all.
    await until(() => script(
      `return document.querySelector('#bot-surface h1')?.textContent===arguments[0] && !document.querySelector('#bot-provider')?.disabled`,
      [BOT.name]), 30000, 'the new bot to open');
    await setId('bot-register-workspace', ws.id);
    const state = await script(`
      const b=document.getElementById('bot-register-runtime');
      const w=document.getElementById('bot-register-workspace');
      return JSON.stringify({
        button: b ? {disabled: b.disabled, text: b.textContent} : 'missing',
        workspaceSelect: w ? {value: w.value, disabled: w.disabled,
          options: [...w.options].map(o=>({v:o.value,t:o.textContent}))} : 'missing',
        status: document.getElementById('bot-status')?.textContent ?? null,
        provider: (()=>{const p=document.getElementById('bot-provider');
          return p?{value:p.value,disabled:p.disabled}:'missing'})(),
        note: [...document.querySelectorAll('#bot-surface .availability-note, #bot-surface p')]
          .map(n=>n.textContent).filter(t=>t && t.length<220).slice(0,6),
      });`);
    const s2 = JSON.parse(state);
    if (s2.button === 'missing' || s2.button.disabled) {
      // Not a defect. The bot page will not register a profile into the runtime
      // until a provider is connected — "Connect this provider to begin" — and
      // connecting Codex or Claude means signing in through a browser, which is
      // a person establishing an account relationship, not a field to fill.
      // The workspace list stays empty until then, which is why the button is
      // disabled rather than the click being refused.
      note('needs-a-person',
        `bot · profile "${BOT.name}" created; Register in workspace is disabled until a provider ` +
        `is connected (status: "${s2.status}"; workspaces offered: ${s2.workspaceSelect.options.length - 1})`);
      bot = null;
    } else {
      await setId('bot-register-workspace', ws.id);
      await click('#bot-register-runtime');
      bot = await until(() => projection(`Object.values(p.bots??{}).find(b=>b.name===${JSON.stringify(BOT.name)})`),
        30000, 'the bot to be registered to the runtime');
      note('created', `bot · ${BOT.name}`);
    }
  }

  // ------------------------------------------------------------------ lane
  // The lane form is opened from the bot's Work page so the actor is carried
  // in rather than typed: a person cannot assign someone to a lane that is
  // not theirs, which is referential closure rather than a validation.
  let lane = bot ? await projection(`Object.values(p.lanes??{}).find(l=>l.actor===${JSON.stringify(bot?.actor)})`) : null;
  if (lane) note('kept', `lane · ${bot.actor}`);
  else if (!bot) note('blocked', 'lane · a lane names a bot actor, and no bot is registered');
  else if (!repo) note('blocked', 'lane · no repository is registered');
  else {
    await click('#bot-tab-work');
    await click('#bot-work [data-record-form=lane_actor]');
    await setDraft('lane_goal', goal.id);
    await setDraft('lane_repo', repo.ref ?? repo.id);
    await click('[data-id=open-lane] button');
    lane = await until(() => projection(`Object.values(p.lanes??{}).find(l=>l.actor===${JSON.stringify(bot.actor)})`),
      20000, 'the lane');
    note('created', `lane · ${bot.actor} on ${GOAL}`);
  }

  // ---------------------------------------------------------------- worker
  if (lane) {
    const found = await projection(`Object.values(p.workers??{}).find(w=>w.locus_ref===${JSON.stringify(lane.id)})`);
    if (found) note('kept', `worker · on ${lane.id}`);
    else {
      await click('#bot-work [data-record-form=worker_lane]');
      await type('[data-draft=worker_purpose]', WORKER_PURPOSE);
      await click('[data-id=open-worker] button');
      await until(() => projection(`Object.values(p.workers??{}).find(w=>w.locus_ref===${JSON.stringify(lane.id)})`),
        20000, 'the worker');
      note('created', `worker · ${WORKER_PURPOSE}`);
    }
  }

  // ----------------------------------------------------------------- tasks
  if (lane) {
    await click('[data-rail-mode=nav]');
    await click('#app-navigation [data-nav=development-tasks]');
    for (const t of TASKS) {
      const has = await projection(`Object.values(p.development_tasks??{}).find(d=>d.title===${JSON.stringify(t.title)})`);
      if (has) { note('kept', `task · ${t.title}`); continue; }
      await type('#task-title', t.title);
      await type('#task-criteria', t.criteria);
      await click('#development-task-form button');
      await until(() => projection(`Object.values(p.development_tasks??{}).find(d=>d.title===${JSON.stringify(t.title)})`),
        20000, `task ${t.title}`);
      note('created', `task · ${t.title}`);
      await sleep(600);
    }
  } else {
    note('blocked', `tasks · a task needs a lane; ${TASKS.length} not created`);
  }

  const made = done.filter(d => d.verb === 'created').length;
  const kept = done.filter(d => d.verb === 'kept').length;
  const missed = done.length - made - kept;
  console.log(`\n${made} created · ${kept} kept · ${missed} not done\n`);
  if (!REAL) console.log(`The throwaway world is at ${temp} and can be deleted.\n`);
} catch (e) {
  failed = e;
  console.error(`\n${R}failed${X}: ${e.message}\n`);
  console.error(log.slice(-1200));
} finally {
  if (session) await wd('DELETE', `/session/${session}`).catch(() => {});
  try { process.kill(-driver.pid, 'SIGTERM'); } catch {}
}
process.exit(failed ? 1 : 0);
