# Workbench recovery and patch conversations — 2026-09-07

This continuation addresses the manual workbench's restart gap and connects
saved-change review to bot conversations. It does not implement Swarm delegation
or autonomous coding.

## Recovery behavior

- Editor saves recovery copies of file tabs, the selected file and unsaved drafts
  on this device. Saving to the repository remains a separate explicit operation.
- After restart, choose the same repository through the native chooser. The app
  restores its own file tabs and drafts; it does not use a saved path as permission
  to open a repository automatically. Other repositories' drafts stay separate.
- Clean tabs read the current disk file. Dirty drafts retain their original bytes,
  so Save still detects outside edits. A draft already identical to disk becomes
  clean. Missing clean files are reported; missing dirty files retain their draft.
- Browser addresses can be restored with Restore browser tabs. Pages reload when
  opened; previous page DOM state, form input and navigation history are not saved.
- Previous shell tabs are reported as ended. Shell commands, process handles and
  scrollback are not stored or automatically restarted. Live sessions still use
  the native inventory when only the main page reloads.
- Editor → Recovery lists saved repository copies and supports explicit deletion.
  Forgetting a copy does not delete disk files or currently open drafts; subsequent
  changes to open files can create a fresh recovery copy.
- The native chooser now has an explicit Enter/default action and a bounded
  initial size. Desktop verification activates it through the window manager.

Recovery is debounced by 500 ms and flushed on normal page close. An abrupt crash
can lose edits made since the latest successful write. Local storage is limited:
up to five repositories, sixteen files per repository and eight browser addresses;
the aggregate serialized recovery record is capped at 3,000,000 characters.
Browser storage can refuse earlier if shared storage is full. Errors remain visible
and the previous successful copy stays intact. Corrupt data is never silently
replaced; Clear recovery data is an explicit destructive action.

Recovery copies contain source text and browser addresses in this device's app
storage. They are not encrypted backups or synchronized project records.

## Discussing a patch

Open Editor → Changes, select a file and choose Discuss changes with bot. The
selected bot receives an attachment containing the inspected working-tree,
staged and/or untracked text, with a capture time and disk-snapshot label.
Long patches are clearly marked as excerpts. It does not send a provider request
until the user writes a message and selects Send.

The conversation link returns to the current Changes view for that file. The
attachment remains the captured snapshot; reopening the view can show newer disk
changes. This is not validation evidence or acceptance of changed bytes. Surface
links carry a per-app-session identity as well as their existing repository/tab
identity so restarted sessions cannot accidentally reuse a numeric identifier.

## Remaining dogfood milestone

A durable agent-owned session registry, parent/child delegation, admitted coding
in isolated worktrees, cancellation, revision-bound validation/acceptance and
agent-run recovery remain the next P0 work. This pass improves continuity and
human-directed code review without inventing those runtime capabilities.

## Verification

- Native workbench: **38 held**, including full process restart, recovered draft
  conflict refusal, browser address recovery, real keyboard input, actual window
  edge dragging, and patch-to-bot navigation.
- Native app regression: **94 held**, including conversation restart recovery.
- JavaScript: **33 passed**; WebView ACL: **35 held / 0 failed**.
- Release build and whitespace checks passed. Existing host compiler warnings
  remain; no backend execution or authority contract was changed.
- Native screenshots inspected; recovery dialog action width adjusted afterward.

Changes are local and uncommitted. Graphonomous tools were unavailable; the saved
audit and source supplied continuity. Rich landing-page scrolling remains an open
issue from the prior pass and is not claimed fixed here.

The updated app is running in the existing saved world. Confirmed 4 workspaces,
2 goals and 2 lanes retained; restored the two local terminal tabs and port-8080
preview. The new Recovery control is present in the actual app.
