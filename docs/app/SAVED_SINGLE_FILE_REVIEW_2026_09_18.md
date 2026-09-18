# A saved single-file review is staged again from its record — 2026-09-18

**Status: built, unit-tested, driven on a real screen in a throwaway world;
the install is recorded at the end.** Finding 3 of
`REVIEW_EVIDENCE_RULINGS_2026_09_18.md` *After the install*: after a restart a
single-file proposal could not be staged from its card — the transcript
restores no live Editor reference and `saved-review.js` re-staged combined
reviews only — so the driver of the first single-file round read the reviewed
bytes from the content store by `result_sha256` and wrote the file by hand,
and said so. This closes that gap through the page's own controls.

## What changed

* **`saved-review.js`** — `savedReviewFile(attempt, task)`: the single-file
  record as a one-member list, under the same refusals a combined review's
  members get (`openReview`, `retainedMember`, both factored out of
  `savedReviewSet`, whose refusals are unchanged). A deletion basis is refused
  by name: the single-file dialog never deletes. The body read
  (`savedReviewBodies`), the repository check (`savedReviewItem`) and the
  item it yields are the existing ones; the item is exactly what
  `checkFileProposal` accepts, which the tests prove.
* **`development.js`** — the `stage-saved-review` handler branches on the
  record's schema. A single-file review goes through `stageSavedFile`: the
  shared read (`readSavedReview`, factored out of `stageSavedReview`) sets up
  the one tab, then opens the **single-file dialog** (`reviewFileProposal`)
  with `recordAttempt: null` — the record exists — and the same `verifyPlan`
  the live proposal used, so *Use as editor draft* re-verifies the plan and
  pins the file to the recorded source basis before it touches the tab.
  **Save in the Editor is still the step that writes.**
* **`development-tasks.js`** (34 KB, over the share cap, written directly) —
  *Stage this review again* is rendered for both shapes while the plan and
  the review are open; the note names the writing step for each. The review
  guide's *Apply* action already clicked this control when present.

## Evidence

* `node --test tools/*-test.mjs`: **288 / 288** (284 before; +2 in
  `saved-review-test.mjs`, +2 in `conversation-title-test.mjs`).
* `bash tools/gates.sh`: 7 held · 2 failed (ordered boundary, ordered
  closure — pre-existing, `ampd/lib` only; the two census JSONs it rewrites
  were restored).
* **`tools/saved-file-review-resume-smoke.mjs`** — new, real cockpit,
  throwaway world, **no bot and no native dialog**: the registered repository
  is opened by ref, a file is committed there, the single-file review is
  recorded *by intent exactly as the page records one* (bodies published by
  digest with `put_review_content`, the record its source basis alone,
  `content.held = "staged"`), and then, in a cockpit whose transcript never
  saw a proposal card: **13 held · 0 failed** on the binary built from this
  tree (`7c615270bc51…`). Seen on screen (`outputs/saved-file-resume/`):
  1. the card offers *Stage saved review in Editor*, and before a file
     request is prepared for the plan it is refused by name;
  2. with the file request prepared, the single-file dialog opens on the
     recorded file, the diff is the recorded change (1 added · 1 removed),
     **Source pinned to `<head>` · exact file and result recorded**, *Use as
     editor draft* enabled, no *Save review attempt* control
     (`02-single-file-dialog-resumed.png`);
  3. *Use as editor draft* leaves the proposed text in the Editor as an
     **unsaved** draft, the file on disk and `git status` unchanged
     (`03-editor-unsaved-draft.png`);
  4. staging again with that draft unsaved is refused as an unsaved edit;
     a file changed on disk since the review is refused
     *"changed on disk since it was reviewed (now …, reviewed at …)"*
     (`04-refused-changed-on-disk.png`).
* Re-run on the same binary: plan-steps, palette-records, reference-text,
  registered-repository smokes — results in the install section.

## Not done here

* The live world's open single-file reviews `da_0064`–`da_0066` (dt_0063)
  were reviewed at `df4ed066` against files that have since changed on disk
  (the palette change they proposed is installed), so this control will
  refuse them by name rather than stage them; that is the correct answer and
  the refusal was not driven on the live world.
* `saved-review-resume-smoke` (combined, native chooser) was not re-run: it
  needs `DEVELOPMENT_TEST_ROOT` and a confirm this box cannot do.
* Acceptance after Save was not driven here; it is unchanged and
  `development-acceptance-smoke` covers it.

## After the install — 2026-09-18 23:39Z

Commit `b3c6f7e` (this change) and `48aa9d1` (the first-reply guard) were
fast-forwarded into `~/build/super-review-content`, built there
(`cargo build --release`, 34.7 s), and installed as `super-desktop` after
`~/build/backup-world.sh` (`default-20260918T233855Z`): MainPID's `/proc/<pid>/exe`
is the worktree's `super-cockpit`, sha256 `1be00b791212054f…`; gateway 4318 → 200,
Expo 8081 → 200, connector 4320 → 403 without the identity header, as before.
Driven from the installed checkout on that binary: `saved-file-review-resume`
**13 held · 0 failed**, `plan-steps` 9/9. From the source clone before the
install (binary `7c615270…`): saved-file-review-resume 13/13, plan-steps 9/9,
palette-records 12/12, reference-text 55/55, registered-repository 19/19.
The unit's journal since the restart carries no error line.
