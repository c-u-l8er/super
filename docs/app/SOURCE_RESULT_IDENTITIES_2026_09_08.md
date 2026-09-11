# Super selected-file source and result identities

September 8, 2026. Implemented and checked in the actual Super app.

## What changed

A plan-linked file request now captures the current Git commit and SHA-256 identities for the selected file's disk bytes and shared editor draft. Proposal review records the proposed result's SHA-256 and byte length alongside the plan revision, repository reference and runtime identity. The review shows a compact source summary with expandable details.

Super checks the source when opening review and again before using the proposal as an editor draft. Changed disk contents, a changed commit, a stale plan or a replaced selected repository require a fresh attachment. Cancel remains available during verification and prevents delayed staging. Save remains a separate action with the existing disk-conflict check.

The source attachment and verified source/result record survive reopening the bot conversation as read-only history. Reopening does not restore proposal actions or send another request.

Plan-linked requests require a readable committed Git HEAD. Super does not create a commit automatically. Ordinary editor use remains available before an initial commit.

## Boundaries

This identifies **one selected file**, its shared draft and its proposed result. It does not capture the other files or index in the checkout, create an immutable worktree, or provide an atomic repository-wide snapshot. The commit and file are checked twice during capture, but this does not lock out external writers.

The record is saved conversation presentation, not yet a durable runtime attempt or an acceptance receipt. Saving the file does not mark the task complete. No validation or real-model dogfood cycle is claimed.

The native operation reads only from the existing selected directory, checks its identity and generation, refuses symlinks and unsupported files, and retains the existing bounded text limits. Missing files and empty files have different identities; newline differences are preserved. It writes neither files nor Git objects.

## Verification

- 25 native plan/file workflow checks passed: native folder selection, wrong-repository refusal, exact attachment and result records, changed disk/commit refusal during open review, stale-plan refusal, fresh staging, explicit Save, and read-only history after reload.
- 51 native workbench regression checks passed. One compositor-only pointer-resize check was explicitly skipped because the isolated display has no window manager; programmatic resize checks passed.
- 8 native review-component checks passed, including failure and cancellation during pending verification. These use fixture callbacks; the separate 25-check workflow exercises native source verification.
- 19 native workbench unit tests passed, including three new source-basis tests.
- All 51 JavaScript tests passed.
- Offline release build, WebView ACL (35 checks), and intent surface (6 checks) passed. The intent check was rerun successfully with process permission after its initial sandbox launch restriction.
- Visually inspected the native review screenshot: source summary, changed lines, both drafts, Use and Cancel are visible at the tested window size.

All app workflows ran in disposable repositories and isolated native windows with a local deterministic provider fixture. The user's saved-world app was not restarted. Existing compiler and Node module-type warnings remain. No commit, push or deployment was performed.

## Next MVP work

1. Create a durable attempt linked to the plan revision and source/result records, with interruption and outcome history.
2. Run checks against a defined result snapshot and retain the check identity, output and outcome; invalidate readiness after relevant changes.
3. Add explicit Accept/Reject bound to that exact result and its validation.
4. Complete one real-model, human-reviewed Super change inside Super, including reopen/recovery.
5. Extend beyond one file with atomic multi-file review and isolated worktrees before delegated execution.

## Implementation locations

Native source capture: `cockpit/src/workbench.rs`; hashing dependency: `cockpit/Cargo.toml` and lockfile. Request attachment and rechecks: `cockpit/ui/development.js` and `task-file-context.js`. Review and saved presentation: `file-proposal-review.js`, `bots.js`, and `cockpit.css`. Regression coverage: `tools/development-plan-file-smoke.mjs` and `proposal-changes-test.mjs`.

Native test setup and folder-picker automation remain documented in `Super_Repository_Matching_Implementation.md`. Use a disk-backed `DEVELOPMENT_TEST_ROOT` with sufficient space; the system temporary volume was nearly full during this work.
