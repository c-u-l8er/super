# Super mobile observer — first developer alpha

September 10, 2026.

The first mobile companion is implemented in the existing Super application. It observes current runtime records through an opt-in gateway and provides Needs me, Tasks, Bots and Stack views. It can inspect retained review/test records. It cannot submit tasks, invoke agents, accept changes or deploy.

## Running it

The repository is `/home/travis/ProjectAmp2/super`. After closing the existing desktop instance, run `mobile/start-local.sh` from that repository. The launcher uses the existing release binary and Node installation, creates a fresh pairing-file location and starts Super with observation enabled. Read the code from the printed local file and enter it at `http://127.0.0.1:4318` on the host. The code is valid for ten minutes and one use; the browser session lasts eight hours. The code is not included in URLs or logs.

For a phone, a trusted private HTTPS route must reach this loopback service. Set `SUPER_MOBILE_ORIGIN` to that route's exact HTTPS origin before starting. Both devices must have access to the private network. The current host has no Tailscale installation; no phone-reachable route was created. Loopback on a phone points to the phone itself.

The current alpha needs desktop Super to remain open. Restarting the observer invalidates its sessions. Disconnect revokes the current session. Another pairing requires a new observer launch and pairing file. There is no remembered-device manager yet.

## Boundary

The gateway gets a selected projection through inherited pipes, without a runtime control descriptor. It has no mutation operation. Provider credentials and arbitrary runtime projection fields are not passed through this bridge; retained task/review content is private and becomes visible to the paired browser. The gateway is a trusted local component running as the same OS user, not a sandbox against a hostile process under that user.

The listener is loopback-only. Remote access requires a separately configured trusted HTTPS proxy; origin/host checks, one-use pairing and session cookies remain in force. There is no application-level encrypted relay. No public deployment or external provider request occurred in this pass.

## Validation

- Native compile and release build passed. Existing host warnings remain.
- Native observer tests: 2 passed, covering stale/unavailable withdrawal and projection-field allowlisting.
- Gateway tests: 8 passed, covering authentication, one-use pairing, expiry, revocation, cross-origin requests, mutation refusal, asset allowlisting, throttling and cookie properties.
- Existing WebView permission checks: 35 held, 0 failed.
- Existing intent-surface checks: 6 held, 0 failed, covering 25 human-control mutations.
- A first native test attempt failed in an unrelated repository folder chooser. The rerun uses Super's existing disposable repository fixture; this does not fix or claim to validate that chooser.

The rerun created a blocked development plan through desktop Super and showed its title, revision 2 and blocker note through the mobile observer. The bot and stack inventories rendered. At 390×844 and 360×800 the tested views had no horizontal overflow. Going offline withdrew task content; reconnecting restored it; Disconnect returned to pairing and the old session received HTTP 401. Screenshots were captured and visually inspected. The native harness also passed five existing setup assertions. No review attempt was created in this fixture, so populated review-record rendering and actual phone hardware remain unverified. Emulated viewport checks do not replace testing on actual iOS and Android devices. The existing user desktop instance was not restarted for testing.

## Next work

Implement runtime-recognized remote-device scopes and revocation before adding remote mutations. Then prove the complete plan → work → exact review → decision loop. Move the host into an independent service, and validate native packaging and notifications on real phones. See the companion research report for the competitor findings and sequencing.
