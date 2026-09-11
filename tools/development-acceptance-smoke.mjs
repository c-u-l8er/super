import {visualEvidence} from './visual-evidence.mjs';
// End-to-end plan/file fixture flow. Run via tools/native-ui-test.sh.
/* Disposable saved-world acceptance checks followed by a real app restart. */
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
let driver = spawn('tauri-driver', ['--port', String(port), '--native-port', String(port + 1), '--native-driver', '/usr/bin/WebKitWebDriver'], {
  cwd:testRepo, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
  env: { ...process.env, XDG_DATA_HOME:testData, XDG_STATE_HOME:testData+'/state', AMPD_DIR: `${root}/ampd`, SUPER_WORLD_MODE: 'saved', SUPER_WORLD: 'crash-fixture', SUPER_COCKPIT_FIXTURE: '0', SUPER_COCKPIT_CARRIER: '0', SUPER_COCKPIT_PANE: '0', WEBKIT_DISABLE_COMPOSITING_MODE: '1' },
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
const evidence=visualEvidence('development-acceptance-smoke',root,{get pid(){return driver.pid}},["New lane appears in its bot Work page", "Assigned worker is visible without inventing an available terminal", "task creation binds the selected lane and bot", "blocker update retains criteria and appends history", "page reload reopens durable plan and blocker history", "goal record links back to its development plan", "plan opens Editor with explicit file selection guidance", "a different native repository cannot be shared with the plan", "plan file request opens the assigned bot without sending", "review records exact source and result identities", "disk changes during review refuse staging and preserve external bytes", "a new commit during review requires a fresh source attachment", "an older plan proposal cannot be staged after the plan changes", "fresh plan proposal stages without writing disk", "explicit Save writes the reviewed plan proposal", "clearing Editor plan context preserves the durable plan", "reopened conversation retains source and result as read-only history"]);
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
  await click('[data-development-task="'+task.id+'"]');
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
  await type('#attempt-note-'+attempt.id,'Unsaved review note');await until(()=>script(`return document.querySelector('#attempt-note-'+arguments[0]).value==='Unsaved review note'`,[attempt.id]));await click('#attempt-check-'+attempt.id);
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
  await until(()=>script(`return !!document.querySelector('[data-accept-result="'+arguments[0]+'"]')`,[attempt.id]));
  await type('[data-acceptance-note="'+attempt.id+'"]','Reviewed the changed heading and passing snapshot against the criteria.');
  await script(`document.querySelector('[data-acceptance-run]').scrollIntoView({block:'center'})`);evidence.capture('Acceptance action and required human reason');
  await click('[data-accept-result="'+attempt.id+'"]');
  await until(()=>script(`return document.querySelector('#attempt-tests-'+arguments[0]).textContent.includes('Save the exact reviewed proposal')`,[attempt.id]));
  check('acceptance refuses a proposal that has not been saved',await script(`return !window.cockpit.frame.projection.development_attempts[arguments[0]].acceptance`,[attempt.id]));
  await script(`document.querySelector('#attempt-tests-'+arguments[0]+' [role=status]').scrollIntoView({block:'center'})`,[attempt.id]);evidence.capture('Acceptance refuses unsaved proposal bytes');
  await click('[data-rail-mode=bots]');await click('#rail-bots [data-nav="'+route+'"]');
  await script(`[...document.querySelectorAll('.bot-proposal button')].filter(b=>b.textContent==='Review in Editor').at(-1).click()`);
  await until(()=>script(`return !!document.querySelector('#bot-file-review[open]')&&!document.querySelector('#bot-file-use-draft').disabled`));
  await click('#bot-file-use-draft');await until(()=>script(`return !document.querySelector('#bot-file-review')`));await click('#editor-save');await until(()=>script(`return document.querySelector('#editor-save').disabled`));
  check('explicit Save writes the proposal before acceptance',readFileSync(testRepo+'/index.html','utf8')===proposedText);
  await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=development-tasks]');
  if(!await script(`return !!document.querySelector('[data-attempt-id="'+arguments[0]+'"]')`,[attempt.id]))await click('#development-task-list article button');
  if(!await script(`return document.querySelector('[data-attempt-id="'+arguments[0]+'"]').open`,[attempt.id]))await click('[data-attempt-id="'+attempt.id+'"] > summary');
  await until(()=>script(`return !!document.querySelector('[data-accept-result="'+arguments[0]+'"]')`,[attempt.id]));
  await script(`document.querySelector('[data-acceptance-note="'+arguments[0]+'"]').value='Reviewed the changed heading and passing snapshot against the criteria.'`,[attempt.id]);
  const testFile=readFileSync(testRepo+'/tools/proposal-test.mjs','utf8');writeFileSync(testRepo+'/tools/proposal-test.mjs',testFile+'\n// changed after testing\n');
  await click('[data-accept-result="'+attempt.id+'"]');await until(()=>script(`return document.querySelector('#attempt-tests-'+arguments[0]).textContent.includes('repository files differ')`,[attempt.id]));
  check('acceptance refuses another source file changed after the passing test',await script(`return !window.cockpit.frame.projection.development_attempts[arguments[0]].acceptance`,[attempt.id]));
  await script(`document.querySelector('#attempt-tests-'+arguments[0]+' [role=status]').scrollIntoView({block:'center'})`,[attempt.id]);evidence.capture('Acceptance refuses a changed test snapshot');
  writeFileSync(testRepo+'/tools/proposal-test.mjs',testFile);
  // Move only this disposable repository's HEAD, then restore its original ref.
  run('git',['-C',testRepo,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--allow-empty','-qm','Changed HEAD']);
  await click('[data-accept-result="'+attempt.id+'"]');await until(()=>script(`return document.querySelector('#attempt-tests-'+arguments[0]).textContent.includes('source commit changed')`,[attempt.id]));
  check('acceptance refuses a changed source commit',await script(`return !window.cockpit.frame.projection.development_attempts[arguments[0]].acceptance`,[attempt.id]));
  await script(`document.querySelector('#attempt-tests-'+arguments[0]+' [role=status]').scrollIntoView({block:'center'})`,[attempt.id]);evidence.capture('Acceptance refuses a changed source commit');
  run('git',['-C',testRepo,'update-ref','HEAD',attempt.source.head]);
  await click('[data-accept-result="'+attempt.id+'"]');
  const accepted=await until(()=>script(`return window.cockpit.frame.projection.development_attempts[arguments[0]].acceptance`,[attempt.id]));
  await until(()=>script(`return !!document.querySelector('[data-accepted-attempt="'+arguments[0]+'"]')`,[attempt.id]));
  check('acceptance keeps the review panel open to show the saved decision',await script(`return document.querySelector('[data-attempt-id="'+arguments[0]+'"]').open`,[attempt.id]));
  check('human acceptance retains the exact passing run and result identity',accepted.result_sha256===attempt.source.result_sha256&&accepted.snapshot_sha256&&accepted.provenance==='human-control-decision');
  check('accepted review is read-only and does not mark the whole plan completed',await script(`return !document.querySelector('#attempt-status-'+arguments[0])&&!document.querySelector('#attempt-run-'+arguments[0])&&window.cockpit.frame.projection.development_tasks[arguments[1]].status==='blocked'`,[attempt.id,task.id]));
  await script(`document.querySelector('[data-accepted-attempt="'+arguments[0]+'"]').scrollIntoView({block:'center'})`,[attempt.id]);evidence.capture('Accepted tested result with exact snapshot and human reason');
  writeFileSync(testRepo+'/index.html','Later unreviewed edit\n');
  check('later edits do not change the immutable acceptance record',JSON.stringify(await script(`return window.cockpit.frame.projection.development_attempts[arguments[0]].acceptance`,[attempt.id]))===JSON.stringify(accepted));
  const beforeWorld=await script(`return window.cockpit.frame.world`);
  // This process group was created above solely for this disposable saved world.
  process.kill(-driver.pid,'SIGKILL');session=null;await sleep(1500);
  driver=spawn('tauri-driver',['--port',String(port),'--native-port',String(port+1),'--native-driver','/usr/bin/WebKitWebDriver'],{
    cwd:testRepo,detached:true,stdio:['ignore','pipe','pipe'],env:{...process.env,XDG_DATA_HOME:testData, XDG_STATE_HOME:testData+'/state',AMPD_DIR:root+'/ampd',SUPER_WORLD_MODE:'saved',SUPER_WORLD:'crash-fixture',SUPER_COCKPIT_FIXTURE:'0',SUPER_COCKPIT_CARRIER:'0',SUPER_COCKPIT_PANE:'0',WEBKIT_DISABLE_COMPOSITING_MODE:'1'}});
  driver.stdout.on('data',b=>{log=(log+b).slice(-8000)});driver.stderr.on('data',b=>{log=(log+b).slice(-8000)});
  await until(async()=>{try{return (await fetch(base+'/status')).ok;}catch{return false;}});
  const reopened=await wd('POST','/session',{capabilities:{alwaysMatch:{'tauri:options':{application:root+'/cockpit/target/release/super-cockpit'}}}});session=reopened.sessionId;
  await until(()=>script(`return !!window.cockpit?.frame?.projection?.development_attempts?.[arguments[0]]`,[attempt.id]));
  await wd('POST',`/session/${session}/window/rect`,{width:1280,height:850});
  check('acceptance reopens in the same saved world with a new runtime',await script(`const w=window.cockpit.frame.world;return w.world_incarnation===arguments[0].world_incarnation&&w.world_generation===arguments[0].world_generation&&w.projection_epoch!==arguments[0].projection_epoch`,[beforeWorld]));
  await click('#app-navigation [data-nav=development-tasks]');await click('#development-task-list article button');await click('[data-attempt-id="'+attempt.id+'"] > summary');
  await until(()=>script(`return !!document.querySelector('[data-accepted-attempt="'+arguments[0]+'"]')`,[attempt.id]));
  check('saved-world restart retains acceptance and its exact evidence',JSON.stringify(await script(`return window.cockpit.frame.projection.development_attempts[arguments[0]].acceptance`,[attempt.id]))===JSON.stringify(accepted));
  check('reopened acceptance explicitly excludes later file edits',await script(`return document.querySelector('[data-accepted-attempt="'+arguments[0]+'"]').textContent.includes('Later edits are not covered')`,[attempt.id]));
  await script(`document.querySelector('[data-accepted-attempt="'+arguments[0]+'"]').scrollIntoView({block:'center'})`,[attempt.id]);evidence.capture('Acceptance and evidence survive app restart');
  evidence.complete();console.log(`development acceptance smoke: ${checks} held`);
} catch(e){console.error(log);if(session)try{console.error(await script(`return document.querySelector('#workspace-canvas').innerText.slice(-4000)`));}catch{}throw e;} finally {evidence.close();botFixture.close();if(session)try{await wd('DELETE',`/session/${session}`);}catch{}try{process.kill(-driver.pid,'SIGTERM');}catch{}}
