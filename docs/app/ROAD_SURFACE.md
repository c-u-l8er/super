# Super inside the T&R road

The desktop launcher opens the T&R road and enters the Super sign. Super's existing trusted webview is placed inside the sign's read frame. It is not a screenshot, a second runtime, or a button that opens a separate cockpit window.

Use **Leave window** to return to the road. Select the **Super (CD)** sign to resume the same live view and session. Resizing keeps the view aligned with the sign. Closing the road exits the desktop application.

The road webview remains `cd-road`; the trusted app view remains `main`. The road has only a narrow `super_sign` placement command and cannot submit runtime intents, choose files, or operate bots. Browser previews and terminal views remain separate webviews with their existing permissions. Linux placement uses a native overlay with explicit child allocations.

The product adapter is in `cockpit/road-host/adapter.js`, applied to shared road assets by `cockpit/build.rs`. Notes and Digest remain standalone proof apps in RRABBIT; Super's product catalogue presents Super. `SUPER_ROAD=0` is an explicit troubleshooting/test override for the desktop launcher.

Run `tools/native-ui-test.sh node tools/super-sign-smoke.mjs` with native test dependencies available. It measures the live viewport against the sign, checks runtime connectivity, denies an intent from the road, verifies leave/re-entry without recreating the session, and verifies resizing. `tools/road-battery.mjs` uses this product flow; RRABBIT retains its standalone proof tests.

The Linux launcher defaults to X11/XWayland with WebKit compositing disabled, matching native integration testing. Native Wayland showed duplicated road pixels in the reparented Super view on the target desktop. `SUPER_DESKTOP_BACKEND` remains an explicit troubleshooting override.
