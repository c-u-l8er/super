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

    /// An unnamed `AF_UNIX` stream pair (possession, never a path), both ends close-on-exec as `fdpass` makes them. The
    /// host's end (`Pair.0`) is `O_NONBLOCK`: XNU ignores `MSG_DONTWAIT` on a stream write that does not fit (MP1), so
    /// every wait is a `poll`. The runtime's end is its own socket and is left as it is.
    pub fn pair() -> io::Result<Pair> {
        let p = fdpass::pair_stream()?;
        if let Err(e) = fdpass::set_nonblocking(p.0) {
            fdpass::close_fd(p.0);
            fdpass::close_fd(p.1);
            return Err(e);
        }
        Ok(p)
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
            // Codex review 1, finding 3: once the first byte has moved, the rest deadline is checked before every pass,
            // so neither writes that keep succeeding nor interrupted ones can outlive FRAME_REST_LIMIT.
            if until.is_some_and(|d| Instant::now() >= d) {
                return Err(gone("the frame limit passed before the rest of a frame was written"));
            }
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
                // A no-wait send interrupted before its first byte returns to its caller, whose own deadline decides.
                Err(e) if e.kind() == io::ErrorKind::Interrupted && sent == 0 && nowait => return Err(e),
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock && sent == 0 && nowait => return Err(e),
                // Not even the first byte fits, and the caller waits: for room, for as long as it takes (O_NONBLOCK).
                Err(e) if e.kind() == io::ErrorKind::WouldBlock && sent == 0 => {
                    fdpass::wait_ready(sock, libc::POLLOUT, None)?;
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock && sent > 0 => {
                    let d = until.expect("set by the first byte");
                    // The deadline is checked here too: XNU can report a stream writable while sendmsg keeps refusing.
                    // A failed wait after the first byte is the bridge gone (Codex review 1, finding 4).
                    if Instant::now() >= d
                        || !fdpass::wait_ready(sock, libc::POLLOUT, Some(d))
                            .map_err(|e| gone(format!("the wait to write a frame's rest failed: {e}")))?
                    {
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
        // Codex review 1, finding 1: the read that accepts rights takes exactly the frame's first byte. On Linux a longer
        // read can run on into a later send and collect ITS rights; the other prefix bytes are continuation reads, where
        // any right is late. A first read that consumed its byte but could not mark an arrival leaves the bridge gone.
        let first = fdpass::recv_part(sock, &mut prefix[..1], RIGHTS_ROOM, if nowait { Some(Instant::now()) } else { None })
            .map_err(|e| if e.to_string().starts_with(fdpass::UNMARKED) { gone(e) } else { e })?;
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
        // Codex review 1, finding 3: the rest deadline before every continuation read, not only through poll.
        if Instant::now() >= until {
            sink(rights);
            sink(late);
            return Err(gone("the frame limit passed before the rest of a frame arrived"));
        }
        // Codex review 1, finding 4: a read that fails mid-frame sinks every right the frame brought, and the bridge is
        // gone (the frame was begun).
        let got = match fdpass::recv_rest(sock, buf, RIGHTS_ROOM, until) {
            Ok(got) => got,
            Err(e) => {
                sink(rights);
                sink(late);
                return Err(gone(format!("a read of a frame's rest failed: {e}")));
            }
        };
        match got {
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
    use crate::fdpass::{self, Fault, Pair};
    use std::os::unix::io::RawFd;
    use std::os::unix::thread::JoinHandleExt;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    /// The specification, independent of the implementation's constant (Codex review 2, finding 3): the rest of a
    /// frame may take 5 s, and these laws allow it at most a 6.5 s ceiling (scheduling included).
    const SPEC: Duration = Duration::from_secs(5);
    const CEILING: Duration = Duration::from_millis(6500);

    /// Make the calling thread's k-th `fault` fail with `errno` (fdpass's test seam).
    fn inject(fault: Fault, k: usize, errno: i32) {
        fdpass::INJECT.with(|c| c.set(Some((fault, k, errno))));
    }

    fn clear_inject() {
        fdpass::INJECT.with(|c| c.set(None));
    }

    extern "C" fn on_usr1(_: libc::c_int) {}

    struct Thread(libc::pthread_t);
    unsafe impl Send for Thread {}

    /// `SIGUSR1`, without `SA_RESTART`, to `target` every millisecond until the flag is set; the count sent.
    fn usr1_storm(target: libc::pthread_t) -> (Arc<AtomicBool>, std::thread::JoinHandle<usize>) {
        static ONCE: std::sync::Once = std::sync::Once::new();
        ONCE.call_once(|| unsafe {
            let mut sa: libc::sigaction = std::mem::zeroed();
            sa.sa_sigaction = on_usr1 as extern "C" fn(libc::c_int) as libc::sighandler_t;
            libc::sigemptyset(&mut sa.sa_mask);
            sa.sa_flags = 0;
            assert_eq!(libc::sigaction(libc::SIGUSR1, &sa, std::ptr::null_mut()), 0);
        });
        let stop = Arc::new(AtomicBool::new(false));
        let (s2, t) = (stop.clone(), Thread(target));
        let h = std::thread::spawn(move || {
            let t = t;
            let mut n = 0usize;
            while !s2.load(Ordering::SeqCst) {
                unsafe { libc::pthread_kill(t.0, libc::SIGUSR1) };
                n += 1;
                std::thread::sleep(Duration::from_millis(1));
            }
            n
        });
        (stop, h)
    }

    /// Small socket buffers, so a 60 KiB frame waits for its reader on Linux as it does on macOS.
    fn small_buffers(p: &Pair) {
        let n: libc::c_int = 4096;
        for (fd, opt) in [(p.0, libc::SO_SNDBUF), (p.1, libc::SO_RCVBUF)] {
            let rc = unsafe {
                libc::setsockopt(fd, libc::SOL_SOCKET, opt, &n as *const _ as *const libc::c_void, std::mem::size_of::<libc::c_int>() as libc::socklen_t)
            };
            assert_eq!(rc, 0, "setsockopt");
        }
    }

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
        // /proc on Linux; /dev/fd on macOS (MP1), which has no /proc.
        let dir = if cfg!(target_os = "linux") { "/proc/self/fd" } else { "/dev/fd" };
        std::fs::read_dir(dir).expect(dir).count()
    }

    /// `n` distinct open files to send: the read ends of pipes whose write ends are closed at once.
    fn pipes(n: usize) -> Vec<RawFd> {
        (0..n)
            .map(|_| {
                let mut p = [0; 2];
                assert_eq!(unsafe { libc::pipe(p.as_mut_ptr()) }, 0);
                for fd in p {
                    fdpass::set_cloexec(fd).unwrap();
                }
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

    #[test]
    fn l2_rights_on_prefix_byte_2_3_or_4_are_refused_with_that_frame_and_the_next_frame_is_unaffected() {
        let _s = serial();
        for k in 1..4usize {
            let p = pair();
            let r = pipes(1);
            let body = b"prefix rights";
            let pre = framed::prefix_of(body.len());
            // The bytes before prefix byte k + 1 plain, then the rest with the right: all queued before the reader runs,
            // so on Linux one longer read would collect the right together with the frame's first byte.
            raw(p.0, &pre[..k], &[]);
            raw(p.0, &[&pre[k..], &body[..]].concat(), &r);
            framed::send(p.0, b"next", &[], 4096, false).unwrap();
            let e = framed::recv(p.1, 4096, false).unwrap_err();
            assert!(e.to_string().starts_with("invalid-bridge-frame"), "prefix byte {}: {e}", k + 1);
            assert!(!super::closes_for_good(&e), "prefix byte {}: the stream is still aligned: {e}", k + 1);
            assert_eq!(framed::recv(p.1, 4096, false).unwrap().0, b"next", "prefix byte {}", k + 1);
            sink(&r);
            close_pair(&p);
        }
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
    fn l3_a_failed_read_or_an_unmarkable_arrival_mid_frame_leaves_no_descriptor() {
        let _s = serial();
        let base = open_fds();
        // A continuation read that fails (its recvmsg, then its poll), and an arrival on the first read that cannot be
        // marked: every right the frame brought is closed.
        for (fault, k) in [(Fault::Recvmsg, 1), (Fault::Poll, 1), (Fault::Mark, 0)] {
            let p = pair();
            let r = pipes(3);
            raw(p.0, &wire(b"a frame with three rights"), &r);
            sink(&r);
            inject(fault, k, libc::EIO);
            if let Ok((_, fds)) = framed::recv(p.1, 4096, false) {
                sink(&fds);
            }
            clear_inject();
            close_pair(&p);
        }
        // A late right whose mark fails.
        let p = pair();
        let r = pipes(2);
        raw(p.0, &framed::prefix_of(9), &[]);
        raw(p.0, b"violation", &r);
        sink(&r);
        inject(Fault::Mark, 0, libc::EIO);
        if let Ok((_, fds)) = framed::recv(p.1, 4096, false) {
            sink(&fds);
        }
        clear_inject();
        close_pair(&p);
        assert_eq!(open_fds(), base, "a failed read or mark kept descriptors");
    }

    #[test]
    fn l3_a_60_kib_frame_with_one_right_cut_into_short_writes_delivers_exactly_one_right() {
        let _s = serial();
        let p = pair();
        small_buffers(&p);
        let r = pipes(1);
        let (w, one) = (p.0, r[0]);
        let t = std::thread::spawn(move || {
            fdpass::SHORT_SEND.with(|c| c.set(Some(1000)));
            let _ = framed::send(w, &vec![7u8; 60 * 1024], &[one], 65536, false);
            fdpass::SHORT_SEND.with(|c| c.set(None));
            fdpass::shutdown_fd(w);
        });
        // Under signals (SIGUSR1 every millisecond, no SA_RESTART) while the reader stalls.
        let (stop, storm) = usr1_storm(t.as_pthread_t() as libc::pthread_t);
        std::thread::sleep(Duration::from_millis(300));
        let (mut rights, mut buf) = (0usize, vec![0u8; 4096]);
        while let Some(part) = fdpass::recv_part(p.1, &mut buf, 64, soon()).unwrap() {
            if part.n == 0 {
                break;
            }
            rights += part.fds.len();
            sink(&part.fds);
        }
        stop.store(true, Ordering::SeqCst);
        assert!(storm.join().unwrap() > 0, "no signal was sent");
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

    #[test]
    fn l4_an_arrival_that_cannot_be_marked_is_never_returned() {
        let _s = serial();
        let p = pair();
        let r = pipes(2);
        raw(p.0, &wire(b"x"), &r);
        inject(Fault::Mark, 1, libc::EIO);
        let got = framed::recv(p.1, 4096, false);
        clear_inject();
        assert!(got.is_err(), "the framed receive returned an arrival it could not mark: {got:?}");
        close_pair(&p);
        // The battery's receiver (it marks by fcntl where there is no MSG_CMSG_CLOEXEC: macOS, and the test feature).
        if cfg!(any(target_os = "macos", feature = "framed-bridge")) {
            let q = fdpass::pair_stream().unwrap();
            raw(q.0, b"y", &r);
            let base = open_fds();
            inject(Fault::Mark, 0, libc::EIO);
            let got = fdpass::recv_msg_with_fds(q.1, 64, 8);
            clear_inject();
            assert!(got.is_err(), "recv_msg_with_fds returned an arrival it could not mark: {got:?}");
            assert_eq!(open_fds(), base, "recv_msg_with_fds kept the arrivals it could not mark");
            close_pair(&q);
        }
        sink(&r);
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
        small_buffers(&p);
        let (w, b2) = (p.0, body.clone());
        let t = std::thread::spawn(move || {
            fdpass::SHORT_SEND.with(|c| c.set(Some(997)));
            framed::send(w, &b2, &[], 65536, false).unwrap();
            fdpass::SHORT_SEND.with(|c| c.set(None));
        });
        // Under signals (SIGUSR1 every millisecond, no SA_RESTART) while the reader stalls.
        let (stop, storm) = usr1_storm(t.as_pthread_t() as libc::pthread_t);
        std::thread::sleep(Duration::from_millis(300));
        let (got, _) = framed::recv(p.1, 65536, false).unwrap();
        stop.store(true, Ordering::SeqCst);
        assert!(storm.join().unwrap() > 0, "no signal was sent");
        t.join().unwrap();
        assert!(got == body, "the frame did not arrive byte-identical");
        close_pair(&p);
    }

    #[test]
    fn l5_an_eintr_before_any_byte_is_retried_with_the_rights() {
        let _s = serial();
        let p = pair();
        let r = pipes(1);
        let want = inos(&r);
        inject(Fault::Send, 0, libc::EINTR);
        framed::send(p.0, b"retried", &r, 4096, false).unwrap();
        clear_inject();
        // Judged on the raw wire: the frame's bytes and its one right, wherever on the frame it rides (that is L2's).
        let (mut got, mut fds, mut buf) = (Vec::new(), Vec::new(), [0u8; 64]);
        while got.len() < wire(b"retried").len() {
            let part = fdpass::recv_part(p.1, &mut buf, 64, soon()).unwrap().expect("bytes");
            assert!(part.n > 0, "the frame was cut");
            got.extend_from_slice(&buf[..part.n]);
            fds.extend(part.fds);
        }
        assert_eq!(got, wire(b"retried"));
        assert_eq!(inos(&fds), want, "the retry after EINTR did not carry the right");
        sink(&fds);
        sink(&r);
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
        // Written from a thread: macOS's stream pair buffers 8 KiB (MP1), so a limit-sized frame waits for its reader.
        let w = p.0;
        let t = std::thread::spawn(move || framed::send_command(w, &vec![b'c'; super::TO_RUNTIME_MAX], &[], false));
        assert_eq!(framed::recv(p.1, super::TO_RUNTIME_MAX, false).unwrap().0.len(), super::TO_RUNTIME_MAX);
        t.join().unwrap().unwrap();
        let e = framed::send_command(p.0, &vec![b'c'; super::TO_RUNTIME_MAX + 1], &[], false).unwrap_err();
        assert!(e.to_string().starts_with("frame-too-large"), "{e}");
        assert!(fdpass::recv_part(p.1, &mut [0u8; 8], 4, Some(Instant::now())).unwrap().is_none(), "a refused command wrote");
        framed::send_command(p.0, b"next", &[], false).unwrap();
        assert_eq!(framed::recv(p.1, super::TO_RUNTIME_MAX, false).unwrap().0, b"next");
        let q = pair();
        let w = q.0;
        let t = std::thread::spawn(move || framed::send(w, &vec![b'r'; super::TO_HOST_MAX], &[], super::TO_HOST_MAX, false));
        assert_eq!(framed::recv_reply(q.1, false).unwrap().len(), super::TO_HOST_MAX);
        t.join().unwrap().unwrap();
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
            // Named: a path; or, on Linux, any address longer than the family (an abstract name starts with a 0 byte).
            // XNU reports the whole sockaddr length even for an unnamed socket (MP1), so length alone is Linux's test.
            let named = path > 0 || (cfg!(target_os = "linux") && (l as usize) > std::mem::size_of::<libc::sa_family_t>());
            (a.sun_family as i32, if named { path.max(1) } else { 0 })
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
        let took = t0.elapsed();
        assert!(super::closes_for_good(&e), "{e}");
        assert!(took + Duration::from_millis(100) >= SPEC, "closed early: {took:?}");
        assert!(took <= CEILING, "closed late: {took:?}");
        close_pair(&p);
    }

    #[test]
    fn l10_a_sender_whose_frame_cannot_finish_within_the_limit_closes_the_bridge_for_good() {
        let _s = serial();
        let p = pair();
        // Nothing reads, so a 4 MiB frame cannot finish: the send must fail, GONE, within the bound. (The bytes of a cut
        // write are L5's.)
        let t0 = Instant::now();
        let e = framed::send(p.0, &vec![1u8; 4 << 20], &[], usize::MAX, true).expect_err("a 4 MiB frame finished with no reader");
        let took = t0.elapsed();
        assert!(super::closes_for_good(&e), "a frame begun and not finished left the bridge open: {e}");
        assert!(took <= CEILING, "the sender gave up late: {took:?}");
        close_pair(&p);
    }

    #[test]
    fn l10_a_receiver_whose_reads_keep_succeeding_slowly_closes_at_the_limit() {
        let _s = serial();
        let p = pair();
        // The whole frame is queued; the receiver takes one byte per read after a 40 ms pause (a test seam): ~8 s.
        raw(p.0, &wire(&[5u8; 200]), &[]);
        fdpass::SLOW_RECV.with(|c| c.set(Some((1, Duration::from_millis(40)))));
        let t0 = Instant::now();
        let r = framed::recv(p.1, 4096, false);
        fdpass::SLOW_RECV.with(|c| c.set(None));
        let took = t0.elapsed();
        // Only the bound is judged: a frame begun is finished within it, or the bridge is closed for good.
        assert!(took <= CEILING, "the rest took {took:?}");
        if let Err(e) = &r {
            assert!(super::closes_for_good(e), "{e}");
        }
        close_pair(&p);
    }

    #[test]
    fn l10_a_sender_whose_writes_keep_succeeding_slowly_closes_at_the_limit() {
        let _s = serial();
        let p = pair();
        let rd = p.1;
        let reader = std::thread::spawn(move || {
            let mut b = vec![0u8; 65536];
            while let Ok(Some(x)) = fdpass::recv_part(rd, &mut b, 4, Some(Instant::now() + Duration::from_secs(10))) {
                if x.n == 0 {
                    break;
                }
            }
        });
        // At most 1,000 bytes per write after a 40 ms pause (test seams), and a reader that keeps up: ~8 s of writes that
        // all succeed.
        fdpass::SHORT_SEND.with(|c| c.set(Some(1000)));
        fdpass::SLOW_SEND.with(|c| c.set(Some(Duration::from_millis(40))));
        let t0 = Instant::now();
        let r = framed::send(p.0, &vec![3u8; 200 * 1000], &[], usize::MAX, false);
        let took = t0.elapsed();
        fdpass::SHORT_SEND.with(|c| c.set(None));
        fdpass::SLOW_SEND.with(|c| c.set(None));
        fdpass::shutdown_fd(p.0);
        reader.join().unwrap();
        // Only the bound is judged.
        assert!(took <= CEILING, "the rest took {took:?}");
        if let Err(e) = &r {
            assert!(super::closes_for_good(e), "{e}");
        }
        close_pair(&p);
    }

    #[test]
    fn l10_a_bounded_receive_never_waits_on_the_fork_lock_past_its_bound() {
        let _s = serial();
        // A no-wait receive, a frame waiting, while a spawn holds the fork lock: WouldBlock at once, the frame untouched.
        let p = pair();
        raw(p.0, &wire(b"waiting"), &[]);
        let rd = p.1;
        let guard = fdpass::spawn_guard();
        let t0 = Instant::now();
        let t = std::thread::spawn(move || framed::recv(rd, 4096, true).map(|x| x.0));
        while !t.is_finished() && t0.elapsed() < Duration::from_millis(1500) {
            std::thread::sleep(Duration::from_millis(10));
        }
        let took = t0.elapsed();
        drop(guard);
        let r = t.join().unwrap();
        assert!(took <= Duration::from_millis(300), "the no-wait receive waited {took:?} on the fork lock");
        assert_eq!(r.unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
        assert_eq!(framed::recv(p.1, 4096, false).unwrap().0, b"waiting", "the waiting frame was touched");
        close_pair(&p);
        // A frame's rest that arrives while the lock is held: the bridge closes at the limit.
        let q = pair();
        raw(q.0, &[&framed::prefix_of(6)[..], b"a"].concat(), &[]);
        let rd = q.1;
        let t0 = Instant::now();
        let t = std::thread::spawn(move || framed::recv(rd, 4096, false));
        std::thread::sleep(Duration::from_millis(300));
        let guard = fdpass::spawn_guard();
        raw(q.0, b"bcdef", &[]);
        while !t.is_finished() && t0.elapsed() < SPEC + Duration::from_secs(3) {
            std::thread::sleep(Duration::from_millis(20));
        }
        let took = t0.elapsed();
        drop(guard);
        let r = t.join().unwrap();
        assert!(took <= CEILING, "the rest waited {took:?} on the fork lock");
        assert!(r.as_ref().is_err_and(super::closes_for_good), "{:?}", r.map(|x| x.0));
        close_pair(&q);
    }

    #[test]
    fn l10_a_final_body_read_that_ends_after_the_limit_closes_the_bridge() {
        let _s = serial();
        let p = pair();
        // The whole frame is queued, a 7-byte body (no prefix read is 7 bytes). Before the body's receive syscall, after
        // its wait and lock, the test seam pauses 5.5 s, whatever reads came before it.
        raw(p.0, &wire(b"zzzzzzz"), &[]);
        fdpass::RECV_PAUSE_LEN.with(|c| c.set(Some((7, SPEC + Duration::from_millis(500)))));
        let t0 = Instant::now();
        let r = framed::recv(p.1, 4096, false);
        let took = t0.elapsed();
        fdpass::RECV_PAUSE_LEN.with(|c| c.set(None));
        assert!(r.as_ref().is_err_and(super::closes_for_good), "a body read that ended after the limit was taken: {:?}", r.map(|x| x.0));
        assert!(took <= CEILING, "the rest took {took:?}");
        close_pair(&p);
    }

    #[test]
    fn l10_a_continuation_whose_polls_are_interrupted_without_end_ends_at_the_limit() {
        let _s = serial();
        let p = pair();
        // A frame stalled after its first bytes; every poll of the reading thread from its second on fails EINTR.
        raw(p.0, &[&framed::prefix_of(10)[..], b"1"].concat(), &[]);
        let rd = p.1;
        let t0 = Instant::now();
        let t = std::thread::spawn(move || {
            fdpass::POLL_EINTR_FROM.with(|c| c.set(Some(1)));
            let r = framed::recv(rd, 4096, false).map(|x| x.0);
            fdpass::POLL_EINTR_FROM.with(|c| c.set(None));
            r
        });
        // Judged from here, so a receive that spins is failed, not waited on.
        while !t.is_finished() && t0.elapsed() < CEILING + Duration::from_secs(1) {
            std::thread::sleep(Duration::from_millis(20));
        }
        let took = t0.elapsed();
        assert!(t.is_finished(), "the interrupted receive did not end ({took:?})");
        let r = t.join().unwrap();
        assert!(r.as_ref().is_err_and(super::closes_for_good), "{r:?}");
        assert!(took <= CEILING, "the interrupted receive took {took:?}");
        close_pair(&p);
    }

    #[test]
    fn l10_a_hard_error_after_a_frames_first_byte_closes_the_bridge_for_good() {
        let _s = serial();
        // Receiving: a continuation read that fails (its recvmsg, then its poll); a first read that cannot mark its right.
        for (fault, k) in [(Fault::Recvmsg, 1), (Fault::Poll, 1), (Fault::Mark, 0)] {
            let p = pair();
            let r = pipes(1);
            raw(p.0, &wire(b"begun"), &r);
            sink(&r);
            inject(fault, k, libc::EIO);
            let got = framed::recv(p.1, 4096, false);
            clear_inject();
            match (fault, got) {
                (_, Err(e)) => assert!(super::closes_for_good(&e), "{fault:?}: {e}"),
                // Only the error's class is judged: a receive that marks nothing returned whole, which is L4's.
                (Fault::Mark, Ok((_, fds))) => sink(&fds),
                (_, Ok(_)) => panic!("{fault:?}: a failed read returned a frame"),
            }
            close_pair(&p);
        }
        // Sending: the wait for room after the first byte fails.
        let p = pair();
        inject(Fault::Poll, 0, libc::EIO);
        let e = framed::send(p.0, &vec![2u8; 4 << 20], &[], usize::MAX, false).unwrap_err();
        clear_inject();
        assert!(super::closes_for_good(&e), "{e}");
        close_pair(&p);
    }

    #[test]
    fn l10_a_no_wait_send_interrupted_before_its_first_byte_returns_to_its_caller() {
        let _s = serial();
        let p = pair();
        inject(Fault::Send, 0, libc::EINTR);
        let e = framed::send(p.0, b"interrupted", &[], 4096, true).unwrap_err();
        clear_inject();
        assert_eq!(e.kind(), std::io::ErrorKind::Interrupted, "{e}");
        assert!(!super::closes_for_good(&e), "{e}");
        assert!(fdpass::recv_part(p.1, &mut [0u8; 8], 4, Some(Instant::now())).unwrap().is_none(), "an interrupted send wrote");
        framed::send(p.0, b"usable", &[], 4096, true).unwrap();
        assert_eq!(framed::recv(p.1, 4096, false).unwrap().0, b"usable");
        close_pair(&p);
    }
}
