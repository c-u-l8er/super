//! Device-local advisory checks, deliberately outside runtime acceptance records.
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    fs,
    io::{Read, Write},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};
#[derive(Clone, Default)]
pub struct Checks(Arc<Mutex<BTreeSet<String>>>);
#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
    Start {
        generation: u64,
        task_ref: String,
        revision: u64,
        world: [Value; 3],
    },
    List {
        task_ref: String,
        world: [Value; 3],
    },
    Reconcile {
        id: String,
        world: [Value; 3],
    },
}
fn read(path: &Path) -> Result<Value, String> {
    let mut bytes = Vec::new();
    fs::File::open(path)
        .map_err(err)?
        .take(262145)
        .read_to_end(&mut bytes)
        .map_err(err)?;
    if bytes.len() > 262144 {
        return Err("Check record exceeds its limit.".into());
    }
    serde_json::from_slice(&bytes).map_err(err)
}
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
fn directory(data: &Path, world: &[Value; 3]) -> Result<PathBuf, String> {
    if !world[0].is_string() || !world[1].is_u64() {
        return Err("Reconnect to the current world.".into());
    }
    let hash = format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(&json!([world[0], world[1]])).map_err(err)?)
    );
    let p = data.join("fleet-checks").join(hash);
    fs::create_dir_all(&p).map_err(err)?;
    fs::set_permissions(&p, fs::Permissions::from_mode(0o700)).map_err(err)?;
    Ok(p)
}
fn save(p: &Path, v: &Value) -> Result<(), String> {
    let mut f = fs::File::create(p).map_err(err)?;
    f.write_all(&serde_json::to_vec(v).map_err(err)?)
        .map_err(err)?;
    f.sync_all().map_err(err)?;
    fs::File::open(p.parent().unwrap())
        .map_err(err)?
        .sync_all()
        .map_err(err)
}
fn valid_id(id: &str) -> bool {
    id.len() == 35
        && id.starts_with("fc-")
        && id[3..]
            .bytes()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
}
// Explicit overrides (including empty = disabled) never fall back to saved settings.
fn config_path(env: impl Fn(&str) -> Option<std::ffi::OsString>) -> Result<PathBuf, String> {
    if let Some(path) = env("SUPER_FLEET_CHECK_CONFIG") {
        return if path.is_empty() {
            Err("Remote checks are disabled for this launch.".into())
        } else { Ok(PathBuf::from(path)) };
    }
    let base = env("XDG_CONFIG_HOME").map(PathBuf::from).filter(|p| p.is_absolute())
        .or_else(|| env("HOME").map(PathBuf::from).filter(|p| p.is_absolute()).map(|p| p.join(".config")))
        .ok_or("Remote checks are not configured on this device.")?;
    let saved = read(&base.join("super/fleet.json"))?;
    if saved["schema"] != "super-device-fleet@1" {
        return Err("Unsupported saved fleet settings.".into());
    }
    saved["checksConfigPath"].as_str().map(PathBuf::from).filter(|p| p.is_absolute())
        .ok_or("Remote checks are not configured on this device.".into())
}
fn config() -> Result<Value, String> {
    let path = config_path(|key| std::env::var_os(key))?;
    let v = read(Path::new(&path))?;
    if v["host"] != "locuchest" || v["guest"] != "100" || v["target"] != "root@192.168.1.69" {
        return Err("The configured worker is not supported.".into());
    }
    Ok(v)
}
impl Checks {
    pub fn prepare(
        &self,
        data: &Path,
        world: [Value; 3],
        root: &Path,
        task: &str,
        revision: u64,
    ) -> Result<PathBuf, String> {
        let active = self.0.lock().map_err(|_| "Checks are busy.")?;
        if !active.is_empty() {
            return Err("Wait for the current remote operation.".into());
        }
        let cfg = config()?;
        let base = directory(data, &world)?;
        let dirs = fs::read_dir(&base)
            .map_err(err)?
            .filter_map(Result::ok)
            .collect::<Vec<_>>();
        if dirs.len() >= 32 {
            return Err(
                "This world's remote check history is full. Existing records are preserved.".into(),
            );
        }
        for d in &dirs {
            if let Ok(r) = read(&d.path().join("record.json")) {
                if r["state"] == "unknown" {
                    return Err(
                        "Check the unresolved remote request before starting another one.".into(),
                    );
                }
            }
        }
        let nonce = format!(
            "{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(err)?
                .as_nanos()
        );
        let id = format!(
            "fc-{}",
            &format!("{:x}", Sha256::digest(nonce.as_bytes()))[..32]
        );
        let dir = base.join(&id);
        fs::create_dir(&dir).map_err(err)?;
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).map_err(err)?;
        fs::write(
            dir.join("client.mjs"),
            include_str!("../../tools/fleet/check-client.mjs"),
        )
        .map_err(err)?;
        save(
            &dir.join("spec.json"),
            &json!({"id":id,"binding":{"world":[world[0],world[1]],"task":task,"revision":revision}}),
        )?;
        save(&dir.join("transport.json"), &cfg)?;
        let out = Command::new("node")
            .arg(dir.join("client.mjs"))
            .arg("prepare")
            .arg(&dir)
            .arg(root)
            .stdin(Stdio::null())
            .output()
            .map_err(err)?;
        if !out.status.success() {
            return Err(String::from_utf8_lossy(&out.stderr)
                .chars()
                .take(400)
                .collect());
        }
        Ok(dir)
    }
    pub fn launch(&self, dir: PathBuf, operation: &'static str) -> Result<Value, String> {
        let record = read(&dir.join("record.json"))?;
        let id = record["id"]
            .as_str()
            .ok_or("Missing request identity.")?
            .to_owned();
        let mut active = self.0.lock().map_err(|_| "Checks are busy.")?;
        if !active.is_empty() {
            return Err("Wait for the current remote operation.".into());
        }
        let out = fs::File::create(dir.join("launcher.json")).map_err(err)?;
        let error = fs::File::create(dir.join("launcher-error.txt")).map_err(err)?;
        let mut child = Command::new("/usr/bin/flock")
            .arg("-n")
            .arg(dir.join("operation.lock"))
            .arg("node")
            .arg(dir.join("client.mjs"))
            .arg(operation)
            .arg(&dir)
            .stdin(Stdio::null())
            .stdout(out)
            .stderr(error)
            .spawn()
            .map_err(err)?;
        active.insert(id.clone());
        let state = self.clone();
        std::thread::spawn(move || {
            let _ = child.wait();
            if let Ok(mut a) = state.0.lock() {
                a.remove(&id);
            }
        });
        Ok(record)
    }
    pub fn request(&self, data: &Path, request: Request) -> Result<Value, String> {
        match request {
            Request::List { world, task_ref } => {
                let base = directory(data, &world)?;
                let active = self.0.lock().map_err(|_| "Checks are busy.")?;
                let mut records = Vec::new();
                for d in fs::read_dir(base)
                    .map_err(err)?
                    .take(33)
                    .filter_map(Result::ok)
                {
                    if let Ok(mut r) = read(&d.path().join("record.json")) {
                        if r["binding"]["task"] == task_ref {
                            r["active"] =
                                json!(r["id"].as_str().is_some_and(|id| active.contains(id)));
                            records.push(r);
                        }
                    }
                }
                records.sort_by_key(|r| r["createdAt"].as_u64().unwrap_or(0));
                Ok(json!({"configured":config().is_ok(),"runs":records}))
            }
            Request::Reconcile { world, id } => {
                if !valid_id(&id) {
                    return Err("Invalid request identity.".into());
                }
                let dir = directory(data, &world)?.join(id);
                let r = read(&dir.join("record.json"))?;
                if r["state"] == "completed" || !dir.join("sent").exists() {
                    return Ok(r);
                }
                self.launch(dir, "status")
            }
            _ => Err("Reopen the current task to start a check.".into()),
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn saved_settings_and_overrides_are_separate() {
        let dir = std::env::temp_dir().join(format!("fleet-settings-{}", std::process::id()));
        fs::create_dir_all(dir.join("super")).unwrap();
        let path = dir.join("super/fleet.json");
        fs::write(&path, br#"{"schema":"super-device-fleet@1","checksConfigPath":"/device/checks.json"}"#).unwrap();
        let env = |key: &str| if key == "XDG_CONFIG_HOME" { Some(dir.clone().into_os_string()) } else { None };
        assert_eq!(config_path(env).unwrap(), PathBuf::from("/device/checks.json"));
        assert!(config_path(|key| if key == "SUPER_FLEET_CHECK_CONFIG" { Some("".into()) } else { env(key) }).is_err());
        assert_eq!(config_path(|key| if key == "SUPER_FLEET_CHECK_CONFIG" { Some("/override".into()) } else { env(key) }).unwrap(), PathBuf::from("/override"));
        for bytes in [r#"{"schema":"wrong","checksConfigPath":"/device/checks.json"}"#, r#"{"schema":"super-device-fleet@1","checksConfigPath":"relative"}"#, "{"] {
            fs::write(&path, bytes).unwrap(); assert!(config_path(env).is_err());
        }
        fs::remove_file(&path).unwrap(); assert!(config_path(env).is_err());
        fs::remove_dir_all(dir).unwrap();
        assert!(config_path(|key| if key == "XDG_CONFIG_HOME" { Some("relative".into()) } else { None }).is_err());
    }
    #[test]
    fn request_ids_never_supply_paths() {
        for s in [
            "../x",
            "fc-../../x",
            "fc-",
            "fc-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        ] {
            assert!(!valid_id(s));
        }
        assert!(valid_id("fc-0123456789abcdef0123456789abcdef"));
    }
    #[test]
    fn page_cannot_supply_source_or_commands() {
        assert!(serde_json::from_value::<Request>(json!({"operation":"start","generation":1,"task_ref":"dt_1","revision":1,"world":["w",1,1],"path":"/tmp","command":"id"})).is_err());
    }
}
