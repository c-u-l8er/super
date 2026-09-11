# Readable references, attachments, and workspace deletion

2026-09-07 · local uncommitted development.

The presentation layer resolves workspace, goal, lane, worker and repository IDs against the current authoritative projection. Named records display their name/title/purpose; unnamed records display a type and number. Links retain raw IDs in tooltips and accessible labels and open dedicated record pages, including records outside the selected workspace filter. Select values, provider requests and saved original messages keep IDs unchanged. Unknown references remain literal. Older messages also receive current-record links, explicitly described as a current lookup rather than proof of historical identity. Message formatting uses safe DOM paragraphs, lists, emphasis and code; it never interprets raw HTML.

Every former JSON record disclosure now opens a dedicated page with labeled fields, relationship links and available actions. Workspace settings contain the deletion flow; list cards no longer contain delete buttons. Runtime identity and history records use the same formatted page renderer. Code blocks in chat intentionally retain literal code.

Live chat reference nodes are retained while their label and runtime identity are unchanged, so incoming frames do not destroy a link during a mouse press. Saved proposal text remains read-only and carries its original reference context.

Attach files uses a trusted-main-webview command and the native GTK chooser, opened on the main GTK thread. Paths remain native; the page receives validated filename/content pairs. Up to four UTF-8 text/code files, each at most 32 KB, are supported. Cancelling returns an empty selection. Binary/image/PDF support remains a separate pending feature. The native chooser has a display-dependent test that opens the real dialog, selects a temporary file, and verifies its returned text.

Delete workspace is a human-control-only ordered mutation. The receiving Loci handler checks that the workspace exists and has no lanes under its goals. In one store save it removes the workspace and its goals; the ID sequence is not rewound. Lane-bearing workspaces are refused to preserve workers and authority ancestry. Registered repositories, filesystem contents, and saved chats are unaffected. The app requires a separate confirmation, checks runtime identity again before submitting, and removes nothing from the projected display until a new runtime frame confirms deletion. No cascade through lanes/workers or undo is implemented.
