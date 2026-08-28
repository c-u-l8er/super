# C1.1 · the three corrections — the channel is a descriptor now

**Artifact: `and-super-rev-f7.zip`. Every gate green.**

You ruled **C1.1 transport core ✓**, `LIVE LOCAL` not yet, and named three things to
close first: the filesystem race, the Peer→subscription asymmetry, and the projection
revision that rewinds. All three are closed. You also called one more shot — one socket,
not two — and specified the demultiplexer and the bounded projection. Those are in too.

Your central finding was right and I had it written in my own source as an admission
rather than a defect: *every process here runs as the same OS user and can `readdir` the
runtime directory.* That sentence should have been a bug report.

---

## 0 · Measured

| | F.6 | F.7 |
|---|---|---|
| conformance vectors | 42 | **42** |
| BEAM tests | 160 | **167**, 0 failures at seed 0 |
| browser assertions | 64 | **64** |
| sabotage falsifiers | 31 · 0 not | **36 · 0 not** |
| host acceptance checks | 16 held | **22 held · 0 failed** |
| socket files created by the runtime | 2 per channel | **zero** |

---

## 1 · The private channel is now actually private

You said the architecture we intended was inherited descriptors, not discoverable paths.
It is:

```
super-host
  ├─ socketpair(AF_UNIX, SOCK_SEQPACKET)
  │     keeps A · spawns ampd with B dup2'd onto fd 3
  │     ampd adopts fd 3 → THE BRIDGE          no path, nothing to race
  │
  └─ per engine:
       socketpair(AF_UNIX, SOCK_STREAM)
         D → ampd over the bridge in an SCM_RIGHTS message labelled "kestrel"
         C → inherited by the engine at spawn; the host closes its copy
```

**There is no socket file anywhere.** `Ampd.Bridge` no longer creates, publishes, or
listens for anything — it *adopts* descriptors. `bridge.sock` is gone, and with it the
root-capability race you identified: whoever won that one could have asked for the human
control channel and for an agent channel named anything.

Two design notes worth your ruling:

* **`SOCK_SEQPACKET` for the bridge**, not `SOCK_STREAM`. It carries descriptors, and a
  descriptor belongs to exactly one message. Sequenced packets keep that true without a
  framing layer that could ever associate a descriptor with the wrong command.

* **A bind with no descriptor attached is refused.** There is no shape of
  `bridge-command@1` that names an identity without handing over the channel it names, so
  "possession is the capability" holds on the host's side too. Falsified by the battery:
  `naming an identity without handing over its channel is refused`, and
  `a descriptor number in the payload is not a descriptor`.

`fdpass.rs` declares the four syscalls by hand rather than pulling a crate — the whole
trust model rests on them and they should be readable in full.

The Elixir side gained one honest exception: `Ampd.Transport.socketpair/1`, which binds,
connects, accepts and unlinks so tests can build the same shape without a Rust process.
It is the only place left in the tree that touches a socket path, it is not how the
runtime obtains channels, and there is a probe that leaks it deliberately to prove the
search that looks for leaks actually finds them.

### It cost one more real bug

Dropping the control channel and immediately asking for a new one was refused
`control-channel-already-claimed` against a descriptor whose only reader had gone.

`close(2)` is not enough. With another thread blocked in `read(2)` on that descriptor,
closing it removes this process's table entry but leaves the underlying open file
description alive until the syscall returns — so **the peer never sees EOF**. It needs
`shutdown(2)` first, which ends the connection itself rather than this process's
reference to it. `fdpass::release_fd` does both, in that order, and says why.

---

## 2 · A dead Peer no longer leaks projections

Reproduced exactly as you described, before fixing:

```
a COMMAND on the old socket → unknown-peer
an unrelated mutation       → the same socket received
                              agent-projection@1 for actor "kestrel"
```

Invalid for commands and still valid for information flow. Both halves you asked for:

* **`Ampd.Subscriptions` stores `peer_id`, not the record**, and re-resolves before every
  push. If it cannot resolve, the subscriber is *dropped*, not served from a cached name.
  Subscribing on a binding that has already gone is refused `unknown-peer` rather than
  quietly registered.
* **The connection monitors `Ampd.Peer`** and closes when it dies. Fail-closed: there is
  nothing to reattach to, and the host must ask for a new channel.

Those two are redundant for the crash case, which is why they get separate falsifiers.
The subscription half is isolated by detaching a binding while `Ampd.Peer` is *healthy* —
nothing tears the connection down, so re-resolution is the only thing that can catch it.

One more ordering bug came out of this: `shutdown` did its bookkeeping before closing the
socket, and the bookkeeping calls into `Ampd.Peer` — the very process that had just died.
The `GenServer.call` exited the caller and left the socket open, held by a dead connection
process. The close is unconditional and first now, and everything after it is best-effort.

---

## 3 · `projection_epoch`

Reproduced:

```
world_generation 1 · revision 7
AuthorityCoordinator killed and restarted
world_generation 1 · revision 0
```

Your tuple, implemented, with the client rule stated in `Ampd.Projection.continuity/0`:

```
same generation, same epoch   → revisions are comparable
same generation, new epoch    → discard the projection and resnapshot
different generation          → discard everything
```

All three fields travel together on **every** frame that carries any of them — `hello@1`,
`reply@1`, `projection-snapshot@1`, and every history page — because none of them means
anything alone. There is a test asserting exactly that, per frame kind.

`ops/0`'s docstring said "this world"; it counts *this incarnation*. Fixed, because the
wrong word there is what made the bug invisible.

Durable revision stays C1.1b's, as you said.

---

## 4 · One socket, and the demultiplexer you specified

Built to your shape:

```
              ONE SOCKET
                  │
             reader thread
                  │
       ┌──────────┼──────────┐
   replies     projections   hello
 by request ID  latest wins  once
```

Three routes, not two — `hello@1` is unprompted, arrives exactly once, and is neither a
reply nor a projection. Pretending it was one of the other two is how you get a client
that treats its own greeting as an answer.

**Projections supersede rather than queue**, as you said: a newer snapshot makes an older
one worthless, so the 256-entry FIFO is gone. It was worse than wasteful — under load it
dropped the *newest*. `projection_after(revision, timeout)` is the wait primitive, which
maps onto a Tauri event or a `watch` channel without changing shape.

One thing I added: **replies that correlate to no waiter are kept**, not dropped. A
frame-level refusal cannot echo a `client_request_id` — the frame it refused was never
decoded — and "the runtime said nothing" and "the runtime refused" are not the same fact.

---

## 5 · The bounded projection

You were right that this is not about corrupt data. Receipts and terminal effects grow
without limit in a perfectly healthy world, so `operator-projection@1` was on a path to
exceeding one frame by ordinary use.

`operator-projection@2` / `agent-projection@2`:

```
live, in full     grants · pending grant requests · pending approvals
                  in-flight effects · reconcile queue · peers · channels
                  seals · recent refusals · world · runtime

windowed          receipts:              %{recent: [...50], total: 18_421,
                  effects_history:         next_cursor: "rcpt-18191", more: true}
                  grant_requests_history:
```

Plus `list_receipts(cursor, limit)` and `list_effect_history(cursor, limit)`, newest
first, each page carrying the continuity triple so pages from either side of a restore
cannot be stitched into a history that never happened. An agent pages only its own — the
same filter the projections apply, reused rather than restated.

`grant_requests_history` is mine rather than yours, and I want to flag it. Resolved
requests are *provenance* — "Kestrel asked, the person said no" is the distinction this
whole system exists to keep — but they also grow without a human ever acting, because an
agent can ask as often as it likes. So they leave the live queue and stay in a window.

The falsifier builds a healthy world with 140 receipts × 4 KB — over half a megabyte,
comfortably past the 256 KB frame — and asserts the projection is still usable, the window
says what it is a window onto, and two pages neither overlap nor repeat.

---

## 6 · The naming correction

`open_control_channel` said "succeeds once per world". You are right that this reads as
though reopening should be forbidden while the product requires it. The invariant is about
concurrency, not lifetime:

> **At most one human control channel is active at a time.**

Changed in `Ampd.Peer`, `Ampd.Bridge`, the refusal's own `operator_detail`, and the
battery's wording. The refusal is `retryable: true` now, which it always should have been.

---

## 7 · Your falsifier table

| Falsifier | State |
|---|---|
| Same-UID process discovers runtime directory | ✅ **nothing to discover** — no socket file exists; the search that looks for one is itself falsified |
| Same-UID process races an agent startup | ✅ **unraceable** — a descriptor cannot be opened by name |
| Peer dies while subscribed | ✅ falsified — no further private projection |
| Peer dies | ✅ falsified — identity-bearing connection closes |
| AuthorityCoordinator dies | ✅ falsified — epoch changes |
| Revision resets within new epoch | ✅ falsified — same generation, new epoch, revision lower |
| Many legitimate receipts exceed one frame | ✅ falsified — 140 × 4 KB, projection usable, history paged |
| Reply and push interleave | ✅ falsified — correlation, in the host |
| Burst of projections | ✅ falsified — newest survives |
| Close/reopen control UI | ✅ falsified — one active at a time, same durable world |

Ten of ten.

---

## 8 · The harness caught itself twice more

The compile check I added last round earned its keep again, and so did the
`SABOTAGE MISSED` path:

* **`a channel accepts once and its socket is retired`** — the listener it probed no
  longer exists. Reported as proving nothing rather than passing.
* **`a leaked socket path is detected`** — I wrote this probe, it reported
  `NOT A FALSIFIER`, and it was right twice over. First because my Elixir scan only looked
  at top-level entries and never descended into a directory; then, after I fixed that,
  because I had added `File.rm_rf(dir)` and the probe was only disabling `File.rm(path)`.
  A stale probe against improved code.

The first of those found a genuine hole in a **test**: the scan was not looking where a
leak would actually be. It also matched any `.sock` on the box, including an unrelated
`claude-cowork-vm.sock`, which is how you get a test somebody disables.

And then running the four gates *in order* found a third thing, which is the kind I like
least because it only appears in sequence. The leak probe disables `socketpair/1`'s
cleanup and runs the whole transport suite, so it leaves thirty leaked pairs on disk — and
the **next** gate, the host battery's search for a path into a channel, correctly found
them and failed. Gate 3 was reporting gate 2's litter as a defect in the runtime.

A harness that leaves behind exactly what the next harness looks for is worse than no
harness, because the failure is real, reproducible, and about nothing. `probe()` cleans up
after itself now, and the four gates pass in sequence rather than only in isolation.

---

## 9 · Where I think this leaves the badge

I agree with your framing and not quite your sequence. You put `LIVE LOCAL` after the
Tauri shell; I would put the *transport* claim here and the *product* claim there:

```
real ampd authority                             ✓
real OS transport                               ✓
runtime-bound agent identity                    ✓
human control is actually private               ✓  descriptors, not paths
stale identity cannot keep receiving anything   ✓
projection continuity has restart semantics     ✓
a healthy world's projection stays usable       ✓
────────────────────────────────────────────────
something renders it                            ✗  ← the whole remainder
```

Every line you named is closed. What is left is not a security or correctness question
any more; it is a window. So my read is:

> **C1.1 complete. `LIVE LOCAL` is one UI away, and the UI is integration work.**

If you still want the badge to wait for the shell, I have no objection — it is your call
and the difference is one word. But I do not think there is another correctness round
between here and there, and I would rather be told I am wrong about that now than find out
by shipping.

---

## 10 · Open

1. **Is the descriptor model the endpoint?** You said `Ampd.Bridge` is the right semantic
   boundary and the path-based realization was not the right physical one. It is now
   `socketpair` + `SCM_RIGHTS`. Inside the BEAM, code can still call `adopt_channel/3` and
   bind a descriptor to any actor — I believe that is irreducible, because the runtime *is*
   the thing trusted to name identities. Confirm and I will stop here.

2. **`SOCK_SEQPACKET` availability.** It is Linux and the BSDs. macOS `socketpair` does not
   support it. When Super ships to macOS the bridge needs `SOCK_STREAM` plus explicit
   framing, and a descriptor would then need to be pinned to a frame rather than to a
   packet. I would rather solve that when there is a macOS target than guess now.

3. **`grant_requests_history`** — my call, §5. If resolved requests should stay live
   because an operator reads them as a queue rather than as history, say so and I will
   move them back and bound them some other way.

4. **Tauri.** Still not built, and for the same reason: everything C1.1 claims is provable
   by running one command, and none of it needs a window. The host is a plain binary that
   drives the whole protocol; the WebView is a shell over exactly this.

---

## 11 · Ladder

    C1.1.0   projection boundary correctness                   ✓
    C1.1.1   identity + projection                             ✓
    C1.1.2   the transport's acceptance battery                ✓
    C1.1     Tauri Rust host + private transport               ✓
             ├─ F.6  CommandSpec · exact-set linearized ·
             │       frame and per-field limits · duration at
             │       creation · pack digest · push projections
             └─ F.7  inherited descriptors, no filesystem ·
                     identity lifetime · projection epoch ·
                     demultiplexer · bounded projection
             ── remaining: the WebView itself
    C1.1b    SQLite transactional persistence · durable revision
    C1.2     FabricProvider.Tailscale

---

## Verify

```
cd ampd && mix test                    # 167 tests
bash tools/sabotage.sh                 # 36 falsified · 0 not
cd .. && bash tools/release.sh         # full gate chain → and-super-rev-f7.zip
cargo build --release --manifest-path host/Cargo.toml
./host/target/release/super-host verify    # 22 held · 0 failed
```

The last one creates a socketpair, spawns the runtime holding one end, passes agent
channels by descriptor, and drives the battery from a separate OS process. It is the only
gate that does not run inside the BEAM it is testing — and the only one that can prove
there is nothing on the filesystem to open.
