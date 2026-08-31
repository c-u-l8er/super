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

use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::FromRawFd;

// --------------------------------------------------------- D.1.3c·1 · tty
//
// **`TCGETS` is `isatty`.** Not a call to libc's `isatty(3)`, which is that
// ioctl plus an errno convention: the fixture issues the request itself so
// that what the census sees is the request, and so that a refusal by Super's
// seccomp allow-list is indistinguishable here from the terminal not being
// one — which is correct, because from inside the Carrier those really are
// the same observation. The host is what can tell them apart.
//
// Both requests are on Super's `IOCTL_ALLOWED`. Everything else this file
// could ask for is refused, including `TIOCSWINSZ`: the payload may read its
// terminal's dimensions and may not choose them.
extern "C" {
    fn syscall(num: i64, ...) -> i64;
}

const SYS_IOCTL: i64 = 16;
const TCGETS: u64 = 0x5401;
const TIOCGWINSZ: u64 = 0x5413;

fn is_tty(fd: i32) -> bool {
    // `struct termios` is 60 bytes on x86-64; over-sized so a short write by
    // a kernel that disagrees cannot corrupt the stack.
    let mut buf = [0u8; 128];
    unsafe { syscall(SYS_IOCTL, fd as i64, TCGETS, buf.as_mut_ptr()) == 0 }
}

fn winsize(fd: i32) -> Option<(u16, u16)> {
    let mut ws = [0u16; 4];
    if unsafe { syscall(SYS_IOCTL, fd as i64, TIOCGWINSZ, ws.as_mut_ptr()) } == 0 {
        Some((ws[0], ws[1]))
    } else {
        None
    }
}

/// One canonical line from fd 0, byte at a time.
///
/// Not `BufReader`: a buffered reader would consume whatever else the
/// terminal had ready, and the next `HEAR` would answer out of a buffer
/// rather than out of the line discipline. Reading to the newline is also
/// what proves the discipline is *doing* something — in canonical mode the
/// kernel does not deliver a byte until the line is complete.
fn read_line_fd0() -> Option<String> {
    let mut fd0 = unsafe { std::fs::File::from_raw_fd(0) };
    let mut out = Vec::new();
    let mut b = [0u8; 1];
    let r = loop {
        match fd0.read(&mut b) {
            Ok(0) => break if out.is_empty() { None } else { Some(()) },
            Ok(_) if b[0] == b'\n' => break Some(()),
            Ok(_) => out.push(b[0]),
            Err(_) => break None,
        }
    };
    // fd 0 stays open: `File` would close it on drop, and this process is
    // asserted to hold exactly {0,1,2,3} for its whole life.
    std::mem::forget(fd0);
    r.map(|_| String::from_utf8_lossy(&out).trim_end_matches('\r').to_string())
}

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
            // --- D.1.3c·1 · terminal semantics ---------------------------
            //
            // **Three verbs, and they are on the CONTROL channel on purpose.**
            // The host drives; the terminal carries only the bytes under
            // test. That keeps the two directions separable — a failure says
            // which one broke — and it keeps this fixture from ever writing
            // to a descriptor it was not just told to write to, which is the
            // rule the HELLO handshake above already follows.
            //
            // `TTY` is deliberately not "am I sandboxed". It reports what
            // this process can observe *about the terminal it was handed*,
            // and the host checks it against what the host itself created.
            // The moduledoc's rule still holds: a Carrier's self-report is
            // never the evidence, only a second reading of it.
            "TTY" => {
                let (ok0, ok1, ok2) = (is_tty(0), is_tty(1), is_tty(2));
                match winsize(0) {
                    Some((r, c)) => format!("TTY {ok0} {ok1} {ok2} {r} {c}"),
                    None => format!("TTY {ok0} {ok1} {ok2} - -"),
                }
            }
            // Carrier → host. Written to fd 1, read by whoever holds the
            // master; a `\n` because the line discipline is what makes this
            // a terminal rather than a pipe, and the host asserts on the
            // `\r\n` the discipline turns it into.
            "SAY" => {
                let mut o = std::io::stdout();
                if write!(o, "{rest}\n").is_err() || o.flush().is_err() {
                    format!("SAY-FAILED")
                } else {
                    format!("SAID {}", rest.len())
                }
            }
            // Host → Carrier. One canonical line from fd 0, echoed back over
            // the *control* channel rather than the terminal, so that a
            // reply proves the read happened and cannot be confused with the
            // terminal's own echo of what the host just wrote.
            "HEAR" => match read_line_fd0() {
                Some(l) => format!("HEARD {l}"),
                None => "HEARD-EOF".to_string(),
            },
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
