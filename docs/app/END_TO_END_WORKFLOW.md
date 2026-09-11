# Super: a complete first workflow

The immediate product milestone is a usable cycle: connect a provider, attach project material, ask for help, review the response, explicitly apply a supported proposal, and reopen the conversation later. ComputeDriven placement experiments continue as research; a positive placement result is not a prerequisite for this app milestone.

## Using the workflow

1. Open Bots and connect your chosen provider. Complete sign-in if requested, or use a running local Ollama model.
2. Attach up to four UTF-8 text/code files, each at most 32 KB. Review the workspace-context checkbox before Send.
3. Send a request and review the reply. Supported workspace, goal, lane and worker proposals require Apply; the current runtime confirms changes.
4. Use New conversation to begin another discussion. Choose a previous discussion from Saved conversations to return to it.
5. Close and reopen Super. The last saved conversation for the remembered provider returns with messages, draft, attachments and context preference. Provider availability is checked again.

Messages and text attachment contents are saved in this device's webview storage, separate from provider credentials. This is local storage, not an encrypted document vault or cloud synchronization. Up to 20 conversations and a bounded total history are supported. Delete saved conversation removes its stored copy. Storage errors are visible; New conversation and history switching stop if the current save fails.

Restored proposals are plain historical text without Apply buttons. Ask for a fresh proposal against the current workspace before taking an action. An interrupted reply is never resent automatically; its draft and attachments return for explicit retry. Runtime state is owned by the existing runtime and is not reconstructed from chat history.

## Verification scope

`node --test --test-isolation=none tools/conversation-store-test.mjs` checks persistence, provider separation, field filtering, failed writes, malformed data, explicit deletion at the history limit, and interrupted-reply metadata.

`GDK_BACKEND=x11 APP_SMOKE_SKIP_RESIZE=1 node tools/cockpit-app-smoke.mjs` runs the native desktop workflow using an isolated ephemeral runtime and a local deterministic provider fixture. It exercises attachment delivery, review before Apply, provider failure, saved-history selection, native app close/reopen, no automatic resend/action replay, and continuing with old and new attachments. The fixture validates integration, not a real model's quality or account authentication.

The default smoke suite also resizes the native window; optional APP_SMOKE_SCREENSHOTS captures screenshots. On the current desktop, the driver timed out on screenshot and resize operations; those checks must be reported separately from workflow results.

Real account sign-in, a real provider reply, broader worker execution, and whole-project restoration remain separate acceptance work. This change closes the conversation-continuity gap; it does not declare all of Super complete.
