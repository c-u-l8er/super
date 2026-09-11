# Prototype to desktop app — first connected slice

Source baseline: `1671d82`. This map is derived from `site/app-prototype.html`,
`Ampd.Projection.operator/0`, `Ampd.CommandSpec`, and the existing cockpit bridge.
The implementation is in `cockpit/ui/`; the website prototype remains a design reference.

| Prototype surface | Runtime support | Desktop app in this slice |
| --- | --- | --- |
| Mission Control | Workspaces, goals, workers, pending grant requests and effect approvals | Live overview and request/consent actions. Counts derive from the delivered projection. |
| Workspace / goals / lanes | Workspace, goal, lane and worker projections; seven existing management forms | Create workspace and goal, inspect records, manage lanes and workers using existing intents. Real workspace selector filters ancestry across goals, lanes and workers. All-workspaces view is also available. |
| Worker detail / terminal | Projected occupancy, generation, purpose and terminal availability | Inspect the actual worker record; existing Watch terminal action retained. No new terminal input. |
| Capabilities | Active grants, requests, approvals | Existing approval, denial and revocation operations retained. No invented installed/discover catalogue. |
| Evidence | Separate bounded validation, worktree and capability receipt windows | All three windows displayed with totals, record details, and explicit older-history limitation. START is shown as attempt admission. |
| Runtime | Runtime health/version, world identity, peers, channels, unresolved Carrier starts and seals | Live runtime page. No inferred supervision tree or made-up heartbeat metrics. |
| Bots / conversation | No runtime bot directory or durable conversation contract | Native session conversation with configurable Ollama/OpenAI/Anthropic adapters; four setup action proposals applied through existing controls. One assistant, no autonomous Carrier. See BOTS.md. |
| Fleet / budgets / routines / gate replay / obligations | No corresponding live dashboard contract in the current operator projection | Prototype navigation destinations with explicit unavailable states. Requires separately defined runtime producers and consumer contracts. |

## Presentation and authority

The desktop uses the prototype's dark palette, navigation rail, central canvas and
activity dock, with local fonts and no remote assets. Navigation and expanded
record details are presentation state. The world remains a rendering of the latest
accepted frame. Submissions update only the session activity rail; a successful
request never directly edits runtime data on screen. Existing stream withdrawal,
acknowledgement, ordering and terminal-surface behavior remain in place.

The page finder navigates screens only. It does not execute authority operations.
The 14-command human-control allowlist is unchanged. A separate native
`choose_repository` command is granted only to the trusted main WebView. It
accepts no page-supplied path, opens a modal Linux folder chooser, validates that
the selected folder is a Git root, and queues registration on the host mutation
lane. Only a reference is returned in the submission receipt; repository records
still appear exclusively through the frame stream. Native and page guards prevent
overlapping chooser requests. Registration does not install a pack or grant access.

The Bots / Nav / Runtime modes and five Nav groups follow the prototype. The
runtime rail links projected record views and does not claim to show a live
supervision tree. Workspace selection changes presentation of the same held
frame; it cannot restore a withdrawn projection. Picker options are cleared when
the projection is withdrawn. Global authority and evidence are labeled as such.

The native bridge currently exposes no paged read surface to the main page.
History therefore honestly displays the supplied bounded windows. Adding a
Load older button requires a framed, continuity-aware host design; it is not
implemented by introducing an independent browser read channel.

## First real flow and remaining gaps

A user can create a workspace and goal, register a local repository through the
native chooser, and use the existing lane and worker forms. Runtime frames confirm
changes. Repository display currently uses runtime references because the
operator projection intentionally does not expose paths or repository names.
The chooser currently supports Linux only. A lane still needs an actor identity;
there is no provider setup or autonomous execution implied by assigning a worker.

Bots now connects a configurable provider to a session conversation and reviewed
setup proposals. Durable conversation storage and a runtime multi-bot roster
remain open; see [the Bots contract](BOTS.md). Worker assignment alone is not a bot.

## Validation

`cargo build --release --offline --manifest-path cockpit/Cargo.toml`

`node tools/check-intent-surface.mjs`

`node tools/check-webview-acl.mjs`

`node tools/cockpit-app-smoke.mjs`

The product smoke starts an ephemeral world and exercises ordinary workspace,
goal and grant-revocation flows. It owns and cleans up only its own driver process group.
Set `APP_SMOKE_SCREENSHOTS` to save optional screenshots. It does not run host
sabotage or the reset-based dogfood against the user's world.

## Record expanders

Workspace, goal, worker, repository, evidence, and runtime record rows use explicit
full-width buttons with `aria-expanded` and `aria-controls`. Their content is a
separate hidden/shown region. These record rows no longer use native HTML details
or summary elements. The open state is presentation state retained across frames;
record contents are still rebuilt from the latest delivered frame.


### Physical-click regression correction

The earlier disclosure-state fixes did not address actual mouse gestures: the
world region replaced its DOM roughly every 50 ms, removing a pressed control
before pointerup could generate a click. The renderer now plans the complete
view from each frame and reconciles it into stable controls. Record identity,
form drafts, and action arguments govern reuse; removed records still disappear.
A native WebDriver regression holds the mouse down, delivers two renders, verifies
the same node remains attached, then releases and checks visible content. The
saved-world preview also recorded human pointerdown/up/click sequences across
advancing frames, with workspace and goal expanded state changing successfully.
