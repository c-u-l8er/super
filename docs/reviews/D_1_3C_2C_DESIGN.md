# D.1.3c·2c — Presented Terminal

**Design only. Nothing here is implemented.** Written against `23fb433`, with
D.1.3c·2b frozen at `ee3d0bc`.

## The proposition

    An ACTIVE `terminal-attachment@1` becomes an interactive terminal a person
    can see and type into, without the PTY master, any descriptor number, the
    choice of which terminal, the choice of what executable, or any ambient
    machine authority becoming reachable from the page.

c·2b established that a Peer *possesses* a terminal. Nothing renders it. The
c·2a review predicted exactly this state — possession with no presentation —
and it has arrived.

---

## 1 · The finding that decides the shape

**The cockpit's existing frame stream cannot carry terminal bytes.** Not
"should not": five independent reasons, each on its own sufficient.

**It coalesces on purpose.** `Delivery` in `cockpit/src/worker.rs` keeps one
frame in flight and *drops* superseded states, counting them into
`coalesced`. That is right for a projection, which is idempotent state where
only the newest matters. A byte stream is not idempotent state. Dropping a
superseded chunk corrupts the terminal.

**It polls at 80 ms.** The worker loop turns on an 80 ms tick. A keystroke
echo would wait that plus a valve round-trip, and both xterm.js and VS Code
treat post-keystroke latency as the number that matters.

**There is an 8192-byte transport cliff.** Under Tauri's direct-execute
threshold a frame is evaluated in the webview; over it, the body is parked in
a queue for the page to fetch, ending in a `.catch`. The worker already calls
this "two transports with two failure modes". A projection frame crosses 8192
only in a synthetic fixture. A terminal crosses it routinely.

**Retransmission cannot repair a lost frame.** `Channel::send` returning `Ok`
does not mean the JS ran (wry#1644), and Tauri's JS-side channel has its own
monotonic index — so a retransmit arrives *under a new index, buffered behind
the hole it was sent to fill*. The projection survives this because a later
snapshot subsumes a lost one. A byte stream has no later snapshot.

**`Ampd.Frame` caps at 256 KiB**, and the projection is already windowed to
stay under it.

**The command surface cannot carry them either.** `check-intent-surface.mjs`
enforces set equality between the cockpit's intent surface and
`Ampd.CommandSpec`'s human-control *mutations*, and refuses any intent that
is a read. A terminal read command would be the forbidden second way to learn
the world; a keystroke is not an authority mutation. Both surfaces are
currently untouched by terminals, so this is an open design rather than a
retrofit.

> **The conclusion is not "make the frame stream better".** It is that a
> terminal is a *third plane*, and the reasons above are what a plane
> boundary looks like when you find one rather than declare one.

---

## 2 · Three planes

    AUTHORITY   ampd, ordered            who may possess which terminal
                terminal-attachment@1    already frozen in c·2b

    CONTROL     the existing frame        that a possession exists, its
                stream, coalesced         status, and its geometry
                                          NO BYTES

    DATA        a separate, ordered,      the bytes, in both directions
                non-coalescing channel    NO AUTHORITY

The authority plane is done and must not be touched. The control plane gains
*at most* a projection row saying a terminal is possessed — a ref and a
status, the way `repositories` carries `ref` only. The data plane is new.

**The data plane carries no authority and decides nothing.** It is the same
rule the host's byte pump already follows: it moves bytes for an attachment
somebody else decided about.

---

## 3 · The data plane

### 3.1 Addressed by the record, opened by the World

A pane does not name a terminal. It presents an `attachment_ref` it was
*given*, and ampd re-derives — inside the total order — that the requesting
Peer possesses that exact ACTIVE attachment before any byte moves. This is
`resize/3`'s rule, unchanged: the epoch triple is read off the current
record, never supplied.

    open_terminal_stream(peer_ref, attachment_ref, attachment_epoch)
        ORDERED
        the same conjunction resize requires:
          record ACTIVE  AND  stream owner ACTIVE
        → a stream grant bound to that exact attachment incarnation

A stale `attachment_ref` opens nothing, for the reason `resize_record/3`
refuses `terminal-attachment-stale`.

### 3.2 One pane, one child webview, one capability file

A terminal pane is a child webview created with `Window::add_child`, which
already exists behind `SUPER_COCKPIT_PANE`. It gets **its own capability
file**, not `main`'s.

This is the W.2.1 lesson applied one object down: a Tauri `windows:` grant
reaches every webview *inside* that window, so a pane that inherited the
cockpit's grants would be a terminal renderer holding the cockpit's authority
surface. The pane's capability set should be exactly: bind its own data
channel, ack, and nothing else. No `frame_ack`, no intent submission.

### 3.3 Framing

Length-prefixed binary, one direction bit, and an ack. Explicitly **not** JSON
per chunk, and explicitly **not** the projection frame shape.

    to the page     seq · bytes
    from the page   bytes           (input needs no seq; see 3.4)
    from the page   ack seq         (the only control message on this plane)

`seq` exists so a gap is *detectable*. On this plane a gap is a fault, not
something to coalesce: the stream closes and the pane says so. A terminal that
silently skipped output would be worse than one that stopped.

---

## 4 · Backpressure

**The chain already exists end to end and this slice must not break it.**

    xterm.js write callback
        → page ack
            → ampd stops pulling
                → socketpair fills (host BUF is 64 KiB per direction, fixed)
                    → the host pump stops draining the master
                        → the Carrier blocks in write(2)

Every link is already built and measured except the first two. `read/3` on
`Ampd.TerminalAttachment` is already a **pull** API over `:socket.recv`, and
the host already documents "no unbounded relay buffer".

**The one place unbounded memory can appear is the reader nobody has written
yet.** ampd has no loop driving `read/3`. The BEAM's mailbox is unbounded even
though the socketpair is not, so a reader that pulls on a timer rather than on
an ack recreates the very problem the rest of the chain avoids.

    RULE  the pull is driven by the page's ack, never by a timer

Concretely, following xterm.js's own guidance: the page acks from the *write
callback* — the point at which the parser consumed the chunk — and ampd pulls
again only when outstanding unacked bytes fall below a low watermark. xterm.js
recommends keeping the high watermark under a few hundred KB for keystroke
latency, and its only internal defence is a discard watermark that **throws**,
documented as a parachute rather than a mechanism.

**Nothing on this plane may drop or coalesce.** The existing valve's
`coalesced` counter is correct for projections and would be corruption here.

---

## 5 · Resize is already done

`Ampd.Carrier.Terminal.resize/3` is out-of-band on the effect channel,
addressed by the epoch triple read off the current record, carries rows and
columns and no `TIOCSWINSZ`, refuses a stale attachment, and refuses in the
window where the World record is ACTIVE and the stream owner is not.

Every system surveyed puts resize in a separate message; roughly half put it
in-band on the byte channel. **Super should keep it out-of-band**, because
in-band resize would put a control decision on the plane that is defined as
carrying no authority.

The pane reports geometry; it does not apply it.

---

## 6 · The five exposures, and what stops each

| must not expose | how a naive pane leaks it | what stops it here |
| --- | --- | --- |
| PTY master | any surviving descriptor is re-nameable through `/proc/self/fd`, so a forgotten `CLOEXEC` *is* a path; a duplicate master also suppresses `SIGHUP`, which fires on last close | the pane never receives a descriptor. The far end is already a `socketpair` where every terminal `ioctl` answers `ENOTTY`, and the host mints its slave via `TIOCGPTPEER` without ever calling `ptsname` |
| descriptor numbers | an integer handle designates without authorizing, so a deputy re-resolves it under its own authority — Hardy's confused deputy, exactly | `terminal-attachment@1` carries opaque refs and epochs and no pid, descriptor or `/dev/pts` path. The pane addresses an attachment incarnation, and ampd resolves it against the requesting Peer's possession |
| which terminal | the client names a session and the server resolves that name with its own credentials | ordered re-derivation of possession before the stream opens, and a stale ref opening nothing. This is the c·2b contract reused rather than a new check |
| which executable | the server picks `argv[0]` and lets the client supply the rest, which for most programs names a different program | the pane cannot start anything. Payload identity is bound at Carrier admission (`carrier_basis`) and the confinement floor attests it; a terminal pane is downstream of a Carrier that already exists |
| ambient machine authority | the spawned shell inherits the server's environment and privilege | unchanged by this slice — and it must *stay* unchanged, which is why the pane gets its own capability file rather than the cockpit's |

**2c's whole security job is to not undo work that is already done.** Every
row above is held today by something frozen; the risk is the last hop.

---

## 7 · What would be new

Projected, to be re-derived at implementation rather than trusted:

    new supervised children     1  a reader per attachment, or one per pane
    new authority stores        0
    new durable stores          0
    new schemas                 2  a stream grant, and the wire frame
    new capability files        1  the pane's, deliberately not main's
    new mechanism classes       1  a second Channel with append-only semantics

The one genuinely new mechanism is the non-coalescing channel. Everything else
is an existing shape used again.

---

## 8 · Falsifiers this slice would need

1. a pane cannot open a stream for an attachment its Peer does not possess
2. a stale `attachment_ref` opens nothing
3. an attachment that stops being ACTIVE closes an open stream
4. the Carrier relation ending closes it, through the c·2b funnel
5. no descriptor, pid or pathname appears in any frame on the data plane
6. a gap in `seq` closes the stream rather than being skipped
7. a page that stops acking stalls the pump and does not grow the BEAM
8. and the Carrier blocks in `write`, measured, rather than output being lost
9. resuming acks resumes the stream with no bytes missing
10. the pane's capability file does not grant the cockpit's intent surface
11. a second pane for the same attachment is refused, or is a second reader
    with its own credit — decided, not left ambiguous
12. every frozen c·2b gate stays green

---

## 9 · Open questions, for ruling before implementation

**Q1 · One reader per attachment, or one per pane?** Two panes on one terminal
is either refused or is genuine multiplexing with independent credit. The
second is more useful and strictly harder; the first is honest. **Recommend:
refuse in 2c**, and say so in the schema rather than leaving it undefined.

**Q2 · Does the control plane learn that a terminal exists?** A projection row
would let the cockpit list possessed terminals. That crosses the
intent-surface gate's "no intent is a read" rule only if it becomes a
*command*; as a projection row it is fine. **Recommend: a ref and a status,
nothing else**, following `repositories`.

**Q3 · Does scrollback live anywhere?** xterm.js keeps 1000 rows by default.
If ampd keeps none, a reconnecting pane sees a blank terminal. If ampd keeps
any, it is unbounded memory with a new name. **Recommend: none in 2c**, and
state that a reattached pane starts empty.

**Q4 · Is the stream grant durable?** By the c·2b argument it should not be —
the runtime dying closes the socket and the host pump ends. **Recommend:
ephemeral**, same as the attachment.

---

## 10 · Why this is the right substrate for what comes after

A presented terminal is the first surface where a person *interacts with* a
confined Carrier rather than reading about one. Everything above it in the
stack has been projections and commands.

Once it exists, an application running inside a Worker can be driven and
observed through the same possession chain that governs everything else —
which is what makes a program built on this stack a real test of it rather
than a demonstration beside it. The interesting result is not that such a
program runs; it is which primitives it finds missing.

That test is worth more once the ordered-participant seam under it is settled,
which is why C1.0b·2 came first.
