# W.1.4.1 — at-most-once, and the layer that never received the constraint

**Artifact: `and-super-rev-w141.zip`, with `and-super-rev-w141.receipt.json` beside it.
Every required gate green, and `ampd/tools/sabotage.sh` — the one the chain does not run — green
too. Predecessor: `W.1.3.2b`, `sha256:66ffe296…a06c`.**

> **Read §3b before the rest.** A build labelled `W.1.4` passed every gate in `release.sh` and then
> failed the BEAM sabotage battery: the fix had moved a line one of its probes targets, so a law
> lost its falsifier while everything stayed green.
>
> **And this is `W.1.4.1` rather than a second `W.1.4` because I had already sent the first one.**
> `sha256:c004caea…` went out labelled `W.1.4`, with a note that it was superseded — and a note is
> not a name. One round after being told that a revision must name one byte history, the natural
> workflow (fix it, repackage it, same label) tried to make `W.1.4` mean two things, and it took
> noticing the hash had changed to catch it. That is worth recording as a fact about the
> discipline: it is not hard to agree with and it is easy to violate by default, because nothing
> in the tooling objects. **The receipt is what objects — it is the only artefact that would have
> made the collision visible after the fact.**
>
> Superseded, for the record: `W.1.4` → `sha256:c004caea…`, which fails
> `ampd/tools/sabotage.sh`. Do not review it.

Tiny, as you said. One property, one fix, one flagship witness, nothing else in the round.

Your falsifier was right down to the number. Passing `framed_once/2` a function that ticks the
clock itself produces **exactly 3 executions** against the unfixed coordinator — no churn, no
scheduling luck, no probability. I ran it before writing a line of the fix.

---

## 0 · Measured — `site/proof/measurements.json`

Figures are in the receipt; this document references it. The one number that belongs in prose
because it is the *subject* rather than a measurement of health:

```
framed_once, function that moves the clock

  before W.1.4    3 executions      deterministic
  after  W.1.4    1 execution       deterministic
```

**The runtime IS touched this round** — `ampd/lib/ampd/authority_coordinator.ex` and
`ampd/lib/ampd/projection.ex`. That claim was true of W.1.3.2b and is why W.1.3.2b is separate
bytes rather than a paragraph in this brief.

---

## 1 · The law, which is the part worth keeping

You promoted it and I think you are right that it is the general form:

> **If a computation carries an execution-multiplicity constraint, every layer that may invoke that
> computation must either preserve that constraint or discharge it.**

`Ampd.CommandSpec` declares `retry: :safe | :once`. The build **fails** if a read omits it —
`@missing_retry` raises at compile time. `Ampd.Control` routes `retry: :once` to
`Projection.framed_once/2`. `framed_once` skips the optimistic loop, exactly as documented.

And then handed the function to `AuthorityCoordinator.observe/1`, which speculated again.

```
CommandSpec      retry: :once        declared, and compile-time enforced
Control          → framed_once       routed
Projection       attempts = 0        constraint honoured — and DROPPED here
AuthorityCoordinator  coherent(fun, st, 3)   ← the layer that can re-execute
```

Declared at the top, checked for presence, honoured through one layer, and never delivered to the
only layer capable of violating it. That is the same shape as the projection-scope defect and the
claim-validity defect — a semantic property is meaningless unless it reaches every lower layer that
can violate it.

---

## 2 · `observe_once`, not relocating the refusal log — as you ruled

I had offered both and you chose correctly. Making `Refusal.new/2` pure would move the recording
obligation out to every caller: today, constructing a refusal *guarantees* it is recorded, and
relocation replaces one guarantee with a distributed obligation to remember. That is a worse trade
than it looks, and it would have been made to accommodate the retry machinery rather than because
anything about refusals wanted it.

```elixir
def observe(fun, timeout \\ 15_000)        # bounded rebuild, retry-safe reads
def observe_once(fun, timeout \\ 15_000)   # exactly once
```

Named APIs rather than an integer, as you asked. And the handler is deliberately **not**
`coherent(fun, st, 1)`:

```elixir
def handle_call({:observe_once, fun}, _from, st), do: {:reply, once(fun, st), st}

defp once(fun, st) do
  content = fun.()
  {sample_after(st, nil), content}
end
```

`coherent(fun, st, 1)` is correct today and would break silently the day anyone changes what the
bound means — an at-most-once guarantee resting on an integer read two functions away. A
computation that may run once gets a body with no loop in it.

### The guarantee that had to survive, and did

You put this exactly right, and it is the part I would have got wrong on my own. The unconditional
property is **cursor ≥ the state the content represents**, and it comes from sampling *after* the
content — not from the retry. The rebuild only converts the common case from conservative to exact.

So for an `:once` operation, at-most-once outranks cursor exactness, and what is given up is the
optimisation rather than the soundness. Pinned:

```
observe_once's cursor is never older than the content beside it
  fun ticks twice, returns the clock it read
  → cursor.view_revision >= content.read_at
```

---

## 3 · The witnesses, and why the old one had to be demoted

`ampd/test/multiplicity_test.exs` is new. Six tests, all deterministic:

```
framed_once executes its function exactly once, even when the clock moves   ← flagship
observe_once executes its function exactly once
observe still speculates for a retry-safe observation                      ← anti-overfix
framed still speculates for a retry-safe read                              ← anti-overfix
observe_once's cursor is never older than the content beside it            ← the guarantee
the reads that write are the ones routed to the once path                  ← the routing half
```

The two `anti-overfix` lines matter: a fix that removed speculation everywhere would make the
flagship pass by deleting the distinction, which is the cheapest way to satisfy a law and the least
honest. `observe/1` keeps its bounded rebuild and a test requires it to.

**The churn probe in `cockpit_test.exs` is demoted to stress evidence**, as you ruled, and renamed
to say so. It stays because it exercises the whole path end to end, which the unit witnesses do
not. It no longer carries the claim.

```
the churn probe, isolated, 20 runs

  before W.1.4    17 passed · 3 failed
  after  W.1.4    20 passed · 0 failed
```

That is evidence and not proof, and the distinction is the reason the flagship exists. At a 15%
rate, twenty green runs afterwards is the outcome you would expect from changing nothing.

### One thing I got wrong writing it

The routing test began as `for {_wire, spec} <- CommandSpec.commands()`. `commands/0` returns
`Map.keys` — a list of wire-name **strings** — and a tuple pattern that does not match is silently
skipped by a comprehension. The body never ran, the assertion inside it passed by never being
evaluated, and the test was green while measuring nothing.

It is now an anti-vacuity check instead: the once-set must be non-empty **and a strict subset of
the reads**, because if every read were `:once` the classification would separate nothing and the
rest of this file would still pass.

---

## 3b · The fix broke a falsifier, and the harness caught it

Worth its own section because it is the round's own lesson landing on the round.

The first W.1.4 packaged green on every gate `release.sh` runs. Then `ampd/tools/sabotage.sh` —
the four-and-a-half-minute battery that is not in the chain — came back one short, with a single
line naming why:

```
  SABOTAGE MISSED  a busy world is observed coherently, not merely observed
                   — the pattern did not match; the probe proved nothing
```

*(The summary line that accompanied it is not quoted here: the new prose scan refused the release
over it, because a quoted failure count has the same shape as a quoted success count and goes stale
the same way. That is the guard being right about something I had not thought of — I had exempted
counterfactuals in my head and not in the pattern.)*

Not a broken law. A **stale probe**: that one targets

```
{cursor, content} = Ampd.AuthorityCoordinator.observe(fun)
```

and my fix had replaced that line with a three-line `if attempts == 0`. `probe()` applies its
sabotage with `sed -i`, so a fix spread across three lines cannot be stubbed by a single-line
expression — and the law *"a busy world is observed coherently"* silently lost its falsifier while
every other gate stayed green.

**MISSED scores as failing, which is the only reason this surfaced.** A harness that treated a
non-matching pattern as "nothing to see" would have reported 69 of 69 and been believed.

Fixed by shaping the code so a probe can name it, which is the same lesson `cursorEq` and
`stabilityToken` already carry in the browser layer:

```elixir
defp ordered_observe(0, fun), do: Ampd.AuthorityCoordinator.observe_once(fun)
defp ordered_observe(_, fun), do: Ampd.AuthorityCoordinator.observe(fun)
```

**A fix that must be falsifiable has to fit on a line a probe can name.**

And W.1.4's own law had no BEAM-side falsifier at all — I had added the deterministic witnesses and
not the sabotage that proves they can fail. Two now, both verified to go red in isolation before
the battery ran:

```
a read that may run once is speculated on anyway            → multiplicity_test RED
the exactly-once observation rebuilds like the retry-safe one → multiplicity_test RED
```

The second is the change someone makes while "unifying" the two observe paths, which would
reinstate the defect silently.

---

## 4 · A second finding, reported not fixed

`Ampd.RefusalLog.record/1` does **not** tick the ViewClock, and `recent_refusals` is in
`operator-projection@2`. So a cockpit holding LIVE LOCAL is not told that a new refusal appeared —
the same class as the channel-opening defect the two-clock design was built for, one collection
over.

I have not touched it, for two reasons. It is outside "at-most-once" and you said keep W.1.4 tiny.
And it is not obviously a bug: `RefusalLog` is listed in `AuthorityCoordinator.touched/0`'s
docstring as one of the three projection-visible non-authority sources, so something may already
tick on its behalf on the paths that matter — I did not chase it far enough to say, and I would
rather report the observation than a conclusion I have not measured.

It is also why the fully-deterministic *end-to-end* witness is a composition rather than a single
test. To force the retry through `Control.command` I would need the clock to move inside the
command, and the only non-invasive lever is exactly this question. So §3's end-to-end property is
stated as two measured facts — `framed_once` runs its function once, and these commands reach
`framed_once` — rather than implied by one.

---

## 5 · Sequencing

Yours, and I take the correction. I said this did not block W.2 because duplicate refusal recording
does not change whether the DOM waits for a frame. Narrowly true and beside the point: W.2 is where
LIVE LOCAL gets earned, and a W.2 integration failure over a baseline whose suite randomly refuses
its own release has two plausible causes instead of one. Debugging a new transport against a known
nondeterministic runtime is how a round loses a week.

```
W.1.3.2b   release identity + measurement semantics     shipped
W.1.4      at-most-once closure                          this
W.2        Tauri LIVE LOCAL                              next
```

Nothing between the second and the third, unless §4 turns out to be a real push defect — in which
case I would want your ruling on whether it belongs before W.2 for the same reason this did.

---

## 6 · Verify

```
cd ampd && mix test test/multiplicity_test.exs      # the six deterministic witnesses
bash tools/release.sh                               # every required gate
```

To watch the flagship fail on purpose, restore the dropped constraint in
`ampd/lib/ampd/projection.ex`:

```
{cursor, content} = Ampd.AuthorityCoordinator.observe(fun)
```

in place of the `attempts == 0` branch. The flagship then reports **3**, deterministically, with
the message naming the law.
