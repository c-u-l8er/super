// Super, on Super, in isolation — ending in the actual application.
//
// A disposable world and a fresh clone of this tree. The provider fixture
// proposes a two-file change to Super itself (a plan-page wording and the test
// that asserts it); the person records it as a combined review, the cockpit is
// killed and restarted, the SAVED review is staged again from its recorded
// bytes (no provider call), the JavaScript profile runs Super's own suites in
// the runner's sandbox, the staged set is applied, the result accepted, and
// `Build accepted app` compiles the accepted snapshot with the real
// `super-cockpit-release@1` profile: cargo, offline, in the runner's sandbox.
// That artifact is then launched as a cockpit of its own, in another
// disposable world, and asked for a frame.
//
// What this is NOT: the smokes' fixture crate, which prints its two files.
// Nothing here touches the production world, a paired phone, held proposals or
// the shared checkout. Run via tools/native-ui-test.sh with
// DEVELOPMENT_TEST_ROOT set; SUPER_SELF_SOURCE names the tree to clone
// (default: this one, at its committed HEAD — uncommitted edits are not part
// of the cycle).
import { spawn, execFileSync as run, execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdirSync, writeFileSync, readFileSync, mkdtempSync, rmSync, existsSync, statSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const port = Number(process.env.APP_SMOKE_PORT ?? 4464);
const base = `http://127.0.0.1:${port}`;
const shots = process.env.APP_SMOKE_SCREENSHOTS;
const sha=b=>createHash('sha256').update(b).digest('hex');
const testRoot=process.env.DEVELOPMENT_TEST_ROOT;if(!testRoot)throw Error('Set DEVELOPMENT_TEST_ROOT to a disposable folder visible to the native chooser.');
const testData=mkdtempSync(testRoot+'/super-self-build-');
const source=process.env.SUPER_SELF_SOURCE??root;
// A clone, not a copy: the cycle runs against committed source, and the
// accepted-build capture lists Git files — a copy of a working tree would
// carry target/ and every other ignored thing the runner must never see.
const testRepo=mkdtempSync(testRoot+'/super-self-');run('git',['clone','-q','--no-hardlinks',source,testRepo]);
const sourceHead=run('git',['-C',testRepo,'rev-parse','HEAD'],{encoding:'utf8'}).trim();
if(existsSync(testRepo+'/cockpit/target')||existsSync(testRepo+'/host/target'))throw Error('the clone must carry no build output');
const PROGRESS='cockpit/ui/task-progress.js',PROGRESS_TEST='tools/task-progress-test.mjs';
const currentProgress=readFileSync(testRepo+'/'+PROGRESS,'utf8'),currentTest=readFileSync(testRepo+'/'+PROGRESS_TEST,'utf8');
const oldReason='Used test profiles agree. Save the exact proposal in Editor, then use the review’s file check and acceptance control.';
const newReason='Used test profiles agree. Stage the saved review in Editor and apply the staged change set (or save the exact proposal), then use the review’s file check and acceptance control.';
if(!currentProgress.includes(oldReason))throw Error('the clone already carries the proposed wording; this cycle proposes it');
const proposedProgress=currentProgress.replace(oldReason,newReason);
const proposedTest=currentTest.trimEnd()+"\n\ntest('a decision points at staging the saved review, which needs no provider call',()=>{const p=projection([{...attempt,test_runs:{r:run}}]);const result=taskProgress(p,task);assert.equal(result.state,'decision');assert.match(result.reason,/Stage the saved review in Editor and apply the staged change set/);});\n";
let driver = spawn('tauri-driver', ['--port', String(port), '--native-port', String(port + 1), '--native-driver', '/usr/bin/WebKitWebDriver'], {
  cwd:testRepo, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
  env: { ...process.env, XDG_DATA_HOME:testData, AMPD_DIR: `${root}/ampd`, XDG_STATE_HOME:testData+'/state', SUPER_WORLD_MODE: 'saved', SUPER_WORLD:'self-build-fixture', SUPER_COCKPIT_FIXTURE: '0', SUPER_COCKPIT_CARRIER: '0', SUPER_COCKPIT_PANE: '0', WEBKIT_DISABLE_COMPOSITING_MODE: '1' },
});
let lastBotRequest, chatCalls = 0;
const botFixture = createServer((req, res) => {
  if(req.url==='/api/tags'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({models:[{name:'fixture-model'}]}));return;}
  let data = ''; req.on('data', chunk => { data += chunk; });
  req.on('end', () => {
    lastBotRequest = JSON.parse(data); chatCalls++;
    res.writeHead(200, {'content-type':'application/json'});
    if(lastBotRequest.messages.at(-1).content.includes('Make the planned edit')){res.end(JSON.stringify({message:{role:'assistant',content:'The next-action text now names the saved-review path, and a test pins it.',tool_calls:[{function:{name:'propose_file_edit',arguments:{path:PROGRESS,content:proposedProgress}}},{function:{name:'propose_file_edit',arguments:{path:PROGRESS_TEST,content:proposedTest}}}]},done:true}));return;}
    res.end(JSON.stringify({message:{role:'assistant',content:'Nothing to propose yet.'},done:true}));
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
async function element(selector) { const e = await wd('POST', `/session/${session}/element`, { using: 'css selector', value: selector }); return e['element-6066-11e4-a52e-4f735466cecf']; }
async function click(selector) {
  for (let attempt = 0; attempt < 3; attempt++) {
    await script('document.querySelector(arguments[0]).scrollIntoView({block: "center", inline: "nearest"})', [selector]);
    try { return await wd('POST', `/session/${session}/element/${await element(selector)}/click`, {}); }
    catch (e) { if (!String(e).includes('stale element reference') || attempt === 2) throw e; }
  }
}
async function type(selector, text) { return wd('POST', `/session/${session}/element/${await element(selector)}/value`, { text }); }
function check(label, value) { assert.ok(value, label); checks++; console.log(`held ${label}`); }
const photo=name=>{if(shots){mkdirSync(shots,{recursive:true});try{run('/usr/bin/python3',[`${root}/tools/development-capture-window.py`,String(driver.pid),resolve(shots,name+'.png')]);}catch(e){console.log('note: no photo '+name+': '+e.message);}}};
const chooser=(...extra)=>execFileSync('/usr/bin/python3',[`${root}/tools/development-confirm-folder.py`,String(driver.pid),...extra],{env:{...process.env,...(extra.length?{}:{})}});
const env=(overrides={})=>({...process.env,XDG_DATA_HOME:testData,XDG_STATE_HOME:testData+'/state',AMPD_DIR:root+'/ampd',SUPER_WORLD_MODE:'saved',SUPER_WORLD:'self-build-fixture',SUPER_COCKPIT_FIXTURE:'0',SUPER_COCKPIT_CARRIER:'0',SUPER_COCKPIT_PANE:'0',WEBKIT_DISABLE_COMPOSITING_MODE:'1',...overrides});
async function openSession(application){await until(async()=>{try{return (await fetch(base+'/status')).ok;}catch{return false;}});const created=await wd('POST','/session',{capabilities:{alwaysMatch:{'tauri:options':{application}}}});session=created.sessionId;await until(()=>script('return !!window.cockpit?.frame?.projection'));await wd('POST',`/session/${session}/window/rect`,{width:1280,height:850});}
async function openTreePath(path){const parts=path.split('/');for(let i=0;i<parts.length;i++){const sub=parts.slice(0,i+1).join('/');while(!await script(`return !!document.querySelector('[data-file-path="'+arguments[0]+'"]')`,[sub])){await click('#editor-up');await sleep(200);}await click('[data-file-path="'+sub+'"]');}}
let savedSet,task,route;
try {
  await openSession(`${root}/cockpit/target/release/super-cockpit`);
  // ------------------------------------------------ world setup, through the page
  await click('#app-navigation [data-nav=positions]');await click('[data-screen=positions] [data-nav=new-workspace]');await type('[data-draft=workspace_name]','Super self-build');await click('[data-id=open-workspace] button');
  const ws=await until(()=>script(`return Object.values(window.cockpit.frame.projection.workspaces).find(w=>w.name==='Super self-build')`));
  await click('#app-navigation [data-nav=goals]');await click('[data-screen=goals] [data-setup-form=open-goal]');
  await script(`const e=document.querySelector('[data-draft=goal_ws]');e.value=arguments[0];e.dispatchEvent(new Event('change',{bubbles:true}))`,[ws.id]);
  await type('[data-draft=goal_title]','Build Super from an accepted review');await click('[data-id=open-goal] button');await until(()=>script(`return Object.values(window.cockpit.frame.projection.goals).some(g=>g.workspace_ref===arguments[0])`,[ws.id]));
  await click('#app-navigation [data-nav=repositories]');await click('[data-host-action=choose-repository]');await sleep(800);
  execFileSync('/usr/bin/python3',[`${root}/tools/development-confirm-folder.py`,String(driver.pid)],{env:{...process.env,SUPER_CHOOSER_TITLE:'Register a local Git repository'}});await sleep(800);if(!await script('return Object.keys(window.cockpit.frame.projection.repositories??{}).length'))execFileSync('/usr/bin/python3',[`${root}/tools/development-confirm-folder.py`,String(driver.pid)],{env:{...process.env,SUPER_CHOOSER_TITLE:'Register a local Git repository'}});
  if(await script(`return !!document.querySelector('#retry-stream')`)){await click('#retry-stream');console.log('note: explicitly reconnected after native folder selection');}
  await until(()=>script('return Object.keys(window.cockpit.frame.projection.repositories??{}).length>0'));
  // The projection publishes a repository's ref only (its name is a held
  // proposal, not shipped), so the clone's identity is proven later: the
  // Editor's `match_plan` binds the chosen folder to the plan's repository.
  check('exactly one repository is registered — the folder the native chooser confirmed, which is the clone the driver runs in',await script('return Object.keys(window.cockpit.frame.projection.repositories).length===1'));
  await click('[data-rail-mode=bots]');await click('#rail-bots [data-nav=new-bot]');
  await type('#new-bot-name','Super Builder');await type('#new-bot-role','Implementation');await type('#new-bot-instructions','Build Super with reviewable changes.');await script(`document.querySelector('#new-bot-provider').value='ollama'`);await click('#create-bot-submit');
  await until(()=>script(`return document.querySelector('#bot-surface h1').textContent==='Super Builder' && !document.querySelector('#bot-provider').disabled`));
  route=await script(`return document.querySelector('#bot-surface').dataset.screen`);
  await script(`const p=document.querySelector('#bot-register-workspace');p.value=arguments[0];p.dispatchEvent(new Event('change'))`,[ws.id]);await click('#bot-register-runtime');
  const bot=await until(()=>script(`return Object.values(window.cockpit.frame.projection.bots??{}).find(b=>b.name==='Super Builder')`));
  await until(()=>script(`return document.querySelector('#bot-status').textContent.includes('Bot identity registered')`));
  await click('#bot-tab-work');await click('#bot-work [data-record-form=lane_actor]');
  await script(`const p=window.cockpit.frame.projection,g=Object.values(p.goals).find(g=>g.workspace_ref===arguments[0]),repo=Object.values(p.repositories)[0];for(const [key,value] of [['lane_goal',g.id],['lane_repo',repo.ref??repo.id]]){const e=document.querySelector('[data-draft='+key+']');e.value=value;e.dispatchEvent(new Event('change',{bubbles:true}));}`,[bot.workspace_ref]);
  await click('[data-id=open-lane] button');
  const lane=await until(()=>script(`return Object.values(window.cockpit.frame.projection.lanes).find(l=>l.actor===arguments[0])`,[bot.actor]));
  await click('[data-rail-mode=bots]');await click(`#rail-bots [data-nav="${route}"]`);await click('#bot-tab-work');
  await click('#bot-work [data-record-form=worker_lane]');await type('[data-draft=worker_purpose]','Implement and review Super changes');await click('[data-id=open-worker] button');
  await until(()=>script(`return Object.values(window.cockpit.frame.projection.workers).some(w=>w.locus_ref===arguments[0])`,[lane.id]));
  await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=development-tasks]');
  await type('#task-title','Point the next action at the saved review');await type('#task-criteria','The decision-state next action names staging the saved review, and a test asserts it.');
  await click('#development-task-form button');
  task=await until(()=>script(`return Object.values(window.cockpit.frame.projection.development_tasks??{}).find(t=>t.title==='Point the next action at the saved review')`));
  await until(()=>script(`return document.querySelector('#development-task-detail').textContent.includes('Plan history')`));
  check('the plan is bound to the clone’s lane and requires the JavaScript profile',task.lane_ref===lane.id&&task.required_checks.profiles[0]==='super-javascript-behavior@1');
  // ------------------------------------------------ share both Super files, get the proposal
  await click('#task-prepare-file');await until(()=>script(`return !document.querySelector('[data-screen=editor]').hidden`));
  await click('#development-choose-editor');await sleep(700);chooser();await sleep(800);if(!await script(`return !!document.querySelector('[data-file-path="cockpit"]')`))chooser();
  await until(()=>script(`return !!document.querySelector('[data-file-path="cockpit"]')`));
  await openTreePath(PROGRESS);await until(()=>script(`return document.querySelector('#editor-status').textContent.startsWith(arguments[0])`,[PROGRESS]));
  await until(()=>script(`return !document.querySelector('#editor-discuss').disabled`));await click('#editor-discuss');
  await until(()=>script(`return document.querySelector('#bot-attachment-list').textContent.includes('task-progress.js')`));
  await until(()=>script(`return !document.querySelector('#bot-provider').disabled`));
  await script(`const p=document.querySelector('#bot-provider');p.value='ollama';p.dispatchEvent(new Event('change'));const e=document.querySelector('#bot-endpoint');e.value=arguments[0];e.dispatchEvent(new Event('input',{bubbles:true}));`,[botEndpoint]);await click('#bot-connect');await until(()=>script(`return !document.querySelector('#bot-send').disabled`));
  await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=editor]');
  await openTreePath(PROGRESS_TEST);await until(()=>script(`return document.querySelector('#editor-status').textContent.startsWith(arguments[0])`,[PROGRESS_TEST]));
  await click('#editor-share-files');await script(`for(const c of document.querySelectorAll('[data-related-file]'))c.checked=true`);await click('#related-files-attach');
  await until(()=>script(`return document.querySelector('#bot-attachment-list').textContent.includes('task-progress-test.mjs')`));
  photo('01_Super_Files_Attached');
  await type('#bot-message','Make the planned edit');await click('#bot-send');
  await until(()=>script(`return !!document.querySelector('[data-review-file-set]')&&!document.querySelector('#bot-send').disabled`),90000);
  check('the provider fixture received both Super files as complete drafts and proposed both back',chatCalls===1&&lastBotRequest.messages.some(m=>m.content.includes(oldReason))&&lastBotRequest.messages.some(m=>m.content.includes("import {taskProgress,taskProgressRows}")));
  await click('[data-review-file-set]');await until(()=>script(`return !!document.querySelector('#bot-file-set-review[open]')`));photo('02_Combined_Review');
  await click('#bot-file-set-record');await until(()=>script(`return document.querySelector('#bot-file-set-record').textContent==='Combined review saved'`));
  savedSet=await script(`return Object.values(window.cockpit.frame.projection.development_attempts).find(a=>a.schema==='development-review-set@1')`);
  await click('#bot-file-set-cancel');await until(()=>script(`return !document.querySelector('#bot-file-set-review')`));
  const body=async ref=>{const r=await script(`return window.__TAURI__.core.invoke('review_content',{digest:arguments[0]})`,[ref.digest]);return r?.state==='available'?r.content:null;};
  check('the saved review names both Super files by digest at the clone’s HEAD, published and readable',savedSet.files.length===2&&savedSet.source.head===sourceHead&&savedSet.files.every(f=>f.content?.held==='staged')&&await body(savedSet.files[0].content.proposed)===proposedProgress&&await body(savedSet.files[1].content.proposed)===proposedTest);
  check('nothing in the clone changed by recording',readFileSync(testRepo+'/'+PROGRESS,'utf8')===currentProgress&&readFileSync(testRepo+'/'+PROGRESS_TEST,'utf8')===currentTest);
  // ------------------------------------------------ restart
  const callsBeforeRestart=chatCalls,worldBefore=await script('return window.cockpit.frame.world');
  process.kill(-driver.pid,'SIGKILL');session=null;await sleep(1500);
  driver=spawn('tauri-driver',['--port',String(port),'--native-port',String(port+1),'--native-driver','/usr/bin/WebKitWebDriver'],{cwd:testRepo,detached:true,stdio:['ignore','pipe','pipe'],env:env()});
  driver.stdout.on('data',b=>{log=(log+b).slice(-8000)});driver.stderr.on('data',b=>{log=(log+b).slice(-8000)});
  await openSession(`${root}/cockpit/target/release/super-cockpit`);
  await until(()=>script(`return !!window.cockpit?.frame?.projection?.development_attempts?.[arguments[0]]`,[savedSet.id]));
  check('an actual restart reopens the saved review, same incarnation, new epoch',await script(`const w=window.cockpit.frame.world;return w.world_incarnation===arguments[0].world_incarnation&&w.projection_epoch!==arguments[0].projection_epoch`,[worldBefore]));
  async function openReview(){await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=development-tasks]');if(await script(`return !!document.querySelector('#development-task-list article button')?.getClientRects().length`))await click('#development-task-list article button');await until(()=>script(`return !!document.querySelector('[data-attempt-id="'+arguments[0]+'"]')`,[savedSet.id]));if(!await script(`return document.querySelector('[data-attempt-id="'+arguments[0]+'"]')?.open`,[savedSet.id]))await click('[data-attempt-id="'+savedSet.id+'"] > summary');}
  const savedStatus=()=>script(`return document.querySelector('[data-saved-review-status="'+arguments[0]+'"]')?.textContent??''`,[savedSet.id]);
  await openReview();await script(`document.querySelector('[data-stage-saved-review="'+arguments[0]+'"]').scrollIntoView({block:'center'})`,[savedSet.id]);await click('[data-stage-saved-review="'+savedSet.id+'"]');
  check('the restarted cockpit refuses to stage until the clone is chosen again',(await until(async()=>(await savedStatus())||null)).includes("Choose the plan's repository in Editor first"));
  await click('#task-prepare-file');await until(()=>script(`return !document.querySelector('[data-screen=editor]').hidden`));
  await click('#development-choose-editor');await sleep(700);chooser();await sleep(800);if(!await script(`return !!document.querySelector('[data-file-path="cockpit"]')`))chooser();
  await until(()=>script(`return !!document.querySelector('[data-file-path="cockpit"]')`));
  // ------------------------------------------------ Super's own suites, in the sandbox
  await openReview();await until(()=>script(`return !document.querySelector('#attempt-run-'+arguments[0]).disabled`,[savedSet.id]));await click('#attempt-run-'+savedSet.id);
  const runRecord=await until(()=>script(`return Object.values(window.cockpit.frame.projection.development_attempts[arguments[0]].test_runs??{}).find(r=>r.state==='completed')`,[savedSet.id]),120000);
  const runsList=await script(`return window.__TAURI__.core.invoke('review_tests',{request:{operation:'list',world:JSON.parse(arguments[1]),attempt_ref:arguments[0]}})`,[savedSet.id,JSON.stringify([worldBefore.world_incarnation,worldBefore.world_generation,(await script('return window.cockpit.frame.world')).projection_epoch])]);
  const runOutput=runsList.runs.find(r=>r.run_id===runRecord.run_id)?.result;
  check('Super’s JavaScript suites — every tools/*-test.mjs in the accepted snapshot, the new assertion included — pass in the runner’s sandbox against the clone plus the proposal',runRecord.outcome.verdict==='pass'&&runRecord.outcome.result_sha256===savedSet.source.result_sha256&&(runOutput?.tests??[]).includes(PROGRESS_TEST)&&(runOutput?.tests?.length??0)===run('/bin/sh',['-c','ls tools/*-test.mjs | wc -l'],{cwd:testRepo,encoding:'utf8'}).trim()*1);
  console.log('note: test files run: '+(runOutput?.tests?.length)+' · snapshot '+runRecord.outcome.snapshot_sha256);
  photo('03_Super_Suites_Passed');
  // ------------------------------------------------ stage the SAVED review, apply, accept
  const callsAfterRestart=chatCalls;
  await openReview();await script(`document.querySelector('[data-stage-saved-review="'+arguments[0]+'"]').scrollIntoView({block:'center'})`,[savedSet.id]);await click('[data-stage-saved-review="'+savedSet.id+'"]');
  await until(()=>script(`return document.querySelector('#bot-file-set-review[open]')?.dataset.savedReview===arguments[0]`,[savedSet.id]));
  photo('04_Saved_Review_Staged_From_Record');
  await click('#bot-file-set-stage');await until(()=>script(`return !document.querySelector('#bot-file-set-review')`));await until(()=>script(`return !!document.querySelector('#editor-set-apply')`));
  check('the saved review is staged from its recorded bytes with no provider call; the clone is unchanged',chatCalls===callsAfterRestart&&chatCalls===callsBeforeRestart&&readFileSync(testRepo+'/'+PROGRESS,'utf8')===currentProgress);
  await click('#editor-set-apply');await until(()=>readFileSync(testRepo+'/'+PROGRESS,'utf8')===proposedProgress);
  await until(()=>script(`return document.querySelector('#editor-status').textContent.includes('All reviewed files applied')`));
  check('one apply writes both Super files',readFileSync(testRepo+'/'+PROGRESS_TEST,'utf8')===proposedTest&&!existsSync(testRepo+'/.git/super-apply-journal-v1.json'));
  await openReview();await until(()=>script(`return !!document.querySelector('[data-accept-result="'+arguments[0]+'"]')`,[savedSet.id]));
  await type('[data-acceptance-note="'+savedSet.id+'"]','Both Super files match the passing snapshot; the wording names the saved-review path.');await click('[data-accept-result="'+savedSet.id+'"]');
  const accepted=await until(()=>script(`const a=window.cockpit.frame.projection.development_attempts[arguments[0]];return a.status==='accepted'?a:null`,[savedSet.id]));
  check('acceptance binds the Super files and the passing snapshot; the record’s identity and content are unchanged',accepted.acceptance.snapshot_sha256===runRecord.outcome.snapshot_sha256&&accepted.acceptance.result_sha256===savedSet.source.result_sha256&&JSON.stringify(accepted.files)===JSON.stringify(savedSet.files)&&accepted.source.basis_id===savedSet.source.basis_id);
  photo('05_Accepted');
  // ------------------------------------------------ the actual application, built from the accepted snapshot
  await until(()=>script(`return !!document.querySelector('[data-build-accepted="'+arguments[0]+'"]')`,[savedSet.id]));
  const buildStarted=Date.now();await click('[data-build-accepted="'+savedSet.id+'"]');
  await until(()=>script(`return !!document.querySelector('[data-accepted-builds="'+arguments[0]+'"] [data-cancel-build]')`,[savedSet.id]));photo('06_Super_Build_Running');
  const buildOutcome=await until(()=>script(`const t=document.querySelector('[data-accepted-builds="'+arguments[0]+'"]').textContent;return t.includes('Development build ready')?'ready':/Build failed|timed out|Build ended|build-failed|timeout/.test(t)?t:null`,[savedSet.id]),25*60*1000);
  const buildSeconds=Math.round((Date.now()-buildStarted)/1000);
  if(buildOutcome!=='ready'){photo('07_Super_Build_Failed');throw Error('the accepted build of Super did not complete after '+buildSeconds+' s: '+buildOutcome.slice(0,1500));}
  const readyText=await script(`return document.querySelector('[data-accepted-builds="'+arguments[0]+'"]').textContent`,[savedSet.id]);
  const launcher=readyText.match(/\/[^\n]*\/artifact\/launch-super\.sh/)?.[0];assert.ok(launcher);const binary=launcher.replace('launch-super.sh','super-cockpit');
  const bytes=readFileSync(binary),buildDir=dirname(dirname(binary));
  const outcome=JSON.parse(readFileSync(buildDir+'/outcome.json','utf8'));
  check('the accepted build ran the real super-cockpit-release@1 profile, offline in the sandbox, and produced an ELF cockpit executable',outcome.profile==='super-cockpit-release@1'&&outcome.state==='completed'&&outcome.snapshot_sha256===accepted.acceptance.snapshot_sha256&&bytes.subarray(0,4).equals(Buffer.from([127,69,76,70]))&&bytes.length>5*1024*1024&&outcome.artifact.sha256===sha(bytes));
  console.log(`note: Super built from the accepted snapshot in ${buildSeconds} s · executable ${bytes.length} bytes · sha256 ${sha(bytes)} · snapshot ${outcome.snapshot_sha256} · head ${outcome.source_head}`);
  const strings=run('/usr/bin/strings',['-n','12',binary],{encoding:'utf8',maxBuffer:256*1024*1024});
  check('the built executable embeds the accepted page: the new next-action wording and the saved-review action are in its bytes; the old wording is not',strings.includes('Stage the saved review in Editor and apply the staged change set')&&strings.includes('Stage saved review in Editor')&&!strings.includes(oldReason));
  check('the snapshot the build captured carries the accepted files exactly',readFileSync(buildDir+'/snapshot/'+PROGRESS,'utf8')===proposedProgress&&readFileSync(buildDir+'/snapshot/'+PROGRESS_TEST,'utf8')===proposedTest);
  photo('08_Super_Build_Ready');
  // ------------------------------------------------ the built application, launched on its own
  process.kill(-driver.pid,'SIGKILL');session=null;await sleep(1500);
  const artifactData=mkdtempSync(testRoot+'/super-self-artifact-');
  driver=spawn('tauri-driver',['--port',String(port),'--native-port',String(port+1),'--native-driver','/usr/bin/WebKitWebDriver'],{cwd:testRepo,detached:true,stdio:['ignore','pipe','pipe'],env:env({XDG_DATA_HOME:artifactData,XDG_STATE_HOME:artifactData+'/state',AMPD_DIR:buildDir+'/snapshot/ampd',SUPER_WORLD:'self-build-artifact'})});
  driver.stdout.on('data',b=>{log=(log+b).slice(-8000)});driver.stderr.on('data',b=>{log=(log+b).slice(-8000)});
  await openSession(binary);
  const running=await script(`return {world:window.cockpit.frame.world,screens:[...document.querySelectorAll('[data-screen]')].map(s=>s.dataset.screen).length,tasks:!!document.querySelector('#development-tasks')}`);
  const module=await script(`return import('./saved-review.js').then(m=>Object.keys(m).sort())`);
  check('the built Super runs as a cockpit of its own — its runtime from the accepted snapshot, in a fresh world — and serves frames',running.world?.world_incarnation!==undefined&&running.tasks&&running.screens>5);
  check('the page the built Super serves carries the saved-review module',JSON.stringify(module)===JSON.stringify(['savedReviewBodies','savedReviewItem','savedReviewItems','savedReviewSet']));
  photo('09_Built_Super_Running');
  writeFileSync(testData+'/self-build-summary.json',JSON.stringify({source_head:sourceHead,clone:testRepo,attempt:accepted.id,snapshot_sha256:outcome.snapshot_sha256,executable:binary,executable_sha256:sha(bytes),executable_bytes:bytes.length,build_seconds:buildSeconds,provider_calls:chatCalls,files:[PROGRESS,PROGRESS_TEST]},null,2)+'\n');
  console.log('summary: '+testData+'/self-build-summary.json');
  console.log(`super self-build dogfood: ${checks} held`);
} catch(e){console.error(log);if(session)try{console.error(await script(`return document.body.innerText.slice(-6500)`));}catch{}throw e;} finally {botFixture.close();if(session)try{await wd('DELETE',`/session/${session}`);}catch{}try{process.kill(-driver.pid,'SIGTERM');}catch{}}
