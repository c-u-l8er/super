#!/usr/bin/env node
/* first-reply-title-only-smoke — the guard for the reply that is only its title header,
   on a real screen, with a local HTTP provider fixture instead of the Claude CLI (the
   decode and the guard are provider-agnostic: bots.js runs them on every reply).

   Measured 2026-09-18 against Claude: the first reply of a new conversation was
   `<conversation-title>…` unterminated, no prose, no proposal, and the page landed it as
   a normal reply, so the round produced nothing. This drives that exact reply shape and
   proves what the page does now — refuse the turn, keep the title, restore the draft —
   and that a reply carrying a proposal behind the same header is NOT refused.

     node tools/first-reply-title-only-smoke.mjs
     APP_SMOKE_SCREENSHOTS=/some/dir node tools/first-reply-title-only-smoke.mjs        */
import {open} from './lib/cockpit-control.mjs';
import {createServer} from 'node:http';
import {writeFileSync, mkdirSync} from 'node:fs';
process.env.GDK_BACKEND ??= 'x11';
let held = 0, failed = 0;
const check = (what, ok, detail = '') => { console.log(`  ${ok ? '\x1b[32mheld\x1b[0m' : '\x1b[31mFAILED\x1b[0m'}  ${what}${detail ? ' — ' + detail : ''}`); ok ? held++ : failed++; };
const q = s => JSON.stringify(s), sleep = ms => new Promise(r => setTimeout(r, ms));
const shots = process.env.APP_SMOKE_SCREENSHOTS; if (shots) mkdirSync(shots, {recursive: true});
const REFUSAL = 'The reply stopped at its title header and carried no answer and no proposal.';
const TITLE = 'Persist the Cancelled fold state on record pages';
// The shape that was measured: the header opened, never closed, and nothing after it.
const HEADER_ONLY = `<conversation-title>${TITLE}`;

// ---- the provider, as a local HTTP fixture. It records what each request asked for.
const asked = [];
const fixture = createServer((req, res) => {
  if (req.url === '/api/tags') { res.writeHead(200, {'content-type': 'application/json'}); res.end(JSON.stringify({models: [{name: 'fixture-model'}]})); return; }
  let data = ''; req.on('data', c => { data += c; });
  req.on('end', () => {
    const body = JSON.parse(data), user = body.messages.at(-1).content, system = body.messages[0].content;
    // The page asks for a title by appending the instruction to the bot's instructions,
    // which this provider receives inside the system message.
    asked.push({titleRequested: system.includes('begin the text field with <conversation-title>'), user: user.slice(0, 40)});
    const reply = (content, tool_calls = []) => { res.writeHead(200, {'content-type': 'application/json'}); res.end(JSON.stringify({message: {role: 'assistant', content, tool_calls}, done: true})); };
    if (user.includes('TITLE-ONLY-CASE')) return asked.filter(a => a.user.includes('TITLE-ONLY-CASE')).length === 1
      ? reply(HEADER_ONLY)                                  // the first send: the measured failure
      : reply('Here is the answer on the second send.');    // the resend, as it behaved for real
    if (user.includes('TITLE-PLUS-ACTION')) return reply(HEADER_ONLY, [{function: {name: 'open_workspace', arguments: {name: 'Proposed by the fixture'}}}]);
    if (user.includes('CLOSED-HEADER')) return reply(`<conversation-title>${TITLE}</conversation-title>A complete answer.`);
    return reply('Unexpected request.');
  });
});
await new Promise(r => fixture.listen(0, '127.0.0.1', r));
const endpoint = `http://127.0.0.1:${fixture.address().port}`;

console.log('\nfirst-reply-title-only (a reply that is only its title header is refused, not landed)\n');
let c;
try {
  c = await open();
  const shot = async name => { if (!shots) return; try { const r = await fetch(`http://127.0.0.1:${process.env.COCKPIT_CONTROL_PORT ?? 4495}/session/${c.session()}/screenshot`); const j = await r.json(); writeFileSync(`${shots}/${name}.png`, Buffer.from(j.value, 'base64')); } catch (e) { console.log('  (screenshot failed: ' + e.message + ')'); } };
  let ws = (await c.list('workspaces'))[0];
  if (!ws) ws = (await c.create('open_workspace', {name: 'Title smoke workspace'}, {kind: 'workspaces', field: 'name', value: 'Title smoke workspace'})).record;
  const bot = (await c.create('register_bot', {client_ref: 'title-only-smoke-bot', workspace_ref: ws.id, name: 'Title smoke bot', role: 'Reviewer', group: 'Smoke', provider: 'ollama', instructions: 'Answers the smoke.'}, {kind: 'bots', field: 'name', value: 'Title smoke bot'})).record;

  await c.page(`document.querySelector('[data-rail-mode=bots]')?.click()`);
  await c.until(() => c.page(`return !!document.querySelector('#rail-bots [data-nav=${q('bot:' + bot.client_ref)}]')`), 20_000, 'bot in the rail');
  await c.page(`document.querySelector('#rail-bots [data-nav=${q('bot:' + bot.client_ref)}]').click()`);
  await c.until(() => c.page(`return !document.querySelector('#bot-surface').hidden`), 20_000, 'bot surface');
  await c.page(`const p=document.querySelector('#bot-provider');p.value='ollama';p.dispatchEvent(new Event('change'));const e=document.querySelector('#bot-endpoint');e.value=${q(endpoint)};e.dispatchEvent(new Event('input',{bubbles:true}));`);
  await c.page(`document.querySelector('#bot-connect').click()`);
  await c.until(() => c.page(`return !document.querySelector('#bot-send').disabled`), 60_000, 'provider connected');

  const status = () => c.page(`return document.querySelector('#bot-status')?.textContent ?? ''`);
  const title = () => c.page(`return document.querySelector('.conversation-title')?.textContent ?? ''`);
  const entries = () => c.page(`return JSON.stringify([...document.querySelectorAll('#bot-transcript .bot-message')].map(e=>({role:e.classList.contains('bot-user')?'user':e.classList.contains('bot-assistant')?'assistant':'result',text:(e.querySelector('.bot-message-text')?.textContent??'').slice(0,160)})))`).then(JSON.parse);
  const draft = () => c.page(`return document.querySelector('#bot-message').value`);
  const send = async text => {
    const before = (await entries()).length;
    if (text !== null) await c.page(`const t=document.querySelector('#bot-message');t.value=${q(text ?? '')};t.dispatchEvent(new Event('input',{bubbles:true}));`);
    await c.page(`document.querySelector('.bot-composer').requestSubmit()`);
    await c.until(async () => (await entries()).length > before && !await c.page(`return document.querySelector('#bot-send').disabled`), 60_000, 'the turn to settle');
    await sleep(400);
  };
  const fresh = async () => { await c.page(`document.querySelector('#bot-new').click()`); await c.until(async () => !(await entries()).length, 20_000, 'a fresh conversation'); };

  // ---- 1. the measured failure: a first reply that is only its unterminated header
  const REQUEST = 'TITLE-ONLY-CASE Fix one defect in the attached file and propose the replacement.';
  await send(REQUEST);
  const after = await entries();
  check('the first send asks the provider for a conversation title', asked.at(-1)?.titleRequested === true);
  check('a header-only reply does NOT land as an assistant reply', !after.some(e => e.role === 'assistant'), JSON.stringify(after.map(e => e.role)));
  check('the transcript says why, naming the resend', (after.at(-1)?.text ?? '').includes(REFUSAL) && after.at(-1).text.includes('send it again in this conversation'), after.at(-1)?.text);
  check('the status line carries the same refusal', (await status()).includes(REFUSAL), await status());
  check('the draft is restored in the composer', await draft() === REQUEST);
  check('the title parsed from the header is kept', await title() === TITLE, await title());
  await shot('01-title-only-refused');

  // ---- 2. the resend, in the now-titled conversation
  await send(null);
  const resent = await entries();
  check('the resend does not ask for a title again', asked.at(-1)?.titleRequested === false);
  check('the resent turn lands a normal reply', resent.at(-1)?.role === 'assistant' && resent.at(-1).text.includes('Here is the answer on the second send.'), resent.at(-1)?.text);
  check('the status line reads Reply received', (await status()).startsWith('Reply received'), await status());
  check('the composer is empty again', await draft() === '');
  check('the kept title is unchanged by the resend', await title() === TITLE, await title());
  await shot('02-resend-landed');

  // ---- 3. the same header WITH a proposal is not empty, and is not refused
  await fresh();
  await send('TITLE-PLUS-ACTION Propose a workspace.');
  const withAction = await entries();
  check('a header-only text carrying a proposal still lands', withAction.at(-1)?.role === 'assistant', JSON.stringify(withAction.map(e => e.role)));
  check('its proposal card is on screen', await c.page(`return document.querySelectorAll('#bot-transcript .bot-proposal').length`) === 1);
  check('its title is taken from the header too', await title() === TITLE, await title());
  check('nothing was refused', !(await status()).includes(REFUSAL), await status());
  await shot('03-header-with-proposal-lands');

  // ---- 4. a properly closed header is unchanged: title out, prose kept
  await fresh();
  await send('CLOSED-HEADER Answer normally.');
  const closed = await entries();
  check('a closed header yields the title and the prose', closed.at(-1)?.role === 'assistant' && closed.at(-1).text.trim() === 'A complete answer.' && await title() === TITLE, `${closed.at(-1)?.text} · ${await title()}`);
} catch (e) {
  failed++;
  console.log(`  \x1b[31mFAILED\x1b[0m  ${e.message}`);
} finally {
  await c?.close();
  fixture.close();
}
console.log(`\nfirst-reply-title-only: ${held} held · ${failed} failed\n`);
process.exit(failed ? 1 : 0);
