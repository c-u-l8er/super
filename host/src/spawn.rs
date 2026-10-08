//! `spawn_possessing` (T28, C4; macOS only).
//!
//! On Linux a spawn bounds what the child inherits after `fork`: `ensure_std_fds`, then `dup_onto` (and, for a Carrier,
//! `seal_inheritance`, which is `close_range` with `CLOSE_RANGE_CLOEXEC`). macOS has no `close_range` and no
//! `closefrom`, and Rust's `posix_spawn` path never sets `POSIX_SPAWN_CLOEXEC_DEFAULT` (any `pre_exec` forces `fork`).
//! So here the spawn itself possesses: with `POSIX_SPAWN_CLOEXEC_DEFAULT` only the descriptors the file actions create
//! survive into the child, whatever this process holds inheritable.
//!
//! * stdin is `/dev/null`; stdout and stderr are the parent's, `dup2`'d from copies numbered ≥ 10 (or `/dev/null` when
//!   the parent's is closed), which keeps `ensure_std_fds`' guarantee: a received channel can never become a stream;
//! * each given descriptor is `dup2`'d onto its target from such a copy (a source never equals a target, and `dup2`
//!   clears `FD_CLOEXEC` on the target);
//! * `SIGPIPE` and every other signal go back to their defaults (`POSIX_SPAWN_SETSIGDEF`), as std does for its children;
//! * the spawn holds the fork lock for writing ([`crate::fdpass::spawn_guard`]), so no descriptor this process is
//!   making or receiving under the lock can be seen between its birth and its `FD_CLOEXEC`.

use std::ffi::CString;
use std::io;
use std::os::unix::io::RawFd;
use std::os::unix::process::ExitStatusExt;
use std::path::Path;
use std::process::ExitStatus;

extern "C" {
    // macOS 26.0 (SDK spawn.h:72–73). libc 0.2.189 does not declare it: the one extern T28 adds, registered by name, with
    // this reason, in T27's L2 guard (`host/tests/t27_no_raw_syscalls.rs`).
    fn posix_spawn_file_actions_addchdir(
        actions: *mut libc::posix_spawn_file_actions_t,
        path: *const libc::c_char,
    ) -> libc::c_int;
}

/// A spawned process: `id`, `kill` (SIGKILL, as std) and `wait` (`waitpid`), the shape `Runtime` uses.
pub struct Child {
    pid: libc::pid_t,
}

impl Child {
    pub fn id(&self) -> u32 {
        self.pid as u32
    }

    pub fn kill(&mut self) -> io::Result<()> {
        if unsafe { libc::kill(self.pid, libc::SIGKILL) } == -1 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    pub fn wait(&mut self) -> io::Result<ExitStatus> {
        loop {
            let mut status: libc::c_int = 0;
            if unsafe { libc::waitpid(self.pid, &mut status, 0) } == -1 {
                let e = io::Error::last_os_error();
                if e.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(e);
            }
            return Ok(ExitStatus::from_raw(status));
        }
    }
}

fn check(rc: libc::c_int, what: &str) -> io::Result<()> {
    if rc != 0 {
        return Err(io::Error::new(io::Error::from_raw_os_error(rc).kind(), format!("{what}: {}", io::Error::from_raw_os_error(rc))));
    }
    Ok(())
}

/// A close-on-exec copy of `fd` numbered ≥ 10, or `None` when `fd` is not open.
fn high_copy(fd: RawFd) -> io::Result<Option<RawFd>> {
    if unsafe { libc::fcntl(fd, libc::F_GETFD) } == -1 {
        return Ok(None);
    }
    let c = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 10) };
    if c == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(Some(c))
}

fn cstring(s: &str) -> io::Result<CString> {
    CString::new(s).map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, format!("a NUL byte in {s:?}")))
}

/// Spawn `program` (looked up on `PATH`, as `posix_spawnp`) with `args` and exactly `env`, in `cwd` if given. The child
/// holds 0, 1, 2 and each `give` source on its target, and nothing else.
pub fn spawn_possessing(
    program: &str,
    args: &[&str],
    env: &[(String, String)],
    cwd: Option<&Path>,
    give: &[(RawFd, RawFd)],
) -> io::Result<Child> {
    let _guard = crate::fdpass::spawn_guard();
    let mut copies: Vec<RawFd> = Vec::new();
    let result = (|| -> io::Result<Child> {
        let prog = cstring(program)?;
        let argv_c: Vec<CString> = std::iter::once(Ok(prog.clone())).chain(args.iter().map(|a| cstring(a))).collect::<io::Result<_>>()?;
        let envp_c: Vec<CString> = env.iter().map(|(k, v)| cstring(&format!("{k}={v}"))).collect::<io::Result<_>>()?;
        let mut argv: Vec<*mut libc::c_char> = argv_c.iter().map(|c| c.as_ptr() as *mut _).collect();
        argv.push(std::ptr::null_mut());
        let mut envp: Vec<*mut libc::c_char> = envp_c.iter().map(|c| c.as_ptr() as *mut _).collect();
        envp.push(std::ptr::null_mut());
        let devnull = c"/dev/null";
        let dir = match cwd {
            Some(p) => Some(cstring(&p.to_string_lossy())?),
            None => None,
        };

        let mut fa: libc::posix_spawn_file_actions_t = unsafe { std::mem::zeroed() };
        check(unsafe { libc::posix_spawn_file_actions_init(&mut fa) }, "posix_spawn_file_actions_init")?;
        let mut attr: libc::posix_spawnattr_t = unsafe { std::mem::zeroed() };
        let r = (|| -> io::Result<Child> {
            check(unsafe { libc::posix_spawnattr_init(&mut attr) }, "posix_spawnattr_init")?;
            check(
                unsafe { libc::posix_spawn_file_actions_addopen(&mut fa, 0, devnull.as_ptr(), libc::O_RDONLY, 0) },
                "stdin",
            )?;
            for target in [1, 2] {
                match high_copy(target)? {
                    Some(c) => {
                        copies.push(c);
                        check(unsafe { libc::posix_spawn_file_actions_adddup2(&mut fa, c, target) }, "a standard stream")?;
                    }
                    None => check(
                        unsafe { libc::posix_spawn_file_actions_addopen(&mut fa, target, devnull.as_ptr(), libc::O_WRONLY, 0) },
                        "a closed standard stream",
                    )?,
                }
            }
            for (src, target) in give {
                let c = high_copy(*src)?.ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, format!("fd {src} is not open")))?;
                copies.push(c);
                check(unsafe { libc::posix_spawn_file_actions_adddup2(&mut fa, c, *target) }, "a given descriptor")?;
            }
            if let Some(d) = &dir {
                check(unsafe { posix_spawn_file_actions_addchdir(&mut fa, d.as_ptr()) }, "the working directory")?;
            }
            let flags = (libc::POSIX_SPAWN_CLOEXEC_DEFAULT | libc::POSIX_SPAWN_SETSIGDEF) as libc::c_short;
            check(unsafe { libc::posix_spawnattr_setflags(&mut attr, flags) }, "posix_spawnattr_setflags")?;
            let mut all: libc::sigset_t = unsafe { std::mem::zeroed() };
            unsafe { libc::sigfillset(&mut all) };
            check(unsafe { libc::posix_spawnattr_setsigdefault(&mut attr, &all) }, "posix_spawnattr_setsigdefault")?;
            let mut pid: libc::pid_t = 0;
            check(
                unsafe { libc::posix_spawnp(&mut pid, prog.as_ptr(), &fa, &attr, argv.as_ptr(), envp.as_ptr()) },
                &format!("posix_spawnp {program}"),
            )?;
            Ok(Child { pid })
        })();
        unsafe {
            libc::posix_spawnattr_destroy(&mut attr);
            libc::posix_spawn_file_actions_destroy(&mut fa);
        }
        r
    })();
    for c in copies {
        unsafe { libc::close(c) };
    }
    result
}
