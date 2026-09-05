//! `super-host effect` — the machine effect, on the far side of a typed
//! boundary from the decision that admitted it.
//!
//! # What this is for
//!
//! D.1.1 put `git worktree add` inside `ampd`, and recorded honestly that
//! the runtime went from executing zero programs to executing one. Two
//! things then turned out to be true of that arrangement, and only the
//! first was known at the time:
//!
//! 1. The Elixir runtime is not where OS confinement can be applied.
//!    Landlock, seccomp, `unshare`, Capsicum — none of them are reachable
//!    from the BEAM without exactly the kind of privileged machinery the
//!    WEK thesis is trying to keep from growing.
//!
//! 2. **`git` is not one program.** `git worktree add` checks out a tree,
//!    and checking out a tree runs the repository's `post-checkout` hook.
//!    Measured, before it was suppressed: a hook planted in a fixture
//!    repository executed, with the runtime's uid and its whole filesystem
//!    view. Configuration can stop hooks; it cannot stop a repository's own
//!    filter drivers. Closing that needs an OS boundary, and an OS boundary
//!    needs to be applied by whatever calls `exec`.
//!
//! So the execution moves here. The boundary is typed, and it is one-way:
//!
//! ```text
//!     ampd    admission · authority · lifecycle
//!               │  worktree-effect-request@1
//!               ▼
//!     host    machine effect + observation
//!               │  worktree-effect-observation@1
//!               ▼
//!     ampd    verification · evidence · commit
//! ```
//!
//! # The host does not decide authority, and cannot
//!
//! This is the property that matters most, and it is structural rather
//! than promised: **`worktree-effect-request@1` carries no actor, no lane,
//! no capability, no grant and no world.** There is nothing in the request
//! this code could consult to form an opinion about whether the caller was
//! entitled to it, so it cannot accidentally grow one. It receives an
//! already-admitted operation and performs it.
//!
//! The inverse is equally deliberate: the host is not a second gate. If it
//! refused things, a refusal would exist that no `refusal@1` describes and
//! no projection shows, and the operator would be reading an authority
//! story with a hole in it.
//!
//! # What OS authority this retains — recorded, not claimed away
//!
//! Moving the exec here **is not confinement**, and this file does not
//! pretend otherwise. As shipped, the child `git` process retains:
//!
//! * the host's uid and gid, and every file they can reach;
//! * the host's mount namespace, network namespace and PID namespace;
//! * every environment variable except the git-specific ones scrubbed
//!   below;
//! * the ability to run any hook or filter git decides to run, limited
//!   only by the configuration hardening passed on the command line.
//!
//! No `landlock`, no `seccomp`, no `unshare`, no `chroot`. What has changed
//! is that there is now exactly one place where adding them would work,
//! and it is written in a language that can make the syscalls. That is the
//! whole of this round's claim.

use crate::sha256;
use serde_json::{json, Value};
use std::io::BufRead;
use std::path::{Path, PathBuf};
use std::process::Command;

/// The version of the request/observation pair this host speaks.
///
/// Bound into `host-identity@1` and therefore into every capability's
/// embodiment basis. A protocol change that altered what a request *means*
/// while keeping the schema names would otherwise be invisible to `ampd`.
pub const EFFECT_PROTOCOL_VERSION: u32 = 1;

/// Git variables that name a location or a program. Absence is the safe
/// value for these: with none set, git uses its own defaults.
const SCRUB: &[&str] = &[
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CONFIG",
    "GIT_CONFIG_COUNT",
    "GIT_SSH",
    "GIT_SSH_COMMAND",
    "GIT_EXTERNAL_DIFF",
    "GIT_PAGER",
    "GIT_EDITOR",
    "GIT_ASKPASS",
    "GIT_NAMESPACE",
    "GIT_COMMON_DIR",
    "GIT_CEILING_DIRECTORIES",
    "GIT_ALLOW_PROTOCOL",
];

/// Pointed at `/dev/null`, **not** unset. Git's documented behaviour is
/// that setting these to `/dev/null` disables the corresponding config
/// file, whereas unsetting them restores the normal default lookup — so
/// scrubbing them the way everything above is scrubbed would leave
/// `~/.gitconfig` in force. Measured on this machine before the
/// correction: `git config --show-origin user.email` still read the global
/// file with both variables unset.
const NULLED: &[(&str, &str)] = &[
    ("GIT_CONFIG_GLOBAL", "/dev/null"),
    ("GIT_CONFIG_SYSTEM", "/dev/null"),
];

/// Passed as `-c` on the command line so a repository's own `.git/config`
/// cannot override them. Anything that must hold against a hostile
/// repository has to be asserted at a precedence the repository cannot
/// reach.
const HARDENED: &[&str] = &[
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "protocol.ext.allow=never",
];

/// The OS authority this effector retains, as data, so `ampd` can bind it
/// into evidence rather than a human writing it into a document that then
/// goes stale. Every field is what is true **today**; a `false` here is a
/// promise nobody is making.
fn confinement_profile() -> Value {
    json!({
        "schema": "host-confinement@1",
        "landlock": false,
        "seccomp": false,
        "mount_namespace": false,
        "network_namespace": false,
        "pid_namespace": false,
        "chroot": false,
        "drops_privileges": false,
        "inherits_uid": true,
        "inherits_environment_except_scrubbed": true,
        "scrubbed": SCRUB,
        "nulled": NULLED.iter().map(|(k, v)| json!([k, v])).collect::<Vec<_>>(),
        "hardening_flags": HARDENED,
        "note": "the boundary exists so confinement can be added here; none is applied yet"
    })
}

/// The `git` this host will actually execute, resolved to an absolute path
/// by walking `$PATH` exactly once.
///
/// # Why resolve rather than let `Command` do it
///
/// `Command::new("git")` resolves through `$PATH` at spawn time, on every
/// call. That means the binary whose identity this host *reports* and the
/// binary it *runs* would be two separate lookups, and a `$PATH` that
/// changed between them — or a directory entry replaced between them —
/// would make the reported identity a description of a program that never
/// ran. Resolving once and exec'ing the resolved path collapses the two
/// into one decision.
///
/// It is not a full closure of the race: the path is resolved, then hashed,
/// then exec'd, and the file can be replaced between any two of those. What
/// it buys is that the window is one function rather than the lifetime of
/// the process, and that the *same* pathname is used for all three.
fn resolve_git() -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        if dir.as_os_str().is_empty() {
            continue;
        }
        let candidate = dir.join("git");
        if let Ok(md) = std::fs::metadata(&candidate) {
            if md.is_file() {
                use std::os::unix::fs::PermissionsExt;
                if md.permissions().mode() & 0o111 != 0 {
                    return Some(candidate);
                }
            }
        }
    }
    None
}

fn git(cd: &str, args: &[&str]) -> Result<String, String> {
    let exe = match resolve_git() {
        Some(p) => p,
        None => return Err("no executable `git` on PATH".into()),
    };

    let mut c = Command::new(exe);
    c.arg("-C").arg(cd);
    for h in HARDENED {
        c.arg(h);
    }
    for a in args {
        c.arg(a);
    }
    for k in SCRUB {
        c.env_remove(k);
    }
    for (k, v) in NULLED {
        c.env(k, v);
    }
    c.env("GIT_TERMINAL_PROMPT", "0");

    match c.output() {
        Ok(o) if o.status.success() => Ok(String::from_utf8_lossy(&o.stdout).to_string()),
        Ok(o) => Err(format!(
            "git {} exited {}: {}",
            args.join(" "),
            o.status.code().unwrap_or(-1),
            String::from_utf8_lossy(&o.stderr).trim()
        )),
        Err(e) => Err(format!("git could not be executed: {e}")),
    }
}

/// The digest and byte count of the image this process is executing.
///
/// `/proc/self/exe` opened directly. See `identity`'s docs for why the
/// distinction between opening the link and opening its text is the whole
/// point of the field.
fn self_image() -> std::io::Result<(String, u64)> {
    let f = match std::fs::File::open("/proc/self/exe") {
        Ok(f) => f,
        // Not Linux, or no procfs. The readlink-then-open form is weaker
        // and is used only because the alternative is no identity at all.
        Err(_) => std::fs::File::open(std::env::current_exe()?)?,
    };
    let bytes = f.metadata().map(|m| m.len()).unwrap_or(0);
    let digest = sha256::digest_reader(&f)?;
    Ok((digest, bytes))
}

/// A stable identity for this host's hardening policy.
///
/// Not a general canonicalizer — a fixed serialization of a fixed
/// structure, which is why writing it here does not make `super` a system
/// with two canonicalizers. `ampd` never re-derives this value; it binds
/// the name the host gives its own policy. What the digest has to do is
/// change when the policy changes, and it does: adding, removing or
/// reordering any scrubbed variable, nulled variable or hardening flag
/// changes the bytes.
fn hardening_policy_digest() -> String {
    let mut s = String::from("super-host/hardening@1\n");
    s.push_str("protocol:");
    s.push_str(&EFFECT_PROTOCOL_VERSION.to_string());
    s.push_str("\nscrub:");
    s.push_str(&SCRUB.join(","));
    s.push_str("\nnulled:");
    for (k, v) in NULLED {
        s.push_str(k);
        s.push('=');
        s.push_str(v);
        s.push(';');
    }
    s.push_str("\nhardened:");
    s.push_str(&HARDENED.join(" "));
    s.push('\n');
    sha256::digest(s.as_bytes())
}

/// `git version --build-options`, or `None`.
///
/// **Not `--version`.** That prints one line which distros hold constant
/// across backported changes, so two builds that behave differently print
/// the same string. `--build-options` additionally reports the upstream
/// commit, the SHA-1 implementation (`SHA1_DC` detects collision attacks;
/// `SHA1_OPENSSL` and `SHA1_APPLE` do not), the compiled-in `shell-path`
/// that hooks and filters are run through, the linked libcurl/OpenSSL, and
/// the default hash and ref format. Every one of those changes what an
/// effect *means* while leaving `--version` identical.
///
/// Run against the resolved executable rather than the name, for the
/// reason `resolve_git` states.
fn git_version(exe: &Path) -> Option<String> {
    let mut c = Command::new(exe);
    c.arg("version").arg("--build-options");
    for k in SCRUB {
        c.env_remove(k);
    }
    for (k, v) in NULLED {
        c.env(k, v);
    }
    match c.output() {
        Ok(o) if o.status.success() => Some(String::from_utf8_lossy(&o.stdout).trim().to_string()),
        _ => None,
    }
}

/// `host-identity@1` — what this host is **made of**, and deliberately not
/// where any of it lives.
///
/// # The defect this answers
///
/// D.1.1a bound an embodiment basis that named the effector *class*
/// (`Ampd.Worktree.Effector.Host`) and nothing about the executable that
/// class runs. `SUPER_HOST_BIN` is read at spawn time and the host then
/// resolved `git` through `$PATH`, so both halves of the machine that
/// actually performs the effect could be replaced with the basis digest
/// unchanged — and a capability established under one machine stayed
/// exercisable under another. That defeats the reason the basis exists.
///
/// # Content identity, not pathname identity
///
/// Every field here is a digest, a size or a version string. **No pathname
/// appears in this object**, which is what lets it be bound into
/// `worktree-profile@1` and thence into a receipt an agent can read.
/// Pathname identity would also be the wrong answer on the merits: the same
/// bytes at a new path are the same embodiment, and different bytes at the
/// same path are not.
///
/// # The host hashes *itself*, by opening the link and not by reading it
///
/// `/proc/self/exe` is **opened**, never `readlink`'d into a `String` that
/// is then opened. Those are different operations and the difference is
/// the whole value of the field. The kernel's `proc_exe_link()` returns
/// the stored `struct file`'s path, so opening the magic link reaches the
/// inode this process is executing; opening the *text* of that link
/// performs a fresh pathname resolution, which after an atomic
/// rename-over reaches the replacement instead. Both calls succeed and
/// they hash different bytes.
///
/// `std::env::current_exe()` is the readlink-then-open form, which is why
/// it is used only as a non-Linux fallback. It is also the form that
/// cannot work at all for a process exec'd from a `memfd`, where the link
/// text is `/memfd:… (deleted)` and names nothing openable.
///
/// Having `ampd` hash the path it is about to spawn would be weaker
/// still: it would attest the file it *looked at*, with a window between
/// the look and the exec.
///
/// # What this is not: it is a self-report
///
/// Stated plainly because the alternative is a claim this does not
/// support. A process measuring itself is trustworthy against drift,
/// mistake and an operator swapping a binary — and worth nothing against
/// a host that has already been replaced by something willing to lie,
/// because that something reports whatever it likes. Closing *that* needs
/// the measurement taken by somebody else: `ampd` opening
/// `/proc/<child>/exe` for the pid it spawned, or `SO_PEERPIDFD` if this
/// ever becomes a connection rather than a spawn. Recorded as a D.1.2+
/// item; not claimed here.
pub fn identity() -> Value {
    let host = match self_image() {
        Ok((digest, bytes)) => json!({ "resolved": true, "sha256": digest, "bytes": bytes }),
        // No path in the reason. An error string is still a projection.
        Err(_) => json!({ "resolved": false, "reason": "the running image could not be read" }),
    };

    let git = match resolve_git() {
        Some(p) => {
            let digest = sha256::digest_file(&p).ok();
            let version = git_version(&p);
            let bytes = std::fs::metadata(&p).map(|m| m.len()).unwrap_or(0);
            json!({
                "resolved": true,
                "sha256": digest,
                "version": version,
                "bytes": bytes,
            })
        }
        None => json!({ "resolved": false, "reason": "no executable `git` on PATH" }),
    };

    json!({
        "schema": "host-identity@1",
        "effect_protocol": ["worktree-effect-request@1", "worktree-effect-observation@1"],
        "effect_protocol_version": EFFECT_PROTOCOL_VERSION,
        "host_binary": host,
        "git": git,
        "hardening_policy_digest": hardening_policy_digest(),
        "confinement": confinement_profile(),
    })
}

/// `super-host identity` — print one `host-identity@1` and exit.
///
/// A separate subcommand rather than a flag on `effect`, because `ampd`
/// asks this question at a different time and for a different reason: it
/// builds the embodiment basis *before* deciding anything, and performing
/// an effect to find out what the machine is would be the wrong order.
pub fn identity_run() -> i32 {
    println!("{}", identity());
    0
}

/// A refusal, as a value rather than as a print.
///
/// Split out from `fail` so that the same refusal can be written to a
/// socket. `fail` keeps the exit-code contract; this keeps the shape.
///
/// Deliberately **no `identity`**, on the failure path only — a refused
/// effect creates nothing, so there is no commitment for an identity to be
/// wrong about, and hashing two binaries to decorate an error is a cost
/// with no reader.
pub fn refusal(reason: String) -> Value {
    json!({
        "schema": "worktree-effect-observation@1",
        "ok": false,
        "reason": reason,
        "confinement": confinement_profile(),
    })
}

/// Perform one already-admitted `worktree-effect-request@1` and return one
/// `worktree-effect-observation@1`.
///
/// **This is the whole mechanism, with no I/O in it.** `run` is stdin/stdout
/// glue over this function and a socket server would be glue of a different
/// shape over the same one — which is the point: moving how the request
/// *arrives* must not move what performing it *means*, or the two transports
/// would be two effectors and the parity check between them would be
/// comparing a thing to itself.
///
/// Carries no actor, no lane, no capability, no grant and no world, so there
/// is nothing here to form an opinion about. It performs an operation that
/// was already admitted and it is not a second gate.
///
/// **Correlation fields are not read here.** `request_id` and
/// `channel_epoch` belong to whatever carried the request; binding them to
/// the reply is the transport's job, and letting the mechanism see them
/// would be letting it decide which request it is answering.
/// Prove that a materialization **is** the snapshot a `source-basis@1` names.
///
/// # Why this exists at all, and why here
///
/// A basis binds a commit; a worktree is a *materialization* of one. Those
/// are different things and conflating them is the mistake Phase A was
/// warned off making: git object identity is immutable, and a directory on
/// disk is not — same-uid software can edit it, and this box runs many
/// sessions over one checkout. `Ampd.Worktree` records the commit the
/// effector observed **at creation**, which is a fact about the past.
///
/// So the question "is this still that snapshot" is asked here, immediately
/// before the read capability is derived from it, because an answer obtained
/// any earlier is a TOCTOU whose window you cannot bound. It is deliberately
/// *not* asked inside `ampd`'s coordinator, where a `git` call would be an
/// unbounded host round trip inside the total order.
///
/// # What is checked, and what each one catches alone
///
///   `rev-parse HEAD` == commit_oid    the wrong revision is materialized
///                                     here, or the worktree was moved to
///                                     another commit after it was bound
///
///   `status --porcelain` is empty     the right revision, edited. Catches a
///                                     modified tracked file, a deleted one,
///                                     and an untracked addition — the last
///                                     because a file that is not in the
///                                     commit is not in the snapshot the
///                                     basis names, whatever else it is
///
/// Neither implies the other. A clean worktree at the wrong commit passes the
/// second and fails the first; a dirty worktree at the right commit does the
/// reverse. Both are required and both are falsified.
///
/// # What it deliberately does not do
///
/// It does not compute a tree object and compare it. `status --porcelain`
/// already answers "does the working tree differ from the commit", and
/// `git write-tree` would additionally *write* into the object database from
/// a read-only verification — and has a documented failure where it returns
/// the empty tree without saying so, which would read as agreement.
///
/// It reports the mismatch rather than repairing it. Re-binding the basis to
/// whatever is currently on disk would answer a different question from the
/// one the admitted job asked.
pub fn verify_source_basis(target: &str, commit_oid: &str) -> Result<(), String> {
    // Exact object names only. The semantic side refuses a symbolic revision
    // when the basis is bound; refusing it again here means this function is
    // safe to call with a value that did not come through that path — and a
    // verifier that trusted its argument to have been checked elsewhere is a
    // verifier one refactor away from checking nothing.
    if commit_oid.len() != 40 || !commit_oid.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(format!(
            "source-basis-revision-not-exact: {commit_oid:?} is not a 40-character object name"
        ));
    }
    if commit_oid.bytes().any(|b| b.is_ascii_uppercase()) {
        return Err(format!(
            "source-basis-revision-not-exact: {commit_oid:?} is not lowercase"
        ));
    }

    if !Path::new(target).is_dir() {
        return Err(format!("source-basis-materialization-absent: {target}"));
    }

    let head = git(target, &["rev-parse", "HEAD"])?;
    let head = head.trim();
    if head != commit_oid {
        return Err(format!(
            "source-basis-revision-moved: materialization is at {head}, the basis names {commit_oid}"
        ));
    }

    let status = git(target, &["status", "--porcelain"])?;
    if !status.trim().is_empty() {
        // The paths are named. A basis mismatch that said only "dirty" would
        // send someone to look at the whole tree.
        let paths: Vec<&str> = status.lines().take(8).map(str::trim).collect();
        return Err(format!(
            "source-basis-materialization-dirty: {} path(s) differ from {commit_oid}: {}",
            status.lines().count(),
            paths.join(" · ")
        ));
    }

    Ok(())
}

pub fn perform(req: &Value) -> Value {
    if req["schema"] != "worktree-effect-request@1" {
        return refusal(format!(
            "unknown request schema: {}",
            req["schema"].as_str().unwrap_or("(absent)")
        ));
    }

    let repo = match req["repo_path"].as_str() {
        Some(s) => s,
        None => return refusal("repo_path is required".into()),
    };
    let target = match req["target"].as_str() {
        Some(s) => s,
        None => return refusal("target is required".into()),
    };
    let revision = req["revision"].as_str().unwrap_or("HEAD");

    if req["op"] != "create" {
        return refusal(format!(
            "unknown op: {}",
            req["op"].as_str().unwrap_or("(absent)")
        ));
    }

    if let Err(e) = git(repo, &["worktree", "add", "--detach", target, revision]) {
        return refusal(e);
    }

    // Observed, not assumed. The host reports what it can see; `ampd`
    // decides whether that is good enough, re-checks confinement against
    // its own root, and is the only thing that may commit.
    let exists = Path::new(target).is_dir();
    let head = match git(target, &["rev-parse", "HEAD"]) {
        Ok(h) => h.trim().to_string(),
        Err(e) => return refusal(e),
    };

    json!({
        "schema": "worktree-effect-observation@1",
        "ok": true,
        "head": head,
        "observed_dir": exists,
        "confinement": confinement_profile(),
        // **The machine that performed it, reported by the machine that
        // performed it.** `ampd` builds the embodiment basis by asking
        // `super-host identity` beforehand and caches the answer; this
        // field is what lets it check that the thing which then ran was
        // the thing it admitted under. Without it the basis is a claim
        // about a lookup, not about an execution, and a binary swapped
        // between the lookup and the exec would go unnoticed.
        "identity": identity(),
    })
}

fn fail(reason: String) -> i32 {
    println!("{}", refusal(reason));
    // **Zero, deliberately.** A well-formed refusal is a successful
    // observation of a failed effect, and `ampd` reads the typed answer
    // rather than the exit code. Exiting non-zero would make a legitimate
    // "git said no" indistinguishable from "the host itself broke", which
    // is exactly the collapse the lifecycle states exist to prevent.
    0
}

/// Read one `worktree-effect-request@1` from stdin, perform it, print one
/// `worktree-effect-observation@1` on stdout.
///
/// One request per invocation. A long-lived host holding a socket is the
/// eventual shape; a process per effect is the shape that can be reasoned
/// about now, and it makes the boundary impossible to accidentally widen
/// into a session.
pub fn run() -> i32 {
    // **One line, not to EOF.** Reading to EOF deadlocks against an Erlang
    // port: `Port.open/2` offers no way to close the child's stdin without
    // closing the port, so `read_to_string` waits for an EOF that only
    // arrives when the caller has given up. Measured as a test run that
    // never finished — the request had been written and both sides were
    // waiting for the other.
    //
    // `Ampd.Core.canon/1` emits single-line JSON, so one line is the whole
    // request and the framing costs nothing.
    let mut buf = String::new();
    if let Err(e) = std::io::stdin().lock().read_line(&mut buf) {
        return fail(format!("could not read the request: {e}"));
    }
    if buf.trim().is_empty() {
        return fail("the request was empty".into());
    }

    let req: Value = match serde_json::from_str(&buf) {
        Ok(v) => v,
        Err(e) => return fail(format!("the request is not valid JSON: {e}")),
    };

    // Every decision about the request now lives in `perform`, so this
    // subcommand and any future socket server cannot drift into disagreeing
    // about what a request means. The exit code stays 0 either way — see
    // `fail` for why a refusal is a successful observation.
    println!("{}", perform(&req));
    0
}
