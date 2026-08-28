# W.1.3.2 — visibility is scoped; coherence is an epistemic state

**Artifact: `and-super-rev-w132.zip`. Every required gate green. The Bot executable spec is
frozen at this revision.**

All six items taken, all nine falsifiers built, and all six findings reproduced against the
shipped W.1.3.1 before anything was changed.

The headline is the one I did not want to be true: **W.1.3.1 closed the large hole and left a
smaller one of the same shape.** Removing `authoritySnapshot()` from the Bot cursor was right,
and leaving `view: viewClock` beside it leaked the same fact through a narrower pipe.

```
                       W.1.3.1                          W.1.3.2

freshness      basis.view !== viewClock          basis.projection_digest !== mine now
               (global clock — moves when         (a Bot learns its view changed only
                anything anywhere changes)         when its own view changed)
observation    mayObserve(b,'lanes')             admits(scope, 'lanes', l.id)
               once per KIND, then all lanes      per OBJECT
group scope    OBSERVABLE.filter(kind names)     intersectScope(predicates)
               bot(auditor) ∩ bot(builder)        bot(auditor) ∩ bot(builder) = ∅
                 = ['bot']                        bot(*) ∩ bot(auditor) = bot(auditor)
coherence      settled:false + a warning badge   UNESTABLISHED · no factual claim at all
claim class    whatever the caller declares      the object declares what it can support
provenance     "3 of 3 lanes" cites one lane     cites lanes:summary + all three members
```

---

## 0 · Measured

| | W.1.3.1 | W.1.3.2 |
|---|---|---|
| conformance vectors | 42 | **42** — runtime untouched |
| BEAM tests | 214 | **214** |
| browser assertions | 124 | **148** |
| browser falsifiers | 22 · 0 not | **31 · 0 not** |
| BEAM sabotage falsifiers | 70 · 0 not | 70 · 0 not |
| host acceptance checks | 78 held · 0 failed | 78 held · 0 failed |
| host sabotage falsifiers | 12 · 0 not | 12 · 0 not |

---

## 1 · The six findings, reproduced first

```
A invisible-change side channel   scout's digest UNCHANGED yet its claim went stale
B resource scope widens to kind   granted lane-a only; projection: lane-a, lane-b, lane-c
C group intersects kinds          ada(bot_auditor) + scout(bot_builder) → groupScope ['bot']
D unsettled frames assert state   ACCEPTED with only a badge
E claim kind self-declared        a live lane state labelled `durable` never decays
F aggregate under-cites           "3 of 3 lanes are running" cites only lane:lane-a
```

After:

```
A closed  scout's digest unchanged; its claim stale? false
B closed  projection lanes = lane:lane-a   (summary names: lane:lane-a)
C closed  groupScope = [evidence(*), runtime(*)] — the bot predicate intersects to ∅
D closed  unestablished-basis · no world state was found in which these facts coexisted
E closed  claim-class-mismatch · lane:lane-a cannot support a durable claim (it supports snapshot)
F closed  "4 of 4 lanes are running" cites 5 objects: lanes:summary, lane-a, lane-b, lane-c, lane-d
```

## 2 · The side channel, and the law it produced

Your example is exactly what happened. Scout observes evidence and runtime, produces an
evidence claim, and a **lane** changes — Scout's permitted projection stays byte-identical and
its claim went stale anyway. Scout learned that something, somewhere, moved.

> **A Bot learns that its view changed only when its own projection changed.**

`claimStale` now compares `basis.projection_digest` against a fresh digest of that Bot's own
projection, and the cursor carries **no global clock at all** — `view` is gone from
`bot-projection@1`, from the basis line, and from the board, which used to print `view N` for
the same reason. A Bot with no observation grant can now never be told anything.

The distinction is worth having as a named primitive, as you say:

```
operator view_revision   versions everything the cockpit may see
projection_digest        versions only what THIS Bot may see
```

## 3 · One scope algebra, used in exactly two places

You were right that two implementations was the cause rather than a coincidence — both were
wrong in the same direction. There is now one: a scope is a set of `(kind, resource)`
predicates, with `admits` and `intersectScope`.

**The `resource === undefined` branch is gone.** `assembleFrame` asks per object and an object
always has an id, so the question that produced the widening bug — *may this Bot see lanes*,
with no lane named — cannot be asked from the projection path. A resource-scoped grant now
answers **no** to the bare kind, asserted directly, so the defence survives even if a future
caller asks badly.

Intersection is over predicates, and the attenuation property holds in both directions:

```
bot(bot_auditor) ∩ bot(bot_builder)  = ∅
bot(*)           ∩ bot(bot_auditor)  = bot(bot_auditor)
```

Both are asserted, and the second matters as much as the first: `*` ∩ X = X is what makes
attenuation *add* restrictions rather than replace them, and it is the same property
delegation has one layer down.

**A collection cannot smuggle its members past the boundary.** `lanes:summary` is admitted by
every lane it names, not by its own id — otherwise granting a group "the summary" would
disclose three lanes to a group permitted to see none of them. Falsified with a group granted
exactly `lanes · summary`.

## 4 · UNESTABLISHED, taken exactly as ruled

You are right that a badge is too permissive, and the reason is the one you gave: it is not
old truth, it is unestablished truth. `botSay` refuses `unestablished-basis` outright, and the
Bot's only remaining utterance is

> *I could not establish a coherent view of the world — these facts were never shown to hold
> together, so I will not tell you they did.*

which carries no claims. `COHERENT` and `UNESTABLISHED` are named states rather than a
boolean, and the pessimistic fallback is in the shape you described — three optimistic
attempts, then one ordered attempt, then the refusal.

**One honesty note about that fallback.** In this prototype nothing can interleave with a
synchronous build, so the ordered attempt is the shape and not the force. It is labelled
`ordered` in the frame and named as such in the source rather than presented as the runtime's
linearized read, because claiming otherwise would be the overclaim this arc keeps finding.

## 5 · The claim class belongs to the object

`claimStale` exempts everything that is not `snapshot`, so a self-declared class was a way to
make any fact eternal. Each frame object now declares what it can support, and `botSay`
refuses `claim-class-mismatch`.

**And the executable-spec overclaim you spotted is gone.** W.1.3.1 demonstrated `durable` by
citing `gates:board` and `evidence:ledger` — both live state. Those are `snapshot` objects
now, and the only durable objects in the frame are receipts. At boot no receipt has been
minted, so **Ada's brief currently makes no durable claim at all**, which is the honest
answer: don't demonstrate a class you have no object for.

Aggregates cite what established them — `lanes:summary` names its members and a claim citing
it must cite all of them, refused `incomplete-provenance` otherwise.

## 6 · Four defects in my own instruments, and one is embarrassing

**Two probes could never have matched.** In a *single-quoted* bash argument `\$` reaches perl
as an escaped dollar — a literal `$`, not end-of-line. Two probes were silently pattern-dead
and reported MISSED, which is the only reason this is a note rather than a false number: the
harness scores a stale pattern as a failure, never as a pass. Third consecutive round in which
`sed`-pinned probes are the fragile part.

**A probe that measured a defence in depth, not the law.** Sabotaging `mayObserve` proved
nothing, because `assembleFrame` calls `admits` directly — I had refactored the projection
path and left the probe pointed at the old door.

**A crash masking a probe.** With the `unobserved-citation` check disabled, the class check
dereferenced a missing object and the battery *threw* instead of printing FAIL — so the probe
read as "the law is unfalsifiable" when the law was fine and my guard chain was not
null-safe. Fixed in the code, not the probe.

**And an instrument error in my own repro.** Finding B first re-read as still OPEN because my
check counted objects of kind `lanes` — which now includes the derived `lanes:summary`. The
projection contained exactly `lane:lane-a`. The check was wrong, not the fix.

## 7 · Deferred to B.3, as ruled

`parent_grant_id` is still `bg_<bot>:<capability>`, which cannot distinguish two grants for
the same capability with different resources. You scoped that to B.3 and I have not done it —
noting it here so it is not mistaken for something this round asserts.

## 8 · Ladder

    C1.1  ├─ W.1 … W.1.3.1                                                  ✓
          └─ W.1.3.2  visibility is scoped · coherence is an epistemic state ✓
                      ── Bot executable spec FROZEN
    W.2   Tauri Channel<CockpitFrame> → WebView · REVOKE                 ← next
    B.1   real :bot principal · bot-projection@1 · observation grants
    B.2   persistent conversation + memory
    B.3   attenuated delegation (real parent grant ids) + routines
    B.4   disclosure-scoped groups

Going to W.2. No W.1.3.3.

## Verify

```
node tools/authority-battery.mjs      # 148 assertions
bash tools/sabotage-bots.sh           # 31 falsified · 0 not   (~3m)
bash tools/release.sh                 # required gates + both tree-integrity brackets
cd ampd && bash tools/sabotage.sh     # 70 · 0 not  (~10m, still outside the chain)
```
