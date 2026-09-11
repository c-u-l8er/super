# Durable task conversation links

Plan-linked file attachments now add bounded optional taskLinks metadata to the existing device-local conversation record. Links identify task, plan revision and world identity/generation. Lookup is scoped to the assigned bot storage and survives runtime epoch changes. Legacy histories remain compatible; deletion naturally removes links. No separate index can drift from saved conversations.

The task page lists provider and revisions for each saved linked conversation. Clicking a row opens that exact history, preserving the current draft first. Restored proposals remain read-only; nothing is resent and edit authority is not recreated. The generic Open conversation button still opens the current bot conversation. Metadata is local presentation history, not a runtime grant or run record.

Verification: 38 focused JavaScript tests; release build; 26 native assertions using a disposable saved world and local provider fixture, including actual process restart, new runtime epoch, exact history selection, preserved newer unrelated draft, and no automatic provider send. Nine numbered screenshots were captured and reviewed across the workflow. Six intent checks cover 24 human-control mutations; 35 WebView ACL checks passed. Existing compiler/module warnings remain.

Earlier native attempts stopped on transient status text while provider setup completed; the final test inspects stable restored proposal cards and missing edit controls. No real external-provider dogfood cycle was performed.

Remaining: retroactive linking of old chats is intentionally absent; broader task/editor context, attention summaries, combined multi-file changes and in-app integration remain open.
