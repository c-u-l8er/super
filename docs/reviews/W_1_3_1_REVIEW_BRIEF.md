# W.1.3.1 — a Bot sees only its projection; an utterance cites the projection it came from

**Artifact: `and-super-rev-w131.zip`. Every required gate green.**

All three rulings taken. All four findings reproduced before being fixed, and the reproduction
is in the brief because two of them were things W.1.3 explicitly claimed to have closed.

The slogan change is right and I have adopted it in the code and on the screen:

> **An utterance is not world truth. It is a cited derivation from one coherent frame.**

W.1.3's *"an utterance is a frame"* was wrong in a way that mattered rather than a way that
read badly. A frame is coherent by construction; an utterance assembled from several live
reads is not, and stamping it afterwards cannot make it so.

```
                         W.1.3                          W.1.3.1

citation      cite exists → accepted            object must be IN the frame
                                                 the bot was handed
board         activeGrants.length, always       only bot-projection@1
cursor        authoritySnapshot() — a digest    projection_digest — a digest
              over EVERY actor's grants          over this bot's own frame
coherence     sample after content              one frame, built under a
              (two reads → one label)            stability check
freshness     whole utterance SUPERSEDED        per claim, per claim KIND
delegation    capability + duration             all 7 dimensions + parent revocation
```

---

## 0 · Measured

| | W.1.3 | W.1.3.1 |
|---|---|---|
| conformance vectors | 42 | **42** — runtime untouched again |
| BEAM tests | 214 | **214** |
| browser assertions | 89 | **124** |
| browser falsifiers | 8 · 0 not | **22 · 0 not** |
| BEAM sabotage falsifiers | 70 · 0 not | 70 · 0 not |
| host acceptance checks | 78 held · 0 failed | 78 held · 0 failed |
| host sabotage falsifiers | 12 · 0 not | 12 · 0 not |

---

## 1 · The four findings, reproduced first

I ran your attacks against the shipped W.1.3 before changing anything. Three landed exactly
as described; the fourth I had to re-aim because `$` is `querySelector`, not
`getElementById`, and my first harness read the wrong element and reported *no leak*. It
leaks.

```
1 observation bypass        ACCEPTED — scout cited `lanes`, which it does not observe
2 board leaks global counts WORLD · 3 active grants · view 2     ← on a bot observing NOTHING
3 global authority digest   cursor.snapshot === authoritySnapshot()  → true
4 torn projection           content read at views 2 and 3; cursor stamped 3; CURRENT
```

And after:

```
1 CLOSED  unobserved-citation · lane:lane-a was not in Scout's projection
2 CLOSED  NEEDS YOU nothing · OBSERVES nothing · PROJECTION · 0 objects visible
3 CLOSED  digest sha256:2af8c6ca…   authoritySnapshot sha256:9d7adfee…
4 CLOSED  frame built at view 2; world now 3; basis 2; 2/2 snapshot claims stale
5 CLOSED  durable claim survives the world moving; only the snapshot decayed
```

### The bypass was structural, so the fix is structural

You were right that fixing the check is not enough. `botSay` now requires a **frame**, and a
claim's `source_object` must be an id **in that frame's `objects` map**. There is no path
that accepts a hand-written `{screen:'lanes'}`, so a Bot cannot cite an object it was never
shown — not because a renderer remembered to check, but because the id does not exist for it.

### The digest was the sharpest of the four

`agent-projection@2` omits `authority_snapshot` because it commits to **every** actor's
grants, and W.1.3 put exactly that digest on every bot utterance so a Bot could tell whether
its own view was stale. A zero-observation Bot could have watched it change and learned that
authority moved somewhere it may not see. It can tell from its own view: the cursor is now
`projection_digest`, a hash over the Bot's own frame.

## 2 · Coherence — you were right that "sample after" proves the wrong thing

W.1.3's witness moved the world mid-assembly and asserted `cursor.view >= readAt`. That
proves the cursor is not *older* than the last read and says nothing about whether the claims
form one view. Reproduced: two claims read at views 2 and 3, stamped 3, labelled CURRENT.

`botFrame/1` builds under W.1's own shape — sample, build, sample again, rebuild if it moved,
bounded at three attempts — and then hands the frame over. Every claim in an utterance shares
one basis **by construction**, not by timing. The world may move ten thousand times while the
model reasons; the derivation is still truthfully *derived from P*.

Where a frame does not settle it says `settled: false` and the UI shows it, rather than
refusing. A `projection-unstable` code that a busy world produces constantly is a promise to
an operator that nothing keeps — the same argument W.1.2 made against that exact refusal.

## 3 · Freshness per claim — this was the right call and it is visible immediately

Four kinds, and only `snapshot` decays:

```
SNAPSHOT        3 of 3 lanes are running · stale at view 2        lane:lane-a ↗
DURABLE         the gate board is the receipt's, replayed         gates:board ↗
DURABLE         claims cite evidence; rulings cite the claims     evidence:ledger ↗
DECISION        github.pr.create is mine to propose and yours     grant:bot_ada:… ↗
                to approve — I hold the grant, never the consent
INTERPRETATION  Auditor · Verification is in my projection        bot:bot_auditor ↗
                because a grant names it
basis  trvm · run-b51 · view 1 · eea0ec28        1 of 5 snapshot claim stale
```

That is one refused crossing after the derivation. Under W.1.3 all five lines would be red.

## 4 · Observation is a grant now, not a field

`observes: ['lanes','gates']` was a parallel permission system beside the real one — two
sources for one fact, which is how they start disagreeing. Gone:

```js
{capability:'super.observe.lanes', resource:'*'},
{capability:'super.observe.bot',   resource:'bot_auditor'},   // one bot, not the roster
```

`bot-projection@1` is assembled from those grants. Ada sees Auditor and not Scout, and the
assertion runs both ways.

## 5 · Delegation over the whole grant

Seven dimensions — `resource duration workspace run placement budget policy` — each with its
own narrowing rule, plus `parent_grant_id`, `delegation_chain`, and
`authority_snapshot_at_entry`. Six separate refusals now exist where W.1.3 had two, and the
one I most wanted to see fail does:

```
delegation-widens · policy "auto" is not within the parent's "human_approval_required"
```

A delegation that keeps the capability and the duration can still turn an approval-bound
grant into an automatic one. That is a different effect on the world than the parent
authorized, and capability-plus-duration could never see it.

Parent revocation takes its children in the same operation, `revoked_reason:
'parent-grant-revoked'` — and a revoked parent can no longer delegate at all.

## 6 · Approval — taken exactly as ruled

Ada now **holds** `github.pr.create` with `policy: human_approval_required`. She is
authorized to propose; she is not authorized to consent, and no grant in this model could
give her that. `escalates` is gone — you were right that it was quasi-authority, a list that
looked like a permission and governed nothing — replaced by `presents`, a routing preference.

`approve_effect` / `deny_effect` / `approve_grant_request` / `deny_grant_request` /
`revoke_grant` / `revoke_capability_domain` are `human_control` only, and attempting to
delegate one refuses `human-control-only` before the holder check even runs.

Peer kinds are `agent · bot · human_control`, and the command table declares **exact sets**
rather than `:both`. I agree that `:both` stops meaning anything with three principals.

## 7 · Groups — the disclosure-context law is encoded, the messaging runtime is not

Per your direction. `groupScope = intersection(members) ∪ granted`, so adding a member can
never widen anyone, and `groupMaySay` refuses `outside-group-scope`:

```
#TRVM research  = ada + scout   → scout sees no lanes → the group discloses none
ada may not state a lane fact there, though she can see it herself
ada may state an evidence fact there
```

The rule is *the group may see it, so Ada may state it here* — not *Ada can see it, so Ada
may tell everyone*.

## 8 · Two defects the harness found in its own second run

Both the instrument, not the thing. Same class as last round.

**A name collision that would have clobbered the frozen authority engine.** My `grantFor(b,
cap)` collided with the engine's existing `grantFor(capId, resource, ctx)`. It threw at boot
and never shipped — but it is precisely why `__botState` is a separate export from
`__capState`, and it is the first time that separation earned its keep. Renamed
`botGrantFor`.

**An assertion that measured intent rather than effect.** `revokeBotGrant` returned
`killed.length` — the size of the set the *filter* selected, which is the same number whether
or not the revocation happened. Stubbing the revocation out left the assertion green. The
count is now taken by re-reading `status === 'revoked'` afterwards. *Report what changed, not
what was intended to.*

### And one in the release chain itself, which is F.8.1's shape again

Chasing the mtimes on `bridge.ex` / `transport.ex` / `native_fd.ex` to prove the runtime was
untouched, I found they are edited **by `sabotage-host.sh`**, which sed-sabotages ampd sources
and restores them — and it runs at stage 15, three stages *after* `mix test`. A failed
restore, or a harness killed mid-probe, would leave a sabotage in the tree with every gate
that could see it already run, and the zip would ship it. That is exactly F.8.1: the chain
that packages the artifact never running the one check that could catch what it ships. It has
happened for real once, in F.8.2.3, and was caught only because a duplicate `mv` errored.

Each adversarial gate is now **bracketed** by a content fingerprint — not the whole chain,
because `inject-proof`, `stamp-rev`, `export-vectors` and `stamp-counts` rewrite files in
those same paths on purpose and a whole-chain fingerprint would refuse every legitimate round.
The guard has its own falsifier: a harness that does not restore is refused and its leftover
`.orig` named. This round it prints

```
tree integrity: sabotage-bots restored what it sabotaged
tree integrity: sabotage-host restored what it sabotaged
```

and I separately re-ran `mix test` after the sabotage pass — 214, 0 failures — rather than
asserting the tree was clean because I had not personally edited it.

## 9 · What I did not do

- **The runtime.** 214 BEAM tests, 42 vectors, unchanged. `bot-projection@1`, the `:bot` peer
  kind and `super.observe.*` are **executable spec, not implementation** — that is B.1.
- **Group messaging.** The law is encoded and asserted; nothing sends a message.
- **W.2.** Untouched. Next, per your sequence.

## 10 · Ladder, as you sequenced it

    C1.1  ├─ W.1      the cockpit observes one incarnation                      ✓
          ├─ W.1.1    LIVE LOCAL holds one live renderable view                 ✓
          ├─ W.1.2    the runtime announces its epoch · the view clock          ✓
          ├─ W.1.3    Bots is the third root                                    ✓
          └─ W.1.3.1  a Bot sees only its projection · an utterance cites
                      the projection it came from                               ✓
    W.2   Tauri Channel<CockpitFrame> → WebView · REVOKE                     ← next
    B.1   real :bot peer · bot-projection@1 · observation grants
    B.2   persistent Bot conversation + memory
    B.3   delegated grants + routines
    B.4   governed groups / bot-to-bot handoffs

## 11 · One thing I would still like ruled, and it is new

`botFrame` returns `settled: false` when three attempts do not find a quiet moment, and the
UI says so. But a Bot reasoning for thirty seconds against a frame that never settled is
deriving from a view that was never coherent — and the person reading the answer cannot tell
the difference between *"this was true and is now old"* and *"this may never have been true
together"*. Right now those wear the same label. I think they are different facts and want to
know whether you agree before I invent a vocabulary for the second one.

## Verify

```
node tools/authority-battery.mjs      # 124 assertions
bash tools/sabotage-bots.sh           # 22 falsified · 0 not   (~2m)
bash tools/release.sh                 # required gates, including both host gates
cd ampd && bash tools/sabotage.sh     # 70 · 0 not  (~10m, still outside the chain)
```

New this round: `botFrame` / `bot-projection@1`, `bot-utterance@1`, `CLAIM_KINDS`,
`super.observe.*`, `delegated-grant@1` with `DIMS`/`narrows`, `revokeBotGrant`,
`groupScope`/`groupMaySay`, `PEER_KINDS`, and last-used-root restore.
