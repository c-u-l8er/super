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

/// The framed transport: selected on macOS and under the test feature on Linux; built on every target, so the laws
/// drive it on real pairs in any build and a plant that selects it on the Linux default still compiles.
pub mod framed {
    use super::*;
    use std::time::Instant;

    fn gone(why: impl std::fmt::Display) -> io::Error {
        io::Error::new(io::ErrorKind::BrokenPipe, format!("{GONE}: {why}"))
    }

    fn refused(why: impl std::fmt::Display) -> io::Error {
        io::Error::new(io::ErrorKind::InvalidData, why.to_string())
    }

    /// The prefix: the body's length as a big-endian `u32` (the runtime's existing frame; `Wire` and `HostBridge`).
    pub fn prefix_of(len: usize) -> [u8; 4] { (len as u32).to_be_bytes() }
    fn len_of(prefix: [u8; 4]) -> usize { u32::from_be_bytes(prefix) as usize }

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
        frame.extend_from_slice(&prefix_of(body.len()));
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
                    pending = pending && carry.is_empty();
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
        let len = len_of(prefix);
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

// ------------------------------------------------------------------ T28's laws, the host's side
#[cfg(test)]
mod laws {
    //! T28's laws on the host's side of the framed bridge (`superlane/t28/TASK.md`): L1–L7, L9 and L10, on real
    //! socketpairs. Each test is named `lN_…` for its law, and `superlane/t28/laws.py` scores the plants by those
    //! names. They run one at a time (they count this process's descriptors), built with `--features framed-bridge`,
    //! where births and arrivals behave as on macOS. Each law's tests assert only what that law says, so a plant is
    //! caught by its own law alone: L3 only counts descriptors, L2 only binds them to frames, and only L1 writes the
    //! prefix by hand (the other raw peers use `framed::prefix_of`).
    use super::framed;
    use crate::fdpass::{self, Pair};
    use std::os::unix::io::RawFd;
    use std::time::{Duration, Instant};

    fn serial() -> std::sync::MutexGuard<'static, ()> {
        fdpass::t27b_serial()
    }

    fn pair() -> Pair {
        framed::pair().expect("a framed pair")
    }

    fn close_pair(p: &Pair) {
        fdpass::close_fd(p.0);
        fdpass::close_fd(p.1);
    }

    fn open_fds() -> usize {
        std::fs::read_dir("/proc/self/fd").expect("/proc/self/fd").count()
    }

    /// `n` distinct open files to send: the read ends of pipes whose write ends are closed at once.
    fn pipes(n: usize) -> Vec<RawFd> {
        (0..n)
            .map(|_| {
                let mut p = [0; 2];
                assert_eq!(unsafe { libc::pipe2(p.as_mut_ptr(), libc::O_CLOEXEC) }, 0);
                fdpass::close_fd(p[1]);
                p[0]
            })
            .collect()
    }

    fn ino(fd: RawFd) -> (u64, u64) {
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        assert_eq!(unsafe { libc::fstat(fd, &mut st) }, 0, "fstat {fd}");
        (st.st_dev as u64, st.st_ino as u64)
    }

    fn inos(fds: &[RawFd]) -> Vec<(u64, u64)> {
        fds.iter().map(|f| ino(*f)).collect()
    }

    fn sink(fds: &[RawFd]) {
        for f in fds {
            fdpass::close_fd(*f);
        }
    }

    /// A raw peer's write of all of `bytes`, `fds` on its first byte.
    fn raw(sock: RawFd, bytes: &[u8], fds: &[RawFd]) {
        let (mut sent, mut carry) = (0usize, fds);
        while sent < bytes.len() {
            sent += fdpass::send_part(sock, &bytes[sent..], carry, 0).expect("a raw send");
            carry = &[];
        }
    }

    fn wire(body: &[u8]) -> Vec<u8> {
        let mut v = framed::prefix_of(body.len()).to_vec();
        v.extend_from_slice(body);
        v
    }

    fn soon() -> Option<Instant> {
        Some(Instant::now() + Duration::from_secs(5))
    }

    // ---- L1 · one frame is one record

    #[test]
    fn l1_the_wire_bytes_are_a_big_endian_u32_length_and_the_body() {
        let _s = serial();
        let p = pair();
        framed::send(p.0, b"abc", &[], 4096, false).unwrap();
        let mut buf = [0u8; 64];
        let part = fdpass::recv_part(p.1, &mut buf, 4, soon()).unwrap().expect("bytes");
        assert_eq!(&buf[..part.n], &[0, 0, 0, 3, b'a', b'b', b'c'], "the wire bytes");
        close_pair(&p);
    }

    #[test]
    fn l1_frames_of_0_to_4096_bytes_one_to_a_write_read_back_as_that_sequence() {
        let _s = serial();
        let p = pair();
        let bodies: Vec<Vec<u8>> = [0usize, 1, 2, 3, 4, 5, 255, 256, 1000, 4095, 4096]
            .iter()
            .map(|&n| (0..n).map(|i| (i * 7 + n) as u8).collect())
            .collect();
        let (w, bs) = (p.0, bodies.clone());
        let t = std::thread::spawn(move || {
            for b in &bs {
                framed::send(w, b, &[], 4096, false).unwrap();
            }
        });
        for b in &bodies {
            assert_eq!(&framed::recv(p.1, 4096, false).unwrap().0, b);
        }
        t.join().unwrap();
        close_pair(&p);
    }

    #[test]
    fn l1_several_frames_in_one_write_read_back_as_that_sequence() {
        let _s = serial();
        let p = pair();
        let bodies: Vec<Vec<u8>> = vec![b"one".to_vec(), vec![], b"three".to_vec(), vec![9u8; 4096]];
        let all: Vec<u8> = bodies.iter().flat_map(|b| wire(b)).collect();
        raw(p.0, &all, &[]);
        for b in &bodies {
            assert_eq!(&framed::recv(p.1, 4096, false).unwrap().0, b);
        }
        close_pair(&p);
    }

    #[test]
    fn l1_a_zero_length_frame_is_one_frame() {
        let _s = serial();
        let p = pair();
        framed::send(p.0, b"", &[], 4096, false).unwrap();
        framed::send(p.0, b"next", &[], 4096, false).unwrap();
        assert_eq!(framed::recv(p.1, 4096, false).unwrap().0, b"");
        assert_eq!(framed::recv(p.1, 4096, false).unwrap().0, b"next");
        close_pair(&p);
    }

    // ---- L2 · a descriptor belongs to its frame

    #[test]
    fn l2_frames_a_b_c_written_before_the_reader_runs_each_get_their_own_rights() {
        let _s = serial();
        let p = pair();
        let (b1, c2) = (pipes(1), pipes(2));
        framed::send(p.0, b"A", &[], 4096, false).unwrap();
        framed::send(p.0, b"B", &b1, 4096, false).unwrap();
        framed::send(p.0, b"C", &c2, 4096, false).unwrap();
        let (a, fa) = framed::recv(p.1, 4096, false).unwrap();
        let (b, fb) = framed::recv(p.1, 4096, false).unwrap();
        let (c, fc) = framed::recv(p.1, 4096, false).unwrap();
        assert_eq!((a.as_slice(), b.as_slice(), c.as_slice()), (&b"A"[..], &b"B"[..], &b"C"[..]));
        assert!(fa.is_empty(), "A got {} rights", fa.len());
        assert_eq!(inos(&fb), inos(&b1), "B's right is the file sent with B");
        assert_eq!(inos(&fc), inos(&c2), "C's rights are the files sent with C, in order");
        for f in [&fa, &fb, &fc, &b1, &c2] {
            sink(f);
        }
        close_pair(&p);
    }

    #[test]
    fn l2_rights_on_a_later_byte_are_refused_with_that_frame_and_the_next_frame_is_unaffected() {
        let _s = serial();
        let p = pair();
        let r = pipes(1);
        let body = b"late rights";
        raw(p.0, &framed::prefix_of(body.len()), &[]);
        raw(p.0, body, &r);
        framed::send(p.0, b"next", &[], 4096, false).unwrap();
        let e = framed::recv(p.1, 4096, false).unwrap_err();
        assert!(e.to_string().starts_with("invalid-bridge-frame"), "{e}");
        assert!(!super::closes_for_good(&e), "the stream is still aligned: {e}");
        assert_eq!(framed::recv(p.1, 4096, false).unwrap().0, b"next");
        sink(&r);
        close_pair(&p);
    }

    // ---- L3 · no descriptor lost, leaked or duplicated

    #[test]
    fn l3_after_100_frames_of_0_to_16_rights_with_refusals_violations_and_over_limits_the_count_is_back_at_baseline() {
        let _s = serial();
        let base = open_fds();
        let p = pair();
        for i in 0..100usize {
            let r = pipes(i % 17);
            match i % 3 {
                0 => framed::send(p.0, b"plain frame", &r, 4096, false).unwrap(),
                1 => {
                    raw(p.0, &framed::prefix_of(9), &[]);
                    raw(p.0, b"violation", &r);
                }
                _ => framed::send(p.0, b"{\"a\":\"reply\"}", &r, 4096, false).unwrap(),
            }
            sink(&r);
            if i % 3 == 2 {
                let _ = framed::recv_reply(p.1, false);
            } else if let Ok((_, f)) = framed::recv(p.1, 4096, false) {
                sink(&f);
            }
        }
        for n in [1usize, 5, 16] {
            let q = pair();
            let r = pipes(n);
            raw(q.0, &framed::prefix_of(5000), &r);
            sink(&r);
            let _ = framed::recv(q.1, 4096, false);
            close_pair(&q);
        }
        close_pair(&p);
        assert_eq!(open_fds(), base, "descriptors were kept");
    }

    #[test]
    fn l3_a_reply_with_rights_is_refused_and_they_are_closed() {
        let _s = serial();
        let base = open_fds();
        let p = pair();
        let r = pipes(2);
        raw(p.0, &wire(b"{\"ok\":true}"), &r);
        sink(&r);
        let e = framed::recv_reply(p.1, false).unwrap_err();
        assert!(e.to_string().starts_with("rights-on-reply"), "{e}");
        close_pair(&p);
        assert_eq!(open_fds(), base, "a reply's rights were kept");
    }

    #[test]
    fn l3_a_60_kib_frame_with_one_right_cut_into_short_writes_delivers_exactly_one_right() {
        let _s = serial();
        let p = pair();
        let r = pipes(1);
        let (w, one) = (p.0, r[0]);
        let t = std::thread::spawn(move || {
            fdpass::SHORT_SEND.with(|c| c.set(Some(1000)));
            let _ = framed::send(w, &vec![7u8; 60 * 1024], &[one], 65536, false);
            fdpass::SHORT_SEND.with(|c| c.set(None));
            fdpass::shutdown_fd(w);
        });
        let (mut rights, mut buf) = (0usize, vec![0u8; 4096]);
        while let Some(part) = fdpass::recv_part(p.1, &mut buf, 64, soon()).unwrap() {
            if part.n == 0 {
                break;
            }
            rights += part.fds.len();
            sink(&part.fds);
        }
        t.join().unwrap();
        assert_eq!(rights, 1, "rights that arrived for one right sent");
        sink(&r);
        close_pair(&p);
    }

    // ---- L4 · close-on-exec

    #[test]
    fn l4_both_ends_of_a_framed_pair_and_every_right_it_receives_are_close_on_exec() {
        let _s = serial();
        let p = pair();
        assert!(fdpass::is_cloexec(p.0) && fdpass::is_cloexec(p.1), "a framed pair end is inheritable");
        let r = pipes(3);
        for f in &r {
            fdpass::make_inheritable(*f).unwrap();
        }
        raw(p.0, &wire(b"x"), &r);
        let (_, got) = framed::recv(p.1, 4096, false).unwrap();
        assert_eq!(got.len(), 3);
        assert!(got.iter().all(|f| fdpass::is_cloexec(*f)), "a received right is inheritable");
        sink(&got);
        sink(&r);
        close_pair(&p);
    }

    // ---- L5 · a short read is never a frame; a short write is finished

    #[test]
    fn l5_a_frame_delivered_a_byte_at_a_time_with_pauses_is_one_frame_with_its_rights() {
        let _s = serial();
        let p = pair();
        let r = pipes(1);
        let want = inos(&r);
        let body = b"byte by byte".to_vec();
        let (w, one, bytes) = (p.0, r[0], wire(&body));
        let t = std::thread::spawn(move || {
            for (i, b) in bytes.iter().enumerate() {
                let first = [one];
                raw(w, &[*b], if i == 0 { &first[..] } else { &[] });
                std::thread::sleep(Duration::from_millis(15));
            }
        });
        let (got, fds) = framed::recv(p.1, 4096, false).unwrap();
        t.join().unwrap();
        assert_eq!(got, body);
        assert_eq!(inos(&fds), want);
        sink(&fds);
        sink(&r);
        close_pair(&p);
    }

    #[test]
    fn l5_a_60_kib_frame_cut_into_short_writes_arrives_byte_identical() {
        let _s = serial();
        let p = pair();
        let body: Vec<u8> = (0..60 * 1024).map(|i| (i % 251) as u8).collect();
        let (w, b2) = (p.0, body.clone());
        let t = std::thread::spawn(move || {
            fdpass::SHORT_SEND.with(|c| c.set(Some(997)));
            framed::send(w, &b2, &[], 65536, false).unwrap();
            fdpass::SHORT_SEND.with(|c| c.set(None));
        });
        let (got, _) = framed::recv(p.1, 65536, false).unwrap();
        t.join().unwrap();
        assert!(got == body, "the frame did not arrive byte-identical");
        close_pair(&p);
    }

    // ---- L6 · a peer's close is named, never a frame

    #[test]
    fn l6_a_close_at_a_frame_boundary_is_the_bridge_closed_never_a_frame() {
        let _s = serial();
        let p = pair();
        framed::send(p.0, b"last", &[], 4096, false).unwrap();
        fdpass::shutdown_fd(p.0);
        assert_eq!(framed::recv(p.1, 4096, false).unwrap().0, b"last");
        let e = framed::recv(p.1, 4096, false).unwrap_err();
        assert!(super::closes_for_good(&e), "{e}");
        let e = framed::recv_reply(p.1, false).unwrap_err();
        assert!(super::closes_for_good(&e), "the reply path read a close as a reply: {e}");
        close_pair(&p);
    }

    #[test]
    fn l6_a_close_inside_a_frame_runs_nothing_and_sinks_its_rights() {
        let _s = serial();
        let base = open_fds();
        let p = pair();
        let r = pipes(2);
        raw(p.0, &[&framed::prefix_of(100)[..], b"ten bytes!"].concat(), &r);
        sink(&r);
        fdpass::shutdown_fd(p.0);
        let e = framed::recv(p.1, 4096, false).unwrap_err();
        assert!(super::closes_for_good(&e) && e.to_string().contains("inside a frame"), "{e}");
        close_pair(&p);
        assert_eq!(open_fds(), base, "a truncated frame's rights were kept");
    }

    #[test]
    fn l6_shutting_the_channel_down_wakes_a_blocked_framed_reader() {
        let _s = serial();
        let p = pair();
        let rd = p.1;
        let t = std::thread::spawn(move || framed::recv(rd, 4096, false));
        std::thread::sleep(Duration::from_millis(200));
        fdpass::shutdown_fd(p.1);
        let t0 = Instant::now();
        while !t.is_finished() && t0.elapsed() < Duration::from_secs(2) {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(t.is_finished(), "the blocked reader did not wake");
        let r = t.join().unwrap();
        assert!(r.as_ref().is_err_and(super::closes_for_good), "{r:?}");
        close_pair(&p);
    }

    // ---- L7 · the maximum frame

    #[test]
    fn l7_exactly_the_limits_are_accepted_and_one_byte_more_is_refused_by_name() {
        let _s = serial();
        let p = pair();
        framed::send_command(p.0, &vec![b'c'; super::TO_RUNTIME_MAX], &[], false).unwrap();
        assert_eq!(framed::recv(p.1, super::TO_RUNTIME_MAX, false).unwrap().0.len(), super::TO_RUNTIME_MAX);
        let e = framed::send_command(p.0, &vec![b'c'; super::TO_RUNTIME_MAX + 1], &[], false).unwrap_err();
        assert!(e.to_string().starts_with("frame-too-large"), "{e}");
        assert!(fdpass::recv_part(p.1, &mut [0u8; 8], 4, Some(Instant::now())).unwrap().is_none(), "a refused command wrote");
        framed::send_command(p.0, b"next", &[], false).unwrap();
        assert_eq!(framed::recv(p.1, super::TO_RUNTIME_MAX, false).unwrap().0, b"next");
        let q = pair();
        framed::send(q.0, &vec![b'r'; super::TO_HOST_MAX], &[], super::TO_HOST_MAX, false).unwrap();
        assert_eq!(framed::recv_reply(q.1, false).unwrap().len(), super::TO_HOST_MAX);
        raw(q.0, &framed::prefix_of(super::TO_HOST_MAX + 1), &[]);
        let e = framed::recv_reply(q.1, false).unwrap_err();
        assert!(super::closes_for_good(&e) && e.to_string().contains("frame-too-large"), "{e}");
        close_pair(&p);
        close_pair(&q);
    }

    // ---- L9 · possession: a socketpair, never a path

    fn names(fd: RawFd) -> (i32, usize, i32, usize) {
        let get = |f: unsafe extern "C" fn(i32, *mut libc::sockaddr, *mut libc::socklen_t) -> i32| {
            let mut a: libc::sockaddr_un = unsafe { std::mem::zeroed() };
            let mut l = std::mem::size_of::<libc::sockaddr_un>() as libc::socklen_t;
            assert_eq!(unsafe { f(fd, &mut a as *mut _ as *mut libc::sockaddr, &mut l) }, 0);
            let path = a.sun_path.iter().take_while(|c| **c != 0).count();
            (a.sun_family as i32, if (l as usize) > std::mem::size_of::<libc::sa_family_t>() { path.max(1) } else { 0 })
        };
        let (sf, sp) = get(libc::getsockname);
        let (pf, pp) = get(libc::getpeername);
        (sf, sp, pf, pp)
    }

    #[test]
    fn l9_every_framed_bridge_end_is_an_unnamed_af_unix_pair() {
        let _s = serial();
        let p = pair();
        for fd in [p.0, p.1] {
            assert_eq!(names(fd), (libc::AF_UNIX, 0, libc::AF_UNIX, 0), "fd {fd} has a name: a path made it");
        }
        framed::send(p.0, b"possession", &[], 4096, false).unwrap();
        assert_eq!(framed::recv(p.1, 4096, false).unwrap().0, b"possession");
        close_pair(&p);
    }

    // ---- L10 · a frame begun is finished, or the bridge is closed for good

    #[test]
    fn l10_a_no_wait_receive_with_nothing_there_leaves_the_bridge_usable() {
        let _s = serial();
        let p = pair();
        let e = framed::recv(p.1, 4096, true).unwrap_err();
        assert_eq!(e.kind(), std::io::ErrorKind::WouldBlock);
        assert!(!super::closes_for_good(&e));
        framed::send(p.0, b"later", &[], 4096, false).unwrap();
        assert_eq!(framed::recv(p.1, 4096, true).unwrap().0, b"later");
        close_pair(&p);
    }

    #[test]
    fn l10_a_no_wait_receive_that_finds_a_first_byte_takes_the_whole_frame_past_its_deadline() {
        let _s = serial();
        let p = pair();
        let body = b"slow rest".to_vec();
        let bytes = wire(&body);
        raw(p.0, &bytes[..5], &[]);
        let (w, rest) = (p.0, bytes[5..].to_vec());
        let t = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(800));
            raw(w, &rest, &[]);
        });
        assert_eq!(framed::recv(p.1, 4096, true).unwrap().0, body);
        t.join().unwrap();
        close_pair(&p);
    }

    #[test]
    fn l10_a_frame_whose_rest_stalls_past_the_limit_closes_the_bridge_for_good() {
        let _s = serial();
        let p = pair();
        raw(p.0, &[&framed::prefix_of(10)[..], b"1"].concat(), &[]);
        let t0 = Instant::now();
        let e = framed::recv(p.1, 4096, false).unwrap_err();
        assert!(super::closes_for_good(&e), "{e}");
        assert!(t0.elapsed() + Duration::from_millis(100) >= super::FRAME_REST_LIMIT, "closed early: {:?}", t0.elapsed());
        close_pair(&p);
    }

    #[test]
    fn l10_a_sender_whose_frame_cannot_finish_within_the_limit_closes_the_bridge_for_good() {
        let _s = serial();
        let p = pair();
        // Only how an error is classed is judged here: the bytes of a cut write are L5's.
        if let Err(e) = framed::send(p.0, &vec![1u8; 4 << 20], &[], usize::MAX, true) {
            assert!(super::closes_for_good(&e), "a frame begun and not finished left the bridge open: {e}");
        }
        close_pair(&p);
    }
}
