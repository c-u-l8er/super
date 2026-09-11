# Runtime bot identities — 2026-09-07

Bots can now register a durable identity in a workspace. Existing local profiles
and conversation history are preserved. Registration is explicit from a bot page;
it is never performed automatically on upgrade or while connecting a provider.

## User flow

1. Open or create a bot under Bots.
2. Choose a workspace and select **Register in workspace**.
3. Wait for the confirming runtime frame. The page now shows Registered in runtime.
4. Edit bot updates the registered profile with a checked revision. The app refuses
   stale edits and waits for a confirming frame before leaving the form.
5. Inspect runtime identity opens a record page with its workspace and lanes. The
   Create lane action fills the registered actor into the existing lane form.
6. Remove runtime registration requires confirmation and refuses when lanes,
   active grants, pending grant requests/approvals or active effects reference the
   actor. Removing a registration preserves local conversations.

A disconnected runtime is shown as unavailable. Previously observed registration
is not relabeled as local-only, and its profile edit is disabled until the runtime
can confirm the current record. Returning to a different world does not reuse its
registration. Profile and conversation data on this device remain separate.

## Runtime contract

`bot@1` lives in the existing loci store; no new durable store was added. Fields:
`id`, `actor`, `client_ref`, `workspace_ref`, `name`, `role`, `instructions`, `group`,
`provider`, `revision`, `world_ref`, and `schema`.

The runtime mints the record ID and a random actor name. They cannot be supplied
or changed by profile fields. `client_ref` correlates an existing local profile
and its history; it is not a credential or authority token. Matching repeated
registration returns the same identity; conflicting reuse is refused. Edits cannot
change workspace, actor or local reference and require the exact current revision.

Three typed human-control mutations were added: `register_bot`, `update_bot`,
and `remove_bot`. They use the existing ordered create/patch participant boundary
and native intent queue. Mutations are confirmed through the accepted projection,
not by installing the submission response as UI truth.

The operator projection includes the directory. The existing agent projection
includes only the identity matching that channel's actor. It does not expose
other bots, grant observations to a new bot, or provide a new agent credential.
New lane assignments for a registered actor must use its registered workspace.

Recovery adds an empty `bots` collection to older loci snapshots. That adds no
identity or authority. Store sealing stays unchanged. Profiles are bounded to 50
records and 64 KiB aggregate logical size so this new directory cannot grow
without limit inside the bounded runtime frame. It is not a guarantee that all
other world collections combined fit in one frame.

## What remains open

Registration does not launch a bot, grant permissions, connect its model to an
agent channel, or implement delegated execution. Conversation requests still use
explicitly shared human workspace context and reviewed proposals. The scoped
identity in the agent projection is a prerequisite, not the complete prototype's
observation-grant/citation contract.

Next: actor-authenticated execution, scoped observation, typed parent/child
capability delegation and revocation, then worktree execution and diff review.

## Bots and Swarms

Keep **Bots** for individual persistent roles. Use **Swarms** for coordinated teams
with a shared goal, coordinator, member roles and delegated tasks/results. Current
sidebar groups are organization labels; they do not yet implement a swarm.
A future Swarms section should show each team's goal, members, blockers, task
handoffs and measured progress, with links into individual bot pages. Naming that
section Swarms becomes useful when those team operations exist.

## Verification

- Final native app smoke: 90 held, including registration, versioned edit, identity
  inspection, disconnection handling and removal with draft preservation.
- Runtime regression suite: 136 tests passed before the final directory-budget
  addition; final targeted registry/workspace suite: 18 tests passed.
- Separate-process persistent-world check passed for identity and zero granted authority.
- Existing 18 JavaScript storage/navigation/guidance tests passed.
- Release build, warnings-as-errors runtime compilation, ordered-boundary and
  ordered-closure gates, 32 WebView ACL checks and 6 intent checks passed. The
  intent surface now covers 18 human-control mutations.
- Screenshots reviewed. No live provider inference or autonomous coding was run.

Changes remain local and uncommitted; earlier local development was retained.
