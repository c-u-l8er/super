/* The phone clients must not decide turn ownership for themselves.
 *
 * `bots.js` projects the in-flight turn to every phone client as `view.turn`,
 * a sibling of `active`, because a reply belongs to the conversation it was
 * SENT from and not to whichever one is on screen. Deciding which conversation
 * owns it is therefore the one question every client has to get right, and it
 * is exactly the question that has now been got wrong twice:
 *
 *   * the Expo app carried a hand-edited copy of `conversation-list.js` that
 *     still derived a row's status from `active`, so it put the indicator on
 *     the wrong chat the moment a reply finished in the background;
 *   * a proposal for this companion hand-compared `turn.id === active.id`.
 *     There is no `id` on a projected turn — the registry stores
 *     `conversationId` — so that test is `undefined === <an id>`, always
 *     false, and the "a reply is generating elsewhere" hint would have been
 *     shown to someone watching that very reply stream.
 *
 * Both are the same mistake: re-deriving identity beside the module that
 * already defines it. `conversation-turns.js` exports `conversationIdentity`
 * (which accepts a row's `id` OR an open view's `conversationId`) and
 * `sameConversation`; the gateway and the private connector both serve that
 * module to the phone, so there is no reason to re-implement it.
 *
 * The last check is what makes the first two more than a style rule: it
 * measures the projected turn and shows that `id` is simply not on it.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {existsSync, readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {dirname, resolve} from 'node:path';
import {createTurnRegistry, conversationIdentity, sameConversation} from '../cockpit/ui/conversation-turns.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const read = p => readFileSync(resolve(root, p), 'utf8');
const companion = read('mobile/ui/conversations.js');

test('the companion decides ownership with the shared helpers', () => {
  assert.match(companion, /import\s*\{[^}]*\}\s*from\s*'\.\/conversation-turns\.js'/,
    'mobile/ui/conversations.js must import the shared turn module');
  assert.match(companion, /sameConversation\(\s*turn\s*,\s*conversationIdentity\(/,
    'ownership must be sameConversation(turn, conversationIdentity(...)), not a hand-written comparison');
});

test('no client hand-compares a field the projected turn does not have', () => {
  for (const [path, source] of [['mobile/ui/conversations.js', companion]]) {
    assert.doesNotMatch(source, /turn\s*\??\.\s*id\b/,
      `${path} reads turn.id, which is always undefined; the field is conversationId, and ` +
      `conversationIdentity/sameConversation already reconcile the two spellings`);
  }
});

test('both phone routes serve the module the companion imports', () => {
  assert.match(read('mobile/server.mjs'), /'\/conversation-turns\.js'/,
    'the gateway must serve /conversation-turns.js or the import 404s on the phone');
  assert.match(read('mobile/private-connector.mjs'), /'\/conversation-turns\.js'/,
    'the private connector must forward /conversation-turns.js');
});

test('a projected turn carries conversationId and no id at all', () => {
  const registry = createTurnRegistry();
  registry.begin({botId: 'b1', provider: 'claude', conversationId: 'c-a', title: 'Alpha', messageCount: 1});
  const turn = registry.current();
  assert.equal(Object.hasOwn(turn, 'conversationId'), true);
  assert.equal(Object.hasOwn(turn, 'id'), false, 'a turn has no id; anything comparing turn.id is comparing undefined');
  // And the helper the clients are required to use gets the open view right.
  assert.equal(sameConversation(turn, conversationIdentity({botId: 'b1', provider: 'claude', id: 'c-a'})), true);
  assert.equal(sameConversation(turn, conversationIdentity({botId: 'b1', provider: 'claude', id: 'c-b'})), false);
});

/* The companion is imported two ways and both have to resolve.
 *
 * In a browser the gateway's asset map answers `/conversation-turns.js` from
 * cockpit/ui, so a bare `./conversation-turns.js` import works. Node has no
 * asset map: it looks beside the file. The repo's answer is a two-line
 * re-export shim per shared module (mobile/ui/conversation-list.js was already
 * one). Adding an import without its shim does not fail in the app — it fails
 * every Node test that imports the companion, which is how it was found. */
test('every shared module the companion imports has a disk shim beside it', () => {
  const imports = [...companion.matchAll(/from\s*'\.\/([\w.-]+\.js)'/g)].map(m => m[1]);
  assert.ok(imports.length >= 2, 'expected the companion to import the shared modules');
  for (const name of imports) {
    const shim = resolve(root, 'mobile/ui', name);
    assert.ok(existsSync(shim),
      `mobile/ui/conversations.js imports ./${name} but mobile/ui/${name} does not exist. ` +
      `The gateway serves it from cockpit/ui, so the app works and only Node breaks. ` +
      `Add a re-export shim like mobile/ui/conversation-list.js.`);
  }
});
