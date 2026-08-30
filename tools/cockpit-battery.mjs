/* cockpit-battery — the W.2 flagship, driven through a real WebView.
   ────────────────────────────────────────────────────────────────────────

   THE LAW

     The cockpit renders the world; it never decides it. An intent that
     resolves successfully changes nothing inside a [data-source="frame"]
     region. The screen changes when a frame says so.

   THE SEQUENCE, and the third step is the one that matters

     DOM shows grant
        │
        ▼  a real WebDriver click on a real button
     Tauri IPC resolves SUCCESS
        │
        ▼
     DOM STILL SHOWS GRANT           ← mandatory intermediate state
        │                              held, not glimpsed
        ▼  the renderer says it is ready
     a new cockpit-frame arrives without the grant
        │
        ▼
     DOM removes the grant

   WHY IT IS NOT VACUOUS

   The obvious way to write this test passes against an app that removes
   the row optimistically, because the assertion lands in whatever
   millisecond the frame happens not to have arrived yet. So the hold is
   not a timing window: it is a state the cockpit is deterministically in.

   `ui/cockpit.js` pauses frame delivery for the duration of every
   submission — a product rule (**do not reflow the list a person is
   clicking on**) before it is a testing one — and this battery holds it
   there by replacing `window.cockpit.resume` with a function that does
   nothing, which is the same condition a slow renderer produces. Nothing
   in the host has a branch for tests.

   Two independent things are then asserted about the intermediate state:
   the grant is still in the DOM, **and** `window.cockpit.frames` has not
   moved. The first alone would pass if a frame had arrived and the
   renderer had simply failed to apply it — the second says no frame
   arrived at all.

   `tools/sabotage-cockpit.sh` falsifies it: with the optimistic
   `row.remove()` restored, or with the host's pause honoured only as a
   comment, this battery goes red at exactly that step.

   ── running it ─────────────────────────────────────────────────────────

     node tools/cockpit-battery.mjs

   Needs `tauri-driver` (cargo install tauri-driver), `WebKitWebDriver`
   (the webkit2gtk-4.1 package), a display, and a built cockpit. It starts
   its own runtime in an EPHEMERAL world and destroys it; it never opens
   the world a person uses.                                              */

import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const APP = `${ROOT}/cockpit/target/release/super-cockpit`;
const DRIVER_PORT = Number(process.env.TAURI_DRIVER_PORT ?? 4444);
const NATIVE_PORT = Number(process.env.TAURI_NATIVE_PORT ?? 4445);
const BASE = `http://127.0.0.1:${DRIVER_PORT}`;

/* ── the harness ─────────────────────────────────────────────────────── */

let held = 0;
let failed = 0;

function check(name, ok, detail = '') {
  if (ok) {
    held++;
    console.log(`  \x1b[32mheld\x1b[0m         ${name}`);
  } else {
    failed++;
    console.log(`  \x1b[31mFAILED\x1b[0m       ${name}`);
    if (detail) console.log(`               ${detail}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* ── W3C WebDriver, spoken directly ──────────────────────────────────────
   No client library. The protocol is six endpoints and a JSON envelope,
   and a dependency here would be a dependency in the one place this
   project has none.                                                     */

async function wd(method, path, body) {
  const res = await fetch(BASE + path, {
    method,
    headers: { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    throw new Error(`${method} ${path} → ${res.status} ${text.slice(0, 300)}`);
  }
  if (json.value && json.value.error) {
    throw new Error(`${method} ${path} → ${json.value.error}: ${json.value.message}`);
  }
  return json.value;
}

let session = null;

const script = (js, args = []) =>
  wd('POST', `/session/${session}/execute/sync`, { script: js, args });

const scriptAsync = (js, args = []) =>
  wd('POST', `/session/${session}/execute/async`, { script: js, args });

async function poll(f, limitMs, everyMs) {
  const deadline = Date.now() + limitMs;
  let last;
  while (Date.now() < deadline) {
    try {
      last = await f();
      if (last) return { got: last, last };
    } catch (e) {
      last = String(e);
    }
    await sleep(everyMs);
  }
  return { got: null, last };
}

async function waitFor(label, f, limitMs = 120_000, everyMs = 250) {
  const { got, last } = await poll(f, limitMs, everyMs);
  if (got) return got;
  throw new Error(`timed out waiting for ${label} (last: ${JSON.stringify(last)})`);
}

/* Returns null instead of throwing.
   **A sabotage that stops something from ever happening must fail the check
   that names it, not the harness.** Waiting hard for "the grant leaves the
   screen" means a cockpit that renders a remembered list — which is exactly
   what one of the falsifiers builds — takes down the run with a timeout, and
   `sabotage-cockpit.sh` greps for a named FAILED line and finds none. It
   would then report NOT A FALSIFIER about a probe that had worked perfectly. */
async function waitSoft(f, limitMs = 20_000, everyMs = 250) {
  return (await poll(f, limitMs, everyMs)).got;
}

/* Window handles, so the untrusted pane can be driven as itself.
   `GET /window/handles` lists every webview the application has open —
   including, as W.2.2 measured, a CHILD webview that shares its parent's
   GTK window.

   **Identified by the label Tauri itself injects, not by what the document
   happens to define.** W.2.1 picked the cockpit out by `typeof
   window.cockpit`, which is a fact about our own JavaScript: a pane that
   accidentally loaded `cockpit.js` would have been mistaken for the trusted
   webview and every refusal below would have been asserted against the
   wrong browsing context. `__TAURI_INTERNALS__.metadata` carries the
   `currentWindow` / `currentWebview` labels the ACL is actually resolved
   against, which makes the topology itself checkable — see the first two
   assertions in `run()`. */
async function handles() {
  return wd('GET', `/session/${session}/window/handles`);
}

async function focus(handle) {
  await wd('POST', `/session/${session}/window`, { handle });
}

async function labels() {
  return script(`const m = window.__TAURI_INTERNALS__ && window.__TAURI_INTERNALS__.metadata;
                 return m ? [m.currentWindow && m.currentWindow.label,
                             m.currentWebview && m.currentWebview.label] : null;`);
}

async function findCockpitAndPane() {
  const hs = await handles();
  const seen = [];
  let cockpit = null;
  let pane = null;
  for (const h of hs) {
    await focus(h);
    const l = await labels();
    if (!l) continue;
    const [win, view] = l;
    seen.push({ handle: h, window: win, webview: view });
    if (view === 'main') cockpit = h;
    if (view === 'pane') pane = h;
  }
  return { cockpit, pane, count: hs.length, seen };
}

/* ── the run ─────────────────────────────────────────────────────────── */

async function main() {
  if (!existsSync(APP)) {
    console.error(`no cockpit at ${APP} — build it first:\n  cd cockpit && cargo build --release`);
    process.exit(2);
  }

  console.log('[&] Super — cockpit battery\n');

  const driver = spawn(
    'tauri-driver',
    ['--port', String(DRIVER_PORT), '--native-port', String(NATIVE_PORT),
     '--native-driver', process.env.WEBKIT_WEBDRIVER ?? '/usr/bin/WebKitWebDriver'],
    {
      stdio: ['ignore', 'inherit', 'inherit'],
      /* **Its own process group, so the tree can be owned.**

         `tauri-driver` spawns the cockpit, which spawns `super-host`, which
         spawns `ampd` — a `beam.smp`. `stop()` killed only the driver, so
         everything below it reparented to init and kept running. Worse,
         `stdio: inherit` hands this process's stdout to every descendant,
         so an orphaned BEAM held the pipe open and the harness waited for
         an EOF that would never arrive. Measured: PPID 1, ~198% CPU,
         eleven minutes of no output at all, released instantly by killing
         the orphan by hand.

         `detached` makes the driver a group leader whose pgid is its own
         pid, so `kill(-pgid)` reaches the whole tree — and reaches exactly
         the processes this battery started, which is the only set a test
         harness is entitled to signal. A `pkill beam.smp` would also have
         killed the ~35 unrelated BEAMs on this machine. */
      detached: true,
      env: {
        ...process.env,
        AMPD_DIR: `${ROOT}/ampd`,
        /* Never the person's world. `WorldDir::Ephemeral` is created under
           the runtime dir and destroyed on shutdown, and `seed_fixture`
           refuses to run against anything else. */
        SUPER_WORLD_MODE: 'ephemeral',
        SUPER_COCKPIT_FIXTURE: '1',
        /* The untrusted-pane boundary, opened so the refusal can be
           measured. Since W.2.2 it is a CHILD WEBVIEW of the trusted
           window, which is the topology Super's browser, Motor and game
           panes will have; W.2.1 opened a second window, whose refusal
           proved a boundary this product is not going to have. It is
           granted no capability; the ACL it fails against is the shipped
           one. */
        SUPER_COCKPIT_PANE: '1',
        /* **A depth, not a mode.** Nothing branches on it. It is 1 so that
           queue saturation — the state in which W.2.1 silently discarded
           the messages that reopen the frame valve — is reached by
           construction instead of by racing. Every other assertion in this
           file is therefore also measured at depth 1, which is a stronger
           statement than measuring them at 64. */
        SUPER_COCKPIT_QUEUE: '1',
        WEBKIT_DISABLE_COMPOSITING_MODE: '1',
      },
    },
  );

  /* **Every exit path, and the group rather than the leader.**

     Idempotent because several of these fire together: a thrown assertion
     runs `finally` and then `exit`, and an interrupt runs the signal
     handler and then `exit` too. */
  let stopped = false;
  const stopSync = () => {
    if (stopped) return;
    stopped = true;
    /* Negative pid = the whole group. SIGTERM, never SIGKILL first: ampd's
       stores are `:dets` and an unclean exit forces a repair on next open. */
    try { process.kill(-driver.pid, 'SIGTERM'); } catch {}
  };

  /* The bounded version, for the paths that can await. Waits for the group
     to actually go — a returned `kill` is not a dead process — and only
     escalates if SIGTERM was ignored. */
  const stop = async () => {
    stopSync();
    const deadline = Date.now() + 5_000;
    while (Date.now() < deadline) {
      try { process.kill(-driver.pid, 0); } catch { return true; }
      await new Promise((r) => setTimeout(r, 100));
    }
    try { process.kill(-driver.pid, 'SIGKILL'); } catch {}
    return false;
  };

  process.on('exit', stopSync);
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.on(sig, () => { stopSync(); process.exit(130); });
  }
  process.on('uncaughtException', (e) => {
    stopSync();
    console.error(`cockpit battery: uncaught ${e?.message ?? e}`);
    process.exit(1);
  });
  process.on('unhandledRejection', (e) => {
    stopSync();
    console.error(`cockpit battery: unhandled rejection ${e?.message ?? e}`);
    process.exit(1);
  });

  try {
    await waitFor('tauri-driver to listen', async () => {
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
    console.log(`  \x1b[31mFAILED\x1b[0m       the battery could not run`);
    console.log(`               ${e.message ?? e}`);
  } finally {
    if (session) { try { await wd('DELETE', `/session/${session}`); } catch {} }

    /* **Awaited, and then verified.** The leak this closes was invisible
       precisely because nothing ever checked; a `kill` that returns is not
       a tree that is gone. */
    const clean = await stop();
    if (!clean) {
      failed++;
      console.log(`  \x1b[31mFAILED\x1b[0m       the battery left its own process group running`);
    }
  }

  /* **Prefixed, and `super-host verify`'s is not.** `emit-measurements`
     reads `host_acceptance` with a bare `^\s*(\d+) held · (\d+) failed$`,
     so an unprefixed summary here would be filed under the host's name
     whenever this ran first — W.1.4.1's trap 4, in which two batteries
     printed byte-identical lines and one number would have been recorded
     as the other's. */
  console.log(`\ncockpit battery: ${held} held · ${failed} failed`);
  process.exit(failed === 0 ? 0 : 1);
}

let COCKPIT = null;
let PANE = null;
let SEEN = [];

async function run() {
  /* ── two webviews, and only one of them is trusted ─────────────────── */

  const found = await waitFor('both webviews to open',
    async () => {
      const f = await findCockpitAndPane();
      return f.cockpit && f.pane ? f : null;
    },
    60_000);

  COCKPIT = found.cockpit;
  PANE = found.pane;
  SEEN = found.seen;
  check(
    'the application opens the trusted cockpit and an untrusted pane beside it',
    !!COCKPIT && !!PANE && found.count === 2,
    `${found.count} webviews`,
  );

  /* ── W.2.2 · and the pane is INSIDE the trusted window ────────────────
     This is the assertion W.2.1 could not have made and the reason the
     round exists. Its pane was a separate `WebviewWindow`, so its refusal
     said "an untrusted WINDOW is denied" — true, and not the boundary Super
     needs. Tauri resolves a command against (window label, webview label)
     with an OR, so a capability naming `windows: ["main"]` grants every
     webview drawn inside `main`, which is exactly what a browser pane, a
     Motor surface or a game pane is going to be.

     Both webviews must therefore report the SAME window and DIFFERENT
     webview labels, or the denials below are being measured against the
     weaker topology again and nobody would be able to tell from the
     output. */

  const topo = Object.fromEntries(SEEN.map((s) => [s.webview, s.window]));
  check(
    'the untrusted pane is a child webview of the TRUSTED window, not a second window',
    topo.main === 'main' && topo.pane === 'main',
    `labels: ${JSON.stringify(SEEN)}`,
  );

  check(
    'and it is a distinct webview — the two are told apart by the label the ACL resolves against',
    SEEN.length === 2 && SEEN[0].webview !== SEEN[1].webview,
    JSON.stringify(SEEN),
  );

  await focus(COCKPIT);

  /* ── LIVE LOCAL, and it means what it says ─────────────────────────── */

  await waitFor('the page to define window.cockpit',
    () => script('return typeof window.cockpit === "object" && window.cockpit !== null'),
    30_000);

  const live = await waitFor('LIVE LOCAL',
    () => script('return window.cockpit.frame && window.cockpit.frame.state === "live-local" ? window.cockpit.frame : null'),
    180_000);

  check(
    'the cockpit reaches LIVE LOCAL from a real desktop WebView',
    live.state === 'live-local',
    JSON.stringify(live.state),
  );

  check(
    'LIVE LOCAL carries the projection it is a view of, not merely a cursor',
    !!live.projection && typeof live.projection === 'object',
    `projection=${typeof live.projection}`,
  );

  check(
    'the frame names the world incarnation it was assembled in',
    typeof live.world?.world_incarnation === 'string' && live.world.world_incarnation.length > 0,
    JSON.stringify(live.world),
  );

  check(
    'both clocks arrive — authority revision and view revision',
    Number.isInteger(live.world?.authority_revision) && Number.isInteger(live.world?.view_revision),
    JSON.stringify(live.world),
  );

  /* ── the DOM shows the grant ───────────────────────────────────────── */

  const grantId = await waitFor('a grant row',
    () => script('const r = document.querySelector(\'#world .row[data-id^="gr_"]\'); return r ? r.dataset.id : null'),
    30_000);

  check('the DOM shows a grant', /^gr_/.test(grantId ?? ''), String(grantId));

  const grantInFrame = await script(
    'return (window.cockpit.frame.projection.grants || []).some(g => g.id === arguments[0])',
    [grantId],
  );
  check(
    'the grant on screen is the grant in the frame — the DOM is derived, not invented',
    grantInFrame === true,
    `grants=${JSON.stringify((live.projection.grants || []).map((g) => g.id))}`,
  );

  /* ── hold the renderer where an in-flight click holds it ─────────────
     The submission's own hold is never released, which is the state a
     renderer waiting on an outcome is already in. The token is captured so
     the release below is the real `hold_end` and not a second mechanism. */

  await script(`
    window.__heldToken = null;
    window.cockpit.holdEnd = async (id) => { window.__heldToken = id; };
  `);

  const framesBefore = await script('return window.cockpit.frames');
  const seqBefore = await script('return window.cockpit.frame.seq');

  /* ── a real click on a real button ─────────────────────────────────── */

  const el = await wd('POST', `/session/${session}/element`, {
    using: 'css selector',
    value: `#world .row[data-id="${grantId}"] button[data-intent="revoke_grant"]`,
  });
  const elementId = Object.values(el)[0];
  await wd('POST', `/session/${session}/element/${elementId}/click`, {});

  /* ── the IPC resolves SUCCESS ──────────────────────────────────────── */

  const outcome = await waitSoft(
    () => script('const li = document.querySelector(\'#receipt-list li[data-intent="revoke_grant"]\'); return li ? li.dataset.outcome : null')
      .then((v) => (v === 'submitted' ? null : v)),
    60_000);

  check(
    'the revocation is submitted and the runtime answers SUCCESS',
    outcome === 'accepted',
    `receipt outcome = ${outcome}`,
  );

  /* ── THE MANDATORY INTERMEDIATE STATE ──────────────────────────────── */

  const stillThere = await script(
    'return !!document.querySelector(\'#world .row[data-id="\' + arguments[0] + \'"]\')',
    [grantId],
  );
  check(
    'the intent succeeded and the grant is STILL on screen',
    stillThere === true,
    'the row left before any frame said it had',
  );

  const framesAt = await script('return window.cockpit.frames');
  check(
    'and no frame has been delivered — the row is there because nothing has said otherwise',
    framesAt === framesBefore,
    `frames ${framesBefore} → ${framesAt}`,
  );

  /* Held, not glimpsed. A cockpit that removes the row optimistically and
     a cockpit that simply had not received the frame yet are
     indistinguishable in the millisecond after a click; they are not
     indistinguishable a second and a half later. */
  await sleep(1500);

  const stillThereLater = await script(
    'return !!document.querySelector(\'#world .row[data-id="\' + arguments[0] + \'"]\')',
    [grantId],
  );
  const framesLater = await script('return window.cockpit.frames');
  check(
    'it is a state and not a race: 1.5 s later the grant is still there and still no frame',
    stillThereLater === true && framesLater === framesBefore,
    `row=${stillThereLater} frames ${framesBefore} → ${framesLater}`,
  );

  check(
    'the receipt rail moved and the world region did not',
    (await script('return document.querySelectorAll("#receipt-list li").length')) > 0,
    'no receipt was rendered at all',
  );

  /* ── release ───────────────────────────────────────────────────────── */

  /* **The result is checked, and W.2.1's harness threw it away.** A release
     that was refused, or issued with the wrong token, produces exactly the
     symptom below — the row never leaves — and the check that fires says
     "the grant leaves the screen only when a frame says so", which points
     at the renderer. That is the same defect as `cockpit.js` not awaiting
     `ack`: a release whose outcome nobody reads. The token is reported too,
     because `undefined` here is a harness bug and looks identical to a
     wedged valve. */
  const released = await scriptAsync(`
    const done = arguments[arguments.length - 1];
    const id = window.__heldToken;
    window.__TAURI__.core
      .invoke('hold_end', { id })
      .then(() => done({ ok: true, id }), (e) => done({ ok: false, id, e: String(e) }));
  `);
  check(
    'the interaction hold is released, and the release is not refused',
    released.ok === true && typeof released.id === 'string',
    `hold_end(${JSON.stringify(released.id)}) → ${JSON.stringify(released)}`,
  );

  const gone = await waitSoft(
    () => script('return !document.querySelector(\'#world .row[data-id="\' + arguments[0] + \'"]\')', [grantId])
      .then((v) => (v ? true : null)),
    30_000);

  const framesAfter = await script('return window.cockpit.frames');
  const seqAfter = await script('return window.cockpit.frame.seq');

  check(
    'the grant leaves the screen only when a frame says so',
    gone === true && framesAfter > framesBefore && seqAfter > seqBefore,
    `frames ${framesBefore} → ${framesAfter}, seq ${seqBefore} → ${seqAfter}`,
  );

  const goneFromFrame = await script(
    'return !(window.cockpit.frame.projection.grants || []).some(g => g.id === arguments[0])',
    [grantId],
  );
  check(
    'and the frame that removed it is a frame in which the grant is genuinely gone',
    goneFromFrame === true,
    'the DOM dropped a row the projection still lists',
  );

  /* ── the valve reported what it swallowed ──────────────────────────── */

  const coalesced = await script('return window.cockpit.frame.coalesced');
  check(
    'the held frame reports the states it superseded rather than dropping them silently',
    Number.isInteger(coalesced),
    `coalesced=${JSON.stringify(coalesced)}`,
  );

  /* ── the cockpit cannot ask the world anything ─────────────────────── */

  const refusedRead = await scriptAsync(`
    const done = arguments[arguments.length - 1];
    window.__TAURI__.core
      .invoke('intent', { name: 'operator_projection', args: {} })
      .then((v) => done({ ok: true, v }), (e) => done({ ok: false, e: String(e) }));
  `);
  check(
    'the WebView cannot submit a read — a second way to learn the world is a second source of truth',
    refusedRead.ok === false && /not an intent/.test(refusedRead.e ?? ''),
    JSON.stringify(refusedRead),
  );

  /* ── W.2.1 · overlapping holds do not release each other ──────────────
     A boolean fails this deterministically: `B` begins, `A` ends, and the
     surface is free to reflow while `B`'s outcome is still unknown. The
     world is moved with a no-op mutation — a domain revocation over an
     actor that does not exist — which bumps the authority revision without
     touching anything a person owns. */

  const beforeHolds = await script('return window.cockpit.frames');

  await scriptAsync(`
    const done = arguments[arguments.length - 1];
    const { invoke } = window.__TAURI__.core;
    (async () => {
      await invoke('hold_begin', { id: 'probe-A' });
      await invoke('hold_begin', { id: 'probe-B' });
      await invoke('hold_end',   { id: 'probe-A' });
      await invoke('intent', {
        name: 'revoke_capability_domain',
        args: { scope: { actor: 'nobody-at-all' }, expected_ids: [] },
      });
      done(true);
    })().catch((e) => done(String(e)));
  `);

  await sleep(1500);
  const duringHolds = await script('return window.cockpit.frames');
  check(
    'one interaction ending does not release another interaction\'s hold',
    duringHolds === beforeHolds,
    `a frame arrived while probe-B still held: frames ${beforeHolds} → ${duringHolds}`,
  );

  await scriptAsync(`
    const done = arguments[arguments.length - 1];
    window.__TAURI__.core.invoke('hold_end', { id: 'probe-B' })
      .then(() => done(true), (e) => done(String(e)));
  `);

  const afterHolds = await waitSoft(
    () => script('return window.cockpit.frames').then((n) => (n > beforeHolds ? n : null)),
    20_000);
  check(
    'and the frame arrives once the last hold is released',
    afterHolds !== null,
    `frames stayed at ${beforeHolds} after every hold ended`,
  );

  /* ── W.2.2 · the valve reopens even when the queue is saturated ───────

     W.2.1 sent `frame_ack`, `hold_begin` and `hold_end` with
     `SyncSender::try_send`, whose contract on a full bounded buffer is
     `Err(Full)` and **the message is not sent**. Both of the messages that
     RELEASE the delivery valve travelled that way:

         Ack(seq) dropped     in_flight stays Some(seq)  → no frame, ever
         HoldEnd(id) dropped  holds keeps id             → no frame, ever

     and `cockpit.js` does not await `ack` at all, so the rejection had
     nowhere to be seen either. The queue can only be full BECAUSE
     mutations are in flight — so the congestion prevented the message that
     clears congestion.

     ── why this is deterministic, and furious clicking is not ───────────

     The worker executes an intent by calling into the runtime and waiting
     for the reply, INSIDE the drain. Firing BURST intents without awaiting
     them therefore parks it for BURST sequential round trips, and for that
     whole window the mutation lane is full with BURST−depth senders
     blocked on it. The release is issued inside that window. The only way
     it is not is if the runtime completes 64 round trips faster than one
     IPC message crosses the WebView boundary.

     `SUPER_COCKPIT_QUEUE` sets the lane depth and this run uses 1, which
     is a DEPTH and not a mode: no branch anywhere reads it, and the code
     path at 1 is the code path at 64. It is set so that saturation is a
     state the test reaches by construction rather than by racing — which
     is the same argument as the interaction hold two blocks up, where a
     millisecond-wide window was made into a state the cockpit sits in. */

  const BURST = 64;
  /* Un-awaited on purpose: the point is BURST submissions in flight at
     once. A no-op domain revocation over an actor that does not exist —
     the same mutation the hold probe uses — so it moves the authority
     revision and touches nothing a person owns. */
  const saturate =
    `for (let i = 0; i < ${BURST}; i++) {` +
    `  window.__TAURI__.core.invoke('intent', { name: 'revoke_capability_domain',` +
    `    args: { scope: { actor: 'nobody-at-all' }, expected_ids: [] } }).catch(() => {});` +
    `}`;

  /* ── a release issued into a saturated queue ──────────────────────── */

  const satBefore = await script('return window.cockpit.frames');

  const release = await scriptAsync(`
    const done = arguments[arguments.length - 1];
    const { invoke } = window.__TAURI__.core;
    invoke('hold_begin', { id: 'saturate' })
      .then(() => { ${saturate} return invoke('hold_end', { id: 'saturate' }); })
      .then(() => done({ ok: true }), (e) => done({ ok: false, e: String(e) }));
  `);

  check(
    'a release issued while the mutation lane is saturated is admitted, not discarded',
    release.ok === true,
    `hold_end was refused: ${JSON.stringify(release)} — a bounded lane may delay a release, never drop it`,
  );

  const satAfter = await waitSoft(
    () => script('return window.cockpit.frames').then((n) => (n > satBefore ? n : null)),
    60_000);
  check(
    'and the valve reopens — the hold it released is genuinely gone from the set',
    satAfter !== null,
    `frames stayed at ${satBefore}: the release never reached the worker and delivery is wedged`,
  );

  /* ── an acknowledgement issued into a saturated queue ─────────────────
     The harder of the two, because nothing retries it. `ack` is replaced
     with a recorder so a frame stays outstanding — which is the state a
     renderer that has painted but not yet reported is already in — and the
     acknowledgement is then issued by hand from inside the saturation
     window. */

  /* The real one is kept and put back afterwards rather than re-written by
     hand: a test that reconstructs the product's acknowledgement is testing
     its own copy of it, and this one now carries a terminal-state path the
     copy would not have had. */
  await script(`
    window.__unacked = null;
    window.__realAck = window.cockpit.ack;
    window.cockpit.ack = (seq) => { window.__unacked = seq; };
  `);

  await scriptAsync(`
    const done = arguments[arguments.length - 1];
    window.__TAURI__.core.invoke('intent', {
      name: 'revoke_capability_domain',
      args: { scope: { actor: 'nobody-at-all' }, expected_ids: [] },
    }).then(() => done(true), () => done(true));
  `);

  const unacked = await waitSoft(
    () => script('return window.__unacked'),
    30_000);
  check(
    'a frame can be left outstanding — the precondition the acknowledgement releases',
    Number.isInteger(unacked),
    `no frame arrived to leave unacknowledged: ${JSON.stringify(unacked)}`,
  );

  const ackBefore = await script('return window.cockpit.frames');

  const acked = await scriptAsync(`
    const done = arguments[arguments.length - 1];
    ${saturate}
    window.__TAURI__.core.invoke('frame_ack', { seq: ${Number(unacked) || 0} })
      .then(() => done({ ok: true }), (e) => done({ ok: false, e: String(e) }));
  `);

  /* Restored before the wait, so what arrives next is acknowledged the way
     the product acknowledges it — including its terminal-state path. */
  await script('window.cockpit.ack = window.__realAck;');

  check(
    'an acknowledgement issued while the mutation lane is saturated is admitted, not discarded',
    acked.ok === true,
    `frame_ack was refused: ${JSON.stringify(acked)} — and cockpit.js does not await it, so nothing would have noticed`,
  );

  const ackAfter = await waitSoft(
    () => script('return window.cockpit.frames').then((n) => (n > ackBefore ? n : null)),
    60_000);
  check(
    'and the frame stream resumes — an in-flight frame that is acknowledged is no longer in flight',
    ackAfter !== null,
    `frames stayed at ${ackBefore}: the acknowledgement was dropped and no further frame can ever be sent`,
  );

  /* W.2.2 gave `ack` a terminal path — the second half of the rule, the one
     the lane cannot close: a release that genuinely cannot be enqueued must
     move the system to a state that SAYS SO rather than vanish. It is the
     only writer into a [data-source="frame"] region that is not a frame,
     which makes it the only thing in this product that could put a claim on
     that region nobody made. So: it did not run. A healthy session that
     tripped it would be a second source of truth in the one region whose
     whole subject is having exactly one. */
  check(
    'the terminal stall path did not fire — nothing but a frame wrote the world region',
    (await script('return window.cockpit.stalled')) === null,
    `window.cockpit.stalled = ${JSON.stringify(await script('return window.cockpit.stalled'))}`,
  );

  /* ── W.2.3 · producer-side success is not delivery ────────────────────

     W.2.2's flagship wedged once and could not be made to do it again. The
     mechanism is upstream and it is not exotic: Tauri hands a Channel
     payload under 8192 bytes to `webview.eval`, and wry's WebKitGTK `eval`
     passes the script to `run_javascript` and returns `Ok(())` **without
     inspecting the asynchronous result** — with no callback the `Result` is
     dropped (`wry-0.55.1/src/webkitgtk/mod.rs`; upstream wry#1644 reports
     exactly this losing Channel messages and hanging the channel).

     So the host can be told a frame was delivered when no JavaScript ever
     ran, and W.2.2's answer to that was silence forever. The law:

       A liveness-critical message is delivered when the CONSUMER says so.
       Absence of acknowledgement must produce retry, recovery, or an
       explicit loss of the claim — never permanent silence.

     Modelled where it actually happens: the page's own delivery entry point
     drops one frame on the floor. The host's send succeeded, the sequence is
     outstanding, and nothing rendered. This is a truer model than forcing
     `send()` to return `Err`, which is the case that already worked. */

  const beatsBefore = await script('return window.cockpit.beats');
  const framesQuiet = await script('return window.cockpit.frames');
  const seqQuiet = await script('return window.cockpit.frame.seq');

  const beatsAfter = await waitSoft(
    () => script('return window.cockpit.beats').then((n) => (n >= beatsBefore + 2 ? n : null)),
    20_000);
  check(
    'the link says it is alive on its own — the world does not have to move',
    beatsAfter !== null,
    `beats stayed at ${beatsBefore}: a quiet world and a dead stream are indistinguishable`,
  );

  check(
    'a heartbeat is not a frame — it is not counted and it does not move the world region',
    (await script('return window.cockpit.frames')) === framesQuiet
      && (await script('return window.cockpit.frame.seq')) === seqQuiet,
    'a heartbeat was counted as a frame, which would make the valve assertions above vacuous',
  );

  const valve = await script('return JSON.stringify(window.cockpit.valve)');
  const v = JSON.parse(valve ?? 'null');
  check(
    'and it carries the valve diagnosis — a closed valve can name the term that closed it',
    !!v && typeof v.sink === 'boolean' && 'in_flight' in v && Array.isArray(v.holds)
      && 'last_ack' in v && typeof v.open === 'boolean',
    `valve = ${valve}`,
  );

  /* ── W.2.3.1 · and whether the host is still trying ────────────────────
     `RETRY_LIMIT` stops retransmission after three attempts, because
     retransmission cannot repair a lost transport index and on the fetch
     transport each further attempt parks another projection in upstream
     state nothing here can reclaim. **A page that could not tell "the
     repair is still coming" from "the host has given up" would be waiting
     on something nobody is still attempting** — which is the same class of
     defect as W.2.2's undiagnosable valve, one field along. So the limit
     rides the heartbeat beside the attempt count. */
  check(
    'and whether the host is still trying — a bounded retry that does not say so is silence',
    !!v && v.retry_limit === 3
      && (v.in_flight === null || typeof v.in_flight.exhausted === 'boolean'),
    `retry_limit = ${v?.retry_limit}, in_flight = ${JSON.stringify(v?.in_flight)}`,
  );

  /* ── a frame the page never receives ─────────────────────────────────── */

  await script(`
    window.__seen = [];
    window.__ate = null;
    window.__ateJson = null;
    window.__again = false;
    window.__swallow = 1;
    window.__realDeliver = window.cockpit.deliver;
    window.cockpit.deliver = (m) => {
      if (m && m.schema === 'cockpit-heartbeat@1') return window.__realDeliver(m);
      window.__seen.push(m.seq);
      if (window.__swallow) {
        window.__swallow = 0;
        window.__ate = m.seq;
        window.__ateJson = JSON.stringify(m);
        return;                       /* sent, acknowledged by nobody, never rendered */
      }
      if (m.seq === window.__ate) window.__again = JSON.stringify(m) === window.__ateJson;
      return window.__realDeliver(m);
    };
  `);

  const lostBefore = await script('return window.cockpit.frames');
  const lostOn = await script('return window.cockpit.channel_id');

  await scriptAsync(`
    const done = arguments[arguments.length - 1];
    window.__TAURI__.core.invoke('intent', {
      name: 'revoke_capability_domain',
      args: { scope: { actor: 'nobody-at-all' }, expected_ids: [] },
    }).then(() => done(1), () => done(1));
  `);

  const ate = await waitSoft(() => script('return window.__ate'), 20_000);
  check(
    'a frame can be lost between a successful send and the renderer',
    Number.isInteger(ate),
    `nothing was swallowed: ${JSON.stringify(ate)} — the witness below would be vacuous`,
  );

  /* ── W.2.3.3 · ON THE SAME CHANNEL, AND THAT CLAUSE IS NEW ─────────────
     **A fix can invalidate an earlier round's witness by making its failure
     mode recoverable, and this round did.**

     This check was `frames > lostBefore` and nothing else. It went red under
     W.2.3.2 with retransmission disabled, and correctly: the swallowed frame
     stayed outstanding, `exhausted` never became true — one attempt, never
     three — heartbeats went on arriving, and the single clock they refreshed
     meant the lease never fired. The stream really was wedged forever and
     `frames` really never moved.

     W.2.3.3's projection deadline ends exactly that state. With
     retransmission disabled the page now notices within one lease that
     nothing has attested its projection, withdraws, rebinds, and is sent the
     current world on a FRESH channel — so `frames` moves, and a check that
     counts frames reports the retransmission fix as working while it is
     switched off. `tools/sabotage-cockpit.sh` caught it, on a probe that had
     been green for three rounds.

     **A retransmission does not rebind.** Requiring the same channel is what
     keeps this check about repair rather than about recovery in general, and
     the two are separately falsified — which is the whole reason both
     mechanisms exist. */
  const recovered = await waitSoft(
    () => script(`return (window.cockpit.channel_id === ${lostOn}
                          && window.cockpit.frames > ${lostBefore}) ? 1 : null`),
    30_000);
  check(
    'and it is sent again on the same channel, rather than wedging the stream forever',
    recovered !== null,
    `frames stayed at ${lostBefore} on channel ${lostOn}, now `
      + `${await script('return window.cockpit.channel_id')} — one silently lost frame either `
      + 'closed the valve permanently, or was recovered from only by abandoning the channel, '
      + 'which is reacquisition and not retransmission',
  );

  const seen = JSON.parse(await script('return JSON.stringify(window.__seen)') ?? '[]');
  check(
    'the retransmission is the SAME sequence and the SAME bytes — not a newer state',
    (await script('return window.__again')) === true
      && seen.filter((s) => s === ate).length >= 2,
    `seen sequences ${JSON.stringify(seen)}, swallowed ${ate} — a retransmission that `
      + 'invents a later state skips one the person was entitled to see',
  );

  /* ── a repeat is applied once and acknowledged every time ────────────── */

  const dupBefore = await script('return window.cockpit.duplicates');
  const framesDup = await script('return window.cockpit.frames');
  await script('window.__realDeliver(window.cockpit.frame);');
  check(
    'a frame already applied is not rendered again, and is acknowledged again',
    (await script('return window.cockpit.duplicates')) === dupBefore + 1
      && (await script('return window.cockpit.frames')) === framesDup,
    'a duplicate reflowed the list under the cursor, or was silently ignored so the '
      + 'host would retransmit it forever',
  );

  const stale = await script(`
    const f = JSON.parse(JSON.stringify(window.cockpit.frame));
    f.seq = 1;
    const before = window.cockpit.frames;
    window.__realDeliver(f);
    return window.cockpit.frames === before && window.cockpit.applied > 1;
  `);
  check(
    'and a frame older than one already applied never walks the world backwards',
    stale === true,
    'a delayed message from a replaced channel regressed the display after recovery',
  );

  /* ── the lease: a dead stream is not a quiet world ─────────────────────

     **W.2.3.2 put this witness on a clock and it has to be written for
     one.** The blackhole is at `deliver`, so the CHANNEL is healthy and only
     this page's handler is discarding — but the page cannot tell, so it
     spends candidates on channels that were never broken and reaches
     UNAVAILABLE after `CANDIDATE_LIMIT` full leases. That is correct: the
     evidence available to the page is silence either way. It does mean the
     witness has a budget, and the version that read the withdrawal state
     over four separate WebDriver round trips before restoring `deliver`
     spent enough of it to fail against a working fix.

     So the state is captured and the fault lifted in ONE call. The same
     discipline the transport-gap witness needed, for the same reason: a
     check assembled from several round trips is a check whose subject can
     move between them. */

  await script(`
    window.cockpit.deliver = (m) => { window.__blackhole = (window.__blackhole || 0) + 1; };
  `);

  const withdrew = await waitSoft(
    () => script(`
      if (!window.cockpit.withdrawn) return null;
      const s = JSON.stringify({
        rows: document.querySelectorAll('#world .row').length,
        live: document.querySelectorAll('button[data-intent]:not([disabled])').length,
        badge: document.getElementById('badge-state').dataset.state,
        candidates: window.cockpit.candidates,
      });
      /* Captured and lifted together — the recovery budget is running. */
      window.cockpit.deliver = window.__realDeliver;
      return s;`),
    20_000);
  const wd0 = JSON.parse(withdrew ?? 'null');
  check(
    'the page withdraws LIVE LOCAL when it hears nothing for longer than its lease',
    !!wd0,
    'a permanently dead stream went on looking exactly like a quiet world, which is the '
      + 'one thing this cockpit exists to make impossible',
  );

  check(
    'and it withdraws rather than inventing — no world region, and no authority to submit',
    !!wd0 && wd0.rows === 0 && wd0.live === 0 && wd0.badge === 'reacquire',
    `withdrawal state = ${withdrew} — the withdrawal left a world on screen, or left `
      + 'authority submittable against it',
  );

  /* Lifted inside the capture above, not here — the budget was running. */

  const restored = await waitSoft(
    () => script('return (!window.cockpit.withdrawn && window.cockpit.frame.state === "live-local") ? 1 : null'),
    30_000);
  check(
    'and the claim comes back when the link does, without a reload',
    restored === 1,
    'the page never recovered from a withdrawal on its own',
  );

  /* ── W.2.3.3 · link liveness is not projection maintenance ─────────────

     Every witness above is a SILENCE: the page hears nothing and its lease
     runs out. There is a third state, and until this round the cockpit sat
     in it indefinitely:

         frames do not reach the page
         heartbeats DO
         the host exhausts RETRY_LIMIT and says so on the heartbeat
             valve.in_flight = { seq: newer than applied, exhausted: true }
         ── and every one of those heartbeats refreshed the one clock the
            lease consulted, so the lease never fired ──
         the page goes on presenting the old projection as maintained, with
         every authority control enabled against it

     **The host could positively state that the newer frame had been
     abandoned, and the message carrying that statement was the thing
     keeping the page from acting on it.** One field was holding two facts:

         the link is alive     ≠     what is on screen is still maintained

     It is not a contrived asymmetry either. Tauri picks a Channel transport
     by payload size — under 8192 bytes by `webview.eval`, over it by
     parking the body and asking the page to fetch it — and a heartbeat is a
     few hundred bytes while a frame carrying a real world crosses the
     threshold. The signal that vouches for the stream travels a different
     path from the payload it vouches for, and the two fail independently.

     Modelled at `window.cockpit.deliver`, scoped to the CHANNEL that is
     live when it is armed: heartbeats pass, frames on that channel do not,
     and the replacement channel a correct recovery builds is untouched — so
     the recovery is deterministic and this witness does not spend the
     candidate budget the blackhole test below needs. */

  await script(`
    window.__ex = {
      on: window.cockpit.channel_id,
      swallowed: 0,
      beatsAtArm: window.cockpit.beats,
      appliedAtArm: window.cockpit.applied,
      latch: null,
    };
    window.__realDeliver = window.cockpit.deliver;
    window.cockpit.deliver = (m) => {
      if (m && m.schema === 'cockpit-heartbeat@1') return window.__realDeliver(m);
      if (window.cockpit.channel_id === window.__ex.on) { window.__ex.swallowed += 1; return; }
      return window.__realDeliver(m);
    };

    /* **THE WITHDRAWN STATE IS LATCHED CAUSALLY, NOT POLLED.**
       Because the swallow is scoped to one channel, the candidate this
       withdrawal builds is healthy and the world comes back within one IPC
       round trip — measured at a few hundred milliseconds. A harness that
       polled \`window.cockpit.withdrawn\` on a 250 ms interval would
       routinely arrive after the recovery and report that no withdrawal
       happened, which is a falsifier decided by a race in a round about
       removing one.

       A MutationObserver is not a faster poll, it is a different kind of
       evidence: its callback is a microtask at the end of the task that
       mutated the DOM, and an arriving frame is a later task. So it reads
       the region \`withdraw()\` just cleared BEFORE anything can refill it,
       by construction. */
    window.__ex.obs = new MutationObserver(() => {
      const c = window.cockpit;
      if (window.__ex.latch || !c.withdrawn || !c.withdrew_at) return;
      window.__ex.latch = {
        w: c.withdrew_at,
        rows: document.querySelectorAll('#world .row').length,
        headings: document.querySelectorAll('#world h2').length,
        live: document.querySelectorAll('button[data-intent]:not([disabled])').length,
        badge: document.getElementById('badge-state').dataset.state,
      };
    });
    window.__ex.obs.observe(document.getElementById('world'), { childList: true, subtree: true });
  `);

  await scriptAsync(`
    const done = arguments[arguments.length - 1];
    window.__TAURI__.core.invoke('intent', {
      name: 'revoke_capability_domain',
      args: { scope: { actor: 'nobody-at-all' }, expected_ids: [] },
    }).then(() => done(1), () => done(1));
  `);

  /* **The host has to SAY it before the page can be judged for not
     listening.** Asserted first and separately: if `exhausted` never came
     back true, everything below would be measuring a silence again. */
  const said = await waitSoft(
    () => script(`
      const f = window.cockpit.valve && window.cockpit.valve.in_flight;
      return (f && f.exhausted && f.seq > window.__ex.appliedAtArm)
        ? JSON.stringify({ seq: f.seq, attempts: f.attempts, beats: window.cockpit.beats })
        : null;`),
    30_000);
  const ex = JSON.parse(said ?? 'null');
  check(
    'the host states on the heartbeat that it has abandoned a frame the page has never seen',
    !!ex && ex.beats > 0,
    `no heartbeat carried an exhausted in_flight within 30 s: ${said} — every assertion below `
      + 'would be about a silence, which is the case W.2.3.2 already covered',
  );

  /* **`withdrew_at` is sampled BY THE PAGE, at the withdrawal.** Reading
     `link_heard_at` from here a round trip later reads a page that has been
     receiving heartbeats in the meantime, and the whole question is what was
     true at the instant it decided. Same discipline as the transport-gap
     witness sampling at the gap; the difference is that only the page can
     see this one — and the DOM half rides the observer armed above, for the
     same reason. */
  const exGone = await waitSoft(
    () => script('return window.__ex.latch ? JSON.stringify(window.__ex.latch) : null'),
    30_000);
  const exW = JSON.parse(exGone ?? 'null');

  check(
    'and the page stops claiming the projection it can no longer be shown a successor to',
    !!exW && exW.w.reason === 'exhausted',
    `withdrawal = ${exGone} — the page went on presenting a projection the runtime had `
      + 'positively told it was superseded and undeliverable',
  );

  /* **THE CLAUSE THAT MAKES THIS A WITNESS FOR THIS PATH AND NO OTHER, AND
     IT HAS TO NAME BOTH DEADLINES.**

     Three things can end a claim now, and under this fault two of them
     eventually would: the silence lease cannot (heartbeats keep arriving),
     but the PROJECTION deadline can — the same stuck frame stops every
     heartbeat attesting, so about a lease later the page withdraws anyway,
     as `unmaintained`. A witness that only required "the link was alive"
     would pass against a cockpit with the exhaustion path deleted, several
     seconds late, and report it as coverage.

     So the assertion is that **neither deadline had expired**. Exhaustion is
     not a timeout at all: it is the page acting on a positive statement, at
     a moment when waiting was still an available option and would have been
     the wrong one. */
  check(
    'while NEITHER deadline had expired — a statement acted on, not a timeout run out',
    !!exW && exW.w.link_age_ms !== null && exW.w.link_age_ms < exW.w.lease_ms
      && exW.w.projection_age_ms !== null && exW.w.projection_age_ms < exW.w.lease_ms
      && exW.w.beats > Number(await script('return window.__ex.beatsAtArm')),
    `at the withdrawal the link had been quiet ${exW?.w?.link_age_ms} ms and the projection `
      + `unattested ${exW?.w?.projection_age_ms} ms of a ${exW?.w?.lease_ms} ms lease, beats `
      + `${exW?.w?.beats} against ${await script('return window.__ex.beatsAtArm')} when the fault `
      + 'was armed — if either had run out, some deadline produced this withdrawal and the '
      + 'exhaustion statement is still unmeasured',
  );

  check(
    'and it withdraws exactly as a lost stream does — no world region, no submittable authority',
    !!exW && exW.rows === 0 && exW.headings === 0 && exW.live === 0 && exW.badge === 'reacquire',
    `state at the withdrawal = ${exGone} — a page that knows it is behind and goes on offering `
      + 'authority against what it is showing is worse than one that knows nothing',
  );

  /* The swallow is scoped to the channel, so the candidate the withdrawal
     builds is healthy and the recovery is the shipped path with nothing
     un-sabotaged. */
  const exBack = await waitSoft(
    () => script(`return (!window.cockpit.withdrawn
                          && window.cockpit.frame.state === 'live-local'
                          && window.cockpit.channel_id !== window.__ex.on
                          && window.cockpit.applied > window.__ex.appliedAtArm) ? 1 : null`),
    45_000);
  check(
    'and a fresh channel brings back a state later than the one that was abandoned',
    exBack === 1,
    `withdrawn=${await script('return window.cockpit.withdrawn')} `
      + `channel=${await script('return window.cockpit.channel_id')} `
      + `applied=${await script('return window.cockpit.applied')} against `
      + `${await script('return window.__ex.appliedAtArm')} at the arm — a page that withdraws `
      + 'and does not recover has traded one wrong state for another',
  );

  await script('window.__ex.obs.disconnect(); window.cockpit.deliver = window.__realDeliver;');

  /* ── W.2.3.1 · the gap goes UNDER the ordering layer ───────────────────

     Everything above sabotages `window.cockpit.deliver`, which is the
     application's own entry point — **downstream of a transport whose
     hidden state is the thing that actually breaks.** Tauri 2.11.5's
     JavaScript `Channel` keeps a private `#nextMessageIndex`; the Rust side
     stamps a new transport index on every `Channel::send`; and the
     receiving callback delivers a message only when its index equals the
     one being waited for, buffering anything ahead of a hole in
     `#pendingMessages`:

         if (index === next) { onmessage(m); next++; drain pending }
         else                { pending[index] = m }          ← forever

     Two consequences the `deliver`-level witness cannot reach, and both
     matter:

       · a same-seq retransmission arrives under a NEW transport index and
         is buffered behind the hole it was sent to fill, so **nothing sent
         on that channel can ever repair it**;
       · later heartbeats queue behind the same hole, so the lease fires —
         which is what makes the recovery correct rather than lucky.

     So W.2.3's "retransmission closes wry#1644" was one layer too high.
     Retransmission closes loss ABOVE the ordering layer. Only the lease and
     a FRESH channel close loss below it. This witness puts a falsifier
     under the second half.

     The sabotage is at the callbacks map, not at `runCallback`.
     `scripts/core.js` installs `runCallback` with
     `Object.defineProperty(obj, name, {value})` — omitted `writable` and
     `configurable` both default to false — and assigning to it from module
     code throws `TypeError: Attempted to assign to readonly property`
     (measured). Tauri does expose the `callbacks` Map itself, and
     `runCallback(id, data)` is `callbacks.get(id)(data)`, so replacing an
     entry drops a raw payload *before the Channel's own closure runs*. From
     the Channel's side that is indistinguishable from a `run_javascript`
     that never executed: index N simply never existed.

     TWO channels are gapped, not one, and that is what makes this a witness
     for reacquisition being a LOOP: W.2.3's `withdraw()` returned early once
     `withdrawn` was set and only a delivered message could clear it, so
     exactly one rebind was ever attempted and a second dead channel wedged
     the page permanently. Against a single gap it looks like a working
     recovery. */

  const gapArmed = await script(`
    window.__gap = {
      armed: 2, wrapped: [], real: new Map(),
      dropped: [], after: {}, gapped: [],
    };
    window.__wrapChannel = (id) => {
      const g = window.__gap;
      const cbs = window.__TAURI_INTERNALS__.callbacks;
      if (g.wrapped.indexOf(id) !== -1 || !cbs.has(id)) return;
      const real = cbs.get(id);
      g.wrapped.push(id);
      g.real.set(id, real);
      cbs.set(id, (data) => {
        const schema = data && data.message && data.message.schema;
        /* WHATEVER ARRIVES FIRST. An early draft waited for a
           cockpit-frame on this channel, so the witness could say a state a
           person was entitled to see had been lost. It measured nothing for
           twenty-five seconds: this late in the run the intent it fired did
           not move the projection cursor, so no frame was produced, the gap
           never happened, and four downstream checks went red for want of a
           FAULT rather than for want of a fix. A failed run_javascript does
           not care what the payload was and neither does the ordering
           layer: any lost index wedges the channel. This version does not
           depend on the world moving, which is also the only version that
           could run against a quiet one. */
        if (g.gapped.indexOf(id) === -1 && g.armed > 0) {
          g.gapped.push(id);
          g.armed -= 1;
          g.after[id] = 0;
          /* Sampled HERE, at the instant of the gap, not from the harness
             afterwards. A heartbeat landing between a read and the gap
             would otherwise look like a message that crossed it. */
          g.dropped.push({ id, index: data.index, schema,
                           seq: data.message && data.message.seq,
                           frames: window.cockpit.frames,
                           beats: window.cockpit.beats,
                           applied: window.cockpit.applied });
          return;                      /* the eval that never ran */
        }
        /* Counted, then handed on: the Channel must buffer these exactly as
           it would have, or the witness is measuring our own bookkeeping
           rather than Tauri's ordering. */
        if (g.gapped.indexOf(id) !== -1) g.after[id] += 1;
        return real(data);
      });
    };
    window.__gapTick = setInterval(() => {
      const id = window.cockpit.channel_id;
      if (typeof id === 'number') window.__wrapChannel(id);
    }, 100);
    return typeof window.cockpit.channel_id;
  `);

  check(
    'the page names the transport it is bound to, so a witness can reach under it',
    gapArmed === 'number',
    `window.cockpit.channel_id is ${gapArmed} — the failure below onmessage cannot be modelled`,
  );

  const firstId = await script('return window.cockpit.channel_id');
  const rebindsBefore = await script('return window.cockpit.rebinds');

  const gapped = await waitSoft(
    () => script('return window.__gap.dropped.length ? JSON.stringify(window.__gap.dropped[0]) : null'),
    25_000);
  const drop0 = JSON.parse(gapped ?? 'null');
  check(
    'a raw Channel callback can be lost below the ordering layer, carrying its transport index',
    !!drop0 && Number.isInteger(drop0.index) && typeof drop0.schema === 'string',
    `dropped = ${gapped} — the witness below would be modelling the wrong layer`,
  );

  /* **Two, and the count is bounded by the lease rather than by patience.**
     The window in which this can be observed opens at the gap and closes
     when the page retires the channel on its rebind, which is one lease —
     six seconds, so about three heartbeats. Requiring three raced the
     withdrawal that stops the count and went red against a working fix.
     Two payloads the host sent, that this wrapper saw, that never reached
     `onmessage`, is the whole of the ordering claim; a third adds patience,
     not evidence.

     Sampled in the SAME call, so the withdrawal that follows cannot move
     the counters between a read and a comparison. */
  const held2 = await waitSoft(
    () => script(`
      const g = window.__gap, id = ${firstId};
      if (!(g.after[id] >= 2)) return null;
      return JSON.stringify({ after: g.after[id],
                              frames: window.cockpit.frames,
                              beats: window.cockpit.beats });`),
    25_000);
  const wedged = JSON.parse(held2 ?? 'null');
  check(
    'the host goes on sending on that channel — this is loss, not a quiet world',
    !!wedged,
    `only ${await script(`return window.__gap.after[${firstId}]`)} further payloads reached the `
      + 'wedged channel; the ordering evidence below would be vacuous',
  );

  check(
    'and NONE of it reaches the page — a retransmission cannot fill a hole in the transport',
    !!wedged && !!drop0 && wedged.frames === drop0.frames && wedged.beats === drop0.beats,
    `at the gap frames=${drop0?.frames} beats=${drop0?.beats}; after ${wedged?.after} further `
      + `payloads frames=${wedged?.frames} beats=${wedged?.beats} — if either moved, the sabotage `
      + 'was above the ordering layer and this proves nothing',
  );

  /* ── and the stale world is withdrawn, UNDER THIS FAULT ────────────────
     The withdrawal is asserted above too, but under a `deliver`-level
     sabotage — and the whole finding of this round is that **a property
     asserted under a different fault is not evidence for this one**. So it
     is asserted again here, against a gap in the transport, where the page
     has no way to know anything is wrong except that it has heard nothing.

     Sampled in ONE call. Channel B is gapped as well so the page stays
     withdrawn until C lands, but a check that read four values separately
     could still straddle the recovery and report a mixture of both. */
  const staleWorld = await waitSoft(
    () => script(`
      if (!window.cockpit.withdrawn) return null;
      return JSON.stringify({
        rows: document.querySelectorAll('#world .row').length,
        headings: document.querySelectorAll('#world h2').length,
        live: document.querySelectorAll('button[data-intent]:not([disabled])').length,
        badge: document.getElementById('badge-state').dataset.state,
      });`),
    25_000);
  const sw = JSON.parse(staleWorld ?? 'null');
  check(
    'the lease withdraws the stale world under a transport gap, not just an application one',
    !!sw && sw.rows === 0 && sw.headings === 0 && sw.live === 0 && sw.badge === 'reacquire',
    `withdrawn state = ${staleWorld} — a page that went on showing a world nobody was maintaining, `
      + 'or went on offering authority to submit against it',
  );

  const rebound = await waitSoft(
    () => script(`return window.cockpit.rebinds > ${rebindsBefore + 1} ? window.cockpit.rebinds : null`),
    40_000);
  check(
    'reacquisition keeps trying — a second dead channel does not end the recovery',
    rebound !== null,
    `rebinds stayed at ${await script('return window.cockpit.rebinds')} against `
      + `${rebindsBefore} before two gapped channels — one attempt is not a recovery`,
  );

  /* **Every clause is required, and the last two are why.** `!withdrawn`
     and `live-local` are both true of a page that never lost anything, so
     on their own this check passes against a witness that produced no
     fault at all — which is exactly how an earlier draft of it went green
     while the gap it was reporting on had never fired. A frame later than
     anything held at the gap, on a channel this page was not bound to
     then, is a statement only recovery can satisfy. */
  const back = await waitSoft(
    () => script(`return (!window.cockpit.withdrawn
                          && window.cockpit.frame.state === "live-local"
                          && window.cockpit.applied > ${drop0?.applied ?? Number.MAX_SAFE_INTEGER}
                          && window.cockpit.channel_id !== ${firstId}) ? 1 : null`),
    40_000);
  check(
    'and a FRESH channel restores LIVE LOCAL — with nothing un-sabotaged and no reload',
    back === 1,
    `withdrawn=${await script('return window.cockpit.withdrawn')} `
      + `state=${await script('return window.cockpit.frame && window.cockpit.frame.state')} `
      + `applied=${await script('return window.cockpit.applied')} (at the gap ${drop0?.applied}) `
      + `channel=${await script('return window.cockpit.channel_id')} (at the gap ${firstId}) — `
      + 'the lease withdrew the claim and nothing replaced it',
  );

  check(
    'on a channel this page had not been bound to when the gap was made',
    (await script('return window.cockpit.channel_id')) !== firstId,
    'the world came back on the wedged channel, which would mean the gap healed itself',
  );

  /* **The distinction the two rules make.** A retransmission repairs an
     outstanding frame on a live channel, and must be the same sequence and
     the same bytes — inventing a newer state there skips one a person was
     entitled to see. A REACQUISITION follows an admitted gap in knowledge
     the page has already told the person about, and must show what the
     world IS; replaying a superseded state there presents the past as the
     present. `Delivery::bind` clears `sent`, so what comes back is the
     current state under a later sequence, and that is correct. */
  const appliedNow = await script('return window.cockpit.applied');
  check(
    'the recovered frame is the PRESENT, not a replay of the state that was lost',
    Number.isInteger(drop0?.applied) && appliedNow > drop0.applied
      && (drop0.seq === undefined || drop0.seq === null || appliedNow > drop0.seq),
    `applied ${appliedNow} against ${drop0?.applied} held at the gap and lost seq ${drop0?.seq} — `
      + 'a reacquisition shows what the world IS; only an outstanding frame on a live channel '
      + 'is repaired as itself',
  );

  /* **The region is rebuilt from the frame, and nothing is left disabled.**
     An earlier version of this asserted `#world .row` was non-empty, which
     is a claim about the WORLD's contents — by this point in the run the
     flagship and four witnesses have revoked everything, so a correct
     recovery onto an empty world failed it. `render()` writes its section
     headings whatever the lists hold; the withdrawal writes one paragraph
     and no headings. That is the frame-derived difference.

     **The count is read from the page, not written here.** It was `=== 3`,
     which was the section count on the day this was written — so adding a
     section to `ui/cockpit.js` failed a check about *recovery*, in another
     language, for a reason with nothing to do with recovery. `render()`
     now publishes how many sections it appended, and this compares the DOM
     against that. Stronger, not weaker: a hardcoded literal only ever
     caught the UI changing, while this catches a region that was built
     half-way. */
  check(
    'the world region is rebuilt from that frame, and authority is submittable again',
    (await script(`
       const h = document.querySelectorAll('#world h2').length;
       const intended = window.cockpit.rendered?.sections ?? 0;
       return h > 0 && h === intended;`)) === true
      && (await script('return document.getElementById("badge-state").dataset.state')) === 'live-local'
      && (await script('return document.querySelectorAll("button[data-intent][disabled]").length')) === 0,
    `#world h2 = ${await script('return document.querySelectorAll(\'#world h2\').length')}, `
      + `render intended ${await script('return window.cockpit.rendered?.sections ?? 0')}, `
      + `badge = ${await script('return document.getElementById("badge-state").dataset.state')}, `
      + `disabled controls = ${await script('return document.querySelectorAll("button[data-intent][disabled]").length')} `
      + '— the page stopped claiming and never started again',
  );

  /* ── and the channel it abandoned is retired ─────────────────────────
     A Channel unregisters itself when `#nextMessageIndex` reaches the `end`
     index its Rust side sends on drop. A permanent hole is exactly the
     state in which that count never gets there, so the callback stays
     registered and its `#pendingMessages` goes on holding a whole
     projection per buffered frame. Measured on the running app before this
     fix: after one dropped callback the abandoned id was still in the map.
     The page now performs `cleanupCallback()`'s own body in the one case
     its caller can never run. */
  check(
    'the wedged channel is retired rather than left registered with its buffered frames',
    (await script(`return !window.__TAURI_INTERNALS__.callbacks.has(${firstId})`)) === true
      && (await script(`return window.cockpit.retired.indexOf(${firstId}) !== -1`)) === true,
    `callbacks still holds ${firstId}; retired = `
      + `${await script('return JSON.stringify(window.cockpit.retired)')}`,
  );

  await script(`
    clearInterval(window.__gapTick);
    window.__gap.armed = 0;
  `);

  /* ── W.2.3.2 · a candidate is judged by the SAME deadline as the stream ─

     W.2.3.1 gave a replacement channel 3 s to prove itself while an
     established channel got the host's advertised 6 s lease — **the
     recovery held its candidates to a stricter timing guarantee than the
     failure detector whose verdict put it there.** A healthy channel whose
     first frame took four seconds was killed at three, and so was the next
     one: a permanent outage manufactured out of a merely slow recovery, by
     the mechanism that exists to end outages.

     Modelled by DELAYING rather than dropping. The first payload on the
     candidate is held back four seconds and everything after it is passed
     straight through, which is what a slow transport actually does — the
     Channel buffers the later indices behind the held one and drains them
     when it lands. Four seconds is past W.2.3.1's 3 s and inside the 6 s
     lease, so the two behaviours are distinguishable by construction and
     not by luck.                                                        */

  const slowSetup = await script(`
    window.__slow = { first: null, second: null, delayed: null, real: new Map(), wrapped: [] };
    window.__slowWrap = (id) => {
      const s = window.__slow;
      const cbs = window.__TAURI_INTERNALS__.callbacks;
      if (s.wrapped.indexOf(id) !== -1 || !cbs.has(id)) return;
      const real = cbs.get(id);
      s.wrapped.push(id);
      s.real.set(id, real);
      if (s.first === null) s.first = id;
      else if (s.second === null) s.second = id;
      cbs.set(id, (data) => {
        /* channel 1 · lose the first raw callback, to force a withdrawal */
        if (id === s.first && !s.gapped) { s.gapped = true; return; }
        /* channel 2 · hold the first raw callback back, healthy but slow */
        if (id === s.second && s.delayed === null) {
          s.delayed = data.index;
          setTimeout(() => real(data), 4000);
          return;
        }
        return real(data);
      });
    };
    window.__slowTick = setInterval(() => {
      const id = window.cockpit.channel_id;
      if (typeof id === 'number') window.__slowWrap(id);
    }, 100);
    return window.cockpit.channel_id;
  `);

  const slowBack = await waitSoft(
    () => script(`
      const s = window.__slow;
      if (s.delayed === null) return null;
      if (window.cockpit.withdrawn || window.cockpit.unavailable) return null;
      if (window.cockpit.frame.state !== 'live-local') return null;
      return JSON.stringify({ on: window.cockpit.channel_id, second: s.second,
                              candidates: window.cockpit.candidates,
                              delayed: s.delayed });`),
    45_000);
  const sl = JSON.parse(slowBack ?? 'null');
  check(
    'a slow but healthy candidate is not killed by the recovery that is trying to use it',
    !!sl && sl.on === sl.second,
    `recovered on channel ${sl?.on} against candidate ${sl?.second} — a candidate discarded `
      + 'sooner than the failure detector allows turns a slow recovery into a permanent outage',
  );

  await script('clearInterval(window.__slowTick);');

  /* ── W.2.3.2 · and the recovery itself is bounded ──────────────────────

     `RETRY_LIMIT` bounds how many times ONE channel is written to. It is
     not a bound on anything if the page may then build another channel, and
     another, without end — **a local budget that recovery can re-mint is
     not a budget.** Under a permanently broken transport W.2.3.1 allocated
     channels forever, and on Tauri's >8192 path each send whose script
     never ran leaves a whole serialised projection in `ChannelDataIpcQueue`
     — Rust-side state that page-side callback retirement cannot reach.

     So: blackhole EVERY raw callback on EVERY channel, and require the page
     to stop. Not to keep trying quietly, and not to claim anything: to
     reach a state that spends nothing and says so.                       */

  const blackholed = await script(`
    window.__bh = { wrapped: [], real: new Map(), ate: 0 };
    window.__bhWrap = (id) => {
      const b = window.__bh;
      const cbs = window.__TAURI_INTERNALS__.callbacks;
      if (b.wrapped.indexOf(id) !== -1 || !cbs.has(id)) return;
      b.real.set(id, cbs.get(id));
      b.wrapped.push(id);
      cbs.set(id, () => { b.ate += 1; });      /* nothing ever gets through */
    };
    window.__bhTick = setInterval(() => {
      const id = window.cockpit.channel_id;
      if (typeof id === 'number') window.__bhWrap(id);
    }, 50);
    return window.cockpit.rebinds;
  `);

  const gaveUp = await waitSoft(
    () => script(`
      if (!window.cockpit.unavailable) return null;
      return JSON.stringify({
        candidates: window.cockpit.candidates,
        rebinds: window.cockpit.rebinds,
        channels: window.__bh.wrapped.length,
        rows: document.querySelectorAll('#world .row').length,
        headings: document.querySelectorAll('#world h2').length,
        live: document.querySelectorAll('button[data-intent]:not([disabled])').length,
        retry: !!document.getElementById('retry-stream'),
        channel_id: window.cockpit.channel_id,
      });`),
    60_000);
  const gu = JSON.parse(gaveUp ?? 'null');
  check(
    'a permanently broken transport reaches a terminal state instead of retrying forever',
    !!gu && gu.candidates === 3,
    `unavailable = ${gaveUp} against ${blackholed} rebinds before — recovery that can re-mint `
      + 'its own budget is not bounded, whatever the per-channel retry limit says',
  );

  check(
    'and the terminal state claims nothing — no world, no submittable authority',
    !!gu && gu.rows === 0 && gu.headings === 0 && gu.live === 0 && gu.retry === true
      && gu.channel_id === null,
    `terminal state = ${gaveUp} — it must withdraw exactly as the lease did, and additionally `
      + 'hold no channel',
  );

  /* **The bound is the point, so it is measured after the fact rather than
     inferred from reaching the state.** Twenty seconds is six lease periods
     and better than six of W.2.3.1's reacquisition intervals.

     **And the instrument has to be re-installed first, because the code
     under test removes it.** The blackhole counts by owning the entry in
     `__TAURI_INTERNALS__.callbacks` — and reaching UNAVAILABLE *retires*
     that entry, which deletes the counter. So the host could go on sending
     forever and `ate` would sit still, because `runCallback` finds no
     callback and only warns. The first version of this check therefore
     passed with the fix disabled: `sabotage-cockpit.sh` said NOT A
     FALSIFIER and refused the release, which is the harness doing exactly
     what it exists for.

     The harness now re-registers a bare counter under every id the page has
     abandoned. Nothing here is read by the page — it measures the PRODUCER.
     With the unbind the host holds no sink and nothing lands; without it
     the host beats into the void every 1.5 s and this counts every one. */
  const idle = await script(`
    const b = window.__bh;
    b.ate = 0; b.ends = 0; b.saw = [];
    for (const id of b.wrapped) {
      window.__TAURI_INTERNALS__.callbacks.set(id, (data) => {
        /* **Tauri's own end-of-channel notification is not the host still
           writing — it is the unbind having worked.** \`Delivery::unbind\`
           drops the Rust Channel, whose \`on_drop\` evals
           \`{end: true, index: N}\`. Counting it made this check demand
           ZERO payloads where exactly one was expected, and the chain
           refused a correct fix over it. Excluded by shape, not by a
           tolerance: a threshold of "one or fewer" would also have
           swallowed a real send. */
        if (data && typeof data === 'object' && 'end' in data) { b.ends += 1; return; }
        b.ate += 1;
        if (b.saw.length < 4) b.saw.push(Object.keys(data || {}).join(','));
      });
    }
    return JSON.stringify({rebinds: window.cockpit.rebinds, channels: b.wrapped.length});`);
  await sleep(20_000);
  const later = await script('return JSON.stringify({rebinds: window.cockpit.rebinds, channels: window.__bh.wrapped.length, ate: window.__bh.ate, ends: window.__bh.ends, saw: window.__bh.saw})');
  const a = JSON.parse(idle); const b = JSON.parse(later);
  check(
    'and it stops SPENDING — no further channel is allocated and none is bound',
    a.rebinds === b.rebinds && a.channels === b.channels,
    `rebinds ${a.rebinds} → ${b.rebinds}, channels ${a.channels} → ${b.channels} over 20 s — `
      + 'a terminal state that goes on allocating is a slower unbounded loop, not a bound',
  );

  check(
    'and the HOST stops sending — unbinding is what ends the cost, not unregistering',
    b.ate === 0,
    `${b.ate} payloads ${JSON.stringify(b.saw)} reached the abandoned channels over 20 s `
      + `(${b.ends} end-of-channel notices excluded) — retiring the callback stops this page `
      + 'reading; only the unbind stops the runtime writing, and on the >8192 path every '
      + 'write whose script never runs parks a projection nothing here can reclaim',
  );

  /* **`total > length` is what makes this non-vacuous.** A ring that has
     never had to discard anything is indistinguishable from an unbounded
     array, and asserting only the ceiling would pass against one on any run
     that happened not to reach it. */
  const ring = JSON.parse(await script(
    'return JSON.stringify({kept: window.cockpit.retired.length, total: window.cockpit.retired_total})'));
  check(
    'and the diagnostic collection is bounded too, in a round about bounded recovery',
    ring.kept <= 4 && ring.total > ring.kept,
    `retired = ${ring.kept} ids kept of ${ring.total} retirements — `
      + (ring.total <= ring.kept
        ? 'the ring never had to discard anything, so this proves nothing'
        : 'the collection grew with the failure it exists to describe'),
  );

  /* ── and a person may start a new episode ───────────────────────────── */

  await script(`
    clearInterval(window.__bhTick);
    for (const [id, fn] of window.__bh.real) window.__TAURI_INTERNALS__.callbacks.set(id, fn);
  `);
  /* Guarded. A sabotage that stops the terminal state from ever being
     reached leaves no button here, and an unguarded `.click()` would throw
     out of the run — killing the harness instead of failing the check that
     names the defect, which is the `waitSoft` lesson in a different costume. */
  await script('const b = document.getElementById("retry-stream"); if (b) b.click(); return !!b;');

  const resumed = await waitSoft(
    () => script(`return (!window.cockpit.unavailable && !window.cockpit.withdrawn
                          && window.cockpit.frame.state === 'live-local'
                          && window.cockpit.episodes === 1) ? 1 : null`),
    45_000);
  check(
    'a deliberate retry begins a new bounded episode and the world comes back',
    resumed === 1,
    `unavailable=${await script('return window.cockpit.unavailable')} `
      + `episodes=${await script('return window.cockpit.episodes')} — the budget is spent by the `
      + 'page, so only a person may replenish it, and doing so must actually work',
  );

  /* ── W.2.3.3 · an instruction from a position that no longer exists ────

     `unavailable()` fires `unbind_frame_stream` and does not await it. A
     person may press *Try again* immediately, which fires `bind_frame_stream`
     behind it. `main.rs` used to say those two could not overtake one
     another because they travel the same control lane — **and that is not a
     guarantee the mechanism provides.** The `SyncSender` orders what is
     already in it; getting there is `crate::async_runtime::spawn` per
     command (`tauri-2.11.5/src/ipc/mod.rs`, `respond_async`) and then a
     `spawn_blocking` per send, a pool with no ordering between tasks. Two
     invokes issued in order are two independent futures racing.

     Prose describing a boundary that does not exist is the W.2.1 defect
     exactly, and it reads as coverage. The ordering is carried by the
     MESSAGE now: every bind and unbind names the binding it addresses, and
     the host obeys a teardown only for the binding it is holding.

     **Measured by the heartbeat, not by the world moving.** If the host had
     obeyed a stale unbind it would hold no sink, and `beat()` returns early
     with no sink — so beats continuing is a direct statement that the stream
     survived, and it does not depend on a projection cursor that this late
     in the run an intent may not move. That dependency cost W.2.3.1 four
     checks and is written down there. */

  const fresh = async (f) => waitSoft(() => script(`
    const v = window.cockpit.valve;
    return (v && ${f}) ? JSON.stringify({ v, beats: window.cockpit.beats,
                                          channel: window.cockpit.channel_id }) : null;`), 20_000);

  const base = JSON.parse(await fresh('true') ?? 'null');
  check(
    'the heartbeat names the binding the host is holding, and what it has refused',
    !!base && !!base.v.stream && typeof base.v.stream.page === 'string'
      && Number.isInteger(base.v.stream.generation)
      && Number.isInteger(base.v.stale_binds) && Number.isInteger(base.v.stale_unbinds),
    `valve = ${JSON.stringify(base?.v)} — a page that could not see a refusal has no way to `
      + 'tell a stale unbind that was ignored from one that was obeyed and killed its stream',
  );

  const held0 = base?.v?.stream ?? { page: 'unknown', generation: 1 };

  await scriptAsync(`
    const done = arguments[arguments.length - 1];
    window.__TAURI__.core.invoke('unbind_frame_stream',
      { stream: { page: ${JSON.stringify(held0.page)}, generation: ${held0.generation - 1} } })
      .then(() => done(1), () => done(1));
  `);

  const refusedUnbind = await fresh(`v.stale_unbinds > ${base?.v?.stale_unbinds ?? 0}`);
  const ru = JSON.parse(refusedUnbind ?? 'null');
  check(
    'a teardown addressed to a superseded binding is refused, not obeyed',
    !!ru && ru.beats > (base?.beats ?? 0),
    `stale_unbinds ${base?.v?.stale_unbinds} → ${ru?.v?.stale_unbinds}, beats `
      + `${base?.beats} → ${ru?.beats} — the host stopped beating, which means it dropped the `
      + 'sink a live page was reading on the word of a message about a stream that is gone',
  );

  await scriptAsync(`
    const done = arguments[arguments.length - 1];
    window.__TAURI__.core.invoke('bind_frame_stream', {
      stream: { page: ${JSON.stringify(held0.page)}, generation: ${held0.generation - 1} },
      channel: new window.__TAURI__.core.Channel(),
    }).then(() => done(1), () => done(1));
  `);

  const refusedBind = await fresh(`v.stale_binds > ${base?.v?.stale_binds ?? 0}`);
  const rb = JSON.parse(refusedBind ?? 'null');
  check(
    'and a sink offered from one is refused too — it would point the host at a dead channel',
    !!rb && rb.beats > (ru?.beats ?? 0) && rb.v.stream
      && rb.v.stream.generation === held0.generation,
    `stale_binds ${base?.v?.stale_binds} → ${rb?.v?.stale_binds}, beats ${ru?.beats} → `
      + `${rb?.beats}, holding generation ${rb?.v?.stream?.generation} against ${held0.generation} `
      + '— the host adopted a channel the page had already retired, and would have spent a '
      + 'whole lease finding out',
  );

  /* **AND THE SAME COMMAND, CORRECTLY ADDRESSED, MUST STILL WORK.** Without
     this the two checks above pass against a host that ignores every unbind
     — which would ALSO break W.2.3.2's terminal state, in a way no assertion
     here would name. The recovery afterwards is the shipped lease doing what
     it does when a stream goes away, with nothing sabotaged. */
  await scriptAsync(`
    const done = arguments[arguments.length - 1];
    window.__TAURI__.core.invoke('unbind_frame_stream',
      { stream: ${JSON.stringify(held0)} }).then(() => done(1), () => done(1));
  `);

  /* **BOTH SAMPLES ARE TAKEN AFTER THE TEARDOWN HAS LANDED, AND BOTH ARE
     INSIDE THE LEASE.** The first draft compared the beat count captured
     with the refusal above against one read five seconds later, and that is
     a race in both directions: a heartbeat can land in the few hundred
     milliseconds between capturing it and the unbind reaching the worker, so
     a correct host looks like it kept beating; and five seconds later the
     page's own lease has fired, rebound, and the host is legitimately
     beating again on a new binding, so a correct host looks like it never
     stopped. The window is opened after the teardown can no longer be in
     flight and closed before the lease can expire — two heartbeat intervals
     of silence, which is a fact about the host and not about the clock. */
  await sleep(1_500);
  const quiet0 = Number(await script('return window.cockpit.beats'));
  await sleep(3_000);
  const quiet1 = Number(await script('return window.cockpit.beats'));
  check(
    'while the same teardown, addressed to the binding actually held, does stop the host',
    quiet0 === quiet1,
    `beats ${quiet0} → ${quiet1} across two heartbeat intervals after an unbind naming the `
      + 'live binding — the two refusals above would be satisfied by a host that ignores every '
      + 'unbind, which is W.2.3.2 undone rather than W.2.3.3 held',
  );

  const healed = await waitSoft(
    () => script(`return (!window.cockpit.withdrawn && !window.cockpit.unavailable
                          && window.cockpit.frame.state === 'live-local'
                          && window.cockpit.stream.generation > ${held0.generation}) ? 1 : null`),
    45_000);
  check(
    'and the page rebinds under a new generation, which the host accepts',
    healed === 1,
    `generation ${await script('return window.cockpit.stream && window.cockpit.stream.generation')} `
      + `against ${held0.generation} held before, withdrawn=`
      + `${await script('return window.cockpit.withdrawn')} — the identity that refuses a stale `
      + 'binding must not refuse the page its next legitimate one',
  );

  /* ── W.2.1 · a sink that binds late is brought up to date ─────────────
     W.2 used a global event against a listener that registers
     asynchronously; a frame emitted before registration was gone, and
     because the valve had already marked it in flight, nothing further
     could be sent. A reload is the latest possible registration — the
     runtime has been live for a minute and the world is not about to
     change — so if a late sink is only fed by the *next* change, this page
     stays blank forever. */

  await wd('POST', `/session/${session}/refresh`, {});

  const relive = await waitSoft(
    () => script('return window.cockpit && window.cockpit.frame ? window.cockpit.frame.state : null')
      .then((v) => (v === 'live-local' ? v : null)),
    45_000);
  check(
    'a sink that binds after the world is already live is brought up to the current state',
    relive === 'live-local',
    'the reloaded page never received a frame — a late sink is a blank cockpit',
  );

  const relivedGrants = await script(
    'return (window.cockpit.frame.projection.grants || []).length',
  );
  check(
    'and what it is brought up to is the world as it is now, not as it was',
    relivedGrants === 0,
    `the revoked grant came back: ${relivedGrants} grants`,
  );

  /* ── W.2.1 · the untrusted pane is refused by Tauri, not by us ────────
     Not by `INTENT_SURFACE`, which only decides what an *allowed* webview
     may ask for. The pane holds no capability, so the command is not
     something it may invoke at all. */

  await focus(PANE);

  /* **First, that the pane could have.** A refusal is only evidence about
     the ACL if the thing being refused was otherwise reachable: a pane
     with no `invoke` at all would fail every check below for a reason that
     has nothing to do with authority, and would read as coverage. It has
     the bridge — Tauri injects it into every webview — which is precisely
     why the ACL has to be the thing that says no. */
  const paneBridge = await script(
    'return typeof (window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke)',
  );
  check(
    'the untrusted pane holds a working Tauri bridge — the refusal below is not a missing API',
    paneBridge === 'function',
    `typeof invoke = ${paneBridge}`,
  );

  const paneIntent = await scriptAsync(`
    const done = arguments[arguments.length - 1];
    window.__TAURI__.core
      .invoke('intent', { name: 'revoke_grant', args: { grant_id: 'gr_0193' } })
      .then((v) => done({ ok: true, v: JSON.stringify(v) }), (e) => done({ ok: false, e: String(e) }));
  `);
  check(
    'an unprivileged webview may not invoke intent at all — Tauri refuses it, not our JavaScript',
    paneIntent.ok === false && /not allowed by ACL/.test(paneIntent.e ?? ''),
    JSON.stringify(paneIntent),
  );

  const paneBind = await scriptAsync(`
    const done = arguments[arguments.length - 1];
    const ch = new window.__TAURI__.core.Channel();
    window.__TAURI__.core
      .invoke('bind_frame_stream', { channel: ch })
      .then(() => done({ ok: true }), (e) => done({ ok: false, e: String(e) }));
  `);
  check(
    'and it may not bind the frame stream either — it cannot become a second reader of the world',
    paneBind.ok === false && /not allowed by ACL/.test(paneBind.e ?? ''),
    JSON.stringify(paneBind),
  );

  await focus(COCKPIT);
}

main();
