/* cockpit-maintenance — THE SECOND DEADLINE, AND WHY IT NEEDS ITS OWN RUN.
   ────────────────────────────────────────────────────────────────────────

   THE LAW

     Link liveness is not projection maintenance. A page may treat a message
     it can still hear as evidence that the LINK is alive. It may not treat
     it as evidence that what is on screen is still being maintained.

   W.2.3.3 gives the cockpit two clocks and two deadlines:

       link_heard_at    any message at all              → `silence`
       projection_at    a message that ATTESTS the      → `unmaintained`
                        projection — a frame, or a
                        heartbeat whose valve holds
                        nothing this page has not seen

   plus one immediate path, `exhausted`, which is not a deadline at all: the
   host stating that it has given up delivering a newer frame.

   AND AT THE SHIPPED DEPTH ONLY ONE OF THE TWO CAN EVER FIRE

   `RETRY_LIMIT` is 3 and `RETRY_AFTER` is 1200 ms, so a frame the page never
   applies is marked `exhausted` about 2.4 s after it is first sent — well
   inside the 6 s lease. The exhaustion path therefore always arrives first,
   and the projection deadline behind it is unreachable. **A mechanism whose
   falsifier can never run is a claim.** That is the defect this whole arc
   keeps finding in other people's code and it is not one to ship here.

   So this gate runs the SHIPPED code at a depth where the host is still
   nominally repairing — `SUPER_COCKPIT_RETRY=64`, which is a DEPTH and not
   a mode: nothing anywhere branches on its value, exactly as with
   `SUPER_COCKPIT_QUEUE`. Every heartbeat then reports `exhausted: false`
   forever, the link stays demonstrably healthy, and the only thing in the
   product that can end the stale claim is the second deadline.

   WHAT IS BEING MODELLED

   Frames swallowed at `window.cockpit.deliver`; heartbeats passed straight
   through. That is not a contrived asymmetry — Tauri picks a Channel
   transport by payload size (`webview.eval` under 8192 bytes, park-and-fetch
   over it), so a heartbeat of a few hundred bytes and a frame carrying a
   real world go by two different paths with two independent failure modes.
   A liveness signal that can travel a different path from the payload it
   vouches for is not evidence about that payload.

   Run from the release root:  node tools/cockpit-maintenance.mjs          */

import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const APP = `${ROOT}/cockpit/target/release/super-cockpit`;
const DRIVER_PORT = Number(process.env.TAURI_DRIVER_PORT ?? 4448);
const NATIVE_PORT = Number(process.env.TAURI_NATIVE_PORT ?? 4449);
const BASE = `http://127.0.0.1:${DRIVER_PORT}`;

/* Deep enough that `attempts` cannot reach it inside the window this gate
   measures: at one retransmission every 1200 ms, 64 attempts is 76 seconds
   against a 6 s lease. The point is not the number, it is that the host is
   still trying throughout — so `exhausted` stays false and cannot be what
   ends the claim. */
const RETRY = Number(process.env.SUPER_COCKPIT_RETRY ?? 64);

let held = 0;
let failed = 0;

function check(name, ok, detail = '') {
  if (ok) { held++; console.log(`  \x1b[32mheld\x1b[0m         ${name}`); }
  else {
    failed++;
    console.log(`  \x1b[31mFAILED\x1b[0m       ${name}`);
    if (detail) console.log(`               ${detail}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function wd(method, path, body) {
  const res = await fetch(BASE + path, {
    method,
    headers: { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json;
  try { json = JSON.parse(text); } catch {
    throw new Error(`${method} ${path} → ${res.status} ${text.slice(0, 300)}`);
  }
  if (json.value && json.value.error) {
    throw new Error(`${method} ${path} → ${json.value.error}: ${json.value.message}`);
  }
  return json.value;
}

let session = null;
const script = (js) => wd('POST', `/session/${session}/execute/sync`, { script: js, args: [] });
const scriptAsync = (js) => wd('POST', `/session/${session}/execute/async`, { script: js, args: [] });

/* Returns null rather than throwing — a hard wait turns a good falsifier
   into a killed run, and the harness then finds no NAMED check to report as
   red. The lesson is W.2.1's `waitSoft`; it is repeated here because this
   file is where a sabotage is expected to make things not happen. */
async function waitSoft(f, limitMs = 30_000, everyMs = 250) {
  const deadline = Date.now() + limitMs;
  while (Date.now() < deadline) {
    try { const v = await f(); if (v) return v; } catch { /* retry */ }
    await sleep(everyMs);
  }
  return null;
}

async function main() {
  if (!existsSync(APP)) {
    console.error(`no cockpit at ${APP} — build it first`);
    process.exit(2);
  }
  console.log('[&] Super — cockpit projection maintenance\n');

  const driver = spawn(
    'tauri-driver',
    ['--port', String(DRIVER_PORT), '--native-port', String(NATIVE_PORT),
     '--native-driver', process.env.WEBKIT_WEBDRIVER ?? '/usr/bin/WebKitWebDriver'],
    { stdio: ['ignore', 'inherit', 'inherit'],
      env: {
        ...process.env,
        AMPD_DIR: `${ROOT}/ampd`,
        SUPER_WORLD_MODE: 'ephemeral',
        SUPER_COCKPIT_FIXTURE: '1',
        SUPER_COCKPIT_QUEUE: '1',
        SUPER_COCKPIT_RETRY: String(RETRY),
        WEBKIT_DISABLE_COMPOSITING_MODE: '1',
      } },
  );
  const stop = () => { try { driver.kill('SIGTERM'); } catch {} };
  process.on('exit', stop);

  try {
    await waitSoft(async () => {
      try { await fetch(`${BASE}/status`); return true; } catch { return false; }
    }, 15_000, 200);

    const created = await wd('POST', '/session', {
      capabilities: { alwaysMatch: { 'tauri:options': { application: APP } } },
    });
    session = created.sessionId ?? created.capabilities?.sessionId;
    if (!session) throw new Error(`no sessionId in ${JSON.stringify(created)}`);

    await run();
  } catch (e) {
    failed++;
    console.log('  \x1b[31mFAILED\x1b[0m       the maintenance gate could not run');
    console.log(`               ${e.message ?? e}`);
  } finally {
    if (session) { try { await wd('DELETE', `/session/${session}`); } catch {} }
    stop();
  }

  /* Prefixed, like every other `held · failed` gate — `emit-measurements`
     files the FIRST bare one under `host_acceptance`. W.1.4.1 trap 4. */
  console.log(`\nmaintenance: ${held} held · ${failed} failed`);
  process.exit(failed === 0 ? 0 : 1);
}

async function run() {
  const live = await waitSoft(
    () => script('return window.cockpit && window.cockpit.frame && window.cockpit.frame.state === "live-local" ? 1 : null'),
    240_000);
  check(
    'the cockpit reaches LIVE LOCAL',
    live === 1,
    'never reached live-local — everything below would be vacuous',
  );
  if (live !== 1) return;

  /* **The depth is asserted, not assumed.** If the environment variable did
     not reach the host, `exhausted` would fire at three attempts and this
     gate would silently be a second, slower copy of the battery's exhaustion
     witness — passing, and measuring the wrong mechanism. */
  /* **Waited for, not sampled.** `window.cockpit.valve` is whatever the last
     heartbeat said, and the page reaches LIVE LOCAL on a FRAME — the host
     delivers before it beats, so at that instant there is no valve at all
     and reading through it throws. Same property the large-frame gate
     records: the heartbeat is the only thing that escapes a closed valve
     and it escapes on its own schedule. */
  const limit = Number(await waitSoft(
    () => script('return window.cockpit.valve ? window.cockpit.valve.retry_limit : null'),
    20_000));
  check(
    'the host is running at a retry depth where exhaustion cannot be what ends the claim',
    limit === RETRY,
    `the heartbeat reports retry_limit ${limit}, this gate asked for ${RETRY} — at 3 the `
      + 'exhaustion path fires first and the deadline under test is unreachable',
  );

  await script(`
    window.__m = {
      on: window.cockpit.channel_id,
      swallowed: 0,
      beatsAtArm: window.cockpit.beats,
      appliedAtArm: window.cockpit.applied,
      latch: null,
    };
    window.__realDeliver = window.cockpit.deliver;
    window.cockpit.deliver = (m) => {
      if (m && m.schema === 'cockpit-heartbeat@1') return window.__realDeliver(m);
      if (window.cockpit.channel_id === window.__m.on) { window.__m.swallowed += 1; return; }
      return window.__realDeliver(m);
    };

    /* **THE WITHDRAWN STATE IS LATCHED CAUSALLY, NOT POLLED.** The swallow
       is scoped to one channel, so the candidate this withdrawal builds is
       healthy and the world is back within one IPC round trip — measured at
       a few hundred milliseconds. Polling \`withdrawn\` every 250 ms would
       routinely miss it and report no withdrawal at all, which is a
       falsifier decided by a race.

       A MutationObserver callback is a microtask at the end of the task that
       mutated the DOM, and an arriving frame is a later task. It therefore
       reads the region \`withdraw()\` just cleared BEFORE anything can
       refill it, by construction rather than by being quick. */
    window.__m.obs = new MutationObserver(() => {
      const c = window.cockpit;
      if (window.__m.latch || !c.withdrawn || !c.withdrew_at) return;
      window.__m.latch = {
        w: c.withdrew_at,
        rows: document.querySelectorAll('#world .row').length,
        headings: document.querySelectorAll('#world h2').length,
        live: document.querySelectorAll('button[data-intent]:not([disabled])').length,
        badge: document.getElementById('badge-state').dataset.state,
      };
    });
    window.__m.obs.observe(document.getElementById('world'), { childList: true, subtree: true });
  `);

  /* A real world change, so there is a state the person is entitled to see.
     Without one the host has nothing outstanding and the page is correctly
     current — the fault has to exist before the response to it is evidence
     of anything. */
  await scriptAsync(`
    const done = arguments[arguments.length - 1];
    window.__TAURI__.core.invoke('intent', {
      name: 'revoke_capability_domain',
      args: { scope: { actor: 'nobody-at-all' }, expected_ids: [] },
    }).then(() => done(1), () => done(1));
  `);

  const stuck = await waitSoft(
    () => script(`
      const f = window.cockpit.valve && window.cockpit.valve.in_flight;
      return (f && f.seq > window.__m.appliedAtArm && !f.exhausted && f.attempts >= 2)
        ? JSON.stringify({ seq: f.seq, attempts: f.attempts, exhausted: f.exhausted })
        : null;`),
    30_000);
  check(
    'a frame the page has never seen is outstanding, and the host is STILL TRYING to deliver it',
    stuck !== null,
    `no heartbeat reported an unexhausted retransmission in progress: ${stuck} — if the host `
      + 'had given up, the withdrawal below would be the exhaustion path and not this one',
  );

  const gone = await waitSoft(
    () => script('return window.__m.latch ? JSON.stringify(window.__m.latch) : null'),
    40_000);
  const g = JSON.parse(gone ?? 'null');

  check(
    'the page stops claiming a projection nothing has confirmed for a whole lease',
    !!g && g.w.reason === 'unmaintained',
    `withdrawal = ${gone} — a page hearing a healthy link forever went on presenting a `
      + 'projection it had no evidence was still being maintained',
  );

  /* **The three clauses that make this THIS mechanism.** The link had not
     gone quiet; the host had not given up; and the projection clock was the
     one past its deadline. Any of the three failing means some other path
     produced the withdrawal and the one under test is unproven. Sampled by
     the page at the withdrawal — see `withdrew_at` in `cockpit.js`. */
  check(
    'while the link was alive and the host had not given up — neither other path could have done it',
    !!g && g.w.link_age_ms !== null && g.w.link_age_ms < g.w.lease_ms
      && g.w.exhausted === false
      && g.w.projection_age_ms > g.w.lease_ms,
    `at the withdrawal: link quiet ${g?.w?.link_age_ms} ms, projection unattested `
      + `${g?.w?.projection_age_ms} ms, lease ${g?.w?.lease_ms} ms, exhausted ${g?.w?.exhausted} `
      + '— the silence deadline or the exhaustion statement got there first, so the second '
      + 'deadline is still unmeasured',
  );

  check(
    'and heartbeats went on arriving throughout, which is the entire point',
    !!g && g.w.beats > Number(await script('return window.__m.beatsAtArm')),
    `beats ${await script('return window.__m.beatsAtArm')} → ${g?.w?.beats} — with no `
      + 'heartbeats this is the W.2.3.2 silence lease under a new name',
  );

  check(
    'it withdraws exactly as a lost stream does — no world region, no submittable authority',
    !!g && g.rows === 0 && g.headings === 0 && g.live === 0 && g.badge === 'reacquire',
    `state at the withdrawal = ${gone}`,
  );

  await script('window.__m.obs.disconnect();');

  const back = await waitSoft(
    () => script(`return (!window.cockpit.withdrawn
                          && window.cockpit.frame.state === 'live-local'
                          && window.cockpit.channel_id !== window.__m.on
                          && window.cockpit.applied > window.__m.appliedAtArm) ? 1 : null`),
    45_000);
  check(
    'and a fresh channel brings back a state later than the one that was stuck',
    back === 1,
    `withdrawn=${await script('return window.cockpit.withdrawn')} `
      + `channel=${await script('return window.cockpit.channel_id')} against `
      + `${await script('return window.__m.on')} at the arm, `
      + `applied=${await script('return window.cockpit.applied')} against `
      + `${await script('return window.__m.appliedAtArm')}`,
  );

  console.log(`\n  retry depth ${RETRY} · ${await script('return window.__m.swallowed')} frames swallowed`);
}

main();
