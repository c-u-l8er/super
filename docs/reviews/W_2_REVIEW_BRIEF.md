# W.2 — a real desktop surface that consumes the truth without becoming another source of it

**Predecessor: `W.1.4.3`, ZIP `sha256:77cec0245bdb47fb517635b62c18e0c676cd139e31ef165be1c93d8f08b9b8f5`,
content `sha256:88c5f33c51b7611771a94d6c8f05fbbb0d7b2448e04941025fdf3e5576349be2`.**

> **W.1.4.3 is frozen and there is no W.1.4.4.** Your two remaining edges are recorded at the
> bottom of this brief with what was and was not done about them, and neither one moved.

You asked for the Tauri cockpit and for one test, staged so it cannot pass vacuously. Both exist.
The flagship runs against a real WebKit WebView driven by `tauri-driver`, with a real `ampd` on the
other side of a real descriptor, and it goes red under six sabotages.

---

## 0 · What is new

```
super/host/          split into lib + bin — src/lib.rs is the whole program,
                     src/main.rs is three lines. The cockpit links the SAME
                     CockpitLoop; there is no second state machine.
super/cockpit/       the Tauri v2 app
  src/main.rs        Tauri setup · intent() · frame_ack() · two CLI probes
  src/worker.rs      the frame pump: Runtime + CockpitLoop + the delivery valve
  ui/                index.html · cockpit.css · cockpit.js — no bundler, no deps
super/tools/
  cockpit-battery.mjs      the flagship, over raw W3C WebDriver
  check-intent-surface.mjs the surface, checked against Ampd.CommandSpec
  check-fixture-guard.sh   the demo fixture cannot touch a person's world
  sabotage-cockpit.sh      six probes; each expects a named check RED
```

---

## 1 · The flagship, measured

`node tools/cockpit-battery.mjs` — real app, real WebView, real click, real IPC. **The figures
are in `site/proof/measurements.json` under `cockpit_assertions`, `cockpit_falsifiers`,
`intent_surface` and `fixture_guard`**; this lists what is asserted, not how many:

```
  the cockpit reaches LIVE LOCAL from a real desktop WebView
  LIVE LOCAL carries the projection it is a view of, not merely a cursor
  the frame names the world incarnation it was assembled in
  both clocks arrive — authority revision and view revision
  the DOM shows a grant
  the grant on screen is the grant in the frame — the DOM is derived, not invented
  the revocation is submitted and the runtime answers SUCCESS
  the intent succeeded and the grant is STILL on screen
  and no frame has been delivered — the row is there because nothing has said otherwise
  it is a state and not a race: 1.5 s later the grant is still there and still no frame
  the receipt rail moved and the world region did not
  the grant leaves the screen only when a frame says so
  and the frame that removed it is a frame in which the grant is genuinely gone
  the held frame reports the states it superseded rather than dropping them silently
  the WebView cannot submit a read — a second way to learn the world is a second source of truth
```

The sequence you specified, with the intermediate state where you put it:

```
DOM shows grant
      │
      ▼   WebDriver clicks the real button
Tauri IPC resolves SUCCESS               receipt rail: revoke_grant · accepted
      │
      ▼
DOM STILL SHOWS GRANT                    held for 1.5 s and asserted twice
      │
      ▼   frame_ack(seq, ready: true)
new cockpit-frame@1 without the grant
      │
      ▼
DOM removes the grant
```

---

## 2 · Your "otherwise it can pass vacuously", and what the hold is made of

This is the part I want reviewed hardest, because you are right that the obvious implementation of
this test passes against a cockpit that removes the row optimistically — the assertion just has to
land in the millisecond before the frame arrives, and on this machine it would.

**The hold is not a timer and it is not a branch for tests.** It is a product rule:

> Do not reflow the list a person is clicking on.

Between "revoke pressed" and "the runtime answered", the rows hold still. Otherwise the row under
the cursor can move while the cursor is on it, in a surface where a mis-click grants or removes
authority. So `ui/cockpit.js` brackets every submission:

```js
await window.cockpit.pause();          // frame_ack(seq, ready: false)
… await invoke('intent', …) …
await window.cockpit.resume();         // frame_ack(seq, ready: true)
```

and `worker.rs` honours it, because the delivery valve was already there for backpressure:

```rust
fn open(&self) -> bool {
    self.in_flight.is_none() && !self.paused
}
```

**Ordering is what makes it deterministic rather than probable.** The pause and the intent are two
messages on one bounded queue, drained in order by the one thread that also emits. The pause is
therefore in force before the intent is submitted, which is before the world can move. There is no
window in which the frame could arrive early.

The battery's only intervention is to replace `window.cockpit.resume` with a function that does
nothing — which is the state a slow renderer is already in. It then asserts **two independent
things** about the intermediate state, and the second is the one that closes your objection:

```
the grant is still in the DOM        — would also pass if a frame had arrived
                                       and the renderer had failed to apply it
window.cockpit.frames is unchanged   — says no frame arrived at all
```

---

## 3 · Falsified

`bash tools/sabotage-cockpit.sh` — each probe disables one fix, rebuilds, and requires a **named**
check to go red. Two of them disable the two halves of the same law on opposite sides of the IPC
boundary, because either one alone would leave the other looking like it was doing the work.

```
the renderer does not draw its own optimism         → the intent succeeded and the
                                                      grant is STILL on screen        RED
the host honours a paused renderer                  → no frame has been delivered     RED
a submission pauses delivery before it is sent      → no frame has been delivered     RED
the world region is rebuilt from the frame,         → the grant leaves the screen
  not remembered                                      only when a frame says so       RED
the intent surface admits no read                   → no intent on the surface
                                                      is a read                       RED
the demo fixture is refused against a person's      → the fixture is refused against
  world                                               a persistent world              RED
```

The first is the W.2 defect itself, restored verbatim — the four-line `submit` every desktop app is
written with:

```js
receipt(name, refusal ? 'refused' : 'accepted', refusal ?? '');
if (!refusal) document.querySelector(`#world .row[data-id="${args.grant_id}"]`)?.remove();
```

---

## 4 · The architecture, and the one thing I refused to duplicate

```
World                     ampd — the only thing that decides
  │
CockpitLoop               super_host::CockpitLoop, UNMODIFIED
  │                       `super-host verify` and the cockpit link the same code
cockpit-frame@1           ordered · at most one un-acknowledged · newest-wins
  │
WebView                   renders the frame
  │
intent()                  back into the human control channel
```

`host/` is now a library with a three-line binary on top of it. The alternative — a Tauri app with
its own continuity handling — would have been a second implementation of the hierarchy F.8.2.5 and
W.1 spent four rounds getting right, agreeing with the first by inspection. Every check in
`super-host verify` is now a check about the cockpit's state machine, not merely about a battery's.

**Three consequences worth naming:**

- **One reader, one writer.** `Chan` has no correlation between concurrent callers — the F.8 lesson,
  measured at 2 replies out of 96. A Tauri command runs on whatever thread the runtime hands it, so
  commands never touch the channel: every message into the world goes through the worker's queue,
  and the socket has exactly one caller for its whole life.
- **`intent()` is `async`.** A synchronous Tauri command runs on the main thread, which on GTK is
  the thread painting the window. A click that waited there would freeze the surface it is trying
  to keep truthful.
- **The intent surface has no read on it.** `INTENT_SURFACE` is six names, and
  `check-intent-surface.mjs` proves against `Ampd.CommandSpec` — not against the comment beside it
  — that every one is a `:mutation` exclusive to `:human_control`, and that the set is *equal* to
  the runtime's human-control mutations. A cockpit that could call `operator_projection` would hold
  a second, uncursored view with no incarnation, epoch or revision attached, and could render from
  that instead.

---

## 5 · The demo fixture, and where I put its guard

The flagship needs a grant to revoke. `SUPER_COCKPIT_FIXTURE=1` seeds one **through ordinary
commands on ordinary channels** — bind an agent channel, the agent asks, the person approves. There
is no privileged route into the registry, and `Ampd.TestFixture.seed_demo!/0` is deliberately not
reachable from here: a fixture that can mint authority without a person is the thing this runtime
exists to make impossible.

It still mints authority, so it is refused against a world this program did not create. **The
judgement is extracted from the I/O** — `worker::fixture_allowed(&WorldDir) -> bool`, with
`super-cockpit --fixture-check` printing its answer for a given environment — because a gate that
had to boot a runtime against somebody's real world in order to watch it not be touched is a gate
nobody runs twice.

I am flagging the limit honestly: that check exercises the predicate, not the whole seeding path.
The path has one caller and one guard, and the sabotage removes the guard rather than faking the
check, but it is a smaller claim than the flagship's.

---

## 6 · Your two W.1.4.3 edges

**POSIX/ZIP metadata outside `release_content_sha256`.** Not reopened, per your recommendation, and
your framing is adopted: when Super ships artifacts whose mode bits, symlinks or ownership are
semantically load-bearing, that becomes *artifact semantics* — `path · type · mode · size ·
content_sha256` — and not a retrofit of the W.1.4 byte-content law. Recorded, not built.

**Classification is not intentional inclusion.** Agreed, and it is now visibly true rather than
abstractly true: this round adds a Rust crate whose build products are 1.1 GB. `cockpit/target` was
already excluded by `SKIP_DIR`, but `cockpit/gen/` — four JSON schema files that `tauri-build`
regenerates on every build — was not, and would have shipped. **That is the `ampd/priv/data` lesson
exactly**: a figure that depends on whether a build has run yet is not a property of the release.
It is excluded by name with the reason written down.

The positive-manifest move you sketched is not in this round, deliberately — a release-scope change
under a round whose subject is a desktop surface is how two unrelated things fail together. It is
the obvious next packaging round.

---

## 7 · What is still not true

- **The cockpit renders three lists.** Grants, pending requests, attached peers, plus the badge
  and the receipt rail. Effects, approvals, receipts, refusals and history are in the frame and are
  not drawn. Nothing claims otherwise on screen; there is no tab that opens onto nothing.
- **`REACQUIRE` and `RESNAPSHOT` are reachable and rendered but not exercised by this battery.**
  `super-host verify` exercises them against a real restore; the WebView's rendering of them is
  asserted only by the state badge's existence.
- **The archive is still not byte-reproducible** (ZIP entries carry mtimes), unchanged from W.1.4.3.
- **No bundle target.** `bundle.active` is `false`: this builds and runs, and there is no installer.
  The site still says no desktop app exists to install, which remains true of the thing a person
  would download.
- **`Motor`/`Machine` is architectural input only**, exactly as you asked. Nothing in this round
  anticipates it, and `MOTOR_MACHINE_RESEARCH_BRIEF_FOR_OPUS.md` was not edited.

---

## 8 · How to reproduce

```
cd super
cargo build --release --manifest-path host/Cargo.toml
cargo build --release --manifest-path cockpit/Cargo.toml
cargo install tauri-driver                 # once
node tools/cockpit-battery.mjs             # the flagship — needs a display
node tools/check-intent-surface.mjs
bash tools/check-fixture-guard.sh
bash tools/sabotage-cockpit.sh             # ~12 min; four probes rebuild and re-run the flagship
```

`WebKitWebDriver` comes with `webkit2gtk-4.1`. The battery starts its own runtime in an **ephemeral**
world and destroys it; it never opens the world a person uses.
