# W.2.3.1 — a recovery tested one layer below the failure is not evidence

**Predecessor: `W.2.3`, ZIP `sha256:6dad087179686ac9b0038217530c33e5c9e58948170677f589b21de375fbf358`,
content `sha256:bf723f04be085ed71efe14e4b72011e31a3e08d7e7049d95600791a6d74994b7`.**

> **Evidence and transport boundary only, as you scoped it.** No `ampd` change, no W.1 change,
> no ACL grant change, no queue change, no Cloud, no Motor. Every W.2 / W.2.1 / W.2.2 / W.2.3
> witness is preserved and still green. `InFlight`, same-seq retransmission, duplicate ACK,
> stale-seq rejection, the heartbeat, the lease, the withdrawal, the rebind and the >8192
> witness are all kept.
>
> **One cosmetic change is in the diff and is accounted for here so it is not a surprise:** the
> window title and the page `<title>` said `[&] Super — cockpit`. The product is `Super (CD)` —
> that is what `release.json` carries and what the prototype's own wordmark reads. Both now say
> `Super (CD) — cockpit`. No behaviour, no gate.

**Your finding is correct, it reproduces here, and it was load-bearing.** It also turned out
to be load-bearing in a way neither of us had it: putting the falsifier at the right layer
found **three further defects**, one of which is W.2.2's own defect wearing a different hat.

**And the falsifier you proposed cannot run.** That is the first thing in this brief, because
had I taken it the round would have been designed around a seam that does not exist.

---

## 0 · Verdict

```
"retransmission closes wry#1644"      WITHDRAWN · it closes loss ABOVE the ordering
                                                  layer and cannot close loss below it
exact transport-index loss            REPRODUCED · at the callbacks map, one raw
                                                  callback below Channel.onmessage
retransmission cannot repair it       MEASURED · host kept sending, page heard none of it
fresh channel recovers from it        MEASURED · new channel id, LIVE LOCAL, no reload
abandoned callback cleaned up         WAS NOT · measured still registered; now retired
reacquisition survives a 2nd failure  WAS NOT · one rebind, ever; now a loop
```

---

## 1 · The seam you proposed is readonly — measured, not reasoned

Your falsifier opens:

```js
window.__TAURI_INTERNALS__.runCallback = (id, raw) => { … }
```

`tauri-2.11.5/scripts/core.js` installs that property with

```js
Object.defineProperty(window.__TAURI_INTERNALS__, 'runCallback', { value: runCallback })
```

and a descriptor that omits `writable` and `configurable` gets `false` for both. Asked of the
running cockpit through WebDriver:

```
Q1 · descriptor of window.__TAURI_INTERNALS__.runCallback
     {"value":"[function]","writable":false,"enumerable":false,"configurable":false}

Q2 · assigning to it from strict-mode code
     THREW: TypeError: Attempted to assign to readonly property.

Q2b · redefining it with Object.defineProperty
     THREW: TypeError: Attempting to change value of a readonly property.
```

`cockpit.js` is a module, so it is strict: that is an exception on line one, not a silent
no-op. The property cannot be deleted, shadowed on that object, or redefined.

**The same file hands over a better seam.** Three lines below:

```js
Object.defineProperty(window.__TAURI_INTERNALS__, 'callbacks', { value: callbacks })
```

— "just for the debugging purposes", says the comment. The *binding* is readonly; the `Map` is
not. And `runCallback(id, data)` is `callbacks.get(id)(data)`, so replacing one entry drops a
raw payload **before the Channel's own closure runs**, which is exactly the property you asked
for. It is also strictly better than intercepting `runCallback` globally: it is scoped to one
channel id and cannot eat an unrelated `invoke` reply.

```
Q3 · window.__TAURI_INTERNALS__.callbacks
     {"ctor":"Map","size":1,"descriptor_writable":false,"keys":[451163848]}

Q4 · raw payloads observed at that layer
     [{"id":451163848,"schema":"cockpit-heartbeat@1","index":1,"keys":["message","index"]},
      {"id":451163848,"schema":"cockpit-heartbeat@1","index":2,"keys":["message","index"]},
      {"id":451163848,"schema":"cockpit-heartbeat@1","index":3,"keys":["message","index"]}]
```

`{message, index}` — the shape `channel_on()` formats. The witness is at the transport.

---

## 2 · Your mechanism, checked in the pinned sources

Not taken. The bundle Tauri 2.11.5 injects is minified; this is `class c` from
`scripts/bundle.global.js` with the private-field helpers read back:

```js
this.id = transformCallback((e) => {
  const index = e.index;
  if ('end' in e) {
    if (index == this.#nextMessageIndex) return this.cleanupCallback();
    this.#messageEndIndex = index; return;
  }
  const message = e.message;
  if (index == this.#nextMessageIndex) {
    this.#onmessage(message);
    this.#nextMessageIndex += 1;
    while (this.#nextMessageIndex in this.#pendingMessages) { … }
    if (this.#nextMessageIndex === this.#messageEndIndex) this.cleanupCallback();
  } else {
    this.#pendingMessages[index] = message;          // ← forever
  }
})
```

and the Rust half, `src/ipc/channel.rs` `channel_on()`:

```rust
let current_index = counter.fetch_add(1, Ordering::Relaxed);
```

stamped on every send, direct-eval path and fetch path alike. So all three of your claims hold:

1. a lost index buffers everything after it, permanently;
2. **a retransmission arrives under a NEW index and is buffered behind the hole it was sent to
   fill** — nothing sent on that channel can repair it;
3. later heartbeats queue behind the same hole, which is what makes the lease fire rather than
   sit behind a link that looks alive.

**Your correction to your own first pass is right and I am adopting the corrected version.**
The problem was never "the heartbeat masks the broken frame". It is that W.2.3's witness sat
downstream of the ordering layer whose failure it claimed to reproduce.

---

## 3 · The claim W.2.3 made, withdrawn and replaced

W.2.3 §0 said:

```
W.2.2 §6 wedge          CAUSE IDENTIFIED · wry#1644 · retransmission closes it
```

The second clause is wrong. Replaced everywhere — brief, `worker.rs`, battery prose — by the
layered result, which is the one the code actually implements:

```text
loss ABOVE the Channel's ordering              same-seq retransmission
  (a renderer that throws, a delivery
   entry point that drops)

loss BELOW it — a transport index that         the lease withdraws the claim,
  never existed (wry#1644)                     a FRESH channel establishes a new
                                               stream with its own ordering state
```

`RETRY_LIMIT = 3` makes the ladder mechanical rather than rhetorical: three attempts inside one
6 s lease, then the host stops and says `"exhausted": true` in the heartbeat. Retrying past that
is not merely futile — see §6.

---

## 4 · The witness, and what it measured

`tools/cockpit-battery.mjs` gaps **two** channels at the callbacks-map layer, taking the first
raw payload on each — a `run_javascript` that fails does not care what the payload was, and
neither does the ordering layer.

```text
channel A · first raw callback dropped, at transport index N
   host sends again (new index N+1)   →  buffered behind the hole
   host beats       (new index N+2)   →  buffered behind the hole
   page hears NOTHING                 →  frames and beats frozen at the values
                                         sampled inside the drop handler
   lease expires                      →  withdraw: world region cleared, every
                                         button[data-intent] disabled
   rebind → channel B                 →  and channel A is retired
channel B · first raw callback dropped
   page is still withdrawn, so nothing can clear the flag
   reacquire fires again              →  rebind → channel C
channel C · clean
   LIVE LOCAL, world region rebuilt, authority submittable
   NOTHING WAS UN-SABOTAGED
```

**It took the first payload of any kind because an earlier draft did not, and that is worth
recording.** The draft waited for a `cockpit-frame@1` on channel A so the witness could say a
state a person was entitled to see had been lost. It measured nothing for twenty-five seconds:
that late in a battery run the intent it fired did not move the projection cursor, `differs()`
was false, no frame was produced — and four downstream checks went red **for want of a fault
rather than for want of a fix**. A witness that needs the world to move cannot be run against a
quiet one, which is the case this whole round is about.

Two more the same run cost, both mine and both the same shape — *an assertion that is true of
a page nothing happened to*:

- `!withdrawn && state === 'live-local'` went green while the gap it was reporting on had
  never fired. It now also requires `applied >` the value sampled **inside the drop handler**
  and `channel_id !==` the wedged one — a statement only recovery can satisfy.
- `#world .row > 0` is a claim about the **world's contents**; by that point the flagship and
  four witnesses have revoked everything, so a correct recovery onto an empty world failed it.
  `render()` writes its three section headings whatever the lists hold and the withdrawal
  writes none, so `#world h2 === 3` is the frame-derived difference.

The two that carry the round:

```
and NONE of it reaches the page — a retransmission cannot fill a hole in the transport
and a FRESH channel restores LIVE LOCAL — with nothing un-sabotaged and no reload
```

**Your item 3 — "prove the lease withdraws the stale World" — is asserted here as well as
above, and deliberately.** The withdrawal already had a witness and a falsifier, but both ran
against a `deliver`-level sabotage. That is the exact shape of the thing you caught: *a
property asserted under a different fault is not evidence for this one.* So it is asserted
again against a gap in the transport, where the page's only signal is that it has heard
nothing — no rows, no headings, no submittable control, badge on `reacquire`, all sampled in
one call so the check cannot straddle the recovery.

The second is the one W.2.3 could not make. Its lease witness recovered by **restoring the
sabotaged function** — that is, by removing the fault, which under the real mechanism is not
available to anybody. Recovery there was asserted of the harness, not of the product.

**A distinction that fell out of this and is worth putting to you.** The frame that comes back
on channel C is *not* the frame that was lost; it is the present state under a later sequence,
because `Delivery::bind` clears `sent`. That is not the defect the same-seq rule exists to
prevent. Those two rules govern different situations and the round now states so:

> A retransmission repairs an outstanding frame on a live channel, and must be the same
> sequence and the same bytes — inventing a newer state there silently skips one a person was
> entitled to see. A **reacquisition** follows an admitted gap in knowledge that the page has
> already told the person about, and must show what the world **is** — replaying a superseded
> state there would be presenting the past as the present.

Asserted: `applied >` the value sampled at the gap, and — when the payload that was dropped
carried one — `applied >` its sequence too.

---

## 5 · Three defects the right layer found

### 5.1 · One rebind is not a recovery

```js
function withdraw() {
  if (c.withdrawn) return;      // ← and only `deliver` ever cleared it
  …
  c.rebinds += 1; bind();
}
```

**Exactly one rebind was ever attempted per episode.** If the channel that rebind produced was
also dead, the page sat on *stream lost* forever, having tried once. That is W.2.2's defect one
layer further out — a recovery path whose own failure is permanent silence — and it is not
hypothetical here: nothing about a failed WebKit `run_javascript` says the next call succeeds.

W.2.3 masked it by accident. `restore()` was called from the heartbeat arm, so a heartbeat on
the new channel re-armed the one-shot. Under the *exact* failure no heartbeat arrives, because
heartbeats queue behind the hole — so the mask is removed by the same mechanism that makes the
bug matter.

Fixed: `reacquire()` on its own timer (`REACQUIRE_EVERY = 3000`), driven from `leaseTick` for
as long as the page is withdrawn. The lease decides when to **stop claiming**; this decides how
often to **try again while not claiming**. W.2.3 had them as one flag.

### 5.2 · A heartbeat may not end a withdrawal

`restore()` used to be called from the heartbeat arm — evidence about the **link** clearing a
claim about the **world**. Hearing a heartbeat ends the *silence* (`heard_at` moves, so the
lease will not fire); only a frame can end the *withdrawal*, because only a frame refills the
region the withdrawal cleared.

**Guarded statically, and that is a limitation I am stating rather than dressing up.** On the
shipped host a fresh channel's first message is always a frame — `run()` delivers before it
beats — so there is no window in which a heartbeat reaches a withdrawn page first, and a
battery witness for it would be asserting another process's emit order. Which is the reason to
make the rule hold by construction instead. `check-webview-acl.mjs` now requires `restore` to
have exactly one call site and the heartbeat arm not to contain it; `sabotage-cockpit.sh` probe
21 puts it back and that check goes red.

### 5.3 · The abandoned callback — you were right, and it is measured

A `Channel` unregisters itself when `#nextMessageIndex` reaches the `end` index its Rust side
evals on drop. **A permanent hole is exactly the state that guarantees the count never gets
there.** Measured on the running app before the fix:

```
Q6 · is the wedged channel id still in the callbacks map?
     {"wedged_id":451163848,"still_registered":true,"map_size":2,
      "unregister_is_fn":true}
```

It is worse than a stale map entry: `#pendingMessages` holds every buffered payload, and each
of those is a whole operator projection. Every recovery would add another.

Taking your first option, and it is not a hack: **the page performs `cleanupCallback()`'s own
body — `unregisterCallback(this.id)` — in the one case its caller can never run.** Not the
webview reload; a reload resets the receipt rail, which is a person's record of what they
submitted, and the whole point of the lease is that it needs no reload.

It is a real dependency on a Tauri internal, so it is **declared** rather than discovered:
`check-webview-acl.mjs` fails the build if `cockpit.js` reaches for any internal other than
`unregisterCallback`, and refuses `runCallback` by name so nobody rediscovers §1 the hard way.
Feature-detected — a Tauri without it leaves the old callback registered, which is where W.2.3
already was.

---

## 6 · Your large-frame point, made mechanical

`fetch_channel_data` removes the cached body **when the fetch runs**:

```rust
if let Some(data) = cache.0.lock().unwrap().remove(&id) { Ok(Response::new(data)) }
```

so a send above 8192 bytes whose script never executed leaves a whole projection in
`ChannelDataIpcQueue` — upstream state this process cannot reach. Unbounded retransmission into
a gap that retransmission provably cannot repair is therefore a leak with no ceiling, and
W.2.3 §6 listed "retransmission is unbounded" as a cosmetic limitation. It is not cosmetic.

`RETRY_LIMIT = 3` bounds it to one lease's worth. It is not a fix for the upstream cache — the
entries from those three attempts are still lost — and this brief does not claim otherwise.

---

## 7 · Measured

Figures in `site/proof/measurements.json` — `cockpit_assertions`, `cockpit_falsifiers`,
`webview_acl`, `big_frame`, `intent_surface`, `fixture_guard`. **Not repeated here, and I tried
to.** I typed the three tallies into this section from my own terminal, and
`check-measurement-prose.mjs` would have refused the release for it: its patterns are derived
from the receipt, not from a list, so any prose that recreates a measured figure is a number
that can drift away from the artifact it claims to describe. The new assertions, named rather
than counted — the list is the count:

```
  the page names the transport it is bound to, so a witness can reach under it
  a raw Channel callback can be lost below the ordering layer, carrying its transport index
  the host goes on sending on that channel — this is loss, not a quiet world
  and NONE of it reaches the page — a retransmission cannot fill a hole in the transport
  reacquisition keeps trying — a second dead channel does not end the recovery
  and a FRESH channel restores LIVE LOCAL — with nothing un-sabotaged and no reload
  on a channel this page had not been bound to when the gap was made
  the recovered frame is the PRESENT, not a replay of the state that was lost
  the lease withdraws the stale world under a transport gap, not just an application one
  the world region is rebuilt from that frame, and authority is submittable again
  the wedged channel is retired rather than left registered with its buffered frames
  the page reaches for exactly one Tauri internal, and it is the declared one
  `runCallback` is not reached for — it is readonly and assigning to it throws
  a withdrawal is ended by a frame and by nothing else — `restore` has one call site
  and whether the host is still trying — a bounded retry that does not say so is silence
```

New falsifiers, each disabling one fix and requiring **named** checks red:

```
one rebind is not a recovery                 → reacquisition keeps trying
  ← W.2.3's withdraw(), restored             → and a FRESH channel restores LIVE LOCAL
                                             → the world region is rebuilt from that frame
only a frame may end a withdrawal            → a withdrawal is ended by a frame and by
                                               nothing else  (static)
the channel a rebind replaces is retired     → the wedged channel is retired rather than
                                               left registered
a witness that cannot name the transport     → the page names the transport it is bound to
  cannot model the failure
a bounded retry says it is bounded           → whether the host is still trying
```

The withdrawal under a transport gap did **not** get a probe of its own. Removing the lease is
one line either way, so `a dead stream withdraws the claim rather than looking quiet` — which
already existed — now requires **both** names red: the application-level one and the transport
one. Two probes running the identical sabotage to grep two different lines would have been the
same six-minute battery twice, which is what this harness's `%%` exists to prevent, and I wrote
the duplicate before I remembered that.

---

## 8 · What is still not true

- **The upstream defect is still not fixed, it is survived.** Checked this round against the
  **code**, not the issue tracker, because an issue's state is a fact about a repository and
  the defect is a fact about a function. `wry 0.56.1` — the latest published crate, 13 August
  2026, one minor ahead of the pinned 0.55.1 — still reads:

  ```rust
  self.webview.run_javascript(js, cancellable, |result| {
    if let Some(callback) = callback { … callback(result); }
  });
  ```

  With no callback nothing touches `result`, and `eval` has already returned `Ok(())`. So the
  mechanism is present in the version this would upgrade to, and none of the repair here
  depends on a fork, a patch, or the issue being triaged. (wry#1644 is also still open with no
  linked PR, fetched directly — a keyword search does not surface that issue number, which is
  why the code is the check and the issue is the footnote.)
- **The W.2.2 §6 original is still not reproduced.** What is reproduced is a failure of the
  same shape at the same layer, deliberately induced.
- **The `ChannelDataIpcQueue` entries from lost large sends are not reclaimed.** Bounded to
  three per episode; not zero. Nothing page-side can reach that map.
- **The abandoned Channel's `#pendingMessages` is released by garbage collection**, once the
  callback is unregistered and this page drops its reference. Not measured — the battery
  asserts the registration is gone, which is the part that is observable.
- **The lease is still a page-side timer.** A frozen renderer and a dead stream remain the same
  picture.
- **§5.2 is guarded statically, not dynamically.** Stated in place.
- **`REACQUIRE_EVERY` is a judgement, not a measurement.** A withdrawn page abandons the
  channel it just bound after 3 s and binds another. It only reaches that state after a full
  6 s lease of total silence, and the host's loop turn is 80 ms, so a channel that has said
  nothing for nine seconds is dead by any reading — but a *transient* stall longer than 3 s
  would be killed rather than waited out, and nothing here measures how long a real one lasts.
- **Nothing bounds how many channels a permanently broken link burns through.** Each
  reacquisition allocates a callback id and retires the last. That is the correct behaviour
  for a link that recovers; for one that never does, it is an unbounded loop this round does
  not escalate out of. The page says *stream lost* throughout, so nothing is claimed — but
  there is no *give up and say so terminally* state, and `ack`'s terminal path is not it.
- Carried forward unchanged: the pane is a boundary witness and not a feature; three lists;
  `REACQUIRE`/`RESNAPSHOT` rendered but not exercised; the fixture guard checks the extracted
  predicate; the archive is not byte-reproducible; `bundle.active` is `false`; the empty
  *Attached* row.

---

## 9 · How to reproduce

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

The internals probe of §1 is reproducible standalone: ask the running cockpit for
`Object.getOwnPropertyDescriptor(window.__TAURI_INTERNALS__, 'runCallback')`.

**Process note taken:** W.2.3's ZIP went without its sibling `*.receipt.json`. This one ships
both.
