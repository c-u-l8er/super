//! The bridge's transport (T28, A-28; `superlane/t28/TASK.md`).
//!
//! **Linux keeps its `SOCK_SEQPACKET` bridge.** By default every function here is the `fdpass` function T27b left,
//! called unchanged: one command is one record, one reply is one record, and the rights ride the record.
//!
//! **macOS has no `SOCK_SEQPACKET` for `AF_UNIX`** (MP0, `superlane/t28/MP0-RESULT.md`), so there the bridge is a
//! `SOCK_STREAM` socketpair carrying the runtime's existing frame, `len (u32, big-endian) ‖ body`, where the body is
//! exactly what one SEQPACKET record carries today. The protocol does not change; only its transport does. On Linux the
//! cargo feature `framed-bridge` (tests only) selects the same framed transport, so Linux runs can catch its bugs.
//!
//! The framed rules (DESIGN §3), each held by a law in `superlane/t28/TASK.md`:
//! * **R1** a frame's rights ride the `sendmsg` that carries the frame's first byte, at most [`MAX_BRIDGE_FDS`];
//! * **R2** a short write is finished without them (re-attaching them would duplicate every descriptor); `EINTR`
//!   before any byte is retried with them;
//! * **R3** a receiver never asks past the current frame: 4 bytes of prefix, then exactly the body;
//! * **R4** every read is a `recvmsg` with a control buffer (room for [`RIGHTS_ROOM`]); on XNU a plain read installs
//!   rights nobody can name;
//! * **R5** rights are accepted only with the read that consumed the frame's first byte; on any later read they are a
//!   violation, sunk, and the frame is refused (the stream is still aligned, so the bridge stays);
//! * **R6** a short read is never a frame: a 1–3 byte prefix keeps reading, and a close inside a frame is a closed
//!   bridge with a truncated frame, never a frame.
//!
//! **A frame begun is a frame finished, or the bridge is closed for good.** A caller's deadline is checked only before a
//! frame's first byte, in both directions. After that byte the rest must move within [`FRAME_REST_LIMIT`]; if it does
//! not, the error says so ([`closes_for_good`]) and the caller marks the bridge closed, because half a frame left on
//! the wire would be read by the next call as a prefix.

use crate::fdpass::{self, Pair};
use std::io;
use std::os::unix::io::RawFd;
use std::time::Duration;

/// The most rights one frame may carry. Today's largest is 5 (the battery's bind with 4 surplus).
pub const MAX_BRIDGE_FDS: usize = 16;
/// A framed receiver's room for rights: four times what a conforming sender may attach, so one is never truncated.
pub const RIGHTS_ROOM: usize = 64;
/// How long the rest of a frame may take once its first byte has moved.
pub const FRAME_REST_LIMIT: Duration = Duration::from_secs(5);
/// The longest command the runtime reads whole (R125: today's Linux limits, now named).
pub const TO_RUNTIME_MAX: usize = fdpass::BRIDGE_COMMAND_MAX;
/// The longest reply the host reads whole.
pub const TO_HOST_MAX: usize = fdpass::BRIDGE_REPLY_MAX;

/// The prefix of every error after which the bridge cannot be used again: the peer closed it, or a frame was begun and
/// not finished, so the stream is no longer aligned.
pub const GONE: &str = "bridge-closed";

/// Whether `e` leaves the bridge unusable for good. Never true on the Linux default, where a record is all or nothing.
pub fn closes_for_good(e: &io::Error) -> bool {
    e.to_string().starts_with(GONE)
}

/// Whether `e` refused a framed reply that was read whole (rights on it, empty, or rights off its first byte), so the
/// reply is consumed and no longer owed. Never true on the Linux default.
pub fn consumed(e: &io::Error) -> bool {
    let m = e.to_string();
    e.kind() == io::ErrorKind::InvalidData
        && ["rights-on-reply:", "empty-reply:", "invalid-bridge-frame:"].iter().any(|p| m.starts_with(p))
}

// ------------------------------------------------------------------ the selector
//
// One line chooses the transport. Linux by default: SEQPACKET. macOS, or the test feature: the frame.

#[cfg(all(target_os = "linux", not(feature = "framed-bridge")))]
use self::seqpacket as imp;
#[cfg(any(target_os = "macos", feature = "framed-bridge"))]
use self::framed as imp;

/// The bridge pair. `Pair.0` is the host's; `Pair.1` goes to the runtime as fd 3.
pub fn pair() -> io::Result<Pair> {
    imp::pair()
}

/// Send one command that carries no descriptor.
pub fn send_plain(sock: RawFd, bytes: &[u8]) -> io::Result<()> {
    imp::send_command(sock, bytes, &[], false)
}

/// [`send_plain`] that never waits before the command's first byte: `WouldBlock` while the runtime is not reading.
pub fn send_plain_nowait(sock: RawFd, bytes: &[u8]) -> io::Result<()> {
    imp::send_command(sock, bytes, &[], true)
}

/// Send one command with `fds` in the same command.
pub fn send_with_fds(sock: RawFd, bytes: &[u8], fds: &[RawFd]) -> io::Result<()> {
    imp::send_command(sock, bytes, fds, false)
}

/// Receive one reply. On the Linux default an empty `Ok` is the runtime's close (T27b round 3), as before.
pub fn recv(sock: RawFd) -> io::Result<Vec<u8>> {
    imp::recv_reply(sock, false)
}

/// [`recv`] that never waits before the reply's first byte: `WouldBlock` while none has arrived.
pub fn recv_nowait(sock: RawFd) -> io::Result<Vec<u8>> {
    imp::recv_reply(sock, true)
}

/// The Linux default: T27b's `fdpass` functions, called unchanged. (Built on Linux under the test feature too, unused.)
#[cfg(target_os = "linux")]
#[cfg_attr(feature = "framed-bridge", allow(dead_code))]
mod seqpacket {
    use super::*;

    pub fn pair() -> io::Result<Pair> {
        fdpass::pair_seqpacket()
    }

    pub fn send_command(sock: RawFd, bytes: &[u8], fds: &[RawFd], nowait: bool) -> io::Result<()> {
        match (fds.is_empty(), nowait) {
            (true, false) => fdpass::send_bridge_plain(sock, bytes),
            (true, true) => fdpass::send_bridge_plain_nowait(sock, bytes),
            (false, _) => fdpass::send_bridge_with_fds(sock, bytes, fds),
        }
    }

    pub fn recv_reply(sock: RawFd, nowait: bool) -> io::Result<Vec<u8>> {
        if nowait {
            fdpass::recv_msg_nowait(sock, fdpass::BRIDGE_REPLY_MAX)
        } else {
            fdpass::recv_msg(sock, fdpass::BRIDGE_REPLY_MAX)
        }
    }
}

/// The framed transport: macOS, the test feature on Linux, and every test build (the laws drive it on real pairs).
#[cfg(any(target_os = "macos", feature = "framed-bridge", test))]
pub mod framed {
    use super::*;
    use std::time::Instant;

    fn gone(why: impl std::fmt::Display) -> io::Error {
        io::Error::new(io::ErrorKind::BrokenPipe, format!("{GONE}: {why}"))
    }

    fn refused(why: impl std::fmt::Display) -> io::Error {
        io::Error::new(io::ErrorKind::InvalidData, why.to_string())
    }

    /// An unnamed `AF_UNIX` stream pair (possession, never a path), both ends close-on-exec as `fdpass` makes them.
    pub fn pair() -> io::Result<Pair> {
        fdpass::pair_stream()
    }

    /// A command to the runtime: the host's refusals of an empty or over-long command, by name, before anything is
    /// written (as `fdpass::send_bridge_*` refuses them on SEQPACKET), then one frame.
    pub fn send_command(sock: RawFd, bytes: &[u8], fds: &[RawFd], nowait: bool) -> io::Result<()> {
        if bytes.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "empty-command: the host sends no empty bridge command",
            ));
        }
        send(sock, bytes, fds, TO_RUNTIME_MAX, nowait)
    }

    /// Send one frame of `body` with `fds` (R1, R2). Over `limit` bytes, or over [`MAX_BRIDGE_FDS`] rights, it is
    /// refused by name before anything is written. `nowait`: `WouldBlock` if not even the first byte can move now, and
    /// the bridge is untouched. After the first byte the rest moves within [`FRAME_REST_LIMIT`], or the bridge is
    /// closed for good.
    pub fn send(sock: RawFd, body: &[u8], fds: &[RawFd], limit: usize, nowait: bool) -> io::Result<()> {
        if fds.len() > MAX_BRIDGE_FDS {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("too-many-rights: {} descriptors on one frame; the limit is {MAX_BRIDGE_FDS}", fds.len()),
            ));
        }
        if body.len() > limit {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("frame-too-large: a {}-byte frame; the limit is {limit}", body.len()),
            ));
        }
        let mut frame = Vec::with_capacity(4 + body.len());
        frame.extend_from_slice(&(body.len() as u32).to_be_bytes());
        frame.extend_from_slice(body);
        let mut sent = 0usize;
        let mut pending = true;
        let mut until: Option<Instant> = None;
        while sent < frame.len() {
            let part = &frame[sent..];
            let carry: &[RawFd] = if pending { fds } else { &[] };
            let flags = if nowait || sent > 0 { libc::MSG_DONTWAIT } else { 0 };
            match fdpass::send_part(sock, part, carry, flags) {
                Ok(0) => return Err(gone("sendmsg took no byte of a frame")),
                Ok(n) => {
                    sent += n;
                    pending = false;
                    until.get_or_insert_with(|| Instant::now() + FRAME_REST_LIMIT);
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock && sent == 0 && nowait => return Err(e),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock && sent > 0 => {
                    let d = until.expect("set by the first byte");
                    if !fdpass::wait_ready(sock, libc::POLLOUT, Some(d))? {
                        return Err(gone("the rest of a frame could not be written within the frame limit"));
                    }
                }
                Err(e) if sent > 0 => return Err(gone(format!("a frame begun and not finished: {e}"))),
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }

    /// A reply from the runtime: one frame, at most [`TO_HOST_MAX`] bytes. A reply carrying rights is refused and its
    /// rights closed; a zero-length reply is refused by name (it is consumed, and it is not the runtime's close).
    pub fn recv_reply(sock: RawFd, nowait: bool) -> io::Result<Vec<u8>> {
        let (body, fds) = recv(sock, TO_HOST_MAX, nowait)?;
        if !fds.is_empty() {
            sink(&fds);
            return Err(refused("rights-on-reply: the runtime attached descriptors to a reply; they are closed"));
        }
        if body.is_empty() {
            return Err(refused("empty-reply: a zero-length reply frame (consumed; not the runtime's close)"));
        }
        Ok(body)
    }

    /// Close every descriptor in `fds`.
    pub fn sink(fds: &[RawFd]) {
        for fd in fds {
            fdpass::close_fd(*fd);
        }
    }

    /// Receive exactly one frame (R3–R6) and the rights that rode its first byte. `nowait`: `WouldBlock` while no
    /// byte of a frame has arrived, and nothing is consumed. Rights on any later read of the frame are a violation:
    /// every right the frame brought is sunk and the frame refused, the bridge staying usable. An announced length
    /// over `limit` is refused before the body is read and closes the bridge for good (the stream is unaligned).
    pub fn recv(sock: RawFd, limit: usize, nowait: bool) -> io::Result<(Vec<u8>, Vec<RawFd>)> {
        let mut prefix = [0u8; 4];
        let first = fdpass::recv_part(sock, &mut prefix, RIGHTS_ROOM, if nowait { Some(Instant::now()) } else { None })?;
        let Some(first) = first else { return Err(io::Error::from(io::ErrorKind::WouldBlock)) };
        if first.n == 0 {
            return Err(gone("the peer closed the bridge at a frame boundary"));
        }
        let rights = first.fds;
        let mut late: Vec<RawFd> = Vec::new();
        let mut truncated = first.ctrunc;
        let mut got = first.n;
        let until = Instant::now() + FRAME_REST_LIMIT;
        while got < 4 {
            let p = rest(sock, &mut prefix[got..], until, &rights, &late)?;
            late.extend(p.fds);
            truncated |= p.ctrunc;
            got += p.n;
        }
        let len = u32::from_be_bytes(prefix) as usize;
        if len > limit {
            sink(&rights);
            sink(&late);
            return Err(gone(format!("frame-too-large: a {len}-byte frame announced; the limit is {limit}")));
        }
        let mut body = vec![0u8; len];
        let mut b = 0usize;
        while b < len {
            let p = rest(sock, &mut body[b..], until, &rights, &late)?;
            late.extend(p.fds);
            truncated |= p.ctrunc;
            b += p.n;
        }
        if !late.is_empty() || truncated {
            sink(&rights);
            sink(&late);
            return Err(refused(if truncated {
                "invalid-bridge-frame: more rights than the receiver's room; those that landed are closed"
            } else {
                "invalid-bridge-frame: rights not on the frame's first byte; every right it brought is closed"
            }));
        }
        Ok((body, rights))
    }

    /// One read of the rest of a frame, waiting no later than `until`. A close here, or no byte by `until`, ends the
    /// bridge for good, and every right the frame brought so far is sunk.
    fn rest(sock: RawFd, buf: &mut [u8], until: Instant, rights: &[RawFd], late: &[RawFd]) -> io::Result<fdpass::Part> {
        match fdpass::recv_part(sock, buf, RIGHTS_ROOM, Some(until))? {
            Some(p) if p.n > 0 => Ok(p),
            Some(p) => {
                sink(rights);
                sink(late);
                sink(&p.fds);
                Err(gone("the peer closed the bridge inside a frame; the truncated frame is dropped"))
            }
            None => {
                sink(rights);
                sink(late);
                Err(gone("the rest of a frame did not arrive within the frame limit"))
            }
        }
    }
}
