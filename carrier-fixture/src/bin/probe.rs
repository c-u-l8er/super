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
//! # Not trying something is not evidence that it is closed
//!
//! A review of the first version made the objection this file's second half
//! exists to answer: *the minimal fixture's inability to exploit something is
//! not evidence that the syscall isn't available.* It is not. A Carrier that
//! opens no files says nothing about `memfd_create`, and a deny list nobody
//! calls is a list of intentions.
//!
//! So every syscall the policy claims to refuse is **called here**, with
//! arguments chosen so the unconfined control *succeeds* wherever the host
//! will let it — because a probe that fails for its own reasons grades as a
//! refusal and inflates the result. Three grades come out, and they are not
//! interchangeable; `verify` names which one each row earned.
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

/// Six arguments, always, with explicit zeros where the syscall takes fewer.
///
/// `syscall(3)` is variadic in its declaration and **fixed in its
/// implementation**: glibc's stub moves six registers whatever the caller
/// passed, so a three-argument call hands the kernel whatever the previous
/// call happened to leave in `r10`, `r8` and `r9`. That is harmless for
/// `open` and `ptrace`, which ignore the tail. It is not harmless for
/// `mount`, `perf_event_open` or `process_vm_readv`, whose fourth through
/// sixth arguments are exactly the ones that decide whether the **bare
/// control** succeeds — and a bare control that fails on register litter
/// grades its row AMBIENT-PRECLUDED and quietly weakens the census.
fn sysc6(n: i64, a: i64, b: i64, c: i64, d: i64, e: i64, f: i64) -> (i64, i32) {
    clear_errno();
    let v = unsafe { syscall(n, a, b, c, d, e, f) };
    (v, errno())
}

fn sysc(n: i64, a: i64, b: i64, c: i64) -> (i64, i32) {
    sysc6(n, a, b, c, 0, 0, 0)
}

// -------------------------------------------------------------- ABI layouts
//
// Hand-declared, like every syscall here, and each one carries the size the
// kernel is told. The kernel decides what these structs *mean* from that
// size: `clone3` and `perf_event_open` both refuse a size they do not
// recognise and both accept a short one by zero-filling the remainder. A
// probe that guessed would be reporting an argument error as a refusal, which
// is the failure mode this whole section exists to remove.

/// `struct clone_args` at `CLONE_ARGS_SIZE_VER2` — 88 bytes.
#[repr(C)]
#[derive(Default)]
struct CloneArgs {
    flags: u64,
    pidfd: u64,
    child_tid: u64,
    parent_tid: u64,
    exit_signal: u64,
    stack: u64,
    stack_size: u64,
    tls: u64,
    set_tid: u64,
    set_tid_size: u64,
    cgroup: u64,
}

/// `struct perf_event_attr`, declared at 128 bytes.
///
/// The kernel's own is larger; anything from 64 bytes up is accepted as long
/// as the tail is zero, which `tail` guarantees by construction.
#[repr(C)]
struct PerfAttr {
    kind: u32,
    size: u32,
    config: u64,
    sample: u64,
    sample_type: u64,
    read_format: u64,
    /// The bitfield word at offset 40: bit 0 `disabled`, 1 `inherit`,
    /// 5 `exclude_kernel`, 6 `exclude_hv`.
    flags: u64,
    tail: [u8; 80],
}

/// `union bpf_attr` as `BPF_MAP_CREATE` reads it — 72 bytes.
#[repr(C)]
struct BpfMapAttr {
    map_type: u32,
    key_size: u32,
    value_size: u32,
    max_entries: u32,
    tail: [u8; 56],
}

/// `struct iovec`.
#[repr(C)]
struct Iov {
    base: *mut u8,
    len: usize,
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

    // 6b · Process creation.
    //
    // Every one of these makes a real process in the bare control, so every
    // one of them must clean up after itself: the child's entire life is
    // `_exit(0)` and this side reaps it before printing. A probe that leaves
    // work in a forked child is a probe that can leave a process behind, and
    // a probe that forks in a loop is a fork bomb with a changelog entry.
    let fork_works = {
        let (pid, e) = sysc(57 /* fork */, 0, 0, 0);
        if pid == 0 {
            sysc(60 /* exit */, 0, 0, 0);
            unreachable!();
        }
        if pid > 0 {
            let mut status: i32 = 0;
            sysc(61 /* wait4 */, pid, &mut status as *mut i32 as i64, 0);
        }
        r("fork", pid > 0, e);
        pid > 0
    };

    {
        // `clone` **without** `CLONE_VM`: the child gets its own address
        // space, which makes this exactly as safe as the `fork` above and
        // specifically not the shared-stack hazard `vfork` is.
        let (pid, e) = sysc6(56 /* clone */, 17 /* SIGCHLD */, 0, 0, 0, 0, 0);
        if pid == 0 {
            sysc(60, 0, 0, 0);
            unreachable!();
        }
        if pid > 0 {
            let mut status: i32 = 0;
            sysc(61, pid, &mut status as *mut i32 as i64, 0);
        }
        r("clone", pid > 0, e);
    }

    {
        let ca = CloneArgs {
            exit_signal: 17, // SIGCHLD
            ..Default::default()
        };
        let (pid, e) = sysc(
            435, /* clone3 */
            &ca as *const CloneArgs as i64,
            std::mem::size_of::<CloneArgs>() as i64,
            0,
        );
        if pid == 0 {
            sysc(60, 0, 0, 0);
            unreachable!();
        }
        if pid > 0 {
            let mut status: i32 = 0;
            sysc(61, pid, &mut status as *mut i32 as i64, 0);
        }
        r("clone3", pid > 0, e);
    }

    // `vfork` is not here. It is the last thing this probe does, and the
    // reason is measured — see the end of `main`.

    // 6c · Anonymous execution.
    //
    // `memfd_create` makes a file with no name on any filesystem. Paired with
    // `execveat` it is a complete execution path that never presents a
    // pathname — and Landlock's entire vocabulary is pathnames, so the
    // `FS_EXECUTE` grant that bounds `execve` has nothing to say about it.
    {
        let name = b"super-carrier-probe\0";
        let (fd, e) = sysc(319 /* memfd_create */, name.as_ptr() as i64, 0, 0);
        r("memfd_create", fd >= 0, e);
        if fd >= 0 {
            sysc(3, fd, 0, 0);
        }
    }

    // 6d · Cross-process memory, asked of **this** process.
    //
    // Deliberately self-directed. Against the trusted host both calls need
    // `PTRACE_MODE_ATTACH_REALCREDS`, which `yama/ptrace_scope = 1` already
    // refuses — so a cross-process row would come back AMBIENT-PRECLUDED and
    // would prove nothing about Super, exactly as `ptrace_attach_host` does.
    // Against ourselves the kernel permits it outright, which is the only
    // form in which a refusal here can be DIFFERENTIAL.
    {
        let mut dst = [0u8; 8];
        let mut src = [0u8; 8];
        let me = unsafe { syscall(39 /* getpid */) };
        let local = Iov {
            base: dst.as_mut_ptr(),
            len: dst.len(),
        };
        let remote = Iov {
            base: src.as_mut_ptr(),
            len: src.len(),
        };
        let l = &local as *const Iov as i64;
        let m = &remote as *const Iov as i64;
        let (n, e) = sysc6(310 /* process_vm_readv */, me, l, 1, m, 1, 0);
        r("process_vm_readv", n > 0, e);
        let (n, e) = sysc6(311 /* process_vm_writev */, me, l, 1, m, 1, 0);
        r("process_vm_writev", n > 0, e);
    }

    // 6e · Kernel facilities a Carrier has no business holding.
    {
        // `KEYCTL_GET_KEYRING_ID` on the session keyring is the cheapest
        // call that actually SUCCEEDS unconfined, which is what makes its
        // refusal differential rather than an argument error.
        let (v, e) = sysc(250 /* keyctl */, 0 /* GET_KEYRING_ID */, -3 /* SESSION */, 0);
        r("keyctl", v > 0, e);
    }
    {
        // A real `BPF_MAP_CREATE`, not `bpf(0, NULL, 0)`.
        //
        // **This row used to be the null call**, and the null call comes back
        // `EINVAL` — the kernel complaining about the arguments. An `EINVAL`
        // is precisely the "the fixture could not exploit it" non-evidence
        // this census exists to replace: it reads as a refusal and is
        // nothing of the kind. With a valid attr the bare control answers
        // `EPERM`, which is a real ambient preclusion
        // (`kernel.unprivileged_bpf_disabled = 2` on this host) and is
        // graded as one.
        let m = BpfMapAttr {
            map_type: 1, // BPF_MAP_TYPE_HASH
            key_size: 4,
            value_size: 4,
            max_entries: 1,
            tail: [0; 56],
        };
        let (v, e) = sysc(
            321, /* bpf */
            0,   /* BPF_MAP_CREATE */
            &m as *const BpfMapAttr as i64,
            std::mem::size_of::<BpfMapAttr>() as i64,
        );
        r("bpf", v >= 0, e);
        if v >= 0 {
            sysc(3, v, 0, 0);
        }
    }
    {
        let a = PerfAttr {
            kind: 1, // PERF_TYPE_SOFTWARE
            size: std::mem::size_of::<PerfAttr>() as u32,
            config: 0, // PERF_COUNT_SW_CPU_CLOCK
            sample: 0,
            sample_type: 0,
            read_format: 0,
            // disabled | inherit | exclude_kernel | exclude_hv — the set an
            // unprivileged process is allowed to open on itself under
            // `perf_event_paranoid = 2`, which is what this host has. With
            // the wrong flags the bare control gets EACCES and the row
            // grades itself down for a reason that is not the policy's.
            flags: 0b110_0011,
            tail: [0; 80],
        };
        let (fd, e) = sysc6(
            298, /* perf_event_open */
            &a as *const PerfAttr as i64,
            0,  /* this process */
            -1, /* any cpu */
            -1, /* no group leader */
            0, 0,
        );
        r("perf_event_open", fd >= 0, e);
        if fd >= 0 {
            sysc(3, fd, 0, 0);
        }
    }

    // 6f · The mount table. Both need `CAP_SYS_ADMIN`, so the bare control
    //      refuses them too and both are AMBIENT-PRECLUDED on this host —
    //      recorded as such rather than counted as confinement. What the
    //      confined run adds is the *author*: 130 rather than `EPERM`.
    {
        let t = format!("{workdir}/probe-mount-target\0");
        sysc(83 /* mkdir */, t.as_ptr() as i64, 0o700, 0);
        let src = b"none\0";
        let fst = b"tmpfs\0";
        let (v, e) = sysc6(
            165, /* mount */
            src.as_ptr() as i64,
            t.as_ptr() as i64,
            fst.as_ptr() as i64,
            0,
            0,
            0,
        );
        r("mount", v == 0, e);
    }
    {
        let root = b"/\0";
        let (v, e) = sysc(155 /* pivot_root */, root.as_ptr() as i64, root.as_ptr() as i64, 0);
        r("pivot_root", v == 0, e);
    }

    // 7 · Execute something else — and no longer by forking.
    //
    // Landlock's FS_EXECUTE is granted on this binary and nowhere else, while
    // seccomp deliberately permits `execve`: the Carrier's own exec has to be
    // able to happen, since the filter is installed before it. So these rows
    // test whether the *filesystem* right is what bounds execution — and
    // whether the sibling that takes a descriptor instead of a path is closed
    // some other way.
    //
    // **The old version forked, and the fork is why this was rewritten.**
    // A successful `execve` replaces the image, so the result line would never
    // be printed; the first version solved that by running the attempt in a
    // child. Then `fork` itself joined the deny list, and the row did not
    // notice: with the fork refused it fell through to `wait4(-1)`, decoded a
    // zeroed status, and printed **ALLOWED** for an execve it had never
    // attempted. A probe whose own setup failing reads as the most permissive
    // possible answer is worse than no probe at all — it is a green row over
    // an unasked question.
    //
    // The rewrite makes success impossible without touching the thing being
    // measured. **The kernel decides whether a file may be executed before it
    // reads `argv`**: `fs/exec.c` opens and permission-checks in `alloc_bprm`
    // and only then does `count(argv)` fault. So a good path with an
    // unreadable `argv` separates the answers cleanly and never execs:
    //
    // ```text
    //   EFAULT (14)  the file was accepted for execution and only the
    //                arguments were bad — the authority was present
    //   EACCES (13)  Landlock refused the file
    //   130          Super's seccomp filter refused the syscall
    // ```
    //
    // Measured on this kernel in both directions: `/usr/bin/id` with a bad
    // `argv` gives EFAULT, and `/etc` — a directory, so never executable —
    // gives EACCES from the identical call. If a future kernel reordered the
    // two, the bare control would stop reporting EFAULT and these rows would
    // go red rather than quietly wrong.
    //
    // Losing the fork is what let `clone`/`fork`/`vfork`/`clone3` join
    // `confine::DENIED` at all.
    const EFAULT: i32 = 14;
    // Non-NULL and unmapped. A NULL `argv` is legal — it means `argc == 0` —
    // and would not fault, so the row would report the wrong thing.
    const BAD_ARGV: i64 = 1;
    {
        let path = b"/usr/bin/id\0";
        let (_, e) = sysc6(59 /* execve */, path.as_ptr() as i64, BAD_ARGV, BAD_ARGV, 0, 0, 0);
        r("execve_other_binary", e == EFAULT, e);

        let (_, e) = sysc6(
            322, /* execveat */
            -100, /* AT_FDCWD */
            path.as_ptr() as i64,
            BAD_ARGV,
            BAD_ARGV,
            0,
            0,
        );
        r("execveat_other_binary", e == EFAULT, e);
    }

    // 8 · `vfork`, last, and only where it cannot make a child.
    //
    // **Measured, and it is worse than the documentation suggests.** The
    // usual warning about `vfork` is that the child shares the parent's
    // memory, so a branch on the return value is a value two processes are
    // writing. The ordering appears to rescue that — the parent stays
    // suspended until the child is gone — and on that reasoning a first
    // version of this row ran the whole thing inside a forked child and
    // reported through its exit status.
    //
    // It did not work, and the reason is one register lower than the data
    // race. Instrumented with single-byte `write(2)` markers, a raw `vfork`
    // from compiled Rust printed `A` (before), `C` (the child), `!` (past an
    // `_exit` that should never return) — and **never `P`**, the parent's
    // marker. The parent was suspended *inside* glibc's `syscall` stub, whose
    // return address is on the stack the child then makes calls on: the
    // child's first `call` instruction writes that exact slot, so the
    // parent's `ret` jumps to wherever the child's callee was going to
    // return. It is not the branch. A branch-free version that had both
    // processes `_exit(0)` unconditionally failed identically, because the
    // `call` to `_exit` is itself the write.
    //
    // The only safe form needs the child to reach the `syscall` instruction
    // with no `call` in between, which means inline assembly. Nothing else
    // in this binary hand-writes assembly and one row is a poor reason to
    // start, so:
    //
    //   * where `fork` is already refused — a Carrier — `vfork` is called
    //     directly. Seccomp answers *before* the kernel creates anything, so
    //     there is no child and no shared stack, and the reading is real;
    //   * where `fork` works — the unconfined control — it is **not called**,
    //     and this probe says so on the wire under its own name rather than
    //     omitting the row. A missing line is indistinguishable from a probe
    //     that crashed.
    //
    // It runs last so that a policy hole here costs the final row and not the
    // census: if `vfork` ever *were* permitted, the parent would resume with
    // a corrupted return address and never reach `r`, and `verify` would see
    // the confined row missing — which is red, and correctly so.
    if fork_works {
        r("vfork_not_attempted_shared_stack", true, 0);
    } else {
        let (v, e) = sysc(58 /* vfork */, 0, 0, 0);
        if v == 0 {
            sysc(60 /* exit */, 0, 0, 0);
            unreachable!();
        }
        r("vfork", v > 0, e);
    }
}
