# F.8.2 — the receiver owns what it receives, and the fix you prescribed had a hole in it

**Artifact: `and-super-rev-f82.zip`. Every gate green.**

Your ruling was right on every count I could test, including the one I had reported as
closed. F.8.1's "bounded by channels ever opened, not by traffic" was false, and it is
now measured to be false: **30 rejected bridge commands carrying 3 descriptors each
leaked 90 descriptors**, and that is a number the old code produces on demand.

The prescription itself needed one correction, below. `dup: true` is right, and on its
own it silently undoes F.8.1 §2.

---

## 0 · Measured

| | F.8.1 | F.8.2 |
|---|---|---|
| conformance vectors | 42 | **42** |
| BEAM tests | 171 | **176**, 0 failures at seed 0 |
| browser assertions | 64 | **64** |
| BEAM sabotage falsifiers | 39 · 0 not | **40 · 0 not** |
| host acceptance checks | 38 held · 0 failed | **44 held · 0 failed** |
| host sabotage falsifiers | — | **5 · 0 not** |
| residual descriptors, after everything | 1 per channel ever opened, ∞ per rejected command | **0** |

---

## 1 · Your reading of OTP was right, and I measured it directly rather than inferring it

Built the sink first and used it as the instrument, so the mechanism is a measurement
rather than a reading of the docs. On OTP 28, against a descriptor whose only reference
was the handle under test:

```
:socket.open(fd, dup: false)   handle IS fd
  :socket.close/1 → :ok        fd still open
:socket.open(fd, dup: true)    handle is a NEW fd
  :socket.close/1 → :ok        the new fd closed · fd still open
```

**OTP closes what OTP created.** So `dup: false` is not "one descriptor, one owner", it
is one descriptor and *no* owner — and F.8.1 chose it for a reason that was exactly
backwards. `dup: true` is the only setting under which the socket handle frees anything
at all; the second descriptor is not waste, it is the one OTP can close.

And your `SCM_RIGHTS`-is-`dup(2)` argument settles the alternatives: I did not try to
hand the descriptor back, and there is no port program that could help.

## 2 · The correction: `dup(2)` does not copy `FD_CLOEXEC`

This is the part neither of us had, and it is the reason I did not just apply your round
as written.

A descriptor arrives close-on-exec because F.8.1 put `[:cmsg_cloexec]` on the receive.
`:socket.open(fd, %{dup: true})` hands back OTP's duplicate — and `dup(2)` does not copy
the flag, so the duplicate is **inheritable**. Measured:

```
received-like fd 18   cloexec
dup:true  → OTP fd 19 INHERITABLE   ← the fix for the leak, undoing the fix for inheritance
dup:false → handle 20 cloexec
```

Applying your prescription alone would have closed the descriptor leak and left the
runtime holding every live channel on a descriptor that survives `exec`. F.8.1's own
reasoning is what makes that unacceptable: it kept the flag precisely so the rule would
not rest on `erl_child_setup` closing descriptors above 2, and this would have made that
VM property the only thing standing between us and the hazard.

So the lifecycle has three steps, not two:

```
SCM_RIGHTS raw fd                 close-on-exec · ours · owned by nothing
  :socket.open(fd, dup: true)  →  an OTP-owned duplicate, inheritable
  set_cloexec/1                →  the flag dup(2) dropped, put back
  close_received/1             →  the raw fd is gone
  ... later :socket.close/1    →  OTP closes what OTP created
                                  residue: none
```

Stated plainly, because it is not zero: between OTP's `dup(2)` and `set_cloexec/1` there
is a window in which the duplicate is inheritable. `socket:open/2` has no close-on-exec
option, so it is closed as tightly as the API allows rather than as tightly as I would
like — and nothing on this VM can enter it, for the reason F.8.1 measured.

## 3 · `Ampd.NativeFd` — three syscalls, no dependency, and nothing that *makes* a descriptor

A NIF, as you said, not Rustler and not `elixir_make`: `ampd` has `deps: []` and that is
load-bearing rather than tidy. A twenty-line Mix compiler task builds it with the `cc`
already on the box — the same argument `fdpass.rs` makes for declaring `sendmsg` by hand.

Deliberately absent: `dup`, `socketpair`, `open`. The runtime has exactly one source of
unowned descriptors, and adding a second one to make the tests easier to write would
widen the thing this round exists to narrow. The cost is that the BEAM suite cannot
construct the case at all — which is honest, and is why the proof is where it is.

`close_received/1` **does not retry**, and the reason is in the code: Linux frees the
number before the error can be reported, so a retry can close a descriptor another thread
has since been handed, and this is a 24-core SMP VM.

**One sink, three call sites, no fourth exit:** the bind path, `HostBridge.close_fd/1`
for everything surplus or rejected, and the failed-adoption path.

## 4 · Two things I did beyond the round

**The bridge is adopted the same way a channel is.** The host `dup2`s it onto fd 3 and
clears `FD_CLOEXEC` deliberately, so it was the one *inheritable* descriptor the runtime
started life holding — and it held it that way for the life of the process. It now takes
a confined duplicate and sinks the raw number. Checked at boot, because `close(2)` frees
the *number* and the next socket the BEAM opens takes it; asked after the first bind,
this check reported a socket on fd 3 and meant nothing by it. That is now a comment in
the battery.

**A runtime with no sink refuses to open a bridge.** Without `Ampd.NativeFd` every
channel, surplus descriptor and rejected command leaks one permanently, and there is no
recovery — so the bridge is refused by name, on stderr, rather than opened. It is a
rule, so it has a BEAM falsifier of its own.

## 5 · The measurements are yours, exactly, and they are exact

`growth <= 14` for a claim of ten is gone. Every one of these is an equality against a
baseline the battery took itself, polled to convergence because the runtime tears
connections down in their own processes.

| | |
|---|---|
| the raw inherited bridge descriptor, at boot | **closed** |
| ten live channels | **exactly** base + 10 |
| every descriptor taken for a channel | close-on-exec, measured via `/proc/<ampd>/fdinfo` |
| closing all ten | **baseline** |
| 100 open/close cycles | **baseline** |
| 30 rejected commands × 3 rights | **baseline** |
| a bind + 4 surplus rights | base + 1, then **baseline** |

The rejected-command case needed two things that did not exist: `send_with_fds` (the host
could only ever send one, which is why that branch had never been entered by a
measurement) and three distinct refusal shapes — an unknown command, a frame that is not
JSON, and a bind whose actor is refused *after* the descriptor has arrived.

## 6 · Sabotage, at the OS boundary, because that is where the defect was

`tools/sabotage-host.sh` — each stubs one fix, runs the real host against a real runtime,
and requires the **named** check to go RED. All five falsify:

```
falsified   an adopted descriptor is disposed of
            → 21 sockets after closing, baseline was 11
falsified   F.8.1's dup:false adoption leaks one descriptor per channel
            → 19 sockets after closing, baseline was 9
falsified   a rejected command's descriptors are disposed of
            → 95 sockets after 30 rejected commands carrying 3 descriptors each
falsified   the FD_CLOEXEC that dup(2) drops is put back
            → 10 descriptors appeared, 10 of them would survive an exec
falsified   the inherited bridge descriptor is adopted, not merely wrapped
            → fd 3 in the runtime is socket:[…]
```

The third line is your finding, priced. 90 descriptors, from 30 refused commands, on a
path F.8.1 described as bounded by channels.

**And `release.sh` now runs them.** It refuses without `cargo` exactly as it refuses
without `mix`. F.8.1 is the whole argument: that release ran the chain, printed "every
gate green" on 42 vectors, 171 tests and 39 falsifiers, and packaged a zip — and the one
battery that could have seen the defect was not in the chain. A gate chain whose
measurement boundary stops at the language boundary will keep certifying whatever lies
outside it. `ampd/tools/sabotage.sh` is still out, and now says why: 4m40s, long enough
that wiring it in would get it skipped rather than run.

## 7 · Your table

| Finding | State |
|---|---|
| `dup:false = ownership` is false in `Bridge` | ✅ corrected · comment rewritten to say what it does |
| the same false model in `HostBridge.close_fd/1` | ✅ closed · **this was the unbounded one** |
| "bounded by channels, not traffic" | ✅ **withdrawn**, not carried forward · it was false |
| `growth <= 14` for a claim of ten | ✅ replaced by equalities against a measured baseline |
| retrying `close(2)` | ✅ does not · reason in the code |
| one ownership sink for every ancillary descriptor | ✅ one function, three call sites |
| `dup: true` drops `FD_CLOEXEC` | ⚠️ **not in the round; found and fixed** · §2 |
| the inherited bridge descriptor | ⚠️ not in the round; adopted and sunk · §4 |
| a runtime with no sink | ⚠️ not in the round; refuses to open a bridge · §4 |

## 8 · Open, and what I did not touch

1. **Nothing measured-and-not-fixed in the transport.** F.8.1's open question 1 is closed.
   Residue is zero, by equality, under sabotage.

2. **`app-prototype.html` still loads IBM Plex from Google.** Your ruling is accepted for
   the production WebView and I have not applied it to the prototype: it is a live
   marketing page whose typography is not a Tauri concern, and changing it this round
   would be changing a shipped surface for a component that does not exist yet. The
   constraint is recorded for the WebView round — bundled or system typography, no remote
   origins, CSP per Tauri's guidance.

3. **Engine confinement is on the ledger, not in this round**, per your instruction. The
   descriptor boundary is now stronger than the filesystem boundary, and `0700` protects
   against other users rather than against a same-UID agent. It wants a design round —
   Landlock, namespaces, or bubblewrap — between "the cockpit works" and any claim that a
   local agent is contained.

## 9 · The WebView, and I agree with your sequencing

Not started. When it is: the Rust host starts the durable world, takes the human control
channel, subscribes, receives a projection, derives the badge, and the WebView renders
it. No shadow world. `LIVE LOCAL` derived from runtime health + control channel + world
loaded + a current projection, all of which are already in `runtime-status@1` and the
continuity triple; `RECONNECTING` only once reacquisition exists. Then one real mutating
path — revoke a grant, through the human channel, no optimistic deletion — before
anything else is wired.

Tauri pinned at ≥ 2.11.1, capability-scoped IPC, no remote content.

## 10 · Ladder

    C1.1     Tauri Rust host + private transport
             ├─ F.6    CommandSpec · exact-set linearized · limits · pack digest
             ├─ F.7    inherited descriptors · identity lifetime · epoch ·
             │         demultiplexer · bounded projection
             ├─ F.8    CLOEXEC confinement · serialized writer ·
             │         continuity cursor · lossless paging
             ├─ F.8.1  durable host world · one owner per world              ✓
             └─ F.8.2  the receiver owns what it receives · zero residue ·
                       the flag dup(2) drops · host gates in the chain       ✓
             ── remaining: the WebView
    C1.1b    SQLite transactional persistence · durable revision
    C1.2     FabricProvider.Tailscale

## Verify

```
cd ampd && mix test                    # 176 tests, seed 0
bash tools/sabotage.sh                 # 40 falsified · 0 not   (4m40s)
cd .. && bash tools/release.sh         # full chain, now including both host gates
./host/target/release/super-host verify        # 44 held · 0 failed
bash tools/sabotage-host.sh                    # 5 falsified · 0 not
./host/target/release/super-host world         # where the durable world lives
```

The `.so` is not in the zip. It is twelve lines of C and a compiler task; one built for
another OTP or another architecture would not load, and the runtime would respond by
refusing to open a bridge — correctly, and unhelpfully.
