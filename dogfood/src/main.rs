//! `super-dogfood` — Super Self-Hosting **R0a · I Speak**.
//!
//! The first Carrier payload whose bytes are its own.
//!
//! # What was missing, and it was not a pipe
//!
//! D.1.3c·2c·1c B5 drove the whole product terminal for real — a person's
//! click, a real webview, a real presentation, a real xterm — and measured
//! it carrying **zero bytes** in eight seconds while sending thirty-three
//! liveness beats. Nothing was broken. There was simply no product path that
//! could put a byte on it: `serve_carrier` has no op that makes a Carrier
//! write, and the only installed payload — `super-carrier-fixture` — touches
//! its terminal in exactly one arm, `SAY`, reached only from the
//! host-owned control channel.
//!
//! So the terminal had stopped finding terminal defects and had found the
//! absence of the thing the terminal is for. This file is that thing, at its
//! smallest.
//!
//! # This is a PAYLOAD, and deliberately not a Motor
//!
//! `Ampd.Carrier`'s chain is `Actor → Peer → Locus → Worker → Carrier →
//! Motor`, and `MOTOR_MACHINE_RESEARCH_BRIEF_FOR_OPUS.md` scopes a Motor as
//! *a bounded policy artifact that proposes actions against a typed Machine
//! contract*. This proposes nothing and decides nothing. It occupies the
//! **payload** slot — the source's own word, and the word the execution
//! basis uses (`payload_digest`) — in the same position a Motor will
//! eventually occupy. Calling it a Motor now would name a seam that has not
//! been designed yet.
//!
//! # No `SAY`, and that absence is the point
//!
//! `super-carrier-fixture` has a `SAY <text>` verb; it is how
//! `super-host verify` makes a Carrier speak, and it is why the fixture
//! could never close B5 — bytes that arrive because the host asked for them
//! prove the pipe, not the producer. **This payload has no verb that makes
//! it write to its terminal.** There is nothing a host, a test, a page or a
//! runtime can send that produces the marker. The only way the marker
//! reaches a screen is that this process, running inside a confined Carrier,
//! wrote it to the terminal it was handed.
//!
//! That is what makes R0a's falsifier possible: remove the write below and
//! the marker cannot appear by any other route, so the assertion goes red
//! for exactly one reason.
//!
//! # Why after the handshake
//!
//! The host speaks first — `HELLO <incarnation>` on fd 3 — and this answers
//! `READY`. Only then does it write to the terminal. Not caution about the
//! descriptor: the host placed 0/1/2 on the pty slave before `exec` and they
//! are not in doubt. It is that **the handshake is where this process learns
//! it is this incarnation**, and the identity line below quotes what the
//! host said rather than what the environment claims. A payload that
//! announced itself before being told who it was would be printing a name
//! it had assumed.
//!
//! # Wire
//!
//! Newline-delimited ASCII words on fd 3, identical to the fixture's,
//! because the control protocol is the host↔Carrier contract and a second
//! payload does not get a second protocol. `carrier_protocol` and
//! `carrier_protocol_version` are fields of the attested execution basis;
//! answering anything else here would move the basis and refuse every start.

use std::io::{BufRead, BufReader, Write};
use std::os::fd::FromRawFd;

/// Fixed at 3 by the host's `dup_onto`, never discovered, never searched
/// for. A Carrier that hunted for its own control channel would be doing
/// addressing-by-name inside the process D.1.3a spent itself teaching to
/// address by possession.
const CONTROL_FD: i32 = 3;

const PROTOCOL: &str = "super-carrier";
const PROTOCOL_VERSION: &str = "1";

/// **The marker, spelled once.**
///
/// `tools/terminal-join-probe.mjs` asserts this exact string appears in a
/// real xterm after traversing the real PTY, the real attachment, the real
/// Plane, the real Tauri Channel and the real write callback. It is a
/// constant here and a literal there on purpose: two independent spellings
/// is what makes the probe's success mean the byte arrived rather than mean
/// the two files agree.
const MARKER: &str = "SUPER-DOGFOOD-R0-READY";

fn main() {
    // SAFETY: the host places the control channel on fd 3 before `exec` and
    // this process has done nothing since. If fd 3 is not the channel the
    // handshake fails, the host refuses the incarnation, and that is the
    // correct outcome — not one this process can talk itself out of.
    let sock = unsafe { std::fs::File::from_raw_fd(CONTROL_FD) };

    // Read and write through `&File`, never `try_clone()`: a `dup(2)` lands
    // on fd 4, in a process whose descriptor table the floor asserts is
    // exactly `{0,1,2,3}`. It refers to the same open file description and
    // grants nothing new, which is precisely why it is worth refusing — a
    // census that tolerated one harmless extra descriptor would have to
    // tolerate the next one on the same grounds.
    let mut out = &sock;
    let mut lines = BufReader::new(&sock).lines();

    let incarnation = match lines.next() {
        Some(Ok(l)) if l.starts_with("HELLO ") => l[6..].trim().to_string(),
        _ => std::process::exit(65),
    };

    if writeln!(out, "READY {PROTOCOL} {PROTOCOL_VERSION} {incarnation}").is_err() {
        std::process::exit(66);
    }
    let _ = out.flush();

    // ---------------------------------------------------------- I speak
    //
    // **fd 1, which the host made this Carrier's terminal, and nothing
    // else.** No host verb stands behind these two lines and no test can
    // reach them. `\n` and not `\r\n`: the line discipline is what turns one
    // into the other, and asserting on the discipline's own output is how
    // D.1.3c·1 proved this is a terminal rather than a pipe.
    //
    // **Written before anyone is necessarily watching, and that is correct.**
    // A person clicks *Watch terminal* after the Carrier is running, so
    // these bytes sit in the kernel's tty buffer until the first reader
    // attaches — held by the line discipline, not replayed by Super, which
    // stores nothing and must not start. If the buffer ever overflowed
    // before an attachment, the Carrier would block in `write(2)`, which is
    // the same backpressure every other link on this path uses.
    {
        let mut t = std::io::stdout();
        if writeln!(t, "{MARKER}").is_err() || t.flush().is_err() {
            // A payload that cannot reach its own terminal is not a Carrier
            // this round has any use for, and failing loudly here is better
            // than a live Carrier that silently never speaks — which is
            // exactly the state B5 measured and could not attribute.
            std::process::exit(67);
        }
        // The identity line, from what the HOST said in `HELLO` — not from
        // `SUPER_CARRIER_INCARNATION`, which this process could have been
        // handed by anyone who could set its environment. Same fact, better
        // provenance, and the difference costs nothing.
        let _ = writeln!(t, "carrier {incarnation}");
        let _ = t.flush();
    }

    // ------------------------------------------------- and then it waits
    //
    // The same closed vocabulary as the fixture minus the two verbs that
    // would undermine the point: no `SAY`, because nothing may make this
    // payload speak; and no `HEAR`, because reading the terminal is the
    // input half and D.1.3c's scope is OBSERVE. `IDENT` and `ECHO` remain
    // so the host can still prove this is *this* Carrier and that the
    // control descriptor is live in both directions.
    for line in lines {
        let Ok(line) = line else { break };
        let mut it = line.trim().splitn(2, ' ');
        let verb = it.next().unwrap_or("");
        let rest = it.next().unwrap_or("");

        let reply = match verb {
            "IDENT" => format!("IDENT {PROTOCOL} {PROTOCOL_VERSION} {incarnation}"),
            "ECHO" => format!("ECHO {rest}"),
            "" => continue,
            // Refused by name rather than ignored, so a host that thinks it
            // is talking to the fixture finds out which payload it has.
            other => format!("REFUSED unknown-verb {other}"),
        };
        if writeln!(out, "{reply}").is_err() {
            break;
        }
        let _ = out.flush();
    }
    std::process::exit(0);
}
