/* A reply belongs to the conversation it was sent from.
 *
 * The acceptance evidence for background navigation, written to the spec the
 * proposal asked for: send a message, navigate away, let the reply land,
 * reopen the originating conversation and find the assistant turn there with
 * the user message above it and no duplicate bubble, then send from the new
 * conversation and find the slot released.
 *
 * ONE generation slot is deliberate and is asserted here too: sending while a
 * turn is in flight must still be refused, and the refusal must NAME the
 * conversation holding it rather than saying "wait". A request id on a
 * singleton is not concurrency; nothing in this file should be read as
 * evidence that two replies can run at once, because they cannot.
 *
 * The fixture provider holds its reply open until released, so "while a reply
 * is in flight" is a real in-flight reply and not a simulated flag.
 */
import {open} from './lib/cockpit-control.mjs';
import assert from 'node:assert/strict';
import {mkdirSync, writeFileSync} from 'node:fs';
import http from 'node:http';

const out = process.env.SUPER_VISUAL_EVIDENCE_DIR || '/tmp/super-background-reply-evidence';
mkdirSync(out, {recursive: true});
const checks = [];
const check = (name, value) => { assert.ok(value, name); checks.push(name); };

let app, holding = false, release = null, arrived = null;
const server = http.createServer(async (req, res) => {
  let body = ''; for await (const b of req) body += b;
  res.setHeader('content-type', 'application/json');
  if (req.url === '/api/tags') return res.end(JSON.stringify({models: [{name: 'fixture'}]}));
  if (holding) { holding = false; arrived.resolve(); await new Promise(r => { release = r; }); }
  res.end(JSON.stringify({message: {content: 'The background reply.', tool_calls: []}}));
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const endpoint = `http://127.0.0.1:${server.address().port}`;

try {
  app = await open({port: 4645});
  const page = (c, a = []) => app.page(c, a);
  const wait = (fn, what) => app.until(fn, 20000, what);
  const shot = async n => {
    const r = await fetch(`http://127.0.0.1:4645/session/${app.session()}/screenshot`);
    writeFileSync(`${out}/${n}.png`, Buffer.from((await r.json()).value, 'base64'));
  };
  const store = id => `const s=createConversationStore({getItem:k=>localStorage.getItem(${JSON.stringify(id)}==='assistant'?k:k+':bot:'+${JSON.stringify(id)}),setItem:(k,v)=>localStorage.setItem(${JSON.stringify(id)}==='assistant'?k:k+':bot:'+${JSON.stringify(id)},v)});`;

  // --- seed: two bots, one saved chat each, both on the fixture provider ----
  const seeded = await page(`
    const {createBotRoster}=await import('./bot-roster.js');
    const {createConversationStore}=await import('./conversation-store.js');
    createBotRoster(localStorage).save({id:'second',name:'Second Bot',role:'Other work',group:'General',instructions:'',provider:'ollama'});
    const mk=(id,title,draft)=>{const s=createConversationStore({getItem:k=>localStorage.getItem(id==='assistant'?k:k+':bot:'+id),setItem:(k,v)=>localStorage.setItem(id==='assistant'?k:k+':bot:'+id,v)});
      return s.save('ollama',null,{messages:[{role:'user',content:title}],entries:[{role:'user',label:'You',text:title}],draft,files:[],includeContext:true});};
    localStorage.setItem('super-last-provider','ollama');localStorage.setItem('super-last-provider:bot:second','ollama');
    const a=mk('assistant','Origin chat','');
    const b=mk('second','Other chat','a draft that must survive');
    window.__bgReload=true;location.reload();
    return {a,b};`);
  await wait(() => page(`return window.__bgReload!==true&&!!document.querySelector('[data-nav="bot:second"]')`), 'reloaded');

  // connect the fixture provider on the assistant
  await page(`document.querySelector('#rail-bots [data-nav="bot:assistant"]').click()`);
  await wait(() => page(`return !!document.querySelector('#bot-provider')`), 'bot surface');
  await page(`document.querySelector('#bot-tab-settings').click();document.querySelector('#bot-endpoint').value='${endpoint}';document.querySelector('#bot-model').value='fixture';document.querySelector('#bot-connect').click();`);
  await wait(() => page(`return !document.querySelector('#bot-send').disabled`), 'fixture connected');

  // --- send in A, and hold the reply open ----------------------------------
  arrived = {}; arrived.promise = new Promise(r => { arrived.resolve = r; }); holding = true;
  // Opening a bot from the rail scopes the list to it, by design. Browsing
  // every conversation is the explicit choice this test needs, so make it.
  await page(`document.querySelector('#bot-tab-conversation').click();
    const s=document.querySelector('.conversation-controls select[aria-label="Filter by bot"]');
    s.value='all';s.dispatchEvent(new Event('change'));`);
  await wait(() => page(`return [...document.querySelectorAll('.conversation-link')].length>=2`), 'both conversations listed');
  await page(`[...document.querySelectorAll('.conversation-link')].find(n=>n.dataset.conversation==='${seeded.a}').click();`);
  await wait(() => page(`return document.querySelector('.conversation-link[aria-current="page"]')?.dataset.conversation==='${seeded.a}'`), 'origin chat open');
  await page(`const m=document.querySelector('#bot-message');m.value='Answer in the background';m.dispatchEvent(new Event('input'));document.querySelector('.bot-composer').requestSubmit();`);
  await arrived.promise;
  await wait(() => page(`return document.querySelector('#bot-send').disabled`), 'a reply in flight');

  // --- 1. navigation is open while it runs ---------------------------------
  check('every conversation row stays clickable while a reply is in flight',
    await page(`return [...document.querySelectorAll('.conversation-link')].every(n=>!n.disabled)`));
  await page(`[...document.querySelectorAll('.conversation-link')].find(n=>n.dataset.conversation==='${seeded.b}').click()`);
  await wait(() => page(`return document.querySelector('#bot-surface').dataset.screen==='bot:second'`), 'navigated to the other bot mid-reply');
  check('navigating to another bot mid-reply actually opens it', true);
  check('the other conversation keeps its own draft',
    await page(`return document.querySelector('#bot-message').value==='a draft that must survive'`));

  // --- 2. the generating indicator follows the conversation, not the view ---
  check('the originating chat still shows it is generating, from another bot’s page',
    await page(`const r=[...document.querySelectorAll('.conversation-link')].find(n=>n.dataset.conversation==='${seeded.a}');
      return !!r&&/Generating|Waiting/.test(r.querySelector('.conversation-state').textContent);`));
  check('and it still shows it when the list is filtered to the other bot',
    await page(`const s=document.querySelector('.conversation-controls select[aria-label="Filter by bot"]');
      s.value='second';s.dispatchEvent(new Event('change'));
      const d=document.querySelector('.conversation-directory');
      const rows=[...document.querySelectorAll('.conversation-link')].map(n=>n.dataset.conversation);
      return !rows.includes('${seeded.a}')&&/generating|Generating/.test(document.querySelector('.conversation-sidebar').textContent);`));
  await shot('01-generating-elsewhere');

  // --- 3. one slot: sending is refused, and the refusal names the holder ----
  await page(`const m=document.querySelector('#bot-message');m.value='should not send';m.dispatchEvent(new Event('input'));document.querySelector('.bot-composer').requestSubmit();`);
  await new Promise(r => setTimeout(r, 600));
  check('sending from another conversation is refused while the slot is held',
    await page(`const t=document.querySelector('#bot-status').textContent;return /still generating|Origin chat/.test(t);`));
  check('and the refusal names the conversation holding it rather than saying "wait"',
    await page(`return document.querySelector('#bot-status').textContent.includes('Origin chat')`));

  // --- 4. the reply lands in ITS OWN conversation ---------------------------
  release();
  await wait(() => page(`return [...document.querySelectorAll('.conversation-link')].every(n=>!/Generating|Waiting/.test(n.querySelector('.conversation-state').textContent))`), 'the reply to land');
  check('the reply was written to the conversation that sent it, not the one on screen',
    await page(`const {createConversationStore}=await import('./conversation-store.js');${store('assistant')}
      const d=s.get('ollama','${seeded.a}');
      return d.entries.some(e=>e.role==='assistant'&&e.text.includes('The background reply.'));`));
  check('the conversation that was open was not written into',
    await page(`const {createConversationStore}=await import('./conversation-store.js');${store('second')}
      const d=s.get('ollama','${seeded.b}');
      return !d.entries.some(e=>e.text.includes('The background reply.'))&&d.draft==='should not send';`));

  // --- 5. reopening the origin shows one clean exchange ---------------------
  await page(`const s=document.querySelector('.conversation-controls select[aria-label="Filter by bot"]');s.value='all';s.dispatchEvent(new Event('change'));`);
  await wait(() => page(`return [...document.querySelectorAll('.conversation-link')].some(n=>n.dataset.conversation==='${seeded.a}')`), 'origin visible again');
  await page(`[...document.querySelectorAll('.conversation-link')].find(n=>n.dataset.conversation==='${seeded.a}').click()`);
  await wait(() => page(`return document.querySelector('.conversation-link[aria-current="page"]')?.dataset.conversation==='${seeded.a}'`), 'origin reopened');
  check('reopening it shows the assistant turn with the user message above it',
    await page(`const t=[...document.querySelectorAll('#bot-transcript > *')].map(n=>n.textContent);
      const u=t.findIndex(x=>x.includes('Answer in the background')),a=t.findIndex(x=>x.includes('The background reply.'));
      return u>=0&&a>u;`));
  check('and exactly one of each — no duplicate bubble',
    await page(`const t=[...document.querySelectorAll('#bot-transcript > *')].map(n=>n.textContent);
      return t.filter(x=>x.includes('The background reply.')).length===1
        &&t.filter(x=>x.includes('Answer in the background')).length===1;`));
  await shot('02-reopened-origin');

  // --- 6. the slot released ------------------------------------------------
  await page(`[...document.querySelectorAll('.conversation-link')].find(n=>n.dataset.conversation==='${seeded.b}').click()`);
  await wait(() => page(`return document.querySelector('#bot-surface').dataset.screen==='bot:second'`), 'back on the other bot');
  await page(`document.querySelector('#bot-tab-settings').click();document.querySelector('#bot-endpoint').value='${endpoint}';document.querySelector('#bot-model').value='fixture';document.querySelector('#bot-connect').click();`);
  await wait(() => page(`return !document.querySelector('#bot-send').disabled`), 'fixture connected for the second bot');
  await page(`document.querySelector('#bot-tab-conversation').click()`);
  await page(`const m=document.querySelector('#bot-message');m.value='now this should send';m.dispatchEvent(new Event('input'));document.querySelector('.bot-composer').requestSubmit();`);
  await wait(() => page(`return !document.querySelector('#bot-send').disabled&&document.querySelector('#bot-status').textContent.includes('Reply received')`), 'the second reply');
  check('once the first reply lands the slot is released and the next send works',
    await page(`const {createConversationStore}=await import('./conversation-store.js');${store('second')}
      const d=s.get('ollama','${seeded.b}');
      return d.entries.some(e=>e.role==='assistant'&&e.text.includes('The background reply.'));`));

  writeFileSync(`${out}/background-reply-checks.json`, JSON.stringify({passed: true, checks}, null, 2));
  console.log(checks.map(c => 'ok  ' + c).join('\n'));
  console.log(`\n${checks.length} checks held. Evidence in ${out}`);
} finally {
  await app?.close();
  server.closeAllConnections();
  server.close();
}
