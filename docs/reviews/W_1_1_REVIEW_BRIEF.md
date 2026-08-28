# W.1.1 — LIVE LOCAL holds one live renderable view

**Artifact: `and-super-rev-w11.zip`. Every gate green.**

All four findings are real. Three reproduced exactly as you drew them; the fourth reproduced
harder than you drew it, and my first attempt to measure it read zero because I grepped for
the wrong refusal code. All four are closed, with falsifiers.

The `CockpitLoop` one is as direct as you said. `Cockpit::LiveLocal` was documented as
*"control held, subscribed, and holding a projection"* and the struct had no field for one.
I wrote both the doc and the struct in the same round.

```
                        BEFORE                          AFTER
CockpitLoop             rt chan cursor state            + projection: Option<Value>
LiveLocal means         I received a cursor             I hold the view that cursor
                        from a coherent snapshot        belongs to · invariant checked
agent channel opens     pushes: 0 · revision 1 -> 1     pushes: 1 · revision unchanged,
                        subscriber holds 1 channel      view_revision moved
Subscriptions killed    connection alive · 0 pushes     connection closed · host sees EOF
                        LIVE LOCAL forever              → reacquires → LIVE LOCAL
one denied preflight    4 refusals recorded             1 refusal recorded
```

---

## 0 · Measured

| | W.1 | W.1.1 |
|---|---|---|
| conformance vectors | 42 | **42** |
| BEAM tests | 204 | **211**, 0 failures at seed 0 and at 91731 |
| browser assertions | 64 | **64** |
| BEAM sabotage falsifiers | 62 · 0 not | **67 · 0 not** |
| host acceptance checks | 61 held · 0 failed | **68 held · 0 failed** |
| host sabotage falsifiers | 8 · 0 not | **10 · 0 not** |

---

## 1 · The cockpit holds the view

`CockpitLoop` gains `projection: Option<Value>`, and `LiveLocal` is now only reachable
through one function:

```rust
fn go_live(&mut self, frame: &Value) -> bool {
    let complete = frame["schema"] == "projection-snapshot@1"
        && frame["world_incarnation"].is_string()
        && frame["projection_epoch"].is_string()
        && frame["view_revision"].is_u64()
        && frame["projection"].is_object();
    if !complete || self.chan.is_none() { … Acquiring }
```

`acquire` validates the subscribe reply before claiming anything, `turn` adopts the **whole
frame** rather than its cursor, and `discard()` runs before every reacquisition so a view
belonging to an ended world is never on screen across one. `invariant_holds()` is the
property from outside: LIVE LOCAL with no projection, no channel, or no incarnation is a
badge that means nothing, and the battery checks it.

The render object is yours:

```rust
pub struct CockpitFrame { state, world: ProjectionCursor, projection: Option<Value> }
```

One call, one coherent answer — so nothing downstream has to take a second sample to draw
what the cursor describes. That was the real risk you identified: the easiest next move
would have been a WebView calling `operator_projection` again, breaking the cursor/content
relation at the last hop.

## 2 · Two clocks, and it was three sources, not two

Confirmed: `Ampd.AuthorityCoordinator` was the only production caller of
`Subscriptions.changed/0`. Measured:

```
subscribed · channels in view: 1
an agent channel opens
pushes received: 0 · revision 1 -> 1
a fresh snapshot now shows 2 channels — the subscriber still holds 1
```

You named `peers` and `channels`. `recent_refusals` is the third, and it is the one that
matters most for a diagnostic view: a refusal that reaches no coordinator — an agent asking
for a human-only command, refused by `Ampd.Control` before dispatch — changed the operator
projection and announced nothing.

So:

```
revision       ordered AUTHORITY mutations · which durable state this is based on
view_revision  everything a projection can SHOW · is this newer than what I render
```

`Ampd.Peer`, `Ampd.Bridge` and `Ampd.RefusalLog` call
`AuthorityCoordinator.touched/0` — a **cast**, necessarily: `Ampd.Bridge.reset/0` is called
from inside a coordinator transaction by `advance_lineage/2`, so a synchronous call would
deadlock against the transaction calling it.

**One naming decision I made and am flagging rather than burying.** You proposed
`authority_revision` / `projection_revision`. On the wire I kept `revision` and added
`view_revision`, because `revision` is in the host, the fixtures and a dozen tests, and a
wire rename is its own decision rather than a side effect of this one. In Rust the fields
are named honestly — `ProjectionCursor { authority_revision, view_revision }` — so the
misleading pairing only survives on the wire. Say the word and it becomes
`authority_revision` in W.2.

## 3 · A subscription is a lease

Confirmed, and the measurement is stark:

```
subscribers before: 1
Ampd.Subscriptions killed
subscribers after restart: 0
an authority mutation
pushes: 0 · the control connection is still alive: true
```

No EOF, no frame, no error. Your smallest fix is the one that shipped: the subscriber
watches the subscription server from its own side, so its death closes the channel and W.1's
already-working EOF path does the rest. A monitor rather than a link, and in that direction
only — a link would let one dying connection take the subscription server down for everyone.

Measured after:

```
killing Ampd.Subscriptions ...
connection alive: false · bridge lists 0 · peer resolves: false
```

## 4 · `kind: :read` did not mean safe to retry

Confirmed, and worse than the `preflight` case alone. Under forced churn, for **one** client
command:

```
preflight (denied)      refusals recorded: 4   %{"denied-by-default" => 4}
inspect_refusal (404)   refusals recorded: 4   %{"refusal-unknown" => 4}
agent_projection        refusals recorded: 0
list_receipts           refusals recorded: 0
```

*(My first probe grepped for `authority-missing` and read 0. The code is
`denied-by-default`. I was measuring the wrong string, not a working system.)*

Your `retry:` axis is what shipped, because you were right that the abstraction is what is
wrong rather than `preflight`:

```
kind:  :read | :mutation      may this be assembled under a cursor?
retry: :safe | :once          may it be executed more than once?
```

`preflight` and `inspect_refusal` are `read + once` and go straight to the ordered path via
`Projection.framed_once/2`. Both facts are declared in `Ampd.CommandSpec` and the build
fails if a read omits either.

This also became load-bearing rather than tidy: recording a refusal now advances the *view*
revision, and the view revision is what the seqlock compares — so a speculative read that
constructs a refusal would invalidate its own attempt, retry, and record again. The two
findings are one fix.

## 5 · What I got wrong building it

**The refusal witness was weak and the probe caught it.** My first version used
`request_effect`, which runs an authority transaction whether or not it is allowed — so the
push it produced came from the coordinator, and the witness stayed green with the refusal
notification removed entirely. Replaced with an agent issuing a human-only command, which is
refused before anything is dispatched and moves no authority. Asserted as a precondition in
the test so it cannot silently regress.

**A cap-dependent assertion.** The refusal test counted `recent_refusals`, which is a window
of 20 — so once the ring is full the length cannot grow, and the test passed alone and
failed in the full suite. It now asserts the newest correlation id changed, which is the
actual claim.

**Two more probes went stale against my own refactor** and reported SABOTAGE MISSED: the
coordinator's `init` line gained `view: 0`, and the `:observe` clause moved to `cursor_of(st)`.
That is four stale probes across two rounds, all from me editing lines a probe was pinned to.

## 6 · Your W.1.1 battery

| Witness | Result |
|---|---|
| successful subscribe retains the complete frame | ✅ |
| `LiveLocal` impossible with `projection == None` | ✅ `invariant_holds()` · one entry point |
| malformed/incomplete snapshot never produces `LiveLocal` | ✅ validated in `acquire` |
| authority push updates projection and cursor together | ✅ whole frame adopted |
| EOF / new incarnation discards before reacquiring | ✅ `discard()` on both paths |
| agent channel opens → newer view, no authority mutation | ✅ BEAM **and** host |
| agent channel closes → same | ✅ BEAM and host |
| a new operator-visible refusal reaches the view | ✅ and it moves no authority |
| topology change advances the view revision | ✅ |
| authority-only change advances **both** | ✅ |
| kill `Ampd.Subscriptions` → cannot stay silently LIVE | ✅ channel closes |
| subscription restart → reacquire → fresh truth | ✅ via W.1's EOF path |
| one denied `preflight` under churn → exactly one refusal | ✅ and `inspect_refusal` too |
| remove stored projection → RED | ✅ host probe 9 |
| remove topology notification → RED | ✅ BEAM probe, three routes |
| remove the view clock → RED | ✅ separate probe |
| remove subscription-death handling → RED | ✅ |
| drive the stream by the authority revision → RED | ✅ host probe 10 |

## 7 · Still no Tauri, and what this round did about that

Unchanged and deliberate: `host/Cargo.toml` is `serde_json` and libc externs. What changed
is that the thing a WebView would need now exists as one value.

Your guidance about a `Channel<CockpitFrame>` rather than generic events, an async command,
a dedicated worker rather than the UI thread, and a microscopic capability surface — that is
the shape `CockpitFrame` was built for: a single ordered stream of whole coherent frames,
produced by a loop that already owns its own blocking socket and condvar. W.2 follows it.

The restore-triggered EOF still cannot be driven from the host, unchanged for the third
round: `advance_lineage/2` is on no channel.

## 8 · Ladder

    C1.1     ├─ F.8.2.5  generation is a fence · authority reacquired         ✓
             ├─ W.1      the cockpit observes one incarnation                 ✓
             └─ W.1.1    LIVE LOCAL holds one live renderable view:
                         · the loop holds the projection, not just its cursor ✓
                         · view revision ≠ authority revision                 ✓
                         · a subscription is a lease, not a past success      ✓
                         · a read that writes is executed exactly once        ✓
                         · the WebView renders it                             ✗
    W.2      Tauri Channel<CockpitFrame> → WebView · REVOKE → capability-scoped
             IPC → human channel → authority transaction → both clocks move
             → one coherent frame → the UI changes because truth changed
    C1.1b    SQLite transactional persistence · durable revision

## Verify

```
cd ampd && mix test --seed 0          # 211 tests
bash tools/sabotage.sh                # 67 falsified · 0 not   (~7m)
cd .. && bash tools/release.sh        # required gates, including both host gates
./host/target/release/super-host verify        # 68 held · 0 failed
bash tools/sabotage-host.sh                    # 10 falsified · 0 not
```

New this round: `Ampd.AuthorityCoordinator.touched/0`, `Ampd.Projection.framed_once/2`,
`CommandSpec`'s `retry:` declaration, the subscription lease in `Ampd.Subscriptions` and
`Ampd.Transport.Connection`, and `CockpitFrame` + `CockpitLoop.projection` in the host.
