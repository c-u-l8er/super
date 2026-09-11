# Super native UI evidence — September 8, 2026

The current UI was exercised in four disposable native suites: plan/file workflow (25 checks), editor/terminal/browser/recovery (51), general app/navigation/bots (97), and review component failure/cancellation (8). All 181 assertions passed. One compositor-only pointer-resize check was skipped because the virtual display has no window manager. The evidence gallery contains 55 native screenshots; tests establish behavior separately from the photographs.

## Repeatable capture

`tools/visual-evidence.mjs` is an optional recorder used by the four existing smoke scripts. With `SUPER_VISUAL_EVIDENCE_DIR` unset, it is inert. With it set, the isolated native wrapper is required. Each suite writes its own PNGs and `evidence.json`: timestamped assertion names, capture hashes, executable hash, test-file hash, skip reasons, and completion state. An interrupted suite is marked incomplete and is not counted as passed. Use a fresh destination per run to preserve earlier receipts.

Set `DEVELOPMENT_TEST_ROOT` to a newly created disk-backed scratch directory with sufficient space. The system `/tmp` volume was nearly full during this session. Set `SUPER_XVFB_BIN_DIR` if Xvfb/xvfb-run are supplied from a local extracted tool directory. `xauth` must also be available. The wrapper isolates the display and process state; it does not restart the user's saved-world app.

Run these through `bash tools/native-ui-test.sh node` and retain stdout/stderr beside the receipt directories:

- `tools/development-plan-file-smoke.mjs`
- `tools/development-smoke.mjs`
- `tools/cockpit-app-smoke.mjs`
- `tools/file-review-component-smoke.mjs`

Use distinct `APP_SMOKE_PORT` values for simultaneous app suites. The workbench suite uses `DEVELOPMENT_SMOKE_PORT` and `DEVELOPMENT_APP_PORT`. Shell and provider fixtures bind loopback. Screenshot capture is scoped to windows descended from the test driver. Evidence-only scrolling places the asserted attachment/history content in view without changing product state.

## User-facing record

The current task's outputs contain `Super_UI_Evidence_Gallery.html`, `Super_UI_Change_Record.md`, the full suite logs, original PNGs and receipt manifests. The gallery embeds its 55 photos and works as a portable offline artifact; the adjacent evidence folder contains the original images and logs. The change index relates the earlier implementation reports to the latest screenshots. Original successful captures are retained separately from the final captures with improved camera positions.

The report's images and links were checked directly. A live gallery browser preview could not be verified: the standalone browser failed to launch, and the browser tool blocked the local-file URL. No URL-policy workaround was used. Search/zoom interactions are not claimed as browser-tested. Markdown and original PNGs remain independently accessible.

## Limits and next work

Provider replies are deterministic local fixtures, not a real-model dogfood run. Some unavailable-state checks deliberately supply fixture state; the component suite uses explicit verification callbacks. Other integration checks exercise real native repository matching, exact file bytes, saves and recovery. No source or validation authority is inferred from screenshots.

Visual follow-ups: long editor error text truncates; narrow navigation is tall; isolated-display captures can show transient scrollbar lines across dialogs. Cross-platform, full keyboard/screen-reader coverage, every responsive breakpoint and normal-compositor border dragging remain unverified.

Durable attempts, result-bound validation, explicit acceptance, and a real-model Super-on-Super cycle remain the product critical path. This pass adds the repeatable evidence workflow, not a new development-attempt implementation. No commit, push or deployment was performed.
