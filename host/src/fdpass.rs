//! `socketpair(2)`, inherited descriptors, and `SCM_RIGHTS` — by hand.
//!
//! No crate for this. The whole point of the C1.1 correction is that the
//! capability *is* the descriptor, so the code that creates and passes one
//! should be readable in full rather than delegated to a dependency whose
//! flags you have to go and check.
//!
//! **`libc` since T27 (R122), and it changes none of that.** It supplies the C
//! declarations, the target's constants and the target's `msghdr`/`cmsghdr`
//! layouts. Every flag, every field and every call is still written below.

use std::io;
use std::os::unix::io::RawFd;

// ---------------------------------------------------------------- libc
//
// The libc crate's declarations of the calls the trust model rests on (they
// were an `extern` block here until T27). `close_range(2)` is not among them
// on purpose: see `seal_inheritance`.
use libc::{close, dup2, fcntl, flock, recvmsg, sendmsg, shutdown, socketpair};

const SHUT_RDWR: i32 = libc::SHUT_RDWR;

const AF_UNIX: i32 = libc::AF_UNIX;
const SOCK_STREAM: i32 = libc::SOCK_STREAM;
const SOCK_SEQPACKET: i32 = libc::SOCK_SEQPACKET;
/// `SOCK_CLOEXEC` — Linux `0o2000000` on x86-64 and aarch64; libc's, so the target's.
///
/// **Every descriptor is close-on-exec by default; explicit inheritance is
/// a capability transfer.** Without this, `socketpair(2)` returns two
/// inheritable descriptors, and this file does not use a Rust socket API
/// that would have set the flag for it — a comment here used to claim
/// "Rust sets CLOEXEC on everything it creates", which is true of Rust's
/// own APIs and false of the raw `libc` calls below.
///
/// The consequence was not theoretical. The host holds the bridge, the
/// human control channel, and one descriptor per engine. Spawning an
/// engine `dup2`s that engine's channel onto fd 3 — and every *other* raw
/// descriptor survived `exec` as well, so a spawned agent could inherit
/// the person's socket and the bridge that mints identities. "The agent
/// cannot issue human commands" stopped being enforced by possession at
/// the moment the agent possessed it.
const SOCK_CLOEXEC: i32 = libc::SOCK_CLOEXEC;
/// `MSG_CMSG_CLOEXEC` — the same rule for descriptors that *arrive*.
pub const MSG_CMSG_CLOEXEC: i32 = libc::MSG_CMSG_CLOEXEC;
const SOL_SOCKET: i32 = libc::SOL_SOCKET;
const SCM_RIGHTS: i32 = libc::SCM_RIGHTS;
const F_SETFD: i32 = libc::F_SETFD;
const F_GETFD: i32 = libc::F_GETFD;
const FD_CLOEXEC: i32 = libc::FD_CLOEXEC;

/// `CLOSE_RANGE_CLOEXEC` — Linux 5.11. **Marks the range close-on-exec; it
/// does not close it.** That distinction is the whole of `seal_inheritance`.
const CLOSE_RANGE_CLOEXEC: u32 = libc::CLOSE_RANGE_CLOEXEC;

/// A `msghdr` for one buffer and an optional control buffer.
///
/// Built from zero and then field by field, because `libc::msghdr` is the
/// target's own layout (glibc's has no padding fields, musl's has two). Zero is
/// what T26's hand-written struct put in every field this does not set:
/// no name, no flags.
fn msghdr(iov: &mut libc::iovec, control: *mut u8, controllen: usize) -> libc::msghdr {
    let mut m: libc::msghdr = unsafe { std::mem::zeroed() };
    m.msg_iov = iov;
    m.msg_iovlen = 1;
    m.msg_control = control.cast();
    m.msg_controllen = controllen as _;
    m
}

fn iovec(buf: &mut [u8]) -> libc::iovec {
    libc::iovec {
        iov_base: buf.as_mut_ptr().cast(),
        iov_len: buf.len(),
    }
}

/// `CMSG_SPACE` for `n` descriptors: the control buffer.
///
/// **libc's arithmetic, not this file's, since T27.** Until then the header
/// (`CmsgHdr {len: usize, level: i32, ty: i32}`) and its alignment
/// (`cmsg_align`, to `size_of::<usize>()`) were written here. That is glibc's
/// layout on every 64-bit Linux, and wrong on macOS, whose kernel aligns
/// control messages to four bytes (T28's design study): a hand-rolled offset
/// there makes `sendmsg` fail `EINVAL`. `libc::CMSG_*` are each target's own;
/// on 64-bit Linux they give exactly T26's numbers (L3e holds them).
fn rights_space(n: usize) -> usize {
    unsafe { libc::CMSG_SPACE((n * std::mem::size_of::<RawFd>()) as libc::c_uint) as usize }
}

/// `CMSG_LEN` for `n` descriptors: the header's own `cmsg_len`. Not the same
/// number as [`rights_space`] (it has no tail padding), and using one for the
/// other is how a receiver ends up reading a descriptor that was never sent.
fn rights_len(n: usize) -> usize {
    unsafe { libc::CMSG_LEN((n * std::mem::size_of::<RawFd>()) as libc::c_uint) as usize }
}

/// A connected pair. `Pair.0` is ours; `Pair.1` is the one we give away.
pub struct Pair(pub RawFd, pub RawFd);

pub fn pair_stream() -> io::Result<Pair> {
    make_pair(SOCK_STREAM)
}

pub fn pair_seqpacket() -> io::Result<Pair> {
    make_pair(SOCK_SEQPACKET)
}

/// Both ends close-on-exec. Nothing inherits a channel by accident; the
/// one descriptor an engine is meant to have is made inheritable
/// deliberately, in `dup_onto`, after `fork` and before `exec`.
fn make_pair(ty: i32) -> io::Result<Pair> {
    #[cfg(test)]
    if FAIL_PAIRS_AFTER.with(|c| match c.get() {
        Some(0) => true,
        Some(k) => {
            c.set(Some(k - 1));
            false
        }
        None => false,
    }) {
        return Err(io::Error::from_raw_os_error(libc::EMFILE));
    }
    let mut sv = [0i32; 2];
    let rc = unsafe { socketpair(AF_UNIX, ty | SOCK_CLOEXEC, 0, sv.as_mut_ptr()) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    debug_assert!(is_cloexec(sv[0]) && is_cloexec(sv[1]));
    Ok(Pair(sv[0], sv[1]))
}

/// What `exec` would do with `fd`.
///
/// Three states, not two. A closed descriptor and an inheritable one both
/// fail an `is_cloexec` test, and they mean opposite things: a closed
/// descriptor cannot leak, an inheritable one is the defect. Collapsing
/// them made the confinement check fail on descriptors this host had
/// already released.
#[derive(PartialEq, Debug)]
pub enum FdState {
    Closed,
    Cloexec,
    Inheritable,
}

pub fn fd_state(fd: RawFd) -> FdState {
    let f = unsafe { fcntl(fd, F_GETFD, 0) };
    if f == -1 {
        FdState::Closed
    } else if (f & FD_CLOEXEC) != 0 {
        FdState::Cloexec
    } else {
        FdState::Inheritable
    }
}

pub fn is_cloexec(fd: RawFd) -> bool {
    fd_state(fd) == FdState::Cloexec
}

/// Clear `FD_CLOEXEC` so this descriptor — and only this one — survives
/// into the child.
///
/// This is the capability transfer, and it is the only place one happens.
/// Everything else is close-on-exec from the moment it exists.
pub fn make_inheritable(fd: RawFd) -> io::Result<()> {
    if unsafe { fcntl(fd, F_SETFD, 0) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Mark **every** descriptor at or above `first` close-on-exec, in the
/// child, before anything is placed.
///
/// # The invariant this establishes, and the one it replaces
///
/// The old claim was about a binary: *everything the host holds is
/// `SOCK_CLOEXEC` or `O_CLOEXEC` by construction*. That is true of
/// `super-host`, which opens almost nothing, and **false of the host role**.
/// A process that links `super_host` alongside GTK/WebKit gets descriptors
/// it never asked for — measured on the cockpit: 56 open, 11 without
/// `O_CLOEXEC`, eight of them above fd 3, on `/dev/urandom`, `/proc/meminfo`,
/// `/proc/zoneinfo` and the host's own cgroup limits. Every one of those
/// would have been inherited into a process the floor confines to four, and
/// Landlock cannot reach an already-open descriptor.
///
/// The new claim is about the spawn path:
///
/// > A Carrier's inherited descriptor set is established by this code, not
/// > by the descriptor hygiene of whatever executable happens to be the
/// > host. Everything above the base is marked for death; the Carrier's
/// > possessions are then rescued, one `dup_onto` at a time.
///
/// # Why the flag and not a close
///
/// `CLOSE_RANGE_CLOEXEC` sets `FD_CLOEXEC` across the range and closes
/// nothing, which is load-bearing three times over:
///
/// 1. `Prepared`'s Landlock ruleset lives above the allowlist and must
///    still be a live descriptor when `install` runs, *after* this.
/// 2. The PTY slave, the control channel and every `extra_fds` source are
///    read by `dup_onto` after this line; closing them would make the
///    Carrier's own possessions unreachable.
/// 3. `std::process::Command` keeps a `CLOEXEC` pipe open across the fork
///    and detects a successful `exec` by that pipe closing — a blind sweep
///    closes it, and a `pre_exec` that then fails reports **nothing** to
///    the parent. The sweep would break the reporting of its own breakage.
///
/// # Failure is a refusal, not a warning
///
/// A Carrier whose descriptor table cannot be bounded must not start. There
/// is no "sealing unavailable, continue anyway" path: the error propagates
/// out of `pre_exec` and the spawn fails, which is the same shape the floor
/// would have refused it in — one step earlier and by a better name.
///
/// Runs after `fork`, before `exec`: one syscall, no allocation.
pub fn seal_inheritance(first: RawFd) -> io::Result<()> {
    // **A raw syscall on purpose**, numbered by libc since T27 (it was x86-64's
    // 436): not glibc's `close_range` wrapper, so the failure this floor must
    // not survive — the kernel not having it — arrives as `ENOSYS` from the
    // kernel instead of as whatever a libc chose to do about it.
    let rc = unsafe {
        libc::syscall(
            libc::SYS_close_range,
            first as u32 as i64,
            u32::MAX as i64,
            CLOSE_RANGE_CLOEXEC as i64,
        )
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Move `fd` onto `target` in the child, after `fork` and before `exec`.
pub fn dup_onto(fd: RawFd, target: RawFd) -> io::Result<()> {
    if unsafe { dup2(fd, target) } == -1 {
        return Err(io::Error::last_os_error());
    }
    make_inheritable(target)
}

/// Guarantee 0, 1 and 2 are open in the child, before `exec`.
///
/// **Not hygiene — a descriptor-ownership guarantee.** `SCM_RIGHTS` is a
/// `dup(2)` into the receiving table and `dup` takes the lowest free
/// number, so if the runtime is started with stdout closed, the first
/// channel it is handed becomes its stdout. Everything the VM then prints
/// goes down a peer's socket, and closing that channel closes the
/// runtime's stdout.
///
/// The runtime used to defend against this by refusing to sink any
/// descriptor below 3 — which turned the hazard into an *exception in the
/// sink*, a descriptor with no exit, the exact bug class the sink exists
/// to end. The guarantee belongs here, in the process that decides what
/// the child inherits, made once and unconditionally rather than assumed
/// from a terminal being attached. A GUI session promises nothing.
///
/// Runs after `fork`, before `exec`, so only `async-signal-safe` calls.
pub fn ensure_std_fds() -> io::Result<()> {
    const O_RDWR: i32 = libc::O_RDWR;

    for target in 0..3 {
        if unsafe { fcntl(target, F_GETFD, 0) } != -1 {
            continue;
        }
        // `open` takes the lowest free descriptor, and `target` is free by
        // the test above — but only if every number below it is taken,
        // which the loop's order guarantees.
        let fd = unsafe { libc::open(c"/dev/null".as_ptr(), O_RDWR, 0 as libc::c_int) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        if fd != target {
            unsafe {
                dup2(fd, target);
                close(fd);
            }
        }
    }
    Ok(())
}

/// Release a channel: `shutdown(2)` **then** `close(2)`.
///
/// `close` alone is not enough and the difference is not cosmetic. When
/// another thread is blocked in `read(2)` on the descriptor, closing it
/// removes this process's table entry but leaves the underlying open file
/// description alive until that syscall returns — so **the peer never sees
/// EOF**, and the runtime goes on believing the channel is held.
///
/// Found by running it: dropping the control channel and immediately
/// asking for a new one was refused `control-channel-already-claimed`
/// against a descriptor whose only reader had gone. `shutdown` ends the
/// connection itself rather than this process's reference to it, which
/// both wakes the reader and delivers the EOF.
pub fn release_fd(fd: RawFd) {
    unsafe {
        shutdown(fd, SHUT_RDWR);
        close(fd);
    }
}

/// End the connection without closing the descriptor.
///
/// The half of `release_fd` that delivers EOF, on its own — so a battery
/// can make a live channel go dead **while its `Chan` is still held**,
/// which is the only way to exercise the reader's EOF path rather than the
/// "no channel in the slot" path beside it. The descriptor stays owned by
/// its `Chan`, so `Drop` still closes it exactly once.
pub fn shutdown_fd(fd: RawFd) {
    unsafe {
        shutdown(fd, SHUT_RDWR);
    }
}

/// Take an exclusive advisory lock on a world directory, for the life of
/// this host.
///
/// **One active owner per local world.** Once the data directory stopped
/// being a throwaway, two hosts could open the same DETS stores at once —
/// and nothing in DETS would have told either of them. That is a
/// corruption path, and it should be refused by name rather than left to
/// whichever process wrote last.
///
/// Returns the held descriptor, which must stay open: an advisory lock
/// lives on the open file description, so closing it releases the world.
pub fn lock_world(path: &std::path::Path) -> Result<RawFd, String> {
    const O_RDWR: i32 = libc::O_RDWR;
    const O_CREAT: i32 = libc::O_CREAT;
    const O_CLOEXEC: i32 = libc::O_CLOEXEC;
    const LOCK_EX: i32 = libc::LOCK_EX;
    const LOCK_NB: i32 = libc::LOCK_NB;

    let mut c = path.as_os_str().as_encoded_bytes().to_vec();
    c.push(0);

    let fd = unsafe { libc::open(c.as_ptr().cast(), O_RDWR | O_CREAT | O_CLOEXEC, 0o600 as libc::c_int) };
    if fd < 0 {
        return Err(format!("world lock: {}", io::Error::last_os_error()));
    }

    if unsafe { flock(fd, LOCK_EX | LOCK_NB) } != 0 {
        unsafe { close(fd) };
        return Err("world-already-open — another Super host holds this world".into());
    }
    Ok(fd)
}

pub fn close_fd(fd: RawFd) {
    unsafe {
        close(fd);
    }
}

/// Send `bytes` and hand `fd` over in the same message.
///
/// One message, one descriptor: the label and the capability it labels
/// cannot be separated in flight, so there is no shape in which the
/// runtime binds an identity to a channel it was not given.
pub fn send_with_fd(sock: RawFd, bytes: &[u8], fd: RawFd) -> io::Result<()> {
    send_with_fds(sock, bytes, &[fd])
}

/// Send `bytes` with `fds` — **more than one, on purpose.**
///
/// One control message can carry any number of descriptors, and the
/// runtime's bind path takes the first and discards the rest. Until this
/// existed, nothing could send it a second one, so "the rest are
/// discarded" was a branch no measurement had ever entered — which is
/// exactly where F.8.1's leak was still sitting after F.8.1 declared the
/// leak bounded.
pub fn send_with_fds(sock: RawFd, bytes: &[u8], fds: &[RawFd]) -> io::Result<()> {
    all_sent(send_with_fds_count(sock, bytes, fds)?, bytes.len())
}

/// [`send_with_fds`], reporting how many bytes `sendmsg` took.
///
/// T27b F3: on SEQPACKET a send is all or nothing, but on a `SOCK_STREAM`
/// socket — the Carrier channel — a signal can cut one short, and until T27b
/// `send_with_fds` returned `Ok` either way. [`send_with_fds`] now refuses a
/// short send; a stream writer that can finish one uses this and sends the
/// rest itself.
pub fn send_with_fds_count(sock: RawFd, bytes: &[u8], fds: &[RawFd]) -> io::Result<usize> {
    let mut buf = bytes[..short_send_cap(bytes.len())].to_vec();
    let mut iov = iovec(&mut buf);

    // `CMSG_SPACE` for the buffer, `CMSG_LEN` for the header's own length;
    // see `rights_len`.
    let space = rights_space(fds.len());
    let mut control = vec![0u8; space];

    let msg = msghdr(&mut iov, control.as_mut_ptr(), space);

    unsafe {
        let cmsg = libc::CMSG_FIRSTHDR(&msg);
        if cmsg.is_null() {
            return Err(io::Error::other("a control buffer too small for its own header"));
        }
        (*cmsg).cmsg_len = rights_len(fds.len()) as _;
        (*cmsg).cmsg_level = SOL_SOCKET;
        (*cmsg).cmsg_type = SCM_RIGHTS;
        let data = libc::CMSG_DATA(cmsg) as *mut i32;
        for (i, fd) in fds.iter().enumerate() {
            *data.add(i) = *fd;
        }
    }

    let n = unsafe { sendmsg(sock, &msg, 0) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(n as usize)
}

/// `Ok` only if `sendmsg` took every byte (T27b F3).
fn all_sent(n: usize, len: usize) -> io::Result<()> {
    if n == len {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::WriteZero,
            format!("short send: sendmsg took {n} of {len} bytes"),
        ))
    }
}

// T27b B6's seam: a test can make sends hand `sendmsg` at most this many bytes, which is a REAL short send. Absent from
// every non-test build.
#[cfg(test)]
thread_local! {
    pub(crate) static SHORT_SEND: std::cell::Cell<Option<usize>> = const { std::cell::Cell::new(None) };
}

// T27b round 3's seam (Codex review 2, finding 7): a test can make a socketpair fail as EMFILE does, after `k` more
// succeed (`Some(k)`; `Some(0)` fails the next), to show what a constructor holds when a later allocation fails.
// Absent from every non-test build.
#[cfg(test)]
thread_local! {
    pub(crate) static FAIL_PAIRS_AFTER: std::cell::Cell<Option<usize>> = const { std::cell::Cell::new(None) };
}

// T27b round 3d: the T27b tests that open descriptors run one at a time. They share one process, and a descriptor
// count, or a closed number reused by another thread, is otherwise another test's noise (laws.py v3 at 90e9eab: three
// plants also failed an unrelated law; the whole set failed 1 run in 15). Test builds only.
#[cfg(test)]
pub(crate) fn t27b_serial() -> std::sync::MutexGuard<'static, ()> {
    static L: std::sync::Mutex<()> = std::sync::Mutex::new(());
    L.lock().unwrap_or_else(|p| p.into_inner())
}

#[cfg(test)]
fn short_send_cap(len: usize) -> usize {
    SHORT_SEND.with(|c| c.get().map_or(len, |cap| cap.min(len)))
}

#[cfg(not(test))]
fn short_send_cap(len: usize) -> usize {
    len
}

/// The longest command the runtime reads whole: OTP's default `recvmsg`
/// buffer (T28 row 8). R125 keeps the limit; T27b enforces it by name.
pub const BRIDGE_COMMAND_MAX: usize = 8_192;

/// The longest reply the host reads whole: every bridge read is
/// `recv_msg(bridge, 64 * 1024)`.
pub const BRIDGE_REPLY_MAX: usize = 64 * 1024;

fn bridge_command_fits(len: usize) -> io::Result<()> {
    // An empty message with no rights is how the runtime reads the host's close (T27b F1): never send one.
    if len == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "empty-command: the runtime reads an empty bridge message as the host's close",
        ));
    }
    if len > BRIDGE_COMMAND_MAX {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("frame-too-large: a {len}-byte bridge command; the runtime reads {BRIDGE_COMMAND_MAX}"),
        ));
    }
    Ok(())
}

/// Send one bridge command that carries no descriptor (T27b F2). **With
/// [`send_bridge_with_fds`], the only senders on the bridge**
/// (`tests/t27b_bridge_sends.rs` holds every bridge send in `lib.rs` to
/// them): a command longer than the runtime reads whole is refused here, by
/// name, before anything is written, because the runtime would otherwise get
/// a prefix of it.
pub fn send_bridge_plain(sock: RawFd, bytes: &[u8]) -> io::Result<()> {
    bridge_command_fits(bytes.len())?;
    send_plain(sock, bytes)
}

/// [`send_bridge_plain`] for a command carrying `fds` in the same message.
pub fn send_bridge_with_fds(sock: RawFd, bytes: &[u8], fds: &[RawFd]) -> io::Result<()> {
    bridge_command_fits(bytes.len())?;
    send_with_fds(sock, bytes, fds)
}

/// [`send_bridge_plain`] that never waits: `WouldBlock` while the runtime is not reading (T27b round 3, Codex review 2,
/// finding 2: a send a deadline bounds must not block past it). The bytes on the wire are [`send_bridge_plain`]'s.
pub fn send_bridge_plain_nowait(sock: RawFd, bytes: &[u8]) -> io::Result<()> {
    bridge_command_fits(bytes.len())?;
    all_sent(send_plain_count_flags(sock, bytes, libc::MSG_DONTWAIT)?, bytes.len())
}

/// Whether `e` is [`recv_msg`]'s reply-too-large. That message was read whole and refused, so it is consumed: the
/// reply it was is no longer owed (T27b round 3, Codex review 2, finding 1).
pub fn is_reply_too_large(e: &io::Error) -> bool {
    e.kind() == io::ErrorKind::InvalidData && e.to_string().starts_with("reply-too-large")
}

/// A descriptor worth nothing, to be handed over and forgotten.
///
/// Both ends of a pair, one closed immediately: what is left is a real,
/// sendable socket descriptor whose peer is gone. Surplus rights in a
/// bridge command have to be *real* descriptors — the kernel refuses to
/// send a number that does not name one — so a test for "the runtime
/// discards what it did not ask for" needs somewhere to get them.
pub fn spare_fd() -> io::Result<RawFd> {
    let Pair(a, b) = make_pair(SOCK_STREAM)?;
    close_fd(b);
    Ok(a)
}

/// Send `bytes` with no descriptor attached.
pub fn send_plain(sock: RawFd, bytes: &[u8]) -> io::Result<()> {
    all_sent(send_plain_count(sock, bytes)?, bytes.len())
}

/// [`send_plain`], reporting how many bytes `sendmsg` took (T27b F3).
pub fn send_plain_count(sock: RawFd, bytes: &[u8]) -> io::Result<usize> {
    send_plain_count_flags(sock, bytes, 0)
}

/// [`send_plain_count`] with `sendmsg` flags (T27b round 3: `MSG_DONTWAIT` for a send a deadline bounds).
fn send_plain_count_flags(sock: RawFd, bytes: &[u8], flags: i32) -> io::Result<usize> {
    let mut buf = bytes[..short_send_cap(bytes.len())].to_vec();
    let mut iov = iovec(&mut buf);

    let msg = msghdr(&mut iov, std::ptr::null_mut(), 0);

    let n = unsafe { sendmsg(sock, &msg, flags) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(n as usize)
}

/// Receive one message. Returns its bytes.
///
/// `MSG_CMSG_CLOEXEC` on every receive: a descriptor that arrives is
/// close-on-exec too, so the rule holds on both sides of a handoff.
pub fn recv_msg(sock: RawFd, max: usize) -> io::Result<Vec<u8>> {
    let mut buf = vec![0u8; max];
    let mut iov = iovec(&mut buf);

    let mut msg = msghdr(&mut iov, std::ptr::null_mut(), 0);

    let n = unsafe { recvmsg(sock, &mut msg, MSG_CMSG_CLOEXEC) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    // T27b F2: a message longer than `max` arrives cut, with MSG_TRUNC set.
    // Until T27b the cut bytes were returned as though they were the reply.
    if msg.msg_flags & libc::MSG_TRUNC != 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("reply-too-large: the message was longer than {max} bytes and arrived cut; refused, not read"),
        ));
    }
    buf.truncate(n as usize);
    Ok(buf)
}

/// Receive one message **and any descriptors it carried**.
///
/// D.1.3c·2, and until now this host had no such function: `send_with_fds`
/// had no counterpart, because every handoff went one way. A terminal
/// attachment is answered with an endpoint, so the acceptance battery — which
/// is the thing standing in for the runtime on that channel — has to be able
/// to take delivery of one.
///
/// **The `controllen` is the whole difference from [`recv_msg`], and getting
/// it wrong is silent.** A `recvmsg` with no control buffer does not fail when
/// rights arrive: the kernel closes them, sets `MSG_CTRUNC` in `flags`, and
/// returns the data as though nothing were missing. So `MSG_CTRUNC` is
/// reported rather than ignored — a truncated control message means a
/// descriptor was destroyed in transit, and a caller that read past it would
/// be looking for a reason the attachment did not work in the wrong half of
/// the system.
pub fn recv_msg_with_fds(sock: RawFd, max: usize, max_fds: usize) -> io::Result<(Vec<u8>, Vec<RawFd>)> {
    const MSG_CTRUNC: i32 = libc::MSG_CTRUNC;

    let mut buf = vec![0u8; max];
    let mut iov = iovec(&mut buf);

    let space = rights_space(max_fds);
    let mut ctrl = vec![0u8; space];

    let mut msg = msghdr(&mut iov, ctrl.as_mut_ptr(), ctrl.len());

    let n = unsafe { recvmsg(sock, &mut msg, MSG_CMSG_CLOEXEC) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    buf.truncate(n as usize);

    let mut fds: Vec<RawFd> = Vec::new();
    // `CMSG_FIRSTHDR` is null unless the kernel wrote at least one header
    // (`msg_controllen` ≥ the header), which is the test this made by hand.
    let first = unsafe { libc::CMSG_FIRSTHDR(&msg) };
    if !first.is_null() {
        // One control message is all this protocol ever sends. Walking a
        // chain would be a generality with no second case to keep it honest.
        let h = unsafe { &*first };
        let head = rights_len(0);
        if h.cmsg_level == SOL_SOCKET
            && h.cmsg_type == SCM_RIGHTS
            && h.cmsg_len as usize >= head
        {
            let payload = h.cmsg_len as usize - head;
            let base = unsafe { libc::CMSG_DATA(first) } as *const u8;
            for i in 0..(payload / 4) {
                let mut raw = [0u8; 4];
                unsafe { std::ptr::copy_nonoverlapping(base.add(i * 4), raw.as_mut_ptr(), 4) };
                fds.push(i32::from_ne_bytes(raw));
            }
        }
    }

    if (msg.msg_flags & MSG_CTRUNC) != 0 {
        // Whatever did arrive is still this process's to close.
        for f in &fds {
            close_fd(*f);
        }
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "the control message was truncated — a descriptor was discarded in transit",
        ));
    }

    Ok((buf, fds))
}

// ------------------------------------------------------------------ T27 laws
#[cfg(test)]
mod t27 {
    use super::*;

    fn dev_ino(fd: RawFd) -> (u64, u64) {
        let mut st = std::mem::MaybeUninit::<libc::stat>::uninit();
        assert_eq!(unsafe { libc::fstat(fd, st.as_mut_ptr()) }, 0, "fstat({fd})");
        let st = unsafe { st.assume_init() };
        (st.st_dev as u64, st.st_ino as u64)
    }

    /// **L3b** — `close_range` (raw, numbered by libc) still marks exactly
    /// `[first, ∞)` close-on-exec and closes nothing: in the child, right
    /// after the seal, `first` is still open and `FD_CLOEXEC` and the
    /// descriptor below it is untouched; after `exec`, only the one below
    /// `first` was inherited.
    #[test]
    fn t27_l3b_close_range_marks_exactly_from_first() {
        use std::os::unix::process::CommandExt;
        let null = unsafe { libc::open(c"/dev/null".as_ptr(), libc::O_RDWR | libc::O_CLOEXEC) };
        assert!(null >= 0);
        // Three inheritable copies (F_DUPFD sets no FD_CLOEXEC): below the
        // seal, AT it, and far above it.
        let below = unsafe { fcntl(null, libc::F_DUPFD, 40) };
        let first = unsafe { fcntl(null, libc::F_DUPFD, 80) };
        let far = unsafe { fcntl(null, libc::F_DUPFD, 160) };
        assert!(below >= 40 && below < first && first < far, "{below} {first} {far}");
        for fd in [below, first, far] {
            assert_eq!(fd_state(fd), FdState::Inheritable, "fd {fd} before the seal");
        }
        let out = unsafe {
            std::process::Command::new("/bin/sh")
                .arg("-c")
                .arg(format!(
                    "for f in {below} {first} {far}; do [ -e /proc/self/fd/$f ] && echo $f; done; true"
                ))
                .pre_exec(move || {
                    seal_inheritance(first)?;
                    let at = fcntl(first, F_GETFD, 0);
                    let under = fcntl(below, F_GETFD, 0);
                    if at == -1 || at & FD_CLOEXEC == 0 || under == -1 || under & FD_CLOEXEC != 0 {
                        return Err(io::Error::from_raw_os_error(libc::ENOTRECOVERABLE));
                    }
                    Ok(())
                })
                .output()
        };
        for fd in [null, below, first, far] {
            close_fd(fd);
        }
        let out = out.expect("the sealed child: the seal marked, and did not close");
        let seen: Vec<i32> = String::from_utf8_lossy(&out.stdout)
            .split_whitespace()
            .map(|v| v.parse().unwrap())
            .collect();
        assert_eq!(seen, vec![below], "inherited across exec (below={below} first={first} far={far})");
    }

    /// **L3e** — the control-message arithmetic is libc's (`CMSG_SPACE`,
    /// `CMSG_LEN`, `CMSG_FIRSTHDR`, `CMSG_DATA`), and on 64-bit Linux it is
    /// T26's byte for byte: T26 sized the buffer `align8(16) + align8(4n)`,
    /// wrote `cmsg_len = 16 + 4n`, and put the descriptors 16 bytes in, for
    /// every count the kernel accepts (`SCM_MAX_FD` = 253).
    #[cfg(all(target_os = "linux", target_pointer_width = "64"))]
    #[test]
    fn t27_l3e_cmsg_arithmetic_is_libcs_and_t26s_on_64_bit_linux() {
        let align8 = |n: usize| (n + 7) & !7;
        for n in 0..=253usize {
            assert_eq!(rights_space(n), align8(16) + align8(4 * n), "the control buffer for {n} rights");
            assert_eq!(rights_len(n), 16 + 4 * n, "cmsg_len for {n} rights");
        }
        let mut control = vec![0u8; rights_space(2)];
        let mut one = [0u8; 1];
        let mut iov = iovec(&mut one);
        let msg = msghdr(&mut iov, control.as_mut_ptr(), control.len());
        let h = unsafe { libc::CMSG_FIRSTHDR(&msg) };
        assert_eq!(h as usize, control.as_ptr() as usize, "the first header is the buffer's start");
        assert_eq!(unsafe { libc::CMSG_DATA(h) } as usize - h as usize, 16, "the rights start 16 bytes in");
        let short = msghdr(&mut iov, control.as_mut_ptr(), 15);
        assert!(unsafe { libc::CMSG_FIRSTHDR(&short) }.is_null(), "no header fits in 15 bytes");
    }

    /// **L3d** — rights still cross by `SCM_RIGHTS` in libc's `msghdr` and
    /// `cmsghdr`: two descriptors sent in one message arrive as two new
    /// descriptors naming the same open files, close-on-exec on arrival
    /// (`MSG_CMSG_CLOEXEC`); a third beyond the receiver's room is refused as
    /// truncation, never silently dropped.
    #[test]
    fn t27_l3d_rights_cross_by_scm_rights_and_arrive_close_on_exec() {
        let Pair(a, b) = pair_seqpacket().expect("a seqpacket pair");
        let x = spare_fd().expect("a spare socket");
        let y = unsafe { libc::open(c"/dev/null".as_ptr(), libc::O_RDONLY | libc::O_CLOEXEC) };
        assert!(y >= 0);

        send_with_fds(a, b"two", &[x, y]).expect("sendmsg with two rights");
        let (bytes, got) = recv_msg_with_fds(b, 64, 4).expect("recvmsg");
        assert_eq!(bytes, b"two");
        assert_eq!(got.len(), 2, "two rights sent, {} arrived", got.len());
        for (sent, arrived) in [x, y].iter().zip(&got) {
            assert_ne!(sent, arrived, "a right arrives as a new descriptor");
            assert_eq!(fd_state(*arrived), FdState::Cloexec, "arrived without MSG_CMSG_CLOEXEC");
            assert_eq!(dev_ino(*sent), dev_ino(*arrived), "not the open file that was sent");
        }

        send_with_fds(a, b"three", &[x, y, x]).expect("sendmsg with three rights");
        let e = recv_msg_with_fds(b, 64, 1).expect_err("room for two, three sent");
        assert!(e.to_string().contains("truncated"), "{e}");

        for fd in got.into_iter().chain([x, y, a, b]) {
            close_fd(fd);
        }
    }
}

#[cfg(test)]
mod t27b {
    //! T27b's laws on the host's side of the bridge (`superlane/t27b/TASK.md`): B3 (the sender's 8,192-byte limit,
    //! by name, nothing written), B5 (a cut reply is named, never read), B6 (a short `sendmsg` is never `Ok`) and B8 (a
    //! normal bridge message arrives byte for byte, with exactly its rights).
    use super::*;

    /// Nothing is waiting on `fd` (a non-blocking read finds no message).
    fn nothing_waiting(fd: RawFd) -> bool {
        let mut b = [0u8; 16];
        let n = unsafe { libc::recv(fd, b.as_mut_ptr().cast(), b.len(), libc::MSG_DONTWAIT) };
        n < 0 && io::Error::last_os_error().kind() == io::ErrorKind::WouldBlock
    }

    #[test]
    fn b3_the_bridge_sender_takes_8192_bytes_and_refuses_8193_by_name_writing_nothing() {
        let _serial = super::t27b_serial();
        let Pair(a, b) = pair_seqpacket().unwrap();
        send_bridge_plain(a, &vec![b'x'; BRIDGE_COMMAND_MAX]).expect("8,192 bytes is a whole command");
        assert_eq!(recv_msg(b, BRIDGE_REPLY_MAX).unwrap().len(), BRIDGE_COMMAND_MAX);
        let e = send_bridge_plain(a, &vec![b'x'; BRIDGE_COMMAND_MAX + 1]).unwrap_err();
        assert!(e.to_string().starts_with("frame-too-large"), "{e}");
        let spare = spare_fd().unwrap();
        let e = send_bridge_with_fds(a, &vec![b'x'; BRIDGE_COMMAND_MAX + 1], &[spare]).unwrap_err();
        close_fd(spare);
        assert!(e.to_string().starts_with("frame-too-large"), "{e}");
        let e = send_bridge_plain(a, b"").unwrap_err();
        assert!(e.to_string().starts_with("empty-command"), "an empty command (the runtime's EOF) was sent: {e}");
        assert!(nothing_waiting(b), "a refused command reached the runtime");
        close_fd(a);
        close_fd(b);
    }

    #[test]
    fn b5_a_reply_of_65536_bytes_arrives_whole_and_a_longer_one_is_named_never_read() {
        let _serial = super::t27b_serial();
        let Pair(a, b) = pair_seqpacket().unwrap();
        send_plain(a, &vec![b'y'; BRIDGE_REPLY_MAX]).unwrap();
        assert_eq!(recv_msg(b, BRIDGE_REPLY_MAX).unwrap().len(), BRIDGE_REPLY_MAX);
        send_plain(a, &vec![b'y'; BRIDGE_REPLY_MAX + 1]).unwrap();
        let e = recv_msg(b, BRIDGE_REPLY_MAX).unwrap_err();
        assert!(e.to_string().starts_with("reply-too-large"), "{e}");
        close_fd(a);
        close_fd(b);
    }

    #[test]
    fn b6_a_short_sendmsg_is_never_ok() {
        let _serial = super::t27b_serial();
        let Pair(a, b) = pair_seqpacket().unwrap();
        let spare = spare_fd().unwrap();
        SHORT_SEND.with(|c| c.set(Some(3)));
        let with_fds = send_with_fds(a, b"hello", &[spare]);
        let plain = send_plain(a, b"hello");
        SHORT_SEND.with(|c| c.set(None));
        close_fd(spare);
        assert!(with_fds.is_err(), "a 3-of-5-byte sendmsg with rights returned Ok");
        assert!(plain.is_err(), "a 3-of-5-byte sendmsg returned Ok");
        close_fd(a);
        close_fd(b);
    }

    #[test]
    fn b8_a_normal_bridge_command_arrives_byte_for_byte_with_exactly_its_rights() {
        let _serial = super::t27b_serial();
        let Pair(a, b) = pair_seqpacket().unwrap();
        let cmd = br#"{"schema":"bridge-command@1","command":"list_channels"}"#;
        send_bridge_plain(a, cmd).unwrap();
        let (got, fds) = recv_msg_with_fds(b, BRIDGE_REPLY_MAX, 4).unwrap();
        assert_eq!(&got[..], &cmd[..]);
        assert!(fds.is_empty(), "a plain command carried rights");
        let spare = spare_fd().unwrap();
        let bind = br#"{"schema":"bridge-command@1","command":"bind_agent_channel","actor":"t27b"}"#;
        send_bridge_with_fds(a, bind, &[spare]).unwrap();
        close_fd(spare);
        let (got, fds) = recv_msg_with_fds(b, BRIDGE_REPLY_MAX, 4).unwrap();
        assert_eq!(&got[..], &bind[..]);
        assert_eq!(fds.len(), 1, "a bind carries exactly its one descriptor");
        for f in fds {
            close_fd(f);
        }
        close_fd(a);
        close_fd(b);
    }
}
