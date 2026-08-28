# W.2.3 — a successful send is not a delivery

> **CORRECTED BY W.2.3.1 (2026-08-26). §0 line 1 below is wrong and is left in place so the
> correction has something to point at.** `retransmission closes it` is one layer too high.
> Tauri 2.11.5's JavaScript `Channel` carries a transport index of its own, stamped on every
> `Channel::send`, and delivers a message only when that index is the one it is waiting for —
> so a same-sequence retransmission arrives under a NEW index and is buffered behind the hole
> it was sent to fill. **Nothing sent on that channel can repair it.** Retransmission closes
> loss *above* the ordering layer; the lease and a *fresh* channel close loss below it. §3's
> falsifier is real but sits downstream of the mechanism it names. See
> `W_2_3_1_REVIEW_BRIEF.md`.

**Predecessor: `W.2.2`, ZIP `sha256:d0a2a1877423218846a235428630f77941e5c8ea1dfbaad948809b71dd6e3a96`,
content `sha256:bed61ce4a8efb493a3747ef363ede80d1f383b8e981c519ac3c2911ecc50de59`.**

> **Stream continuity only, as scoped.** No `ampd` change, no W.1 change, no ACL change, no
> queue change, no Cloud, no Motor. Every W.2 / W.2.1 / W.2.2 witness is preserved and still
> green. The `webviews:["main"]` grant, the child-webview witness and the split bounded lanes
> are untouched.

**Your upstream finding is the round.** I verified it against the pinned sources rather than
taking it, and it turns W.2.2 §6 from an unreproduced failure into a named mechanism with a
deterministic falsifier under it.

---

## 0 · Verdict

```
W.2.2 §6 wedge          CAUSE IDENTIFIED · wry#1644 · retransmission closes it
quiet world vs dead     CLOSED · heartbeat + lease; the page withdraws its own claim
>8192 Channel path      CLOSED · a real 22,663-byte frame, delivered and acknowledged
valve not diagnosable   CLOSED · the heartbeat carries which term is false
```

---

## 1 · The upstream cause, checked rather than accepted

You are right, and both halves reproduce here.

**The pin.** `cockpit/Cargo.lock` carries `wry 0.55.1`.

**The code.** `wry-0.55.1/src/webkitgtk/mod.rs`, `InnerWebView::eval`:

```rust
self.webview.run_javascript(js, cancellable, |result| {
  if let Some(callback) = callback {
    let result = result.map(|r| r.js_value().and_then(|js| js.to_json(0)))…;
    callback(result);
  }
});
Ok(())
```

With no callback the closure never touches `result`; the asynchronous WebKit outcome is
dropped and `eval` has already returned `Ok(())`. Tauri passes no callback for a Channel
message, and for a payload under `MAX_JSON_DIRECT_EXECUTE_THRESHOLD` (8192) `channel_on()`
delivers precisely through `webview.eval`.

**The report.** wry#1644, opened 23 December 2025, still open: while investigating **Tauri
`Channel` messages being lost and the channel hanging**, the cause was unsuccessful
`run_javascript` calls whose errors wry ignores.

So the chain is real end to end:

```text
Delivery::push → Channel::send → webview.eval → run_javascript
     Ok(())         Ok(())          Ok(())        …result dropped
```

and W.2.2's valve treated the first `Ok` as delivery.

**Your correction to my §6 is accepted.** I had put `sink` first. On this mechanism `eval`
returns `Ok`, so nothing drops the sink and nothing rejects on the page: the wedge state is

```text
sink      = Some(..)
holds     = empty
in_flight = Some(seq)      ← this one
```

which matches the observed failure exactly, including the reload recovering it and the
terminal-stall path never firing.

---

## 2 · What changed

### The whole packet is kept, and the answer to silence is the same frame

W.2.2 kept `Option<u64>` — enough to know a frame was outstanding, not enough to do anything
about it. Now:

```rust
struct InFlight { seq: u64, payload: Value, sent_at: Instant, attempts: u32 }
```

and `retransmit_due()` resends **the same sequence and the same bytes** after `RETRY_AFTER`.
Deliberately not a newer state: a retransmission that fabricates a later frame silently skips
a state the person was entitled to see, which is the same class of defect as rendering
optimism.

### The link speaks for itself

A heartbeat every `HEARTBEAT_EVERY` on the same Channel. **It is not a frame**: no projection,
no cursor, not counted by the page, and it never writes a `[data-source="frame"]` region — it
is a statement about the link, not about the world. It is sent whether the valve is open or
closed, because a closed valve is exactly when the difference between *quiet* and *dead*
matters.

### It carries the diagnosis, which is what W.2.2 could not do

```json
{"open": false, "sink": true,
 "in_flight": {"seq": 2, "age_ms": 720, "attempts": 1},
 "holds": [], "last_ack": {"seq": 1, "age_ms": 4982},
 "last_send_ok": true, "retransmits": 0}
```

Three terms close that valve and `bind` clears all three, so a reload recovers from any of them
and tells you nothing — which is why W.2.2 produced five downstream failures and no answer. The
heartbeat is the only thing that escapes a closed valve, so it is the right carrier.

One property of it, stated because it caught me while writing the large-frame gate: the page's
copy is **whatever the last heartbeat said**, so it lags by up to one interval. A gate that
samples it immediately after an intent reads a snapshot taken before the acknowledgement it is
asking about. The battery waits for a fresh one rather than sampling.

### The page may stop claiming

A lease. The host advertises `lease_ms` on every heartbeat; if the page hears **nothing at all**
— neither frame nor heartbeat — for longer than that, it withdraws: the badge changes, the world
region is cleared and says why, every `button[data-intent]` is disabled, and it rebinds. When
the link returns it restores without a reload.

> A timeout may say *I no longer know that this is being maintained*. It may never invent world
> state.

Nothing in `withdraw()` writes a grant and `render` is not called from it.

### A repeat is applied once and acknowledged every time

Retransmission makes duplicate arrival normal, so the renderer needed a rule:

```text
seq >  applied   render, then acknowledge
seq <= applied   DO NOT render, but acknowledge anyway
```

Not rendering matters because a repeat reflows the list under a person's cursor for no new
information. Acknowledging anyway matters because otherwise the host retransmits forever — and
it also closes the dual failure where the frame arrived and its *acknowledgement* was the thing
that was lost. The `<=` arm additionally stops a delayed message from a replaced channel walking
the world backwards after a recovery, which is the case you flagged.

---

## 3 · The falsifier, and why it is modelled in the page

You asked for the sabotage to make the host behave as though `send` returned `Ok(())` while
nothing reaches `onmessage`. I did it one step further out: **the page's own delivery entry
point drops exactly one frame.**

```js
window.cockpit.deliver = (m) => {
  if (m.schema === 'cockpit-heartbeat@1') return real(m);
  if (window.__swallow) { window.__swallow = 0; window.__ate = m.seq;
                          window.__ateJson = JSON.stringify(m); return; }
  if (m.seq === window.__ate) window.__again = JSON.stringify(m) === window.__ateJson;
  return real(m);
};
```

From the host's side that is indistinguishable from the upstream failure — the send succeeded,
the sequence is outstanding, no JavaScript ran — and it needs no branch in the host. It also
lets the witness be exact rather than approximate: the swallowed frame's **bytes** are kept, so
the check is that the *same sequence and the same payload* came back, not merely that something
did.

W.2.2's code wedges under it. The falsifier disables `retransmit_due` and requires **two** named
checks red, because a "recovery" that invented a newer state would satisfy the first alone.

`deliver` being a named function on `window.cockpit` is the only structural change this needed —
the same shape `render`, `ack`, `holdBegin` and `holdEnd` already had.

---

## 4 · Both transports, and the second one had never run

`tools/cockpit-bigframe.mjs` is a new gate. `SUPER_COCKPIT_BULK=n` has the fixture's agent ask
for `n` further grants through `request_grant` — ordinary commands, left pending, nothing
approved, no private route into the registry — so the projection is large because **the world
is large**, not because a payload was padded.

```
frame 22663 bytes · threshold 8192 · 40 pending requests
```

It asserts the frame is over the threshold (or the gate is measuring the same transport as the
flagship and proves nothing), that it is applied, that the DOM derives from it, and — the whole
question on this path — that it was **acknowledged**, witnessed by a second frame arriving.
On the fetch transport the page-side failure ends in `.catch(console.error)`, invisible to the
sender.

I did not put a ceiling on Super. `Ampd.Projection.operator/0` carries `authority_snapshot`,
`pending_approvals`, `effects`, `channels`, `peers`, `recent_refusals` (twenty) and four windowed
histories; it crosses 8192 on its own eventually, and now that day is measured rather than
discovered.

---

## 5 · Measured

Figures are in `site/proof/measurements.json` (`cockpit_assertions`, `big_frame`,
`cockpit_falsifiers`, `webview_acl`, `intent_surface`, `fixture_guard`). Every W.2.2 assertion
still holds; the new ones are:

```
  the link says it is alive on its own — the world does not have to move
  a heartbeat is not a frame — it is not counted and it does not move the world region
  and it carries the valve diagnosis — a closed valve can name the term that closed it
  a frame can be lost between a successful send and the renderer
  and it is sent again rather than wedging the stream forever
  the retransmission is the SAME sequence and the SAME bytes — not a newer state
  a frame already applied is not rendered again, and is acknowledged again
  and a frame older than one already applied never walks the world backwards
  the page withdraws LIVE LOCAL when it hears nothing for longer than its lease
  and it withdraws rather than inventing — no world region, and no authority to submit
  and the claim comes back when the link does, without a reload
```

New falsifiers, each disabling one fix and requiring **named** checks red:

```
an unacknowledged frame is sent again        → and it is sent again rather than
  ← THE W.2.2 WEDGE, RESTORED                  wedging the stream forever
                                             → the retransmission is the SAME sequence
the link speaks for itself when the world    → the link says it is alive on its own
  is quiet                                   → the page withdraws LIVE LOCAL …
a dead stream withdraws the claim rather     → the page withdraws LIVE LOCAL when it
  than looking quiet                           hears nothing
a repeated frame is applied once, not twice  → a frame already applied is not rendered
                                             → and a frame older than one already applied
a closed valve names the term that closed it → it carries the valve diagnosis
```

---

## 6 · What is still not true

- **The upstream defect is not fixed, it is survived.** wry#1644 is open. Nothing here depends
  on a fork: the stream tolerates a lost delivery whatever produced it — wry, WebKit, a future
  backend, or something not yet found. I did not build the diagnostic wry patch you suggested;
  it would tell us whether the *next* occurrence is that issue, and it is not load-bearing for
  the repair.
- **The W.2.2 §6 failure itself is still not reproduced.** What is reproduced is a failure of
  the same shape, deliberately induced. The identification is by mechanism and symptom match,
  not by catching the original in the act.
- **The lease is a page-side timer.** A page that is itself frozen cannot withdraw anything; a
  frozen renderer and a dead stream are still the same picture. Only the host's own liveness is
  covered here.
- **Retransmission is unbounded.** An outstanding frame retries indefinitely rather than
  escalating. The page's lease is what turns a permanently dead link into a withdrawn claim, so
  silence is bounded on the side that matters — but the host will keep trying forever, and
  `attempts` is visible rather than acted on.
- Carried forward and unchanged: the pane is a boundary witness and not a feature; the cockpit
  renders three lists; `REACQUIRE`/`RESNAPSHOT` are rendered but not exercised through the
  WebView; the fixture guard checks the extracted predicate; the archive is not
  byte-reproducible; `bundle.active` is `false`, so there is still nothing a person could
  download; the empty *Attached* row is still there.

---

## 7 · How to reproduce

```
cd super
cargo build --release --manifest-path host/Cargo.toml
cargo build --release --manifest-path cockpit/Cargo.toml
cargo install tauri-driver                 # once
node tools/check-webview-acl.mjs
node tools/check-intent-surface.mjs
bash tools/check-fixture-guard.sh
node tools/cockpit-battery.mjs             # the flagship — needs a display
node tools/cockpit-bigframe.mjs            # the >8192 transport
bash tools/sabotage-cockpit.sh             # long; most probes re-run the flagship
```

`WebKitWebDriver` comes with `webkit2gtk-4.1`. Both batteries start their own runtime in an
**ephemeral** world and destroy it; neither opens the world a person uses.
