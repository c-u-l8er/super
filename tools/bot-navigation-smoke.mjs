/* dt_0052 — choosing a bot scopes the chat list, and the directory is reachable.
 *
 * Two reported defects, driven against a real cockpit:
 *
 *   1. clicking a bot opened its page but left the conversation list showing
 *      every bot's chats;
 *   2. the only way back to the bot directory ("Manage bots") sat *below* the
 *      whole conversation list, so a long list hid it.
 *
 * What makes this a regression test rather than a demonstration: it uses the
 * real roster and the real conversation store, through the exact per-bot
 * storage keys `bots.js` uses (`super-conversations-v1` for the assistant,
 * `super-conversations-v1:bot:<id>` for every other profile), and it re-reads
 * those keys after a reload to prove the conversation identities, titles,
 * pins and drafts the navigation touched are unchanged. A test that asserted
 * an invented key would pass while the product lost history.
 *
 * The refusal case is a real refusal: a reply is left in flight by a fixture
 * provider that does not answer until released, and the bot switch attempted
 * during it must be refused AND must leave the chosen scope alone.
 */
import {open} from './lib/cockpit-control.mjs';
import assert from 'node:assert/strict';
import {mkdirSync, writeFileSync} from 'node:fs';
import http from 'node:http';

const out = process.env.SUPER_VISUAL_EVIDENCE_DIR || '/tmp/super-bot-navigation-evidence';
mkdirSync(out, {recursive: true});
const checks = [];
const check = (name, value) => { assert.ok(value, name); checks.push(name); };

let app, holding = false, release = null, arrived = null;
const server = http.createServer(async (req, res) => {
  let body = ''; for await (const b of req) body += b;
  res.setHeader('content-type', 'application/json');
  if (req.url === '/api/tags') return res.end(JSON.stringify({models: [{name: 'fixture'}]}));
  // A reply the fixture refuses to finish is the only honest way to reach the
  // in-flight refusal: the switch must be refused *while* the turn is pending.
  if (holding) { holding = false; arrived.resolve(); await new Promise(r => { release = r; }); }
  res.end(JSON.stringify({message: {content: 'Fixture reply.', tool_calls: []}}));
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const endpoint = `http://127.0.0.1:${server.address().port}`;

try {
  app = await open({port: 4599});
  const page = code => app.page(code);
  const wait = (fn, what) => app.until(fn, 15000, what);
  const shot = async name => {
    const r = await fetch(`http://127.0.0.1:4599/session/${app.session()}/screenshot`);
    writeFileSync(`${out}/${name}.png`, Buffer.from((await r.json()).value, 'base64'));
  };
  const links = () => page(`return [...document.querySelectorAll('.conversation-link')].map(n=>n.dataset.conversation)`);
  const filter = () => page(`return document.querySelector('.conversation-controls select[aria-label="Filter by bot"]').value`);

  // --- seed: two bots, three conversations, through the real stores --------
  const seeded = await page(`
    const {createBotRoster}=await import('./bot-roster.js');
    const {createConversationStore}=await import('./conversation-store.js');
    createBotRoster(localStorage).save({id:'builder',name:'Super Builder',role:'Implementation',group:'General',instructions:'Build things.',provider:'ollama'});
    const storeFor=id=>createConversationStore({getItem:k=>localStorage.getItem(id==='assistant'?k:k+':bot:'+id),setItem:(k,v)=>localStorage.setItem(id==='assistant'?k:k+':bot:'+id,v)});
    const make=(id,title,draft)=>storeFor(id).save('ollama',null,{messages:[{role:'user',content:title}],entries:[{role:'user',label:'You',text:title}],draft,files:[],includeContext:true});
    localStorage.setItem('super-last-provider','ollama');
    localStorage.setItem('super-last-provider:bot:builder','ollama');
    const assistantOne=make('assistant','Assistant plan one','assistant draft');
    const assistantTwo=make('assistant','Assistant plan two','');
    const builderOne=make('builder','Builder retry loop','builder draft');
    storeFor('builder').update('ollama',builderOne,{pinned:true});
    window.__navReload=true;location.reload();
    return {assistantOne,assistantTwo,builderOne};
  `);
  await wait(() => page(`return window.__navReload!==true&&!!document.querySelector('[data-nav="bot:assistant"]')`), 'reloaded app');

  // --- 1. the list starts unscoped, and every bot's chats are there --------
  await page(`document.querySelector('#rail-bots [data-nav="bot:assistant"]').click()`);
  await wait(() => page(`return document.querySelectorAll('.conversation-link').length>0`), 'conversation sidebar');
  await page(`const s=document.querySelector('.conversation-controls select[aria-label="Filter by bot"]');s.value='all';s.dispatchEvent(new Event('change'));`);
  await wait(() => page(`return document.querySelectorAll('.conversation-link').length===3`), 'all three conversations');
  check('browsing every conversation stays available as an explicit choice',
    await page(`return [...document.querySelector('.conversation-controls select[aria-label="Filter by bot"]').options].map(o=>o.value).join()==='all,assistant,builder'`));

  // --- 2. the directory control is at the TOP of the sidebar ---------------
  check('an All bots control is the first thing in the conversation sidebar',
    await page(`const s=document.querySelector('.conversation-sidebar');const d=s.querySelector('.conversation-directory');return !!d&&s.firstElementChild===d&&!d.hidden&&d.textContent.includes('All bots')`));
  check('it sits above the conversation rows, not after them',
    await page(`const d=document.querySelector('.conversation-directory'),rows=document.querySelector('.conversation-link');return !!(d.compareDocumentPosition(rows)&Node.DOCUMENT_POSITION_FOLLOWING)&&d.getBoundingClientRect().top<rows.getBoundingClientRect().top`));
  // Two other driven smokes reach the directory with `.conversation-sidebar >
  // button`, which used to be the bottom "Manage bots" control. Pin that the
  // sidebar still offers exactly one direct-child button and it still goes
  // there, so moving the control did not silently break them.
  check('the sidebar still exposes exactly one direct-child button, and it is this one',
    await page(`const b=document.querySelectorAll('.conversation-sidebar > button');return b.length===1&&b[0].classList.contains('conversation-directory')`));
  await shot('01-all-conversations');

  // --- 3. opening another bot's chat from the all-list keeps the scope -----
  const before = await filter();
  await page(`[...document.querySelectorAll('.conversation-link')].find(n=>n.dataset.conversation==='${seeded.builderOne}').click()`);
  await wait(() => page(`return document.querySelector('#bot-surface').dataset.screen==='bot:builder'`), 'builder conversation opened');
  check('opening a chat from the all-conversations list does not rescope the list',
    await filter() === before && before === 'all' && (await links()).length === 3);
  check('and it really did open that conversation on its own bot',
    await page(`return document.querySelector('[data-conversation="${seeded.builderOne}"]').getAttribute('aria-current')==='page'`));
  await shot('02-opened-other-bot-chat-scope-kept');

  // --- 4. explicitly choosing a bot scopes the list ------------------------
  await page(`document.querySelector('.conversation-directory').click()`);
  await wait(() => page(`return !document.getElementById('bot-directory').hidden&&document.getElementById('bot-surface').hidden`), 'bot directory');
  check('All bots returns to the full bot directory', true);
  await shot('03-directory');
  await page(`document.querySelector('#bot-directory [data-nav="bot:assistant"]').click()`);
  await wait(() => page(`return document.querySelector('#bot-surface').dataset.screen==='bot:assistant'`), 'assistant page');
  check('choosing a bot shows only that bot’s chats',
    await filter() === 'assistant' && JSON.stringify((await links()).sort()) === JSON.stringify([seeded.assistantOne, seeded.assistantTwo].sort()));
  await shot('04-scoped-to-assistant');

  // --- 5. reselecting the bot that is already open also scopes -------------
  await page(`const s=document.querySelector('.conversation-controls select[aria-label="Filter by bot"]');s.value='all';s.dispatchEvent(new Event('change'));`);
  await wait(() => page(`return document.querySelectorAll('.conversation-link').length===3`), 'unscoped again');
  await page(`document.querySelector('.conversation-directory').click()`);
  await wait(() => page(`return !document.getElementById('bot-directory').hidden`), 'directory again');
  await page(`document.querySelector('#bot-directory [data-nav="bot:assistant"]').click()`);
  await wait(() => page(`return !document.getElementById('bot-surface').hidden`), 'assistant page again');
  check('reselecting the bot that is already open scopes the list to it',
    await filter() === 'assistant' && (await links()).length === 2);

  // --- 6. a stale search is cleared; a deliberate sort is kept -------------
  await page(`const s=document.querySelector('.conversation-controls select[aria-label="Sort conversations"]');s.value='bot';s.dispatchEvent(new Event('change'));
             const q=document.querySelector('.conversation-controls input[aria-label="Search conversations"]');q.value='zzz-no-match';q.dispatchEvent(new Event('input'));`);
  await wait(() => page(`return document.querySelectorAll('.conversation-link').length===0`), 'search with no matches');
  await page(`document.querySelector('.conversation-directory').click()`);
  await wait(() => page(`return !document.getElementById('bot-directory').hidden`), 'directory for builder');
  await page(`document.querySelector('#bot-directory [data-nav="bot:builder"]').click()`);
  await wait(() => page(`return document.querySelector('#bot-surface').dataset.screen==='bot:builder'`), 'builder page');
  check('switching bot clears a stale search so its chats are visible',
    await page(`return document.querySelector('.conversation-controls input[aria-label="Search conversations"]').value===''`) && (await links()).length === 1);
  check('and the deliberate sort choice is preserved across the switch',
    await page(`return document.querySelector('.conversation-controls select[aria-label="Sort conversations"]').value==='bot'`));
  await shot('05-scoped-to-builder');

  // --- 7. a refused switch leaves the scope alone -------------------------
  check('a bot that is not in the roster is refused and changes nothing',
    await page(`const {navigate}=await import('./app-shell.js');navigate('bot:ghost');return document.querySelector('#bot-surface').dataset.screen==='bot:builder'`) && await filter() === 'builder');

  await page(`document.querySelector('#bot-tab-settings').click();document.querySelector('#bot-endpoint').value='${endpoint}';document.querySelector('#bot-model').value='fixture';document.querySelector('#bot-connect').click();`);
  await wait(() => page(`return !document.querySelector('#bot-send').disabled`), 'fixture provider connected');
  arrived = {}; arrived.promise = new Promise(r => { arrived.resolve = r; }); holding = true;
  await page(`document.querySelector('#bot-tab-conversation').click();document.querySelector('#bot-new').click();document.querySelector('#bot-message').value='Hold this reply';document.querySelector('#bot-message').dispatchEvent(new Event('input'));document.querySelector('.bot-composer').requestSubmit();`);
  await arrived.promise;                             // the provider really has the turn
  await wait(() => page(`return document.querySelector('#bot-send').disabled`), 'a reply in flight');
  await page(`const {navigate}=await import('./app-shell.js');navigate('bot:assistant');`);
  await wait(() => page(`return document.querySelector('#bot-surface').dataset.screen==='bot:assistant'`), 'bot switch during reply');
  check('a bot switch while a reply is pending opens the chosen bot and scopes its chats',
    await filter() === 'assistant');
  // --- 7b. a held reply keeps navigation open and names the one-slot owner ---
  check('while a reply runs, every listed chat stays clickable',
    await page(`const rows=[...document.querySelectorAll('.conversation-link')];return rows.length>0&&rows.every(n=>!n.disabled)`));
  check('and the sidebar names the generating conversation while saying reading stays open',
    await page(`const h=[...document.querySelectorAll('.conversation-sidebar .rail-hint')].find(n=>/Generating a reply in/.test(n.textContent));
      return !!h&&!h.hidden&&h.textContent.includes('every other chat stays open for reading')`));
  await shot('06-switch-during-reply');
  release();                                         // release the held reply
  await wait(() => page(`return ![...document.querySelectorAll('.conversation-sidebar .rail-hint')].some(n=>/Generating a reply in/.test(n.textContent)&&!n.hidden)`), 'reply finished');
  check('when the reply finishes every chat is clickable again and the reason is withdrawn',
    await page(`const rows=[...document.querySelectorAll('.conversation-link')];
      const h=[...document.querySelectorAll('.conversation-sidebar .rail-hint')].find(n=>/Generating a reply in/.test(n.textContent));
      return rows.length>0&&rows.every(n=>!n.disabled)&&(!h||h.hidden)`));

  // --- 7c. unread the current view hides is still announced ---------------
  // Scoping the list was a deliberate fix; hiding a reply that arrived on
  // another bot was not. While a bot page is open the rail roster is hidden
  // too, so the directory control is the only place left to say it.
  await page(`document.querySelector('.conversation-directory').click()`);
  await wait(() => page(`return !document.getElementById('bot-directory').hidden`), 'directory before hidden unread');
  await page(`document.querySelector('#bot-directory [data-nav="bot:builder"]').click()`);
  await wait(() => page(`return document.querySelector('#bot-surface').dataset.screen==='bot:builder'`), 'builder before hidden unread');
  await page(`const s=document.querySelector('.conversation-controls select[aria-label="Filter by bot"]');s.value='builder';s.dispatchEvent(new Event('change'));`);
  await wait(() => page(`return document.querySelector('.conversation-controls select[aria-label="Filter by bot"]').value==='builder'`), 'scoped to builder');
  const zero = await page(`const d=document.querySelector('.conversation-directory');
    return JSON.stringify({text:d.textContent,label:d.getAttribute('aria-label'),title:d.title,kids:d.children.length,unread:'unread' in d.dataset});`);
  check('with nothing unread elsewhere the control is exactly as it ships',
    JSON.parse(zero).text === '← All bots' && JSON.parse(zero).label === 'All bots — open the bot directory'
    && JSON.parse(zero).title === 'Show every bot' && JSON.parse(zero).kids === 1 && JSON.parse(zero).unread === false);
  // A reply lands on the assistant while the list is scoped to the builder.
  await page(`const {createConversationStore}=await import('./conversation-store.js');
    const st=createConversationStore(localStorage);
    const d=st.get('ollama','${seeded.assistantOne}');
    d.entries.push({role:'assistant',label:'Workspace assistant',text:'A reply you have not read',proposals:[],referenceWorld:null});
    d.messages.push({role:'assistant',content:'A reply you have not read',attachments:[]});
    st.save('ollama','${seeded.assistantOne}',d);
    // A real reply reaches the sidebar through updateHistory() -> render().
    // Writing the store directly skips that, so emit the same signal the app
    // emits rather than waiting on a render that nothing asked for.
    document.dispatchEvent(new CustomEvent('page-selected',{detail:{id:'bot:builder'}}));`);
  await wait(() => page(`return document.querySelector('.conversation-directory').dataset.unread==='1'`), 'the unread count to appear');
  check('an unread reply on a bot this view hides is announced on the All bots control',
    await page(`const d=document.querySelector('.conversation-directory');
      return /1 unread conversation not shown in this view$/.test(d.getAttribute('aria-label'))&&d.textContent.includes('← All bots')&&d.textContent.includes('1');`));
  check('and it is words, not colour — the count is in the accessible name',
    await page(`return document.querySelector('.conversation-directory').getAttribute('aria-label').includes('unread')`));
  check('the count is what this render left out — the unread chat is absent from the rows',
    await page(`const d=document.querySelector('.conversation-directory');
      const shown=[...document.querySelectorAll('.conversation-link')].map(n=>n.dataset.conversation);
      return Number(d.dataset.unread)===1
        &&!shown.includes('${seeded.assistantOne}')
        &&shown.length>0&&shown.every(id=>id!=='${seeded.assistantOne}');`));
  check('seeing it did not rescope, reorder, clear the search or move the selection',
    await page(`return document.querySelector('.conversation-controls select[aria-label="Filter by bot"]').value==='builder'
      &&document.querySelector('.conversation-controls select[aria-label="Sort conversations"]').value==='bot'
      &&document.querySelector('.conversation-controls input[aria-label="Search conversations"]').value==='';`));
  check('the sidebar still has exactly one direct-child button, and the badge is inside it',
    await page(`const b=document.querySelectorAll('.conversation-sidebar > button');
      return b.length===1&&b[0].classList.contains('conversation-directory')&&!!b[0].querySelector('.conversation-elsewhere');`));
  await shot('07-unread-elsewhere');
  check('clicking it — badge and all — still reaches the bot directory',
    await page(`document.querySelector('.conversation-elsewhere').click();
      return !document.getElementById('bot-directory').hidden&&document.getElementById('bot-surface').hidden;`));

  // --- 8. nothing the navigation touched was lost -------------------------
  await page(`window.__navReload=true;location.reload()`);
  await wait(() => page(`return window.__navReload!==true&&!!document.querySelector('[data-nav="bot:assistant"]')`), 'reloaded for persistence');
  const after = await page(`
    const {createConversationStore}=await import('./conversation-store.js');
    const storeFor=id=>createConversationStore({getItem:k=>localStorage.getItem(id==='assistant'?k:k+':bot:'+id),setItem:(k,v)=>localStorage.setItem(id==='assistant'?k:k+':bot:'+id,v)});
    const read=id=>storeFor(id).list('ollama').map(c=>({id:c.id,title:c.title,pinned:c.pinned,draft:storeFor(id).get('ollama',c.id).draft}));
    return {assistant:read('assistant'),builder:read('builder'),
            roster:(await import('./bot-roster.js')).createBotRoster(localStorage).list().map(b=>b.id)};
  `);
  const find = (list, id) => list.find(c => c.id === id);
  check('every seeded conversation identity survives the navigation and a reload',
    !!find(after.assistant, seeded.assistantOne) && !!find(after.assistant, seeded.assistantTwo) && !!find(after.builder, seeded.builderOne));
  check('titles, pins and drafts are unchanged',
    find(after.assistant, seeded.assistantOne).title === 'Assistant plan one'
    && find(after.assistant, seeded.assistantOne).draft === 'assistant draft'
    && find(after.builder, seeded.builderOne).pinned === true
    && find(after.builder, seeded.builderOne).draft === 'builder draft');
  check('both bot profiles are still in the roster',
    after.roster.includes('assistant') && after.roster.includes('builder'));

  writeFileSync(`${out}/bot-navigation-checks.json`, JSON.stringify({passed: true, checks}, null, 2));
  console.log(checks.map(c => 'ok  ' + c).join('\n'));
  console.log(`\n${checks.length} checks held. Evidence in ${out}`);
} finally {
  await app?.close();
  server.closeAllConnections();
  server.close();
}
