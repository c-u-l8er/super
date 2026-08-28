# C1.1.0 — projection boundary correctness · review brief

**Artifact: `and-super-rev-f3.zip`. Every gate green.**

Your ruling: *enter C1.1, but close three interface-level invariants (plus strict manifest validation) before the badge changes.* That is exactly this round's scope. The transport itself is deliberately **not** here — see §6.

---

## 0 · Measured

| | C1.0b.1 | C1.1.0 |
|---|---|---|
| conformance vectors | 39 | 39 |
| BEAM tests | 72 | **87**, 0 failures across 7 seeds |
| browser assertions | 60 | 60 |

Breakdown: 39 vectors + 5 bootstrap + **9 control** + 4 crash + 7 effect + **12 linearization** + **11 world**.

---

## 1 · You found a real bypass, and it was worse than "stale UI"

You were right that `decide/4` must not be public, and right about the stronger reason. Measured on the BEAM before fixing:

```
before: approvals=0 coordinator_ops=2
after : approvals=1 coordinator_ops=2
  CONFIRMED — decide/4 created a pending approval with ZERO coordinator ops

staled outside the order? status=stale ops_delta=0
```

So a bare `decide` both **created** a pending approval and **staled granted consent** outside the total order — directly contradicting C1.0b.1's own claim, in code whose docstring said "consumes nothing." It consumed no grant use; it definitely mutated the world.

Split as you specified:

```
preflight/4     advisory   creates nothing, stales nothing
request_effect  ordered    may open a proposal + pending approval
perform/5       ordered    re-checks, claims, acts
```

`preflight@1` returns `eligible · requires_approval · placement · observed_authority_snapshot · effect_key · advisory:true`. Two falsifiers pin it: preflight opens no approval and burns no coordinator op, and preflight does not stale a granted approval where the ordered path would.

`decide/4` is `@doc false` and refuses when called outside the coordinator.

---

## 2 · The registry boundary is mechanical now

Adopted exactly as you described — the caller PID in `handle_call`. An authority-bearing mutation is served only when the caller *is* `AuthorityCoordinator`; anything else gets `unordered-authority-mutation` and the state is untouched. Falsifiers call raw primitives on all five registries and assert both the refusal and that nothing moved.

Two things fell out of implementing it that are worth reporting:

**`handle_cast` had to go.** `CapabilityRegistry.install_postgres/update_github` were casts, and **a cast carries no caller** — the guard could not see who sent it. They are calls now. Pack policy is authority (`source_data`, secret residency decide placement), so a mutation that cannot be attributed cannot be ordered.

**A sealed registry now refuses instead of raising.** Previously a write to a sealed store raised. With the guard, that write arrives *from the coordinator* — so the raise would kill the total order along with the registry, and one lost store would become a node-wide outage. It returns `refusal@1` and there is a falsifier asserting the coordinator is still alive afterwards. This is a bug your ruling created and I would not have found without it.

---

## 3 · Fifth world state — you were right that presence ≠ validity

`{"foo":"bar"}` counted as an initialized world. Confirmed, then closed: `schema`, `schema_version`, `installation_id`, `initialized_at`, `generation` are validated by shape.

```
manifest absent  + no authority store    → FIRST BOOT
manifest valid   + every store present   → EXISTING
manifest valid   + store missing/damaged → SEALED
manifest absent  + any store present     → ORPHANED
manifest present but INVALID             → WORLD-META-UNTRUSTED
```

An invalid manifest seals, names which fields are wrong, and is **never overwritten** — it might be a real world's. Falsified with both a junk manifest and a truncated one missing only `generation`.

---

## 4 · Structured dual disclosure — adopted whole

Your `refusal@1` shape, implemented as specified. The falsifier asserts both directions in one test:

- general channel: `code`, `retryable:false`, `requires_human:true`, `public_message`, `correlation_id`; **no `operator_detail`**, and `reason` is replaced rather than trimmed, so the world id and store name do not leak through the free-text field.
- human control: the whole thing, including `operator_detail.seal`.

You were right that this beats either extreme — the agent learns "stop retrying, ask the operator" without learning the recovery topology.

---

## 5 · `approve_last` demoted; `approve_effect` requires both identities

`Ampd.Control.approve_effect(request_id, approval_id)` is the product API. It refuses `approval-identity-mismatch` when the two disagree — a failure `approve_last/0` **could not express**. Also refuses `approval-not-pending` (naming the actual status) and `approval-unknown`.

`approve_last/0` survives as a documented conformance helper only, because the frozen corpus drives it.

---

## 6 · What I did NOT build, and why

**The transport.** `Ampd.Control` defines the two channels and what each may issue, and the falsifiers prove an agent cannot approve, revoke, or recover. But `origin` is currently supplied by the caller, so **it is not yet a trust boundary** — it is the place the trust boundary goes. The moduledoc says this in those words, so nobody reads the channel split as authentication it is not.

Building the private inherited channel from the Tauri Rust host requires the Rust host, which is C1.1 proper. I would rather ship a boundary that is honest about being unenforced than a token in `world.json` that looks like security and is not — which is the thing you explicitly ruled out.

**Also deferred, per your rulings:** SQLite (after the projection, before any real adapter); the five reconciliation classes, recorded as mandatory-for-every-future-adapter but unbuilt since no adapter exists; the `PackArtifactRegistry` / `InstalledCapabilityContract` split.

**The execution lease** is accepted and unbuilt. Your correction landed — I had been sloppily treating it as "authority expires", and the right model is that the *authority* fact is frozen at CLAIM and what expires is the runtime's knowledge of the attempt. So: deadline after ATTEMPTED → `UNKNOWN` with `adapter-deadline-exceeded`, never FAILED; a late adapter return becomes reconciliation evidence rather than rewriting UNKNOWN → COMMITTED; `ABORTED_BEFORE_ATTEMPT` only where the journal proves the world was never touched; and no automatic restoration of a consumed approval or one-shot, because manufacturing authority during recovery is worse than burning a use. It is unbuilt because with no adapter every attempt returns instantly, so a deadline would be untestable theatre.

---

## 7 · Open for the next ruling

1. **Should `preflight` be rate-limited or budgeted on the general channel?** It is read-only and cheap, but it is also an oracle: an agent can enumerate what it *would* be allowed to do, including across resources it has no grant for. Refusals already name near-misses (`scope-mismatch · grant is for traaviis/trvm`), which is useful to a legitimate agent and is also a probe. Do near-miss names belong in the general projection of a *preflight*, or should preflight collapse to eligible/ineligible and keep the named near-miss for the ordered path?

2. **Does `projection@1` need field-level redaction too?** It currently returns whole grant objects, receipts, and the effect journal to the general channel. That is right for the Super UI and possibly too much for an arbitrary agent — a receipt names resources and placements. Same dual-projection treatment, or a separate narrower agent projection?

3. **What happens to a pending approval when its world seals?** Right now the approval survives (it is durable) and the gateway refuses everything, so it is unreachable but not marked. On unseal it becomes live again — which is arguably correct (consent was given) and arguably wrong (the human consented under an authority state we can no longer verify). I lean toward marking such approvals stale on unseal, since the snapshot they bound to cannot be re-derived, but it is a real judgement call and I would rather you rule it than pick.

---

## 8 · Ladder

    C1.0a    crash truth                                       ✓
    C1.0b    bootstrap truth + effect journal                  ✓
    C1.0b.1  authority linearization                           ✓
    C1.1.0   projection boundary correctness                   ✓  this round
             preflight read-only · mechanical coordinator
             boundary · WORLD-META-UNTRUSTED · dual refusals
    C1.1     Tauri host + private human-control transport
             SIMULATED → LIVE LOCAL                            ← next
    C1.1b    SQLite transactional persistence
    C1.2     FabricProvider.Tailscale
    C1.3     capability-derived network envelopes

The badge still says SIMULATED. It should, until the transport exists.
