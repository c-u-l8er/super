# W.1.2 — the runtime announces its epoch, and the view clock names what it renders

**Artifact: `and-super-rev-w12.zip`. Every gate green.**

Both findings are real and both reproduced on the first attempt. The second one is the more
important of the two and you were right about why: it could not have been fixed by testing
it harder, because the mechanism itself was wrong.

```
                    BEFORE                              AFTER
coordinator killed  pushes: 0                           pushes: 1
                    channel alive · subscribers 1       channel alive · subscribers 1
                    host holds epoch A indefinitely     new epoch announced · NewRuntime

refusal lands       frame cursor view_revision : 2      frame cursor view_revision : 10
during an           frame CONTENT contains it  : true   frame CONTENT contains it  : true
ordered build       view_revision now          : 3      view_revision now          : 10
                    LAGGING                             causal
```

---

## 0 · Measured

| | W.1.1 | W.1.2 |
|---|---|---|
| conformance vectors | 42 | **42** |
| BEAM tests | 211 | **214**, 0 failures at seed 0 |
| browser assertions | 64 | **64** |
| BEAM sabotage falsifiers | 67 · 0 not | **70 · 0 not** |
| host acceptance checks | 68 held · 0 failed | **78 held · 0 failed** |
| host sabotage falsifiers | 10 · 0 not | **12 · 0 not** |

---

## 1 · Classifiable but not observable

Confirmed exactly:

```
held epoch 23186cc1 · view 7
new epoch is now 8ac1c094
pushes after the restart: 0
control channel alive: true · subscribers: 1
STALE — the host would hold epoch 23186cc1 indefinitely
```

`AuthorityCoordinator.init/1` minted a new `projection_epoch` and told nobody. So W.1's
`NewRuntime` test proved the comparison function, and the event it compares was unreachable
— which is the same shape as the bind-vs-submit overclaim in F.8.2.5, one layer up.

The fix is a `handle_continue(:announce, …)`, and it is **only** announcing. Your warning
was the right one to write into the code: closing the channel would be `NewIncarnation`
behaviour, and the entire value of the distinction is that a restart keeps the person's
authority while a world discontinuity does not. The test asserts the channel and the
subscription both survive, so a future fix cannot quietly take that route.

## 2 · The view clock lagged the view, and a cast could not fix it

Confirmed with your witness, unchanged:

```
refusal rf-f6be88d00d39 recorded while the build is blocked inside observe/1
frame cursor view_revision : 2
frame CONTENT contains it  : true
view_revision now          : 3
LAGGING — cursor 2 beside content that belongs to a later view
```

You were right that this is not patchable with another cast, and right about why: mutable
state in process A, an asynchronous *I changed* to process B, and B's number claiming to
version A. The coordinator could not even *process* the cast — it was busy being the thing
that made the frame coherent.

**`Ampd.ViewClock`** is a `:counters` slot in `:persistent_term`. Every projection-visible
mutation advances it **synchronously, inside its own handler**; any reader samples it
without asking anyone. `AuthorityCoordinator.touched/0` no longer involves the coordinator
at all — which also retires the deadlock caveat that forced it to be a cast in the first
place.

### The guarantee, stated exactly

I want to be precise rather than claim more than holds:

> A frame's `view_revision` is sampled **after** its content, so it is always **≥** the
> version of everything in it. Never less.

That direction is the one that matters. A client told `V` about content from `V+1` believes
it has already seen the newer state and skips it — permanent staleness. The reverse is a
conservative label on slightly older content, corrected by the very next tick, because the
tick is what causes the next push.

`observe/1` additionally re-reads the clock either side of the build and rebuilds when it
moved, so the common case is exact equality rather than merely safe. **Exactness cannot be
guaranteed** for state spread across `Ampd.Peer`, `Ampd.Bridge` and `Ampd.RefusalLog`
without a lock over all three held for the length of a projection, and that is a worse trade
than a bounded rebuild. I am stating the bound rather than implying the stronger claim.

## 3 · The cursor cleanup you noticed

`go_live` validated incarnation, epoch, `view_revision` and projection, and not `revision` —
while `CockpitFrame.world` claimed to carry both clocks and `ProjectionCursor::of` turned a
missing revision into `0`. A zero is a number a WebView renders as fact.

`ProjectionCursor::try_of` requires every field or returns nothing, and `go_live` uses it.
Five witnesses, one per field, plus one that a cockpit will not go live on a frame it cannot
fully read.

`of` is kept and documented as the lenient reader for frames whose completeness is already
established — the classification path, where a missing field means "different from what I
hold", which is the safe answer there.

## 4 · One structural change I made to keep a probe honest

The sample point moved onto its own line:

```elixir
cursor = sample_after(st, before)
…
defp sample_after(st, _before), do: cursor_of(st)
```

Not decoration. The claim *"the cursor is sampled after the content"* is a statement about
ordering, and `sed` is line-oriented — there was no single-line sabotage that could restore
the defect. A property whose falsifier cannot be written is a property this harness cannot
check, and I would rather move a line than accept a probe that proves something adjacent.

Similarly, one probe is line-anchored: `if Process.whereis(Ampd.Subscriptions), do:
Ampd.Subscriptions.changed()` appears three times, and only the one inside
`handle_continue(:announce, …)` is the restart announcement. Sabotaging all three would go
red for a much broader reason than the claim.

## 5 · Your W.1.2 battery

| Witness | Result |
|---|---|
| kill the real `AuthorityCoordinator` while LIVE | ✅ a push arrives with no unrelated mutation |
| host sees that frame as `NewRuntime` | ✅ classified and **applied** |
| coordinator restart retains human-control | ✅ asserted on both sides |
| old projection discarded, fresh one adopted | ✅ epoch adopted, world unchanged, view held |
| disable the restart announcement | ✅ **RED** |
| `RefusalLog` changes during an ordered build | ✅ cursor ≥ content, witnessed |
| same for channel topology | ✅ the clock ticks at the source |
| remove/delay the view-clock mechanism | ✅ **RED**, two probes |
| `go_live` requires `revision` too | ✅ and every other cursor field |

**One row I could not do end to end, and it is the third time I have written this
sentence.** A coordinator restart cannot be caused from outside the BEAM — there is no
command for it and there should not be. So the runtime half (the restart announces, the
channel survives) is witnessed in `ampd/test/cockpit_test.exs`, and the host half (that
frame is classified `NewRuntime` and applied without touching the capability) is witnessed
in `super-host verify` by feeding the frame through the real state machine. `CockpitLoop.feed/1`
is the split — it is the half of `turn` that decides what a frame means, and it is what a
Tauri worker will call anyway.

## 6 · Two defects in the harnesses, found by running them

Neither is in the runtime, and both are the class this arc keeps finding — the
instrument being wrong rather than the thing it measures.

**`tools/sabotage-host.sh` could hang forever.** It read the host's output with
`out=$("$HOST" verify 2>&1)`, and a command substitution waits for EOF on the pipe. Probe 11
made the host exit while the `ampd` it had spawned kept running, and that orphan held the
inherited stdout open — so EOF never came. Measured: **1h46m wedged**, with a `.orig` left in
the tree the whole time. Now it reads through a temp file with a 240 s `timeout`, reports
`TIMED OUT` as a failure rather than hanging, and reaps orphaned runtimes between probes.
Same class as the `INT` trap fix in F.8.2.5, and the same argument: a harness that can wedge
or corrupt the source it is testing is a worse defect than anything it can find.

**And probe 11 itself was badly written.** Its sabotage set `self.chan = None`, which makes
the battery's later EOF witness `unwrap()` a `None` and abort the host — so it would have
gone red for a panic rather than for the property, which is the "BROKE THE BUILD" failure
mode this harness already screens for in the BEAM battery and did not screen for here. It
now bumps only the counter the check asserts.

**Three probes went stale against my own refactor**, reported honestly as `SABOTAGE MISSED`
and counted as failures. That is the third consecutive round in which moving a line unpins a
probe — `sed` pinned to source text is structurally fragile against exactly the refactors
these rounds produce. Nothing false shipped, because the harness scores a missed pattern as
a failure rather than a pass, but it is worth naming as a cost.

## 7 · Ladder

    C1.1     ├─ W.1      the cockpit observes one incarnation                  ✓
             ├─ W.1.1    LIVE LOCAL holds one live renderable view             ✓
             └─ W.1.2    the runtime announces its epoch · the view clock
                         names what it renders · cursors fail closed          ✓
             ── remaining: the WebView
    W.2      Tauri Channel<CockpitFrame> → WebView · REVOKE → capability-scoped
             IPC → human channel → authority transaction → both clocks move
             → one coherent frame → the UI changes because truth changed

Still no Tauri dependency, and this is the last round in which that sentence is the right
one. The value a WebView receives now has: a state, two clocks that mean different things,
a projection that the clocks describe, cursor fields that fail closed rather than defaulting,
and a loop that notices every way the runtime can change underneath it — EOF, a new runtime,
a new world.

Scaffolding Tauri next, per your direction, and I will not go back into the runtime unless
the GUI itself exposes a falsifiable defect.

## Verify

```
cd ampd && mix test --seed 0          # 214 tests
bash tools/sabotage.sh                # 70 falsified · 0 not   (~10m)
cd .. && bash tools/release.sh        # required gates, including both host gates
./host/target/release/super-host verify        # 78 held · 0 failed
bash tools/sabotage-host.sh                    # 12 falsified · 0 not
```

New this round: `Ampd.ViewClock`, `AuthorityCoordinator.handle_continue(:announce, …)`,
`ProjectionCursor::try_of`, and `CockpitLoop::feed`.
