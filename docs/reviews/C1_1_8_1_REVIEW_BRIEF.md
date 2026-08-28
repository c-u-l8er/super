# F.8.1 — the world survives quitting, and a descriptor leak neither of us predicted

**Artifact: `and-super-rev-f81.zip`. Every gate green.**

You scoped this exactly right: two closures, no design round, nothing touched that did not
need touching. Both are closed, and building your descriptor-ownership measurement found a
third thing — a real leak, in my code, that neither of us had.

---

## 0 · Measured

| | F.8 | F.8.1 |
|---|---|---|
| conformance vectors | 42 | **42** |
| BEAM tests | 170 | **171**, 0 failures at seed 0 |
| browser assertions | 64 | **64** |
| sabotage falsifiers | 39 · 0 not | **39 · 0 not** |
| host acceptance checks | 31 held | **38 held · 0 failed** |

---

## 1 · The world no longer dies with the program

You were right, and it was worse than a configuration mistake — it was a **verification
rule being used as a production rule.** `Runtime::start` made a directory named for the pid
and the clock, pointed `AMPD_DATA_DIR` at it, and `shutdown` removed it. The isolation was
correct for a battery that must not inherit state, and exactly wrong for a product whose
whole claim is that the world is durable.

Split, as you specified:

```
WorldDir::Ephemeral    a battery's world · unique · destroyed on shutdown
WorldDir::Persistent   $XDG_STATE_HOME/super/worlds/<name> · 0700 · never deleted here
```

State, not cache and not runtime: a world is neither reconstructible nor ephemeral.

**And the acceptance check is now the one you described**, not the weak one. It starts host
A, revokes a grant, exits the way a user quitting the app does, starts a *brand-new* host,
and asserts the same `installation_id` and that the revocation survived.

Falsified by restoring F.8's behaviour:

```
FAILED  quitting the host does not delete the world
          /tmp/super-verify-3101143/durable is gone
FAILED  a new host reaches the same world, not a new one
          {"generation":1,"installation_id":"w-30b160c88a9bcb0d"}
        → {"generation":1,"installation_id":"w-9b2d797de132f4c8"}
```

A different world, silently, on every launch.

**One active owner per local world**, as you asked: an advisory `flock` on `world.lock`,
held on the open file description for the host's lifetime, taken before anything opens a
store. A second host is refused `world-already-open` rather than left to whichever process
writes last. Falsified by disabling the lock: *two hosts opened the same world.*

---

## 2 · `cmsg_cloexec` — and an honest narrowing of the claim

You were right that the shipped code did not do what the brief said. `recvmsg/1` is
`recvmsg` with an empty flag list; it is `recvmsg(sock, [:cmsg_cloexec])` now.

But I measured the consequence before claiming one, and it does not reproduce here. A
process the BEAM spawns sees **zero** sockets: `erl_child_setup` closes every descriptor
above 2 before `exec`. So on this OTP the runtime side was never the vulnerability its Rust
counterpart was.

That makes your mirror-image test an **invariant check, not a falsifier**, and it is
labelled one — it passes whether or not our measures are in place, so counting it would be
claiming evidence this round does not have. It asserts the property holds; it does not
assert that our code is what makes it hold. The flag stays because the rule should be
enforced where the runtime controls it, rather than resting on a property of the VM's spawn
path that nothing here asserts.

---

## 3 · The descriptor leak, which is mine

Your `dup => true` reasoning was right, and following it produced a measurement that
surprised me. Counted against `/proc/<ampd>/fd` across real `SCM_RIGHTS` binds:

```
dup: true     10 channels → +18 sockets · 10 reclaimed on close · 8 leaked
dup: false    10 channels → +10 sockets ·  0 reclaimed on close · 10 leaked
```

So I isolated it, and the mechanism is this:

```
:socket.close/1 on a dup:false adoption returns :ok
and does NOT close(2) the descriptor.
```

Proved directly against an fd whose only reference was the handle under test: still live
after `close` returned `:ok`; closed only when the *owning* handle was closed. **OTP will
not close a descriptor it did not create**, and there is no Erlang call that will.

Which means neither setting avoids the leak — both end at one descriptor per closed
channel. `dup: false` is strictly better and stays: half the descriptors while live, the
same residue after. Two checks assert what is actually true rather than what I would like
to be:

* a closed channel **is** torn down — the bridge stops listing it, the peer detaches, the
  subscription drops;
* the residual cost is **bounded by channels ever opened**, not by traffic.

I did not paper over this and I am not claiming it is fine. It is a bounded leak with an
identified cause, and it is open question 1.

While measuring it I also found and fixed an ordering bug of my own: `shutdown` closed the
socket before killing the reader, and `:socket.close/1` on a socket another process is
blocked reading defers. The reader dies first now.

---

## 4 · Your table

| Finding | State |
|---|---|
| BEAM receives descriptors without `cmsg_cloexec` | ✅ closed · consequence measured and narrowed |
| received raw fd duplicated and left open | ✅ halved · **residual leak measured and named, §3** |
| BEAM-spawned child inherits authority descriptors | ✅ does not occur · invariant check, not falsifier |
| clean exit deletes the world | ✅ closed · falsified |
| crash orphans a world the next host ignores | ✅ closed · stable path, same world |
| two hosts could open one world | ✅ closed · advisory lock, falsified |

---

## 5 · Open

1. **The residual descriptor.** One per closed channel, in the runtime, unreclaimable from
   Erlang. The options I can see: a minimal NIF or port program that calls `close(2)`; or
   `dup: true` plus handing the original back to the host to close, which is baroque and I
   do not like it. For a desktop app opening a channel per engine per session this is
   small, and I would rather you ruled whether it blocks the badge than have me guess. It
   is the only thing I know of in the transport that is measured-and-not-fixed.

2. **`BridgeTransport`.** Not extracted, per your ruling. The law is written where the
   Linux realization lives.

3. **The badge as a projection.** I like it and have not built it. On your sketch —
   `healthy + control channel + world loaded + projection received = LIVE LOCAL`, degrading
   to `RECONNECTING` / `SEALED` / `OFFLINE` — every one of those facts is already in
   `runtime-status@1` and the continuity triple, so the badge would be derived from the
   projection rather than asserted beside it. That is the Tauri round's first commit.

---

## 6 · Ladder

    C1.1     Tauri Rust host + private transport
             ├─ F.6    CommandSpec · exact-set linearized · limits · pack digest
             ├─ F.7    inherited descriptors · identity lifetime · epoch ·
             │         demultiplexer · bounded projection
             ├─ F.8    CLOEXEC confinement · serialized writer ·
             │         continuity cursor · lossless paging
             └─ F.8.1  runtime descriptor ownership · durable host world ·
                       one owner per world                            ✓
             ── remaining: the WebView
    C1.1b    SQLite transactional persistence · durable revision
    C1.2     FabricProvider.Tailscale

---

## Verify

```
cd ampd && mix test                    # 171 tests
bash tools/sabotage.sh                 # 39 falsified · 0 not
cd .. && bash tools/release.sh         # full gate chain → and-super-rev-f81.zip
cargo build --release --manifest-path host/Cargo.toml
./host/target/release/super-host verify    # 38 held · 0 failed
./host/target/release/super-host world     # where the durable world lives
```

The host battery now starts a second runtime against a world the first one left behind,
and counts `/proc/<ampd>/fd` across real descriptor handoffs. Neither is reachable from
inside the BEAM.
