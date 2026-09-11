import {visualEvidence} from './visual-evidence.mjs';
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
const testData=mkdtempSync((process.env.DEVELOPMENT_TEST_ROOT??'/tmp')+'/super-app-smoke-');
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
const evidence=visualEvidence('cockpit-app-smoke',root,driver,["Mission Control guides setup and labels frame charts", "File New workspace opens the page and preserves the draft", "workspace opens a dedicated formatted page", "Goal overview has a scoped next step", "Related work tab reveals relationships", "repositories have their own page and visible chooser", "runtime assignments show authoritative rows without creation forms", "all three typed history windows show their coverage", "registered Work tab reports empty assignments and prefills its actor", "runtime identity has its own record page and lane action", "Connect provider is primary and manual keys start collapsed", "local connect discovers a model without a key or model ID", "switching back restores connection model draft and attachment", "chat displays readable links while retaining original IDs", "applying a proposal creates the workspace through a live frame", "reopening neither sends messages nor restores action buttons", "workspace deletion requires a separate confirmation", "narrow layout has no page overflow"]);
function check(label, value) { assert.ok(value, label); evidence.record(label); checks++; console.log(`held ${label}`); }
async function screenshot(name) {
  if (!shots) return;
  mkdirSync(shots, { recursive: true });
  const b = await wd('GET', `/session/${session}/screenshot`);
  writeFileSync(resolve(shots, `${name}.png`), Buffer.from(b, 'base64'));
}
try {
  await until(async () => { try { return (await fetch(base + '/status')).ok; } catch { return false; } }, 15000);
  const created = await wd('POST', '/session', { capabilities: { alwaysMatch: { 'tauri:options': { application: `${root}/cockpit/target/release/super-cockpit` } } } });
  session = created.sessionId;
  await until(() => script('return window.cockpit?.frame?.state === "live-local" && !!document.querySelector("[data-screen=mission] h1")'));
  check('live frame renders Mission Control', await script('return !document.querySelector("[data-screen=mission]").hidden'));
  check('prototype navigation groups, development tools, and three rail modes are available', await script('return document.querySelectorAll("#app-navigation .nav-group").length === 5 && document.querySelectorAll("#app-navigation [data-nav]").length === 18 && !!document.querySelector("#app-navigation [data-nav=development-tasks]") && document.querySelectorAll("[data-rail-mode]").length === 3')); 
  check('Mission Control guides setup and labels frame charts',await script(`return !!document.querySelector('[data-screen=mission] .work-guidance') && document.querySelectorAll('[data-screen=mission] .frame-chart').length===2`));
  check('sidebar counters derive from current workspaces',await script(`return document.querySelector('[data-nav-count=positions]').textContent===String(Object.keys(window.cockpit.frame.projection.workspaces).length)`));
  await screenshot('super-mission');
  await click('#app-navigation [data-nav=positions]');
  await click('[data-screen=positions] [data-nav=new-workspace]');
  await type('[data-draft=workspace_name]', 'App flow workspace');
  await click('[data-screen=new-workspace] .subtle');
  check('cancel returns to the list without creating a workspace',await script(`return !document.querySelector('[data-screen=positions]').hidden && !Object.values(window.cockpit.frame.projection.workspaces).some(w=>w.name==='App flow workspace')`));
  await click('[data-menu=File]');await click('[data-menu=File] + .desktop-menu button');
  check('File New workspace opens the page and preserves the draft',await script(`return !document.querySelector('[data-screen=new-workspace]').hidden && document.querySelector('[data-draft=workspace_name]').value==='App flow workspace'`));
  await click('[data-id=open-workspace] button');
  await until(() => script('return Object.values(window.cockpit.frame.projection.workspaces).some(w => w.name === "App flow workspace")'));
  await until(()=>script(`return !document.querySelector('[data-screen=record]').hidden && document.querySelector('[data-screen=record] h1').textContent==='App flow workspace'`));
  check('workspace creation redirects to its confirmed detail page',await script(`return !document.querySelector('[data-screen=positions] [data-draft=workspace_name]')`));
  await click('#app-navigation [data-nav=positions]');
  check('workspace creation is confirmed in a live frame and rendered', await script('return document.querySelector("[data-screen=positions]").textContent.includes("App flow workspace")'));
  await script(`const p = document.getElementById('workspace-picker'); p.value = Object.values(window.cockpit.frame.projection.workspaces).find(w => w.name === 'App flow workspace').id; p.dispatchEvent(new Event('change', {bubbles:true}));`);
  check('workspace selection scopes the goal form', await script(`return document.querySelector('[data-draft=goal_ws]').options.length === 1 && document.querySelector('[data-draft=goal_ws]').value === document.getElementById('workspace-picker').value`));
  // A real press lasts across frames; webdriver element.click was too fast
  // to catch a DOM node being discarded between pointerdown and pointerup.
  const recordSelector = '[data-screen=positions] [data-detail^="position-workspace:"] .record-trigger';
  await script(`document.querySelector(arguments[0]).scrollIntoView({block:'center'});window.pressedRecord=document.querySelector(arguments[0]);`, [recordSelector]);
  const recordElement = await element(recordSelector);
  await wd('POST', `/session/${session}/actions`, {actions:[{type:'pointer',id:'record-mouse',parameters:{pointerType:'mouse'},actions:[{type:'pointerMove',duration:0,origin:{'element-6066-11e4-a52e-4f735466cecf':recordElement},x:0,y:0},{type:'pointerDown',button:0}]}]});
  await script(`window.cockpit.render(window.cockpit.frame);window.cockpit.render(window.cockpit.frame);`);
  await sleep(120);
  check('pressed workspace control stays connected across redraws', await script(`return window.pressedRecord.isConnected && window.pressedRecord===document.querySelector(arguments[0])`,[recordSelector]));
  await wd('POST', `/session/${session}/actions`, {actions:[{type:'pointer',id:'record-mouse',parameters:{pointerType:'mouse'},actions:[{type:'pointerUp',button:0}]}]});

  check('workspace opens a dedicated formatted page',await script(`return !document.querySelector('[data-screen=record]').hidden && document.querySelector('[data-screen=record] h1').textContent==='App flow workspace' && !document.querySelector('[data-screen=record] pre')`));
  await click('#history-back');
  check('back returns to workspace list',await script(`return !document.querySelector('[data-screen=positions]').hidden`));
  await click('#history-forward');
  check('forward restores the record page',await script(`return !document.querySelector('[data-screen=record]').hidden`));
  await click('[data-record-back]');
  await click('#app-navigation [data-nav=goals]');
  await click('[data-screen=goals] [data-setup-form=open-goal]');
  await type('[data-draft=goal_title]', 'Wire the app to the runtime');
  await click('[data-id=open-goal] button');
  await until(() => script('return Object.values(window.cockpit.frame.projection.goals).some(g => g.title === "Wire the app to the runtime")'));
  await until(()=>script(`return !document.querySelector('[data-screen=record]').hidden && document.querySelector('[data-screen=record] h1').textContent==='Wire the app to the runtime'`));
  check('goal creation redirects to its confirmed detail page',true);
  await click('#app-navigation [data-nav=goals]');
  await click('[data-screen=goals] [data-detail^="goal:"] .record-trigger');
  check('goal page shows actionable formatted relationships',await script(`return !document.querySelector('[data-screen=record]').hidden && !!document.querySelector('[data-screen=record] [data-record-form]') && !!document.querySelector('[data-screen=record] dl')`));
  check('Goal overview has a scoped next step',await script(`return document.querySelector('[data-record-view=overview] .record-flag [data-record-form=lane_goal]').dataset.recordValue===document.querySelector('[data-screen=record]').dataset.recordKey.slice(5)`));
  await click('[data-record-tab=work]');
  check('Related work tab reveals relationships',await script(`return !document.querySelector('[data-record-view=work]').hidden&&document.querySelector('[data-record-view=overview]').hidden`));
  await script(`window.cockpit.render(window.cockpit.frame)`);
  check('Record section survives delivered-frame redraw',await script(`return document.querySelector('[data-record-tab=work]').getAttribute('aria-selected')==='true'&&!document.querySelector('[data-record-view=work]').hidden`));
  await click('[data-record-tab=data]');
  check('Record data is a separate section',await script(`return !document.querySelector('[data-record-view=data]').hidden&&document.querySelector('[data-record-view=work]').hidden`));
  await click('[data-record-tab=overview]');
  await screenshot('super-record-pages');await click('[data-record-back]');
  check('goals return to their own directory',await script(`return !document.querySelector('[data-screen=goals]').hidden`));
  await click('#app-navigation [data-nav=positions]');

  check('navigation selection survives incoming frames', await script('return !document.querySelector("[data-screen=positions]").hidden && document.querySelector("[data-screen=mission]").hidden'));
  check('workspace choice survives a new frame', await script(`return document.getElementById('workspace-picker').selectedOptions[0].textContent === 'App flow workspace'`));
  await click('[data-screen=positions] [data-nav=new-workspace]');
  await type('[data-draft=workspace_name]', 'Another workspace');
  await click('[data-id=open-workspace] button');
  await until(() => script(`return Object.values(window.cockpit.frame.projection.workspaces).some(w => w.name === 'Another workspace')`));
  await until(()=>script(`return !document.querySelector('[data-screen=record]').hidden && document.querySelector('[data-screen=record] h1').textContent==='Another workspace'`));
  await click('#app-navigation [data-nav=positions]');
  await script(`const p = document.getElementById('workspace-picker'); p.value = Object.values(window.cockpit.frame.projection.workspaces).find(w => w.name === 'Another workspace').id; p.dispatchEvent(new Event('change', {bubbles:true}));`);
  check('switching workspaces excludes the other workspace goal', await script(`return !document.querySelector('[data-screen=goals]').textContent.includes('Wire the app to the runtime') && document.querySelector('[data-draft=lane_goal]').disabled`));
  await script(`const p = document.getElementById('workspace-picker'); p.value = ''; p.dispatchEvent(new Event('change', {bubbles:true}));`);
  check('all-workspaces view restores the complete goal list', await script(`return document.querySelector('[data-screen=goals]').textContent.includes('Wire the app to the runtime')`));
  await click('#app-navigation [data-nav=repositories]');
  check('repositories have their own page and visible chooser',await script(`return !document.querySelector('[data-screen=repositories]').hidden && document.querySelector('[data-screen=repositories] [data-host-action="choose-repository"]').getBoundingClientRect().height>0 && !document.querySelector('[data-screen=positions] [data-host-action="choose-repository"]')`));
  check('repository page survives incoming frames',await script(`window.cockpit.render(window.cockpit.frame);return !document.querySelector('[data-screen=repositories]').hidden`));
  await click('#history-back');
  check('back returns from repositories to workspaces',await script(`return !document.querySelector('[data-screen=positions]').hidden`));
  await screenshot('super-workspaces');
  check('workspace directory does not duplicate goal or lane cards',await script(`return !document.querySelector('[data-screen=positions] [data-detail^="goal:"]')&&!document.querySelector('[data-screen=positions] [data-detail^="lane:"]')`));
  await click('#app-navigation [data-nav=lanes]');
  check('lanes have their own setup and directory page',await script(`return !document.querySelector('[data-screen=lanes]').hidden && !!document.querySelector('[data-screen=lanes] [data-setup-form=open-lane]')`));
  await click('[data-rail-mode=runtime]');
  check('switching to Runtime opens a runtime page',await script(`return !document.querySelector('[data-screen=runtime]').hidden`));
  await click('#rail-runtime [data-nav=runtime-assignments]');
  check('runtime assignments show authoritative rows without creation forms',await script(`const p=document.querySelector('[data-screen=runtime-assignments]');return !p.hidden && p.querySelectorAll('[data-runtime-record]').length===Object.keys(window.cockpit.frame.projection.workspaces).length+Object.keys(window.cockpit.frame.projection.goals).length+Object.keys(window.cockpit.frame.projection.lanes).length+Object.keys(window.cockpit.frame.projection.workers).length+Object.keys(window.cockpit.frame.projection.carrier_attempts??{}).length && !p.querySelector('[data-intent-form],[data-setup-form]')`));
  await script(`const p=document.querySelector('#workspace-picker');p.value=Object.keys(window.cockpit.frame.projection.workspaces)[0];p.dispatchEvent(new Event('change',{bubbles:true}));`);
  check('runtime assignments remain whole-runtime when workspace filter changes',await script(`return document.querySelectorAll('[data-screen=runtime-assignments] .runtime-record-id').length===Object.keys(window.cockpit.frame.projection.workspaces).length+Object.keys(window.cockpit.frame.projection.goals).length`));
  await script(`const p=document.querySelector('#workspace-picker');p.value='';p.dispatchEvent(new Event('change',{bubbles:true}));`);
  const stateFacts=await wd('POST',`/session/${session}/execute/async`,{script:`const done=arguments[arguments.length-1];import('./runtime-assignments.js').then(({runtimeAssignments})=>{const node=(tag,text,cls)=>{const n=document.createElement(tag);if(text!==undefined)n.textContent=text;if(cls)n.className=cls;return n;};const page=runtimeAssignments({frame:{projection:{workers:{one:{id:'wk_test1',locus_ref:'ln_test',status:'open',occupancy:'OCCUPIED',terminal:'PRESENT',generation:7},two:{id:'wk_test2',status:'closed'}}}},node,panel:()=>node('section'),card:()=>node('span'),detail:()=>node('span')});const one=page.querySelector('[data-runtime-record=wk_test1]').children,two=page.querySelector('[data-runtime-record=wk_test2]').children;done(one[3].textContent==='OCCUPIED'&&one[4].textContent==='PRESENT'&&one[5].textContent==='7'&&two[3].textContent==='Not reported'&&two[4].textContent==='Not reported');}).catch(e=>done(String(e)));`,args:[]});
  check('runtime worker table preserves reported state and does not invent missing state',stateFacts===true);
  await screenshot('super-runtime-assignments');
  await click('[data-rail-mode=nav]');
  check('Nav restores its own last page',await script(`return !document.querySelector('[data-screen=lanes]').hidden`));
  await click('#history-back');
  check('back selects the matching Runtime sidebar mode',await script(`return !document.querySelector('[data-screen=runtime-assignments]').hidden && document.querySelector('[data-rail-mode=runtime]').getAttribute('aria-selected')==='true'`));
  await click('#history-forward');
  check('forward restores the Nav page and sidebar together',await script(`return !document.querySelector('[data-screen=lanes]').hidden && document.querySelector('[data-rail-mode=nav]').getAttribute('aria-selected')==='true'`));
  await click('#app-navigation [data-nav=positions]');

  await click('#app-navigation [data-nav=capabilities]');
  check('fixture grant is rendered on Capabilities', await script('return document.querySelector("[data-screen=capabilities]").textContent.includes("github.pr.create")'));
  await click('button[data-intent=revoke_grant]');
  await until(() => script('return window.cockpit.frame.projection.grants.length === 0'));
  check('revocation is reflected by the next runtime frame', await script('return !document.querySelector("button[data-intent=revoke_grant]")'));
  await click('#app-navigation [data-nav=evidence]');
  check('all three typed history windows show their coverage', await script('return document.querySelectorAll("[data-screen=evidence] .history-count").length === 3'));
  const historyShape = await wd('POST', `/session/${session}/execute/async`, {
    script: `const done = arguments[arguments.length - 1];
      import('./app-shell.js').then(({history}) => {
        const rendered = history('Sample', {total: 3, next_cursor: 'rcpt-1', recent: [
          {id: 'rcpt-2', kind: 'validation_job_outcome@1', state: 'completed', verdict: 'fail'},
          {id: 'rcpt-1', kind: 'validation_job_started@1'}]}, 'sample');
        done(rendered.textContent.includes('completed · fail') && rendered.textContent.includes('Attempt admitted') &&
          rendered.textContent.includes('Showing 2 of 3') && !!rendered.querySelector('.availability-note'));
      }).catch(e => done(String(e)));`, args: []
  });
  check('populated history preserves admission, verdict and bounded coverage', historyShape === true);
  await screenshot('super-evidence');
  await click('[data-rail-mode=runtime]');
  await click('#rail-runtime [data-nav=runtime]');
  await click('[data-detail=runtime-identity] .record-trigger');
  check('runtime details use formatted fields',await script(`return !document.querySelector('[data-screen=record]').hidden && document.querySelector('[data-screen=record]').textContent.includes(window.cockpit.frame.world.world_incarnation) && !document.querySelector('[data-screen=record] pre')`));
  check('record page survives a live redraw',await script(`window.cockpit.render(window.cockpit.frame);return !document.querySelector('[data-screen=record]').hidden`));
  await click('[data-record-back]');
  await script(`document.querySelector('[data-detail=runtime-identity] .record-trigger').focus()`);
  await wd('POST', `/session/${session}/actions`, {actions:[{type:'key',id:'record-keyboard',actions:[{type:'keyDown',value:'\uE007'},{type:'keyUp',value:'\uE007'}]}]});
  check('Enter opens the focused record page',await script(`return !document.querySelector('[data-screen=record]').hidden`));
  await click('#toggle-sidebar');check('sidebar toggle hides navigation',await script(`return document.querySelector('#app-rail').getBoundingClientRect().width===0`));await click('#toggle-sidebar');
  await script(`document.querySelector('#rail-resizer').focus()`);
  await wd('POST', `/session/${session}/actions`, {actions:[{type:'key',id:'resize-keyboard',actions:[{type:'keyDown',value:'\uE014'},{type:'keyUp',value:'\uE014'}]}]});
  check('sidebar border supports keyboard resize',await script(`return document.querySelector('#rail-resizer').getAttribute('aria-valuenow')==='228'`));
  const dragHandle=await element('#activity-resizer');
  await wd('POST',`/session/${session}/actions`,{actions:[{type:'pointer',id:'sidebar-drag',parameters:{pointerType:'mouse'},actions:[{type:'pointerMove',duration:0,origin:{'element-6066-11e4-a52e-4f735466cecf':dragHandle},x:0,y:0},{type:'pointerDown',button:0},{type:'pause',duration:150},{type:'pointerMove',duration:250,origin:'pointer',x:-35,y:0},{type:'pointerUp',button:0}]}]});
  check('activity border drags across live frames',await script(`return Number(document.querySelector('#activity-resizer').getAttribute('aria-valuenow'))>=290`));
  const legacy=await wd('POST',`/session/${session}/execute/async`,{script:`const done=arguments[arguments.length-1];import('./references.js').then(({renderMessage})=>{const n=document.createElement('div'),id=Object.keys(window.cockpit.frame.projection.workspaces)[0],raw='- **Workspace:** '+id+'\\n\\n* ';renderMessage(n,raw,null);done(!!n.querySelector('strong')&&!!n.querySelector('a[data-record-ref]')&&n.dataset.rawText===raw&&n.querySelector('a').title.includes('older message'));}).catch(e=>done(String(e)));`,args:[]});
  check('legacy messages render Markdown and current links without changing raw text',legacy===true);
  await click('[data-menu=Help]');check('Help menu opens',await script(`return !document.querySelector('[data-menu=Help]').nextElementSibling.hidden`));await click('[data-menu=Help]');
  await click('#open-navigation');
  await type('#navigation-search', 'Bots');
  await click('.palette-result');
  check('page finder navigates and closes', await script('return !document.querySelector("[data-screen=bots]").hidden && !document.querySelector("dialog").open'));
  await click('#rail-bots [data-nav=new-bot]');
  await type('#new-bot-name','Super Builder');await type('#new-bot-role','Implementation');await type('#new-bot-instructions','Implement Super with reviewable changes.');
  await click('#create-bot-submit');
  await until(()=>script(`return document.querySelector('#bot-surface h1').textContent==='Super Builder' && !document.querySelector('#bot-provider').disabled`));
  const builderRoute=await script(`return document.querySelector('#bot-surface').dataset.screen`);
  check('creation opens the named bot page with explicit delegation gap',await script(`return !document.querySelector('#bot-surface').hidden && document.querySelector('.bot-identity-board').textContent.includes('not connected yet')`));
  await click('#bot-tab-work');
  check('local bot Work tab explains registration without inventing counts',await script(`return !document.querySelector('#bot-work').hidden && document.querySelector('#bot-conversation').hidden && !document.querySelector('.bot-work-stats') && document.querySelector('#bot-work').textContent.includes('Register this bot')`));
  await click('#bot-tab-conversation');
  await type('#bot-message','Builder-only draft');
  await click('#rail-bots [data-nav="bot:assistant"]');
  check('bot histories isolate drafts on the same provider',await script(`return document.querySelector('#bot-message').value==='' && document.querySelector('#bot-surface h1').textContent==='Workspace assistant'`));
  await click('#history-back');
  check('history returns to the exact bot and its saved draft',await script(`return document.querySelector('#bot-surface h1').textContent==='Super Builder' && document.querySelector('#bot-message').value==='Builder-only draft'`));
  await click('#bot-surface [data-nav=edit-bot]');
  await script(`document.querySelector('#new-bot-role').value='Implementation and review'`);
  await click('#create-bot-submit');
  check('editing a bot preserves its identity and conversation',await script(`return document.querySelector('#bot-surface').dataset.screen===arguments[0] && document.querySelector('#bot-message').value==='Builder-only draft' && document.querySelector('#bot-surface .screen-description').textContent.includes('Implementation and review')`,[builderRoute]));
  await script(`const picker=document.querySelector('#bot-register-workspace');picker.value=Object.values(window.cockpit.frame.projection.workspaces).find(w=>w.name==='App flow workspace').id;picker.dispatchEvent(new Event('change'));`);
  await click('#bot-register-runtime');
  const registeredBuilder=await until(()=>script(`return Object.values(window.cockpit.frame.projection.bots??{}).find(b=>b.name==='Super Builder')`));
  await until(()=>script(`return document.querySelector('#bot-status').textContent.includes('Bot identity registered')`));
  check('registration confirms a durable actor through the runtime frame',await script(`return document.querySelector('.bot-identity-board').textContent.includes('Registered in runtime') && window.cockpit.frame.projection.bots[arguments[1]].actor===arguments[0] && window.cockpit.frame.projection.bots[arguments[1]].revision===1`,[registeredBuilder.actor,registeredBuilder.id]));
  await click('#bot-tab-work');
  if(process.env.SUPER_VISUAL_EVIDENCE_DIR)await script(`document.querySelector(arguments[0])?.scrollIntoView({block:'center'})`,["#bot-work"]);check('registered Work tab reports empty assignments and prefills its actor',await script(`return [...document.querySelectorAll('.bot-work-stats strong')].every(n=>n.textContent==='0') && document.querySelector('#bot-work [data-record-form=lane_actor]').dataset.recordValue===arguments[0]`,[registeredBuilder.actor]));
  await screenshot('super-bot-work');
  check('Work clears assignments and actions while runtime is unavailable',await wd('POST',`/session/${session}/execute/async`,{script:`const done=arguments[arguments.length-1],c=window.cockpit;c.stalled='test';document.dispatchEvent(new Event('runtime-view-rendered'));const held=!document.querySelector('.bot-work-stats')&&!document.querySelector('#bot-work [data-record-form]')&&document.querySelector('#bot-work').textContent.includes('Runtime unavailable');c.stalled=null;document.dispatchEvent(new Event('runtime-view-rendered'));done(held);`,args:[]}));
  await click('#bot-tab-conversation');
  await click('#bot-surface [data-nav=edit-bot]');
  await script(`document.querySelector('#new-bot-role').value='Runtime implementation'`);
  await click('#create-bot-submit');
  await until(()=>script(`return window.cockpit.frame.projection.bots[arguments[0]].revision===2 && !document.querySelector('#bot-surface').hidden`,[registeredBuilder.id]));
  check('registered edits persist through runtime while preserving the local draft',await script(`return document.querySelector('#bot-message').value==='Builder-only draft' && window.cockpit.frame.projection.bots[arguments[0]].role==='Runtime implementation'`,[registeredBuilder.id]));
  await click('#bot-surface [data-record-open]');
  check('runtime identity has its own record page and lane action',await script(`return document.querySelector('[data-screen=record]').textContent.includes(arguments[0]) && !!document.querySelector('[data-screen=record] [data-record-form=lane_actor]')`,[registeredBuilder.actor]));
  await click('#history-back');
  check('registered profile is unavailable and cannot be edited after projection loss',await wd('POST',`/session/${session}/execute/async`,{script:`const done=arguments[arguments.length-1],c=window.cockpit;c.stalled='test';document.dispatchEvent(new Event('runtime-view-rendered'));const held=document.querySelector('.bot-identity-board').textContent.includes('Runtime status unavailable')&&document.querySelector('#bot-surface [data-nav=edit-bot]').disabled;c.stalled=null;document.dispatchEvent(new Event('runtime-view-rendered'));done(held);`,args:[]}));
  await screenshot('super-bot-profile');
  await script(`window.originalConfirm=window.confirm;window.confirm=()=>true;`);
  await click('#bot-remove-runtime');
  await until(()=>script(`return !window.cockpit.frame.projection.bots[arguments[0]]`,[registeredBuilder.id]));
  await until(()=>script(`return document.querySelector('#bot-status').textContent.includes('Runtime registration removed')`));
  await script(`window.confirm=window.originalConfirm;`);
  check('removing registration preserves the local conversation draft',await script(`return document.querySelector('#bot-message').value==='Builder-only draft' && !!document.querySelector('#bot-register-runtime')`));

  await click('#rail-bots [data-nav="bot:assistant"]');

  check('Connect provider is primary and manual keys start collapsed', await script(`return document.querySelector('#bot-provider').options.length===5 && document.querySelector('#bot-provider').value==='codex' && !document.querySelector('.bot-settings').open && document.querySelector('#bot-send').disabled && document.querySelector('#bot-connect').getBoundingClientRect().height>0`));
  await screenshot('super-connect-provider');
  await script(`const p=document.querySelector('#bot-provider');p.value='ollama';p.dispatchEvent(new Event('change'));`);
  await script(`const n=document.getElementById('bot-endpoint'); n.value=arguments[0]; n.dispatchEvent(new Event('input',{bubbles:true}));`, [botEndpoint]);
  await click('#bot-connect');
  await until(() => script(`return !document.querySelector('#bot-send').disabled`));
  if(process.env.SUPER_VISUAL_EVIDENCE_DIR)await script(`document.querySelector(arguments[0])?.scrollIntoView({block:'center'})`,["#bot-connect"]);check('local connect discovers a model without a key or model ID',await script(`return document.querySelector('#bot-model-picker').value==='fixture-model' && !document.querySelector('.bot-settings').open`));
  await type('#bot-message','Draft stays with Ollama');
  await script(`const file=new File(['Attachment sent only on Send'],'notes.md',{type:'text/plain'});const transfer=new DataTransfer();transfer.items.add(file);const input=document.querySelector('#bot-attachments');input.files=transfer.files;input.dispatchEvent(new Event('change'));`);
  await until(()=>script(`return document.querySelector('#bot-attachment-list').textContent.includes('notes.md') && !document.querySelector('#bot-send').disabled`));
  check('staging an attachment sends no provider request',lastBotRequest===undefined);
  await script(`const p=document.querySelector('#bot-provider');p.value='openai';p.dispatchEvent(new Event('change'));`);
  check('provider has a separate draft and attachment list',await script(`return document.querySelector('#bot-message').value==='' && document.querySelector('#bot-attachment-list').children.length===0 && document.querySelector('#bot-send').disabled`));
  await script(`const p=document.querySelector('#bot-provider');p.value='ollama';p.dispatchEvent(new Event('change'));`);
  await until(()=>script(`return !document.querySelector('#bot-send').disabled`));
  if(process.env.SUPER_VISUAL_EVIDENCE_DIR)await script(`document.querySelector(arguments[0])?.scrollIntoView({block:'center'})`,["#bot-attachment-list"]);check('switching back restores connection model draft and attachment',await script(`return document.querySelector('#bot-model-picker').value==='fixture-model' && document.querySelector('#bot-message').value==='Draft stays with Ollama' && document.querySelector('#bot-attachment-list').textContent.includes('notes.md')`));
  await click('#bot-refresh-models');
  await until(()=>script(`return !document.querySelector('#bot-send').disabled`));
  check('catalog refresh preserves draft and selected model',await script(`return document.querySelector('#bot-model-picker').value==='fixture-model' && document.querySelector('#bot-message').value==='Draft stays with Ollama'`));
  await script(`document.querySelector('#bot-message').value='Please create a workspace for our next project.'`);

  await click('#bot-send');
  await until(() => script(`return !!document.querySelector('.bot-proposal button') && !document.querySelector('#bot-send').disabled`));
  check('attachment content reaches the native provider adapter on Send',lastBotRequest.messages.at(-1).content.includes('Attachment sent only on Send'));
  check('named role instructions reach the native provider without granting tools',lastBotRequest.messages[0].content.includes('Name: Workspace assistant') && lastBotRequest.messages[0].content.includes('cannot grant authority'));
  check('native provider request includes typed tools and workspace context', lastBotRequest.model === 'fixture-model' && lastBotRequest.tools.length === 5 && lastBotRequest.messages[0].content.includes('App flow workspace'));
  if(process.env.SUPER_VISUAL_EVIDENCE_DIR)await script(`document.querySelector(arguments[0])?.scrollIntoView({block:'center'})`,["#bot-transcript"]);check('chat displays readable links while retaining original IDs',await script(`const p=document.querySelector('.bot-assistant .bot-message-text'),a=p.querySelector('a[data-record-ref]');return !!a && p.dataset.rawText.includes(a.dataset.recordRef) && a.textContent!==a.dataset.recordRef`));
  await script(`window.chatLink=document.querySelector('.bot-assistant a[data-record-ref]');window.cockpit.render(window.cockpit.frame);`);
  check('reference link stays connected through live frame updates',await script(`return window.chatLink.isConnected`));
  await click('.bot-assistant a[data-record-ref]');
  check('chat reference opens its actual workspace page',await script(`return !document.querySelector('[data-screen=record]').hidden && document.querySelector('[data-screen=record]').dataset.recordKey==='position-workspace:'+window.chatLink.dataset.recordRef`));
  await click('[data-rail-mode=bots]');await click('#rail-bots [data-nav="bot:assistant"]');
  check('bot proposal makes no change before Apply', await script(`return !Object.values(window.cockpit.frame.projection.workspaces).some(w => w.name === 'Bot proposed workspace')`));
  await click('.bot-proposal button');
  await until(() => script(`return Object.values(window.cockpit.frame.projection.workspaces).some(w => w.name === 'Bot proposed workspace')`));
  if(process.env.SUPER_VISUAL_EVIDENCE_DIR)await script(`document.querySelector(arguments[0])?.scrollIntoView({block:'center'})`,[".bot-proposal"]);check('applying a proposal creates the workspace through a live frame', await script(`return document.querySelector('.bot-proposal').textContent.includes('Request accepted') && document.querySelector('.bot-proposal button').disabled`));
  check('conversation survives frame updates outside the runtime region', await script(`return document.querySelector('#bot-transcript').textContent.includes('Please create a workspace') && !document.querySelector('#world #bot-transcript')`));
  await script(`const p=document.querySelector('#bot-provider');p.value='openai';p.dispatchEvent(new Event('change'));`);
  check('other provider does not inherit the conversation or proposals',await script(`return document.querySelector('#bot-transcript').children.length===0`));
  await script(`const p=document.querySelector('#bot-provider');p.value='ollama';p.dispatchEvent(new Event('change'));`);
  await until(()=>script(`return !document.querySelector('#bot-send').disabled`));
  check('returning restores transcript and accepted proposal state',await script(`return document.querySelector('#bot-transcript').textContent.includes('Please create a workspace') && document.querySelector('.bot-proposal button').disabled && document.querySelector('.bot-proposal').textContent.includes('Request accepted')`));
  await screenshot('super-bots');
  await type('#bot-message','Trigger provider error');
  await click('#bot-send');
  await until(() => script(`return document.querySelector('#bot-status').textContent.includes('HTTP 503')`));
  check('provider failure is visible and preserves the message for retry', await script(`return document.querySelector('#bot-message').value === 'Trigger provider error' && !document.querySelector('#bot-send').disabled`));
  const savedConversation = await script(`return document.querySelector('#bot-history').value`);
  await click('#bot-new');
  check('new conversation clears messages and proposals', await script(`return document.querySelector('#bot-transcript').children.length === 0`));
  await click('#bot-manage');
  check('provider settings opens visibly', await script(`const d=document.querySelector('.bot-settings');return d.open && d.querySelector('form').getBoundingClientRect().height > 0`));
  await click('.bot-settings summary');
  check('provider settings closes', await script(`return !document.querySelector('.bot-settings').open`));
  await click('.bot-settings summary');
  await script(`const n=document.getElementById('bot-provider');n.value='openai';n.dispatchEvent(new Event('change',{bubbles:true}));`);
  check('provider switch disables send until configured and clears the key input', await script(`return document.querySelector('#bot-send').disabled && document.querySelector('#bot-api-key').value === '' && document.querySelector('#bot-model').value === ''`));

  check('manual cloud-key management saves securely by default and exposes a forget control', await script(`return document.querySelector('#bot-remember-key').checked && document.querySelector('#bot-remember-key').getBoundingClientRect().height > 0 && !document.querySelector('#bot-forget-key').hidden`));

  await wd('POST', `/session/${session}/actions`, {actions: [{type: 'key', id: 'keyboard', actions: [
    {type: 'keyDown', value: '\uE009'}, {type: 'keyDown', value: 'k'},
    {type: 'keyUp', value: 'k'}, {type: 'keyUp', value: '\uE009'}]}]});
  check('keyboard shortcut opens the page finder', await script('return document.querySelector("dialog").open'));
  await wd('POST', `/session/${session}/actions`, {actions: [{type: 'key', id: 'keyboard', actions: [
    {type: 'keyDown', value: '\uE00C'}, {type: 'keyUp', value: '\uE00C'}]}]});
  await until(()=>script('return !document.querySelector("#navigation-dialog").open'),3000);
  check('Escape closes the page finder', await script('return !document.querySelector("#navigation-dialog").open'));
  await click('[data-rail-mode=bots]');
  await click('#rail-bots [data-nav="bot:assistant"]');
  await script(`const p=document.querySelector('#bot-provider');p.value='ollama';p.dispatchEvent(new Event('change'));`);
  await until(()=>script(`return !document.querySelector('#bot-send').disabled`));
  await script(`const p=document.querySelector('#bot-history');p.value=arguments[0];p.dispatchEvent(new Event('change'));`,[savedConversation]);
  check('saved conversation restores failed draft and read-only proposal history', await script(`return document.querySelector('#bot-message').value==='Trigger provider error' && document.querySelector('#bot-transcript').textContent.includes('Please create a workspace') && document.querySelector('.bot-proposal') && !document.querySelector('.bot-proposal button')`));
  await script(`document.querySelector('#bot-message').value='Continue after reopening';document.querySelector('#bot-message').dispatchEvent(new Event('input')); const t=new DataTransfer();t.items.add(new File(['Next project material'],'next.md',{type:'text/plain'}));const i=document.querySelector('#bot-attachments');i.files=t.files;i.dispatchEvent(new Event('change'));`);
  await until(()=>script(`return document.querySelector('#bot-attachment-list').textContent.includes('next.md')`));
  const callsBeforeReopen=chatCalls;
  await wd('DELETE', `/session/${session}`); session=null;
  const reopened=await wd('POST','/session',{capabilities:{alwaysMatch:{'tauri:options':{application:`${root}/cockpit/target/release/super-cockpit`}}}});session=reopened.sessionId;
  await until(()=>script(`return window.cockpit?.frame?.state==='live-local'`));
  await click('[data-rail-mode=bots]');
  await click('#rail-bots [data-nav="bot:assistant"]');
  await until(()=>script(`return !document.querySelector('#bot-send').disabled`));
  check('app restart restores provider model conversation draft and staged file',await script(`return document.querySelector('#bot-provider').value==='ollama' && document.querySelector('#bot-model-picker').value==='fixture-model' && document.querySelector('#bot-message').value==='Continue after reopening' && document.querySelector('#bot-attachment-list').textContent.includes('next.md') && document.querySelector('#bot-transcript').textContent.includes('Please create a workspace')`));
  check('created bot roster survives restart',await script(`return [...document.querySelectorAll('#bot-roster-links button')].some(b=>b.textContent.includes('Super Builder'))`));
  check('sidebar widths survive an app restart',await script(`const p=JSON.parse(localStorage.getItem('super.desktop.layout'));return p.left===228 && p.right>=290 && document.querySelector('#rail-resizer').getAttribute('aria-valuenow')==='228'`));
  if(process.env.SUPER_VISUAL_EVIDENCE_DIR)await script(`document.querySelector(arguments[0])?.scrollIntoView({block:'center'})`,[".bot-proposal"]);check('reopening neither sends messages nor restores action buttons',chatCalls===callsBeforeReopen && await script(`return !document.querySelector('.bot-proposal button')`));
  await screenshot('super-restored-conversation');
  await click('#bot-send');
  await until(()=>script(`return !!document.querySelector('.bot-proposal button') && !document.querySelector('#bot-send').disabled`));
  check('continued request includes earlier and newly attached project material',lastBotRequest.messages.some(m=>m.content.includes('Attachment sent only on Send')) && lastBotRequest.messages.at(-1).content.includes('Next project material'));
  await click('[data-rail-mode=nav]');await click('#app-navigation [data-nav=positions]');
  await click('[data-screen=positions] [data-nav=new-workspace]');
  await type('[data-draft=workspace_name]','Disposable workspace');await click('[data-id=open-workspace] button');
  const deleteId=await until(()=>script(`return Object.values(window.cockpit.frame.projection.workspaces).find(w=>w.name==='Disposable workspace')?.id`));
  await until(()=>script(`return !document.querySelector('[data-screen=record]').hidden && document.querySelector('[data-screen=record] h1').textContent==='Disposable workspace'`));
  await click(`[data-screen=record] .workspace-delete`);
  check('workspace deletion requires a separate confirmation',await script(`return document.querySelector('#delete-workspace-dialog').open && !!window.cockpit.frame.projection.workspaces[arguments[0]]`,[deleteId]));
  await click('#delete-workspace-dialog [data-confirm-workspace-delete]');
  await until(()=>script(`return !window.cockpit.frame.projection.workspaces[arguments[0]]`,[deleteId]));
  check('confirmed deletion is reflected in a new runtime frame',true);
  if(process.env.APP_SMOKE_SKIP_RESIZE!=='1'){
  await wd('POST', `/session/${session}/window/rect`, { width: 620, height: 800 });
  await until(() => script('return window.innerWidth <= 650'),10000).catch(async error=>{console.error('Resize diagnostics',await wd('GET',`/session/${session}/window/rect`),await script('return {innerWidth,outerWidth,devicePixelRatio,screenWidth:screen.width}'));throw error;});
  await click('[data-rail-mode=nav]');
  await click('#app-navigation [data-nav=mission]');
  check('navigation works in the narrow layout', await script('return !document.querySelector("[data-screen=mission]").hidden'));
  check('narrow layout has no page overflow', await script('return document.documentElement.scrollWidth <= window.innerWidth + 1'));
  await screenshot('super-narrow');
  }
  check('projection loss removes every sidebar count and chart',await script(`const f=window.cockpit.frame;window.cockpit.render({...f,projection:null});const cleared=[...document.querySelectorAll('[data-nav-count]')].every(n=>n.hidden&&!n.textContent)&&!document.querySelector('#world .frame-chart');window.cockpit.render(f);return cleared;`));
 evidence.complete();
  console.log(`app smoke: ${checks} held`);
} catch (e) { console.error(log); throw e; }
finally {evidence.close();
  botFixture.close();
  if (session) { try { await wd('DELETE', `/session/${session}`); } catch {} }
  try { process.kill(-driver.pid, 'SIGTERM'); } catch {}
  await sleep(1000);
  try { process.kill(-driver.pid, 'SIGKILL'); } catch {}
}
