# Super repository matching and native workflow verification

September 8, 2026. This pass supersedes the folder-picker blocker and unverified-repository limitation in the earlier plan/file review report.

**Later pass:** Selected-file source/result identities are now implemented; see `Super_Source_Result_Identity_Implementation.md` for the latest state and 25-check workflow. Counts and remaining-work statements below describe this earlier repository-matching pass.

## What is now working

- Real native folder selection in an isolated virtual display. The helper targets the test app's process, types paths without the clipboard, clicks Open instead of navigating into a selected child, and fails promptly if the dialog does not close.
- Plan → selected file → assigned bot → local test-provider proposal → changed-line review → unsaved editor draft → explicit disk Save → page reload.
- A read-only native check compares the selected editor root with the current plan's registered repository path before sharing and again before staging. A different repository, stale plan revision, cancelled plan, changed runtime incarnation or epoch, replaced selected directory, or changed editor generation is refused.
- Repository paths remain outside the runtime projection and match receipt. The page supplies a plan identifier, revision and runtime identity; the host obtains the path from its existing native-selected directory, rather than accepting a page-supplied path.
- Cancelling while verification is pending cannot stage a draft when the check later finishes. The exact shared-draft guard runs again after verification.
- Plan and recovery banners share one layout container, keeping the editor toolbar reachable. Prepared file attachments can be added while the assigned bot checks its provider status on opening; this does not send a message.

Repository matching means matching the registered root path. It is not a pinned Git commit, source-content identity, completed run, validation receipt or task acceptance. Save still performs the existing disk-conflict checks and remains a human editor operation.

## Verification

- **21 native plan/file workflow checks passed**, including refusal of a different repository, a matching receipt in the attachment, stale-plan refusal, fresh proposal staging, exact bytes saved, and a plan retained after reload. Saving did not mark the task accepted.
- **8 native review-component checks passed**, including verification failure and Cancel during a pending verification. These component checks use explicit fixture callbacks; the separate workflow test exercises the actual native/runtime matching path.
- **51 native workbench regression checks passed**, including disk conflicts, file proposals, interactive shells, browser preview, session links, process restart, restored drafts and refusal to overwrite externally changed files. One compositor-driven pointer-resize check was explicitly skipped on the virtual display, which has no window manager. Programmatic shrink/grow checks passed.
- **34 JavaScript tests passed**, including proposal guards, exact attachments, bounded changed-line review, conversation persistence and draft recovery.
- **10 runtime development-task tests passed**, including read-only matching, path redaction, wrong/stale/cancelled cases and path aliases.
- **16 native workbench tests passed**, including selected-directory replacement and generation checks.
- Release build, runtime formatting, whitespace, WebView ACL (35), human intent surface (6), ordered-boundary and ordered-closure checks passed. Existing compiler, fixture carrier-drain and virtual-display graphics warnings remain.

The native workflow used a deterministic local provider fixture and disposable Git repositories. It proves interface and host integration, not the quality of real-model work. The existing saved-world app was not restarted. Source changes are local and uncommitted; the release executable is ready for the next launch.

## Repeating native tests

Run `bash tools/native-ui-test.sh node tools/development-plan-file-smoke.mjs` from Super. The wrapper requires Xvfb, xvfb-run and xauth. `SUPER_XVFB_BIN_DIR` can identify a locally extracted test-tool directory. This session used a signature-verified distribution package extracted into task scratch space; it did not install a system package.

Set `DEVELOPMENT_TEST_ROOT` to a directory with sufficient storage to retain test artifacts. Without it, the wrapper creates a temporary test root and removes it after success; failed-test artifacts remain for diagnosis. Runtime scratch files use that test root. Choose distinct test ports for concurrent runs. The normal desktop remains outside the isolated display.

The test work encountered a full system temporary volume. Only completed diagnostic app-data directories identified in this task's own trace were removed; later tests used task workspace storage. The runner now cleans up roots it creates after successful tests.

## Remaining MVP work, in order

1. Pin a concrete source revision and draft/result identity for each development attempt. Matching a registered path alone does not identify the bytes that were reviewed.
2. Persist the attempt, request, proposal and outcome links across restart without restoring permission to apply an old proposal.
3. Attach checks and their output to the exact result they validated. Editing the result invalidates the earlier validation.
4. Add explicit accept/reject with a human note and durable history. Keep saved, validated and accepted states distinct.
5. Complete a small real-model change to Super from inside Super, through review, Save, checks, acceptance and reopening its history.

After supervised dogfooding: atomic multi-file changes, isolated worktrees, bounded execution, cancellation/recovery and delegation/Swarms. The original feature audit retains the broader prototype parity backlog.
