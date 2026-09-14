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

Validation completed: 160 JavaScript behavior tests; 17 native checks, including all registered screens, task focus, draft retention, Escape, 1080 × 620 layout, and a native browser preview. Captured and visually inspected task, connection, whole-app, small-window and browser-cover screenshots. Diagram scroll is deliberate; the whole-app graph is not fitted into one unreadably small image. Zoom/follow and edge-event instrumentation remain next work.

Evidence folder in the development workspace: `outputs/schematics/`, containing the screenshots and `checks.json`. Installed-world verification is recorded separately as `installed-check.json` after installation.
