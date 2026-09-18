# Two rulings on review evidence — 2026-09-18

**Status: ruled by the supervising session, built, tested and installed on
2026-09-18; the commit, binary hash and the post-install measurement are in
*After the install* at the end.** Both questions were left open by the previous
session's hand-off; both were blocking the flow the app exists for — record a
review, check it, test it, accept it, finish the plan — and each had already
cost a real round.

## Ruling 1 — review bodies live in the content store, never in the record

### What stopped it, measured

The attempt directory (`development_attempts`, one authority collection in the
`loci` store) is admitted under a 128 KiB encoded budget, and single-file
reviews carried their whole current and proposed text inside the record while
change sets published members by digest. From the backup taken at 18:21:57Z on
2026-09-18 (`loci.dets`, read with `:dets`, sizes as JSON):

| | bytes |
|---|---|
| whole `loci` state | 183 595 |
| `development_attempts`, 8 records | 130 720 |
| `development_tasks`, 23 records | 39 701 |
| `da_0062` alone — one single-file review, accepted | 43 567 |
| `da_0030` — a three-file inline change set | 30 631 |
| `da_0064` + `da_0065` + `da_0066` — three single-file reviews | 43 418 |
| the four staged change sets `da_0033/37/38` + metadata | about 13 000 |

Five records held 130 720 of the 131 072 bytes. The app-shell review for
dt_0063 was refused `attempt-directory-full`, and after that **no text check or
test run could be recorded for any attempt**, because each writes into its
attempt. The frame cap is 262 144; 160 KiB was the last raise that fit and
would have bought one more review of the size of `da_0062`.

### The decision

**Not a raise.** The number was not the fault; the *shape* was — a record that
carries bytes it already names by digest. The staged shape existed for change
sets since 2026-09-12, and every consumer of it already handled a single-file
record with a `source` and no bodies (`member_content/1`, `content_state/1`,
the projection's `member_view/1`, the host's `resolve_review_bodies`, the
downgrade's `inline_from_content/1`); what was missing was the door.

Three things changed, all in `ampd` and the page, nothing in the host:

1. **A single-file review can be recorded staged.** `record_development_attempt`'s
   `shared_draft` and `proposed_text` are optional (`command_spec.ex`); absent,
   the record is its source basis alone and `DevelopmentAttempt.create/2`
   validates it with the same `member_fault/1` a change-set member gets — the
   content must be published under the digests the source names, the sizes
   are re-derived from what is stored, the basis must bind its content, and
   the four refusals are kept apart by name. The inline shape is still
   accepted, still bounded by its old caps, so a page on an older runtime
   still submits. The page (`development.js`) publishes first, then names:
   `stageContent` for each side, then the record without bodies.
2. **Inline bodies leave every record as the world opens.**
   `DevelopmentAttempt.stage_inline/1` runs both phases of the migration that
   `REVIEW_CONTENT_STAGING_2026_09_12.md` built and deliberately left unwired:
   `ReviewContent.absorb/1` publishes each body under the digest its source
   already carries (addressed by bytes, so repeating it is a no-op), then
   `migrate_inline/1` rewrites only the members whose two sides read back
   under those digests. `Ampd.Loci` calls it at boot and on `load_state`, and
   saves only when a record changed. This is a rewrite of an authority store,
   so it earns its place the way `shape/1` does: it moves only bytes the
   record itself carries, under names the record already has, and anything
   the content store refuses stays exactly where it was and is logged. The
   record's meaning does not change — same digests, same basis, same
   everything but where the bytes live. The inverse, `inline_from_content/1`,
   is what `Ampd.Downgrade` runs for an older runtime, and its rules are
   unchanged.
3. **The text check reads through the resolver.** `check_text` used to read
   `attempt["proposed_text"]`; it now reads `member_content/1`, so a staged
   record checks the bytes its digest names, bounded by the 4 MiB per-file
   cap, and a record whose bytes are gone refuses `review-content-unavailable`
   by path and side rather than checking an empty string.

What this buys, on the live world: the five inline records become about 25 KB
of metadata, which puts the directory at roughly 38 KB of its 128 KiB; a new
single-file review costs a few hundred bytes; and the file being reviewed can
be the 54 KB `development.js`, which the old caps excluded outright. The
128 KiB cap stays — it now bounds metadata and is no longer the thing that
decides how much can be reviewed.

The measurement from the running world after the install is in *After the
install* at the end.

### Evidence

* `ampd/test/review_content_record_test.exs` — a single-file review 70 KB a
  side is recorded staged, its record is under 4 000 bytes, the projection
  carries `content.held = "staged"`, the same request again is the same
  record, and the text check finds the trailing space in the staged text; a
  record naming content that was never published refuses
  `review-content-unavailable` naming the side and records nothing; an inline
  single-file record's bodies leave the record when the store restarts, read
  back byte for byte, and a second restart moves nothing.
* `ampd/test/development_attempt_test.exs` — "store restart retains draft,
  result and notes" now asserts the staged shape and the same bytes through
  `member_content/1`; the durability tests compare what a record keeps across
  an open.
* The whole `ampd` suite: 859 tests, 0 failures (the clean tree at `dd94f1e`:
  855, 0). `node --test tools/*-test.mjs`: 284/284. `bash tools/gates.sh`:
  7 held · 2 failed (ordered boundary, ordered closure — pre-existing,
  `ampd/lib` only). Driven against the built binary: plan-steps 9/9,
  palette-records 12/12, reference-text 55/55, registered-repository 19/19.

### Not done here

* `saved-review.js` still declines to *re-stage* a single-file review into the
  Editor after a restart ("a single-file review shows its retained text on the
  plan"). That is a separate feature; the plan page reads a staged single-file
  record through its content refs exactly as it reads a set member.
* The 24 000-byte *share* cap (the file a bot is shown in a conversation) is a
  different limit and is not touched. `development-tasks.js` and
  `development.js` still cannot be shared with a bot.

## Ruling 2 — evidence binds to the plan, not to its revision

### What produced it

`completion_refs/2` and `taskProgress()` counted only attempts whose
`task_revision` equalled the plan's current revision. A plan's revision is
bumped by every `update_development_task` — a status change *or a planning
note*. On 2026-09-18 dt_0052 had `da_0062` accepted at revision 5; recording
the unblock note moved the plan to revision 6, and the stepper showed
*Prepare* again, truthfully by that rule. On 2026-09-16 the same rule refused a
review as `attempt-task-stale` because a note landed between sharing the file
and recording the reply.

### Why the rule was wrong

A plan's **title and criteria cannot change after creation**. `update/3` takes
a status and a note, and nothing else; there is no mutation that edits
criteria. So no revision of an open plan judges a review differently from any
other, and `revision` was doing two jobs: fencing concurrent updates (which it
must keep doing — a stale `update` is still refused `task-revision-stale`) and
standing in for "the criteria changed", which it cannot mean.

### The rule

**An attempt recorded, tested or accepted against any revision an open plan
has had is that plan's attempt.** Concretely:

* Recording (single file or change set) requires the plan to be open, the
  request's `task_revision` to be one the plan has had (a revision it has
  never reached refuses `attempt-task-stale`), and the source basis to carry
  that same revision — the request and the basis still have to agree with
  each other; they no longer have to agree with the plan's *latest* note.
* A test run, the native lookup that admits one, a text check, a note and an
  acceptance no longer compare the plan's revision to the attempt's. Cancelled
  and completed plans still refuse all of them.
* Completion counts every accepted result of the plan, and every unresolved
  attempt of the plan — whatever revision it was recorded against — still has
  to be accepted or dismissed first. `task-completion-not-ready` is unchanged
  in meaning.
* The page follows: `task-progress.js`, `plan-steps.js`, `review-next-step.js`
  (the `stale` step is gone), `saved-review.js`, `schematics-model.js`,
  `visual-review.js`, `development-tasks.js` (the accepted-result panel), and
  `file-proposal.js` (a later plan revision at apply time is the same plan; a
  cancelled or completed one is not). The recorded revision is still shown on
  every card, as information.

### Evidence

* `development_attempt_test.exs` — "a planning note does not orphan a review":
  after a note moves the plan to revision 2, the review shared at revision 1
  still records (and says so), a revision the plan never had refuses, the
  native lookup still matches, a test runs, the acceptance holds, the
  unresolved second review blocks completion until dismissed, and the plan
  completes naming the accepted attempt. "acceptance … when the plan changes"
  now proves a blocked-status update does *not* invalidate a prepared
  acceptance, and the native lookup test proves a cancelled plan still does.
* `development_task_test.exs` — a result accepted at an earlier revision
  completes the plan.
* `review_content_record_test.exs` — a set shared before a note still
  records; a future revision and a cancelled plan refuse.
* `tools/*-test.mjs` — the six page-side tests that pinned the old rule now
  pin the new one, each saying why.

### dt_0052

Under this ruling dt_0052 is finishable again: `da_0062` is accepted and it is
the plan's only attempt. Its criteria named Fable 5.1 as the proposer; the
proposal was made by Claude Opus 5 after Travis pinned every bot to
`opus[1m]`/`xhigh`, so no future run could satisfy that clause as written. The
plan's disposition is recorded in *After the install* at the end.

## Done outside Super, and why

Both rulings are runtime changes in `ampd/lib` (Elixir) plus page modules, and
the pieces are interdependent: the staged single-file door, the boot
migration, the command spec, the completion rule and the page's revision
checks. `development_attempt.ex` alone is over 50 KB, above the 24 KB share
cap, and until ruling 1 was installed no single-file review could be recorded
at all — the directory was full. So this slice was written directly, tested
as above, committed in `super-live`, pulled into the worktree, built and
restarted; the *next* slice is the first single-file round through Super on
the installed binary, which is the proof that the directory takes it.
