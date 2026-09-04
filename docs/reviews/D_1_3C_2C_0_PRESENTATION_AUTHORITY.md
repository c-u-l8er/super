# D.1.3c·2c·0 — Terminal Presentation Authority

**A proposal for ruling. Nothing here is implemented, and the byte plane is
stopped until it is ruled.**

Measured at `fe9a1e4ef39e23ffd9a889cac10f1b28c54f6a2b`, then re-checked and
re-numbered against the C1.0b·2·1 tree. Every claim below carries the source
it was read off — and a line number is the weakest form of that, so where a
symbol name identifies the same thing it is given instead.

---

## 0 · Why this document exists instead of a terminal

The D.1.3c·2c design proposes one entry point:

    open_terminal_stream(peer_ref, attachment_ref, attachment_epoch)
        docs/reviews/D_1_3C_2C_DESIGN.md:95

and resolves it by re-deriving *that the requesting Peer possesses that
attachment* (`D_1_3C_2C_DESIGN.md:186`).

The requesting Peer is the **cockpit**, which is a `:human_control` Peer.
The possessing Peer is the **agent**. They are not the same semantic owner,
and the design does not name the relation that would let the first act on the
second's terminal.

So the question was put to the source rather than to a design:

> What existing semantic authority relation in ampd permits the human-control
> Peer to observe or interact with an agent Peer's terminal?

**Measured answer: none exists.** Not a narrow one, not an indirect one. The
audit is §2. Under the standing instruction — *if none exists, stop and
return a narrow proposal rather than inventing one* — the data plane stops
here.

---

## 1 · What the human-control Peer actually is

    Peer.claim_control_channel/2      peer.ex:286
      id prefix    "pc-"              peer.ex:1024
      channel      :human_control     peer.ex:1029
      actor        nil                peer.ex:1032

with the load-bearing comment above that last line:

> the person is not an actor: they hold no grants and exercise no
> capabilities. They are the only source of consent.

The cockpit presents **no identity**. It presents a descriptor over
`SCM_RIGHTS`, and the runtime mints the Peer:

    cockpit/src/worker.rs:995      CockpitLoop::acquire()
    host/src/lib.rs:1840           bind_channel("bind_control_channel", None)
    ampd/lib/ampd/transport.ex:355 bind(:human_control, _) → claim_control_channel

Two consequences follow mechanically and neither is incidental:

1. **No actor ⇒ no occupancy.** `Worker.occupancy_of/3`'s first clause
   refuses on a nil actor (`worker.ex:466`, `no_actor/1` at `worker.ex:597`).
2. **No occupancy ⇒ no attachment ⇒ no terminal.**
   `Carrier.Terminal.admit_attach/1` refuses at its first gate,
   `carrier-not-attached` (`Carrier.Terminal.occupied/1`, `carrier/terminal.ex:311`).

So the predicate the 2c design would evaluate — *does the requesting Peer
possess this attachment* — is not merely false for the operator today. It is
**structurally false and always will be**, and a design that resolves an
operator request by evaluating it is a design that can only ever refuse.

---

## 2 · The audit: every cross-peer relation that exists

| # | relation | shape | keyed on | file |
|---|---|---|---|---|
| 1 | `approve_grant_request` / `deny_grant_request` | consent | `actor` string on the request | `authority.ex:114`, `:183` |
| 2 | `approve_effect` / `deny_effect` | consent | `request_id` + `approval_id` | `control.ex:652`, `:518` |
| 3 | `revoke_grant` / `revoke_capability_domain` | withdrawal | `actor` / capability / resource | `authority.ex:74`, `:87` |
| 4 | `open_worker` / `close_worker` / `reopen_worker` | **destructive supervision** | `worker_ref` | `authority.ex:295` |
| 5 | `reconcile_carrier_attempt` | ticket clearing | `ticket_id` | `control.ex:309` |
| 6 | operator projection | disclosure of **state** | world-complete | `projection.ex:69` |
| 7 | refusal disclosure (`operator_detail`) | disclosure of **refusals** | refusal id | `refusal.ex:140` |

**Not one of these is keyed on a `peer_ref`.** `peer_ref` appears only inside
`Ampd.Peer`, `Ampd.Carrier`, `Ampd.Carrier.Terminal` and `Ampd.Worker` — never
in a command field, never in a grant, never in a capability.

And three negative results that matter more than the table:

- **The projection carries no terminal-attachment fact at all.**
  `Ampd.Projection` names `Ampd.Carrier.Terminal`, `Ampd.TerminalAttachment`
  and `terminal_attachment` **zero** times. (It does contain the word
  `terminal` seven times, and every one is `Ampd.Effects.terminal?/1` — a
  terminal *effect state*, COMMITTED/FAILED/UNKNOWN. An earlier draft of this
  document said "contains the string `terminal` zero times", which is a
  different claim and a false one.) `Peer.terminal_attachments/0`
  (`peer.ex:509`) — the only enumerating accessor — has no production caller.
- **The whole semantic possession layer is unreachable from any wire.**
  `Carrier.Terminal.acquire/1`, `release/1` and `resize/3` have zero
  production callers; **none of `Ampd.CommandSpec`'s 35 commands** names a
  terminal, and none carries a `peer_ref`.
- **The byte layer has no caller check whatsoever.** `TerminalAttachment`'s
  `read`/`write` are gated only by the stream's own phase
  (`terminal_attachment.ex:370`). Possession of the pid *is* the
  authorisation, and the pid is confined by construction —
  `Peer.terminal_owner/1` is `@doc false`, "runtime machinery, not part of
  the relation" (`peer.ex:569`). **Any presentation API must supply the
  missing check itself. There is nothing at the byte layer to reuse.**

The nearest thing to a precedent is a refusal: `K.3`
(`test/terminal_possession_test.exs:334`) forges a ticket's `peer_ref` to a
second agent peer and asserts `carrier-attached-elsewhere` — produced by
structural re-derivation (`moved/1`), not by consulting a rule, because there
is no rule to consult.

### 2.1 One thing found in passing, and it is not a hole today

`Carrier.Terminal.resize_record/3` (`carrier/terminal.ex:1008`) takes a
`peer_ref` from its caller and operates on *that peer's* record, with no check
that the caller is entitled to name it. It is safe only because nothing on any
wire reaches it (§2, third negative result). **It becomes a confused deputy
the moment a command is added that passes a caller-supplied `peer_ref` to
it** — which is exactly what the current 2c contract would do.

---

## 3 · What must NOT be treated as the authority

Stated as refusals because each is a plausible mistake and three of them are
in the current design:

- **Bridge privilege.** The cockpit's channel is privileged for *binding*, not
  for reading another Peer's content.
- **Possession of a descriptor.** The whole point of `Ampd.NativeFd`'s
  confinement is that holding an fd is not a claim.
- **Knowing a `peer_ref`.** The operator projection already publishes every
  agent's `peer_ref` in `"peers"` (`projection.ex:89`). If knowing it were
  sufficient, the relation would already be granted to everyone who can read
  the projection, which is the definition of not being a relation.
- **Knowing an `attachment_ref`.** A fresh full-width identity is an
  unguessable *name*, not a capability. Treating it as one makes it a bearer
  token, which §6 refuses on other grounds too.
- **Being the main webview**, or being *called* human control.

---

## 4 · The proposal

### 4.1 The relation is to a WORKER, not to a Peer

    terminal-presentation@1
        subject    the human-control Peer (channel: :human_control)
        object     worker_ref
        content    the terminal attachment of whatever peer currently
                   occupies that Worker, resolved by ampd at use time

The operator designates `worker_ref`. ampd resolves

    worker_ref → current occupancy → occupying peer → that peer's
    terminal attachment → its stream owner

and refuses **by name** at every link that is absent, closed, stale by
generation, or occupied by a different attachment incarnation.

Four reasons this is the right object and `peer_ref` is not:

1. **It matches the grain of every existing relation.** All seven in §2 are
   keyed on a durable object id. None is keyed on an ephemeral runtime handle.
2. **The operator already commands exactly this object.** `open_worker`,
   `close_worker`, `reopen_worker` are human-control-only and take a
   `worker_ref` (`authority.ex:295`).
3. **The page never names another Peer**, so the confused-deputy shape in §2.1
   cannot arise: there is no caller-supplied `peer_ref` to trust.
4. **Re-derivation at use time is already how this tree stays honest.** A
   generation advance, a re-occupancy, or a Carrier replacement invalidates
   the resolution without anything having to be revoked.

### 4.2 It is a role predicate, not a grant

The human-control Peer holds no actor and therefore **cannot hold a grant** —
grants are actor-keyed (`grant_registry.ex:441`). So this relation cannot be
expressed in the grant algebra even in principle.

It does not need to be. The tree already has an enforcement point for exactly
this class: **15 commands are declared `channel: :human_control` in
`Ampd.CommandSpec` and enforced at `control.ex:108`.** The proposal reuses it
and adds nothing:

    new mechanism classes     0
    new authority stores      0
    new durable stores        0
    new grant kinds           0
    new command specs         1 or 2   (see §4.3)

### 4.3 Observe and drive are two different claims and should be ruled apart

- **`observe_worker_terminal`** — bytes flow terminal → operator.
- **`drive_worker_terminal`** — bytes flow operator → terminal.

The second is materially larger: writing to an agent's terminal is *acting at
the agent's position*, in a session whose shell state, working directory and
history belong to that agent's execution. It is the first thing in this tree
that would let the operator produce effects that are attributed to nobody —
the agent has an actor and the operator does not.

**Recommendation: rule `observe` now, defer `drive`.** A read-only pane is
the product-visible thing; a driveable one can wait for its own ruling.

### 4.4 The one thing genuinely being asserted, and it is a disclosure claim

Everything above is plumbing. This is the ruling:

> **Opening a position entails the right to observe what is executed at it.**

`Ampd.Projection` already says *"this is the person, and the world is theirs"*
(`projection.ex:93`) — but it says it about **state**: grants, effects,
receipts, lanes, workers. Terminal bytes are **content**: whatever the agent
read, wrote, or was shown, including file contents the operator has not
otherwise been disclosed and output from processes the operator did not run.

Extending "the world is theirs" from state to content is a real widening and
it should be decided rather than absorbed. Two things make it defensible and
neither makes it automatic:

- The operator already holds a **destructive** relation to the same object —
  `close_worker` kills the terminal through `Carrier.converge/1` →
  `release_terminal` (`peer.ex:1076`). Destroy without observe is an odd
  place to stand.
- The Worker is a position **the operator authored**. Nothing occupies it
  that the operator did not open.

And the argument against, stated as fairly:

- **Destroy does not imply read.** Ending a session discloses nothing;
  observing it discloses everything. They are not the same power and the tree
  has never conflated them.
- The agent's own projection is `actor`-filtered precisely so that actors do
  not see each other's work. This relation is asymmetric by design — but
  asymmetry is a decision, not a derivation.

**This is the ruling requested.**

---

## 5 · The page-facing contract, corrected

The design's contract lets the page assert facts. It should designate, and
nothing else:

    the page supplies    worker_ref            — already in its authorized projection
    the page NEVER supplies
                         peer_ref
                         attachment_ref
                         attachment_epoch
                         pty_epoch
                         carrier_ref / carrier_epoch
                         any descriptor

The presenter's identity comes from **the bound connection**, not an argument.
ampd resolves the peer, the Carrier, the PTY and both epochs internally, at
use time, on every operation.

Resize follows the same rule: the page supplies `rows` and `cols`, nothing
else, and the backend resolves the current attachment identity and calls the
existing semantic resize path (`carrier/terminal.ex:996`).

Note this is *narrower* than the current design in one more way: the design
has the page present an `attachment_ref` "it was given" (`:89`), which means
the control projection must first disclose one. Under this proposal the
control projection discloses **no new identity at all** — `worker_ref` is
already there.

---

## 6 · What it must not become

- **Not a bearer credential.** A presentation is an ephemeral binding of
  already-established authority. If holding the handle were sufficient, it
  would be portable, and a portable handle to another Peer's terminal is the
  §3 mistake with extra steps. Prefer the name `terminal-presentation@1` over
  "stream grant" for exactly this reason.
- **Not durable.** No presentation ledger, no boot recovery, no entry in any
  authority store. It dies with the connection, the Worker's generation, the
  Carrier, or the attachment incarnation — whichever goes first.
- **Not a second owner.** Closing a presentation must not close the
  underlying ACTIVE possession. The agent's terminal outlives the operator
  looking at it.

---

## 7 · Falsifiers this relation would need

Written now so the ruling can be judged on what would have to be proved:

1. A `:human_control` Peer that names a `worker_ref` it did not open is
   refused — **the confused-deputy falsifier**, and it must fail if the check
   is removed.
2. An `:agent` Peer that names any `worker_ref` is refused: this command is
   human-control-only and the channel check is where that is enforced.
3. Naming a Worker whose generation has advanced since the page last saw it
   is refused by name, not silently re-resolved to the new occupant.
4. Naming an open Worker that nothing occupies is refused
   `locus-not-occupied`, not answered with an empty stream.
5. The occupant changing mid-presentation closes the presentation. The
   operator does not silently begin watching a different agent.
6. `close_worker` during a presentation closes the presentation **and** the
   possession, in that order, and the falsifier reads both.
7. Closing the presentation leaves the ACTIVE possession intact and the agent
   still able to write to its terminal.
8. No `peer_ref`, `attachment_ref`, epoch or descriptor crosses to the page —
   asserted against the serialized payload, not against the call site.
9. The presentation appears in no durable store: a runtime restart finds
   nothing to recover, and the falsifier reads the stores rather than the
   absence of code.

---

## 8 · What is still open, and needs the ruling before any of it

1. **The §4.4 disclosure claim.** Does opening a position entail observing
   what is executed at it? Everything else is contingent on this.
2. **Observe now, drive later** — or both together?
3. Is `worker_ref` the right object, or should it be `locus_ref`? A Locus is
   the durable position; a Worker is the assignment at it. `worker_ref` is
   proposed because that is what `open_worker`/`close_worker` take.
4. Fan-out: one presentation per attachment is proposed for 2c. Spectators
   later, and a second operator is not a spectator — there is at most one
   human-control channel at a time (`peer.ex:668`).

---

## 9 · What is accepted from the 2c design, unchanged

The three-plane conclusion stands and is not reopened:

    AUTHORITY   ordered semantic state              ampd
    CONTROL     coalesced projection frames         cockpit
    DATA        lossless ordered terminal bytes     a dedicated plane

A coalesced snapshot may discard an old state because a newer one supersedes
it. A byte stream may not: `"hel"` then `"lo\n"` cannot legally become
`"lo\n"` because `"lo\n"` is newer. Terminal bytes must not ride the frame
stream, and the five reasons in `D_1_3C_2C_DESIGN.md:21-56` are all still
true.

Also carried forward, to be applied once §4.4 is ruled:

- **Both directions are ordered** — `OUT(seq)/OUT_ACK(seq)` and
  `IN(seq)/IN_ACK(seq)` in independent sequence spaces. The current design
  leaves input unsequenced and refers to a `§3.4` that does not exist.
  `IN_ACK` must mean the owning runtime path accepted the bytes, not that the
  frontend invoked a command.
- **The pane gets its own capability label**, not the parent window's. The
  primitive is already built and already gated: `SUPER_COCKPIT_PANE=1`
  creates a child webview `"pane"` holding no capability
  (`cockpit/src/main.rs:302`), and `tools/check-webview-acl.mjs` already fails
  if `windows:` returns to `capabilities/default.json`.
- **Backpressure is the page's ack, never a timer.**
- **No server-side scrollback; reopening starts empty.**
