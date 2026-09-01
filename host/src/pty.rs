//! D.1.3c·1 — a pseudoterminal the host owns and a Carrier possesses.
//!
//! ```text
//!        trusted host                          Carrier
//!  ┌───────────────────────────┐        ┌────────────────────┐
//!  │ /dev/ptmx  ──► master fd  │        │  0 ─┐              │
//!  │            O_CLOEXEC      │◄──────►│  1 ─┼─ PTY slave   │
//!  │                           │ bytes  │  2 ─┘              │
//!  │ TIOCGPTPEER ──► slave fd  │───────►│  3 ── control      │
//!  │            closed after   │  dup   │                    │
//!  │            spawn          │        │  no /dev/pts grant │
//!  └───────────────────────────┘        └────────────────────┘
//! ```
//!
//! # No pathname is ever formed
//!
//! `ptsname(3)` is not called and `/dev/pts/N` is never constructed. The
//! slave is minted by `ioctl(master, TIOCGPTPEER, …)`, which **returns the
//! descriptor**, so the only thing that ever names this terminal is
//! possession of the master it came from. That is the same move D.1.3a made
//! for the effect channel, one layer down: `TIOCGPTPEER` is to `ptsname` what
//! `SCM_RIGHTS` is to a socket path.
//!
//! The kernel documents the property directly — the operation works
//! *"regardless of whether the pathname of the slave device is accessible
//! through the calling process's mount namespace"*. It is Linux 4.13+, and
//! **there is no `ptsname` fallback on purpose**: a compatibility path that
//! resolved a name and hoped it still meant the same resource would undo the
//! whole point on the kernels least able to afford it. An older kernel gets a
//! typed refusal instead — see [`Pty::open`].
//!
//! # What is deliberately NOT here
//!
//! No byte pump, no proxy, no stream endpoint for the runtime or the cockpit.
//! c·1 proves *the Carrier possesses a terminal*; who else may hold an
//! attachment to that terminal is c·2's question and a different mechanism.
//! The master stays inside this process, and the only thing that reads or
//! writes it in this slice is `verify`.
//!
//! # The three measurements this exists to make possible
//!
//! `TIOCGSID` and `TIOCGPGRP` on a **master** answer for the session and
//! foreground group that claimed the *slave* — and `TIOCGSID` fails `ENOTTY`
//! until somebody has claimed it, which makes it a clean binary probe keyed
//! on the descriptor the host holds rather than on any name. `st_rdev` from
//! `fstat` is the third, independent of both.

use std::os::fd::RawFd;

extern "C" {
    fn syscall(num: i64, ...) -> i64;
    // Signatures match `fdpass.rs` and `confine.rs` exactly. Two `extern`
    // blocks describing one symbol differently is a warning today and a
    // calling-convention bug the day one of them changes.
    fn open(path: *const u8, flags: i32, mode: i32) -> i32;
    fn close(fd: i32) -> i32;
    fn fcntl(fd: i32, cmd: i32, arg: i32) -> i32;
    fn __errno_location() -> *mut i32;
}

const SYS_IOCTL: i64 = 16;

const O_RDWR: i32 = 0o2;
const O_NOCTTY: i32 = 0o400;
const O_CLOEXEC: i32 = 0o2000000;

// **Every one of these is `u64` and written as hex, and that is not style.**
// `TIOCGPTN` and `TIOCGPTLCK` have bit 31 set — it is `_IOC_READ`, the
// direction field — so through an `i32` they are negative numbers that
// sign-extend to `0xFFFFFFFF80045430` when widened for the syscall. The
// request would then match nothing and the call would fail for a reason no
// amount of reading the ioctl list would explain.
pub const TIOCSPTLCK: u64 = 0x4004_5431;
pub const TIOCGPTN: u64 = 0x8004_5430;
pub const TIOCGPTPEER: u64 = 0x0000_5441;
pub const TIOCSCTTY: u64 = 0x0000_540e;
pub const TIOCGPGRP: u64 = 0x0000_540f;
pub const TIOCGSID: u64 = 0x0000_5429;
pub const TIOCGWINSZ: u64 = 0x0000_5413;
pub const TIOCSWINSZ: u64 = 0x0000_5414;

#[repr(C)]
#[derive(Default, Clone, Copy, Debug, PartialEq, Eq)]
pub struct WinSize {
    pub rows: u16,
    pub cols: u16,
    pub xpixel: u16,
    pub ypixel: u16,
}

fn errno() -> i32 {
    unsafe { *__errno_location() }
}

/// A master/slave pair. Owns both descriptors until [`Pty::close_slave`].
#[derive(Debug)]
pub struct Pty {
    master: RawFd,
    slave: Option<RawFd>,
    /// The devpts index, read once at allocation. **For evidence only** —
    /// nothing resolves it back into a pathname, and it is never serialized
    /// into a ticket, a receipt or a projection.
    ptn: u32,
    /// `st_rdev` of the slave as the host created it. The anchor the
    /// provenance falsifier compares `/proc/<pid>/fd/0` against, because the
    /// device number identifies the slave **within the current devpts
    /// instance** and the symlink text is only a name.
    ///
    /// **The condition on that exactness, recorded.** Linux allows multiple
    /// independent devpts instances and the kernel documents that indices do
    /// not span them, so two slaves in two instances can carry the same
    /// `st_rdev` — major 136 with the index as the minor. It is `st_dev`
    /// that separates the instances. Super is sound today because host and
    /// Carrier share one devpts instance and the Carrier cannot `unshare` or
    /// `setns` into another — which is a measured confinement row, not an
    /// assumption. **If Carrier confinement ever gains its own mount or
    /// devpts namespace, this must become `{st_dev, st_ino, st_rdev}` or
    /// another measured kernel identity before exactness is claimed across
    /// instances.**
    slave_rdev: u64,
    /// Ephemeral, host-originated, 16 CSPRNG bytes — minted here because the
    /// terminal is allocated here, and a replacement terminal must be
    /// unable to inherit its predecessor's name.
    ///
    /// **Not authority and not durable.** It grants nothing; it is the third
    /// identity a terminal operation must name — beside `carrier_ref` and
    /// `carrier_epoch` — so that input or a resize addressed to a dead PTY
    /// cannot land on the live one that replaced it. It is never a pathname
    /// and it never outlives the `Pty`.
    epoch: String,
}

impl Pty {
    /// Allocate a pair.
    ///
    /// The order is fixed and each step earns its place:
    ///
    /// ```text
    /// open /dev/ptmx      posix_openpt(3) IS this open on Linux
    /// TIOCSPTLCK 0        unlockpt(3). REQUIRED — TIOCGPTPEER honours the
    ///                     lock and returns EIO before it
    /// TIOCGPTN            the index, recorded as evidence and not used
    /// TIOCGPTPEER         the slave descriptor, from the master alone
    /// ```
    ///
    /// `grantpt(3)` is **not** called: it is a no-op on Linux, where the
    /// slave's owner and mode come from the devpts mount options rather than
    /// from a helper. On this machine that means mode `0600`, not the
    /// POSIX-specified `0620` — worth knowing before anyone asserts on it.
    ///
    /// `/dev/ptmx` and not `/dev/pts/ptmx`: this mount is `ptmxmode=000`, so
    /// the in-directory node exists and cannot be opened by anyone.
    pub fn open() -> Result<Pty, String> {
        let m = unsafe { open(b"/dev/ptmx\0".as_ptr(), O_RDWR | O_NOCTTY | O_CLOEXEC, 0) };
        if m < 0 {
            return Err(format!("pty: opening /dev/ptmx: errno {}", errno()));
        }

        let unlock: i32 = 0;
        if unsafe { syscall(SYS_IOCTL, m as i64, TIOCSPTLCK, &unlock as *const i32) } < 0 {
            let e = errno();
            unsafe { close(m) };
            return Err(format!("pty: unlocking the pty: errno {e}"));
        }

        let mut n: u32 = 0;
        if unsafe { syscall(SYS_IOCTL, m as i64, TIOCGPTN, &mut n as *mut u32) } < 0 {
            let e = errno();
            unsafe { close(m) };
            return Err(format!("pty: reading the pty index: errno {e}"));
        }

        let s = unsafe {
            syscall(
                SYS_IOCTL,
                m as i64,
                TIOCGPTPEER,
                (O_RDWR | O_NOCTTY | O_CLOEXEC) as i64,
            )
        };
        if s < 0 {
            let e = errno();
            unsafe { close(m) };
            // **A typed refusal, and no fallback.** `TIOCGPTPEER` is Linux
            // 4.13+; on anything older this is `EINVAL`/`ENOTTY`. The
            // alternative — `ptsname` plus opening the pathname — would turn
            // possession back into namespace addressing precisely on the
            // kernels least able to afford it, so Super declares a floor
            // instead of degrading past its own doctrine.
            return Err(format!(
                "pty-peer-descriptor-unavailable: the kernel refused TIOCGPTPEER (errno {e}); \
                 Super requires Linux 4.13+ for a possessed terminal and will not fall back to \
                 resolving the slave by pathname"
            ));
        }

        let slave_rdev = fstat_rdev(s as RawFd).unwrap_or(0);
        Ok(Pty {
            master: m,
            slave: Some(s as RawFd),
            ptn: n,
            slave_rdev,
            // `crate::new_epoch` and not a second mint here. Two epoch mints
            // in one process are two disciplines that can drift, and the
            // width of this one is the whole of its value.
            epoch: crate::new_epoch(),
        })
    }

    pub fn master(&self) -> RawFd {
        self.master
    }
    pub fn slave(&self) -> Option<RawFd> {
        self.slave
    }
    pub fn ptn(&self) -> u32 {
        self.ptn
    }
    pub fn slave_rdev(&self) -> u64 {
        self.slave_rdev
    }
    /// The terminal's ephemeral identity. See the field.
    pub fn epoch(&self) -> &str {
        &self.epoch
    }

    /// A private copy of the master for a pump thread.
    ///
    /// **The master itself is never handed over.** `Pty` owns exactly one
    /// number and closes it in `Drop`; a thread that outlives this borrow
    /// needs a number of its own, and `dup(2)` is the only way to get one
    /// without giving away the original.
    ///
    /// **This is a hangup-suppressing operation and the caller owes a
    /// close.** A pseudoterminal delivers `SIGHUP` to its session on the
    /// *last* close of the master, so a leaked duplicate is a death signal
    /// that never fires — the exact defect host probe 32 constructs on the
    /// slave side. Every duplicate this returns must be closed before the
    /// `Carrier` that owns the terminal is disposed of, and the death matrix
    /// counts the host's masters across that boundary to prove it.
    pub fn dup_master(&self) -> Result<RawFd, String> {
        // F_DUPFD_CLOEXEC, not dup(2): a duplicate that survived an exec
        // would be a master descriptor in a process that was never given
        // one. Declared beside its use, as `set_nonblocking` declares
        // `F_GETFL`.
        const F_DUPFD_CLOEXEC: i32 = 1030;
        let d = unsafe { fcntl(self.master, F_DUPFD_CLOEXEC, 0) };
        if d < 0 {
            return Err(format!("pty: duplicating the master: errno {}", errno()));
        }
        Ok(d as RawFd)
    }

    /// Drop the host's copy of the slave, leaving the Carrier the only holder.
    ///
    /// **Called after the spawn and not before.** Until it is, the host holds
    /// a reference and the master will not see a hangup when the Carrier
    /// dies — measured: the master reports `POLLHUP` on the *last* close, not
    /// the first. A host that kept this open would have built a death signal
    /// that never fires.
    pub fn close_slave(&mut self) {
        if let Some(s) = self.slave.take() {
            unsafe { close(s) };
        }
    }

    /// The session that claimed this terminal, asked of the **master**.
    ///
    /// `ENOTTY` until a slave-side session leader has taken it as its
    /// controlling terminal, then exactly that session id. That is what makes
    /// it a provenance proof rather than a liveness check: a decoy master the
    /// host also holds answers `ENOTTY` forever.
    pub fn session(&self) -> Option<i32> {
        let mut sid: i32 = 0;
        let r = unsafe { syscall(SYS_IOCTL, self.master as i64, TIOCGSID, &mut sid as *mut i32) };
        if r < 0 {
            None
        } else {
            Some(sid)
        }
    }

    /// The foreground process group of this terminal, asked of the master.
    pub fn foreground_pgrp(&self) -> Option<i32> {
        let mut pg: i32 = 0;
        let r = unsafe { syscall(SYS_IOCTL, self.master as i64, TIOCGPGRP, &mut pg as *mut i32) };
        if r < 0 {
            None
        } else {
            Some(pg)
        }
    }

    /// Resize. **Host-only in c·1** — the payload is refused `TIOCSWINSZ` by
    /// seccomp, so a terminal's dimensions are something done *to* a Carrier
    /// and never by it. The typed operation that will drive this from the
    /// runtime belongs to c·2; this is the mechanism it will use.
    pub fn set_winsize(&self, ws: WinSize) -> Result<(), String> {
        let r = unsafe { syscall(SYS_IOCTL, self.master as i64, TIOCSWINSZ, &ws as *const WinSize) };
        if r < 0 {
            Err(format!("pty: setting the window size: errno {}", errno()))
        } else {
            Ok(())
        }
    }

    /// Make reads on the master return `EAGAIN` instead of blocking.
    ///
    /// **A harness that can wedge is a worse defect than anything it can
    /// find**, and this exists because one did. `verify`'s ioctl census read
    /// the master until the hangup — correct when the Carrier is the only
    /// slave holder, and an unbounded block when it is not. The host
    /// sabotage battery has a probe that deliberately makes the host keep
    /// its copy of the slave, so the hangup could never arrive: the probe
    /// scored `TIMED OUT` after 240s and proved nothing, and it was right
    /// to. A blocking read whose terminating condition is the thing under
    /// test is not a measurement.
    pub fn set_nonblocking(&self) -> Result<(), String> {
        const F_GETFL: i32 = 3;
        const F_SETFL: i32 = 4;
        const O_NONBLOCK: i32 = 0o4000;
        let fl = unsafe { fcntl(self.master, F_GETFL, 0) };
        if fl < 0 || unsafe { fcntl(self.master, F_SETFL, fl | O_NONBLOCK) } < 0 {
            return Err(format!("pty: setting O_NONBLOCK: errno {}", errno()));
        }
        Ok(())
    }

    pub fn winsize(&self) -> Option<WinSize> {
        let mut ws = WinSize::default();
        let r =
            unsafe { syscall(SYS_IOCTL, self.master as i64, TIOCGWINSZ, &mut ws as *mut WinSize) };
        if r < 0 {
            None
        } else {
            Some(ws)
        }
    }
}

impl Drop for Pty {
    /// **The PTY cannot outlive the host's record of it.** Both ends close
    /// here, and dropping the master is what delivers `SIGHUP` to a Carrier
    /// that took this terminal as its controlling one. That is a second lever
    /// beside `PR_SET_PDEATHSIG` and not a replacement for it: a payload that
    /// ignores `SIGHUP` survives the hangup, which is measured, so the
    /// parent-death signal stays the floor.
    fn drop(&mut self) {
        self.close_slave();
        unsafe { close(self.master) };
    }
}

/// `st_rdev` of a descriptor, via `fstat(2)`.
///
/// Hand-rolled rather than `std::os::unix::fs::MetadataExt` on a `File`,
/// because building a `File` from the raw fd would transfer ownership of the
/// number and close it on drop — the exact defect D.1.3b·2a spent a session
/// finding in the control-channel handshake.
pub fn fstat_rdev(fd: RawFd) -> Option<u64> {
    const SYS_FSTAT: i64 = 5;
    let mut buf = [0u64; 18];
    let r = unsafe { syscall(SYS_FSTAT, fd as i64, buf.as_mut_ptr()) };
    if r < 0 {
        return None;
    }
    Some(buf[ST_RDEV_WORD])
}

/// `st_rdev`'s index in `struct stat` read as `u64` words, on x86-64:
///
/// ```text
///   0   st_dev            byte  0
///   1   st_ino                  8
///   2   st_nlink               16
///   3   st_mode | st_uid       24   ← four bytes each, packed into one word
///   4   st_gid  | __pad0       32
///   5   st_rdev                40
/// ```
///
/// **This was `3` and both sides of the provenance check read it**, so the
/// comparison was between `st_uid | st_mode` — `0x3e8_00002180`, uid 1000 and
/// mode `0600 | S_IFCHR` — which is byte-identical for *any* two
/// pseudoterminals on this machine. The check passed, and it passed for a
/// reason that had nothing to do with the terminals being the same one.
///
/// The decoy master is what found it: the Carrier's fd 0 "matched" the decoy
/// too, which is impossible and therefore a defect in the predicate rather
/// than in the thing under test. A falsifier with no way to be wrong had
/// silently become one.
const ST_RDEV_WORD: usize = 5;

/// Decode `/proc/<pid>/stat` field 7 (`tty_nr`) into `(major, minor)`.
///
/// `proc_pid_stat(5)`: *"The minor device number is contained in the
/// combination of bits 31 to 20 and 7 to 0; the major device number is in
/// bits 15 to 8."* A split minor, which is why this is a function and not an
/// expression written twice.
pub fn decode_tty_nr(t: u32) -> (u32, u32) {
    ((t >> 8) & 0xff, (t & 0xff) | ((t >> 12) & 0xfff00))
}

/// Are this process's 0, 1 and 2 the *exact* slave of a given master?
///
/// **The equality the v3 floor was missing.** v3 required that stdio be a
/// pseudoterminal, that 0/1/2 be one terminal, and — separately — that the
/// process's *controlling terminal* be the one whose master this host holds.
/// Those are two facts about two relationships and Unix does not join them:
/// a process may have controlling terminal A while its standard descriptors
/// refer to terminal B. Both halves would pass and the terminal the Carrier
/// is *using* need not be the terminal the host says it possesses.
///
/// Compared by `st_rdev` rather than by the `/proc/<pid>/fd/N` symlink text,
/// for the reason recorded on [`fstat_rdev_of_path`]: the string
/// `/dev/pts/36` is a name, equally true of another mount namespace's
/// terminal with the same index. The device number is the resource.
///
/// All three descriptors, not just fd 0. A Carrier reading from the host's
/// terminal and writing somewhere else is exactly the split this exists to
/// refuse.
pub fn stdio_is_slave(pid: u32, slave_rdev: u64) -> bool {
    slave_rdev != 0
        && (0..=2).all(|fd| {
            fstat_rdev_of_path(&format!("/proc/{pid}/fd/{fd}")) == Some(slave_rdev)
        })
}

/// The four terminal properties of a process, read separately.
///
/// **They are not synonyms and this struct exists so that nothing can treat
/// them as one.** A process can have a PTY on 0/1/2 and no session of its
/// own; it can be a session leader and still have no controlling terminal —
/// `setsid(2)` says so and it is measured. Collapsing these into
/// `has_pty = true` would make the staged falsifier unwritable, and the stage
/// that matters is the middle one.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct TermProps {
    /// `/proc/<pid>/stat` field 5.
    pub pgrp: Option<i32>,
    /// Field 6. Session leader iff this equals the pid.
    pub session: Option<i32>,
    /// Field 7. **`0` means no controlling terminal** — not "unknown".
    pub tty_nr: Option<u32>,
    /// Field 8. `-1` when there is no controlling terminal.
    pub tpgid: Option<i32>,
}

impl TermProps {
    pub fn read(pid: u32) -> TermProps {
        let Ok(s) = std::fs::read_to_string(format!("/proc/{pid}/stat")) else {
            return TermProps::default();
        };
        // Split after the **last** `)`: `comm` is arbitrary and can contain
        // both spaces and parentheses. `carrier::observe` uses the same
        // idiom for `starttime` and for the same reason.
        let Some(tail) = s.rsplit_once(')') else {
            return TermProps::default();
        };
        let f: Vec<&str> = tail.1.split_whitespace().collect();
        // `tail` begins at field 3, so field N is at index N - 3.
        TermProps {
            pgrp: f.get(2).and_then(|v| v.parse().ok()),
            session: f.get(3).and_then(|v| v.parse().ok()),
            tty_nr: f.get(4).and_then(|v| v.parse::<i32>().ok()).map(|v| v as u32),
            tpgid: f.get(5).and_then(|v| v.parse().ok()),
        }
    }

    pub fn is_session_leader(&self, pid: u32) -> bool {
        self.session == Some(pid as i32)
    }
    pub fn has_controlling_terminal(&self) -> bool {
        matches!(self.tty_nr, Some(t) if t != 0)
    }
    pub fn is_foreground(&self) -> bool {
        self.tpgid.is_some() && self.tpgid == self.pgrp
    }
}

/// Compose a device number the way `st_rdev` encodes it, so a `tty_nr` read
/// from `/proc` can be compared against an `fstat` of the host's own slave.
pub fn makedev(major: u32, minor: u32) -> u64 {
    ((major as u64 & 0xfff) << 8)
        | (minor as u64 & 0xff)
        | ((major as u64 & !0xfff) << 32)
        | ((minor as u64 & !0xff) << 12)
}

/// `st_rdev` of whatever a path resolves to.
///
/// Used against `/proc/<pid>/fd/0`, and the distinction is the point: this
/// asks the kernel what *device* the descriptor refers to, where
/// `read_link` on the same path returns the string `/dev/pts/36`. The string
/// is a name — it would be equally true of another namespace's terminal with
/// the same index — and a name is not possession.
/// `stat(2)` and never `open`. Opening `/proc/<pid>/fd/0` would *reopen the
/// terminal* — acquiring the thing under measurement is exactly what this
/// slice says nobody may do by name, and doing it inside the falsifier would
/// be the measurement granting itself the authority it is checking for.
pub fn fstat_rdev_of_path(path: &str) -> Option<u64> {
    const SYS_STAT: i64 = 4;
    let mut c = path.as_bytes().to_vec();
    c.push(0);
    let mut buf = [0u64; 18];
    let r = unsafe { syscall(SYS_STAT, c.as_ptr(), buf.as_mut_ptr()) };
    if r < 0 {
        None
    } else {
        Some(buf[ST_RDEV_WORD])
    }
}
