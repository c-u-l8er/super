//! D.1.3c·2 — a terminal attachment: the byte pump, and the stream endpoint
//! somebody other than the Carrier may possess.
//!
//! ```text
//!                    trusted super-host
//!                            │
//!                     owns PTY MASTER
//!                            │
//!                    ┌───────┴────────┐
//!                    │   byte pump    │   this file
//!                    └───────┬────────┘
//!                            │
//!                  private stream endpoint
//!                            │
//!                            ▼
//!                   TERMINAL ATTACHMENT
//!                            │
//!                       possessed by
//!                            │
//!                      Peer / runtime
//! ```
//!
//! c·1 established *Carrier possesses PTY slave*. This adds a second, and
//! **different**, typed relationship: *somebody possesses an attachment that
//! targets that PTY* — without possessing the master, without terminal
//! selection, and without any authority over the Carrier.
//!
//! # The pump is the mechanism; the socketpair is not
//!
//! It would be cheap to say "a socketpair already exists, so this is not new".
//! That would be counting the transport and not the thing. A socketpair is two
//! descriptors. **The pump is an owner**: of the master's bytes in both
//! directions, of the buffers that bound them, of the hangup translation from
//! a pseudoterminal's `EIO` into a stream's EOF, and of its own lifetime
//! against the Carrier's. None of that exists anywhere else in this host, so
//! the WEK census counts it as `+1`.
//!
//! # What the holder of the far end can do, exhaustively
//!
//! ```text
//!   write bytes    → the Carrier's terminal input
//!   read bytes     → the Carrier's terminal output
//!   observe EOF    → the terminal is gone
//! ```
//!
//! and nothing else. It is a `socketpair(AF_UNIX, SOCK_STREAM)` end: **not a
//! terminal**, so every `ioctl` that means anything to a terminal answers
//! `ENOTTY` on it — measured, rather than argued, in `verify`. It carries no
//! master, no pathname, no pts index, no control channel and no route to
//! another Carrier's stream.
//!
//! # Backpressure is the kernel's, and the buffers are bounded
//!
//! There is **no unbounded relay buffer**. Each direction has one fixed
//! [`BUF`]-byte buffer, and the pump only asks to read a side when that
//! side's outbound buffer has room. A consumer that stops reading therefore
//! fills its buffer, the pump stops draining the master, the pseudoterminal's
//! own kernel buffer fills, and **the Carrier blocks in `write`** — which is
//! what a terminal whose reader has gone quiet is supposed to do. The stall
//! propagates to the process that is producing, and never into this host's
//! heap.
//!
//! Nothing here claims lossless delivery. Bytes already accepted are
//! forwarded, and bytes that were never accepted were never accepted.
//!
//! # It holds a duplicate of the master, and that is a hangup hazard
//!
//! A thread cannot borrow a `Pty` owned by another thread's map, so the pump
//! gets its own descriptor from [`crate::pty::Pty::dup_master`]. A
//! pseudoterminal delivers `SIGHUP` on the **last** close of the master, so a
//! duplicate that outlived its Carrier would be a death signal that never
//! fires — host probe 32's defect, one descriptor over. The disposal is
//! therefore explicit and *joined*: [`Attachment::close`] stops the thread and
//! waits for it, and the death matrix counts the host's masters across every
//! Carrier discontinuity to prove the number came back.

use crate::pty::Pty;
use std::os::fd::RawFd;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;

extern "C" {
    fn read(fd: i32, buf: *mut u8, count: usize) -> isize;
    fn write(fd: i32, buf: *const u8, count: usize) -> isize;
    fn close(fd: i32) -> i32;
    fn shutdown(fd: i32, how: i32) -> i32;
    fn fcntl(fd: i32, cmd: i32, arg: i32) -> i32;
    fn poll(fds: *mut PollFd, nfds: u64, timeout: i32) -> i32;
    fn __errno_location() -> *mut i32;
}

fn errno() -> i32 {
    unsafe { *__errno_location() }
}

/// One direction's buffer. 64 KiB is larger than a pseudoterminal's own
/// kernel buffer and smaller than a socketpair's, so the *stall* lands on
/// whichever side stopped — which is the point — rather than this number
/// being the thing that governs.
const BUF: usize = 64 * 1024;

/// The poll deadline is **not** the wakeup mechanism and must not be read as
/// one: a hangup, readable data and writable space all wake `poll` on their
/// own, and a stop wakes it by shutting the stream endpoint down. It is the
/// floor under a wedge, and it exists because this round's predecessor spent
/// 240 seconds discovering that a read loop whose terminating condition is
/// the thing under test does not terminate.
const POLL_MS: i32 = 250;

const POLLIN: i16 = 0x001;
const POLLOUT: i16 = 0x004;
const POLLERR: i16 = 0x008;
const POLLHUP: i16 = 0x010;
const POLLNVAL: i16 = 0x020;

const SHUT_WR: i32 = 1;
const SHUT_RDWR: i32 = 2;

const EAGAIN: i32 = 11;
const EINTR: i32 = 4;
const EIO: i32 = 5;

#[repr(C)]
#[derive(Clone, Copy)]
struct PollFd {
    fd: i32,
    events: i16,
    revents: i16,
}

/// What the pump did, readable while it is still running.
///
/// Counters and not a log: the questions a falsifier asks are *did these
/// bytes cross*, *did this direction stall*, and *why did it end* — and a
/// transcript of terminal traffic is the one thing this host must not keep.
#[derive(Debug, Default)]
pub struct Stats {
    pub to_stream: AtomicU64,
    pub to_master: AtomicU64,
    /// Times the pump declined to read the master because the outbound
    /// buffer was full. **Non-zero is the backpressure claim being true**,
    /// not a fault.
    pub stalled_out: AtomicU64,
    pub stalled_in: AtomicU64,
    /// Set once, when the pump stops. See [`Ending`].
    pub ending: AtomicU64,
}

/// Why a pump stopped. Distinct values because they are distinct facts and
/// the runtime is told which one happened.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ending {
    /// Still running.
    Live = 0,
    /// The terminal hung up — the Carrier's slave was closed by the last
    /// holder, which means the Carrier is gone.
    TerminalHangup = 1,
    /// The far end closed or shut down its write side. **The holder let go;
    /// the Carrier is not affected.**
    HolderClosed = 2,
    /// The host asked, through [`Attachment::close`].
    HostClosed = 3,
    /// A descriptor went bad in a way neither of the above explains.
    Fault = 4,
}

impl Ending {
    pub fn name(self) -> &'static str {
        match self {
            Ending::Live => "live",
            Ending::TerminalHangup => "terminal-hangup",
            Ending::HolderClosed => "holder-closed",
            Ending::HostClosed => "host-closed",
            Ending::Fault => "fault",
        }
    }
    fn of(v: u64) -> Ending {
        match v {
            1 => Ending::TerminalHangup,
            2 => Ending::HolderClosed,
            3 => Ending::HostClosed,
            4 => Ending::Fault,
            _ => Ending::Live,
        }
    }
}

/// One attachment: a pump thread, the host's end of the private stream, and
/// the three identities a terminal operation has to name.
///
/// **The refs are not authority.** Nothing here grants anything; they exist so
/// that an operation addressed to a terminal that has been replaced can be
/// refused instead of landing on its replacement.
pub struct Attachment {
    pub attachment_ref: String,
    pub attachment_epoch: String,
    /// The epoch of the PTY this attachment targets — copied at creation, so
    /// a stale operation is caught by comparison and not by hoping the
    /// terminal is still there to disagree.
    pub pty_epoch: String,
    /// The host's end of the private stream. **Owned here, borrowed by the
    /// pump.** The pump may `shutdown` it and must never `close` it: a thread
    /// that closed a number the controlling thread still holds would release
    /// it for reuse while `close` was still to come.
    host_end: RawFd,
    stop: Arc<AtomicBool>,
    stats: Arc<Stats>,
    join: Option<JoinHandle<()>>,
}

impl std::fmt::Debug for Attachment {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Attachment")
            .field("attachment_ref", &self.attachment_ref)
            .field("pty_epoch", &self.pty_epoch)
            .field("ending", &self.ending().name())
            .finish()
    }
}

impl Attachment {
    /// Create an attachment on a Carrier's terminal.
    ///
    /// Returns the attachment and **the far end, which the caller owes to
    /// somebody and must then close.** It is returned rather than kept so
    /// that this function cannot be the thing that decides who may hold it —
    /// that question is answered before the call, by occupancy, and this is
    /// only the plumbing that follows the answer.
    pub fn open(pty: &Pty) -> Result<(Attachment, RawFd), String> {
        let master = pty.dup_master()?;

        let crate::fdpass::Pair(ours, theirs) = match crate::fdpass::pair_stream() {
            Ok(p) => p,
            Err(e) => {
                unsafe { close(master) };
                return Err(format!("terminal attachment socketpair: {e}"));
            }
        };

        // Both sides non-blocking before the thread exists. A pump that set
        // this up itself would have a window in which a blocking read of the
        // master could park it forever, and the window would be exactly the
        // moment a fast Carrier writes.
        if let Err(e) = set_nonblocking(master).and_then(|_| set_nonblocking(ours)) {
            unsafe { close(master) };
            crate::fdpass::close_fd(ours);
            crate::fdpass::close_fd(theirs);
            return Err(e);
        }

        let stop = Arc::new(AtomicBool::new(false));
        let stats = Arc::new(Stats::default());

        let t_stop = Arc::clone(&stop);
        let t_stats = Arc::clone(&stats);
        let join = std::thread::spawn(move || pump(master, ours, t_stop, t_stats));

        Ok((
            Attachment {
                // Full width, both of them. The ref was 12 hex characters —
                // 48 bits — while this slice was host-only and nothing
                // decided anything by it, and truncating it cost nothing
                // visible. It stops being free the moment the runtime names
                // an attachment object by it: an identifier that will be
                // indexed wants its collisions to be impossible rather than
                // improbable, and 48 bits is improbable at a scale this
                // stack keeps saying it is designing for. Widened before the
                // consumer exists, because afterwards the width is a
                // migration.
                attachment_ref: format!("ta_{}", crate::new_epoch()),
                attachment_epoch: crate::new_epoch(),
                pty_epoch: pty.epoch().to_string(),
                host_end: ours,
                stop,
                stats,
                join: Some(join),
            },
            theirs,
        ))
    }

    pub fn stats(&self) -> &Stats {
        &self.stats
    }

    pub fn ending(&self) -> Ending {
        Ending::of(self.stats.ending.load(Ordering::SeqCst))
    }

    /// Is the pump still moving bytes?
    pub fn live(&self) -> bool {
        self.ending() == Ending::Live
    }

    /// Wait, bounded, for the pump to stop **on its own**.
    ///
    /// Called when the Carrier's process has just been reaped. The terminal
    /// has hung up, the pump is about to notice, and the interesting thing is
    /// that it notices — so this waits for that rather than forcing it. The
    /// difference is visible: a forced stop reports `host-closed` and a
    /// settled one reports `terminal-hangup`, and only the second is evidence
    /// that PTY lifetime is bound to Carrier lifetime rather than to this
    /// host remembering to tidy up.
    ///
    /// Returns whether it settled. `false` is not a failure — [`Self::close`]
    /// still ends it — but it is the fact a check should assert on, because a
    /// pump that never notices a hangup is exactly the defect probe 32 built
    /// on the slave side.
    pub fn settle(&self, grace_ms: u64) -> bool {
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(grace_ms);
        while std::time::Instant::now() < deadline {
            if !self.live() {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        !self.live()
    }

    /// Stop the pump and **wait for it**.
    ///
    /// The join is the whole point. The pump holds a duplicate of the PTY
    /// master, and returning before that duplicate is closed would leave the
    /// terminal alive for an unbounded moment after the Carrier that owned it
    /// was disposed of — a hangup that fires late is a hangup a census can
    /// catch in the wrong state, and the master count across a Carrier's death
    /// is exactly what the death matrix measures.
    ///
    /// `shutdown` and not `close`: closing the descriptor the pump is polling
    /// would free the number for reuse while the pump was still naming it.
    /// `SHUT_RDWR` wakes `poll` immediately and leaves the number valid.
    pub fn close(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        unsafe { shutdown(self.host_end, SHUT_RDWR) };
        if let Some(j) = self.join.take() {
            let _ = j.join();
        }
    }
}

impl Drop for Attachment {
    fn drop(&mut self) {
        // Idempotent: `close` takes the handle, so an explicit close followed
        // by a drop stops the thread once and joins once.
        self.close();
        crate::fdpass::close_fd(self.host_end);
    }
}

fn set_nonblocking(fd: RawFd) -> Result<(), String> {
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const O_NONBLOCK: i32 = 0o4000;
    let fl = unsafe { fcntl(fd, F_GETFL, 0) };
    if fl < 0 || unsafe { fcntl(fd, F_SETFL, fl | O_NONBLOCK) } < 0 {
        return Err(format!("attachment: setting O_NONBLOCK: errno {}", errno()));
    }
    Ok(())
}

/// The pump. Owns `master` and closes it; borrows `stream` and only ever
/// shuts it down.
fn pump(master: RawFd, stream: RawFd, stop: Arc<AtomicBool>, stats: Arc<Stats>) {
    // Two ring-free buffers with an offset, which is enough because each is
    // drained toward exactly one descriptor and refilled only when empty of
    // its written prefix.
    let mut out = Vec::with_capacity(BUF); // master → stream
    let mut out_at = 0usize;
    let mut inb = Vec::with_capacity(BUF); // stream → master
    let mut in_at = 0usize;

    // Three facts, kept apart on purpose. "The terminal hung up" and "the
    // holder went away" are different endings with different consequences,
    // and collapsing them into `done` is how a detach would come to look
    // like a death.
    // **A hangup and a finished direction are two facts, and merging them
    // busy-spins.** `POLLHUP` is level-triggered and is reported whatever the
    // events mask says, so a pump that has seen the hangup but still has
    // undelivered output would be woken by `poll` on every single call — and
    // if the consumer has stopped reading, that is a host thread at 100% of a
    // core until it starts again. Found by writing probe 37 and asking why it
    // could not fail: the answer was that this path had never been reached
    // with a full buffer.
    //
    // So the hangup is *recorded* the moment it is seen, the master stops
    // being polled from that moment, and the direction ends only when the
    // bytes the terminal already produced have been delivered.
    let mut master_hup = false;
    let mut stream_gone = false;
    // Uninitialised deliberately: the loop is the only way out and every exit
    // names its ending, so the compiler proves there is no path that stops
    // pumping without saying why. An initial `Live` would have been a default
    // that a forgotten branch could ship.
    let ending: Ending;

    loop {
        if stop.load(Ordering::SeqCst) {
            ending = Ending::HostClosed;
            break;
        }

        // A direction is finished when its source is gone and its buffer is
        // drained — not when its source is gone. Bytes a dying Carrier
        // already wrote are the last thing anybody watching it will see, and
        // dropping them would make the most interesting output the least
        // reliable.
        let out_pending = out.len() > out_at;
        let in_pending = inb.len() > in_at;

        if master_hup && !out_pending {
            ending = Ending::TerminalHangup;
            break;
        }
        if stream_gone && !in_pending {
            ending = Ending::HolderClosed;
            break;
        }

        let mut m_ev: i16 = 0;
        let mut s_ev: i16 = 0;

        // Read the master only while there is somewhere to put it. This
        // single condition **is** the backpressure: no read means the pts
        // buffer fills, which means the Carrier's own `write` blocks.
        // Once the hangup is recorded the master is never polled again. That
        // is what stops the level-triggered `POLLHUP` from returning
        // instantly forever while `out` waits for a consumer.
        if !master_hup {
            if !out_pending {
                m_ev |= POLLIN;
            } else {
                stats.stalled_out.fetch_add(1, Ordering::Relaxed);
            }
            if in_pending {
                m_ev |= POLLOUT;
            }
        }
        if !stream_gone {
            if !in_pending {
                s_ev |= POLLIN;
            } else {
                stats.stalled_in.fetch_add(1, Ordering::Relaxed);
            }
            if out_pending {
                s_ev |= POLLOUT;
            }
        }

        if m_ev == 0 && s_ev == 0 {
            // Nothing to wait for and nothing to do. Reachable only if both
            // sides are gone, which the checks above already broke on; treat
            // it as a fault rather than spinning.
            ending = Ending::Fault;
            break;
        }

        let mut fds = [
            PollFd { fd: master, events: m_ev, revents: 0 },
            PollFd { fd: stream, events: s_ev, revents: 0 },
        ];

        let n = unsafe { poll(fds.as_mut_ptr(), 2, POLL_MS) };
        if n < 0 {
            if errno() == EINTR {
                continue;
            }
            ending = Ending::Fault;
            break;
        }
        if n == 0 {
            continue; // the wedge floor expiring, not an event
        }

        let mr = fds[0].revents;
        let sr = fds[1].revents;

        if (mr & POLLNVAL) != 0 || (sr & POLLNVAL) != 0 {
            ending = Ending::Fault;
            break;
        }

        // ---------------------------------------------------------- master →
        if (mr & POLLIN) != 0 && !out_pending {
            out.clear();
            out_at = 0;
            out.resize(BUF, 0);
            let got = unsafe { read(master, out.as_mut_ptr(), BUF) };
            if got > 0 {
                out.truncate(got as usize);
                stats.to_stream.fetch_add(got as u64, Ordering::Relaxed);
            } else {
                out.clear();
                // **`EIO`, not zero.** Linux reports a hung-up master by
                // failing the read, and a loop that waited for a 0-length
                // read here would wait forever — the same fact `verify`'s
                // hangup check is written around.
                let e = errno();
                if got == 0 || e == EIO {
                    master_hup = true;
                } else if e != EAGAIN && e != EINTR {
                    ending = Ending::Fault;
                    break;
                }
            }
        } else if (mr & (POLLHUP | POLLERR)) != 0 {
            // Recorded whether or not `out` is drained. The break above is
            // what waits for the drain; this only stops the polling.
            master_hup = true;
        }

        if (sr & POLLOUT) != 0 && out.len() > out_at {
            let put = unsafe { write(stream, out[out_at..].as_ptr(), out.len() - out_at) };
            if put > 0 {
                out_at += put as usize;
            } else {
                let e = errno();
                if e != EAGAIN && e != EINTR {
                    // The holder is gone mid-write. That is a detach, not a
                    // death: nothing here touches the Carrier.
                    stream_gone = true;
                }
            }
        }

        // ---------------------------------------------------------- → master
        if (sr & POLLIN) != 0 && !in_pending {
            inb.clear();
            in_at = 0;
            inb.resize(BUF, 0);
            let got = unsafe { read(stream, inb.as_mut_ptr(), BUF) };
            if got > 0 {
                inb.truncate(got as usize);
                stats.to_master.fetch_add(got as u64, Ordering::Relaxed);
            } else {
                inb.clear();
                let e = errno();
                if got == 0 {
                    stream_gone = true;
                } else if e != EAGAIN && e != EINTR {
                    stream_gone = true;
                }
            }
        } else if (sr & (POLLHUP | POLLERR)) != 0 && !in_pending {
            stream_gone = true;
        }

        if (mr & POLLOUT) != 0 && inb.len() > in_at {
            let put = unsafe { write(master, inb[in_at..].as_ptr(), inb.len() - in_at) };
            if put > 0 {
                in_at += put as usize;
            } else {
                let e = errno();
                if e != EAGAIN && e != EINTR {
                    master_hup = true;
                }
            }
        }
    }

    // **Tell the holder, then let go of the terminal.**
    //
    // `SHUT_WR` and not `close`: the far end must see EOF — that is the
    // whole of "the terminal disappeared" as the holder experiences it — and
    // the number belongs to `Attachment`, which closes it when it drops.
    unsafe { shutdown(stream, SHUT_WR) };
    unsafe { close(master) };
    stats.ending.store(ending as u64, Ordering::SeqCst);
}
