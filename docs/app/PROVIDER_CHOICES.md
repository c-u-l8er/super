# Provider choices, catalogs, thinking, and attachments

2026-09-06, local app development changes (uncommitted).

Provider switches restore the active configuration, transcript, proposal cards, draft, staged files, and selected model within the app session. Model, endpoint, last provider, and per-model thinking choices persist in localStorage; credentials remain in their existing provider-managed store or system keychain. Conversations, drafts and text attachments are saved on this device and can be reopened from Saved conversations after an app restart. Saved proposal history has no Apply buttons; request a fresh proposal before applying a step. Local history is limited to 20 conversations and reports storage failures without discarding older saves.

Catalogs refresh on connection and when returning to an active provider; Refresh models requests another catalog without resetting the conversation or replacing the chosen model. Codex uses paginated app-server model/list. Claude uses the installed CLI's streaming initialize control response, including resolved model names and supportedEffortLevels; it does not make an inference request to discover models. Ollama lists installed models. API connections list models using their native HTTPS catalog endpoints. API catalogs may include models unsuitable for this app's chat adapter. The saved model remains selectable if absent from the current catalog; a provider may reject it when sent. A failed refresh preserves previous choices and displays an error.

The thinking menu beneath the composer uses Codex and Claude's advertised model options. A selected level is forwarded to Codex turn/start or Claude --effort. Other adapters currently expose Provider default only. No universal Ultra level is assumed. Availability depends on account access and the installed harness version; Refresh models cannot upgrade the harness.

Attachments currently support UTF-8 text/code files: up to four per message, at most 32 KB per file and 256 KB across conversation attachments. A native file chooser supplies the contents; arbitrary page-provided filesystem paths are never read. Names and contents are encoded as data in provider conversation messages only when Send is clicked. Staging and removing files make no provider request. Failed sends restore the draft and attached files. Binary files, screenshots/images, and PDFs are not implemented yet.

Model replies remain proposals: existing explicit Apply controls are required to mutate the runtime.
