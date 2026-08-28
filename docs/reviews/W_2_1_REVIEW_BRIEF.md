# W.2.1 — the boundary around the law

**Predecessor: `W.2`, ZIP `sha256:f1f179ed4b158253ca330d31cd90f210ae159a984fd7b3fb566b3c9d62775f44`,
content `sha256:8c5fc48798288ed54403db90b158a72a4bcd8e9c10c73c6ffb38130ba74a4075`.**

> **Narrow, as scoped.** No `ampd` change, no W.1 change, no Cloud work, no Motor. Every W.2
> flagship assertion and every W.2 sabotage case is preserved; the flagship's staging is
> unchanged in spirit and the mechanism under it is now compositional.

All three findings are real and all three are fixed. Two of them I would have argued were
adequate, and both arguments were wrong in the same way — a mechanism that *happens to*
produce the right outcome on this machine is not the property.

---

## 0 · Verdict on each

```
1  application commands outside the Tauri ACL        FIXED · statically + at runtime
2  first-frame race between emit and listen()        FIXED · Channel, bound by the frontend
3  paused: bool does not compose across intents      FIXED · keyed holds
```

---

## 1 · The ACL, and why your framing of it is the important part

You are right that this was not an immediate exploit and right that it was the wrong thing to
leave. The capability read *"the cockpit may listen for frames and nothing else"* beside an
`intent` command every webview in the process could call. **The sentence was describing a
boundary that did not exist**, which is worse than a missing boundary, because it reads as
coverage.

`build.rs` now declares the commands, so `allow-intent` is a permission that must be granted:

```rust
tauri_build::try_build(
    tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&[
            "bind_frame_stream", "intent", "frame_ack", "hold_begin", "hold_end",
        ]),
    ),
)
```

and the capability grants them to `main` and to nothing else. **`core:default` is gone
entirely** — not narrowed. Your reading of it was correct (`core:event:default` carries
`allow-emit` and `allow-emit-to`, which is injection into the application's own event bus, not
listening) and finding 2's fix removes the need for any core permission at all: the frame
stream is a Channel the frontend hands over, so the cockpit holds **no** core permission. That
is a stronger statement than a carefully chosen few.

**The runtime witness is the one you asked for.** `SUPER_COCKPIT_PANE=1` opens a second
webview — the shape a browser or application pane will take — granted nothing. It invokes
`intent`, and Tauri answers:

```
Command intent not allowed by ACL
Command bind_frame_stream not allowed by ACL
```

Not our JavaScript. Not `INTENT_SURFACE`. Not authorized to invoke the command at all.

**And the check asserts it could have.** A pane with no `invoke` would fail every one of those
for a reason unrelated to authority and still read as coverage, so the battery first proves the
pane holds a working Tauri bridge, then requires the refusal to carry *"not allowed by ACL"*
specifically. Three lists — what `invoke_handler` registers, what `AppManifest` declares, what
the capability grants — are checked against each other statically by
`tools/check-webview-acl.mjs`, because a command added to one and not the others fails **open**,
which is exactly how W.2 got here.

---

## 2 · The first-frame race, and the reason I stopped defending Events

Your diagnosis is exact, including the interaction with the valve, which is the part that makes
it a wedge rather than a dropped frame:

```
worker              delivery.in_flight = seq
                    emit("cockpit-frame")
frontend                                    X listener not yet registered
                    never acknowledged
                    no later frame may ever be sent
```

I had reasoned that the one-in-flight/ACK discipline discharged the ordering problem. It
discharges *reordering*; it makes *loss* permanent. And W.2's battery passing was timing
evidence — runtime startup is slow enough on this machine — which is precisely the class of
argument this project spends its rounds refusing elsewhere.

So: `Channel<CockpitFrame>`, constructed by the frontend, `onmessage` installed, **then** handed
over. There is no interval in which a frame can be addressed to nobody, and no global emit.

**One thing fell out of it that I did not expect and that matters more than the race.** A sink
that binds *late* must be brought up to the current state, or it is fed nothing until the world
next changes — a blank cockpit attached to a healthy runtime. `Delivery::bind` therefore clears
`sent`, and that is what makes the deterministic falsifier possible without a test seam:

> **reload the live page.** A reload is the latest possible registration — the runtime has been
> up for a minute and the world is not about to move. If a late sink is only fed by the next
> change, that page stays blank forever.

That is the same defect you named, reachable without an injected delay, and the sabotage that
breaks it (drop the `self.sent = None` from `bind`) is one line.

---

## 3 · Holds

Agreed and adopted verbatim, including your framing of it as another boolean carrying two facts.

```
frame acknowledgement   ack(seq)
interaction hold        hold_begin(id) / hold_end(id)

delivery opens iff      a sink exists
                        AND no frame is in flight
                        AND the hold set is empty
```

I took keyed holds rather than serializing submissions, for your reason: serialization is a rule
future UI code has to remember, and a rule future code has to remember is a rule.

The falsifier is the one you wrote — begin A, begin B, end A, move the world, require **no
frame**; end B, require the frame — and the sabotage is `holds.clear()` on release, which *is*
the boolean, so it fails deterministically.

---

## 4 · Measured

Figures are in `site/proof/measurements.json` (`cockpit_assertions`, `cockpit_falsifiers`,
`webview_acl`, `intent_surface`, `fixture_guard`). What is asserted, and the new lines are the
last six:

```
  the application opens the trusted cockpit and an untrusted pane beside it
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
  the WebView cannot submit a read — a second source of truth
  one interaction ending does not release another interaction's hold
  and the frame arrives once the last hold is released
  a sink that binds after the world is already live is brought up to the current state
  and what it is brought up to is the world as it is now, not as it was
  the untrusted pane holds a working Tauri bridge — the refusal is not a missing API
  an unprivileged webview may not invoke intent at all — Tauri refuses it, not our JavaScript
  and it may not bind the frame stream either
```

Falsifiers — `bash tools/sabotage-cockpit.sh`, each disabling one fix and requiring a **named**
check red:

```
the renderer does not draw its own optimism        → the intent succeeded and the
                                                     grant is STILL on screen
the host honours a holding renderer                → no frame has been delivered
a submission takes its hold before it is sent      → no frame has been delivered
the world region is rebuilt from the frame,        → the grant leaves the screen only
  not remembered                                     when a frame says so
the intent surface admits no read                  → no intent on the surface is a read
the demo fixture is refused against a person's     → the fixture is refused against a
  world                                              persistent world
a registered command outside the ACL is caught     → every registered command is
  statically                                         declared to the ACL
the ACL is what refuses the untrusted pane         → an unprivileged webview may not
                                                     invoke intent at all
a sink that binds late is brought up to the        → a sink that binds after the world
  current state                                      is already live
an interaction hold is keyed, not a shared flag    → one interaction ending does not
                                                     release another
```

The seventh is W.2's own defect restored: drop `intent` from the ACL manifest and it goes back
to being reachable from every webview while the capability file goes on describing a boundary.

---

## 5 · Packaging, again, and it fired again

`cockpit/permissions/autogenerated/*.toml` is written by `build.rs` at build time from the list
*in* `build.rs`. Shipping it would put a second copy of that declaration in the artifact — one
that must then agree with the first — and it is build output, so a clone that has not been built
ships a different set than one that has. Excluded by name with the reason written down, beside
`cockpit/gen/`.

That is the second W.2-era instance of your *"classification is not intentional inclusion"* in
two rounds. The positive-manifest move is still deliberately not in this round.

---

## 6 · What is still not true

- **The pane is a boundary witness, not a feature.** `SUPER_COCKPIT_PANE=1` opens a webview that
  renders one sentence about holding no capability. There is no browser pane and no application
  pane; what exists is the boundary they will sit behind, exercised now so it is not discovered
  later. The ACL it fails against is the shipped one.
- **The cockpit renders three lists.** Grants, pending requests, attached peers, plus the badge
  and the receipt rail. Effects, approvals, receipts, refusals and history are in the frame and
  are not drawn. Nothing on screen claims otherwise.
- **`REACQUIRE` and `RESNAPSHOT` are rendered but not exercised through the WebView.**
  `super-host verify` exercises them against a real restore.
- **The fixture guard checks the extracted predicate, not the whole seeding path.**
- **The archive is not byte-reproducible** (ZIP entries carry mtimes), unchanged since W.1.4.3.
- **No bundle target.** `bundle.active` is `false`: this builds and runs, and there is no
  installer, no signing and no update path. Nothing here is a thing a person could download.
- **One cosmetic defect, unfixed and named:** the human control peer renders as an empty row
  under *Attached*, because `peers` carries no actor for it. It is a rendering gap, not a claim.

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
bash tools/sabotage-cockpit.sh             # ~30 min; seven probes re-run the flagship
```

`WebKitWebDriver` comes with `webkit2gtk-4.1`. The battery starts its own runtime in an
**ephemeral** world and destroys it; it never opens the world a person uses.
