#!/usr/bin/env node
/* conversation-bodies-downgrade — T24's rollback aid: every version-2 conversation store back to version 1, its file
   bodies re-inlined from the device body store, so a build before T24 can read the history again.

     node tools/conversation-bodies-downgrade.mjs [--device DIR] [--write] [--check-with TREE]
                                                  [--drop-unrecoverable] [--allow-over-quota] [--report FILE]

   --device DIR           the app data directory (default: $XDG_DATA_HOME or ~/.local/share, then
                          com.computedriven.super.cockpit). Its localstorage/ and conversation-bodies/ are read.
   (default)              a DRY RUN: every key is downgraded in memory and checked; nothing is written.
   --write                write. Refused while any process holds the localStorage file (stop Super first, with proof).
   --check-with TREE      also load every result with TREE's cockpit/ui/conversation-store.js: name the build being
                          rolled back TO (e.g. ~/build/super-rollback-… or the T23 tree), and the check is its own.
   --drop-unrecoverable   a body that is missing, corrupt or only a pending placeholder has no bytes to restore; by
                          default that refuses. With this flag the proposal keeps its text as history and loses its
                          recovery record, and the attachment or draft file is removed — each reported.
   --allow-over-quota     the version-1 stores may not fit WebKit's 5 MiB localStorage quota (T24 exists because they
                          did not). By default an over-quota result is refused: a build before T24 would load it, and
                          then refuse every save, which is how r3 lost proposals.

   Before writing, the version-2 values are saved to conversation-bodies/downgrade-backup-<time>.json. The writes are
   one sqlite transaction, read back after. The body store is never changed, so running T24 again migrates again.   */
import {readFileSync, writeFileSync, readdirSync, readlinkSync, openSync, fsyncSync, closeSync, existsSync} from 'node:fs';
import {DatabaseSync} from 'node:sqlite';
import {join, resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {downgradeValue, blobReader, isConversationKey, webkitBytes, QUOTA_BYTES} from './lib/conversation-downgrade.mjs';

const args = process.argv.slice(2);
const flag = f => args.includes(f);
const opt = f => { const i = args.indexOf(f); return i >= 0 ? args[i + 1] : null; };
const device = resolve(opt('--device') ?? join(process.env.XDG_DATA_HOME ?? join(process.env.HOME, '.local/share'), 'com.computedriven.super.cockpit'));
const dbPath = join(device, 'localstorage', 'tauri_localhost_0.localstorage');
const blobs = join(device, 'conversation-bodies', 'blobs');
const write = flag('--write');
const report = {device, mode: write ? 'write' : 'dry-run', keys: [], quota_bytes: QUOTA_BYTES};
const done = code => {
  const text = JSON.stringify(report, null, 2);
  if (opt('--report')) writeFileSync(opt('--report'), text + '\n');
  console.log(text);
  process.exit(code);
};
if (!existsSync(dbPath)) { report.error = `no localStorage at ${dbPath}`; done(2); }

/* Who holds the localStorage file? WebKit's network process does while Super runs. */
const holders = [];
for (const p of readdirSync('/proc').filter(n => /^\d+$/.test(n))) {
  let fds; try { fds = readdirSync(`/proc/${p}/fd`); } catch { continue; }
  for (const fd of fds) { let l; try { l = readlinkSync(`/proc/${p}/fd/${fd}`); } catch { continue; } if (l.startsWith(dbPath)) { holders.push(Number(p)); break; } }
}
report.holders = holders;
if (write && holders.length) { report.error = `the localStorage file is held by pid ${holders.join(', ')}: stop Super (and prove it exited) before writing`; done(1); }

let validateWith = null;
if (opt('--check-with')) {
  const tree = resolve(opt('--check-with'));
  validateWith = (await import(`${tree}/cockpit/ui/conversation-store.js`)).createConversationStore;
  report.checked_with = tree;
}

const db = new DatabaseSync(dbPath, {readOnly: !write});
const rows = db.prepare('SELECT key, value FROM ItemTable').all().map(r => ({key: r.key, value: Buffer.from(r.value).toString('utf16le')}));
const read = blobReader(sha => readFileSync(join(blobs, sha)));
const next = new Map();
for (const {key, value} of rows.filter(r => isConversationKey(r.key))) {
  const r = downgradeValue(value, read, {dropUnrecoverable: flag('--drop-unrecoverable'), validateWith});
  report.keys.push({key, state: r.state, inlined: r.inlined, problems: r.problems, dropped: r.dropped,
    chars_before: value.length, chars_after: r.value?.length ?? null, sha256_after: r.sha256 ?? null});
  if (r.state === 'downgraded') next.set(key, r.value);
}
const bytesOf = map => rows.reduce((n, {key, value}) => n + webkitBytes(key) + webkitBytes(map.get(key) ?? value), 0);
report.webkit_bytes_before = bytesOf(new Map());
report.webkit_bytes_after = bytesOf(next);
report.over_quota = report.webkit_bytes_after > QUOTA_BYTES;
const blocked = report.keys.filter(k => k.state === 'refused' || k.state === 'unreadable');
if (blocked.length) { report.error = `${blocked.length} key(s) cannot be downgraded; nothing was written`; db.close(); done(1); }
if (report.over_quota && !flag('--allow-over-quota')) {
  report.error = `the version-1 stores would be ${report.webkit_bytes_after} of ${QUOTA_BYTES} bytes: a build before T24 would load them and then refuse every save. Nothing was written`;
  db.close(); done(1);
}
if (!write) { report.result = `dry run: ${next.size} key(s) would be downgraded`; db.close(); done(0); }

// The version-2 values, kept before anything changes.
const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
const backup = join(device, 'conversation-bodies', `downgrade-backup-${stamp}.json`);
const saved = Object.fromEntries(rows.filter(r => next.has(r.key)).map(r => [r.key, r.value]));
writeFileSync(backup, JSON.stringify({schema: 'conversation-downgrade-backup@1', created: new Date().toISOString(), device, values: saved}));
{ const fd = openSync(backup, 'r'); fsyncSync(fd); closeSync(fd); }
report.backup = backup;

db.exec('BEGIN IMMEDIATE');
try {
  const update = db.prepare('UPDATE ItemTable SET value = ? WHERE key = ?');
  for (const [key, value] of next) update.run(Buffer.from(value, 'utf16le'), key);
  db.exec('COMMIT');
} catch (e) { db.exec('ROLLBACK'); report.error = `the write failed and was rolled back: ${e.message}`; db.close(); done(1); }
const check = db.prepare('SELECT value FROM ItemTable WHERE key = ?');
const mismatched = [...next].filter(([key, value]) => Buffer.from(check.get(key).value).toString('utf16le') !== value).map(([k]) => k);
db.close();
report.read_back = mismatched.length ? {mismatched} : 'every written value reads back exactly';
report.result = `wrote ${next.size} key(s) as version 1`;
report.written_sha256 = Object.fromEntries([...next].map(([k, v]) => [k, createHash('sha256').update(Buffer.from(v, 'utf8')).digest('hex')]));
done(mismatched.length ? 1 : 0);
