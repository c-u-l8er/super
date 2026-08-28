# C1.0b.1 — authority linearization · review brief

**Artifact: `and-super-rev-f3.zip`. Every gate green, including the one that can now refuse.**

Your ruling was: *accept C1.0b, add a narrow C1.0b.1 before LIVE LOCAL; no SQLite yet, no Tailscale yet.* That is exactly what this is. Every item you ruled for **now** is done; every item you ruled for **later** is recorded as deferred, not quietly built.

---

## 0 · Measured

| | C1.0b | C1.0b.1 |
|---|---|---|
| conformance vectors | 35 | **39** |
| BEAM tests | 51 | **72**, 0 failures across 6 seeds |
| browser assertions | 55 | **60** |
| release | green | green — and now **refuses** without Elixir |

Breakdown: 39 vectors + 4 crash + 5 bootstrap + 7 effect + **8 linearization** + **9 world**.

---

## 1 · You were right to narrow the TOCTOU claim

I said "closed by ordering." You correctly restricted that to effects-against-effects. The interleaving you drew was reachable, and nothing serialized an effect against a *grant mutation*.

**`Ampd.AuthorityCoordinator`** now owns the total order over grant mutations, session mutations, pack-policy mutations, approval mutations, and effect claims. **`Ampd.Authority`** is the public linearized API; the registry functions became primitives the coordinator calls once it holds the order. The conformance runner drives `Ampd.Authority`, so the 39 vectors exercise the real path rather than a bypass.

Your law is implemented as stated:

> **CLAIM is the authority boundary.** Before it, revocation wins. After it, the effect owns a lease for its frozen snapshot.

`perform` re-decides **inside** the order, so a verdict taken earlier cannot ride into a later claim. The adapter runs **outside** the lock, deliberately — holding authority across a remote call would make every revocation wait on a stranger's TCP timeout, and the lease is precisely what makes that safe. There is a falsifier for the lease: an adapter that revokes its own grant mid-flight still commits, and everything after it refuses.

### The falsifier that actually earns the claim

24 concurrent exercises against **one** one-shot use. Without the coordinator, several `decide` "allow" before any consumes, and authority is double-spent.

I verified this the only way worth verifying it: **stubbed `AuthorityCoordinator.transact/2` out and re-ran.** Red. Restored. Green.

Two neighbouring tests pass *with or without* the coordinator. I have labelled them in the file as invariant checks rather than falsifiers, with the reason, because a test that cannot fail is not evidence and I would rather say so than let a count imply otherwise.

---

## 2 · effect-key ≠ approval-digest — your split, adopted whole

You were right, and the failure mode you named is the one that matters: reconcile an UNKNOWN effect after an unrelated grant change and the far side gets a *different* key for the same desired effect.

    effect-intent@1   → effect_key       what should happen
    approval-intent@1 → approval_digest  why this actor may do it now
                        (embeds effect_key + actor + grant
                         + authority snapshot + placement + pack version)

The idempotency key is now `effect_key`. `effect-intent@1` carries no actor, grant, snapshot, or placement, and a falsifier asserts it never gains one — that field list is load-bearing, so it should fail loudly if someone "helpfully" enriches it.

Both runtimes, with cross-language parity verified live just now: browser `sha256:656bc0868c8cd5cef5c…`, Elixir `sha256:656bc0868c8cd5cef5c…`. Vectors pin that the effect key **survives** an authority change and the approval digest **does not**.

---

## 3 · Orphan-world recovery — the case I had backwards

Your fourth row was the one my code got wrong. `new_world!()` treated a missing manifest as first boot regardless of what was on disk, so **losing `world.json` from a live world would have seeded defaults over real authority state** — the same widening the manifest exists to prevent, arriving from the other direction.

    manifest absent  + no authority store    → FIRST BOOT  (may initialize)
    manifest present + every store present   → EXISTING    (load truth)
    manifest present + store missing/damaged → SEALED
    manifest absent  + any store present     → ORPHANED    (SEALED, not seeded)

Falsifier asserts the store files still exist afterwards — refusing to initialize is worth little if the evidence is destroyed on the way to refusing.

---

## 4 · Sealed reads, and the state triple

Adopted. A sealed `CapabilityRegistry` was serving built-in pack surfaces — including the `source_data: private` policy that decides placement. Not a bypass (the gateway seals first), but you are right that sealed state must not invent content. Every registry has a `sealed_state/0` that is neutral and empty.

Your HEALTHY / SEALED / DOWN triple is the right vocabulary and I have used it in the docs. `Ampd.seals/0` enumerates SEALED; DOWN is OTP's business.

---

## 5 · `generation` — your ruling implemented exactly

Renamed from `store_generation` (manifest `schema_version` → 2). Advances only on wholesale replacement; a semantics-preserving migration moves `schema_version` instead. Restoring generation 3 into generation 7 yields **generation 8** with `restored_from_generation: 3`, never a rollback to 3. Falsified with that exact scenario.

---

## 6 · The release gate — you caught a real dishonesty

You were right and it was the sharpest small finding in your review. `release.sh` printed **"every gate green"** on your machine while skipping the BEAM replay.

`tools/release.sh` now **refuses** and exits non-zero with a named reason. `tools/preview-release.sh` is the honest degraded path: runs every browser gate, **cannot package**, and states plainly that the Elixir half is unverified. Both verified by running them with `mix` removed from PATH.

---

## 7 · Deferred by your ruling, and not built

- **SQLite** — after C1.1, before any real side-effecting adapter. Agreed and recorded.
- **Reconciliation contracts** (`native_idempotency` · `queryable` · `preallocated_id` · `manual` · `unsupported`) — accepted as the shape of RECONCILE, not built. There is no adapter to declare one, and inventing the enum before the first connector would be guessing at which strategies are real. Your point that UNKNOWN cannot be abolished is recorded; so is the correction that the key belongs to the effect, not the grant.
- **PackArtifactRegistry / InstalledCapabilityContract split** — accepted as the right long-term shape. Until it exists the whole capability registry seals, which is the conservative side.

---

## 8 · Open for the next ruling

1. **Does the lease need a ceiling?** Right now a claimed effect holds its lease until the adapter returns. With no adapters that is instant; with a real one, a hung connector holds a lease indefinitely. Options: a lease deadline after which the effect self-transitions to UNKNOWN (safe, since UNKNOWN is already unclaimable), or an explicit operator-cancel that can only move it to UNKNOWN, never to FAILED. I lean toward the deadline, because "we stopped waiting" and "it didn't happen" are different facts and only one of them is knowable.

2. **Should `decide/4` be public at all?** It consumes nothing and is genuinely useful for UI preflight ("would this be allowed?"), but a caller could show a verdict that is stale by the time the user clicks. Either it stays public and the projection must re-check on act (my assumption), or it becomes internal and the UI asks a `preflight` command that returns a verdict plus the snapshot it was taken under.

3. **Which channel do refusals go out on?** Given your two-channel split, a refusal naming `RECOVERY-STATE-MISSING` or `ORPHANED-WORLD` is operationally sensitive — it describes the state of the authority store. Does that belong on the general local channel (agents can see why they were refused) or only on the human control channel (agents get a generic refusal)? I lean toward naming it on both, because a refusal an agent cannot understand becomes a retry loop, but it is a real disclosure question.

---

## 9 · Ladder

    C1.0a   crash truth                                        ✓
    C1.0b   bootstrap truth + effect journal                   ✓
    C1.0b.1 authority linearization
            effect-key ≠ approval-digest
            orphan-world recovery
            mandatory BEAM release gate                        ✓  this round
    C1.1    typed UI projection
            private human-control channel
            SIMULATED → LIVE LOCAL                             ← next
    C1.1b   SQLite transactional persistence
    C1.2    FabricProvider.Tailscale
    C1.3    capability-derived network envelopes

Nothing in this round networks. Nothing pretends to. The badge still says SIMULATED, because it still is.
