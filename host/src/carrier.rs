//! D.1.3b — spawning a Carrier, and observing what it actually became.
//!
//! # A successful `execve` is not authorization to be a Carrier
//!
//! This module deliberately stops after *observation*. It starts a process,
//! measures it, and reports; it decides nothing. Whether the observed process
//! may commit to `RUNNING` is an authority question, re-derived inside the
//! ordered layer against a world that may have moved while the machine was
//! busy. A host that could promote its own child would be a host deciding
//! product authority, which D.1.3a proved this one does not do and which
//! nothing here may quietly reintroduce.
//!
//! # The census is taken from outside
//!
//! [`observe`] reads `/proc/<pid>/` — descriptors, `status`, `environ`, the
//! Landlock domain — rather than asking the Carrier what it can see. Two
//! reasons, one measured:
//!
//! 1. Under the real policy the fixture **cannot read its own
//!    `/proc/self/fd`** (measured: `EACCES`), so a self-census reports an
//!    error precisely when the policy is working.
//! 2. A self-reported confinement census is `mechanism name ≠ mechanism
//!    possession` wearing a different hat. The process under test is the one
//!    party whose report is not evidence.
//!
//! # The descriptor table is exact, not approximate
//!
//! ```text
//! 0  /dev/null          explicit stdin policy — the fixture reads no input
//! 1  the log file       explicit output
//! 2  the log file       explicit error
//! 3  control channel    the Carrier's one privileged possession
//! ```
//!
//! and nothing else. Not "roughly four descriptors": [`observe`] returns the
//! resolved target of every open descriptor and `verify` asserts the set.
//! Everything the host holds is `SOCK_CLOEXEC` or `O_CLOEXEC` by
//! construction, so the allowlist is enforced by the kernel at `exec` rather
//! than by a loop that must remember to run.

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::os::fd::{FromRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

use crate::confine::{self, Policy, Prepared};
use crate::fdpass;

/// A live Carrier process, from the host's side.
///
/// `incarnation` is semantic identity and is minted by the caller. `pid` and
/// `starttime` are *embodiment observations* and are deliberately separate
/// fields: the same Worker at the same Locus may be embodied by process A and
/// later by process B, and confusing OS-process continuity with assignment
/// continuity is the D.1.1 error in a new setting.
pub struct Carrier {
    pub incarnation: String,
    pub pid: u32,
    pub starttime: Option<u64>,
    child: Child,
    /// The host's end of the control channel, **owned**.
    ///
    /// This was a `RawFd` and the handshake was a descriptor-lifetime bug that
    /// source review caught and no gate did. The old shape did
    /// `File::from_raw_fd(self.control)` — which *transfers ownership of the
    /// number* — handed the `File` to a reader thread, `try_clone()`d a second
    /// descriptor for writing, and then `mem::forget`ed the clone to stop it
    /// closing. Three consequences, all silent:
    ///
    /// 1. the reader thread dropped its `File` after one line, closing the
    ///    original descriptor;
    /// 2. the forgotten clone leaked, one per successful handshake;
    /// 3. `self.control` still held the **closed** number, so `terminate`'s
    ///    `close(self.control)` could close whatever the kernel had since
    ///    handed that number to.
    ///
    /// The third is the one that makes this more than a leak: a
    /// close-the-wrong-thing bug in the process that owns every privileged
    /// descriptor in the host.
    ///
    /// An `Option<UnixStream>` fixes all three by construction. There is one
    /// owner, `Drop` closes it exactly once, `None` is how "already closed" is
    /// represented, and no number outlives the object that owned it.
    control: Option<UnixStream>,
    control_inode: Option<u64>,
    configured: serde_json::Value,
}

/// Everything the host measured about a started Carrier.
///
/// Every field answers "what did the kernel say", never "what did the source
/// say". `configured` and `observed` are reported side by side and are never
/// merged, because the gap between them is the only thing worth reading.
#[derive(Debug)]
pub struct Observed {
    pub fds: BTreeMap<i32, String>,
    pub uid: Option<u32>,
    pub gid: Option<u32>,
    pub groups: Vec<u32>,
    pub no_new_privs: Option<bool>,
    pub seccomp_mode: Option<u32>,
    pub seccomp_filters: Option<u32>,
    pub landlock_domain: bool,
    pub ppid: Option<u32>,
    pub env_keys: Vec<String>,
    pub cwd: Option<String>,
    pub exe: Option<String>,
    pub starttime: Option<u64>,
}

fn proc_field(pid: u32, file: &str, key: &str) -> Option<String> {
    let s = std::fs::read_to_string(format!("/proc/{pid}/{file}")).ok()?;
    for line in s.lines() {
        if let Some(v) = line.strip_prefix(key) {
            return Some(v.trim().to_string());
        }
    }
    None
}

/// Read `/proc/<pid>/` from the trusted side.
///
/// Absent fields stay `None` rather than defaulting. A `false` invented for a
/// field the host could not read would be indistinguishable from a measured
/// `false`, and the direction of that error is the wrong one: it would report
/// confinement as absent when it might be present, or — worse, if the default
/// went the other way — present when it is not.
pub fn observe(pid: u32) -> Observed {
    let mut fds = BTreeMap::new();
    if let Ok(rd) = std::fs::read_dir(format!("/proc/{pid}/fd")) {
        for e in rd.flatten() {
            if let Ok(n) = e.file_name().to_string_lossy().parse::<i32>() {
                let t = std::fs::read_link(e.path())
                    .map(|p| p.to_string_lossy().into_owned())
                    .unwrap_or_else(|_| "<unreadable>".into());
                fds.insert(n, t);
            }
        }
    }

    let first_num = |s: Option<String>| -> Option<u32> {
        s.and_then(|v| v.split_whitespace().next()?.parse().ok())
    };

    let groups = proc_field(pid, "status", "Groups:")
        .map(|v| v.split_whitespace().filter_map(|g| g.parse().ok()).collect())
        .unwrap_or_default();

    // A Landlock domain shows up as a non-zero id in `/proc/<pid>/status`
    // on kernels that report it. Its absence is not proof of no domain, so
    // `verify` never rests a claim on this field alone — the attributable
    // evidence is the confined-versus-bare behavioural difference.
    // **Measured: this kernel exposes no Landlock field anywhere.** Not in
    // `/proc/<pid>/status`, not in `/proc/<pid>/attr/`. So a Landlock domain
    // is not observable from outside the process that is in it, and the
    // previous version of this code read a key that never exists and
    // therefore always answered `false`.
    //
    // That forces a classification rather than allowing one. Landlock is
    // **host-attested**: the host built the ruleset and called
    // `landlock_restrict_self`, and its word is the only evidence available
    // in-band. It is not, and must not be reported as, an observation.
    // `super-host verify`'s differential battery is the out-of-band proof
    // that the attestation corresponds to something.
    let landlock_domain = proc_field(pid, "status", "Landlock:")
        .map(|v| !v.is_empty() && v != "0")
        .unwrap_or(false);

    let env_keys = std::fs::read(format!("/proc/{pid}/environ"))
        .map(|b| {
            b.split(|c| *c == 0)
                .filter(|e| !e.is_empty())
                .filter_map(|e| {
                    let s = String::from_utf8_lossy(e);
                    s.split('=').next().map(|k| k.to_string())
                })
                .collect()
        })
        .unwrap_or_default();

    let starttime = std::fs::read_to_string(format!("/proc/{pid}/stat"))
        .ok()
        .and_then(|s| {
            // Field 22 is starttime, but field 2 (comm) may contain spaces
            // and parentheses, so split after the last ')' rather than by
            // whitespace from the beginning.
            let tail = s.rsplit_once(')')?.1;
            tail.split_whitespace().nth(19)?.parse().ok()
        });

    Observed {
        fds,
        uid: first_num(proc_field(pid, "status", "Uid:")),
        gid: first_num(proc_field(pid, "status", "Gid:")),
        groups,
        no_new_privs: proc_field(pid, "status", "NoNewPrivs:").map(|v| v == "1"),
        seccomp_mode: first_num(proc_field(pid, "status", "Seccomp:")),
        seccomp_filters: first_num(proc_field(pid, "status", "Seccomp_filters:")),
        landlock_domain,
        ppid: first_num(proc_field(pid, "status", "PPid:")),
        env_keys,
        cwd: std::fs::read_link(format!("/proc/{pid}/cwd"))
            .ok()
            .map(|p| p.to_string_lossy().into_owned()),
        exe: std::fs::read_link(format!("/proc/{pid}/exe"))
            .ok()
            .map(|p| p.to_string_lossy().into_owned()),
        starttime,
    }
}

impl Observed {
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "schema": "carrier-confinement-observed@1",
            "fds": self.fds.iter()
                       .map(|(k, v)| (k.to_string(), serde_json::Value::from(v.clone())))
                       .collect::<serde_json::Map<String, serde_json::Value>>(),
            "uid": self.uid, "gid": self.gid, "groups": self.groups,
            "no_new_privs": self.no_new_privs,
            "seccomp_mode": self.seccomp_mode,
            "seccomp_filters": self.seccomp_filters,
            // Retained and renamed so nothing reads it as an observation.
            // False on this kernel always; see `observe`.
            "landlock_domain_observable": self.landlock_domain,
            "ppid": self.ppid,
            "env_keys": self.env_keys,
            "cwd": self.cwd, "exe": self.exe,
            "starttime": self.starttime,
        })
    }
}

/// Start a confined Carrier.
///
/// `log` receives both stdout and stderr. It is a real file rather than
/// `inherit` on purpose: `stdio: inherit` is exactly how the D.1.3a cockpit
/// battery handed a grandchild its own stdout and then read as a hang for
/// eleven minutes. A Carrier's output must not be able to hold a harness's
/// pipe open.
///
/// # Refuses rather than degrades
///
/// If the confinement cannot be built, this returns `Err` and no process is
/// started. There is deliberately no "spawn it anyway and sandbox later"
/// path: the first instruction of Carrier payload code must execute with the
/// restrictions already installed, or there is a window in which ordinary
/// Worker code runs with the host's ambient authority — which is the
/// architectural habit this slice exists to refuse, not merely a risk to
/// mitigate.
pub fn spawn(
    payload: &Path,
    workdir: &Path,
    log: &Path,
    incarnation: &str,
    policy: Option<Policy>,
) -> Result<Carrier, String> {
    spawn_with(payload, workdir, log, incarnation, policy, &[], &[])
}

/// As [`spawn`], plus argv tail and extra inherited descriptors.
///
/// `extra_fds` exists for one purpose and it is adversarial: the
/// inherited-pre-open falsifier needs the host to leak a descriptor it opened
/// *before* the domain existed, so that the battery can show Landlock does
/// not reach it. Every entry widens the descriptor allowlist by exactly one
/// and the census asserts the resulting set, so a leak added here is a leak
/// the gate must then account for by name.
pub fn spawn_with(
    payload: &Path,
    workdir: &Path,
    log: &Path,
    incarnation: &str,
    policy: Option<Policy>,
    args: &[String],
    extra_fds: &[(RawFd, RawFd)],
) -> Result<Carrier, String> {
    let payload_s = payload
        .canonicalize()
        .map_err(|e| format!("carrier payload {}: {e}", payload.display()))?;
    let workdir_s = workdir
        .canonicalize()
        .map_err(|e| format!("carrier workdir {}: {e}", workdir.display()))?;

    let policy = policy.unwrap_or_else(|| {
        Policy::minimal(
            &workdir_s.to_string_lossy(),
            &payload_s.to_string_lossy(),
        )
    });
    let prepared: Prepared = confine::prepare(&policy)?;
    let configured = prepared.configured();

    let fdpass::Pair(ours, theirs) =
        fdpass::pair_stream().map_err(|e| format!("carrier control socketpair: {e}"))?;

    let logf = std::fs::File::create(log).map_err(|e| format!("carrier log {log:?}: {e}"))?;
    let logf2 = logf
        .try_clone()
        .map_err(|e| format!("carrier log dup: {e}"))?;

    let extra: Vec<(RawFd, RawFd)> = extra_fds.to_vec();
    // Read before the fork. `getppid()` inside `pre_exec` answers "who is my
    // parent now", which is the question; this is "who did we mean", which is
    // what it has to be compared against.
    let expected_parent = std::process::id() as i32;
    let child = unsafe {
        Command::new(&payload_s)
            .args(args)
            .current_dir(&workdir_s)
            // **The environment is constructed, not inherited.**
            // `env_clear` first: the host's environment carries
            // `AMPD_BRIDGE_FD`, `AMPD_DATA_DIR`, `SUPER_HOST_BIN` and
            // whatever a developer's shell contributes, and a Carrier that
            // learns a descriptor number from its environment has been told
            // where a privileged endpoint is even if it cannot reach it.
            .env_clear()
            .env("SUPER_CARRIER_INCARNATION", incarnation)
            .env("SUPER_CARRIER_CONTROL_FD", "3")
            .stdin(Stdio::null())
            .stdout(Stdio::from(logf))
            .stderr(Stdio::from(logf2))
            .pre_exec(move || {
                // Order is load-bearing three times over.
                //
                // 1. `ensure_std_fds` before `dup_onto(_, 3)`, for the reason
                //    `fdpass` gives: `dup2` takes the number it is given but
                //    `open` takes the lowest free one, and a control channel
                //    that landed on fd 1 would be a channel the payload
                //    writes its logs into.
                // 2. The descriptor placement before the confinement, because
                //    Landlock does not reach an already-open descriptor and
                //    `install` is the last thing that happens.
                // 3. `install` last of all, so nothing between it and `exec`
                //    needs an authority the policy denies.
                fdpass::ensure_std_fds()?;
                fdpass::dup_onto(theirs, 3)?;
                for (from, to) in extra.iter() {
                    fdpass::dup_onto(*from, *to)?;
                }
                prepared.install(expected_parent)
            })
            .spawn()
    }
    .map_err(|e| format!("spawning carrier: {e}"))?;

    // Read before closing, exactly as the bridge does: the child inherited
    // this same open file description, so this inode is the one its control
    // channel will show in `/proc/<pid>/fd`. That is what makes the
    // descriptor census structural rather than a socket count.
    let control_inode = crate::fd_inode_pub(theirs);
    fdpass::close_fd(theirs);

    // SAFETY: `ours` came from `pair_stream()` and this is its first and only
    // owner. From here the descriptor number is never handled again.
    let control = unsafe { UnixStream::from_raw_fd(ours) };

    let pid = child.id();
    let starttime = observe(pid).starttime;

    Ok(Carrier {
        incarnation: incarnation.to_string(),
        pid,
        starttime,
        child,
        control: Some(control),
        control_inode,
        configured,
    })
}

impl Carrier {
    pub fn control_inode(&self) -> Option<u64> {
        self.control_inode
    }

    pub fn configured(&self) -> &serde_json::Value {
        &self.configured
    }

    /// Speak first, and require the Carrier to echo back the incarnation the
    /// host minted.
    ///
    /// A Carrier that answered `READY` without the incarnation would be
    /// proving only that *something* is on the other end of fd 3. Echoing a
    /// value the host chose is what makes the handshake evidence that this
    /// process is this incarnation — the same reason D.1.3a's channel epoch
    /// is minted host-side from `/dev/urandom` rather than chosen by the
    /// runtime.
    pub fn handshake(&mut self, deadline_ms: u64) -> Result<String, String> {
        // No dup, no thread, no `forget`. `impl Read for &UnixStream` and
        // `impl Write for &UnixStream` let both directions borrow the one
        // owned endpoint, and `set_read_timeout` supplies the deadline that
        // used to need a thread and a channel. The bug the old shape had was
        // not in any one of those three devices; it was in there being three.
        let sock = self
            .control
            .as_ref()
            .ok_or_else(|| "the carrier control endpoint is already closed".to_string())?;

        sock.set_read_timeout(Some(std::time::Duration::from_millis(deadline_ms)))
            .map_err(|e| format!("carrier control deadline: {e}"))?;

        let mut w = sock;
        writeln!(w, "HELLO {}", self.incarnation).map_err(|e| format!("carrier hello: {e}"))?;
        w.flush().ok();

        let mut line = String::new();
        BufReader::new(sock)
            .read_line(&mut line)
            .map_err(|e| format!("the carrier did not complete its handshake in time: {e}"))?;

        // Back to blocking: the deadline governed the handshake, and a
        // timeout left on the endpoint would silently bound every later read.
        let _ = sock.set_read_timeout(None);

        let line = line.trim();
        let want = format!("READY super-carrier 1 {}", self.incarnation);
        if line != want {
            return Err(format!(
                "carrier handshake mismatch: expected {want:?}, got {line:?}"
            ));
        }
        Ok(line.to_string())
    }

    /// Send one verb and read one line. Proves the control endpoint is live
    /// in both directions after the handshake, which the old raw-fd shape
    /// could not have survived — the reader thread had already closed it.
    pub fn speak(&mut self, verb: &str, deadline_ms: u64) -> Result<String, String> {
        let sock = self
            .control
            .as_ref()
            .ok_or_else(|| "the carrier control endpoint is closed".to_string())?;
        sock.set_read_timeout(Some(std::time::Duration::from_millis(deadline_ms)))
            .map_err(|e| e.to_string())?;
        let mut w = sock;
        writeln!(w, "{verb}").map_err(|e| e.to_string())?;
        w.flush().ok();
        let mut line = String::new();
        BufReader::new(sock).read_line(&mut line).map_err(|e| e.to_string())?;
        let _ = sock.set_read_timeout(None);
        Ok(line.trim().to_string())
    }

    pub fn observe(&self) -> Observed {
        observe(self.pid)
    }

    /// Is this still the process the host started?
    ///
    /// pid alone is not identity — pids are reused, and a Carrier that died
    /// and let its number be taken by something else would otherwise read as
    /// alive. `starttime` from `/proc/<pid>/stat` makes the pair unique for
    /// as long as anyone cares.
    pub fn same_process(&self) -> bool {
        match (self.starttime, observe(self.pid).starttime) {
            (Some(a), Some(b)) => a == b,
            _ => false,
        }
    }

    /// SIGTERM, awaited, then SIGKILL.
    ///
    /// A `kill` that returns is not a dead process — the harness lesson from
    /// D.1.3a, applied here to the thing the harness was measuring.
    pub fn terminate(&mut self, grace_ms: u64) -> bool {
        // Dropping the stream closes it exactly once. `take()` makes the
        // second call a no-op rather than a double close — which is the
        // whole reason the field is an `Option` and not a number that has to
        // be remembered to be invalid.
        drop(self.control.take());
        unsafe { libc_kill(self.pid as i32, 15) };
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(grace_ms);
        while std::time::Instant::now() < deadline {
            if let Ok(Some(_)) = self.child.try_wait() {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        false
    }
}

extern "C" {
    #[link_name = "kill"]
    fn libc_kill(pid: i32, sig: i32) -> i32;
}

impl Drop for Carrier {
    /// A dropped Carrier is not an orphan.
    ///
    /// `serve_carrier` reaps its map when its channel closes, but a `Carrier`
    /// dropped on any other path — an error return between spawn and
    /// handshake, a panic, a `HashMap` overwrite — would previously have left
    /// a live process with no owner and no record. `Drop` is the one place
    /// every such path converges, which is the argument `Ampd.Peer.drop/2`
    /// makes for putting the attachment release there rather than at the call
    /// sites.
    fn drop(&mut self) {
        if self.control.is_some() || self.child.try_wait().ok().flatten().is_none() {
            self.terminate(1_000);
        }
    }
}

/// Where the fixture lives, relative to the host binary.
///
/// Resolved from `/proc/self/exe` rather than `$PATH`, because "the Carrier
/// payload is whatever `PATH` says `super-carrier-fixture` means" is the
/// property D.1.3a removed one layer up and would be strange to reintroduce
/// here.
pub fn fixture_path() -> Option<PathBuf> {
    let exe = std::fs::read_link("/proc/self/exe").ok()?;
    let dir = exe.parent()?;
    for c in [
        dir.join("super-carrier-fixture"),
        dir.join("../../../carrier-fixture/target/release/super-carrier-fixture"),
    ] {
        if c.is_file() {
            return c.canonicalize().ok();
        }
    }
    None
}
