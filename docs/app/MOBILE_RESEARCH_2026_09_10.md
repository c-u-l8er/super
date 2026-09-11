# Super mobile: research and first build

September 10, 2026. Research is based on official product pages, documentation and repositories reviewed today. Competitor capabilities below are documented claims, not independently tested reliability or performance results. Screenshots and demo transcripts on vendor sites are not evidence of successful execution.

## Recommendation

Build Super as a host-owned runtime with several clients: desktop, mobile web, and subsequently iOS/Android. Start with private observation, add explicitly scoped remote actions, and then decouple the host lifecycle from the desktop. Retain Tauri as the initial mobile-shell candidate; test device integrations before committing. A shared UI does not make desktop filesystem/process code portable.

The competitive baseline has moved beyond tiled terminals. Several products already offer remote access, mobile clients, cross-provider coordination and durable sessions. Super's proposed differentiator is a clear chain from intent to exact source, checks, decision, and observed effect. This is a direction to validate, not a claim that competitors lack verification.

## What to learn from each product

| Product | Documented approach | What to bring into Super |
|---|---|---|
| [CodeAgentSwarm](https://www.codeagentswarm.com/) | Parallel CLI agents, searchable conversations, a task board, live diffs and attention notifications. Its site distinguishes shipped capabilities from planned autonomous mode. | One next action per task; unread/attention tracking; keep lifecycle claims distinct from a visible terminal. |
| [BridgeMind](https://docs.bridgemind.ai/docs/agent-mode) | Persistent teammates with a brief, memory, skills, approved places and separate chats. Provider engine and teammate identity are different concepts. Messaging and routines have distinct permissions. | Preserve Super bot identity across engines and sessions. Show scope and purpose on the bot page, with memory provenance and explicit routine permissions. |
| [T3 Code](https://github.com/pingdotgg/t3code/blob/main/docs/user/remote-access.md) | Managed T3 Connect, direct pairing links, one-use enrollment, private-network access and Tailscale HTTPS. Docs distinguish host reachability from merely generating a pairing URL. | A short connection flow, named hosts and revocable devices. Offer private pairing first; later add managed reachability through the existing CD cloud architecture. |
| [SanuDesk](https://sanudesk.com/features) | Agent-readable Kanban and acceptance criteria, a bundled MCP server, terminal sessions and recurring Loops. Some cloud features are marked as forthcoming. | Let human and agent workflows share task records. Add bounded recurring jobs with cost limits, ownership and explicit stop conditions after normal tasks are dependable. |
| [Harmony](https://ideharmony.com/) | A shared board, durable agent inbox/handoffs, CLI/MCP operations, isolated worktrees and sessions that can outlive the UI. | Make delegation a recorded handoff with one owner and defined inputs/outputs. Preserve machine observations separately from agent assertions. |
| [Orca](https://github.com/stablyai/orca) | Mobile companion, remote worktrees, parallel agent environments, diff comments, provider integrations and an agent-facing CLI. | Review changes and send focused feedback from the phone. Keep work environments isolated and make desktop/mobile refer to the same task. |
| [Herdr](https://herdr.dev/) | A background terminal runtime, CLI/socket operations, agent state detection and SSH-connected machines. Its managed cloud connection is described as coming soon. | Separate the host service from the client lifecycle. Treat terminal-derived states as observations with uncertainty. Recover sessions deliberately after interruption. |
| [Happy](https://happy.engineering/) | Phone/web control of local coding agents with paired-device end-to-end encrypted session data; the service describes its relay as storing opaque ciphertext. | Minimize relay access to content if adding a relay. Pair devices explicitly and make phone intervention fast. Encryption claims need implementation review and testing before Super adopts them. |
| [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control) | Local execution with remote continuity, device enrollment/revocation, reconnect behavior and push notifications. Docs describe local-only commands and process-lifecycle limitations. | Notifications should lead to an actionable task. Document exactly which actions and recoveries work remotely. Distinguish the phone disconnecting from the host stopping. |

## Super's own twist

1. **Needs me is the default screen.** Group work by the next human action, not by model provider. Retain the reason a task needs attention.
2. **A decision has a precise subject.** Remote acceptance must name the task revision, proposal identity, required-check policy and tested snapshot. A stale approval refuses; it does not silently apply to newer work.
3. **Evidence has a time and origin.** Keep “agent says finished,” “checks passed,” “accepted,” “integrated,” and “running in production” as separate facts. A historical acceptance is not a fresh disk check.
4. **Remote access has a small scope.** A device may observe without being able to start work, grant tools, accept a change or deploy. Lost-device revocation must stop subsequent actions.
5. **The runtime belongs to the host.** Eventually closing the desktop window should leave host jobs running. A sleeping execution machine still cannot compute; an awake remote host can.
6. **Reliability is part of the interface.** Reconnection must show current state, not replay a stale approval or create a duplicate task. Pending, refused and outcome-unknown are useful states.

## What was built in this pass

An opt-in mobile observer in the existing Super repository:

- A Rust observation bridge exports selected runtime projection collections over inherited pipes. The child receives no runtime/control descriptor or mutation queue.
- A Node HTTP gateway binds only to loopback. HTTPS remote origins can be configured for a private reverse proxy. It uses a short-lived, single-use pairing code, an HttpOnly same-site session cookie, bounded connections and explicit origin checks.
- A responsive companion has Needs me, Tasks, Bots and Stack views. It reuses Super's existing task-progress and check-coverage logic and exposes retained review records for inspection.
- Expired host observations and failed connections withdraw current data. The UI does not present unavailable state as zero tasks or certify process liveness from worker records.
- Mobile is disabled unless explicitly configured when launching Super. No cloud service, remote exposure, account registration or provider request was performed by this change.

This is a **read-only developer alpha**, not the originally described complete mobile control loop. It requires Node on the host and desktop Super to remain open. There are no native phone packages, push notifications, device-management screen, remote task submission, remote approvals or autonomous execution in this slice. Pairing is limited to one browser session per observer launch; restarting invalidates sessions and requires a fresh pairing-file path. It uses transport security through the configured private HTTPS proxy; it does not implement Happy-style application-level end-to-end encryption.

## Next implementation sequence

### 1. Private-device dogfooding

Configure a private HTTPS route on an existing trusted network; test on an actual iPhone and Android device. Measure pairing completion, resume behavior, small-screen review readability and stale-state withdrawal. Tailscale is not installed on the current host, so a real off-machine connection is not established by this pass. [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve)

### 2. Scoped remote control

Introduce runtime-recognized remote-device identities and revocation with separate observe, plan, message and review scopes. Do not map arbitrary network requests onto the privileged human channel. Add durable request IDs and retry receipts, current-world checks and proposal/snapshot-bound acceptance. Build the first vertical workflow: create a plan, send bounded work, observe it, review its evidence and decide. Plans alone do not execute agents in current Super.

### 3. Host independence

Move observation and execution ownership to a supervised host process; desktop and phone attach as clients. Test UI exit, host restart, interrupted jobs and reattachment. Keep this local-host implementation consistent with the existing CD architecture; do not introduce a new cloud database or hosted Elixir service as a shortcut.

### 4. Native clients and notifications

Validate a small Tauri 2 shell on iOS and Android with credential storage, deep links, accessibility and notification delivery. Retain Capacitor as an alternative if the required integrations are materially simpler. Deliver notifications only for meaningful completion, failure or required action; opening one fetches current evidence before enabling a decision. [Tauri](https://tauri.app/) · [Capacitor](https://capacitorjs.com/docs)

### 5. Fleet and managed reachability

Add named hosts, host-specific availability, task placement and identity-preserving handoffs. Consider an outbound relay through the existing CD cloud stack after the private-network path works. Reuse established cryptographic libraries and protocols; review key lifecycle and recovery separately from the transport.

## Reuse policy

Borrow interaction patterns and architecture lessons now. Before importing third-party code, inspect the exact repository revision and license, assess dependencies and maintenance, and retain required notices. This pass copies no competitor implementation. Open-source status does not establish security, performance or compatibility with Super's runtime invariants.

## Validation

See the separate build report for measured checks and screenshots. Browser-width emulation is not an iOS/Android device test; synthetic vendor demos and controlled local fixtures are not real-provider dogfooding.
