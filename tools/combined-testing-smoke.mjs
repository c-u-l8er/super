
// End-to-end plan/file fixture flow. Run via tools/native-ui-test.sh.
/* Product flow in an isolated world; explicitly removes the disposable local test cache to verify runtime-only recovery. No runtime resets. */
import { spawn, execFileSync as run } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdirSync, writeFileSync, readFileSync, readdirSync, mkdtempSync, rmSync } from 'node:fs';
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
mkdirSync(testRepo+'/tools');writeFileSync(testRepo+'/tools/proposal-test.mjs',"import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';test('combined page and style',async()=>{await new Promise(r=>setTimeout(r,1200));assert.equal(fs.readFileSync('index.html','utf8'),'<h1>After task</h1>\\n');assert.equal(fs.readFileSync('style.css','utf8'),'h1 { color: blue; }\\n');});");
mkdirSync(testRepo+'/cockpit/src',{recursive:true});mkdirSync(testRepo+'/ampd');
writeFileSync(testRepo+'/cockpit/Cargo.toml','[package]\nname="super-cockpit"\nversion="0.1.0"\nedition="2021"\n');
writeFileSync(testRepo+'/cockpit/Cargo.lock','version = 4\n[[package]]\nname = "super-cockpit"\nversion = "0.1.0"\n');
writeFileSync(testRepo+'/cockpit/src/main.rs','fn main(){if std::env::var("SUPER_BUILD_PREVIEW").as_deref()==Ok("1"){if std::path::Path::new("'+testRepo+'/preview-fail-trigger").exists(){eprintln!("Preview fixture could not open its runtime");std::process::exit(23);}let data=std::env::var("XDG_DATA_HOME").unwrap();std::fs::create_dir_all(&data).unwrap();assert_eq!(std::env::var("SUPER_WORLD_MODE").unwrap(),"ephemeral");assert!(std::env::var("SUPER_WORLD").is_err());std::fs::write(format!("{}/preview-proof",data),std::env::var("AMPD_DIR").unwrap()).unwrap();eprintln!("[super-preview-frame-painted@1]");loop{std::thread::sleep(std::time::Duration::from_secs(1));}}print!("{}{}",include_str!("../../index.html"),include_str!("../../style.css"));}');
writeFileSync(testRepo+'/cockpit/build.rs','fn main(){assert!(std::env::var("SUPER_BUILD_SECRET").is_err());assert!(std::fs::write("/snapshot/forbidden","x").is_err());assert!(!std::path::Path::new("'+testRepo+'").exists());std::thread::sleep(std::time::Duration::from_secs(2));}');
writeFileSync(testRepo+'/ampd/mix.exs','defmodule BuildFixture.MixProject do\n use Mix.Project\n def project, do: [app: :build_fixture, version: "0.1.0"]\nend\n');
run('git',['-C',testRepo,'add','index.html']);run('git',['-C',testRepo,'-c','user.name=Super fixture','-c','user.email=fixture@example.invalid','commit','-qm','Starting file']);
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
    if(lastBotRequest.messages.at(-1).content.includes('Make the planned edit')){res.end(JSON.stringify({message:{role:'assistant',content:'Review the planned change.',tool_calls:[{function:{name:'propose_file_edit',arguments:{path:'index.html',content:proposedText}}},{function:{name:'propose_file_edit',arguments:{path:'style.css',content:'h1 { color: blue; }\n'}}}]},done:true}));return;}
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
const evidence={capture(){},record(){},close(){}};
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
  await type('#task-title','Highlight changed ranges');await type('#task-criteria','Changed lines are visible and Cancel preserves the draft.');
  await click('#task-required-checks input');await click('#development-task-form button');
  check('new plans cannot omit all required checks',await script(`return document.querySelector('#development-task-form').parentElement.textContent.includes('Choose at least one required check.')&&Object.keys(window.cockpit.frame.projection.development_tasks??{}).length===0`));
  await click('#task-required-checks input');
  if(shots){mkdirSync(shots,{recursive:true});execFileSync('/usr/bin/python3',[`${root}/tools/development-capture-window.py`,String(driver.pid),resolve(shots,'00_Required_Check_Selection.png')]);}
  await click('#development-task-form button');
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

  while(await script(`return !!document.querySelector('#bot-attachment-list button')`))await click('#bot-attachment-list button');
  const photo=name=>{if(shots){mkdirSync(shots,{recursive:true});run('/usr/bin/python3',[`${root}/tools/development-capture-window.py`,String(driver.pid),resolve(shots,name+'.png')]);}};
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
  check('file switch displays the second complete replacement',await script(`return document.querySelector('#bot-file-set-review .file-proposal-columns').textContent.includes('blue')&&document.querySelector('#bot-file-set-review .file-proposal-columns').textContent.includes('red')`));
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
  check('one saved review retains both exact files without staging or writing',savedSet.files.length===2&&savedSet.files[0].shared_draft==='<h1>Before task</h1>\n'&&savedSet.files[1].proposed_text==='h1 { color: blue; }\n'&&await script(`return !document.querySelector('[data-screen=editor] .workbench-tabs').textContent.includes('●')`)&&readFileSync(testRepo+'/index.html','utf8')==='<h1>Before task</h1>\n');photo('06_Combined_Review_Saved');
  check('successful recording disables duplicate submission',await script(`return document.querySelector('#bot-file-set-record').disabled&&Object.keys(window.cockpit.frame.projection.development_attempts).length===1`));

  await click('#bot-file-set-cancel');
  async function openReview(){await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=development-tasks]');if(await script(`return !!document.querySelector('#development-task-list article button')?.getClientRects().length`))await click('#development-task-list article button');await until(()=>script(`return !!document.querySelector('[data-attempt-id="'+arguments[0]+'"]')`,[savedSet.id]));if(!await script(`return document.querySelector('[data-attempt-id="'+arguments[0]+'"]')?.open`,[savedSet.id]))await click('[data-attempt-id="'+savedSet.id+'"] > summary');}
  await openReview();
  await until(()=>script(`return document.querySelector('[data-profile-coverage="'+arguments[0]+'"]').textContent.includes('Required — not run yet')`,[savedSet.id]));
  check('required JavaScript policy is retained and missing checks hide acceptance',await script(`return window.cockpit.frame.projection.development_tasks[arguments[0]].required_checks.profiles[0]==='super-javascript-behavior@1'&&!document.querySelector('[data-accept-result="'+arguments[1]+'"]')`,[savedSet.task_ref,savedSet.id]));
  await script(`document.querySelector('[data-profile-coverage="'+arguments[0]+'"]').scrollIntoView({block:'center'})`,[savedSet.id]);photo('07_Required_Check_Missing');
  const originalTest=readFileSync(testRepo+'/tools/proposal-test.mjs','utf8');writeFileSync(testRepo+'/tools/proposal-test.mjs',originalTest.replace('color: blue','color: wrong'));
  await click('#attempt-run-'+savedSet.id);
  const failed=await until(()=>script(`return Object.values(window.cockpit.frame.projection.development_attempts[arguments[0]].test_runs??{}).find(r=>r.state==='completed')`,[savedSet.id]));
  check('failing required check prevents acceptance',failed.outcome.verdict==='fail'&&await script(`return !document.querySelector('[data-accept-result="'+arguments[0]+'"]')`,[savedSet.id]));
  await until(()=>script(`return document.querySelector('[data-profile-coverage="'+arguments[0]+'"]').textContent.includes('Tests failed')`,[savedSet.id]));
  await script(`document.querySelector('[data-profile-coverage="'+arguments[0]+'"]').scrollIntoView({block:'center'})`,[savedSet.id]);photo('08_Required_Check_Failed');
  writeFileSync(testRepo+'/tools/proposal-test.mjs',originalTest);
  await until(()=>script(`return !document.querySelector('#attempt-run-'+arguments[0]).disabled`,[savedSet.id]));await click('#attempt-run-'+savedSet.id);
  const runRecord=await until(()=>script(`return Object.values(window.cockpit.frame.projection.development_attempts[arguments[0]].test_runs??{}).find(r=>r.state==='completed'&&r.outcome.verdict==='pass')`,[savedSet.id]));
  check('native tests pass against both replacements in one bound snapshot',runRecord.outcome.verdict==='pass'&&runRecord.outcome.result_sha256===savedSet.source.result_sha256&&runRecord.outcome.source_basis_id===savedSet.source.basis_id);
  check('testing the combined set leaves both repository files unchanged',readFileSync(testRepo+'/index.html','utf8')==='<h1>Before task</h1>\n'&&readFileSync(testRepo+'/style.css','utf8')==='h1 { color: red; }\n');
  await until(()=>script(`return !!document.querySelector('[data-accept-result="'+arguments[0]+'"]')`,[savedSet.id]));
  await click('[data-run-output="'+runRecord.run_id+'"] > summary');
  await script(`document.querySelector('[data-run-output="'+arguments[0]+'"]').scrollIntoView({block:'center'})`,[runRecord.run_id]);photo('09_Combined_Tests_Passed');
  async function accept(){await script(`document.querySelector('[data-acceptance-note="'+arguments[0]+'"]').value=''`,[savedSet.id]);await type('[data-acceptance-note="'+savedSet.id+'"]','Both reviewed files match the passing combined snapshot.');await click('[data-accept-result="'+savedSet.id+'"]');}
  await accept();await until(()=>script(`return document.querySelector('#attempt-tests-'+arguments[0]+' [role=status]').textContent.includes('selected file differs')`,[savedSet.id]));
  check('acceptance refuses before the first replacement is saved',await script(`return !window.cockpit.frame.projection.development_attempts[arguments[0]].acceptance`,[savedSet.id]));
  await click('[data-rail-mode=bots]');await click(`#rail-bots [data-nav="${route}"]`);await click('[data-review-file-set]');await click('#bot-file-set-stage');await until(()=>script(`return !document.querySelector('#bot-file-set-review')`));
  await click('#editor-save');await until(()=>script(`return document.querySelector('#editor-save').disabled`));
  await openReview();await accept();await until(()=>script(`return document.querySelector('#attempt-tests-'+arguments[0]+' [role=status]').textContent.includes('style.css')`,[savedSet.id]));
  check('saving only the first file cannot accept the combined set',readFileSync(testRepo+'/index.html','utf8')===proposedText&&readFileSync(testRepo+'/style.css','utf8')==='h1 { color: red; }\n'&&await script(`return !window.cockpit.frame.projection.development_attempts[arguments[0]].acceptance`,[savedSet.id]));
  await script(`document.querySelector('#attempt-tests-'+arguments[0]+' [role=status]').scrollIntoView({block:'center'})`,[savedSet.id]);photo('10_Partial_Save_Refused');
  await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=editor]');await click('[data-file-path="style.css"]');await click('#editor-save');await until(()=>script(`return document.querySelector('#editor-save').disabled`));
  writeFileSync(testRepo+'/unrelated.txt','Later unrelated edit');await openReview();await accept();await until(()=>script(`return document.querySelector('#attempt-tests-'+arguments[0]+' [role=status]').textContent.includes('repository files differ')`,[savedSet.id]));
  check('other repository changes also refuse acceptance',await script(`return !window.cockpit.frame.projection.development_attempts[arguments[0]].acceptance`,[savedSet.id]));rmSync(testRepo+'/unrelated.txt');
  // The reason remains after refusal; the existing control checks it again.
  await click('[data-accept-result="'+savedSet.id+'"]');
  const accepted=await until(()=>script(`const a=window.cockpit.frame.projection.development_attempts[arguments[0]];return a.status==='accepted'?a:null`,[savedSet.id]));
  check('human acceptance binds all reviewed files and the passing snapshot',accepted.acceptance.result_sha256===savedSet.source.result_sha256&&accepted.acceptance.snapshot_sha256===runRecord.outcome.snapshot_sha256&&accepted.acceptance.run_id===runRecord.run_id);assert.deepEqual(accepted.files,savedSet.files);
  await until(()=>script(`return !!document.querySelector('[data-accepted-attempt="'+arguments[0]+'"]')`,[savedSet.id]));await script(`document.querySelector('[data-accepted-attempt="'+arguments[0]+'"]').scrollIntoView({block:'center'})`,[savedSet.id]);photo('11_Accepted_Combined_Result');
  async function verifySaved(expected){await click('[data-verify-accepted="'+savedSet.id+'"]');return until(()=>script(`const p=document.querySelector('[data-accepted-file-check="'+arguments[0]+'"] [role=status]');return p.textContent.includes(arguments[1])?p.textContent:null`,[savedSet.id,expected]));}
  await verifySaved('Matched at');check('accepted source check confirms the complete saved snapshot',true);photo('13_Accepted_Files_Match');
  writeFileSync(testRepo+'/style.css','h1 { color: green; }\n');await verifySaved('selected file differs');check('later edit refuses the accepted file check',readFileSync(testRepo+'/style.css','utf8').includes('green'));photo('14_Accepted_File_Drift');
  writeFileSync(testRepo+'/style.css','h1 { color: blue; }\n');writeFileSync(testRepo+'/unrelated.txt','Later change');await verifySaved('repository files differ');check('accepted source check covers unrelated captured files',true);rmSync(testRepo+'/unrelated.txt');
  await verifySaved('Matched at');assert.deepEqual(await script(`return window.cockpit.frame.projection.development_attempts[arguments[0]]`,[savedSet.id]),accepted);check('rechecking does not change acceptance, review history or test runs',true);
  await click('[data-build-accepted="'+savedSet.id+'"]');
  const buildId=await until(()=>script(`return document.querySelector('[data-accepted-builds="'+arguments[0]+'"] [data-cancel-build]')?.dataset.cancelBuild`,[savedSet.id]));
  check('build progress appears for accepted source',true);photo('16_Build_Running');
  await click('[data-cancel-build="'+buildId+'"]');await until(()=>script(`return document.querySelector('[data-build-id="'+arguments[0]+'"]').textContent.includes('Build cancelled')`,[buildId]),120000);check('cancelled build has no ready artifact',true);photo('17_Build_Cancelled');
  await until(()=>script(`return !document.querySelector('[data-build-accepted="'+arguments[0]+'"]').disabled`,[savedSet.id]));await click('[data-build-accepted="'+savedSet.id+'"]');
  await until(()=>script(`return document.querySelector('[data-accepted-builds="'+arguments[0]+'"]').textContent.includes('Development build ready')`,[savedSet.id]),120000);
  const readyText=await script(`return document.querySelector('[data-accepted-builds="'+arguments[0]+'"]').textContent`,[savedSet.id]);
  const launcher=readyText.match(/\/[^\n]*\/artifact\/launch-super\.sh/)?.[0];assert.ok(launcher);const binary=launcher.replace('launch-super.sh','super-cockpit');
  check('native build compiles both accepted replacements into an executable',run(binary,[],{encoding:'utf8'})===proposedText+'h1 { color: blue; }\n');
  await script(`document.querySelector('[data-accepted-builds="'+arguments[0]+'"]').scrollIntoView({block:'end'})`,[savedSet.id]);photo('18_Build_Ready');
  const readyId=await script(`return document.querySelector('[data-try-build]').dataset.tryBuild`);
  await click('[data-try-build="'+readyId+'"]');await until(()=>script(`return !!document.querySelector('[data-close-preview]')`));
  const previewRoot=testData+'/com.computedriven.super.cockpit/build-previews';
  const trial=await until(()=>{try{return readdirSync(previewRoot).find(n=>n.startsWith('trial-'));}catch{return false;}});
  const proof=await until(()=>{try{return readFileSync(previewRoot+'/'+trial+'/data/preview-proof','utf8');}catch{return false;}});
  check('preview runs a verified private source copy in a temporary world',proof===previewRoot+'/'+trial+'/source/ampd');
  await until(()=>script(`return document.querySelector('[data-accepted-builds]').textContent.includes('first runtime frame')`));check('preview readiness requires the child frame signal',true);
  photo('21_Preview_Running');
  await click('[data-close-preview="'+readyId+'"]');await until(()=>script(`return document.querySelector('[data-accepted-builds]').textContent.includes('Preview closed')`));
  check('closing preview removes its temporary session',!readdirSync(previewRoot).includes(trial));photo('22_Preview_Closed');
  writeFileSync(testRepo+'/preview-fail-trigger','fail');await click('[data-try-build="'+readyId+'"]');
  await until(()=>script(`return document.querySelector('[data-accepted-builds]').textContent.includes('Preview exited with code 23')`));
  await until(()=>script(`return document.querySelector('[data-accepted-builds]').textContent.includes('Preview fixture could not open its runtime')`));
  check('early preview failure shows exit reason and diagnostic output',!await script(`return !!document.querySelector('[data-close-preview]')`));
  await script(`const d=[...document.querySelectorAll('[data-accepted-builds] details')].find(d=>d.textContent.includes('Preview diagnostic output'));d.open=true;d.scrollIntoView({block:'center'});`);photo('24_Preview_Failure');rmSync(testRepo+'/preview-fail-trigger');
  await click('[data-try-build="'+readyId+'"]');await until(()=>script(`return !!document.querySelector('[data-close-preview]')`));check('failed preview can be tried again',true);await click('[data-close-preview]');await until(()=>script(`return !!document.querySelector('[data-try-build]')`));
  const capturedRuntime=dirname(dirname(binary))+'/snapshot/ampd/mix.exs',runtimeBefore=readFileSync(capturedRuntime,'utf8');writeFileSync(capturedRuntime,runtimeBefore+'# changed');
  await click('[data-try-build="'+readyId+'"]');await until(()=>script(`return document.querySelector('[data-accepted-builds]').textContent.includes('Captured source changed')`));
  check('changed captured runtime refuses preview before launch',!await script(`return !!document.querySelector('[data-close-preview]')`));photo('23_Changed_Runtime_Refused');writeFileSync(capturedRuntime,runtimeBefore);
  assert.deepEqual(await script(`return window.cockpit.frame.projection.development_attempts[arguments[0]]`,[savedSet.id]),accepted);check('building preserves accepted runtime history and repository bytes',readFileSync(testRepo+'/style.css','utf8')==='h1 { color: blue; }\n');
  await click('[data-build-accepted="'+savedSet.id+'"]');
  const crashBuild=await until(()=>script(`return document.querySelector('[data-accepted-builds="'+arguments[0]+'"] [data-cancel-build]')?.dataset.cancelBuild`,[savedSet.id]));
  function childrenOfDriver(){const all=readdirSync('/proc').filter(p=>/^\d+$/.test(p));const desc=new Set([String(driver.pid)]);for(let n=0;n<8;n++)for(const pid of all)try{const stat=readFileSync('/proc/'+pid+'/stat','utf8').split(')').at(-1).trim().split(/\s+/);if(desc.has(stat[1]))desc.add(pid);}catch{}return [...desc].map(pid=>{try{return {pid:Number(pid),args:readFileSync('/proc/'+pid+'/cmdline','utf8').split('\0')};}catch{return {pid:Number(pid),args:[]};}});}
  const processes=await until(()=>{const rows=childrenOfDriver(),app=rows.find(p=>p.args[0]===root+'/cockpit/target/release/super-cockpit'),launcher=rows.find(p=>p.args.some(a=>a.includes('/'+crashBuild+'/runner.mjs')));return app&&launcher?{app,launcher}:null;});
  const beforeWorld=await script('return window.cockpit.frame.world'),callsBefore=chatCalls;
  process.kill(processes.app.pid,'SIGKILL');
  await until(()=>{try{return readFileSync('/proc/'+processes.launcher.pid+'/stat','utf8').split(')').at(-1).trim().startsWith('Z');}catch{return true;}});check('app-only crash stops its build launcher',true);
  process.kill(-driver.pid,'SIGKILL');session=null;await sleep(1500);
  driver=spawn('tauri-driver',['--port',String(port),'--native-port',String(port+1),'--native-driver','/usr/bin/WebKitWebDriver'],{cwd:testRepo,detached:true,stdio:['ignore','pipe','pipe'],env:{...process.env,XDG_DATA_HOME:testData,XDG_STATE_HOME:testData+'/state',AMPD_DIR:root+'/ampd',SUPER_WORLD_MODE:'saved',SUPER_WORLD:'durable-set-fixture',SUPER_COCKPIT_FIXTURE:'0',SUPER_COCKPIT_CARRIER:'0',SUPER_COCKPIT_PANE:'0',WEBKIT_DISABLE_COMPOSITING_MODE:'1'}});
  driver.stdout.on('data',b=>{log=(log+b).slice(-8000)});driver.stderr.on('data',b=>{log=(log+b).slice(-8000)});
  await until(async()=>{try{return (await fetch(base+'/status')).ok;}catch{return false;}});
  const reopened=await wd('POST','/session',{capabilities:{alwaysMatch:{'tauri:options':{application:root+'/cockpit/target/release/super-cockpit'}}}});session=reopened.sessionId;
  await until(()=>script(`return !!window.cockpit?.frame?.projection?.development_attempts?.[arguments[0]]`,[savedSet.id]));
  await wd('POST',`/session/${session}/window/rect`,{width:1280,height:850});
  const restored=await script(`return window.cockpit.frame.projection.development_attempts[arguments[0]]`,[savedSet.id]);assert.deepEqual(restored.acceptance,accepted.acceptance);assert.deepEqual(restored.files,savedSet.files);
  check('actual restart preserves the accepted combined result without another provider call',chatCalls===callsBefore&&await script(`return window.cockpit.frame.world.projection_epoch!==arguments[0].projection_epoch`,[beforeWorld]));
  await openReview();await script(`document.querySelector('[data-accepted-attempt="'+arguments[0]+'"]').scrollIntoView({block:'center'})`,[savedSet.id]);photo('12_After_Restart');
  check('required checks survive restart',await script(`return window.cockpit.frame.projection.development_tasks[arguments[0]].required_checks.profiles[0]==='super-javascript-behavior@1'`,[savedSet.task_ref]));
  check('restart does not present an old file check as a current match',await script(`return !document.querySelector('[data-accepted-file-check="'+arguments[0]+'"] [role=status]').textContent.includes('Matched at')`,[savedSet.id]));
  await click('[data-accepted-file-check="'+savedSet.id+'"] button:nth-of-type(2)');await until(()=>script(`return !document.querySelector('[data-screen=editor]').hidden`));
  await click('#development-choose-editor');await sleep(700);execFileSync('/usr/bin/python3',[`${root}/tools/development-confirm-folder.py`,String(driver.pid)]);await until(()=>script(`return !!document.querySelector('[data-file-path="index.html"]')`));
  await openReview();await verifySaved('Matched at');check('accepted files can be checked again after native restart and repository selection',true);photo('15_Rechecked_After_Restart');
  await until(()=>script(`return document.querySelector('[data-accepted-builds="'+arguments[0]+'"]').textContent.includes('Development build ready')`,[savedSet.id]));
  await until(()=>script(`return document.querySelector('[data-build-id="'+arguments[0]+'"]').textContent.includes('Build interrupted')`,[crashBuild]));check('unfinished build is shown as interrupted after restart',true);
  check('completed device-local build history survives restart',true);await script(`document.querySelector('[data-accepted-builds="'+arguments[0]+'"]').scrollIntoView({block:'end'})`,[savedSet.id]);photo('19_Build_After_Restart');
  writeFileSync(binary,Buffer.concat([readFileSync(binary),Buffer.from('changed')]));
  await until(()=>script(`return document.querySelector('[data-accepted-builds="'+arguments[0]+'"]').textContent.includes('artifact unavailable')`,[savedSet.id]));check('changed executable is no longer presented as a ready build',await script(`return !document.querySelector('[data-accepted-builds="'+arguments[0]+'"]').textContent.includes('Launcher')`,[savedSet.id]));photo('20_Changed_Artifact_Unavailable');
  console.log(`combined testing smoke: ${checks} held`);
} catch(e){console.error(log);if(session)try{console.error(await script(`return document.body.innerText.slice(-6500)`));}catch{}throw e;} finally {botFixture.close();if(session)try{await wd('DELETE',`/session/${session}`);}catch{}try{process.kill(-driver.pid,'SIGTERM');}catch{}}
