# Opening a registered repository in the Editor without the native chooser

September 18, 2026. This pass closes the gap that stopped two rounds of Super's own
development loop on 2026-09-16 and 2026-09-17: the Editor's repository root could
be set only through `choose_workbench`, a GTK folder dialog on the cockpit's main
thread. No script can answer that dialog reliably; while it waits, every other
command stalls, including a harness's own teardown; and the root was held in memory
only, so every restart re-required a person at the display before one proposal
could be applied.

## The ruling

A registered repository may be reopened in the Editor **by its reference**, with no
dialog. The reasoning:

- Registration already is the person's decision. `register_repository` stores exactly
  the folder they picked in the native chooser, as an ordered write in the world.
  Reopening that folder asks nothing of them that they have not already decided.
- The reference is what every other surface already uses. The projection publishes
  repositories as `{ref, name}`; `open_lane` takes a `repository_ref`, never a path;
  plan matching compares the Editor's root with the plan's registered repository.
- The alternatives were weaker. A path remembered by the page was ruled out on
  2026-09-07 (`WORKBENCH_RECOVERY_2026_09_07.md`: recovery "does not use a saved path
  as permission to open a repository automatically") and is not reinstated here. An
  environment variable at launch binds one root to one process and cannot be changed
  without a restart, which is the restart problem restated. Widening `choose_workbench`
  to accept a path from the page was refused outright: the page must not be able to
  name an executable folder.

The boundary is unchanged: the webview never supplies a path and never receives one
from the runtime. It sends `rp_XXXX`; the host asks the runtime over the bridge; the
runtime answers the stored path to the host process only; the host re-checks that the
folder is a Git top-level and holds it exactly as the chooser's result was held.

## What changed

- `Ampd.Transport.HostBridge` gained `registered_repository`. It takes a reference of
  the form `rp_` plus digits, at most 100 bytes, and answers `{ref, path}` from
  `Ampd.Worktree.repo/1`. Anything else, including a path or an unknown reference, is
  refused as `repository-unknown` with `requires_human: true`. The projection still
  carries no path.
- The cockpit gained the `open_workbench_repository` command (registered, declared
  in the ACL manifest, granted to the trusted `main` webview only). It validates the
  reference before the runtime is asked, resolves it through the bridge, and calls
  `Workbench::choose`, so the generation increments and running shells refuse the
  switch exactly as before.
- The Editor, Terminal and Browser toolbars gained a **Registered repositories**
  picker and an **Open registered** control, painted from the held projection on the
  existing two-second inventory poll. The native chooser remains, relabelled
  **Other folder…**, for a folder that is not yet registered. Its identifier
  `development-choose-<page>` is unchanged so existing smokes still find it.
- `tools/lib/cockpit-control.mjs` gained `openRepository(ref)`.

## Verification

- `tools/registered-repository-smoke.mjs`: **19 checks held, 0 failed** in a throwaway
  world, driven through the real cockpit with `SUPER_COCKPIT_CARRIER=1` supplying the
  registered repository. The Editor adopted the folder in 303 ms with no window titled
  like the chooser on the display; a repeated open moved the generation from 1 to 2;
  `rp_9999`, `/tmp`, an empty string and `rp_0001/..` were refused and changed nothing.
- `ampd/test/registered_repository_bridge_test.exs`: 4 tests over a socketpair, as the
  Rust host speaks. Together with the other affected suites (development attempts,
  downgrade, development tasks, transport, repository display): **102 tests, 0 failures**.
- `cargo test --release repository::`: 5 tests, 0 failures, two new.
- Static gates: webview ACL 41 held (47 registered commands, three lists agree),
  source hygiene clean. The ordered-boundary and ordered-closure gates were RED before
  this change (recorded at `f2e5fda`) and read only `ampd/lib`; see the gate log for
  their state after it.

## What this does not do

- It does not persist the workbench root across restarts. After a restart the person,
  or a script, chooses a registered repository again; that is one click or one call
  and no dialog, which is the property that was missing.
- It does not register a repository. Registration still goes through the native
  chooser, on purpose: it is the one act that decides which folder on this machine the
  runtime may ever create worktrees from.
- The person-facing picker was verified through the driven cockpit, not observed by a
  person at the screen.
