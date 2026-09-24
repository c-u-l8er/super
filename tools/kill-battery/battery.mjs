#!/usr/bin/env node
/* kill-battery — random SIGKILLs of ampd during continuous effects, and what the world recovers.
 *
 * The acceptance test named in wek/b2/trvm/JOURNAL_BRIEF.md §6 item 4, written against TODAY's store
 * first, because a battery that cannot fail proves nothing. Per kill it counts:
 *   · a SEAL from an ordinary crash (the runtime boots sealed, or refuses to boot at all);
 *   · an INVENTED transition (an effect, receipt or consumption nothing acknowledged or started, an
 *     illegal history, a second receipt for one effect);
 *   · a LOST acknowledged transition (an acknowledged effect missing, not COMMITTED, without its
 *     receipt, or its grant not consumed by it; an acknowledged grant missing);
 *   · a TORN witness tail, and whether anything named it.
 *
 *   node tools/kill-battery/battery.mjs            (env below; results go to KB_OUT)
 *
 * KB_BASE     directory on the filesystem under test; one world per lineage is made inside it
 * KB_OUT      results directory (kept)                         KB_KILLS    kills to make (36)
 * KB_DELAY    "min,max" seconds after the loop starts (0.05,4)   KB_RNG_SEED delay seed (20260924)
 * KB_KEEP=1   keep the worlds (default: removed at the end; evidence is the reports and results)
 *
 * A LINEAGE is one world: seeded once, then killed and rebooted until a kill ends it (a seal, a
 * refused boot) or the battery ends. History grows by REAL effects across kills, never injected.
 * Only a whole-BEAM SIGKILL can leave a DETS table dirty; killing a process inside the VM lets the
 * table's owner close it cleanly, so this kills the BEAM's OS pid, from outside.
 */
import {spawn, execFileSync} from 'node:child_process';
import {mkdirSync, readFileSync, writeFileSync, existsSync, readdirSync, cpSync, rmSync, statSync} from 'node:fs';
import {join, resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {tmpdir} from 'node:os';
import {check} from './check.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const AMPD = resolve(HERE, '../../ampd');
const BASE = resolve(process.env.KB_BASE ?? join(tmpdir(), 'kill-battery'));
const OUT = resolve(process.env.KB_OUT ?? join(BASE, 'results'));
const KILLS = Number(process.env.KB_KILLS ?? 36);
const [DMIN, DMAX] = (process.env.KB_DELAY ?? '0.05,4').split(',').map(Number);
const SEED = Number(process.env.KB_RNG_SEED ?? 20260924);
const BOOT_TIMEOUT_MS = 120_000;
mkdirSync(BASE, {recursive: true}); mkdirSync(OUT, {recursive: true});

const rng = (a => () => { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; })(SEED);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const lines = f => existsSync(f) ? readFileSync(f, 'utf8').split('\n').filter(Boolean).flatMap(l => { try { return [JSON.parse(l)]; } catch { return []; } }) : [];
const fsType = execFileSync('stat', ['-f', '-c', '%T', BASE], {encoding: 'utf8'}).trim();

/* The raw state of every table, read from a COPY with repair:false and read access — the question
   "is this table dirty" answered without the runtime, so a refused boot still says which table. */
const rawDets = dataDir => {
  const copy = join(BASE, '.raw-check'); rmSync(copy, {recursive: true, force: true}); mkdirSync(copy);
  const files = readdirSync(dataDir).filter(f => f.endsWith('.dets'));
  for (const f of files) cpSync(join(dataDir, f), join(copy, f));
  const erl = `Fs = [${files.map(f => JSON.stringify(join(copy, f))).join(',')}], ` +
    `lists:foreach(fun(F) -> R = case dets:open_file(make_ref(), [{file, F}, {access, read}, {repair, false}]) of ` +
    `{ok, T} -> dets:close(T), ok; {error, {needs_repair, _}} -> needs_repair; {error, {not_closed, _}} -> not_closed; ` +
    `{error, E} -> {error, E} end, io:format("~s ~p~n", [filename:basename(F), R]) end, Fs), halt().`;
  const out = execFileSync('erl', ['-noshell', '-eval', erl], {encoding: 'utf8'});
  rmSync(copy, {recursive: true, force: true});
  return Object.fromEntries(out.trim().split('\n').filter(Boolean).map(l => { const [f, ...r] = l.split(' '); return [f.replace('.dets', ''), r.join(' ')]; }));
};

/* The authority log's raw state (`Ampd.AuthorityLog`, when the tree under test has one), read from a
   COPY: its frames checked the way replay checks them — header, declared lengths, CRC-32 — without the
   runtime. `ok`, `torn` (a bad LAST frame: what replay truncates and names) or `damaged` (a bad frame
   with bytes after it: what seals). The payloads are not decoded here, so a record-sequence gap is the
   runtime's to find. */
const CRC = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
const crc32 = b => { let c = 0xFFFFFFFF; for (let i = 0; i < b.length; i++) c = CRC[(c ^ b[i]) & 0xFF] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0; };
const HEADER = Buffer.from('AMPD-AUTHORITY-LOG/1\n');
/* The retention archive (`authority.archive`, when the tree has one) is the same frames after its own
   header, and is judged the same way: a torn LAST batch is what boot truncates and names. */
const AR_HEADER = Buffer.from('AMPD-AUTHORITY-ARCHIVE/1\n');
const rawLog = dataDir => rawFrames(join(dataDir, 'authority.log'), HEADER);
const rawArchive = dataDir => rawFrames(join(dataDir, 'authority.archive'), AR_HEADER);
const rawFrames = (p, HEADER) => {
  if (!existsSync(p)) return null;
  const b = readFileSync(p); let off = HEADER.length, frames = 0;
  if (b.length < HEADER.length) return {state: 'torn', frames, bytes: b.length, torn_bytes: b.length, why: 'partial header'};
  if (!b.subarray(0, HEADER.length).equals(HEADER)) return {state: 'damaged', frames, bytes: b.length, why: 'header'};
  while (off < b.length) {
    if (b.length - off < 8) return {state: 'torn', frames, bytes: b.length, torn_bytes: b.length - off, why: 'partial frame header'};
    const len = b.readUInt32BE(off), crc = b.readUInt32BE(off + 4);
    if (b.length - off - 8 < len) return {state: 'torn', frames, bytes: b.length, torn_bytes: b.length - off, why: 'frame shorter than declared'};
    const ok = crc32(b.subarray(off + 8, off + 8 + len)) === crc, last = off + 8 + len === b.length;
    if (!ok) return last ? {state: 'torn', frames, bytes: b.length, torn_bytes: b.length - off, why: 'checksum, last frame'}
                         : {state: 'damaged', frames, bytes: b.length, why: `checksum at ${off} with bytes after`};
    off += 8 + len; frames++;
  }
  return {state: 'ok', frames, bytes: b.length};
};

/* One boot of the driver. Resolves when the loop has started (so a kill can land), or when the boot
   ended on its own (sealed, refused). */
const boot = ({world, acks, report, seed, log}) => new Promise(res => {
  const before = lines(acks).length, t0 = Date.now();
  const child = spawn('mix', ['run', '../tools/kill-battery/driver.exs'], {cwd: AMPD, stdio: ['ignore', 'pipe', 'pipe'],
    env: {...process.env, MIX_ENV: 'test', AMPD_DATA_DIR: world, AMPD_TEST_DATA_DIR: join(BASE, '.test-config'),
          KB_ACKS: acks, KB_REPORT: report, KB_SEED: seed ? '1' : '0'}});
  let text = ''; child.stdout.on('data', b => text += b); child.stderr.on('data', b => text += b);
  let done = false, exitCode = null; const exited = new Promise(r => child.on('exit', c => { exitCode = c; r(c); }));
  const finish = v => { if (!done) { done = true; res({...v, child, exited, text: () => text, exitCode: () => exitCode}); } };
  child.on('exit', () => { writeFileSync(log, text); finish({state: 'exited'}); });
  (async () => {
    for (const end = Date.now() + BOOT_TIMEOUT_MS; Date.now() < end && !done; await sleep(20)) {
      const mine = lines(acks).slice(before);
      const b = mine.find(e => e.event === 'boot');
      if (mine.some(e => e.event === 'loop_started')) return finish({state: 'looping', os_pid: Number(b.os_pid), boot_ms: Date.now() - t0});
    }
    finish({state: 'boot-timeout'});
  })();
});

const rows = [];
let lineage = 0, world = null, acks = null, bootN = 0;
const newLineage = () => { lineage++; bootN = 0; world = join(BASE, `world-${lineage}`); acks = join(OUT, `acks-L${lineage}.jsonl`); rmSync(world, {recursive: true, force: true}); mkdirSync(world, {recursive: true}); };
newLineage();
let pending = await boot({world, acks, report: join(OUT, `report-L${lineage}-b0.json`), seed: true, log: join(OUT, `boot-L${lineage}-b0.log`)});
const t0 = Date.now();
for (let k = 1; k <= KILLS; k++) {
  if (pending.state !== 'looping') throw Error(`lineage ${lineage} boot ${bootN} did not reach its loop (${pending.state}); log ${join(OUT, `boot-L${lineage}-b${bootN}.log`)}`);
  const delay = (DMIN + rng() * (DMAX - DMIN)) * 1000;
  await sleep(delay);
  try { process.kill(pending.os_pid, 'SIGKILL'); } catch {}
  await pending.exited;
  // Read AFTER the BEAM is gone and BEFORE the reboot: nothing can write between, so this is exactly
  // what was acknowledged (read before the kill, an ack landing in the gap would read as invented).
  const evBefore = lines(acks);
  const ackedAtKill = evBefore.filter(e => e.event === 'ack' && e.allow).length;
  const raw = rawDets(world);
  const alog = rawLog(world), archive = rawArchive(world);
  bootN++;
  const report = join(OUT, `report-L${lineage}-b${bootN}.json`), log = join(OUT, `boot-L${lineage}-b${bootN}.log`);
  pending = await boot({world, acks, report, seed: false, log});
  const row = {kill: k, lineage, boot: bootN, delay_ms: Math.round(delay), acked_before_kill: ackedAtKill, reboot_ms: pending.boot_ms ?? null,
    last_event_before_kill: evBefore.at(-1)?.event ?? null, raw_dets: raw,
    dirty_tables: Object.entries(raw).filter(([, v]) => v !== 'ok').map(([k]) => k), authority_log: alog, authority_archive: archive};
  if (pending.state === 'looping' || existsSync(report)) {
    const rep = JSON.parse(readFileSync(report, 'utf8'));
    row.outcome = rep.seals.length ? 'SEALED' : 'CONTINUED';
    row.seals = rep.seals;
    row.witness_torn = rep.witness.filter(w => w.torn_tail_bytes > 0).map(w => ({file: w.file, bytes: w.torn_tail_bytes}));
    row.witness_undecodable_complete_lines = rep.witness.reduce((n, w) => n + w.undecodable_complete_lines, 0);
    row.authority_log_status = rep.authority_log ?? null;
    // Only what was acknowledged BEFORE the kill: the reboot's own loop has already started writing
    // (its first grant would otherwise read as an acknowledged mint the report cannot contain).
    if (!rep.seals.length) Object.assign(row, check(rep, evBefore));
  } else {
    await pending.exited;
    const text = pending.text();
    row.outcome = 'BOOT-REFUSED';
    row.exit_code = pending.exitCode();
    row.boot_error = (text.match(/\*\* \(RuntimeError\) ([^\n]{0,260})/) ?? text.match(/\*\* \(Mix\) ([^\n]{0,260})/) ?? [null, text.slice(-300)])[1];
    row.seal_codes = [...new Set([...text.matchAll(/(RECOVERY-STATE-[A-Z]+|ORPHANED-WORLD|WORLD-META-[A-Z-]+) · ([a-z_]+)/g)].map(m => `${m[1]} · ${m[2]}`))];
  }
  rows.push(row);
  // A clean recovery's report is only the evidence that it was clean, and at tens of thousands of
  // effects each is megabytes: keep the first, the last, and every one with a finding.
  const finding = row.outcome !== 'CONTINUED' || row.lost?.length || row.invented?.length || row.split?.length;
  if (process.env.KB_KEEP_REPORTS !== 'all' && !finding && k !== 1 && k !== KILLS) rmSync(report, {force: true});
  console.log(`kill ${k}/${KILLS} L${lineage}b${bootN} +${row.delay_ms} ms · acked ${row.acked_before_kill} · dirty [${row.dirty_tables}]${alog ? ` · log ${alog.state}${alog.torn_bytes ? ' ' + alog.torn_bytes + 'B' : ''}` : ''}${archive ? ` · archive ${archive.state} ${archive.frames}b${archive.torn_bytes ? ' ' + archive.torn_bytes + 'B' : ''}` : ''} · ${row.outcome}` +
    (row.outcome === 'CONTINUED' ? ` · lost ${row.lost.length}${row.lost.length ? ' ' + JSON.stringify(row.lost.slice(0, 3)) : ''} · invented ${row.invented.length}${row.invented.length ? ' ' + JSON.stringify(row.invented.slice(0, 3)) : ''} · unrecorded ${JSON.stringify(row.unrecorded)} · in-flight ${JSON.stringify(row.inflight)}` : ` · ${row.seal_codes?.join(', ') ?? row.seals?.map(s => s.store).join(', ') ?? ''}`) +
    (row.witness_torn?.length ? ` · torn witness ${JSON.stringify(row.witness_torn)}` : ''));
  if (row.outcome !== 'CONTINUED') {
    if (pending.state === 'looping') { pending.child.kill('SIGTERM'); await pending.exited; }
    if (k < KILLS) { newLineage(); pending = await boot({world, acks, report: join(OUT, `report-L${lineage}-b0.json`), seed: true, log: join(OUT, `boot-L${lineage}-b0.log`)}); }
  }
}
if (pending.state === 'looping') { pending.child.kill('SIGTERM'); await pending.exited; }

const count = f => rows.filter(f).length;
const summary = {
  schema: 'kill-battery-result@1', when: new Date().toISOString(), wall_s: Math.round((Date.now() - t0) / 1000),
  source: {tree: resolve(HERE, '../..'), head: execFileSync('git', ['-C', resolve(HERE, '../..'), 'rev-parse', 'HEAD'], {encoding: 'utf8'}).trim(),
           dirty: execFileSync('git', ['-C', resolve(HERE, '../..'), 'status', '--porcelain'], {encoding: 'utf8'}).split('\n').filter(Boolean)},
  filesystem: {base: BASE, type: fsType}, kills: KILLS, delay_s: [DMIN, DMAX], rng_seed: SEED,
  route: 'github.pr.draft one-shot grant → Gateway.perform/4, default adapter (write-boundary C1)',
  counts: {
    continued: count(r => r.outcome === 'CONTINUED'), sealed_running: count(r => r.outcome === 'SEALED'), boot_refused: count(r => r.outcome === 'BOOT-REFUSED'),
    any_dirty_table: count(r => r.dirty_tables.length), log_torn: count(r => r.authority_log?.state === 'torn'), log_damaged: count(r => r.authority_log?.state === 'damaged'),
    archive_torn: count(r => r.authority_archive?.state === 'torn'), archive_damaged: count(r => r.authority_archive?.state === 'damaged'),
    lost_acknowledged: rows.reduce((n, r) => n + (r.lost?.length ?? 0), 0),
    invented: rows.reduce((n, r) => n + (r.invented?.length ?? 0), 0), kills_with_torn_witness: count(r => r.witness_torn?.length),
    recoveries_with_split_claim: count(r => r.split?.length), recoveries_with_conflict_listing: count(r => r.split?.some(x => x.includes('CONFLICT'))),
    recoveries_with_open_preclaim: count(r => r.open_preclaim?.length),
  },
  dirty_by_table: rows.flatMap(r => r.dirty_tables).reduce((m, t) => ({...m, [t]: (m[t] ?? 0) + 1}), {}),
  lineages: lineage, rows,
};
writeFileSync(join(OUT, 'result.json'), JSON.stringify(summary, null, 1));
console.log(JSON.stringify({filesystem: summary.filesystem, counts: summary.counts, dirty_by_table: summary.dirty_by_table, lineages: lineage}, null, 1));
if (process.env.KB_KEEP !== '1') for (let l = 1; l <= lineage; l++) rmSync(join(BASE, `world-${l}`), {recursive: true, force: true});
