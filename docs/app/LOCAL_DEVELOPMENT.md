# Tabbed development workbench

Editor, Terminal and Browser sit together in Nav → Work. Each uses the available
panel without an outer card. These are device-local work surfaces; the runtime
workspace selector does not change the explicitly chosen repository.

## Editor

Open a Git root with the native folder chooser. Open up to 16 file tabs, with
separate drafts, selection and undo history. CodeMirror 6 supplies line numbers,
search, indentation, bracket matching and the One Dark syntax theme. JavaScript,
TypeScript, Python, Rust, HTML, CSS, JSON and Markdown have language modes; other
files use plain text. Ctrl/Cmd S saves. Reload and closing a dirty tab require
explicit draft-discard confirmation. File tabs survive navigation. Device-local recovery copies restore tabs and drafts
after restart when the same repository is selected again.

Files remain bounded to 1 MiB of UTF-8 text. Reads and atomic saves use the native
selected-directory handles. Absolute paths, traversal, .git, symlink components,
binary and special files are refused. Saves compare original bytes with disk;
conflicts retain the draft. New files never overwrite an existing destination.
Listings contain at most 1,000 entries. New file parents must already exist.

The editor's pinned build dependencies, lockfile and build entry are in
`tools/editor`; the bundled frontend and licenses are in `cockpit/ui/vendor`.
The CSP permits locally generated styles so CodeMirror and xterm can paint their
layout and theme. Script and IPC restrictions remain in place.

## Terminal

The + button creates one of up to eight interactive Bash PTYs in the chosen
repository. Each has its own tab, xterm screen and output cursor. Input, Ctrl C,
terminal escape sequences and measured screen resize reach the actual PTY.
Commands continue when switching tabs or pages. Native session inventory restores
available sessions after a main-page reload. Closed sessions have monotonic IDs.

The native buffer retains the latest 128 KiB per shell; skipped older output is
labelled. xterm has 3,000 lines of scrollback. Large pastes are bounded and serialized;
partial native writes continue from their byte offset, with a bounded stall timeout.
Failures are reported without replaying input. Repository switching is refused while
shells run. Closing a shell terminates its foreground command and shell process group;
normal app shutdown cleans up all managed shells. Use foreground development servers.
Deliberately detached jobs are outside this lifecycle contract.

These shells run under the machine user's account. The selected repository is a
working directory, not a shell sandbox. Bot conversation tools do not gain shell input.

The runtime terminal picker lists open workers whose held projection reports a
PRESENT terminal. Labels resolve lane actors to registered bot names where possible.
Watch uses the existing admitted terminal binding, expected worker generation, and
read-only byte transport, displayed in the panel. The existing transport watches
one runtime worker at a time. Runtime loss removes availability. This is separate
from local interactive shells; no external CLI process is inferred to be a bot.

## Browser

Up to eight local app tabs use distinct native WebViews. Switching tabs preserves
page state. The address bar and tabs remain above the page; page content fills the
remaining panel. Native browser views hide on navigation and app overlays. Window
edge/corner handles support native resizing; on Linux the main widget handles
the original pointer press, motion and release because the compositor ignored
the embedded view’s begin-resize request; the Linux overlay releases the main
WebView's old minimum size so browser-open windows can shrink again.

Only HTTP/HTTPS loopback top-level navigation is accepted: localhost, 127.0.0.1,
and IPv6 loopback. Popups are refused. Normal page subresource networking still
applies. None of the bounded browser labels has Super's Tauri capability grants.
A server error page remains visible as page content; loading is not validation.

## Bot links and the execution gap

Choose a bot and Discuss with bot to attach the selected file draft (up to 24,000
UTF-8 bytes), terminal screen excerpt (up to 16,000 UTF-8 bytes), worker identity,
or browser URL. Sending requires a normal user message and Send. The snapshot is
an ordinary attachment saved with conversation history; a session-local link returns
to the same surface. Closed tabs and changed repositories refuse stale links.
Browser contents are not automatically extracted or sent. Worker links carry identity,
not automatically copied runtime terminal bytes.

External coding-agent terminals and browser tabs do not yet register with this
inventory. The remaining execution bridge needs authenticated session ownership,
workspace/lane/bot associations, cancellation and recovery, plus admitted tool
operations and durable results. Swarm delegation must use that same registry.
These UI changes do not claim autonomous execution or grant new bot permissions.

## Verification

`tools/development-smoke.mjs` opens a disposable world and Git repository through
the real desktop chooser. It exercises CodeMirror styles and drafts, disk saves and
conflicts, bot attachments/backlinks, two PTYs, a real HTTP server, independent
native browser tabs, state retention, native window resizing and an actual XTest
corner drag, browser IPC refusal and shell cleanup. Set DEVELOPMENT_TEST_ROOT to
a disposable directory visible to the desktop. The Linux check uses X11/XTest,
GTK, WebKitWebDriver, tauri-driver and a Python HTTP server; no provider is called.

The broader `tools/cockpit-app-smoke.mjs`, JavaScript state tests, native Rust tests
and `tools/check-webview-acl.mjs` cover existing navigation, conversation behavior,
PTY bounds and the unchanged worker byte-plane permissions.


## Saved changes (2026-09-07 follow-up)

Editor → Changes reads Git status and patches for the native-selected repository.
Working tree, staged and untracked text are separate. Refresh reads disk again;
unsaved drafts are excluded. Open in Editor returns to the named file. This is
manual read-only review, not worktree acceptance or runtime validation evidence.
Each Git read is bounded to 10 seconds / 512 KiB, disables external diff/textconv
and optional locks, and does not hold the interactive shell mutex while Git runs.
See PROTOTYPE_PASS_2_2026_09_07.md for limits and verification.


## Recovery and patch conversations

Editor → Recovery manages local copies of file tabs and unsaved drafts for up to
five repositories. The same native-selected repository restores its own copies;
original bytes are preserved so external edits still refuse on Save. Browser
addresses have an explicit restore action. Previous shells are labelled ended;
commands and scrollback are not restored automatically. Storage errors preserve
the previous successful copy and remain visible.

Changes → Discuss changes with bot attaches the inspected patch snapshot, including
working-tree/staged/untracked section labels and a capture time. Large excerpts
are labelled. Send remains explicit, and the link returns to current changes for
that file. It does not accept or validate a change. See
WORKBENCH_RECOVERY_2026_09_07.md for the full contract and limits.


### Linked sessions and proposed code

Terminal and Browser have **Link to bot** for an existing local session. Bot → Work → Linked workbench sessions provides Open/Unlink. Native process state supplies the inventory and lifetime identities; page reload preserves links, process restart clears them, and browser slot reuse cannot inherit an old association. Linking sends no contents to providers.

For a full Editor file of at most 24,000 UTF-8 bytes, **Discuss with bot** can supply the snapshot for a typed single-file proposal. **Review in Editor** compares shared/proposed code, **Use as editor draft** stages unsaved text, and **Save** checks disk conflicts. Proposed replacement text is bounded to 32,000 UTF-8 bytes. Files shared as excerpts are not eligible for this direct-review path. Changed drafts and repository/page replacements require a fresh shared snapshot. Restored conversation proposals remain read-only.
