/* dt_0051 — a retired bot profile keeps its history, and gives it back.
 *
 * The acceptance criterion that sank both earlier attempts (da_0030, da_0033)
 * is not "the roster forgot the profile" — it is that the profile's saved
 * conversations must stay REACHABLE. Their regression test asserted on
 * `super-conversations:bot:<id>`, a key this app does not use, so it passed
 * while history became unreachable.
 *
 * This drives a real cockpit and reads the real keys: `super-conversations-v1`
 * for the assistant and `super-conversations-v1:bot:<id>` for every other
 * profile, plus `super-provider-preferences:bot:<id>`. It archives through the
 * directory's own control, reloads the whole app, restores through the
 * directory's own control, and then opens the restored conversation.
 */
import {open} from './lib/cockpit-control.mjs';
import assert from 'node:assert/strict';
import {mkdirSync, writeFileSync} from 'node:fs';

const out = process.env.SUPER_VISUAL_EVIDENCE_DIR || '/tmp/super-bot-archive-evidence';
mkdirSync(out, {recursive: true});
const checks = [];
const check = (name, value) => { assert.ok(value, name); checks.push(name); };
let app;
const KEY = id => `super-conversations-v1:bot:${id}`;

try {
  app = await open({port: 4631});
  const page = code => app.page(code);
  const wait = (fn, what) => app.until(fn, 15000, what);
  const shot = async n => {
    const r = await fetch(`http://127.0.0.1:4631/session/${app.session()}/screenshot`);
    writeFileSync(`${out}/${n}.png`, Buffer.from((await r.json()).value, 'base64'));
  };

  const seeded = await page(`
    const {createBotRoster}=await import('./bot-roster.js');
    const {createConversationStore}=await import('./conversation-store.js');
    createBotRoster(localStorage).save({id:'retiree',name:'Retired Helper',role:'Old work',group:'General',instructions:'Past project.',provider:'ollama'});
    const store=createConversationStore({getItem:k=>localStorage.getItem(k+':bot:retiree'),setItem:(k,v)=>localStorage.setItem(k+':bot:retiree',v)});
    const id=store.save('ollama',null,{messages:[{role:'user',content:'Retired work notes'}],entries:[{role:'user',label:'You',text:'Retired work notes'}],draft:'an unsent draft',files:[],includeContext:true});
    store.update('ollama',id,{pinned:true});
    localStorage.setItem('super-provider-preferences:bot:retiree',JSON.stringify([['ollama',{model:'fixture'}]]));
    localStorage.setItem('super-last-provider:bot:retiree','ollama');
    window.__archiveReload=true;location.reload();
    return id;`);
  await wait(() => page(`return window.__archiveReload!==true&&!!document.querySelector('[data-nav="bot:retiree"]')`), 'reloaded with the profile');

  const bytesBefore = await page(`return localStorage.getItem('${KEY('retiree')}')`);
  check('the profile starts in the directory, the rail and the chat filter', await page(`
    document.querySelector('#rail-bots [data-nav="bot:assistant"]').click();
    const f=[...document.querySelector('.conversation-controls select[aria-label="Filter by bot"]').options].map(o=>o.value);
    document.querySelector('.conversation-directory').click();
    return !!document.querySelector('#bot-directory [data-nav="bot:retiree"]')&&f.includes('retiree');`));
  await shot('01-before-archive');

  // --- archive it, through the directory's own control ---------------------
  await page(`document.querySelector('#bot-directory [data-archive-bot="retiree"], #bot-directory [data-archiveBot="retiree"]')?.click();
              [...document.querySelectorAll('#bot-directory button')].find(b=>b.textContent==='Archive'&&b.dataset.archiveBot==='retiree')?.click();`);
  await wait(() => page(`return !document.querySelector('#bot-directory [data-nav="bot:retiree"]')`), 'the profile to leave the directory');
  check('archiving removes it from the directory and the rail',
    await page(`return !document.querySelector('#bot-directory [data-nav="bot:retiree"]')&&!document.querySelector('#bot-roster-links [data-nav="bot:retiree"]')`));
  check('and from the conversation filter, so its chats stop appearing under All conversations',
    await page(`document.querySelector('#rail-bots [data-nav="bot:assistant"]').click();
      const s=document.querySelector('.conversation-controls select[aria-label="Filter by bot"]');
      s.value='all';s.dispatchEvent(new Event('change'));
      const ids=[...s.options].map(o=>o.value);
      const rows=[...document.querySelectorAll('.conversation-link')].map(n=>n.dataset.conversation);
      return !ids.includes('retiree')&&!rows.includes('${seeded}');`));
  check('it appears under Archived bots with a Restore control',
    await page(`document.querySelector('.conversation-directory').click();
      return document.querySelector('#bot-directory').textContent.includes('Archived bots')
        &&!!document.querySelector('#bot-directory [data-restore-bot="retiree"], #bot-directory [data-restoreBot="retiree"]')
        ||[...document.querySelectorAll('#bot-directory button')].some(b=>b.dataset.restoreBot==='retiree');`));
  await shot('02-archived');

  // --- THE POINT: nothing of its history was touched -----------------------
  check('its saved conversations are byte-for-byte untouched on disk',
    await page(`return localStorage.getItem('${KEY('retiree')}')`) === bytesBefore && !!bytesBefore);
  check('and its provider settings are still there',
    await page(`return localStorage.getItem('super-provider-preferences:bot:retiree')!==null&&localStorage.getItem('super-last-provider:bot:retiree')==='ollama'`));
  check('the active roster record is exactly the shipped shape, with no archived key',
    await page(`const r=JSON.parse(localStorage.getItem('super-bot-roster-v1'));
      return r.version===1&&Array.isArray(r.bots)&&r.archived===undefined&&!r.bots.some(b=>b.id==='retiree');`));
  check('the archive lives under its own key, which an older build never writes',
    await page(`const a=JSON.parse(localStorage.getItem('super-bot-roster-archived-v1'));
      return a.version===1&&a.bots.length===1&&a.bots[0].id==='retiree'&&a.bots[0].role==='Old work';`));

  // --- survives a full reload ---------------------------------------------
  await page(`window.__archiveReload=true;location.reload()`);
  await wait(() => page(`return window.__archiveReload!==true&&!!document.querySelector('[data-nav="bot:assistant"]')`), 'reloaded while archived');
  await page(`document.querySelector('#rail-bots [data-nav="bot:assistant"]').click();document.querySelector('.conversation-directory').click();`);
  await wait(() => page(`return !document.getElementById('bot-directory').hidden`), 'directory after reload');
  check('it is still archived after restarting the app, not resurrected and not lost',
    await page(`return !document.querySelector('#bot-directory [data-nav="bot:retiree"]')
      &&document.querySelector('#bot-directory').textContent.includes('Archived bots')
      &&[...document.querySelectorAll('#bot-directory button')].some(b=>b.dataset.restoreBot==='retiree');`));

  // --- restore, and get the history back -----------------------------------
  await page(`[...document.querySelectorAll('#bot-directory button')].find(b=>b.dataset.restoreBot==='retiree').click()`);
  await wait(() => page(`return !!document.querySelector('#bot-directory [data-nav="bot:retiree"]')`), 'the profile to return');
  check('restore brings back the same id, with its name, role and provider intact',
    await page(`const {createBotRoster}=await import('./bot-roster.js');
      const b=createBotRoster(localStorage).get('retiree');
      return !!b&&b.id==='retiree'&&b.name==='Retired Helper'&&b.role==='Old work'&&b.provider==='ollama';`));
  check('its conversation is reachable again through normal navigation',
    await page(`document.querySelector('#rail-bots [data-nav="bot:assistant"]').click();
      const s=document.querySelector('.conversation-controls select[aria-label="Filter by bot"]');
      s.value='all';s.dispatchEvent(new Event('change'));
      return [...document.querySelectorAll('.conversation-link')].some(n=>n.dataset.conversation==='${seeded}');`));
  check('with the same conversation id, title, pin and unsent draft it had before',
    await page(`const {createConversationStore}=await import('./conversation-store.js');
      const s=createConversationStore({getItem:k=>localStorage.getItem(k+':bot:retiree'),setItem:(k,v)=>localStorage.setItem(k+':bot:retiree',v)});
      const row=s.list('ollama').find(c=>c.id==='${seeded}');
      const data=s.get('ollama','${seeded}');
      return !!row&&row.pinned===true&&row.title==='Retired work notes'&&data.draft==='an unsent draft';`));
  check('and the archive key is empty again rather than holding a stale copy',
    await page(`const a=JSON.parse(localStorage.getItem('super-bot-roster-archived-v1'));return a.bots.length===0;`));
  await shot('03-restored');

  writeFileSync(`${out}/bot-archive-checks.json`, JSON.stringify({passed: true, checks}, null, 2));
  console.log(checks.map(c => 'ok  ' + c).join('\n'));
  console.log(`\n${checks.length} checks held. Evidence in ${out}`);
} finally { await app?.close(); }
