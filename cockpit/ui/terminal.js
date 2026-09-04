/* D.1.3c·2c·1b — the page half of the terminal data plane.
   D.1.3c·2c·1b·1 — fail-closed sequencing, a coalesced ack, and a beat.
   ────────────────────────────────────────────────────────────────────────

   THE LAW

     Acknowledge what has been CONSUMED, never what has arrived.

   `terminal_ack(seq)` is the only thing that returns credit, and the credit
   is what makes the whole chain hold still:

       this page stops acking
         → ampd stops forwarding
         → the terminal attachment stops selecting on its socket
         → the socketpair from the host fills                (SO_RCVBUF)
         → the host's pump stops draining the PTY master
         → the Carrier blocks in write(2)

   Every link is a process declining to read. None is a buffer that grows.
   Acking on ARRIVAL would still be a working program and would quietly
   move the boundary: the window would then bound the socket rather than
   the screen, and a renderer that fell behind would accumulate in the page
   instead of stopping the terminal. `Terminal.write(data, callback)` fires
   its callback after the data has been parsed into the buffer, which is
   why the ack lives in there and nowhere else.

   NOTHING HERE SENDS INPUT. There is no `onData`, no `onKey`, no resize
   observer and no dormant handler for any of them. `terminal_input` and
   `terminal_resize` are not commands this process registers, so they are
   not refused here — they do not exist. That is what makes OBSERVE a scope
   rather than a stage.

   ── D.1.3c·2c·1b·1 · three repairs, and each was a real defect ──────────

   1 · A GAP WAS COUNTED AND THEN ACKED ACROSS.

       The previous version said, correctly, that "acking past a gap would
       return credit for bytes that were never rendered" — and then did it:
       it incremented `gaps`, assigned `applied = msg.seq`, rendered the
       later frame and acknowledged it. A recorded fault that changes no
       behaviour is a comment, not a check. Sequencing now FAILS CLOSED:
       anything that is not exactly the next frame renders nothing, acks
       nothing, and ends the presentation.

   2 · ONE ACK INVOKE PER 4 KiB CHUNK, ISSUED CONCURRENTLY.

       Two Tauri invokes issued in order do not reach the `SyncSender` in
       order — each is its own `async_runtime::spawn` and its own
       `spawn_blocking`, which `cockpit/src/main.rs` documents at length for
       `bind`/`unbind`. The far side must tolerate that (and now does), but
       the page should not create the race it is asking the far side to
       absorb. At most one ack is in flight; completed xterm callbacks
       raise a high-water mark; the next invoke carries the highest.

   3 · SILENCE MEANT NOTHING.

       Tauri 2.11 has no webview-destroyed event — `WebviewEvent` carries
       `DragDrop` and nothing else — and `Channel::send` bottoms out in
       `send_user_message`, which is fire-and-forget: it returns `Ok` for a
       webview that no longer exists. So the cockpit cannot be *told* that
       this renderer is gone. It has to be shown that it is here. The beat
       below re-sends the high-water already sent, on a timer, so that
       *not* hearing from this page for `SUPER_TERMINAL_SILENCE_MS` is a
       fact rather than an absence of evidence.

       CORRECTION, and it is worth stating because the first draft of this
       comment got it backwards: a REPEATED ack of the same value was
       always tolerated by the plane — its old law refused `seq < acked`,
       and the beat sends `seq == acked`. What the old law killed was a
       STRICTLY OLDER ack, and the version of this file that shipped before
       today produced them: it invoked `terminal_ack` from every xterm
       callback with no in-flight gate, so several were outstanding at once
       and any pair could land reversed. Repair 2 makes this page
       single-flight and monotonic; the plane's repair removes its
       dependence on that discipline. Neither is redundant — one is the
       page not creating the race, the other is the protocol not being
       fatal when something else does.                                     */

const { invoke, Channel } = window.__TAURI__.core;

/* How often this page proves it is still here. Must be comfortably under
   the cockpit's `SUPER_TERMINAL_SILENCE_MS`; the cockpit picks that bound
   and this only has to be faster than it. */
const BEAT_MS = 250;

const el = { state: document.getElementById('state'), term: document.getElementById('term') };

const term = new window.Terminal({
  convertEol: false,
  cursorBlink: false,
  disableStdin: true,
  // Page-local, bounded, and the only scrollback that exists. There is no
  // server-side history to reopen into — `Ampd.Terminal.Plane` says why —
  // so a reopened presentation begins empty by construction rather than by
  // a decision made here.
  scrollback: 1000,
  fontSize: 12,
});
term.open(el.term);

/* Observable state, for `tools/cockpit-battery.mjs`. The battery reads what
   the product records rather than reconstructing it — a test that
   reimplements the acknowledgement is testing its own copy. */
const t = (window.terminalPane = {
  bound: false,
  frames: 0,
  bytes: 0,
  /** Highest sequence RENDERED. Contiguous by construction: see `next`. */
  applied: 0,
  /** Highest sequence xterm has finished parsing. Never behind `acked`. */
  consumed: 0,
  /** Highest sequence the cockpit has been told about and has answered. */
  acked: 0,
  duplicates: 0,
  gaps: 0,
  /** Beats sent, including the ones that carried no new credit. */
  beats: 0,
  /** Non-null once this presentation has been abandoned as unusable. */
  fault: null,
  closed: null,
  error: null,
});

let inFlight = false;

function say(s) {
  el.state.textContent = s;
}

function bytesOf(b64) {
  const raw = atob(b64);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i += 1) out[i] = raw.charCodeAt(i);
  return out;
}

/* **The whole sequencing rule, in one function, so that removing it is one
   edit.** `tools/cockpit-battery.mjs` sabotages exactly this — it replaces
   the comparison with `true` and requires that bytes then get acked across
   a hole. A check nothing can be shown to depend on is decoration. */
function next(seq) {
  return seq === t.applied + 1;
}

/* A protocol fault ends the presentation. It does not try to resynchronise
   and it does not render the suspect bytes.

   **OUT is not a snapshot and is not retransmitted**, which is why this
   plane does not inherit the cockpit projection's dedup semantics: there,
   a repeated frame is a retransmit and superseding it is correct; here, a
   repeated sequence means the two ends disagree about what was sent, and
   the only honest response to that is to stop. */
function fault(kind) {
  if (t.fault) return;
  t.fault = kind;
  say(`protocol fault: ${kind} — presentation abandoned`);
  // Best effort. The cockpit does not depend on this arriving: it closes
  // the socket itself when this page stops beating.
  invoke('terminal_close').catch(() => {});
}

/* **At most one ack in flight, carrying the highest consumed sequence.**

   `force` is the beat: it re-sends the high-water even when nothing new has
   been consumed, so that this page's silence is measurable. `seq` may be 0
   — a presentation that has produced no bytes yet still has to prove its
   renderer is here, and an ack of 0 returns no credit on either side. */
function pumpAck(force) {
  if (t.fault || t.closed) return;
  if (inFlight) return;

  const seq = target();
  if (!force && seq <= t.acked) return;
  if (force) t.beats += 1;

  inFlight = true;
  invoke('terminal_ack', { seq }).then(
    () => {
      if (seq > t.acked) t.acked = seq;
      inFlight = false;
      // A callback may have completed while this one was in flight.
      pumpAck(false);
    },
    (e) => {
      t.error = String(e);
      inFlight = false;
    },
  );
}

/* G · the browser-backpressure hook, and it holds the VALUE rather than the
   invoke. Held, this page keeps parsing — xterm still consumes, callbacks
   still fire, `consumed` still rises — and keeps proving it is alive, since
   the beat re-sends what was already acked. What it stops is the high-water
   ADVANCING, which is the only thing that returns credit. A hook that
   suppressed the invoke would also suppress the beat, and would then be
   measuring the renderer-loss watchdog rather than backpressure. */
function target() {
  return window.__terminalHold ? t.acked : t.consumed;
}

function deliver(msg) {
  if (!msg) return;

  if (msg.schema === 'terminal-close@1') {
    t.closed = msg.code;
    say(`presentation ended: ${msg.code}`);
    return;
  }

  if (t.fault || t.closed) return;

  if (msg.schema !== 'terminal-out@1') return fault('unknown-schema');
  if (!Number.isInteger(msg.seq)) return fault('non-integer-seq');
  if (typeof msg.b64 !== 'string') return fault('malformed-frame');

  /* Order matters here only for the counters — a duplicate and a gap are
     both faults and both stop. They are counted apart because "the plane
     re-sent" and "the plane skipped" are different bugs on the far side. */
  if (msg.seq <= t.applied) {
    t.duplicates += 1;
    return fault('duplicate-or-old-sequence');
  }
  if (!next(msg.seq)) {
    t.gaps += 1;
    return fault('sequence-gap');
  }

  let bytes;
  try {
    bytes = bytesOf(msg.b64);
  } catch (e) {
    return fault('malformed-b64');
  }

  t.applied = msg.seq;
  t.frames += 1;
  t.bytes += bytes.length;

  const seq = msg.seq;
  term.write(bytes, () => {
    if (seq > t.consumed) t.consumed = seq;
    pumpAck(false);
    say(`${t.frames} chunks · ${t.bytes} bytes · applied ${t.applied} · acked ${t.acked}`);
  });
}

/* The sink is offered at load, BEFORE any presentation can be opened. A
   presentation opened first would produce bytes with nowhere to go, and the
   cockpit process would have to hold them — which is the one thing the
   window cannot bound. `Terminal::park` on the Rust side refuses an open
   with no sink for that reason.

   This invoke is also how the cockpit learns that a NEW renderer exists: a
   page binds once, at load, so a bind arriving while a presentation is open
   means the page that presentation was opened for has been replaced. See
   `Terminal::bind_sink`. */
/* ── test hooks, and what they cannot do ──────────────────────────────

   `tools/cockpit-battery.mjs` needs to put a malformed or out-of-sequence
   frame into THIS page's decoder, because the plane will not produce one —
   which is the point of the plane, and is why the sequencing rule above
   would otherwise be unfalsifiable from the product.

   **Neither hook grants anything.** `__terminalDeliver` is the same
   function the Channel calls; its whole power is to render into this
   page's own xterm and to invoke `terminal_ack`, both of which this page
   can already do. It cannot make the plane send a byte, cannot reach the
   cockpit's authority, and cannot be seen from another webview.
   `__terminalHold` only lowers the value this page acknowledges, which is
   indistinguishable from a renderer that is slow. */
window.__terminalDeliver = deliver;
window.__terminalHold = false;

const stream = new Channel();
stream.onmessage = deliver;

invoke('terminal_stream', { channel: stream }).then(
  () => {
    t.bound = true;
    say('ready — no presentation');
    // The beat starts at bind, not at the first byte: a presentation that
    // opens and produces nothing still has a renderer that has to be
    // visible, and the cockpit's watchdog starts when the reader does.
    setInterval(() => pumpAck(true), BEAT_MS);
  },
  (e) => {
    t.error = String(e);
    say(`this webview may not offer a terminal sink: ${e}`);
  },
);
