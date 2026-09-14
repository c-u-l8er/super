# Continue work and guided review

Continue work keeps the selected unfinished plan across restart. The next action and explanation appear before the step tracker; acceptance criteria are available under **Done when**. The main action is tested at a 1080 × 620 window size with long criteria.

Opening a retained review offers one primary action:

1. Inspect the retained proposal.
2. Run the next missing or unsuccessful required check.
3. Open the passing proposal in Editor and explicitly save it.
4. Return to the review, explain the decision, and check the saved files before accepting.

The guide delegates to existing controls. Native snapshot and file validation still determine whether testing, staging or acceptance is permitted. Opening Editor is not evidence that files were saved. Combined reviews can be staged from retained content; single-file reviews retain their existing Editor proposal flow. Additional controls and output are under **Review details and other controls**. Refusals appear beside the primary action. Test polling continues while the review is open even when its details are collapsed.

Presentation progress is kept through plan rerenders and navigation within the current runtime session, scoped to the world, attempt and task revision. Reloading starts at inspection again; durable tests and acceptance records remain authoritative. A stale or disconnected review does not offer an active mutation step.

Validation: `tools/work-focus-smoke.mjs`, `tools/review-guide-smoke.mjs`, `tools/review-next-step-test.mjs`, and the existing `tools/development-plan-file-smoke.mjs`. The latter expands detailed controls explicitly and waits for the actual saved file rather than the Save button's temporary busy state.
