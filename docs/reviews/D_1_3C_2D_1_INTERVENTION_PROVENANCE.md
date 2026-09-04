# D.1.3c·2d·1 — Intervention provenance

**DESIGN ONLY. Nothing here is implemented.** This revises D.1.3c·2d·0 on
GPT's ruling: the laundering diagnosis is accepted, the proposed remedy — a
new *actor kind* for the human-control incarnation — is rejected, and what
replaces it is an **intervention activity** whose initiator is not a
principal.

---

## 0 · The finding that stands

D.1.3c·2d·0 measured this and it has not changed:

```
human types into an agent's terminal
        ↓
the agent's shell executes it
        ↓
every existing receipt says the AGENT did it
```

The human-control Peer holds `actor: nil` (`ampd/lib/ampd/peer.ex`, `claim/3`
— *"The person is not an actor: they hold no grants and exercise no
capabilities. They are the only source of consent."*). So a human acting at
an agent's position has **no actor to attribute the effect to**, and an actor
it would be attributed to anyway. That is provenance laundering, and
`approve_grant_request/2` exists precisely to prevent the inverse — a machine
becoming the source of consent.

## 1 · Why the remedy was wrong, in this codebase's own terms

The 2d·0 proposal was "mint a new actor kind for the human-control
incarnation." In this tree `actor` is not a label for a cause. It is the
**key of the authority namespace**, and it keys, at minimum:

| what it keys | where |
|---|---|
| grants | `Ampd.GrantRegistry` |
| capabilities | `Ampd.CapabilityRegistry` |
| effect requests | `Ampd.Effects` `effect-request@1`, field `actor` |
| receipts | `Ampd.Receipts` `capability-effect-receipt@1`, field `actor` |
| agent projections | `Ampd.Projection.agent/1`, literally `record["actor"] == actor` |
| Lanes | `open_lane`'s `actor` argument |
| Workers, occupancy | `Ampd.Worker.occupancy_of/3` |

Putting a provenance-only identity into that namespace means every one of
those has to be taught that one member of the namespace is not really a
member. That is the `X-Remote-Group` shape: a field that reads like
provenance becomes a credential the moment anything downstream keys off it.

**GPT's ruling is adopted: the human remains `actor: nil`.** That invariant
survives this slice unchanged.

## 2 · The shape, and the four systems that converged on it

Every audited system that has this problem carries **both identities in every
record** and never collapses to one:

| system | initiator | executing authority |
|---|---|---|
| Linux auditd | `auid` (loginuid) | `uid` / `euid` / `fsuid` |
| Kubernetes audit | `user` | `impersonatedUser` |
| AWS CloudTrail | `sessionContext.sourceIdentity` | `sessionIssuer` + session ARN |
| sudo | `SUDO_USER` | the target uid |

`auid` is the closest analogue and the one worth copying deliberately, because
of *why* it works. It is:

- **write-once** — settable once, then immutable (`CONFIG_AUDIT_LOGINUID_IMMUTABLE`,
  `auditctl --loginuid-immutable`, gated by `CAP_AUDIT_CONTROL`);
- **inherited by every descendant process**, so it survives `su` and setuid;
- **and it authorises nothing.** No kernel access decision ever reads it.

Those three together are the point. Its immutability is what makes it
evidence; its powerlessness is what makes granting that immutability safe.
An operator identifier that any permission check can read is not `auid`, it
is `X-Remote-Group` — and that is a documented, repeatedly-exploited class
(`kubernetes#119631`; the `X-Forwarded-For` CVE family; Google OIDC `sub`
inconsistency pushing SaaS onto `email`+`hd` as an identity key).

W3C PROV supplies the vocabulary, and it is a **three-way** split rather than
a two-way one:

- `prov:Activity` — *the intervention*: something that occurs and acts upon entities.
- `prov:Agent` — bears **responsibility** (PROV-DM §5.3.1).
- `prov:wasStartedBy(id; a2, e, a1, t, attrs)` — §5.1.6, whose **`trigger`**
  slot is literally "what started this activity" and is *structurally
  distinct* from responsibility.
- `prov:wasAssociatedWith` + `prov:hadRole` (§5.3.3, §5.7.2.3) — the spec's
  own example attaches two agents to one activity, discriminated only by
  role, where the operator has **no `prov:Plan`** and the designer has one.

That asymmetry is exactly ours: the agent is executing a plan; the operator's
keystroke is not part of any plan. **PROV describes; it does not authorise** —
nothing in PROV-DM or PROV-O makes `actedOnBehalfOf` an access-control input,
and nothing here should either.

## 3 · The record

```
terminal-intervention@1

  intervention_ref            iv_<hex>          runtime-minted
  kind                        SHAPE | DRIVE

  initiator:
    kind                      "human-control-incarnation"
    incarnation_ref           the control-channel incarnation
    control_peer_ref          the Peer id of that binding

  target:
    worker_ref
    worker_generation
    locus_ref
    actor                     the AGENT's actor, unchanged

  basis:
    world_incarnation
    world_generation
    presentation basis        attachment_ref / attachment_epoch / carrier_epoch

  request:                    operation-specific; for SHAPE, rows + cols
  outcome:                    ATTEMPTED | APPLIED | REFUSED | INDETERMINATE
  at:                         ISO-8601, for a reader, never read back as proof
```

The load-bearing invariant, and the falsifier for laundering:

```
initiator  ≠  target.actor
```

An intervention record where they are equal, or where `initiator` is absent,
is a record that has laundered a human act into an agent's history.

**What `initiator.incarnation_ref` is not**, stated so it cannot be quietly
promoted: it grants nothing; it owns no Worker; it cannot occupy a Lane; it
cannot bind a channel; it cannot exercise a capability; it is not an actor;
it is not a bearer credential; it is never page-supplied. It names the
control incarnation that caused an intervention and that is its whole job.
It may be durable as history even though the control channel was ephemeral —
which is the `auid` property: the login is over, the number stays.

**Where the four outcomes come from.** They are C1.0b·2's, not new:
`Ampd.Participant`'s measured classes, where `INDETERMINATE` means *the reply
was lost and the work may be about to happen* — not *it did not happen*.

## 4 · C2 · Where the record goes — three designs, audited against the source

### The audit

**`Ampd.Effects` (`effect-request@1`)** is a state machine around an
*actor-authorized capability effect*. Its fields, from `handle_ordered({:propose, env})`:
`idempotency_key`, `approval_digest`, `capability`, `pack`, `actor`,
`resource`, `request_id`, `request_revision`, `request`, `grant_ref`,
`approval_ref`, `authority_snapshot_at_entry`, `placement`, `attempts`,
`history`, `state`. Around them: `claim`, in-flight and terminal state sets,
and a reconciliation path for `UNKNOWN` whose comment says the adapter *"may
already have changed the world; re-claiming it is precisely the double-effect
this machine exists to prevent."*

A SHAPE intervention has **no** actor grant, **no** capability grant, **no**
pack authority, and **no** approval request from an agent. Six of those
sixteen fields would be fabricated.

**`Ampd.Receipts`** is a flat append-only ledger — `%{"log" => [...], "seq" => n}`,
ids `rcpt-NNNN`, one dets table, in `Ampd.seals/0` and therefore in the
world's seal/recovery surface. And the decisive measurement:

> `Receipts.emit/1` does
> `Map.merge(%{"kind" => "capability-effect-receipt@1", "id" => id, "committed" => true}, m)`
> — **merge order means the caller's own `kind` wins**, and
> `Ampd.Locus.emit_receipt/5` already uses that, emitting
> `"worktree_created@1"` into the same ledger.

So `Ampd.Receipts` is **already a multi-kind causal journal**. It was not
described as one, and that is the only thing the third design changes.

### The comparison

| | 1 · generalise `Ampd.Effects` | 2 · a new intervention journal | 3 · a kind in `Ampd.Receipts` |
|---|---|---|---|
| pre-effect durability | yes | yes | yes (append before the attempt) |
| lost-reply ambiguity | `UNKNOWN` + reconciliation | must be rebuilt | **repaired by re-observation** (§5) |
| reconciliation | reuses `claim`/`attempts` | new | not needed for SHAPE |
| new stores | 0 | **1** (dets, seal, boot, recovery) | 0 |
| new mechanism classes | 0, but the machine is re-specified | **≥1** | 0 |
| projection filtering | `actor` filter reused — **and it is wrong here** | new | `actor` filter reused **correctly** (§6) |
| boot recovery | reuses | new seal, new recovery path | reuses |
| proof surface | large: every `Ampd.Effects` falsifier is now about two unlike things | large: a whole store to falsify | small: one new kind, existing ledger laws |
| schema honesty | **fabricates six fields** | honest | honest |
| future DRIVE | inherits a machine built for the wrong thing | free hand | free hand (§7) |

### Recommendation: **design 3**, and the reason is idempotency

`Ampd.Effects`' machinery exists for effects that **cannot be re-observed**.
That is why it needs `UNKNOWN`, `attempts`, and a reconciliation path: after a
lost reply there is no way to ask the world what happened, so the state
machine has to carry the ambiguity.

SHAPE is not that kind of effect, and this is checkable at kernel source
rather than assumed. `tty_do_resize()` in `drivers/tty/tty_io.c`:

```c
if (!memcmp(ws, &tty->winsize, sizeof(*ws)))
        return 0;                       /* no signal, no state change */
kill_pgrp(pgrp, SIGWINCH, 1);
tty->winsize = *ws;
```

So `TIOCSWINSZ` with the current dimensions is a **true no-op** — no
`SIGWINCH`, no change, return 0 — and `TIOCGWINSZ` reads the applied state
back. `ioctl_tty(2)` agrees: the signal is sent "when the window size
*changes*". SHAPE is therefore idempotent *and* externally observable, so a
lost reply is repaired by **re-reading the geometry and re-applying**, not by
an `UNKNOWN` that must be reconciled.

Adopting `Ampd.Effects` would buy a reconciliation machine for a problem that
does not exist here and would require lying about six fields to get it. GPT's
instruction was to prefer the smallest design that does not lie about
existing schemas; that is design 3.

**The residual is stated, not hidden.** Design 3 is right *because* SHAPE is
idempotent. It is therefore **not** automatically right for DRIVE, and §7
says so rather than assuming the extension.

## 5 · The invariant that is actually shared

GPT is right that "a second way for things to have happened" is a hazard, and
right that squeezing unlike things into one schema is not the fix. The
common law is at a level above both:

> **Every causal action that can change execution must have durable
> provenance sufficient to distinguish initiator, target, basis, attempt and
> outcome.**

Capability effects are one class of that. Operator interventions are another.
They may one day share a general causal substrate; nothing requires
refactoring `Ampd.Effects` into one before a terminal can be resized.

## 6 · C3 · Agent visibility — the ruling

> **An agent MUST be able to learn that human intervention affected its
> execution.**

If a human changes an agent's execution and the agent reasons from a history
that omits it, the agent's causal account of its own run is false. That is a
correctness property, not a courtesy.

**Semantic history, not attention.** Two different things:

```
must appear in the agent's semantic history       YES
must interrupt or inject into the model's context NO
```

The surface is a bounded `interventions` list on the agent projection,
windowed like receipts and effect history (`Ampd.Projection.window/1`). It is
keyed on **`target.actor`**, which is the agent — so `Ampd.Projection.agent/1`'s
existing `record["actor"] == actor` filter is reused *correctly*: the agent
sees interventions aimed at it.

**The agent must not be able to query by initiator.** The human-control
incarnation is not an actor, has no projection, and asking "what else has this
initiator done" is asking the runtime to treat a provenance identifier as a
principal — the exact failure §2 is about. Interventions are visible to their
target and to the operator projection, and by no other index.

Whether an intervention *deserves* immediate attention is a harness
scheduling decision, made from a fact that is now available. It was not
available before, and that was the defect.

## 7 · C4/C5 · SHAPE first, DRIVE deferred

### SHAPE (next, after D.1.3c·2c·1b)

Narrow, and it unlocks correct full-screen rendering. The page supplies:

```
worker_ref
expected_worker_generation
rows
cols
```

and its bound control/presentation context. **Never a caller-supplied
`peer_ref`.** `Ampd.Carrier.Terminal.resize_record/3` takes one today and
operates on that peer's record with no entitlement check — safe only because
nothing on any wire reaches it, and a confused deputy the moment a command
passes one through. SHAPE must resolve the terminal internally from the
already-authorised presentation, exactly as D.1.3c·2c·1a's chain does.

One record per attempt, `kind: SHAPE`, appended before the ioctl is
requested, settled to `APPLIED`/`REFUSED`/`INDETERMINATE` after — with
`INDETERMINATE` resolvable by re-observation, which is the property §4 rests
on.

### DRIVE (deferred, and this is why)

**Input is not idempotent.** `"rm -rf "` sent twice is not `"rm -rf "` sent
once. The prior art is mosh (Winstein & Balakrishnan, USENIX ATC '12), and
its answer is worth stating precisely because it is not the obvious one:

> mosh does **not** make input idempotent. It makes the *carriage* of input
> idempotent. The client→server object is `UserStream`, an append-only
> `deque` of `UserEvent`s, and every datagram is an **absolutely addressed**
> diff ("state 41 → state 57"). A duplicate re-applies the same absolute
> transition and is a no-op; a loss is repaired by a later diff from a live
> reference state. The screen direction may skip intermediate states; the
> input direction *"Nothing is omitted."*

Note also that mosh carries **resize inside the same `UserStream`** as
keystrokes — consistent with §4: replaying a redundant resize costs nothing.

**And DRIVE has a second problem that is not a transport problem.** Raw
terminal input contains secrets. The surveyed products are unanimous, and
their agreement is the finding:

| | default for stdin |
|---|---|
| Teleport session recording | **not captured** — "recordings typically do not contain passwords entered into a terminal"; desktop recording captures screen, not keystrokes |
| RHEL `tlog` session recording | **disabled by default**, "to avoid intercepting raw passwords"; enabling it captures them in plaintext |
| `script(1)` | output only; `-I`/`--log-in` is opt-in and warned twice: input is logged **independently of the terminal echo flag** |
| sudo `log_input` | captures input "even when not echoed"; 1.9.10 added a *heuristic on output text* to hide password prompts |
| AWS SSM Session Manager | the outlier — logs entered commands; mitigation is telling the operator to type `stty -echo` |

The argument, in one line: **terminal echo state is a property of the
terminal, not of the recorder**, so a recorder on the input path captures the
password precisely in the case where the terminal hid it.

Teleport's response to the resulting blind spot is the architecturally
interesting one, and it is the direction to take: it does **not** start
recording stdin. It moves the observation point *down* a layer — Enhanced
Session Recording emits `session.command` / `session.exec` / `session.network`
from BPF. Commands without password prompts.

So the DRIVE design must rule, before any implementation, on what is
retained:

```
raw bytes            ← rejected on the above evidence unless something changes
digest of the bytes  ← still a password oracle for short/guessable inputs
byte count
sequence range
redacted semantic operation
```

**A provenance mechanism must not become a durable keystroke logger while
trying to solve attribution.** That question is mandatory before DRIVE, and
answering it is a slice of its own.

## 8 · What this slice does not decide

- The exact field names. They are provisional and must be derived from the
  tree at implementation time, as `terminal-attachment@1` was.
- Whether interventions eventually share a substrate with `Ampd.Effects`.
  §5 says they may; nothing here requires it.
- Multiple human identities. Today "the human-control role" and "this human"
  are the same thing because `Ampd.Peer` refuses a second control channel —
  asserted by `Ampd.TerminalPresentationTest`'s `T.10`, written to fail
  loudly if that ever stops being true. When it does, `initiator` gains a
  field; it does not become an actor.

---

### Sources for the external claims above

- W3C PROV-DM §5.1.6 (`wasStartedBy`), §5.3.1 (Agent), §5.3.3 (Association,
  `prov:role`, `prov:Plan`), §5.3.4 (Delegation) — https://www.w3.org/TR/prov-dm/
- PROV-O qualified pattern (`prov:qualifiedAssociation`, `prov:hadRole`) — https://www.w3.org/TR/prov-o/
- `audit_setloginuid(3)`; `auditctl(8)` `--loginuid-immutable`; `CONFIG_AUDIT_LOGINUID_IMMUTABLE`
- Kubernetes `audit.k8s.io/v1` `user` / `impersonatedUser`; user-impersonation docs
- AWS CloudTrail `userIdentity` / `sessionContext.sourceIdentity`; "How to relate IAM role activity to corporate identity"
- `tty_do_resize()`, `drivers/tty/tty_io.c`; `ioctl_tty(2)` / `TIOCSWINSZ(2const)`
- Winstein & Balakrishnan, *Mosh: An Interactive Remote Shell for Mobile Clients*, USENIX ATC '12
- Teleport session recording + Enhanced Session Recording (BPF); RHEL 8 session recording (`tlog`); `script(1)`; sudo 1.9.10 password hiding; AWS SSM session logging
- Provenance-identifier-as-credential: RFC 6749 §2.2; `kubernetes#119631`; F5 "Security Rule Zero: A Warning about X-Forwarded-For"
