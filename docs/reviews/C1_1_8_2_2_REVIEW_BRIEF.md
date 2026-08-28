# F.8.2.2 — a channel handoff is a transaction

**Artifact: `and-super-rev-f822.zip`. Every gate green.**

You were right about the sentence and right about the mechanism. `Connection.start/3`
never took ownership of anything: a `:socket` handle is owned by its
`{otp, controlling_process}`, that stayed `Ampd.Bridge`, and I wrote "the connection
process has already taken the socket" about code that does `spawn` with no monitor.

All three of your variants reproduce. I measured them before touching anything:

```
A · connection killed AFTER a successful agent bind
      socket fd 26      -> :inheritable   (want :closed)
      bridge lists         -> 1 channel(s)   (want 0)
      peer still resolves  -> true   (want false)

B · connection killed AFTER taking the HUMAN CONTROL channel
      can the person retake control? -> false
      REFUSED: control-channel-already-claimed

C · Ampd.Peer suspended past the startup deadline
      adopt returned after 5001 ms: :refused "channel-bind-failed"
      peers after the host was told it FAILED ->
        [%{"actor" => "kestrel", "channel" => :agent, ...}]
```

B is not a leak. It is one crash taking the person's authority away and never giving it
back. C is the one you called nastier than a leak, and it is: the host and the world
disagreeing about who is in the world.

---

## 0 · Measured

| | F.8.2.1 | F.8.2.2 |
|---|---|---|
| conformance vectors | 42 | **42** |
| BEAM tests | 176 | **180**, 0 failures at seed 0 |
| browser assertions | 64 | **64** |
| BEAM sabotage falsifiers | 40 · 0 not | **44 · 0 not** |
| host acceptance checks | 47 held | **47 held · 0 failed** |
| host sabotage falsifiers | 6 · 0 not | **6 · 0 not** |

---

## 1 · The law, and where it is enforced

> A channel is either committed to one live connection, or rolled back completely. There
> is no timed-out-but-still-starting state.

I took your architecture: **Bridge owns capabilities; Connection executes them.** It is
what the code already did, and it is the right shape for what Super is becoming — worlds
and authority above transient engine processes rather than inside them.

`Connection.start/3` is now `spawn_monitor` and an `await/5` that ends four ways: READY
commits, REFUSED waits for the child to actually be gone, DOWN rolls back, and the
deadline kills, drains, rolls back, **and only then replies** — your phrase, and it is the
one that matters.

`Ampd.Bridge` keeps `pid → {meta, sock, ref, peer}` and owns the invariant:

```
DOWN(pid) → close the socket · unsubscribe · detach the identity
          · drop the channel · free the human-control claim
```

One removal path, two entrances: `:graceful` when the connection has already cleaned up
after itself, `:died` when nothing has and the bridge is the only thing that will.

## 2 · Two deadlines, ordered rather than equal

You said not to just change one to 6000, and I did not — but the ordering still has to be
stated somewhere, so it is stated in code rather than inherited from a default:

```elixir
@bind_deadline 5_000
@startup_deadline @bind_deadline + 3_000
```

with `@bind_deadline` passed explicitly into `Ampd.Peer.attach_agent/3` and
`claim_control_channel/2`. The child's own deadline fires first by construction, so the
parent's is a backstop for a child that is *stuck* rather than a competitor with a child
that is *slow*. `spawn_monitor` is what makes the backstop rarely needed: a child that
dies for any reason — including its own call timing out — produces DOWN immediately.

## 3 · The part that needed more than a monitor

Rolling back the socket was not enough for case C, and the reason is that
`GenServer.call`'s timeout is the **client's**. The call was still sitting in
`Ampd.Peer`'s mailbox, and `Ampd.Peer` performed it the moment the suspension lifted —
minting an identity for a connection that had been dead for a second and a half.

So `Ampd.Peer` now enforces one rule of its own:

> An identity exists only while the process that asked for it does.

Two halves: a caller already gone gets a refusal instead of a binding, and a caller that
dies later takes its identity with it via a monitor. This is the module's own founding
rule — *a handle cannot outlive the incarnation that minted it* — pushed one level down to
the connection.

The child also reports its `peer_id` to the waiting parent **the moment `bind` returns**,
before `resolve`, before the hello, before anything else that can block. A rollback has to
be able to undo an identity that exists, and the only process that knows it exists is the
one that just created it.

## 4 · Three things I have to report against myself

**One of your five became two, and one of mine was named for a claim it does not make.**
The probe I wrote as "an identity cannot be created for a connection that is already gone"
passes with `Ampd.Peer`'s dead-caller guard disabled — because `Process.monitor/1` on a
dead pid delivers DOWN immediately and the monitor half covers it. The test is renamed to
what it measures, and the guard is documented as **not falsifiable by this battery and not
counted**: it stops the phantom binding existing at all, where the monitor only removes it
one message later, and that window is too narrow to observe from outside. It sits beside
the `Peer` epoch, for the same reason.

**Two more of my probes were bad and the harness caught them.** `spawn_monitor` → `spawn`
+ `Process.monitor` is not a sabotage, it is a refactor — NOT A FALSIFIER, correctly. And
a two-line `sed` pattern cannot match, because `sed` works a line at a time — SABOTAGE
MISSED, correctly. Both are fixed; the second is now a note in the file so the next person
does not spend a round on it.

**This round broke an older falsifier, and that is a finding.** "A closed socket frees the
claim everywhere" stopped falsifying: it disabled `Bridge.channel_closed/1`, and the new
DOWN backstop covered for it. The property still held — the probe had quietly become a
test of one redundant route. `probe` now takes more than one `(expression, file)` pair and
that one disables both. **A redundancy that rescues a sabotage is a probe that has stopped
being evidence**, and it is the failure mode a project adding defence-in-depth should
expect to keep hitting.

## 5 · And one flake, chased rather than reran

The suite failed once in ten on a subscription test, and an intermittent in a harness is
worse than a slow one. It is not this round's code: a push delivered while the
subscription was still legitimately live sits in the socket buffer, and a `recv/2` after
the detach reads it and blames the detach. Reproduced deterministically by emitting one
`Subscriptions.changed/0` between the subscribe and the detach — then it fails every time.
The test now drains before the mint, after which `build/1` answers `:gone` for that id
forever, so anything read is a real violation. Ten consecutive clean runs at seed 0.

## 6 · Your table

| Finding | State |
|---|---|
| `Connection` was described as the socket owner and is not | ✅ corrected · Bridge owns, Connection executes |
| no controlling-process transfer, no monitor | ✅ `spawn_monitor` · Bridge holds the ref |
| two racing five-second deadlines | ✅ ordered · `@bind_deadline` + 3s, both explicit |
| bind-after-refusal | ✅ closed · identity cannot outlive its process |
| abnormal death: socket, channel, identity, control claim | ✅ closed · one DOWN backstop, four undos |
| rollback must precede the reply | ✅ kill · drain · rollback · **then** reply |

## 7 · Open

`super-host verify` is unchanged at 47 held: this defect is above raw-descriptor adoption,
so it is reachable — and therefore falsifiable — from inside the BEAM, which is where the
four new tests and four new probes live.

Carried, unchanged, and still not this round: `app-prototype.html`'s remote fonts
(accepted for the production WebView), engine confinement (Landlock/namespaces/bubblewrap,
its own design round), and your Rust child-process falsifier for `ensure_std_fds` — which
I agree should not hold anything up, and which the first Tauri commit is the natural place
for, since a GUI launch is the environment where it stops being an invariant check.

I would now change "nothing measured-and-not-fixed in the transport" to: nothing measured
and not fixed, and the next unmeasured edge is the one we have not thought of yet. That
has been true at each of the last four rounds and it is the only honest form of the claim.

## 8 · Ladder

    C1.1     Tauri Rust host + private transport
             ├─ F.6      CommandSpec · exact-set linearized · limits · pack digest
             ├─ F.7      inherited descriptors · identity lifetime · epoch ·
             │           demultiplexer · bounded projection
             ├─ F.8      CLOEXEC confinement · serialized writer ·
             │           continuity cursor · lossless paging
             ├─ F.8.1    durable host world · one owner per world              ✓
             ├─ F.8.2    the receiver owns what it receives · zero residue     ✓
             ├─ F.8.2.1  adopt_channel consumes its argument exactly once ·
             │           boot baseline · no exception in the sink              ✓
             └─ F.8.2.2  a channel handoff is a transaction · one ordered
                         deadline · an identity cannot outlive its process     ✓
             ── remaining: the WebView
    C1.1b    SQLite transactional persistence · durable revision
    C1.2     FabricProvider.Tailscale

## Verify

```
cd ampd && mix test                    # 180 tests, seed 0
bash tools/sabotage.sh                 # 44 falsified · 0 not   (~5m)
cd .. && bash tools/release.sh         # required gates, including both host gates
./host/target/release/super-host verify        # 47 held · 0 failed
bash tools/sabotage-host.sh                    # 6 falsified · 0 not
```
