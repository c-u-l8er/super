# D.1.3c·2d·0 — Terminal SHAPE and DRIVE, and where the effects go

**A proposal for ruling. Nothing here is implemented, and nothing in
D.1.3c·2c has an entry point for either power.**

The question this must answer, and it is not a plumbing question:

> A human with no actor causes a keystroke to reach a shell running at an
> agent's position. **Whose effect is that?**

---

## 0 · Why this is a separate slice and not a parameter

D.1.3c·2c·1a resolves one power — OBSERVE — and the two neighbouring ones
look like they should be the same mechanism with a different argument. They
are not, and the distance between them is not effort:

| power | direction | what it changes | ruled |
| --- | --- | --- | --- |
| **OBSERVE** | terminal → human | nothing in the agent's world | **2c·1a, GO** |
| **SHAPE** | rows/cols → PTY | raises `SIGWINCH`; programs relayout, some redraw, some re-read state | **deferred** |
| **DRIVE** | keystrokes → terminal | runs commands at the agent's position | **deferred** |

OBSERVE adds no cause to the agent's execution. The other two do, and the
runtime currently has nowhere to record who caused them.

`Ampd.Terminal.Presentation` has no `resize/3` and no `write/2`, so neither
can be reached by supplying a different argument to something that exists.
That is deliberate: a dormant page API is a decision nobody made.

---

## 1 · The hole, stated precisely

Every effect in this tree is attributed. `Ampd.Effects` records a proposal,
an authorization, an approval and a claim, each carrying the **actor** that
asked for it; `Ampd.Receipts` emits against that actor; `Ampd.GrantRegistry`
scopes authority by actor. The whole apparatus is actor-keyed.

**The human-control Peer has `actor: nil`**, and that is not an oversight —
`Ampd.Peer` states it: *the person is not an actor: they hold no grants and
exercise no capabilities. They are the only source of consent.*

So a keystroke the operator sends into an agent's terminal has:

- **no actor to attribute it to** — the operator has none;
- **an actor it would be attributed to anyway** — because whatever the shell
  does next happens inside the Carrier, under the agent's confinement, with
  the agent's grants, and every receipt it produces will say the agent's
  name.

That second line is the defect, and it has a name in this tree already:
**laundering**. `Ampd.Authority.approve_grant_request/2` exists because *an
agent asked* and *the person chose* must stay distinguishable; sharing the
grant draft destroyed that and it had to be rebuilt. DRIVE without
provenance recreates exactly that failure one layer down — the person acts
and the record says the agent did.

**SHAPE is the same shape, smaller.** A resize is not passive: it writes
`TIOCSWINSZ` and raises `SIGWINCH` in the foreground process group. A
full-screen program relayouts; some re-read terminal state; a program that
mis-handles it can corrupt its own display or exit. The operator has caused
a change in the agent's execution, and no receipt says so.

---

## 2 · What must be ruled, in order

### 2.1 Is an operator intervention an *effect*?

If yes, it belongs in the existing apparatus — proposed, claimed, committed,
receipted — and the whole question becomes "which actor". If no, it needs a
parallel record, and the tree gains a second way for things to have
happened, which is the outcome to avoid.

**Recommendation: yes, with a new actor kind.** The alternative — a private
intervention log — makes the agent's own history incomplete, and an
incomplete history is worse than an attributed intervention.

### 2.2 What actor does the operator act as?

Four candidates, and only the fourth survives:

| candidate | why it fails |
| --- | --- |
| the agent's actor | laundering, exactly §1 |
| no actor at all | the effect is unattributable; every receipt lies by omission |
| a fixed `"operator"` actor | works only while there is one human, which is the same assumption `T.10` is written to expire |
| **an actor minted for the human-control incarnation** | the person is not an actor and this does not make them one — it names *the intervention*, not the human |

The fourth needs care in the wording. It must not become "the person has an
identity in the world", because the whole consent model rests on them not
having one. What it names is a **channel incarnation acting at a position**:
ephemeral, minted when the presentation is bound, dead when it closes.

### 2.3 Does the agent learn it was driven?

**Recommendation: yes, and this may be the sharpest sub-ruling.** An agent
whose terminal was typed into and cannot tell is an agent whose account of
its own execution is wrong — and this tree's agents are asked to report
outcomes. `Ampd.Projection.agent/1` would carry the intervention the way it
carries approvals.

The argument against is real: a human debugging a stuck agent may want to
intervene without perturbing it. That is a preference; the agent reasoning
from a false history is a correctness problem.

### 2.4 Is SHAPE ruled with DRIVE or before it?

They differ by two orders of magnitude in what they can cause, and by
almost nothing in mechanism. Ruling SHAPE first buys a usable terminal
(`SIGWINCH` is what makes a full-screen program render correctly at all) at
a fraction of the authority.

**Recommendation: rule SHAPE first, as a narrow effect with the same
provenance record, and leave DRIVE until an application forces it.**

---

## 3 · What the implementation must not do

Stated as refusals because each is the cheap path:

- **Not reuse `Carrier.Terminal.resize_record/3` as a page-facing deputy.**
  It takes a caller-supplied `peer_ref` and operates on that peer's record
  with no entitlement check — safe today only because nothing on any wire
  reaches it. SHAPE must start from the authorized Worker presentation and
  resolve the terminal internally, exactly as 2c·1a resolves it.
- **Not add a `rows`/`cols` argument to anything in `2c·1a`.** The
  presentation resolves an observation; a power that changes the agent's
  world is a different relation and gets its own resolution and its own
  refusal names.
- **Not let the pane hold both.** A pane that can observe and drive under
  one capability makes the distinction a UI convention.
- **Not attribute by omission.** An effect with no actor field is not
  "unattributed", it is attributed to whoever reads it last.

---

## 4 · What it would cost, measured against what exists

| dimension | OBSERVE (2c·1a, shipped) | SHAPE + DRIVE (proposed) |
| --- | --- | --- |
| new semantic relation | 1 | 1 or 2 |
| new actor kind | 0 | **1** |
| new effect kind | 0 | **1** |
| new durable record | 0 | **1** (the intervention, receipted) |
| new authority store | 0 | 0 |
| agent-visible change | none | **the agent learns it was driven** |

The row that makes this a separate ruling is the third. OBSERVE was
implementable without touching the effect apparatus at all; neither of these
is.

---

## 5 · Falsifiers such a slice would owe

1. An intervention produces a receipt naming the intervening incarnation and
   **not** the agent's actor.
2. The agent's own projection shows the intervention.
3. A resize that changes nothing still records that it was attempted, because
   *the operator acted* is the fact, not *the geometry differed*.
4. An intervention after the Worker generation moved is refused, not
   re-targeted — the 2c·1a property, restated for a power that writes.
5. The pane's SHAPE capability does not confer DRIVE, asserted against the
   effective ACL rather than the capability source.
6. Removing the actor from the intervention record makes a receipt
   indistinguishable from one the agent produced — the laundering falsifier,
   and the one that must fail loudly.

---

## 6 · The recommendation, in one line

> Rule **SHAPE** as a narrow attributed effect with an ephemeral
> intervention actor minted per presentation, decide **2.3** explicitly
> because it is the one with a real argument on both sides, and leave
> **DRIVE** until an application asks for it.

Until then, the terminal a person can see is a terminal they cannot touch,
and that is a coherent product rather than a half-finished one.
