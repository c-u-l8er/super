# Super Schematics — active development plan

Owner: Super desktop development. Started 2026-09-14.
Find this plan from the repository README and the Schematics → Development plan disclosure in the desktop app.

## Product outcome
Every screen has a schematic counterpart. The top-right Schematics toggle preserves the current screen, selection and drafts. Users can inspect this screen, its connections, and the whole app. Nodes explain their purpose and current state; selecting a node offers a route to the existing app controls. Live activity must come from observed state and events.

## Delivery sequence
1. Foundation: shared screen registry; app-wide toggle; screen, connections and app levels; accessible node inspector; return to the original screen. Include all screens in the app map and mark incomplete internal detail explicitly.
2. First connected path: Continue work, bot conversations, Editor and development reviews. Bind task, bot, review and check nodes to current runtime records and exact session identity. Show disconnected and unobserved states honestly.
3. Validate and install: pure model tests, native navigation/state-preservation tests, smaller-window tests, screenshots inspected by the developer. Preserve standalone launch mode and saved world.
4. Expand: detailed internals for every remaining screen; explicit edge-by-edge event instrumentation, recent-event history, pan/zoom and follow-active controls. Add direct actions through existing handlers after their context and confirmation behavior is tested.
5. Deeper execution: connect WRL/TRVM execution views only where actual records and execution evidence support the edges. Architecture links and screen navigation do not establish an executed integration.

## First-increment acceptance
- Toggle beside Find; works on every registered screen and dynamic bot/record pages.
- Selected page, input drafts and scroll return intact when toggled off.
- Screen, Connections and Whole app views with named nodes and labeled links.
- Hover/focus descriptions and a pinned inspector; keyboard operation works.
- Core task path reflects current saved state; unrelated sessions never appear as task activity.
- Runtime withdrawal clears live claims; missing instrumentation says so.
- Native browser/worker surfaces are hidden while inspecting schematics and restored afterward.
- Test results and screenshots delivered for user review.

## Evidence and progress
Implementation and validation evidence are recorded below as work completes. Remaining work in steps 4–5 must stay visibly marked in the app; the first increment does not claim full execution tracing.

### First increment — 2026-09-14

Implemented the app-wide toggle, three schematic levels, all 27 registered screens plus the record-details overview, core task path, descriptions and inspector navigation. Long descriptions collapse to keep the destination action accessible. Native browser surfaces are covered during inspection. No diagram action submits a mutation directly.

Validation completed: 161 JavaScript behavior tests; 17 native checks, including all registered screens, task focus, draft retention, Escape, 1080 × 620 layout, and a native browser preview. Captured and visually inspected task, connection, whole-app, small-window and browser-cover screenshots. Diagram scroll is deliberate; the whole-app graph is not fitted into one unreadably small image. Zoom/follow and edge-event instrumentation remain next work.

Evidence folder in the development workspace: `outputs/schematics/`, containing the screenshots and `checks.json`. Installed-world verification is recorded separately as `installed-check.json` after installation.

Installed-world visual inspection caught premature “Needs attention” wording before any proposal exists; corrected to “Awaiting proposal” with a regression test.

### Second increment — tracing and internal diagrams

Completed distinct internal diagrams for Editor, Bots and Development tasks. Editor reads exact plan-linked session metadata for open tabs, selection and unsaved drafts; stale task revisions and world changes do not reuse those files. Bot request and reply observations retain exact task/session matching. Review diagrams distinguish applying files, acceptance and completion.

Selecting a node highlights its direct connections. The inspector's connection buttons follow and center the neighboring component within the diagram; Clear trace restores all components. Zoom out/in, reset and Fit width preserve the selected component. Routes use gutters between rows and columns, with stable positions across state changes. Highlights indicate selection, not event traffic.

Validation: 167 behavior tests and 23 native checks, including a real folder selection and open Editor file, tracing, zoom, clearing selection, all screen overviews, small windows, draft retention and native browser coverage. Screenshots were visually inspected; reduced contrast for unselected nodes was adjusted to keep labels readable. Evidence: `outputs/schematics-2/` in the development workspace.

Next: internal diagrams for the remaining screens; per-edge event instrumentation and bounded event history; follow-active behavior. Wire actual WRL execution only when corresponding runtime evidence is available.

### Third increment — automatic placement and routed connections

User feedback: improve the connection lines and replace the grid arrangement with an algorithmic layout. Replaced the grid/gutter implementation with locally bundled ELK 0.10.0 layered placement and orthogonal routing. Separate fixed-side ports distinguish connections; corners are rounded. Added Flow down / Flow right, Fit diagram and selection centering on direction changes. Layout is cached by graph structure rather than status text, and asynchronous render generations discard stale results after navigation or world changes.

Validation: 169 behavior tests and 26 native checks passed. Geometry checks exercise actual work-screen flows in both directions, the app connection graph, cycles, self-loops, duplicate edges and disconnected nodes. Node rectangles do not overlap; routed orthogonal segments do not cross node interiors. Duplicate connections have distinct ports. Native checks include direction changes with retained selection, fitting the full graph, rapid toggles, every screen, Editor file state and browser surface coverage. Screenshots in `outputs/schematics-3/` were visually inspected. A whole-app fit is an overview; zoom and the inspector provide readable detail.

Dependency provenance, SHA-256 and EPL-2.0 license are retained under `cockpit/ui/vendor/`. Primary algorithm reference: https://eclipse.dev/elk/reference/algorithms/org-eclipse-elk-layered.html . No library download is needed at runtime. Remaining screen internals and actual event instrumentation continue as the next plan work.

### Fourth increment — full-canvas editor workspace

Schematics now occupies the entire width and height below Super's existing header. View selection and the diagram description float at the top left, selected-component details float at the top right, and zoom/flow controls float along the bottom. The plan remains discoverable under About this diagram. Details can be hidden and reopened without clearing the selected component. Dragging empty canvas pans the graph; scrollbars and keyboard navigation remain available.

Fit diagram reserves the floating panels' footprints while the canvas itself retains its full bounds. Resizing recalculates placement and keeps a wrapping toolbar clear of the inspector. Normal zoom supports reading and exploring individual components; fitting a large graph is an overview.

Validation: 169 behavior tests and 33 native checks passed. Large, small and narrow window screenshots were visually inspected. Evidence is saved in `outputs/schematics-4/` in the development workspace: behavior test output, native geometry/navigation/panning checks, large and small window screenshots, and saved-world installation verification. The remaining internals and observed event tracing in steps 4–5 remain future work.


### Responsiveness repair — passive status must remain passive

Investigating the frozen desktop exposed an idle feedback loop below the UI: terminal status derivation recorded worker-not-open / worker-not-occupied refusals, which advanced the projection clock and retriggered the same reads. Status and current-binding checks now derive reasons without logging; actual resolution still records refusals. Worker status shares its occupancy conditions with the action decision without producing an event on failure.

A saved-world copy went from 39 frames in a 1.5-second idle interval to no changes. Validation: 39 terminal tests, 17 authority source checks and 35 native checks passed, including idle workers and a normal-duration pointer click. Ten older worker/worktree test failures were reproduced unchanged on the baseline and are documented separately. Evidence: `outputs/freeze-fix/` in the development workspace.


### Task activity — request observations across work surfaces

Continue work and detailed task schematics now show the matching request's status,
last observed assistant text, and bounded lifecycle events. The activity panel floats
separately from graph controls; opening it does not push the graph down. It keeps
at most eight recent requests, eight events per request and the last 8,000 text
characters in memory. Nothing is restored as live activity after reload.

Managed-provider polling feeds observed output into the view; providers that return
only a final reply show waiting then completion. Counts describe received assistant
text bytes, not tokens. Repeated identical observations produce no activity event.
Task revision, assigned bot and complete runtime-session identity must match, and
late callbacks cannot revive a finished request. This is request observation, not
per-edge execution proof or WRL tracing. Next deliveries are ordered in MVP_NEXT.md.
