#!/usr/bin/env node
/* reference-text-smoke — every record id on screen is a reference, on every screen.
   ────────────────────────────────────────────────────────────────────────

   THE GAP THIS PINS (2026-09-18)

     "there are many areas of plain text where the id of a record is being
     displayed without the hyperlink or tooltip thing we built earlier." Two
     causes: the id pattern knew six prefixes (no dt_/da_), and app-shell.js's
     node() linked <p> only. tools/check-reference-text.mjs holds the source to
     the rule; this walks the running cockpit and holds the SCREEN to it.

   WHAT IT DOES

     Real cockpit, throwaway world (SUPER_COCKPIT_CARRIER=1 seeds a workspace,
     goal, lane, worker and repository; the smoke registers a bot, opens a lane
     for it and creates a plan — the palette smoke's shape). Then it visits
     every [data-nav] screen, every record page kind, the plan detail in every
     wizard step and with every section shown, the palette results and the
     rails, and on each one asserts: no text node matches the id pattern unless
     it is inside [data-record-ref]; no reference link sits inside a button,
     summary, label or link. It then clicks a plan reference (opens the plan),
     a repository reference and a workspace reference (open their record pages),
     and checks a reference inside a button is a tooltip span.

     Not covered: a review attempt reference. Recording an attempt needs the
     Editor's file-proposal flow, which this world does not run; the routing is
     unit-tested in tools/references-test.mjs and shares the plan route.

     node tools/reference-text-smoke.mjs                                    */
import {open} from './lib/cockpit-control.mjs';

process.env.SUPER_COCKPIT_CARRIER = '1';
process.env.GDK_BACKEND ??= 'x11';

let held = 0, failed = 0;
const check = (what, ok, detail = '') => { console.log(`  ${ok ? '\x1b[32mheld\x1b[0m' : '\x1b[31mFAILED\x1b[0m'}  ${what}${detail ? ' — ' + detail : ''}`); ok ? held++ : failed++; };
const q = s => JSON.stringify(s);
const TITLE = 'Reference smoke plan';

console.log('\nreference-text (every id on screen is a reference)\n');
let c;
try {
  c = await open();
  const lane0 = await c.until(async () => (await c.list('lanes'))[0], 60_000, 'a lane in the fixture world');
  const ws = (await c.list('workspaces'))[0], repo = (await c.list('repositories'))[0], goal = (await c.list('goals'))[0], worker = (await c.list('workers'))[0];
  const bot = (await c.create('register_bot', {client_ref: 'reference-smoke-bot', workspace_ref: ws.id, name: 'Reference smoke bot', role: 'Reviewer', group: 'Smoke', provider: 'ollama', instructions: 'Holds the smoke lane.'}, {kind: 'bots', field: 'name', value: 'Reference smoke bot'})).record;
  await c.intent('open_lane', {goal_ref: goal.id, actor: bot.actor, repository_ref: repo.ref});
  const lane = await c.until(async () => (await c.list('lanes')).find(l => l.actor === bot.actor), 20_000, 'a lane held by the smoke bot');
  const plan = (await c.create('create_development_task', {client_ref: 'reference-smoke', lane_ref: lane.id, title: TITLE, criteria: `Every id is a reference, including this plan's own id and ${repo.ref}.`, required_checks: {profiles: ['super-javascript-behavior@1']}}, {kind: 'development_tasks', field: 'title', value: TITLE})).record;
  check('the world holds a workspace, goal, lane, worker, repository, bot and plan', !!ws && !!goal && !!lane0 && !!worker && !!repo && !!bot && /^dt_\d+$/.test(plan.id), `${ws?.id} ${goal?.id} ${lane?.id} ${worker?.id} ${repo?.ref} ${bot?.id} ${plan?.id}`);

  // the page's own modules: the pattern the renderer derives, and the shell's openRecord
  await c.page(`import('./references.js').then(m=>{window.__refs=m;window.__refPattern=m.referencePattern().source;});import('./app-shell.js').then(m=>{window.__shell=m;});`);
  await c.until(() => c.page(`return !!(window.__refs&&window.__shell)`), 10_000, 'page modules');
  await c.page(`
    window.__scan=function(sel){const out=[];for(const root of document.querySelectorAll(sel)){const pat=new RegExp(window.__refPattern,'g');const w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);let n;
      while(n=w.nextNode()){const el=n.parentElement;if(!el)continue;if(el.closest('pre,code,textarea,script,style,option,[data-record-ref]'))continue;if(el.closest('[hidden]'))continue;const d=el.closest('dialog');if(d&&!d.open)continue;
        const found=n.textContent.match(pat);if(found)out.push({ids:[...new Set(found)].join(','),where:el.tagName.toLowerCase()+(el.id?'#'+el.id:'')+(el.className?'.'+String(el.className).split(' ')[0]:''),text:n.textContent.trim().slice(0,70)});}}
      return JSON.stringify(out);};
    window.__nested=sel=>[...document.querySelectorAll(sel)].reduce((n,r)=>n+r.querySelectorAll('button a[data-record-ref],summary a[data-record-ref],label a[data-record-ref],a a[data-record-ref]').length,0);
    window.__refCount=sel=>[...document.querySelectorAll(sel)].reduce((n,r)=>n+r.querySelectorAll('[data-record-ref]').length,0);`);
  const scan = async (name, sel) => {
    const plain = JSON.parse(await c.page(`return window.__scan(${q(sel)})`)), nested = await c.page(`return window.__nested(${q(sel)})`), refs = await c.page(`return window.__refCount(${q(sel)})`);
    check(`${name}: no plain id, no link inside a control`, plain.length === 0 && nested === 0, plain.length ? plain.slice(0, 3).map(p => `${p.ids} in ${p.where} "${p.text}"`).join(' | ') : nested ? `${nested} nested` : `${refs} references`);
  };
  const visible = () => c.page(`return document.querySelector('[data-screen]:not([hidden])')?.dataset.screen ?? null`);

  // 1. the rails
  await scan('rails', '#app-navigation,#rail-bots,#rail-runtime');

  // 2. every navigable screen
  const navs = JSON.parse(await c.page(`return JSON.stringify([...document.querySelectorAll('#app-navigation [data-nav],#rail-bots [data-nav],#rail-runtime [data-nav]')].map(b=>b.dataset.nav).filter((v,i,a)=>a.indexOf(v)===i))`));
  check('the rails list the screens to walk', navs.length >= 20, `${navs.length} screens`);
  for (const id of navs) {
    await c.page(`document.querySelector('[data-nav=${q(id)}]').click()`);
    const shown = await c.until(async () => (await visible()) === id ? id : (id.startsWith('bot:') && (await visible())?.startsWith('bot') ? await visible() : null), 10_000, `screen ${id}`).catch(() => null);
    if (!shown) { check(`screen ${id} opens`, false); continue; }
    await scan(`screen ${id}`, '[data-screen]:not([hidden])');
  }

  // 3. every record page kind
  const pages = [['Workspace', ws.id], ['Goal', goal.id], ['Lane', lane.id], ['Worker', worker?.id], ['Bot', bot.id], ['Repository', repo.ref]];
  for (const [kind, id] of pages) {
    if (!id) { check(`a ${kind} record page`, false, 'no record in the world'); continue; }
    await c.page(`const r=window.__refs.reference(${q(id)});if(r)window.__shell.openRecord(r.key);`);
    const key = await c.until(() => c.page(`const p=document.querySelector('[data-screen=record]:not([hidden])');return p&&p.dataset.recordKey&&p.dataset.recordKey.endsWith(${q(id)})?p.dataset.recordKey:null`), 10_000, `${kind} record page`).catch(() => null);
    if (!key) { check(`${kind} record page opens by reference key`, false, id); continue; }
    await scan(`${kind} record page (${id})`, '[data-screen=record]:not([hidden])');
    const header = await c.page(`const s=document.querySelector('[data-screen=record]:not([hidden]) .record-id [data-record-ref]');return s?s.dataset.recordRef+' '+s.tagName+' '+s.title:null`);
    check(`${kind} header id is a reference with a tooltip`, header?.startsWith(`${id} A ${kind}:`), header);
  }
  // a reference inside a record-row button is a tooltip span, not a link
  await c.page(`window.__shell.openRecord(window.__refs.reference(${q(ws.id)}).key)`);
  await c.until(() => c.page(`return document.querySelector('[data-screen=record]:not([hidden])')?.dataset.recordKey?.endsWith(${q(ws.id)})`), 10_000, 'workspace page');
  const inButton = await c.page(`const b=[...document.querySelectorAll('[data-screen=record]:not([hidden]) button.record-trigger')].find(b=>b.querySelector('[data-record-ref=${q(lane.id)}]'));const r=b?.querySelector('[data-record-ref=${q(lane.id)}]');return r?r.tagName+' '+r.className+' '+r.title+' | links:'+b.querySelectorAll('a').length:null`);
  check('a lane id inside a related-work button is a tooltip span and the button holds no link', inButton?.startsWith('SPAN record-ref Lane:') && inButton.endsWith('links:0'), inButton);

  // 4. the plan detail, every wizard step and every section
  await c.page(`document.querySelector('[data-rail-mode=nav]')?.click(); document.querySelector('#app-navigation [data-nav=development-tasks]').click();`);
  await c.until(() => c.page(`return !!document.querySelector('[data-development-task=${q(plan.id)}]')`), 15_000, 'plan listed');
  await c.page(`document.querySelector('[data-development-task=${q(plan.id)}]').click()`);
  await c.until(() => c.page(`return !!document.querySelector('#task-steps')`), 15_000, 'stepper');
  const meta = await c.page(`const a=document.querySelector('#development-task-detail .plan-head a[data-record-ref=${q(plan.id)}]');return a?a.textContent+' | '+a.title:null`);
  check('the plan meta line shows the id as a link whose tooltip is the title', meta === `${plan.id} | Development plan: ${TITLE} — open current record`, meta);
  const steps = JSON.parse(await c.page(`return JSON.stringify([...document.querySelectorAll('#task-steps li')].filter(l=>!l.querySelector('button').disabled).map(l=>l.dataset.step))`));
  for (const step of steps) { await c.page(`document.querySelector('#task-steps [data-step=${q(step)}] button').click()`); await scan(`plan detail · step ${step}`, '#development-task-detail'); }
  await c.page(`const b=document.querySelector('#task-wizard-all');if(!b.checked)b.click();`);
  check('every section is shown', await c.page(`return document.querySelector('#development-task-detail').dataset.wizardStep==='all'`));
  await scan('plan detail · every section', '#development-task-detail');
  const criteria = await c.page(`const a=document.querySelector('[data-plan-panel=brief] a[data-record-ref=${q(repo.ref)}]');return a?a.textContent:null`);
  check('a repository id in the plan criteria is a link showing the repository name', criteria === repo.name || criteria === repo.ref, criteria);

  // 5. the palette
  await c.page(`document.querySelector('#open-navigation').click()`);
  await c.until(() => c.page(`return document.querySelector('#navigation-dialog').open`), 10_000, 'palette open');
  const type = async text => { await c.page(`const s=document.querySelector('#navigation-search'); s.value=${q(text)}; s.dispatchEvent(new Event('input',{bubbles:true}));`); };
  await type(plan.id);
  const row = await c.until(() => c.page(`const b=[...document.querySelectorAll('#navigation-results .palette-result')].find(b=>b.dataset.recordId===${q(plan.id)});const r=b?.querySelector('[data-record-ref]');return r?r.tagName+' '+r.className+' '+r.textContent+' | '+r.title+' | links:'+b.querySelectorAll('a').length:null`), 10_000, 'palette row');
  check('a palette result keeps the id visible as a tooltip span, with no link inside the button', row === `SPAN record-ref ${plan.id} | Development plan: ${TITLE} | links:0`, row);
  await scan('palette results (plan)', '#navigation-results');
  await type(repo.ref);
  await c.until(() => c.page(`return !!document.querySelector('#navigation-results .palette-result[data-record-kind="Repository"] [data-record-ref=${q(repo.ref)}]')`), 10_000, 'repository row');
  await scan('palette results (repository)', '#navigation-results');
  await c.page(`document.querySelector('#close-navigation').click()`);
  await c.until(() => c.page(`return !document.querySelector('#navigation-dialog').open`), 10_000, 'palette closed');

  // 6. clicking references
  await c.page(`window.__shell.openRecord(window.__refs.reference(${q(repo.ref)}).key)`);
  await c.until(() => c.page(`return document.querySelector('[data-screen=record]:not([hidden])')?.dataset.recordKey?.endsWith(${q(repo.ref)})`), 10_000, 'repository page');
  const planLink = await c.page(`const a=document.querySelector('[data-screen=record]:not([hidden]) .plan-row a[data-record-ref=${q(plan.id)}]');return a?a.textContent:null`);
  check('the repository page lists the plan with its id as a link', planLink === plan.id, planLink);
  await c.page(`document.querySelector('[data-screen=record]:not([hidden]) .plan-row a[data-record-ref=${q(plan.id)}]').click()`);
  const opened = await c.until(() => c.page(`return document.querySelector('[data-screen=development-tasks]:not([hidden])')&&document.querySelector('#development-task-detail .plan-head h2')?.textContent===${q(TITLE)}?'plan':null`), 10_000, 'plan opened from its reference').catch(() => null);
  check('clicking a plan reference opens that plan in the wizard', opened === 'plan');
  await c.page(`window.__shell.openRecord(window.__refs.reference(${q(lane.id)}).key)`);
  await c.until(() => c.page(`return document.querySelector('[data-screen=record]:not([hidden])')?.dataset.recordKey?.endsWith(${q(lane.id)})`), 10_000, 'lane page');
  const repoLink = await c.page(`const a=document.querySelector('[data-screen=record]:not([hidden]) [data-field-key=repository_ref] a[data-record-ref=${q(repo.ref)}]');return a?a.textContent:null`);
  check('the lane page shows its repository as a link with the repository name', repoLink === (repo.name || repo.ref), repoLink);
  await c.page(`document.querySelector('[data-screen=record]:not([hidden]) [data-field-key=repository_ref] a[data-record-ref=${q(repo.ref)}]').click()`);
  const repoKey = await c.until(() => c.page(`const k=document.querySelector('[data-screen=record]:not([hidden])')?.dataset.recordKey;return k&&k.endsWith(${q(repo.ref)})?k:null`), 10_000, 'repository page from reference').catch(() => null);
  check('clicking a repository reference opens its record page', !!repoKey, repoKey);
  await c.page(`window.__shell.openRecord(window.__refs.reference(${q(goal.id)}).key)`);
  await c.until(() => c.page(`return document.querySelector('[data-screen=record]:not([hidden])')?.dataset.recordKey?.endsWith(${q(goal.id)})`), 10_000, 'goal page');
  await c.page(`document.querySelector('[data-screen=record]:not([hidden]) [data-field-key=workspace_ref] a[data-record-ref=${q(ws.id)}]').click()`);
  const wsKey = await c.until(() => c.page(`const k=document.querySelector('[data-screen=record]:not([hidden])')?.dataset.recordKey;return k&&k.endsWith(${q(ws.id)})?k:null`), 10_000, 'workspace page from reference').catch(() => null);
  check('clicking a workspace reference on the goal page opens the workspace', !!wsKey, wsKey);
} catch (e) { check('the smoke ran to completion', false, String(e).slice(0, 400)); }
finally { if (c) { try { await c.close(); } catch {} } }
console.log(`\nreference-text: ${held} held · ${failed} failed\n`);
process.exit(failed ? 1 : 0);
