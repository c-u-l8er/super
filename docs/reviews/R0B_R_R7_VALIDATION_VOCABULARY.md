# R0b.R · R7–R13 — the durable vocabulary for validation work

**Status: GO proposed, R0b.R·1 included.** GPT returned GO on the vocabulary
and REVISE on one producer-boundary hole; §4b is that closure. Super can name one bounded validation job over its own
source and durably record that it started and how it ended, with execution
outcome, predicate verdict, subject visibility and record kind remaining
semantically distinct.

Nothing here executes a predicate inside a Carrier. That is R0b.1.

---

## 0 · the parent, and why it is not the shared HEAD

The shared checkout moved to `f3e1a7b` and then `4da0b01` while R2–R6 was
landing, both `site/` commits from a parallel session. Neither touches the
ledger, but an evidence tree that moves underneath a semantic-schema slice is
an evidence tree that cannot be named.

So this round ran in a **detached worktree at the exact R2–R6 tip**:

```text
worktree     /home/travis/ProjectAmp2/super-r7
parent       78b19e8  An agent could not see the establishment of its own worktree
tree         3c21126022e0bd5289920c39d199caeb2a88d24d
```

Reconciliation is trivial and is stated rather than deferred: `git diff
78b19e8..4da0b01` is `site/amp-nav.js` and `site/index.html`, 12 insertions,
6 deletions, zero files under `ampd/`, `host/`, `tools/` or `cockpit/`. This
branch can be merged to the shared HEAD without interaction.

**A second isolation was needed and git does not provide it.** `config/config.exs`
set the test data dir to the fixed absolute path `/tmp/ampd-test-data` and
`rm -rf`'d it at config load. Every checkout on this machine shared it, so two
suites running at once deleted each other's world mid-run — and what that
produces is ordinary-looking red rows. Measured here: `locus_test.exs` reported
**30 failures of 54** while another suite was running, and **0 of 54** on the
identical tree moments later.

**Fixed, and not by this session.** A parallel R7 session hit the same wall,
measured it more carefully — *11 failures across four files against the shared
path, 0 against a private one, same commit, same seed* — and repaired it. That
fix is merged here verbatim: the directory is now per-run, keyed on the OS pid,
with `AMPD_TEST_DATA_DIR` for a caller wanting a known location. Their note is
the one worth carrying: it cost them a wrong diagnosis first, because the spread
looked exactly like a regression in the change under test. It cost this session
two hours of the same.

Every number in §6 was still taken with nothing else running, because the
batteries predate the fix.

### the other session

`main` reached `a43ccfc` with an **independent implementation of this same
brief** — R7, R8 and R10, `validation-job-started@1` /
`validation-job-outcome@1`, states `COMPLETED · FAILED · SOURCE_BASIS_MISMATCH`,
verdicts `HELD · REFUTED`, free-form `detail`, `worker_ref` as the only subject.

Travis ruled for this branch's vocabulary. The reason is narrow and worth
stating rather than assuming: it is GPT's exact ruling, including the part
`a43ccfc` departs from — **a source-basis mismatch is not a third value beside
"it completed" and "it failed"**; it is the reason a failure has. Promoting one
reason to a state makes the enum's members answer two different questions, which
is the collapse §2 exists to refuse.

That is a naming ruling and nothing more. The other session's `config.exs` fix
and two of its falsifiers are merged in and attributed; its test file, whose
nineteen cases exercise the retired vocabulary, is removed.

---

## 1 · the naming ruling, taken

Two append-only kinds:

```text
validation_job_started@1     execution began
validation_job_outcome@1     how that attempt ended
```

Nothing mutates the first into the second. A START with no OUTCOME is a
truthful historical state — the honest representation of a Carrier that died
mid-job — and it is strictly more informative than an `INDETERMINATE` invented
to fill the row, which would additionally be a *claim*, made by a process that
was not there, about a moment nothing observed.

There is no `INDETERMINATE` in this vocabulary. If a later round finds an
execution cut where a durable outcome is genuinely required despite the truth
being unknowable, it can name one then, with the cut as its argument.

### three vocabularies, kept apart

```text
kind             the RECORD's type    validation_job_started@1
validation_kind  the WORK's type      source-hygiene
state / verdict  how it WENT          completed · pass
```

`kind` belongs to `Ampd.Receipts` and names a row shape. `validation_kind`
names what was checked. Writing `kind = source-hygiene` would leave no way to
tell a start from an outcome at the ledger layer, and no room for the progress
or evidence records a later round may add.

---

## 2 · state and verdict are orthogonal

| what happened | state | verdict | reason |
|---|---|---|---|
| ran · no NUL in scope | `completed` | `pass` | — |
| ran · a NUL in an in-scope file | `completed` | `fail` | — |
| the materialization moved or is dirty | `failed` | — | typed |
| the Carrier died | **STARTED, and no OUTCOME** | | |

Finding a NUL is the job **succeeding at its purpose**. Flattening these into
one enum — `PASS | FAIL | SOURCE_BASIS_MISMATCH` — puts "the property does not
hold" and "we could not ask" at one semantic level, and then every reader
downstream must know which members are verdicts and which are excuses.

Worse, a basis mismatch recorded as `fail` is a **false statement about the
source**: it asserts a property of bytes that were never read.

Both directions are refused rather than stored with the extra field dropped —
a completed outcome carrying a `reason`, and a failed outcome carrying a
`verdict`, are each `validation-outcome-overspecified`. Silently dropping the
extra field would make the ledger disagree with its writer about what was
recorded.

### the failure-cut table — every reason is quoted, none is invented

| reason | producer, today |
|---|---|
| `source-basis-unknown` | `Ampd.Validation` — a basis the store cannot resolve; reachable whenever the worktree store is sealed between a start and an execution |
| `source-basis-revision-not-exact` | `host/src/effect.rs` — not a 40-char lowercase object name |
| `source-basis-materialization-absent` | `host/src/effect.rs` — the directory is gone |
| `source-basis-materialization-unresolvable` | `host/src/lib.rs` — `canonicalize` failed |
| `source-basis-revision-moved` | `host/src/effect.rs` — `rev-parse HEAD` is not the bound commit |
| `source-basis-materialization-dirty` | `host/src/effect.rs` — `status --porcelain` is non-empty |

**Deliberately absent**, each because nothing can produce it yet:

* `scope-mismatch` — nothing re-derives a scope manifest at execution time
  until R0b.1. When it does, the cut is real and gets a name then.
* `carrier-failure` — this round starts no Carrier, and a death during
  execution is already represented, as a start with no outcome.

Admitting either would make the enum a wish list. A reason outside the set is
**refused**, not recorded; an enum that accepts anything is a comment.

The host's four cuts are kept apart rather than collapsed into one
`source-basis-mismatch`, because `verify_source_basis` already argues in its
own docs that they are independent: *"a clean worktree at the wrong commit
passes the second and fails the first; a dirty worktree at the right commit
does the reverse."*

---

## 3 · identity, subject and visibility

### JobBasis — `validation-job@1`

```text
ref                vj_NNNN
validation_kind    source-hygiene          closed enum
source_basis_ref   sb_NNNN
scope_digest       64 lowercase hex
actor              the Lane's, never the caller's
worker_ref         wk_NNNN
worker_generation  integer
```

No executable, no argv, no environment, no host path. The job says *what
validation work exists over what exact semantic input*; it does not say what
binary to run. Implementation identity stays `ExecutionBasis` and the installed
payload, measured through the running Carrier's own `/proc` — a stronger
statement than any field here could carry.

**`worker_generation` is bound, and that is derived rather than added.**
`Ampd.Worker.reopen/1` advances `generation`, and its own docs say why: *"a
reopened position is grounds for a new attachment, never for reviving an old
one."* `still_standing/1` already refuses `attachment-worker-generation-stale`
on that basis. A job recording only `worker_ref` would name a position that
could be closed and reopened between its start and its outcome, and the two
records would read as one continuous position having done the work.

**Where the jobs live.** In the worktree store beside `bases`, not in a store
of their own. A job names an `sb_` which names a `wt_` which names an `rp_` —
one chain, and this store owns the rest of it. Co-locating makes them **seal as
one fact**: a job in a separate durable store could be served while the basis
it names was unreachable, and a reader would see a job over a snapshot that no
longer resolves without anything having failed. It also adds no authority
store, so `Ampd.World.authority_stores/0`, the seals report and the recovery
manifest are unchanged.

### R8 · subject

Validation records **are** subjected by top-level `actor` — approved, and
earned separately rather than assumed. `worktree_created@1` names a Lane's
actor (`locus_actor`, the actor a Lane *belongs to*); a validation is work
performed by the Actor *occupying* a Worker, which is what `actor` has always
meant on a capability receipt. R6 is the record of what happens when a
projection assumes the answer instead of deriving it.

No `initiator`, `control_peer` or `terminal_peer`. Human-vs-agent causal
intervention provenance belongs to the later SHAPE/intervention design.

### R9 · typed projection, no cockpit renderer

One key, `validations`, holding **both** kinds ordered by `seq` — a start and
an outcome are one lifecycle read in order, and two windows would let a reader
page past the outcome of a start it had not seen. `history_for(:validations, …)`
is typed identically so the paged command and the frame agree.

The R1 census established that nothing shipped renders the durable ledger. No
renderer was built: doing so would invent the consumer whose absence made
splitting the key safe. The cockpit may ignore the field.

### the third defect — two windows handing out a cursor nothing could redeem

`Ampd.Projection` states a rule in its own docs:

> Every window a projection hands out has a `next_cursor`, and every one of
> them needs a command that can follow it — a cursor with nothing to give it
> to is a promise the protocol does not keep.

**R6 broke it in the round that split `receipts` by kind.** It added the
`worktree_receipts` window and `history_for(:worktree_receipts, …)` and no
door — in the very round whose finding was that an agent could not see the
establishment of its own worktree. It could see it in the frame and could not
page it. R7 would have done exactly the same thing again with `validations`.

So both commands now exist: `list_worktree_receipts` and `list_validations`,
`channel: :both`, `kind: :read`, `retry: :safe`, the shape `list_receipts`
already had. The filter is `history_for/2` — reused rather than restated, so
`worktree_receipts` stays subjected by `locus_actor` and `validations` by
`actor` without either rule being written twice. **No new authority**: a record
an agent cannot see in its frame cannot be paged to here either, asserted.

The suite checks the **rule**, not the two cases: it walks the agent projection
for every key carrying a `next_cursor` and requires a command for each. That is
what makes the next omission visible rather than found a round later.

And a gate caught the half of this that was got wrong. `cockpit_test.exs`
derives its expected read list from `CommandSpec.reads/0` and refused both new
commands as *"declared in command-spec@1 and never exercised here"*. Adding a
read and forgetting to frame it is caught by that assertion and by nothing
else, because an unframed reply simply has no cursor and a client cannot tell a
missing cursor from an unchanged one.

---

## 4 · creation authority — R12's alternative, not R12's command

`Ampd.Authority.start_validation_job/1`, ordered, with **no `Ampd.CommandSpec`
entry** — exactly like `bind_source_basis/1`, and for a sharpened version of
its reason. The chain is `SourceBasis → one read capability → Carrier`, and the
*job* is the link that causes the derivation: R0b.1 resolves a job's
`source_basis_ref` into the `source_basis` object the host verifies and confines
over. So whoever mints a job decides what a confined process sees.

An agent command would let a Carrier name any bound `sb_` and obtain a read
capability over it. The ownership check narrows that, but **a check is not a
reason to open a door**. R12 offers the alternative — *prove the design can use
the existing Authority path without adding an agent command* — and that is what
is taken.

Whether an Actor may **request** a bounded job against a basis already granted
to its own Worker is a real question and a separate one. It is not answered by
these fields being safe, and it is not answered here.

### the ownership check

A basis binds a `wt_`; a `wt_` was established from exactly one Lane's worktree
capability; a Worker belongs to one Lane. A job whose Worker sits in a different
Lane is a job about someone else's snapshot — `validation-job-lane-mismatch`. A
basis no capability claims is a broken chain rather than an ownership
violation, and gets its own name: `source-basis-unowned`.

### R11.2 · the durable start precedes execution

`start_validation_job/1` mints the job and appends STARTED in one ordered
transaction, and `Validation.admissible?/1` is false without a durable start.

Nothing rolls back, because nothing can: two durable stores, no two-phase
commit. So the **failure is designed to land on the side that refuses
execution**. Mint-then-append leaves, on ledger failure, a job nothing may
execute. Append-then-mint would leave a start naming a job that does not exist.

### the outcome refuses to be recorded out of order, structurally

`Receipts.emit` is deliberately **not** an ordered op — a ledger append is not
an authority mutation, and making it one would put every receipt through the
total order for nothing. So nothing about the store stops a direct
`Validation.record_outcome/2` from racing.

But every check that function makes is a **read of the ledger followed by a
write to it** — *a start is durable*, *no outcome yet* — and an unordered pair
of those races a concurrent append of the very record it is looking for. Two
contradictory terminal outcomes for one `job_ref` is exactly what that race
produces.

So `record_outcome/2` refuses unless `Ampd.Participant.inside?()` —
`unordered-validation-outcome`. Requiring it there rather than trusting callers
to go through `Ampd.Authority` is the difference between a guarantee and a
habit. `Ampd.Worker.close/1` is the same shape one layer down and does trust
its callers; it returns `{:ok, <refusal>}` to anyone who does not, which is §9.3.

---

## 4b · R0b.R·1 — the invariants move to the ledger

GPT's REVISE, and it was right. Everything in §4 held **only if every caller
chose to enter through `Ampd.Validation`**. `Ampd.Receipts.emit/1` let a caller
pick the `kind`, and `Ampd.Validation` read validation truth back out of the
ledger *by kind alone*. So:

```elixir
Receipts.emit(%{"kind" => "validation_job_started@1", "job_ref" => "vj_fake"})
```

minted a durable validation START for a job that does not exist — no JobBasis,
no SourceBasis, no Lane, no Worker — and `admissible?/1`, which asked only *is
there a start and no outcome*, then answered **true** for it. Reproduced before
it was fixed:

```text
forged record minted   rcpt-0007 · validation_job_started@1
JobBasis for vj_fake   nil
admissible?(vj_fake)   true   <-- a receipt created executable work
```

**This round's own suite contained that call.** It arrived as a ported case from
the other session, was rewritten to fit this vocabulary, passed, and was
evidence of the defect the whole time. That is the strongest argument available
for the rule GPT keeps applying: *"the intended caller goes through the boundary"
is not the same sentence as "the boundary enforces the property"*.

### the shape of the fix

`emit/1` refuses `Ampd.Validation.kinds/0` by name —
`receipt-kind-requires-typed-admission`. **Refused, not silently re-kinded and
not dropped**: rewriting the kind files the caller's record somewhere it did not
ask for, and dropping it loses a write with no explanation.

The protected kinds are reachable only through two store-owned appends:

```text
Receipts.record_validation_start(job_ref)
Receipts.record_validation_outcome(job_ref, result)
```

**Not a flag.** Nothing consults a `producer` field, an `internal: true`, the
process dictionary, or the calling module — every one of those is something a
caller can supply or arrange, which makes the guard a convention wearing a
check's clothes. The protection is structural: the protected kinds are reachable
only through a *different message*, and `{:emit, m}` refuses them.

**A ref, never a job.** `record_validation_start/1` takes a string and resolves
the JobBasis in its own body. A caller that could hand in a job map could hand in
a forged one, and the store would be back to trusting its input. Every semantic
field on the START — `validation_kind`, `actor`, `worker_ref`,
`worker_generation`, `source_basis_ref`, `scope_digest` — is the durable job's,
and there is no parameter through which a different value could arrive. The
OUTCOME's subject comes off the START the same way. Even
`Ampd.Authority.start_validation_job/1`, which is holding the freshly-minted job,
passes only `job["ref"]`.

### atomicity, and why the coordinator is still required

The relationship checks — *a start exists*, *no outcome yet* — moved **inside
`Ampd.Receipts`' own handler**, against the log it is about to append to. A
process handles one message at a time, so check and append cannot interleave. A
caller-side check is two round trips with a window between them, and two
concurrent outcomes could both observe "none yet".

Both appends are also in `@ordered_ops`, and that is not redundant: **ordering is
about the world's total order across stores; atomicity here is about this store's
log.** Neither subsumes the other, and the falsifiers separate them — one asserts
`unordered-authority-mutation` from outside the coordinator, another drives three
contradictory outcomes at a decided job and requires exactly one row to exist.

### `admissible?/1` gained its missing clause

It claimed to answer *may this job be handed to an executor* while asking only
about receipts. Now:

```text
a JobBasis exists      there is work, over a named SourceBasis,
                       owned by a Lane, at a Worker generation
a START is durable     execution was admitted
no OUTCOME             it has not already been decided
```

Either lock alone closes the measured hole. Both are here because they answer
different questions, and an executor deserves to be told about a job whose basis
is gone rather than about one whose receipt merely looks right. **A ledger row
may not create executable work by itself.**

R0b.1 extends this with execution-time facts — Worker generation still current,
SourceBasis resolves, materialization proves itself, scope digest re-derives.
None is pre-invented here; none has a producer yet.

### the closure gate caught the first attempt

`record_validation_outcome/2` was written with `with/else`, which the BEAM
compiles to an anonymous function, and `check-ordered-closure.mjs` refused it:
*the census cannot follow this dispatch and nothing says where it lands.* The
cheap answer was an exclusion entry. Removing the opaque dispatch is better than
adjudicating it, so it is a `case`.

---

## 5 · three pre-existing defects found on the way

The third is in §3 above, beside the projection work it belongs to.

### `:bind_basis` was classified a read at the participant boundary

`Ampd.Worktree`'s `@ordered_ops` contains `:bind_basis` — served only for the
coordinator — and `@participant_mutations` did not. Every tag not on that line
is classified a READ, so a `bind_basis` whose reply was lost was
`:unavailable` (retryable, nothing was mutated) when the truth is
`:indeterminate` (a basis may be on disk, a human must look). That is precisely
the second execution the class exists to forbid, **on the one operation that
mints source authority**.

Present since `cbc9b99`, the commit that introduced SourceBasis. Fixed.

### the gate that names that exact failure was red, and nothing ran it

`tools/check-ordered-boundary.mjs` says it in its own comment — *"An ordered op
OUTSIDE the mutation list … is a write the boundary would classify as a read"* —
and it was **RED on `bind_basis` through all of Phase A and R2–R6**. It is in no
`verify`, no `release.sh`, no battery. There was no runner for the static gates
at all.

A gate nobody invokes is not a gate. It is a file that would have caught
something. `tools/gates.sh` is now that runner.

Two further findings came out of building it:

* Both ordered gates hardcoded `const ROOT = '/home/travis/ProjectAmp2/super'`,
  so running them from a detached worktree measured the **canonical tree** — a
  green verdict about source the run never saw. This round needed an isolated
  parent and would have gated against the wrong one. Now derived from the
  script's own location.
* `check-dispatch-partition.mjs` shells to `mix run` and parses its stdout. On a
  stale `_build` the compiler's output enters the parse: observed as `22 reads ·
  10 held · 1 failed`, deterministic `15 · 11 · 0` on the next run. A false RED
  is cheaper than a false green and still corrosive — it is how a gate earns the
  reputation that stops anyone running it. `gates.sh` compiles first.
* `CANNOT RUN` is a third verdict in `gates.sh`, alongside held and failed. A
  gate whose subject is unbuilt has measured nothing, and scoring that as either
  verdict lies in one of the two directions.

---

## 6 · evidence

All figures taken with nothing else running on the machine — see §0.

```text
super-host verify         319 held ·  0 failed
ExUnit (this tree)        682 tests ·  0 failures
ExUnit (baseline 78b19e8) 630 tests ·  0 failures     the delta is exactly this suite
ExUnit multi-seed         seeds 0 · 424242 · 909090 — 666/0 each, retained
static gates                8 held ·  0 failed · 0 could not run
scope-manifest vectors     12 held ·  0 failed
sabotage-validation        33 caught · 0 NOT A FALSIFIER · 0 unapplied
host sabotage (isolated)   55 falsified ·  0 did not · 0 could not ask (baseline 319/0)
```

### the host battery, and a rule this session broke

`tools/sabotage-isolated.sh tools/sabotage-host.sh` ran at `0efaa4a` and
reported **55 falsified · 0 did not · 0 could not ask their question**, on a
`319 held · 0 failed` unsabotaged baseline — the same figures Phase A was
FINAL-FROZEN at. It measured **this** host: `git diff 0efaa4a..HEAD -- host/`
is empty, which is the check the bundle generator makes rather than trusting
the commits to be equal.

It also ended with:

```text
CANONICAL TREE MOVED during an isolated run
  This is NOT evidence the battery reached it — it edits only inside
  the worktree and is never given the canonical path. Concurrent
  editing is the usual cause on a shared checkout.
```

The concurrent editor was this session, committing while the battery ran —
against a rule it had already written down. The harness is right about what it
means: it works in `../.super-sabotage-<sha>-<stamp>` and is never handed the
canonical path, so the verdict stands. Recording the warning rather than
suppressing it is the point of it existing, and the honest version of this
section says who moved the tree.

The seed battery keeps what happened — one directory per run holding commit,
tree, seed, both timestamps, exit status, summary, full stdout, and an orphan-
runtime census before and after. Seed `909090` recorded `orphans 0→1`; that is
a recorded fact about the machine, not a failure, and it is exactly the kind of
thing D.1.3b·2f lost by piping a run through `grep`.

### the sabotage column that is new, and why

The first version of `tools/sabotage-validation.sh` embedded Python inside a
shell string. The quoting did not survive, **every stub silently failed to
apply**, the suites stayed green, and eighteen cases were scored `NOT A
FALSIFIER`.

A harness that cannot tell *"the mechanism was removed and nothing noticed"*
from *"the mechanism was never removed"* reports the wrong verdict with total
confidence — which is the same defect it exists to find. The substitution is now
exact and a miss is `UNAPPLIED`, which is neither a catch nor a verdict about
the suite.

All 33 mechanisms are load-bearing. Each case removes exactly one and requires a
**named** test to fail; a stub that merely reddens the suite somewhere does not
score, or a stub that broke compilation would count as evidence for every row at
once.

---

## 7 · the dogfood — the success criterion, executed

`tools/dogfood-validation.exs` drives the whole chain against **this tree at
whatever commit it is run on**:

```text
repository → Lane → Worker → worktree → SourceBasis
           → scope manifest → JobBasis → STARTED → OUTCOME
```

**The figures are not reproduced here.** They move with every commit — the file
count and the scope digest are properties of the tree, and a number typed into
this document would be stale the moment the next file lands. That is the defect
this lane has already paid for twice. The run is in the bundle's appendix, and
the bundle refuses to generate unless that log shows a durable start, a
`completed · pass` outcome, and no leaked path.

What is fixed, and what the appendix must show:

* the scope digest is the **real** one, derived over the materialization Super
  established for itself — and it is the same value `check-scope-manifest.sh`
  prints for the same tree. Two paths to one number, agreeing. A constant would
  have proved nothing.
* `admissible?` moves **true → false** across the outcome. R11.2's ordering,
  observable rather than asserted.
* five surfaces give five different answers from one ledger — the operator sees
  both validation records, `kestrel` sees its own, `mallory` sees none, the
  capability surface is empty because no capability effect happened, and the
  worktree surface holds its own `worktree_created@1`. Before R6 that was one
  key returning everything to everyone, with worktree establishment invisible
  to the agent it belonged to.
* no host path on the job, the start or the outcome — asserted on the records
  themselves, not on the call sites that serialize them. The materialization
  path is read exactly once, to derive the digest; only the digest travels.

---

## 8 · what this round did NOT do

No native `source-hygiene` execution. No Carrier started. No terminal input, no
SHAPE, no DRIVE.

`SourceBasis` is untouched: RW Carrier workdir, X installed payload, RO
SourceBasis materialization, 3 Landlock grants, cap 4. No source writes, no
child-process authority, no network, no extra execute grants, no ExecutionBasis
change.

The rollover defects in the other paged stores — `ef_`, `gr_`, `gq_`, `ap_` —
remain filed and out of this slice.

---

## 9 · open, and named rather than closed

1. **May an Actor request a bounded job against its own Worker's basis?**
   Deferred deliberately (§4). It needs an authority argument, not a field audit.
2. **`ampd/priv/data/` was tracked despite the `*.dets` rule.** `.gitignore` is
   not consulted for a file git already tracks, and the four dets tables had
   been tracked since the repo's first commit — so a rule added in `0d7c53a`
   protected every world except the ones a developer's runtime actually
   writes. This round's dogfood minted a world into them and committed it.
   Fixed here: `git rm --cached`, the directory ignored whole, and the
   runtime proven to boot from nothing rather than assumed to.
3. **`ampd/priv/ampd_fd_nif.so` is a compiled binary in git.** Noticed while
   fixing the above; out of scope, not touched.
4. **`Ampd.Worker.close/1` returns `{:ok, <refusal>}`** when called outside the
   coordinator — `transition/3` wraps whatever `Loci.put_worker/2` returns. No
   production caller reaches it (only `Ampd.Authority.close_worker/1`, inside
   `tx`), so it is filed rather than fixed. A refusal wearing an `:ok` tag is
   worth removing before something new calls it.
