# Super progress — bot work pages

Each bot now has Conversation and Work tabs. Work shows assigned lanes, open workers and available terminals from the current runtime projection. Lane ownership follows the registered bot actor and its workspace; local profile names and groups do not confer ownership.

Create lane for this bot prefills the real lane form. Assign worker prefills the selected lane. Worker and goal links open their actual record pages. Watch terminal uses the existing read-only terminal binding and checks the current world, worker generation, open status and terminal availability.

Conversation drafts remain in place across tab changes. Linking an editor, terminal, browser or patch snapshot opens Conversation before focusing its composer. Runtime withdrawal clears Work counts and setup controls instead of displaying old assignments as current.

The shared record-action prefill now updates submitted text-field state as well as visible values. This fixes bot actor prefills that previously looked correct but submitted an empty actor.

Returning from a bot patch link clears the old diff immediately while the current disk snapshot loads.

Repository registration now uses the same explicit Enter/Accept behavior as the workbench folder chooser.

Remaining MVP work: agent-owned browser/terminal session registry; actual delegation and cancellation; admitted coding runs and restart recovery; revision-bound validation and acceptance. Heavy landing-page browser scrolling remains unresolved. This pass does not claim autonomous dogfooding is ready.

## Verification

- Bot assignment native check: 4 held. A fresh workspace, goal, repository registration, bot, lane and offline worker were created through the actual controls in an isolated runtime.
- Product regression: 97 held. Native workbench: 38 held, including patch backlinks, live shells, browser tabs, native resize and restart recovery.
- JavaScript behavior checks: 36 passed. Repository validation: 3 passed. WebView ACL: 35 held, 0 failed.
- Release build passed with the existing three host warnings.
- The native Work screenshot shows test records, not a live coding run. Watch uses the existing terminal binding path; this new offline-worker test verifies that unavailable terminals are not offered, not a newly executing agent terminal.

Changes remain local and uncommitted.

The verified build is running in the existing saved world: 4 workspaces, 2 goals, 2 lanes and 1 repository. Both prior shell sessions were recreated and the local preview restored. The editor is showing the new bot Work implementation.
