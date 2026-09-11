import {visualEvidence} from './visual-evidence.mjs';
// End-to-end plan/file fixture flow. Run via tools/native-ui-test.sh.
/* Product flow in an isolated world; explicitly removes the disposable local test cache to verify runtime-only recovery. No runtime resets. */
import { spawn, execFileSync as run } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdirSync, writeFileSync, readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const port = Number(process.env.APP_SMOKE_PORT ?? 4464);
const base = `http://127.0.0.1:${port}`;
const shots = process.env.APP_SMOKE_SCREENSHOTS;
const proposedText=process.env.SUPER_TEXT_CHECK_ISSUES==='1'?'<h1>After task</h1> \n':'<h1>After task</h1>\n';
const expectedTextOutcome=process.env.SUPER_TEXT_CHECK_ISSUES==='1'?'fail':'pass';
const testData=mkdtempSync((process.env.DEVELOPMENT_TEST_ROOT??'/tmp')+'/super-app-smoke-');
const testRoot=process.env.DEVELOPMENT_TEST_ROOT;if(!testRoot)throw Error('Set DEVELOPMENT_TEST_ROOT to a disposable folder visible to the native chooser.');
const testRepo=mkdtempSync(testRoot+'/plan-repository-');run('git',['init','-q',testRepo]);writeFileSync(testRepo+'/index.html','<h1>Before task</h1>\n');
mkdirSync(testRepo+'/tools');writeFileSync(testRepo+'/tools/proposal-test.mjs',"import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';test('proposed page',async()=>{await new Promise(r=>setTimeout(r,1200));assert.equal(fs.readFileSync('index.html','utf8'),'<h1>After task</h1>\\n');});");
run('git',['-C',testRepo,'add','index.html']);run('git',['-C',testRepo,'-c','user.name=Super fixture','-c','user.email=fixture@example.invalid','commit','-qm','Starting file']);
const wrongRepo=mkdtempSync(testRoot+'/other-repository-');run('git',['init','-q',wrongRepo]);writeFileSync(wrongRepo+'/index.html','<h1>Before task</h1>\n');
const driver = spawn('tauri-driver', ['--port', String(port), '--native-port', String(port + 1), '--native-driver', '/usr/bin/WebKitWebDriver'], {
  cwd:testRepo, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
  env: { ...process.env, XDG_DATA_HOME:testData, AMPD_DIR: `${root}/ampd`, SUPER_WORLD_MODE: 'ephemeral', SUPER_COCKPIT_FIXTURE: '1', SUPER_COCKPIT_CARRIER: '0', SUPER_COCKPIT_PANE: '0', WEBKIT_DISABLE_COMPOSITING_MODE: '1' },
});
let lastBotRequest, chatCalls = 0;
const botFixture = createServer((req, res) => {
  if(req.url==='/api/tags'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({models:[{name:'fixture-model'}]}));return;}
  let data = ''; req.on('data', chunk => { data += chunk; });
  req.on('end', () => {
    lastBotRequest = JSON.parse(data); chatCalls++;
    if (lastBotRequest.messages.at(-1).content === 'Trigger provider error') { res.writeHead(503); res.end('{}'); return; }
    res.writeHead(200, {'content-type':'application/json'});
    if(lastBotRequest.messages.at(-1).content.includes('Make the planned edit')){res.end(JSON.stringify({message:{role:'assistant',content:'Review the planned change.',tool_calls:[{function:{name:'propose_file_edit',arguments:{path:'index.html',content:proposedText}}}]},done:true}));return;}
    const ref=lastBotRequest.messages[0].content.match(/ws_\d+/)?.[0]??'';
    res.end(JSON.stringify({message:{role:'assistant',content:`I can propose a workspace for you to review. Related workspace: ${ref}`,tool_calls:[{function:{name:'open_workspace',arguments:{name:'Bot proposed workspace'}}}]},done:true}));
  });
});
await new Promise(resolve => botFixture.listen(0, '127.0.0.1', resolve));
const botEndpoint = `http://127.0.0.1:${botFixture.address().port}`;
let log = '', session, checks = 0;
driver.stdout.on('data', b => { log = (log + b).slice(-8000); });
driver.stderr.on('data', b => { log = (log + b).slice(-8000); });
driver.on('error', e => { log += String(e); });
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function wd(method, path, body) {
  const r = await fetch(base + path, { method, headers: { 'content-type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(60000) });
  const j = await r.json(); if (!r.ok || j.value?.error) throw new Error(JSON.stringify(j)); return j.value;
}
const script = (code, args = []) => wd('POST', `/session/${session}/execute/sync`, { script: code, args });
async function until(fn, ms = 60000) { const end = Date.now() + ms; while (Date.now() < end) { const v = await fn(); if (v) return v; await sleep(150); } throw new Error('Timed out waiting for product state'); }
async function reloadPage(){const token=String(Date.now());await script('window.__planReloadToken=arguments[0];location.reload()',[token]);await until(()=>script('return window.__planReloadToken!==arguments[0]&&!!window.cockpit?.frame?.projection?.development_tasks&&!!document.querySelector("#development-task-list")',[token]));}
async function element(selector) { const e = await wd('POST', `/session/${session}/element`, { using: 'css selector', value: selector }); return e['element-6066-11e4-a52e-4f735466cecf']; }
async function click(selector) {
  for (let attempt = 0; attempt < 3; attempt++) {
    await script('document.querySelector(arguments[0]).scrollIntoView({block: "center", inline: "nearest"})', [selector]);
    try { return await wd('POST', `/session/${session}/element/${await element(selector)}/click`, {}); }
    catch (e) { if (!String(e).includes('stale element reference') || attempt === 2) throw e; }
  }
}
async function type(selector, text) { return wd('POST', `/session/${session}/element/${await element(selector)}/value`, { text }); }
const evidence=visualEvidence('development-plan-file-smoke',root,driver,["New lane appears in its bot Work page", "Assigned worker is visible without inventing an available terminal", "task creation binds the selected lane and bot", "blocker update retains criteria and appends history", "page reload reopens durable plan and blocker history", "goal record links back to its development plan", "plan opens Editor with explicit file selection guidance", "a different native repository cannot be shared with the plan", "plan file request opens the assigned bot without sending", "review records exact source and result identities", "disk changes during review refuse staging and preserve external bytes", "a new commit during review requires a fresh source attachment", "an older plan proposal cannot be staged after the plan changes", "fresh plan proposal stages without writing disk", "explicit Save writes the reviewed plan proposal", "clearing Editor plan context preserves the durable plan", "reopened conversation retains source and result as read-only history"]);
function check(label, value) { assert.ok(value, label); evidence.record(label); checks++; console.log(`held ${label}`); }
async function screenshot(name) {
  if (!shots) return;
  mkdirSync(shots, { recursive: true });
  const b = await wd('GET', `/session/${session}/screenshot`);
  writeFileSync(resolve(shots, `${name}.png`), Buffer.from(b, 'base64'));
}
try {
  await until(async()=>{try{return (await fetch(base+'/status')).ok;}catch{return false;}});
  const created=await wd('POST','/session',{capabilities:{alwaysMatch:{'tauri:options':{application:`${root}/cockpit/target/release/super-cockpit`}}}});session=created.sessionId;
  await until(()=>script('return !!window.cockpit?.frame?.projection'));
  await wd('POST',`/session/${session}/window/rect`,{width:1280,height:850});
  await click('#app-navigation [data-nav=positions]');await click('[data-screen=positions] [data-nav=new-workspace]');await type('[data-draft=workspace_name]','Super dogfood test');await click('[data-id=open-workspace] button');
  const ws=await until(()=>script(`return Object.values(window.cockpit.frame.projection.workspaces).find(w=>w.name==='Super dogfood test')`));
  await click('#app-navigation [data-nav=goals]');await click('[data-screen=goals] [data-setup-form=open-goal]');
  await script(`const e=document.querySelector('[data-draft=goal_ws]');e.value=arguments[0];e.dispatchEvent(new Event('change',{bubbles:true}))`,[ws.id]);
  await type('[data-draft=goal_title]','Make Super ready for dogfooding');await click('[data-id=open-goal] button');await until(()=>script(`return Object.values(window.cockpit.frame.projection.goals).some(g=>g.workspace_ref===arguments[0])`,[ws.id]));
  await click('#app-navigation [data-nav=repositories]');await click('[data-host-action=choose-repository]');await sleep(800);evidence.capture('Native repository folder picker before confirmation');
  const {execFileSync}=await import('node:child_process');execFileSync('/usr/bin/python3',[`${root}/tools/development-confirm-folder.py`,String(driver.pid)],{env:{...process.env,SUPER_CHOOSER_TITLE:'Register a local Git repository'}});await sleep(800);if(!await script('return Object.keys(window.cockpit.frame.projection.repositories??{}).length'))execFileSync('/usr/bin/python3',[`${root}/tools/development-confirm-folder.py`,String(driver.pid)],{env:{...process.env,SUPER_CHOOSER_TITLE:'Register a local Git repository'}});
  if(await script(`return !!document.querySelector('#retry-stream')`)){await click('#retry-stream');console.log('note: explicitly reconnected after native folder selection');}
  await until(()=>script('return Object.keys(window.cockpit.frame.projection.repositories??{}).length>0'));
  await click('[data-rail-mode=bots]');await click('#rail-bots [data-nav=new-bot]');
  await type('#new-bot-name','Super Builder');await type('#new-bot-role','Implementation');await type('#new-bot-instructions','Build Super with reviewable changes.');await script(`document.querySelector('#new-bot-provider').value='ollama'`);await click('#create-bot-submit');
  await until(()=>script(`return document.querySelector('#bot-surface h1').textContent==='Super Builder' && !document.querySelector('#bot-provider').disabled`));
  const route=await script(`return document.querySelector('#bot-surface').dataset.screen`);
  await script(`const p=document.querySelector('#bot-register-workspace');p.value=arguments[0];p.dispatchEvent(new Event('change'))`,[ws.id]);await click('#bot-register-runtime');
  const bot=await until(()=>script(`return Object.values(window.cockpit.frame.projection.bots??{}).find(b=>b.name==='Super Builder')`));
  await until(()=>script(`return document.querySelector('#bot-status').textContent.includes('Bot identity registered')`));
  await click('#bot-tab-work');await click('#bot-work [data-record-form=lane_actor]');
  check('Create lane carries the selected bot actor into the real form',await script(`return document.querySelector('[data-draft=lane_actor]').value===arguments[0]`,[bot.actor]));
  await script(`const p=window.cockpit.frame.projection,g=Object.values(p.goals).find(g=>g.workspace_ref===arguments[0]),repo=Object.values(p.repositories)[0];for(const [key,value] of [['lane_goal',g.id],['lane_repo',repo.ref??repo.id]]){const e=document.querySelector('[data-draft='+key+']');e.value=value;e.dispatchEvent(new Event('change',{bubbles:true}));}`,[bot.workspace_ref]);
  await click('[data-id=open-lane] button');
  const lane=await until(()=>script(`return Object.values(window.cockpit.frame.projection.lanes).find(l=>l.actor===arguments[0])`,[bot.actor]));
  await click('[data-rail-mode=bots]');await click(`#rail-bots [data-nav="${route}"]`);await click('#bot-tab-work');
  if(process.env.SUPER_VISUAL_EVIDENCE_DIR)await script(`document.querySelector(arguments[0])?.scrollIntoView({block:'center'})`,["#bot-work"]);check('New lane appears in its bot Work page',await script(`return document.querySelector('.bot-work-stats strong').textContent==='1' && !!document.querySelector('#bot-work [data-record-open="lane:'+arguments[0]+'"]')`,[lane.id]));
  await click('#bot-work [data-record-form=worker_lane]');await type('[data-draft=worker_purpose]','Implement and review Super changes');await click('[data-id=open-worker] button');
  const worker=await until(()=>script(`return Object.values(window.cockpit.frame.projection.workers).find(w=>w.locus_ref===arguments[0])`,[lane.id]));
  await click('[data-rail-mode=bots]');await click(`#rail-bots [data-nav="${route}"]`);await click('#bot-tab-work');
  if(process.env.SUPER_VISUAL_EVIDENCE_DIR)await script(`document.querySelector(arguments[0])?.scrollIntoView({block:'center'})`,["#bot-work"]);check('Assigned worker is visible without inventing an available terminal',await script(`return document.querySelectorAll('.bot-work-stats strong')[1].textContent==='1' && document.querySelectorAll('.bot-work-stats strong')[2].textContent==='0' && !document.querySelector('#bot-work [data-watch-worker]') && document.querySelector('#bot-work').textContent.includes('OFFLINE')`));
  await script(`document.querySelector('#workspace-canvas').scrollTop=0`);
  if(shots){mkdirSync(shots,{recursive:true});execFileSync('/usr/bin/python3',[`${root}/tools/development-capture-window.py`,String(driver.pid),resolve(shots,'Super_Progress_02_Bot_Work.png')]);}
  await click('#bot-work [data-record-open^="worker:"]');
  check('Worker link opens the actual worker record',await script(`return document.querySelector('[data-screen=record]').dataset.recordKey==='worker:'+arguments[0]`,[worker.id]));
  await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=development-tasks]');
  await type('#task-title','Highlight changed ranges');await type('#task-criteria','Changed lines are visible and Cancel preserves the draft.');await click('#development-task-form button');
  const task=await until(()=>script(`return Object.values(window.cockpit.frame.projection.development_tasks??{}).find(t=>t.title==='Highlight changed ranges')`));
  await until(()=>script(`return document.querySelector('#development-task-detail').textContent.includes('Plan history')`));
  check('task creation binds the selected lane and bot',task.lane_ref===lane.id&&task.bot_ref===bot.id&&task.status==='planned');
  await script(`const e=document.querySelector('#task-status');e.value='blocked';e.dispatchEvent(new Event('change',{bubbles:true}))`);
  await type('#task-note','Waiting for review guidance');await click('#development-plan-update button');
  await until(()=>script(`return window.cockpit.frame.projection.development_tasks[arguments[0]].revision===2`,[task.id]));
  await until(()=>script(`return document.querySelector('#development-task-detail').textContent.includes('Waiting for review guidance')`));
  if(process.env.SUPER_VISUAL_EVIDENCE_DIR)await script(`document.querySelector(arguments[0])?.scrollIntoView({block:'center'})`,["#development-task-detail form"]);check('blocker update retains criteria and appends history',await script(`const t=window.cockpit.frame.projection.development_tasks[arguments[0]];return t.status==='blocked'&&t.history.length===2&&t.criteria.includes('Cancel')`,[task.id]));
  await reloadPage();
  await click('#app-navigation [data-nav=development-tasks]');await click('#development-task-list article button');
  if(process.env.SUPER_VISUAL_EVIDENCE_DIR)await script(`document.querySelector(arguments[0])?.scrollIntoView({block:'center'})`,["#development-task-detail form"]);check('page reload reopens durable plan and blocker history',await script(`return document.querySelector('#development-task-detail').textContent.includes('Waiting for review guidance')`));
  await click('#development-task-detail [data-record-open^="goal:"]');
  if(process.env.SUPER_VISUAL_EVIDENCE_DIR)await script(`document.querySelector(arguments[0])?.scrollIntoView({block:'center'})`,["[data-development-task]"]);check('goal record links back to its development plan',await script(`return !!document.querySelector('[data-development-task="'+arguments[0]+'"]')`,[task.id]));
  await click('[data-screen=record] [data-development-task="'+task.id+'"]');
  check('goal backlink opens the same task',await script(`return !document.querySelector('#development-tasks').hidden&&document.querySelector('#development-task-detail').textContent.includes(arguments[0])`,[task.id]));
  if(shots){mkdirSync(shots,{recursive:true});execFileSync('/usr/bin/python3',[`${root}/tools/development-capture-window.py`,String(driver.pid),resolve(shots,'Super_Development_Task.png')]);}
  await click('#task-prepare-file');
  check('plan opens Editor with explicit file selection guidance',await script(`return !document.querySelector('[data-screen=editor]').hidden && document.querySelector('#editor-task-context').textContent.includes('Highlight changed ranges') && document.querySelector('#editor-task-context').textContent.includes('checks the repository')`));
  await click('#development-choose-editor');await sleep(700);execFileSync('/usr/bin/python3',[`${root}/tools/development-confirm-folder.py`,String(driver.pid),wrongRepo]);
  await until(()=>script(`return !!document.querySelector('[data-file-path="index.html"]')`));await click('[data-file-path="index.html"]');await until(()=>script(`return !document.querySelector('#editor-discuss').disabled`));await click('#editor-discuss');
  await until(()=>script(`return document.querySelector('#editor-status').textContent.includes('does not match')`));
  check('a different native repository cannot be shared with the plan',chatCalls===0&&await script(`return !document.querySelector('[data-screen=editor]').hidden`));
  await click('#development-choose-editor');await sleep(700);execFileSync('/usr/bin/python3',[`${root}/tools/development-confirm-folder.py`,String(driver.pid)]);await sleep(800);if(!await script(`return !!document.querySelector('[data-file-path="index.html"]')`))execFileSync('/usr/bin/python3',[`${root}/tools/development-confirm-folder.py`,String(driver.pid)]);
  await until(()=>script(`return !!document.querySelector('[data-file-path="index.html"]')`));await click('[data-file-path="index.html"]');await until(()=>script(`return !document.querySelector('#editor-discuss').disabled`));
  await click('#editor-discuss');
  await until(()=>script(`return document.querySelector('#bot-attachment-list').textContent.includes('index.html')`));
  if(process.env.SUPER_VISUAL_EVIDENCE_DIR)await script(`document.querySelector(arguments[0])?.scrollIntoView({block:'center'})`,["#bot-attachment-list"]);check('plan file request opens the assigned bot without sending',chatCalls===0&&await script(`return document.querySelector('#bot-surface h1').textContent==='Super Builder'&&document.querySelector('#bot-attachment-list').textContent.includes('index.html')`));
  await until(()=>script(`return !document.querySelector('#bot-provider').disabled`));
  await script(`const p=document.querySelector('#bot-provider');p.value='ollama';p.dispatchEvent(new Event('change'));const e=document.querySelector('#bot-endpoint');e.value=arguments[0];e.dispatchEvent(new Event('input',{bubbles:true}));`,[botEndpoint]);await click('#bot-connect');await until(()=>script(`return !document.querySelector('#bot-send').disabled`));
  await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=editor]');await click('#editor-discuss');await until(()=>script(`return !document.querySelector('#bot-surface').hidden&&document.querySelector('#bot-attachment-list').textContent.includes('index.html')`));await type('#bot-message','Make the planned edit');await click('#bot-send');
  await until(()=>script(`return [...document.querySelectorAll('.bot-proposal button')].some(b=>b.textContent==='Review in Editor')&&!document.querySelector('#bot-send').disabled`));
  check('native confirmation is included in the file attachment',lastBotRequest.messages.some(m=>m.content.includes('matched the plan')));
  check('provider receives plan criteria and the exact selected file',lastBotRequest.messages.some(m=>m.content.includes('Changed lines are visible')&&m.content.includes('<h1>Before task</h1>')));
  await script(`[...document.querySelectorAll('.bot-proposal button')].find(b=>b.textContent==='Review in Editor').click()`);await until(()=>script(`return !!document.querySelector('#bot-file-review[open]')`));
  check('file review identifies the plan and shows changed lines',await script(`return document.querySelector('#bot-file-review').textContent.includes(arguments[0])&&!!document.querySelector('#proposal-diff .added')&&!!document.querySelector('#proposal-diff .removed')`,[task.id]));
  await until(()=>script(`return !document.querySelector('#bot-file-use-draft').disabled`));
  check('review records exact source and result identities',await script(`return document.querySelector('#proposal-source-record').textContent.includes('draft_sha256')&&document.querySelector('#proposal-source-record').textContent.includes('result_sha256')`));
  if(shots)execFileSync('/usr/bin/python3',[`${root}/tools/development-capture-window.py`,String(driver.pid),resolve(shots,'Super_Pinned_File_Review.png')]);
  await script(`document.querySelector('#proposal-source-record').open=true`);evidence.capture('Expanded exact source and result record');await script(`document.querySelector('#proposal-source-record').open=false`);
  writeFileSync(testRepo+'/index.html','External edit\n');
  await click('#bot-file-use-draft');await until(()=>script(`return document.querySelector('#bot-file-review [role=status]').textContent.includes('changed on disk')`));
  check('disk changes during review refuse staging and preserve external bytes',readFileSync(testRepo+'/index.html','utf8')==='External edit\n'&&await script(`return !!document.querySelector('#bot-file-review[open]')`));
  writeFileSync(testRepo+'/index.html','<h1>Before task</h1>\n');
  run('git',['-C',testRepo,'-c','user.name=Super fixture','-c','user.email=fixture@example.invalid','commit','--allow-empty','-qm','Advance source commit']);
  await click('#bot-file-use-draft');await until(()=>script(`return document.querySelector('#bot-file-review [role=status]').textContent.includes('source commit or file changed')`));
  check('a new commit during review requires a fresh source attachment',await script(`return !!document.querySelector('#bot-file-review[open]')`));
  await click('#bot-file-cancel');
  await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=development-tasks]');
  await type('#task-note','Criteria need another review');await click('#development-plan-update button');await until(()=>script(`return window.cockpit.frame.projection.development_tasks[arguments[0]].revision===3`,[task.id]));
  await click('[data-rail-mode=bots]');await click(`#rail-bots [data-nav="${route}"]`);await script(`[...document.querySelectorAll('.bot-proposal button')].find(b=>b.textContent==='Review in Editor').click()`);
  if(process.env.SUPER_VISUAL_EVIDENCE_DIR)await script(`document.querySelector(arguments[0])?.scrollIntoView({block:'center'})`,[".bot-proposal"]);check('an older plan proposal cannot be staged after the plan changes',await script(`return !document.querySelector('#bot-file-review')&&document.querySelector('.bot-proposal').textContent.includes('plan changed')`));
  await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=editor]');
  await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=development-tasks]');await click('#task-prepare-file');await click('#editor-discuss');await until(()=>script(`return !document.querySelector('#bot-surface').hidden&&document.querySelector('#bot-attachment-list').textContent.includes('index.html')`));
  await until(()=>script(`return !document.querySelector('#bot-send').disabled`));await type('#bot-message','Make the planned edit');await click('#bot-send');
  await until(()=>chatCalls===2&&script(`return !document.querySelector('#bot-send').disabled`));
  await script(`[...document.querySelectorAll('.bot-proposal button')].filter(b=>b.textContent==='Review in Editor').at(-1).click()`);await until(()=>script(`return !!document.querySelector('#bot-file-review[open]')`));
  await until(()=>script(`return !document.querySelector('#bot-file-record-attempt').disabled`));
  await click('#bot-file-record-attempt');
  const attempt=await until(()=>script(`return Object.values(window.cockpit.frame.projection.development_attempts??{})[0]`));
  await until(()=>script(`return document.querySelector('#bot-file-record-attempt').textContent==='Review attempt saved'`));
  check('recording an attempt retains exact drafts without staging or saving',attempt.shared_draft==='<h1>Before task</h1>\n'&&attempt.proposed_text===proposedText&&attempt.task_revision===3&&readFileSync(testRepo+'/index.html','utf8')===attempt.shared_draft);
  evidence.capture('Review attempt saved independently of editor Save');
  await click('#bot-file-cancel');await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=development-tasks]');
  await until(()=>script(`return !!document.querySelector('[data-attempt-id="'+arguments[0]+'"]')`,[attempt.id]));
  await click('[data-attempt-id="'+attempt.id+'"] > summary');await click('[data-attempt-id="'+attempt.id+'"] > details > summary');
  check('plan exposes retained source and proposed text as read-only review material',await script(`const c=document.querySelector('[data-attempt-id="'+arguments[0]+'"]');return c.textContent.includes('Before task')&&c.textContent.includes('After task')&&!c.querySelector('[contenteditable=true]')`,[attempt.id]));
  await script(`document.querySelector('[data-attempt-id="'+arguments[0]+'"] > details').scrollIntoView({block:'center'})`,[attempt.id]);evidence.capture('Retained review source and proposed text on the plan');
  await type('#attempt-note-'+attempt.id,'Unsaved review note');await click('#attempt-check-'+attempt.id);
  check('text checks preserve unfinished review notes',await script(`return !window.cockpit.frame.projection.development_attempts[arguments[0]].text_check&&document.querySelector('#attempt-note-'+arguments[0]).value==='Unsaved review note'`,[attempt.id]));
  await script(`document.querySelector('#attempt-note-'+arguments[0]).value=''`,[attempt.id]);
  await click('#attempt-check-'+attempt.id);
  const checked=await until(()=>script(`return window.cockpit.frame.projection.development_attempts[arguments[0]].text_check`,[attempt.id]));
  check('text checks store the exact result identity and expected findings',checked.outcome===expectedTextOutcome&&checked.result_sha256===attempt.source.result_sha256&&checked.result_bytes===Buffer.byteLength(proposedText)&&checked.checks.at(-1).outcome==='not_applicable');
  check('checking text does not save files or claim plan acceptance',readFileSync(testRepo+'/index.html','utf8')===attempt.shared_draft&&await script(`return window.cockpit.frame.projection.development_tasks[arguments[0]].status==='blocked'`,[task.id]));
  await until(()=>script(`return !!document.querySelector('#attempt-checks-'+arguments[0])&&!document.querySelector('#attempt-check-'+arguments[0])`,[attempt.id]));
  await script(`document.querySelector('#attempt-checks-'+arguments[0]).scrollIntoView({block:'center'})`,[attempt.id]);
  check('text check UI identifies its limited scope and app tests not run',await script(`return document.querySelector('#attempt-checks-'+arguments[0]).textContent.includes('App tests were not run')&&document.querySelector('#attempt-checks-'+arguments[0]).textContent.includes(arguments[1])`,[attempt.id,expectedTextOutcome==='pass'?'Text checks passed':'Text checks found issues']));
  evidence.capture('Proposed text checks '+expectedTextOutcome+' with explicit scope');
  await type('#attempt-note-'+attempt.id,'Keep this unfinished review');await click('#attempt-run-'+attempt.id);
  check('starting tests preserves an unfinished review note',await script(`return document.querySelector('#attempt-note-'+arguments[0]).value==='Keep this unfinished review'&&document.querySelector('#attempt-tests-'+arguments[0]).textContent.includes('Save your unfinished')`,[attempt.id]));
  await script(`document.querySelector('#attempt-note-'+arguments[0]).value=''`,[attempt.id]);
  await click('#attempt-run-'+attempt.id);
  await until(()=>script(`return document.querySelector('#attempt-test-history-'+arguments[0]).textContent.includes(arguments[1])`,[attempt.id,expectedTextOutcome==='pass'?'Tests passed':'Tests failed']));
  check('native test control executes the saved proposal and displays its actual outcome',await script(`return document.querySelector('#attempt-test-history-'+arguments[0]).textContent.includes('Saved proposal only')`,[attempt.id]));
  await click('#attempt-test-history-'+attempt.id+' details > summary');
  await until(()=>script(`return Object.values(window.cockpit.frame.projection.development_attempts[arguments[0]].test_runs??{}).some(r=>r.state==='completed')`,[attempt.id]));
  check('runtime saves the test start and matching exact-result outcome',await script(`const runs=Object.values(window.cockpit.frame.projection.development_attempts[arguments[0]].test_runs);return runs.length===1&&runs[0].revision===2&&runs[0].result_sha256===arguments[1]&&runs[0].outcome.result_sha256===arguments[1]&&runs[0].outcome.verdict===arguments[2]`,[attempt.id,attempt.source.result_sha256,expectedTextOutcome]));
  await until(()=>script(`return document.querySelector('#attempt-test-history-'+arguments[0]).textContent.includes('Start and outcome saved in runtime')`,[attempt.id]));
  check('test output exposes the exact result and snapshot without saving the source file',readFileSync(testRepo+'/index.html','utf8')===attempt.shared_draft&&await script(`return document.querySelector('#attempt-test-history-'+arguments[0]).textContent.includes(arguments[1])&&document.querySelector('#attempt-test-history-'+arguments[0]).textContent.includes('# tests 1')`,[attempt.id,attempt.source.result_sha256]));
  await script(`document.querySelector('#attempt-tests-'+arguments[0]).scrollIntoView({block:'center'})`,[attempt.id]);evidence.capture('Local JavaScript tests '+expectedTextOutcome+' with saved output and snapshot');
  writeFileSync(testRepo+'/tools/proposal-test.mjs',"import test from 'node:test';test('wait for cancellation',async()=>{await new Promise(r=>setTimeout(r,20000));});");
  await click('#attempt-run-'+attempt.id);await until(()=>script(`return !!document.querySelector('#attempt-test-history-'+arguments[0]+' [data-cancel-test]')`,[attempt.id]));
  await script(`document.querySelector('#attempt-test-history-'+arguments[0]+' [data-cancel-test]').scrollIntoView({block:'center'})`,[attempt.id]);evidence.capture('Active local test run offers cancellation');
  await click('#attempt-test-history-'+attempt.id+' [data-cancel-test]');await until(()=>script(`return document.querySelector('#attempt-test-history-'+arguments[0]).textContent.includes('Cancelled')`,[attempt.id]));
  await until(()=>script(`return Object.values(window.cockpit.frame.projection.development_attempts[arguments[0]].test_runs).some(r=>r.outcome?.reason==='cancelled')`,[attempt.id]));
  check('cancelled test outcome is retained in runtime without a verdict',await script(`const r=Object.values(window.cockpit.frame.projection.development_attempts[arguments[0]].test_runs).find(r=>r.outcome?.reason==='cancelled');return r.state==='failed'&&r.outcome.verdict===null`,[attempt.id]));
  check('cancelling a native test run retains a cancelled outcome without acceptance',await script(`return !document.querySelector('#attempt-test-history-'+arguments[0]+' [data-cancel-test]')&&window.cockpit.frame.projection.development_tasks[arguments[1]].status==='blocked'`,[attempt.id,task.id]));
  await script(`document.querySelector('#attempt-test-history-'+arguments[0]+' article:last-child').scrollIntoView({block:'center'})`,[attempt.id]);evidence.capture('Cancelled local test run remains in review history');

  await script(`const e=document.querySelector('#attempt-status-'+arguments[0]);e.value='needs_changes';e.dispatchEvent(new Event('change'))`,[attempt.id]);
  await type('#attempt-note-'+attempt.id,'Improve the wording before validation');await click('[data-attempt-id="'+attempt.id+'"] form button');
  await until(()=>script(`return window.cockpit.frame.projection.development_attempts[arguments[0]].revision===3`,[attempt.id]));
  check('review note changes only its attempt and preserves plan status',await script(`return window.cockpit.frame.projection.development_attempts[arguments[0]].status==='needs_changes'&&window.cockpit.frame.projection.development_tasks[arguments[1]].status==='blocked'`,[attempt.id,task.id]));
  await script(`document.querySelector('[data-attempt-id="'+arguments[0]+'"] form').scrollIntoView({block:'center'})`,[attempt.id]);evidence.capture('Versioned review note and needs changes status');
  await click('[data-rail-mode=bots]');await click(`#rail-bots [data-nav="${route}"]`);
  await script(`[...document.querySelectorAll('.bot-proposal button')].filter(b=>b.textContent==='Review in Editor').at(-1).click()`);await until(()=>script(`return !!document.querySelector('#bot-file-review[open]')&&!document.querySelector('#bot-file-record-attempt').disabled`));
  await click('#bot-file-record-attempt');await until(()=>script(`return document.querySelector('#bot-file-record-attempt').textContent==='Review attempt saved'`));
  check('recording the same proposal again reuses its durable attempt',await script(`return Object.keys(window.cockpit.frame.projection.development_attempts).length===1&&window.cockpit.frame.projection.development_attempts[arguments[0]].revision===3`,[attempt.id]));
  await until(()=>script(`return !document.querySelector('#bot-file-use-draft').disabled`));await click('#bot-file-use-draft');await until(()=>script(`return !document.querySelector('#bot-file-review')`));
  check('fresh plan proposal stages without writing disk',readFileSync(testRepo+'/index.html','utf8')==='<h1>Before task</h1>\n'&&await script(`return !document.querySelector('#editor-save').disabled`));
  await click('#editor-save');await until(()=>script(`return document.querySelector('#editor-save').disabled`));
  check('explicit Save writes the reviewed plan proposal',readFileSync(testRepo+'/index.html','utf8')===proposedText);
  check('saving a proposal does not claim task acceptance',await script(`return window.cockpit.frame.projection.development_tasks[arguments[0]].status==='blocked'`,[task.id]));
  await click('#editor-clear-task');
  check('clearing Editor plan context preserves the durable plan',await script(`return document.querySelector('#editor-task-context').hidden && window.cockpit.frame.projection.development_tasks[arguments[0]].revision===3`,[task.id]));
  await reloadPage();
  check('reloading preserves the plan and saved file without sending again',chatCalls===2&&readFileSync(testRepo+'/index.html','utf8')===proposedText&&await script(`return window.cockpit.frame.projection.development_tasks[arguments[0]].revision===3`,[task.id]));
  await click('[data-rail-mode=bots]');await click(`#rail-bots [data-nav="${route}"]`);
  await until(()=>script(`return document.querySelector('#bot-surface').textContent.includes('result_sha256')`));
  if(process.env.SUPER_VISUAL_EVIDENCE_DIR)await script(`document.querySelector(arguments[0])?.scrollIntoView({block:'center'})`,[".bot-proposal:last-child"]);check('reopened conversation retains source and result as read-only history',chatCalls===2&&await script(`return document.querySelector('#bot-surface').textContent.includes('draft_sha256')&&![...document.querySelectorAll('.bot-proposal button')].some(b=>b.textContent==='Review in Editor')`));
  await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=development-tasks]');await click('#development-task-list article button');
  await click('[data-attempt-id="'+attempt.id+'"] > summary');
  check('reloading retains attempt bytes and versioned review history',await script(`const a=window.cockpit.frame.projection.development_attempts[arguments[0]];return a.revision===3&&a.shared_draft===arguments[1]&&a.proposed_text===arguments[2]&&document.querySelector('[data-attempt-id="'+arguments[0]+'"] ').textContent.includes('Improve the wording before validation')`,[attempt.id,attempt.shared_draft,attempt.proposed_text]));
  await script(`document.querySelector('[data-attempt-id="'+arguments[0]+'"] ').scrollIntoView({block:'center'})`,[attempt.id]);evidence.capture('Review attempt and notes restored after reload');
  assert.deepEqual(await script(`return window.cockpit.frame.projection.development_attempts[arguments[0]].text_check`,[attempt.id]),checked);
  await until(()=>script(`return document.querySelector('#attempt-test-history-'+arguments[0]).textContent.includes('Cancelled')`,[attempt.id]));
  check('runtime test history survives page reload independently of review revision',await script(`const a=window.cockpit.frame.projection.development_attempts[arguments[0]];return Object.keys(a.test_runs).length===2&&Object.values(a.test_runs).every(r=>r.revision===2)&&a.revision===3`,[attempt.id]));
  check('reopening a saved review restores local test outcomes and output',await script(`return document.querySelector('#attempt-test-history-'+arguments[0]).textContent.includes(arguments[1])&&document.querySelector('#attempt-test-history-'+arguments[0]).textContent.includes('# tests 1')`,[attempt.id,expectedTextOutcome==='pass'?'Tests passed':'Tests failed']));
  await script(`document.querySelector('#attempt-tests-'+arguments[0]).scrollIntoView({block:'center'})`,[attempt.id]);evidence.capture('Local test history restored after reopening');
  // Remove only this disposable app's local test cache; the runtime owns the durable record.
  rmSync(testData+'/com.computedriven.super.cockpit/review-tests',{recursive:true,force:true});
  await reloadPage();await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=development-tasks]');await click('#development-task-list article button');await click('[data-attempt-id="'+attempt.id+'"] > summary');
  await until(()=>script(`return document.querySelector('#attempt-test-history-'+arguments[0]).textContent.includes('Runtime test history')`,[attempt.id]));
  check('runtime results remain reviewable after the disposable local test cache is removed',await script(`const panel=document.querySelector('#attempt-test-history-'+arguments[0]);return panel.textContent.includes('Runtime outcome: '+arguments[1])&&panel.textContent.includes('Runtime outcome: cancelled')&&panel.textContent.includes('Start and outcome saved in runtime')`,[attempt.id,expectedTextOutcome]));
  await script(`document.querySelector('#attempt-tests-'+arguments[0]).scrollIntoView({block:'center'})`,[attempt.id]);evidence.capture('Runtime test history survives removal of local test cache');
  check('reopening preserves the exact text check and does not offer duplicate checks',await script(`return !document.querySelector('#attempt-check-'+arguments[0])`,[attempt.id]));
  writeFileSync(testRepo+'/index.html','Different later result\n');
  check('later file changes do not relabel saved checks as current checkout validation',await script(`return document.querySelector('#attempt-checks-'+arguments[0]).textContent.includes('Changes in the editor or other files are not covered')&&window.cockpit.frame.projection.development_attempts[arguments[0]].text_check.result_sha256===arguments[1]`,[attempt.id,attempt.source.result_sha256]));

  await script(`document.querySelector('#attempt-status-'+arguments[0]).value='dismissed'`,[attempt.id]);await type('#attempt-note-'+attempt.id,'Retain this proposal as history');await click('[data-attempt-id="'+attempt.id+'"] form button');
  await until(()=>script(`return window.cockpit.frame.projection.development_attempts[arguments[0]].revision===4`,[attempt.id]));
  check('dismissed attempt remains visible without editable review actions',await script(`return !document.querySelector('[data-attempt-id="'+arguments[0]+'"] form')&&document.querySelector('[data-attempt-id="'+arguments[0]+'"] ').textContent.includes('read-only history')`,[attempt.id]));
  await script(`document.querySelector('[data-attempt-id="'+arguments[0]+'"] ').scrollIntoView({block:'center'})`,[attempt.id]);evidence.capture('Dismissed review retained as read-only history');
  await script(`window.__retryRefusal=null;const w=window.cockpit.frame.world;window.__TAURI__.core.invoke('review_tests',{request:{operation:'retry',world:[w.world_incarnation,w.world_generation,w.projection_epoch],run_id:'run-not-retained'}}).then(()=>window.__retryRefusal='unexpected success',e=>window.__retryRefusal=String(e));`);
  await until(()=>script(`return window.__retryRefusal`));
  check('native retry refuses an outcome absent from this host session',await script(`return window.__retryRefusal.includes('No trusted completion')`));
  // Exercise the production panel with simulated transport failures. This is a UI
  // component fixture in the native window, separate from the real runtime flow above.
  await script(`window.__recoveryReady=false;import('./review-test-panel.js').then(({reviewTestPanel})=>{
    const host=document.createElement('section');host.id='recovery-ui-fixture';host.style='position:fixed;inset:40px;z-index:99999;background:#111827;color:#eee;padding:24px;overflow:auto;border:2px solid #64748b';
    const heading=document.createElement('h2');heading.textContent='Recovery UI fixture · simulated reporting failure';host.append(heading);
    const detail=document.createElement('details');detail.open=true;host.append(detail);document.body.append(host);
    const row={run_id:'run-recovery-fixture',attempt_ref:'recovery-fixture',state:'completed',runtime_save_error:true,retryable:true,result:{started_at:new Date().toISOString(),verdict:'fail',tests:['tools/example-test.mjs'],output:'Fixture: 1 test failed. Retained completion; no rerun.',snapshot_sha256:'fixture-snapshot',result_sha256:'fixture-result'}};
    const saved={run_id:row.run_id,state:'started'};const state={frame:{world:{world_incarnation:'fixture',world_generation:1,projection_epoch:'fixture'},projection:{development_attempts:{'recovery-fixture':{test_runs:{[row.run_id]:saved}}}}}};
    window.__recovery={calls:[],row,saved,state};
    const invoke=async(command,{request})=>{window.__recovery.calls.push(request.operation);if(request.operation==='list')return {runs:[structuredClone(row)]};if(request.operation==='retry'){await new Promise(r=>setTimeout(r,700));if(window.__recovery.calls.filter(x=>x==='retry').length===1)throw Error('Simulated connection loss. Retry when available.');row.retryable=false;row.runtime_save_error=false;saved.state='completed';return row;}throw Error('Unexpected operation: '+request.operation);};
    detail.append(reviewTestPanel({attempt:{id:'recovery-fixture',status:'dismissed'},invoke,current:()=>state}));window.__recoveryReady=true;
  });`);
  await until(()=>script(`return window.__recoveryReady&&!!document.querySelector('[data-retry-test="run-recovery-fixture"]')`));
  check('recovery UI fixture offers retry for a trusted retained completion',await script(`return document.querySelector('#recovery-ui-fixture').textContent.includes('Runtime start recorded · awaiting final outcome')`));
  evidence.capture('UI fixture - retained outcome offers retry');
  await click('[data-retry-test="run-recovery-fixture"]');
  check('recovery UI fixture disables retry while saving',await script(`return document.querySelector('[data-retry-test="run-recovery-fixture"]').disabled`));
  await until(()=>script(`return document.querySelector('#recovery-ui-fixture').textContent.includes('Simulated connection loss')&&!document.querySelector('[data-retry-test="run-recovery-fixture"]').disabled`));
  check('recovery UI fixture preserves retry after a reporting error',await script(`return window.__recovery.row.retryable&&window.__recovery.saved.state==='started'`));
  evidence.capture('UI fixture - failed report remains retryable');
  await click('[data-retry-test="run-recovery-fixture"]');
  await until(()=>script(`return document.querySelector('#recovery-ui-fixture').textContent.includes('Outcome saved. Tests were not rerun.')`));
  check('recovery UI fixture saves without starting or rerunning tests',await script(`return !document.querySelector('[data-retry-test="run-recovery-fixture"]')&&window.__recovery.calls.filter(x=>x==='retry').length===2&&!window.__recovery.calls.includes('start')&&document.querySelector('#recovery-ui-fixture').textContent.includes('Start and outcome saved in runtime')`));
  evidence.capture('UI fixture - outcome saved without rerunning tests');
  await script(`document.querySelector('#recovery-ui-fixture').remove();delete window.__recovery;`);
 evidence.complete();
  console.log(`development task smoke: ${checks} held`);
} catch(e){console.error(log);if(session)try{console.error(await script(`return document.querySelector('#workspace-canvas').innerText.slice(-4000)`));}catch{}throw e;} finally {evidence.close();botFixture.close();if(session)try{await wd('DELETE',`/session/${session}`);}catch{}try{process.kill(-driver.pid,'SIGTERM');}catch{}}
