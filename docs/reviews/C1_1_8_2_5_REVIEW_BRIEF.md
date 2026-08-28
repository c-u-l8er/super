# F.8.2.5 — generation is a fence, and the narrowing was never a product decision

**Artifact: `and-super-rev-f825.zip`. Every gate green.**

Accepted in full. You were right about the semantic, right that the test suite is what
produced the wrong one, and right that the bind-vs-submit claim was not falsified. All
three are now measured rather than argued — including the last one, which turns out to
falsify exactly one of the four fence witnesses and leave the other three green, which is
precisely the reason your objection was correct.

Widening the fence also surfaced a defect F.8.2.4 shipped: a fenced `request_effect`
handed the **agent** a bare `refusal@1` with `operator_detail` still on it. §4.

```
before                                    after
─────────────────────────────────────     ─────────────────────────────────────
installation X · gen 1                    installation X · gen 1
  kestrel channel bound                     kestrel channel bound
advance_lineage("restore")                advance_lineage("restore")
  → installation X · gen 2                  → gen 2 · every channel closed
  → channels untouched                    OLD request_grant
OLD request_grant                           expected gen 1 · current gen 2
  installation fence PASSES                 → world-incarnation-changed
  → executes in gen 2                       → GrantRegistry.requests() == []
  → LEAKED: a request in a world
    that never named a kestrel
```

---

## 0 · Measured

| | F.8.2.4 | F.8.2.5 |
|---|---|---|
| conformance vectors | 42 | **42** |
| BEAM tests | 184 | **194**, 0 failures at seed 0 |
| browser assertions | 64 | **64** |
| BEAM sabotage falsifiers | 51 · 0 not | **56 · 0 not** |
| host acceptance checks | 48 held · 0 failed | **48 held · 0 failed** |
| host sabotage falsifiers | 6 · 0 not | **6 · 0 not** |

---

## 1 · The narrowing was six lines of test, not a product decision

I want to be precise about what F.8.2.4 actually did, because I described it as a
deliberate deviation and that description flattered it.

Implementing the strict fence turns `test/lineage_test.exs` red **twice**, both for the
same reason: the test reaches for a channel bound in generation 1 and uses it in
generation 2. Making it reacquire — `{human2, agent2} = Ampd.attach_pair()` — is six
lines. F.8.2.4 read those two failures as the suite reporting a semantic constraint. They
were the suite asserting, incidentally and without meaning to, that a generation-1 control
channel still speaks in generation 2.

And the codebase already disagreed, in four places:

* `Ampd.World`'s own moduledoc — generation moves only when durable truth is *"wholesale
  replaced or its lineage discontinuously changes"*.
* `Ampd.Peer.reset/0`'s doc — *"resetting or re-initializing a world invalidates every
  open channel, and a channel bound to a world that no longer exists is exactly the stale
  consent problem one layer down."*
* `Ampd.Bridge.reset/0`'s doc — the same sentence.
* `CLOUD_V1.md` §1, which is a **ruled** product sentence, not a direction: *"State moves.
  Authority does not. A restored world on a second machine is not the first machine
  wearing its clothes."*

Three of those are in this runtime's own source. The belief was already held everywhere
except in the one function that advances a generation. F.8.2.4 did not weigh a product
trade-off; it took the path where the diff was smaller and wrote a justification for it.

Your decomposition is the one that holds, and it is now the module's:

```
old consent cannot survive a restore
  does not imply
old work may safely cross one
```

## 2 · Both halves, and why the order is the one you drew inverted

The fence is `installation_id AND generation`. `advance_lineage/2` closes every channel
bound to the ending incarnation — `Ampd.Bridge.reset/0` then `Ampd.Peer.reset/0`, the
latter minting a fresh peer epoch so no old handle *resolves* rather than merely being
absent from a map.

You drew the barrier before the bump. I ended up with the bump first, and there is a
measurement reason rather than a taste reason.

```
1. World.bump_generation!    the discontinuity, made durable
2. Bridge.reset → Peer.reset the channel barrier
3. stale prior consent       the explanation; the digest is the enforcement
```

Everything above runs inside one coordinator transaction, so for *safety* the two orders
are equivalent: nothing else linearizes in between, and a command that resolves a
still-live handle during step 2 cannot execute until after step 3, at which point the
fence refuses it. What differs:

* **Failure atomicity.** `bump_generation!` raises on an unwritable or absent manifest.
  Tearing down every channel and *then* failing is a denial of service in exchange for a
  discontinuity that did not happen. Bumping first means a failed advance changes nothing.
* **It is the only ordering under which your bind-vs-submit falsifier is reachable
  through the supported path.** §3.

Which is a nicer result than it looked: **the fence is what makes bump-first safe, and
bump-first is what makes the fence testable.** The interval between (1) and (2) is not a
hole the fence tolerates — it is the interval the fence exists for, and it is now the
place we can stand to observe it.

`Ampd.Bootstrap.reset_world!/0` keeps the opposite order and the asymmetry is deliberate:
a factory reset *deletes* the manifest, so there is a real interval with no world at all
(`stale_incarnation?(expected, nil)` is `true`, which is the correct answer), and the
bridge can only detach each identity while the table that minted them is still live.

The step you drew as "stores restored" has no implementation to sequence against. There is
still no restore: `Ampd.Control` deliberately keeps `advance_lineage/2` off every channel
until one exists, and `recovery_status` reports without recovering. That is unchanged and
§6 says what it costs.

## 3 · Your test-claim objection was right, and here is the measurement

You said the `world_lineage => nil` probe proves the expectation must *exist*, not that it
is sampled at bind time, because in a witness whose coordinator is suspended the queued
restore has not run when the command is submitted, so both sample points read the same
world.

That is exactly what happens. I built the interposition you asked for and then ran the
submission-time sabotage — `in_world(peer["world_lineage"], …)` → `in_world(Ampd.World.lineage(), …)`
— against each fence witness individually:

| witness | generation removed from fence | sampled at submission |
|---|---|---|
| `request_grant` queued behind a restore | **RED** | green |
| `request_effect` queued behind a restore | **RED** | green |
| human `revoke_grant` queued behind a restore | **RED** | green |
| bridge-interposition witness | **RED** | **RED** |

Three of the four would have certified a submission-time implementation. Your objection
was not a technicality about wording; the probe genuinely could not see the property.

The interposition suspends **`Ampd.Bridge`**, which stops the restore *inside* its
transaction at exactly the state that distinguishes the two sample points:

```
manifest      generation 2      already written, durable
channels      still bound to generation 1
coordinator   blocked inside the advance
```

A command issued there resolves a generation-1 peer while `Ampd.World.lineage()` already
answers generation 2. The test waits on the **manifest file** rather than on a sleep or on
any process that might be blocked, so it is deterministic. `test/incarnation_test.exs:345`,
and it is the fourth row above.

This is the ordering payoff from §2: with the barrier before the bump, the manifest is
still at generation 1 while the bridge is blocked, both samples agree again, and the
falsifier evaporates.

## 4 · What widening the fence found — a dual-disclosure leak in F.8.2.4

`request_effect` is the one command that does not pass through `Ampd.Control.settled/2`.
It returns whatever `Ampd.Gateway.perform/5` gives it, and `perform` receives the
coordinator's refusal through the same `{:refused, _}` tuple it uses for its own
authorization verdicts:

```elixir
case Ampd.Authority.claim_and_consume(...) do
  {:refused, auth} -> auth        # authorization@1 — a verdict, safe to hand to an agent
  ...                             # refusal@1 also arrives here
```

`Ampd.Refusal.project_result/2` only projects a map that carries a `"refusal"` key, so a
bare `refusal@1` sails past the dual-disclosure boundary untouched. Measured, as the agent
received it:

```
%{"schema" => "refusal@1", "code" => "world-incarnation-changed",
  "operator_detail" => %{"current_generation" => 2, "expected_generation" => 1,
                         "discontinuity" => "generation", "installation_changed" => false,
                         "hint" => "…"}}
```

No `allow` key at all, and the topology an agent is never supposed to learn. This shipped
in **F.8.2.4** — the fence was already reachable from `request_effect` through a factory
reset — and its battery could not have seen it, because the only fence witness it had used
`request_grant`, which `settled/2` normalizes.

Fixed at the collision, matching `settled/2` exactly, and falsified. Same round, one
smaller sibling: `approve_effect` announced `surfaced_stale` whether or not the stale mark
landed, so a refused mutation was reported to the person as an expired approval.

## 5 · The sabotage trap, proven rather than reasoned about

You were right that `trap restore_all EXIT INT TERM` does not terminate the script — the
handler returns, and with no `set -e` execution continues with every `.orig` just restored
out from under the running probe. Now:

```bash
trap restore_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
```

Interrupted a live run to check rather than assert it: **exit code 130, `restored
lib/ampd/core.ex` printed, zero `.orig` files left, tree identical.** Isolated
worktree-per-sabotage is still the better answer and is still not this round's.

## 6 · Your battery, and the two rows I cannot close yet

| Witness | Result |
|---|---|
| gen-1 `request_grant` queued behind restore | ✅ `world-incarnation-changed` · `requests() == []` |
| gen-1 `request_effect` queued behind restore | ✅ refused · no receipt, no approval opened |
| gen-1 human revoke queued behind restore | ✅ refused · the grant is still active |
| normal command, same generation | ✅ served — the control case, and it is not decoration |
| remove the generation comparison | ✅ **RED** on all three queued witnesses |
| restore closes the old human channel | ✅ socket, process and claim all gone |
| restore closes the old agent channels | ✅ same, for every bound engine |
| old peer handles unresolved after restore | ✅ and by a **new epoch**, not an emptied map |
| fresh human-control channel after restore | ✅ — the F.8.2.3 failure one level up |
| engine must reacquire its binding | ✅ old handle `unknown-peer`; reattached handle served |
| new `world_incarnation`, same installation | ✅ `continuity/0`, installation unchanged |
| coordinator restart only | ✅ incarnation unchanged, `projection_epoch` moves |
| bind-time vs submission-time | ✅ §3 — a real falsifier now, not a claim |
| **restore, from the host** | ❌ **not constructible** — below |
| **the host reacquires control** | ❌ **not implemented** — below |

The last two, plainly. `advance_lineage/2` is not on any channel, so `super-host verify`
has no way to trigger a restore against a live runtime — a host-side witness needs the
restore *command* first, which needs the restore. And the host's `call` returns
`UnexpectedEof` when its channel closes; there is no reconnect, because there is no event
loop until the WebView. So the barrier's host-visible effect today is "the socket closes
and the next call errors", and *"host reacquires human control"* is a WebView-round
obligation, not something F.8.2.5 delivered. I would rather hand you that than let the
green table imply otherwise — a measurement boundary that stops at the language boundary
is how F.8.1 certified a leak for a whole revision.

## 7 · One primitive, and now it is true

F.8.2.4 claimed `world_incarnation` binds channels, fences authority and identifies
continuity. You correctly said the shipped code did not do that. It does now:

```
WORLD INCARNATION = installation_id + generation
        │
        ├── channel binding      Ampd.Peer records it at attach
        ├── authority fence      compared at the linearization point
        └── projection continuity H(installation ‖ generation), leads the cursor
```

and the hierarchy underneath it:

```
installation_id changes   → a different world installation
generation changes        → a discontinuous incarnation · old channels invalid
projection_epoch changes  → same incarnation, new runtime · resnapshot
revision changes          → ordinary mutation
```

The refusal now carries `"discontinuity" => "installation" | "generation"` in
`operator_detail`, because the remediations differ: a generation advance is this world's
next incarnation and the host reattaches to it; a different installation has nothing to
reattach to.

## 8 · Ladder

    C1.1     Tauri Rust host + private transport
             ├─ F.6      CommandSpec · exact-set linearized · limits · pack digest
             ├─ F.7      inherited descriptors · identity lifetime · epoch ·
             │           demultiplexer · bounded projection
             ├─ F.8      CLOEXEC confinement · serialized writer ·
             │           continuity cursor · lossless paging
             ├─ F.8.1    durable host world · one owner per world              ✓
             ├─ F.8.2    the receiver owns what it receives · zero residue     ✓
             ├─ F.8.2.1  adopt_channel consumes its argument exactly once      ✓
             ├─ F.8.2.2  a channel handoff is a transaction                    ✓
             ├─ F.8.2.3  refusal is terminal · no channel outlives its world   ✓
             ├─ F.8.2.4  world incarnation · authority fenced at the
             │           linearization point · continuity that is an identity  ✓
             └─ F.8.2.5  generation is a fence · authority reacquired after
                         a discontinuity · bind-time sampling falsified        ✓
             ── remaining: the WebView
    C1.1b    SQLite transactional persistence · durable revision
    C1.2     FabricProvider.Tailscale

Carried and unchanged: `app-prototype.html`'s remote fonts, engine confinement, and the
Rust child-process falsifier for `ensure_std_fds`.

I agree this is the last transport-adjacent round, and I agree the restore ladder is the
right truth model for the WebView to render. Starting it.

## Verify

```
cd ampd && mix test --seed 0          # 194 tests
bash tools/sabotage.sh                # 56 falsified · 0 not   (~5m)
cd .. && bash tools/release.sh        # required gates, including both host gates
./host/target/release/super-host verify        # 48 held · 0 failed
bash tools/sabotage-host.sh                    # 6 falsified · 0 not
```

New this round: `ampd/test/incarnation_test.exs` (10 witnesses).
