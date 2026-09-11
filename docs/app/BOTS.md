# Bots — first conversation and orchestration connection

The primary flow is **Bots → select or create a bot → Connect provider**. ChatGPT / Codex is selected by
default: the button opens the official browser sign-in flow, then Super loads the
account's model catalog and selects its default model. A model picker supports
switching without typing model identifiers. Codex manages credential storage and
refresh with `cli_auth_credentials_store="keyring"`, under Super's separate Codex
home. Super never copies another Codex installation's auth file or browser cookies.
Disconnect applies only to Super's connection. On restart Super checks its own
saved sign-in and reconnects without another key entry.

Selecting **Claude · local session** connects through the installed Claude CLI.
It checks the local subscription sign-in, reuses it when available, and starts
`claude auth login --claudeai` when needed. Claude retains ownership of its
credentials. Super stores only an enabled marker and the chosen model. Disconnect
removes Super's connection marker and cancels only its pending login process;
it never logs the user out of their separate Claude Code sessions. The model
picker reads the installed CLI catalog, including resolved model names and supported
thinking levels; inference availability is checked when sending. This is a local personal integration, not a claim that Anthropic
has approved a distributed Super subscription-login product.

Claude replies use the documented print-mode JSON interface with structured
output, an empty tool list, restricted mode, no hooks, no user/project settings,
no MCP servers, and no saved conversation. Prompts go through stdin, never command
arguments. Time and output size are bounded. The same native proposal validator
and human Apply path are used. A stale saved login is not proof of a valid token:
the live check here reported an expired OAuth session; Super marks that connection
for renewed sign-in and displays an actionable message.

Selecting Ollama connects to its local loopback endpoint and discovers installed
models. **Manage connections** holds optional endpoint overrides and manual API
keys for direct OpenAI and Anthropic connections. Those providers need a key once;
Save connection defaults to secure keychain storage. Later Connect clicks reuse
the saved key and remembered model choice. Direct API catalogs are fetched from their own provider endpoints after configuration;
manual model overrides remain available.

The Codex CLI and Linux `secret-tool` must be installed and the system keychain
must be available. There is no plaintext credential fallback. ChatGPT availability
is determined by the signed-in account; direct API calls use the provider's API
billing. Automated tests do not claim live model availability; the local Claude attempt
reached an expired-authentication error and needs the user to renew sign-in.

## Conversation and actions

A message goes through a native provider adapter. The returned text is displayed
as plain text, and supported tool calls become reviewable proposals. Applying a
proposal uses the existing human-control submission path. The model has no runtime
channel and cannot itself submit a mutation. The four initial proposals are:

- Create workspace (`open_workspace`)
- Create goal (`open_goal`)
- Create lane (`open_lane`)
- Assign worker (`open_worker`)

Each proposal displays its exact arguments and has Apply and Dismiss controls.
An applied or dismissed proposal cannot be applied again from that card. App
submission results appear in the conversation and are included with the next
message. Runtime frames remain the source of truth for actual workspaces and
positions. Accepted submission is not described as execution of a worker.

Proposal controls are disabled while the runtime projection is unavailable,
while another operation is pending, or after switching workspace/world identity.
The bot can still discuss work without a live projection, with context marked
unavailable. It cannot restore withdrawn runtime data.

## Context and session boundaries

The context checkbox controls inclusion of workspace names, goal titles, lane and
worker summaries, repository references, and frame identity. It excludes source
files, terminal output, grant records and API keys. Context is filtered to the
selected workspace; repository references cover the runtime's shared registry.
The screen names the destination provider before sending.

Conversations live outside the frame-owned region, so frame refreshes do not erase
messages or drafts. Conversations, drafts and text attachments persist locally, alongside provider/model choices and without credentials. Saved conversations can be reopened or deleted. Reopening never resends a message; proposals restored from disk are read-only history. An interrupted reply restores its draft and attachments for an explicit retry. Provider switching restores each provider's separate conversation and draft; model changes preserve that conversation.
See [Provider choices](PROVIDER_CHOICES.md) for refresh, thinking, and attachment limits. Keys stay in native process
memory after configuration and are cleared from the input. Opting into “Remember
in system keychain” stores a key in Linux Secret Service through `secret-tool`,
scoped to Super and the provider. Leaving the key blank loads that provider's saved
key. “Forget saved key” deletes it and clears its active native configuration.
Keys are never returned to the page or written to app configuration files. A
locked or unavailable keychain produces an error; there is no plaintext fallback.
ChatGPT / Codex uses its own managed browser sign-in, separate from direct API keys.

Since the 2026-09-07 MVP pass, Bots has a persistent device-local roster, groups,
creation/editing pages and dedicated named conversation pages. Each profile keeps
its own provider preferences and conversation namespace; the original Workspace
assistant preserves its existing history. Role instructions reach the native provider
adapters without changing available tools. Profiles can now be explicitly registered to a workspace as durable runtime bot
identities. Registration preserves local history, mints no permissions and starts
no Carrier. See [Runtime bot identities](RUNTIME_BOT_IDENTITIES.md). There is no autonomous orchestration loop or grant approval tool,
external messaging tool, or background orchestration. Those require explicit
runtime contracts beyond this connection. The next user message can incorporate
an app result and ask for the next step.

## Provider contracts

The OpenAI adapter uses Chat Completions with function tools and `store:false`.
[OpenAI Chat API reference](https://developers.openai.com/api/reference/resources/chat)

The Anthropic adapter uses Messages, with a top-level system prompt, input-schema
tools, and text/tool-use response blocks.
[Anthropic Messages reference](https://platform.claude.com/docs/en/api/messages/create)

The Ollama adapter uses `/api/chat` with function tools and non-streaming replies.
[Ollama Chat reference](https://docs.ollama.com/api/chat)

All adapters have bounded input/output, a two-minute request timeout, no automatic
retry, and no redirect following. Provider errors remain separate from runtime
refusals. Malformed, incomplete or unsupported proposals are not made applyable.

## Verification scope

Unit tests cover the three provider request/response shapes, settings separation,
minimal secret-free configuration receipts and valid proposal arguments.
The desktop product smoke uses an explicit local deterministic provider to drive
the actual HTTP adapter, conversation UI, proposal review, existing intent queue,
and runtime frame confirmation. It also checks visible provider errors and draft
retention. This is an integration fixture, not a real model inference measurement.
Live cloud calls require user-supplied credentials and have not been performed.


## Codex connection implementation and verification

The native adapter uses official `account/login/start`, `account/read`,
`account/logout`, `model/list`, `thread/start`, and `turn/start` messages over
stdio. It only opens HTTPS login URLs on auth.openai.com or chatgpt.com.
Credentials never cross the native/webview boundary. Chat replies run in an
app-owned empty workspace with ephemeral threads, read-only sandboxing, never
approval, and shell, multi-agent, apps, web search and image viewing disabled.
Server requests for additional operations receive an error. Structured replies
pass the same native proposal validator as the direct providers; proposals reach
the runtime only through an explicit Apply click.

A real installed-Codex handshake and isolated account read passed without using
existing credentials. A protocol fixture checks completion events arriving before
the turn-start response. The product smoke checks the primary connection button,
collapsed manual controls, automatic local model discovery, and review/apply flow.
Browser OAuth completion and live ChatGPT inference still require user sign-in.

[Official Codex App Server documentation](https://learn.chatgpt.com/docs/app-server)
[Credential storage configuration](https://learn.chatgpt.com/docs/config-file/config-reference)

[Claude CLI programmatic interface](https://code.claude.com/docs/en/headless)

See [the MVP inventory](MVP_PASS_2026_09_07.md) for the actor-bound identity, observation, delegation, execution and review work still needed for full Super-on-Super development.
