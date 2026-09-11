# Super dogfooding continuation — 2026-09-07

## Native session links

Terminal and Browser now have **Link to bot**. A bot’s Work page lists those actual native sessions, with current state and Open/Unlink actions. Links survive main-page reloads; closing a session removes its link. Browser slot reuse receives a new session identity. App process restart ends sessions and their links. These are explicit local associations, separate from runtime actor assignments and delegated execution. Linking transmits no content and grants no provider tools.

## Reviewed code proposals

A provider can return the typed `propose_file_edit` action for an Editor file explicitly shared in the current message. The UI binds review to that exact file snapshot and page/repository generation. Wrong files, excerpts without a full snapshot, changed drafts and replaced repositories cannot be applied. Historical conversation proposals remain read-only after restart.

**Review in Editor** shows both complete drafts with syntax highlighting. Cancel preserves the draft and disk. **Use as editor draft** stages unsaved text; **Save** remains separate and keeps native disk-conflict checks. Proposals contain complete bounded text (32,000 UTF-8 bytes maximum), never a command or automatic write.

The isolated native flow has verified a provider response → review → draft → Save → terminal-served browser preview. The fixture provider is explicitly a test server; this alone is not a real model dogfooding claim.

Automatic Swarm delegation, actor-authenticated coding execution, durable agent-run recovery and revision-bound acceptance remain open. Rich landing-page scrolling remains an unresolved native rendering issue.

## Verification and running state

- Native workbench: **51 held**, covering code proposals, review/cancel/stage/Save, stale-draft refusal, editor conflict protection, linked session round trips, main-page reload, close/unlink, browser isolation, real keyboard input, native corner drag and process restart recovery.
- Native app regression: **97 held**.
- JavaScript behavior checks: **40 passed**. Provider proposal tests: **5 passed**. Native session lifetime tests: **3 passed**. WebView ACL: **35 held / 0 failed**.
- Release build and whitespace checks passed. Existing three host compiler warnings remain.
- Native screenshots captured and inspected. The screenshot-mode drag harness exposed desktop activation/coordinate sensitivity; the final full 51-check run passed without optional screenshot capture, with activation and pointer diagnostics in the helper.
- Updated saved-world app running: **4 workspaces, 2 goals, 2 lanes** preserved. Existing two shells and loopback preview restored and linked locally to Workspace assistant. No provider content was sent by linking them.

## Live model dogfooding block

Both saved provider connections report signed in. Automatic approval review nevertheless rejected the proposed source transmission because the exact payload/destination had not been explicitly approved. The rejected combined action did not run. Unaffected local restart and linking were completed separately; the provider request was not retried or routed elsewhere.

Pending approval: send only `cockpit/ui/file-proposal.js` and the prepared improvement request to the signed-in ChatGPT/Codex connection inside Super, with workspace-context sharing disabled. The requested improvement is a pure changed-range helper for code review. No real model-authored edit has been claimed or applied.

Changes remain local and uncommitted.
