# W.2.3.3 — link liveness is not projection maintenance

**Super (CD) · the cockpit · the round after bounded recovery**

> **THE LAW**
>
> **Evidence that the link is alive may end a silence. It may not sustain a
> claim.** A page must never treat a message it can still hear as proof that
> what it is showing is still being maintained.
>
> **THE COROLLARY THAT MAKES IT MECHANICAL**
>
> A liveness signal is evidence about the path it travelled. Where it can
> travel a **different path** from the thing it vouches for — and here it
> demonstrably can — it is not evidence about that thing at all.
>
> **AND ONE LAYER DOWN**
>
> A message is evidence for the **position it was issued from**. A stale
> completion, a stale teardown, a stale sink: each still knows which function
> to call. None of them has any standing to call it.

---

## 0 · Verdict on your W.2.3.3 brief

Accepted in full, and all four targets are closed. Two of them are worse in
the code than in your report, one of them would have shipped a new defect if
implemented as specified, and one had to move to a different layer to be
falsifiable at all. Those four differences are the content of this brief;
everything else is your design.

| your target | state | the difference |
|---|---|---|
| **P0** exhaustion must revoke the projection claim | closed | it is an **authority** defect, not a display one — see §1 |
| **P0** split the clocks | closed | the second deadline is **unreachable at the shipped retry depth**, so it needed its own gate to be falsifiable — §3 |
| **P1** candidate-deadline contradiction | closed | there is now **no clock write in `bind` at all**; held statically, because there is no dynamic window — §5 |
| **P1** bind/unbind stream generation | closed | **a generation alone breaks the reload.** It is `{page, generation}` — §4 |

---

## 1 · The defect, confirmed — and it is an authority defect

Your reading of `cockpit.js` was exact. `deliver()` wrote `c.heard_at =
Date.now()` before it had looked at what the message *said*; `leaseTick()`
consulted that same field to decide whether the world on screen was still
maintainable; and the Rust heartbeat has carried `in_flight.exhausted` since
W.2.3.1 with nothing in the page ever reading it.

So the host could state *I have abandoned delivery of a newer state*, and the
heartbeat carrying that statement was, by arriving, the thing that stopped
the page acting on it. Indefinitely — the beat interval is a quarter of the
lease, so the deadline could never expire while the link answered.

**What makes it worse than a stale screen.** The withdrawal path does two
things, and only one of them is about display: it clears the world region
*and* it disables every `button[data-intent]`. So the state W.2.3.2 sat in
was not "showing something old". It was **offering authority — revoke this
grant, deny this request — against a projection the runtime had positively
said was superseded and undeliverable.** The grant ids under those buttons
came from a state the host had stopped maintaining. That is the exact failure
W.2.1 built the two-gate ACL to prevent from the outside, arriving from the
inside.

Your framing is the right one and I have adopted it as the round's law:

```text
   link is alive          ≠          displayed projection is maintained
```

One field held both, so the mechanism for the second was governed by evidence
about the first.

---

## 2 · Two clocks, two deadlines, one statement

```text
   link_heard_at     ← any message at all              → silence
   projection_at     ← a message that ATTESTS the      → unmaintained
                       projection: a frame of any
                       sequence, or a heartbeat whose
                       valve holds nothing this page
                       has not seen
   (no clock)        ← a heartbeat reporting an        → exhausted
                       abandoned frame newer than
                       anything applied                  immediately
```

The attestation predicate is the whole design, so it is worth stating
precisely. A heartbeat attests maintenance **iff** its `valve.in_flight` is
either absent or carries a sequence this page has already applied.

- `in_flight` absent → the page is current. This is the quiet world, and it is
  why the second deadline does not fire against a healthy cockpit with
  nothing happening in it.
- `in_flight.seq <= applied` → the only thing outstanding is *our own
  acknowledgement*. The frame path works; the ack was lost. Attested.
- `in_flight.seq > applied`, `exhausted` false → repair is in progress. This
  beat attests **nothing**. If the repair never lands, `projection_at` goes
  stale and the second deadline ends the claim.
- `in_flight.seq > applied`, `exhausted` true → not a deadline at all. The
  host has said it gave up. Withdraw now.

**Three withdrawal reasons, and the person is told which**, because they are
three different states of knowledge: *I have heard nothing* / *I am hearing
you and nothing you have said confirms this is current* / *you told me you
gave up*. A screen that cannot distinguish "I do not know" from "I know it is
stale" is back to hope, which is the sentence at the top of `cockpit.js`.

**The `seq > applied` scoping matters and is not decoration.** Without it,
every ordinary frame in flight at the moment a heartbeat is generated would
read as a maintenance failure, and a busy world would withdraw itself. With
it, a false positive requires the host to hold a frame the page has never
seen for a whole lease — which is the fault, by definition.

**And the two are ordered, which bounds what the first one buys.** Under the
exact fault you specified, deleting the exhaustion path does *not* restore
W.2.3.2's behaviour: the same stuck frame stops every heartbeat attesting, so
the projection deadline catches it about a lease later and withdraws as
`unmaintained`. Measured, both ways, before the probe for it was written —
which is why that probe names the withdrawal's **reason** and the fact that
neither deadline had expired, and not "it withdrew" or "it recovered", both of
which survive the deletion.

So what the exhaustion path is actually worth is: **the page acts on a
statement instead of waiting out a timeout** — sooner, and able to say which
of the three things happened. That is a smaller claim than "without it the
cockpit lies forever", and it is the true one. The thing that closes W.2.3.2's
hole is the *clock split*; the exhaustion statement is what makes acting on it
prompt and legible.

---

## 3 · Why the two deadlines are not redundant — and why the second needed its own gate

Your P0 asked for the clocks to be split. Implemented naively that produces a
mechanism **whose falsifier can never run**, which is the thing this arc
refuses to ship.

At the shipped constants a frame the page never applies is marked `exhausted`
about two and a half seconds after it is first sent — comfortably inside the
lease. So the exhaustion statement always arrives first and the projection
deadline behind it is unreachable. A sabotage collapsing the two clocks would
have gone green.

`RETRY_LIMIT` is therefore settable by `SUPER_COCKPIT_RETRY`, and it is a
**depth, not a mode** — the same rule and the same wording as
`SUPER_COCKPIT_QUEUE`: nothing anywhere branches on its value, and the code
path at the deep setting is the code path at the shipped one.
`tools/cockpit-maintenance.mjs` runs the shipped product at a depth where the
host is still visibly retransmitting, `exhausted` stays false throughout, and
the only thing in the program that can end the stale claim is the second
deadline. It asserts the depth reached the host before it asserts anything
else, because a gate that silently ran at the default would be a slower copy
of the battery's exhaustion witness — passing, and measuring the wrong
mechanism.

### The transport asymmetry, which is why this is not a contrived fault

The model — heartbeats through, frames swallowed — is not an arbitrary
partition of the message space. **Tauri picks a Channel transport by payload
size.** `tauri-2.11.5/src/ipc/channel.rs`:

```text
   json.len() < MAX_JSON_DIRECT_EXECUTE_THRESHOLD   (8192)
       webview.eval(runCallback(…))                        ← direct

   otherwise
       park the body in ChannelDataIpcQueue
       webview.eval("invoke(fetch…).then(runCallback).catch(console.error)")
```

A heartbeat is a few hundred bytes and always takes the first. A frame
carrying a world with traffic in it crosses the threshold and takes the
second — which is why W.2.3 built `tools/cockpit-bigframe.mjs` at all.

**This is measured now, not argued.** That gate wraps the raw Channel
callback and records both payloads from the *same run against the same
world*: the heartbeat lands under the threshold, the frame over it. The
instrument is named in the check rather than glossed — the payload reaches
the page already parsed, so it is re-serialised rather than read off the
wire, and the two differ only in string escaping. That is adequate for the
question, which is not *how many bytes* but *which side of 8192*, at margins
better than twentyfold and twofold.

So **the signal that vouches for the stream travels a different path from the
payload it is vouching for, and the two paths have independent failure
modes**: the direct path is wry#1644 (`run_javascript`'s asynchronous result
dropped unread — I re-checked, still open, and current wry still calls
WebKitGTK `run_javascript` and only inspects the result when a callback
exists), the fetch path ends in `.catch(console.error)`.

Frames lost while heartbeats arrive is therefore the *expected* shape of a
partial transport failure in this product, not the exotic one. That is the
corollary at the top of this brief, and I think it generalises past cockpits:
a health check that does not travel the path it certifies certifies the health
check.

---

## 4 · The stale locus — and a generation counter alone would have broken the reload

Your P1 was right about the hazard and right that the fix is structural. Two
corrections.

**First, the premise in the code was false, not merely unproven.**
`main.rs` said `unbind_frame_stream` was *"the symmetric partner of
`bind_frame_stream`, on the same control lane, so it cannot overtake or be
overtaken by a bind."* That is not a guarantee the mechanism provides. A
`SyncSender` orders the messages **already in it**. Getting there is two
unordered hops per command: Tauri answers an async command with
`crate::async_runtime::spawn` (`tauri-2.11.5/src/ipc/mod.rs`,
`InvokeResolver::respond_async`), and `control()` then does its blocking send
inside `spawn_blocking` — a pool with no ordering between tasks. Two invokes
the page issued in order are two independent futures racing to the lane.

This is the W.2.1 defect shape exactly: **prose describing a boundary that
does not exist reads as coverage and is worse than no boundary.** The comment
now says so, at the site, in those terms.

**Second, `bind(epoch)` / `unbind(epoch)` as you specified it ships a new
defect.** A page-owned counter is reset by a reload, so a host refusing
anything at or below the generation it already holds refuses the reloaded page
its stream **permanently** — a cockpit that survives a dead WebKit transport
and dies of `F5`. The battery's oldest W.2.1 check (*a sink that binds after
the world is already live is brought up to the current state*, driven by a
real page reload) would have caught it, and that is a good outcome for the
harness and a bad one for the design.

The counter collapses two facts, in the same way `heard_at` did:

```text
   which page is speaking          ≠      which attempt by that page
```

So the identity is `{page, generation}` — a per-page-instance nonce plus a
counter — and the comparison is asymmetric on purpose:

```text
   bind     refused iff  same page AND generation <= the one held
                         (a DIFFERENT page is always the newer locus)
   unbind   obeyed  iff  exact match
                         (this is the message that destroys a working
                          stream; a destructive instruction from a position
                          that no longer exists is refused, not interpreted)
```

Refusals ride the heartbeat as `valve.stale_binds` / `valve.stale_unbinds`
beside the binding actually held, for the same reason `exhausted` does: it is
the only thing that escapes a closed valve, and a page that could not see a
refusal has no way to tell a stale unbind that was correctly ignored from one
that was obeyed and quietly killed its stream.

**And the page refuses its own stale completions.** `bind()`'s continuation
now checks that the generation it was issued from is still the live one before
writing anything — including before painting the *this webview may not bind
the frame stream* paragraph, which a stale rejection would otherwise have
written over a working cockpit.

Your formulation of the position is the one I built to, and I think it is the
right vocabulary for the Motor layer too:

```text
   webview × world incarnation × projection basis × stream generation
           × authority surface × transport binding
```

---

## 5 · The candidate deadline — the code and the brief disagreed

You reported that `nextCandidate()` writes the clock at the attempt and
`bind()`'s success arm writes it again on resolve, so a slow bind mints extra
lease time. Confirmed, and the sharper statement is that **W.2.3.2's own
comment two functions above claimed the opposite**: *"the candidate's lease
starts now, not when the invoke resolves — else a slow `bind` would be charged
to the channel it produced."* The comment described the intended mechanism and
the code did the other thing.

`bind()` now writes **no clock at all**, so there is no line to get right.

**Falsified statically, and that is the honest place for it.** A bind that
resolves in a millisecond moves the clock by a millisecond; there is no
dynamic window in which to witness it, and a witness built on saturating the
lane to make the bind slow would be measuring the saturation. The property is
not "the clock has the right value", it is **which lines are allowed to write
a clock** — and that is checked by counting the assignment sites in
`tools/check-webview-acl.mjs`:

```text
   link_heard_at    deliver (a message arrived)  ·  nextCandidate (attempt)
   projection_at    deliver, and nowhere else
```

The probe puts the assignment back into `bind()`'s success arm and the count
goes to three. Same argument, and the same layer, as W.2.3.1's *only a frame
may end a withdrawal*.

`heard_at` is additionally **refused by name**, like `windows` and
`try_send` before it: the substitution that reopens this class is one
identifier, under which every comment in the file goes on describing a
distinction that has stopped existing.

---

## 6 · The witnesses

### The exhaustion witness (`tools/cockpit-battery.mjs`)

Frames swallowed at `window.cockpit.deliver`, **scoped to the channel live
when the fault is armed**; heartbeats passed straight through. A real world
change is forced, so there is a state the person is entitled to see.

Four things had to be true for it to be evidence:

1. **The host must actually say it.** Asserted first and separately: a
   heartbeat must carry `in_flight.exhausted` with a sequence past `applied`.
   Without that clause everything below is measuring a silence, which is the
   case W.2.3.2 already covered.
2. **The link must be alive at the instant of the withdrawal.** `withdrew_at`
   is sampled **by the page, inside `withdraw()`** — reason, the age of both
   clocks, the lease, the beat count. A harness reading `link_heard_at` a
   round trip later reads a page that has been receiving heartbeats in the
   meantime. The check requires the link age to be *inside* the lease: if the
   link had gone quiet, this is the W.2.3.2 mechanism firing under a new name
   and the new one is unproven.
3. **The DOM state is latched causally, not polled.** Because the swallow is
   scoped to one channel, the candidate the withdrawal builds is healthy and
   the world is back within one IPC round trip — a few hundred milliseconds.
   A harness polling `withdrawn` on its normal interval would routinely arrive
   after the recovery and report that nothing happened. **A `MutationObserver`
   is not a faster poll**: its callback is a microtask at the end of the task
   that mutated the DOM, and an arriving frame is a later task, so it reads
   the region `withdraw()` just cleared *before anything can refill it*, by
   construction rather than by being quick.
4. **The recovery must happen**, on a fresh channel, to a sequence later than
   the one abandoned. A page that withdraws and does not recover has traded
   one wrong state for another.

### The maintenance witness (`tools/cockpit-maintenance.mjs`)

Same fault, at `SUPER_COCKPIT_RETRY` deep. Three clauses make it *this*
mechanism and not another: the link had not gone quiet, the host had **not**
given up (`exhausted` false, retransmission visibly in progress), and the
projection clock was the one past its deadline. Any of the three failing means
some other path produced the withdrawal.

### The stale-binding witnesses (`tools/cockpit-battery.mjs`)

Measured through the **heartbeat**, not through the world moving: if the host
had obeyed a stale unbind it would hold no sink, and `beat()` returns early
with no sink — so beats continuing *is* the statement that the stream
survived. That avoids depending on an intent moving the projection cursor,
which late in a run it may not; that dependency cost W.2.3.1 four checks and
is written down there.

And the pair that stops it being vacuous: **the same teardown, addressed to
the binding actually held, must still stop the host.** Without it, both
refusal checks pass against a host that ignores every unbind — which would
also undo W.2.3.2's terminal state, in a way no assertion in the file would
name. The page then rebinds under a new generation and the host accepts it,
which is the reload argument of §4 measured rather than asserted.

### A BEAM falsifier that had been a coin flip for several rounds

The first W.2.3.3 chain was refused — not by anything in this round's code,
but by `ampd/tools/sabotage.sh` reporting **NOT A FALSIFIER** for a W.1 law,
*a busy world is observed coherently, not merely observed*. The bracket
verified the tree was clean and the chain stopped, which is the gate behaving
correctly.

The probe deletes the ordered-observe fallback in `Ampd.Projection`, so a
frame's `grants` and its `authority_snapshot` — read five registry calls
apart in `Projection.operator/0` — can be assembled either side of a
mutation. The test drives that with a churn process and forty reads.

**I measured it before changing anything, and then measured the fix, and the
first diagnosis was wrong.** Both numbers are here because the wrong one is
the more useful half.

*First diagnosis.* The churn was `Enum.take(20_000)` — a budget, not a
duration. Forty operator projections under contention each retry the
optimistic seqlock before reaching the fallback, and each builds the entire
operator map; the two costs are the same order of magnitude, so the churn
could drain first and leave the remaining reads against a quiet world. Made
the loop unbounded (killed twice — the second from `on_exit`, restoring the
leak-safety `Enum.take` was providing by accident) and added an assertion
that the coordinator's operation count really advanced across the read
window. **A witness whose fault may silently not have happened is not a
witness: it reports the absence of a fault as the presence of a fix.**

*And it did not fix the flake.* Re-measured with the churn guaranteed live:
still missed. Baseline across both measurements is **two misses in twenty
sabotaged runs at forty reads.** So the cause is not the fault's presence,
it is the *window*: a read only tears if a mutation falls between
`Projection.operator/0`'s two reads of the grant registry — five entries
apart — and a churn that revokes and re-grants one domain is invisible unless
an odd number of transitions lands inside it. A read whose optimistic seqlock
happens to settle never reaches the sabotaged fallback at all. Both are
per-read coin flips.

So the answer is the exponent, sized from the measurement rather than from
taste:

```text
   (1 - p) ^ 40  ≈ 0.10        →   p ≈ 0.056
   (1 - p) ^ 200 ≈ 0.00001
```

The read count is 200. Re-measured at that depth: **sixteen sabotaged runs,
sixteen falsifications, no misses**, and the healthy direction stays green —
which matters, because the test also asserts that no read *starved* under
load, and five times the reads against an unbounded churn is where that would
show.

**The honest limit of the claim: the bound is computed, and those runs are
consistency with it rather than proof of it** — sixteen green runs cannot
distinguish one-in-a-hundred-thousand from one-in-a-hundred. A deterministic construction would need a
synchronisation point inside `Projection.operator/0`, which is a test seam in
the product, and this runtime refuses that more strongly than it dislikes an
exponent. The cost is that the file's runtime roughly doubles, in fourteen of
the BEAM probes.

The implication for earlier rounds stands either way: **this law has been
recorded as falsified in every previous receipt on evidence that was about
ninety percent likely rather than certain.** The round that finally rolled
the other way was this one.

This is out of W.2.3.3's scope and I did it anyway, because the alternative
was re-running the chain until the coin came up heads, and that is the one
thing this arc is built to refuse.

### A fix can invalidate an earlier round's witness by making its failure mode recoverable

The second chain got all the way to the cockpit probes and was refused by one
of them: *an unacknowledged frame is sent again* — green for three rounds —
came back **NOT A FALSIFIER**. This one is worth reporting because the cause
is W.2.3.3 itself, and nothing was wrong with the fix under test.

That probe disables retransmission and required a named check, *and it is sent
again rather than wedging the stream forever*, to go red. Under W.2.3.2 it
did, and correctly: the swallowed frame stayed outstanding, `exhausted` never
became true (one attempt, never three), heartbeats went on arriving, and the
single clock they refreshed meant the lease never fired. The stream really
was wedged forever and the frame counter really never moved.

**The projection deadline ends exactly that state.** With retransmission
disabled the page now notices within one lease that nothing has attested its
projection, withdraws, rebinds, and is sent the current world on a fresh
channel — so the counter moves, and a check that counts frames reports the
retransmission fix as working while it is switched off.

The repair is one clause: **a retransmission does not rebind**, so the check
names the channel. *Repaired* and *replaced* are now separately falsified,
which is the reason both mechanisms exist.

The general form is worth having, because it will happen again as Super grows
recovery paths:

> A fix that makes an older witness's failure mode recoverable has not
> repaired that witness — it has made it ambiguous. Every check that says
> *and then it came back* has to name **by what route**.

It also says something about the harness: the probe was the only thing that
could have caught this, no gate on the fix itself would have, and it cost a
chain to hear. That is the trade this arc has already accepted.

### Two harness defects this round found in itself

- **The ACL check's comment stripper was line-based** — it dropped lines
  whose first non-space character was `*`, `/*` or `//`, which is not what a
  comment is: the prose in `cockpit.js` wraps *without* a leading `*`, so the
  second and later lines of every explanation counted as code. It was harmless
  for the three W.2.3.1 checks (measured both ways rather than assumed) and
  not harmless for the new check that refuses `heard_at` by name, which fired
  on the sentence explaining why the name is refused. Block comments are now
  removed as spans. **A scan that cannot tell the account of a defect from the
  defect makes the fix unwritable** — the `try_send` check says exactly that
  and then did the opposite thing.
- **A probe went dead from a signature change.** `Delivery::bind` took a
  second parameter, so probe 9's `sed` address range stopped matching and the
  substitution inside it ran over the whole file, landing on `unbind` — which
  clears the same field for the same reason, so it would have looked like a
  working probe. `SABOTAGE_DRYRUN=1` caught it in seconds. This is the third
  round in a row it has paid for itself.

---

## 7 · Measured

Every figure is in `site/proof/measurements.json`, bound to this revision, and
the receipt beside the archive carries them with the content digest. Nothing
in this document restates one — `tools/check-measurement-prose.mjs` derives
its patterns from that receipt and refuses any prose that recreates a measured
number, which is the rule three earlier rounds broke by hand-typing tallies.

New gates in the chain this round:

- `cockpit-maintenance` — the second deadline, at a retry depth where it is
  the only thing that can fire.
- the cockpit battery gains the exhaustion witness and the stale-binding
  witnesses.
- `check-webview-acl` gains the collapsed-clock refusal, the two
  assignment-site counts, and the binding-identity check on both ends.
- `sabotage-cockpit` gains five probes and re-anchors five.
- `cockpit-bigframe` gains the transport-asymmetry measurement.
- `ampd/test/cockpit_test.exs` — the busy-world witness repaired so its fault
  is guaranteed to occur and is asserted to have occurred. No test was added
  or removed; the BEAM test count is unchanged.

---

## 8 · What is still not true

- **The exhaustion path depends on the host reporting a field.** That is why
  the second deadline exists and is separately falsified; but a host that
  reported `exhausted` *wrongly* — true when delivery was fine — would make
  the page withdraw a good projection. Nothing measures that direction. The
  cost is bounded (one candidate, one lease) and the failure is honest rather
  than confident, which is the right way round, but it is not proved.
- **`stale_binds` and `stale_unbinds` are counters, not a log.** A page can
  tell that the host refused something; it cannot tell what. Bounded on
  purpose — W.2.3.2's finding was that an unbounded diagnostic inside a
  recovery is the defect in miniature — but it means a diagnosis stops at
  "one of your messages was stale".
- **The reordering that motivates §4 has no dynamic witness.** The stale
  binding witnesses construct the stale message deliberately; nothing here
  makes the two `spawn_blocking` tasks actually race. The claim being tested
  is *the host refuses a stale binding*, which is exactly what a real
  reordering would produce; the claim *a reordering can happen* rests on
  reading `ipc/mod.rs` and the tokio contract. I would rather say that than
  imply the race has been observed.
- **`SUPER_COCKPIT_RETRY` is a depth with no branch, and it is still a knob a
  gate sets.** The argument that the code path is the same is by inspection
  and by the `retry_limit` assertion in the gate, not by a falsifier.
- **An exhaustion withdrawal CLEARS the world rather than freezing it.** That
  is a deliberate choice and it has a cost: the person loses sight of the last
  known state at exactly the moment they might want to read it. It matches
  what a lost stream already does, it is what the existing assertions are
  written against, and *offering authority against a known-stale projection*
  is the failure I was more afraid of — but "show it greyed, disabled, and
  labelled as of when" is a defensible alternative I did not build, and this
  is the round to say so rather than the one after.
- **W.2.2's flagship flake has still not reproduced.** Every round since has
  been green; it is still not explained, and I have not marked it closed.

---

## 9 · How to reproduce

```bash
cd super
bash tools/release.sh            # every gate; refuses without mix/cargo/tauri-driver
```

Individually, from the release root:

```bash
node tools/cockpit-battery.mjs        # the flagship + the exhaustion and binding witnesses
node tools/cockpit-maintenance.mjs    # the second deadline
node tools/check-webview-acl.mjs      # the static half: clocks, names, binding identity
SABOTAGE_DRYRUN=1 bash tools/sabotage-cockpit.sh   # every probe still anchored — seconds
bash tools/sabotage-cockpit.sh        # each fix disabled, each named check expected RED
```

The artifact is `and-super-rev-w233.zip` with `and-super-rev-w233.receipt.json`
beside it. The receipt carries the archive digest, the content digest —
sorted `(path, size, sha256)`, which is the value that means *the same code* —
and every gate figure from the run that produced those bytes.
