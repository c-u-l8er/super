# C1.1.1 — identity and projection · review brief

**Artifact: `and-super-rev-f4.zip`. Every gate green.**

Your ruling: *spend the next round making identity and projection trustworthy, not adding
another feature.* That is exactly this round's scope. All four of your C1.1 requirements are
built, both new laws are enforced, and eight of your ten acceptance criteria are falsified on
the BEAM. The transport is still **not** here — see §8 for which two criteria that leaves and
why they are the right two to defer.

---

## 0 · Measured

| | C1.1.0 | C1.1.1 |
|---|---|---|
| conformance vectors | 39 | 39 |
| BEAM tests | 87 | **110**, 0 failures across 7 seeds + seed 0 |
| browser assertions | 60 | 60 |
| sabotage probes | — | **9 falsified · 0 not** |

Breakdown: 39 conformance + 10 identity + 12 linearization + 13 control + 14 world + 7 effect
+ 6 bootstrap + 5 lineage + 4 crash.

The vector count is unchanged and that is the point: nothing here touched the authority
algebra. Every figure is derived by `tools/stamp-counts.mjs`; none is typed.

**New: `tools/sabotage.sh`.** Nine probes, each stubbing out one fix and asserting the test
goes RED. A test that passes with its fix disabled is an invariant check, not a falsifier, and
last round I shipped three of those without noticing. Now the distinction is measured.

---

## 1 · Connection determines actor — the command has no actor to lie in

You were right that this was the most important rule, and implementing it turned out to be
cheaper than validating the claim would have been, because the right answer was **to stop
accepting one**.

`Ampd.Peer` binds a channel to an identity once, when the channel is created. Every command
derives its context from that binding:

```
request_effect(capability, resource, request)      ← no ctx argument exists
        ctx = Peer.authoritative_context(peer, request)
              actor      ← the binding
              workspace  ← the session the runtime holds
              run        ← the session the runtime holds
              placement  ← request["placement"], a preference that can only narrow
```

The falsifier sends `actor`, `workspace`, `run`, **and** a nested `ctx` in one payload and
asserts the derived context is Kestrel/trvm/run-b51 regardless. A second one binds a peer to
`mallory` and confirms it cannot reach Kestrel's grants.

**`claim_control_channel/0` succeeds once.** The host claims it at boot, before any engine
exists; a second claim is refused `control-channel-already-claimed`. So "there is exactly one
channel that may speak for the person, and it was established before anything else was
running" is mechanical rather than conventional.

**Peer bindings are not durable.** A binding that survived a restart would be a connection
that outlived its socket. Resetting the world also drops every binding — a peer holding an
actor identity in a world that never granted it one is the stale-consent problem one layer
down, on the identity instead of the approval.

### On `SO_PEERCRED`, and why the module does not reach for it

Your instinct about inherited capability channels is the one the ecosystem already converged
on, and it is worth recording why the alternative is worse than "still needs a binding":

`SO_PEERCRED`'s `pid` is a small integer that wraps, so a `pid → agent` table is **racy by
construction** — the process you look up may have exited and been replaced between the connect
and the lookup. Linux 6.5 (glibc 2.39) added `SO_PEERPIDFD`, which returns a pidfd that always
refers to one process and closes that race. It still would not answer the question: a pidfd
tells you *which* process, never *what* it is, and turning a pid into "this is Kestrel" means a
per-sandbox lookup that does not generalize. Flatpak, the Wayland compositors, and D-Bus all
landed on the same answer instead — **hand each client its own socket with the identity already
attached, and make that socket the only way in.**

So: your ruling, with a citation. The module docs carry it.

### What is still unenforced, stated plainly

Anything inside this BEAM can call `Peer.attach_agent/2`, because something has to be trusted
to say who connected and until the Rust host exists that something is any caller. What C1.1.1
removes is the *per-command* claim. The transport now has to be right in exactly one place —
at attach — instead of on every message. That is the difference between a boundary a transport
can secure and one it cannot.

---

## 2 · Three projections

Adopted as specified, with one addition and one subtraction.

```
operator-projection@1   world · all agents' grants · grant requests · approvals · effects
                        · receipts · reconcile queue · seals · peers · recent refusals
agent-projection@1      self · own grants · own requests · own approvals · own effects
                        · own receipts · workspace · run · public runtime health
runtime-status@1        healthy | sealed | down · version · world loaded?
```

**Subtraction: the agent projection does not carry `authority_snapshot`.** It is a digest over
every grant on the machine, so watching it change is a side channel onto authority the caller
cannot see. The snapshots that authorized this actor's own effects are on its own approvals
and receipts, where they are evidence rather than a probe.

**Addition: `"down"` is in `runtime-status@1`'s vocabulary and is never returned.** A runtime
that answers is not down, so `"down"` is what a caller concludes from *no answer*. Naming it is
the difference between a client that knows silence is a state and one that hangs waiting for a
fourth value.

`receipts` gained an `actor` field. Without it the ledger was all-or-nothing: either every
agent reads every receipt on the machine, or none reads its own.

The cross-agent falsifier is deliberately two-sided — Mallory's projection is empty **and**
Kestrel's is non-empty, from the same world at the same moment. An empty projection because
nothing happened would prove nothing.

There is no way to *ask* for another actor's projection. `agent_projection` takes no argument;
passing one is ignored, because the actor is read off the binding. The forgery is not refused,
it is unphrasable.

---

## 3 · Preflight: rate limit at the transport, redact at the boundary

Ruling taken: **no semantic budget.** `preflight` still creates nothing, stales nothing, and
burns no coordinator op — the two C1.1.0 falsifiers still hold. Per-peer rate limiting is a
transport concern and belongs with the transport; nothing here pretends otherwise.

The redaction is mechanical rather than per-call. `Ampd.Core.near_miss_class/5` returns the
class and the comparison separately; `near_miss/5` still returns the exact sentence the frozen
simulator returns, because that is what the vectors match on. The class rides in `refusal@1`,
the comparison rides in `operator_detail`, and the existing dual projection does the work:

```
agent      code: scope-mismatch
           public_message: "No applicable grant covers the requested resource."
operator   code: scope-mismatch
           operator_detail: { requested: other/repo, grant_resource: traaviis/trvm }
```

The falsifier asserts the agent's `reason` does not contain `traaviis/trvm` anywhere — the
free-text field is *replaced*, not trimmed, which is the same fix C1.1.0 made for seals.

### One tightening beyond your ruling

`actor-mismatch` is itself an oracle. Told apart from `authority-missing`, it says "somebody
else holds this capability", and an agent that may ask about arbitrary capabilities can
enumerate the rest of the machine's authority one bit at a time. So `refusal@1` gained
`public_code`: the operator reads `actor-mismatch`, the agent reads `authority-missing`. One
stored object, two codes.

This is the line I drew from your rule — *the class may be explained, the hidden state may not
be enumerated* — applied to a class that **is** hidden state. Every other near-miss class
describes the caller's own grant or the request itself, so those stay visible. If you think the
line belongs elsewhere, this is the one judgement call in §3 I would want re-ruled.

---

## 4 · `grant-request@1`

Built as specified. `request_grant` no longer touches `set_draft`.

```
agent  →  request_grant  →  grant-request@1 PENDING { id, actor, capability, resource,
                                                     requested_duration, reason, created_at }
human  →  approve_grant_request(id, duration)  →  mints the grant, resolves the request
       →  deny_grant_request(id, why)
```

The falsifier asserts that after an agent's request: the active grant list is byte-identical,
the capability still does not authorize, the human's projection is unchanged, and there is
exactly one pending request carrying the asking actor's name. A second asserts an agent cannot
resolve its own request.

`duration` is the only thing the human supplies that the request did not — a person answering
"once" to a request for "workspace". Everything else is minted from the request, so what is
granted is what was asked for.

Both new registry ops are inside the ordered-mutation boundary. A request creates no authority,
but it is a durable object a human decides on, and an unordered write to it races the decision.

---

## 5 · Consent binds to world lineage

Adopted exactly, including your split: `approval-intent@1` carries the lineage,
`effect-intent@1` does not.

```
effect-intent@1     what should happen           stable across restore
approval-intent@1   + world_installation_id      dies with the lineage
                    + world_generation
```

`Ampd.Authority.advance_lineage/2` bumps the generation inside the total order and stales every
approval bound to a prior one. Your caution about *when* is implemented: staling happens at the
trusted recovery, **not** at the moment a store seals, because at seal time one of the stores
involved may be the damaged one, and a recovery step whose first act is to write to the thing
that just failed cannot run when it is needed.

**The mark is the explanation; the digest is the enforcement.** The strongest falsifier here
sabotages the mark — grant consent, advance the lineage, then force the approval *back* to
`granted` as though the stale mark had been lost — and asserts the effect is still refused,
because the digest cannot match across a lineage change, and that a fresh pending approval
opens at the new generation instead. That is the "no special case to forget" property you were
after, tested by removing the special case.

### The divergence this creates, pinned

This is the first field `approval-intent@1` carries that the frozen browser simulator **cannot**
produce: a page has no durable world, so it has no lineage to bind. No vector is affected —
none asserts a runtime-computed approval digest, and the three literal digests in the corpus
are taken over supplied fixture envelopes — but the two engines now genuinely differ here.

Rather than write that down, there is a test that reads the envelope out of
`app-prototype.html` and asserts the BEAM's key set differs by **exactly**
`world_generation` and `world_installation_id`, with nothing dropped. A hand-copied list would
agree with the engine only until someone edited one of them.

`advance_lineage/2` is deliberately **not** on a channel. A lineage advance with no restore
behind it is the placeholder you told me not to ship; it is the runtime half of a transition
whose other half does not exist yet.

---

## 6 · `schema_version` — and the ordering bug in my own fix

Ruling taken, with one correction that came from running it.

```
schema_version == 2   →  VALID
schema_version <  2   →  WORLD-META-MIGRATION-REQUIRED   sealed
schema_version >  2   →  WORLD-META-UNSUPPORTED          sealed
shape wrong at 2      →  WORLD-META-UNTRUSTED            sealed
```

I first implemented it shape-first, exactly as it reads. Then I pointed the runtime at a real
`world.json` left over from an older build and it reported `:malformed`. It was not malformed —
it was a v1 manifest, and v1 called the field `store_generation`. **Shape is versioned**, so
checking shape before version reports an old manifest as corrupt and sends an operator hunting
for damage that is not there. Only `schema` and `schema_version` are judged ahead of the
version itself.

The same run produced a better boot message: a version problem now names the versions rather
than listing this build's field names against a file that never claimed to have them.

None of these may be seeded over. The `:unsupported` falsifier asserts the future world's
manifest is still byte-present after a failed initialization — overwriting it would destroy an
identity this build could not even read.

---

## 7 · Three defects that were live before this round, all found by running the thing

### A refusal code no input could produce

`world-meta-untrusted` was unreachable. The seal-code mapping tested
`String.contains?(reason, "UNTRUSTED")` first, and every `WORLD-META-UNTRUSTED · …` reason
contains that substring — so it always matched the earlier branch. **An invalid manifest
reported itself as a damaged store**, sending an operator to repair a `.dets` file that was
fine.

Worse, the mapping was written out twice — once in the gateway, once in the ordered-mutation
refusal — and the second copy did not know `WORLD-META` existed at all. It is now one function,
matching on the prefix, with a test that asserts all six codes are reachable.

### A seal that crash-looped

`Effects.recover!/0` runs from `Application.start/2`, right after the supervisor comes up. It is
not an ordered op, so it never met the seal guard C1.1.0 gave the mutations — and `Store.save/2`
raises on a sealed store *by design*. The raise killed Effects, which killed the start callback,
which killed the application.

**A sealed world could not boot at all.** The named refusal the seal exists to produce never got
the chance to be produced, which is precisely the crash-loop-instead-of-refusal failure the
whole seal design is a reaction to — surviving in the one code path that runs before anything
else. It was reachable only by opening a world an older build wrote, which is exactly what I
did by accident.

Fixed, falsified, and verified end to end: the old v1 manifest now boots, and

```
runtime-status@1   status: sealed · world_loaded: false
agent preflight    world-meta-migration-required · no operator_detail
```

### And a third, in the tool that exists to prevent exactly this

`stamp-counts.mjs` derives every conformance figure so none is typed by hand. The blueprint
keeps a per-round record — *C1.0b: 35 vectors / 51 tests*, *C1.0b.1: 39 / 72* — and **every one
of those lines was inside the stamp markers.** So each release rewrote the history with the
current round's numbers, and the C1.0b section had come to claim 110 BEAM tests, a figure that
was never true at C1.0b.

The tool built to stop stale counts was manufacturing false ones, which is worse: a stale number
is visibly old, and a restamped one is not. The workflow had been quietly compensating by keeping
a clean copy of the blueprint outside the release tree and copying it in — a workaround for a
defect nobody had named.

Historical records are frozen literals now, and `stamp-counts` **refuses** when a file contains
more than one marker of a kind, because a second one means a past round has been wrapped again.
The true figures are restored: 35/51, 39/72, 39/87, and this round's 39/110.

---

## 8 · Command surface: every command means its name

* `recover_world` → **`recovery_status`**. Not aliased — the old name now refuses
  `unknown-command`, and the test asserts it. The response carries `recoverable: false` and says
  in words that no recovery transition exists.
* `inspect_refusal` **implemented**, against a bounded 200-entry in-memory ring. A refusal is a
  diagnostic, not authority: losing one costs an explanation, and an unbounded refusal log is a
  surface an agent can fill by retrying. It is open to **both** channels on purpose — it is the
  dual projection checked from the other direction. The agent that received a code and a public
  message comes back with the correlation id and still gets no topology; the operator pastes the
  same id and sees everything. One stored object, two answers, provable twice.
* `Gateway.authorize/4`, `exercise/1`, `approve_last/0`, and `forge_pr_create/1` moved to
  **`Ampd.Conformance`**. `Ampd.Control` cannot dispatch to any of them. The module docstring
  says what each one can do that the product path cannot — `authorize/4` consumes consent with
  no journal in front of it, `forge_pr_create/1` writes granted consent straight into the store.
  Four test-shaped functions sitting beside three product ones were a second runtime API waiting
  for someone in a hurry.

The channel table is now two-sided rather than "human-only vs everything else": `preflight` and
`request_effect` are refused on the **human** channel too, because they need an actor and the
person is not one. They hold no grants and exercise no capabilities; they are the source of
consent. The control room renders eligibility from the operator projection.

---

## 9 · Your acceptance battery

| | criterion | state |
|---|---|---|
| 1 | human-origin forgery refused | ✅ falsified |
| 2 | actor forgery ignored | ✅ falsified — and unphrasable, there is no field |
| 3 | cross-agent projection absent | ✅ falsified, two-sided |
| 4 | preflight oracle redacted | ✅ falsified, plus `actor-mismatch` collapsed |
| 5 | grant request leaves authority unchanged | ✅ falsified |
| 6 | approval identity exact | ✅ falsified (C1.1.0, still green) |
| 7 | world generation stales consent | ✅ falsified, incl. with the mark sabotaged |
| 8 | projection updates without reload | ⛔ needs the transport |
| 9 | crash truth survives restart | ✅ falsified (C1.0a/C1.0b, still green) |
| 10 | reconnect truth | ⛔ needs the transport |

8 and 10 are the two that are *about* the transport rather than about semantics the transport
will carry, which is why they are the right two to be last.

---

## 10 · Open for the next ruling

1. **Is `public_code` the right instrument, or too clever?** It hides the true refusal class
   behind a second one, and a wrong `public_code` would be a silent disclosure that no test
   naming the *visible* code could catch. The alternative is refusing to distinguish
   `actor-mismatch` from `authority-missing` at all — losing the operator's diagnostic to
   protect the agent's. I took the two-code route; it is the change here I am least certain of.

2. **Should `advance_lineage/2` stale `granted` approvals, or only `pending` ones?** It
   currently stales both. A `granted` approval is consent the human already gave and the runtime
   has not yet spent, so staling it re-asks a question that was answered — but the answer was
   given under a snapshot that no longer exists. I lean toward the current behaviour and would
   rather you rule it than pick.

3. **Does the peer table need to survive a `Peer` process crash?** It does not today: a
   supervisor restart drops every binding, and every open channel is silently disconnected with
   no way for the host to learn that. The alternative is monitoring each peer's owning process
   and re-binding, which starts to look like the session management SQLite is meant to hold.
   Deferring feels right; the failure mode is "everything reconnects" rather than "something
   gains authority", but I have not proved that second clause.

---

## 11 · Ladder

    C1.0a    crash truth                                       ✓
    C1.0b    bootstrap truth + effect journal                  ✓
    C1.0b.1  authority linearization                           ✓
    C1.1.0   projection boundary correctness                   ✓
    C1.1.1   identity + projection                             ✓  this round
             connection determines actor · three projections ·
             grant-request@1 · consent binds to world lineage ·
             schema_version semantics · conformance quarantined
    C1.1     Tauri host + private inherited transport
             SIMULATED → LIVE LOCAL                            ← next
    C1.1b    SQLite transactional persistence
    C1.2     FabricProvider.Tailscale
    C1.3     capability-derived network envelopes

The badge still says SIMULATED. Every interface the transport has to attach to is now shaped
and falsified; what is missing is the socket, and nothing here pretends otherwise.

---

## Verify

```
cd ampd && mix test                # 110 tests
bash tools/sabotage.sh             # 9 falsified · 0 not
cd .. && bash tools/release.sh     # the full gate chain → and-super-rev-f4.zip
```
