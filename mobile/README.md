# Super mobile observer

Opt-in, read-only developer alpha. Run `./mobile/start-local.sh` from the Super repository after closing the existing desktop instance. It uses the existing release build and Node 22+. Pair at http://127.0.0.1:4318 with the code in the file printed at launch. Code: one use / ten minutes. Session: eight hours. Restarting revokes all sessions.

The desktop shows that code itself: **Runtime → Mobile device** in the sidebar, or **File → Pair a phone…**. That page reports whether the companion is running, shows the code in four-character groups with the time left, and states what a paired phone can and can never do.

`SUPER_MOBILE_PANEL=1 ./mobile/start-local.sh` also shows it in a separate window, in four-character groups so it can be typed onto a phone; `./mobile/pairing-panel.sh $SUPER_MOBILE_PAIR_FILE` opens the same window for an observer that is already running. It reads the 0600 file directly and passes the code to the dialog on stdin, so the code stays out of `ps`, out of URLs and out of logs. It needs `yad`; without it the script prints the grouped code to the terminal instead. A new code does not need a restart: the desktop mints one from Runtime → Mobile device → “New pairing code”, which resets the code and its ten minutes and touches no session, so a device that is already paired stays paired.

For private phone access, put a trusted HTTPS proxy in front of the loopback listener and set `SUPER_MOBILE_ORIGIN` to its exact origin. Do not publish it publicly. No Tailscale setup is performed automatically.

The host sends selected runtime observations to the gateway over inherited pipes. The gateway receives no runtime/control descriptor and exposes no mutation operation. Invalid, expired or unavailable observations withdraw the current view. The shared task-progress code is guidance, never authority.

Run `node --test mobile/test/gateway.test.mjs` and `cargo test --manifest-path cockpit/Cargo.toml mobile_gateway::tests`. See `docs/app/MOBILE_OBSERVER_2026_09_10.md` for measured results and limitations, and `docs/app/MOBILE_RESEARCH_2026_09_10.md` for next milestones.

This requires the desktop to stay open. Native packages, remote actions, device scope management, push notifications, daemon ownership and real-phone validation remain open. The gateway is a trusted same-user local component, not process isolation against that user.

## Android browser recovery regression

The web companion accepts the grouped code displayed by desktop Super and marks the input as a one-time code rather than a password. Pairing invalidates earlier unauthenticated refreshes so they cannot overwrite the new session. Task lists and details include stable task IDs. Temporary observation/network loss removes live task content while retaining the selected task for the same runtime world; a replacement world clears that selection. Successful reconnect clears stale warnings. Failed logout is reported as unconfirmed, and successful logout points to New pairing code instead of requiring a host restart.

Run `tools/mobile-android-smoke.mjs` with `ADB` set to the Android platform-tools executable and `SUPER_VISUAL_EVIDENCE_DIR` for screenshots. It requires a booted Android emulator with Chrome first-run setup completed. It owns a fixture gateway on loopback 4342 and a Chrome debugging forward on 9223. Those ports are for this test only. It creates two distinctly identified tasks with the same title, uses test pairing codes, interrupts the forwarded connection and existing sockets, backgrounds/resumes Chrome, changes the fixture world, and checks logout and code renewal. It does not pair with real user records.

Measured on Android 15 with Chrome 124: 14 checks passed. This is Android browser validation of the web companion, not Expo/native-package, physical-phone, private-HTTPS or real-provider validation.

## Existing private HTTPS connector

`mobile/private-connector.mjs` supports the current companion at `/mobile` while retaining the older `/api/observer/snapshot|pair|logout` API paths. Current `/api/snapshot|pair|logout` paths reach the same paired gateway. Exact private origin, Tailscale owner identity, loopback backends and read-only route checks remain required. UI asset requests do not forward session cookies to the UI backend; private response cookies receive Secure. The connector does not mint codes or expose a renewal/control endpoint.

The private network and Serve configuration must already exist. This connector listens only on loopback port 4320 with `SUPER_MOBILE_PRIVATE_ORIGIN` and `SUPER_MOBILE_TAILSCALE_LOGIN` explicitly configured. The prototype UI remains the fallback for older non-companion routes. Verify with `node --test mobile/test/private-connector.test.mjs mobile/test/gateway.test.mjs`.
