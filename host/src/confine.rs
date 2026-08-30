//! D.1.3b — the confinement floor a Carrier is born inside.
//!
//! D.1.3a proved that possessing a mechanism endpoint is not the same as
//! knowing its name. That is an *addressing* property and it says nothing
//! about what a process can reach once it is running. This module is the
//! other half: what a Carrier may touch, asked of the kernel rather than of
//! the Carrier.
//!
//! # No single row earns the word "confined"
//!
//! ```text
//! descriptor closure  ∧  no_new_privs  ∧  Landlock  ∧  seccomp
//!                     ∧  process relationship  ∧  explicit environment
//! ```
//!
//! Each is partial. Landlock does not reach an already-open descriptor;
//! seccomp does not know what a path means; `no_new_privs` alone stops only
//! privilege *escalation*. The profile this module emits reports each row
//! separately for that reason, and the word "confined" appears nowhere in it.
//!
//! # Two measured facts decide the shape of this file
//!
//! **1 · The ruleset is built before `fork`, installed after it.**
//! `pre_exec` runs between `fork` and `exec` in a process that may have been
//! multi-threaded, so only async-signal-safe calls are legal there —
//! `landlock_add_rule` needs `open(O_PATH)` per granted path and the seccomp
//! program needs a heap allocation. Both happen in the parent. What crosses
//! the fork is a descriptor and a pointer, and what runs in the child is
//! three raw syscalls with arguments that were computed before it existed.
//! The ruleset is therefore *a possessed descriptor* — which is D.1.3a's
//! doctrine arriving in the confinement layer without being asked to.
//!
//! **2 · A statically linked payload needs execute on one inode; a
//! dynamically linked one needs it on `/usr/lib`.** Measured on this kernel:
//! granting `LANDLOCK_ACCESS_FS_EXECUTE` on a dynamic binary alone yields
//! `EACCES` at `execve`, because the loader must map `ld-linux` and `libc`.
//! Granting `/usr/lib` back makes every shared object on the machine
//! executable, which is most of what the policy was for. So the Carrier
//! fixture is static-pie and the execute grant names exactly its own file.
//!
//! # The distinctive errno
//!
//! This machine has `yama/ptrace_scope = 1`, so `ptrace` and `pidfd_getfd`
//! against a non-descendant already fail with `EPERM` for a reason Super did
//! not create. A battery that ran the attack, saw `EPERM` and called it
//! confinement would be measuring a sysctl. The filter therefore refuses with
//! `EOWNERDEAD` — an errno no ptrace path produces — so a refusal names its
//! author. `verify` additionally runs every attack twice, confined and bare,
//! and only counts a refusal that the bare control did not also produce.
//!
//! # What this module does not do
//!
//! No namespaces, no chroot, no uid change, no cgroup. Those are separate
//! mechanism classes and each would move the WEK census on its own; none is
//! needed for a deterministic fixture that opens nothing. They are named here
//! so their absence is a decision rather than an oversight.

use std::ffi::CString;
use std::io;
use std::os::unix::io::RawFd;
use std::path::Path;

// ---------------------------------------------------------------- syscalls
//
// Declared here rather than pulled in, for the reason `fdpass.rs` gives: the
// host has exactly one declared dependency and a confinement slice is a poor
// reason to make it two. `landlock` and `seccompiler` are both good crates;
// neither is worth the census movement for six syscalls.

extern "C" {
    fn syscall(num: i64, ...) -> i64;
    fn prctl(option: i32, a2: u64, a3: u64, a4: u64, a5: u64) -> i32;
    // Signature matches `fdpass.rs`'s declaration exactly. Two `extern`
    // blocks describing the same symbol differently is a warning today and a
    // calling-convention bug the day one of them changes.
    fn open(path: *const u8, flags: i32, mode: i32) -> i32;
    fn close(fd: i32) -> i32;
    fn fcntl(fd: i32, cmd: i32, arg: i32) -> i32;
}

const F_DUPFD_CLOEXEC: i32 = 1030;

/// The ruleset descriptor is moved above every number the Carrier's
/// descriptor allowlist can name.
///
/// **Found by running it.** The ruleset is created in the parent and taken
/// through `fork` to be installed in the child — but it is allocated by the
/// kernel at the lowest free number, which in a host holding only 0/1/2 is
/// **3**, and 3 is where `dup_onto` places the Carrier's control channel. The
/// control channel therefore landed on top of the ruleset, and
/// `landlock_restrict_self` was handed a socket: `EBADFD`, from inside
/// `pre_exec`, reported as a spawn failure with nothing pointing at Landlock.
///
/// The general statement is worth keeping: **the confinement's own
/// descriptor is subject to the descriptor policy it is installing.** Any
/// host-side descriptor that must survive into `pre_exec` has to live above
/// the allowlist, or the allowlist will overwrite the thing enforcing it.
const RULESET_FD_FLOOR: i32 = 64;

fn relocate_above_allowlist(fd: i32) -> Result<i32, String> {
    let hi = unsafe { fcntl(fd, F_DUPFD_CLOEXEC, RULESET_FD_FLOOR) };
    if hi < 0 {
        let e = io::Error::last_os_error();
        unsafe { close(fd) };
        return Err(format!("relocating the ruleset descriptor: {e}"));
    }
    unsafe { close(fd) };
    Ok(hi)
}

const SYS_LANDLOCK_CREATE_RULESET: i64 = 444;
const SYS_LANDLOCK_ADD_RULE: i64 = 445;
const SYS_LANDLOCK_RESTRICT_SELF: i64 = 446;
const SYS_SECCOMP: i64 = 317;

const PR_SET_NO_NEW_PRIVS: i32 = 38;
const PR_GET_NO_NEW_PRIVS: i32 = 39;

const O_PATH: i32 = 0o10000000;
const O_CLOEXEC: i32 = 0o2000000;

const LANDLOCK_CREATE_RULESET_VERSION: u32 = 1 << 0;
const LANDLOCK_RULE_PATH_BENEATH: i32 = 1;

const SECCOMP_SET_MODE_FILTER: i64 = 1;

/// The errno a Super filter refuses with.
///
/// Chosen because no ptrace, LSM or DAC path returns it, so
/// `strerror` reading "Owner died" on a denied `ptrace` is proof that this
/// filter refused rather than `yama`. Attribution is the whole point; see the
/// module header.
pub const SUPER_DENY_ERRNO: u32 = 130; // EOWNERDEAD

// ------------------------------------------------------------ landlock ABI

/// Filesystem access rights, by the ABI that introduced each.
///
/// Bit 16 (`RESOLVE_UNIX`) is ABI 9. Nothing above it exists on this kernel:
/// `LANDLOCK_ACCESS_NET_BIND_UDP` and `CONNECT_SEND_UDP` are ABI 10 and are
/// **absent from `/usr/include/linux/landlock.h` here**. UDP egress is
/// therefore not governable by Landlock on this machine and is closed by the
/// seccomp `socket(2)` clause instead — a substitution, not an equivalence,
/// and reported as such in the profile.
mod fs {
    pub const EXECUTE: u64 = 1 << 0;
    pub const WRITE_FILE: u64 = 1 << 1;
    pub const READ_FILE: u64 = 1 << 2;
    pub const READ_DIR: u64 = 1 << 3;
    pub const REMOVE_DIR: u64 = 1 << 4;
    pub const REMOVE_FILE: u64 = 1 << 5;
    pub const MAKE_CHAR: u64 = 1 << 6;
    pub const MAKE_DIR: u64 = 1 << 7;
    pub const MAKE_REG: u64 = 1 << 8;
    pub const MAKE_SOCK: u64 = 1 << 9;
    pub const MAKE_FIFO: u64 = 1 << 10;
    pub const MAKE_BLOCK: u64 = 1 << 11;
    pub const MAKE_SYM: u64 = 1 << 12;
    pub const REFER: u64 = 1 << 13; // ABI 2
    pub const TRUNCATE: u64 = 1 << 14; // ABI 3
    pub const IOCTL_DEV: u64 = 1 << 15; // ABI 5
    pub const RESOLVE_UNIX: u64 = 1 << 16; // ABI 9
}

mod net {
    pub const BIND_TCP: u64 = 1 << 0; // ABI 4
    pub const CONNECT_TCP: u64 = 1 << 1; // ABI 4
}

mod scope {
    pub const ABSTRACT_UNIX_SOCKET: u64 = 1 << 0; // ABI 6
    pub const SIGNAL: u64 = 1 << 1; // ABI 6
}

/// The handled-access set for a given ABI, built by *removing* what the
/// running kernel cannot express rather than by assuming what it can.
///
/// Landlock's own documentation calls this best-effort, and the failure mode
/// it prevents is specific: a `handled_access_fs` containing a bit the kernel
/// does not know makes `landlock_create_ruleset` return `EINVAL`, so a policy
/// written for a newer kernel does not degrade — it does not install at all,
/// and a caller that ignored the error would run the payload unconfined.
fn handled_for(abi: i32) -> (u64, u64, u64) {
    let mut f = fs::EXECUTE
        | fs::WRITE_FILE
        | fs::READ_FILE
        | fs::READ_DIR
        | fs::REMOVE_DIR
        | fs::REMOVE_FILE
        | fs::MAKE_CHAR
        | fs::MAKE_DIR
        | fs::MAKE_REG
        | fs::MAKE_SOCK
        | fs::MAKE_FIFO
        | fs::MAKE_BLOCK
        | fs::MAKE_SYM;
    let mut n = 0u64;
    let mut s = 0u64;

    if abi >= 2 {
        f |= fs::REFER;
    }
    if abi >= 3 {
        f |= fs::TRUNCATE;
    }
    if abi >= 4 {
        n |= net::BIND_TCP | net::CONNECT_TCP;
    }
    if abi >= 5 {
        f |= fs::IOCTL_DEV;
    }
    if abi >= 6 {
        s |= scope::ABSTRACT_UNIX_SOCKET | scope::SIGNAL;
    }
    if abi >= 9 {
        f |= fs::RESOLVE_UNIX;
    }
    (f, n, s)
}

#[repr(C)]
struct RulesetAttr {
    handled_access_fs: u64,
    handled_access_net: u64,
    scoped: u64,
}

#[repr(C)]
struct PathBeneathAttr {
    allowed_access: u64,
    parent_fd: i32,
}

/// The Landlock ABI this kernel supports, or `None` if Landlock is absent.
///
/// Read from the kernel every time rather than cached at build: a host binary
/// outlives the kernel it was compiled against, and a hard-coded ABI is the
/// assumption this function exists to refuse.
pub fn landlock_abi() -> Option<i32> {
    let v = unsafe {
        syscall(
            SYS_LANDLOCK_CREATE_RULESET,
            std::ptr::null::<RulesetAttr>(),
            0usize,
            LANDLOCK_CREATE_RULESET_VERSION as u64,
        )
    };
    if v > 0 {
        Some(v as i32)
    } else {
        None
    }
}

/// Is `no_new_privs` set on the calling process?
pub fn no_new_privs_set() -> bool {
    unsafe { prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) == 1 }
}

// ----------------------------------------------------------------- policy

/// What a Carrier is allowed to reach, stated as data.
///
/// Every field is an allowlist. There is no `deny` list and no wildcard,
/// because a policy that can be widened by adding a string is a policy whose
/// author is whoever can add strings.
pub struct Policy {
    /// Read + write + create, no execute. Normally exactly the Carrier's own
    /// working directory.
    pub rw_dirs: Vec<String>,
    /// Read only.
    pub ro_dirs: Vec<String>,
    /// Execute + read, granted per *file*. Static-pie payloads make this one
    /// entry; see the module header.
    pub exec_files: Vec<String>,
    /// TCP/UDP reachability. `false` is the only value a deterministic
    /// fixture should ever be given.
    pub network: bool,
}

impl Policy {
    /// The floor: one writable directory, one executable file, no network.
    pub fn minimal(workdir: &str, payload: &str) -> Policy {
        Policy {
            rw_dirs: vec![workdir.to_string()],
            ro_dirs: vec![],
            exec_files: vec![payload.to_string()],
            network: false,
        }
    }
}

/// A built, unenforced confinement. Holds the ruleset descriptor and the BPF
/// program; both must outlive the `fork` that installs them.
///
/// `Prepared` is deliberately not `Clone` and not `Copy`: it owns a
/// descriptor, and a second owner is a second disposal path.
pub struct Prepared {
    ruleset: RawFd,
    abi: i32,
    filter: Vec<SockFilter>,
    policy_fs: u64,
    policy_net: u64,
    policy_scope: u64,
    granted: Vec<(String, u64)>,
}

impl Drop for Prepared {
    fn drop(&mut self) {
        if self.ruleset >= 0 {
            unsafe { close(self.ruleset) };
        }
    }
}

fn grant(rs: RawFd, path: &str, access: u64) -> Result<(), String> {
    let c = CString::new(path).map_err(|_| format!("path has a NUL: {path}"))?;
    let fd = unsafe { open(c.as_ptr() as *const u8, O_PATH | O_CLOEXEC, 0) };
    if fd < 0 {
        return Err(format!(
            "cannot open {path} to grant it: {}",
            io::Error::last_os_error()
        ));
    }
    let attr = PathBeneathAttr {
        allowed_access: access,
        parent_fd: fd,
    };
    let rc = unsafe {
        syscall(
            SYS_LANDLOCK_ADD_RULE,
            rs as i64,
            LANDLOCK_RULE_PATH_BENEATH as i64,
            &attr as *const PathBeneathAttr,
            0u32,
        )
    };
    unsafe { close(fd) };
    if rc != 0 {
        return Err(format!(
            "landlock_add_rule({path}): {}",
            io::Error::last_os_error()
        ));
    }
    Ok(())
}

/// Build the ruleset and the filter. Runs in the parent, before `fork`.
///
/// Returns `Err` if Landlock is unavailable or a granted path does not exist.
/// **It does not fall back to an unconfined child.** A Carrier that could not
/// be confined is a Carrier that must not start — the alternative is the
/// unconfined-execution window this slice exists to refuse.
pub fn prepare(policy: &Policy) -> Result<Prepared, String> {
    let abi = landlock_abi().ok_or_else(|| {
        "this kernel reports no Landlock ABI; refusing to start an unconfined Carrier".to_string()
    })?;

    let (hfs, hnet_all, hscope) = handled_for(abi);

    // A right is denied by being *handled* and not granted, so EXECUTE stays
    // in the handled set whether or not any file is granted it — dropping it
    // would permit execution everywhere rather than nowhere.
    //
    // `handled_access_net = 0` is the opposite: it means Landlock governs no
    // network operation at all, which is what `network: true` asks for.
    let hnet = if policy.network { 0 } else { hnet_all };

    let attr = RulesetAttr {
        handled_access_fs: hfs,
        handled_access_net: hnet,
        scoped: hscope,
    };
    let rs = unsafe {
        syscall(
            SYS_LANDLOCK_CREATE_RULESET,
            &attr as *const RulesetAttr,
            std::mem::size_of::<RulesetAttr>() as u64,
            0u64,
        )
    };
    if rs < 0 {
        return Err(format!(
            "landlock_create_ruleset(abi {abi}): {}",
            io::Error::last_os_error()
        ));
    }
    let rs = relocate_above_allowlist(rs as RawFd)?;

    let rw = fs::READ_FILE
        | fs::WRITE_FILE
        | fs::READ_DIR
        | fs::MAKE_REG
        | fs::MAKE_DIR
        | fs::REMOVE_FILE
        | fs::REMOVE_DIR
        | if abi >= 3 { fs::TRUNCATE } else { 0 };
    let ro = fs::READ_FILE | fs::READ_DIR;
    let ex = fs::EXECUTE | fs::READ_FILE;

    // Build the grants into a local first. Any failure closes the ruleset on
    // the way out: a half-built ruleset that leaked its descriptor would be a
    // policy nobody enforces and nobody frees.
    let granted: Vec<(String, u64)>;
    let build = || -> Result<Vec<(String, u64)>, String> {
        let mut g = Vec::new();
        for d in &policy.rw_dirs {
            grant(rs, d, rw)?;
            g.push((d.clone(), rw));
        }
        for d in &policy.ro_dirs {
            grant(rs, d, ro)?;
            g.push((d.clone(), ro));
        }
        for f in &policy.exec_files {
            if !Path::new(f).is_file() {
                return Err(format!("the execute grant names {f}, which is not a file"));
            }
            grant(rs, f, ex)?;
            g.push((f.clone(), ex));
        }
        Ok(g)
    };
    match build() {
        Ok(g) => granted = g,
        Err(e) => {
            unsafe { close(rs) };
            return Err(e);
        }
    }

    Ok(Prepared {
        ruleset: rs,
        abi,
        filter: build_filter(policy.network),
        policy_fs: hfs,
        policy_net: hnet,
        policy_scope: hscope,
        granted,
    })
}

impl Prepared {
    pub fn abi(&self) -> i32 {
        self.abi
    }

    /// The ruleset descriptor, so a gate can assert where it landed.
    ///
    /// Exposed because the collision this guards against is **latent and
    /// depends on host state**: the ruleset is allocated at the lowest free
    /// number, so it lands on fd 3 — the control channel's slot — only in a
    /// host holding few descriptors. Sabotaging the relocation and then
    /// asserting "a Carrier starts" proves nothing under `verify`, where the
    /// host holds many; the battery said so, in those words. Asserting the
    /// *number* is falsifiable whatever the host happens to have open.
    pub fn ruleset_fd(&self) -> RawFd {
        self.ruleset
    }

    /// The floor the ruleset descriptor must sit above.
    pub fn allowlist_ceiling() -> i32 {
        RULESET_FD_FLOOR
    }

    /// The policy as the kernel was asked for it — *configured*, never
    /// *observed*. `carrier::observe` reads the enforced side out of the
    /// child's own `/proc` and the two are reported as separate fields,
    /// because a source file containing the word "landlock" is not evidence
    /// that a domain exists.
    pub fn configured(&self) -> serde_json::Value {
        serde_json::json!({
            "schema": "carrier-confinement-configured@1",
            "landlock_abi": self.abi,
            "handled_access_fs": format!("{:#x}", self.policy_fs),
            "handled_access_net": format!("{:#x}", self.policy_net),
            "scoped": format!("{:#x}", self.policy_scope),
            "grants": self.granted.iter()
                .map(|(p, a)| serde_json::json!({"path": p, "access": format!("{a:#x}")}))
                .collect::<Vec<_>>(),
            "seccomp_filter_insns": self.filter.len(),
            "seccomp_deny_errno": SUPER_DENY_ERRNO,
            "udp_governed_by_landlock": self.abi >= 10,
        })
    }

    /// Install everything, in the child, between `fork` and `exec`.
    ///
    /// **Async-signal-safe: three syscalls and no allocation.** Every
    /// argument was computed before the fork.
    ///
    /// Order is load-bearing and not stylistic. `no_new_privs` must precede
    /// both of the others: `landlock_restrict_self` and
    /// `seccomp(SET_MODE_FILTER)` each refuse with `EACCES` without it unless
    /// the caller has `CAP_SYS_ADMIN`, and a Carrier host that needed
    /// `CAP_SYS_ADMIN` to confine its children would be a worse position than
    /// the one this slice starts from.
    ///
    /// # Safety
    /// Call only from `pre_exec`.
    pub unsafe fn install(&self) -> io::Result<()> {
        if prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0 {
            return Err(io::Error::last_os_error());
        }
        if syscall(SYS_LANDLOCK_RESTRICT_SELF, self.ruleset as i64, 0u32) != 0 {
            return Err(io::Error::last_os_error());
        }
        let prog = SockFprog {
            len: self.filter.len() as u16,
            filter: self.filter.as_ptr(),
        };
        if syscall(
            SYS_SECCOMP,
            SECCOMP_SET_MODE_FILTER,
            0u64,
            &prog as *const SockFprog,
        ) != 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
}

// ----------------------------------------------------------------- seccomp

#[repr(C)]
#[derive(Clone, Copy)]
struct SockFilter {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
}

#[repr(C)]
struct SockFprog {
    len: u16,
    filter: *const SockFilter,
}

const BPF_LD: u16 = 0x00;
const BPF_JMP: u16 = 0x05;
const BPF_RET: u16 = 0x06;
const BPF_W: u16 = 0x00;
const BPF_ABS: u16 = 0x20;
const BPF_JEQ: u16 = 0x10;
const BPF_K: u16 = 0x00;

const SECCOMP_RET_KILL_PROCESS: u32 = 0x8000_0000;
const SECCOMP_RET_ERRNO: u32 = 0x0005_0000;
const SECCOMP_RET_ALLOW: u32 = 0x7fff_0000;
const SECCOMP_RET_DATA: u32 = 0x0000_ffff;

// offsets into `struct seccomp_data`
const OFF_NR: u32 = 0;
const OFF_ARCH: u32 = 4;
const OFF_ARG0: u32 = 16;

const AUDIT_ARCH_X86_64: u32 = 0xc000_003e;

const AF_UNIX: u32 = 1;

/// Syscalls a Carrier is refused, by number on x86-64.
///
/// The list is the process-introspection and privilege-boundary family, not
/// an attempt at a general policy. A deterministic fixture that opens nothing
/// could be allowed far less than this; the eventual Motor profile will need
/// its own and is explicitly not designed here.
///
/// **`execve` is not on this list, and that is deliberate.** The filter is
/// installed in `pre_exec`, so the payload's own `execve` has not happened
/// yet — denying it would kill every Carrier at birth. What bounds execution
/// is Landlock's `FS_EXECUTE` right, granted on the payload file and nowhere
/// else. Measured: an unlisted binary then fails `execve` with `EACCES`.
const DENIED: &[u32] = &[
    101, // ptrace
    434, // pidfd_open
    438, // pidfd_getfd
    310, // process_vm_readv
    311, // process_vm_writev
    62,  // kill
    424, // pidfd_send_signal
    234, // tgkill
    272, // unshare
    308, // setns
    165, // mount
    166, // umount2
    155, // pivot_root
    161, // chroot
    248, // add_key
    250, // keyctl
    321, // bpf
    298, // perf_event_open
    139, // sysfs
    175, // init_module
    313, // finit_module
    176, // delete_module
];

fn stmt(code: u16, k: u32) -> SockFilter {
    SockFilter {
        code,
        jt: 0,
        jf: 0,
        k,
    }
}
fn jump(code: u16, k: u32, jt: u8, jf: u8) -> SockFilter {
    SockFilter { code, jt, jf, k }
}

/// Build the classic-BPF program.
///
/// The architecture check comes first and kills rather than refuses: on a
/// mismatch the syscall *numbers* mean something else, so every comparison
/// below it would be reading a different table. A filter that answers the
/// wrong question politely is worse than one that stops.
fn build_filter(allow_network: bool) -> Vec<SockFilter> {
    let deny = SECCOMP_RET_ERRNO | (SUPER_DENY_ERRNO & SECCOMP_RET_DATA);
    let mut f = vec![
        stmt(BPF_LD | BPF_W | BPF_ABS, OFF_ARCH),
        jump(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 1, 0),
        stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
        stmt(BPF_LD | BPF_W | BPF_ABS, OFF_NR),
    ];
    for nr in DENIED {
        f.push(jump(BPF_JMP | BPF_JEQ | BPF_K, *nr, 0, 1));
        f.push(stmt(BPF_RET | BPF_K, deny));
    }

    // ABI 9 has no UDP right, so the network policy cannot be completed in
    // Landlock on this kernel. Close the family at `socket(2)` instead:
    // AF_UNIX is permitted, everything else refused. This is coarser than a
    // port rule and is reported as a substitution, not as UDP restriction.
    if !allow_network {
        f.push(jump(BPF_JMP | BPF_JEQ | BPF_K, 41 /* socket */, 0, 3));
        f.push(stmt(BPF_LD | BPF_W | BPF_ABS, OFF_ARG0));
        f.push(jump(BPF_JMP | BPF_JEQ | BPF_K, AF_UNIX, 1, 0));
        f.push(stmt(BPF_RET | BPF_K, deny));
        // Fall through for AF_UNIX; reload nr so a later clause could read it.
        f.push(stmt(BPF_LD | BPF_W | BPF_ABS, OFF_NR));
    }

    f.push(stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW));
    f
}
