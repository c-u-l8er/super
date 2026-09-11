# Desktop shell

2026-09-07 · local uncommitted development.

The custom desktop header provides sidebar toggle, page/record back and forward history, File/Edit/View/Help menus, a draggable title area and minimize/maximize/close controls. Window operations use a four-action command restricted to the trusted main webview and its own window. No broad core permission was added.

Navigation preserves record identity and workspace context when traveling through history. A record from an unavailable world shows an unavailable page. The File menu opens workspace creation, new conversation, attachment selection and connection management. Edit offers Undo, Redo and Select all through the focused editor. Help contains shortcuts and About.

Both sidebar borders support pointer dragging, keyboard arrows and double-click reset. Widths and visibility are saved locally. At narrow widths activity moves below the page and its vertical resize handle is hidden. Ctrl B toggles navigation, Ctrl K finds pages, and Alt Left/Right travels through history.

Validation: native app smoke 61 checks passed, including actual pointer dragging across frames, legacy message formatting, record navigation, deletion confirmation and narrow layout. The webview ACL gate passed 32 checks with 20 registered commands.

Workspace creation now has its own New workspace page, reachable from the workspace list, File menu, and page finder. Cancel returns to the list without submitting and keeps the current draft. Other goal/lane/worker setup forms live on Create & manage work; record-page action links open this setup page with the relevant selection filled in. The workspace listing contains no creation forms.

New workspace page validation: native smoke 64 held, including list/menu entry, cancel/draft preservation, confirmed creation and remaining setup flows.

Creation forms for workspaces, goals, lanes and workers now redirect to the new record's detail page. The successful receipt supplies only the destination ID; a later authoritative frame must contain that exact record before navigation occurs. Refusals do not redirect. A page change or world change cancels pending navigation. Bot proposal application keeps the conversation open. Six focused navigation tests cover these confirmation and cancellation rules.

Local repositories now has a dedicated page in the Work sidebar and page finder. The setup page links to it. Repository selection, shared scope, and detail-page navigation are unchanged; the workspace list no longer embeds repository management.

The workspace directory sidebar label is Workspaces & lanes, matching its page title.

## Nav and Runtime responsibilities

Nav now has separate Workspaces, Goals, and Lanes directories. Each shows its own records, relevant relationships/counts, and focused setup entry points. Workspaces keeps the internal positions route for compatibility but no longer embeds goals or lanes. Workspace filtering applies to all three directories. Shared record details remain the destination for relationships, management actions, and confirmed creation redirects.

Runtime > Assignments & state replaces the old duplicate Workspaces / Goals / Lanes route. It is whole-runtime regardless of workspace filter, and displays workspace lineage, goal assignments, lane actor/repository bindings, active worktree capability counts, worker assignment/occupancy/terminal/generation, and carrier attempt state. Missing values say Not reported; no execution/progress claims are inferred. The page contains no creation forms.

Sidebar modes remember their last directory and follow unique page destinations during back/forward and page-finder navigation. Record detail pages retain their originating mode.
