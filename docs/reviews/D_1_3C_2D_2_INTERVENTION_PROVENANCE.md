# D.1.3c·2d·2 — Intervention provenance, revised

**DESIGN ONLY. Nothing here is implemented.** No Elixir changed, no schema
file written. This revises D.1.3c·2d·1 against an external reviewer's eight
directives (J1–J8). The shape 2d·1 arrived at survives — an intervention is
an *activity* whose initiator is not a principal, recorded in
`Ampd.Receipts` — but four of its statements about this tree were wrong, and
one of them was wrong in the way that matters most: it would have shipped a
surface that silently returned nothing while a ruling said it must return
something.

---

## 0 · What 2d·1 got wrong

Stated first, because a revision that buries its corrections is a revision
that lets them be re-derived by the next reader.

| # | 2d·1 said | the source says | §  |
|---|---|---|---|
| 1 | the record carries `initiator.incarnation_ref` **and** `control_peer_ref` | there is no control-channel incarnation object in this tree; the Peer id **contains** the epoch (`peer.ex:1024`). Two names, one fact. | J1 |
| 2 | the record is "appended before the ioctl is requested, **settled to** APPLIED/REFUSED/INDETERMINATE after" (§7) | `Ampd.Receipts` has **no update-in-place operation at all**. Three writes exist: append, wholesale replace, truncate. This is not implementable. | J2 |
| 3 | interventions are "keyed on `target.actor`, so `Ampd.Projection.agent/1`'s existing `record["actor"] == actor` filter is reused *correctly*" (§6, lines 260–262) | the filter reads a **top-level** `"actor"` (`projection.ex:231`). A nested `target.actor` yields `nil`, every intervention is dropped, and the C3 ruling is unmet with no crash and no failing test. | J3 |
| 4 | INDETERMINATE is "repaired by re-observation" — the property §4's whole recommendation rests on | **re-observation does not exist.** The host's operation vocabulary has no geometry read, and `Pty::winsize()` has zero callers anywhere. | J5 |

Correction 3 is the dangerous one. Corrections 1, 2 and 4 produce a design
that cannot be built; correction 3 produces a design that builds, passes, and
is empty.

---

## J1 · One identifier, and it is the one that already exists

**The `pc-…` control-Peer id and a "control-channel incarnation" are not two
facts. They are one fact under two names, and the second name has no
referent in this tree.**

### The audit

The control Peer id is minted in one place:

```elixir
# ampd/lib/ampd/peer.ex:1024
id = "pc-" <> st.epoch <> "-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
```

`st.epoch` is set once per runtime incarnation in `init/1` (`peer.ex:118`),
under a comment (`peer.ex:103–112`) saying exactly why: *"Every incarnation
gets a fresh epoch, and every handle carries it. A supervisor restart
therefore invalidates every outstanding handle by construction."* The epoch
**is** the incarnation, and it is already inside the id.

The rest of the tree's "incarnation" vocabulary is two other things, neither
of which is the control channel: `world_incarnation` (`projection.ex:343`,
`:476`, `:553`, `:567`), and the `effect-channel@1` / carrier-channel
incarnations minted by whoever created the endpoint (`bridge.ex:164–176`,
`:213–216`). Naming a SHAPE record's initiator with an "incarnation_ref"
would either restate the epoch already in the peer id, or borrow a word that
in this tree means the bridge channel — which is the host's identity, not
the human's.

The only *other* control-channel identity in the tree is deliberately not an
id at all. `Ampd.Terminal.Presentation.resolve/3` attaches both to a
presentation:

```elixir
# ampd/lib/ampd/terminal/presentation.ex:158–162
{:ok,
 Map.merge(p, %{
   "control_peer_ref" => peer["id"],
   "control_owner" => Peer.owner_pid(peer["id"])
 })}
```

and `presentation.ex:154–157` says why the second is a **pid**: *"an id would
have to be looked up later, and by then the answer is `nil` for both 'closed'
and 'never existed'."* A pid is runtime machinery with no durability and no
meaning after the process ends. It is not a candidate for provenance and was
never proposed as one.

So there is nothing for a second field to name.

### Is the id durable enough to be historical provenance?

The reviewer's test is the right one, and the answer is a clean split.

```text
  "pc-" <> epoch <> "-" <> 8 random bytes            peer.ex:1024
         │           │
         │           └─ 64 bits from strong_rand_bytes
         └───────────── the runtime incarnation, re-minted on every restart

  THE STRING                          THE BINDING
  ──────────                          ───────────
  written into a receipt, it is       gone when the owning process dies:
  in dets under Ampd.Store.save/2     handle_info({:DOWN, …}) → drop/2
  and survives restart, restore       peer.ex:994–998
  and the world's seal surface
                                      gone when Ampd.Peer restarts: the
                                      table is `peers: %{}` in init/1
                                      (peer.ex:113–118), with no
                                      `Ampd.Store.boot` anywhere in the
                                      module — eight modules boot a
                                      durable store; Ampd.Peer is not
                                      one of them, and is absent from
                                      `Ampd.seals/0` (ampd.ex:50–65)

                                      and unresolvable from another
                                      incarnation by explicit check:
                                      resolve/1 returns nil unless the id
                                      contains the CURRENT epoch
                                      (peer.ex:695–699)
```

That split is not a defect to work around. **It is the `auid` property, and
this tree has it in a stronger form than Linux does.** `auid` authorises
nothing but is at least readable by a live process; a dead `pc-…` id resolves
to `nil` by construction, in three independent ways. The string is durable
history; the binding cannot be resurrected into a principal even by a caller
who wants to.

One honest limit: `pc-<epoch>-<rand>` says nothing about *which world* it
belonged to. The epoch is re-minted per runtime incarnation, not per world,
so the id alone cannot be located in history. That is why the record's
`basis` must still carry `world_incarnation` and `world_generation` — the
2d·1 record was right about that and it is retained unchanged.

### The recommendation

One field. `initiator.control_peer_ref`, plus `initiator.kind:
"human-control"`. The second identifier is not minted, because the measured
semantic need for it does not exist.

### The law

**This identifier is provenance and nothing else.** It authorizes nothing.
It owns nothing. It cannot receive a grant, cannot hold a capability, cannot
occupy a Locus, cannot bind a channel, cannot embody a Carrier. It is never
page-supplied. It is not queryable as an actor and no index exists that
accepts it as a key.

Two of those are already structural rather than aspirational, and should be
named as such so the next slice does not re-argue them:

- **`actor: nil` stands.** `peer.ex:1030–1032` — *"The person is not an actor:
  they hold no grants and exercise no capabilities. They are the only source
  of consent."* 2d·1 §1 adopted this from GPT's ruling; nothing here touches
  it.
- **"never page-supplied" is already enforced by the shape of the resolver.**
  `presentation.ex:140–143` — the peer is *"the **bound connection's** peer
  record, supplied by `Ampd.Control` from the channel binding — never a
  caller argument. That is the whole of the identity check: an argument the
  caller chooses is not an identity."* SHAPE resolves its initiator the same
  way or not at all.

The one law that is *not* yet structural is "not queryable as an actor," and
J3 is where it has to be kept.

---

## J2 · Two facts, because the ledger cannot be edited

**`Ampd.Receipts` has no update-in-place operation. 2d·1 §7's "appended
before the ioctl is requested, settled to APPLIED/REFUSED/INDETERMINATE
after" is not implementable in this tree and must be replaced.**

### The audit

Every write to the receipt ledger, exhaustively:

| where | what it does | who may |
|---|---|---|
| `receipts.ex:87` | `%{s \| "log" => s["log"] ++ [m]}` — **append**, seq+1 | anyone |
| `receipts.ex:92–95` | `handle_ordered({:load_state, s})` — replaces the **whole** state | ordered only (`receipts.ex:58–77`) |
| `receipts.ex:97` | `handle_ordered(:reset)` — truncates to `initial/0` | ordered only |

There is no fourth. There is no `handle_call({:update, id, …})`, no
read-modify-write of one record, and no addressing scheme that could carry
one: `Ampd.Store.save/2` writes the entire `%{"log" => [...], "seq" => n}`
blob under a single key, so a record has an id for *sorting and paging*
(`projection.ex:180`, `:209`) and no durable identity to send an update to.

`load_state/1` is not an escape hatch. It replaces everything, it is
ordered-only, and it exists for restore and for tests that need a
constructed history (`locus_test.exs:175`). Using it to amend one record
would mean re-writing the whole ledger to change one field, inside the total
order, on the hot path of a human resizing a window.

### The design

Two kinds, appended, sharing one reference:

```text
   t0   ORDERED   terminal-intervention-attempt@1
                    intervention_ref  iv_<hex>          minted here
                    kind              SHAPE
                    initiator         control_peer_ref, kind: human-control
                    target            worker_ref, worker_generation, locus_ref,
                                      target_actor                     (J3)
                    basis             world_incarnation, world_generation,
                                      attachment_ref, attachment_epoch,
                                      carrier_epoch, pty_epoch
                    request           rows, cols
                    committed         false                            (J4)

   t1   ── the request leaves the runtime ──

   t2   ORDERED   terminal-intervention-outcome@1
                    intervention_ref  the SAME iv_<hex>
                    outcome           APPLIED | REFUSED | INDETERMINATE
                    refused_as        the host's or the runtime's code, if REFUSED
                    committed         true only when outcome == APPLIED
```

The pairing is a join at read time, not a mutation at write time. Nothing in
`Ampd.Receipts` needs to change to support it.

### The law that falls out of append-only

**An ATTEMPT with no OUTCOME is a first-class durable state, not a bug.**

It is the only honest record a runtime can leave when it dies between the
request and the answer. A design that could not produce it would be a design
that lies about that cut — and this tree already refuses that trade in the
adjacent mechanism: `Ampd.Locus`'s lifecycle carries `RECOVERY_REQUIRED` with
the reason *"evidence is durable and the commit is not"* rather than guessing
(`locus.ex`, the `check` ladder).

Two consequences, both binding:

1. **A reconciler may never manufacture an outcome for an unmatched attempt.**
   It may append a *third* record saying what it observed (J5), and that
   record's subject is the world, not the attempt.
2. **The attempt is appended before the request is sent, and the send is
   conditional on the append.** If the append is refused NOT_APPLIED, nothing
   is sent. If the append is refused INDETERMINATE, nothing is sent either —
   an intervention whose attempt record may or may not exist must not also be
   performed, because the two unknowns compound into a history no reader can
   resolve. This is J6's cut 1 and it is the one cut where the safe action is
   unambiguous.

---

## J3 · The agent-projection claim is FALSE, and the same defect is already live

**2d·1 §6 (lines 260–262) says interventions keyed on `target.actor` reuse
`Ampd.Projection.agent/1`'s filter "correctly". That is false. The filter
reads a top-level `"actor"`, a nested `target.actor` is invisible to it,
every intervention would be silently dropped, and the C3 ruling — an agent
MUST be able to learn it was human-intervened — would be unmet with no crash
and no failing test.**

### The measurement

```elixir
# ampd/lib/ampd/projection.ex:230–231
def agent(actor) when is_binary(actor) do
  mine = fn list -> Enum.filter(list, &(&1["actor"] == actor)) end
```

applied to receipts at `projection.ex:256`:

```elixir
"receipts" => Receipts.all() |> mine.() |> window(),
```

and its paged twin, which is what `list_receipts` actually serves
(`control.ex:629–630`):

```elixir
# ampd/lib/ampd/projection.ex:276–277
def history_for(:receipts, nil), do: Receipts.all()
def history_for(:receipts, actor), do: Enum.filter(Receipts.all(), &(&1["actor"] == actor))
```

Both read `&1["actor"]` — one map access, at the top level, no nesting.
A record shaped `%{"target" => %{"actor" => "kestrel"}}` returns `nil` from
that access, `nil == "kestrel"` is false, and the record is dropped. Not
refused, not logged: dropped, into an empty list that renders as a normal
empty history.

### The live precedent — this is already happening today, unremarked

`Ampd.Locus.emit_receipt/5` (`locus.ex:676–707`) emits `worktree_created@1`
into the same ledger, and its actor is under a *different key*:

```elixir
# ampd/lib/ampd/locus.ex:678, :683
"kind" => @receipt_kind,          # "worktree_created@1"  (locus.ex:66)
...
"locus_actor" => lane["actor"],
```

There is no top-level `"actor"` anywhere in that map. So **every
`worktree_created@1` receipt in this tree is already invisible to
`Ampd.Projection.agent/1` and to `list_receipts` on the agent channel**, and
has been since the kind was introduced. An agent cannot see the receipt for
its own worktree.

### And that invisibility has already made a falsifier vacuous

`locus_test.exs`'s F19f walk checks that no serialized surface carries a host
path. It opens by proving its *walker* is not vacuous —

> `locus_test.exs:1593` — *"If this fails, every assertion below is
> vacuous."*

— and then asserts over surfaces without proving any of them is non-empty.
Two of those surfaces cannot contain the record under test:

```elixir
# ampd/test/locus_test.exs:1621–1625
refute_discloses!(
  Control.command(ctx.agent, :list_receipts, [nil, 50]),
  ctx,
  "list_receipts on the agent channel"
)

# ampd/test/locus_test.exs:1627
refute_discloses!(Ampd.Projection.agent(ctx.lane["actor"]), ctx, "the agent projection")
```

`list_receipts` on the agent channel routes to `history_for(:receipts,
peer["actor"])`, which filters on top-level `"actor"`, which
`worktree_created@1` does not have. The test's setup
(`locus_test.exs:1588–1589`) produces exactly one receipt and it is that
kind. The page is empty. The assertion cannot fail for the reason it was
written.

The property itself is *not* unprotected — `locus_test.exs:1607` checks
`r["receipt"]` directly, and `:1677` walks the whole stored log. What is
vacuous is the claim that the **projection surfaces** are clean, which is the
claim about the thing an agent can actually reach.

This is stated here not to relitigate F19f but because it is the same defect
in advance: a receipt kind that does not carry a top-level `"actor"` is a
receipt kind that leaves the agent-facing surfaces silently.

### The design

**Do not put the agent's actor in the top-level `"actor"` slot.** That field
has a meaning in this ledger and it is not this one:

> `gateway.ex:410–412` — *"`actor` is on the receipt so a receipt can be
> projected to the actor it belongs to. Without it the ledger is
> all-or-nothing: either every agent reads every receipt on the machine, or
> none reads its own."*

`"actor"` means **the authority principal responsible for the ordinary
capability effect** — the one that held the grant and exercised the
capability. An intervention has no such principal by construction: that is
the entire finding of 2d·0. Writing the agent's actor there would say the
agent was responsible for a keystroke it did not make, which is the
laundering this slice exists to refuse, re-entered through the schema. It
would also silently enrol interventions in every `"actor"`-keyed consumer at
once, including `Receipts.count/0` (J4).

So, three things instead:

1. **A top-level `"target_actor"`** on both intervention kinds. Explicit,
   flat, and distinct from `"actor"` in name as well as in meaning. It is a
   subject, not a principal.
2. **A separate bounded `"interventions"` surface on the agent projection**,
   filtered on `"target_actor"` and passed through
   `Ampd.Projection.window/1` (`projection.ex:208–219`) — bounded for the
   same reason `"receipts"` is (`projection.ex:243–245`): a party the agent
   does not control can grow the list without limit, and an unbounded list in
   a projection is the frame-size failure the windows exist to remove.
3. **A paged command to follow its cursor**, because *"every window a
   projection hands out has a `next_cursor`, and every one of them needs a
   command that can follow it — a cursor with nothing to give it to is a
   promise the protocol does not keep"* (`projection.ex:271–274`). Whether
   that is a new `list_interventions` or a kind parameter on `list_receipts`
   is not settled here; either works, because J4 requires the ids stay
   `rcpt-`-prefixed and the existing cursor check therefore applies unchanged.

### The prohibition

**There must be no "query all actions by initiator peer" surface.** No index
keyed on `control_peer_ref`, on any channel, for any caller — not the agent,
and not the operator projection either.

The reason is sharper than 2d·1 stated it. J1's law is that the `pc-…` id
cannot be resolved into a principal, and that is currently true *because the
only lookup, `Peer.resolve/1`, refuses it* (`peer.ex:695–699`). An index over
receipts keyed on the initiator would hand back a second lookup — one that
works after the connection is gone, works across restarts, and returns a set
of actions. That is a principal with a history, assembled out of provenance,
which is the `X-Remote-Group` shape 2d·1 §2 is about. Interventions are
reachable from their target and from the operator's whole-world view, and by
no other index.

---

## J4 · The Receipts consumer audit

**Reuse survives, and no new durable store is warranted — but a second kind
emitted during the existing flows breaks a stated invariant, and the audit
has to be done before the kind exists, not after.**

### What `Receipts.emit/1` actually guarantees

```elixir
# ampd/lib/ampd/receipts.ex:85–87
id = "rcpt-" <> String.pad_leading(Integer.to_string(s["seq"]), 4, "0")
m = Map.merge(%{"kind" => "capability-effect-receipt@1", "id" => id, "committed" => true}, m)
{:reply, m, %{st | s: Ampd.Store.save(tab, %{s | "log" => s["log"] ++ [m], "seq" => s["seq"] + 1})}}
```

`Map.merge/2` takes the **second** map's value on a conflict, so **the caller
wins on every key, including `kind`, `id` and `committed`.** The defaults are
defaults, not guarantees. That is what makes multi-kind possible at all, and
it is also three ways to break the ledger by accident.

The ledger is already multi-kind, in production, today:

| kind | emitted by | since |
|---|---|---|
| `capability-effect-receipt@1` | `gateway.ex:413` (the merge default) | the beginning |
| `worktree_created@1` | `locus.ex:66`, `locus.ex:677` | D.1.1 |

So "add a kind" is not a new mechanism class. It is a second use of one.

### The consumers, and what each one does when a second kind interleaves

**`Receipts.count/0` is `length(all())` (`receipts.ex:54`)** — every kind, no
filter — and roughly fifteen assertions across seven test files read it as
*how many capability effects committed*:

| file | lines | reads it as |
|---|---|---|
| `linearization_test.exs` | 29, 36, 63, 84, 90, 112, **138–139** | effects committed |
| `control_test.exs` | 62, 73, 79, 121, 140 | effects committed |
| `conformance_test.exs` | 94–95 | a per-fixture expected count |
| `crash_test.exs` | 50, 51, 52, 67 | survived a restart |
| `lineage_test.exs` | 77, 107 | nothing happened |
| `transport_test.exs` | 690 | n effects |
| `incarnation_test.exs` | 159, 185 | unchanged across an incarnation |
| `effect_test.exs` | 50 | exactly one |

`linearization_test.exs:138–139` is the one that matters most, because it
elevates the count to a **stated invariant with a message that names the
ledger**:

```elixir
assert Receipts.count() == allowed,
       "round #{round}: #{allowed} allowed but #{Receipts.count()} receipts — verdict and ledger disagree"
```

A second kind emitted anywhere inside that concurrent round makes that
message a lie: the verdict and the ledger would agree perfectly while the
assertion reports them disagreeing. An invariant whose failure message
misdescribes the failure is worse than no invariant.

**`List.last(Receipts.all())` readers break harder than the counts**, because
they do not compare a number — they read capability-shaped fields off
whatever happens to be last:

- `effect_test.exs:51` — `List.last(Receipts.all())["effect_ref"] == e["id"]`
- `effect_test.exs:70` — `…["idempotency_key"]` against the attempt's
- `conformance_test.exs:133`, `:139`, `:151` — `authority_snapshot_at_entry`,
  `authority_snapshot_after`, `idempotency_key`/`effect_key`

An intervention appended after a capability effect makes all six read `nil`
and assert against it.

**`crash_test.exs:53` is different and should not be lumped in.** It reads
`hd(Receipts.all())["capability"]` — the *oldest* record, not the newest — so
it breaks only if an intervention can be appended before the first capability
effect in that test's flow. It cannot today. It is listed because a helper
that fixes `List.last` by kind and leaves `hd` alone would leave a latent
one behind.

**Footprints count all kinds:** `worker_test.exs:962` and
`effect_channel_test.exs:851` both take `length(Receipts.all())` as part of
a "the world did not move" tuple. Those are *correct* as written — an
intervention IS the world moving — but they will need updating in any test
where a SHAPE happens inside a should-change-nothing assertion.

**The precedent that this was already solved once, locally, and never
generalised:** `locus_test.exs:179–180`

```elixir
defp worktree_receipts,
  do: Enum.filter(Receipts.all(), &(&1["kind"] == Locus.receipt_kind()))
```

One test file needed kind-awareness, wrote a private helper, and nothing
moved it into `Ampd.Receipts` where the next kind would find it. That is the
whole reason this audit is a section rather than a footnote.

### Recommendation: kind-awareness in the module, not in each caller

Add `Receipts.of_kind/1` and `Receipts.count/1` beside the existing pair, and
migrate the readers that mean "capability effects":

- **Must adopt:** `linearization_test.exs:138–139` (the stated invariant),
  `conformance_test.exs:94–95`, and the six `List.last` readers above.
- **Should adopt for clarity, no behaviour change today:** `effect_test.exs:50`,
  `control_test.exs:62,73,79,121,140`, `crash_test.exs:50,52,67`,
  `lineage_test.exs:77,107`, `transport_test.exs:690`,
  `incarnation_test.exs:159,185`.
- **Leave, deliberately:** the two footprints — they mean "all kinds" and
  should keep meaning it.

`Receipts.count/0` itself should stay, with a docstring saying it counts
*every* kind, so the next reader does not have to infer it from `length/1`.

### Four hard constraints on the new records

**1 · No forbidden key names, at any depth.** `effect_channel_test.exs:259`
puts `Receipts.all()` into its surfaces map, and `:266–268` walks every key
of every record forbidding:

```
channel_epoch  effect_endpoint  effect_channel  fd  descriptor
socket  endpoint  sock  request_id
```

`:271–275` additionally forbids the channel epoch and the raw fd as *values*.
The live consequence: `EffectChannel.request/5` mints a correlation id and
puts it on the wire as `request_id`, and that is the obvious thing to record
for a lost-reply investigation. **It may not be recorded under that name**,
and on reflection should not be recorded at all — it is a channel-layer
correlation token whose only use is inside the round trip that created it.
The `intervention_ref` is the durable correlation and it is minted by the
runtime.

**2 · No host path, at any depth.** `locus_test.exs:1677` runs
`refute_discloses!(Receipts.all(), …)` recursively over the whole stored log.
A SHAPE record carries refs, epochs, rows and cols, so this is satisfiable —
but it forbids ever putting a pty device path, a carrier working directory or
a socket path into the record, including inside a refusal detail copied from
the host.

**3 · The id must be minted by `Receipts.emit/1`.** `Projection.page/3`
sorts by `record["id"]` descending (`projection.ex:180`) and `window/1` does
the same (`projection.ex:209`); the resulting `next_cursor` is fed back
through `CommandSpec`'s `{:id, "rcpt-"}` declaration
(`command_spec.ex:242–251`, the cursor field at `:248`) and checked at
`command_spec.ex:691–702`, which refuses any value not carrying that prefix.
Because the caller wins the merge, supplying an `"id"` would silently replace
the minted one — and a non-`rcpt-` id would corrupt the sort *and* be
rejected as a cursor. **The intervention records supply no `"id"`.**

**4 · `"committed"` must be set explicitly on the attempt.** The merge
default is `true` (`receipts.ex:86`), so an attempt record that omits the key
inherits an assertion that the intervention committed — at the moment it was
merely requested. And this one has no falsifier: `"committed"` is *written*
at `receipts.ex:86` and **read nowhere in `lib/` or `test/`**. Nothing would
catch it. That is precisely why it has to be stated as a constraint rather
than left to a test.

### One pre-existing latent defect, recorded and out of scope

```elixir
# ampd/lib/ampd/receipts.ex:85
id = "rcpt-" <> String.pad_leading(Integer.to_string(s["seq"]), 4, "0")
```

Four digits. `initial/0` starts the counter at 7 (`receipts.ex:51`). At
`seq` ≥ 10000 the ids stop sorting:

```text
   "rcpt-9999"    9 chars
   "rcpt-10000"  10 chars

   lexicographic:  '1' < '9'   →   "rcpt-10000" < "rcpt-9999"
```

Both `page/3` (`projection.ex:180`) and `window/1` (`projection.ex:209`) sort
by that string, so past 10000 the newest page pins to `rcpt-9999` and the
cursor walks backwards into the four-digit block. It corrupts silently — no
crash, no refusal, a history that simply stops advancing.

**This is not caused by this slice and is not fixed by it.** It is recorded
because a second kind on the same counter reaches the boundary sooner, and a
SHAPE record is emitted per window resize rather than per authorized effect —
a far higher-frequency source. Two records per intervention doubles it again.

### Conclusion

Receipt reuse survives the audit. A new durable store would mean a new dets
file, a new entry in `Ampd.seals/0` (`ampd.ex:50–65`), a new boot path, a new
recovery path and a new seal semantics — five new surfaces to falsify — for a
record the existing ledger already carries two kinds of. **Design 3 stands.**

---

## J5 · Two dimensions, and the one 2d·1 assumed does not exist yet

**Attempt outcome and state convergence are different questions with
different evidence, and conflating them is how an INDETERMINATE gets
rewritten into an APPLIED that nothing measured.**

### Dimension A — what happened to *this attempt*

`APPLIED` / `REFUSED` / `INDETERMINATE`, from C1.0b·2's vocabulary
(`participant.ex:38–48`).

The classification cannot be read off the return value, because the transport
collapses the classes. `EffectChannel.request/5` returns `{:ok, observation}`
or `{:error, String.t()}`, and the string is the only discriminator:

```elixir
# ampd/lib/ampd/worktree/effect_channel.ex:417–433
case :socket.send(sock, <<byte_size(body)::big-32>> <> body) do
  :ok ->
    # **Past this line the effect may have happened.** Every failure
    # below is therefore indeterminate rather than failed, and none of
    # them may resubmit.
    await(sock, request_id, epoch, deadline(timeout), expect)

  {:error, e} ->
    {:error, "the effect channel could not be written: #{inspect(e)}"}
end
```

Below that line, three distinct facts arrive wearing one shape: the deadline
expired (`:442`), the channel closed before an observation (`:449–455`), some
other socket failure (`:458`). The source already draws the right conclusion
at `:422–424` and it is binding on SHAPE: **anything past the send is
INDETERMINATE and none of it may resubmit.**

The `:socket.send` failure at `:426–431` is the one cut where NOT_APPLIED is
provable — nothing left the runtime. The tree currently reports it
conservatively as indeterminate anyway (`:427–430`), and SHAPE should follow
rather than diverge; a second opinion about the same socket in a different
module is how two mechanisms come to disagree about one cut.

And `APPLIED` needs stating precisely, because the host does not measure what
the name suggests:

```rust
// host/src/lib.rs:340–341, 356–359
let rows = req["rows"].as_u64().unwrap_or(0);
let cols = req["cols"].as_u64().unwrap_or(0);
...
match c.pty().map(|p| p.set_winsize(ws)) {
    Some(Ok(())) => json!({
        "schema": "carrier-pty-resize-observation@1",
        "resized": true, "rows": rows, "cols": cols,
    }),
```

The `rows` and `cols` in the observation are the ones **parsed out of the
request**, echoed back. `set_winsize` (`host/src/pty.rs:298–305`) returns
`Ok(())` when the `TIOCSWINSZ` syscall returns ≥ 0. So `APPLIED` means *the
ioctl was issued on the master the host holds and the kernel accepted it* —
a real and useful attestation, and an **execution** fact, not a state
observation.

`REFUSED` is genuine and enumerable, from two layers: the host's
(`lib.rs:328` no such carrier, `:338` attachment address mismatch, `:342–347`
degenerate dimensions, `:363–366` that carrier has no terminal) and the
runtime's, which never reach the wire at all (`terminal.ex:1076–1112`:
`terminal-not-attached`, `terminal-attachment-stale`,
`terminal-not-possessed`, `terminal-stream-not-active`,
`terminal-resize-degenerate`).

### Dimension B — did the world converge

`REQUESTED_GEOMETRY_OBSERVED` / `CONVERGED` / `NOT_CONVERGED`. A statement
about the terminal, not about the attempt.

**And here is correction 4: this dimension has no instrument today.**

2d·1 §4 recommends design 3 on the strength of SHAPE being *"idempotent **and
externally observable**, so a lost reply is repaired by re-reading the
geometry and re-applying"*, and §7 says INDETERMINATE is *"resolvable by
re-observation, which is the property §4 rests on."* Measured against the
host:

```text
  the host's entire operation vocabulary          host/src/lib.rs
  ────────────────────────────────────────
    drain          :186
    start          :205
    stop           :242
    pty-attach     :261
    pty-detach     :306
    pty-resize     :327
                                    ← there is no geometry read

  Pty::winsize()  — TIOCGWINSZ, implemented    host/src/pty.rs:329–338
      callers in host/ and carrier-fixture/:   ZERO

  the only geometry read anywhere in the tree is the fixture reading
  its OWN fd 0                    carrier-fixture/src/main.rs:68, :174
                                    ← guest side, not reachable by the runtime
```

The idempotency half of 2d·1 §4's argument survives untouched —
`tty_do_resize()` still makes a redundant `TIOCSWINSZ` a true no-op, and that
is still why `Ampd.Effects`' reconciliation machinery is the wrong purchase.
The observability half is a **future** property requiring a new host
operation. Stating it as present would have shipped a reconciler with nothing
to call.

### The reviewer's example, worked

```text
  geometry before   40 × 120
  requested         40 × 120        the human asked for what it already had
  reply             lost
  geometry after    40 × 120        what a read-back would report, if one existed

  the observation proves:      the terminal HAS the desired state
  the observation does NOT prove:  this ioctl executed

  why:  tty_do_resize() returns 0 and sends no SIGWINCH when the size is
        unchanged, so "applied as a no-op" and "never applied" leave the
        world in the SAME state and are indistinguishable from outside.
```

The evidence is consistent with the ioctl having run, with it having been
dropped in the host's queue, with the runtime having died before the socket
write, and with a fourth party having resized the terminal in between. One
observation, four histories.

### The law

**INDETERMINATE is a fact about an attempt. It is never rewritten.**

A later observation may append a *third* record —
`terminal-intervention-observation@1`, sharing the `intervention_ref` —
saying the geometry now matches. It records `REQUESTED_GEOMETRY_OBSERVED`,
and that is a claim about the world at a time. It does not touch the outcome
record, and by J2 it structurally cannot.

This is not an analogy to an existing rule, it is the same rule.
`Ampd.Participant` already refuses exactly this upgrade:

```elixir
# ampd/lib/ampd/participant.ex:267–273
defp after_death(:mutate, witness) when is_function(witness, 0) do
  case run_witness(witness) do
    :applied -> :indeterminate      # ← a witness cannot promote
    :not_applied -> :not_applied
    _ -> :indeterminate
  end
end
```

with the reasoning at `:278–282`: *"A witness that says APPLIED does not make
the operation a success… Only a witness that establishes the mutation point
was never crossed narrows anything."* And the asymmetry at `:71–87`: a
witness is sound after a death, unsound after a timeout, because a timed-out
participant is alive and still holds the request. The tree already recorded
this as *a timeout is not a death*
(`project_super_terminal_possession`); a geometry read-back is a witness by
another name, over a socket instead of a process boundary, and it inherits
the constraint whole.

The narrowing direction is the only one open: an observation could in
principle establish NOT_APPLIED — but for SHAPE it cannot even do that,
because a no-op apply is invisible. So for this operation the read-back is
useful for **convergence**, and useless for **outcome**. That is worth saying
plainly, since it is the reason dimension B cannot simply be folded into
dimension A once the host operation exists.

---

## J6 · The failure cuts

Read `re-observe?` as "would be permitted once a host geometry operation
exists"; it is unavailable today for every row, per J5.

| # | cut | durable evidence that exists | what may have happened | re-observe? | reapply? | re-establish human-control authority? | what final history says |
|---|---|---|---|---|---|---|---|
| 1 | attempt append fails **before** the request | nothing, or an INDETERMINATE refusal in `Ampd.RefusalLog` | nothing was sent — the send is conditional on the append (J2) | n/a | **no** — nothing to reapply | not applicable; the operator simply retries | no intervention occurred |
| 2 | attempt appended, runtime crashes **before** the ioctl leaves | ATTEMPT, no OUTCOME | nothing reached the host | yes | **no** | **yes** — the control channel died with the runtime | an attempt with no outcome; unresolved |
| 3 | request never delivered — `:socket.send` fails (`effect_channel.ex:426–431`) | ATTEMPT + OUTCOME `INDETERMINATE` | provably nothing left the runtime; reported conservatively | yes | **no** | no — the connection is alive; a **new** intervention may be initiated | indeterminate, with the write-failure reason |
| 4 | ioctl returns a refusal (`lib.rs:328/338/347/365`, or `terminal.ex:1076–1112`) | ATTEMPT + OUTCOME `REFUSED` + `refused_as` | the terminal was not resized | not needed | **no** — a refusal is an answer | no | refused, by name |
| 5 | ioctl applies, reply arrives | ATTEMPT + OUTCOME `APPLIED` | `TIOCSWINSZ` returned 0 on the master | not needed | **no** | no | applied |
| 6 | ioctl applies, reply lost — channel closed (`effect_channel.ex:449–455`) | ATTEMPT + OUTCOME `INDETERMINATE` | applied; the answer died in transit | yes | **no** | no | indeterminate, possibly converged |
| 7 | still queued at the deadline (`effect_channel.ex:439–442`) | ATTEMPT + OUTCOME `INDETERMINATE` | may be **about to** happen — the request is abandoned, the work is not (`participant.ex:55–69`) | yes | **no** — a retry here is a second execution | no | indeterminate, may still land |
| 8 | outcome append fails after a **known** apply | ATTEMPT only; the apply is known to the process and to nothing durable | the terminal was resized and history does not say so | yes | **no** — the effect already happened | no | an attempt with no outcome; **indistinguishable from cut 2 and 9** |
| 9 | runtime crashes after the ioctl, before the outcome | ATTEMPT only | applied, refused, or still queued — unknown | yes | **no** | **yes** | an attempt with no outcome; unresolved |
| 10 | control/presentation authority expires before recovery | ATTEMPT, and possibly OUTCOME | anything above | yes — observation needs no authority to intervene | **no** | **yes** — `control_owner` is a pid and dies with the channel (`presentation.ex:149–162`) | whatever was recorded; no new intervention without a new initiator |
| 11 | Worker generation changes before recovery | ATTEMPT, and possibly OUTCOME | the position the attempt named no longer exists under that name | yes, against the **new** generation, labelled as such | **no** — the target is a different assignment | **yes** — `fresh/2` refuses `worker-generation-stale` (`presentation.ex:242–262`) | the attempt is history about generation *n*; nothing about *n+1* |

Three things the table makes visible that a prose account hides:

**Cuts 2, 8 and 9 produce byte-identical durable evidence.** An attempt with
no outcome does not say which of them happened, and no amount of schema
design makes it. That is the honest floor of an append-only ledger over a
non-transactional boundary, and it is why J2's law makes the unmatched
attempt a first-class state rather than something a reconciler is expected to
resolve.

**Every row says no to reapply.** Not one of them is a case where repeating
is correct, and the reasons differ: nothing to repeat (1), the effect already
happened (5, 6, 8), the request may be about to run (7), the target is gone
(11), the authority is gone (2, 9, 10).

**Cut 10 is the one where the temptation is strongest**, because SHAPE *is*
idempotent and a stale resize is harmless in the way a stale `rm` is not.

### The law

**Idempotency does not grant authority.**

After a restart, or after the control incarnation that initiated an attempt
has ended, do not reapply merely because repeating is technically safe. The
authority to intervene is a live human-control presentation, and the tree
already builds it to die with the connection: `resolve/3` binds
`control_owner` to `Peer.owner_pid/1` *"because an id would have to be looked
up later"* (`presentation.ex:149–162`), the peer record is dropped when its
owner dies (`peer.ex:994–998`), and no `pc-…` id from a previous incarnation
resolves (`peer.ex:695–699`).

A reapply after that point is not a retry. It is a **new intervention with no
initiator** — an act with a target, a basis and an effect, and nobody to
attribute it to. Which is precisely the laundering shape D.1.3c·2d·0 measured,
reintroduced through a reconciler instead of through a keystroke. A
mechanism built to refuse provenance laundering must not contain a path that
performs it automatically, at boot, unattended.

---

## J7 · Where SHAPE orchestration executes

**C1.0b·2's four classes exist only inside `Ampd.AuthorityCoordinator`.
Outside it, `Ampd.Participant.call/4` is a plain `GenServer.call` and a
participant fault EXITS the caller. A non-ordered SHAPE orchestration
therefore does not inherit INDETERMINATE isolation — it has to be given it
explicitly.**

### The measurement

```elixir
# ampd/lib/ampd/participant.ex:197–205
def call(server, op, class, opts \\ []) when class in [:read, :mutate] do
  timeout = Keyword.get(opts, :timeout, 5_000)

  if inside?() do
    guarded(server, op, class, timeout, Keyword.get(opts, :witness))
  else
    GenServer.call(server, op, timeout)
  end
end
```

and the moduledoc's own statement of it (`participant.ex:132–137`): *"Outside
the total order, nothing changes. A caller that is not the coordinator gets a
plain `GenServer.call`, byte for byte."*

`Ampd.Receipts.emit/1` routes through `ask/2` → `Participant.call/4` with
class `:mutate` (`receipts.ex:19–29`, `:52`). So:

```text
   INSIDE  AuthorityCoordinator.transact/1
   ────────────────────────────────────────
     Receipts crash → Participant.Failure raised
                    → classify/1 catches BY STRUCT      coordinator.ex:465–469
                    → run/2 returns {:refused, refusal} coordinator.ex:440–445
                    → and touched/0 on the indeterminate branch  :441
     the coordinator survives. THE CALLER OF transact SURVIVES and
     receives a value.

   OUTSIDE
   ───────
     Receipts crash → bare GenServer.call
                    → caller EXITS with the reason      participant.ex:12–14
     whatever process ran the orchestration dies. If that process is the
     control connection, the operator's connection dies because a receipt
     could not be appended.
```

That second column is the requirement in this directive, and it is not
hypothetical: it is the same measurement C1.0b·2 was built on, one layer out.

### The precedent to copy: `Ampd.Carrier.Terminal.acquire/1`

`acquire/1` (`terminal.ex:934–950`) already solves the general problem —
an operation with an unbounded machine phase in the middle of ordered
decisions:

| phase | ordered? | source |
|---|---|---|
| `admit_attach/1` — agree the ticket | **yes**, `AuthorityCoordinator.transact` | `terminal.ex:280–282` |
| `machine_attach/1` — ask the host | **no** | `terminal.ex:374–384` |
| `own_stream/3` — take the descriptor | no | `terminal.ex:397` |
| `commit_b1/3`, `commit_b2/3` | **yes**, two linearization points | `terminal.ex:436–457`, `:543–545` |

and the reason for the middle is stated in the source:
*"The machine phase. **Not ordered**, and it decides nothing… The duration is
unbounded, which is the whole reason it is outside the total order."*
(`terminal.ex:376–381`).

SHAPE's middle phase is the same kind of thing.
`ask_resize/3` → `EffectChannel.request/5` (`terminal.ex:1181–1201`) is a
synchronous socket round trip with `EffectChannel.deadline_ms()` = 10 000 ms
(`effect_channel.ex:168`), against a coordinator whose own budget is 15 000 ms
(`authority_coordinator.ex:160`). Running it inside `transact` would park the
total order behind a terminal that is slow to answer, and every authority
mutation on the machine would queue behind a window resize.

### The comparison

| | ordered mutation (all of it inside `transact`) | non-ordered orchestration process |
|---|---|---|
| **advantage** | participant isolation is free (`classify/1`); linearized against every other authority mutation; the attempt/outcome pair cannot interleave with a `reset` | the coordinator is free during the 10 s round trip; matches the shape `acquire/1` already established; the ordered phases are still ordered |
| **cost** | up to 10 s of the total order per resize; `budget_ms` is 15 s, so two slow resizes exceed it; a busy terminal becomes a control-plane stall | isolation is **not** inherited and must be built; the interleaving window between attempt and outcome is real and must be represented (J2 already does) |
| **participant semantics** | four classes, refusals graded by `Participant.refusal/1` (`participant.ex:354–368`) | none — bare `GenServer.call`; a fault is an exit, unclassified |
| **what must be added explicitly** | nothing | a process boundary, a supervision/monitor decision, and a rule that the round trip's failures cannot escape as exits |

### Recommendation

**Copy `acquire/1`'s shape — ordered, not-ordered, ordered — and run the
composition in a process that is not the control connection.**

```text
  control connection process
        │  shape_terminal(worker_ref, expected_generation, rows, cols)
        │  peer comes from the BINDING, never from the payload
        │                                   presentation.ex:140–143
        ▼
  spawn_monitor ─── the intervention process ──────────────────────────┐
        │                                                              │
        │  ORDERED   transact:                                         │
        │              Presentation.resolve/3 from the bound peer      │
        │              re-derive attachment currency + stream phase    │
        │                             terminal.ex:1073–1116            │
        │              append terminal-intervention-attempt@1          │
        │            a participant fault here is {:refused, …}         │
        │            and NOTHING is sent                    (J2, J6·1) │
        │                                                              │
        │  NOT ORDERED   ask_resize → EffectChannel.request, ≤ 10 s    │
        │                terminal.ex:1181–1201 · effect_channel.ex:168 │
        │                the coordinator is free for the whole wait    │
        │                                                              │
        │  ORDERED   transact: append terminal-intervention-outcome@1  │
        │            classified per J5, never better than measured     │
        └──────────────────────────────────────────────────────────────┘
        ▼
  the connection receives a VALUE; a fault inside arrives as a DOWN
```

Five things must be added explicitly, because none of them is inherited:

1. **`spawn_monitor`, not a link and not a `Task`.** The argument is already
   written in this tree, for the coordinator rather than the connection:
   *"A `Task` LINKS to its caller… an abnormal exit in the witness process
   propagates through that link and kills the coordinator unless it traps
   exits, which it does not"* (`participant.ex:300–310`). Substitute "the
   control connection" for "the coordinator" and the reasoning is unchanged.
2. **Both appends go through `transact/1`**, so a `Receipts` fault is a
   classified refusal (`authority_coordinator.ex:440–445`) rather than an
   exit. This is the whole reason not to append from the non-ordered phase.
3. **The non-ordered phase must not be able to raise into the parent.** It
   touches no participant — `EffectChannel.request/5` writes and reads a
   socket — but it can raise, and the round trip must be wrapped so that
   neither a raise nor a 10 s block escapes the intervention process.
4. **A deadline on the whole composition**, strictly greater than the
   channel's 10 s and strictly less than whatever the connection is willing
   to wait. `Ampd.WorktreeTest`'s deadline-ordering falsifier reads these
   numbers off the modules that own them and fails if the chain stops
   decreasing (`authority_coordinator.ex:156–158`); a new orchestration
   deadline joins that chain rather than sitting beside it.
5. **INDETERMINATE is reported as INDETERMINATE.** A refusal that says
   nothing happened, when the outcome append was indeterminate, is the
   collapse `Ampd.Participant` exists to prevent — and the graded refusal
   already carries the right words (`participant.ex:380–383`: *"a timed-out
   request is abandoned but its work is not. Do not retry — establish the
   outcome first"*).

### The acceptance property

A `Ampd.Receipts` or `Ampd.Peer` fault during a SHAPE must:

- **(a)** not kill the control connection,
- **(b)** not kill `Ampd.AuthorityCoordinator`, and
- **(c)** not produce an outcome record claiming more than was measured.

(b) comes free from `transact`. (a) and (c) do not, and are what the process
boundary and the classification rule above are for.

---

## J8 · DRIVE remains deferred

No terminal input this round. 2d·1 §7's finding is retained in full and
sharpened in one place.

**Input is not idempotent** — `"rm -rf "` sent twice is not `"rm -rf "` sent
once — and after J5 it is not re-observable either. SHAPE was recommended
into `Ampd.Receipts` on the strength of idempotency; DRIVE has neither that
property nor the observability half that J5 has now shown does not yet exist
for anything. So nothing in this document extends to DRIVE by inheritance.

**And raw terminal input must not become durable provenance.** The surveyed
products are unanimous and 2d·1 §7 tabulates them: Teleport does not capture
stdin, RHEL `tlog` disables it by default *"to avoid intercepting raw
passwords"*, `script(1)` warns twice that input logging is independent of the
terminal's echo flag, sudo 1.9.10 had to add an output heuristic to hide
password prompts from a feature that captures input *"even when not echoed"*.
The argument in one line, unchanged: **terminal echo state is a property of
the terminal, not of the recorder**, so a recorder on the input path captures
the password precisely in the case where the terminal hid it.

### Why a digest is refused too, and not as a compromise

A digest of the input is a **verifier**, and terminal input is exactly the
input class verifiers break on.

```text
   H(bytes) retained durably

   an attacker (or an auditor, or a future feature) holding the log can
   test any guess for one hash:

       for candidate in guesses:
           if H(candidate) == recorded:   ← the password is confirmed

   the guess space for a typed password is small and structured.
   a human at a prompt types something rememberable. this is not the
   uniform 256-bit input a digest is safe over; it is the low-entropy,
   guessable input a digest is a CRACKING ORACLE over.
```

Salting does not rescue it: a salt is only useful to a later reader if the
salt is stored, and a stored salt beside a stored digest is a stored
plaintext with extra steps. Keying it does not either, for the same reason —
the key would have to outlive the session to serve the audit purpose the
digest was retained for, and a durable key beside a durable digest is a
durable password.

And the case where it is worst is the same case the echo argument names: the
terminal hid the characters, the human believes nothing was recorded, and a
"redacted" provenance record is holding a confirmable copy.

So the retained set for DRIVE, when it is designed, starts from:

```text
   raw bytes             ← refused
   digest of the bytes   ← refused, on the oracle argument above
   byte count            ← candidate
   sequence range        ← candidate
   redacted semantic operation observed BELOW the input path  ← the direction
```

The last is Teleport's answer to the resulting blind spot and it is the
architecturally interesting one: it does not start recording stdin, it moves
the observation point down a layer and emits
`session.command` / `session.exec` / `session.network` from BPF — commands,
without password prompts.

**A provenance mechanism must not become a durable keystroke logger while
trying to solve attribution.** That ruling is mandatory before DRIVE and is a
slice of its own.

---

## What this design does NOT settle

- **The host geometry operation.** Whether to add one, its schema (something
  like `carrier-pty-geometry-observation@1`), whether reading the master's
  winsize from the host is inside the Carrier floor's attested surface, and
  what a reconciler may do with the answer. `Pty::winsize()`
  (`host/src/pty.rs:329–338`) already implements the syscall and has no
  callers, so the mechanism exists and the *operation* does not. Until it
  does, dimension B of J5 is unmeasurable and
  `terminal-intervention-observation@1` is a design, not a plan.
- **Exact field names.** Provisional, as 2d·1 §8 said, and derived from the
  tree at implementation time the way `terminal-attachment@1` was.
- **The `Receipts.count/0` migration.** J4 names the readers and the
  breakage; it does not decide whether `count/0` is kept with a clarified
  docstring, deprecated, or left alone with every caller migrated. Roughly
  fifteen assertions across seven files is a real change and it should be
  costed rather than assumed.
- **`list_interventions` vs a kind parameter on `list_receipts`.** Both work
  under J4's id constraint. Neither is chosen here.
- **The `rcpt-` four-digit id defect** (`receipts.ex:85`). Recorded, not
  scheduled, and explicitly not this slice's to fix — but a second,
  higher-frequency kind on the same counter shortens the fuse.
- **Whether an unmatched attempt becomes a standing operator item.** The
  shape exists — `"carrier_attempts"` on the operator projection is exactly
  *"the list of things that are stuck, not a history"*
  (`projection.ex:114–129`) — and nothing here rules on whether an
  intervention with no outcome belongs in it.
- **Multiple human identities.** Unchanged from 2d·1 §8: today "the
  human-control role" and "this human" are the same thing because
  `Ampd.Peer` refuses a second control channel
  (`peer.ex:668`, `control_claimed`). When that stops being true, `initiator`
  gains a field; it does not become an actor.
- **Whether interventions ever share a substrate with `Ampd.Effects`.**
  2d·1 §5 says they may; nothing here requires it and nothing here forbids it.
- **DRIVE's retained set** (J8), which is a ruling and a slice of its own.

---

### Sources for the external claims

The external citations in 2d·1 (W3C PROV-DM/PROV-O, `auid` /
`CONFIG_AUDIT_LOGINUID_IMMUTABLE`, Kubernetes `impersonatedUser`, CloudTrail
`sourceIdentity`, `tty_do_resize()` / `ioctl_tty(2)`, mosh, Teleport / `tlog`
/ `script(1)` / sudo / AWS SSM, and the provenance-identifier-as-credential
family) are carried forward unchanged and are not restated here. Every
claim in this document about **this tree** is cited inline as `file:line`
against `super/` at the time of writing.
