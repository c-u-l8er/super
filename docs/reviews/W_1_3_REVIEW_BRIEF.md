# W.1.3 — Bots is the third root, and an utterance is a frame

**Artifact: `and-super-rev-w13.zip`. Every required gate green.**

Yes to the third root, and yes to the ordering and the framing. *Bot explains, Nav
organizes, Runtime proves* is the right sentence and I have put it on the screen. But the
design as sketched cannot be built on this runtime without five changes, and one of them is
not cosmetic: **the conversational surface is where every mechanism W.1.2 built stops
applying.**

I built it in the prototype rather than answering in prose, because the prototype is the
frozen executable spec and a design that cannot be falsified is a design nobody can check.

```
                    GPT's sketch                    what is now shipped

roster              Ada · 7 grants · 2 approval-bound    a projection with no channel
                    subscriptions: gates lanes evidence  → bot-projection@1, filtered
                                                           by observation grant

delegation          may_delegate: [research, code]       naming kinds of work
                    authority: {deploy: denied}          → delegate ⊆ holds, narrowing only

utterance           "Kestrel finished the Rust           a frame with no cursor
                     transport change."                  → cursor sampled AFTER content,
                                                           SUPERSEDED when the world moves
```

---

## 0 · Measured

| | W.1.2 | W.1.3 |
|---|---|---|
| conformance vectors | 42 | **42** — unchanged, and that is the point |
| BEAM tests | 214 | **214** — the runtime was not touched |
| browser assertions | 64 | **89** |
| browser falsifiers | *none existed* | **8 falsified · 0 not** |
| BEAM sabotage falsifiers | 70 · 0 not | 70 · 0 not |
| host acceptance checks | 78 held · 0 failed | 78 held · 0 failed |
| host sabotage falsifiers | 12 · 0 not | 12 · 0 not |

**The browser battery had 64 assertions and no proof that any of them could fail.** That is
the gap `sabotage-host.sh` closed for the host and nothing had closed here, so
`tools/sabotage-bots.sh` is new and now runs inside `release.sh`.

---

## 1 · There is no channel a Bot can stand on

This is the finding that has to be settled before any of the rest is buildable, and it is
mechanical rather than philosophical.

`Ampd.Projection` has exactly two identified projections and the filter is the actor **the
runtime assigned**:

```elixir
# projection.ex — agent(actor)
mine = fn list -> Enum.filter(list, &(&1["actor"] == actor)) end
```

Everything Ada could see would be filtered `actor == "ada"`. Not a lane, not another
agent's finding, not a gate — those are not in `agent-projection@2` at all.

The other one is `operator-projection@2`, and `command_spec.ex` declares it
`channel: :human_control`. `Ampd.Peer.claim_control_channel/0` succeeds **once**. So putting
Ada there does not give her a view of the world; it makes her *the person*, which is the one
thing your own law forbids.

Your roster card — `authority: 7 grants · 2 approval-bound`, `subscriptions: gates · lanes ·
evidence · runtime` — is describing a projection that does not exist and cannot be either of
the two that do.

**What I built, and what I want you to rule on.** The existing filter is identity
(`actor == me`). The bot filter is **observation** (`subject ∈ observed(bot)`), which keeps
`Ampd.Projection`'s stated law intact — *an agent-projection is not a projection an agent
asks for; it is the projection its channel is capable of receiving* — and makes the roster
itself governed rather than ambient. That implies a fourth channel class beside
`:agent` / `:human_control` / `:both` / `:open`, declared in `CommandSpec` like the others,
because the channel is part of the schema.

In the prototype: `bot_scout` observes `['evidence','runtime']` and nothing beginning
`bot_`, so Scout cannot see the roster. Ada can, by grant. Asserted both ways.

## 2 · Delegation is a capability, and your two blocks can contradict

```
may_delegate:                        authority:
  - research                           github.pr.create: approval
  - code                               deploy.production: denied
```

`may_delegate` names kinds of work; `authority` names capabilities; nothing relates them. A
Bot denied `deploy.production` that may delegate *code* can delegate to an Agent that holds
`deploy.production`, and the effect happens. That is a confused deputy, and it is precisely
the crossing `Ampd.Gateway` exists to refuse — *no path reaches an adapter except through
here*, matching actor + capability + resource + duration and naming the miss.

Shipped law, in two parts, because they are **different facts**:

```
delegation-exceeds-holder   Ada does not hold deploy.production
delegation-not-permitted    Ada holds lane.spawn and may not pass it on
delegation-widens           workspace outlives Ada's own run
```

Duration is ranked against the same closed enum the runtime uses — `once run agent
workspace` — for the reason `duration_ok` ending in `_ -> true` once let `"forever"` outlive
both its run and its workspace.

**One fixture choice worth flagging, because it changed a law from true to true-and-
reachable.** I first gave Ada `workspace`. That is the top rung, so *"delegation may only
narrow"* was **vacuously true** — there was nothing wider left to refuse, and the assertion
passed while measuring nothing. Ada's own hold is now `run`, which is also the better
default: a Bot is long-lived and its authority should not be.

## 3 · An utterance is a frame with no cursor — this is W.1.2 one layer up

W.1.2's argument was exact and I am reusing it verbatim: a frame labelled `revision 2`
carrying revision-3 content is worse than a stale frame, because a client comparing cursors
believes it has already rendered the newer state, so **the correction never arrives — and
the correction is a revoked grant still on the screen.**

> Kestrel finished the Rust transport change. Magpie's WebView branch is held because two
> falsifiers are red.

That has no cursor at all. The seqlock, `ViewClock`, `try_of` failing closed on a missing
field — every mechanism of the last three rounds is bypassed the moment the same truth is
rendered as a sentence. Nothing in it can fail closed, and a Bot is the surface a person is
*most* likely to believe.

So an utterance is a projection here:

```
Ada · Chief Architect
Here is the world as of the cursor below.
  3 of 3 lanes are running                                        lanes ↗
  3 grants active · 0 crossing attempts · 0 allowed, 0 held        capabilities · gateway ↗
  github.pr.create needs you — I hold no grant and may not mint one
cursor  trvm · run-b51 · view 1 · 9d7adfee     [ SUPERSEDED — world is at view 2 ]
```

Measured in the browser: a refused `postgres.query.write` crossing moved the clock 1 → 2 and
that line flipped to `SUPERSEDED` on its own. The claim text still says *0 crossing
attempts*, which is correct — it describes view 1, and it says so.

Three sub-laws, all falsified:

- **the cursor is sampled after the content**, so the label is never younger than what it
  labels;
- **superseded is a label, not a deletion** — the utterance stays in the feed;
- **a Bot may not state a figure it cannot cite** → `uncited-claim`. This is the same defect
  `proof-battery.mjs` already fails the release for, one layer up: a transcribed number that
  nothing can check. *"The authority revision advanced 14 times"* is transcribing.

### The probe that could not be written, and what it cost

`botSay(bot, body, claims)` took an array. With the content already assembled, **sampled-
before and sampled-after return the same number** — so the sabotage that swaps them stayed
green and the assertion proved nothing. Same shape as the bind-vs-submit overclaim in
F.8.2.5, and I only found it because I wrote the sabotage before believing the test.

`claims` is now a **thunk**, evaluated inside `botSay`, so the two sample points sit either
side of something observable. The witness moves the world mid-assembly — the JS shape of
W.1.2 parking a build inside `observe/1`. Sabotaged, it goes red.

`cursorEq` is also now **one line**, for the reason you moved one in W.1.2: split across
two, the only sabotage that can force it true orphans the tail of the expression, the file
stops parsing, and the harness correctly scores that as a broken probe — after which the law
goes unchecked. A predicate that must be falsifiable has to fit on a line.

## 4 · The roster is a side channel unless it is granted

`agent-projection@2` omits `authority_snapshot` deliberately: it is a digest over **all**
grants and watching it is a side channel. A roster showing *Auditor · 1 finding* to every Bot
is the same class — Ada learns Scout found something with no grant saying she may.

This is also the mechanical reason not to copy Grok Bot's foundation, and I think it is worth
stating in those terms rather than as taste. xAI shipped Grok Bot on 11 August 2026; its
Bots share **one user-scoped persistent computer** — files, browser sessions and app logins
in common, isolated to the account rather than to a Bot. That is *shared ambient authority*.
In Super, possession of a descriptor **is** the capability; a shared filesystem is a covert
channel between Bots that no grant describes. Your "Bot ≠ computer, Bot ≠ credentials" line
is right, and this is why.

Worth noting the docs are thinner than the announcement: `docs.x.ai/grok-bot/bots` specifies
only **name, title, description, avatar** as profile fields, defaults a new Bot to
`"New Agent"`, and says a duplicate carries "profile, settings, enabled skills, routines, and
avatar" — no model selection and no access-control fields are specified at all. So
`may_delegate` / `authority` / `escalation` as first-class objects is genuinely ours, not
a port.

## 5 · The third root is not a third position on the same switch

Nav and Runtime are two projections of **the same target set** — every node in `#railtree`
carries a `data-nav` and lands on one of the same twelve screens, so Runtime is Nav relabelled
by what is alive. Bots is not: selecting Ada opens a conversation that is none of those
screens.

That does not weaken the ordering, but it does mean Bots gets its own screen and its own
canvas mode rather than being a re-labelling of the rail, and the switch changes *kind*
rather than *view*. Built that way.

**One thing I did not do, deliberately.** Bots is **first in the switch and not the default
selected mode.** The landing page embeds this prototype live and its first paint is Mission
Control; changing where a visitor lands is a product decision about the page, not about the
root, and I would rather you take it than find I had taken it. One line if you want it.

## 6 · What I did not touch

- **The runtime.** 214 BEAM tests, 42 vectors, both unchanged. `bot-projection@1` and the
  `:bot` channel class are **designed, not built** — §1 is a request for a ruling, not a
  report of work.
- **The authority engine.** `__botState` is a separate export from `__capState` on purpose:
  the Bots layer sits above the frozen executable spec and mutates none of it, and one merged
  surface would make that easy to stop being true. Asserted: a delegation mints no grant.
- **W.2.** Still the Tauri WebView, still untouched, still the last thing. This round took
  W.1.3 rather than the number you reserved.

## 7 · Two harness defects, found by running them

Both are the class this arc keeps finding — the instrument wrong rather than the thing.

**A battery assertion that passed for the wrong reason.** `a refusal moves the view clock`
compared against an utterance assembled *before* the mid-assembly witness, which moves the
clock itself — so it was already true and would have passed whether or not a refusal moved
anything. Now sampled immediately before the crossing.

**A sabotage that was a no-op.** Prefixing `cursorEq`'s body with `return true &&` is
`true && x`, which is `x`. It ran green and read as *the law is unfalsifiable*. The harness
screens for broken parses and stale patterns; it cannot screen for a sabotage that is
semantically identity, and I do not have a general fix for that — only the habit of checking
that the red I expected is the red I got.

## 8 · Open, and I would like rulings

1. **Is `bot-projection@1` a fourth channel class, or is a Bot an agent with a wider
   observation grant?** The second is smaller and I could not convince myself it is
   sufficient: an agent's filter is identity, and widening it to a set changes what the
   filter *is*.
2. **Where does a group chat live?** Bot-to-bot messaging is an information flow with no
   grant behind it today. Two Bots in a group can compare notes; if their observation sets
   differ, the group is a channel between them that neither's grant describes. I have the
   groups rail rendering and the law unwritten.
3. **May a Bot hold an approval-class capability at all?** Every `approve_*` command is
   `channel: :human_control`, so mechanically no — but "Ada escalates to Travis" and "Ada
   holds a grant whose exercise requires approval" are different, and only the first is
   currently expressible.

## 9 · Ladder

    C1.1     ├─ W.1      the cockpit observes one incarnation                  ✓
             ├─ W.1.1    LIVE LOCAL holds one live renderable view             ✓
             ├─ W.1.2    the runtime announces its epoch · the view clock
             │           names what it renders · cursors fail closed          ✓
             └─ W.1.3    Bots is the third root · an utterance is a frame
                         and carries the cursor it was assembled from         ✓
             ── remaining: the WebView
    W.2      Tauri Channel<CockpitFrame> → WebView · unchanged

## Verify

```
node tools/authority-battery.mjs      # 89 assertions
bash tools/sabotage-bots.sh           # 8 falsified · 0 not   (~40s)
bash tools/release.sh                 # required gates, including both host gates
cd ampd && bash tools/sabotage.sh     # 70 · 0 not  (~10m, still outside the chain)
```

New this round: `tools/sabotage-bots.sh`, `window.__botState`, `Ampd.ViewClock`'s browser
analogue (`viewClock` / `touched` / `viewCursor`), and the `s-bots` screen.
