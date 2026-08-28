# W.2.3.2 — a recovery procedure must itself have a bounded failure mode

**Predecessor: `W.2.3.1`, ZIP `sha256:2392e6b2ccfecd0b5afa596e310bf10059e34b529280fb812b3067b03f462b48`,
content `sha256:bc46c6fcb11b367b63225c14db2ef76ae1c72e3a215e27d61257c3b8fd25f1d7`.**

> **One property, as you scoped it.** No `ampd` change, no W.1 change, no projection semantics,
> no Cloud, no Motor. Every W.2 / W.2.1 / W.2.2 / W.2.3 / W.2.3.1 witness is preserved and still
> green — the callback-map transport-gap witness, same-seq retransmission, lease withdrawal,
> fresh-channel reacquisition, repeated recovery, callback retirement, the heartbeat/frame
> distinction, `RETRY_LIMIT` and the >8192 witness are all kept.

**Both findings are real and both reproduce.** The second is worse in the code than in your
description, and it is mine: I introduced it in W.2.3.1 and then wrote down the wrong half of it
in that brief's §8.

**One addition beyond the page.** Making UNAVAILABLE *stop spending* rather than *stop
listening* needs the host to stop writing, and nothing in the command surface could say that. So
there is one new Tauri command, `unbind_frame_stream` — the symmetric partner of
`bind_frame_stream`, on the same control lane, through the same ACL. It is called out here
because it is the only surface change in the round.

---

## 0 · Verdict

```
local retry bound is not a bound     CONFIRMED · RETRY_LIMIT bounds sends per channel;
                                                 unbounded channel creation re-mints it
candidate deadline asymmetry         CONFIRMED · and worse than described — see §2
terminal UNAVAILABLE state           ADDED · claims nothing, spends nothing, needs a person
host stops writing, not just page    ADDED · unbind_frame_stream
`retired` bounded                    DONE · ring of 4 + a total
```

---

## 1 · The unbounded recovery, confirmed

`RETRY_LIMIT = 3` bounds how many times **one** channel is written to. `reacquire()` then built
another channel, and another, with nothing but a 3 s throttle between them. So the shape was
exactly as you drew it: finitely many sends on an unbounded number of channels.

I had written this in W.2.3.1 §8 — *"Nothing bounds how many channels a permanently broken link
burns through … there is no give up and say so terminally state"* — and shipped it as a stated
limitation rather than a defect. Your framing is the one that makes it a defect:

> **Local retry bounds do not constitute a bound if recovery can recreate the retry budget
> indefinitely.**

And your resource argument is the part I had underweighted. `ChannelDataIpcQueue` is inserted
into **before** the JavaScript that fetches it is evaluated, and removed **only** by that fetch
running. A send whose script never runs therefore parks a whole serialised projection in
Rust-side state, and `unregisterCallback` — the page's entire retirement discipline — cannot
reach it. Page-side cleanliness could never have bounded this.

---

## 2 · The candidate deadline — and it is worse in the code than in your report

You described it as an asymmetry: 6 s lease for an established channel, 3 s for a candidate.
The code was blunter than that. `leaseTick` took the withdrawn branch **before** the deadline
test:

```js
if (c.withdrawn) return reacquire();          // ← candidates never reached the line below
if (!c.bound || !c.heard_at || !c.lease_ms) return;
if (Date.now() - c.heard_at > c.lease_ms) withdraw();
```

So a candidate was not held to a *shorter* lease. **It was not held to a lease at all** — it was
displaced on a fixed 3 s timer regardless of what it had or had not said. A candidate that
delivered its first frame at 2.9 s survived by luck of scheduling, not by having satisfied
anything.

There is now one deadline in the file, and which branch is taken says only whether the page was
still claiming when the silence began — never how long the silence had to be:

```js
if (c.unavailable) return;
if (!c.bound || !c.heard_at || !c.lease_ms) return;
if (Date.now() - c.heard_at <= c.lease_ms) return;
if (!c.withdrawn) return withdraw();
return nextCandidate();
```

`heard_at` is set when a candidate is **attempted**, not when its `bind` resolves — otherwise a
slow `bind` is charged to the channel it produced.

> **A recovery mechanism may not assume a stricter timing guarantee than the mechanism whose
> failure it is recovering from.**

---

## 3 · Bounded reacquisition

```text
LIVE
 │  lease expires
 ▼
WITHDRAWN ──► candidate 1 ──► candidate 2 ──► candidate 3
 │              (each gets a FULL lease, not a shorter one)
 │              (a frame ends the episode and returns the budget)
 ▼
UNAVAILABLE
   world absent · authority disabled · last channel retired
   host told to stop · no channel created · a person may Retry
```

`CANDIDATE_LIMIT = 3` is **policy and is named as policy**, per your note — there is no
measurement behind three, it is the number of independent chances a link gets before the page
stops spending on it. It sits beside `RETIRED_KEPT` as a constant somebody changes on purpose,
not as an inferred invariant.

**UNAVAILABLE stops spending, which is not the same as stopping listening.** Retiring the
callback stops this page reading; the host would go on beating into a webview that had stopped
consuming, and — if the valve ever reopened — sending frames whose scripts never run. So the
page calls `unbind_frame_stream`, and `Delivery::unbind` drops the sink and clears `in_flight`,
`holds`, `sent`, `held`. Clearing `in_flight` matters as much as dropping the sink: a retained
one would leave the next `bind` inheriting an outstanding frame addressed to a page that no
longer exists, which is W.2.1's first-frame wedge arriving by a new route.

The **Retry** control carries no `data-intent`. It asks this page to try again and submits
nothing to the runtime, so it reaches no authority and the disabled-controls assertions — which
are about `button[data-intent]` — are untouched by it.

---

## 4 · The witnesses

**Every candidate fails, permanently.** Not two channels: a blackhole over *every* raw callback
on *every* channel, installed by a poller that follows `window.cockpit.channel_id`, so no
channel the page can create ever delivers anything.

```text
LIVE ─► lease ─► withdraw ─► candidate 1 ✗ ─► candidate 2 ✗ ─► candidate 3 ✗ ─► UNAVAILABLE
                                                                                    │
                                            then twenty seconds of doing nothing ───┤
                                                                                    ▼
                             rebinds unchanged · channels allocated unchanged ·
                             raw callbacks arriving unchanged · world absent ·
                             authority disabled · channel_id null
```

The twenty-second idle measurement is the round. Reaching UNAVAILABLE proves the state exists;
only the idle window proves it is a **bound** rather than a slower loop. Three separate counters
must all be flat: `rebinds` (the page stopped binding), the number of distinct channel ids the
blackhole has wrapped (the page stopped allocating), and the count of raw callbacks arriving
(**the host stopped writing**). The third is the one `unbind_frame_stream` exists for, and
without it the other two go flat while the cost simply moves upstream.

**The third counter needed re-installing, because the code under test removes it.** The
blackhole counts by owning the entry in `__TAURI_INTERNALS__.callbacks` — and reaching
UNAVAILABLE *retires* that entry, which deletes the counter. So the host could go on sending
forever and the count would sit still, because `runCallback` finds nothing and only warns. The
first version of this check therefore **passed with the fix disabled**: `sabotage-cockpit.sh`
reported NOT A FALSIFIER and refused the release, which is the harness doing exactly what it is
for. The harness now re-registers a bare counter under every id the page has abandoned —
nothing the page reads, an instrument aimed at the *producer*. Measured both ways before this
brief was written: with the unbind, nothing lands; without it, **thirteen payloads over twenty
seconds**, which is one every 1.5 s — the heartbeat interval, beating into a webview that had
stopped listening.

> A measurement whose instrument is dismantled by the mechanism it measures reports silence and
> calls it success.

**And then it counted the fix working as the fix failing.** With the instrument restored, one
payload still arrived — `Delivery::unbind` drops the Rust `Channel`, whose `on_drop` evals
`{end: true, index: N}`. That is Tauri announcing the unbind *succeeded*, and demanding zero
payloads made the chain refuse a correct fix over it. Excluded **by shape** rather than by a
tolerance: "one or fewer" would have swallowed a real send just as happily. The check now
reports what it saw, so the two cases are legible rather than numeric —

```
with the unbind      0 payloads                            · end notices excluded
without it          13 payloads ["message,index", …]       · 0 end notices
```

thirteen over twenty seconds being one every 1.5 s, the heartbeat interval exactly.

> **Verify a witness in both directions before spending a chain on it.** Three separate defects
> in this one check — an instrument the code removes, a success counted as a failure, and the
> earlier round-trip race — each cost a full release run to discover, and each would have cost
> two minutes to find by running the sabotage by hand first.

### Two W.2 probes were naming a check they could lose

Not W.2.3.2's doing, but this round's chain is where it surfaced. **`the host honours a holding
renderer`** and **`a submission takes its hold before it is sent`** both expected `no frame has
been delivered` — asserted the instant the receipt appears. With the hold disabled the frame
does arrive, but the worker replies to the intent and *then* takes its next 80 ms turn, while
this battery polls for the receipt every 250 ms. Roughly one run in three observes the receipt
inside that window, the check passes, and the probe refuses a release over a fix that is
working. Measured rather than reasoned: the same sabotage run by hand turned all three checks
red a minute after the chain had it green.

Both now name **`it is a state and not a race: 1.5 s later …`**, which asserts the same two
facts — row still present, no frame arrived — eighteen worker turns after the reply. It cannot
be won by luck in either direction, and it is the check whose *name* is the claim those two
fixes exist to make true.

> A falsifier for a fix that removes a race must not itself be decided by one.

**A slow but healthy candidate is retained.** Modelled by *delaying* rather than dropping: the
first raw callback on the candidate is held back four seconds and everything after it passes
straight through, which is what a slow transport actually does — the Channel buffers the later
indices behind the held one and drains them when it lands. Four seconds is past W.2.3.1's 3 s
and inside the 6 s lease, so the two behaviours are distinguishable by construction rather than
by timing luck. The assertion is that LIVE LOCAL comes back **on that candidate** — not on its
successor, which is what "give up sooner" would produce and what a weaker check would accept.

**A deliberate retry begins a new episode.** The blackhole is lifted, the button is clicked, and
the world comes back with `episodes === 1`. The click is guarded: a sabotage that stops
UNAVAILABLE from being reached leaves no button, and an unguarded `.click()` would throw out of
the run — killing the harness instead of failing the check that names the defect. That is the
`waitSoft` lesson in a different costume, and it cost a run to remember.

**The ring is asserted non-vacuously.** `retired.length <= 4` alone would pass against an
unbounded array on any run that happened not to exceed four, so the check also requires
`retired_total > retired.length` — the ring must have actually discarded something. Where it has
not, the failure text says the check proved nothing rather than reporting a pass.

---

## 5 · Measured

Figures in `site/proof/measurements.json` — `cockpit_assertions`, `cockpit_falsifiers`,
`webview_acl`, `big_frame`, `intent_surface`, `fixture_guard`. Not repeated here;
`check-measurement-prose.mjs` derives its patterns from the receipt and refuses prose that
recreates a measured figure, and in the last round the tally I typed into this section was
already wrong by one when I typed it.

New assertions:

```
  a slow but healthy candidate is not killed by the recovery that is trying to use it
  a permanently broken transport reaches a terminal state instead of retrying forever
  and the terminal state claims nothing — no world, no submittable authority
  and it stops SPENDING — no further channel is allocated and none is bound
  and the HOST stops sending — unbinding is what ends the cost, not unregistering
  and the diagnostic collection is bounded too, in a round about bounded recovery
  a deliberate retry begins a new bounded episode and the world comes back
```

New falsifiers, each disabling one fix and requiring **named** checks red:

```
a recovery that can re-mint its own budget   → reaches a terminal state instead of
  is not bounded                               retrying forever
                                             → and it stops SPENDING
                                             → a deliberate retry begins a new episode
a candidate is judged by the same deadline   → a slow but healthy candidate is not killed
  as the stream it replaces                    by the recovery
the terminal state tells the host to stop,   → and the HOST stops sending
  not just itself
the retirement log is bounded too            → the diagnostic collection is bounded too
```

`check-webview-acl.mjs` cross-checks six commands now rather than five: registered in
`generate_handler!`, declared in `AppManifest::commands`, granted in the capability. A command
registered but not declared fails **open**, which was W.2's original defect.

---

## 6 · The ladder, as it now stands

```text
a message is missing                 retransmit it — same sequence, same bytes
the channel's ordering is unknowable withdraw the claim, reacquire on a fresh channel
reacquisition itself fails           try again, under a budget, each candidate judged
                                       by the same deadline as the stream it replaces
the budget is spent                  stop claiming, stop spending, say so, and wait
                                       for a person
```

Your formulation of the last rung is the one I would keep:

> A recovery procedure must itself have a bounded failure mode.

---

## 7 · What is still not true

- **The `ChannelDataIpcQueue` entries already parked are not reclaimed.** Bounded now — at most
  `RETRY_LIMIT × CANDIDATE_LIMIT` sends per episode, and no further sends at all once
  UNAVAILABLE is reached — but not zero, and nothing page-side can reach that map. A second
  episode started by a person spends another such budget, deliberately.
- **`CANDIDATE_LIMIT = 3` is policy with no measurement behind it**, and is labelled as such
  rather than presented as an invariant.
- **UNAVAILABLE is reached by silence, never by a positive signal of transport death.** There is
  no such signal to reach for: that is the whole of wry#1644. A candidate is spent when it says
  nothing for a full lease, which cannot distinguish a dead transport from a runtime that has
  stopped producing.
- **The lease is still a page-side timer.** A frozen renderer and a dead stream remain the same
  picture; a page that cannot run cannot withdraw, count candidates, or reach UNAVAILABLE.
- **`unbind_frame_stream` is best-effort.** It is an `invoke` over the same IPC whose failure
  mode this round is about. Its rejection is swallowed — if it never arrives the host keeps a
  sink for a page that has stopped consuming, which is W.2.3.1's position. Nothing asserts what
  happens then.
- **W.2.2 §6's original failure is still not reproduced**, only failures of the same shape at
  the same layer, deliberately induced.
- Carried forward unchanged: the pane is a boundary witness and not a feature; the cockpit
  renders three lists; `REACQUIRE`/`RESNAPSHOT` are rendered but not exercised; the fixture
  guard checks the extracted predicate; the archive is not byte-reproducible; `bundle.active` is
  `false`; the empty *Attached* row.

---

## 8 · How to reproduce

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
