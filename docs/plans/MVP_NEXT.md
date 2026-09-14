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

**New hardware track:** [Two-machine fleet MVP](FLEET_MVP.md). Start with measured inventory and a Linux execution guest on Proxmox; keep FreeBSD observation separate from worker readiness. This runs alongside provider recovery and feeds the real Super-on-Super cycle.

1. **Task activity across work surfaces — implemented and tested.** Show actual request lifecycle, bounded assistant-text preview and request events in Continue work and Schematics. Match bot, task revision and runtime session. Keep graph nodes stable while text arrives. Older saved replies remain history after reload.
2. **Connection and interruption recovery.** Make an unavailable provider an actionable next step for the assigned bot. Verify expired sign-in, cancellation, restored drafts and reconnect behavior; do not claim configured credentials prove a successful request.
3. **Repeat the full Super-on-Super cycle.** Use the assigned Fable bot with a working provider connection. Produce and inspect a real change, run required checks, explicitly accept and verify restart recovery. Provider fixture tests do not satisfy this gate.
4. **Mobile observation gate.** Verify pairing, active-task visibility, disconnect/reconnect and navigation on Android. Document what is tested on an emulator and what still needs a device.
5. **Expand internal diagrams and observed execution.** Add remaining screen internals, evidence-linked events and follow-active behavior. Per-edge execution and WRL integration require corresponding runtime observations.

## Evidence

Each increment saves test output, native checks, inspected screenshots and
saved-world installation verification in the development workspace's `outputs/`.
The task-activity increment uses `outputs/task-activity/`. The detailed graph plan
remains in [SCHEMATICS.md](SCHEMATICS.md).

Task-activity validation: 175 behavior tests and 42 native app checks passed. Native provider fixtures cover pending, complete, failure, task isolation and reload; a real Fable request remains a separate gate.
