//! `socketpair(2)`, inherited descriptors, and `SCM_RIGHTS` — by hand.
//!
//! No crate for this. The whole point of the C1.1 correction is that the
//! capability *is* the descriptor, so the code that creates and passes one
//! should be readable in full rather than delegated to a dependency whose
//! flags you have to go and check.

use std::io;
use std::os::unix::io::RawFd;

// ---------------------------------------------------------------- libc
//
// Declared here rather than pulled in, for the reason above. These are the
// four calls the trust model rests on.
extern "C" {
    fn socketpair(domain: i32, ty: i32, protocol: i32, sv: *mut i32) -> i32;
    fn flock(fd: i32, operation: i32) -> i32;
    fn open(path: *const u8, flags: i32, mode: i32) -> i32;
    fn sendmsg(fd: i32, msg: *const MsgHdr, flags: i32) -> isize;
    fn recvmsg(fd: i32, msg: *mut MsgHdr, flags: i32) -> isize;
    fn close(fd: i32) -> i32;
    fn fcntl(fd: i32, cmd: i32, arg: i32) -> i32;
    fn dup2(old: i32, new: i32) -> i32;
    fn shutdown(fd: i32, how: i32) -> i32;
    /// Variadic, exactly as `confine.rs` declares it and for the same
    /// reason: `close_range(2)` is reached as a raw syscall rather than
    /// through glibc's wrapper, so the failure this floor must not survive
    /// — the kernel not having it — arrives as `ENOSYS` from the kernel
    /// instead of as whatever a libc chose to do about it.
    fn syscall(num: i64, ...) -> i64;
}

const SHUT_RDWR: i32 = 2;

const AF_UNIX: i32 = 1;
const SOCK_STREAM: i32 = 1;
const SOCK_SEQPACKET: i32 = 5;
/// `SOCK_CLOEXEC` — Linux `0o2000000`.
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
const SOCK_CLOEXEC: i32 = 0o2000000;
/// `MSG_CMSG_CLOEXEC` — the same rule for descriptors that *arrive*.
pub const MSG_CMSG_CLOEXEC: i32 = 0x40000000;
const SOL_SOCKET: i32 = 1;
const SCM_RIGHTS: i32 = 1;
const F_SETFD: i32 = 2;
const F_GETFD: i32 = 1;
const FD_CLOEXEC: i32 = 1;

/// `close_range(2)` — x86-64 syscall 436, Linux 5.9.
const SYS_CLOSE_RANGE: i64 = 436;
/// `CLOSE_RANGE_CLOEXEC` — Linux 5.11. **Marks the range close-on-exec; it
/// does not close it.** That distinction is the whole of `seal_inheritance`.
const CLOSE_RANGE_CLOEXEC: u32 = 1 << 2;

#[repr(C)]
struct IoVec {
    base: *mut u8,
    len: usize,
}

#[repr(C)]
struct MsgHdr {
    name: *mut u8,
    namelen: u32,
    iov: *mut IoVec,
    iovlen: usize,
    control: *mut u8,
    controllen: usize,
    flags: i32,
}

#[repr(C)]
struct CmsgHdr {
    len: usize,
    level: i32,
    ty: i32,
}

const CMSG_ALIGN_TO: usize = std::mem::size_of::<usize>();
const fn cmsg_align(n: usize) -> usize {
    (n + CMSG_ALIGN_TO - 1) & !(CMSG_ALIGN_TO - 1)
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
    let rc = unsafe {
        syscall(
            SYS_CLOSE_RANGE,
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
    const O_RDWR: i32 = 2;

    for target in 0..3 {
        if unsafe { fcntl(target, F_GETFD, 0) } != -1 {
            continue;
        }
        // `open` takes the lowest free descriptor, and `target` is free by
        // the test above — but only if every number below it is taken,
        // which the loop's order guarantees.
        let fd = unsafe { open(b"/dev/null\0".as_ptr(), O_RDWR, 0) };
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
    const O_RDWR: i32 = 2;
    const O_CREAT: i32 = 0o100;
    const O_CLOEXEC: i32 = 0o2000000;
    const LOCK_EX: i32 = 2;
    const LOCK_NB: i32 = 4;

    let mut c = path.as_os_str().as_encoded_bytes().to_vec();
    c.push(0);

    let fd = unsafe { open(c.as_ptr(), O_RDWR | O_CREAT | O_CLOEXEC, 0o600) };
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
    let mut buf = bytes.to_vec();
    let mut iov = IoVec {
        base: buf.as_mut_ptr(),
        len: buf.len(),
    };

    let hdr_len = std::mem::size_of::<CmsgHdr>();
    let payload = std::mem::size_of::<i32>() * fds.len();
    // `CMSG_SPACE` for the buffer, `CMSG_LEN` for the header's own length.
    // They differ by the tail padding, and using one for the other is how
    // a receiver ends up reading a descriptor that was never sent.
    let space = cmsg_align(hdr_len) + cmsg_align(payload);
    let mut control = vec![0u8; space];

    unsafe {
        let cmsg = control.as_mut_ptr() as *mut CmsgHdr;
        (*cmsg).len = hdr_len + payload;
        (*cmsg).level = SOL_SOCKET;
        (*cmsg).ty = SCM_RIGHTS;
        let data = control.as_mut_ptr().add(cmsg_align(hdr_len)) as *mut i32;
        for (i, fd) in fds.iter().enumerate() {
            *data.add(i) = *fd;
        }
    }

    let msg = MsgHdr {
        name: std::ptr::null_mut(),
        namelen: 0,
        iov: &mut iov,
        iovlen: 1,
        control: control.as_mut_ptr(),
        controllen: space,
        flags: 0,
    };

    let n = unsafe { sendmsg(sock, &msg, 0) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
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
    let mut buf = bytes.to_vec();
    let mut iov = IoVec {
        base: buf.as_mut_ptr(),
        len: buf.len(),
    };

    let msg = MsgHdr {
        name: std::ptr::null_mut(),
        namelen: 0,
        iov: &mut iov,
        iovlen: 1,
        control: std::ptr::null_mut(),
        controllen: 0,
        flags: 0,
    };

    let n = unsafe { sendmsg(sock, &msg, 0) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Receive one message. Returns its bytes.
///
/// `MSG_CMSG_CLOEXEC` on every receive: a descriptor that arrives is
/// close-on-exec too, so the rule holds on both sides of a handoff.
pub fn recv_msg(sock: RawFd, max: usize) -> io::Result<Vec<u8>> {
    let mut buf = vec![0u8; max];
    let mut iov = IoVec {
        base: buf.as_mut_ptr(),
        len: buf.len(),
    };

    let mut msg = MsgHdr {
        name: std::ptr::null_mut(),
        namelen: 0,
        iov: &mut iov,
        iovlen: 1,
        control: std::ptr::null_mut(),
        controllen: 0,
        flags: 0,
    };

    let n = unsafe { recvmsg(sock, &mut msg, MSG_CMSG_CLOEXEC) };
    if n < 0 {
        return Err(io::Error::last_os_error());
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
    const MSG_CTRUNC: i32 = 0x8;

    let mut buf = vec![0u8; max];
    let mut iov = IoVec {
        base: buf.as_mut_ptr(),
        len: buf.len(),
    };

    let space = cmsg_align(std::mem::size_of::<CmsgHdr>()) + cmsg_align(max_fds * 4);
    let mut ctrl = vec![0u8; space];

    let mut msg = MsgHdr {
        name: std::ptr::null_mut(),
        namelen: 0,
        iov: &mut iov,
        iovlen: 1,
        control: ctrl.as_mut_ptr(),
        controllen: ctrl.len(),
        flags: 0,
    };

    let n = unsafe { recvmsg(sock, &mut msg, MSG_CMSG_CLOEXEC) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    buf.truncate(n as usize);

    let mut fds: Vec<RawFd> = Vec::new();
    if msg.controllen >= std::mem::size_of::<CmsgHdr>() {
        // One control message is all this protocol ever sends. Walking a
        // chain would be a generality with no second case to keep it honest.
        let h = unsafe { &*(ctrl.as_ptr() as *const CmsgHdr) };
        if h.level == SOL_SOCKET && h.ty == SCM_RIGHTS && h.len >= std::mem::size_of::<CmsgHdr>() {
            let payload = h.len - std::mem::size_of::<CmsgHdr>();
            let base = unsafe {
                ctrl.as_ptr()
                    .add(cmsg_align(std::mem::size_of::<CmsgHdr>()))
            };
            for i in 0..(payload / 4) {
                let mut raw = [0u8; 4];
                unsafe { std::ptr::copy_nonoverlapping(base.add(i * 4), raw.as_mut_ptr(), 4) };
                fds.push(i32::from_ne_bytes(raw));
            }
        }
    }

    if (msg.flags & MSG_CTRUNC) != 0 {
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
