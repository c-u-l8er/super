# Super: build accepted app

September 10, 2026

Super now connects **accepted review → Build accepted app → retained development bundle**. The native host resolves the runtime's acceptance, verifies the selected repository and accepted source, and starts a fixed offline cockpit build in isolation. The panel shows running, cancelled, failed, interrupted and completed states, compiler output, the source snapshot, an executable hash and the generated launcher path.

The bundle contains a Linux cockpit executable, a launcher and the captured source, including the Elixir runtime. The launcher points the cockpit at that captured runtime. The build uses a separate writable scratch directory, a read-only source snapshot and pinned Rust/cache inputs; source files and acceptance history remain unchanged. It requires existing Rust/cache inputs to build and local Elixir/desktop dependencies to launch. It is a development bundle, not a system installer.

Cancellation stops the isolated compiler. An app-only crash signals the launcher to stop; after restart, an unfinished local record is shown as interrupted. Completed build history survives restart. The app checks that the executable is still present and its hash matches before displaying it as ready. Missing or changed executables lose the ready state and launcher display.

## Verification

| Check | Result |
| --- | --- |
| Runtime regression suite | 752 passed |
| Native review/build unit suite | 16 passed |
| Accepted-build compiler tests | 3 passed: success/source drift, compiler failure, timeout/cancellation |
| UI behavior suite | 19 passed |
| Native workflow | 46 assertions passed |
| Human-control/access boundaries | 6 intent checks (25/25 mutations), 35 webview checks |
| Final release build and whitespace checks | Passed |

The native workflow uses a disposable Git repository and deterministic local provider. It obtains a real runtime acceptance for two reviewed files, cancels a build, compiles a small Rust executable containing both accepted replacements, runs that fixture executable, verifies unchanged runtime history, kills only the app during another build, restarts and checks retained/interrupted history, then alters the executable and confirms it is unavailable. Native screenshots were captured and visually inspected.

A separate full-source experiment compiled Super itself offline in isolation in approximately 7 minutes 24 seconds and produced a 20,032,904-byte cockpit executable. Its generated launcher was then opened on an isolated native display; the captured runtime connected and development plans rendered. This experiment used **synthetic acceptance input**, not a real provider cycle or a new runtime acceptance. Its snapshot was captured earlier in this increment, before the last UI/recovery refinements; the final working-tree executable was separately rebuilt and exercised by the native workflow above.

Full-source experiment snapshot: `9e4aca451c0d07f7ea6aea93b1717b3113d847ce005b7a50504e53c144db72b8`.

Executable SHA-256: `2a77f3be2e85c6c1af68f5369172c0288f938e879c19fc6915c14c79edda57e3`.

## Current limits and next steps

Build history is device-local, limited to eight retained builds per world, and is not a runtime build receipt. The fixed recipe builds the Linux Super cockpit; custom recipes and cross-platform installers are not included. Controls currently belong to accepted reviews on the current active plan revision.

Source promotion into another checkout, an in-app launch/install handoff, rollback and retention management remain. The next useful proof is an ordinary Super change completed through the real provider and this build workflow, followed by repeated daily use and installation/recovery checks. The broader MVP remains unfinished.

Evidence and current status are in the current Codex task outputs.
