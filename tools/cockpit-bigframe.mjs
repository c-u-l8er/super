/* cockpit-bigframe — the OTHER Tauri Channel transport.
   ────────────────────────────────────────────────────────────────────────

   THE LAW

     A cockpit frame is delivered, applied and acknowledged whichever of
     Tauri's two Channel transports carries it.

   THERE ARE TWO, AND THIS PRODUCT HAD ONLY EVER RUN ON ONE

     tauri-2.11.5, src/ipc/channel.rs, channel_on():

       json.len() < MAX_JSON_DIRECT_EXECUTE_THRESHOLD   (8192)
           webview.eval(runCallback(...))                        ← direct

       otherwise
           park the body in ChannelDataIpcQueue under a data_id
           webview.eval("invoke('__tauri_fetch_channel_data__', …)
                          .then(runCallback).catch(console.error)")   ← fetch

   W.2.2 measured every fixture frame at 2,342 bytes — 5,850 bytes of
   headroom — so the second branch had never executed here. That measurement
   is what ruled the fetch path out as the cause of W.2.2's wedge; it is not
   a reason to leave the path untested, because `Ampd.Projection.operator/0`
   is not a fixed-size document. It carries `authority_snapshot`,
   `pending_approvals`, `effects`, `channels`, `peers`, `recent_refusals`
   (twenty) and four windowed histories. A world with traffic in it crosses
   8192 with nothing in this repository changing, and on that day every
   frame switches to a transport whose page-side failure ends in
   `.catch(console.error)`.

   THE FRAME IS MADE BIG BY THE WORLD, NOT BY PADDING

   `SUPER_COCKPIT_BULK=n` has the fixture's agent ask for `n` further grants
   through `request_grant`, the same ordinary command the first one uses,
   and leaves them pending. They are real projection content. Nothing is
   approved and nothing reaches the registry by a private route.

   Run from the release root:  node tools/cockpit-bigframe.mjs            */

import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const APP = `${ROOT}/cockpit/target/release/super-cockpit`;
const DRIVER_PORT = Number(process.env.TAURI_DRIVER_PORT ?? 4446);
const NATIVE_PORT = Number(process.env.TAURI_NATIVE_PORT ?? 4447);
const BASE = `http://127.0.0.1:${DRIVER_PORT}`;

/* Tauri's own constant. Named here so the gate fails if the product ever
   drifts past a threshold nobody re-read. */
const THRESHOLD = 8192;
/* Enough pending requests to clear it with margin, and no more: this gate
   pays a runtime round trip per request. */
const BULK = Number(process.env.SUPER_COCKPIT_BULK ?? 40);

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
  console.log('[&] Super — cockpit large-frame transport\n');

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
        SUPER_COCKPIT_BULK: String(BULK),
        SUPER_COCKPIT_QUEUE: '1',
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
    console.log('  \x1b[31mFAILED\x1b[0m       the large-frame gate could not run');
    console.log(`               ${e.message ?? e}`);
  } finally {
    if (session) { try { await wd('DELETE', `/session/${session}`); } catch {} }
    stop();
  }

  console.log(`\nbig frame: ${held} held · ${failed} failed`);
  process.exit(failed === 0 ? 0 : 1);
}

async function run() {
  const live = await waitSoft(
    () => script('return window.cockpit && window.cockpit.frame && window.cockpit.frame.state === "live-local" ? 1 : null'),
    240_000);
  check(
    'the cockpit reaches LIVE LOCAL with a large world',
    live === 1,
    'never reached live-local — the fetch-path assertions below would be vacuous',
  );
  if (live !== 1) return;

  const bytes = Number(await script('return JSON.stringify(window.cockpit.frame).length'));
  check(
    `the frame is over Tauri's direct-execute threshold — the fetch transport is the one carrying it`,
    bytes > THRESHOLD,
    `frame is ${bytes} bytes, threshold is ${THRESHOLD} — this gate measured the SAME `
      + 'transport as the flagship and proves nothing about the other one',
  );

  const pending = Number(await script(
    'return (window.cockpit.frame.projection.grant_requests || []).length'));
  check(
    'and it is large because the WORLD is large, not because the payload was padded',
    pending >= BULK,
    `${pending} pending requests in the projection, ${BULK} were asked for`,
  );

  check(
    'the large frame is applied — it reached the renderer, not just the sender',
    Number(await script('return window.cockpit.applied')) === Number(await script('return window.cockpit.frame.seq')),
    'the frame was received but never became the applied sequence',
  );

  check(
    'and the DOM is derived from it',
    Number(await script('return document.querySelectorAll(\'#world .row\').length')) >= BULK,
    'the world region does not show the projection the frame carries',
  );

  /* The acknowledgement is the whole question on this transport: the fetch
     path's page-side promise ends in `.catch(console.error)`, so a failure
     there is invisible to the sender. If the frame was acknowledged the
     valve reopened, and the only way to see that is a SECOND frame. */
  const before = Number(await script('return window.cockpit.frames'));
  await scriptAsync(`
    const done = arguments[arguments.length - 1];
    window.__TAURI__.core.invoke('intent', {
      name: 'revoke_capability_domain',
      args: { scope: { actor: 'nobody-at-all' }, expected_ids: [] },
    }).then(() => done(1), () => done(1));
  `);
  const moved = await waitSoft(
    () => script('return window.cockpit.frames').then((n) => (Number(n) > before ? n : null)),
    45_000);
  check(
    'it was acknowledged, so the stream continues over the fetch transport',
    moved !== null,
    `frames stayed at ${before}: the large frame was sent, and either never arrived or was `
      + 'never acknowledged — on this transport the failure ends in console.error',
  );

  /* **Waited for, not sampled.** `window.cockpit.valve` is whatever the last
     heartbeat said, so it lags by up to one heartbeat interval — reading it
     immediately after an intent returns a snapshot taken before the
     acknowledgement it is being asked about. That is a property of the
     diagnosis, not a flaw in it: the heartbeat is the only thing that
     escapes a closed valve, and it escapes on its own schedule. */
  const fresh = await waitSoft(
    () => script('return JSON.stringify(window.cockpit.valve)')
      .then((s) => { const v = JSON.parse(s ?? 'null'); return v && v.last_ack ? v : null; }),
    20_000);
  check(
    'and the link reports itself healthy rather than merely quiet',
    !!fresh && fresh.sink === true && fresh.last_ack !== null,
    `no heartbeat carried an acknowledged valve within the wait: ${JSON.stringify(fresh)}`,
  );

  /* ── W.2.3.3 · THE TWO MESSAGES TAKE TWO TRANSPORTS, MEASURED ──────────

     W.2.3.3 rests on a corollary: *a liveness signal is evidence about the
     path it travelled, and where it can travel a different path from the
     thing it vouches for it is not evidence about that thing.* In this
     product it demonstrably can, and this is the gate that can say so —
     the world here is already the large one.

     Tauri chooses per payload: under the threshold, `webview.eval`, whose
     wry WebKitGTK implementation drops the asynchronous `run_javascript`
     result unread (wry#1644, still open); over it, park the body and have
     the page fetch it, ending in `.catch(console.error)`. **Two paths, two
     independent failure modes, and the heartbeat is on the other one from
     the frame it is vouching for.**

     **What the instrument is.** The delivered payload is handed to the page
     already parsed, so this re-serialises it rather than reading the wire
     bytes; the two differ only in string escaping. That is fine for the
     question being asked, which is not "how many bytes" but "which side of
     8192" — and the margins are better than twentyfold on one side and
     better than twofold on the other. It is stated rather than glossed
     because a measurement whose instrument is not named is a number. */
  const sized = await script(`
    window.__sz = { beat: null, frame: null };
    const id = window.cockpit.channel_id;
    const cbs = window.__TAURI_INTERNALS__.callbacks;
    const real = cbs.get(id);
    if (!real) return null;
    cbs.set(id, (data) => {
      const m = data && data.message;
      if (m && m.schema === 'cockpit-heartbeat@1') {
        if (window.__sz.beat === null) window.__sz.beat = JSON.stringify(m).length;
      } else if (m && typeof m.seq === 'number') {
        if (window.__sz.frame === null) window.__sz.frame = JSON.stringify(m).length;
      }
      return real(data);
    });
    window.__sz.off = () => cbs.set(id, real);
    return id;
  `);

  /* One more world change, so a frame is produced with the wrapper in place
     — otherwise only heartbeats arrive and the comparison has one side. */
  await scriptAsync(`
    const done = arguments[arguments.length - 1];
    window.__TAURI__.core.invoke('intent', {
      name: 'revoke_capability_domain',
      args: { scope: { actor: 'still-nobody' }, expected_ids: [] },
    }).then(() => done(1), () => done(1));
  `);

  const both = await waitSoft(
    () => script('return (window.__sz.beat !== null && window.__sz.frame !== null) '
      + '? JSON.stringify(window.__sz) : null'),
    30_000);
  const sz = JSON.parse(both ?? 'null');
  await script('if (window.__sz && window.__sz.off) window.__sz.off();');

  check(
    'a heartbeat and a frame from the same world take OPPOSITE sides of the transport threshold',
    sized !== null && !!sz && sz.beat < THRESHOLD && sz.frame > THRESHOLD,
    `heartbeat ${sz?.beat} bytes, frame ${sz?.frame} bytes, threshold ${THRESHOLD} — if both `
      + 'sat on the same side, the claim that the link signal can fail independently of the '
      + 'payload it vouches for would be an argument rather than a measurement',
  );

  console.log(`\n  frame ${bytes} bytes · threshold ${THRESHOLD} · ${pending} pending requests`
    + ` · heartbeat ${sz?.beat} bytes vs frame ${sz?.frame} bytes on the wire`);
}

main();
