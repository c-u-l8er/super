//! `super-carrier-probe` — the adversarial census, run *as* a Carrier.
//!
//! This is not the Carrier. The Carrier is `super-carrier-fixture` and is
//! deliberately incapable. This binary is its hostile twin: same launch path,
//! same policy, but it spends its life trying to reach things a Carrier must
//! not reach, and prints what happened.
//!
//! # Every attack is run twice and only the difference counts
//!
//! `verify` launches this binary confined and again unconfined, and scores an
//! attack only where the bare run **succeeded** and the confined run failed.
//!
//! The reason is measured, not theoretical. This machine has
//! `kernel.yama.ptrace_scope = 1`, under which `ptrace` and `pidfd_getfd`
//! against a non-descendant already fail with `EPERM` — with no Landlock, no
//! seccomp and no Super. A battery that ran the attack, saw the refusal and
//! reported confinement would be measuring a sysctl that an administrator can
//! set to `0`, and would keep printing green after someone did.
//!
//! That is the same defect D.1.3a closed in the standard-descriptor gate,
//! which called a socket a channel and so answered differently depending on
//! who launched it. Here the answer would depend on a sysctl. The fix has the
//! same shape both times: stop letting the answer depend on something the
//! property does not mention.
//!
//! # Output
//!
//! One line per attack on stdout, which the host has pointed at a log file:
//!
//! ```text
//! <name>\t<ALLOWED|REFUSED>\t<errno>
//! ```
//!
//! `errno` is the raw number, not a message. `130` (`EOWNERDEAD`) is the
//! value Super's seccomp filter returns and nothing else on this path
//! produces, so a refusal that carries it names its own author.

use std::io::Write;

extern "C" {
    fn syscall(num: i64, ...) -> i64;
    fn __errno_location() -> *mut i32;
}

fn errno() -> i32 {
    unsafe { *__errno_location() }
}

fn clear_errno() {
    unsafe { *__errno_location() = 0 }
}

/// Report an attack. `ok` means the operation SUCCEEDED — i.e. the authority
/// was present. A probe that reported "refused" as success would invert every
/// reading downstream.
fn r(name: &str, ok: bool, e: i32) {
    let mut o = std::io::stdout();
    let _ = writeln!(o, "{name}\t{}\t{}", if ok { "ALLOWED" } else { "REFUSED" }, e);
    let _ = o.flush();
}

fn sysc(n: i64, a: i64, b: i64, c: i64) -> (i64, i32) {
    clear_errno();
    let v = unsafe { syscall(n, a, b, c) };
    (v, errno())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let target: i32 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(0);
    let preopen: i32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(-1);
    let workdir = args.get(3).cloned().unwrap_or_else(|| ".".into());

    // 1 · The inherited pre-open. Landlock does not reach a descriptor that
    //     was already open when the domain was installed; this measures it on
    //     the running kernel rather than citing the documentation.
    if preopen >= 0 {
        let mut buf = [0u8; 64];
        let (n, e) = sysc(
            0, /* read */
            preopen as i64,
            buf.as_mut_ptr() as i64,
            buf.len() as i64,
        );
        r("read_inherited_preopen_fd", n > 0, e);
    }

    // 2 · Filesystem reach.
    for (name, path) in [
        ("open_etc_passwd", "/etc/passwd\0"),
        ("open_home_dotfile", "/home/travis/.bashrc\0"),
        ("open_super_source", "/home/travis/ProjectAmp2/super/host/src/lib.rs\0"),
    ] {
        let (fd, e) = sysc(2 /* open */, path.as_ptr() as i64, 0, 0);
        r(name, fd >= 0, e);
        if fd >= 0 {
            sysc(3, fd, 0, 0);
        }
    }
    {
        // The Carrier's own workdir must still work, or the policy is not a
        // policy but a wall.
        let p = format!("{workdir}/probe-wrote-here\0");
        let (fd, e) = sysc(2, p.as_ptr() as i64, 0o101 /* O_WRONLY|O_CREAT */, 0o600);
        r("write_own_workdir", fd >= 0, e);
        if fd >= 0 {
            sysc(3, fd, 0, 0);
        }
    }

    // 3 · The trusted host's own process.
    {
        let p = format!("/proc/{target}/fd\0");
        let (fd, e) = sysc(2, p.as_ptr() as i64, 0o200000 /* O_DIRECTORY */, 0);
        r("open_host_proc_fd_dir", fd >= 0, e);
        if fd >= 0 {
            sysc(3, fd, 0, 0);
        }
    }

    // 4 · Same-UID process theft — the family D.1.3a named as unsolved.
    let (v, e) = sysc(101 /* ptrace */, 16 /* PTRACE_ATTACH */, target as i64, 0);
    r("ptrace_attach_host", v == 0, e);
    if v == 0 {
        sysc(101, 17 /* DETACH */, target as i64, 0);
    }

    let (pfd, e) = sysc(434 /* pidfd_open */, target as i64, 0, 0);
    r("pidfd_open_host", pfd >= 0, e);
    if pfd >= 0 {
        let (st, e2) = sysc(438 /* pidfd_getfd */, pfd, 3, 0);
        r("pidfd_getfd_host_fd3", st >= 0, e2);
        if st >= 0 {
            sysc(3, st, 0, 0);
        }
        sysc(3, pfd, 0, 0);
    } else {
        r("pidfd_getfd_host_fd3", false, e);
    }

    let (v, e) = sysc(62 /* kill */, target as i64, 0, 0);
    r("signal_host", v == 0, e);

    // 5 · Network. ABI 9 has no UDP right, so the UDP row is closed by the
    //     seccomp `socket(2)` clause and not by Landlock — reported
    //     separately so the substitution is legible.
    let (s, e) = sysc(41 /* socket */, 2 /* AF_INET */, 1 /* STREAM */, 0);
    r("socket_inet_tcp", s >= 0, e);
    if s >= 0 {
        sysc(3, s, 0, 0);
    }
    let (s, e) = sysc(41, 2, 2 /* DGRAM */, 0);
    r("socket_inet_udp", s >= 0, e);
    if s >= 0 {
        sysc(3, s, 0, 0);
    }

    // 6 · Privilege-boundary syscalls.
    let (v, e) = sysc(272 /* unshare */, 0x1000_0000 /* CLONE_NEWUSER */, 0, 0);
    r("unshare_user_ns", v == 0, e);
    let (v, e) = sysc(321 /* bpf */, 0, 0, 0);
    r("bpf", v >= 0, e);

    // 7 · Execute something else.
    //
    // Landlock's FS_EXECUTE is granted on this binary and nowhere else, while
    // seccomp deliberately permits `execve` — the Carrier's own exec has to be
    // able to happen, since the filter is installed before it. So this row
    // tests whether the *filesystem* right is what bounds execution.
    //
    // In a child, because a successful `execve` replaces the image and the
    // result line would never be printed — an attack that reports nothing
    // when it succeeds is not a measurement.
    {
        let (pid, _) = sysc(57 /* fork */, 0, 0, 0);
        if pid == 0 {
            let path = b"/usr/bin/id\0";
            let argv = [path.as_ptr(), std::ptr::null()];
            let envp: [*const u8; 1] = [std::ptr::null()];
            sysc(
                59, /* execve */
                path.as_ptr() as i64,
                argv.as_ptr() as i64,
                envp.as_ptr() as i64,
            );
            // Only reached when exec was refused.
            sysc(60 /* exit */, 66, 0, 0);
            unreachable!();
        }
        let mut status: i32 = 0;
        sysc(61 /* wait4 */, pid, &mut status as *mut i32 as i64, 0);
        let exited_66 = (status & 0x7f) == 0 && ((status >> 8) & 0xff) == 66;
        r("execve_other_binary", !exited_66, if exited_66 { 13 } else { 0 });
    }
}
