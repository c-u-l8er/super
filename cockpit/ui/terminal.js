/* D.1.3c·2c·1b — the page half of the terminal data plane.
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
   rather than a stage.                                                   */

const { invoke, Channel } = window.__TAURI__.core;

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
  applied: 0,
  acked: 0,
  duplicates: 0,
  gaps: 0,
  closed: null,
  error: null,
});

function say(s) {
  el.state.textContent = s;
}

function bytesOf(b64) {
  const raw = atob(b64);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i += 1) out[i] = raw.charCodeAt(i);
  return out;
}

function deliver(msg) {
  if (!msg) return;

  if (msg.schema === 'terminal-close@1') {
    t.closed = msg.code;
    say(`presentation ended: ${msg.code}`);
    return;
  }

  if (msg.schema !== 'terminal-out@1') return;

  /* **A gap is recorded, never papered over.** The plane's claim is that
     `seq` is 1..n with no holes; if this page ever sees one, the claim is
     false and the number is how a reader finds out. Acking past a gap
     would return credit for bytes that were never rendered. */
  if (msg.seq === t.applied) {
    t.duplicates += 1;
    return;
  }
  if (msg.seq !== t.applied + 1) t.gaps += 1;
  t.applied = msg.seq;

  const bytes = bytesOf(msg.b64);
  t.frames += 1;
  t.bytes += bytes.length;

  term.write(bytes, () => {
    t.acked = msg.seq;
    invoke('terminal_ack', { seq: msg.seq }).catch((e) => {
      t.error = String(e);
    });
  });

  say(`${t.frames} chunks · ${t.bytes} bytes · applied ${t.applied} · acked ${t.acked}`);
}

/* The sink is offered at load, BEFORE any presentation can be opened. A
   presentation opened first would produce bytes with nowhere to go, and the
   cockpit process would have to hold them — which is the one thing the
   window cannot bound. `Terminal.park/1` on the Rust side refuses an open
   with no sink for that reason. */
const stream = new Channel();
stream.onmessage = deliver;

invoke('terminal_stream', { channel: stream }).then(
  () => {
    t.bound = true;
    say('ready — no presentation');
  },
  (e) => {
    t.error = String(e);
    say(`this webview may not offer a terminal sink: ${e}`);
  },
);
