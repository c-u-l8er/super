//! Device-local build artifacts. These records never grant acceptance or launch an app.
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs,
    io::Read,
    os::unix::{fs::PermissionsExt, process::CommandExt},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
#[derive(Clone, Default)]
pub struct Builds(Arc<Mutex<BTreeMap<String, Arc<Mutex<Child>>>>>);
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
fn base(data: &Path, world: &[Value; 3]) -> Result<PathBuf, String> {
    let key = format!(
        "{:x}",
        Sha256::digest(json!([world[0], world[1]]).to_string())
    );
    let dir = data.join("accepted-builds").join(key);
    fs::create_dir_all(&dir).map_err(err)?;
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).map_err(err)?;
    Ok(dir)
}
fn save(path: &Path, value: &Value) -> Result<(), String> {
    let temp = path.with_extension("tmp");
    fs::write(&temp, serde_json::to_vec(value).map_err(err)?).map_err(err)?;
    fs::rename(temp, path).map_err(err)
}
fn read(path: &Path) -> Result<Value, String> {
    let file = fs::File::open(path).map_err(err)?;
    if file.metadata().map_err(err)?.len() > 256 * 1024 {
        return Err("Build record is too large.".into());
    }
    let mut bytes = Vec::new();
    file.take(256 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(err)?;
    serde_json::from_slice(&bytes).map_err(err)
}
impl Builds {
    pub fn start(
        &self,
        data: &Path,
        world: [Value; 3],
        root: PathBuf,
        attempt: Value,
    ) -> Result<Value, String> {
        let mut active = self.0.lock().map_err(|_| "Build status is busy.")?;
        if !active.is_empty() {
            return Err("Finish or cancel the active build first.".into());
        }
        let base = base(data, &world)?;
        if fs::read_dir(&base)
            .map_err(err)?
            .filter_map(Result::ok)
            .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
            .count()
            >= 8
        {
            return Err(
                "This world's eight local builds are retained. Build history is full.".into(),
            );
        }
        let id = format!(
            "build-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(err)?
                .as_nanos()
        );
        let dir = base.join(&id);
        fs::create_dir(&dir).map_err(err)?;
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).map_err(err)?;
        fs::create_dir(dir.join("lib")).map_err(err)?;
        for (path, text) in [
            (
                "runner.mjs",
                include_str!("../../tools/accepted-build-runner.mjs"),
            ),
            (
                "lib/accepted-build-runner.mjs",
                include_str!("../../tools/lib/accepted-build-runner.mjs"),
            ),
            (
                "lib/proposal-test-runner.mjs",
                include_str!("../../tools/lib/proposal-test-runner.mjs"),
            ),
        ] {
            fs::write(dir.join(path), text).map_err(err)?;
        }
        fs::write(
            dir.join("attempt.json"),
            serde_json::to_vec(&attempt).map_err(err)?,
        )
        .map_err(err)?;
        let receipt = base.join(format!("{id}.json"));
        let mut record = json!({"schema":"device-accepted-build@1","local_only":true,"build_id":id,"attempt_ref":attempt["id"],"snapshot_sha256":attempt["acceptance"]["snapshot_sha256"],"state":"running"});
        save(&receipt, &record)?;
        let output = fs::File::create(dir.join("launcher.json")).map_err(err)?;
        let errors = fs::File::create(dir.join("error.txt")).map_err(err)?;
        let mut command = Command::new("node");
        command
            .arg(dir.join("runner.mjs"))
            .arg(root)
            .arg(dir.join("attempt.json"))
            .arg(&dir)
            .stdin(Stdio::null())
            .stdout(output)
            .stderr(errors);
        // An app crash must stop its build launcher, which cancels the isolated compiler.
        let parent = unsafe { libc::getpid() };
        unsafe {
            command.pre_exec(move || {
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                if libc::getppid() != parent {
                    return Err(std::io::Error::from_raw_os_error(libc::ESRCH));
                }
                Ok(())
            });
        }
        let child = command.spawn();
        let child = match child {
            Ok(child) => Arc::new(Mutex::new(child)),
            Err(e) => {
                record["state"] = json!("failed");
                record["message"] = json!(e.to_string());
                save(&receipt, &record)?;
                return Ok(record);
            }
        };
        active.insert(id.clone(), child.clone());
        let state = self.clone();
        let initial = record.clone();
        std::thread::spawn(move || {
            loop {
                match child
                    .lock()
                    .map_err(|_| ())
                    .and_then(|mut c| c.try_wait().map_err(|_| ()))
                {
                    Ok(None) => std::thread::sleep(Duration::from_millis(150)),
                    _ => break,
                }
            }
            let result = (|| -> Result<Value, String> {
                let launch = read(&dir.join("launcher.json"))?;
                let path = PathBuf::from(
                    launch["directory"]
                        .as_str()
                        .ok_or("Build returned no result location.")?,
                )
                .canonicalize()
                .map_err(err)?;
                if !path.starts_with(dir.canonicalize().map_err(err)?) {
                    return Err("Build result escaped its directory.".into());
                }
                read(&path.join("outcome.json"))
            })();
            let mut record = initial;
            match result {
                Ok(result) => {
                    record["state"] = result["state"].clone();
                    record["result"] = result;
                }
                Err(_) => {
                    record["state"] = json!("failed");
                    let error = fs::read_to_string(dir.join("error.txt")).unwrap_or_default();
                    record["message"] = json!(if error.is_empty() {
                        "Build ended without a complete result.".to_owned()
                    } else {
                        error.chars().take(1200).collect()
                    });
                }
            }
            let _ = save(&receipt, &record);
            if let Ok(mut active) = state.0.lock() {
                active.remove(&id);
            }
        });
        Ok(record)
    }
    pub fn list(
        &self,
        data: &Path,
        world: [Value; 3],
        attempt_ref: String,
    ) -> Result<Value, String> {
        let base = base(data, &world)?;
        let active = self.0.lock().map_err(|_| "Build status is busy.")?;
        let mut rows = Vec::new();
        for entry in fs::read_dir(&base).map_err(err)?.filter_map(Result::ok) {
            if entry.path().extension().is_none_or(|x| x != "json") {
                continue;
            }
            let mut row = read(&entry.path())?;
            if row["attempt_ref"] != attempt_ref {
                continue;
            }
            row["local_only"] = json!(true);
            row["artifact_available"] = json!(false);
            if row["state"] == "completed" {
                if let Some(path) = row["result"]["artifact"]["path"].as_str() {
                    if let Ok(path) = PathBuf::from(path).canonicalize() {
                        if path.starts_with(&base)
                            && fs::metadata(&path)
                                .is_ok_and(|m| m.is_file() && m.len() <= 256 * 1024 * 1024)
                        {
                            if let Ok(bytes) = fs::read(&path) {
                                row["artifact_available"] = json!(
                                    row["result"]["artifact"]["sha256"]
                                        == format!("{:x}", Sha256::digest(&bytes))
                                );
                            }
                        }
                    }
                }
            }
            if row["state"] == "running"
                && !active.contains_key(row["build_id"].as_str().unwrap_or(""))
            {
                row["state"] = json!("interrupted");
                row["message"]=json!("The app stopped before a complete build result was saved. No completed build is confirmed here.");
            }
            rows.push(row);
        }
        rows.sort_by_key(|r| r["build_id"].as_str().unwrap_or("").to_owned());
        Ok(json!({"builds":rows}))
    }
    pub fn cancel(&self, data: &Path, world: [Value; 3], id: String) -> Result<Value, String> {
        if !id.starts_with("build-") || !id.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-')
        {
            return Err("Invalid build identifier.".into());
        }
        read(&base(data, &world)?.join(format!("{id}.json")))?;
        let active = self.0.lock().map_err(|_| "Build status is busy.")?;
        let child = active
            .get(&id)
            .ok_or("Build is no longer running.")?
            .lock()
            .map_err(|_| "Build is busy.")?;
        unsafe {
            libc::kill(child.id() as i32, libc::SIGTERM);
        }
        Ok(json!({"cancel_requested":true}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn restart_marks_unfinished_builds_interrupted_and_missing_artifacts_unavailable() {
        let root = std::env::temp_dir().join(format!(
            "super-build-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let world = [json!("test"), json!(1), json!("epoch")];
        let dir = base(&root, &world).unwrap();
        save(
            &dir.join("build-one.json"),
            &json!({"build_id":"build-one","attempt_ref":"a","state":"running"}),
        )
        .unwrap();
        save(&dir.join("build-two.json"),&json!({"build_id":"build-two","attempt_ref":"a","state":"completed","result":{"artifact":{"path":"/etc/passwd","sha256":"forged"}}})).unwrap();
        let builds = Builds::default();
        let result = builds.list(&root, world.clone(), "a".into()).unwrap();
        assert_eq!(result["builds"][0]["state"], "interrupted");
        assert_eq!(result["builds"][1]["artifact_available"], false);
        assert_eq!(
            builds.list(&root, world, "other".into()).unwrap()["builds"],
            json!([])
        );
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn cancel_cannot_address_arbitrary_paths() {
        assert!(Builds::default()
            .cancel(
                Path::new("/tmp"),
                [json!("w"), json!(1), json!("e")],
                "../other".into()
            )
            .is_err());
    }
}
