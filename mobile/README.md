# Super mobile observer

Opt-in, read-only developer alpha. Run `./mobile/start-local.sh` from the Super repository after closing the existing desktop instance. It uses the existing release build and Node 22+. Pair at http://127.0.0.1:4318 with the code in the file printed at launch. Code: one use / ten minutes. Session: eight hours. Restarting revokes all sessions.

The desktop shows that code itself: **Runtime → Mobile device** in the sidebar, or **File → Pair a phone…**. That page reports whether the companion is running, shows the code in four-character groups with the time left, and states what a paired phone can and can never do.

`SUPER_MOBILE_PANEL=1 ./mobile/start-local.sh` also shows it in a separate window, in four-character groups so it can be typed onto a phone; `./mobile/pairing-panel.sh $SUPER_MOBILE_PAIR_FILE` opens the same window for an observer that is already running. It reads the 0600 file directly and passes the code to the dialog on stdin, so the code stays out of `ps`, out of URLs and out of logs. It needs `yad`; without it the script prints the grouped code to the terminal instead. A new code still needs a fresh observer launch.

For private phone access, put a trusted HTTPS proxy in front of the loopback listener and set `SUPER_MOBILE_ORIGIN` to its exact origin. Do not publish it publicly. No Tailscale setup is performed automatically.

The host sends selected runtime observations to the gateway over inherited pipes. The gateway receives no runtime/control descriptor and exposes no mutation operation. Invalid, expired or unavailable observations withdraw the current view. The shared task-progress code is guidance, never authority.

Run `node --test mobile/test/gateway.test.mjs` and `cargo test --manifest-path cockpit/Cargo.toml mobile_gateway::tests`. See `docs/app/MOBILE_OBSERVER_2026_09_10.md` for measured results and limitations, and `docs/app/MOBILE_RESEARCH_2026_09_10.md` for next milestones.

This requires the desktop to stay open. Native packages, remote actions, device scope management, push notifications, daemon ownership and real-phone validation remain open. The gateway is a trusted same-user local component, not process isolation against that user.
