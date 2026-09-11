import {visualEvidence} from './visual-evidence.mjs';

// End-to-end plan/file fixture flow. Run via tools/native-ui-test.sh.
/* Product flow in an isolated world; explicitly removes the disposable local test cache to verify runtime-only recovery. No runtime resets. */
import { spawn, execFileSync as run } from 'node:child_process';
import { createServer } from 'node:http';
import { existsSync, statSync, mkdirSync, writeFileSync, readFileSync, readdirSync, mkdtempSync, rmSync } from 'node:fs';
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
const testRepo=mkdtempSync(testRoot+'/plan-repository-');run('git',['init','-q',testRepo]);writeFileSync(testRepo+'/index.html','<h1>Before task</h1>\n');writeFileSync(testRepo+'/style.css','h1 { color: red; }\n');
mkdirSync(testRepo+'/tools');writeFileSync(testRepo+'/tools/proposal-test.mjs',"import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';test('replacement and deleted stylesheet',async()=>{await new Promise(r=>setTimeout(r,1200));assert.equal(fs.readFileSync('index.html','utf8'),'<h1>After task</h1>\\n');assert.equal(fs.existsSync('style.css'),false);});");
run('git',['-C',testRepo,'add','index.html','style.css']);run('git',['-C',testRepo,'-c','user.name=Super fixture','-c','user.email=fixture@example.invalid','commit','-qm','Starting file']);
const wrongRepo=mkdtempSync(testRoot+'/other-repository-');run('git',['init','-q',wrongRepo]);writeFileSync(wrongRepo+'/index.html','<h1>Before task</h1>\n');
let driver = spawn('tauri-driver', ['--port', String(port), '--native-port', String(port + 1), '--native-driver', '/usr/bin/WebKitWebDriver'], {
  cwd:testRepo, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
  env: { ...process.env, XDG_DATA_HOME:testData, AMPD_DIR: `${root}/ampd`, XDG_STATE_HOME:testData+'/state', SUPER_WORLD_MODE: 'saved', SUPER_WORLD:'durable-set-fixture', SUPER_COCKPIT_FIXTURE: '0', SUPER_COCKPIT_CARRIER: '0', SUPER_COCKPIT_PANE: '0', WEBKIT_DISABLE_COMPOSITING_MODE: '1' },
});
let lastBotRequest, chatCalls = 0;
const botFixture = createServer((req, res) => {
  if(req.url==='/api/tags'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({models:[{name:'fixture-model'}]}));return;}
  let data = ''; req.on('data', chunk => { data += chunk; });
  req.on('end', () => {
    lastBotRequest = JSON.parse(data); chatCalls++;
    if (lastBotRequest.messages.at(-1).content === 'Trigger provider error') { res.writeHead(503); res.end('{}'); return; }
    res.writeHead(200, {'content-type':'application/json'});
    if(lastBotRequest.messages.at(-1).content.includes('Make the planned edit')){res.end(JSON.stringify({message:{role:'assistant',content:'Review the planned change.',tool_calls:[{function:{name:'propose_file_edit',arguments:{path:'index.html',content:proposedText}}},{function:{name:'propose_file_edit',arguments:{path:'style.css',content:null}}}]},done:true}));return;}
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
const evidence=visualEvidence('deletion-review-smoke',root,driver);
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
  await type('#task-title','Remove obsolete stylesheet');await type('#task-criteria','Deleted file is absent and Cancel preserves the originals.');
  await click('#task-required-checks input');await click('#development-task-form button');
  check('new plans cannot omit all required checks',await script(`return document.querySelector('#development-task-form').parentElement.textContent.includes('Choose at least one required check.')&&Object.keys(window.cockpit.frame.projection.development_tasks??{}).length===0`));
  await click('#task-required-checks input');
  if(shots){mkdirSync(shots,{recursive:true});execFileSync('/usr/bin/python3',[`${root}/tools/development-capture-window.py`,String(driver.pid),resolve(shots,'00_Required_Check_Selection.png')]);}
  await click('#development-task-form button');
  const task=await until(()=>script(`return Object.values(window.cockpit.frame.projection.development_tasks??{}).find(t=>t.title==='Remove obsolete stylesheet')`));
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
  check('plan opens Editor with explicit file selection guidance',await script(`return !document.querySelector('[data-screen=editor]').hidden && document.querySelector('#editor-task-context').textContent.includes('Remove obsolete stylesheet') && document.querySelector('#editor-task-context').textContent.includes('checks the repository')`));
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

  while(await script(`return !!document.querySelector('#bot-attachment-list button')`))await click('#bot-attachment-list button');
  const photo=name=>evidence.capture(name);
  await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=editor]');
  await click('[data-file-path="style.css"]');await click('#editor-share-files');
  await script(`for(const c of document.querySelectorAll('[data-related-file]'))c.checked=true`);await click('#related-files-attach');
  await until(()=>script(`return document.querySelector('#bot-attachment-list').textContent.includes('style.css')`));
  check('related files attach without sending',chatCalls===0);await script(`document.querySelector('#bot-attachment-list').scrollIntoView({block:'center'})`);photo('01_Related_Files');
  await type('#bot-message','Make the planned edit');await click('#bot-send');
  await until(()=>script(`return !!document.querySelector('[data-review-file-set]')&&!document.querySelector('#bot-send').disabled`));
  check('provider receives both complete drafts',lastBotRequest.messages.some(m=>m.content.includes('h1 { color: red; }'))&&lastBotRequest.messages.some(m=>m.content.includes('<h1>Before task</h1>')));
  await click('[data-review-file-set]');await until(()=>script(`return !!document.querySelector('#bot-file-set-review[open]')`));
  check('combined review lists both files and separate unsaved staging',await script(`const d=document.querySelector('#bot-file-set-review');return d.querySelectorAll('[data-proposal-set-path]').length===2&&d.textContent.includes('Files remain unsaved')&&d.textContent.includes('test the complete set')`));photo('02_Combined_Review');
  await click('[data-proposal-set-path="style.css"]');
  check('file switch explicitly displays deletion and the original text',await script(`return document.querySelector('#bot-file-set-review .file-proposal-columns').textContent.includes('File will be deleted')&&document.querySelector('#bot-file-set-review .file-proposal-columns').textContent.includes('red')`));
  await wd('POST',`/session/${session}/window/rect`,{width:1000,height:760});await sleep(300);photo('05_Narrow_Review');
  check('narrow combined review keeps both file choices and staging accessible',await script(`const d=document.querySelector('#bot-file-set-review'),b=d.querySelector('#bot-file-set-stage');return d.getBoundingClientRect().width<=innerWidth&&b.getBoundingClientRect().bottom<=innerHeight&&d.querySelectorAll('[data-proposal-set-path]').length===2`));
  await wd('POST',`/session/${session}/window/rect`,{width:1280,height:850});
  await click('#bot-file-set-cancel');
  check('cancelling leaves every editor draft and disk file unchanged',await script(`return !document.querySelector('[data-screen=editor] .workbench-tabs').textContent.includes('●')`)&&readFileSync(testRepo+'/index.html','utf8')==='<h1>Before task</h1>\n'&&readFileSync(testRepo+'/style.css','utf8')==='h1 { color: red; }\n');
  await click('[data-rail-mode=bots]');await click(`#rail-bots [data-nav="${route}"]`);await click('[data-review-file-set]');
  writeFileSync(testRepo+'/style.css','External CSS edit\n');await click('#bot-file-set-stage');
  await until(()=>script(`return document.querySelector('#bot-file-set-review [role=status]').textContent.includes('changed on disk')`));
  check('changed second file refuses the whole set with no first-file staging',await script(`return !document.querySelector('[data-screen=editor] .workbench-tabs').textContent.includes('●')`)&&readFileSync(testRepo+'/style.css','utf8')==='External CSS edit\n');photo('03_Conflict_Refused');
  writeFileSync(testRepo+'/style.css','h1 { color: red; }\n');
  await click('#bot-file-set-record');
  const savedSet=await until(()=>script(`return Object.values(window.cockpit.frame.projection.development_attempts??{}).find(a=>a.schema==='development-review-set@1')`));
  await until(()=>script(`return document.querySelector('#bot-file-set-record').textContent==='Combined review saved'`));
  check('one saved review retains both exact files without staging or writing',savedSet.files.length===2&&savedSet.files[0].shared_draft==='<h1>Before task</h1>\n'&&savedSet.files[1].proposed_text===null&&savedSet.files[1].source.schema==='selected-file-deletion-basis@1'&&await script(`return !document.querySelector('[data-screen=editor] .workbench-tabs').textContent.includes('●')`)&&readFileSync(testRepo+'/index.html','utf8')==='<h1>Before task</h1>\n');photo('06_Combined_Review_Saved');
  check('successful recording disables duplicate submission',await script(`return document.querySelector('#bot-file-set-record').disabled&&Object.keys(window.cockpit.frame.projection.development_attempts).length===1`));

  await click('#bot-file-set-cancel');
  async function openReview(){await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=development-tasks]');if(await script(`return !!document.querySelector('#development-task-list article button')?.getClientRects().length`))await click('#development-task-list article button');await until(()=>script(`return !!document.querySelector('[data-attempt-id="'+arguments[0]+'"]')`,[savedSet.id]));if(!await script(`return document.querySelector('[data-attempt-id="'+arguments[0]+'"]')?.open`,[savedSet.id]))await click('[data-attempt-id="'+savedSet.id+'"] > summary');}

  await openReview();
  check('saved review explicitly labels deletion',await script(`return document.querySelector('[data-attempt-id="'+arguments[0]+'"]').textContent.includes('Delete file')`,[savedSet.id]));
  await click('#attempt-run-'+savedSet.id);
  const runRecord=await until(()=>script(`return Object.values(window.cockpit.frame.projection.development_attempts[arguments[0]].test_runs??{}).find(r=>r.state==='completed')`,[savedSet.id]));
  check('native tests pass with replacement and deletion in one snapshot',runRecord.outcome.verdict==='pass'&&runRecord.outcome.result_sha256===savedSet.source.result_sha256);
  check('testing leaves original files untouched',readFileSync(testRepo+'/index.html','utf8')==='<h1>Before task</h1>\n'&&readFileSync(testRepo+'/style.css','utf8')==='h1 { color: red; }\n');
  await until(()=>script(`return !!document.querySelector('[data-accept-result="'+arguments[0]+'"]')`,[savedSet.id]));
  await click('[data-run-output="'+runRecord.run_id+'"] > summary');await script(`document.querySelector('[data-run-output="'+arguments[0]+'"]').scrollIntoView({block:'center'})`,[runRecord.run_id]);photo('Deletion snapshot tests passed');
  async function accept(){await script(`document.querySelector('[data-acceptance-note="'+arguments[0]+'"]').value=''`,[savedSet.id]);await type('[data-acceptance-note="'+savedSet.id+'"]','Reviewed replacement and deletion match the tested snapshot.');await click('[data-accept-result="'+savedSet.id+'"]');}
  await accept();await until(()=>script(`return document.querySelector('#attempt-tests-'+arguments[0]+' [role=status]').textContent.includes('selected file differs')`,[savedSet.id]));check('acceptance refuses unapplied review',!await script(`return !!window.cockpit.frame.projection.development_attempts[arguments[0]].acceptance`,[savedSet.id]));
  await click('[data-rail-mode=bots]');await click(`#rail-bots [data-nav="${route}"]`);await click('[data-review-file-set]');await click('#bot-file-set-stage');await until(()=>script(`return !document.querySelector('#bot-file-set-review')`));
  check('staged deletion is visibly marked',await script(`return document.querySelector('[data-screen=editor] .workbench-tabs').textContent.includes('DELETE')`));photo('Staged deletion');
  await click('[data-file-path="style.css"]');check('staged deletion retains original editor text and disables individual Save',await script(`return document.querySelector('#editor-save').disabled&&document.querySelector('#editor-content').textContent.includes('color: red')`));photo('Selected deletion cannot save an empty file');
  await click('#editor-set-apply');await until(()=>!existsSync(testRepo+'/style.css')&&readFileSync(testRepo+'/index.html','utf8')===proposedText);await until(()=>script(`return !document.querySelector('#editor-set-apply')`));
  check('one apply writes replacement and removes deleted file and tab',!existsSync(testRepo+'/.git/super-apply-journal-v1.json')&&await script(`return !document.querySelector('[data-screen=editor] .workbench-tabs').textContent.includes('style.css')`));photo('Deletion applied');
  // Reconstruct an interrupted deletion boundary explicitly, then reopen the
  // native application. This fixture is not a timed process-crash experiment.
  const info=statSync(testRepo),journal=testRepo+'/.git/super-apply-journal-v1.json',material={version:2,device:info.dev,inode:info.ino,modes:{'index.html':420,'style.css':420},files:[{path:'style.css',original:'h1 { color: red; }\n',content:null},{path:'index.html',original:'<h1>Before task</h1>\n',content:proposedText}]};
  writeFileSync(journal,JSON.stringify(material));writeFileSync(testRepo+'/index.html',material.files[1].original);
  const callsBefore=chatCalls;
  async function restart(){await wd('DELETE',`/session/${session}`);session=null;const reopened=await wd('POST','/session',{capabilities:{alwaysMatch:{'tauri:options':{application:root+'/cockpit/target/release/super-cockpit'}}}});session=reopened.sessionId;await until(()=>script(`return !!window.cockpit?.frame?.projection?.development_attempts?.[arguments[0]]`,[savedSet.id]));await wd('POST',`/session/${session}/window/rect`,{width:1280,height:850});await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=editor]');await click('#development-choose-editor');await sleep(800);run('/usr/bin/python3',[root+'/tools/development-confirm-folder.py',String(driver.pid),testRepo]);await until(()=>script(`return !!document.querySelector('[data-file-path="index.html"]')`));}
  await restart();await until(()=>script(`return !!document.querySelector('#editor-set-restore')&&!document.querySelector('#editor-set-restore').disabled`));
  check('native restart discovers interrupted deletion',existsSync(journal)&&chatCalls===callsBefore);photo('Interrupted deletion after reopening');
  await click('#editor-set-restore');await until(()=>script(`return !!document.querySelector('#editor-set-confirmation')?.open`));photo('Restore deletion confirmation');await click('#editor-set-cancel');check('cancel recovery preserves deletion and journal',existsSync(journal)&&!existsSync(testRepo+'/style.css'));
  writeFileSync(testRepo+'/style.css','outside content');await click('#editor-set-restore');await click('#editor-set-confirm');await until(()=>script(`return document.querySelector('#editor-status').textContent.includes('changed on disk')`));check('recreated unrelated file blocks deletion recovery',existsSync(journal)&&readFileSync(testRepo+'/style.css','utf8')==='outside content');photo('Recreated file conflict');rmSync(testRepo+'/style.css');
  await click('#editor-set-restore');await click('#editor-set-confirm');await until(()=>!existsSync(journal));check('restore brings deleted file back with original bytes',readFileSync(testRepo+'/style.css','utf8')===material.files[0].original&&readFileSync(testRepo+'/index.html','utf8')===material.files[1].original);photo('Deleted original restored');
  writeFileSync(journal,JSON.stringify(material));rmSync(testRepo+'/style.css');await reloadPage();await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=editor]');await until(()=>script(`return !!document.querySelector('#editor-set-finish')&&!document.querySelector('#editor-set-finish').disabled`));await click('#editor-set-finish');await click('#editor-set-confirm');await until(()=>!existsSync(journal));check('finish recovery preserves deletion and completes replacement',!existsSync(testRepo+'/style.css')&&readFileSync(testRepo+'/index.html','utf8')===proposedText);photo('Deletion recovery finished');
  await openReview();writeFileSync(testRepo+'/style.css','');await accept();await until(()=>script(`return document.querySelector('#attempt-tests-'+arguments[0]+' [role=status]').textContent.includes('style.css')`,[savedSet.id]));check('an empty replacement cannot satisfy deletion acceptance',!await script(`return !!window.cockpit.frame.projection.development_attempts[arguments[0]].acceptance`,[savedSet.id]));await script(`document.querySelector('#attempt-tests-'+arguments[0]+' [role=status]').scrollIntoView({block:'center'})`,[savedSet.id]);photo('Empty file acceptance refused');rmSync(testRepo+'/style.css');
  await accept();const accepted=await until(()=>script(`const a=window.cockpit.frame.projection.development_attempts[arguments[0]];return a.status==='accepted'?a:null`,[savedSet.id]));check('acceptance binds deletion to passing snapshot',accepted.acceptance.snapshot_sha256===runRecord.outcome.snapshot_sha256&&accepted.acceptance.result_sha256===savedSet.source.result_sha256);assert.deepEqual(accepted.files,savedSet.files);
  await until(()=>script(`return !!document.querySelector('[data-accepted-attempt="'+arguments[0]+'"]')`,[savedSet.id]));await script(`document.querySelector('[data-accepted-attempt="'+arguments[0]+'"]').scrollIntoView({block:'center'})`,[savedSet.id]);photo('Deletion accepted');
  await restart();await openReview();const retained=await script(`return window.cockpit.frame.projection.development_attempts[arguments[0]]`,[savedSet.id]);assert.deepEqual(retained.acceptance,accepted.acceptance);assert.deepEqual(retained.files,savedSet.files);check('accepted deletion survives native restart without another provider call',chatCalls===callsBefore);
  await click('[data-verify-accepted="'+savedSet.id+'"]');await until(()=>script(`return document.querySelector('[data-accepted-file-check="'+arguments[0]+'"] [role=status]').textContent.includes('Matched at')`,[savedSet.id]));check('reopened accepted deletion matches current checkout',!existsSync(testRepo+'/style.css'));await script(`document.querySelector('[data-accepted-file-check="'+arguments[0]+'"]').scrollIntoView({block:'center'})`,[savedSet.id]);photo('Accepted deletion rechecked after restart');
  evidence.complete();console.log(`deletion review smoke: ${checks} held`);
} catch(e){console.error(log);if(session)try{evidence.capture('Failure diagnostic');console.error(await script(`return document.body.innerText.slice(-6500)`));}catch{}throw e;} finally {evidence.close();botFixture.close();if(session)try{await wd('DELETE',`/session/${session}`);}catch{}try{process.kill(-driver.pid,'SIGTERM');}catch{}}
