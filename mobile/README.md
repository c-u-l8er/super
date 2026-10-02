# Super mobile companion

Opt-in developer alpha with task observation and shared bot conversations. Run `./mobile/start-local.sh` from the Super repository after closing the existing desktop instance. It uses the existing release build and Node 22+. Pair at http://127.0.0.1:4318 by pasting the code from desktop Super's Mobile device page (or from the file printed at launch). Code: one use / ten minutes. Session: eight hours. The launcher persists unexpired sessions privately across restarts; logout revokes the current session. Upgrading from a gateway without persistence requires a fresh pairing code once.

## What a paired phone can do

A paired phone reads this host's plans, review evidence and screenshots, and chats with its bots. In Chat it can open, start, rename and pin conversations, save a draft to the desktop, and **send a message, which runs on desktop Super with that conversation's provider**. Opening a conversation on the phone also selects it on the desktop: there is one shared active conversation. Decisions, file changes, checks, acceptance and every runtime intent stay on the desktop, because the gateway has no control channel (below). The phone's **Stack** tab says the same.

## Pairing code

The code is 48 hexadecimal characters (`randomBytes(24)`), for one use within ten minutes. **Paste it.** Before sending, the companion removes every space, line break and dash (including the dashes iOS substitutes for a typed `--`) and folds capital letters, so the desktop's grouped display, the text of its QR code, or a code typed in fours with dashes all pair (R126). Nothing is checked on the phone: a wrong code of any shape is sent, refused, and counted toward the gateway's limit of ten failures a minute.

The desktop shows that code itself: **Runtime → Mobile device** in the sidebar, or **File → Pair a phone…**. That page reports whether the companion is running, shows the code in four-character groups with the time left, and states what a paired phone can and can never do.

`SUPER_MOBILE_PANEL=1 ./mobile/start-local.sh` also shows it in a separate window, in four-character groups for reading (pasting stays the easy path); `./mobile/pairing-panel.sh $SUPER_MOBILE_PAIR_FILE` opens the same window for an observer that is already running. It reads the 0600 file directly and passes the code to the dialog on stdin, so the code stays out of `ps`, out of URLs and out of logs. It needs `yad`; without it the script prints the grouped code to the terminal instead. A new code does not need a restart: the desktop mints one from Runtime → Mobile device → “New pairing code”, which resets the code and its ten minutes and touches no session, so a device that is already paired stays paired.

For private phone access, put a trusted HTTPS proxy in front of the loopback listener and set `SUPER_MOBILE_ORIGIN` to its exact origin. Do not publish it publicly. No Tailscale setup is performed automatically.

The host sends selected runtime observations to the gateway over inherited pipes. The gateway receives no runtime/control descriptor and exposes only a bounded conversation mailbox to the existing desktop chat UI; it cannot execute runtime intents. Invalid, expired or unavailable observations withdraw the current view. The shared task-progress code is guidance, never authority.

Run `node --test mobile/test/gateway.test.mjs` and `cargo test --manifest-path cockpit/Cargo.toml mobile_gateway::tests`. See `docs/app/MOBILE_OBSERVER_2026_09_10.md` for measured results and limitations, and `docs/app/MOBILE_RESEARCH_2026_09_10.md` for next milestones.

This requires the desktop to stay open. Native packages, task execution and review actions, device scope management, push notifications, daemon ownership and real-phone validation remain open. The gateway is a trusted same-user local component, not process isolation against that user.

## Android browser recovery regression

The web companion accepts the code however it is grouped (see Pairing code) and marks the input as a one-time code rather than a password. Pairing invalidates earlier unauthenticated refreshes so they cannot overwrite the new session. Task lists and details include stable task IDs. Temporary observation/network loss removes live task content while retaining the selected task for the same runtime world; a replacement world clears that selection. Successful reconnect clears stale warnings. Failed logout is reported as unconfirmed, and successful logout points to New pairing code instead of requiring a host restart.

Run `tools/mobile-android-smoke.mjs` with `ADB` set to the Android platform-tools executable and `SUPER_VISUAL_EVIDENCE_DIR` for screenshots. It requires a booted Android emulator with Chrome first-run setup completed. It owns a fixture gateway on loopback 4342 and a Chrome debugging forward on 9223. Those ports are for this test only. It creates two distinctly identified tasks with the same title, uses test pairing codes, interrupts the forwarded connection and existing sockets, backgrounds/resumes Chrome, changes the fixture world, and checks logout and code renewal. It does not pair with real user records.

Measured on Android 15 with Chrome 124: 14 checks passed. This is Android browser validation of the web companion, not Expo/native-package, physical-phone, private-HTTPS or real-provider validation.

## Existing private HTTPS connector

`mobile/private-connector.mjs` supports the current companion at `/mobile` while retaining the older `/api/observer/snapshot|pair|logout` API paths. Current `/api/snapshot|pair|logout` paths reach the same paired gateway. Exact private origin, Tailscale owner identity, loopback backends and strict route checks remain required. UI asset requests do not forward session cookies to the UI backend; private response cookies receive Secure. The connector does not mint codes or expose a renewal/control endpoint.

The private network and Serve configuration must already exist. This connector listens only on loopback port 4320 with `SUPER_MOBILE_PRIVATE_ORIGIN` and `SUPER_MOBILE_TAILSCALE_LOGIN` explicitly configured. The prototype UI remains the fallback for older non-companion routes. Verify with `node --test mobile/test/private-connector.test.mjs mobile/test/gateway.test.mjs`.

## Shared conversations (desktop must remain open)

Expo and the browser companion show the desktop’s existing bot identities and conversation history, pinned/recent lists, editable titles, shared drafts, task links in Expo, and public reply progress. Opening a conversation on the phone also selects it on desktop. This is one shared active conversation, not independent concurrent provider sessions. Choose/connect a provider on desktop; enter its exact connected model on the phone before sending. Model drift refuses the send. Attachments and proposal application remain on desktop.

The desktop retains sole ownership of history and inference. Phone operations are limited to open, create, title/pin update, draft save and send. Revision checks prevent silently overwriting a newer desktop draft. Clients retain local drafts and pending request identities; retry is explicit. A durable desktop receipt is written before dispatch so an interrupted send is never replayed automatically. An uncertain receipt means inspect the conversation before sending again. Requests expire after two minutes; public history/progress is refreshed roughly once a second and withdrawn on connection loss. Views larger than 4 MB are refused.

The installed Expo Go delivery is a separate repository/service on port 8081. Open `exp://super-mobile.tail988e95.ts.net:8081` in Expo Go (SDK 57), then pair on Host. Browser access remains `https://super-mobile.tail988e95.ts.net/mobile`. Updating this repository alone does not update Expo. The native implementation lives in the existing `super-native` checkout.

Session files are scoped to the configured origin, private mode 0600, atomically replaced, and retain only unexpired eight-hour sessions. They contain credentials and must never be published. The launcher uses `$XDG_STATE_HOME/super/mobile/sessions.json` (default `~/.local/state/super/mobile/sessions.json`). This does not change private network routing.

Verification: `node --test mobile/test/*.test.mjs`, `node --test tools/mobile-conversation-ledger-test.mjs`, and `tools/mobile-conversation-smoke.mjs` with a built cockpit under the native test display. The smoke uses an explicit local fixture model, never an external default model. Real provider authentication, physical-phone validation, mobile proposal approval/application, and automatic source-bound build/launch/capture remain unfinished.

### Phone chat layout

The browser companion separates Chats and conversation settings into panels, leaving a scrolling transcript and bottom composer. Model selection is an explicit tap in settings. Expo has the corresponding native layout, searchable conversation lists, and a composer verified above the Android keyboard. Neither UI update requires restarting the gateway or pairing again.

### Starting a task discussion

Open a task review, choose **Discuss task**, then **Start discussion**. The selected chat bot is named before creation; use Chats to select another bot first if needed. Desktop validates the task's world lineage and revision and prepares a separate shared draft from its current title, status and criteria. The existing conversation stays saved. Opening or preparing a discussion does not call a provider: review the draft, select the exact connected model, then Send. The task link returns to the same current revision. This prepares a discussion, not task execution, source capture or approval.

Validation: `node --test tools/mobile-task-discussion-test.mjs`; the native desktop flow is `tools/native-ui-test.sh node tools/mobile-task-discussion-smoke.mjs`, using only an explicit local fixture model.

### Conversation navigation and live replies

The desktop, browser companion and Expo chat lists can filter by bot and group by bot or recency. Pins stay first within a group. Lists distinguish Waiting, Generating, Interrupted, Needs attention, Needs review, Draft and Ready. Read markers are local to each device; opening a list does not mark the active thread read. A reply is marked read when its conversation is visible at the latest messages. Existing history is initially treated as read; later replies and new threads can show New reply.

Direct Ollama NDJSON and OpenAI/Anthropic SSE replies are decoded incrementally, with text sent through a Tauri channel. Managed Codex/Claude public assistant text feeds the same live transcript. Mobile mirrors the text through the private gateway, polling more frequently during generation. Updates are batched rather than sent once per token. No partial tool arguments become proposals; completion and normal action validation are required. Interrupted streams retain the original draft and a labeled partial result.

Super still has one active provider turn at a time. Chats remain navigable while it runs; the generating indicator follows the owning conversation and a second send is refused until that reply finishes or is cancelled. External provider/account behavior must be checked with an explicitly selected model; the automated streaming smoke uses a delayed local fixture only.

Checks: `node --test tools/conversation-list-test.mjs`, `cargo test --manifest-path cockpit/Cargo.toml bot_stream`, and `tools/native-ui-test.sh node tools/mobile-streaming-smoke.mjs`.

### iOS navigation and layout

Where you are lives in the URL (`#/tasks/dt_0052`, `#/tasks?show=all&bot=bt_0003`) and in history. Safari's back swipe returns from a plan to its list, at the position you left it, and a reload or pull-to-refresh returns to the same place. A plan opens at its top, and the two-second refresh never moves the page. Tasks lists the plans that need attention first, then the other open ones, and finished plans under **Done** or **All**; each badge is coloured by its state. Tapping a bot opens its plans. **Disconnect** asks before it ends the session. Under 600 px the header is compact, and the page starts below the status bar (`env(safe-area-inset-top)`).

Checks: `node --test mobile/test/*.test.mjs`. The phone tests run the real `ui/app.js` and `ui/conversations.js` in a small DOM built from `ui/index.html` (`mobile/test/phone.mjs`), against a real gateway over loopback HTTP, with the page's timers ticked by the test.
