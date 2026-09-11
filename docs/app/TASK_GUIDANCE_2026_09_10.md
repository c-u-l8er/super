# Super task guidance — 10 September 2026

Implemented and rebuilt in `/home/travis/ProjectAmp2/super`.

Development plans now show a Next action section derived from their runtime records. It distinguishes preparing a request, a recorded blocker, requested changes, missing checks, failed/incomplete or mismatched checks, unfinished test reports, a human decision, and plan completion. Buttons open the relevant review, focus the planning/completion note, or enter the existing plan-linked Editor flow.

Mission Control and the assigned bot’s Work page list open tasks with the same guidance. The plan list also shows the next step. Task revision changes refresh guidance when there is no draft textarea note to preserve.

Passing checks do not imply a file was saved, accepted, integrated or rebuilt. Completion guidance requires a matching acceptance receipt for the current plan revision, no current open review, and no unfinished test start even on an older review. Runtime controls continue to enforce decisions.

## Verification

- 24 focused JavaScript behavior tests passed, including five new guidance tests.
- Native disposable-world test: 14 assertions passed, covering plan creation, blocker focus, reload, goal backlink and Mission Control navigation.
- Release build passed; six intent checks covered all 24 human-control mutations; 35 WebView ACL checks passed.
- Desktop screenshot visually inspected: task-page-evidence/Super_Development_Task.png in the September 10 task outputs.
- Existing module-type and Rust compiler warnings remain.

The first native run stopped because an old unscoped test selector found a link in hidden Mission Control before the visible record-page link. The corrected test scopes navigation to the visible page and completed successfully.

## Remaining M1 work

This is the first task-guidance increment, not a complete unified workbench. Provider readiness/reply progress, conversation-to-task linkage, editor/session context and richer task-level attention counts remain. No new real-provider dogfooding cycle was performed. Multi-file acceptance, integration and startup-wide recovery are subsequent backlog items.

Changed implementation: `task-progress.js` (new), `development-tasks.js`, `work-guidance.js`, `bot-work-view.js`; new `tools/task-progress-test.mjs` and extended native task smoke coverage. No runtime authority changes or user-world mutations were needed.
