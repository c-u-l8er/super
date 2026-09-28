/* T24 · the downgrade (rollback aid): version 2 back to version 1, bodies re-inlined, nothing invented. */
import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, dirname} from 'node:path';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {DatabaseSync} from 'node:sqlite';
import {downgradeValue, blobReader, QUOTA_BYTES} from './lib/conversation-downgrade.mjs';
import {createBodyService, BODY_SCHEMA} from '../cockpit/ui/conversation-bodies.js';
import {migrateKey} from '../cockpit/ui/conversation-migration.js';
import {RECOVERY_SCHEMA} from '../cockpit/ui/proposal-recovery.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const hex = s => createHash('sha256').update(Buffer.from(s, 'utf8')).digest('hex');
const KEY = 'super-conversations-v1:bot:dg';

/* An in-memory host with bodies.rs's contract, whose blobs can be read back as files would be. */
function host() {
  const blobs = new Map();
  return {
    blobs,
    read: blobReader(sha => { if (!blobs.has(sha)) throw Error('ENOENT'); return Buffer.from(blobs.get(sha), 'utf8'); }),
    invoke: async (cmd, {request: r}) => {
      if (r.operation === 'put') { const d = hex(r.text); blobs.set(d, r.text); return {state: 'stored', sha256: d, bytes: Buffer.byteLength(r.text)}; }
      if (r.operation === 'get') return blobs.has(r.sha256) ? {state: 'available', sha256: r.sha256, text: blobs.get(r.sha256)} : {state: 'missing'};
      return {};
    },
  };
}
const basis = (path, draft) => ({schema: 'selected-file-basis@1', basis_id: 'b'.repeat(64), head: 'h'.repeat(40), path, draft_sha256: hex(draft), disk_sha256: hex(draft)});
function v1(n = 2) {
  const conversations = [];
  for (let i = 0; i < n; i++) conversations.push({id: `c${i}`, revision: 2, provider: 'claude', title: `t${i}`, pinned: false, titleSource: 'ai', updated: `2026-09-2${i}T00:00:00Z`,
    data: {messages: [{role: 'user', content: 'Change it', attachments: [{name: 'f.js', content: `// file ${i} é𝄞\r\n` + 'x'.repeat(3000)}]}, {role: 'assistant', content: 'Here', attachments: []}],
      entries: [{role: 'user', label: 'You', text: 'Change it', referenceWorld: null, proposals: []},
        {role: 'assistant', label: 'Bot · claude', text: 'Here', referenceWorld: null, proposals: [
          {text: 'Proposed', recovery: {schema: RECOVERY_SCHEMA, path: 'src/a.js', content: `content ${i}\n`, draft: `draft ${i}\n`, original: `draft ${i}\n`, source: basis('src/a.js', `draft ${i}\n`), task: null}}, 'history only']}],
      draft: '', files: [{name: 'd.md', content: `draft file ${i}`}], includeContext: true, replyPending: false}});
  return JSON.stringify({version: 1, selected: {claude: 'c1'}, conversations});
}
async function migrated(raw) {
  const h = host(), map = new Map([[KEY, raw]]);
  const storage = {get length() { return map.size; }, key: i => [...map.keys()][i], getItem: k => map.get(k) ?? null, setItem: (k, v) => map.set(k, v)};
  const r = await migrateKey(storage, KEY, createBodyService({invoke: h.invoke}));
  assert.equal(r.state, 'migrated');
  return {h, v2: map.get(KEY)};
}

test('T24 downgrade · a migrated store comes back byte-identical to the original, and loads', async () => {
  const raw = v1();
  const {h, v2} = await migrated(raw);
  assert.equal(JSON.parse(v2).version, 2);
  const r = downgradeValue(v2, h.read);
  assert.equal(r.state, 'downgraded');
  assert.equal(r.value, raw, 'byte-identical to the pre-migration value');
  assert.equal(r.inlined, 2 * 5);
});

test('T24 downgrade · a missing, corrupt or pending body refuses the key, naming the slot', async () => {
  const {h, v2} = await migrated(v1());
  const refs = JSON.parse(v2).conversations[0].data;
  h.blobs.delete(refs.messages[0].attachments[0].content.sha256);
  const r = downgradeValue(v2, h.read);
  assert.equal(r.state, 'refused');
  assert.match(r.problems.join('\n'), /c0: attachment f\.js is missing/);
  const corrupt = await migrated(v1());
  const d = JSON.parse(corrupt.v2).conversations[1].data.entries[1].proposals[0].recovery.content.sha256;
  corrupt.h.blobs.set(d, 'something else');
  assert.match(downgradeValue(corrupt.v2, corrupt.h.read).problems.join('\n'), /c1: proposal content src\/a\.js is corrupt/);
  const pending = JSON.parse(v2);
  pending.conversations[1].data.files[0].content = {schema: BODY_SCHEMA, pending: true, pending_id: 'p-1', bytes: 3};
  assert.match(downgradeValue(JSON.stringify(pending), h.read).problems.join('\n'), /c1: draft file d\.md is pending/);
});

test('T24 downgrade · with --drop-unrecoverable the loss is explicit: history-only proposal, attachment removed, each reported', async () => {
  const {h, v2} = await migrated(v1());
  const data = JSON.parse(v2).conversations[0].data;
  h.blobs.delete(data.entries[1].proposals[0].recovery.content.sha256);
  h.blobs.delete(data.messages[0].attachments[0].content.sha256);
  const r = downgradeValue(v2, h.read, {dropUnrecoverable: true});
  assert.equal(r.state, 'downgraded');
  const out = JSON.parse(r.value).conversations[0].data;
  assert.equal(out.entries[1].proposals[0], 'Proposed', 'the proposal keeps its text as history');
  assert.deepEqual(out.messages[0].attachments, []);
  assert.equal(r.dropped.length, 2);
  assert.match(r.dropped.join('\n'), /kept as history only/);
  // The other conversation is untouched and whole.
  assert.equal(JSON.stringify(JSON.parse(r.value).conversations[1]), JSON.stringify(JSON.parse(v1()).conversations[1]));
});

test('T24 downgrade · version 1 is left alone; version 2 without references still becomes version 1', () => {
  assert.equal(downgradeValue(v1(), () => ({state: 'missing'})).state, 'unchanged');
  const plain = JSON.stringify({...JSON.parse(v1()), version: 2});
  const r = downgradeValue(plain, () => ({state: 'missing'}));
  assert.equal(r.state, 'downgraded');
  assert.equal(JSON.parse(r.value).version, 1);
});

test('T24 downgrade · the build being rolled back TO gets the last word', async () => {
  const {h, v2} = await migrated(v1());
  const refuses = () => ({error: 'Saved conversation format is not supported.'});
  const r = downgradeValue(v2, h.read, {validateWith: refuses});
  assert.equal(r.state, 'refused');
  assert.match(r.problems.join('\n'), /does not load: Saved conversation format is not supported/);
});

/* The CLI on a real sqlite file laid out as WebKit lays it out. */
function device(values, blobs) {
  const dir = mkdtempSync(join(tmpdir(), 't24-downgrade-'));
  mkdirSync(join(dir, 'localstorage')); mkdirSync(join(dir, 'conversation-bodies', 'blobs'), {recursive: true});
  const db = new DatabaseSync(join(dir, 'localstorage', 'tauri_localhost_0.localstorage'));
  db.exec('CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB NOT NULL ON CONFLICT FAIL)');
  const ins = db.prepare('INSERT INTO ItemTable (key, value) VALUES (?, ?)');
  for (const [k, v] of Object.entries(values)) ins.run(k, Buffer.from(v, 'utf16le'));
  db.close();
  for (const [d, t] of blobs) writeFileSync(join(dir, 'conversation-bodies', 'blobs', d), t);
  return dir;
}
const cli = (...a) => { try { return {code: 0, out: JSON.parse(execFileSync('node', [join(HERE, 'conversation-bodies-downgrade.mjs'), ...a], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore']}))}; }
  catch (e) { return {code: e.status, out: JSON.parse(e.stdout)}; } };
const stored = (dir, key) => { const db = new DatabaseSync(join(dir, 'localstorage', 'tauri_localhost_0.localstorage'), {readOnly: true}); const v = Buffer.from(db.prepare('SELECT value FROM ItemTable WHERE key = ?').get(key).value).toString('utf16le'); db.close(); return v; };

test('T24 downgrade · the CLI: a dry run writes nothing; --write backs up, writes, reads back; a second run has nothing to do', async () => {
  const raw = v1();
  const {h, v2} = await migrated(raw);
  const dir = device({[KEY]: v2, 'other-key': 'untouched'}, h.blobs);
  const dry = cli('--device', dir);
  assert.equal(dry.code, 0); assert.match(dry.out.result, /dry run: 1 key/);
  assert.equal(stored(dir, KEY), v2, 'the dry run changed nothing');
  const w = cli('--device', dir, '--write');
  assert.equal(w.code, 0, JSON.stringify(w.out));
  assert.equal(stored(dir, KEY), raw, 'now the original version-1 value, byte for byte');
  assert.equal(stored(dir, 'other-key'), 'untouched');
  assert.equal(w.out.read_back, 'every written value reads back exactly');
  assert.equal(JSON.parse(readFileSync(w.out.backup, 'utf8')).values[KEY], v2, 'the version-2 value was kept first');
  assert.ok(readdirSync(join(dir, 'conversation-bodies', 'blobs')).length > 0, 'the body store is untouched');
  const again = cli('--device', dir, '--write');
  assert.equal(again.code, 0); assert.equal(again.out.keys[0].state, 'unchanged');
});

test('T24 downgrade · the CLI refuses a result over WebKit\'s quota unless told otherwise, and refuses a missing body', async () => {
  const {h, v2} = await migrated(v1());
  const filler = '—'.repeat(Math.floor(QUOTA_BYTES / 2) - 4000); // U+2014 is not Latin-1: 2 bytes per character in WebKit's accounting (é is Latin-1, 1 byte)
  const dir = device({[KEY]: v2, filler}, h.blobs);
  const r = cli('--device', dir, '--write');
  assert.equal(r.code, 1); assert.equal(r.out.over_quota, true); assert.match(r.out.error, /refuse every save/);
  assert.equal(stored(dir, KEY), v2);
  assert.equal(cli('--device', dir, '--write', '--allow-over-quota').code, 0);
  const lost = await migrated(v1());
  lost.h.blobs.delete(JSON.parse(lost.v2).conversations[0].data.files[0].content.sha256);
  const d2 = device({[KEY]: lost.v2}, lost.h.blobs);
  const refused = cli('--device', d2, '--write');
  assert.equal(refused.code, 1); assert.match(refused.out.error, /cannot be downgraded/);
  assert.equal(stored(d2, KEY), lost.v2);
  assert.ok(!existsSync(join(d2, 'conversation-bodies', 'downgrade-backup')));
});
