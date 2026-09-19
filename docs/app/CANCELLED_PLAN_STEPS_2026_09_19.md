# A cancelled plan's stepper claims no step — 2026-09-19

**Status: proposed through Super by Claude Opus 5, reviewed, tested, accepted,
the plan finished from the wizard, and installed.** The second single-file
round through Super, and the first one whose reviewed bytes reached disk
through the plan card's own control rather than a driver writing them.

## The defect

`planSteps()` sent a cancelled plan down the same branch as a completed one:

    const [at,blocked]=done||progress.state==='cancelled'?[STEPS.length,false]:…

so `at` was `STEPS.length`, every index satisfied `i<at`, and all five steps
rendered `done`. A cancelled plan's stepper was therefore indistinguishable
from a finished plan's — the same five dimmed, completed steps — and it
asserted five steps the plan never completed. The page's own banner said the
plan was cancelled; the stepper beside it said the opposite.

## The change

A cancelled plan takes `at = -1`, a sentinel that sits **before** every step:
no index satisfies `i<at` or `i===at`, so nothing is `done`, `current` or
`blocked` and all five fall through to `todo`. The `current` lookup is guarded
(`at>=0&&at<STEPS.length`) so the sentinel is never used to index `steps`.

No new step state was introduced, deliberately: `cockpit.css` styles exactly
`done`, `current`, `blocked` and `todo`, so a fifth value would render
unstyled and make this a two-file change. `todo` is already dimmed, which is
what "not established" should look like. Completed plans, blocked plans,
`completionReason` and both exports are untouched.

## The round

| step | record |
|---|---|
| plan | `dt_0071`, created from the driver, criteria naming the four styled states |
| proposal | one `propose_file_edit`, 66 s, opus[1m] at xhigh in a new conversation |
| record | `da_0072`, **staged** (bodies by digest), directory 42 079 → 44 127 bytes |
| note | the supervisor's review, including the deviation below |
| text check | pass — conflict markers, trailing spaces, JSON syntax not applicable |
| tests | `super-javascript-behavior@1` `run-779042-…` **pass, 48 tests**, snapshot `d55fe824c296` |
| save | **the plan card's *Stage saved review in Editor* → *Use as editor draft* → *Save*** |
| accept | 2026-09-19T01:18:52Z, reason recorded |
| finish | *Approve and finish plan*, `dt_0071` completed at revision 2 naming `da_0072` |

The save step is the part worth naming. The 2026-09-18 round had to read the
reviewed bytes out of the content store by `result_sha256` and write the file
by hand, because a single-file card holds no live Editor reference after a
restart. `SAVED_SINGLE_FILE_REVIEW_2026_09_18.md` built the control that
removes that; this round used it on the **live world** for the first time,
and the log carries what it showed: *Source pinned to `3cf6121604` · exact
file and result recorded*, then *plan-steps.js · Saved review da_0072 staged
as unsaved draft · Review, then Save*, then *Saved*.

**One deviation, recorded rather than waved through.** The proposal also
re-indented the five `STEPS` lines from one space to two, and its own summary
claimed the compact style was untouched. It is cosmetic and it is in the
review note on `da_0072`, where a reader of the record will find it.

**One gap, closed outside the round.** The existing cancelled test asserted
only `cancelled === true`, so a passing test run did not prove the new
behaviour — it would have passed against the old code too. The assertions that
pin it were added directly afterwards in `tools/plan-steps-test.mjs`, and they
fail against the old shared branch, which is how they were checked. Saying
this plainly matters more than the tidiness of having it inside the round: the
round's 48 passing tests are evidence that nothing broke, not evidence that
the fix works.

## Evidence

* `node --test tools/*-test.mjs` 288/288; `bash tools/gates.sh` 7 held · 2
  pre-existing failed.
* Installed from `54ef3ff`: binary `157313fd5c083eef…` running as
  `super-desktop`, proven from `/proc/<MainPID>/exe`, after
  `~/build/backup-world.sh` (`default-20260919T012020Z`). Gateway 4318 → 200,
  Expo 8081 → 200, connector 4320 → 403 without the identity header, no error
  line in the unit's journal.
* Driven against that binary: `plan-steps` 9/9, `first-reply-title-only`
  16/16, `saved-file-review-resume` 13/13.
* Driver, request, diff, screenshots and every record:
  `Documents/Codex/2026-09-16/super-turn-projection/outputs/cancelled-stepper/`.

## Not done

* A cancelled plan that *did* have an accepted result now shows five `todo`
  steps, the same as one that never started. That is the honest floor, not a
  full answer: the stepper does not distinguish "stopped early" from "stopped
  late". Doing so means either a fifth state with its own CSS, or steps
  derived from the evidence rather than from `taskProgress`'s collapsed
  `cancelled`. Left for a decision.
* Two driver faults cost a run each before the round went through, both in the
  adaptation rather than the app: a leftover filename from the template, and a
  single click on the bot rail landing on the bot **directory** instead of the
  bot's surface. The second is now a retry in the driver.
