/* Product-flow checks in an isolated world. No faults or runtime resets. */
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdirSync, writeFileSync, mkdtempSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const port = Number(process.env.APP_SMOKE_PORT ?? 4464);
const base = `http://127.0.0.1:${port}`;
const shots = process.env.APP_SMOKE_SCREENSHOTS;
const testData=mkdtempSync('/tmp/super-app-smoke-');
const driver = spawn('tauri-driver', ['--port', String(port), '--native-port', String(port + 1), '--native-driver', '/usr/bin/WebKitWebDriver'], {
  detached: true, stdio: ['ignore', 'pipe', 'pipe'],
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
  await click('#app-navigation [data-nav=repositories]');await click('[data-host-action=choose-repository]');await sleep(800);
  const {execFileSync}=await import('node:child_process');execFileSync('/usr/bin/python3',[`${root}/tools/development-choose-folder.py`],{env:{...process.env,SUPER_CHOOSER_TITLE:'Register a local Git repository'}});await sleep(800);if(!await script('return Object.keys(window.cockpit.frame.projection.repositories??{}).length'))execFileSync('/usr/bin/python3',[`${root}/tools/development-choose-folder.py`],{env:{...process.env,SUPER_CHOOSER_TITLE:'Register a local Git repository'}});
  await until(()=>script('return Object.keys(window.cockpit.frame.projection.repositories??{}).length>0'));
  await click('[data-rail-mode=bots]');await click('#rail-bots [data-nav=new-bot]');
  await type('#new-bot-name','Super Builder');await type('#new-bot-role','Implementation');await type('#new-bot-instructions','Build Super with reviewable changes.');await click('#create-bot-submit');
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
  check('New lane appears in its bot Work page',await script(`return document.querySelector('.bot-work-stats strong').textContent==='1' && !!document.querySelector('#bot-work [data-record-open="lane:'+arguments[0]+'"]')`,[lane.id]));
  await click('#bot-work [data-record-form=worker_lane]');await type('[data-draft=worker_purpose]','Implement and review Super changes');await click('[data-id=open-worker] button');
  const worker=await until(()=>script(`return Object.values(window.cockpit.frame.projection.workers).find(w=>w.locus_ref===arguments[0])`,[lane.id]));
  await click('[data-rail-mode=bots]');await click(`#rail-bots [data-nav="${route}"]`);await click('#bot-tab-work');
  check('Assigned worker is visible without inventing an available terminal',await script(`return document.querySelectorAll('.bot-work-stats strong')[1].textContent==='1' && document.querySelectorAll('.bot-work-stats strong')[2].textContent==='0' && !document.querySelector('#bot-work [data-watch-worker]') && document.querySelector('#bot-work').textContent.includes('OFFLINE')`));
  await script(`document.querySelector('#workspace-canvas').scrollTop=0`);
  if(shots){mkdirSync(shots,{recursive:true});execFileSync('/usr/bin/python3',[`${root}/tools/development-capture-window.py`,String(driver.pid),resolve(shots,'Super_Progress_02_Bot_Work.png')]);}
  await click('#bot-work [data-record-open^="worker:"]');
  check('Worker link opens the actual worker record',await script(`return document.querySelector('[data-screen=record]').dataset.recordKey==='worker:'+arguments[0]`,[worker.id]));
  await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=development-tasks]');
  await type('#task-title','Highlight changed ranges');await type('#task-criteria','Changed lines are visible and Cancel preserves the draft.');await click('#development-task-form button');
  const task=await until(()=>script(`return Object.values(window.cockpit.frame.projection.development_tasks??{}).find(t=>t.title==='Highlight changed ranges')`));
  await until(()=>script(`return document.querySelector('#development-task-detail').textContent.includes('Plan history')`));
  check('task creation binds the selected lane and bot',task.lane_ref===lane.id&&task.bot_ref===bot.id&&task.status==='planned');
  check('new plan offers prepare request',await script(`return document.querySelector('[data-task-next-action] button').textContent==='Prepare file request'`));
  await script(`const e=document.querySelector('#task-status');e.value='blocked';e.dispatchEvent(new Event('change',{bubbles:true}))`);
  await type('#task-note','Waiting for review guidance');await click('#development-task-detail form button');
  await until(()=>script(`return window.cockpit.frame.projection.development_tasks[arguments[0]].revision===2`,[task.id]));
  await until(()=>script(`return document.querySelector('#development-task-detail').textContent.includes('Waiting for review guidance')`));
  check('blocker update retains criteria and appends history',await script(`const t=window.cockpit.frame.projection.development_tasks[arguments[0]];return t.status==='blocked'&&t.history.length===2&&t.criteria.includes('Cancel')`,[task.id]));
  check('blocked plan names next action',await script(`return document.querySelector('[data-task-next-action]').textContent.includes('Review plan blocker')`));
  await click('[data-task-next-action] button');
  check('blocker action focuses planning note',await script(`return document.activeElement.id==='task-note'`));
  const reloadToken=String(Date.now());await script('window.__attentionReload=arguments[0];location.reload()',[reloadToken]);await until(()=>script('return window.__attentionReload!==arguments[0]&&!!window.cockpit?.frame?.projection?.development_tasks&&!!document.querySelector("#development-task-list")',[reloadToken]));
  await click('#app-navigation [data-nav=development-tasks]');await click('#development-task-list article button');
  check('page reload reopens durable plan and blocker history',await script(`return document.querySelector('#development-task-detail').textContent.includes('Waiting for review guidance')`));
  await click('#development-task-detail [data-record-open^="goal:"]');
  check('goal record links back to its development plan',await script(`return !!document.querySelector('[data-development-task="'+arguments[0]+'"]')`,[task.id]));
  await click('[data-screen=record] [data-development-task="'+task.id+'"]');
  check('goal backlink opens the same task',await script(`return !document.querySelector('#development-tasks').hidden&&document.querySelector('#development-task-detail').textContent.includes(arguments[0])`,[task.id]));
  if(shots){mkdirSync(shots,{recursive:true});execFileSync('/usr/bin/python3',[`${root}/tools/development-capture-window.py`,String(driver.pid),resolve(shots,'Super_Development_Task.png')]);}
  await click('#app-navigation [data-nav=mission]');
  check('mission links task with blocker',await script(`return [...document.querySelectorAll('[data-screen=mission] [data-development-task]')].some(n=>n.dataset.developmentTask===arguments[0]&&n.parentElement.textContent.includes('Review plan blocker'))`,[task.id]));
  await click('[data-screen=mission] [data-development-task="'+task.id+'"]');
  check('mission opens correct task',await script(`return !document.querySelector('#development-tasks').hidden&&document.querySelector('[data-task-next-action]').dataset.taskNextAction===arguments[0]`,[task.id]));

  async function photo(name,selector){if(!shots)return;await script('document.querySelector(arguments[0]).scrollIntoView({block:"center"})',[selector]);mkdirSync(shots,{recursive:true});execFileSync('/usr/bin/python3',[`${root}/tools/development-capture-window.py`,String(driver.pid),resolve(shots,name+'.png')]);}
  await click('#development-task-detail > button');await type('#task-title','Prepare another improvement');await type('#task-criteria','Keep this plan separate from the blocked plan.');await click('#development-task-form button');
  const second=await until(()=>script(`return Object.values(window.cockpit.frame.projection.development_tasks).find(t=>t.title==='Prepare another improvement')`));
  await click('#app-navigation [data-nav=mission]');
  check('mission counts each plan once and separates preparation',await script(`const n=document.querySelector('[data-screen=mission] [data-task-attention-total]');return n.dataset.taskAttentionTotal==='2'&&n.dataset.taskNeedsAttention==='1'&&document.querySelector('[data-screen=mission] [data-task-attention-group=blocked] summary').textContent.includes('(1)')&&document.querySelector('[data-screen=mission] [data-task-attention-group=prepare] summary').textContent.includes('(1)')`));
  await photo('01_Mission_Attention','[data-screen=mission] [data-task-attention]');
  await click('[data-screen=mission] [data-task-attention-group=blocked] summary');
  await sleep(700);
  check('attention group can collapse',await script(`return !document.querySelector('[data-screen=mission] [data-task-attention-group=blocked]').open`));
  await click('[data-screen=mission] [data-task-attention-group=blocked] summary');
  await click('[data-screen=mission] [data-development-task="'+task.id+'"]');
  check('grouped blocker opens exact task',await script(`return document.querySelector('[data-task-next-action]').dataset.taskNextAction===arguments[0]`,[task.id]));
  await click('[data-rail-mode=bots]');await click('#rail-bots [data-nav="'+route+'"]');await click('#bot-tab-work');
  check('bot work shows the same scoped attention counts',await script(`const n=document.querySelector('#bot-work [data-task-attention-total]');return n.dataset.taskAttentionTotal==='2'&&n.dataset.taskNeedsAttention==='1'`));
  await photo('02_Bot_Work_Attention','#bot-work [data-task-attention]');
  await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=positions]');await click('[data-screen=positions] [data-nav=new-workspace]');await type('[data-draft=workspace_name]','Empty attention workspace');await click('[data-id=open-workspace] button');
  const other=await until(()=>script(`return Object.values(window.cockpit.frame.projection.workspaces).find(w=>w.name==='Empty attention workspace')`));
  await script(`const e=document.querySelector('#workspace-picker');e.value=arguments[0];e.dispatchEvent(new Event('change',{bubbles:true}))`,[other.id]);await click('#app-navigation [data-nav=mission]');
  check('workspace switch excludes other task attention',await script(`return document.querySelector('[data-screen=mission] [data-task-attention-total]').dataset.taskAttentionTotal==='0'&&!document.querySelector('[data-screen=mission] [data-development-task]')`));
  await photo('03_Empty_Workspace','[data-screen=mission] [data-task-attention]');
  await script(`const e=document.querySelector('#workspace-picker');e.value=arguments[0];e.dispatchEvent(new Event('change',{bubbles:true}))`,[ws.id]);
  await click('[data-screen=mission] [data-development-task="'+second.id+'"]');
  await script(`const e=document.querySelector('#task-status');e.value='cancelled';e.dispatchEvent(new Event('change',{bubbles:true}))`);await type('#task-note','Cancel the extra fixture plan');await click('#development-plan-update button');
  await until(()=>script(`return window.cockpit.frame.projection.development_tasks[arguments[0]].status==='cancelled'`,[second.id]));await click('#app-navigation [data-nav=mission]');
  check('closed plans disappear from attention totals',await script(`const n=document.querySelector('[data-screen=mission] [data-task-attention-total]');return n.dataset.taskAttentionTotal==='1'&&n.dataset.taskNeedsAttention==='1'&&!document.querySelector('[data-screen=mission] [data-task-attention-group=prepare]')`));
  await wd('POST',`/session/${session}/window/rect`,{width:1000,height:760});await photo('04_Narrow_Attention','[data-screen=mission] [data-task-attention]');
  check('attention navigation sends no provider messages',chatCalls===0);
  console.log(`task attention smoke: ${checks} held`);
} catch(e){console.error(log);throw e;} finally {botFixture.close();if(session)try{await wd('DELETE',`/session/${session}`);}catch{}try{process.kill(-driver.pid,'SIGTERM');}catch{}}
