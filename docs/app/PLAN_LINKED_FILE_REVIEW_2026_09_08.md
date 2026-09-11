# Plan-linked file requests and changes review — September 8, 2026

**Historical first-pass report.** The native picker and repository-matching gaps below are resolved by the subsequent `REPOSITORY_MATCHING_2026_09_08.md` pass. Its verification and remaining-work list are current.

A development plan now offers **Prepare file request**. It opens Editor with the selected plan and instructions to choose the intended repository and file. **Discuss with bot** shares the plan title, acceptance criteria, plan revision and complete selected file draft with the plan's assigned bot. It prepares an attachment; sending still requires a message and Send. Clear plan removes the editor association without changing the durable plan.

This remains human-directed source selection. The editor's native-selected folder has not yet been matched against the plan's runtime repository reference. The editor banner, attachment and review identify that limitation. This association is not an execution grant or validation/acceptance receipt.

A plan-linked file proposal can be reviewed or staged only while the same plan revision is available in the same runtime world, the plan is not cancelled, and the exact shared editor draft remains current. Existing repository-generation and per-app-session checks remain. Changing the plan requires a fresh file share; restored conversation proposals remain historical.

Review in Editor now includes a line-numbered changes summary above both complete drafts. Additions and removals have distinct colors and signs. Final-newline, CRLF and whitespace edits remain visible. Detailed line matching is bounded to 500,000 comparison cells; larger changes show the whole differing block and label the approximation. The summary renders at most 600 rows and states the omitted count. Complete draft panes remain available.

Use as editor draft stages unsaved text. Cancel preserves the draft and disk. Save remains separate and keeps native disk-conflict checks. The prepared file must fit the existing full-snapshot bound (24,000 bytes); combined task/file attachment data must fit 32,000 bytes. This pass adds no automatic provider requests, file writes, execution runs or result acceptance.

Next: native matching of the selected editor repository to the plan repository, durable source/result identity, validation bound to those bytes, and explicit task acceptance. A real-model Super-on-Super run remains to be demonstrated; deterministic fixture runs prove the interface flow only.

## Verification for this pass

- Release build passed, with three existing host warnings.
- 33 focused JavaScript tests passed, covering proposal snapshot guards, plan revision/world checks, diff bounds and newline handling, exact plan/file attachments, bot assignments, conversation persistence and draft recovery.
- 6 native review-component checks passed: changed-line rendering, plan/repository labels, visible action buttons, Cancel preserving the draft, changed plan revision refusing staging, and a current plan staging the proposed text.
- WebView ACL: 35 held, zero failed. Git whitespace checks passed.

The native component test uses explicit fixture callbacks in an isolated app window. It does not prove the complete plan → native repository chooser → assigned bot → provider → review → save workflow. That end-to-end test stopped at native folder-picker confirmation: the correct disposable repository was displayed, but simulated confirmation did not close the modal. A stalled picker subsequently caused the test world's frame stream to expire. This has not established a product repository-registration defect. No real provider request was sent.

The original development-task regression is retained. The expanded integration scenario is separate in `tools/development-plan-file-smoke.mjs` and remains unverified on this desktop. `tools/file-review-component-smoke.mjs` is the passing component check. The native helper targets only windows descended from its test driver.

The local release executable is updated for the next launch. The existing saved-world app was not restarted. Changes remain uncommitted.

## Remaining work toward supervised dogfooding, in order

1. Finish the full desktop integration check, including selecting the repository, preparing the plan attachment, using the assigned bot, receiving a proposal, reviewing it, cancelling, staging and saving. Resolve the automation blocker or perform and record the manual workflow before calling this integration verified.
2. Match the editor-selected native repository to the plan's registered repository. Refuse a wrong match and handle renamed paths. Bind the request to a concrete source revision plus current draft identity; a symbolic lane base is insufficient.
3. Persist a work attempt and its source/result identities. Retain the bot request, proposal and outcome links across restart without restoring permission to apply an old proposal.
4. Run the relevant checks and attach their commands, outcomes and output to the exact result checked. Changing the result must invalidate earlier validation.
5. Add explicit accept/reject for that validated result, with a human note and durable history. A saved file or a passing check alone must not complete the plan.
6. Complete one small real-model change to Super from inside Super: plan, request, review, save, validate, accept, restart and reopen its history.

After that supervised milestone: atomic multi-file changes; bounded execution in isolated worktrees; cancellation and recovery; and delegation/Swarms. The broader prototype parity backlog remains in the feature audit.
