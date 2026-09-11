# Durable review attempts — Super

September 8, 2026. Implemented in the actual app and verified with fresh native tests.

## What you can now do

In a plan-linked file review, choose **Save review attempt** to retain the exact shared draft and proposed text in the runtime, along with the source/result identities, assigned bot, plan revision and acceptance criteria. This is separate from **Use as editor draft** and the editor's **Save**.

Open the plan's new **Review attempts** section to inspect that material and add a review note. The available statuses are **recorded**, **needs changes**, and **dismissed**. Each note has a revision and timestamp. Dismissed attempts remain read-only history. Saved material and notes survive page reload and runtime-store restart.

Recording the same proposal again in its current review session reuses the same request identity. A differing reuse or stale review-note update is refused. Updating review notes does not change the plan's status, source draft or proposed result. Historical review text has no restored Apply or Save action.

## Photos of the new workflow

### Record without saving the file

![Review attempt saved separately from the editor](/home/travis/Documents/Codex/2026-09-08/let-s-continue-super-development-where/outputs/review-attempt-evidence/verified/development-plan-file-smoke/16-review-attempt-saved-independently-of-editor-save.png)

### Reopen both retained drafts from the plan

![Retained source and proposed text](/home/travis/Documents/Codex/2026-09-08/let-s-continue-super-development-where/outputs/review-attempt-evidence/verified/development-plan-file-smoke/17-retained-review-source-and-proposed-text-on-the-plan.png)

### Keep versioned review notes

![Needs-changes review note](/home/travis/Documents/Codex/2026-09-08/let-s-continue-super-development-where/outputs/review-attempt-evidence/verified/development-plan-file-smoke/18-versioned-review-note-and-needs-changes-status.png)

### Retain dismissed work as history

![Dismissed review remains read-only](/home/travis/Documents/Codex/2026-09-08/let-s-continue-super-development-where/outputs/review-attempt-evidence/verified/development-plan-file-smoke/24-dismissed-review-retained-as-read-only-history.png)

[Browse the updated gallery](Super_UI_Evidence_Gallery.html). It contains **61 screenshots** from the final four native suites. Earlier evidence is retained separately.

## Verification

| Check | Final result |
|---|---|
| Plan → file → review → recorded attempt → notes → Save → reload → dismissal | 31 passed |
| Editor, terminal, browser, linked sessions and restart recovery | 51 passed; one compositor-only pointer-resize skip |
| App navigation, setup, bot identities and conversations | 97 passed |
| Native review component, including record refusal/retry and Cancel before verification completes | 11 passed |
| Runtime development-plan and review-attempt tests | 20 passed |
| JavaScript behavior tests | 51 passed |
| Ordered boundary and closure | Passed |
| WebView ACL | 35 passed |
| Human intent surface | 6 passed, covering 22 declared mutations |
| Release build, runtime formatting/compilation, whitespace checks | Passed |

The four final native suites total **190 passing assertions**. Tests ran in disposable repositories and isolated native windows using deterministic local providers. The full native workflow exercises the actual runtime store and native source checks. The separate component suite explicitly uses fixture callbacks for error and pending-verification cases.

Runtime tests verify exact retained newline bytes, digests and sizes, stale plans, wrong repositories, world lineage, human-only commands, idempotent retries, immutable content, stale notes, terminal dismissal, restart recovery, legacy-store shaping, and history/directory limits. JSON-encoded size is bounded too, so escaping cannot turn a logically small record into an oversized stored payload.

The record-size guard initially referenced an unavailable serializer during development; the tests caught it. It now uses Super's existing bounded frame encoder, and the final 20 runtime tests pass. Existing host compiler, fixture carrier-drain and Node module-type warnings remain.

Final logs and capture receipts are in `review-attempt-evidence/verified`; runtime and boundary logs are in `review-attempt-evidence`. Every screenshot receipt identifies the test and executable hashes. The source manifest records the final installed implementation. Images were visually inspected, with the new review/notes/history screens inspected at full size.

## Exact scope and limits

This is a **durable review attempt**, not a running coding job. It begins when a person explicitly records an available proposal. It does not yet retain a pre-send attempt, provider failure/interruption lifecycle, complete model request metadata, execution ownership, validation outcome or human acceptance.

The UI rechecks the native repository, source commit, disk contents, editor draft and plan before recording. The runtime independently checks draft/result hashes and byte lengths, plan ancestry/revision, world lineage, input shape and limits. Stored source metadata is labeled human-recorded review material: it is not a signed native attestation. The observed runtime epoch is retained as context; the native UI verifies it before submission, while the receiving store checks world lineage and the existing human control channel's fence. Do not use this record alone as authority to execute, save files or claim validation.

Source identity still covers one selected file. Other working-tree files and the index are outside this record. Its retained shared draft can include unsaved editor changes. Disk source bytes are represented by the observed hash; the complete editor draft and proposed replacement text are retained.

Limits: 50 attempts per world, 32 history entries per attempt, and a 64 KiB aggregate directory limit enforced for both logical and JSON-encoded size. Earlier records are preserved when growth is refused. Paging/archive and larger durable artifact storage are needed before routine large-file or multi-file use. Unsubmitted review-note form drafts are not restart recovery records.

Cancel before source verification finishes prevents recording. Once a Save review attempt command has been submitted, closing the dialog does not revoke that requested history write. Recording never stages or writes the editor file.

The existing visual caveats remain: long editor status messages can truncate, narrow navigation is tall, and the isolated display can show transient scrollbar artifacts. Normal-compositor dragging, full accessibility/cross-platform coverage and real-model dogfooding remain unverified. The gallery's local-file browser preview remains blocked by the browser URL policy; its embedded images, links and script syntax are checked directly, without claiming browser-tested search or zoom.

## Next development work

1. Bind validation commands, output and terminal outcomes to a defined result snapshot; edits must invalidate readiness.
2. Add explicit Accept/Reject tied to the exact result and validation.
3. Extend attempt recording earlier in the request lifecycle so interrupted/provider-failed work has durable context and retry history.
4. Complete a real-model, human-reviewed Super-on-Super change with reopen/recovery.
5. Add atomic multi-file review and isolated worktrees before delegated execution.

No commits, pushes or deployments were performed. The user's saved-world app was not restarted. The rebuilt executable is available for the next app launch.
