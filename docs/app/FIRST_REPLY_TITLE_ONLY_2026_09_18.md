# The first reply that was only its title — 2026-09-18

**Status: the page refuses such a reply and restores the draft, driven on a
real screen against a local provider fixture (16 held · 0 failed); and the
CAUSE is now reproduced and measured — the model's first structured call can
carry only the opening title header. A second defect the stream exposed, a
streaming accumulator never reset between tool calls, is fixed here too.**
Finding 1 of
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

## The cause, measured — 2026-09-18 evening, once the sign-in was restored

`outputs/title-only/run.mjs` replays the turn outside the cockpit with the same
flags, schema and prompt assembly, against the same request and pre-fix file,
with bt_0034's real role and instructions, and keeps the **full stream-json**
the cockpit never keeps. Three runs, opus[1m] at xhigh:

| run | title asked | turns | prose block | what happened |
|---|---|---|---|---|
| T1 | yes | 3 | none | **the failure, reproduced on the first try** |
| T2 | yes | 2 | none | one complete call |
| C1 | no  | 2 | 2 942 bytes | one complete call |

**T1 is the cause.** The model's FIRST `StructuredOutput` call was 92 bytes and
carried one key:

    {"text": "<conversation-title>Persist Cancelled plans fold state on record pages (dt_0069)"}

The title header, unterminated, and nothing else — the exact 79-character shape
Super was left with on 2026-09-18. The CLI refused it against the schema,
*"Output does not match required schema: root: must have required property
`actions`"*, fed that back as a tool result, and the model's second call was
the complete answer: the closed title, 2 832 bytes of prose, and a
`propose_file_edit` of 13 693 bytes. 85 seconds, and the person would have got
a correct reply.

So the model does sometimes end a call having written only the opening header.
**What decided the 09-18 outcome was `actions`.** Super's `bots.rs` requires
`actions` to be an array and refuses the reply outright when it is not, so the
call that reached the page must have carried `actions: []` — schema-valid,
nothing for the CLI to refuse, nothing upstream to retry. The same premature
call is caught when it omits `actions` and lands as an empty reply when it
includes an empty one. **No schema can express "the text must be more than its
own header", which is why the page-side guard is the fix and not a workaround.**

Two observations that are *not* established, at n = 2 and n = 1:

* One of the two title-requesting runs made the premature call. That is a
  reproduction, not a rate.
* Only the run that was **not** asked for a title wrote a prose block at all
  (2 942 bytes) before its tool call; both title-requesting runs emitted no
  `text_delta` and wrote straight into the schema. Suggestive that the
  instruction changes the shape of the turn; one control is not a finding.

Summaries and the complete streams are in `outputs/title-only/runs/`.

## A second defect the stream exposed, and its fix

`ReplyState.partial` in `claude_connection.rs` is one raw-JSON accumulator for
the whole turn, and **nothing reset it between tool calls**. T1 streamed two
`StructuredOutput` calls, so the buffer held `{…}{…}` and `structured_prefix`
kept parsing the FIRST object — the abandoned header. Replaying T1's own
deltas through the accumulator: what the page would have shown for the whole
turn is the 79-character header, while the reply being written was 2 832 bytes
plus a 13.7 KB proposal. The person watches *"Receiving Claude reply… 79
bytes"* sit still for about a minute, then the right answer appears at the end.

Fixed in `observe_reply`: a `content_block_start` whose block is a `tool_use`
clears the accumulator, because a new tool call is a new structured reply.
`a_refused_structured_reply_does_not_freeze_the_one_that_replaces_it` pins it
(and that the argument side still never crosses); with the clear disabled the
test fails with the stale header, which is how it was checked.

## Not done

* **Whether the title should move out of `text` into its own optional schema
  field.** The measurement sharpens the case rather than settling it: the model
  writes the header as a *prefix of the prose*, so a call that ends early
  leaves something that reads like a reply. With its own field an early call
  would leave `text: ""`, which is obviously nothing. It does not remove the
  premature call, only its disguise, and it touches the Rust schema for both
  local providers. Still the owner's call.
* A rate for the premature call. Two title-requesting runs, one of them
  premature, is not one.
* The failing shape has not been produced **through Super's own UI** against
  the real provider — only outside it. The page-side guard is covered by
  `tools/first-reply-title-only-smoke.mjs` instead, which drives the identical
  reply shape through a fixture provider.

## After the install — 2026-09-19 01:05Z

The streaming fix is installed: `2db9d36` built in `~/build/super-review-content`
(33.9 s) and running as `super-desktop`, binary `e4882fd044666223…` proven from
`/proc/<MainPID>/exe`, after `~/build/backup-world.sh`
(`default-20260919T010452Z`). Gateway 4318 → 200, Expo 8081 → 200, connector
4320 → 403 without the identity header. No error line in the unit's journal.
Driven against that binary from the installed checkout: `first-reply-title-only`
16/16, `saved-file-review-resume` 13/13, `plan-steps` 9/9. Suites on the source:
`cargo test --bin super-cockpit` 105 passed · 1 ignored, `node --test
tools/*-test.mjs` 288/288, `bash tools/gates.sh` 7 held · 2 pre-existing failed.

### Earlier — 2026-09-18 23:39Z (the guard itself)

Installed with the change above as binary `1be00b791212054f…` at `48aa9d1`
(see `SAVED_SINGLE_FILE_REVIEW_2026_09_18.md`, *After the install*). The smoke
above was then run **from the installed checkout, against that installed
binary**: 16 held · 0 failed, the same as from the source clone — so the
behaviour proven on screen is the behaviour that is installed. The smoke adds
no source: the binary is byte-identical before and after
(`1be00b791212054f…` from `/proc/<MainPID>/exe`, unchanged). Unit evidence
beside it: `tools/conversation-title-test.mjs`, 5/5 in the 288/288 suite.

What is still **not** shown on any screen is a title-only reply from the real
provider — that is the cause, and it waits on the sign-in.
