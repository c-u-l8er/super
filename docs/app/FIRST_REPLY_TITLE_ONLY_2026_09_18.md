# The first reply that was only its title — 2026-09-18

**Status: the page now refuses such a reply and restores the draft — driven on
a real screen against a local provider fixture, 16 held · 0 failed; the CAUSE
is NOT reproduced, because the machine's Claude CLI sign-in was expired when
the reproduction was attempted.** Finding 1 of
`REVIEW_EVIDENCE_RULINGS_2026_09_18.md` *After the install*.

## What was measured

Driving the cancelled-fold round (`outputs/cancelled-fold/driver-attempt2-title-only.log`,
`attempt2-reply-title-only.png`), opus[1m] at xhigh, a **new** conversation
(`#bot-new`), the request that later produced the proposal:

    Thinking · 150 tokens → Preparing reply → Receiving 52 bytes → 78 bytes → Reply received   (25 s)

The structured `text` was exactly 78 bytes:

    <conversation-title>Persist the Cancelled fold state on record pages (dt_0069)

— the requested header, never closed, no note, no `propose_file_edit`. The
page landed it as a normal reply ("Reply received.", the sidebar row *Ready*),
so the driver found no card and the round produced nothing. The same request
resent in that conversation — now titled by nothing, so `titleSource` was
`fallback` and the title was **asked for again** — answered in 92 s with the
proposal. (The title instruction rides in `bot_instructions`, which
`bots.rs` folds into the stdin prompt under "User-configured conversational
role"; the `--system-prompt` is fixed. The CLI implements `--json-schema` as
one `StructuredOutput` tool the model must call once at the end of its reply,
with a nudge and a retry cap when it does not; `decode_reply` keeps only the
`structured_output` object.)

Why the model stopped inside the header is not known. n = 1.

## What changed (page only)

* `conversation-title.js` — `conversationReply` also accepts a header the
  model opened and never closed **when nothing follows it**, yielding the
  title and an empty text; a header that prose follows without closing is
  left alone (that reply has an answer in it). New `emptyFirstReply(titled,
  actions)`: no prose after the header and no proposal.
* `bots.js` — after decoding, a first reply that is empty by that rule
  **records the title** (`titleSource: ai`, or `attempted` when there was
  none to keep — either way the resend does not ask again) and then **fails
  the turn like any other failed reply**: the draft and attachments are
  restored, the transcript says *"The reply stopped at its title header and
  carried no answer and no proposal. Your message is restored — send it
  again in this conversation."*, and nothing is landed as an answer. Both
  landing paths (the conversation on screen, and a reply landing while
  another is open) go through the same throw.

This turns a lost round into one resend, which is the workaround the driver
found by hand. It does not prevent the model from doing it again.

## Driven on a real screen — `tools/first-reply-title-only-smoke.mjs`

The decode and the guard run on **every** reply, whatever the provider
(`bots.js` applies them to the result of `bot_chat`), so the measured reply
shape can be produced by a local HTTP provider fixture and the Claude CLI is
not needed to prove what the page does with it. Real cockpit, throwaway world,
an `ollama` endpoint pointed at a fixture that records what each request asked
for: **16 held · 0 failed** (screenshots in `outputs/title-only/shots/`).

1. The first send **asks** for a title (the instruction reaches the provider
   inside the system message). The fixture answers with the measured shape —
   `<conversation-title>…` unterminated, nothing after it, no tool call.
2. Nothing lands as an assistant reply: the transcript holds the user message
   and an *App result* carrying the refusal, the status line carries the same
   sentence, **the draft is restored in the composer**, and the conversation
   is titled from the header (`01-title-only-refused.png`; the Activity rail
   reads *Reply stopped · No live assistant text received* and the sidebar row
   *Needs attention*).
3. The resend **does not ask for a title again** — proven from the fixture's
   own record of the second request — lands a normal reply, empties the
   composer, and leaves the kept title alone (`02-resend-landed.png`).
4. The same unterminated header **carrying a proposal** is not refused: it
   lands with its proposal card on screen, title taken from the header too
   (`03-header-with-proposal-lands.png`). The guard is about emptiness, not
   about the header.
5. A properly closed header still yields the title and the prose.

One observation, not changed: the status line and the result entry read
*"Error: The reply stopped…"*. Every in-page refusal in `bots.js` renders
through `String(error)` and so carries that prefix (the attachment limits, the
model catalog, the missing API key). Dropping it is a one-line change to how
that file renders **every** failure, so it is left for the owner rather than
made here for one message.

## Reproduction, prepared and blocked

`outputs/title-only/run.mjs` (this session's outputs folder) replays the turn
outside the cockpit with the same flags, schema and prompt assembly, against
the same request and pre-fix file, with bt_0034's real role and instructions,
and keeps the **full stream-json** the cockpit never keeps — so a rerun can
say whether the header came as prose or as the tool's `text`, whether the CLI
nudged, and how many turns there were. All three runs on 2026-09-18 ended in
1–2 s with `Failed to authenticate: OAuth session expired and could not be
refreshed`; a trivial `claude -p` on haiku fails the same way, and
`claude auth status --json` still reports `loggedIn: true`, which is all the
cockpit's status probe reads — so Super will show *connected* and fail on the
first send until someone signs the CLI in again (`claude login`, or Connect
provider in Super; a browser sign-in, which no script may perform).

## Not done

* The cause. Candidates the stream would settle: the header emitted as a
  prose block and the tool call carrying only what the model had already
  written; a schema-side stop after the header; a model fallback. Rerun the
  three runs once signed in and record the summaries beside the README.
* Moving the title out of `text` into its own optional schema field would
  make the failure shape impossible rather than merely caught; it touches the
  Rust schema for both providers and is not worth doing until the cause is
  seen.

## After the install — 2026-09-18 23:39Z

Installed with the change above as binary `1be00b791212054f…` at `48aa9d1`
(see `SAVED_SINGLE_FILE_REVIEW_2026_09_18.md`, *After the install*). The
guard itself has not been seen on a real screen: producing a title-only reply
needs the provider, and the CLI sign-in is expired. Its unit tests are the
evidence (`tools/conversation-title-test.mjs`, 5/5 in the 288/288 suite).
