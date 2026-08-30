//! `super-carrier-fixture` — the first Carrier, deliberately stupid.
//!
//! Its entire universe:
//!
//! ```text
//! start  →  handshake on fd 3  →  answer one word at a time  →  wait  →  exit
//! ```
//!
//! It is not a shell, not an interpreter, not a Motor. It cannot open a file
//! it was not handed, cannot start a process, and has no code path that reads
//! a pathname. That is the point: **a Carrier with no general capability makes
//! any capability it turns out to have attributable to the host**, because
//! there is nowhere else it could have come from. A `bash` first Carrier would
//! have told us nothing — everything it could reach would be explicable by
//! `bash` being `bash`.
//!
//! # It does not witness its own confinement
//!
//! There is deliberately no `report-my-fds` verb and no `am-i-sandboxed`
//! verb. Under the real policy the fixture cannot even read `/proc/self/fd`
//! — measured — so a self-census would report an error and a *permissive*
//! policy would report a clean bill of health. Both answers are useless. The
//! host reads `/proc/<pid>/` from outside, which is the only vantage point
//! from which the answer is evidence.
//!
//! The verbs it does have exist so the host can prove the process is *this*
//! Carrier and not merely *a* process: `IDENT` echoes the incarnation the
//! host minted, and `ECHO` proves the control descriptor is live in both
//! directions rather than merely open.
//!
//! # Wire
//!
//! Newline-delimited ASCII words on fd 3, request and response. Not the
//! runtime's length-prefixed JSON frame: a Carrier control channel is not a
//! command channel and must not be able to become one by having the same
//! shape. `Ampd.Frame` is avoided one layer up for exactly this reason.

use std::io::{BufRead, BufReader, Write};
use std::os::fd::FromRawFd;

/// The control descriptor. Fixed at 3 by the host's `dup_onto`, never
/// discovered, never searched for. A Carrier that hunted for its own control
/// channel would be doing addressing-by-name inside the process that D.1.3a
/// spent itself teaching to address by possession.
const CONTROL_FD: i32 = 3;

const PROTOCOL: &str = "super-carrier";
const PROTOCOL_VERSION: &str = "1";

fn main() {
    // SAFETY: the host places the control channel on fd 3 before `exec` and
    // this process has done nothing since. If fd 3 is not the channel, the
    // handshake below fails and the host refuses the incarnation — which is
    // the correct outcome and not one this process can talk itself out of.
    let sock = unsafe { std::fs::File::from_raw_fd(CONTROL_FD) };

    // Read and write through `&File`, never `try_clone()`.
    //
    // `try_clone` is a `dup(2)`, and the duplicate arrives as fd 4 — a
    // descriptor the host never handed over, in a process whose descriptor
    // table the host asserts is exactly `{0,1,2,3}`. It refers to the same
    // open file description, so it grants nothing new; that is precisely why
    // it is worth refusing. A census that tolerated one harmless extra
    // descriptor would have to tolerate the next one on the same grounds,
    // and "exact" would quietly become "about four".
    let mut out = &sock;
    let mut lines = BufReader::new(&sock).lines();

    // The host speaks first. A Carrier that announced itself unprompted would
    // be a Carrier whose first act is to write to a descriptor it has not yet
    // been told is the right one.
    let incarnation = match lines.next() {
        Some(Ok(l)) if l.starts_with("HELLO ") => l[6..].trim().to_string(),
        _ => std::process::exit(65),
    };

    if writeln!(out, "READY {PROTOCOL} {PROTOCOL_VERSION} {incarnation}").is_err() {
        std::process::exit(66);
    }
    let _ = out.flush();

    for line in lines {
        let line = match line {
            Ok(l) => l,
            // EOF or a broken channel. The host closing the control channel
            // is how a Carrier is told to stop; there is no other signal it
            // is required to understand, and `kill` is denied to it anyway.
            Err(_) => break,
        };
        let mut it = line.trim().splitn(2, ' ');
        let verb = it.next().unwrap_or("");
        let rest = it.next().unwrap_or("");

        let reply = match verb {
            "IDENT" => format!("IDENT {PROTOCOL} {PROTOCOL_VERSION} {incarnation}"),
            "ECHO" => format!("ECHO {rest}"),
            "EXIT" => break,
            "" => continue,
            // A closed vocabulary. An unknown word is refused by name rather
            // than ignored, so a host that thinks it is talking to a newer
            // fixture finds out.
            other => format!("REFUSED unknown-verb {other}"),
        };
        if writeln!(out, "{reply}").is_err() {
            break;
        }
        let _ = out.flush();
    }
    std::process::exit(0);
}
