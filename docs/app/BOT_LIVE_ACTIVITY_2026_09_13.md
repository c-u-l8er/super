# Bot activity and Claude reconnect

Claude conversations now use the CLI stream-json protocol with partial messages. Only public assistant text deltas are exposed; reasoning, raw events and tool arguments are excluded. Structured proposals still come only from a validated final result. Requests have a bounded preview, bounded input stream, five-minute hard timeout and cancellation. The current claude.com OAuth destination is recognized alongside the existing official hosts.

The bot page offers current state, elapsed time, last public output, preview, cancellation, reconnect and a next action. The Activity sidebar mirrors this conversation request across app pages, with Open bot and Cancel reply. It is separate from runtime submission receipts. This does not implement automatic delegation, background execution, multi-bot scheduling or mobile output streaming. Codex retains its received-byte reporting; direct API providers still return complete replies.

Validation: seven Claude adapter tests, sixteen native activity checks (including text before completion, navigation away, proposal review without execution, cancellation and expired authentication), and four existing native bot Work checks passed. Native screenshots were inspected. Build and intent/ACL checks passed. Controlled-provider checks do not certify account access; real Fable verification is recorded separately in the task outputs.

Repeat the native check with tools/native-ui-test.sh node tools/bot-live-smoke.mjs, putting tools/fixtures/claude-live first in PATH and setting SUPER_VISUAL_EVIDENCE_DIR. That fake provider runs only in the isolated test app. Set SUPER_XVFB_BIN_DIR where Xvfb is not installed globally.

Provider protocol reference: https://code.claude.com/docs/en/agent-sdk/streaming-output

The first real Fable audit exceeded the previous two-minute timeout. Claude now has the same five-minute upper bound offered for Codex replies. Cancellation remains available throughout the active provider process.
