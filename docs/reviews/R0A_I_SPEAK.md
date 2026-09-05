# Super Self-Hosting **R0a · I Speak**

**A Carrier said something, and nothing asked it to.**

```text
plane frames 1 · bytes 66 · applied 1 · consumed 1 · acked 1 · gaps 0 · duplicates 0
fault null · closed null
screen: "\nSUPER-DOGFOOD-R0-READY\ncarrier e6c52ea4aee66535d03dd052016fe2b7"
terminal join probe: 16 held · 0 failed
```

That string traversed a real PTY, a real `TerminalAttachment`, the real
`Terminal.Plane`, a real socketpair, the cockpit's Rust decoder, a real Tauri
`Channel`, a real `xterm.js`, its write callback, `terminal_ack`, and back as
credit — from a person's click on *Watch terminal* in a normal Super.

## A1 · the payload, and how it is selected

**No protocol field names an executable, and none was added.** D.1.2's rule
is untouched: `open_lane` still declines to take a path,
`carrier-start-request@1` still has no payload field, and the grammar's own
comment — *"a grammar in which a caller could name one would be a grammar
where naming something runs it"* — still holds.

The selection is the host's, and it is one function:

```rust
pub fn payload_path() -> Option<PathBuf> {
    installed("dogfood", "super-dogfood").or_else(fixture_path)
}
```

`tools/build-payloads.sh` is what "installed" means — a table of
`crate : binary`, and a payload not in it is not installed. It was
`build-carrier-fixture.sh` and built one; splitting it would have duplicated
the `cd` that *is* the build rule, the private `CARGO_TARGET_DIR` that makes
provenance structural, and the `cp`-not-`mv` that stops a write following a
`deps/` hard link.

**Changing the payload is not silent.** `bind_carrier_channel` already
measured `fixture_path()` and put its digest in the attested
`execution_basis`; it now measures `payload_path()`, `Ampd.Carrier` binds
that into every ticket, and a mismatch refuses
`carrier-execution-basis-changed`. That mechanism existed and had never
governed an actual payload change. It does now.

### it is a payload, and deliberately not a Motor

`Ampd.Carrier`'s chain is `Actor → Peer → Locus → Worker → Carrier → Motor`,
and `MOTOR_MACHINE_RESEARCH_BRIEF_FOR_OPUS.md` scopes a Motor as *a bounded
policy artifact that proposes actions against a typed Machine contract*.
`super-dogfood` proposes nothing and decides nothing. It occupies the
**payload** slot — the source's own word, and the word the basis uses
(`payload_digest`) — in the position a Motor will eventually occupy. Naming
it a Motor now would name a seam that has not been designed.

## A2 · the byte is the payload's own

`super-carrier-fixture` has a `SAY <text>` verb. It is how `super-host
verify` makes a Carrier speak, and it is exactly why the fixture could never
close B5: bytes that arrive because the host asked for them prove the pipe,
not the producer.

**`super-dogfood` has no verb that makes it write to its terminal.** No
`SAY`, and no `HEAR` either — reading the terminal is the input half and
D.1.3c's scope is OBSERVE. `IDENT` and `ECHO` remain so the host can still
prove this is *this* Carrier and that the control descriptor is live in both
directions. There is nothing a host, a test, a page or a runtime can send
that produces the marker.

It writes after the handshake, because the handshake is where the process
learns which incarnation it is — the identity line quotes what the host said
in `HELLO`, not `SUPER_CARRIER_INCARNATION`, which anyone who could set its
environment could have supplied.

## A3 · the chain, and the evidence at the end of it

| | |
| --- | --- |
| `super-host verify` | **299 held · 0 failed** (was 290) |
| `tools/terminal-join-probe.mjs` | **16 held · 0 failed** (was 6 held · 1 failed) |
| ExUnit | **596 tests · 0 failures** (was 586) |

The nine new host rows measure the same byte a second before the browser
does, and make two claims the probe cannot:

- **nothing asked for it.** The battery sends `HELLO` and reads. There is no
  verb it could have sent, so the marker's arrival is attributable to the
  payload alone.
- **the line discipline is doing its job.** The payload writes `\n`; the
  master delivers `\r\n`. A pipe would not.

Plus: the production payload is `super-dogfood` and not the fixture; it is
statically linked, so the execute grant names one inode; the fixture is
**still installed and is a different file**, because `carrier_confinement`'s
thirty-odd direct spawns are a census of what a deliberately stupid process
can reach and running them against a payload that does things would measure
the payload instead of the floor; and speaking cost the Carrier no
descriptor — the set is still exactly `{0,1,2,3}`.

### the page evidence, in full

```text
bound        true
frames       1        at least one OUT frame delivered
bytes        66       >= the marker's own length
applied      1        contiguous
consumed     1        >= applied
acked        1        credit returned for what was consumed
gaps         0
duplicates   0
fault        null
closed       null
xterm        contains SUPER-DOGFOOD-R0-READY exactly
```

**And one row that is a property, not a formality:** the payload writes at
startup and the person clicks afterwards. `terminalPane` at bind time already
carried `frames: 1` — the bytes waited in the kernel's tty buffer, held by
the line discipline. Super stored nothing and must not start; B7's rule that
a reopened presentation gets no server scrollback is untouched. Those two
facts are compatible and this is where the difference is visible.

## A4 · a probe that was red on purpose, promoted

`tools/terminal-join-probe.mjs` shipped **red**, deliberately, at `b470a1b`:
6 held, 1 failed, because the joined path was open and no product path could
put a byte on it. It was a milestone acceptance probe and said so.

The marker assertion was not weakened. It is now green because the marker
genuinely traversed the path, so the probe moves into `tools/release.sh`'s
mandatory list. The historical finding is preserved verbatim in
`docs/reviews/D_1_3C_2C_1C_B5.md` with a closure note on top.

## A5 · the source of the bytes, falsified

`tools/sabotage-cockpit.sh` probe 30 removes the payload's marker write and
rebuilds — including the payload, which needed a `rebuild` that runs
`tools/build-payloads.sh`, because a probe that sabotages a separate artifact
and rebuilds only the cockpit is a probe that never runs its own sabotage.

Measured:

```text
plane frames 1 · bytes 42 · applied 1 · consumed 1 · acked 1 · gaps 0 · duplicates 0
fault null · closed null
screen: "\ncarrier 3ec6cf471cb6874e016b59c5509b7162"

FAILED   R0a — the marker SUPER-DOGFOOD-R0-READY reached a real xterm
held     ×15   everything else
```

**One row red, fifteen green, and the fifteen are the other half of the
evidence.** The Carrier still ran, the terminal was still PRESENT, the
presentation still opened, the sink still bound, the page still beat
thirty-three times, and the identity line still flowed — so the plane still
carried a frame with contiguity, credit and no fault. A sabotage that turned
the whole probe red would be consistent with having broken the Carrier. This
one is only consistent with having removed the marker.

**No positive control was added, on purpose.** Injecting the marker from the
host or the page to prove the assertion can pass would build the exact bypass
this probe exists to rule out, and it would then live in the tree.

### and four probes that had quietly died

`SABOTAGE_DRYRUN=1` reported **4 missed** before this round's probe was
added — measured against a stashed tree, so they were already dead at
`b470a1b`. `cockpit/ui/cockpit.js` split `const grants = (p.grants ?? []).map`
into two statements and `cockpit/capabilities/default.json` reformatted
`"webviews": ["main"],` onto three lines. Neither changed behaviour; both
retired a falsifier — one for the frame-rebuild property, three for the
webview ACL. Repaired: **34 patterns matched · 0 missed.**

## A6 · B9 · the negative acquisition matrix, through the command

`ampd/test/terminal_acquire_test.exs` — 10 tests. Aimed at
`acquire_terminal`, the **command**, not at `admit_attach/1`, the function
`terminal_possession_test` already falsifies. The distinction is the one this
round keeps paying for: a refusal only reachable by calling an internal
function is not a refusal a caller can meet.

| | case | refused |
| --- | --- | --- |
| Z0 | fully occupied, live Carrier, no terminal | **admitted** — fails only in the machine |
| Z1 | occupies nothing (same actor, second channel) | `carrier-not-attached` |
| Z2 | another actor's Peer | `carrier-not-attached` |
| Z3 | the human control channel | the grammar, before the chain |
| Z4 | no Carrier | `terminal-no-live-carrier` |
| Z5 | already possessed | `terminal-already-attached` |
| Z6 | the Carrier stopped | `terminal-no-live-carrier` |
| Z7 | the Worker closed | `worker-not-open` |
| Z8 | the Peer is gone | `unknown-peer` |
| Z9 | the World incarnation moved | `world-incarnation-changed` |

**Z0 is the discriminator and every other row depends on it.** Without a case
that gets *past* admission, the whole matrix would also pass against an
`acquire_terminal` that refused unconditionally. Z0 is admitted and then
fails in the machine phase, because this test runtime possesses no host
carrier channel — a different answer from every refusal above it.

Every row also asserts it is **not** a post-admission code
(`terminal-machine-refused`, `terminal-acquire-indeterminate`): the unbounded
host round trip never starts for a caller the World should have stopped. Same
property `carrier_test`'s E1 states for starts.

**No test passes an identity in.** The command declares `fields: []`; Z5
installs a terminal record as world state, and the command it then sends is
still empty.

### two rows came back with better answers than expected

Z8 was written expecting `terminal-peer-gone` and got `unknown-peer`; Z9
expected `terminal-carrier-not-current` and got `world-incarnation-changed`.
Both are **outer gates** the command meets before the terminal chain runs —
`Ampd.Control` will not dispatch for a Peer it cannot resolve, or under a
superseded world incarnation. Asserting the inner refusals would have been
asserting that the outer gates do not exist. Two independent reasons each
case cannot succeed, and the command path meets the first.

## The PRELUDE · evidence that survives the run that provokes it

D.1.3b·2f recorded one unexplained run — seed `909090`, 586 tests, 4
failures — whose output was discarded by a `grep` for the summary line, then
five clean runs at the same seed. `tools/suite-evidence.sh` is the repair.
One directory per execution, created with `mkdir` so a collision **refuses**
rather than clobbers:

```text
.suite-runs/<stamp>-<sha>-seed<seed>/
    meta.json    commit · tree · dirty paths · seed · started_at ·
                 finished_at · duration · exit status · timed_out ·
                 summary · orphan runtimes before/after · byte counts
    stdout.log   in full          (10.9 MB per run, retained)
    stderr.log   in full
```

and one appended line in `.suite-runs/INDEX`. Output goes to **files, never
a command substitution** — `out=$(mix test)` waits for an EOF an orphaned
BEAM holds open, which cost the host battery 1h46m once already.

The orphan census is in there because that was my hypothesis and it does not
hold: the runs were clean with orphans at zero, and clean earlier *with*
orphans present. It is recorded as evidence, not as an explanation.

**The prior 4 failures are recorded as `unexplained prior run · details
unavailable · not reproduced`, and no explanation was manufactured.**

Re-run at this tree:

```text
green  seed 0        586 tests, 0 failures   (164s, orphans 0→0)
green  seed 424242   586 tests, 0 failures   (164s, orphans 0→0)
green  seed 909090   586 tests, 0 failures   (164s, orphans 0→0)
```

## What R0a did NOT do

No `terminal_input`. No `onData`, no `onKey`. No fourth inbound Plane frame.
No `TerminalAttachment.write/2` caller. The terminal's authority class is
exactly what it was: **OBSERVE**. The first real bytes originate from the
Carrier's own payload, which is what makes that possible.

No confinement was widened. `super-dogfood` runs under the same
`Policy::minimal` the fixture does, holds exactly `{0,1,2,3}`, and speaking
cost it nothing.

## Verdict

```text
payload selection      GREEN   host-side, digest-attested, no protocol field
byte source            GREEN   the payload's own, falsified by removing it
joined path            GREEN   16 held · 0 failed, credit returned, no gaps
host measurement       GREEN   299 held · 0 failed
possession matrix      GREEN   10 tests · 0 failures, Z0 discriminates
ExUnit                 GREEN   596 tests · 0 failures, evidence retained
ordered census         380 functions · 26 crossings · CLOSED — unchanged
```

**GO.**

R0b is the next slice and is not started here: one real Super
build/test/verification operation, streamed through the terminal R0a just
proved, with every missing authority filed as a named decision rather than
granted to make the job pass.
