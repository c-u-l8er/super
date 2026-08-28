# W.1.3.2b — the errata, the two the errata found, and the two you found in those

**Artifact: `and-super-rev-w132b.zip`, with `and-super-rev-w132b.receipt.json` beside it binding
this revision to that archive's SHA-256. Every required gate green.**

> **On the identity, which was your sharper point.** You are right, and it is the one thing here I
> would not have caught myself. W.1.3.2a shipped **twice**: the second bundle carried new tools, a
> modified prototype, modified release scripts and regenerated proof artifacts, and still called
> itself W.1.3.2a. Two byte histories, one name — in a system whose entire subject is identity,
> citation, basis and provenance. The review artifacts cannot be ambiguous about what a revision
> refers to while the product they describe is about exactly that.
>
> This is W.1.3.2b: `release.json`, the brief's filename, the archive name, and a sibling receipt
> that binds them. The archive cannot contain its own hash, so the binding is beside it, as you
> said. The bundle you reviewed as "W.1.3.2b" was
> `sha256:2b490704…c75a` and called itself W.1.3.2a; this one says what it is.

**§§1–10 are the W.1.3.2a round** — your four errata and the two leftovers, unchanged except where
noted. **§11–12** are the two you found in that. **§13** is the runtime defect the chain surfaced
on its own. **§14** is this round: release identity and measurement semantics.

All four of your findings reproduced against the shipped W.1.3.2 before anything was changed,
and each is now a named falsifier rather than a fixed line. Two of them were **stronger than you
stated**, which is the part worth your time:

- **§4 (the bracket).** You said the mid-probe claim was untrue and packaging still stops. It is
  worse: with the harness dying *dirty*, the old bracket produced **no output at all**. Not a
  wrong verdict — silence, with a sabotaged file in the tree. And the sentence "the guard has its
  own falsifier" in the W.1.3.1 brief had **no harness under it**. It was prose. Writing one found
  that two of the three cases the bracket claims to catch were not caught.
- **§2 (claim validity).** Fixing it needed a place to put the resolved `(kind, resource)` of each
  citation, which meant the claim had to carry them — and *not* re-derive them by parsing an id.
  Your §3 and your §2 turn out to be the same defect at two altitudes.

And one finding of my own, in the measurement rather than the model: **the browser-assertion count
was never derived.** The brief I sent you said 148. The blueprint said 64. The battery emitted
**150**. Three numbers, one measurement, and the one that reached you was the one nothing checked.

---

## 0 · Measured — **`site/proof/measurements.json`**

**Every figure this round measured is in the receipt, and this document does not restate them.**
That is the fix for the defect you found, not a stylistic choice: three rounds running, a number
was copied out of a gate's output into prose and three times the copy was wrong, and each time the
answer was to protect one more noun. `vectors`, then `tests`, then `assertions` — and the fourth to
drift was `text assets`, which no one had thought to name. **The list can only ever contain the
mistakes already made.**

So `tools/emit-measurements.mjs` builds one receipt from the gates' own reported lines, and
`tools/check-measurement-prose.mjs` takes its noun list **from that receipt**. A gate added
tomorrow is guarded tomorrow, by nobody remembering anything. This paragraph would be refused by it
if it named a figure.

Three counts still read inline, because a table with no numbers is not a report: those carry
`stamp-counts` markers and are written by the tool that measured them.

| | W.1.3.2 as shipped | this revision |
|---|---|---|
| conformance vectors | 42 | **<!--vectors-->42<!--/vectors-->** — runtime untouched |
| BEAM tests | 214 | **<!--tests-->214<!--/tests-->** |
| browser assertions | 148 *(claimed)* · 150 *(actual)* | **<!--assertions-->188<!--/assertions-->** |

Everything else — browser falsifiers, guard falsifiers, count-gate outcomes, source-hygiene assets,
host acceptance, host and BEAM sabotage — is in the receipt beside the artifact's SHA-256.

Runtime untouched, verified by mtime on `ampd/lib` + `host/src`. `bot-projection@1` is still
executable spec, not implementation.

`ampd/tools/sabotage.sh` — the four-and-a-half-minute gate `release.sh` deliberately does not run,
and without which a round is not closed — was run separately, all probes falsified, and **zero
`.orig` in the tree afterwards**, which is now a checked property rather than an assumption.

> **Read the BEAM row with §13 beside it.** That figure is one run of a suite I have since measured
> as nondeterministic — one test fails roughly 15% of the time, and it is detecting a real
> at-most-once violation rather than being flaky about nothing. A single green run of it is about
> 85% reliable. That was true of every brief in this arc, including the ones that did not say so.

---

## 1 · The global side channel inside `botFrame()` — taken

Your reproduction is exact, and the law you wrote is the one I should have written at W.1.3.2:

> **Neither freshness nor coherence may reveal changes outside the Bot's projection.**

W.1.3.2 scoped freshness to the projection digest and left coherence reading `viewClock`, so the
leak walked one door down. Coherence is not a label a Bot reads off a frame — it is an
*availability*, and an availability that depends on invisible churn is a channel.

```
                W.1.3.2                          W.1.3.2a

  const before = viewClock;          const before = stabilityToken(b);
  f = assembleFrame(b);              f = assembleFrame(b);
  if (viewClock === before) …        if (stabilityToken(b) === before) …

  a private lane churns              two builds of the same projection
  → every attempt retries            → nothing outside it can make them differ
  → UNESTABLISHED                    → COHERENT
  → "something is moving"            → nothing learned
```

`stabilityToken` is deliberately **one line**, for the reason `cursorEq` is: the only forcing
sabotage swaps the token for the clock, and a predicate split across two lines orphans its tail,
stops the file parsing, and scores as a broken probe — which leaves the law unchecked.

**The witness is your injection, not an argument about it.** `assembleFrame` walks `receiptsLog`
on every build and Scout holds no receipts grant, so hooking its `filter` puts a `touched()`
*inside* the frame build that is invisible to the frame being built:

```
the churn fired inside the frame build                        churn ≥ 2
scout's frame is COHERENT despite continuous invisible churn  COHERENT
the churn is invisible to scout's projection                  digest unchanged
and the frame still supports a factual claim                  not refused
a bot that DOES observe receipts is also coherent             COHERENT
```

Run against the W.1.3.2 semantics (`stabilityToken` → `viewClock`) all five go red. Confirmed
live in the browser as well as headless: the global clock moved **3 times** during Scout's build,
Scout's frame came back COHERENT, and Scout could still speak.

The last line matters: the fix is not "never retry", it is "retry on what this Bot can see".

---

## 2 · `decision` and `interpretation` were immortal — taken, with your state model

You are right that `stale` is the wrong word for three of the four, and right that this must not
reach B.1. Implemented as you sketched:

```
snapshot        CURRENT | STALE          the projection moved
durable         ESTABLISHED | RETRACTED  the world withdrew the object
decision        VALID | INVALIDATED      the authority behind it died
interpretation  BASIS-BOUND              never current, never false
```

`claimStale` survives as a thin `!VALIDITY_HOLDS[claimValidity(...)]` so the existing law and its
falsifiers stay live, and the board now prints the kind's own failure word rather than "stale" for
all four.

**Your decision witness, in the shipped UI:**

| claim | before revoke | after revoke |
|---|---|---|
| `3 of 3 lanes are running` · snapshot | CURRENT | STALE |
| `github.pr.create is mine to propose` · **decision** | VALID | **INVALIDATED** |
| `Auditor is in my projection` · snapshot | CURRENT | STALE |
| `I would route verification to Auditor` · **interpretation** | BASIS-BOUND | BASIS-BOUND |

**And I took your point about the examples, which was the sharper half.** "Auditor is visible to
me" is not an interpretation — it is a presence claim, true of a moment, false the moment the
grant naming Auditor is revoked. W.1.3.2's brief demonstrated the eternal class by asserting
something that decays. `bot:` objects now support **both** classes and `botBrief` emits one of
each, so the difference is visible in the product rather than argued in a comment.

### The one place the fix could have become the next side channel

`durable` is the only kind whose truth condition lives *outside* the Bot's projection, so it is
the only one that could tell a Bot about a world it may not observe. A Bot that has **lost** the
grant naming a receipt must not thereby learn the receipt was retracted:

```
a retracted object RETRACTS the durable claim                      RETRACTED
a bot that lost the grant is NOT told the object was retracted     ESTABLISHED
and a bot that still observes it IS                                RETRACTED
```

with its own falsifier (`retraction is reported to a bot that may no longer see the object`).

**Open, and deliberately not invented here — for the B.1 sheet.** "I cannot tell any more" is
arguably its own state and not `ESTABLISHED`. It is STALE-vs-UNESTABLISHED one layer up: a claim
that still holds and a claim you have lost the standing to re-check are different facts wearing
one label. I chose the conservative answer (never fabricate a retraction) rather than add a fifth
state unilaterally. **Your call.**

---

## 3 · Object ids are identity; grant resources are authority scope — taken

Exactly as you specified. Every frame object now carries `resource`, and disclosure consumes the
field instead of `oid.split(':').slice(1)`.

```
{ id: "gateway:counters", kind: "capabilities", resource: "gateway", … }
```

```
ada's frame admits the gateway object                                        yes
and it carries the resource it was admitted by                               'gateway'
which is NOT its id tail                                                     'counters'
a group granted capabilities(gateway) may be told about the gateway object   ok
and a group granted the ID TAIL may not                                      outside-group-scope
an object with no declared resource is not disclosable                       undeclared-resource
```

Two notes on the shape:

- **A collection still carries no resource of its own** and is admitted by every member it names,
  so the summary-smuggling law is untouched. Its falsifier was rewritten against the new line.
- **The boundary now fails closed on an object it cannot scope** (`undeclared-resource`) rather
  than guessing. That is new behaviour, not just a rename — the previous code could not have an
  unscopable object because it always manufactured one.
- **The `self` objects were being refused for an accidental reason.** A Bot's own grants are the
  one thing it observes without a grant, and `grant:bot_ada:lane.spawn` split to the resource
  `bot_ada:lane.spawn` — a string no scope could ever name. Correct outcome, no principle. Now
  they carry `resource: bot_ada`, `self` is not an observable kind so no member's scope can
  contain it, and the person can still grant a group `self(bot_ada)` explicitly — an
  information-authority change, governed as one. Asserted rather than reasoned about:

  ```
  a bot may not state its own authority in a group by default   outside-group-scope
  and may when the person grants the group that scope           ok
  a grant naming a different bot does not do it                 outside-group-scope
  ```

**And this is where your §2 and §3 met.** Validity is asked long after the frame is gone, so it
needed `(kind, resource)` per citation — and reconstructing that from an id would have reintroduced
your §3 defect in the least visible place in the system. `botSay` stamps the resolved citations
onto each claim at say-time. Falsifier: `the claim does not carry its resolved citations`.

---

## 4 · The bracket — taken, and it was worse than the finding

Your fix is the right shape and I took it. The measured facts, against W.1.3.2's bracket:

| case | W.1.3.2 bracket | W.1.3.2a |
|---|---|---|
| harness restores cleanly | `tree integrity: restored` | same |
| harness does not restore | refused, fingerprint named | same |
| **harness leaves its `.orig`** | **`tree integrity: restored`** ← says success | refused, backup named |
| **harness dies, tree clean** | **(no output at all)** | `RELEASE REFUSED · probe exited 3` |
| **harness dies, tree dirty** | **(no output at all)** | refused + `harness exit status: 3` |

The bottom two rows are the ones to look at. `set -e` killed the subshell at `"$@"`, so the
bracket never reached its own report — a sabotaged file in the tree and **silence**. Packaging
stopping is not the same as the bracket working, and only one of those two was ever true.

Implemented as you wrote it, with `set -e` saved and restored rather than force-enabled:

```bash
local had_e=0; case $- in *e*) had_e=1;; esac
set +e; "$@"; rc=$?; [ "$had_e" = 1 ] && set -e
after=$(fingerprint …); orig=$(find … -name '*.orig')
if tree_changed || orig; then refuse; fi
if [ "$rc" -ne 0 ]; then refuse "$label exited $rc"; fi
```

**Three things beyond the finding:**

1. **`tools/sabotage-guard.sh` exists now.** W.1.3.1's "the guard has its own falsifier" was a
   sentence with no harness under it — the claim-about-a-measurement defect `proof-battery.mjs`
   fails the release for, four levels up. The harness runs against a scratch tree it owns, under
   `set -e` because that is how `release.sh` calls it, and **each case names the sentence the
   bracket must produce** — because my first version asserted only a nonzero exit, and under the
   old bracket both death cases *passed* it. A nonzero exit is not a verdict.
2. **`.orig` cannot ship.** `fingerprint` excludes `*.orig` by design, so "source restored, backup
   left behind" fingerprints identical — and neither packager excluded it. Both packagers exclude
   it now, and `release.sh` refuses outright if one is anywhere in the tree.
3. **`preview-release.sh` ran `sabotage-bots.sh` completely unbracketed.** `release.sh` got the
   bracket at W.1.3.1 and the sibling script — the one a box without Elixir actually uses — kept
   calling it bare. Now bracketed, and it runs `sabotage-guard.sh` too.

Traps harmonised, as you asked:

```bash
cleanup(){ restore; rm -f "$ORIG"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
```

The old form ran cleanup on Ctrl-C **and carried on** — the loop kept sabotaging with the backup
already deleted, so the next probe wrote a change nothing could undo.

**Not taken this round:** temp worktrees instead of editing the release tree in place. You are
right that it is cleaner; it is a bigger change than an errata patch and it does not block W.2.
Recorded.

---

## 5 · The two leftovers — swept

- `botAsk()` logged `u.basis.view`, which W.1.3.2 removed from the cursor. It had been printing
  `undefined` since the moment the model changed. Now `basisText(u.basis)`.
- `pickGroup()` joined `sc` — an array of predicate objects since W.1.3.2 — producing
  `[object Object]`. Now `scopeText(sc)`.

Verified in the browser: no `[object Object]` and no `undefined` in the rendered feed.

---

## 6 · The finding that was mine, and it was in the number I sent you

**The browser-assertion count was never derived.** `stamp-counts.mjs` has derived vectors and BEAM
tests since W.1 precisely so no one types them; the browser battery was the one suite it did not
cover, and the count was typed into whatever document was being written.

```
W.1.3.2 review brief   148     ← the number I sent you
blueprint, current     64      ← last true at W.1.3, wrong for two rounds
the battery            150     ← what actually ran
```

The battery counts itself now, `stamp-counts.mjs` derives the figure by **running it and reading
what it reports** — not by counting `t(` calls, because an assertion inside a branch that never
executes is written and not attempted — and a bare `N assertions` outside markers fails the
release the same way a bare vector count does.

**Nothing about your six accepted W.1.3.2 items changes.** The laws held; the number describing
them did not.

---

## 7 · The defect this round re-committed

Worth recording because W.1.3.2 recorded it and I did it again inside the fix.

`claimValidity` dereferenced `now.objects[o.id]`. With the freshness check stubbed by a sabotage,
`now` became a stub without `.objects`, the battery **threw**, and the harness — which greps for a
named assertion going red — scored the law as *unfalsifiable* rather than as failing. A crash
masks a probe. Every dereference in that function is guarded now, so a stubbed link produces a
different **refusal**, never a stack trace.

The screen that caught it is the one that already existed: MISSED and NOT both score as failure,
so a probe that stops working cannot quietly become a probe that passes.

---

## 8 · What I did not do

- **No W.1.3.3.** As you ruled.
- **The runtime.** Untouched, verified by mtime.
- **A fifth claim-validity state** for "I cannot tell any more" — §2 above, your call.
- **Temp worktrees** for the sabotage harnesses — §4 above.
- **`parent_grant_id`** still `bg_<bot>:<cap>`, still B.3, unchanged.

---

## 9 · W.2, which is where I am going next

Taking your sequence and your falsifier verbatim. I re-checked the two Tauri facts independently
rather than inherit them:

- **Tauri core 2.11.5** is current (docs.rs `tauri/latest` → 2.11.5, released 2026-07-01).
- **Channels are the right primitive**, and the docs say so in the terms you used: *"Channels are
  designed to be fast and deliver ordered data. They are used internally for streaming operations
  such as download progress, child process output and WebSocket messages."* The event system is
  documented as **not** for low latency or high throughput, and explicitly warns that async
  listeners may process rapid successive events **out of order** — which for a `CockpitFrame`
  stream is not a performance note, it is a coherence bug. A frame that arrives after the frame
  that superseded it is W.1.2's torn projection, delivered by the transport.

**The seam is already cut, which I had forgotten and re-read rather than assumed.**
`CockpitLoop::feed(&frame)` was deliberately split out of `turn` at W.1, with the comment *"a
Tauri worker fed from elsewhere runs the same code"* — receiving a frame and deciding what it
means are separable, and only the second half is the state machine. So W.2 does not port the
cockpit; it gives `feed` a different source. `host/Cargo.toml` has one dependency (`serde_json`)
and no Tauri yet, so the Tauri app is additive rather than a rewrite.

The falsifier I am building to:

```
click REVOKE
        ↓
IPC returns success
        ↓
DOM MUST STILL SHOW THE GRANT
        ↓  (until)
a new CockpitFrame arrives without it
        ↓
DOM removes it
```

The thing I will be watching for: the honest failure mode is not that this test fails, it is that
it **passes vacuously** — if the IPC round-trip and the frame push are indistinguishable in time,
the assertion cannot tell "the UI waited for the frame" from "the UI updated itself and the frame
happened to agree". Same shape as the W.1.3 delegation law that was vacuously true at the top
rung. So the witness has to **hold the frame back** and assert the DOM still shows the grant while
the IPC has already returned — not merely assert the end state.

---

## 10 · Verify

```
node tools/authority-battery.mjs      # count derived and printed
bash tools/sabotage-bots.sh           # every bot law, falsified
bash tools/sabotage-guard.sh          # the bracket itself, falsified   ← new
bash tools/release.sh                 # every required gate green
```

To see §1 and §4 fail on purpose:

```
# the coherence side channel, restored
perl -0pi -e "s/^function stabilityToken\(b\)\{ return assembleFrame\(b\)\.cursor\.projection_digest; \}\$/function stabilityToken(b){ return viewClock; }/m" site/app-prototype.html
node tools/authority-battery.mjs      # 6 FAIL, including 'scout's frame is COHERENT…'

# the W.1.3.2 bracket, restored into tools/guard.sh
bash tools/sabotage-guard.sh          # 3 caught · 3 not — two of them produce NO OUTPUT
```

---

## 11 · W.1.3.2b — the two you found, closed

Not a design round. Two measurement/hygiene errata, each with a falsifier, taken as you scoped them.

### 11.1 · The count that drifted inside the section about count drift

You are right, and the mechanism is the one you named. §6 claimed a bare `N assertions` outside the
markers fails the release. It did not, because the scan was:

```js
const guarded = ['../README.md', '../ampd/README.md'];
```

The brief was **stamped** and not **scanned** — and those are different guarantees. A marker fixes
the number you remembered to wrap; the scan is what catches the one you did not. So the file
written to explain the fix shipped the defect, and the gate was green over it.

Three things done:

- §10's line is now `# count derived and printed`. The number is **removed** rather than corrected,
  because correcting it leaves a hand-typed number in the same place a year from now.
- The **current** brief joins the bare-count scan, found from `release.json` the same way the stamp
  target is. Historical briefs stay frozen literals — restamping a past round's measurement is the
  defect `stamp-counts` already refuses two markers to prevent.
- **`tools/sabotage-counts.sh`**, because the tool that stops figures being typed had never refused
  anything — your point one level up. Seven cases, run bracketed:

```
a clean tree                                          accepted, as it must
a bare assertion count in the current review brief    refused   <- your 999 case
a bare vector count in the README                     refused
a bare test count in the ampd README                  refused
a hand-edited marker is restamped, not refused        restamped <- a different guarantee, measured
a failing battery still gets its number stamped       refused
a battery that stops reporting its count              refused
```

The fifth is worth a look: `stamp-counts` is documented as *reverting* a hand-edited marker rather
than failing on it, and that distinction had never been measured either. The sixth matters most —
the count is derived by **running** the battery, so a red battery must stop it stamping, or a
failing suite's number is written in as though it passed. Worse than a stale count, because it is
a fresh one.

### 11.2 · The NUL, and the parity claim is now measured

Confirmed, and the browser half is measured rather than inferred. Before the fix:

| | separator | U+FFFD in source | U+0000 in source |
|---|---|---|---|
| `authority-battery.mjs` (regex + eval over raw UTF-8) | **U+0000** | 0 | 1 |
| an actual browser (WHATWG script-data state) | **U+FFFD** | 1 | 0 |

Both work as a separator, so nothing was broken — which is exactly why it needed catching. The
suite called "the browser battery" was not executing what a browser executes.

The source now carries the six-character textual escape rather than the byte, so both run the same
bytes and the same separator. Verified live: zero replacement characters in the DOM, runtime
separator U+0000, scope algebra unchanged.

**The provenance is W.1.3.2, not W.1.3.2a.** It entered with `intersectScope` — the
predicate-intersection fix — and survived your review of that round and mine.

`tools/check-source-hygiene.mjs` forbids NUL in every text asset and runs before any
suite reads the source, in both chains.

**It caught itself on its first run.** The comment explaining the fix contained a literal NUL where
I meant the escape: the file forbidding NULs shipped one. That is the round in miniature, and an
argument for gates that scan over authors who intend. It happened twice more while writing this
section, both caught by the same gate.

### 11.3 · One diagnosis I had wrong

I told you `grep` needed `-a` on `app-prototype.html` because of its very long lines. That was
wrong — it was the NUL. `grep` reclassifies a file containing one as binary and reports **no
matches, exit 1**, silently, and it looks exactly like a stale pattern. It cost this session a
wrong diagnosis before it cost the right one; that is now in the gate's comment.

### 11.4 · Measured after 11.1–11.2

The two **new** gates, which have no marker keys and cannot drift against §0:

See `site/proof/measurements.json`. Both gates report into it, so this section names them and
does not carry their numbers.

Everything else is unchanged from §0 and **is not restated here** — which is not modesty, it is
the fix. My first draft of this section reprinted the assertion and BEAM-test counts, and the new
scan refused the brief on the spot: a second copy of a stamped figure is the drift mechanism, and
a section written to explain that cannot also demonstrate it. §0 is stamped; this points at it.

---

## 12 · Your rulings, recorded

**`UNVERIFIABLE` for B.1 — taken, and your rule is better than my answer.** I chose "losing sight
answers ESTABLISHED" to avoid leaking the retraction; you are right that it is the wrong
conservative, because it still asserts something. The clean rule is that **losing observation scope
always yields `UNVERIFIABLE` regardless of whether the object still exists** — which is precisely
why it leaks nothing — and it resolves again to ESTABLISHED or RETRACTED when scope returns.
Recorded on the B.1 sheet, not built here.

**W.2's seven gates — taken as specified**, including the two I would not have written myself:

- *"After it ships, deleting every local state-mutating line from the frontend should not change the
  application, because there should no longer be any such line."* A sharper acceptance test than my
  falsifier: mine tests one command, yours tests the whole class. I will build both — yours as the
  standing property, mine as the witness that proves it for REVOKE.
- **The Tauri authority boundary configured in W.2, not after.** Capabilities on the same webview
  merge, and Super is heading toward browser and app panes inside the same shell — so "only the
  trusted `main` cockpit webview holds the consent commands" has to be true before there is a second
  pane, not retrofitted once there is.

And the scope limit is noted as a limit on the **claim**: W.2 establishes a trusted desktop
application origin. It does not establish that a physical human pressed a key, and nothing in the
round may be written as though it does.

---

## 13 · A runtime finding I did not go looking for, and it is your §1 again

The release chain refused on its last run: the BEAM suite came back with one failure. It passed on
re-run with the same seed, which makes it a flake — and a flake in a suite whose entire purpose is
proof is not a nuisance, it is a claim that has been partly luck.

**Measured rate:** the whole suite failed 1 of 6 runs. The named test in isolation failed **3 of
20**, on *both* of its commands, always recording exactly **2** where the law says 1.

```
ampd/test/cockpit_test.exs:599
  "a read that constructs a refusal is executed exactly once"

  preflight       → recorded 2 denied-by-default refusals for one command
  inspect_refusal → recorded 2 refusal-unknown  refusals for one command
```

That is not a flaky assertion. It is an at-most-once violation that reproduces.

### The cause, and it is the shape you found in the Bot layer

`Ampd.Refusal.new/2` records into `Ampd.RefusalLog` as it constructs, so a read that can refuse is
a read with a side effect. An earlier round measured **four** recorded refusals for one client
command, declared `retry: :safe | :once` in `Ampd.CommandSpec`, and routed `retry: :once` reads
away from the optimistic loop:

```elixir
# Ampd.Projection — the fix, and its docstring
#   "Assemble a frame **without speculating** — straight to the ordered path."
#   "a `retry: :once` read comes here: one execution, inside the total order"
def framed_once(expected, fun), do: do_framed(expected, fun, 0)
```

`attempts = 0` does skip the optimistic loop. Then it hands `fun` to the ordered path:

```elixir
{cursor, content} = Ampd.AuthorityCoordinator.observe(fun)
```

and one layer down:

```elixir
# Ampd.AuthorityCoordinator
def handle_call({:observe, fun}, _from, st), do: {:reply, coherent(fun, st, 3), st}

defp coherent(fun, st, attempts) do
  before  = Ampd.ViewClock.read()
  content = fun.()                                    # <- up to three times
  cursor  = sample_after(st, before)
  if cursor["view_revision"] == before or attempts <= 1,
    do: {cursor, content},
    else: coherent(fun, st, attempts - 1)
end
```

**The outer speculation was removed and an identical one was left directly beneath it.** That is
your §1, one subsystem over: W.1.3.1 took the authority digest off the Bot cursor and left the
global clock beside it; this round took the speculation out of `framed_once` and left it in
`observe`. Twice in one codebase, in the same week, in two layers that do not know about each
other.

It also explains the numbers exactly. Four executions became one-usually-two, never four, because
only the inner loop survives and it settles on its second attempt in the common case. And the
`retry: :once` declaration is enforced at compile time — `CommandSpec` refuses a read that omits
it — while nothing enforces it past the first layer at runtime. A property declared, checked for
presence, and not honoured.

`coherent/3`'s own comment says the loop "converts the common case from safe to exact" — it re-runs
the read to get a cursor that matches its content. That is the right optimisation for a read with
no side effect and the wrong one for a read that writes, which is precisely the distinction
`retry:` was introduced to carry and the coordinator never receives.

### What I did NOT do

**I did not fix it, and I am not going to inside this round.** Three reasons, in order:

1. **The runtime is untouched, and that is a load-bearing property of this artifact.** §0 says so
   and it is verified by mtime. Editing `authority_coordinator.ex` to close this would make that
   sentence false in the same document that relies on it.
2. **A 15% test cannot prove a fix.** "It passed twenty times afterwards" is not evidence at this
   rate; the witness has to become deterministic *first* — drive the ViewClock from the test rather
   than racing it with a 20,000-iteration churn process — and that is the first half of the work,
   not a detail of it.
3. **It is a design question, not a patch.** `observe` needs to know whether its `fun` may be
   re-run. The shape is probably `observe(fun, attempts)` with `framed_once` passing 1, but that
   means the coordinator starts carrying a property from `CommandSpec` that it currently has no
   channel for — and the alternative (make the refusal log write outside the speculated region)
   is a different answer with different consequences. Your call, not mine to guess at.

### What this changes about every number I have sent you

The BEAM figure in §0, and the same figure in every brief this arc has produced, comes from a
**single** run of the suite. At this flake rate a single green run is roughly 85% reliable, not a
proof — so "0 failures" has been a weaker statement than it reads, in my briefs and in the ones
before them. That is a gate defect independent of the runtime defect: a chain that runs a
nondeterministic suite once cannot distinguish a passing suite from a lucky one.

I have not changed the chain to repeat the suite, because at this rate that would refuse nearly
every release and it is not my call to make packaging impossible at the end of a round you asked me
to close. But I would put it directly after the fix: once the witness is deterministic, the suite
should be deterministic, and then a single run means what it says.

**Sequencing suggestion**, since it touches your ordering: this is not a W.2 blocker — W.2 is a
desktop shell over the existing cockpit, and a read that records its refusal twice does not change
whether the DOM waits for a frame. But it *is* a B.1 blocker, because B.1 copies this machinery
into the runtime, and it should not copy a speculation that re-runs side-effecting reads.

---

## 14 · W.1.3.2b — release identity and measurement semantics

Your two rulings, and nothing else. The at-most-once closure is **W.1.4**, a separate artifact,
sequenced as you asked — this one does not touch the runtime, which is the property that makes it
a separate artifact rather than a paragraph.

### 14.1 · The identity, which was the sharper point

You are right and I would not have caught it. `W.1.3.2a` named two byte histories: the bundle you
reviewed first, and the one you reviewed second with new tools, a modified prototype, modified
release scripts and regenerated proof artifacts. In a system whose subject is identity, citation,
basis and provenance, the review artifacts were ambiguous about what a revision refers to.

Closed as ruled — `release.json`, the brief's filename, the archive name — plus the binding you
suggested, as a sibling because the archive cannot contain its own hash:

```
and-super-rev-w132b.receipt.json
  { "schema": "release-receipt@1",
    "revision": "…", "artifact": "…", "sha256": "…", "bytes": …,
    "measurements": { … } }
```

The measurement receipt travels inside it, so the figures and the bytes they describe cannot be
separated afterwards. `release.sh` refuses to write a receipt whose measurements name a different
revision than the tree.

### 14.2 · Measurements are referenced, not recreated

Your framing is the fix, and it is better than what I would have built. I was about to protect a
fourth noun.

```
W.1.3.2   the brief's browser-assertion count was two below what the battery emitted
W.1.3.2a  §10's count disagreed with the stamped one in §0 of the same document
W.1.3.2b  the brief's text-asset count was two above what the shipped gate reported
```

Three rounds, three protected nouns — `vectors`, `tests`, `assertions` — and each time the next
number to drift was one nobody had thought to name. **The list can only ever contain the mistakes
already made.**

So the noun list is derived. `tools/emit-measurements.mjs` builds one receipt from the gates' own
reported lines; `tools/check-measurement-prose.mjs` takes its patterns **from that receipt**. A
gate added tomorrow is guarded tomorrow, by nobody remembering anything.

**Two things I got wrong building it, both caught by the thing itself:**

- **The first version keyed on `\d+ <noun>` and flagged three innocent sentences** — "100 refused
  claims" (the host battery's *workload*), "leaked by 30 refused commands" (a description of a past
  defect), and "3 caught · 3 not" (a labelled *counterfactual*, showing what the old bracket
  produces). `refused` and `caught` are ordinary English, and a guard that fires on them teaches
  you to phrase around it. Distinctive nouns keep the bare form; generic ones require the **gate's
  summary shape**, which prose can only match by copying the gate's own line — which is the thing
  being forbidden.
- **The receipt counted itself.** `text_assets` went 110 on a first run and 111 on every run after,
  because `measurements.json` is a text asset written by the gate that counts them. Same defect as
  the one below, arriving *from the fix for it*.

### 14.3 · Why 108 and 110 were both right, which is worse than one being wrong

The two extra files were `ampd/priv/data/world.json` and `ampd/priv/data-elsewhere/world.json` —
**runtime state**. They exist only after the suite has run and are excluded from the artifact. So
the gate reported the larger figure in a working tree and the smaller one in the shipped bundle:
the same check measuring two different things depending on whether anyone had run the tests.

*(That sentence originally quoted both numbers, and the new prose scan refused the release over it
— the third time this round it has caught me writing a measurement while explaining measurement
drift. I am leaving the note in because a guard that has never inconvenienced its author is a guard
nobody has tested.)*

A figure that depends on the observer's history is not a property of the release. Both excluded
now, and the count is stable across runs and identical in tree and artifact — which I verified by
running it in both, and by deleting the receipt and running it again.

### 14.4 · The count harness reported a number correctly and the thing it counted wrongly

Also right, and it is the same defect as calling four claim kinds "stale" — one round earlier, in
this same brief.

`sabotage-counts.sh` incremented a variable named `REFUSED` for every met expectation and
summarised "7 refused", while its own output contained:

```
refused    a clean tree (accepted, as it must)
```

A contradiction printed in full and read past. Three of the seven are not refusals — the baseline
is an **accept** and the hand-edited marker is a **restamp**, and that second distinction is
load-bearing: `stamp-counts` is documented as *reverting* a hand-edited number rather than failing
on it, because the marker is the tool's own output and it owns it.

```
accepted   a clean tree
refused    a bare assertion count in the current review brief
refused    a bare vector count in the README
refused    a bare test count in the ampd README
restamped  a hand-edited marker is restamped, not refused
refused    a failing battery still gets its number stamped
refused    a battery that stops reporting its count
```

and a summary that names all three outcomes plus `unexpected`, which is the only one that fails the
gate.

### 14.5 · What is in W.1.4, not here

The at-most-once closure, as you sequenced it. Runtime untouched in this artifact — that claim is
true of these bytes and is the reason they are separate bytes.

One consequence worth stating plainly: **this artifact's BEAM gate can still refuse at random**,
because the defect is still present in it. If you build it and `mix test` fails once, that is the
15% and not a regression. W.1.4 is where that stops being true.
