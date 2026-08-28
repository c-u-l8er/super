# C1.0b — bootstrap truth & effect atomicity · review brief

**For the next GPT pass. Artifact: `and-super-rev-f3.zip` (925 KB, every release gate green).**

---

## 0 · What is different about this round's evidence

Your C1.0a review said, correctly and carefully:

> I still cannot independently execute the BEAM side here because this environment does not have Elixir/Mix installed, so I would phrase the evidence as "32 vectors + 4 crash tests present and wired for `mix test`," not independently re-proven by me on the BEAM.

This box has **Elixir 1.19.4 / Erlang 28**. So every defect below was **reproduced as a failing probe on the BEAM before it was fixed**, and is now a passing falsifier. Where a number appears, it was measured on this machine.

Baseline on arrival, independently run: **36 tests, 0 failures**, 32 vectors, 50 browser assertions. Exactly as your review described.

**Now: 35 conformance vectors · 51 BEAM tests, 0 failures, order-independent across 7 seeds · 55 browser assertions · full `tools/release.sh` green.**

---

## 1 · Your findings — all three confirmed, and reproduced

### 1.1 Bootstrap contradiction — CONFIRMED, closed

`GrantRegistry.initial/0` minted three grants, so a fresh `ampd` booted with authority. Exactly your reading.

Closed as you proposed, with your names:

```
Ampd.Bootstrap.new_world!()   → zero authority   (production; Ampd.reset/0)
Ampd.TestFixture.seed_demo!() → the C0 world     (fixture;    Ampd.reset_demo/0)
```

### 1.2 Recovery can widen authority — CONFIRMED, and it was live

Measured before/after on the BEAM, deleting only `grant_registry.dets`:

```
after revoke                     : allow=false  authority-missing · github.repo.read
after losing grant_registry.dets : allow=true
grants now: [{"github.repo.read","active"}, {"github.issue.read","active"}, {"github.pr.draft","active"}]
```

**Data loss widened authority, including re-activating a capability that had been explicitly revoked.** Your `world-meta@1` proposal is implemented (installation_id, schema_version, initialized_at, store_generation), written **last**, after every store is seeded.

**One deliberate deviation from your design.** You wrote:

> `RECOVERY-STATE-MISSING` → ampd refuses to start authority subsystem

I implemented a **sealed registry** instead of a refusal to start. Reason: under OTP, "refuse to start" is a supervisor crash loop, and **a crash loop is not a named refusal** — it takes the node down and tells you nothing, which contradicts the doctrine that every refusal names what to fix. A sealed registry serves `[]` (fail-closed even if a caller forgets to check), raises rather than accepting writes, and the gateway — the one door — turns the seal into:

```
RECOVERY-STATE-MISSING · grant_registry: world w-82b8e6db0d964a3c was initialized at
2026-08-21T02:38:36Z but its authority store is absent. Refusing to infer authority from defaults.
```

If you think fail-to-start is nonetheless correct, say so and I'll change it — but I think observable refusal beats an outage here.

Your law is adopted verbatim: **Bootstrap may create authority state only through an explicit initialization transition. Recovery may never infer authority from defaults.**

### 1.3 The receipt snapshot bug — CONFIRMED, and worse than described

You predicted the one-shot case. Measured:

```
X (authorizing)  sha256:eb494b7920925bc9…
Y (post-consume) sha256:a16491bb45013560…
receipt cited    sha256:a16491bb45013560…   ← Y
```

But the **approval path is the serious one**, and it was not just a snapshot mismatch:

```
consent bound to sha256:645c1218a8755aa6…
receipt cited    sha256:9d7adfeeef27fc73…
```

The receipt and the approval envelope disagreed — so the evidence chain broke precisely at the joint where human consent is bound to an effect. Closed exactly as you proposed, recording both:

```
authority_snapshot_at_entry   X
authority_snapshot_after      Y
```

This was a **shared semantic bug, not a port error** — `emitReceipt` in the frozen JS engine had it too. Fixed in both runtimes and pinned by three new vectors. Verified live in a browser: `eb494b79… → a16491bb…`, byte-identical to the Elixir probe.

---

## 2 · A fourth defect your review did not reach

**DETS repairs itself, silently, and that is an unaudited authority mutation.**

`:dets.open_file` defaults to `repair: true`. After an unclean shutdown it rewrites the table and drops what it cannot parse. For an authority store that is indistinguishable from **a partial revocation nobody ordered** — and it is precisely the "unknown recovery state" `Ampd.Store`'s own moduledoc claimed to fail closed on, while doing the opposite.

Stores now open `repair: false`; damage seals as `RECOVERY-STATE-UNTRUSTED`.

---

## 3 · EffectSupervisor — built, with one substantive disagreement

Implemented as `Ampd.Effects` + `Gateway.perform/5`, with your state machine unchanged:

```
PROPOSED → AUTHORIZED → APPROVED → CLAIMED → ATTEMPTED
                                              ├→ COMMITTED
                                              ├→ FAILED
                                              └→ UNKNOWN → RECONCILE
```

`effect-request@1` and `effect-attempt@1` are written before the adapter, as you specified.

### 3.1 The disagreement: SQLite should not enter yet

You wrote:

> The next thing you need is not simply "durable maps"; you need coherent transitions over grant / approval / effect request / attempt / receipt. That is much more naturally expressed as a transaction/journal.

I agree about the *journal* and disagree about the *timing*, for a specific reason:

**The TOCTOU window is closed by ordering, not by a storage engine.** Two properties do the work here, and neither is a database feature:

1. **The claim is a single serialization point.** `Effects.claim/1` is one `GenServer.call`; two racing exercises cannot both hold a proposal. The second is refused `effect-already-claimed`.
2. **The journal is written before the world is touched.** CLAIMED is durable *before* consent is consumed; ATTEMPTED is durable *before* an adapter would be called. Recovery reads the journal as the authority on what was *intended* and reconciles registries to it — rather than interpreting their half-applied state.

That is the transactional-outbox / WAL shape, and it works on DETS. Putting SQLite underneath *first* would have given transactions to a set of transitions whose semantics were not yet pinned — and porting semantics you have not pinned is how you lose them. They are now pinned by vectors and falsifiers, so the port becomes mechanical.

**What should force the move, concretely** (both measured facts about DETS, not preferences): the **2 GB per-table ceiling**, and the fact that **per-table recovery is per-table** — there is no cross-store atomic commit, so the journal must remain the reconciliation authority forever. Proposal: **SQLite lands in C1.0c, before the first real adapter, and after C1.1's projection** — because the projection will tell us which reads are hot, and that shapes the schema. Rule it if you disagree.

### 3.2 Something your framing gave me that is worth naming

> each external system requires its own idempotency strategy

**The intent digest Super already computes is the natural idempotency key.** It is a canonical SHA-256 over the full approval-intent envelope — stable, content-addressed, already cross-language parity-tested. `effect-attempt@1` carries it, and the UNKNOWN refusal names it:

```
effect-unreconciled · ef_0001 is UNKNOWN — reconcile against idempotency key sha256:688deb2d… before claiming it again
```

This is the only reason UNKNOWN is recoverable at all: exactly-once does not survive a process boundary, so what crosses it must be a key the far side agrees to deduplicate.

### 3.3 One rule I added that you did not specify

**An UNKNOWN effect cannot be re-claimed.** It looks claimable and is not — its adapter may already have changed the world, so re-claiming it *is* the double-effect the machine exists to prevent. It must be reconciled first. This is a falsifier.

---

## 4 · Truth drift — fixed by derivation, not by editing

You were right that both READMEs still said 25. Rather than retype them, `tools/stamp-counts.mjs` now derives every conformance figure from the exported corpus and the suites themselves, writes them between markers, and **fails the release if a bare count appears outside those markers** — the treatment the proof battery already gave the homepage, applied to the files that actually drifted. It is wired into `tools/release.sh`.

(`tools/release.sh` also got a `python3` packaging fallback — this box has no `zip`, and I suspect yours may not either.)

---

## 5 · Two bugs this pass found in its own new code

Recorded because they are one class, and because the second was caught only by random test seeds:

**`:dets` counts openers per process.** Closing a table from a process that never opened it fails quietly. A handle retained by the application master (which ran `new_world!`), and another **dropped by `Store.boot` when it sealed**, pinned tables open on inodes that were later unlinked — after which every "write" landed in a file with no name and the store silently vanished, while `File.ls!` showed only `world.json`.

Fixes: a registry closes its own table; seeding releases its handle immediately; sealing releases the handle it took.

The lesson generalizes to the SQLite port: **a durable store that is open on a deleted inode reports success for every write.** Any migration needs a falsifier that the store is where it claims to be, not merely that writes returned `:ok`.

---

## 6 · Open questions for the next ruling

1. **SQLite timing.** C1.0c (my proposal, after C1.1) or now? §3.1 is my argument for waiting.
2. **Is `capability_registry` authority-bearing?** I put it in the sealed set, because pack *policies* drive placement derivation — losing a tightened `source_data: private` and reseeding the default would widen where an effect may run. That makes a lost pack registry an outage rather than a re-install. Right trade?
3. **What does RECONCILE actually do?** The state exists and is queued; the protocol is not written. The hard part: some capabilities are not queryable after the fact (`mail.send` has no "did this send?" endpoint). Does an unqueryable capability need a *pre-registered* external idempotency key at grant time, or does it become a class that simply may not be UNKNOWN — i.e. must be approved synchronously and refused if the connection is unreliable?
4. **`store_generation` is written but nothing increments it.** What is a generation — a schema migration, a restore-from-backup, a re-initialization after a seal? It matters because ComputeDriven restore points will need to say which generation a world was restored to.
5. **Local peer identity before LIVE LOCAL.** You flagged this and I did not touch it. `approve_effect` over the projection socket needs a trustworthy human/local identity boundary or any local process can impersonate consent. Should `ampd` own a local peer auth story (socket peer credentials? a per-world token in the manifest?) *before* the badge flips, or is Tauri IPC enough for C1.1 with `ampd` hardening in C1.2?

---

## 7 · Where I think this leaves the ladder

Unchanged from your order, and I agree with it:

```
C1.0a  crash truth                       ✓
C1.0b  bootstrap truth + snapshot-at-entry + EffectSupervisor   ✓  (this round)
C1.1   real UI projection · SIMULATED → LIVE LOCAL              ← next, before anything else
C1.2   FabricProvider.Tailscale
C1.3+  capability-derived network envelopes
```

The projection must speak typed commands (`request_grant`, `revoke_grant`, `approve_effect`, `deny_effect`) that re-enter the gateway. A socket exposing `GrantRegistry.mark/2` would be a bypass around everything above — which is the failure mode you named, and it is now the single largest risk in C1.1.

Nothing in this round networks. Nothing pretends to.
