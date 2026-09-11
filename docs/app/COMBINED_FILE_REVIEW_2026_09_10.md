# Combined file review — 2026-09-10

A bot reply proposing multiple file edits now offers Review files together. The dialog supports two to four plan-linked files from one Editor session, repository, plan revision and shared source commit. File selectors show changed lines and complete read-only shared/proposed drafts.

Stage all drafts revalidates every member before any draft mutation, including native plan/repository matching and selected-file source checks. Missing or changed drafts, original bytes, closed tabs, stale plans, mixed sources and duplicate paths refuse the set. Editor states are allocated before committing the draft updates. Cancel never stages. This is an all-draft UI operation, not an atomic disk transaction: existing Save remains per-file and rechecks conflicts. No runtime permissions, test evidence or acceptance are created.

The combined shortcut is excluded from saved proposal slots, retaining the original per-file proposal history. Reopened history remains read-only. Individual review still works and neither dialog can overlap the other.

Validation: 38 focused JavaScript tests; 25 native workflow checks in a disposable repository with a deterministic local provider; 11 native single-file dialog checks with fixture callbacks; release build; six intent checks covering 24 human-control mutations; 35 WebView ACL checks. Full/narrow screenshots were inspected. Earlier native attempts needed a visible record-backlink selector and a wait for UI completion after disk Save. Native screenshot inspection identified background scrollbars painting over the modal; the covered rail/tree stop scrolling while it is open.

Tests: tools/file-proposal-set-test.mjs, tools/file-proposal-set-smoke.mjs and tools/file-review-component-smoke.mjs. Run native fixtures through tools/native-ui-test.sh with the existing isolated display configuration and APP_SMOKE_SCREENSHOTS for captures.

Remaining: durable multi-file change-set records, a shared source/result identity carried through combined testing and acceptance, integration/rebuild through Super, and repeated real-provider dogfooding. This pass did not prove those or full process-restart recovery.
