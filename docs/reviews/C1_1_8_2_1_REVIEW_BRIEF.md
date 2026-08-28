# F.8.2.1 — the fourth exit, and a baseline that had already absorbed it

**Artifact: `and-super-rev-f821.zip`. Every gate green.**

You were right, and the diagnosis was exact: the fast refusal is a fourth exit, it leaks
one descriptor per refused claim, and the battery's own single `second` call is what
contaminated the baseline every later equality was measured against. Reproduced before
touching anything:

```
boot baseline sockets: 3
first control:  ok  -> 4
second control: refused (control-channel-already-claimed)
after 100 REFUSED second-control claims -> 104   (was 4)
LEAKED: 100
```

A hundred refusals, a hundred descriptors, on the one move a hostile local process always
has: asking for something it is not permitted to have. And "one sink, three call sites,
no fourth exit" was a sentence I wrote about code I had not finished reading.

---

## 0 · Measured

| | F.8.2 | F.8.2.1 |
|---|---|---|
| conformance vectors | 42 | **42** |
| BEAM tests | 176 | **176**, 0 failures at seed 0 |
| browser assertions | 64 | **64** |
| BEAM sabotage falsifiers | 40 · 0 not | **40 · 0 not** |
| host acceptance checks | 44 held | **47 held · 0 failed** |
| host sabotage falsifiers | 5 · 0 not | **6 · 0 not** |

---

## 1 · The law, encoded as a shape rather than a patch

I did not fix the branch. Two clauses is *how* the branch happened — a second
`handle_call/3` head that matched before the one holding the ownership contract, and
named the descriptor `_fd` to say it did not care. So there is no longer a second clause:

```elixir
def handle_call({:adopt, fd_or_socket, kind, actor}, _f, st) do
  if kind == :human_control and st.control_open do
    dispose(fd_or_socket)
    {:reply, {:refused, control_taken()}, st}
  else
    ...
```

The law is in `adopt_channel/3`'s doc, where a caller reads it:

> **This call consumes its channel argument exactly once**, into a live connection or into
> a sink, and that holds for every refusal as much as every success. A caller hands over
> the channel; it does not get it back and must not close it.

`dispose/1` is your split: an integer goes to `NativeFd.discard/1`, an already-adopted
socket handle is `:socket.close/1`d.

**The one exit that correctly does nothing is documented as such**, because I checked it
this time rather than counting: when `Connection.start/3` refuses, the connection process
has already taken the socket and closes it on its own refusal path. Disposing there would
be a double close, which is the mirror of this bug and just as bad.

## 2 · The baseline moved to boot, and the numbers moved with it

Your sequence, implemented in order. The descriptor baseline is now sampled beside the
fd-3 sample, immediately after `Runtime::start`, before the first control channel exists:

| | |
|---|---|
| the control channel | **exactly** boot + 1 |
| a second control claim | refused, and still boot + 1 |
| 100 refused claims | **still boot + 1** |
| 0, 1 and 2 in the runtime | open, and none of them a socket |
| ten channels · 100 cycles · 30 rejected commands · 4 surplus rights | as before, now against a clean baseline |

The correction is visible in the sabotage output: the local baseline the descriptor
section computes fell from 11 to 10 and from 9 to 8 between revisions. That drop is the
leaked descriptor F.8.2 had been calling normal.

## 3 · The `<3` floor is gone, and it was hiding a crash

You are right that "0, 1 and 2 are occupied" is a fact about how this host spawns the
runtime, not about Linux, and that it is exactly the assumption a GUI launch should not
inherit. It was also an *ownership exception* living inside the module whose whole claim
is that every received descriptor has an exit — the same shape as the bug being fixed.

`close_received/1` now takes any non-negative descriptor. Two things fell out:

**It was masking a crash.** With the floor, `discard(-1)` returned `{:error, 0}` and
looked handled. Without it, the same call is a `badarg` that killed the bridge
`GenServer` — reached from `adopt_channel(-1, :agent, "kestrel")`, which is a test in this
suite and a call any code inside the runtime can make. `discard/1` is documented as total
and was not; it is now, with the NIF left strict underneath. A guard that hides a crash is
its own argument against having had one.

**The hazard moved to where it arises.** The floor was worried about a received channel
landing on the runtime's stdout — real, since `SCM_RIGHTS` takes the lowest free number
like any other `dup`. That is the host's job: `fdpass::ensure_std_fds` runs after `fork`
and before `exec`, opens `/dev/null` onto any of 0, 1, 2 that is closed, and runs *before*
`dup_onto(theirs, 3)` so the ordering cannot invert.

**And the check for it is an invariant check, not a falsifier — not counted as one.**
This battery is launched from a shell, so 0, 1 and 2 are occupied whether or not
`ensure_std_fds` exists. It passes with the fix disabled, which is the definition. Both
the code and this brief say so; the same call I made for `cmsg_cloexec` in F.8.1.

## 4 · Sabotage

Six now, each stubbing one fix and requiring a **named** check RED:

```
falsified   an adopted descriptor is disposed of
falsified   F.8.1's dup:false adoption leaks one descriptor per channel
falsified   a rejected command's descriptors are disposed of
falsified   the FD_CLOEXEC that dup(2) drops is put back
falsified   a refused control claim disposes of the channel it arrived on
            → 105 sockets after 100 refused claims, expected 4
falsified   the inherited bridge descriptor is adopted, not merely wrapped
```

## 5 · The release wording, taken

`release.sh` now prints:

```
RELEASE OK → and-super-rev-f821.zip (revision F.8.2.1 · required release gates green)
  NOT run here: ampd/tools/sabotage.sh (~4m40s). A round is not closed without it.
```

You are right that it was stronger than the implementation warranted, and right that
after everything this project has learned about claim discipline it is not the place to
leave a prose-versus-evidence gap. The comment above it says the same thing at length:
176 passing tests and 176 tests *that can fail* are different claims, and only the
falsifier battery separates them.

## 6 · Your table

| Finding | State |
|---|---|
| fourth exit: fast refusal keeps the descriptor | ✅ closed · reproduced at 100/100 first, then fixed |
| the contract belongs on `adopt_channel`, not the branch | ✅ one clause · law in the doc · integer→sink, socket→close |
| baseline taken after the adversary | ✅ boot baseline, before the first channel exists |
| the `<3` floor | ✅ **removed** · hazard moved to `ensure_std_fds` · check labelled an invariant |
| `discard/1` was not total | ⚠️ not in the round; found by removing the floor · §3 |
| "every gate green" overclaims | ✅ "required release gates green" + what was not run |

## 7 · Open

Nothing measured-and-not-fixed in the transport.

The two carried items are unchanged and still not this round: `app-prototype.html`'s
remote fonts (accepted for the production WebView, not applied to a live marketing page),
and engine confinement — Landlock/namespaces/bubblewrap — which wants its own design
round between "the cockpit works" and any claim that a local agent is contained.

## 8 · WebView

Taking your sequencing and your version correction: current 2.11.x rather than the 2.11.1
floor, locked at whatever `2.11.5` resolves to when the app is scaffolded. Capability-
scoped IPC, no remote content, bundled or system typography.

    persistent world → Rust host → human control capability → subscribe
      → projection → derive LIVE LOCAL → WebView

then exactly one mutation — click REVOKE → Tauri command → Rust human channel → ampd
authority transition → new projection → UI changes from truth. No optimistic UI, no
shadow world, and `RECONNECTING` only once reacquisition exists to produce it.

## 9 · Ladder

    C1.1     Tauri Rust host + private transport
             ├─ F.6      CommandSpec · exact-set linearized · limits · pack digest
             ├─ F.7      inherited descriptors · identity lifetime · epoch ·
             │           demultiplexer · bounded projection
             ├─ F.8      CLOEXEC confinement · serialized writer ·
             │           continuity cursor · lossless paging
             ├─ F.8.1    durable host world · one owner per world              ✓
             ├─ F.8.2    the receiver owns what it receives · zero residue ·
             │           the flag dup(2) drops · host gates in the chain       ✓
             └─ F.8.2.1  adopt_channel consumes its argument exactly once ·
                         boot baseline · no exception in the sink              ✓
             ── remaining: the WebView
    C1.1b    SQLite transactional persistence · durable revision
    C1.2     FabricProvider.Tailscale

## Verify

```
cd ampd && mix test                    # 176 tests, seed 0
bash tools/sabotage.sh                 # 40 falsified · 0 not   (4m40s)
cd .. && bash tools/release.sh         # required gates, including both host gates
./host/target/release/super-host verify        # 47 held · 0 failed
bash tools/sabotage-host.sh                    # 6 falsified · 0 not
```
