# F.8.2.4 — world incarnation, and the one primitive both bugs were missing

**Artifact: `and-super-rev-f824.zip`. Every gate green.**

Both findings are real and both reproduce deterministically. You were also right that they
are one missing concept, and building it collapsed them into a single primitive — which is
the most satisfying result of this whole arc.

```
1 · a command queued behind a world reset
      world A: w-b8cd1743…  gen 1
      queued: reset_world!            (coordinator tx queue = 1)
      queued: kestrel request_grant   (coordinator tx queue = 2)
      after resume:
        world B: w-ceac4f44…  gen 1
        requests in the NEW world -> 1
          LEAKED: actor="kestrel" capability="github.pr.create"
                  reason="stale-world witness"

2 · a factory reset, seen through the continuity triple
      before  w-0d840f34…  gen 1  epoch cf7320ae  rev 3
      after   w-0e2b4559…  gen 1  epoch cf7320ae  rev 4
      a client comparing only the triple sees: SAME WORLD, ordinary advance
```

After:

```
1 · requests in the NEW world -> 0
    the command returned: "The world this channel belongs to no longer exists."
2 · world_incarnation  a1acd5fef2345252 -> b0b2e1e4c6c47a94
    (generation, epoch and revision unchanged in their behaviour)
```

---

## 0 · Measured

| | F.8.2.3 | F.8.2.4 |
|---|---|---|
| conformance vectors | 42 | **42** |
| BEAM tests | 182 | **184**, 0 failures at seed 0 |
| browser assertions | 64 | **64** |
| BEAM sabotage falsifiers | 48 · 0 not | **51 · 0 not** |
| host acceptance checks | 47 held | **48 held · 0 failed** |
| host sabotage falsifiers | 6 · 0 not | **6 · 0 not** |

---

## 1 · The fence, where you said to put it

Captured when the **channel** is bound — `peer` records carry `world_lineage` from
`Ampd.Peer`'s attach and claim — and checked at the **linearization point** inside the
coordinator. Your reasoning for both halves held up: sampling at submission would let a
connection paused between `resolve/1` and its authority call read the world that replaced
its own, and checking anywhere but inside the coordinator races the reset it is trying to
detect.

The plumbing is two chokepoints rather than forty signatures. `Ampd.Control.command/3` is
the only way a peer reaches `Ampd.Authority`, and `Ampd.Authority.tx/1` is the only way
that module reaches the coordinator. One sets the expectation, one reads it. A command
added later cannot forget to carry it — which is the failure mode this entire arc has been
about.

Refusal is `world-incarnation-changed`, your name, for your reason: an operation that was
valid when issued and got overtaken is a different thing from one that never had an
identity, and `unknown-peer` would have said the second.

## 2 · One deliberate narrowing, and the suite is what forced it

You specified `expected_world == Ampd.World.lineage()` — exact equality on the whole
lineage. I implemented that first and `test/lineage_test.exs` went red immediately.

`Ampd.Authority.advance_lineage/2` moves the **generation** on a *restore*: same
installation, same stores, same actors, and **no channels destroyed**. Fencing on
generation would have left every live channel permanently unable to act, with nothing torn
down and nothing told — a worse version of the bug F.8.2.3 closed.

So the fence keys on **installation identity**. The two questions turn out to be different:

* *may this command execute?* — a generation advance does not un-name an actor or destroy
  the store it refers to. Its consequence is that consent from before the discontinuity is
  stale, and that is already enforced per-approval by the intent digest, which is what
  `lineage_test.exs` exists to prove. Fence on the installation.
* *is what I am holding still valid?* — a generation advance invalidates cached content, so
  a client must resnapshot. That is why `world_incarnation` hashes the generation in.

A world is an installation; a generation is a chapter within it. Only one of those can be
replaced by something that never knew this channel. I am flagging this as a deviation from
your spec rather than burying it — if you want the stricter fence, it needs
`advance_lineage/2` to invalidate channels too, and that is a product decision about what a
restore does to open connections.

## 3 · The incarnation, and why it is hashed

`H(installation_id ‖ generation)`, first field of `continuity/0`, and the Rust
`ProjectionCursor` compares it before anything else. Your reasoning for the opaque form
stands: `installation_id` is the stable name of this installation across every world it
ever holds, it is operator-only, and continuity frames go to agents. An agent needs to know
*that* the world changed, never *which* installation it is talking to.

The host battery gained the case the three-field cursor could not see — same generation,
same epoch, higher revision, different world — and it is a falsifier, not decoration.

## 4 · The two smaller items

**The process barrier.** You were right that F.8.2.3 proved the resource barrier and not
the process one. `Bridge.reset/0` now watches each killed connection out via the monitor it
already holds, and drops the monitor after rather than before. Defence in depth, as you
said — and explicitly **not** the fix for Finding 1, which the fence is.

**The harness trap.** `sabotage.sh` now installs an `EXIT INT TERM` trap that restores
every `.orig` before it exits, and says which files it restored. It mutates the tree in
place and always did; the previous round's corruption was caught only because a duplicate
`mv` happened to fail loudly, and an interrupted run would not have been.

## 5 · Two tests of mine that could not fail

Worth reporting because they are the same defect class as everything else here.

The witness needs the reset and the command *both visibly queued* before the coordinator
resumes. My first wait returned `:ok` whether or not that happened — `Process.sleep/1`
returns `:ok`, so it was the exhausted loop's accumulator as well as the halt value. My
second counted the coordinator's mailbox, which a suspended coordinator also fills with the
`:ops` and `:epoch` calls a connection makes while building its `hello@1` — so it reached
two before either transaction had arrived, resumed early, and the command came back
`unknown-peer` from a world that had already been reset.

Both **passed**, for reasons the test was not measuring. It now waits for
`{:"$gen_call", _, {:tx, _, _}}` specifically, which is the thing the ordering claim is
about.

## 6 · Your table

| Finding | State |
|---|---|
| stale queued work across a reset | ✅ fenced at the linearization point, bind-time expectation |
| fence must not sample at submission | ✅ `world_lineage` on the peer record · probed |
| projection cannot distinguish incarnations | ✅ `world_incarnation` leads the cursor · probed |
| reset process barrier unproven | ✅ each connection watched out before completion |
| sabotage tree restoration on interruption | ✅ `trap … EXIT INT TERM` |
| fence granularity | ⚠️ **narrowed to installation** · §2 · deliberate, and flagged |

## 7 · Where this leaves it

The primitive is the good outcome. `world_incarnation` binds channels, fences authority
transactions, and identifies projection continuity — one concept where there were two
unrelated-looking bugs, which is what a missing abstraction usually looks like from the
outside.

I agree this was the right blocker and I agree it is the last one. The WebView now has a
truth to render that can answer *which world am I looking at* mechanically rather than by
convention, and the vertical slice is unchanged:

    durable world incarnation → Rust host → human-control capability
      → subscription → incarnation-fenced projection → LIVE LOCAL → WebView

then `REVOKE → Tauri command → human channel → authority transition → new projection → UI`.
No shadow state, no optimistic authority mutation.

Carried and unchanged: `app-prototype.html`'s remote fonts, engine confinement, and the
Rust child-process falsifier for `ensure_std_fds`.

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
             └─ F.8.2.4  world incarnation · authority fenced at the
                         linearization point · continuity that is an identity  ✓
             ── remaining: the WebView
    C1.1b    SQLite transactional persistence · durable revision
    C1.2     FabricProvider.Tailscale

## Verify

```
cd ampd && mix test                    # 184 tests, seed 0
bash tools/sabotage.sh                 # 51 falsified · 0 not   (~5m)
cd .. && bash tools/release.sh         # required gates, including both host gates
./host/target/release/super-host verify        # 48 held · 0 failed
bash tools/sabotage-host.sh                    # 6 falsified · 0 not
```
