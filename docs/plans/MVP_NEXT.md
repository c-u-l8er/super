# Super development MVP — next deliveries

Updated 2026-09-14. This is the current execution order; the older inventory in
`docs/app/MVP_PASS_2026_09_07.md` retains the broader scope and history.

## Acceptance target

Develop a bounded Super change inside Super: select a saved task and repository,
prepare source files, send the assigned bot a request, observe progress or recover
from a failure, review the proposed bytes, run checks, explicitly accept, and
restore the same work after restart.

## Current baseline

- Continue work chooses one task and guides preparation, reply, review, checks and completion.
- Editor and retained reviews link to exact task revisions and source snapshots.
- Schematics fills the workspace, with automatic routing, zoom, pan and floating panels.
- Idle worker status checks no longer create a self-triggering refusal/refresh loop.
- User confirmed the desktop is responsive after that repair.

## Delivery order

**Hardware track:** [Two-machine fleet MVP](FLEET_MVP.md). Both hosts have machine and guest detail pages, a compact Machines directory, and consistent schematic naming. Separate Proxmox and bhyve Linux guests have passed restricted task-bound checks and interrupted-receiver recovery. Wifibox remains separate. Physical network-outage and whole-host reboot drills remain open.

1. **Task activity across work surfaces — implemented and tested.** Show actual request lifecycle, bounded assistant-text preview and request events in Continue work and Schematics. Match bot, task revision and runtime session. Keep graph nodes stable while text arrives. Older saved replies remain history after reload.
2. **Connection and interruption recovery — current increment.** Continue work, task status and schematic activity distinguish capacity limits, expired sign-in, cancellation, timeout and unavailable-provider replies. Restored task attachments no longer hide failure guidance behind a Send action. Recovery opens the assigned conversation, preserves drafts and requires an explicit retry. Live recovery observations remain session-only; saved conversation history remains separate. Controlled native provider checks cover connection failure, capacity failure, restored files and successful explicit retry. A real provider reply remains a separate gate.
3. **Repeat the full Super-on-Super cycle.** Use the assigned Fable bot with a working provider connection. Produce and inspect a real change, run required checks, explicitly accept and verify restart recovery. Provider fixture tests do not satisfy this gate.
4. **Mobile observation gate — Android browser regression implemented.** The read-only web companion passes grouped pairing, exact task identity, observation withdrawal, interrupted-connection recovery, background/resume, world replacement, failed logout and code-renewal checks on Android 15 / Chrome 124 with controlled records. The existing private Tailscale HTTPS route now serves the current companion at /mobile. A same-node client with certificate verification paired with the actual saved workspace and matched all 14 task identities; one-use codes, renewal, logout and read-only refusals passed. Physical-phone access and the separate native/Expo client remain open; same-node HTTPS and emulator fixtures do not complete those gates.
5. **Expand internal diagrams and observed execution.** Add remaining screen internals, evidence-linked events and follow-active behavior. Per-edge execution and WRL integration require corresponding runtime observations.

## Evidence

Each increment saves test output, native checks, inspected screenshots and
saved-world installation verification in the development workspace's `outputs/`.
The task-activity increment uses `outputs/task-activity/`. The detailed graph plan
remains in [SCHEMATICS.md](SCHEMATICS.md).

Task-activity validation: 175 behavior tests and 42 native app checks passed. Native provider fixtures cover pending, complete, failure, task isolation and reload; a real Fable request remains a separate gate.

### Fleet advisory checks — latest delivery

Continue work, plan details and Schematics now have task-bound remote-check
controls and device-local history. Execution is enabled through the approved restricted Proxmox check key and
fixed VM-100 bridge. Three real task-bound checks passed; an interrupted local
result receiver recovered the original receipt without resubmission. See
[FLEET_MVP.md](FLEET_MVP.md#task-bound-advisory-check-implementation-2026-09-14).
The separate bhyve guest is now enrolled with destination-bound receipts and a restricted SSH bridge. Next: a physical network-outage drill. Actual app
screenshots and recovery evidence are in `outputs/fleet-active/`. Earlier
simulation screenshots remain labeled separately.
