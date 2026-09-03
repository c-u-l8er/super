#!/usr/bin/env bash
# The D.1.3c·2b freeze receipt.
#
# Written once and then frozen, unlike a review bundle — but the identities
# and tallies are still derived rather than typed, because a receipt that
# quotes a number nobody re-read is the drift defect this tree keeps finding.
#
#   bash tools/emit-freeze-d13c2b.sh <beam-sabotage.log> <host-sabotage.log>
set -euo pipefail
cd "$(dirname "$0")/.."

BEAM="${1:?beam sabotage log}"
HOST="${2:?host sabotage log}"
OUT=docs/reviews/D_1_3C_2B_FREEZE.md

need () { [ -n "$1" ] || { echo "REFUSING: could not derive $2" >&2; exit 1; }; }

FROZEN=$(git rev-parse HEAD)
TREE=$(git rev-parse HEAD^{tree})
SUBJ=$(git log -1 --pretty=%s)
SLICE=$(git rev-list -1 --grep='A terminal a Peer possesses' HEAD)
REV1=$(git rev-list -1 --grep='Six ways a commit could take' HEAD)
REV2=$(git rev-list -1 --grep='A comment that was false about its own supervisor' HEAD)
C2A=$(git rev-list -1 --grep='Answers that are the wrong shape' HEAD)
need "$SLICE" "the slice commit"; need "$REV1" "the first review commit"; need "$REV2" "the second review commit"

# The counts, not the line — a receipt that quotes "beam sabotage: N" inside
# a column headed "result" is repeating the label it is already under.
BEAMTALLY=$(grep -oE 'beam sabotage: .*' "$BEAM" | tail -1 | sed 's/^beam sabotage: //')
HOSTTALLY=$(grep -oE 'host sabotage: .*' "$HOST" | tail -1 | sed 's/^host sabotage: //')
need "$BEAMTALLY" "the beam sabotage tally"; need "$HOSTTALLY" "the host sabotage tally"

VERIFY=$(./host/target/release/super-host verify 2>&1 | grep -oE '[0-9]+ held · [0-9]+ failed' | tail -1)
need "$VERIFY" "the host acceptance tally"
TESTS=$(cd ampd && MIX_ENV=test mix test --seed 0 2>&1 | grep -oE '[0-9]+ tests?, [0-9]+ failures?' | tail -1)
need "$TESTS" "the ExUnit tally"

BEAMPROBES=$(grep -c '^probe "' ampd/tools/sabotage.sh)
HOSTPROBES=$(grep -c '^probe "' tools/sabotage-host.sh)
# **Excluding this receipt.** It is being written as this runs, so counting it
# would make every emission report a dirty tree — a number that is always the
# same is not a measurement.
DIRTY=$(git status --short -- . ':(exclude)docs/reviews/D_1_3C_2B_FREEZE.md' | wc -l)

mkdir -p docs/reviews
cat > "$OUT" <<EOF
# D.1.3c·2b — FROZEN

    frozen at   $FROZEN
    tree        $TREE
    subject     $SUBJ
    tree state  $([ "$DIRTY" = 0 ] && echo clean || echo "$DIRTY UNCOMMITTED PATHS")

The slice and the two review rounds it took:

    $SLICE  the slice
    $REV1  an adversarial review of it — six defects
    $REV2  a review of those repairs — five more, two of them the repairs' own

Audited from source against \`$C2A\` (c·2b·0a, items A–H).

## What is frozen

A Peer possesses a terminal attachment only after two ordered re-derivations
either side of a local owner transition. Owning the descriptor is not
possessing the terminal; neither is a record that says \`COMMITTING\`.

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

\`pty_epoch\` is machine-established physical identity bound at commit, and
never an admission-time World basis: the World agrees which **Carrier** may
be attached to, and the host answers which **terminal** that Carrier had.

## Tallies at the freeze

| gate | result |
| --- | --- |
| ExUnit | $TESTS |
| \`super-host verify\` | $VERIFY |
| BEAM sabotage | $BEAMTALLY |
| host sabotage | $HOSTTALLY |
| BEAM sabotage probes | $BEAMPROBES |
| host sabotage probes | $HOSTPROBES |

## Preserved explicitly at review's instruction

**1 · One unexplained ExUnit run.** A generation run of the review bundle
recorded \`492 tests, 1 failure\`. Its identity was not captured, because the
gate helper reported a tally and discarded failing test names; it records
them now. Every run since has been clean — the generation the bundle came
from, six consecutive runs at seed 0 after it, and eleven full-suite runs
across eleven distinct seeds during the slice. That is one in more than
twenty, with a cause we cannot name. It is preserved rather than re-run
until it went away.

**2 · The accepted \`recvmsg\` → adopt resource seam.** A process that dies
between \`recvmsg\` returning and the descriptor being adopted strands one
physical attachment attempt. It cannot produce a semantic attachment, Peer
possession, or PTY-master transfer. Accepted as a TCB resource-denial seam
rather than closed with a second native socket reader.

**3 · The accepted tree-wide registry-crash residual.** An ordered
transaction executes inside the \`Ampd.AuthorityCoordinator\` process, and
calls \`Ampd.Peer\`, \`Ampd.Loci\` and the other registries with synchronous
\`GenServer.call\`. A call to a process that dies mid-call exits the caller,
so a registry fault can become a control-plane discontinuity. This predates
D.1.3c and is not a terminal defect; it is the subject of the next slice and
was deliberately **not** special-cased here.

**4 · Normal death and registry failure are different facts.** An
\`Ampd.TerminalAttachment\` dying is the ordinary path — it is
\`restart: :temporary\`, the Carrier-removal funnel kills it, and it dies with
its owner. \`Ampd.Peer\` dying is a fault. Only the first is wrapped, and the
comment that once justified this by claiming a Peer crash invalidates the
whole incarnation was false: the supervisor is \`:one_for_one\` and starts
\`Ampd.Peer\` before the coordinator.

**5 · Nothing durable, and no new authority mechanism.** No durable terminal
ledger, no new durable store, no new authority store, no new supervised
child, no new mechanism class. A terminal attachment has a mechanical abort —
the runtime dying closes the socket endpoint and the host's pump ends — so
there is nothing for a boot sweep to reconcile.

## Not to be reopened

Host byte pump · attachment cardinality · Carrier/PTY/attachment physical
address · full-width attachment identities · \`SCM_RIGHTS\` framing ·
ctrunc-first sinking · immediate adoption · the accepted \`recvmsg\`→adopt
denial seam · PROVISIONAL byte refusal · the setup→ACTIVE monitor transition
· the fresh Carrier fixture builder · the sabotage restoration mechanism ·
the semantic possession contract established here.

Reopen only if a new executable falsifier proves the frozen result false.
EOF
echo "wrote $OUT"
