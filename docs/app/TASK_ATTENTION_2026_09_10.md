# Task attention — 2026-09-10

Mission Control and bot Work now share a scoped, grouped summary of open development plans. Each plan has one next action, regardless of review count. Completed and cancelled plans are excluded. Unavailable runtime state is not presented as zero. Unfinished test reports are not evidence of a running process.

Groups preserve disclosure state across runtime refreshes using stable identities and the existing disclosure binding. Native testing found and verified the fix for groups reopening during refresh. Permission counters now explicitly say Permission decisions/Permission requests.

Validation: 55 focused JavaScript tests, 21 native workflow assertions, release build, six intent checks covering 24 human-control mutations, and 35 WebView ACL checks passed. Four final native screenshots were visually inspected, including bot scope, empty workspace, and narrow layout. The fixture runs in a disposable world and sends no provider messages. This pass does not establish real-provider dogfooding or full process-restart recovery. No runtime authority or permission behavior changed.

Tests: tools/task-attention-test.mjs and tools/task-attention-smoke.mjs. Run the native fixture through tools/native-ui-test.sh with the existing isolated display configuration and APP_SMOKE_SCREENSHOTS set to an evidence directory.

Next MVP target: combined multi-file review, testing, and acceptance against the same snapshot.
