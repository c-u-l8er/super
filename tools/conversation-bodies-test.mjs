/* T24 · conversation bodies by digest on this device.
 *
 * The host store is `cockpit/src/bodies.rs` (its own Rust tests hold durability, ownership and collection). These hold
 * the page: exact bytes through reference and resolve, the quota fallback that never drops committed bytes, the
 * store's refresh against a stale sibling, release-after-commit, and a migration that never replaces an original
 * until it is verified — interrupted at every step. The host here is an in-memory stand-in with the same contract:
 * `put` answers only after the bytes are stored and the owner recorded; `get` re-hashes.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createBodyService, bodySlots, valueAt, isBodyRef, problemText, BODY_SCHEMA} from '../cockpit/ui/conversation-bodies.js';
import {createConversationStore, STORAGE_KEY, bodyOwner} from '../cockpit/ui/conversation-store.js';
import {migrateKey, migrateConversationStores, MIGRATION_RECEIPTS} from '../cockpit/ui/conversation-migration.js';
import {validateRecoveryShape, validateRecovery, RECOVERY_SCHEMA} from '../cockpit/ui/proposal-recovery.js';
import {PATCH_SCHEMA} from '../cockpit/ui/file-patch.js';

const hex = s => createHash('sha256').update(Buffer.from(s, 'utf8')).digest('hex');

function fakeHost({failPut = () => false, beforePut = () => {}} = {}) {
  const blobs = new Map(), owners = new Map(), calls = [];
  const host = {
    blobs, owners, calls,
    corrupt(d) { blobs.set(d, blobs.get(d) + 'x'); },
    lose(d) { blobs.delete(d); },
    async invoke(cmd, {request: r}) {
      assert.equal(cmd, 'conversation_bodies');
      calls.push(r.operation);
      if (r.operation === 'put') {
        beforePut(r);
        if (failPut(r)) throw new Error('disk full (injected)');
        const d = hex(r.text);
        blobs.set(d, r.text);
        if (!owners.has(r.owner)) owners.set(r.owner, new Set());
        owners.get(r.owner).add(d);
        return {state: 'stored', sha256: d, bytes: Buffer.byteLength(r.text, 'utf8')};
      }
      if (r.operation === 'get') {
        if (!blobs.has(r.sha256)) return {state: 'missing', sha256: r.sha256};
        const t = blobs.get(r.sha256);
        return hex(t) === r.sha256 ? {state: 'available', sha256: r.sha256, text: t} : {state: 'corrupt', sha256: r.sha256};
      }
      if (r.operation === 'release') { const n = owners.get(r.owner)?.size ?? 0; owners.delete(r.owner); return {released: n}; }
      throw new Error('unknown op');
    },
  };
  return host;
}

/* localStorage with WebKit's arithmetic: the quota counts UTF-16 code units of every key and value, twice (bytes). */
function fakeStorage(quotaBytes = Infinity, init = {}) {
  const map = new Map(Object.entries(init));
  const used = () => [...map].reduce((n, [k, v]) => n + 2 * (k.length + v.length), 0);
  return {
    map,
    get length() { return map.size; },
    key: i => [...map.keys()][i] ?? null,
    getItem: k => (map.has(k) ? map.get(k) : null),
    setItem(k, v) {
      const next = used() - (map.has(k) ? 2 * (k.length + map.get(k).length) : 0) + 2 * (k.length + v.length);
      if (next > quotaBytes) { const e = new Error('QuotaExceededError'); e.name = 'QuotaExceededError'; throw e; }
      map.set(k, v);
    },
    removeItem: k => map.delete(k),
  };
}
/* A store as bots.js makes one: the per-bot key is the real localStorage key. */
const botKey = id => `${STORAGE_KEY}:bot:${id}`;
const storeOn = (storage, id, bodies) => createConversationStore(
  {getItem: k => storage.getItem(k === STORAGE_KEY ? botKey(id) : k), setItem: (k, v) => storage.setItem(k === STORAGE_KEY ? botKey(id) : k, v)},
  {bodies, key: botKey(id)});

const basis = (path, draft) => ({schema: 'selected-file-basis@1', basis_id: 'b'.repeat(64), head: 'h'.repeat(40), path, draft_sha256: hex(draft), disk_sha256: hex(draft)});
const recovery = (path, draft, content, extra = {}) => ({schema: RECOVERY_SCHEMA, path, content, draft, original: draft, source: basis(path, draft), task: null, ...extra});
function conversation({attachments = [], files = [], proposals = []} = {}) {
  return {
    messages: [{role: 'user', content: 'Please change it.', attachments}, {role: 'assistant', content: 'Here.', attachments: []}],
    entries: [{role: 'user', label: 'You', text: 'Please change it.', referenceWorld: null, proposals: []},
      {role: 'assistant', label: 'Bot', text: 'Here.', referenceWorld: null, proposals}],
    draft: '', files, includeContext: true, replyPending: false,
  };
}
const flush = () => new Promise(r => setTimeout(r, 0));
async function settle(n = 5) { for (let i = 0; i < n; i++) await flush(); }

/* A random well-formed string: ASCII, CRLF, BMP and astral characters. */
function randomText(rand, max) {
  const pool = ['a', 'Z', ' ', '\n', '\r\n', '\t', 'é', '✓', '—', '𝄞', '😀', '\u{feff}', '"', '\\', '{'];
  let s = '', n = Math.floor(rand() * max);
  while (n-- > 0) s += pool[Math.floor(rand() * pool.length)];
  return s;
}
function seeded(seed) { return () => ((seed = (seed * 1103515245 + 12345) % 2 ** 31) / 2 ** 31); }

test('T24 · every moved body round-trips byte-exactly through persist, reference and resolve (property)', async () => {
  const host = fakeHost(), bodies = createBodyService({invoke: host.invoke});
  const rand = seeded(24);
  for (let i = 0; i < 60; i++) {
    const texts = [randomText(rand, 400), randomText(rand, 50), '', randomText(rand, 2000)];
    const data = conversation({attachments: [{name: 'a.txt', content: texts[0]}], files: [{name: 'b.txt', content: texts[1]}],
      proposals: [{text: 'p', recovery: recovery('src/x.js', texts[2], texts[3])}]});
    const owner = `conv:${botKey('p')}:${i}`;
    await bodies.persist(owner, bodySlots(data).map(s => valueAt(data, s.path)));
    const {data: slim, unpersisted} = bodies.slim(data, owner);
    assert.deepEqual(unpersisted, []);
    for (const s of bodySlots(slim)) assert.ok(isBodyRef(valueAt(slim, s.path)), 'every file body is a reference');
    const fresh = createBodyService({invoke: host.invoke});
    const {data: back, problems} = await fresh.resolve(slim, owner);
    assert.deepEqual(problems, []);
    assert.equal(JSON.stringify(back), JSON.stringify(data));
  }
});

test('T24 · a body whose host digest disagrees with the page\'s is never referenced', async () => {
  const bodies = createBodyService({invoke: async () => ({state: 'stored', sha256: 'f'.repeat(64), bytes: 5})});
  await assert.rejects(bodies.persist('conv:k:1', ['hello']), /different bytes/);
  assert.equal(bodies.refFor('conv:k:1', 'hello'), null);
  assert.equal(bodies.stateOf('conv:k:1', 'hello'), 'failed');
});

test('T24 · an unpaired surrogate is refused rather than stored inexactly', async () => {
  const bodies = createBodyService({invoke: fakeHost().invoke});
  await assert.rejects(bodies.persist('conv:k:1', ['bad \ud800 text']), /cannot be stored exactly/);
});

test('T24 · a reference is owned by the conversation that holds it: another conversation persists it again', async () => {
  const host = fakeHost(), bodies = createBodyService({invoke: host.invoke});
  await bodies.persist('conv:k:A', ['shared']);
  const {unpersisted} = bodies.slim(conversation({attachments: [{name: 's', content: 'shared'}]}), 'conv:k:B');
  assert.deepEqual(unpersisted, ['shared'], 'B may not borrow A\'s reference');
  await bodies.persist('conv:k:B', ['shared']);
  assert.ok(host.owners.get('conv:k:B').has(hex('shared')));
});

test('T24 · store version 2: a version-1 store loads, every write is version 2, and a malformed reference is refused', () => {
  const v1 = {version: 1, selected: {}, conversations: [{id: 'c1', revision: 1, provider: 'claude', title: 't', updated: '2026-09-27T00:00:00Z',
    data: conversation({attachments: [{name: 'a', content: 'inline'}]})}]};
  const storage = fakeStorage(Infinity, {[STORAGE_KEY]: JSON.stringify(v1)});
  const store = createConversationStore(storage);
  assert.equal(store.error, null);
  assert.equal(store.get('claude', 'c1').messages[0].attachments[0].content, 'inline');
  store.update('claude', 'c1', {pinned: true});
  assert.equal(JSON.parse(storage.getItem(STORAGE_KEY)).version, 2);
  const bad = structuredClone(v1); bad.conversations[0].data.messages[0].attachments[0].content = {schema: BODY_SCHEMA, sha256: 'nothex', bytes: 1};
  assert.match(createConversationStore(fakeStorage(Infinity, {[STORAGE_KEY]: JSON.stringify(bad)})).error, /digest/);
});

test('T24 · quota: the r3 shape cannot be saved inline, and saves as references', async () => {
  const big = n => 'x'.repeat(n);
  const data = conversation({attachments: [{name: 'bots.js', content: big(69000)}, {name: 'development.js', content: big(61000) + 'y'}],
    proposals: [{text: 'p', recovery: recovery('cockpit/ui/development.js', big(61000) + 'y', big(62000) + 'z')}]});
  const quota = 400_000; // bytes: the inline record is ~0.9 MB in UTF-16
  // Without bodies: refused, and the error is thrown to the caller.
  assert.throws(() => storeOn(fakeStorage(quota), 'r3', null).save('claude', null, data), /Could not save locally/);
  // With bodies: the inline commit is refused, the NEW bodies become placeholders, the record is committed, then
  // written, then rewritten as references.
  const host = fakeHost(), bodies = createBodyService({invoke: host.invoke}), storage = fakeStorage(quota);
  const store = storeOn(storage, 'r3', bodies);
  const id = store.save('claude', null, data);
  assert.equal(store.outcome(id).ok, true);
  assert.ok(store.outcome(id).pending.length > 0, 'saved with placeholders first');
  const first = store.get('claude', id);
  assert.ok(bodySlots(first).every(s => valueAt(first, s.path)?.pending === true));
  await settle();
  const after = store.get('claude', id);
  assert.ok(bodySlots(after).every(s => isBodyRef(valueAt(after, s.path)) && !valueAt(after, s.path).pending), 'rewritten as references');
  // A restart: new service, new store object, only what is in storage and the host.
  const reopened = storeOn(storage, 'r3', createBodyService({invoke: host.invoke}));
  const {data: back, problems} = await createBodyService({invoke: host.invoke}).resolve(reopened.get('claude', id), bodyOwner(botKey('r3'), id));
  assert.deepEqual(problems, []);
  assert.equal(JSON.stringify(back.entries[1].proposals), JSON.stringify(data.entries[1].proposals));
  assert.equal(back.messages[0].attachments[1].content, data.messages[0].attachments[1].content);
});

test('T24 · a body the committed record already holds inline is never replaced by a placeholder', () => {
  const host = fakeHost(), bodies = createBodyService({invoke: host.invoke});
  const storage = fakeStorage(Infinity), store = storeOn(storage, 'q', null);
  const legacy = 'L'.repeat(30000);
  const id = store.save('claude', null, conversation({attachments: [{name: 'legacy', content: legacy}]}));
  // Now storage is nearly full, and a save with a new large body is attempted through a bodies-aware store.
  const used = [...storage.map].reduce((n, [k, v]) => n + 2 * (k.length + v.length), 0);
  const tight = fakeStorage(used + 20_000, Object.fromEntries(storage.map));
  const aware = storeOn(tight, 'q', bodies);
  const next = conversation({attachments: [{name: 'legacy', content: legacy}, {name: 'new', content: 'N'.repeat(30000)}]});
  aware.save('claude', id, next);
  const saved = aware.get('claude', id);
  assert.equal(saved.messages[0].attachments[0].content, legacy, 'the committed inline body stayed inline');
  assert.equal(saved.messages[0].attachments[1].content.pending, true, 'only the new body became a placeholder');
});

test('T24 · when even the slim record cannot be saved, the save throws, the outcome says so and storage is unchanged', () => {
  const bodies = createBodyService({invoke: fakeHost().invoke});
  const storage = fakeStorage(1_000, {other: 'z'.repeat(480)});
  const store = storeOn(storage, 'full', bodies);
  const before = JSON.stringify([...storage.map]);
  let id = null;
  assert.throws(() => { id = store.save('claude', null, conversation({attachments: [{name: 'a', content: 'x'.repeat(5000)}]})); }, /Could not save locally/);
  assert.equal(JSON.stringify([...storage.map]), before);
});

test('T24 · a delayed refresh works on storage as it is now, and never overwrites a sibling\'s newer save', async () => {
  let release;
  const gate = new Promise(r => { release = r; });
  const host = fakeHost();
  const slowInvoke = async (cmd, arg) => { if (arg.request.operation === 'put') await gate; return host.invoke(cmd, arg); };
  const bodies = createBodyService({invoke: slowInvoke}), storage = fakeStorage(Infinity);
  const a = storeOn(storage, 'shared', bodies), b = storeOn(storage, 'shared', bodies);
  const id1 = a.save('claude', null, conversation({attachments: [{name: 'x', content: 'first body'}]}));
  // A sibling store object (another view of the same key) saves a second conversation meanwhile.
  const b2 = storeOn(storage, 'shared', null);
  const id2 = b2.save('claude', null, conversation({attachments: [{name: 'y', content: 'second'}]}));
  release(); await settle(8);
  const final = storeOn(storage, 'shared', null);
  assert.ok(final.get('claude', id2), 'the sibling\'s conversation survived the delayed refresh');
  assert.ok(isBodyRef(final.get('claude', id1).messages[0].attachments[0].content), 'and the first was rewritten as a reference');
  void b;
});

test('T24 · deleting a conversation commits first and then releases only its own bodies', async () => {
  const host = fakeHost(), bodies = createBodyService({invoke: host.invoke}), storage = fakeStorage(Infinity);
  const store = storeOn(storage, 'del', bodies);
  const idA = store.save('claude', null, conversation({attachments: [{name: 's', content: 'shared'}]}));
  const idB = store.save('claude', null, conversation({attachments: [{name: 's', content: 'shared'}]}));
  await settle();
  const r = await store.remove('claude', idA);
  assert.equal(r.released, 1);
  assert.equal(store.get('claude', idA), null);
  assert.ok(host.owners.get(bodyOwner(botKey('del'), idB)).has(hex('shared')), 'B still owns the shared body');
  // A release that fails leaves the record deleted and says so (the caller reports it).
  const failing = storeOn(storage, 'del', createBodyService({invoke: async (c, a) => { if (a.request.operation === 'release') throw new Error('busy'); return host.invoke(c, a); }}));
  await assert.rejects(failing.remove('claude', idB), /busy/);
  assert.equal(storeOn(storage, 'del', null).get('claude', idB), null);
});

test('T24 · a delete the storage refuses releases nothing: the conversation and its bodies stay', async () => {
  const host = fakeHost(), bodies = createBodyService({invoke: host.invoke}), storage = fakeStorage(Infinity);
  const store = storeOn(storage, 'keep', bodies);
  const id = store.save('claude', null, conversation({attachments: [{name: 'a', content: 'still needed'}]}));
  await settle();
  const owner = bodyOwner(botKey('keep'), id);
  assert.ok(host.owners.get(owner)?.size, 'owned before the delete');
  const refusing = {getItem: storage.getItem, setItem: () => { throw new Error('QuotaExceededError'); }};
  const failing = createConversationStore({getItem: k => refusing.getItem(k === STORAGE_KEY ? botKey('keep') : k), setItem: (k, v) => refusing.setItem(k, v)}, {bodies, key: botKey('keep')});
  assert.throws(() => failing.remove('claude', id), /Could not save locally/);
  await settle();
  assert.ok(host.owners.get(owner)?.size, 'a delete that did not commit released nothing');
  assert.ok(storeOn(storage, 'keep', null).get('claude', id), 'and the conversation is still there');
});

test('T24 · a missing, corrupt or pending body is reported per slot and never replaced by other text', async () => {
  const host = fakeHost(), bodies = createBodyService({invoke: host.invoke});
  const data = conversation({attachments: [{name: 'a.txt', content: 'AAA'}], proposals: [{text: 'p', recovery: recovery('src/x.js', 'draft', 'content')}]});
  await bodies.persist('conv:k:1', ['AAA', 'draft', 'content']);
  const {data: slim} = bodies.slim(data, 'conv:k:1');
  host.lose(hex('AAA')); host.corrupt(hex('content'));
  const withPending = structuredClone(slim);
  withPending.entries[1].proposals[0].recovery.original = {schema: BODY_SCHEMA, pending: true, pending_id: 'gone-1', bytes: 5};
  const {data: back, problems} = await createBodyService({invoke: host.invoke}).resolve(withPending, 'conv:k:1');
  const byKind = Object.fromEntries(problems.map(p => [p.kind, p.state]));
  assert.deepEqual(byKind, {'attachment': 'missing', 'proposal content': 'corrupt', 'proposal original': 'pending'});
  assert.ok(isBodyRef(back.messages[0].attachments[0].content), 'an unresolvable slot keeps its reference');
  assert.equal(back.entries[1].proposals[0].recovery.draft, 'draft', 'what does resolve, resolves');
  assert.match(problemText({kind: 'attachment', name: 'a.txt', state: 'missing'}), /missing from this device/);
  assert.match(problemText({kind: 'proposal content', state: 'corrupt'}), /no longer matches its recorded digest/);
  assert.match(problemText({kind: 'proposal original', state: 'pending'}), /not saved to this device before Super closed/);
});

test('T24 · a recovery record with references keeps its basis, patch, provenance and supersession; resolved, it validates whole', async () => {
  const draft = 'const a = 1;\n', content = 'const a = 2;\n';
  const patch = {schema: PATCH_SCHEMA, edits: [{old_text: 'a = 1', new_text: 'a = 2'}]};
  const host = fakeHost(), bodies = createBodyService({invoke: host.invoke}), storage = fakeStorage(Infinity);
  const store = storeOn(storage, 'prov', bodies);
  const p = {text: 'Proposed patch', recovery: recovery('src/a.js', draft, content, {patch}),
    provenance: {provider: 'claude', model: 'claude-opus-5-5[1m]', request_id: 'req-1', received_at: '2026-09-27T23:00:00Z'},
    supersedes: [{entry: 1, index: 0}], superseded_by: {entry: 5, index: 1}};
  const validPatch = validateRecovery(p.recovery); // the sample must itself be a valid patch record: no silent skip
  assert.ok(validPatch.patch);
  const data = conversation({proposals: [p]});
  const id = store.save('claude', null, data);
  await settle();
  const saved = store.get('claude', id).entries[1].proposals[0];
  assert.ok(isBodyRef(saved.recovery.content) && isBodyRef(saved.recovery.draft));
  assert.deepEqual(saved.recovery.source, data.entries[1].proposals[0].recovery.source, 'the basis stays inline');
  assert.deepEqual(saved.recovery.patch, validPatch.patch, 'the exact patch stays inline');
  assert.deepEqual(saved.provenance, p.provenance);
  assert.deepEqual(saved.supersedes, p.supersedes);
  assert.deepEqual(saved.superseded_by, p.superseded_by);
  const {data: back} = await createBodyService({invoke: host.invoke}).resolve(store.get('claude', id), bodyOwner(botKey('prov'), id));
  assert.equal(validateRecovery(back.entries[1].proposals[0].recovery).content, content);
  // Shape checks: a malformed position or provenance is refused, not dropped.
  assert.throws(() => validateRecoveryShape({...saved.recovery, path: '../x'}), /Invalid recovery path/);
  const broken = storeOn(fakeStorage(Infinity, {[botKey('bad')]: JSON.stringify({version: 2, selected: {}, conversations: [{id: 'c', provider: 'claude', title: 't', updated: 'u',
    data: conversation({proposals: [{...p, superseded_by: {entry: -1, index: 0}}]})}]})}), 'bad', null);
  assert.match(broken.error, /position/);
});

/* ── migration ─────────────────────────────────────────────────────────────── */

function v1Store(n = 2) {
  const conversations = [];
  for (let i = 0; i < n; i++) conversations.push({id: `c${i}`, revision: 3, provider: 'claude', title: `t${i}`, pinned: false, titleSource: 'ai', updated: `2026-09-2${i}T00:00:00Z`,
    data: conversation({attachments: [{name: 'bots.js', content: `// bots ${i}\r\n` + 'b'.repeat(5000)}], files: [{name: 'd.md', content: `draft ${i} é𝄞`}],
      proposals: [{text: 'p', recovery: recovery('cockpit/ui/x.js', `draft ${i}\n`, `content ${i}\n`)}, 'history only']})});
  return JSON.stringify({version: 1, selected: {claude: 'c1'}, conversations});
}

test('T24 · migration moves every body, keeps the original as a verified blob, and the result resolves to exactly the original', async () => {
  const raw = v1Store();
  const storage = fakeStorage(Infinity, {[botKey('m')]: raw, 'unrelated': 'keep me'});
  const host = fakeHost(), bodies = createBodyService({invoke: host.invoke});
  const [r] = await migrateConversationStores(storage, bodies);
  assert.equal(r.state, 'migrated', JSON.stringify(r));
  assert.ok(r.after < r.before / 2);
  assert.equal(host.blobs.get(r.original.sha256), raw, 'the original is kept byte-identical outside localStorage');
  assert.ok(host.owners.get(`migration:${botKey('m')}`).has(r.original.sha256));
  const now = JSON.parse(storage.getItem(botKey('m')));
  assert.equal(now.version, 2);
  const parsed = JSON.parse(raw);
  for (const [i, c] of now.conversations.entries()) {
    const {data, problems} = await createBodyService({invoke: host.invoke}).resolve(c.data, bodyOwner(botKey('m'), c.id));
    assert.deepEqual(problems, []);
    assert.equal(JSON.stringify(data), JSON.stringify(parsed.conversations[i].data));
  }
  assert.equal(storage.getItem('unrelated'), 'keep me');
  assert.equal(JSON.parse(storage.getItem(MIGRATION_RECEIPTS))[0].original.sha256, r.original.sha256);
  // A second run has nothing to move.
  assert.equal((await migrateKey(storage, botKey('m'), bodies)).state, 'nothing to move');
});

for (const [name, host, detail] of [
  ['the original cannot be stored', fakeHost({failPut: r => r.kind === 'original'}), /disk full/],
  ['a body cannot be stored', fakeHost({failPut: r => r.text.startsWith('// bots 1')}), /disk full/],
]) {
  test(`T24 · migration interrupted (${name}) leaves the key byte-identical, and a second run completes`, async () => {
    const raw = v1Store(), storage = fakeStorage(Infinity, {[botKey('m')]: raw});
    const [r] = await migrateConversationStores(storage, createBodyService({invoke: host.invoke}));
    assert.equal(r.state, 'failed'); assert.match(r.detail, detail);
    assert.equal(storage.getItem(botKey('m')), raw);
    const [again] = await migrateConversationStores(storage, createBodyService({invoke: fakeHost().invoke}));
    assert.equal(again.state, 'migrated');
  });
}

test('T24 · migration whose verification read-back is wrong leaves the key byte-identical', async () => {
  const raw = v1Store(), storage = fakeStorage(Infinity, {[botKey('m')]: raw});
  const host = fakeHost();
  let puts = 0;
  const lying = async (c, a) => {
    const r = await host.invoke(c, a);
    if (a.request.operation === 'put' && ++puts === 3) host.lose(r.sha256); // stored, then gone before verification
    return r;
  };
  const [r] = await migrateConversationStores(storage, createBodyService({invoke: lying}));
  assert.equal(r.state, 'verification failed');
  assert.equal(storage.getItem(botKey('m')), raw);
});

test('T24 · a save between migration\'s read and its write aborts the replace (compare-and-set)', async () => {
  const raw = v1Store(), storage = fakeStorage(Infinity, {[botKey('m')]: raw});
  let touched = false;
  const host = fakeHost({beforePut: () => { if (!touched) { touched = true; storage.setItem(botKey('m'), raw.replace('"t0"', '"t0 renamed"')); } }});
  const [r] = await migrateConversationStores(storage, createBodyService({invoke: host.invoke}));
  assert.equal(r.state, 'changed during migration');
  assert.match(storage.getItem(botKey('m')), /t0 renamed/, 'the concurrent save stands');
});

test('T24 · a migration whose write is refused leaves the key byte-identical', async () => {
  const raw = v1Store();
  const storage = fakeStorage(Infinity, {[botKey('m')]: raw});
  const refusing = {...storage, get length() { return storage.length; }, key: storage.key, getItem: storage.getItem, setItem: () => { throw new Error('QuotaExceededError'); }};
  const [r] = await migrateConversationStores(refusing, createBodyService({invoke: fakeHost().invoke}));
  assert.equal(r.state, 'write refused');
  assert.equal(storage.getItem(botKey('m')), raw);
});

test('T24 · a store that does not load is not migrated and is left exactly as it is', async () => {
  const bad = JSON.stringify({version: 7, conversations: []});
  const storage = fakeStorage(Infinity, {[botKey('m')]: bad});
  const [r] = await migrateConversationStores(storage, createBodyService({invoke: fakeHost().invoke}));
  assert.equal(r.state, 'not loadable');
  assert.equal(storage.getItem(botKey('m')), bad);
});

test('T24 · the real store shape fits after migration where it did not before', async () => {
  // 1.1 MB of attachments and bodies in one key, against a 2 MB quota: v1 is over, v2 is well under.
  const conversations = [];
  for (let i = 0; i < 8; i++) conversations.push({id: `c${i}`, revision: 1, provider: 'claude', title: 't', updated: 'u',
    data: conversation({attachments: [{name: 'f.js', content: `${i}`.repeat(60000)}], proposals: [{text: 'p', recovery: recovery('a.js', `${i}d`.repeat(20000), `${i}c`.repeat(20000))}]})});
  const raw = JSON.stringify({version: 1, selected: {}, conversations});
  assert.ok(2 * raw.length > 2_000_000);
  const storage = fakeStorage(Infinity, {[botKey('big')]: raw});
  const [r] = await migrateConversationStores(storage, createBodyService({invoke: fakeHost().invoke}));
  assert.equal(r.state, 'migrated');
  assert.ok(2 * storage.getItem(botKey('big')).length < 100_000, `after: ${2 * storage.getItem(botKey('big')).length} bytes`);
});
