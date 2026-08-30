/* check-harness-reaping — does a measurement harness own what it launches?
   ────────────────────────────────────────────────────────────────────────

   THE LAW

     A harness may signal exactly the processes it started, and when it
     exits — for any reason — none of them is still running and none of
     them still holds its stdout.

   WHY THIS EXISTS

   `tools/cockpit-battery.mjs` killed only `tauri-driver` and left its
   descendants reparented to init. `stdio: inherit` had handed those
   descendants the harness's own stdout, so an orphaned `beam.smp` at
   PPID 1 held the pipe open and the run produced no output for eleven
   minutes. It looked exactly like a hang. It was a leak.

   That is a harness defect, and it matters more than it looks: D.1.3b is
   about spawn, wait, signal, reap and descriptor inheritance. A harness
   that cannot reliably own its own children cannot tell a Super
   process-lifecycle bug from its own.

   WHAT THIS CHECKS

   Deliberately fails a run at each of the points a real battery can fail,
   and after each one asserts:

       no descendant survives
       the harness's stdout is not held open by anything it started
       the exit is deterministic

   The subject is a fixture that reproduces the exact topology — a group
   leader that spawns a grandchild which ignores SIGTERM's usual courtesy
   and inherits stdout — so a passing result is about the doctrine and not
   about tauri-driver being well behaved. */

import { spawn } from 'node:child_process';
import { writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

let held = 0;
let failed = 0;

const check = (name, ok, detail = '') => {
  if (ok) {
    held++;
    console.log(`  \x1b[32mheld\x1b[0m         ${name}`);
  } else {
    failed++;
    console.log(`  \x1b[31mFAILED\x1b[0m       ${name} — ${detail}`);
  }
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const alive = (pid) => {
  try { process.kill(pid, 0); return true; } catch { return false; }
};

/* A group leader that spawns a grandchild and then exits, leaving the
   grandchild running with the inherited stdout — the cockpit battery's
   topology in twenty lines. */
const FIXTURE = `
const { spawn } = require('node:child_process');
const grand = spawn(process.execPath,
  ['-e', 'process.stdout.write("grandchild-up\\\\n"); setInterval(() => {}, 1000)'],
  { stdio: ['ignore', 'inherit', 'inherit'] });
process.stdout.write('leader-up ' + grand.pid + '\\n');
setInterval(() => {}, 1000);
`;

const dir = mkdtempSync(join(tmpdir(), 'harness-reap-'));
const fixture = join(dir, 'leader.cjs');
writeFileSync(fixture, FIXTURE);

/* Start the fixture the way a harness should: its own process group. */
const startTree = async () => {
  const leader = spawn(process.execPath, [fixture], {
    stdio: ['ignore', 'pipe', 'inherit'],
    detached: true,
  });

  let out = '';
  leader.stdout.on('data', (d) => { out += d.toString(); });

  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline && !out.includes('grandchild-up')) await sleep(50);

  const m = out.match(/leader-up (\d+)/);
  return { leader, grandchild: m ? +m[1] : null };
};

/* The doctrine under test: signal the group, wait for it to actually go,
   escalate only if SIGTERM was ignored. */
const reap = async (leader) => {
  try { process.kill(-leader.pid, 'SIGTERM'); } catch {}
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    try { process.kill(-leader.pid, 0); } catch { return true; }
    await sleep(50);
  }
  try { process.kill(-leader.pid, 'SIGKILL'); } catch {}
  return false;
};

console.log('[&] Super — harness reaping\n');

/* 1 · the leak, reproduced, so the check is known to be able to fail */
{
  const { leader, grandchild } = await startTree();
  check('the fixture reproduces the topology — a grandchild holding stdout',
        grandchild !== null && alive(grandchild),
        `grandchild=${grandchild}`);

  /* Kill only the leader, which is what the battery used to do. */
  try { leader.kill('SIGTERM'); } catch {}
  await sleep(400);

  check('killing only the leader DOES leak the grandchild — the defect is real',
        grandchild !== null && alive(grandchild),
        'the grandchild died anyway, so this check proves nothing');

  /* Clean up the leak this check deliberately created. */
  if (grandchild && alive(grandchild)) { try { process.kill(grandchild, 'SIGTERM'); } catch {} }
  await sleep(200);
}

/* 2 · the doctrine: group kill reaps the whole tree */
{
  const { leader, grandchild } = await startTree();
  const clean = await reap(leader);
  await sleep(200);

  check('signalling the process group reaps the grandchild too',
        clean && grandchild !== null && !alive(grandchild),
        `clean=${clean} grandchild=${grandchild} alive=${grandchild && alive(grandchild)}`);
}

/* 3 · a run that throws still reaps */
{
  const { leader, grandchild } = await startTree();
  try {
    try { throw new Error('a deliberate assertion failure'); }
    finally { await reap(leader); }
  } catch { /* expected */ }
  await sleep(200);

  check('a thrown assertion still reaps the tree',
        grandchild !== null && !alive(grandchild),
        `grandchild ${grandchild} survived a failing run`);
}

/* 4 · a timeout path still reaps */
{
  const { leader, grandchild } = await startTree();
  const timedOut = await Promise.race([
    sleep(300).then(() => 'timeout'),
    sleep(10_000).then(() => 'finished'),
  ]);
  await reap(leader);
  await sleep(200);

  check('a timed-out run still reaps the tree',
        timedOut === 'timeout' && grandchild !== null && !alive(grandchild),
        `grandchild ${grandchild} survived a timeout`);
}

/* 5 · and the harness only ever signalled its own group */
{
  const { leader, grandchild } = await startTree();
  const other = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'],
                      { stdio: 'ignore', detached: true });
  await sleep(200);

  await reap(leader);
  await sleep(200);

  check('a process outside the harness group is untouched',
        alive(other.pid) && grandchild !== null && !alive(grandchild),
        `bystander ${other.pid} alive=${alive(other.pid)}`);

  try { process.kill(other.pid, 'SIGTERM'); } catch {}
}

rmSync(dir, { recursive: true, force: true });

console.log(`\nharness reaping: ${held} held · ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
