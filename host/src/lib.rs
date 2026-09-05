//! The [&] Super host.
//!
//! It owns the human capability and nothing else owns any:
//!
//! ```text
//!   super-host
//!     ├─ socketpair(SEQPACKET)   → keeps A, spawns ampd with B as fd 3
//!     │                            ampd adopts fd 3: THE BRIDGE
//!     ├─ bind the control channel over the bridge  ← THIS is the person
//!     └─ per engine:
//!          socketpair(STREAM)    → one end to ampd over the bridge,
//!                                  labelled; the other inherited by the
//!                                  engine at spawn
//! ```
//!
//! # Possession is the capability
//!
//! There is no socket file and no path. A channel is a descriptor, and a
//! descriptor cannot be guessed, enumerated, or opened by name — it can
//! only be given. The first version of this host asked the runtime for a
//! *path* and connected to it, which meant the identity law was really
//! "first connector wins" against every other process running as the same
//! user. `fdpass.rs` is the correction, written out by hand because the
//! whole trust model rests on those four syscalls.
//!
//! The host is trusted for exactly one thing — deciding which process gets
//! which descriptor — instead of being trusted on every message. It cannot
//! forge a message on a channel it did not create, and nothing else can
//! obtain one at all.

pub mod effect;
pub mod sha256;
pub mod fdpass;
pub mod confine;
pub mod pty;
pub mod attach;
pub mod carrier;

use std::collections::HashMap;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::RawFd;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

const MAX_FRAME: usize = 256 * 1024;

// ============================================================== framing
//
// Four-byte big-endian length, then the body. The length is checked before
// the body is read — on both sides — because a length-prefixed protocol
// that allocates first has made the attack cheaper rather than more
// expensive.
fn read_exact(fd: RawFd, n: usize) -> io::Result<Vec<u8>> {
    extern "C" {
        fn read(fd: i32, buf: *mut u8, count: usize) -> isize;
    }

    let mut buf = vec![0u8; n];
    let mut got = 0;
    while got < n {
        let r = unsafe { read(fd, buf.as_mut_ptr().add(got), n - got) };
        if r == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "channel closed"));
        }
        if r < 0 {
            return Err(io::Error::last_os_error());
        }
        got += r as usize;
    }
    Ok(buf)
}

fn write_all(fd: RawFd, buf: &[u8]) -> io::Result<()> {
    extern "C" {
        fn write(fd: i32, buf: *const u8, count: usize) -> isize;
    }

    let mut sent = 0;
    while sent < buf.len() {
        let r = unsafe { write(fd, buf.as_ptr().add(sent), buf.len() - sent) };
        if r <= 0 {
            return Err(io::Error::last_os_error());
        }
        sent += r as usize;
    }
    Ok(())
}

/// 16 bytes of kernel randomness, hex. No crate, and not a counter: an
/// epoch that can be predicted is an epoch a replaced endpoint's
/// observation can be stamped with.
pub(crate) fn new_epoch() -> String {
    use std::io::Read;
    let mut b = [0u8; 16];
    match std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut b)) {
        Ok(()) => b.iter().map(|x| format!("{x:02x}")).collect(),
        // Refuse rather than substitute something guessable. The caller
        // turns this into a failed bind, which is a host that does not
        // serve effects — loud, and not a channel with a weak identity.
        Err(e) => panic!("could not read /dev/urandom for a channel epoch: {e}"),
    }
}

/// Serve `worktree-effect-request@1` on a possessed descriptor until it
/// closes.
///
/// **One effect semantic implementation, two transports.** Every decision
/// about what a request means lives in `effect::perform`, which the
/// `effect` subcommand also calls. A second interpreter here is exactly
/// how the reference path and the production path would come to disagree
/// while both looked correct, and the parity check between them would
/// then be comparing a thing to itself.
///
/// **Correlation is echoed, never consulted.** `request_id` and
/// `channel_epoch` are copied from the request onto the observation and
/// are not passed to `perform`. They say which request this is; letting
/// the mechanism read them would be letting it decide which request it is
/// answering.
///
/// **No authorization happens here and none can.** The request carries no
/// actor, Worker, Lane, grant or capability, so there is nothing to form
/// an opinion about. A malformed request gets a typed refusal — which is
/// an observation of a failed effect, not a second gate.
/// Serve Carrier lifecycle requests on a possessed channel.
///
/// **Holds no authority and decides nothing.** It starts what it is told to
/// start and reports what it observed; whether that process joins the World is
/// re-derived by `Ampd.Carrier.commit_start/2` inside the total order, against
/// a world that may have moved while this was running. A host that could
/// promote its own child would be a host deciding product authority.
///
/// The `carrier_ref` and `carrier_epoch` are **echoed, never consulted** —
/// the same rule `serve_effects` follows for `request_id`. Letting the machine
/// read them would be letting it decide which start it is answering.
pub fn serve_carrier(fd: RawFd, workdir: PathBuf) {
    use std::collections::HashMap;
    let mut live: HashMap<String, carrier::Carrier> = HashMap::new();

    // **Which runtime incarnation this physical set belongs to.**
    //
    // D.1.3b·2d. The runtime's `Ampd.Peer` can die and be restarted by its
    // supervisor while this process, this channel and every Carrier in the
    // map above go on existing — so the map can outlive the semantic
    // membership that admitted every entry in it. `Ampd.Carrier.Machine.Gate`
    // is what notices, and this is the second line of defence for the case
    // where the Gate restarts at the same moment and has nothing to compare.
    //
    // Not authority. This never decides whether a Carrier *may* run; it
    // refuses to let a physical set survive across a discontinuity in the
    // runtime that owns it.
    let mut set_epoch: Option<String> = None;

    // A typed refusal on the schema the caller was expecting. An attach that
    // failed must not answer with a start observation: the runtime matches on
    // the schema it asked for and would report "unknown observation schema"
    // for what is really a refusal it could have read.
    fn refused(schema: &str, why: &str) -> Value {
        json!({"schema": schema, "refused": why})
    }

    loop {
        let req = match read_frame(fd) { Ok(v) => v, Err(_) => break };
        let carrier_ref = req["carrier_ref"].as_str().unwrap_or("").to_string();

        // The descriptor this reply carries, if any. Declared out here so the
        // single write path below is the only place that can send or close
        // it — an attachment endpoint returned down one arm and closed down
        // another is the fourth-exit shape `Ampd.Bridge` was rebuilt to
        // remove.
        let mut pass_fd: Option<RawFd> = None;

        let mut obs = match req["op"].as_str() {
            // **Absence is the whole request.** No actor, no Locus, no
            // Worker, no grant — there is nothing here to authorize, because
            // the operation only ever subtracts. That is also why the runtime
            // may retry it: see the note on `drain` in
            // `Ampd.Carrier.Machine`.
            Some("drain") => {
                let asked = live.len();
                for (_, mut c) in live.drain() {
                    // `terminate` is SIGTERM, awaited, then SIGKILL, and it
                    // returns only once the child has been reaped. Replying
                    // before that would make this "the stop was requested",
                    // which is the distinction three rounds of this lane have
                    // been about.
                    c.terminate(3_000);
                }
                set_epoch = None;

                json!({
                    "schema": "carrier-runtime-drain-observation@1",
                    "reaped": asked,
                    "remaining": live.len(),
                })
            }

            Some("start") => {
                let want = req["runtime_epoch"].as_str().unwrap_or("").to_string();

                match &set_epoch {
                    // A start under a different runtime incarnation while
                    // this one still holds processes. The runtime should have
                    // drained first; refusing is what makes that not merely a
                    // convention.
                    Some(cur) if *cur != want && !live.is_empty() => json!({
                        "schema": "carrier-start-observation@1",
                        "refused": format!(
                            "the physical carrier set belongs to runtime incarnation {cur} and \
                             holds {} carrier(s); drain it before starting under {want}",
                            live.len()
                        ),
                    }),

                    _ => {
                        set_epoch = Some(want);
                        match start_one(&workdir, &carrier_ref, &req) {
                            Ok((c, o)) => { live.insert(carrier_ref.clone(), c); o }
                            Err(e) => {
                                // The host says why on its own stream. The
                                // runtime's refusal is disclosure-graded and
                                // an agent never sees this text; an operator
                                // reading the host's log should.
                                eprintln!("  carrier start refused: {e}");
                                json!({
                                    "schema": "carrier-start-observation@1",
                                    "refused": e,
                                })
                            }
                        }
                    }
                }
            }

            Some("stop") => {
                // Absence is success. A reap that insisted on having
                // something to kill would fail exactly in the INDETERMINATE
                // case where it matters most and is understood least.
                if let Some(mut c) = live.remove(&carrier_ref) { c.terminate(3_000); }
                json!({"schema": "carrier-stop-observation@1", "stopped": true})
            }

            // ---------------------------------------------- D.1.3c·2
            //
            // **These three consult `carrier_epoch`, and nothing above them
            // does.** That asymmetry is deliberate rather than an
            // inconsistency. For `start` and `stop`, reading the correlation
            // fields would let the machine decide which request it is
            // answering — the rule `serve_effects` follows. A terminal
            // operation is the other case: it is addressed *at* a resource
            // that can be replaced underneath it, and this host is the only
            // thing that knows which terminal is the current one. The epoch
            // triple is not correlation here; it is the address.
            Some("pty-attach") => {
                let want_ce = req["carrier_epoch"].as_str().unwrap_or("");
                match live.get_mut(&carrier_ref) {
                    None => refused("carrier-pty-attach-observation@1", "no such carrier"),
                    Some(c) if c.incarnation != want_ce => refused(
                        "carrier-pty-attach-observation@1",
                        "the carrier epoch does not name the carrier that holds this terminal",
                    ),
                    // **The cardinality rule is NOT here, deliberately.**
                    //
                    // It was, and it was a second implementation of a rule
                    // `Carrier::attach` already enforces — which the sabotage
                    // battery caught the only way that is catchable: probe 40
                    // disabled this guard and scored NOT A FALSIFIER, because
                    // the refusal simply happened one layer down and the check
                    // stayed green. Two guards agreeing is indistinguishable
                    // from one guard working until exactly one of them is
                    // wrong.
                    //
                    // So the invariant lives with the mutation that can break
                    // it, the same reason `Ampd.Worker.occupancy/2` is the one
                    // place that knows what occupying a Locus means. This arm
                    // reports whatever `attach` decided, under the schema the
                    // caller asked for.
                    Some(c) => match c.attach() {
                        Err(e) => refused("carrier-pty-attach-observation@1", &e),
                        Ok(far) => {
                            let a = c.attachment().unwrap();
                            pass_fd = Some(far);
                            json!({
                                "schema": "carrier-pty-attach-observation@1",
                                "attached": true,
                                "attachment_ref": a.attachment_ref,
                                "attachment_epoch": a.attachment_epoch,
                                "pty_epoch": a.pty_epoch,
                            })
                        }
                    },
                }
            }

            // **Detaching is not killing.** The holder letting go of a
            // terminal says nothing about whether the process behind it
            // should continue, and a runtime that conflated the two would
            // have built "close the window, lose the work".
            Some("pty-detach") => match live.get_mut(&carrier_ref) {
                None => refused("carrier-pty-detach-observation@1", "no such carrier"),
                Some(c) => match c.attachment_address(&req) {
                    Err(e) => refused("carrier-pty-detach-observation@1", &e),
                    Ok(()) => {
                        let ending = c.detach();
                        json!({
                            "schema": "carrier-pty-detach-observation@1",
                            "detached": true,
                            "ending": ending,
                            "carrier_still_running": c.same_process(),
                        })
                    }
                },
            },

            // Resize is a **typed control operation on this serialized
            // channel**, not a message inside the byte stream. It is bounded,
            // correlated and rare; terminal content is none of those. Mixing
            // them would mean either parsing the data plane for commands or
            // giving the data plane an authority it must not have.
            Some("pty-resize") => match live.get_mut(&carrier_ref) {
                None => refused("carrier-pty-resize-observation@1", "no such carrier"),
                // **Attachment-scoped, deliberately.** Resize could have
                // been addressed at the terminal alone — the host performs it
                // either way and `terminal_resize_is_the_hosts` is unchanged.
                // Scoping it to the attachment says something narrower and
                // truer for this slice: the thing entitled to ask is the
                // holder of the current attachment, so a Carrier nobody is
                // watching cannot be resized by a request that merely
                // remembers its terminal.
                Some(c) => match c.attachment_address(&req) {
                    Err(e) => refused("carrier-pty-resize-observation@1", &e),
                    Ok(()) => {
                        let rows = req["rows"].as_u64().unwrap_or(0);
                        let cols = req["cols"].as_u64().unwrap_or(0);
                        if rows == 0 || cols == 0 || rows > u16::MAX as u64 || cols > u16::MAX as u64
                        {
                            refused(
                                "carrier-pty-resize-observation@1",
                                "rows and cols must each be 1..65535",
                            )
                        } else {
                            let ws = pty::WinSize {
                                rows: rows as u16,
                                cols: cols as u16,
                                xpixel: 0,
                                ypixel: 0,
                            };
                            match c.pty().map(|p| p.set_winsize(ws)) {
                                Some(Ok(())) => json!({
                                    "schema": "carrier-pty-resize-observation@1",
                                    "resized": true, "rows": rows, "cols": cols,
                                }),
                                Some(Err(e)) => {
                                    refused("carrier-pty-resize-observation@1", &e)
                                }
                                None => refused(
                                    "carrier-pty-resize-observation@1",
                                    "that carrier has no terminal",
                                ),
                            }
                        }
                    }
                },
            },

            _ => json!({"schema": "carrier-start-observation@1", "refused": "unknown carrier op"}),
        };

        obs["request_id"] = req["request_id"].clone();
        obs["channel_epoch"] = req["channel_epoch"].clone();
        obs["carrier_ref"] = req["carrier_ref"].clone();
        obs["carrier_epoch"] = req["carrier_epoch"].clone();

        let sent = write_frame_with_fd(fd, &obs, pass_fd);
        // **Closed on every exit, including the one where the send failed.**
        // The far end is the runtime's copy from the moment `sendmsg`
        // succeeds; this host keeping its own would be a second holder of a
        // stream that is supposed to have exactly one.
        if let Some(p) = pass_fd { fdpass::close_fd(p); }
        if sent.is_err() { break }
    }

    // The channel is gone, so every Carrier it admitted has lost the
    // authority incarnation that owns it. Terminate rather than orphan:
    // "losing the runtime incarnation terminates the Carrier" is a rule the
    // machine side has to keep too, or the runtime forgets a process that is
    // still running.
    for (_, mut c) in live { c.terminate(3_000); }
}

/// Where Carrier working directories live.
///
/// Under the world directory, so they are removed with the world and never
/// accumulate in a developer's tree. Each Carrier gets its own subdirectory
/// and that subdirectory is the *only* thing its Landlock policy grants
/// write access to.
pub fn world_dir_for_carriers() -> PathBuf {
    let base = std::env::var_os("AMPD_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let d = base.join("carriers");
    let _ = std::fs::create_dir_all(&d);
    d
}

extern "C" {
    fn getuid() -> u32;
}

/// Content identity of the Carrier payload **as installed**.
///
/// Read from the pathname, and that is correct *here and only here*: this is
/// asked at Carrier-channel establishment, when no Carrier is running and the
/// question is which implementation is installed to be launched. It is the
/// admission basis, not an attestation about a process.
fn installed_payload_digest(p: &Path) -> String {
    match std::fs::read(p) {
        Ok(b) => crate::sha256::digest(&b),
        // Unreadable is not "no digest" — a missing value must not be able to
        // satisfy a comparison, so it is a value nothing else can equal.
        Err(e) => format!("unreadable:{e}"),
    }
}

/// Content identity of the executable **that is actually running**.
///
/// # Why not the pathname
///
/// The previous version digested `payload` *after* `spawn` had already
/// `execve`d it, which is a TOCTOU with no attacker required:
///
/// ```text
/// exec(A)  →  something replaces the pathname  →  read(path) → digest(B)
/// ```
///
/// and the host would attest B while the live process is A. An ordinary
/// package update or a concurrent build is enough. The host is trusted; being
/// trusted is not the same as being asked the right question.
///
/// # Why `/proc/<pid>/exe`
///
/// It is a magic link to the *inode of the executed image*, not a path to be
/// re-resolved. Opening it reaches the bytes that are running even after the
/// directory entry has been replaced or unlinked.
///
/// **Measured on this kernel**, with a static binary A installed, running, and
/// then atomically renamed over by B:
///
/// ```text
///                      readlink /proc/<pid>/exe    bytes through it
/// before the rename    <path>                      digest(A)
/// after the rename     <path> (deleted)            digest(A)     ← still A
/// the pathname now                                 digest(B)
/// ```
///
/// So the **link target is the wrong evidence** — it goes stale and says
/// `(deleted)` — and the **bytes read through the link are the right
/// evidence**. This reads the bytes and never the target.
fn running_image_digest(pid: u32) -> String {
    match std::fs::read(format!("/proc/{pid}/exe")) {
        Ok(b) => crate::sha256::digest(&b),
        Err(e) => format!("unreadable:{e}"),
    }
}

/// `carrier-execution-basis@1` — what a Carrier implementation *is*.
///
/// Two callers, deliberately measuring two different things through one
/// constructor so the shapes cannot drift apart:
///
/// ```text
/// carrier_channel()   payload = the installed pathname   → the admission basis
/// start_one()         payload = /proc/<pid>/exe          → what actually ran
/// ```
///
/// `Ampd.Carrier.commit_start/2` compares them. Every field is one whose
/// discontinuity is exercised by a falsifier; nothing decorative is bound,
/// because a field nobody can move is a field that only makes the comparison
/// look stronger than it is.
fn execution_basis(payload_digest: String) -> Value {
    json!({
        "schema": "carrier-execution-basis@1",
        "payload_digest": payload_digest,
        "carrier_protocol": "carrier-lifecycle",
        "carrier_protocol_version": 1,
    })
}

fn start_one(
    root: &Path,
    carrier_ref: &str,
    req: &Value,
) -> Result<(carrier::Carrier, Value), String> {
    let payload = carrier::payload_path().ok_or("no carrier payload is installed")?;
    let dir = root.join(carrier_ref);
    std::fs::create_dir_all(&dir).map_err(|e| format!("carrier workdir: {e}"))?;
    let log = dir.join("carrier.log");

    // The incarnation the Carrier must echo is the epoch the *runtime* minted
    // and the host was handed. The host does not choose it: a machine that
    // named the incarnation it was proving would be answering its own
    // question, which is the reason D.1.3a mints the channel epoch on the
    // opposite side from the one that checks it.
    let epoch = req["carrier_epoch"].as_str().unwrap_or("").to_string();

    // **D.1.3c·1 — a served Carrier possesses a terminal.**
    //
    // Allocated here rather than requested, and that is the authority
    // boundary: no field of `carrier-start-request@1` selects, names or
    // configures this. The runtime asks for a Carrier; the host decides that
    // a Carrier is a confined process with a controlling terminal it did not
    // choose. Nothing an agent can say reaches this line.
    //
    // The `Pty` is moved into the `Carrier`, so its lifetime is the
    // Carrier's — every path that already disposes of a Carrier (a stop, a
    // drain, the Peer-incarnation fence, `Drop`) now disposes of the
    // terminal too, with no path having to remember. See `Carrier::pty`.
    //
    // Failure is a refusal and not a fallback. On a kernel without
    // `TIOCGPTPEER` this is `pty-peer-descriptor-unavailable` and no Carrier
    // starts — resolving the slave by pathname instead would trade the
    // slice's entire claim for compatibility.
    // **Phase A · the one read capability, and where it comes from.**
    //
    // `source_basis` is present only when the runtime admitted a job that
    // named one. It carries the exact commit the basis binds and the host
    // path the runtime resolved from `source_basis_ref` — and the path is
    // NOT the authority. The authority is the proof below: this directory
    // really is that commit, and it is clean. A path that fails the proof
    // grants nothing and refuses the start, because a Carrier confined over
    // a directory that is not the snapshot the job named would be reading
    // something nobody authorized.
    //
    // The proof is taken here rather than by `ampd`, immediately before the
    // ruleset is built and installed, so the window between "verified" and
    // "granted" is as short as this code can make it.
    let policy = match req["source_basis"].as_object() {
        None => None,
        Some(sb) => {
            let commit = sb
                .get("commit_oid")
                .and_then(|v| v.as_str())
                .ok_or("source basis carries no commit_oid")?;
            let path = sb
                .get("materialization")
                .and_then(|v| v.as_str())
                .ok_or("source basis carries no materialization")?;

            crate::effect::verify_source_basis(path, commit)?;

            let canonical = std::fs::canonicalize(path)
                .map_err(|e| format!("source-basis-materialization-unresolvable: {e}"))?;

            Some(confine::Policy::minimal_over(
                &dir.to_string_lossy(),
                &payload.to_string_lossy(),
                &canonical.to_string_lossy(),
            ))
        }
    };

    let term = crate::pty::Pty::open()?;
    let mut c = carrier::spawn_on_pty(&payload, &dir, &log, &epoch, policy, term)?;
    if let Err(e) = c.handshake(5_000) {
        // A Carrier that cannot prove it is this incarnation is not left
        // running. The runtime will see the refusal, but the process is this
        // side's to dispose of.
        c.terminate(3_000);
        return Err(e);
    }

    let o = c.observe();

    // **Three evidence classes, never merged.**
    //
    //   observed    read by this host out of the child's own /proc
    //   attested    this host installed it and says so — Landlock and
    //               PR_SET_PDEATHSIG are not exposed per-process anywhere on
    //               this kernel, so there is no other in-band evidence
    //   configured  what the policy asked for, kept so the runtime can see
    //               the gap between request and result
    //
    // The runtime may trust the host — it is inside the TCB — but it must not
    // be able to claim it *observed* a field that was attested.
    //
    // **This object was missing entirely and the omission was invisible.**
    // `Ampd.Carrier.Floor` requires eight attested rows; the Elixir harness
    // fabricated them, so every falsifier passed while the production path
    // could not have committed a single Carrier. The two halves were proved
    // separately and the join between them was proved by nobody — which is
    // the D.1.3a "no deployed Super could open a Lane" shape exactly.
    let cfg = c.configured().clone();
    let obs = json!({
        "schema": "carrier-start-observation@1",
        "host_process_ref": format!("hp_{}_{}", c.pid, c.starttime.unwrap_or(0)),
        "observed": o.to_json(),
        "attested": carrier_attestation(&c, &dir),
        "configured": cfg,
    });

    Ok((c, obs))
}

/// The `carrier-confinement-attested@1` object, for a live Carrier.
///
/// **Extracted so the battery measures this and not a reimplementation of
/// it.** The executable-TOCTOU falsifier used to call `running_image_digest`
/// directly, which meant it measured the *function* while its name claimed it
/// measured "what the host attests" — so sabotaging the attestation's digest
/// source left the check green. `tools/sabotage-host.sh` reported it as
/// **NOT A FALSIFIER**, which is exactly what that battery is for.
///
/// One function, both callers. A check that cannot be moved by breaking the
/// production path is not a check on the production path.
/// What the host can say about a Carrier's terminal.
///
/// Deliberately *not* the pts index or a pathname. Nothing downstream is
/// given a name it could try to open; what crosses the wire is whether the
/// relationships hold, which is the only part a floor can check and the only
/// part that is not an invitation.
fn terminal_attestation(c: &carrier::Carrier) -> Value {
    let Some(p) = c.pty() else { return Value::Null };
    let t = crate::pty::TermProps::read(c.pid);
    json!({
        "schema": "carrier-terminal-attested@1",
        "session_leader": t.is_session_leader(c.pid),
        "controlling_terminal": t.has_controlling_terminal(),
        "foreground": t.is_foreground(),
        "is_this_host_master": p.session().is_some() && p.session() == t.session,
        // **The join, added at c·1a after review found it missing.**
        //
        // `is_this_host_master` says the Carrier's *controlling terminal* is
        // the one this host holds. It says nothing about what is on 0/1/2 —
        // and a process may have ctty A while its standard descriptors refer
        // to terminal B, so the floor could be satisfied by a Carrier using
        // a terminal the host does not possess. `super-host verify` already
        // proved this correspondence with a decoy master; it simply was not
        // part of what the World requires before admitting *this* process.
        "stdio_is_this_host_slave": crate::pty::stdio_is_slave(c.pid, p.slave_rdev()),
        "master_held_by": "super-host",
        "resize_authority": "super-host",
    })
}

pub fn carrier_attestation(c: &carrier::Carrier, dir: &Path) -> Value {
    let cfg = c.configured().clone();

    json!({
        "schema": "carrier-confinement-attested@1",
        "landlock_abi": cfg["landlock_abi"].clone(),
        "landlock_handled_fs": cfg["handled_access_fs"].clone(),
        "landlock_handled_net": cfg["handled_access_net"].clone(),
        "landlock_scoped": cfg["scoped"].clone(),
        "landlock_grants": cfg["grants"].clone(),
        "seccomp_deny_errno": cfg["seccomp_deny_errno"].clone(),
        "pdeathsig": "SIGKILL",
        "network": "none",
        "attestor": "super-host",
        // **D.1.3c·1 — the terminal relationship, attested and observed
        // together, because half of it can only be one and half only the
        // other.**
        //
        // `session_leader`, `controlling_terminal` and `foreground` are read
        // out of the child's own `/proc/<pid>/stat` — genuine observations.
        // `is_this_host_master` is the one that matters and it is a
        // *correspondence*: `TIOCGSID` asked of the descriptor this host
        // holds, compared against the session the child reports. It answers
        // ENOTTY until a slave-side session leader has claimed the terminal,
        // so it cannot be satisfied by any terminal other than this one.
        //
        // `null` when the Carrier has no terminal. The floor distinguishes
        // absent from false — a Carrier that was never given a terminal and
        // one whose terminal did not take are not the same fact.
        "terminal": terminal_attestation(c),
        // **The identity of the image that is running, measured through the
        // process rather than through the pathname it was launched from.**
        // This was `fixture_digest(&fixture)` — a read of the installation
        // path *after* `execve` had already happened, so a replacement
        // landing in that window would have been attested as the running
        // Carrier. See `running_image_digest`.
        //
        // Emitted as a basis object rather than a bare digest because the
        // runtime does not compare digests, it compares *bases*: the ticket
        // bound one at admission and this is the one to hold it against.
        "execution_basis": execution_basis(running_image_digest(c.pid)),
        "expected_uid": unsafe { getuid() },
        "control_inode": c.control_inode(),
        // **Canonicalized before digesting.** `/proc/<pid>/cwd` is a resolved
        // path; `dir` may contain a symlink component, and `carrier::spawn`
        // canonicalizes it before `current_dir` anyway. Digesting the
        // unresolved form compared two spellings of the same directory and
        // refused every real start on `cwd_is_the_allocated_workdir` —
        // sixteen of seventeen floor rows passing, which is the shape of a
        // correspondence bug rather than a policy one.
        "workdir_identity": crate::sha256::digest(
            dir.canonicalize().unwrap_or_else(|_| dir.to_path_buf()).to_string_lossy().as_bytes()
        ),
    })
}

pub fn serve_effects(fd: RawFd) {
    loop {
        let req = match read_frame(fd) {
            Ok(v) => v,
            // EOF or a framing error ends the loop. The runtime treats a
            // channel that stopped answering as indeterminate; it is not
            // this side's job to decide that for it.
            Err(_) => return,
        };

        let mut obs = effect::perform(&req);
        obs["request_id"] = req["request_id"].clone();
        obs["channel_epoch"] = req["channel_epoch"].clone();

        if write_frame(fd, &obs).is_err() {
            return;
        }
    }
}


/// The inode behind a `/proc/<pid>/fd/<n>` target, if it is a socket.
///
/// `socket:[12345]` → `Some(12345)`. Anything else → `None`.
pub fn socket_inode(target: &str) -> Option<u64> {
    let rest = target.strip_prefix("socket:[")?;
    rest.strip_suffix(']')?.parse().ok()
}

/// The inode of a descriptor this process holds.
///
/// **This is what makes a channel identifiable after it has been given
/// away.** `SCM_RIGHTS` and `dup2` both produce a descriptor sharing the
/// *same open file description* as the one sent, so the inode the host
/// reads here is the inode the runtime will show for its adopted copy —
/// even though the fd numbers differ and the host has since closed its own.
/// `fd_inode` for the Carrier module, which needs the same
/// read-before-you-close discipline the bridge uses and must not grow a
/// second copy of it.
pub fn fd_inode_pub(fd: RawFd) -> Option<u64> {
    fd_inode(fd)
}

fn fd_inode(fd: RawFd) -> Option<u64> {
    std::fs::read_link(format!("/proc/self/fd/{fd}"))
        .ok()
        .and_then(|p| socket_inode(&p.to_string_lossy()))
}

/// `pub(crate)` so `verify` can drive a Carrier channel as the runtime end
/// would. The battery needs to issue a real drain against a real
/// `serve_carrier` holding real processes; nothing outside the BEAM can make
/// `Ampd.Peer` die, so the physical half of that proof is measured here.
pub(crate) fn read_frame(fd: RawFd) -> io::Result<Value> {
    let len = read_exact(fd, 4)?;
    let n = u32::from_be_bytes([len[0], len[1], len[2], len[3]]) as usize;
    if n > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("runtime announced a {n} byte frame"),
        ));
    }
    let body = read_exact(fd, n)?;
    serde_json::from_slice(&body).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

pub(crate) fn write_frame(fd: RawFd, v: &Value) -> io::Result<()> {
    let body = serde_json::to_vec(v)?;
    if body.len() > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("frame of {} bytes exceeds the {MAX_FRAME} byte limit", body.len()),
        ));
    }
    write_all(fd, &(body.len() as u32).to_be_bytes())?;
    write_all(fd, &body)
}

/// One frame, and a descriptor beside it, in **one** `sendmsg`.
///
/// D.1.3c·2. A terminal attachment is possessed or it is nothing, so the
/// answer to "you may attach" has to *be* the endpoint rather than name one.
/// The bridge is where this host normally hands descriptors over, and it is
/// deliberately not used here: `serve_carrier` is spawned on a bare
/// socketpair by the acceptance battery with no bridge in existence at all,
/// and a mechanism the battery cannot drive is a mechanism whose production
/// path nothing measures.
///
/// **The length prefix travels inside the same `sendmsg` as the descriptor,
/// and that is load-bearing.** On a stream socket the kernel associates
/// ancillary data with the *first byte* of the message that carried it, so a
/// reader that took the four length bytes with a plain `read` would be told
/// nothing and the descriptor would be discarded with `MSG_CTRUNC`. Whoever
/// asks for an attachment must read the answer with `recvmsg`.
///
/// A frame with no descriptor is written the ordinary way, so nothing else on
/// this channel changes shape.
///
/// # The contract the runtime's receiver owes this sender
///
/// **Frozen at D.1.3c·2a·1, before c·2b is written**, so that the receiving
/// half is designed against a stated sender rather than against whatever the
/// sender happened to do. A specialized `request_with_fd` must:
///
/// ```text
///   recvmsg for the FIRST response bytes    rights ride the first byte
///   capture SCM_RIGHTS from that call       or they are already gone
///   tolerate a partial frame afterwards     SOCK_STREAM has no message
///                                           boundaries; one sendmsg is not
///                                           one recvmsg
///   MSG_CMSG_CLOEXEC on receive             the mirror of this host's
///                                           O_CLOEXEC on everything it opens
///   REJECT MSG_CTRUNC                       a truncated control message means
///                                           a descriptor was destroyed in
///                                           transit; reading past it looks
///                                           for the fault in the wrong half
///   exactly ONE fd on a successful attach
///   exactly ZERO fds on a refusal           this host sends none — measured
///   close every excess or unexpected fd     "one sink, no fourth exit"
/// ```
///
/// And it must **not** teach the shared `recv_frame` to carry rights. That
/// function is scarred: a hard-coded observation schema in it once made every
/// production Carrier start INDETERMINATE, and nothing in 53 harness
/// falsifiers could see it. A second reader for one new response shape is the
/// smaller change, and the Gate's single-submitter guarantee is what makes it
/// safe.
pub(crate) fn write_frame_with_fd(fd: RawFd, v: &Value, pass: Option<RawFd>) -> io::Result<()> {
    let Some(p) = pass else { return write_frame(fd, v) };

    let body = serde_json::to_vec(v)?;
    if body.len() > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("frame of {} bytes exceeds the {MAX_FRAME} byte limit", body.len()),
        ));
    }
    let mut msg = Vec::with_capacity(4 + body.len());
    msg.extend_from_slice(&(body.len() as u32).to_be_bytes());
    msg.extend_from_slice(&body);
    fdpass::send_with_fd(fd, &msg, p)
}

// ========================================================= demultiplexer
//
//                    ONE SOCKET
//                        │
//                   reader thread
//                        │
//             ┌──────────┴──────────┐
//         replies                projections
//     by client_request_id      latest snapshot
//             │                     │
//        oneshot waiter        revision-gated wait
//
// **Once a channel subscribes, the reply to a command is not the next
// frame on the socket.** The first version of this host wrote a command
// and read one frame; a projection pushed in between was read as the
// answer, so `operator_projection` returned a map with a `projection` key
// where `grants` was expected, the id list came out empty, and a bulk
// revocation "passed" its check by confirming nothing. A check that passes
// for the wrong reason is worse than one that fails.
//
// Correlation is not left to each caller. One reader owns the socket and
// routes: replies to the waiter that asked, projections into a slot.
//
// **Projections supersede rather than queue.** A newer snapshot makes an
// older one worthless — it is the whole world, not an event — so a FIFO of
// 256 would drop the *newest* under load, which is precisely backwards.
struct Shared {
    waiters: Mutex<HashMap<String, SyncSender<Value>>>,
    latest: Mutex<Option<Value>>,
    // `hello@1` is neither a reply nor a projection: it is unprompted, it
    // arrives exactly once, and it is what tells a client what it is
    // before it has asked anything. A third slot, rather than pretending
    // it is one of the other two.
    hello: Mutex<Option<Value>>,
    // Replies that correlate to no waiter. A frame-level refusal carries
    // no `client_request_id` — the frame it refused was never decoded — so
    // when nothing is in flight it would otherwise be dropped silently,
    // and "the runtime said nothing" and "the runtime refused" are not the
    // same fact.
    unmatched: Mutex<Vec<Value>>,
    cv: Condvar,
    closed: AtomicBool,
}

impl Shared {
    fn new() -> Arc<Shared> {
        Arc::new(Shared {
            waiters: Mutex::new(HashMap::new()),
            latest: Mutex::new(None),
            hello: Mutex::new(None),
            unmatched: Mutex::new(Vec::new()),
            cv: Condvar::new(),
            closed: AtomicBool::new(false),
        })
    }
}

pub struct Chan {
    fd: RawFd,
    shared: Arc<Shared>,
    seq: AtomicU64,
    /// **One writer.** `write_frame` is a 4-byte header followed by a
    /// body, and two threads doing that concurrently on one stream can
    /// produce `header A · header B · body A · body B` — a corrupt stream
    /// the runtime cannot resynchronise from.
    ///
    /// The reader was already single; this makes the pair explicit:
    /// **one reader, one writer, many logical callers.** `super-host
    /// verify` is nearly sequential and would never have shown this; a
    /// WebView issuing concurrent commands would have shown it immediately
    /// and intermittently, which is the worst way to find it.
    writer: Mutex<()>,
}

impl Chan {
    pub fn adopt(fd: RawFd) -> Chan {
        let shared = Shared::new();
        let s = Arc::clone(&shared);

        std::thread::spawn(move || loop {
            match read_frame(fd) {
                Ok(f) => {
                    let schema = f["schema"].as_str().unwrap_or("");

                    if schema == "hello@1" {
                        *s.hello.lock().unwrap() = Some(f);
                        s.cv.notify_all();
                        continue;
                    }

                    if schema == "projection-snapshot@1" {
                        let mut slot = s.latest.lock().unwrap();
                        *slot = Some(f);
                        s.cv.notify_all();
                        continue;
                    }

                    if schema == "reply@1" {
                        let id = f["client_request_id"].as_str().map(String::from);
                        let mut w = s.waiters.lock().unwrap();

                        // A frame-level refusal cannot echo an id: the
                        // frame it refused was never decoded. With one
                        // command in flight per waiter, it belongs to
                        // whoever is waiting.
                        let key = match id {
                            Some(k) if w.contains_key(&k) => Some(k),
                            _ if w.len() == 1 => w.keys().next().cloned(),
                            _ => None,
                        };

                        match key.and_then(|k| w.remove(&k)) {
                            Some(tx) => {
                                let _ = tx.send(f);
                            }
                            None => {
                                drop(w);
                                let mut u = s.unmatched.lock().unwrap();
                                u.push(f);
                                if u.len() > 64 {
                                    u.remove(0);
                                }
                                s.cv.notify_all();
                            }
                        }
                    }
                }
                Err(_) => {
                    s.closed.store(true, Ordering::SeqCst);
                    s.waiters.lock().unwrap().clear();
                    s.cv.notify_all();
                    return;
                }
            }
        });

        Chan { fd, shared, seq: AtomicU64::new(0), writer: Mutex::new(()) }
    }

    pub fn closed(&self) -> bool {
        self.shared.closed.load(Ordering::SeqCst)
    }

    /// The descriptor this channel is served over. Exposed so a battery
    /// can `shutdown(2)` it without closing it — see `fdpass::shutdown_fd`.
    pub fn fd(&self) -> RawFd {
        self.fd
    }

    /// One command, one reply, routed by id. Note what is absent from the
    /// frame: any statement about who is sending it.
    pub fn call(&self, command: &str, args: Value) -> io::Result<Value> {
        let id = format!("h{}", self.seq.fetch_add(1, Ordering::SeqCst));
        let (tx, rx): (SyncSender<Value>, Receiver<Value>) = sync_channel(1);
        self.shared.waiters.lock().unwrap().insert(id.clone(), tx);

        {
            let _w = self.writer.lock().unwrap();
            write_frame(
                self.fd,
                &json!({
                    "schema": "command@1",
                    "command": command,
                    "args": args,
                    "client_request_id": id,
                }),
            )?;
        }

        rx.recv_timeout(Duration::from_secs(10)).map_err(|_| {
            self.shared.waiters.lock().unwrap().remove(&id);
            io::Error::new(io::ErrorKind::TimedOut, format!("no reply to {command}"))
        })
    }

    /// Send raw bytes as one frame — for driving hostile input at the
    /// protocol rather than through it.
    pub fn send_raw(&self, bytes: &[u8]) -> io::Result<()> {
        let _w = self.writer.lock().unwrap();
        write_all(self.fd, &(bytes.len() as u32).to_be_bytes())?;
        write_all(self.fd, bytes)
    }

    /// The next projection *newer* than `cursor`, or a timeout.
    ///
    /// Newer is not "a bigger revision". The runtime sends all four
    /// continuity fields and the client must apply the rule, or the server
    /// knows continuity changed and the client does not. (This said
    /// *"triple"* for two revisions after `world_incarnation` was added and
    /// made the leading field — see `ProjectionCursor`.)
    ///
    /// ```text
    /// generation 8 · epoch A · revision 137
    ///   AuthorityCoordinator restarts
    /// generation 8 · epoch B · revision 0
    /// ```
    ///
    /// A client comparing revisions alone waits for epoch B to climb past
    /// 137, ignoring every projection of the live world until then. The
    /// rule belongs here, in the dispatcher, so a WebView never has to
    /// reinvent it.
    pub fn projection_after(&self, cursor: &ProjectionCursor, wait: Duration) -> Option<Value> {
        let deadline = Instant::now() + wait;
        let mut slot = self.shared.latest.lock().unwrap();

        loop {
            if let Some(v) = slot.as_ref() {
                if cursor.superseded_by(v) {
                    return slot.clone();
                }
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return None;
            }
            let (g, t) = self.shared.cv.wait_timeout(slot, left).unwrap();
            slot = g;
            if t.timed_out() {
                return None;
            }
        }
    }

    pub fn latest(&self) -> Option<Value> {
        self.shared.latest.lock().unwrap().clone()
    }

    pub fn hello(&self) -> Option<Value> {
        self.shared.hello.lock().unwrap().clone()
    }

    /// The oldest reply that correlated to nothing, consumed.
    pub fn last_reply(&self) -> Option<Value> {
        let mut u = self.shared.unmatched.lock().unwrap();
        if u.is_empty() { None } else { Some(u.remove(0)) }
    }
}

impl Drop for Chan {
    fn drop(&mut self) {
        // `shutdown` before `close` — see `fdpass::release_fd`. A blocked
        // reader keeps the open file description alive past `close`, so
        // the peer never sees EOF and the channel is never released.
        fdpass::release_fd(self.fd);
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        // Every path that is not `shutdown`/`stop_keeping_world`: a `?`
        // inside `start`, a panic, a battery section returning early. The
        // world is deliberately left alone — a durable world outliving the
        // host is the point, and an ephemeral one is only disposable
        // because `shutdown` was told so.
        self.release();
    }
}

/// Where a client is in a world's history.
///
/// All four fields, because none of them means anything alone — see
/// `Ampd.Projection.continuity/0`, which is where the rule is stated.
///
/// **`world_incarnation` leads, and it is the one that is an identity.**
/// This held three fields and could not tell a factory reset from an
/// ordinary advance. A reset destroys the manifest and initializes again,
/// which mints a new installation and sets `generation` back to 1 — while
/// the coordinator survives, so `projection_epoch` does not move and
/// `revision` merely increments. Measured on the runtime:
///
/// ```text
/// before  w-0d840f34…  gen 1  epoch cf7320ae  rev 3
/// after   w-0e2b4559…  gen 1  epoch cf7320ae  rev 4
/// ```
///
/// Two different worlds, which this classified as *same world, next
/// revision*. ABA, and it would have been the ground under LIVE LOCAL.
/// **Two revisions, because the cockpit renders more than authority.**
///
/// `authority_revision` (`revision` on the wire) counts ordered authority
/// mutations and is carried as evidence: *which durable authority state is
/// this frame based on*. `view_revision` counts everything a projection can
/// show — authority, plus peers, channels and refusals, which are not
/// authority at all — and is the one that decides whether a frame is new.
///
/// They were one number, and the difference was a product bug. An agent
/// channel opening changes `peers` and `channels` in `operator-projection@2`
/// and performs no authority transaction, so the runtime pushed nothing and
/// the cockpit rendered a channel topology that was no longer true, with
/// every field it could compare unchanged. Measured on the runtime.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ProjectionCursor {
    pub world_incarnation: Option<String>,
    pub world_generation: Option<u64>,
    pub projection_epoch: Option<String>,
    pub authority_revision: u64,
    pub view_revision: u64,
}

impl ProjectionCursor {
    /// Lenient: absent numbers read as zero.
    ///
    /// Kept for comparing against frames whose completeness has already
    /// been established. **Anything that will be handed to a UI must use
    /// `try_of` instead** — inventing a zero for a missing revision is a
    /// cursor that claims to know something it was never told.
    pub fn of(v: &Value) -> ProjectionCursor {
        ProjectionCursor {
            world_incarnation: v["world_incarnation"].as_str().map(String::from),
            world_generation: v["world_generation"].as_u64(),
            projection_epoch: v["projection_epoch"].as_str().map(String::from),
            authority_revision: v["revision"].as_u64().unwrap_or(0),
            view_revision: v["view_revision"].as_u64().unwrap_or(0),
        }
    }

    /// **Fail closed.** Every field present and of the right type, or
    /// nothing.
    ///
    /// `CockpitFrame.world` claims to carry both clocks, and `of` would
    /// happily produce one carrying `authority_revision: 0` from a frame
    /// that never mentioned a revision — a value a WebView would render as
    /// fact. A frame that cannot produce a complete cursor is a frame this
    /// host does not understand, and saying so is cheaper than a zero.
    pub fn try_of(v: &Value) -> Option<ProjectionCursor> {
        Some(ProjectionCursor {
            world_incarnation: Some(v["world_incarnation"].as_str()?.to_string()),
            world_generation: Some(v["world_generation"].as_u64()?),
            projection_epoch: Some(v["projection_epoch"].as_str()?.to_string()),
            authority_revision: v["revision"].as_u64()?,
            view_revision: v["view_revision"].as_u64()?,
        })
    }

    /// Whether `v` is something this cursor has not seen.
    ///
    /// Kept as the thin predicate the dispatcher needs; `classify` is what
    /// a client acts on, and this is defined in terms of it so the two can
    /// never disagree.
    pub fn superseded_by(&self, v: &Value) -> bool {
        self.classify(v) != Continuity::Seen
    }

    /// **What a client must DO about `v`, which a boolean cannot say.**
    ///
    /// `superseded_by` answers "is this new", and every one of the three
    /// ways a frame can be new demands a different action. Collapsing them
    /// into one bit pushed the decision into whatever called it, which for
    /// the cockpit means the decision would have been made in TypeScript,
    /// separately, from a comment.
    ///
    /// ```text
    /// view_revision increases      → apply the snapshot · stay LIVE LOCAL
    /// projection_epoch changes     → same world, new runtime · resnapshot
    /// world_incarnation changes    → the authority you hold is not valid here
    ///                                · discard the projection
    ///                                · reacquire human control
    ///                                · resubscribe
    /// lower or equal view_revision → already seen · ignore
    /// ```
    ///
    /// **`view_revision`, not `revision`.** Comparing the authority
    /// revision ignores every frame in which only the runtime changed — a
    /// channel opening, a channel dying, a refusal landing — all of which
    /// `operator-projection@2` shows.
    ///
    /// This is `Ampd.Projection.continuity/0`'s hierarchy, executable. The
    /// ordering is load-bearing: incarnation is checked before epoch, and
    /// epoch before revision, because a restore moves all three and only
    /// the outermost answer is the correct one.
    pub fn classify(&self, v: &Value) -> Continuity {
        let i = v["world_incarnation"].as_str().map(String::from);
        let e = v["projection_epoch"].as_str().map(String::from);
        let r = v["view_revision"].as_u64().unwrap_or(0);

        // A cursor that has never held anything accepts the first frame as
        // the world it is now in, not as an incarnation change — there is
        // nothing to discard and no authority to reacquire.
        if self.world_incarnation.is_none() && self.projection_epoch.is_none() {
            return Continuity::Fresh;
        }

        if i != self.world_incarnation {
            return Continuity::NewIncarnation;
        }

        if e != self.projection_epoch {
            return Continuity::NewRuntime;
        }

        if r > self.view_revision {
            Continuity::Advance
        } else {
            Continuity::Seen
        }
    }
}

/// What the WebView renders: one state, both cursors, and the projection
/// they describe — together, because they are only meaningful together.
///
/// Handing the UI a state and letting it fetch the projection separately
/// would take a **second sample** and undo the whole of W.1: the frame the
/// cursor was validated against would not be the frame on screen.
#[derive(Clone, Debug)]
pub struct CockpitFrame {
    pub state: Cockpit,
    /// Which durable world, and which authority state within it.
    pub world: ProjectionCursor,
    /// What this view is of — the projection itself.
    pub projection: Option<Value>,
}

/// What changed between a held cursor and an arriving frame.
///
/// Named for the action rather than the comparison: the host's state
/// machine matches on this, and `Ampd.Projection.continuity/0` is the
/// authority for what each one means.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Continuity {
    /// Nothing held yet. Adopt the frame.
    Fresh,
    /// A newer revision of the same world and the same runtime. Apply it.
    Advance,
    /// Same world, new runtime incarnation. The revision restarted at
    /// zero, so what is held is not comparable — resnapshot, but the
    /// authority the host holds is still valid.
    NewRuntime,
    /// A different world incarnation. **Everything held is invalid**,
    /// including the human control channel: F.8.2.5 closes it at the
    /// runtime, so the socket is already at EOF or about to be. Discard,
    /// reacquire, resubscribe.
    NewIncarnation,
    /// Already seen. Ignore rather than re-render.
    Seen,
}

impl Continuity {
    /// Whether the projection the client is holding must be thrown away.
    pub fn discards_projection(self) -> bool {
        matches!(self, Continuity::NewRuntime | Continuity::NewIncarnation)
    }

    /// Whether the *authority* the client holds must be re-established —
    /// the distinction that is the whole of F.8.2.5, on the host side.
    /// A new runtime is a reconnect; a new incarnation is a reacquisition.
    pub fn reacquires_authority(self) -> bool {
        matches!(self, Continuity::NewIncarnation)
    }
}

// ============================================================== cockpit
/// What the host believes about the world right now.
///
/// This is the state a WebView renders, and it is derived from the
/// continuity hierarchy rather than asserted anywhere. F.8.2.5 left the
/// host with `UnexpectedEof` and no reconnect, because there was no loop
/// to reconnect *in*; this is that loop.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Cockpit {
    /// No control channel yet, or the last one died. The host is trying to
    /// take one.
    Acquiring,
    /// Control held, subscribed, and holding a projection that names the
    /// incarnation it was assembled in.
    LiveLocal,
    /// The runtime restarted under us. The world is the same and the
    /// authority is still ours; the projection is not comparable.
    Resnapshot,
    /// The world incarnation ended. Everything held is invalid — the
    /// projection *and* the human control channel. This is the state that
    /// exists because "state moves, authority does not" is a product rule
    /// rather than a slogan.
    Reacquire,
}

/// The host's own loop: hold human control, hold one coherent projection,
/// and re-establish both when the world says they are no longer valid.
///
/// **The one thing F.8.2.5 could not deliver, and said so.** A restore
/// closes every channel bound to the ending incarnation, so the host's
/// control socket reaches EOF — and the host's answer to EOF was to return
/// an `io::Error` to whoever called last. There was nothing to reacquire
/// *with*. A reacquisition is not a retry: the old capability is gone, and
/// a new one is taken by the same route it was taken the first time.
pub struct CockpitLoop<'a> {
    rt: &'a Runtime,
    chan: Option<Chan>,
    cursor: ProjectionCursor,
    /// **The view itself, and W.1 did not have this field.**
    ///
    /// `Cockpit::LiveLocal` was documented as "control held, subscribed,
    /// and holding a projection" while `acquire` read the cursor out of the
    /// subscribe reply and dropped `result["projection"]` on the floor;
    /// `turn` did the same to every pushed frame. So LIVE LOCAL meant *I
    /// received a cursor from a coherent snapshot*, not *I hold the
    /// snapshot*. The next step would have been a WebView calling
    /// `operator_projection` again to get something to draw — a second
    /// sample, and the exact cursor/content relation W.1 exists to
    /// establish, broken at the last hop.
    projection: Option<Value>,
    state: Cockpit,
    /// How many times authority has had to be re-established. The cockpit
    /// shows it; a number that climbs on its own is a runtime restarting
    /// in a loop, which is worth seeing.
    pub reacquisitions: u64,
}

impl<'a> CockpitLoop<'a> {
    pub fn new(rt: &'a Runtime) -> CockpitLoop<'a> {
        CockpitLoop {
            rt,
            chan: None,
            cursor: ProjectionCursor::default(),
            projection: None,
            state: Cockpit::Acquiring,
            reacquisitions: 0,
        }
    }

    pub fn state(&self) -> &Cockpit {
        &self.state
    }

    pub fn cursor(&self) -> &ProjectionCursor {
        &self.cursor
    }

    pub fn projection(&self) -> Option<&Value> {
        self.projection.as_ref()
    }

    /// The render object. One call, one coherent answer.
    pub fn frame(&self) -> CockpitFrame {
        CockpitFrame {
            state: self.state.clone(),
            world: self.cursor.clone(),
            projection: self.projection.clone(),
        }
    }

    /// **`LiveLocal` is not reachable without a view.**
    ///
    /// The state machine only enters it through `go_live`, and this is the
    /// property a battery can check from outside: a cockpit claiming to be
    /// live while holding no projection is a badge that means nothing.
    pub fn invariant_holds(&self) -> bool {
        match self.state {
            Cockpit::LiveLocal => {
                self.projection.is_some()
                    && self.chan.is_some()
                    && self.cursor.world_incarnation.is_some()
                    && self.cursor.projection_epoch.is_some()
            }
            _ => true,
        }
    }

    /// Adopt a whole frame. The only way into `LiveLocal`.
    ///
    /// A frame missing its projection, its incarnation or its epoch is not
    /// something to render, so it does not produce a live cockpit — it
    /// leaves the loop `Acquiring`, which is honest and is what the next
    /// turn will act on.
    fn go_live(&mut self, frame: &Value) -> bool {
        // `try_of` is the completeness check for **every** cursor field,
        // including the authority revision — which the first version of
        // this validated `view_revision` and forgot, while `CockpitFrame`
        // went on claiming to carry both clocks. A missing revision became
        // a zero, and a zero is a number a UI renders.
        let cursor = match ProjectionCursor::try_of(frame) {
            Some(c) if frame["schema"].as_str() == Some("projection-snapshot@1")
                && frame["projection"].is_object() => c,
            _ => {
                self.projection = None;
                self.state = Cockpit::Acquiring;
                return false;
            }
        };

        if self.chan.is_none() {
            self.projection = None;
            self.state = Cockpit::Acquiring;
            return false;
        }

        self.cursor = cursor;
        self.projection = Some(frame["projection"].clone());
        self.state = Cockpit::LiveLocal;
        true
    }

    /// Drop everything held about the world. Called before any
    /// reacquisition, so a stale view is never on screen across one.
    fn discard(&mut self) {
        self.projection = None;
        self.cursor = ProjectionCursor::default();
    }

    pub fn channel(&self) -> Option<&Chan> {
        self.chan.as_ref()
    }

    /// Hand the channel out so a caller can drop it — the only way to make
    /// the runtime see EOF on demand, since `advance_lineage/2` is on no
    /// channel and a restore therefore cannot be driven from the host.
    pub fn take_channel(&mut self) -> Option<Chan> {
        self.chan.take()
    }

    /// Take human control and subscribe. **Both, or neither** — a host
    /// holding a control channel it never subscribed on renders nothing
    /// and looks live, which is the failure mode the whole projection
    /// pipeline exists to remove.
    pub fn acquire(&mut self) -> Result<(), String> {
        self.state = Cockpit::Acquiring;
        // Dropped first, explicitly. The runtime allows exactly one active
        // human control channel, so holding the dead one open while asking
        // for a new one is refused `control-channel-already-claimed` — by
        // us, on our own behalf.
        self.chan = None;
        self.discard();

        let chan = self.rt.control_channel()?;
        let snap = chan
            .call("subscribe", json!({}))
            .map_err(|e| format!("subscribe failed: {e}"))?;

        let result = &snap["result"];
        if let Some(code) = result["refusal"]["code"].as_str() {
            return Err(format!("subscribe refused: {code}"));
        }

        self.chan = Some(chan);

        // **Validated, not assumed.** A subscribe that answered with
        // something other than a complete `projection-snapshot@1` is not a
        // subscription this loop can render, and saying LIVE LOCAL about
        // it would be the same lie in a different place.
        if self.go_live(result) {
            Ok(())
        } else {
            self.chan = None;
            Err(format!(
                "subscribe returned no renderable snapshot: schema={:?} projection={}",
                result["schema"].as_str(),
                result["projection"].is_object()
            ))
        }
    }

    /// One turn of the loop. Returns the state it settled in.
    ///
    /// The ordering here is the whole point: EOF is checked first, because
    /// a closed channel cannot deliver the frame that would have explained
    /// why it closed. A restore closes the socket and *then* the world is
    /// different — the host learns the second fact by reacquiring, not by
    /// being told.
    pub fn turn(&mut self, wait: Duration) -> Cockpit {
        let dead = match &self.chan {
            None => true,
            Some(c) => c.closed(),
        };

        if dead {
            // Discard before reacquiring, always: whatever is on screen
            // describes a world this host can no longer speak for.
            self.reacquisitions += 1;
            self.state = Cockpit::Reacquire;
            self.discard();
            let _ = self.acquire();
            return self.state.clone();
        }

        let chan = self.chan.as_ref().unwrap();
        let Some(frame) = chan.projection_after(&self.cursor, wait) else {
            return self.state.clone();
        };

        self.feed(&frame)
    }

    /// Apply one frame. Split out of `turn` because *receiving* a frame and
    /// *deciding what it means* are separable, and only the second half is
    /// the state machine — a Tauri worker fed from elsewhere runs the same
    /// code, and a battery can drive the branches without a special path
    /// through the loop.
    pub fn feed(&mut self, frame: &Value) -> Cockpit {
        match self.cursor.classify(frame) {
            Continuity::Seen => {}

            // Adopt the **whole frame**, not merely its cursor. W.1 took
            // the cursor and dropped the projection here, which is how
            // LIVE LOCAL came to mean something weaker than it said.
            Continuity::Fresh | Continuity::Advance => {
                self.go_live(frame);
            }

            Continuity::NewRuntime => {
                // Same world, new runtime. The authority is still ours, so
                // the channel stands; only the view is not comparable, and
                // this frame is the resnapshot.
                self.state = Cockpit::Resnapshot;
                self.discard();
                self.go_live(frame);
            }

            Continuity::NewIncarnation => {
                // The world this channel belongs to has ended. Do not
                // reconcile, do not keep the capability, and do not keep
                // the view — take all of it again.
                self.reacquisitions += 1;
                self.state = Cockpit::Reacquire;
                self.discard();
                let _ = self.acquire();
            }
        }

        self.state.clone()
    }

    /// Turn until `f` is satisfied or the deadline passes. Returns whether
    /// it settled, so a caller never mistakes a timeout for a state.
    pub fn settle(&mut self, limit: Duration, f: impl Fn(&CockpitLoop) -> bool) -> bool {
        let deadline = Instant::now() + limit;
        loop {
            if f(self) {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            self.turn(Duration::from_millis(120));
        }
    }
}

// ============================================================== runtime
/// Where a world's stores live, and who is allowed to delete them.
///
/// **The verification rule was being used as the production rule.**
/// `Runtime::start` made a directory named for the pid and the clock,
/// pointed `AMPD_DATA_DIR` at it, and `shutdown` removed it — so a clean
/// exit *deleted the world* and an unclean one orphaned a directory the
/// next host would never look at. The isolation was right for a battery
/// that must not inherit state, and exactly wrong for a product whose
/// whole claim is that the world is durable.
#[derive(Clone, Debug)]
pub enum WorldDir {
    /// A battery's world: unique, and destroyed on shutdown. A test that
    /// passes on state it did not set up is not a test.
    Ephemeral(PathBuf),
    /// The user's world: stable across host restarts, and never deleted by
    /// this program.
    Persistent(PathBuf),
}

impl WorldDir {
    pub fn path(&self) -> &Path {
        match self {
            WorldDir::Ephemeral(p) | WorldDir::Persistent(p) => p,
        }
    }

    /// `$XDG_STATE_HOME/super/worlds/<name>`, falling back to
    /// `~/.local/state`. State, not cache and not runtime: a world is
    /// neither reconstructible nor ephemeral.
    pub fn product(name: &str) -> WorldDir {
        let base = std::env::var("XDG_STATE_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".into()))
                    .join(".local/state")
            });

        WorldDir::Persistent(base.join("super").join("worlds").join(name))
    }

    pub fn ephemeral(under: &Path) -> WorldDir {
        WorldDir::Ephemeral(under.join("world"))
    }
}

pub struct Runtime {
    dir: PathBuf,
    world: WorldDir,
    /// Held for the host's lifetime — an advisory lock lives on the open
    /// file description, so releasing this descriptor releases the world.
    world_lock: RawFd,
    child: Child,
    bridge: RawFd,
    /// The bridge is one descriptor carrying send/recv transactions with
    /// no correlation ids, so two concurrent channel creations would read
    /// each other's replies. Channel creation is rare; a lock is the right
    /// size of answer.
    bridge_lock: Mutex<()>,
    /// Every channel descriptor this host has created, so descriptor
    /// confinement is something the battery can check rather than trust.
    channels: Mutex<Vec<RawFd>>,
    /// The inodes of every endpoint this host has handed to the runtime.
    ///
    /// The **structural** answer to "is this descriptor a Super channel?",
    /// replacing the string test `readlink(...) contains "socket:"`. That
    /// proxy called any socket a channel, so a verifier launched with
    /// socketpair-backed stdio — which `execFileSync` supplies — reported a
    /// channel on fd 1 and 2 and failed a gate about something else
    /// entirely. Sockets are perfectly valid stdio; the question was never
    /// whether a descriptor is a socket.
    channel_inodes: Mutex<Vec<u64>>,
    /// Whether `release` has already run. `shutdown` and
    /// `stop_keeping_world` call it explicitly and `Drop` calls it again
    /// on the way out, so it has to be answerable twice.
    released: bool,
}

/// Remove `$XDG_RUNTIME_DIR/ampd-<pid>-<stamp>` directories whose owning host
/// is gone.
///
/// # What these directories are, which is less than it looks
///
/// `Runtime::start` creates one per runtime and `Runtime::release` removes it.
/// **Nothing else in the tree touches one.** There is no accessor, nothing is
/// ever written inside, and a grep across `host/`, `ampd/`, `cockpit/` and
/// `tools/` finds exactly the two lines that make and unmake it. They are
/// always empty — for a live runtime as much as a dead one — so "is it empty"
/// carries no information about whether anyone is using it.
///
/// The sockets a reader might assume live here are somewhere else entirely:
/// `Ampd.Transport` puts them in `$TMPDIR/ampd-pair-<rand>/<rand>.sock`, and
/// those are made and removed on the BEAM side.
///
/// So the directory's only real value is diagnostic, and it is the accidental
/// kind: **one left behind is one runtime that did not release.**
/// `Runtime::release`'s own note records 368 of them once, alongside three
/// occasions of orphaned BEAMs pinning 17 to 23 of 24 cores. That is a useful
/// signal and the reason this sweeps rather than the field being deleted —
/// but a signal nothing reads and nothing bounds is just accumulation, and
/// the count was **502** when this was written.
///
/// # Why deleting one is safe, stated rather than assumed
///
/// The dangerous mistake would be removing a directory a live runtime needs.
/// It cannot happen, for two independent reasons, and the second is the one
/// that actually holds:
///
///   1. the pid in the name is the host process that owns the `Runtime`, so a
///      live runtime implies a live pid, and a live pid is skipped;
///   2. **nothing uses the directory at all** — so even in the case the first
///      reason misses (a host that died leaving an orphaned BEAM, which is
///      exactly the case these directories mark) removing it takes nothing
///      away from anyone.
///
/// PID reuse can only make this *more* conservative: a recycled pid looks
/// alive, and its directory is left alone.
///
/// # The predicates
///
/// All four must hold, and they are deliberately more than the argument above
/// needs:
///
///   name parses as `ampd-<digits>-<digits>`   not ours otherwise
///   the directory is empty                    never removes anything's content
///   `/proc/<pid>` is absent                   the owner is gone
///   mtime older than the grace period         no just-created directory, ever
///
/// The third is the load-bearing one. Removing it, or the fourth, turns
/// `tools/check-runtime-dir-sweep.sh` red — measured.
///
/// **The second is redundant today and is kept deliberately, which is worth
/// saying because the test cannot see it.** Removing the emptiness check
/// alone changes nothing: `remove_dir` is not `remove_dir_all` and refuses a
/// non-empty directory itself, so the falsifier stays green and the predicate
/// looks dead. It is not dead, it is doubled — remove the check *and* widen
/// the call to `remove_dir_all` and the same falsifier goes red. So the pair
/// is load-bearing together and either half alone suffices, which is the
/// property you want for a deletion and the reason not to "simplify" one of
/// them away on the evidence of a green suite.
///
/// Failures are ignored throughout. A sweep that refused to start a runtime
/// because it could not tidy up would be trading a real capability for
/// housekeeping.
fn sweep_stale_runtime_dirs(base: &Path) {
    // **Long, because this is many concurrent sessions on one machine.** A
    // parallel session's directory is already protected by its live pid; the
    // grace period is the belt to that braces, and an hour of accumulation is
    // nothing against a count that reached 502.
    const GRACE: Duration = Duration::from_secs(3600);

    let Ok(entries) = std::fs::read_dir(base) else { return };
    let now = SystemTime::now();

    for e in entries.flatten() {
        let name = e.file_name();
        let Some(name) = name.to_str() else { continue };

        // `ampd-<pid>-<stamp>`, both numeric. `ampd-pair-*` fails this on the
        // first field, which is the point — those belong to the BEAM and hold
        // real sockets.
        let Some(rest) = name.strip_prefix("ampd-") else { continue };
        let Some((pid, stampf)) = rest.split_once('-') else { continue };
        let Ok(pid) = pid.parse::<u32>() else { continue };
        if stampf.is_empty() || !stampf.bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }

        let p = e.path();
        if !p.is_dir() {
            continue;
        }

        // Empty, or leave it alone.
        match std::fs::read_dir(&p) {
            Ok(mut it) => {
                if it.next().is_some() {
                    continue;
                }
            }
            Err(_) => continue,
        }

        // The owner is still here.
        if Path::new(&format!("/proc/{pid}")).exists() {
            continue;
        }

        // Younger than the grace period.
        let recent = e
            .metadata()
            .and_then(|m| m.modified())
            .map(|m| now.duration_since(m).map(|d| d < GRACE).unwrap_or(true))
            .unwrap_or(true);
        if recent {
            continue;
        }

        let _ = std::fs::remove_dir(&p);
    }
}

impl Runtime {
    /// Spawn `ampd` holding one end of a sequenced-packet pair.
    ///
    /// The bridge exists before the runtime has executed an instruction,
    /// so "the privileged connection" is a fact established at `fork`
    /// rather than a race anything can enter.
    pub fn start(ampd_dir: &Path, world: WorldDir) -> Result<Runtime, String> {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);

        let base = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());

        // Before this run adds one of its own. See `sweep_stale_runtime_dirs`.
        sweep_stale_runtime_dirs(Path::new(&base));

        let dir = PathBuf::from(base).join(format!("ampd-{}-{}", std::process::id(), stamp));
        std::fs::create_dir_all(&dir).map_err(|e| format!("runtime dir: {e}"))?;

        let world_path = world.path().to_path_buf();
        std::fs::create_dir_all(&world_path).map_err(|e| format!("world dir: {e}"))?;
        std::fs::set_permissions(&world_path, std::fs::Permissions::from_mode(0o700))
            .map_err(|e| format!("world dir mode: {e}"))?;

        // Before anything opens a store. Two hosts on one world is a
        // corruption path DETS would not report.
        let world_lock = fdpass::lock_world(&world_path.join("world.lock"))?;

        let fdpass::Pair(ours, theirs) =
            fdpass::pair_seqpacket().map_err(|e| format!("bridge socketpair: {e}"))?;

        let child = unsafe {
            Command::new("mix")
                .args(["run", "--no-halt"])
                .current_dir(ampd_dir)
                .env("AMPD_BRIDGE_FD", "3")
                // A verification run must start from a world it created.
                // This battery once inherited a 5 MB grant request from
                // `priv/data` and watched every projection come back
                // `frame-too-large` — a real refusal, for a reason that had
                // nothing to do with the code under test.
                .env("AMPD_DATA_DIR", &world_path)
                .env("MIX_ENV", "dev")
                .stdin(Stdio::null())
                .stdout(Stdio::inherit())
                .stderr(Stdio::inherit())
                .pre_exec(move || {
                    // Order matters: 0, 1 and 2 must be occupied before
                    // the bridge is placed, or `dup2(theirs, 3)` could be
                    // handing the bridge a number the runtime will later
                    // treat as a standard stream.
                    fdpass::ensure_std_fds()?;
                    fdpass::dup_onto(theirs, 3)
                })
                .spawn()
        }
        .map_err(|e| format!("spawning ampd: {e}"))?;

        // Read before closing: the child inherited this same open file
        // description as fd 3, so this inode is the one its adopted bridge
        // will show. The bridge is a Super channel and must be in the set.
        let bridge_inode = fd_inode(theirs);

        // Our copy of the child's end is dead weight the moment it is
        // inherited; holding it would keep the channel alive after the
        // child died, which is a channel with nobody on it.
        fdpass::close_fd(theirs);

        let rt = Runtime {
            dir,
            world,
            world_lock,
            child,
            bridge: ours,
            bridge_lock: Mutex::new(()),
            channels: Mutex::new(Vec::new()),
            channel_inodes: Mutex::new(bridge_inode.into_iter().collect()),
            released: false,
        };
        rt.await_ready(Duration::from_secs(90))?;
        Ok(rt)
    }

    /// The runtime answers a bridge command when it is up. Nothing appears
    /// in the filesystem to poll for, so readiness is asked rather than
    /// watched.
    pub fn await_ready(&self, limit: Duration) -> Result<(), String> {
        let start = Instant::now();
        let mut last = String::from("no answer");

        while start.elapsed() < limit {
            match self.bridge_call(&json!({
                "schema": "bridge-command@1",
                "command": "runtime_status"
            })) {
                Ok(v) if v["ok"] == true => return Ok(()),
                Ok(v) => last = format!("{v}"),
                Err(e) => last = e,
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        Err(format!("the runtime never became ready: {last}"))
    }

    pub fn bridge_call(&self, v: &Value) -> Result<Value, String> {
        let _b = self.bridge_lock.lock().unwrap();
        let bytes = serde_json::to_vec(v).map_err(|e| e.to_string())?;
        fdpass::send_plain(self.bridge, &bytes).map_err(|e| format!("bridge send: {e}"))?;
        let reply = fdpass::recv_msg(self.bridge, 64 * 1024).map_err(|e| format!("bridge recv: {e}"))?;
        serde_json::from_slice(&reply).map_err(|e| format!("bridge reply: {e}"))
    }

    /// Send `raw` — which need not be a valid command — carrying `n`
    /// descriptors the runtime has no use for.
    ///
    /// The point is the descriptors, not the reply. A command the runtime
    /// rejects still arrived with rights attached, and those rights are in
    /// the runtime's descriptor table from the moment `recvmsg` returns.
    /// Whether they are still there afterwards is the measurement.
    pub fn bridge_call_with_rights(&self, raw: &[u8], n: usize) -> Result<Value, String> {
        let _b = self.bridge_lock.lock().unwrap();
        let mut spares = Vec::new();
        for _ in 0..n {
            spares.push(fdpass::spare_fd().map_err(|e| format!("spare fd: {e}"))?);
        }

        let sent = fdpass::send_with_fds(self.bridge, raw, &spares);
        for fd in &spares {
            fdpass::close_fd(*fd);
        }
        sent.map_err(|e| format!("bridge sendmsg: {e}"))?;

        let reply = fdpass::recv_msg(self.bridge, 64 * 1024).map_err(|e| format!("bridge recv: {e}"))?;
        serde_json::from_slice(&reply).map_err(|e| format!("bridge reply: {e}"))
    }

    /// A *valid* bind, with `surplus` extra descriptors in the same
    /// control message.
    ///
    /// The runtime binds the first and discards the rest. One channel
    /// should remain; `surplus` descriptors should not.
    pub fn agent_channel_with_surplus(&self, actor: &str, surplus: usize) -> Result<Chan, String> {
        let _b = self.bridge_lock.lock().unwrap();
        let fdpass::Pair(ours, theirs) =
            fdpass::pair_stream().map_err(|e| format!("channel socketpair: {e}"))?;

        let mut all = vec![theirs];
        for _ in 0..surplus {
            all.push(fdpass::spare_fd().map_err(|e| format!("spare fd: {e}"))?);
        }

        let cmd = json!({"schema":"bridge-command@1","command":"bind_agent_channel","actor":actor});
        let bytes = serde_json::to_vec(&cmd).map_err(|e| e.to_string())?;
        let sent = fdpass::send_with_fds(self.bridge, &bytes, &all);
        for fd in &all {
            fdpass::close_fd(*fd);
        }
        sent.map_err(|e| format!("bridge sendmsg: {e}"))?;

        let reply = fdpass::recv_msg(self.bridge, 64 * 1024).map_err(|e| format!("bridge recv: {e}"))?;
        let v: Value = serde_json::from_slice(&reply).map_err(|e| format!("bridge reply: {e}"))?;

        if v["ok"] != true {
            fdpass::close_fd(ours);
            return Err(format!("refused: {}", v["refusal"]["code"]));
        }

        self.channels.lock().unwrap().push(ours);
        Ok(Chan::adopt(ours))
    }

    /// Hand the runtime one end of a new pair, labelled. The label and the
    /// capability travel in the same message.
    pub fn bind_channel(&self, command: &str, actor: Option<&str>) -> Result<Chan, String> {
        let _b = self.bridge_lock.lock().unwrap();
        let fdpass::Pair(ours, theirs) =
            fdpass::pair_stream().map_err(|e| format!("channel socketpair: {e}"))?;

        let mut cmd = json!({"schema": "bridge-command@1", "command": command});
        if let Some(a) = actor {
            cmd["actor"] = json!(a);
        }

        let bytes = serde_json::to_vec(&cmd).map_err(|e| e.to_string())?;
        // Read before the send, because `theirs` is closed straight after.
        let given = fd_inode(theirs);
        let sent = fdpass::send_with_fd(self.bridge, &bytes, theirs);
        fdpass::close_fd(theirs);
        sent.map_err(|e| format!("bridge sendmsg: {e}"))?;

        let reply = fdpass::recv_msg(self.bridge, 64 * 1024).map_err(|e| format!("bridge recv: {e}"))?;
        let v: Value = serde_json::from_slice(&reply).map_err(|e| format!("bridge reply: {e}"))?;

        if v["ok"] != true {
            fdpass::close_fd(ours);
            return Err(format!(
                "the runtime refused the channel: {}",
                v["refusal"]["code"]
            ));
        }

        if let Some(i) = given { self.channel_inodes.lock().unwrap().push(i); }

        self.channels.lock().unwrap().push(ours);
        let chan = Chan::adopt(ours);
        let hello = read_hello(&chan)?;

        if let Some(a) = actor {
            if hello["actor"] != a {
                return Err(format!("a channel for {a} greeted as {}", hello["actor"]));
            }
        }
        Ok(chan)
    }

    pub fn control_channel(&self) -> Result<Chan, String> {
        self.bind_channel("bind_control_channel", None)
    }

    /// Hand the runtime one end of a private **effect** channel and keep
    /// the other, then serve machine effects on it.
    ///
    /// **The same bind, in the other direction of use.** A control or agent
    /// channel makes the runtime the server and this process the client;
    /// on this one the runtime is the client — it submits already-admitted
    /// mechanism requests — and this process is the server that performs
    /// them. That inversion is the whole point: authority is decided above,
    /// and the mechanism only receives what was admitted.
    ///
    /// Nothing new is introduced to do it. Same `pair_stream`, same
    /// `SCM_RIGHTS` transfer over the same bridge, same 4-byte framing,
    /// same adoption on the far side. The only new thing on the wire is a
    /// `bridge-command@1` name and the ephemeral incarnation that travels
    /// with it.
    ///
    /// The incarnation is minted **here**, by the process that creates the
    /// pair, because an epoch that the runtime chose would say nothing
    /// about which endpoint it is talking to. `host_identity` is the same
    /// object `super-host identity` prints — the runtime therefore learns
    /// what performs its effects from the endpoint that will perform them,
    /// instead of from a second resolution of a pathname.
    pub fn effect_channel(&self) -> Result<RawFd, String> {
        let _b = self.bridge_lock.lock().unwrap();
        let fdpass::Pair(ours, theirs) =
            fdpass::pair_stream().map_err(|e| format!("effect socketpair: {e}"))?;

        let cmd = json!({
            "schema": "bridge-command@1",
            "command": "bind_effect_channel",
            "incarnation": {
                "schema": "effect-channel@1",
                "channel_epoch": new_epoch(),
                "protocol": "worktree-effect",
                "protocol_version": effect::EFFECT_PROTOCOL_VERSION,
                "host_identity": effect::identity(),
            }
        });

        let bytes = serde_json::to_vec(&cmd).map_err(|e| e.to_string())?;
        let given = fd_inode(theirs);
        let sent = fdpass::send_with_fd(self.bridge, &bytes, theirs);
        fdpass::close_fd(theirs);
        sent.map_err(|e| format!("bridge sendmsg: {e}"))?;
        if let Some(i) = given { self.channel_inodes.lock().unwrap().push(i); }

        let reply =
            fdpass::recv_msg(self.bridge, 64 * 1024).map_err(|e| format!("bridge recv: {e}"))?;
        let v: Value = serde_json::from_slice(&reply).map_err(|e| format!("bridge reply: {e}"))?;

        if v["ok"] != true {
            fdpass::close_fd(ours);
            return Err(format!(
                "the runtime refused the effect channel: {}",
                v["refusal"]["code"]
            ));
        }

        self.channels.lock().unwrap().push(ours);
        Ok(ours)
    }

    /// D.1.3c·2c·1b — **a terminal data-plane endpoint, and it names nothing.**
    ///
    /// The narrowest bridge command in the runtime, deliberately. It carries
    /// no Worker, no generation, no actor and no incarnation: it hands the
    /// runtime a socket and gets back an opaque reference to the socket the
    /// caller already owns the other end of. There is no argument here that
    /// could designate a position, so there is nothing here to get wrong.
    ///
    /// The authority for a presentation arrives **separately, on the human
    /// control channel**, where `Ampd.Control` has already resolved the bound
    /// connection. The bridge carries no operator identity and never will —
    /// which is exactly why the Worker is not named here.
    ///
    /// Returns `(our end, endpoint_ref)`. The reference is for the caller's
    /// own next call and must not be handed to a page.
    ///
    /// Same socketpair, same `SCM_RIGHTS`, same adoption, same disposal as
    /// `effect_channel` and `carrier_channel` above. One more bridge command
    /// and no new descriptor mechanism.
    pub fn terminal_endpoint(&self) -> Result<(RawFd, String), String> {
        let _b = self.bridge_lock.lock().unwrap();
        let fdpass::Pair(ours, theirs) =
            fdpass::pair_stream().map_err(|e| format!("terminal socketpair: {e}"))?;

        let cmd = json!({
            "schema": "bridge-command@1",
            "command": "bind_terminal_endpoint",
        });

        let bytes = serde_json::to_vec(&cmd).map_err(|e| e.to_string())?;
        let sent = fdpass::send_with_fd(self.bridge, &bytes, theirs);
        fdpass::close_fd(theirs);
        sent.map_err(|e| format!("bridge sendmsg: {e}"))?;

        let reply =
            fdpass::recv_msg(self.bridge, 64 * 1024).map_err(|e| format!("bridge recv: {e}"))?;
        let v: Value = serde_json::from_slice(&reply).map_err(|e| format!("bridge reply: {e}"))?;

        if v["ok"] != true {
            fdpass::close_fd(ours);
            return Err(format!(
                "the runtime refused the terminal endpoint: {}",
                v["refusal"]["code"]
            ));
        }

        // **Top level, not under `result`.** `Ampd.Transport.HostBridge`'s
        // `ok/1` merges `{"schema", "ok"}` over the payload map, so a bridge
        // reply is flat — `v["result"]["endpoint_ref"]` reads `null` on a
        // perfectly good answer and closes a socket the runtime has adopted.
        match v["endpoint_ref"].as_str() {
            Some(r) => Ok((ours, r.to_string())),
            // **Closed here, and this branch is not defensive padding.** A
            // reply we cannot read is a socket the runtime has adopted and we
            // still hold — the one shape where both ends stay open forever
            // because each is waiting to be told what to do with it.
            None => {
                fdpass::close_fd(ours);
                Err("the runtime answered without an endpoint_ref".to_string())
            }
        }
    }

    /// The **Carrier lifecycle** channel — a second possessed endpoint.
    ///
    /// Deliberately its own channel and not a second protocol on the effect
    /// one. D.1.3a recorded that `EffectChannel.await/4` skips a non-matching
    /// observation rather than routing it, which is safe with one submitter
    /// and is not a demultiplexer; D.1.3b·2 puts the Carrier machine phase
    /// *outside* the total order, so a Carrier start can be in flight while a
    /// worktree effect is submitted. Two submitters on one stream is exactly
    /// the case that was named as the thing that would break.
    ///
    /// Same socketpair, same `SCM_RIGHTS`, same adoption, same framing. One
    /// more bridge command and no new descriptor mechanism.
    pub fn carrier_channel(&self) -> Result<RawFd, String> {
        let _b = self.bridge_lock.lock().unwrap();
        let fdpass::Pair(ours, theirs) =
            fdpass::pair_stream().map_err(|e| format!("carrier socketpair: {e}"))?;

        // **The Carrier execution basis rides the possessed channel.**
        //
        // The runtime must bind, at admission, the identity of the Carrier
        // implementation it is admitting — otherwise "admitted as A" is not a
        // fact about anything and A can silently become B before commit. The
        // question is where that identity comes from, and the answer must not
        // be a second ambient lookup: a runtime that resolved the payload by
        // name would have re-acquired exactly the authority D.1.3a took away.
        //
        // This channel is already host-originated and already possessed, so
        // its establishment is the one moment that is both trusted and
        // *before* any admission. Measuring here also means a host restart or
        // a rebind naturally establishes a fresh basis, which is the correct
        // behaviour for a redeployed payload and needs no invalidation
        // protocol of its own.
        //
        // No raw pathname crosses: the basis carries a digest.
        // **`payload_path`, not `fixture_path`, and they must be the same
        // function the spawn uses.** The digest bound into every ticket is
        // a promise about the executable `start_one` will run; measuring one
        // payload here and running another would refuse every admission
        // `carrier-execution-basis-changed` and point the reader at the
        // digest rather than at the mismatch. `super-host verify` holds the
        // two together.
        let carrier_basis = match carrier::payload_path() {
            Some(p) => execution_basis(installed_payload_digest(&p)),
            // A host with no fixture installed still binds the channel — it
            // can still serve `stop` — but every admission against this basis
            // will refuse, which is the right direction. A basis that was
            // absent rather than unequal would be a basis a comparison could
            // skip.
            None => execution_basis("uninstalled".to_string()),
        };

        let cmd = json!({
            "schema": "bridge-command@1",
            "command": "bind_carrier_channel",
            "incarnation": {
                "schema": "effect-channel@1",
                "channel_epoch": new_epoch(),
                "protocol": "carrier-lifecycle",
                "protocol_version": 1,
                "host_identity": effect::identity(),
                "carrier_basis": carrier_basis,
            }
        });

        let bytes = serde_json::to_vec(&cmd).map_err(|e| e.to_string())?;
        let given = fd_inode(theirs);
        let sent = fdpass::send_with_fd(self.bridge, &bytes, theirs);
        fdpass::close_fd(theirs);
        sent.map_err(|e| format!("bridge sendmsg: {e}"))?;
        if let Some(i) = given { self.channel_inodes.lock().unwrap().push(i); }

        let reply =
            fdpass::recv_msg(self.bridge, 64 * 1024).map_err(|e| format!("bridge recv: {e}"))?;
        let v: Value = serde_json::from_slice(&reply).map_err(|e| format!("bridge reply: {e}"))?;

        if v["ok"] != true {
            fdpass::close_fd(ours);
            return Err(format!(
                "the runtime refused the carrier channel: {}",
                v["refusal"]["code"]
            ));
        }

        self.channels.lock().unwrap().push(ours);
        Ok(ours)
    }

    pub fn agent_channel(&self, actor: &str) -> Result<Chan, String> {
        self.bind_channel("bind_agent_channel", Some(actor))
    }

    /// A descriptor for an engine: the runtime end is bound and adopted,
    /// and the raw client end is returned to be inherited by a child.
    pub fn agent_fd(&self, actor: &str) -> Result<RawFd, String> {
        let _b = self.bridge_lock.lock().unwrap();
        let fdpass::Pair(ours, theirs) =
            fdpass::pair_stream().map_err(|e| format!("channel socketpair: {e}"))?;

        let cmd = json!({"schema":"bridge-command@1","command":"bind_agent_channel","actor":actor});
        let bytes = serde_json::to_vec(&cmd).map_err(|e| e.to_string())?;
        let given = fd_inode(theirs);
        let sent = fdpass::send_with_fd(self.bridge, &bytes, theirs);
        if let Some(i) = given { self.channel_inodes.lock().unwrap().push(i); }
        fdpass::close_fd(theirs);
        sent.map_err(|e| format!("bridge sendmsg: {e}"))?;

        let reply = fdpass::recv_msg(self.bridge, 64 * 1024).map_err(|e| format!("bridge recv: {e}"))?;
        let v: Value = serde_json::from_slice(&reply).map_err(|e| e.to_string())?;

        if v["ok"] != true {
            fdpass::close_fd(ours);
            return Err(format!("refused: {}", v["refusal"]["code"]));
        }
        self.channels.lock().unwrap().push(ours);
        Ok(ours)
    }

    /// Every descriptor this host holds, and whether it would survive an
    /// `exec`. The channels are tracked as they are created so this can be
    /// asserted rather than assumed.
    /// `Some(n)` when all `n` still-open descriptors are close-on-exec;
    /// `None` when any of them would survive an `exec`. Released
    /// descriptors are skipped — they cannot leak — but counted separately
    /// so a vacuous pass is visible.
    pub fn live_cloexec(&self) -> Option<usize> {
        let mut live = 0;
        let mut all = vec![self.bridge];
        all.extend(self.channels.lock().unwrap().iter().copied());

        for fd in all {
            match fdpass::fd_state(fd) {
                fdpass::FdState::Closed => {}
                fdpass::FdState::Cloexec => live += 1,
                fdpass::FdState::Inheritable => return None,
            }
        }
        Some(live)
    }

    /// Kill the runtime, reap it, and release what the host was holding.
    ///
    /// **This is `Drop`'s body, and that is the point.** `Child` does not
    /// kill on drop, so for as long as the only cleanup was a `self`-by-value
    /// `shutdown` every path that dropped a `Runtime` without calling one
    /// left a live `beam.smp` reparented to init, spinning a scheduler on
    /// every core. `Runtime::start`'s own `await_ready(90s)?` was the worst
    /// of them: it drops `rt` on timeout, so the caller never receives the
    /// handle it would have needed to clean up, and no caller-side
    /// discipline could have closed it. Measured before the fix: 368
    /// `$XDG_RUNTIME_DIR/ampd-*` dirs — this function is the only thing
    /// that removes one — and three separate occasions of 5, 8 and 13
    /// orphans pinning 17 to 23 of 24 cores.
    ///
    /// Idempotent, because both stop paths call it *before* deciding what
    /// happens to the world and then drop, which would otherwise
    /// double-`close(2)` two descriptors onto numbers the kernel has
    /// already handed back out.
    fn release(&mut self) {
        if self.released {
            return;
        }
        self.released = true;

        let _ = self.child.kill();
        let _ = self.child.wait();
        fdpass::close_fd(self.bridge);
        // Releases the advisory lock with it.
        fdpass::close_fd(self.world_lock);
        let _ = std::fs::remove_dir_all(&self.dir);
    }

    /// Stop the runtime. **Only an ephemeral world is deleted** — the
    /// user's world outliving the program that opened it is the entire
    /// point of it being durable.
    pub fn shutdown(mut self) {
        // Before the world is touched: the runtime is still writing to it.
        self.release();

        if let WorldDir::Ephemeral(p) = &self.world {
            let _ = std::fs::remove_dir_all(p);
        }
    }

    /// Stop the runtime and leave the world alone, whatever kind it is.
    /// The durability check needs a first host to exit the way a user
    /// quitting the app does, and then a second one to find the world.
    pub fn stop_keeping_world(mut self) {
        self.release();
    }

    /// How many descriptors the runtime process is holding.
    ///
    /// Descriptor ownership can only be measured here: the `dup` question
    /// arises on the integer path, and the only thing that reaches it is
    /// an `SCM_RIGHTS` receive from this host. Counting `/proc/<ampd>/fd`
    /// across real binds is the measurement; an in-BEAM test cannot
    /// construct the case at all.
    pub fn child_pid(&self) -> u32 {
        self.child.id()
    }

    pub fn runtime_fd_count(&self) -> usize {
        self.runtime_socket_count()
    }

    /// Poll until the runtime holds exactly `target` sockets, or give up.
    ///
    /// **What it converges to, not what it is at an arbitrary instant.**
    /// The runtime tears each connection down in its own process, so a
    /// count taken right after a close is a race. Returns the final count
    /// either way — a check that fails should report the number it saw,
    /// not the word "timeout".
    pub fn settle_sockets(&self, target: usize, limit: Duration) -> usize {
        let deadline = Instant::now() + limit;
        loop {
            let n = self.runtime_socket_count();
            if n == target || Instant::now() >= deadline {
                return n;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    /// Sockets only. The BEAM holds a couple of dozen descriptors that are
    /// nothing to do with us — epoll, eventfd, the DETS stores — and they
    /// move for their own reasons. Counting all of them measures the VM;
    /// counting sockets measures channels.
    pub fn runtime_socket_count(&self) -> usize {
        std::fs::read_dir(format!("/proc/{}/fd", self.child.id()))
            .map(|d| {
                d.flatten()
                    .filter(|e| {
                        std::fs::read_link(e.path())
                            .map(|t| t.to_string_lossy().contains("socket:"))
                            .unwrap_or(false)
                    })
                    .count()
            })
            .unwrap_or(0)
    }

    /// Of the sockets the runtime holds, how many would survive an `exec`.
    ///
    /// **This is readable from here and from nowhere else.** `fcntl` asks
    /// about *this* process's table; `/proc/<ampd>/fdinfo/<n>` reports the
    /// other one's, and its octal `flags` field carries `O_CLOEXEC`
    /// (`02000000`) alongside the access mode. The runtime cannot check
    /// this about itself — `Ampd.NativeFd.state/1` answers for a
    /// descriptor the caller already names, and the interesting question
    /// is whether *every* descriptor it holds is confined.
    ///
    /// Every unix-domain socket the runtime holds, and whether it would
    /// survive an `exec`.
    ///
    /// **Unix-domain only, and taken as a set so it can be differenced.**
    /// Two restrictions, each for a measured reason:
    ///
    /// *Unix-domain*, because the BEAM holds sockets of its own and OTP
    /// creates an `inet` socket inheritable. The first version of this
    /// check counted all sockets and failed on the VM rather than on us.
    /// Every descriptor that reaches the runtime from this host is
    /// `AF_UNIX`, and `/proc/net/unix` names their inodes, so the
    /// population can be selected by what it *is*.
    ///
    /// *A set*, because even among unix sockets the BEAM has one of its
    /// own — a `u_str` pair to `erl_child_setup`, inheritable, and not
    /// ours to police. Asserting against the sockets that **appear** when
    /// a channel is bound measures our adoption and nothing else. A check
    /// that has to reason about which of the VM's descriptors to forgive
    /// is a check that will forgive one of ours.
    pub fn runtime_unix_fds(&self) -> std::collections::BTreeMap<String, bool> {
        const O_CLOEXEC: u32 = 0o2000000;
        let pid = self.child.id();
        let mut out = std::collections::BTreeMap::new();

        let unix_inodes: std::collections::HashSet<String> =
            std::fs::read_to_string("/proc/net/unix")
                .map(|s| {
                    s.lines()
                        .skip(1)
                        .filter_map(|l| l.split_whitespace().nth(6).map(String::from))
                        .collect()
                })
                .unwrap_or_default();

        let Ok(dir) = std::fs::read_dir(format!("/proc/{pid}/fd")) else {
            return out;
        };

        for e in dir.flatten() {
            let Ok(target) = std::fs::read_link(e.path()) else {
                continue;
            };
            let target = target.to_string_lossy().to_string();
            let Some(ino) = target
                .strip_prefix("socket:[")
                .and_then(|s| s.strip_suffix(']'))
            else {
                continue;
            };
            if !unix_inodes.contains(ino) {
                continue;
            }

            let fd = e.file_name().to_string_lossy().to_string();
            let Ok(info) = std::fs::read_to_string(format!("/proc/{pid}/fdinfo/{fd}")) else {
                continue;
            };
            for line in info.lines() {
                if let Some(v) = line.strip_prefix("flags:") {
                    if let Ok(f) = u32::from_str_radix(v.trim(), 8) {
                        out.insert(format!("{fd} ({ino})"), f & O_CLOEXEC != 0);
                    }
                }
            }
        }
        out
    }

    /// Is descriptor `n` open in the runtime at all?
    ///
    /// Asked about fd 3, this is the shortest proof that the inherited
    /// bridge descriptor was disposed of: the host `dup2`s the bridge onto
    /// 3 before `exec`, so 3 is where it lands, and after adoption there
    /// should be nothing there.
    /// Every endpoint inode this host has handed to the runtime.
    pub fn adopted_channel_inodes(&self) -> Vec<u64> {
        self.channel_inodes.lock().unwrap().clone()
    }

    /// Is this `/proc/<pid>/fd/<n>` target one of the runtime's adopted
    /// Super channels?
    ///
    /// **Not "is it a socket".** A socket the launcher supplied as stdio is
    /// a socket and is not a channel; the difference is whether this host
    /// gave it away. Independent of how the verifier itself was started.
    pub fn is_adopted_channel(&self, target: &str) -> bool {
        match socket_inode(target) {
            None => false,
            Some(i) => self.channel_inodes.lock().unwrap().contains(&i),
        }
    }

    pub fn runtime_fd_open(&self, n: RawFd) -> bool {
        std::fs::read_link(format!("/proc/{}/fd/{}", self.child.id(), n)).is_ok()
    }

    /// What the runtime has on descriptor `n`, for a failure message that
    /// says something.
    pub fn runtime_fd_target(&self, n: RawFd) -> String {
        std::fs::read_link(format!("/proc/{}/fd/{}", self.child.id(), n))
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|_| "closed".into())
    }

    pub fn world(&self) -> WorldDir {
        self.world.clone()
    }
}

/// `hello@1` arrives unprompted, before anything is asked — so a client
/// never has to make "what am I, and how current am I?" its first command.
fn read_hello(chan: &Chan) -> Result<Value, String> {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if let Some(h) = chan.hello() {
            return Ok(h);
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    Err("the channel never greeted".into())
}

/// The binary's whole body, in the library, so `super-host` and the
/// cockpit are one program with two entry points rather than two programs
/// that agree by inspection.
pub fn cli() -> i32 {
    let args: Vec<String> = std::env::args().collect();

    let ampd_dir = std::env::var("AMPD_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            std::env::current_dir()
                .unwrap_or_else(|_| PathBuf::from("."))
                .join("ampd")
        });

    // **Before the `ampd/` requirement, deliberately.** `effect` performs a
    // machine operation that was already admitted; it does not start a
    // runtime, read a world, or consult anything in `ampd/`. Requiring the
    // runtime's source tree to be present would couple the performer to the
    // decider in the one direction this boundary exists to remove.
    if args.get(1).map(String::as_str) == Some("effect") {
        return effect::run();
    }

    // Same reason as `effect`, one step earlier: `ampd` asks what this
    // machine *is* before it decides anything, and answering requires no
    // world, no runtime and no `ampd/` tree.
    if args.get(1).map(String::as_str) == Some("identity") {
        return effect::identity_run();
    }

    // **Test scaffolding, and named as such.** Spawns one Carrier, prints its
    // pid and start time, and waits to be killed. `verify` uses it as a
    // sacrificial parent so the parent-death binding can be proved
    // behaviourally rather than only attested — there is no `/proc` field for
    // `PR_SET_PDEATHSIG`, so the only way to show it works is to kill a
    // parent and watch the child go.
    //
    // Before the `ampd/` check for the same reason `effect` is: it starts no
    // runtime and reads no world. +1 subcommand on the host's surface,
    // counted; it creates no authority and adopts no channel.
    // Diagnostic, and the only way `sweep_stale_runtime_dirs` can be
    // falsified: it is called from `Runtime::start` against the real
    // `$XDG_RUNTIME_DIR`, where a test may not plant fixtures. This arm runs
    // it against a base directory the caller owns and prints what survived,
    // so `tools/check-runtime-dir-sweep.sh` can assert exactly which entries
    // it may and may not remove. Same shape as `carrier-orphan-fixture`.
    if args.get(1).map(String::as_str) == Some("sweep-runtime-dirs") {
        let Some(base) = args.get(2) else {
            eprintln!("usage: super-host sweep-runtime-dirs <base-dir>");
            return 2;
        };
        sweep_stale_runtime_dirs(Path::new(base));
        let mut left: Vec<String> = std::fs::read_dir(base)
            .map(|d| {
                d.flatten()
                    .map(|e| e.file_name().to_string_lossy().to_string())
                    .collect()
            })
            .unwrap_or_default();
        left.sort();
        for n in left {
            println!("{n}");
        }
        return 0;
    }

    if args.get(1).map(String::as_str) == Some("carrier-orphan-fixture") {
        let dir = std::env::temp_dir().join("super-orphan-fixture");
        let _ = std::fs::create_dir_all(&dir);
        let Some(fx) = carrier::fixture_path() else {
            eprintln!("no carrier fixture is installed");
            return 1;
        };
        return match carrier::spawn(&fx, &dir, &dir.join("o.log"), "orphan-probe", None) {
            Ok(mut c) => {
                let _ = c.handshake(5_000);
                println!("{} {}", c.pid, c.starttime.unwrap_or(0));
                use std::io::Write as _;
                let _ = std::io::stdout().flush();
                // Forgotten deliberately: the point is to die WITHOUT running
                // cleanup, which is what a SIGKILL of the real host does.
                // `Drop` would reap it and the test would prove nothing.
                std::mem::forget(c);
                loop {
                    std::thread::park()
                }
            }
            Err(e) => {
                eprintln!("{e}");
                1
            }
        };
    }

    if !ampd_dir.join("mix.exs").exists() {
        eprintln!(
            "no ampd/ at {} — run from the release root, or set AMPD_DIR",
            ampd_dir.display()
        );
        return 2;
    }

    let code = match args.get(1).map(String::as_str) {
        Some("verify") => verify::run(&ampd_dir),
        Some("run") | None => run_host(&ampd_dir, args.iter().skip(2).cloned().collect()),
        Some("world") => {
            println!("{}", WorldDir::product("default").path().display());
            0
        }
        Some(other) => {
            eprintln!(
                "usage: super-host [verify | run <actor> [-- <command>...] | effect | identity | carrier-orphan-fixture]"
            );
            eprintln!("  unknown subcommand: {other}");
            2
        }
    };

    code
}

// ================================================================== run
fn run_host(ampd_dir: &Path, rest: Vec<String>) -> i32 {
    let world = WorldDir::product(&std::env::var("SUPER_WORLD").unwrap_or_else(|_| "default".into()));
    println!("[&] Super host");
    println!("  world            {}", world.path().display());

    let rt = match Runtime::start(ampd_dir, world) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("could not start the runtime: {e}");
            return 1;
        }
    };

    let human = match rt.control_channel() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{e}");
            rt.shutdown();
            return 1;
        }
    };

    println!("  bridge           inherited descriptor (no path)");
    println!("  control channel  active");

    // **The effect channel, before any engine exists.** Same ordering
    // reason the control channel is taken first: the mechanism the runtime
    // will reach for must be possessed before anything can ask for an
    // effect, or the first request finds no endpoint and is correctly
    // refused for a reason that is really a startup race.
    //
    // A host that cannot serve effects still runs. It says so, and the
    // runtime refuses effects by name rather than falling back to
    // resolving an executable — which is the property this whole slice
    // exists to install, and it must hold on the degraded path too.
    match rt.effect_channel() {
        Ok(fd) => {
            std::thread::spawn(move || serve_effects(fd));
            println!("  effect channel   active (possessed descriptor, no path)");
        }
        Err(e) => eprintln!("  effect channel   UNAVAILABLE: {e}"),
    }

    // Same degraded-path rule: a host that cannot serve Carrier starts still
    // runs, and the runtime refuses them by name rather than resolving an
    // executable. The property has to hold on the unhappy path or it is not a
    // property.
    let carrier_root = world_dir_for_carriers();
    match rt.carrier_channel() {
        Ok(fd) => {
            std::thread::spawn(move || serve_carrier(fd, carrier_root));
            println!("  carrier channel  active (possessed descriptor, no path)");
        }
        Err(e) => eprintln!("  carrier channel  UNAVAILABLE: {e}"),
    }

    let mut children: Vec<Child> = Vec::new();

    if let Some(split) = rest.iter().position(|a| a == "--") {
        let actor = rest[..split].join("");
        let argv = rest[split + 1..].to_vec();

        if !actor.is_empty() && !argv.is_empty() {
            match rt.agent_fd(&actor) {
                Ok(fd) => {
                    println!("  channel          {actor} → inherited as fd 3");
                    match unsafe {
                        Command::new(&argv[0])
                            .args(&argv[1..])
                            .env("AMPD_CHANNEL_FD", "3")
                            .env("AMPD_ACTOR", &actor)
                            .pre_exec(move || fdpass::dup_onto(fd, 3))
                            .spawn()
                    } {
                        Ok(c) => children.push(c),
                        Err(e) => eprintln!("  could not spawn {actor}: {e}"),
                    }
                    fdpass::close_fd(fd);
                }
                Err(e) => eprintln!("  {e}"),
            }
        }
    }

    let _ = human.call("subscribe", json!({}));
    println!("\n  ctrl-c to stop");

    let mut seen = ProjectionCursor::default();
    loop {
        if human.closed() {
            eprintln!("  control channel closed");
            break;
        }
        if let Some(p) = human.projection_after(&seen, Duration::from_secs(30)) {
            let next = ProjectionCursor::of(&p);
            if next.world_generation != seen.world_generation
                || next.projection_epoch != seen.projection_epoch
            {
                println!("  continuity       world changed — discarding the held projection");
            }
            seen = next;
            println!(
                "  projection       revision {} · epoch {} · generation {}",
                p["revision"], p["projection_epoch"], p["world_generation"]
            );
        }
    }

    for mut c in children {
        let _ = c.kill();
    }
    rt.shutdown();
    0
}

pub mod verify;
