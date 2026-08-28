# F.8.2.3 — refusal is terminal, and no channel outlives its world

**Artifact: `and-super-rev-f823.zip`. Every gate green.**

Both findings are real, both reproduce, both are closed. The second one is the most
product-relevant defect any of these rounds has turned up, and it had nothing to do with
descriptors.

```
1 · a startup refusal whose cleanup stalls
      adopt returned after 1003 ms -> :refused "control-channel-already-claimed"
      socket fd 26 at the moment of refusal -> :inheritable   (want :closed)
      socket fd 26 1.5 s later              -> :inheritable

2 · a production world reset, with channels open
      before reset: bridge lists 2 · peers 2
      after Ampd.Bootstrap.reset_world!():
        bridge lists            -> 2 channel(s)
        agent socket fd 28      -> :inheritable
        human socket fd 30      -> :inheritable
        can the person take a control channel in the NEW world? -> false
        REFUSED: control-channel-already-claimed
```

After:

```
1 · adopt returned after 2 ms · socket :closed at the moment of refusal
2 · bridge 0 · peers 0 · both sockets :closed · subscriptions 0
    can the person take a control channel in the NEW world? -> true
```

---

## 0 · Measured

| | F.8.2.2 | F.8.2.3 |
|---|---|---|
| conformance vectors | 42 | **42** |
| BEAM tests | 180 | **182**, 0 failures at seed 0 |
| browser assertions | 64 | **64** |
| BEAM sabotage falsifiers | 44 · 0 not | **48 · 0 not** |
| host acceptance checks | 47 held | **47 held · 0 failed** |
| host sabotage falsifiers | 6 · 0 not | **6 · 0 not** |

---

## 1 · Finding 1, and I took the simplification

Reaching it needed the shape you described: hold `Ampd.Peer`'s control claim so the bridge
still believes the channel is free and the refusal happens one layer in, then fill the
socket's send buffer so nobody is reading. `socket:send/2` is the infinity form; the
connection stalls; the parent's flat one-second branch fires, demonitors, and returns
`{:refused, _}` **without rolling back**. 1003 ms, socket open, still open a second and a
half later — the timed-out-but-still-starting state the previous round said it had removed.

Your simplification is right and I took it whole: **a channel that was refused never became
a channel.** There is no reader on the other end by construction, and the refusal reaches
whoever asked by the route they asked on — `bridge-reply@1` for the host, the return value
of `adopt_channel/3` inside the BEAM. So the frame is gone, and with it the only thing in
that path that could block.

The escape is gone too, and in the way that matters more than removing the write: `settle/5`
now **always rolls back**, and shares the startup deadline rather than inventing a second
one. The bounded wait after the kill is a belt rather than a mechanism — `:kill` cannot be
trapped, so the process is gone — and if it expired it would no longer take the channel
with it.

## 2 · Finding 2 is the one I would not have found

`do_reset_world!/0` reset `Ampd.Peer` and never `Ampd.Bridge`, under a comment that is
already the argument for doing both: *every open channel was bound to the world being
destroyed*. So the fail-closed half worked — old handles stopped resolving — and the
liveness half did not: the bridge went on listing the old channels with `control_open`
still true, and refused the person a control channel **in the world they had just reset**.

> World generation changed; capability generation did not.

Fixed in your order, and the order is load-bearing: `Bridge.reset/0` first, so identities
are detached by the table that minted them, then `Peer.reset/0` and its new epoch, then the
stores.

And `Bridge.reset/0` is a barrier now rather than a broadcast. It demonitored everything —
dropping the backstop the previous round existed to build — then sent `:stop` and returned
without proving anything had stopped. It terminates and disposes in its own process before
replying. The graceful `:stop` is not available and the reason is Finding 1: `:stop` ends
in `Wire.send_frame/2`, so one client that is not reading could hold a world reset open
indefinitely. Closing the socket delivers EOF, which is the honest signal for a channel
whose world no longer exists.

**The test asserts this with no polling.** `settled/3` would have passed against the
fire-and-forget version too — the sockets do close eventually — so it measures nothing
about a barrier. Asserting `NativeFd.state(fd) == :closed` on the line after
`reset_world!/0` returns is the claim.

## 3 · The harness tried to corrupt the tree, and that is the finding I owe you

Extending `probe` to take several `(expression, file)` pairs — which I did last round to
fix the redundant-route problem — had a bug I hit immediately: the world-reset probe
targets `bridge.ex` twice, and the loop backed the file up once per pair. The second copy
captured the file **as the first sabotage had left it**, so the restore wrote that sabotage
back into the source permanently. It did exactly that to `Ampd.Bridge`, and the only reason
I caught it is that the duplicate `mv` failed loudly afterwards.

Repaired, and the loop now backs a file up once however many expressions target it. Worth
saying plainly: a verification harness that can silently modify the source it is verifying
is a worse defect than anything in the list it produces, and this one shipped for exactly
one round because I added the capability and the first probe to use it in the same change.

## 4 · Two probes that were not probes, and one that became one

`a world reset does not complete until its channels are gone` came back NOT A FALSIFIER on
the first attempt — correctly, because the test polled. Making the assertion immediate is
what turned the property into something a sabotage can break.

The other three falsify directly: disabling `settle/5`'s rollback, restoring the wire
refusal frame (which does not leak — it *stalls*, and the test's elapsed bound catches it),
and removing `Bridge.reset/0` from the bootstrap sequence.

## 5 · Your table

| Finding | State |
|---|---|
| ordinary bind-refusal: one-second escape | ✅ closed · rollback unconditional · shares the deadline |
| refusal frame on an uncommitted channel | ✅ removed · no reader exists by construction |
| world reset → channel invalidation | ✅ wired · `Bridge.reset/0` before `Peer.reset/0` |
| world reset completion barrier | ✅ synchronous · asserted with no polling |
| stale claim blocks the replacement channel | ✅ closed · the measured product bug |

## 6 · Where that leaves the transport

Descriptor ownership, refusal ownership, startup ownership, process-death ownership, and
now world-generation ownership. Every one of the five was found the same way — by someone
reading the source and asking who disposes of a thing — and every one was reproduced before
it was fixed.

I am not going to write "closed". What I will write is what has been true at each of the
last five rounds: **nothing measured and not fixed, and the next unmeasured edge is one we
have not thought of yet.** On your ruling that we have now traversed the ownership space,
I agree, and the WebView is the right next thing.

Your `channel lifetime ⊆ world-generation lifetime` note — making the generation explicit
in channel metadata — I have not built. It is the right idea and it is a design decision
rather than a closure, so I have left it for the round that wants it. A capability
belonging to an incarnation of a world rather than to an actor is a change to what a
channel *is*, not a repair.

Carried and unchanged: `app-prototype.html`'s remote fonts (accepted for the production
WebView), engine confinement, and the Rust child-process falsifier for `ensure_std_fds`.

## 7 · Ladder

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
             └─ F.8.2.3  refusal is terminal · no channel outlives its world   ✓
             ── remaining: the WebView
    C1.1b    SQLite transactional persistence · durable revision
    C1.2     FabricProvider.Tailscale

## Verify

```
cd ampd && mix test                    # 182 tests, seed 0
bash tools/sabotage.sh                 # 48 falsified · 0 not   (~5m)
cd .. && bash tools/release.sh         # required gates, including both host gates
./host/target/release/super-host verify        # 47 held · 0 failed
bash tools/sabotage-host.sh                    # 6 falsified · 0 not
```
