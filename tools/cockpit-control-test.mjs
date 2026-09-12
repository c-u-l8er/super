#!/usr/bin/env node
/* Does `lib/cockpit-control.mjs` actually do what it says?
 *
 * It claims three things and each is checked here against a real cockpit and a
 * throwaway world:
 *
 *   1. an intent submitted through it reaches the runtime and the record
 *      appears in the projection;
 *   2. a REFUSAL is surfaced, not swallowed — the failure that would let a
 *      script build on a record that does not exist;
 *   3. `create` is idempotent: asked twice for the same record it makes one.
 *
 * Plus the finding this file exists to pin: `remove_bot` works, and the reason
 * it looked broken the first time was reading the projection without waiting
 * for the frame that carries the removal.
 */
import {open, Refused} from './lib/cockpit-control.mjs';

let held = 0, failed = 0;
const check = (what, ok, detail = '') => {
  console.log(`  ${ok ? '\x1b[32mheld\x1b[0m' : '\x1b[31mFAILED\x1b[0m'}  ${what}${detail ? ' — ' + detail : ''}`);
  ok ? held++ : failed++;
};

console.log('\ncockpit-control\n');
let c;
try {
  c = await open();

  // 1. an intent reaches the runtime
  const ws = await c.create('open_workspace', {name: 'Control test'},
    {kind: 'workspaces', field: 'name', value: 'Control test'});
  check('an intent creates a record and the record reaches the projection',
    ws.created && /^ws_/.test(ws.record.id), ws.record.id);

  // 3. idempotence — asked again, it makes nothing
  const again = await c.create('open_workspace', {name: 'Control test'},
    {kind: 'workspaces', field: 'name', value: 'Control test'});
  check('asking twice for the same record creates one',
    !again.created && again.record.id === ws.record.id);
  check('and the runtime holds exactly one of it',
    (await c.list('workspaces')).filter(w => w.name === 'Control test').length === 1);

  // 2. a refusal is surfaced
  let refused = null;
  try {
    await c.intent('open_goal', {workspace_ref: 'ws_9999', title: 'Goal in a workspace that is not there'});
  } catch (e) { refused = e; }
  check('a refusal is thrown rather than returned as success',
    refused !== null, refused ? (refused instanceof Refused ? `Refused ${refused.code}` : refused.message.slice(0, 80)) : 'NOTHING WAS THROWN');
  check('and no goal was created by it',
    !(await c.find('goals', 'title', 'Goal in a workspace that is not there')));

  // A malformed intent must not read as acceptance either.
  let bad = null;
  try { await c.intent('open_workspace', {}); } catch (e) { bad = e; }
  check('a missing required argument is refused', bad !== null,
    bad ? (bad instanceof Refused ? `Refused ${bad.code}` : bad.message.slice(0, 60)) : 'NOTHING WAS THROWN');

  // remove_bot: the thing that looked broken and was not.
  const bot = await c.create('register_bot',
    {client_ref: 'control-test-bot', workspace_ref: ws.record.id, name: 'Control test bot',
     role: 'A bot that exists to be removed', group: 'General', provider: 'claude', instructions: ''},
    {kind: 'bots', field: 'name', value: 'Control test bot'});
  check('a bot registers through the same intent the disabled button sends',
    bot.created && /^bot_/.test(bot.record.actor ?? ''), bot.record.actor);

  const result = await c.intent('remove_bot', {bot_ref: bot.record.id});
  check('remove_bot is accepted', result?.allow === true, JSON.stringify(result));
  // Read straight away: this is the mistake, kept so the test records it.
  const immediately = await c.find('bots', 'name', 'Control test bot');
  await c.until(async () => !(await c.find('bots', 'name', 'Control test bot')), 15_000,
    'the bot to leave the projection');
  check('and the bot is gone once the frame carrying the removal arrives', true,
    immediately ? 'it was still present in the frame held at the moment of the call' : 'gone immediately too');

  // What the library says it cannot do.
  check('no repository is registered, and none was invented',
    (await c.list('repositories')).length === 0);
} catch (e) {
  check('the suite ran', false, e instanceof Refused ? `${e.intent} refused — ${e.code}` : e.message);
} finally {
  if (c) await c.close();
}
console.log(`\ncockpit-control: ${held} held · ${failed} failed\n`);
process.exit(failed ? 1 : 0);
