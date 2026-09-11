//! A supervised trial of a retained build. The original app stays open.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Read,
    os::unix::{fs::PermissionsExt, process::CommandExt},
    path::{Component, Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
#[derive(Clone, Default)]
pub struct Previews(Arc<Mutex<Option<Trial>>>);
struct Trial {
    child: Child,
    world: [Value; 3],
    build: String,
    directory: PathBuf,
    closed: bool,
    failure: Option<String>,
    started: Instant,
    diagnostics: Arc<Mutex<Diagnostics>>,
}
const READY_MARKER: &str = "[super-preview-frame-painted@1]";
#[derive(Default)]
struct Diagnostics {
    output: Vec<u8>,
    ready: bool,
}
impl Diagnostics {
    fn push(&mut self, bytes: &[u8]) {
        self.output.extend_from_slice(bytes);
        if self
            .output
            .windows(READY_MARKER.len())
            .any(|w| w == READY_MARKER.as_bytes())
        {
            self.ready = true;
        }
        if self.output.len() > 8192 {
            self.output.drain(..self.output.len() - 8192);
        }
    }
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.output)
            .replace(READY_MARKER, "")
            .trim()
            .to_owned()
    }
}
#[derive(Serialize, Deserialize)]
struct Entry {
    path: String,
    mode: u32,
    bytes: u64,
    sha256: String,
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn read(path: &Path, limit: u64) -> Result<Vec<u8>, String> {
    let f = fs::File::open(path).map_err(|e| e.to_string())?;
    let m = f.metadata().map_err(|e| e.to_string())?;
    if !m.is_file() || m.len() > limit {
        return Err("Build file is unavailable or too large.".into());
    }
    let mut bytes = Vec::new();
    f.take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() as u64 > limit {
        return Err("Build file grew during verification.".into());
    }
    Ok(bytes)
}
fn bounded(path: &Path, base: &Path) -> Result<PathBuf, String> {
    let p = path.canonicalize().map_err(|e| e.to_string())?;
    if !p.starts_with(base) {
        return Err("Build file escaped its retained bundle.".into());
    }
    Ok(p)
}
fn id(id: &str) -> Result<(), String> {
    if !id.starts_with("build-") || !id.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-') {
        return Err("Invalid build identifier.".into());
    }
    Ok(())
}
fn world_base(data: &Path, world: &[Value; 3]) -> PathBuf {
    data.join("accepted-builds")
        .join(hash(json!([world[0], world[1]]).to_string().as_bytes()))
}
fn prepare(
    data: &Path,
    world: &[Value; 3],
    build: &str,
    attempt: &Value,
    dest: &Path,
) -> Result<(), String> {
    id(build)?;
    let base = world_base(data, world)
        .canonicalize()
        .map_err(|e| e.to_string())?;
    let bundle = bounded(&base.join(build), &base)?;
    let row: Value =
        serde_json::from_slice(&read(&base.join(format!("{build}.json")), 256 * 1024)?)
            .map_err(|e| e.to_string())?;
    if row["state"] != "completed"
        || row["build_id"] != build
        || row["attempt_ref"] != attempt["id"]
        || attempt["status"] != "accepted"
        || row["snapshot_sha256"] != attempt["acceptance"]["snapshot_sha256"]
        || row["result"]["snapshot_sha256"] != row["snapshot_sha256"]
        || row["result"]["result_sha256"] != attempt["acceptance"]["result_sha256"]
    {
        return Err("This build does not match the accepted review.".into());
    }
    let executable = bounded(
        Path::new(
            row["result"]["artifact"]["path"]
                .as_str()
                .ok_or("Build has no executable.")?,
        ),
        &bundle,
    )?;
    let bytes = read(&executable, 256 * 1024 * 1024)?;
    if !bytes.starts_with(b"\x7fELF") || json!(hash(&bytes)) != row["result"]["artifact"]["sha256"]
    {
        return Err("The built executable changed. Build it again before trying it.".into());
    }
    let output = executable
        .parent()
        .and_then(Path::parent)
        .ok_or("Build bundle is incomplete.")?;
    let manifest: Value = serde_json::from_slice(&read(&output.join("manifest.json"), 256 * 1024)?)
        .map_err(|e| e.to_string())?;
    let entries: Vec<Entry> =
        serde_json::from_value(manifest["files"].clone()).map_err(|e| e.to_string())?;
    if entries.is_empty()
        || entries.len() > 1024
        || json!(hash(
            &serde_json::to_vec(&entries).map_err(|e| e.to_string())?
        )) != row["snapshot_sha256"]
    {
        return Err("The captured source manifest changed.".into());
    }
    let snapshot = bounded(&output.join("snapshot"), &bundle)?;
    let mut previous = String::new();
    let mut total = 0u64;
    for entry in entries {
        let path = Path::new(&entry.path);
        if entry.path <= previous
            || path
                .components()
                .any(|c| !matches!(c, Component::Normal(_)))
            || !matches!(entry.mode, 0o644 | 0o755)
        {
            return Err("Invalid captured source path or mode.".into());
        }
        previous = entry.path.clone();
        total = total
            .checked_add(entry.bytes)
            .ok_or("Source is too large.")?;
        if total > 32 * 1024 * 1024 {
            return Err("Source is too large.".into());
        }
        let source = bounded(&snapshot.join(path), &snapshot)?;
        let content = read(&source, 2 * 1024 * 1024)?;
        if content.len() as u64 != entry.bytes || hash(&content) != entry.sha256 {
            return Err("Captured source changed. Build it again before trying it.".into());
        }
        let target = dest.join("source").join(path);
        fs::create_dir_all(target.parent().unwrap()).map_err(|e| e.to_string())?;
        fs::write(&target, content).map_err(|e| e.to_string())?;
        fs::set_permissions(target, fs::Permissions::from_mode(entry.mode))
            .map_err(|e| e.to_string())?;
    }
    if !dest.join("source/ampd/mix.exs").is_file() {
        return Err("Captured runtime is missing.".into());
    }
    fs::write(dest.join("super-cockpit"), bytes).map_err(|e| e.to_string())?;
    fs::set_permissions(
        dest.join("super-cockpit"),
        fs::Permissions::from_mode(0o700),
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}
impl Trial {
    fn poll(&mut self) -> Result<(), String> {
        if !self.closed {
            if let Some(status) = self.child.try_wait().map_err(|e| e.to_string())? {
                unsafe {
                    libc::kill(-(self.child.id() as i32), libc::SIGTERM);
                }
                self.closed = true;
                if !status.success() {
                    self.failure = Some(match status.code() {
                        Some(code) => format!("Preview exited with code {code}."),
                        None => "Preview stopped unexpectedly.".into(),
                    });
                }
                let _ = fs::remove_dir_all(&self.directory);
            }
        }
        Ok(())
    }
    fn state(&self) -> &str {
        if self.failure.is_some() {
            "failed"
        } else if self.closed {
            "closed"
        } else if self.diagnostics.lock().is_ok_and(|d| d.ready) {
            "ready"
        } else if self.started.elapsed() >= Duration::from_secs(15) {
            "unconfirmed"
        } else {
            "starting"
        }
    }
    fn close(&mut self) -> Result<(), String> {
        self.poll()?;
        if !self.closed {
            unsafe {
                libc::kill(-(self.child.id() as i32), libc::SIGTERM);
            }
            for _ in 0..20 {
                if self.child.try_wait().map_err(|e| e.to_string())?.is_some() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            if self.child.try_wait().map_err(|e| e.to_string())?.is_none() {
                unsafe {
                    libc::kill(-(self.child.id() as i32), libc::SIGKILL);
                }
                self.child.wait().map_err(|e| e.to_string())?;
            }
            self.closed = true;
            let _ = fs::remove_dir_all(&self.directory);
        }
        Ok(())
    }
}
impl Previews {
    pub fn shutdown(&self) {
        if let Ok(mut guard) = self.0.lock() {
            if let Some(t) = guard.as_mut() {
                let _ = t.close();
            }
        }
    }

    pub fn start(
        &self,
        data: &Path,
        world: [Value; 3],
        build: String,
        attempt: Value,
    ) -> Result<Value, String> {
        let mut guard = self.0.lock().map_err(|_| "Preview is busy.")?;
        if let Some(t) = guard.as_mut() {
            t.poll()?;
            if !t.closed {
                return Err("Close the current preview before trying another build.".into());
            }
        }
        let directory = data.join("build-previews").join(format!(
            "trial-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(|e| e.to_string())?
                .as_nanos()
        ));
        fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
            .map_err(|e| e.to_string())?;
        let launch = (|| -> Result<Child, String> {
            prepare(data, &world, &build, &attempt, &directory)?;
            let mut command = Command::new(directory.join("super-cockpit"));
            command
                .current_dir(directory.join("source"))
                .env("AMPD_DIR", directory.join("source/ampd"))
                .env("XDG_DATA_HOME", directory.join("data"))
                .env("XDG_STATE_HOME", directory.join("state"))
                .env("XDG_CONFIG_HOME", directory.join("config"))
                .env("SUPER_WORLD_MODE", "ephemeral")
                .env_remove("SUPER_WORLD")
                .env("SUPER_COCKPIT_FIXTURE", "0")
                .env("SUPER_COCKPIT_CARRIER", "0")
                .env("SUPER_COCKPIT_PANE", "0")
                .env("SUPER_BUILD_PREVIEW", "1")
                .env_remove("OPENAI_API_KEY")
                .env_remove("ANTHROPIC_API_KEY")
                .env_remove("CODEX_API_KEY")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::piped());
            let parent = unsafe { libc::getpid() };
            unsafe {
                command.pre_exec(move || {
                    if libc::setpgid(0, 0) != 0
                        || libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) != 0
                    {
                        return Err(std::io::Error::last_os_error());
                    }
                    if libc::getppid() != parent {
                        return Err(std::io::Error::from_raw_os_error(libc::ESRCH));
                    }
                    Ok(())
                });
            }
            command.spawn().map_err(|e| e.to_string())
        })();
        match launch {
            Ok(mut child) => {
                let diagnostics = Arc::new(Mutex::new(Diagnostics::default()));
                let sink = diagnostics.clone();
                let mut errors = child
                    .stderr
                    .take()
                    .ok_or("Preview output is unavailable.")?;
                std::thread::spawn(move || {
                    let mut bytes = [0u8; 2048];
                    loop {
                        match errors.read(&mut bytes) {
                            Ok(0) | Err(_) => break,
                            Ok(n) => {
                                if let Ok(mut d) = sink.lock() {
                                    d.push(&bytes[..n]);
                                }
                            }
                        }
                    }
                });
                *guard = Some(Trial {
                    child,
                    world,
                    build,
                    directory,
                    closed: false,
                    failure: None,
                    started: Instant::now(),
                    diagnostics,
                });
                Ok(json!({"state":"starting"}))
            }
            Err(e) => {
                let _ = fs::remove_dir_all(directory);
                Err(e)
            }
        }
    }
    pub fn status(&self, world: [Value; 3]) -> Result<Value, String> {
        let mut guard = self.0.lock().map_err(|_| "Preview is busy.")?;
        if let Some(t) = guard.as_mut() {
            t.poll()?;
            if t.world[..2] == world[..2] {
                return Ok(
                    json!({"state":t.state(),"build_id":t.build,"message":t.failure,"output":t.diagnostics.lock().map(|d|d.text()).unwrap_or_default()}),
                );
            }
            if !t.closed {
                return Ok(json!({"state":"other-world"}));
            }
        }
        Ok(json!({"state":"none"}))
    }
    pub fn stop(&self, world: [Value; 3], build: String) -> Result<Value, String> {
        let mut guard = self.0.lock().map_err(|_| "Preview is busy.")?;
        let t = guard.as_mut().ok_or("No preview is running.")?;
        if t.world[..2] != world[..2] || t.build != build {
            return Err("This preview belongs to another build or world.".into());
        }
        t.close()?;
        Ok(json!({"state":"closed","build_id":build}))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture {
        root: PathBuf,
        world: [Value; 3],
        attempt: Value,
        output: PathBuf,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "preview-test-{}-{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            let world = [json!("test"), json!(1), json!("epoch")];
            let base = world_base(&root, &world);
            let output = base.join("build-one/accepted-build-test");
            fs::create_dir_all(output.join("artifact")).unwrap();
            fs::create_dir_all(output.join("snapshot/ampd")).unwrap();
            fs::write(output.join("snapshot/ampd/mix.exs"), b"runtime").unwrap();
            let entries = vec![Entry {
                path: "ampd/mix.exs".into(),
                mode: 0o644,
                bytes: 7,
                sha256: hash(b"runtime"),
            }];
            let snapshot = hash(&serde_json::to_vec(&entries).unwrap());
            fs::write(
                output.join("manifest.json"),
                serde_json::to_vec(&json!({"files":entries,"snapshot_sha256":snapshot})).unwrap(),
            )
            .unwrap();
            let binary = fs::read("/usr/bin/yes").unwrap();
            fs::write(output.join("artifact/super-cockpit"), &binary).unwrap();
            let attempt = json!({"id":"a","status":"accepted","acceptance":{"snapshot_sha256":snapshot,"result_sha256":"result"}});
            let record = json!({"build_id":"build-one","attempt_ref":"a","state":"completed","snapshot_sha256":snapshot,"result":{"snapshot_sha256":snapshot,"result_sha256":"result","artifact":{"path":output.join("artifact/super-cockpit"),"sha256":hash(&binary)}}});
            fs::write(
                base.join("build-one.json"),
                serde_json::to_vec(&record).unwrap(),
            )
            .unwrap();
            Self {
                root,
                world,
                attempt,
                output,
            }
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
    #[test]
    fn copies_verified_bytes_and_ignores_uncaptured_source() {
        let f = Fixture::new();
        fs::write(f.output.join("snapshot/ampd/injected.exs"), "extra").unwrap();
        let dest = f.root.join("copy");
        prepare(&f.root, &f.world, "build-one", &f.attempt, &dest).unwrap();
        assert_eq!(
            fs::read(dest.join("source/ampd/mix.exs")).unwrap(),
            b"runtime"
        );
        assert!(!dest.join("source/ampd/injected.exs").exists());
    }
    #[test]
    fn refuses_changed_executable_source_and_manifest() {
        let f = Fixture::new();
        fs::write(f.output.join("snapshot/ampd/mix.exs"), "changed").unwrap();
        assert!(prepare(
            &f.root,
            &f.world,
            "build-one",
            &f.attempt,
            &f.root.join("copy")
        )
        .unwrap_err()
        .contains("source changed"));
        fs::write(f.output.join("artifact/super-cockpit"), "changed").unwrap();
        assert!(prepare(
            &f.root,
            &f.world,
            "build-one",
            &f.attempt,
            &f.root.join("copy")
        )
        .unwrap_err()
        .contains("executable changed"));
        let g = Fixture::new();
        fs::write(g.output.join("manifest.json"), r#"{"files":[]}"#).unwrap();
        assert!(prepare(
            &g.root,
            &g.world,
            "build-one",
            &g.attempt,
            &g.root.join("copy")
        )
        .is_err());
    }
    #[test]
    fn refuses_wrong_review_world_and_paths() {
        let f = Fixture::new();
        let mut wrong = f.attempt.clone();
        wrong["id"] = json!("other");
        assert!(prepare(&f.root, &f.world, "build-one", &wrong, &f.root.join("copy")).is_err());
        assert!(prepare(
            &f.root,
            &[json!("other"), json!(1), json!("e")],
            "build-one",
            &f.attempt,
            &f.root.join("copy")
        )
        .is_err());
        assert!(prepare(
            &f.root,
            &f.world,
            "../build-one",
            &f.attempt,
            &f.root.join("copy")
        )
        .is_err());
    }
    #[test]
    fn refuses_snapshot_symlink_escape() {
        let f = Fixture::new();
        fs::remove_file(f.output.join("snapshot/ampd/mix.exs")).unwrap();
        std::os::unix::fs::symlink("/etc/passwd", f.output.join("snapshot/ampd/mix.exs")).unwrap();
        assert!(prepare(
            &f.root,
            &f.world,
            "build-one",
            &f.attempt,
            &f.root.join("copy")
        )
        .is_err());
    }
    #[test]
    fn preview_is_single_scoped_and_close_removes_temporary_session() {
        let f = Fixture::new();
        let previews = Previews::default();
        previews
            .start(
                &f.root,
                f.world.clone(),
                "build-one".into(),
                f.attempt.clone(),
            )
            .unwrap();
        assert_eq!(
            previews.status(f.world.clone()).unwrap()["state"],
            "starting"
        );
        assert!(previews
            .start(
                &f.root,
                f.world.clone(),
                "build-one".into(),
                f.attempt.clone()
            )
            .is_err());
        assert!(previews
            .stop([json!("other"), json!(1), json!("e")], "build-one".into())
            .is_err());
        let temp = previews
            .0
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .directory
            .clone();
        previews.stop(f.world.clone(), "build-one".into()).unwrap();
        assert_eq!(previews.status(f.world.clone()).unwrap()["state"], "closed");
        assert!(!temp.exists());
        assert!(f.output.join("artifact/super-cockpit").exists());
    }
    #[test]
    fn diagnostics_are_bounded_and_detect_split_readiness() {
        let mut d = Diagnostics::default();
        d.push(&vec![b'x'; 20000]);
        assert_eq!(d.output.len(), 8192);
        d.push(b"[super-preview-frame-");
        assert!(!d.ready);
        d.push(b"painted@1]");
        assert!(d.ready);
        assert!(!d.text().contains(READY_MARKER));
    }
    #[test]
    fn early_failure_retains_exit_reason_and_cleans_session() {
        let f = Fixture::new();
        let binary = fs::read("/usr/bin/false").unwrap();
        fs::write(f.output.join("artifact/super-cockpit"), &binary).unwrap();
        let record = world_base(&f.root, &f.world).join("build-one.json");
        let mut row: Value = serde_json::from_slice(&fs::read(&record).unwrap()).unwrap();
        row["result"]["artifact"]["sha256"] = json!(hash(&binary));
        fs::write(record, serde_json::to_vec(&row).unwrap()).unwrap();
        let previews = Previews::default();
        previews
            .start(
                &f.root,
                f.world.clone(),
                "build-one".into(),
                f.attempt.clone(),
            )
            .unwrap();
        let mut status = json!({});
        for _ in 0..100 {
            status = previews.status(f.world.clone()).unwrap();
            if status["state"] == "failed" {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(status["state"], "failed");
        assert_eq!(status["message"], "Preview exited with code 1.");
        assert!(!previews
            .0
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .directory
            .exists());
    }
    #[test]
    fn running_is_not_readiness_and_unconfirmed_can_still_close() {
        let f = Fixture::new();
        let previews = Previews::default();
        previews
            .start(
                &f.root,
                f.world.clone(),
                "build-one".into(),
                f.attempt.clone(),
            )
            .unwrap();
        {
            let mut g = previews.0.lock().unwrap();
            let t = g.as_mut().unwrap();
            t.started = Instant::now() - Duration::from_secs(16);
        }
        assert_eq!(
            previews.status(f.world.clone()).unwrap()["state"],
            "unconfirmed"
        );
        {
            let g = previews.0.lock().unwrap();
            g.as_ref()
                .unwrap()
                .diagnostics
                .lock()
                .unwrap()
                .push(READY_MARKER.as_bytes());
        }
        assert_eq!(previews.status(f.world.clone()).unwrap()["state"], "ready");
        previews.stop(f.world.clone(), "build-one".into()).unwrap();
        assert_eq!(previews.status(f.world.clone()).unwrap()["state"], "closed");
    }
}
