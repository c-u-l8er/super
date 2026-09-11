# Super prototype-to-app pass 2 — 2026-09-07

Compared `site/app-prototype.html` with the current native cockpit, the preceding
MVP audit, and the local development and runtime bot contracts. The prototype
remains a simulated design reference; its success counters and delegation diagrams
are not runtime facts.

## Implemented in this pass

- **Editor → Changes:** read-only Git inventory and per-file patches, with separate
  working-tree, staged, and untracked sections. Uses the selected repository,
  excludes unsaved drafts, labels disk snapshots, supports refresh and returning
  to the matching editor file. Reviewing never stages, commits or accepts work.
  Save/reload/context actions for another editor buffer are disabled during review.
- **Record sections:** Overview, Related work and Record data tabs; keyboard
  navigation; selection survives delivered-frame redraws within the same world.
- **Record guidance:** workspace, goal, lane, worker, bot and repository pages show
  relevant setup gaps, linked actions and reported worker-state bars. Counts follow
  actual relationships. Offline workers stay visibly incomplete; closed workers
  do not satisfy an open-worker requirement. Connection is not proof of success.
- **Less background work:** inventory calls no longer copy every shell's output;
  unchanged terminal/browser/worker controls retain their DOM nodes. Inventory and
  browser URL polling runs every two seconds; active terminal output remains at
  200 ms. Native layout updates only when its relevant geometry/state changes.
- **Landing-page animation:** yields during scrolling and includes slow active
  frames in its resolution governor. This reduces unnecessary drawing, but is not
  a verified fix for the full WebKit page-painting bottleneck described below.

## Browser lag investigation

Tested the actual native WebKit browser, including the local page currently open
at port 8080. A simple long document scrolls at about 16.7 ms per frame. The rich
Super landing page takes roughly 247–421 ms per measured frame in these trials.
Turning on compositing with the legacy renderer did not solve it. Pausing its
WebGL animation while scrolling reduced drawing to one call during the measured
interval, but scrolling remained slow. Removing heavy visual effects and hiding
the embedded prototype for diagnosis improved the measurement, but those visual
removals are **not shipped**. This is a page-painting issue still requiring work;
it is not evidence that all Browser tabs are slow. Keep the launcher’s known
working renderer until a replacement passes visual and interaction checks.

Measurements are local diagnostic trials, not a controlled GPU benchmark. The
existing Super session and other desktop apps remained running. No claim of
smooth scrolling on the rich landing page is made.

## Next MVP work, in order

| Priority | Prototype promise | Actual remaining work / acceptance |
|---|---|---|
| P0 | Bots coordinate as Swarms | Durable parent/child delegation, bounded authority and revocation, shared membership and relationship pages. Keep **Bots** for individuals; use **Swarms** for real coordinated teams. |
| P0 | Watch what agents execute | A session registry with stable bot/lane/workspace/run ownership shared by the executor, Terminal and Browser; show live, ended and disconnected states; link a conversation to the exact session. Current local shells and preview tabs are human-operated. |
| P0 | Bot develops Super | Connect admitted bot work to isolated worktrees, actual coding tools, cancellation and recorded results. A registered bot or assigned worker alone does not start coding. |
| P0 | Review and accept work | Extend today's manual Git review to a specific worktree and source revision, invoke real validation, show its evidence, and accept/reject those exact bytes. Handle concurrent edits and failed promotion. |
| P0 | Recover the same task | Restore task ownership and durable results after restart; clearly explain terminated processes and unavailable sessions. Complete a real-provider Super-on-Super run with interruption and cancellation. |
| P0 | Evidence is navigable | Native paging with provenance/continuity, filtering, source links and comparison; the current recent windows do not cover complete history. |
| P1 | Proof-stage badges and richer charts | Derive stages, trends, budgets and success measures from actual evidence/events. Show unknown when producers do not exist. Do not copy prototype sample numbers. |
| P1 | Line-level bot context | Revision-bound change attribution and line discussions; current context is an explicit file/terminal snapshot or tab link. |
| P1 | Remaining prototype sections | Measured gates/replay, durable rulings/deadlines, routines, capability upgrades and fleet placement all require real producer and lifecycle contracts. |
| P1 | Browser responsiveness | Resolve rich-page WebKit painting cost while preserving page fidelity; repeat wheel/touch and resize checks on the actual desktop renderer. |

## Review limits

Git review requires the native-selected repository and matching selection generation.
Each Git read has a 10-second deadline and a 512 KiB output limit. The list shows
at most 1,000 changes; rendered patches cap lines/line lengths with a visible notice.
External diff/text conversion and optional index locks are disabled. Text reads
retain the editor's file restrictions. Binary/special files and oversize contents
produce a visible refusal. A deleted file whose parent folder is itself gone is
not yet reviewable here. Git status and patches are successive disk snapshots,
not an atomic acceptance basis; refresh when external tools change files.

Existing unrelated modifications were retained. No commit, push or deployment.
Graphonomous tools were unavailable; continuity came from the repo and task notes.

## Validation

- Native workbench flow: **29 held**, including real pointer resizing, live PTY
  input, two browser tabs and rendered Git changes.
- Native application flow: **94 held**, including scoped guidance, persistent
  record tabs, runtime registration and conversation restart recovery.
- Rust: **28 passed, 1 ignored** (unrelated desktop attachment chooser test).
- JavaScript: **23 passed**; WebView ACL: **35 held, 0 failed**.
- Release build and whitespace checks passed. Existing host compiler warnings remain.
- Inspected native screenshots of the actual diff and record views.

The user authorized the restart and the updated build is now running. Confirmed
4 workspaces, 2 goals and 2 lanes preserved; recreated two terminal tabs and the
port-8080 preview server, and reopened its Browser tab. Old process sessions and
terminal scrollback were not preserved. No saved-world reset was performed.
