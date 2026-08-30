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
    control: RawFd,
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
            "landlock_domain_reported": self.landlock_domain,
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
                prepared.install()
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

    let pid = child.id();
    let starttime = observe(pid).starttime;

    Ok(Carrier {
        incarnation: incarnation.to_string(),
        pid,
        starttime,
        child,
        control: ours,
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
        let sock = unsafe { std::fs::File::from_raw_fd(self.control) };
        let mut w = sock
            .try_clone()
            .map_err(|e| format!("carrier control dup: {e}"))?;
        writeln!(w, "HELLO {}", self.incarnation)
            .map_err(|e| format!("carrier hello: {e}"))?;
        w.flush().ok();

        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut line = String::new();
            let _ = BufReader::new(sock).read_line(&mut line);
            let _ = tx.send(line);
        });
        let line = rx
            .recv_timeout(std::time::Duration::from_millis(deadline_ms))
            .map_err(|_| "the carrier did not complete its handshake in time".to_string())?;

        // Leaked deliberately: the reader thread owns the `File` and closing
        // it here would close the control channel out from under a Carrier
        // the host has not decided to stop.
        std::mem::forget(w);

        let line = line.trim();
        let want = format!("READY super-carrier 1 {}", self.incarnation);
        if line != want {
            return Err(format!(
                "carrier handshake mismatch: expected {want:?}, got {line:?}"
            ));
        }
        Ok(line.to_string())
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
        fdpass::close_fd(self.control);
        self.control = -1;
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
