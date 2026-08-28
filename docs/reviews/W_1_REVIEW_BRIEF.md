# W.1 — the cockpit observes one world incarnation

**Artifact: `and-super-rev-w1.zip`. Every gate green.**

Both findings are real, both reproduce deterministically, and one of them is worse than
you described. The read fence, the coherent frame, the `Continuity` enum and the host
event loop are in — including the two rows F.8.2.5 reported as not implemented.

**What W.1 does not deliver is the WebView itself.** §8. The truth pipeline is complete up
to the render; the render is not started, and the ladder says so rather than implying
otherwise.

```
BEFORE                                    AFTER
──────────────────────────────────────    ──────────────────────────────────────
GEN-1 CHANNEL, manifest at generation 2   GEN-1 CHANNEL, manifest at generation 2
  request_grant  → refused                  request_grant       → refused
  agent_projection → SERVED, gen 2          agent_projection    → refused
  preflight        → SERVED, gen 2          preflight           → refused
                                            list_*              → refused
snapshot cursor revision : 1                subscribe           → refused
revision now             : 2
the revoked grant        : gone           snapshot cursor revision : 2
TORN                                      revision now             : 2
                                          coherent
```

---

## 0 · Measured

| | F.8.2.5 | W.1 |
|---|---|---|
| conformance vectors | 42 | **42** |
| BEAM tests | 194 | **204**, 0 failures at seed 0 |
| browser assertions | 64 | **64** |
| BEAM sabotage falsifiers | 56 · 0 not | **62 · 0 not** |
| host acceptance checks | 48 held · 0 failed | **61 held · 0 failed** |
| host sabotage falsifiers | 6 · 0 not | **8 · 0 not** |

---

## 1 · Your first finding, verified — and one detail corrected

Reproduced in exactly the interval you named, with `Ampd.Bridge` suspended so a lineage
advance parks inside its transaction after the durable bump and before the barrier:

```
manifest now gen 2 · incarnation 1349278d…
gen-1 peer still resolves: %{"generation" => 1, …}

agent_projection    -> SERVED  agent-projection@2   incarnation=nil
preflight           -> SERVED  (answered authority-missing out of generation 2)
list_effect_history -> BLOCKED on the held coordinator
list_grant_requests -> BLOCKED on the held coordinator
operator_projection -> BLOCKED on the held coordinator
subscribe           -> BLOCKED on the held coordinator
request_grant       -> BLOCKED on the held coordinator
```

**`subscribe` does not return a generation-2 snapshot in that window.** It blocks — because
`Ampd.Projection.continuity/0` calls the coordinator, and the coordinator is held by the
advance that created the window. Your diagram is right about the law and wrong about which
command demonstrates it; the two that actually crossed were `agent_projection` and
`preflight`, neither of which touches the coordinator at all.

That does not weaken the finding, it sharpens it. The block was incidental — an accident of
which transaction happened to be holding the coordinator — not a fence. And it points at
something worth noting: `agent_projection` carried **no `world_incarnation` at all**, so a
client could not have checked it either. Only `projection-snapshot@1` and `history-page@1`
carried a cursor. That is now true of every peer-bound read.

## 2 · Your second finding, verified — and it was four samples, not two

`continuity/0` did not sample the cursor and the content independently. It sampled *itself*
independently, four times:

```
World.incarnation()  → reads the manifest, hashes it
generation()         → reads the manifest AGAIN
epoch()              → GenServer.call to the coordinator
revision()           → GenServer.call to the coordinator AGAIN
```

A lineage advance between the first two yields an incarnation from before the bump beside a
generation from after it. A coordinator restart between the last two yields the *old* epoch
with the *new* revision — a revision going backwards inside an epoch that never changed,
which is the precise fault the epoch was introduced to make impossible.

Now: one manifest read for both world fields, and `AuthorityCoordinator.cursor/0` for both
runtime fields.

The tear you described is real and measured, with `Ampd.Session` suspended to park the
build between the cursor and the grant read:

```
snapshot cursor revision : 1
revision now             : 2
still in the snapshot?   : false
TORN — the cursor names revision 1, the content is revision 2
```

## 3 · The fence must not ask the coordinator

I implemented the read fence against `continuity/0` first, which is the obvious thing and
is wrong in a way worth recording: **the transaction most likely to have ended a channel's
incarnation is a lineage advance, and a lineage advance holds the coordinator while it
tears channels down.** A fence that has to ask the coordinator cannot answer during the one
operation it exists for.

The suite said so immediately and unsubtly — every queued-work witness in F.8.2.5 stopped
reaching the coordinator, because the fence in front of them was waiting on it, and the
whole file wedged.

The incarnation is a file. `Ampd.Projection.fence/1` reads the manifest and nothing else.
That is also why the reads above no longer appear as `BLOCKED`: they are refused
immediately, by something that needs no process to be free.

## 4 · The seqlock starves, and refusing by name was the wrong fix

Your before/after cursor validation is right and it is not sufficient on its own. Against a
process issuing back-to-back grant edits, **40 of 40** projection reads failed to settle.

I built the `projection-unstable` refusal you would expect, and then deleted it. A busy
world that cannot be observed is a worse product than a slow one, and the cockpit has no
other input. So:

```
optimistic  sample · build · sample · accept only if nothing moved   (3 attempts)
pessimistic AuthorityCoordinator.observe/1 — assemble INSIDE the total
            order, where nothing can linearize between cursor and content
```

`observe/1` does **not** increment `seq` and does not notify subscribers: a read that
counted as an ordered operation would advance the revision it is reporting — a cursor that
changes because it was looked at, and a push that is its own reason for another push.
There is a falsifier for exactly that.

`projection-unstable` is gone because the fallback made it unreachable, and a refusal code
no input can produce is a promise to an operator that nothing keeps. That is the same
defect class as the `world-meta-untrusted` code F.8's `seal_code/1` could never emit.

The trade is honest and is why the pessimistic path is second: `fun` there walks a dozen
registry processes and every authority mutation waits behind it.

## 5 · Three of my own witnesses were weak, and the harness caught all three

Worth reporting in full, because it is the same defect class the round is about.

**The read-fence probe did not falsify.** Disabling the fence in `Ampd.Control.served/3`
left every read still refused — by the second fence inside `framed/2`. One property, two
routes, and the probe was testing one of them. Exactly what this harness's own `probe()`
documentation warns about. Now two pairs.

**The churn witness did not falsify.** It asserted liveness — nothing refused — and the
sabotage that removes the fallback *preserves* liveness while destroying coherence, so it
stayed green. A test that passes for a reason it is not measuring. Fixed by finding an
invariant inside the frame: `Ampd.Core.snapshot_of/2` digests exactly the active grants,
and the operator projection carries both that digest and the grant list, read at different
points in the build. Recomputing one from the other is a coherence check on the frame
itself, and it goes red the moment the build tears.

**The host EOF witness did not falsify.** It dropped the `Chan`, which empties the loop's
slot — so the loop reacquired down the `None` arm and never consulted `closed()` at all.
`tools/sabotage-host.sh` disabled the EOF check and stayed green. Now the witness calls
`shutdown(2)` without closing, so the channel goes dead while its `Chan` stays in the slot.

And two probes carried from F.8.2.5 reported **SABOTAGE MISSED** against my own refactor —
their `sed` patterns no longer matched. Both re-pointed, and the bind-vs-submit one is
better for it: W.1 gave `served/3` one binding that both fences read, so the probe now
sabotages the *source* of the expectation rather than one of its two uses.

## 6 · A defect found while building the witnesses

`Ampd.Bridge.reset/0` was a bare `GenServer.call/2` — a 5 s client deadline in front of a
handler that waits up to 2 s **per channel**. Three wedged channels is already 6 s, so the
caller times out and **raises inside the transaction that called it**:

```
** (stop) exited in: GenServer.call(Ampd.Bridge, :reset, 5000) ** (EXIT) time out
    (ampd) lib/ampd/authority.ex:347: Ampd.Authority.close_channels!/0
    (ampd) lib/ampd/authority.ex:331: anonymous fn/2 in Ampd.Authority.advance_lineage/2
```

That leaves a world at generation 2 whose channels were never closed — precisely the state
F.8.2.5's barrier exists to make unreachable, reachable by a slow client. The wait is now
one budget for the whole teardown rather than a fresh one per channel, and the call is
given room above it.

## 7 · Your W.1 battery

| Witness | Result |
|---|---|
| current human channel subscribes | ✅ coherent operator snapshot |
| snapshot cursor identifies the incarnation rendered | ✅ on **every** peer-bound read, derived from `command-spec@1` |
| authority changes during snapshot construction | ✅ retried; frame carries the later revision, never the earlier |
| gen-1 channel asks for a projection mid-advance | ✅ `world-incarnation-changed` |
| same stale channel calls `subscribe` | ✅ refused · no snapshot · subscriber not registered |
| same stale channel requests history | ✅ refused · no `items` key |
| fresh channel in gen 2 | ✅ served normally |
| coordinator epoch changes | ✅ `Continuity::NewRuntime` · discards projection, keeps authority |
| world incarnation changes | ✅ `Continuity::NewIncarnation` · **reacquires** authority |
| revision advances | ✅ `Continuity::Advance` |
| older/equal revision | ✅ `Continuity::Seen` |
| control socket at EOF | ✅ noticed without being asked |
| reacquisition → fresh subscription → LIVE LOCAL | ✅ and the reacquired channel answers |
| **the Tauri WebView renders it** | ❌ **not started** — §8 |

Two additions of my own: a cursor holding nothing classifies its first frame as `Fresh`
rather than as a discontinuity, so a host does not start by reacquiring authority it just
took; and the incarnation is checked to be 128 bits **on the wire**, not in the runtime
that produces it.

`world_incarnation` is now 16 bytes as you asked. It cost nothing and it is about to be the
identity a restored world is recognised by across machines.

## 8 · What is not in this round, plainly

**There is no Tauri dependency in `host/Cargo.toml`, and I did not add one.** The crate is
`serde_json` and libc externs. Adding a WebView is a large dependency change on a build
that every release gate runs through, and doing it in the same round as the truth pipeline
would have meant shipping neither well. So W.1 delivers:

```
Rust event loop → take human control → subscribe → validated coherent
projection → classify continuity → derive LIVE LOCAL
```

and stops one arrow short of `→ render Tauri WebView`. `Cockpit::LiveLocal` is derived and
measured; nothing draws it yet.

**The restore-triggered EOF still cannot be driven from the host**, unchanged from F.8.2.5
and for the same reason: `advance_lineage/2` is on no channel. The EOF witness uses
`shutdown(2)` on a live channel, which is what a runtime-side close looks like from here —
it measures the reacquisition, not its cause.

## 9 · Ladder

    C1.1     Tauri Rust host + private transport
             ├─ F.8.2.3  refusal is terminal · no channel outlives its world   ✓
             ├─ F.8.2.4  world incarnation · authority fenced at the
             │           linearization point                                   ✓
             ├─ F.8.2.5  generation is a fence · authority reacquired after
             │           a discontinuity · bind-time sampling falsified        ✓
             └─ W.1      the cockpit observes one incarnation:
                         · reads fenced to the peer's incarnation              ✓
                         · the cursor describes the content beside it          ✓
                         · a busy world stays observable, and coherent         ✓
                         · Continuity is an enum the host acts on              ✓
                         · the event loop reacquires after EOF                 ✓
                         · the WebView renders it                              ✗
    W.2      REVOKE → Tauri IPC → human channel → authority transition
             → coherent pushed projection → the UI changes because truth did
    C1.1b    SQLite transactional persistence · durable revision

I agree with your framing of what W.2 is, and with why it is the point where C1.1 becomes a
product milestone rather than a well-tested substrate. The honest next step is the WebView
itself: a render surface for a truth that is now, finally, mechanically identified.

## Verify

```
cd ampd && mix test --seed 0          # 204 tests
bash tools/sabotage.sh                # 62 falsified · 0 not   (~6m)
cd .. && bash tools/release.sh        # required gates, including both host gates
./host/target/release/super-host verify        # 61 held · 0 failed
bash tools/sabotage-host.sh                    # 8 falsified · 0 not
```

New this round: `ampd/test/cockpit_test.exs` (10 witnesses), `Ampd.Projection.framed/2` and
`fence/1`, `Ampd.AuthorityCoordinator.cursor/0` and `observe/1`, `CommandSpec`'s `kind:`
declaration, and `Continuity` + `CockpitLoop` in the host.
