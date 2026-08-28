# W.2.2 — the boundary Super will actually have

**Predecessor: `W.2.1`, ZIP `sha256:db6c195413636b258300e12757d0533573013a3a9ba83beb97bb6b249576465c`,
content `sha256:2427772270260c3899bef4e7398ebe71be5b044024f064d6536fe6f7126ce566`.**

> **Two closures only, as scoped.** No `ampd` change, no W.1 change, no Cloud work, no Motor.
> Every W.2 and W.2.1 witness is preserved and still green — and now measured at queue depth 1,
> which is strictly stronger than measuring them at 64. The Channel, the `AppManifest` ACL
> declaration and the keyed holds are untouched.

Both findings are real. **Finding 1 is worse than "not established"** — I reproduced the
class rather than reasoning about it, and the pane was allowed. Finding 2 is exactly as
described and the general law you drew out of it is the part worth keeping.

---

## 0 · Verdict on each

```
1  same-window webview authority        FIXED · webviews:["main"], no windows key,
                                                witness is a real child webview
2  ACK / release lost to a full queue   FIXED · two bounded lanes, both blocking,
                                                control drained first

3  (NEW, MINE, OPEN) the flagship wedged once, in the release chain, and I
   cannot reproduce it.  §6.  DO NOT FREEZE LIVE LOCAL OVER IT.
```

**Read §6 before anything else in this document.** Findings 1 and 2 are closed and their
witnesses are real. But this round also produced the first *intermittent* failure this arc has
seen, and a green battery beside a known flake is precisely the "timing evidence, not a
property" shape W.2.1 was re-cut to remove. I am not going to bury it in a *still not true*
list.

---

## 1 · Finding 1 — I checked the resolver, not the documentation

You quoted the capability reference. I went to the code the reference describes, because
"prefer `webviews`" is advice and I wanted the rule.

`tauri-2.11.5`, `src/ipc/authority.rs`, `resolve_access`:

```rust
origin.matches(&cmd.context)
  && (cmd.webviews.iter().any(|w| w.matches(webview))
    || cmd.windows.iter().any(|w| w.matches(window)))     // ← an OR
```

called from `src/webview/mod.rs:1458` with

```rust
.resolve_access(&cmd_name, self.window().label(), self.label(), &origin)
```

So under `windows: ["main"]` the *window* label satisfies it and the webview's own label is
never consulted. The complementary half is in `tauri-utils-2.9.3`, `src/acl/resolved.rs`:
`parse_glob_patterns` maps an absent list to an empty `Vec<glob::Pattern>`, so `.any()` is
`false` — which is what makes `webviews: ["main"]` **with no `windows` key** a real denial
rather than a preference.

The trusted webview's label is `main` as well — a window and the webview inside it are given
the same label, which is why `webviews: ["main"]` still grants the cockpit. I did not want to
take that from the builder source, since the product's main window comes from
`tauri.conf.json` rather than from a `WebviewWindowBuilder` call, so it is read out of the
running application in the assertions below. The substitution is one word in each direction.

### The pane was allowed. Measured, and it is worse than "not established".

`tools/sabotage-cockpit.sh` gained a probe that puts `windows: ["main"]` back, rebuilds, and
runs the flagship battery. It goes red at exactly the check you would want it to:

```
falsified   a window-scoped grant reaches every webview inside that window
            → an unprivileged webview may not invoke intent at all
```

**And the failure detail is the finding, not a proxy for it.** I ran that configuration by
hand to see what the pane actually got back, because "the check went red" is consistent with
a different error and I did not want to infer. The untrusted pane invoked
`intent{name: "revoke_grant", grant_id: "gr_0193"}` and the ACL did not appear:

```json
{"ok": true, "v": {"allow": false, "reason": "No such active grant.",
                   "refusal": {"code": "grant-unknown",
                               "component": "Ampd.GrantRegistry",
                               "operator_detail": {"grant_id": "gr_0193"},
                               "requires_human": true, "schema": "refusal@1"}}}
```

`ok: true`. The call **reached `ampd`**. What refused it was the grant registry, saying that
*this particular id* is not an active grant — a judgement about the argument, not about the
caller. Given a real id it would have revoked a real grant, and the pane's other invoke tells
you where it would have got one:

```json
{"ok": true}     ← bind_frame_stream, from the untrusted pane
```

It became a second reader of the authoritative world. So under W.2.1 an untrusted pane drawn
inside the cockpit's window could subscribe to the frame stream, read a live `grant_id` out of
it, and revoke it. The only thing standing between W.2.1 and that was that no such pane had
been written yet — which is exactly the position you flagged: get it right once, early,
rather than retrofit after the shell becomes interesting.

### The witness is now the topology Super is heading for

`SUPER_COCKPIT_PANE=1` no longer opens a second `WebviewWindow`. It opens a child webview of
the trusted window through `Window::add_child` + `WebviewBuilder` — the primitive a browser
pane, a Motor surface or a game pane will be built with:

```rust
let main = app.get_window("main").ok_or("no main window to host the pane")?;
main.add_child(
    tauri::webview::WebviewBuilder::new("pane", tauri::WebviewUrl::App("pane.html".into())),
    tauri::LogicalPosition::new(0., 600.),
    tauri::LogicalSize::new(520., 200.),
)?;
```

**And the battery asserts the topology instead of assuming it**, because a witness that
quietly reverted to two windows would go on printing the same green line. Both webviews are
now identified by the labels Tauri injects — `__TAURI_INTERNALS__.metadata` — which are the
labels the ACL is resolved against, not by `typeof window.cockpit`, which is a fact about our
own JavaScript:

```
window=main  webview=pane   /pane.html   invoke: function
window=main  webview=main   /            invoke: function
```

```
held   the untrusted pane is a child webview of the TRUSTED window, not a second window
held   and it is a distinct webview — told apart by the label the ACL resolves against
held   the untrusted pane holds a working Tauri bridge — the refusal is not a missing API
held   an unprivileged webview may not invoke intent at all — Tauri refuses it, not our JS
held   and it may not bind the frame stream either
```

`tools/check-webview-acl.mjs` now **refuses the word `windows` outright** rather than
requiring `webviews`, so the one-word substitution cannot come back through a file whose
prose would go on describing a boundary that had stopped existing. It has its own falsifier
and it is the cheap gate: it runs before anything is built.

### One cost, named

`Window::add_child` and `WebviewBuilder` are behind tauri's `unstable` feature, so
`cockpit/Cargo.toml` turns it on. That is the only reason it is on and the reason is written
beside it. It is a real cost: `unstable` may break in a minor release. I took it because the
alternative is proving the boundary against a topology this product will not have, which is
the failure this round exists to correct.

---

## 2 · Finding 2 — and your law is the part I kept

Correct in every particular, including the detail that makes it silent: `cockpit.js` calls

```js
window.cockpit.ack(frame.seq);
```

with no `await` and no `catch`, so the rejection had nowhere to be seen even when it happened.

The law, as adopted, is in `worker.rs` and in the README:

> **New work may be refused BUSY. A message whose absence can leave a gate permanently closed
> may not use lossy delivery — it must enqueue, or move the system to a state that says so.**

### The shape

```
intents      bounded · blocking            a wedged runtime must not become a memory leak
  Intent

control      bounded · blocking ·          every one of these RELEASES something the
  Bind       DRAINED FIRST                 valve is waiting on
  Ack
  HoldBegin
  HoldEnd
```

Both lanes stay bounded — I agree with you and with my own earlier argument that an
indefinitely wedged runtime must not accept unbounded queued mutations. What changed is that
nothing is discarded. **`try_send` no longer appears anywhere in the program**, and
`check-webview-acl.mjs` refuses it by name, because the two methods differ by four characters
and this class returns by picking the wrong one.

Every command that touches the valve is `async` and does its blocking send inside
`spawn_blocking`. Two different repairs in one line: *blocking* is what stops a release being
dropped, *`spawn_blocking`* is what stops the wait landing on the GTK thread that paints the
window. **Your third point is taken too** — `intent`'s bounded send has moved inside
`spawn_blocking` as well, so a full mutation lane parks a blocking-pool thread rather than a
Tauri async worker.

The wait cannot deadlock, and this is the argument: the worker never blocks on anything the
frontend must feed it. `drain` is `try_recv`, `lp.turn` carries a deadline, and an intent's
reply goes to a `sync_channel(1)` whose receiver is already parked. A full lane therefore
means a busy worker, and a busy worker always comes back to `drain`.

### The deterministic witness, and why furious clicking is not one

You were right to say don't try to reproduce it by clicking. The construction uses the
worker's own blocking behaviour instead:

```
SUPER_COCKPIT_QUEUE=1                    lane depth — a DEPTH, not a mode
    │
hold_begin('saturate')                   awaited · delivery now closed
    │
64 × invoke('intent', …) un-awaited      the worker executes each one by calling into the
    │                                    runtime and waiting for the reply, INSIDE the
    │                                    drain — so it is parked for 64 sequential round
    │                                    trips and the mutation lane stays full throughout
hold_end('saturate')                     issued inside that window
    │
    ├─ W.2.1   try_send → Full → discarded → holds keeps 'saturate' → NO FRAME, EVER
    └─ W.2.2   admitted → holds empties → the valve reopens
```

and the same shape again through `in_flight`, because they wedge through different fields and
a repair could plausibly fix one:

```
window.cockpit.ack replaced by a recorder     a frame is left outstanding
64 × invoke('intent', …) un-awaited           the lane is saturated
frame_ack(seq) by hand                        issued inside that window
    ├─ W.2.1   discarded → in_flight stays Some(seq) → NO FRAME, EVER
    └─ W.2.2   admitted  → the frame stream resumes
```

Four new assertions:

```
held   a release issued while the mutation lane is saturated is admitted, not discarded
held   and the valve reopens — the hold it released is genuinely gone from the set
held   a frame can be left outstanding — the precondition the acknowledgement releases
held   an acknowledgement issued while the mutation lane is saturated is admitted, not discarded
held   and the frame stream resumes — an in-flight frame that is acknowledged is no longer in flight
```

The first and third of each pair are the *mechanism* (the message was admitted); the second is
the *consequence* (a frame actually arrived). Both, because a lane that returns `Ok` and a
worker that acts on it are two facts.

### The other half of your law

> ACK / RELEASE / CLOSE / UNLOCK must eventually enqueue **or explicitly transition the system
> to a terminal/error state** — never silently disappear.

The lane closes *eventually enqueue*. It does not close the `or`, and I nearly left that half
as prose. `frame_ack` can still reject for one reason — the worker is gone — and
`cockpit.js` called it with no `await` and no `catch`, so that one remaining rejection was
still an unhandled promise and a screen that goes on showing a world nobody is maintaining.
That is W.1's *"a screen whose relationship to the runtime is hope"* arriving through the back
door.

So `ack` now has a terminal path: the badge goes to `stalled` and the world region says the
stream stopped and that what is on it is no longer being maintained. **It is the only writer
into a `[data-source="frame"]` region in the whole file that is not a frame**, and it is
allowed there because it does not make a claim about the world — it withdraws the one the last
frame made.

Which makes it the one thing in this product that could put an unasserted claim on that
region, so the battery checks it **did not run**:

```
held   the terminal stall path did not fire — nothing but a frame wrote the world region
```

The firing path itself has no witness. Inducing it means killing the worker thread under a
live WebView and I did not build that; it is listed in §5 rather than counted.

**`SUPER_COCKPIT_QUEUE` is a depth and not a mode.** Nothing branches on its value; the code
path at 1 is the code path at 64. It exists so saturation is reached by construction rather
than by racing — the same move as the interaction hold, where a millisecond-wide window was
made into a state the cockpit deterministically sits in. The whole battery runs at depth 1,
so every W.2 and W.2.1 assertion is now also measured under saturation.

---

## 3 · What I did *not* claim, and one thing I nearly wrote

**Control-before-mutations is not falsified by this battery, and the code says so.**

I first wrote that draining control first was what keeps a hold in force before the intent it
brackets, and that draining mutations first "could take the intent while the hold sat unread
one lane over". That is wrong, and I would have shipped it as a comment describing a property
nothing measured. `drain` empties **both** lanes before `lp.turn` computes a frame, so a hold
enqueued before its intent is in force by the time any frame is evaluated, whichever lane is
read first. The flagship's mandatory intermediate state rests on the drain-then-evaluate
structure, not on lane order.

Lane order is here for a real but unwitnessed reason — a release that queues behind 64
blocking calls stalls the frame stream during exactly the traffic that produced it. It is
written down in `worker.rs` as an argument with no harness under it, rather than counted as a
property. That distinction is the one this arc keeps having to relearn.

**One enum over two channels, deliberately.** The lane a message travels is decided by which
of two `Queues` methods its command calls, not by its type. A stricter typing was available
and I did not take it: it would have made W.2.1's exact defect unreachable by a one-word edit,
and therefore made the repair unfalsifiable. There are five call sites, all in `main.rs`, each
naming its lane in one line, and `sabotage-cockpit.sh` is what enforces it. The trade is
stated in the struct's doc comment so the next reader does not "tighten" it into something
nothing can check.

---

## 4 · Measured

Figures are in `site/proof/measurements.json` (`cockpit_assertions`, `cockpit_falsifiers`,
`webview_acl`, `intent_surface`, `fixture_guard`). Everything W.2.1 asserted still holds; the
new lines are the two topology assertions in §1 and the five saturation assertions in §2.

New falsifiers — `bash tools/sabotage-cockpit.sh`, each disabling one fix and requiring a
**named** check red:

```
the ACL is what refuses the untrusted pane      → an unprivileged webview may not
  (updated: now grants the CHILD webview)         invoke intent at all
a window-scoped grant reaches every webview     → an unprivileged webview may not
  inside that window  ← FINDING 1, EXECUTED       invoke intent at all
the word 'windows' is refused before            → the capability names no window
  anything is built
a release and an acknowledgement survive        → a release issued while the mutation
  a saturated queue  ← FINDING 2, EXECUTED        lane is saturated is admitted
                                                → an acknowledgement issued while the
                                                  mutation lane is saturated is admitted
a lossy send is refused by name                 → no valve-control message is sent lossily
```

`probe()` gained the ability to require **more than one** named check red for a single
sabotage, separated by `%%`. One defect that wedges through two fields would otherwise be two
identical four-minute battery runs grepping two different lines — and, worse, a repair that
fixed `holds` and not `in_flight` would have passed one probe and looked like coverage.

### One probe went dead in this round, and it is a class you have seen here before

Lifting the match arms out of `drain` into `apply` moved `delivery.holds.remove(&id)` from
sixteen spaces of indentation to twelve. Probe 10's sed is anchored with `^` and sixteen
spaces, so it silently stopped applying its sabotage — and a probe that applies nothing still
runs, still costs a rebuild, and reports `SABOTAGE MISSED` about a fix that was never
disabled. That is exactly what happened to `sabotage-host.sh` probes 7–12 when the host became
a library.

The harness does catch it and the release does refuse — but half an hour in, which is how it
was found. There is no new gate for this: `probe()` already reports it and
`sabotage-cockpit.sh` already exits non-zero, so the property is enforced and only the
feedback is slow. Worth knowing that **every sed in that file is an anchored coupling to
source formatting**, and a refactor that touches indentation is a refactor that can quietly
retire a falsifier.

---

## 5 · What is still not true

Carried forward from W.2.1 §6, all still accurate:

- **The pane is a boundary witness, not a feature.** It renders one sentence about holding no
  capability. There is no browser pane and no Motor pane; what exists is the boundary they
  will sit behind. It is now in the right place relative to that boundary, which is the whole
  of this round's first half.
- **The cockpit renders three lists** — grants, pending requests, attached peers, plus the
  badge and receipt rail. Effects, approvals, receipts, refusals and history are in the frame
  and are not drawn.
- **`REACQUIRE` and `RESNAPSHOT` are rendered but not exercised through the WebView.**
- **The fixture guard checks the extracted predicate, not the whole seeding path.**
- **The archive is not byte-reproducible** (ZIP entries carry mtimes).
- **No bundle target.** `bundle.active` is `false`. Nothing here is a thing a person could
  download.
- **The empty *Attached* row** for the human control peer is still there — a rendering gap.

New, and specific to this round:

- **`unstable` is on.** Named above. It may break in a tauri minor release; nothing else in
  this tree depends on it.
- **The pane is positioned, not laid out.** It sits at a fixed offset chosen to stay clear of
  the grant rows so a real WebDriver click is not occluded. There is no pane layout system and
  this is not the beginning of one.
- **Depth 1 is measured; depth 64 is the default and is measured only by the same code path.**
  The argument that they are the same path is the absence of any branch on `queue_depth()`,
  which is checkable by reading and is not a harness.
- **Lane order has no witness** — §3.
- **The terminal stall path is written but never fired.** The battery proves it *didn't* run,
  which is the assertion that protects the frame region; it does not prove that it *would*.
  That needs the worker killed under a live WebView, and there is no harness for it.
- **The flagship is not known to be deterministic.** It wedged once and I could not make it do
  so again. §6. Everything else in this document is measured; that one is open.

---

## 6 · The one thing that should stop the freeze — an unreproduced wedge

The first full release run of this revision **failed the flagship**, and every subsequent
attempt to reproduce it has passed. That is the worst shape a result can have, so here is all
of it.

### What happened

```
held     the intent succeeded and the grant is STILL on screen
held     and no frame has been delivered
held     it is a state and not a race: 1.5 s later …
FAILED   the grant leaves the screen only when a frame says so
         frames 1 → 1, seq 1 → 1
FAILED   and the frame arrives once the last hold is released
FAILED   and the valve reopens …
FAILED   a frame can be left outstanding …
FAILED   and the frame stream resumes …
held     a sink that binds after the world is already live is brought up to date
held     an unprivileged webview may not invoke intent at all
```

The valve closed at the first revocation and never reopened. **No frame was delivered again
for the rest of that run** — every downstream failure is that one wedge, counted five times.
The runtime stayed healthy: the reload check passed, because a reload rebinds.

### What it is not

Not the sabotage — this was the shipped configuration. Not the queue: `try_send` is gone, both
lanes block, and the saturation checks *before* the wedge reported their sends admitted. Not
load alone in any way I can provoke.

Attempts to reproduce, all green: **five full battery runs** (one immediately after
`MIX_ENV=test mix test`, to match the chain's state), and **eighty hold → intent → release
cycles** driven inside two single launches at depth 1 — forty with the untrusted pane open and
forty without.

### Three fields can close that valve, and the battery cannot tell them apart

```rust
fn open(&self) -> bool {
    self.sink.is_some() && self.in_flight.is_none() && self.holds.is_empty()
}
```

`Delivery::bind` clears all three, so a reload recovers from any of them — which is why the
reload check passed and told us nothing. Of the three:

- **`holds`** — the release was never applied. The battery *discarded the result of that
  invoke*, so this could not be ruled out at the time. It is checked now (§4), which removes
  this candidate from the next occurrence rather than the last one.
- **`in_flight`** — the acknowledgement for frame 1 was never applied. It cannot have been
  dropped by the lane any more, and it cannot have been rejected: the terminal-stall check
  held, so the promise did not reject.
- **`sink`** — and this is where I would look first.

### The hypothesis I would test, and it is not W.2.2 code

```rust
fn send(&mut self, payload: Value) {
    let gone = match self.sink.as_ref() {
        None => return,
        Some(sink) => sink.send(payload).is_err(),
    };
    if gone { self.sink = None; self.in_flight = None; self.sent = None; }
}
```

That is **unchanged since W.2.1**. It treats *any* `Channel::send` error as "the page is
gone" and drops the sink permanently — and nothing ever rebinds on its own. A live page whose
channel errored once is then a cockpit that will never receive another frame, with no
rejection anywhere for anyone to see, recoverable only by a reload the person has no reason to
perform. That fits every symptom above exactly, including the ones that argue against the
other two fields.

I have not proved it. `Channel::send` bottoms out in the webview's IPC callback and I did not
find a way to make it fail on demand.

### What I think follows

1. **Do not freeze LIVE LOCAL on this artifact.** Findings 1 and 2 are closed on their own
   evidence and should stay; the freeze is a separate judgement and this is a reason to
   withhold it.
2. **`Delivery` should report why it is closed.** The battery can distinguish a wedge from a
   quiet world but not one closed valve from another, and that gap cost this investigation
   its answer. A frame that carried the closure reason, or a diagnostic that did, would have
   turned an unreproducible failure into a named one.
3. **A dropped sink should be a state, not a silence.** If the sink is going to be dropped on
   a send error, that is the same class as the acknowledgement the lane can no longer discard:
   it leaves a gate permanently closed, so it must move the system to a state that says so —
   which is the law from finding 2, applied to the hop below it.

I did not do any of that in this round, because you scoped it to two closures and because the
right response to an unreproduced failure is not to start changing code near it.

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
bash tools/sabotage-cockpit.sh             # long; most probes re-run the flagship
```

`WebKitWebDriver` comes with `webkit2gtk-4.1`. The battery starts its own runtime in an
**ephemeral** world and destroys it; it never opens the world a person uses.
