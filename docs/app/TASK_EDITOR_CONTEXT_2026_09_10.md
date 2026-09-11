# Task Editor context — 10 September 2026

Task pages now display the selected Editor repository, open tabs and unsaved draft state through a session-only presentation snapshot. No file contents are copied into the snapshot. Open-tab navigation verifies task revision/world, session, repository generation, tab existence and idle/review state. Repository matching is still performed separately by the existing plan-linked sharing path; open tabs are not proof of reviewed work.

Plan changes/closure invalidate context. Explicit preparation reconnects tabs. Clearing context and reload remove live links, with existing draft recovery unchanged. No new native command, file write or runtime authority was added.

Verification: 51 JavaScript tests; 20 native disposable-world assertions; release build; 6 intent checks covering 24 human-control mutations; 35 WebView ACL checks. Four screenshots visually inspected, including narrow layout. No provider message was sent. Compiler/module warnings remain. This pass tested page reload, not process restart; prior conversation restart evidence is separate.

Remaining: consolidated attention summaries, combined multi-file changes, required checks, and accepted-result integration/rebuild.
