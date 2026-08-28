# C1.1 · F.8 — every descriptor is close-on-exec, and evidence paging is lossless

**Artifact: `and-super-rev-f8.zip`. Every gate green.**

You found a critical defect and were right about all five. The `CLOEXEC` one is the most
important finding anyone has made on this project, because it broke a claim I had just
finished making — and the comment that let it through was mine:

> Rust sets `CLOEXEC` on everything it creates.

True of Rust's APIs. `fdpass.rs` does not use one; it calls `libc::socketpair` directly.

---

## 0 · Measured

| | F.7 | F.8 |
|---|---|---|
| conformance vectors | 42 | **42** |
| BEAM tests | 167 | **170**, 0 failures at seed 0 and across 6 random seeds |
| browser assertions | 64 | **64** |
| sabotage falsifiers | 36 · 0 not | **39 · 0 not** |
| host acceptance checks | 22 held | **31 held · 0 failed** |

---

## 1 · The descriptor leak — reproduced, then falsified

Your reasoning was exact, so I went straight to a real child process rather than a
`fcntl` probe. The host holds the bridge, the human control channel, and one descriptor
per engine; it spawns a child the way it spawns an engine, one `dup2` onto fd 3, and the
child prints `readlink` of everything in `/proc/self/fd`.

With `SOCK_CLOEXEC` removed — which is what F.7 shipped:

```
inherited 4 sockets:
  3 socket:[62766496]     ← its own channel
  4 socket:[62766494]     ← NOT ITS OWN
  5 socket:[62777404]     ← NOT ITS OWN
  6 socket:[62766496]     ← the pre-dup2 copy of its own
```

Four sockets where there should be one. The two it had no business holding are the other
live channels — **the bridge that mints identities, and the person's socket.** At that
point "an agent cannot issue human commands" was not enforced by possession, because the
agent possessed it.

Fixed as you specified, and stated as the invariant rather than a checklist:

> **Every descriptor is close-on-exec by default. Explicit inheritance is a capability
> transfer.**

* `socketpair(AF_UNIX, ty | SOCK_CLOEXEC, 0, sv)` — both ends, with a `debug_assert`.
* `MSG_CMSG_CLOEXEC` on every `recvmsg`, so a descriptor that *arrives* is close-on-exec
  too. Erlang's `:socket` supports `cmsg_cloexec`, so the same rule holds inside the
  runtime and not only in the host.
* `dup_onto` is the only place inheritance is granted, after `fork` and before `exec`.

The falsifier is the one you asked for and it is now among the most important in the
tree. With the fix in: **exactly one inherited socket, on fd 3.** With it out: four.

I also had to fix my first attempt at the confinement check. `is_cloexec` returned false
for a *closed* descriptor and for an *inheritable* one, which are opposite facts —
`fcntl` fails the same way for both. It reported a leak on descriptors the host had
already released. There is an `FdState` with three values now: `Closed`, `Cloexec`,
`Inheritable`, and the check counts live descriptors so a vacuous pass is visible.

---

## 2 · Concurrent writes — worse than the theory

You called this "likely to appear as soon as Tauri issues multiple commands
concurrently." It appears immediately and catastrophically.

Eight threads, twelve commands each, on one channel. With the writer lock:

```
96 concurrent commands on one socket all get their own reply     held
the channel is still coherent after concurrent writes            held
```

With the lock removed:

```
2/96 returned — the stream interleaved
the channel is still coherent after concurrent writes — null
```

**Two of ninety-six**, and the channel never recovered. A header and a body are two
writes; interleaving them produces a stream the runtime cannot resynchronise from, and it
does not fail loudly — it fails as a hang.

Now: **one reader, one writer, many logical callers**, on every channel. The bridge is
serialized too — it carries send/recv transactions with no correlation ids, so two
concurrent channel creations would read each other's replies. Channel creation is rare; a
lock is the right size of answer.

---

## 3 · The cursor now applies the rule the runtime sends

You were right that the epoch existed in the protocol and not in the client.
`projection_after(after: u64)` compared revisions, so after a coordinator restart the host
would have ignored every projection of the live world until the new epoch's revision
climbed past the old one's.

`ProjectionCursor { world_generation, projection_epoch, revision }`, with your rule in
`superseded_by`:

```
different generation          → accept, and reset
same generation, new epoch    → accept, and reset
same generation and epoch     → accept only a higher revision
```

Four falsifiers, one per branch — including the one that matters: *a new epoch supersedes,
however low its revision.* It lives in the dispatcher, so the WebView never reinvents
continuity semantics.

---

## 4 · The one-record pagination hole

Reproduced over 120 synthetic records before fixing:

```
page 1  rcpt-0120 … rcpt-0071   next_cursor rcpt-0070
page 2  rcpt-0069 … rcpt-0020   next_cursor rcpt-0019
page 3  rcpt-0018 … rcpt-0001

total 120 · returned 118 · skipped ["rcpt-0070", "rcpt-0019"]
```

Your diagnosis was exact and I took your preferred fix: **cursor is the last item already
seen; a page returns entries strictly older.** The projection *window* had the same
off-by-one and now uses the same rule — the two disagreeing was the actual defect, and
fixing only the page would have left the window's cursor dropping a record on the first
follow-up.

The part I want to flag, because it is the more useful lesson: **my test asserted the
pages did not overlap and did not repeat, and both were true while records were being
dropped.** Not-overlapping and not-repeating are the easy half. The falsifier now walks
`next_cursor` to exhaustion at three page sizes, including one that divides the total
exactly, and asserts:

> concatenating every page equals the history exactly once

Evidence paging is lossless or it is not evidence.

---

## 5 · The agent projection is bounded now too

You caught that `agent-projection@2` still carried resolved requests, so an agent could
grow its own projection past the frame by request/resolve cycles — the healthy-world
failure the windows exist to remove, left in **the one projection an untrusted party
controls the size of.**

Symmetric now: `grant_requests` pending only, `grant_requests_history` windowed. And
because every window hands out a cursor, `list_grant_requests` exists to follow it — a
cursor with no command to give it to is a promise the protocol does not keep. The operator
had that dangling too.

And yes: **resolved grant requests are history, not live queue state.** Applied to both.

---

## 6 · Two things running it found that you did not name

**My test client had the F.6 host's bug.** After `subscribe`, every `call` could read a
push instead of its reply — the same "the next frame is my answer" assumption, in the
harness this time. It showed up as intermittent failures across random seeds rather than
as a wrong answer, which is how a test that reads the wrong frame usually presents. The
test client correlates on `client_request_id` and stashes pushes now, exactly as the Rust
dispatcher does.

I am recording it because it is the second time this assumption has cost something, and
the first time it produced a check that passed for the wrong reason. **A full-duplex
channel needs demultiplexing in every client, including the ones that are only tests.**

**Subscriptions did not drain between tests.** `Bridge.reset/0` sends `:stop` and each
connection tears down in its own process, concurrently with the next test starting — so a
test asserting "one subscriber" could see the previous test's still draining. The setup
waits for quiet rather than assuming it.

---

## 7 · Your table

| Finding | State |
|---|---|
| raw socketpairs lack `FD_CLOEXEC`; capabilities leak across `exec` | ✅ closed · **falsified with a real child process** |
| concurrent Rust writes can interleave frames | ✅ closed · falsified at 2/96 |
| Rust projection consumer ignores epoch/generation | ✅ closed · four branch falsifiers |
| agent grant-request history unbounded | ✅ closed · symmetric with the operator |
| history cursor skips one record per page | ✅ closed · losslessness falsified |

Plus the confinement family you asked for:

```
DESCRIPTOR CONFINEMENT
  a spawned engine inherits exactly one channel, and no other      held
  the inherited descriptor is the one it was given, on fd 3        held
  every descriptor the host still holds is close-on-exec           held
```

---

## 8 · Open

1. **`BridgeTransport` as a named interface.** I have not extracted it. The law you stated
   — *actor label and descriptor belong to one authenticated bridge message* — is now
   written where the Linux realization lives, and `SEQPACKET` is described as a clean
   realization of it rather than as the law. I would rather extract the trait when there
   is a second implementation to shape it, than guess its edges from one.

2. **The badge.** I accept your ruling and I think you have the better argument: the badge
   is a product claim, and until the WebView is rendering real projections the thing on
   screen is a simulated UI. `LIVE LOCAL` waits for the shell.

3. **Anything else before the shell?** Two rounds running, review has found real defects
   in code I had just declared finished — the descriptor leak especially. If there is
   another pass you want on this transport before I build a UI against it, now is cheaper
   than after. Otherwise my next round is the Tauri integration against exactly this host.

---

## 9 · Ladder

    C1.1     Tauri Rust host + private transport
             ├─ F.6  CommandSpec · exact-set linearized · frame and
             │       per-field limits · duration at creation · pack
             │       digest · push projections
             ├─ F.7  inherited descriptors · identity lifetime ·
             │       projection epoch · demultiplexer · bounded projection
             └─ F.8  CLOEXEC confinement · serialized writer ·
                     continuity cursor · lossless paging ·
                     symmetric agent bounds                        ✓
             ── remaining: the WebView
    C1.1b    SQLite transactional persistence · durable revision
    C1.2     FabricProvider.Tailscale

---

## Verify

```
cd ampd && mix test                    # 170 tests
bash tools/sabotage.sh                 # 39 falsified · 0 not
cd .. && bash tools/release.sh         # full gate chain → and-super-rev-f8.zip
cargo build --release --manifest-path host/Cargo.toml
./host/target/release/super-host verify    # 31 held · 0 failed
```

The last one spawns a child and reads `/proc/self/fd` to prove descriptor confinement,
runs 96 concurrent commands down one socket, and drives the acceptance battery from a
separate OS process. It is the only gate that can prove any of those three.
