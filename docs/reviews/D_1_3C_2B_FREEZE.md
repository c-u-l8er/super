# D.1.3c·2b — FROZEN

    frozen at   ee3d0bcea1700c177d67844908e891000a117c04
    tree        2b16fcf05664519c763c24afab0fc0a4b13ddc03
    subject     A comment that was false about its own supervisor, and a timeout that is an answer

    receipt emitted from  afd73fb4267a535126afd806a4d5e9cee84e0a7c
    tree state at emit    1 UNCOMMITTED PATHS

The slice and the two review rounds it took:

    e5eb56743b4854b433d257f44914aca7143e65cd  the slice
    c4160fd0686163ea46f62dbefc9a26f8b6e9f9bf  an adversarial review of it — six defects
    ee3d0bcea1700c177d67844908e891000a117c04  a review of those repairs — five more, two of them the repairs' own

Audited from source against `76516978bfa84057d179c0dbdc8a323f512a828b` (c·2b·0a, items A–H).

## What is frozen

A Peer possesses a terminal attachment only after two ordered re-derivations
either side of a local owner transition. Owning the descriptor is not
possessing the terminal; neither is a record that says `COMMITTING`.

    Peer ── occupies ──▶ Locus ── has ──▶ Worker ── embodied by ──▶ Carrier
                                                                      │
                                                            physically owns
                                                                      ▼
                                                                     PTY
                                                                      │
                                                       interactively possessed
                                                                   through
                                                                      ▼
                                                          TerminalAttachment

`pty_epoch` is machine-established physical identity bound at commit, and
never an admission-time World basis: the World agrees which **Carrier** may
be attached to, and the host answers which **terminal** that Carrier had.

## Tallies at the freeze

| gate | result |
| --- | --- |
| ExUnit | 492 tests, 0 failures |
| `super-host verify` | 284 held · 0 failed |
| BEAM sabotage | 103 falsified · 0 did not |
| host sabotage | 45 falsified · 0 did not |
| BEAM sabotage probes | 103 |
| host sabotage probes | 45 |

## Preserved explicitly at review's instruction

**1 · One unexplained ExUnit run.** A generation run of the review bundle
recorded `492 tests, 1 failure`. Its identity was not captured, because the
gate helper reported a tally and discarded failing test names; it records
them now. Every run since has been clean — the generation the bundle came
from, six consecutive runs at seed 0 after it, and eleven full-suite runs
across eleven distinct seeds during the slice. That is one in more than
twenty, with a cause we cannot name. It is preserved rather than re-run
until it went away.

**2 · The accepted `recvmsg` → adopt resource seam.** A process that dies
between `recvmsg` returning and the descriptor being adopted strands one
physical attachment attempt. It cannot produce a semantic attachment, Peer
possession, or PTY-master transfer. Accepted as a TCB resource-denial seam
rather than closed with a second native socket reader.

**3 · The accepted tree-wide registry-crash residual.** An ordered
transaction executes inside the `Ampd.AuthorityCoordinator` process, and
calls `Ampd.Peer`, `Ampd.Loci` and the other registries with synchronous
`GenServer.call`. A call to a process that dies mid-call exits the caller,
so a registry fault can become a control-plane discontinuity. This predates
D.1.3c and is not a terminal defect; it is the subject of the next slice and
was deliberately **not** special-cased here.

**4 · Normal death and registry failure are different facts.** An
`Ampd.TerminalAttachment` dying is the ordinary path — it is
`restart: :temporary`, the Carrier-removal funnel kills it, and it dies with
its owner. `Ampd.Peer` dying is a fault. Only the first is wrapped, and the
comment that once justified this by claiming a Peer crash invalidates the
whole incarnation was false: the supervisor is `:one_for_one` and starts
`Ampd.Peer` before the coordinator.

**5 · Nothing durable, and no new authority mechanism.** No durable terminal
ledger, no new durable store, no new authority store, no new supervised
child, no new mechanism class. A terminal attachment has a mechanical abort —
the runtime dying closes the socket endpoint and the host's pump ends — so
there is nothing for a boot sweep to reconcile.

## Not to be reopened

Host byte pump · attachment cardinality · Carrier/PTY/attachment physical
address · full-width attachment identities · `SCM_RIGHTS` framing ·
ctrunc-first sinking · immediate adoption · the accepted `recvmsg`→adopt
denial seam · PROVISIONAL byte refusal · the setup→ACTIVE monitor transition
· the fresh Carrier fixture builder · the sabotage restoration mechanism ·
the semantic possession contract established here.

Reopen only if a new executable falsifier proves the frozen result false.
