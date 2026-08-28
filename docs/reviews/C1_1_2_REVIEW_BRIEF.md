# C1.1.2 — the transport's acceptance battery, before the transport

**Artifact: `and-super-rev-f5.zip`. Every gate green.**

You ruled: *don't insert another sub-round; build the transport, but close the exact-grant
identity, duration validation, transition-result truth, and hostile-input boundary on the way
in.* None of those needs a socket, and each was a live authority defect — so this is that list,
closed, with the battery green against the semantics before the socket is written.

I took the "no new sub-round" part seriously: nothing here is polish. Every change fixes
something that was reproduced failing first.

---

## 0 · Measured

| | C1.1.1 | C1.1.2 |
|---|---|---|
| conformance vectors | 39 | **42** |
| BEAM tests | 110 | **128**, 0 failures across 7 seeds + seed 0 |
| browser assertions | 60 | **64** |
| sabotage probes | 9 falsified | **18 falsified · 0 not** (+1 declared un-falsifiable) |

The corpus grew for the first time in three rounds, and for a reason: one of these was a defect
in the **frozen simulator too**, so it is fixed in both engines and the law is held in the
language-neutral corpus rather than only on the BEAM.

---

## 1 · Reproduced before fixed

Four of your five reproduced exactly as described. The fifth reproduced as something worse.

```
── revoke_grant crosses actors ───────────────────────────────
   active before: [{kestrel, repo.read}, {kestrel, issue.read},
                   {kestrel, pr.draft}, {mallory, repo.read}]
   REPRODUCED  operator revoked Kestrel's row and Mallory's went too
── duration is an open string ────────────────────────────────
   agent requested duration="forever" → minted duration="forever"
   REPRODUCED  a grant with duration "forever" authorizes
   REPRODUCED  ...and survives an end_run AND a workspace change
── human approval can WIDEN an agent's narrower request ──────
   REPRODUCED  asked once, granted workspace
── Control reports the command, not the transition ───────────
   REPRODUCED  sealed revoke answered "revoked"
   REPRODUCED  sealed request_grant reported a grant_request
               returned: {:refused, %{"code" => "recovery-state-missing"…
── hostile command arguments ─────────────────────────────────
   request_effect([])     → {:raised, FunctionClauseError}
   approve_effect([1])    → {:raised, FunctionClauseError}
   preflight(42)          → {:raised, FunctionClauseError}
```

---

## 2 · Your dormant-grant scenario is real, and the install was never needed

You reasoned: a grant for an undeclared capability lies dormant, then the pack installs, and
**installation activates authority**. Correct. But when I ran it, day 1 already said ALLOW.

`postgres` ships at `installation: "available"` — discovered, never installed — and **already
declares its whole surface**, because that is what makes it browsable in the catalog. Neither
engine's authorize path ever read `installation`. In the frozen simulator it is read in exactly
one place: `tabFor()`, to decide which tab a pack renders under.

So the dormancy you described never happened. A grant against a merely *discovered* pack
authorized immediately. **Installation confers zero authority** was running backwards, one step
earlier than the step you were looking at: *discovery* conferred it.

Closed at both ends, because either alone leaves a hole:

* **At mint** — a capability no *installed* pack declares cannot be granted, so the dormant grant
  never exists to be activated. This is the end your version needs.
* **At the gateway** — `pack-not-installed`, so a grant that arrives another way (an older store,
  a restored world, a hand-edited dets) is inert. This is the end mine needs.

Three new vectors hold it in the corpus:

```
a discovered pack confers nothing                    → pack-not-installed
installing after a refused mint still grants nothing → authority-missing
an unenforceable duration is never minted            → authority-missing
```

Both engines changed. The browser battery gained four assertions and one of its old ones was
wrong in the same way — it asserted `postgres.query.write` refuses `denied-by-default` while
postgres was still discovered, which was reading a deny flag off a surface that is not in force.
It now asserts the pack refusal there, and the policy refusal after the install.

---

## 3 · The other four

**Exact-grant identity.** `revoke_grant(grant_id)`. Bulk is `revoke_capability_domain(scope,
expected)` — it refuses an unbounded scope by name, and refuses when the count no longer matches
what the operator was shown, naming both numbers. That makes "confirm what you were shown"
mechanical rather than a dialog. Falsifier runs two actors holding the same capability.

**Duration.** Closed to `once · run · agent · workspace`. `agent` was already the intended
fourth member — the frozen simulator's own comment said `/* agent: actor equality already
required */` next to the `return true` that let everything else through. Unknown durations refuse
`invalid-grant-duration` at three points: mint, the draft setter, and the scope check itself, so
a grant that got past minting in some older world is still inert.

**Narrowing only.** `Core.duration_rank/1` orders the enum; approving with a wider duration
refuses `grant-widening-refused` and **leaves the request pending**, because a refused approval
must not consume the thing it refused.

**Transition truth.** One `settled/2` on every mutating dispatch. A refusal becomes a refusal.
The falsifier seals the grant registry and asserts all three commands refuse, that no
`grant_request` key appears on the refused one, and that the coordinator is still alive.

---

## 4 · `public_code` removed, exactly as you ruled

One canonical code on the object; `Ampd.Refusal.agent_code/1` is the entire disclosure policy.

```elixir
def agent_code("actor-mismatch"), do: "authority-missing"
def agent_code(code) when is_binary(code), do: code
```

The exhaustive test enumerates all 33 canonical codes and asserts the hidden set is exactly
`["actor-mismatch"]` — so adding a code that needs hiding means adding a clause, and adding one
that does *not* fails loudly if someone hides it. You were right that the per-call-site field was
a drift axis: it put disclosure policy in the hands of whoever happened to be constructing a
refusal, and no test naming the visible code could have caught a wrong one.

---

## 5 · The wire

`Ampd.Wire` is the only entry point a transport should call. Decoding is **total**: any term, any
shape, any depth, yields a decoded command or a named refusal with a `correlation_id`.

* **Never `String.to_atom/1`.** The vocabulary is a fixed map built from `Ampd.Control`'s own
  command tables, so the two cannot drift — there is a test asserting they are the same set. A
  test sends 500 distinct unknown command words and asserts `:erlang.system_info(:atom_count)` is
  unchanged: the atom table has a hard ceiling and is never collected, so an interning decoder is
  a denial of service that outlives the connection.
* Argument count (8), argument size (64 KB), and nesting depth (12) limits, refusing
  `invalid-command-arguments` rather than raising.
* The `Ampd.Control.command/3` call is wrapped, so an arity with no clause becomes a refusal and
  the handler stays alive.
* Refusals minted here are projected by the peer's channel, and as an *agent* when there is no
  peer — an unidentified caller gets the narrower answer, never the wider one.

Frame limits at the socket and per-peer rate limiting remain the transport's, as you ruled.

---

## 6 · One thing I did not manage to make falsifiable, and am not counting

The `Peer` epoch is in, and every handle carries it. But stubbing the epoch comparison out leaves
its test **green**, because a crashed `Peer` comes back with an empty map and `Map.get/2` returns
nil whatever the handle says. The epoch is redundant today; it is insurance for a persistence or
handoff path that does not exist yet, and insurance against a thing that does not exist cannot be
falsified by a test.

So it is excluded from `tools/sabotage.sh`, which says why in the script, and its test is labelled
an invariant check rather than a falsifier. `18 falsified · 0 not` is the honest number; `19`
would not have been.

Your other two peer rulings are recorded and are the transport's: fail-closed reattachment after
a crash, and `attach_agent/2` / `claim_control_channel/0` restricted to the host bridge the way
registry mutations are restricted to the coordinator.

---

## 7 · Your acceptance table

| C1.1 falsifier | state |
|---|---|
| agent tries human command | ✅ falsified |
| agent puts `actor=kestrel` in payload | ✅ unphrasable — no such field |
| fake/old peer handle | ✅ falsified |
| peer crashes → old channels invalid | ✅ falsified (epoch itself: see §6) |
| claim control after restart | ⛔ transport |
| revoke Kestrel's while Mallory holds same | ✅ falsified |
| unknown grant duration | ✅ falsified |
| agent asks `duration=forever` | ✅ falsified |
| approve grant for undeclared capability | ✅ falsified — **and for a discovered pack** |
| store sealed during revoke/request | ✅ falsified |
| malformed command frame/args | ✅ falsified |
| arbitrary command string → no atoms | ✅ falsified |
| Kestrel projection contains only Kestrel | ✅ falsified |
| UI updates without reload | ⛔ transport |
| close/reopen → same durable world | ⛔ transport |

Twelve of fifteen. The three left are the socket.

---

## 8 · Ladder

    C1.1.0   projection boundary correctness                   ✓
    C1.1.1   identity + projection                             ✓
    C1.1.2   the transport's acceptance battery                ✓  this round
             exact-grant identity · closed durations ·
             discovery confers nothing · transition truth ·
             centralized redaction · total wire decoder
    C1.1     Tauri Rust host + private inherited transport
             SIMULATED → LIVE LOCAL                            ← next, and now only this
    C1.1b    SQLite transactional persistence
    C1.2     FabricProvider.Tailscale

---

## 9 · Open

1. **Should `Authority.mint/1` refuse an undeclared capability, or only warn?** It refuses now,
   which means an operator cannot pre-grant against a pack they are about to install. That is the
   correct default and it is also a workflow someone will want. The alternative — allow it, and
   let the gateway refuse — is exactly the dormant grant, so I do not think there is a middle.

2. **Is `expected_count` the right confirmation for bulk revocation?** It makes "confirm what you
   were shown" mechanical, but it is a count, not an identity: two grants revoked and two minted
   between render and click would pass. The identity-exact version is a list of grant ids, which
   is heavier and correct. I picked the count and would rather you ruled it.

3. **Where does the wire's argument schema live?** It is currently shape checks in `Ampd.Wire`
   plus `Ampd.Control`'s function heads. A declared per-command schema would be better and is
   arguably C1.1's job, since the wire format is not settled until the socket exists.

---

## Verify

```
cd ampd && mix test               # 128 tests
bash tools/sabotage.sh            # 18 falsified · 0 not
cd .. && bash tools/release.sh    # full gate chain → and-super-rev-f5.zip
```
