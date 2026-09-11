//! Human-operated local development tools. This is not a runtime actor,
//! grant, validation receipt, or bot execution channel. A native chooser
//! establishes the root; the trusted page only supplies relative paths.
#[path = "change_set.rs"]
mod change_set;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, VecDeque},
    ffi::CString,
    fs::File,
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            fs::{MetadataExt, PermissionsExt},
            process::CommandExt,
        },
    },
    path::{Component, Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
};
const FILE_LIMIT: usize = 1024 * 1024;
const OUTPUT_LIMIT: usize = 128 * 1024;
#[derive(Default, Clone)]
pub struct Workbench(Arc<Mutex<Session>>);
#[derive(Default)]
struct Session {
    generation: u64,
    root: Option<PathBuf>,
    directory: Option<File>,
    run: Option<Run>,
    shells: BTreeMap<u64, Run>,
    next_shell: u64,
}
struct Run {
    child: Child,
    pgid: i32,
    output: Arc<Mutex<Output>>,
    command: String,
    exit: Option<Option<i32>>,
    stopped: bool,
    tty: Option<File>,
    reader_stop: Arc<AtomicBool>,
}
#[derive(Default)]
struct Output {
    bytes: VecDeque<u8>,
    total: u64,
}
impl Output {
    fn push(&mut self, data: &[u8]) {
        self.total += data.len() as u64;
        self.bytes.extend(data);
        while self.bytes.len() > OUTPUT_LIMIT {
            self.bytes.pop_front();
        }
    }
}
impl Run {
    fn stop(&mut self) {
        if !self.stopped {
            self.reader_stop.store(true, Ordering::Relaxed);
            if let Some(tty) = self.tty.as_ref() {
                let foreground = unsafe { libc::tcgetpgrp(tty.as_raw_fd()) };
                if foreground > 0 && foreground != self.pgid {
                    unsafe {
                        libc::kill(-foreground, libc::SIGKILL);
                    }
                }
            }
            unsafe {
                libc::kill(-self.pgid, libc::SIGKILL);
            }
            self.stopped = true;
            let _ = self.child.wait();
            self.exit = Some(None);
        }
    }
    fn metadata(&mut self) -> Result<Value, String> {
        if self.exit.is_none() {
            // Observe without reaping: keeping the leader reserves its PID/PGID
            // until Stop/replacement, so a late cleanup cannot signal a reused ID.
            let mut info = std::mem::MaybeUninit::<libc::siginfo_t>::zeroed();
            if unsafe {
                libc::waitid(
                    libc::P_PID,
                    self.child.id(),
                    info.as_mut_ptr(),
                    libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
                )
            } != 0
            {
                return Err(error(std::io::Error::last_os_error()));
            }
            let info = unsafe { info.assume_init() };
            if unsafe { info.si_pid() } != 0 {
                self.exit = Some(if info.si_code == libc::CLD_EXITED {
                    Some(unsafe { info.si_status() })
                } else {
                    None
                });
            }
        }
        Ok(
            json!({"command":self.command,"running":self.exit.is_none(),"exit_code":self.exit.flatten(),"stopped":self.stopped}),
        )
    }
    fn status(&mut self) -> Result<Value, String> {
        let mut value = self.metadata()?;
        let output = self
            .output
            .lock()
            .map_err(|_| "Command output is unavailable.")?;
        let bytes: Vec<u8> = output.bytes.iter().copied().collect();
        value["output"] = json!(String::from_utf8_lossy(&bytes));
        value["omitted_bytes"] = json!(output.total.saturating_sub(bytes.len() as u64));
        Ok(value)
    }
}
impl Drop for Run {
    fn drop(&mut self) {
        self.stop();
    }
}
#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
    ApplySet {
        generation: u64,
        files: Vec<change_set::Edit>,
    },
    RecoverSet {
        generation: u64,
        restore: bool,
    },
    SetStatus {
        generation: u64,
    },
    DeleteBasis {
        generation: u64,
        path: String,
        original: Option<String>,
        draft: String,
    },
    FileBasis {
        generation: u64,
        path: String,
        original: Option<String>,
        draft: String,
        proposed: Option<String>,
    },
    MatchPlan {
        generation: u64,
        task_ref: String,
        revision: u64,
        world: [Value; 3],
    },
    Status,
    Changes {
        generation: u64,
    },
    Diff {
        generation: u64,
        path: String,
    },
    OpenShell {
        generation: u64,
    },
    ShellOutput {
        generation: u64,
        id: u64,
        after: u64,
    },
    ShellInput {
        generation: u64,
        id: u64,
        data: String,
    },
    ShellResize {
        generation: u64,
        id: u64,
        cols: u16,
        rows: u16,
    },
    CloseShell {
        generation: u64,
        id: u64,
    },
    List {
        generation: u64,
        path: String,
    },
    Read {
        generation: u64,
        path: String,
    },
    Save {
        generation: u64,
        path: String,
        original: Option<String>,
        content: String,
    },
    Run {
        generation: u64,
        command: String,
    },
    Stop {
        generation: u64,
    },
}
fn error(e: impl std::fmt::Display) -> String {
    format!("Local workspace: {e}")
}
fn parts(path: &str) -> Result<Vec<String>, String> {
    if path.len() > 4096 {
        return Err("The file path is too long.".into());
    }
    Path::new(path)
        .components()
        .map(|c| match c {
            Component::Normal(s) if s != ".git" => s
                .to_str()
                .map(str::to_owned)
                .ok_or_else(|| "Use UTF-8 file names.".into()),
            _ => Err("Choose a relative path inside this repository, outside .git.".into()),
        })
        .collect()
}
fn open_at(parent: &File, name: &str, flags: i32, mode: u32) -> Result<File, String> {
    let name = CString::new(name).map_err(|_| "Invalid file name.")?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_CLOEXEC | libc::O_NOFOLLOW,
            mode,
        )
    };
    if fd < 0 {
        Err(error(std::io::Error::last_os_error()))
    } else {
        Ok(unsafe { File::from_raw_fd(fd) })
    }
}
fn directory(root: &File, parts: &[String]) -> Result<File, String> {
    let mut dir = root.try_clone().map_err(error)?;
    for part in parts {
        dir = open_at(&dir, part, libc::O_RDONLY | libc::O_DIRECTORY, 0)?;
    }
    Ok(dir)
}
fn read_text(file: &mut File) -> Result<String, String> {
    if !file.metadata().map_err(error)?.is_file() {
        return Err("Choose a regular text file.".into());
    }
    let mut bytes = Vec::new();
    file.take((FILE_LIMIT + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(error)?;
    if bytes.len() > FILE_LIMIT {
        return Err("The editor supports files up to 1 MiB.".into());
    }
    if bytes.contains(&0) {
        return Err("This is a binary file. Choose a text file.".into());
    }
    String::from_utf8(bytes).map_err(|_| "The editor supports UTF-8 text files.".into())
}
fn file_parent(root: &File, path: &str) -> Result<(File, String), String> {
    let mut p = parts(path)?;
    let name = p.pop().ok_or("Choose a file.")?;
    Ok((directory(root, &p)?, name))
}
fn listing(root: &File, path: &str) -> Result<Value, String> {
    let dir = directory(root, &parts(path)?)?;
    // Enumerate the already-open directory, not a re-resolved supplied path.
    let mut entries = Vec::new();
    let mut truncated = false;
    for entry in std::fs::read_dir(format!("/proc/self/fd/{}", dir.as_raw_fd())).map_err(error)? {
        let entry = entry.map_err(error)?;
        let name = entry.file_name();
        if name == ".git" {
            continue;
        }
        let Some(name) = name.to_str() else {
            continue;
        };
        let kind = entry.file_type().map_err(error)?;
        if !kind.is_dir() && !kind.is_file() {
            continue;
        }
        if entries.len() == 1000 {
            truncated = true;
            break;
        }
        entries.push(json!({"name": name, "directory": kind.is_dir()}));
    }
    entries.sort_by_key(|v| {
        (
            !v["directory"].as_bool().unwrap_or(false),
            v["name"].as_str().unwrap_or("").to_lowercase(),
        )
    });
    Ok(json!({"path":path,"entries":entries,"truncated":truncated}))
}
fn save(
    root: &File,
    path: &str,
    original: Option<String>,
    content: String,
) -> Result<Value, String> {
    save_mode(root, path, original, content, None)
}
fn save_mode(
    root: &File,
    path: &str,
    original: Option<String>,
    content: String,
    restore_mode: Option<u32>,
) -> Result<Value, String> {
    if content.len() > FILE_LIMIT || content.contains('\0') {
        return Err("Save UTF-8 text up to 1 MiB.".into());
    }
    let (parent, name) = file_parent(root, path)?;
    let mut mode = 0o644;
    match open_at(&parent, &name, libc::O_RDONLY | libc::O_NONBLOCK, 0) {
        Ok(mut f) => {
            mode = f.metadata().map_err(error)?.permissions().mode() & 0o777;
            if original.as_deref() != Some(read_text(&mut f)?.as_str()) {
                return Err(
                    "The file changed on disk. Reload it before saving; your draft is still here."
                        .into(),
                );
            }
        }
        Err(_) if original.is_none() => {
            // Includes dangling symlinks: they are not a new-file destination.
            let n = CString::new(name.clone()).map_err(error)?;
            let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
            if unsafe {
                libc::fstatat(
                    parent.as_raw_fd(),
                    n.as_ptr(),
                    stat.as_mut_ptr(),
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            } == 0
                || std::io::Error::last_os_error().raw_os_error() != Some(libc::ENOENT)
            {
                return Err("This destination is unavailable or already exists.".into());
            }
        }
        Err(e) => return Err(e),
    }
    if let Some(saved_mode) = restore_mode {
        mode = saved_mode;
    }
    let temporary = format!(
        ".super-save-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(error)?
            .as_nanos()
    );
    let mut file = open_at(
        &parent,
        &temporary,
        libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
        0o600,
    )?;
    let from = CString::new(temporary).map_err(error)?;
    let to = CString::new(name).map_err(error)?;
    let result = (|| {
        file.write_all(content.as_bytes()).map_err(error)?;
        file.set_permissions(std::fs::Permissions::from_mode(mode))
            .map_err(error)?;
        file.sync_all().map_err(error)?;
        // New files must not replace a file created since the initial check.
        let renamed = unsafe {
            libc::renameat2(
                parent.as_raw_fd(),
                from.as_ptr(),
                parent.as_raw_fd(),
                to.as_ptr(),
                if original.is_none() {
                    libc::RENAME_NOREPLACE
                } else {
                    0
                },
            )
        };
        if renamed != 0 {
            return Err(error(std::io::Error::last_os_error()));
        }
        Ok(json!({"path":path,"content":content}))
    })();
    if result.is_err() {
        unsafe {
            libc::unlinkat(parent.as_raw_fd(), from.as_ptr(), 0);
        }
    }
    result
}
impl Workbench {
    pub fn shutdown(&self) {
        if let Ok(mut session) = self.0.lock() {
            if let Some(run) = &mut session.run {
                run.stop();
            }
            for shell in session.shells.values_mut() {
                shell.stop();
            }
        }
    }
    pub fn choose(&self, selected: PathBuf) -> Result<Value, String> {
        let root = crate::repository::git_root(&selected)?;
        let dir = File::open(&root).map_err(error)?;
        let mut session = self.0.lock().map_err(|_| "The workspace is busy.")?;
        if let Some(run) = &mut session.run {
            if run.status()?["running"] == true {
                return Err("Stop the running command before changing repositories.".into());
            }
        }
        for shell in session.shells.values_mut() {
            if shell.metadata()?["running"] == true {
                return Err(
                    "Close the running shell sessions before changing repositories.".into(),
                );
            }
        }
        session.shells.clear();
        session.run = None;
        session.generation += 1;
        session.root = Some(root);
        session.directory = Some(dir);
        Ok(json!({"generation":session.generation,"root":session.root}))
    }
    pub fn matching_root(&self, generation: u64) -> Result<PathBuf, String> {
        let session = self.0.lock().map_err(|_| "The workspace is busy.")?;
        if generation != session.generation {
            return Err("The selected repository changed. Open it again.".into());
        }
        let root = session
            .root
            .as_ref()
            .ok_or("Choose the plan's repository in Editor first.")?;
        let held = session
            .directory
            .as_ref()
            .ok_or("Choose a repository first.")?
            .metadata()
            .map_err(error)?;
        let current = File::open(root).map_err(error)?.metadata().map_err(error)?;
        if held.dev() != current.dev() || held.ino() != current.ino() {
            return Err("The selected repository folder was replaced. Open it again.".into());
        }
        crate::repository::git_root(root)
    }
    pub fn request(&self, request: Request) -> Result<Value, String> {
        let mut session = self.0.lock().map_err(|_| "The workspace is busy.")?;
        let expected = match &request {
            Request::Status => None,
            Request::ApplySet { generation, .. }
            | Request::RecoverSet { generation, .. }
            | Request::SetStatus { generation }
            | Request::DeleteBasis { generation, .. }
            | Request::FileBasis { generation, .. }
            | Request::MatchPlan { generation, .. }
            | Request::Changes { generation }
            | Request::Diff { generation, .. }
            | Request::List { generation, .. }
            | Request::Read { generation, .. }
            | Request::Save { generation, .. }
            | Request::Run { generation, .. }
            | Request::Stop { generation }
            | Request::OpenShell { generation }
            | Request::ShellOutput { generation, .. }
            | Request::ShellInput { generation, .. }
            | Request::ShellResize { generation, .. }
            | Request::CloseShell { generation, .. } => Some(*generation),
        };
        if expected.is_some()
            && (expected != Some(session.generation) || session.directory.is_none())
        {
            return Err("The selected repository changed. Reopen the file or command.".into());
        }
        match request {
            Request::ApplySet { files, .. } => change_set::apply(&session, files),
            Request::RecoverSet { restore, .. } => change_set::recover(&session, restore),
            Request::SetStatus { .. } => change_set::status(&session),
            Request::DeleteBasis {
                path,
                original,
                draft,
                ..
            } => {
                if original.is_none() {
                    return Err("Only an existing file can be proposed for deletion.".into());
                }
                let mut basis = file_basis(&session, &path, original.as_deref(), &draft, None)?;
                basis["schema"] = json!("selected-file-deletion-basis@1");
                basis["result_sha256"] =
                    json!(text_digest(&json!(["deleted-file@1", path]).to_string()));
                basis["result_bytes"] = json!(0);
                Ok(basis)
            }
            Request::FileBasis {
                path,
                original,
                draft,
                proposed,
                ..
            } => file_basis(
                &session,
                &path,
                original.as_deref(),
                &draft,
                proposed.as_deref(),
            ),
            Request::MatchPlan { .. } => {
                Err("Plan matching requires the live runtime host.".into())
            }
            Request::Status => {
                let run = session.run.as_mut().map(Run::status).transpose()?;
                let mut shells = vec![];
                for (id, shell) in &mut session.shells {
                    let mut value = shell.metadata()?;
                    value.as_object_mut().unwrap().remove("output");
                    value["id"] = json!(id);
                    shells.push(value);
                }
                Ok(
                    json!({"generation":session.generation,"root":session.root,"run":run,"shells":shells}),
                )
            }
            Request::Changes { .. } => {
                let root = session.root.as_ref().unwrap().clone();
                drop(session);
                let raw = git_read(
                    &root,
                    &[
                        "-c",
                        "status.renames=false",
                        "status",
                        "--porcelain=v1",
                        "-z",
                        "--untracked-files=all",
                        "--ignore-submodules=all",
                    ],
                )?;
                let mut entries = vec![];
                for record in raw.split(|b| *b == 0).filter(|v| !v.is_empty()).take(1000) {
                    if record.len() < 4 {
                        return Err("Git returned an incomplete change record.".into());
                    }
                    let path = std::str::from_utf8(&record[3..])
                        .map_err(|_| "A changed file name is not UTF-8.")?;
                    entries.push(json!({"path":path,"index":(record[0] as char).to_string(),"working":(record[1] as char).to_string()}));
                }
                Ok(
                    json!({"entries":entries,"truncated":raw.split(|b|*b==0).filter(|v|!v.is_empty()).count()>1000}),
                )
            }
            Request::Diff { path, .. } => {
                if parts(&path)?.is_empty() {
                    return Err("Choose a changed file.".into());
                }
                // Refuse symlinks/special files using the same handle-based reader
                // as Editor. A deleted file has no current bytes to inspect.
                let (parent, name) = file_parent(session.directory.as_ref().unwrap(), &path)?;
                let current = match open_at(&parent, &name, libc::O_RDONLY | libc::O_NONBLOCK, 0) {
                    Ok(mut f) => Some(read_text(&mut f)?),
                    Err(e) => {
                        let name = CString::new(name).map_err(error)?;
                        let mut info = std::mem::MaybeUninit::<libc::stat>::uninit();
                        let missing = unsafe {
                            libc::fstatat(
                                parent.as_raw_fd(),
                                name.as_ptr(),
                                info.as_mut_ptr(),
                                libc::AT_SYMLINK_NOFOLLOW,
                            )
                        } < 0
                            && std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT);
                        if !missing {
                            return Err(e);
                        }
                        None
                    }
                };
                let root = session.root.as_ref().unwrap().clone();
                drop(session);
                let state = git_read(
                    &root,
                    &[
                        "-c",
                        "status.renames=false",
                        "status",
                        "--porcelain=v1",
                        "-z",
                        "--untracked-files=all",
                        "--",
                        &path,
                    ],
                )?;
                let untracked = state.starts_with(b"?? ");
                let working = git_read(
                    &root,
                    &[
                        "diff",
                        "--no-ext-diff",
                        "--no-textconv",
                        "--no-renames",
                        "--no-color",
                        "--",
                        &path,
                    ],
                )?;
                let staged = git_read(
                    &root,
                    &[
                        "diff",
                        "--cached",
                        "--no-ext-diff",
                        "--no-textconv",
                        "--no-renames",
                        "--no-color",
                        "--",
                        &path,
                    ],
                )?;
                Ok(
                    json!({"path":path,"working":String::from_utf8_lossy(&working),"staged":String::from_utf8_lossy(&staged),"untracked":if untracked{current}else{None}}),
                )
            }
            Request::OpenShell { .. } => {
                if session.shells.len() >= 8 {
                    return Err("Close a shell tab before opening another (eight maximum).".into());
                }
                let shell = spawn_shell(session.root.as_ref().unwrap())?;
                session.next_shell += 1;
                let id = session.next_shell;
                session.shells.insert(id, shell);
                Ok(json!({"id":id}))
            }
            Request::CloseShell { id, .. } => {
                let mut shell = session
                    .shells
                    .remove(&id)
                    .ok_or("This shell session has ended.")?;
                shell.stop();
                Ok(json!({"closed":id}))
            }
            Request::ShellInput { id, data, .. } => {
                if data.len() > 8192 {
                    return Err("Paste smaller chunks into the terminal.".into());
                }
                let shell = session
                    .shells
                    .get_mut(&id)
                    .ok_or("This shell session has ended.")?;
                if shell.metadata()?["running"] != true {
                    return Err("This shell has exited.".into());
                }
                let tty = shell
                    .tty
                    .as_mut()
                    .ok_or("No terminal input is available.")?;
                let mut written = 0;
                let deadline = std::time::Instant::now() + std::time::Duration::from_secs(1);
                while written < data.len() {
                    match tty.write(&data.as_bytes()[written..]) {
                        Ok(0)=>return Err(format!("Terminal accepted {written} bytes before closing. Input was not replayed.")),
                        Ok(n)=>written+=n,
                        Err(e) if e.kind()==std::io::ErrorKind::WouldBlock=>{
                            if std::time::Instant::now()>deadline {return Err(format!("Terminal accepted {written} bytes before input stalled. Input was not replayed."));}
                            std::thread::sleep(std::time::Duration::from_millis(5));
                        },
                        Err(e)=>return Err(error(e)),
                    }
                }
                Ok(json!({"accepted_bytes":written}))
            }
            Request::ShellResize { id, cols, rows, .. } => {
                if !(2..=400).contains(&cols) || !(2..=160).contains(&rows) {
                    return Err("Invalid terminal dimensions.".into());
                }
                let shell = session
                    .shells
                    .get(&id)
                    .ok_or("This shell session has ended.")?;
                let size = libc::winsize {
                    ws_row: rows,
                    ws_col: cols,
                    ws_xpixel: 0,
                    ws_ypixel: 0,
                };
                if unsafe {
                    libc::ioctl(
                        shell.tty.as_ref().unwrap().as_raw_fd(),
                        libc::TIOCSWINSZ,
                        &size,
                    )
                } != 0
                {
                    return Err(error(std::io::Error::last_os_error()));
                }
                Ok(json!({"resized":true}))
            }
            Request::ShellOutput { id, after, .. } => {
                let shell = session
                    .shells
                    .get_mut(&id)
                    .ok_or("This shell session has ended.")?;
                let status = shell.metadata()?;
                let out = shell.output.lock().map_err(|_| "Output is unavailable.")?;
                if after > out.total {
                    return Err("The terminal output position is no longer valid.".into());
                }
                let first = out.total - out.bytes.len() as u64;
                let start = after.max(first);
                let bytes: Vec<u8> = out
                    .bytes
                    .iter()
                    .skip((start - first) as usize)
                    .take(16384)
                    .copied()
                    .collect();
                Ok(
                    json!({"data":bytes,"next":start+bytes.len() as u64,"omitted":first.saturating_sub(after),"running":status["running"],"exit_code":status["exit_code"]}),
                )
            }
            Request::List { path, .. } => listing(session.directory.as_ref().unwrap(), &path),
            Request::Read { path, .. } => {
                let (parent, name) = file_parent(session.directory.as_ref().unwrap(), &path)?;
                let text = read_text(&mut open_at(
                    &parent,
                    &name,
                    libc::O_RDONLY | libc::O_NONBLOCK,
                    0,
                )?)?;
                Ok(json!({"path":path,"content":text}))
            }
            Request::Save {
                path,
                original,
                content,
                ..
            } => {
                let _set_lock = change_set::guard(&session)?;
                save(
                    session.directory.as_ref().unwrap(),
                    &path,
                    original,
                    content,
                )
            }
            Request::Stop { .. } => {
                if let Some(run) = &mut session.run {
                    run.stop();
                    run.status()
                } else {
                    Ok(Value::Null)
                }
            }
            Request::Run { command, .. } => {
                if command.trim().is_empty() || command.len() > 8192 || command.contains('\0') {
                    return Err("Enter a command up to 8 KiB.".into());
                }
                if let Some(run) = &mut session.run {
                    if run.status()?["running"] == true {
                        return Err("A command is already running. Stop it first.".into());
                    }
                }
                session.run = None;
                let mut child = Command::new("/bin/bash")
                    .args(["-c", &command])
                    .current_dir(session.root.as_ref().unwrap())
                    .env("TERM", "dumb")
                    .env("NO_COLOR", "1")
                    .stdin(Stdio::null())
                    .stdout(Stdio::piped())
                    .stderr(Stdio::piped())
                    .process_group(0)
                    .spawn()
                    .map_err(error)?;
                let output = Arc::new(Mutex::new(Output::default()));
                fn drain(mut pipe: impl Read + Send + 'static, output: Arc<Mutex<Output>>) {
                    std::thread::spawn(move || {
                        let mut bytes = [0; 4096];
                        loop {
                            match pipe.read(&mut bytes) {
                                Ok(0) | Err(_) => break,
                                Ok(n) => {
                                    if let Ok(mut out) = output.lock() {
                                        out.push(&bytes[..n]);
                                    } else {
                                        break;
                                    }
                                }
                            }
                        }
                    });
                }
                drain(child.stdout.take().unwrap(), output.clone());
                drain(child.stderr.take().unwrap(), output.clone());
                let pgid = child.id() as i32;
                session.run = Some(Run {
                    child,
                    pgid,
                    output,
                    command,
                    exit: None,
                    stopped: false,
                    tty: None,
                    reader_stop: Arc::new(AtomicBool::new(false)),
                });
                session.run.as_mut().unwrap().status()
            }
        }
    }
}

fn text_digest(text: &str) -> String {
    format!("{:x}", Sha256::digest(text.as_bytes()))
}

// Only the selected file is measured. Other working-tree files and the index
// are outside this basis. These reads do not create a commit or Git object.
fn basis_disk(dir: &File, path: &str) -> Result<Option<String>, String> {
    let (parent, name) = file_parent(dir, path)?;
    let name = CString::new(name).map_err(|_| "Invalid file name.")?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NONBLOCK | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        let error_value = std::io::Error::last_os_error();
        if error_value.raw_os_error() == Some(libc::ENOENT) {
            return Ok(None);
        }
        return Err(error(error_value));
    }
    let mut file = unsafe { File::from_raw_fd(fd) };
    Ok(Some(read_text(&mut file)?))
}
fn basis_head(root: &Path) -> Result<String, String> {
    let bytes = git_read(root, &["rev-parse", "--verify", "HEAD^{commit}"])
        .map_err(|_| "A readable committed Git HEAD is required for a plan-linked file. Make an initial commit or resolve the repository problem, then share again.")?;
    let head = std::str::from_utf8(&bytes)
        .map_err(error)?
        .trim()
        .to_owned();
    if ![40, 64].contains(&head.len()) || !head.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("Git did not return a concrete commit identity.".into());
    }
    Ok(head)
}
fn basis_root(session: &Session) -> Result<&Path, String> {
    let root = session
        .root
        .as_deref()
        .ok_or("Choose a repository first.")?;
    let held = session
        .directory
        .as_ref()
        .ok_or("Choose a repository first.")?
        .metadata()
        .map_err(error)?;
    let now = File::open(root).map_err(error)?.metadata().map_err(error)?;
    if held.dev() != now.dev() || held.ino() != now.ino() {
        return Err("The selected repository folder was replaced. Open it again.".into());
    }
    Ok(root)
}
fn file_basis(
    session: &Session,
    path: &str,
    original: Option<&str>,
    draft: &str,
    proposed: Option<&str>,
) -> Result<Value, String> {
    if draft.len() > 24000
        || draft.contains('\0')
        || original.is_some_and(|s| s.len() > FILE_LIMIT || s.contains('\0'))
        || proposed.is_some_and(|s| s.len() > 32000 || s.contains('\0'))
    {
        return Err("This file exceeds the plan-linked snapshot limits.".into());
    }
    let root = basis_root(session)?;
    let head = basis_head(root)?;
    let dir = session.directory.as_ref().unwrap();
    let disk = basis_disk(dir, path)?;
    if disk.as_deref() != original {
        return Err("The source file changed on disk. Reload or resolve your draft, then share a fresh snapshot.".into());
    }
    let disk_sha256 = disk.as_deref().map(text_digest);
    let draft_sha256 = text_digest(draft);
    let id = text_digest(
        &json!([
            "selected-file-basis@1",
            head,
            path,
            disk_sha256,
            draft_sha256
        ])
        .to_string(),
    );
    if basis_head(root)? != head || basis_disk(dir, path)? != disk {
        return Err(
            "The commit or source file changed while taking its snapshot. Share it again.".into(),
        );
    }
    basis_root(session)?;
    Ok(
        json!({"schema":"selected-file-basis@1", "scope":"selected-file-only", "basis_id":id, "head":head, "path":path, "disk_sha256":disk_sha256, "draft_sha256":draft_sha256, "draft_bytes":draft.len(), "unsaved":original != Some(draft), "result_sha256":proposed.map(text_digest), "result_bytes":proposed.map(str::len)}),
    )
}

// Fixed read-only Git operations. Bound both execution time and captured bytes;
// disable external diff drivers, text conversion, prompts and optional locks.
fn git_read(root: &Path, args: &[&str]) -> Result<Vec<u8>, String> {
    let mut cmd = Command::new("git");
    cmd.arg("--no-pager")
        .arg("--literal-pathspecs")
        .args([
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "diff.ignoreSubmodules=all",
        ])
        .args(args)
        .current_dir(root)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for key in [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_EXTERNAL_DIFF",
    ] {
        cmd.env_remove(key);
    }
    let mut child = cmd.spawn().map_err(error)?;
    fn capture(mut stream: impl Read + Send + 'static) -> std::thread::JoinHandle<(Vec<u8>, bool)> {
        std::thread::spawn(move || {
            let mut bytes = vec![];
            let mut buf = [0; 8192];
            let mut truncated = false;
            while let Ok(n) = stream.read(&mut buf) {
                if n == 0 {
                    break;
                }
                let keep = n.min((512usize * 1024).saturating_sub(bytes.len()));
                bytes.extend_from_slice(&buf[..keep]);
                truncated |= keep < n;
            }
            (bytes, truncated)
        })
    }
    let output = capture(child.stdout.take().unwrap());
    let errors = capture(child.stderr.take().unwrap());
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    let result = loop {
        match child.try_wait() {
            Ok(Some(s)) => break Ok(s),
            Ok(None) => {}
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                break Err(error(e));
            }
        }
        if std::time::Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            break Err("Git review timed out. Narrow the repository changes and try again.".into());
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    };
    let (bytes, large) = output.join().map_err(|_| "Git output was unavailable.")?;
    let (err, _) = errors.join().map_err(|_| "Git output was unavailable.")?;
    if !result?.success() {
        return Err(format!("Git review: {}", String::from_utf8_lossy(&err)));
    }
    if large {
        return Err(
            "This change exceeds the 512 KiB review limit. Inspect it in your external Git tools."
                .into(),
        );
    }
    Ok(bytes)
}

fn spawn_shell(root: &Path) -> Result<Run, String> {
    let (mut master, mut slave) = (-1, -1);
    let size = libc::winsize {
        ws_row: 24,
        ws_col: 80,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    if unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null(),
            &size,
        )
    } != 0
    {
        return Err(error(std::io::Error::last_os_error()));
    }
    let mut reader = unsafe { File::from_raw_fd(master) };
    let slave = unsafe { File::from_raw_fd(slave) };
    for fd in [reader.as_raw_fd(), slave.as_raw_fd()] {
        if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
            return Err(error(std::io::Error::last_os_error()));
        }
    }
    if unsafe { libc::fcntl(reader.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) } < 0 {
        return Err(error(std::io::Error::last_os_error()));
    }
    let writer = reader.try_clone().map_err(error)?;
    let mut command = Command::new("/bin/bash");
    command
        .args(["--noprofile", "--norc", "-i"])
        .current_dir(root)
        .env("TERM", "xterm-256color")
        .env("PS1", "\\w $ ")
        .stdin(Stdio::from(slave.try_clone().map_err(error)?))
        .stdout(Stdio::from(slave.try_clone().map_err(error)?))
        .stderr(Stdio::from(slave));
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::ioctl(0, libc::TIOCSCTTY, 0) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let child = command.spawn().map_err(error)?;
    let pgid = child.id() as i32;
    let output = Arc::new(Mutex::new(Output::default()));
    let sink = output.clone();
    let reader_stop = Arc::new(AtomicBool::new(false));
    let stop = reader_stop.clone();
    std::thread::spawn(move || {
        let mut bytes = [0; 4096];
        while !stop.load(Ordering::Relaxed) {
            match reader.read(&mut bytes) {
                Ok(0) => break,
                Ok(n) => {
                    if let Ok(mut out) = sink.lock() {
                        out.push(&bytes[..n]);
                    } else {
                        break;
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(std::time::Duration::from_millis(10))
                }
                Err(_) => break,
            }
        }
    });
    Ok(Run {
        child,
        pgid,
        output,
        command: "Interactive shell".into(),
        exit: None,
        stopped: false,
        tty: Some(writer),
        reader_stop,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        os::unix::fs::symlink,
        sync::atomic::{AtomicU64, Ordering},
        time::{Duration, Instant},
    };
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Scratch(PathBuf);
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn setup() -> (Scratch, Workbench, u64) {
        let root = std::env::temp_dir().join(format!(
            "super-development-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&root).unwrap();
        assert!(Command::new("git")
            .args(["init", "-q"])
            .arg(&root)
            .status()
            .unwrap()
            .success());
        let w = Workbench::default();
        let g = w.choose(root.clone()).unwrap()["generation"]
            .as_u64()
            .unwrap();
        (Scratch(root), w, g)
    }
    #[test]
    fn plan_matching_requires_the_selected_directory_and_generation() {
        let (s, w, g) = setup();
        assert_eq!(w.matching_root(g).unwrap(), s.0.canonicalize().unwrap());
        assert!(w.matching_root(g + 1).is_err());
        let moved = s.0.with_extension("moved");
        std::fs::rename(&s.0, &moved).unwrap();
        std::fs::create_dir(&s.0).unwrap();
        assert!(w.matching_root(g).unwrap_err().contains("replaced"));
        std::fs::remove_dir(&s.0).unwrap();
        std::fs::rename(moved, &s.0).unwrap();
        assert!(serde_json::from_value::<Request>(json!({"operation":"match_plan", "generation":g, "task_ref":"dt_1", "revision":1, "world":[null,null,"epoch"], "path":"/page-supplied"})).is_err());
    }
    fn read(w: &Workbench, g: u64, p: &str) -> Result<Value, String> {
        w.request(Request::Read {
            generation: g,
            path: p.into(),
        })
    }
    fn wait(w: &Workbench) -> Value {
        let end = Instant::now() + Duration::from_secs(5);
        loop {
            let s = w.request(Request::Status).unwrap();
            if s["run"]["running"] == false {
                return s["run"].clone();
            }
            assert!(Instant::now() < end);
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    fn git_test(root: &Path, args: &[&str]) {
        assert!(Command::new("git")
            .args(args)
            .current_dir(root)
            .status()
            .unwrap()
            .success());
    }
    fn commit_file(root: &Path) {
        git_test(root, &["add", "."]);
        git_test(
            root,
            &[
                "-c",
                "user.name=Source test",
                "-c",
                "user.email=source@example.invalid",
                "commit",
                "-qm",
                "Source",
            ],
        );
    }
    fn basis(
        w: &Workbench,
        g: u64,
        path: &str,
        original: Option<&str>,
        draft: &str,
        proposed: Option<&str>,
    ) -> Result<Value, String> {
        w.request(Request::FileBasis {
            generation: g,
            path: path.into(),
            original: original.map(str::to_owned),
            draft: draft.into(),
            proposed: proposed.map(str::to_owned),
        })
    }
    #[test]
    fn file_basis_pins_exact_bytes_commit_and_result_without_writes() {
        let (s, w, g) = setup();
        std::fs::write(s.0.join("file.txt"), "abc").unwrap();
        commit_file(&s.0);
        let before = git_read(&s.0, &["status", "--porcelain=v1"]).unwrap();
        let a = basis(&w, g, "file.txt", Some("abc"), "abc\n", Some("abc\r\n")).unwrap();
        assert_eq!(
            a["disk_sha256"],
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            a["draft_sha256"],
            "edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb"
        );
        assert_eq!(
            a["result_sha256"],
            "552bab6864c7a7b69a502ed1854b9245c0e1a30f008aaa0b281da62585fdb025"
        );
        assert_eq!(a["draft_bytes"], 4);
        assert_eq!(a["result_bytes"], 5);
        assert_eq!(a["unsaved"], true);
        let b = basis(&w, g, "file.txt", Some("abc"), "abc\n", Some("different")).unwrap();
        assert_eq!(a["basis_id"], b["basis_id"]);
        assert_ne!(a["result_sha256"], b["result_sha256"]);
        assert_eq!(a["head"], basis_head(&s.0).unwrap());
        assert_eq!(
            before,
            git_read(&s.0, &["status", "--porcelain=v1"]).unwrap()
        );
        assert_eq!(
            std::fs::read_to_string(s.0.join("file.txt")).unwrap(),
            "abc"
        );
    }
    #[test]
    fn file_basis_refuses_stale_disk_and_distinguishes_a_new_commit() {
        let (s, w, g) = setup();
        std::fs::write(s.0.join("file.txt"), "old").unwrap();
        commit_file(&s.0);
        let old = basis(&w, g, "file.txt", Some("old"), "draft", None).unwrap();
        std::fs::write(s.0.join("file.txt"), "external").unwrap();
        assert!(basis(&w, g, "file.txt", Some("old"), "draft", None)
            .unwrap_err()
            .contains("changed on disk"));
        std::fs::write(s.0.join("file.txt"), "old").unwrap();
        git_test(
            &s.0,
            &[
                "-c",
                "user.name=Source test",
                "-c",
                "user.email=source@example.invalid",
                "commit",
                "--allow-empty",
                "-qm",
                "Next commit",
            ],
        );
        assert_ne!(
            old["basis_id"],
            basis(&w, g, "file.txt", Some("old"), "draft", None).unwrap()["basis_id"]
        );
        assert!(basis(&w, g + 1, "file.txt", Some("old"), "draft", None).is_err());
    }
    #[test]
    fn file_basis_distinguishes_missing_from_empty_and_refuses_uncommitted_head() {
        let (s, w, g) = setup();
        assert!(basis(&w, g, "new.txt", None, "", None)
            .unwrap_err()
            .contains("committed Git HEAD"));
        std::fs::write(s.0.join("seed"), "seed").unwrap();
        commit_file(&s.0);
        let new = basis(&w, g, "new.txt", None, "", None).unwrap();
        assert!(new["disk_sha256"].is_null());
        std::fs::write(s.0.join("new.txt"), "").unwrap();
        assert!(basis(&w, g, "new.txt", None, "", None).is_err());
        let empty = basis(&w, g, "new.txt", Some(""), "", None).unwrap();
        assert_ne!(new["basis_id"], empty["basis_id"]);
        symlink(s.0.join("seed"), s.0.join("alias")).unwrap();
        assert!(basis(&w, g, "alias", None, "", None).is_err());
        assert!(basis(&w, g, "../outside", None, "", None).is_err());
        assert!(basis(&w, g, "new.txt", Some(""), &"x".repeat(24001), None).is_err());
    }
    #[test]
    fn review_separates_index_worktree_and_untracked_without_writes() {
        let (s, w, g) = setup();
        let name = "space [literal].txt";
        std::fs::write(s.0.join(name), "base\n").unwrap();
        std::fs::write(s.0.join("deleted.txt"), "removed\n").unwrap();
        git_test(&s.0, &["add", "."]);
        git_test(
            &s.0,
            &[
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.invalid",
                "commit",
                "-qm",
                "base",
            ],
        );
        std::fs::write(s.0.join(name), "staged\n").unwrap();
        git_test(&s.0, &["--literal-pathspecs", "add", "--", name]);
        std::fs::write(s.0.join(name), "working\n").unwrap();
        std::fs::write(s.0.join("new.txt"), "untracked\n").unwrap();
        std::fs::write(s.0.join("empty.txt"), "").unwrap();
        std::fs::remove_file(s.0.join("deleted.txt")).unwrap();
        let index = std::fs::read(s.0.join(".git/index")).unwrap();
        let changes = w.request(Request::Changes { generation: g }).unwrap();
        assert_eq!(changes["entries"].as_array().unwrap().len(), 4);
        assert!(changes["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|e| e["path"] == name && e["index"] == "M" && e["working"] == "M"));
        let diff = |path: &str| {
            w.request(Request::Diff {
                generation: g,
                path: path.into(),
            })
            .unwrap()
        };
        let d = diff(name);
        assert!(d["working"].as_str().unwrap().contains("+working"));
        assert!(d["staged"].as_str().unwrap().contains("+staged"));
        assert_eq!(diff("new.txt")["untracked"], "untracked\n");
        assert_eq!(diff("empty.txt")["untracked"], "");
        assert!(diff("deleted.txt")["working"]
            .as_str()
            .unwrap()
            .contains("-removed"));
        assert_eq!(std::fs::read(s.0.join(".git/index")).unwrap(), index);
        assert_eq!(
            std::fs::read_to_string(s.0.join(name)).unwrap(),
            "working\n"
        );
        assert!(w.request(Request::Changes { generation: g + 1 }).is_err());
    }
    #[test]
    fn review_handles_initial_index_and_refuses_non_text() {
        let (s, w, g) = setup();
        std::fs::write(s.0.join("first.txt"), "first\n").unwrap();
        git_test(&s.0, &["add", "first.txt"]);
        let d = w
            .request(Request::Diff {
                generation: g,
                path: "first.txt".into(),
            })
            .unwrap();
        assert!(d["staged"].as_str().unwrap().contains("+first"));
        std::fs::write(s.0.join("binary"), [0, 1]).unwrap();
        std::fs::write(s.0.join("large"), vec![b'x'; FILE_LIMIT + 1]).unwrap();
        for path in ["binary", "large"] {
            assert!(w
                .request(Request::Diff {
                    generation: g,
                    path: path.into()
                })
                .is_err());
        }
    }
    #[test]
    fn chooser_and_generation_define_checkout() {
        let (s, w, g) = setup();
        std::fs::write(s.0.join("hello.txt"), "hello").unwrap();
        assert_eq!(read(&w, g, "hello.txt").unwrap()["content"], "hello");
        assert!(read(&w, g + 1, "hello.txt").is_err());
        assert!(Workbench::default()
            .request(Request::Read {
                generation: 0,
                path: "x".into()
            })
            .is_err());
    }
    #[test]
    fn paths_cannot_escape_or_enter_git() {
        let (_s, w, g) = setup();
        for p in [
            "../outside",
            "/etc/passwd",
            ".git/config",
            "src/../../outside",
        ] {
            assert!(read(&w, g, p).is_err(), "{p}");
        }
        assert!(w
            .request(Request::List {
                generation: g,
                path: ".git".into()
            })
            .is_err());
    }
    #[test]
    fn symlink_directories_and_files_are_refused() {
        let (s, w, g) = setup();
        symlink("/tmp", s.0.join("outside")).unwrap();
        symlink("/etc/passwd", s.0.join("secret")).unwrap();
        assert!(read(&w, g, "secret").is_err());
        assert!(read(&w, g, "outside/file").is_err());
        assert!(w
            .request(Request::Save {
                generation: g,
                path: "secret".into(),
                original: None,
                content: "x".into()
            })
            .is_err());
    }
    #[test]
    fn text_limits_and_special_files() {
        let (s, w, g) = setup();
        std::fs::write(s.0.join("binary"), [0, 1, 2]).unwrap();
        std::fs::write(s.0.join("large"), vec![b'x'; FILE_LIMIT + 1]).unwrap();
        std::fs::create_dir(s.0.join("dir")).unwrap();
        let fifo = CString::new(s.0.join("pipe").to_str().unwrap()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        for p in ["binary", "large", "dir", "pipe"] {
            assert!(read(&w, g, p).is_err(), "{p}");
        }
    }
    #[test]
    fn save_refuses_outside_changes_and_keeps_permissions() {
        let (s, w, g) = setup();
        let path = s.0.join("test.sh");
        std::fs::write(&path, "old").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        w.request(Request::Save {
            generation: g,
            path: "test.sh".into(),
            original: Some("old".into()),
            content: "new".into(),
        })
        .unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "new");
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o755
        );
        assert!(w
            .request(Request::Save {
                generation: g,
                path: "test.sh".into(),
                original: Some("old".into()),
                content: "lost".into()
            })
            .is_err());
        assert_eq!(std::fs::read_to_string(path).unwrap(), "new");
    }
    #[test]
    fn new_files_do_not_overwrite_existing_files() {
        let (s, w, g) = setup();
        w.request(Request::Save {
            generation: g,
            path: "new.txt".into(),
            original: None,
            content: "first".into(),
        })
        .unwrap();
        assert!(w
            .request(Request::Save {
                generation: g,
                path: "new.txt".into(),
                original: None,
                content: "second".into()
            })
            .is_err());
        assert_eq!(
            std::fs::read_to_string(s.0.join("new.txt")).unwrap(),
            "first"
        );
    }
    #[test]
    fn command_uses_checkout_and_reports_real_exit() {
        let (s, w, g) = setup();
        w.request(Request::Run {
            generation: g,
            command: "pwd; printf stdout; printf stderr >&2; exit 7".into(),
        })
        .unwrap();
        let result = wait(&w);
        std::thread::sleep(Duration::from_millis(30));
        let out = w.request(Request::Status).unwrap()["run"]["output"]
            .as_str()
            .unwrap()
            .to_owned();
        assert!(out.contains(s.0.to_str().unwrap()));
        assert!(out.contains("stdout") && out.contains("stderr"));
        assert_eq!(result["exit_code"], 7);
    }
    #[test]
    fn one_command_and_repository_switch_refusal() {
        let (s, w, g) = setup();
        w.request(Request::Run {
            generation: g,
            command: "sleep 30".into(),
        })
        .unwrap();
        assert!(w
            .request(Request::Run {
                generation: g,
                command: "true".into()
            })
            .is_err());
        assert!(w.choose(s.0.clone()).is_err());
        let result = w.request(Request::Stop { generation: g }).unwrap();
        assert_eq!(result["running"], false);
        assert_eq!(result["stopped"], true);
        w.choose(s.0.clone()).unwrap();
        assert!(read(&w, g, "anything").is_err());
    }
    #[test]
    fn output_is_bounded_with_visible_omission() {
        let (_s, w, g) = setup();
        w.request(Request::Run {
            generation: g,
            command: "head -c 400000 /dev/zero | tr '\\0' x".into(),
        })
        .unwrap();
        wait(&w);
        std::thread::sleep(Duration::from_millis(50));
        let status = w.request(Request::Status).unwrap();
        assert_eq!(
            status["run"]["output"].as_str().unwrap().len(),
            OUTPUT_LIMIT
        );
        assert_eq!(
            status["run"]["omitted_bytes"].as_u64().unwrap(),
            400000 - OUTPUT_LIMIT as u64
        );
    }
    #[test]
    fn shutdown_stops_running_work() {
        let (_s, w, g) = setup();
        w.request(Request::Run {
            generation: g,
            command: "sleep 30".into(),
        })
        .unwrap();
        w.shutdown();
        assert_eq!(w.request(Request::Status).unwrap()["run"]["stopped"], true);
    }
    #[test]
    fn completed_process_id_is_reserved_until_cleanup() {
        let (_s, w, g) = setup();
        w.request(Request::Run {
            generation: g,
            command: "exit 0".into(),
        })
        .unwrap();
        let pid = w.0.lock().unwrap().run.as_ref().unwrap().pgid;
        assert_eq!(wait(&w)["exit_code"], 0);
        assert_eq!(unsafe { libc::kill(pid, 0) }, 0);
        w.shutdown();
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
        assert_eq!(
            std::io::Error::last_os_error().raw_os_error(),
            Some(libc::ESRCH)
        );
    }
    fn shell_text(w: &Workbench, g: u64, id: u64) -> String {
        let v = w
            .request(Request::ShellOutput {
                generation: g,
                id,
                after: 0,
            })
            .unwrap();
        String::from_utf8_lossy(
            &v["data"]
                .as_array()
                .unwrap()
                .iter()
                .map(|n| n.as_u64().unwrap() as u8)
                .collect::<Vec<_>>(),
        )
        .to_string()
    }
    #[test]
    fn interactive_shells_have_separate_outputs_resize_and_interrupt() {
        let (_s, w, g) = setup();
        let a = w.request(Request::OpenShell { generation: g }).unwrap()["id"]
            .as_u64()
            .unwrap();
        let b = w.request(Request::OpenShell { generation: g }).unwrap()["id"]
            .as_u64()
            .unwrap();
        w.request(Request::ShellResize {
            generation: g,
            id: a,
            cols: 91,
            rows: 33,
        })
        .unwrap();
        w.request(Request::ShellInput {
            generation: g,
            id: a,
            data: "stty size; printf 'ALPHA_READY\n'; sleep 30\r".into(),
        })
        .unwrap();
        w.request(Request::ShellInput {
            generation: g,
            id: b,
            data: "printf 'BETA_%s\\n' READY\r".into(),
        })
        .unwrap();
        let end = Instant::now() + Duration::from_secs(5);
        while !shell_text(&w, g, a).contains("33 91")
            || !shell_text(&w, g, b).contains("BETA_READY")
        {
            assert!(Instant::now() < end);
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(!shell_text(&w, g, a).contains("BETA_READY"));
        let prompts = shell_text(&w, g, a).matches(" $ ").count();
        w.request(Request::ShellInput {
            generation: g,
            id: a,
            data: "\u{3}".into(),
        })
        .unwrap();
        while shell_text(&w, g, a).matches(" $ ").count() <= prompts {
            assert!(Instant::now() < end);
            std::thread::sleep(Duration::from_millis(20));
        }
        w.request(Request::ShellInput {
            generation: g,
            id: a,
            data: "printf 'AFTER_%s\\n' INTERRUPT\r".into(),
        })
        .unwrap();
        while !shell_text(&w, g, a).contains("AFTER_INTERRUPT") {
            assert!(Instant::now() < end);
            std::thread::sleep(Duration::from_millis(20));
        }
        w.request(Request::CloseShell {
            generation: g,
            id: a,
        })
        .unwrap();
        let state = w.request(Request::Status).unwrap();
        assert_eq!(state["shells"].as_array().unwrap().len(), 1);
        assert_eq!(state["shells"][0]["id"], b);
        assert_eq!(state["shells"][0]["running"], true);
        assert!(w
            .request(Request::ShellInput {
                generation: g,
                id: a,
                data: "x".into()
            })
            .is_err());
        assert!(w
            .request(Request::ShellInput {
                generation: g + 1,
                id: b,
                data: "x".into()
            })
            .is_err());
        w.shutdown();
    }
    #[test]
    fn shell_limits_and_repository_switch_are_enforced() {
        let (s, w, g) = setup();
        for _ in 0..8 {
            w.request(Request::OpenShell { generation: g }).unwrap();
        }
        assert!(w.request(Request::OpenShell { generation: g }).is_err());
        assert!(w.choose(s.0.clone()).is_err());
        assert!(w
            .request(Request::ShellResize {
                generation: g,
                id: 1,
                cols: 0,
                rows: 0
            })
            .is_err());
        assert!(w
            .request(Request::ShellInput {
                generation: g,
                id: 1,
                data: "x".repeat(8193)
            })
            .is_err());
        assert!(w
            .request(Request::ShellOutput {
                generation: g,
                id: 1,
                after: u64::MAX
            })
            .is_err());
        w.shutdown();
    }
}
