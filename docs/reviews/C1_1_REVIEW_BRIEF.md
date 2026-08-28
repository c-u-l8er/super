# C1.1 — the transport is real, and running it found two things reading could not

**Artifact: `and-super-rev-f6.zip`. Every gate green.**

You ruled: *build C1.1 — real Rust host, real inherited human-control channel, real
agent-bound channel, `Ampd.CommandSpec` at the wire, exact-set bulk mutations linearized,
runtime pushes projections, reconnect restores the same durable world. Then run the
acceptance battery through the actual transport rather than directly against `Control`.*

That is what this is. All three rulings and all three additional requirements landed, and
then the last instruction — *run the battery through the transport* — did the thing it was
supposed to do: it failed, seven of sixteen, on the first run.

---

## 0 · Measured

| | C1.1.2 | C1.1 |
|---|---|---|
| conformance vectors | 42 | **42** — unchanged, and that is correct; see §7 |
| BEAM tests | 128 | **160**, 0 failures at seed 0 and across random seeds |
| browser assertions | 64 | **64** |
| sabotage falsifiers | 18 falsified · 0 not | **31 falsified · 0 not** |
| host acceptance checks | — | **16 held · 0 failed**, from a separate OS process |

**Two of the previous round's 18 were not evidence.** See §5. The honest prior number was 16.

---

## 1 · Your three rulings

### Pre-grants stay refused

No change, as ruled. `Authority.mint/1` still refuses a capability no installed pack
declares, and the gateway still refuses one at exercise time. I did not build
`grant-plan@1`; you called it a later object and it is.

One thing did move, and it moves in your direction. `request_grant` now refuses an
undeclared capability **at request creation** rather than letting a pending object exist
that `mint` was always going to refuse. The old shape bought nothing except a person
clicking approve to find out.

### Bulk revoke: exact set, one linearization point

You were right that `expected_ids` compared in `Ampd.Control` would not have been enough.
The old flow sampled the world twice with a writable gap:

```
Control    GrantRegistry.matching(scope)      ← sample 1, outside
Control    compare count
Authority  revoke_matching(scope)             ← sample 2, inside
```

Reproduced before fixing, exactly as you described it:

```
operator is shown: [gr_0193 gr_0194 gr_0195 gr_0196 gr_0197 gr_0198]   count 6
concurrently:      gr_0194 revoked, gr_0199 minted
scope now matches: [gr_0193 gr_0195 gr_0196 gr_0197 gr_0198 gr_0199]   count 6
REPRODUCED         count 6 still matched — revoked gr_0199, which the operator never saw
```

`Ampd.Control` now samples **nothing**. `expected_ids` goes straight down, and
`GrantRegistry.revoke_matching/2` compares and mutates in one `handle_call` — one message
to one process, so there is no gap to write into. The refusal names the difference in both
directions rather than only that it changed:

```
appeared: ["gr_0199"]   gone: []   matches_now: [...]   confirmed: [...]
```

`expected_ids` is **required** in `Ampd.CommandSpec`. A bulk revocation with no confirmed
set is the operation this command exists to make hard to say by accident, so there is no
arity that omits it.

The linearization has its own sabotage probe, and it is the one I would look at hardest.
It does not disable the comparison — it *moves* it, by re-deriving the confirmed set in
`Ampd.Control` from a fresh read and passing that down. The check still runs, still inside
the coordinator, still compares two identical lists. If the test stayed green under that,
the exact-set check would be decoration over a re-evaluated query. It goes red.

### `Ampd.CommandSpec`, and named fields

Built as you specified, and it is the source rather than a parallel copy:

```
Ampd.CommandSpec   what may be said     — channel, fields, types, limits, required, order
Ampd.Wire          checking it          — applies the declaration
Ampd.Control       what it means        — semantics only
```

`Ampd.Control`'s `@agent`/`@human`/`@both`/`@open` are now **read from the spec at compile
time**. They were four hand-written lists that `Ampd.Wire` derived a vocabulary from; the
drift axis is gone rather than tested for.

Named fields on the wire, positional inside the BEAM, `bind/2` between them. That bought
something I did not expect: because `bind/2` fills every declared field, it always emits
exactly the declared arity, so the "well-typed but no clause" case — `preflight` with one
argument — **cannot be constructed through this path at all**. The `rescue` in `Ampd.Wire`
stays as a guard against a future `Ampd.Control` clause the spec does not know about, and
is now unreachable, so it is declared un-falsifiable rather than counted (§5).

An unknown field is **refused, not dropped**. A client that misspells `expected_ids` must
not receive a bulk revocation it did not confirm.

---

## 2 · Your three additional requirements

### The nested-argument hole was real, and reproduced

```
top-level 5 MB binary:                 REFUSED  invalid-command-arguments
the SAME 5 MB one level down in a map: REPRODUCED  accepted and STORED —
                                       grant-request gq_0001 carries 5 242 880 bytes
```

You preferred a frame maximum plus per-field limits. Both, and the frame limit is enforced
**by the socket driver** — `packet: 4` with `packet_size`, so a 5 MB frame is refused after
four bytes have been examined and none of the body has been copied into the VM. A limit
that allocates the thing it is rejecting has made the attack cheaper.

Per-field, from the spec: `capability` 128 B · `resource` 512 B · `reason` 4 KB ·
`request` 64 KB · frame 256 KB. `Ampd.Frame.logical_size/2` is recursive and short-
circuiting, and counts **keys as well as values** — a limit that ignores keys has a hole in
it the shape of the keys.

### Invalid requested durations, refused at creation — and the hole was worse than the corner

You called this "one duration corner still open." It was larger than that.

```
rank("once")     = 0
rank("forever")  = nil
guard evaluates: rank("once") > rank("forever")   ⇒   false
```

`nil` sorts **above every integer** in Elixir's term order. So the widening guard was
silently false for *every* approval of a malformed request, not only the narrowing ones —
`"workspace"` would have passed too. Reproduced: a request for `"forever"` approved as
`"once"` minted a grant.

Fixed at both ends, as you preferred: `request_grant` refuses `invalid-grant-duration` at
creation, so a malformed request cannot exist. And `approve_grant_request` now checks that
the *request's own* duration is rankable before ranking it — for the ones already on disk in
a store written before the rule. There is a test that loads exactly such a request and
asserts every duration, including narrowing ones, refuses.

### Grant requests bind pack identity

Implemented, not deferred — it was three lines once `Core.pack_digest/1` existed.

`grant-request@1` records `pack`, `pack_version`, and a digest over the **authority-relevant**
part of the pack: version, declared surface, policy. Not `installation`, which is checked
directly at mint and at the gateway; folding it in would make every install look like a
contract change.

`approve_grant_request` refuses `grant-request-stale` when the digest moved, naming both
versions and both digests. The request stays **pending**, for the same reason
`grant-widening-refused` leaves it pending: a refused approval must not consume the thing it
refused. A request carrying no digest — written before the binding existed — is *not* treated
as stale. Absence of evidence is not evidence of a change, and refusing every pre-existing
request on an upgrade would be a migration failure wearing a security refusal's name.

---

## 3 · The transport

```
  super-host  (Rust, 1 dependency)
    ├─ mkdir  <runtime_dir>   0700     ← before ampd is spawned
    ├─ spawn  ampd
    ├─ connect <runtime_dir>/bridge.sock          first connection wins
    ├─ ask for the control channel → connect      ← THIS is the person
    └─ per engine: ask for an agent channel → spawn the engine with its path
```

Unix domain sockets in a `0700` directory, not a loopback port: nothing about loopback
distinguishes the Super control room from any other program the user runs. This is what
Wayland, D-Bus, and Flatpak's portal all settled on, for this reason.

**The identity law is now structural rather than validated.** `Ampd.Bridge.open_agent_channel("kestrel")`
creates a listener *for* kestrel; whoever connects is kestrel because that is what the
listener was for. The listener→identity map is complete before the first byte arrives, so
there is no code path in which anything a client sent decides who it is. And there is no
field to try it in — `Ampd.Frame` refuses a frame carrying `actor`, `peer_id`, or `channel`,
**refuses rather than ignores**, so a client that believes it is choosing its identity is
told it is not.

Channels are **single-use**: a listener accepts once, then closes and unlinks its socket
file. Every process here runs as the same OS user and can `readdir` the runtime directory,
so a long-lived agent socket would be enumerable. A single-use one is a window, not a door.
It also makes reattachment fail-closed, which you asked for: a dropped connection does not
reconnect, it goes back to the host for a new channel.

**Push, not poll.** `Ampd.Subscriptions` sends each channel its own projection when the
world moves. The revision is not a counter this module invents — it is
`AuthorityCoordinator.ops()`, the number of ordered mutations, so "revision 137" is a fact
about the world. Pushes coalesce over 15 ms; revisions do not. A burst of six mints sends
one frame whose revision has moved by six, so a client can always tell how much happened
even though it is not told six times.

Snapshot, not delta, as you said was fine at this size. Every frame carries
`world_generation` beside `revision`, because a revision is only comparable within one
generation — a client that reconnects to a changed generation discards its projection
rather than reconciling.

The bridge speaks `bridge-command@1`, a **different protocol** from `command@1`. Nothing on
the authority surface can create a channel or name an actor, and that has to stay true, so
the host's own needs cannot live there. Two vocabularies, no shared command word.

---

## 4 · What only running it could find

Both of these were green in 160 BEAM tests and failed the moment a separate OS process
drove the same protocol.

### A closed socket did not free the claim everywhere it was held

"The control channel is claimed" lives in two places, released by two different events:
`Ampd.Peer` frees its claim when the peer detaches; `Ampd.Bridge` cleared `control_open`
only on an explicit `close_channel/1`.

The Elixir test **called `close_channel/1` by hand** after closing the socket. So the two
locks were never given the chance to disagree, and the suite was green while a host that
simply closed its window — which is what closing a window is — could never take the control
channel again.

```
close and reopen reaches the same durable world
  FAILED — the runtime refused the control channel: "control-channel-already-claimed"
```

The connection teardown now tells the bridge. The manual call is gone from the test, and its
absence is the assertion.

### Once a channel subscribes, the reply is not the next frame

The host's `call` wrote a command and read one frame. That is correct until `subscribe`,
after which a `projection-snapshot@1` can arrive between the write and the answer. The host
then read a push as the reply to `operator_projection`, got a map with a `projection` key
where it expected `grants`, built an **empty** id list, and sent a bulk revocation
confirming nothing.

That refusal was scored as a pass — the check was "a mismatched set refuses", and an empty
set does mismatch. **A test that passes for the wrong reason is worse than one that fails**,
and it took reading the failure two lines below it to notice.

The protocol already carried the fix: every `reply@1` echoes `client_request_id`, and a push
has none. The host correlates now and queues what is not its answer. I am recording it as a
protocol lesson rather than a client bug, because every client will meet it: **a subscribed
channel is full-duplex, and request/response over it requires demultiplexing.** If that
should instead be two sockets — one for commands, one for pushes — say so and I will split
it before the WebView is written against this shape.

### And one contamination that taught something anyway

The first host run inherited `priv/data` from an earlier scripted reproduction, including
the 5 MB grant request from §2. Every projection came back `frame-too-large`:

```
{"code":"frame-too-large","operator_detail":{"bytes":5244364,"max":262144}}
```

Not a defect — the system did exactly what it should, refusing by name rather than going
silent. But it demonstrates a consequence worth stating: **one oversized object makes a
whole projection unencodable**, and the channel gets a refusal instead of its world. The
per-field limits mean a new world cannot reach that state. A world that already has is not
recoverable through the projection. See §8.

A verification run now starts from a world it created — `AMPD_DATA_DIR` — because a battery
that passes on state it did not set up is not a battery. Unifying that also found three
modules reading the data directory independently, so the world manifest and the stores could
have landed in different directories. One function now, with a probe.

---

## 5 · Two of last round's falsifiers were not evidence

I added a compile check to `tools/sabotage.sh`, and it immediately caught the harness
scoring itself:

```
BROKE THE BUILD  actor comes from the binding, not the payload
BROKE THE BUILD  the wire decoder is total
```

A sabotage that does not compile turns every test red, which the harness read as
*falsified* — the strongest possible result, awarded for breaking the build.

* **`actor comes from the binding`** matched `"actor" => actor,` — which appears in
  `handle_call` for `:attach` as well, where `request` is not in scope. It has never proved
  anything about that fix.
* **`the wire decoder is total`** replaced `try do` with `if true do`, a syntax error.

Both are re-pointed and genuinely falsify now. **So C1.1.2's `18 falsified · 0 not` should
be read as 16.** I would rather say that than carry the number forward.

`31 falsified · 0 not` this round, with two still declared un-falsifiable and excluded, each
with its reason in the script: the `Peer` epoch (unchanged from last round) and the
`Ampd.Wire` rescue (newly unreachable, §1).

---

## 6 · Your acceptance table

| C1.1 falsifier | state |
|---|---|
| agent tries human command | ✅ falsified — **over the socket** |
| agent puts `actor=kestrel` in payload | ✅ unphrasable — refused as a *frame* |
| fake/old peer handle | ✅ falsified |
| peer crashes → old channels invalid | ✅ falsified over the socket (epoch itself: §5) |
| **claim control after restart** | ✅ **falsified** — and it failed first (§4) |
| revoke Kestrel's while Mallory holds same | ✅ falsified |
| unknown grant duration | ✅ falsified — now at request creation |
| agent asks `duration=forever` | ✅ falsified |
| approve grant for undeclared capability | ✅ falsified |
| store sealed during revoke/request | ✅ falsified |
| malformed command frame/args | ✅ falsified — frame *and* argument layers |
| arbitrary command string → no atoms | ✅ falsified over the socket |
| Kestrel projection contains only Kestrel | ✅ falsified — two live sockets |
| **UI updates without reload** | ✅ **falsified** — push, revision advances |
| **close/reopen → same durable world** | ✅ **falsified** — across a registry kill |

Fifteen of fifteen.

---

## 7 · Why the corpus did not grow

42 vectors, unchanged, and I want to be explicit that this is a decision rather than an
oversight. Everything this round is **command, wire, and transport** semantics. The corpus
is the cross-language authority contract — what `authorize` and `exercise` decide — and the
frozen JS engine has no socket, no channel, and no command layer to disagree about. Adding
vectors for `bulk-scope-changed` would put laws in a language-neutral corpus that only one
language can execute.

If you think the exact-set rule belongs there anyway, it would mean giving the JS engine a
command layer, and I would want that ruled rather than assumed.

---

## 8 · Open

1. **Should a subscribed channel be one socket or two?** §4. One socket needs
   demultiplexing in every client; two makes ordering between a reply and a push
   unspecified. I built one and correlated; I would rather you ruled it before a WebView is
   written against it.

2. **What should a projection that outgrows the frame do?** Today: a named refusal, and the
   channel gets no world. The alternatives are paging, or a projection that degrades by
   dropping its largest lists and saying so. Refusing is honest and leaves an agent with
   nothing; degrading is useful and is a projection that lies by omission unless the
   omission is in the frame.

3. **Is `Ampd.Bridge` the right place to stop?** Inside the BEAM anything can still call
   `open_agent_channel/2` and mint a channel for any actor. I do not think that is closable
   — the runtime *is* the thing trusted to name identities. The boundary has moved from
   every message → every attach → the moment a channel is created, by the process that
   spawns its holder. I think that is the end of the line, and I would like it confirmed
   rather than assumed.

4. **Tauri.** Not built. `super-host` is a plain Rust binary that owns the human control
   channel and drives the whole protocol; the WebView is a shell over exactly this. I
   stopped here deliberately rather than half-adding a GUI, because everything C1.1 claims
   is now provable by running one command, and none of it needs a window.

---

## 9 · Ladder

    C1.1.0   projection boundary correctness                   ✓
    C1.1.1   identity + projection                             ✓
    C1.1.2   the transport's acceptance battery                ✓
    C1.1     Tauri Rust host + private transport               ✓  this round
             CommandSpec · exact-set linearized · frame and
             per-field limits · duration at creation · pack
             digest binding · push projections · 16 host checks
             ── remaining: the WebView itself
    C1.1b    SQLite transactional persistence
    C1.2     FabricProvider.Tailscale

---

## Verify

```
cd ampd && mix test                    # 160 tests
bash tools/sabotage.sh                 # 31 falsified · 0 not
cd .. && bash tools/release.sh         # full gate chain → and-super-rev-f6.zip
cargo build --release --manifest-path host/Cargo.toml
./host/target/release/super-host verify    # 16 held · 0 failed
```

The last one spawns its own runtime, claims the control channel, opens an agent channel,
and drives the acceptance battery over real sockets from a separate OS process. It is the
only gate here that does not run inside the BEAM it is testing.
