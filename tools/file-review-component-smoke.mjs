import {visualEvidence} from './visual-evidence.mjs';
// Component test with fixture callbacks; does not prove repository or provider integration.
/* Product-flow checks in an isolated world. No faults or runtime resets. */
import { spawn, execFileSync as run } from 'node:child_process';
import { mkdirSync, writeFileSync, mkdtempSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const port = Number(process.env.APP_SMOKE_PORT ?? 4464);
const base = `http://127.0.0.1:${port}`;
const shots = process.env.APP_SMOKE_SCREENSHOTS;
const testData=mkdtempSync((process.env.DEVELOPMENT_TEST_ROOT??'/tmp')+'/super-app-smoke-');
const testRoot=process.env.DEVELOPMENT_TEST_ROOT;if(!testRoot)throw Error('Set DEVELOPMENT_TEST_ROOT to a disposable folder visible to the native chooser.');
const driver = spawn('tauri-driver', ['--port', String(port), '--native-port', String(port + 1), '--native-driver', '/usr/bin/WebKitWebDriver'], {
  cwd:root, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
  env: { ...process.env, XDG_DATA_HOME:testData, AMPD_DIR: `${root}/ampd`, SUPER_WORLD_MODE: 'ephemeral', SUPER_COCKPIT_FIXTURE: '1', SUPER_COCKPIT_CARRIER: '0', SUPER_COCKPIT_PANE: '0', WEBKIT_DISABLE_COMPOSITING_MODE: '1' },
});
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
const evidence=visualEvidence('file-review-component-smoke',root,driver,["review actions are visible without scrolling", "plan revision changing during review blocks staging", "repository verification failure preserves the draft"]);
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

  await script(`return import('./file-proposal-review.js').then(({reviewFileProposal})=>{
   const reference={session:'test',generation:1,key:'index.html',draft:'<h1>Before task</h1>\\n',task:{id:'dt_review_fixture',revision:2,world:'test-world'}};
   const state={session:'test',generation:1,file:{path:'index.html',draft:reference.draft},task:{id:'dt_review_fixture',revision:2,status:'planned'},world:'test-world'};
   const el=(tag,text,cls)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(cls)e.className=cls;return e;};
   const button=(text,id,fn)=>{const b=el('button',text);b.id=id;b.onclick=fn;return b;};
   window.reviewFixture={state,staged:null,open:()=>reviewFileProposal({reference,proposal:{path:'index.html',content:'<h1>After task</h1>\\n'},current:()=>state,verify:async()=>{if(window.reviewFixture.fail)throw Error("Repository mismatch fixture");if(window.reviewFixture.wait)await new Promise(resolve=>window.reviewFixture.resolve=resolve)},stage:text=>window.reviewFixture.staged=text,navigate:()=>{},el,button})};window.reviewFixture.open();
  })`);
  check('native review renders added and removed lines',await script(`return !!document.querySelector('#proposal-diff .added')&&!!document.querySelector('#proposal-diff .removed')`));
  check('review labels plan revision and required repository check',await script(`return document.querySelector('#bot-file-review').textContent.includes('revision 2')&&document.querySelector('#bot-file-review').textContent.includes('checked against this plan')`));
  check('review actions are visible without scrolling',await script(`const r=document.querySelector('#bot-file-use-draft').getBoundingClientRect();return r.top>=0&&r.bottom<=innerHeight`));
  await click('#bot-file-cancel');check('Cancel leaves the fixture draft unstaged',await script(`return !document.querySelector('#bot-file-review')&&window.reviewFixture.staged===null`));
  await script('window.reviewFixture.open();window.reviewFixture.state.task.revision=3');await click('#bot-file-use-draft');
  check('plan revision changing during review blocks staging',await script(`return window.reviewFixture.staged===null&&document.querySelector('#bot-file-review').textContent.includes('plan changed')`));
  await click('#bot-file-cancel');await script('window.reviewFixture.state.task.revision=2;window.reviewFixture.open()');
  await script('window.reviewFixture.fail=true');await click('#bot-file-use-draft');
  check('repository verification failure preserves the draft',await script(`return window.reviewFixture.staged===null&&document.querySelector('#bot-file-review').textContent.includes('Repository mismatch fixture')`));
  await script('window.reviewFixture.fail=false;window.reviewFixture.wait=true');await click('#bot-file-use-draft');await click('#bot-file-cancel');await script('window.reviewFixture.resolve()');
  check('Cancel during repository verification cannot stage later',await script(`return !document.querySelector('#bot-file-review')&&window.reviewFixture.staged===null`));
  await script('window.reviewFixture.wait=false;window.reviewFixture.open()');
  run('/usr/bin/python3',[`${root}/tools/development-capture-window.py`,String(driver.pid),testRoot+'/review-component.png']);
  await click('#bot-file-use-draft');check('current plan stages the proposed draft',await script(`return !document.querySelector('#bot-file-review')&&window.reviewFixture.staged.includes('After task')`));
  await script(`return import('./file-proposal-review.js').then(({reviewFileProposal})=>{
    const f=window.reviewFixture;f.staged=null;f.recordCalls=0;
    const reference={session:'test',generation:1,key:'index.html',draft:f.state.file.draft,task:{id:'dt_review_fixture',revision:2,world:'test-world'},source:{head:'fixture-commit'}};
    const el=(tag,text,cls)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(cls)e.className=cls;return e;};
    const button=(text,id,fn)=>{const b=el('button',text);b.id=id;b.onclick=fn;return b;};
    f.openRecord=()=>reviewFileProposal({reference,proposal:{path:'index.html',content:'after record'},current:()=>f.state,verify:async()=>{if(f.waitSource)await new Promise(resolve=>f.releaseSource=resolve);return {head:'fixture-commit'};},recordAttempt:async()=>{if(f.recordFailure)throw Error('Record was refused fixture');f.recordCalls++;return 'da_fixture';},stage:text=>f.staged=text,navigate:()=>{},el,button});f.openRecord();
  })`);
  await until(()=>script(`return !document.querySelector('#bot-file-record-attempt').disabled`));await script('window.reviewFixture.recordFailure=true');await click('#bot-file-record-attempt');
  await until(()=>script(`return document.querySelector('#bot-file-review').textContent.includes('Record was refused fixture')`));
  check('failed review recording preserves the draft and allows retry',await script(`return window.reviewFixture.staged===null&&window.reviewFixture.recordCalls===0&&!document.querySelector('#bot-file-record-attempt').disabled`));evidence.capture('Review record refusal preserves draft and permits retry - fixture');
  await script('window.reviewFixture.recordFailure=false;window.reviewFixture.waitSource=true');await click('#bot-file-record-attempt');await click('#bot-file-cancel');await script('window.reviewFixture.releaseSource()');
  check('Cancel before source verification finishes prevents recording',await script(`return window.reviewFixture.recordCalls===0&&window.reviewFixture.staged===null&&!document.querySelector('#bot-file-review')`));
  await script('window.reviewFixture.waitSource=false;window.reviewFixture.openRecord()');await until(()=>script(`return !document.querySelector('#bot-file-record-attempt').disabled`));await click('#bot-file-record-attempt');
  await until(()=>script(`return document.querySelector('#bot-file-record-attempt').textContent==='Review attempt saved'`));
  check('successful record is separate from staging and disables duplicate clicks',await script(`return window.reviewFixture.recordCalls===1&&window.reviewFixture.staged===null&&document.querySelector('#bot-file-record-attempt').disabled`));
 evidence.complete();
  console.log(`native review component: ${checks} held (fixture callbacks; no repository or provider integration)`);
}finally{evidence.close();if(session)try{await wd('DELETE',`/session/${session}`);}catch{}try{process.kill(-driver.pid,'SIGTERM');}catch{}}
