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
        #[serde(default)]
        worker: Option<String>,
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
fn worker_id(v: &Value) -> String { format!("{}/{}", v["host"].as_str().unwrap_or(""), v["guest"].as_str().unwrap_or("")) }
// The supported workers, one row each: host, guest, target (user@address), port, jump target (user@address), jump
// port, the guest's HostKeyAlias and the fixed remote command; "" and 0 mean none (a direct row). The same rows, field
// for field, are WORKER_TABLE in tools/fleet/check-client.mjs; law L3 reads this constant's literals, so it holds
// string and integer literals only. No jump row has root anywhere (R103).
const SUPPORTED_WORKERS: [(&str, &str, &str, u64, &str, u64, &str, &str); 4] = [
    ("locuchest", "100", "root@192.168.1.69", 22, "", 0, "", ""),
    ("locuchest", "100", "root@192.168.88.252", 22, "", 0, "", ""),
    ("cd-floor-01", "super-worker-02", "root@192.168.1.71", 22, "", 0, "", ""),
    ("cd-floor-01", "super-worker-02", "fleet@127.0.0.1", 2222, "travis@192.168.88.254", 22, "super-worker-02", "super-fleet-check"),
];
type Fields = serde_json::Map<String, Value>;
const DIRECT_FIELDS: [&str; 6] = ["host", "guest", "target", "port", "identityFile", "knownHosts"];
const JUMP_ROW_FIELDS: [&str; 8] = ["host", "guest", "target", "port", "identityFile", "knownHosts", "jump", "hostKeyAlias"];
const JUMP_FIELDS: [&str; 4] = ["target", "port", "identityFile", "knownHosts"];
fn text<'a>(m: &'a Fields, key: &str) -> Option<&'a str> { m.get(key).and_then(Value::as_str) }
fn only(m: &Fields, keys: &[&str]) -> bool { m.keys().all(|k| keys.contains(&k.as_str())) }
// An absent port is 22. A present one is a JSON number whose parsed value is an integer in 1-65535: 22, 22.0 and
// 2.2e1 alike, since the spelling is not judged (JavaScript's parser cannot see it; check-client.mjs holds the same
// policy). A string, null, a fraction or a value out of range is refused.
fn port(m: &Fields) -> Option<u64> {
    match m.get("port") {
        None => Some(22),
        Some(p) => p
            .as_u64()
            .or_else(|| p.as_f64().filter(|f| f.fract() == 0.0 && (1.0..=65535.0).contains(f)).map(|f| f as u64))
            .filter(|p| (1..=65535).contains(p)),
    }
}
// OpenSSH runs a ProxyCommand through a shell, so every path in a jump row matches ^/[A-Za-z0-9._/-]{1,512}$.
fn jump_path(s: &str) -> bool {
    s.starts_with('/') && (2..=513).contains(&s.len()) && s.bytes().all(|c| c.is_ascii_alphanumeric() || b"._/-".contains(&c))
}
// The table row this configuration equals in every field, if any; a field outside the row's own set refuses it.
fn table_row(r: &Value) -> Option<usize> {
    let m = r.as_object()?;
    SUPPORTED_WORKERS.iter().position(|&(host, guest, target, p, jump_target, jump_port, alias, _)| {
        let same = text(m, "host") == Some(host) && text(m, "guest") == Some(guest) && text(m, "target") == Some(target) && port(m) == Some(p);
        let route = if jump_target.is_empty() {
            only(m, &DIRECT_FIELDS)
        } else {
            only(m, &JUMP_ROW_FIELDS)
                && m.get("hostKeyAlias").map_or(true, |a| a.as_str() == Some(alias))
                && m.get("jump").and_then(Value::as_object).is_some_and(|j| {
                    only(j, &JUMP_FIELDS) && text(j, "target") == Some(jump_target) && port(j) == Some(jump_port)
                })
        };
        same && route
    })
}
fn configurations(v: Value) -> Result<Vec<Value>, String> {
    let rows = if let Some(rows) = v.get("workers") { rows.as_array().ok_or("Invalid worker list.")?.clone() } else { vec![v] };
    if rows.is_empty() || rows.len() > 2 { return Err("Configure one or two supported workers.".into()); }
    let mut seen = BTreeSet::new();
    for r in &rows {
        let row = match table_row(r) {
            Some(i) if seen.insert(worker_id(r)) => SUPPORTED_WORKERS[i],
            _ => return Err("The configured worker is unsupported or duplicated.".into()),
        };
        let jump = !row.4.is_empty();
        let mut paths = vec![&r["identityFile"], &r["knownHosts"]];
        if jump { paths.extend([&r["jump"]["identityFile"], &r["jump"]["knownHosts"]]); }
        let valid = |s: &str| if jump { jump_path(s) } else { Path::new(s).is_absolute() && !s.contains('\0') };
        if !paths.iter().all(|p| p.as_str().is_some_and(|s| valid(s))) { return Err("Invalid worker transport identity.".into()); }
    }
    Ok(rows)
}
fn configs() -> Result<Vec<Value>, String> {
    configurations(read(&config_path(|key| std::env::var_os(key))?)?)
}
fn worker_label(v: &Value) -> &'static str {
    if v["host"] == "cd-floor-01" { "super-worker-02 · FreeBSD / bhyve" } else { "super-worker-01 · Proxmox" }
}
impl Checks {
    pub fn prepare(
        &self,
        data: &Path,
        world: [Value; 3],
        root: &Path,
        task: &str,
        revision: u64,
        worker: Option<&str>,
    ) -> Result<PathBuf, String> {
        let active = self.0.lock().map_err(|_| "Checks are busy.")?;
        if !active.is_empty() {
            return Err("Wait for the current remote operation.".into());
        }
        let cfg = configs()?.into_iter().find(|r| worker_id(r) == worker.unwrap_or("locuchest/100")).ok_or("Choose a configured check worker.")?;
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
            &json!({"id":id,"binding":{"world":[world[0],world[1]],"task":task,"revision":revision},"destination":{"host":cfg["host"],"guest":cfg["guest"]}}),
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
                let workers = configs().unwrap_or_default().iter().map(|v| json!({"id":worker_id(v),"label":worker_label(v)})).collect::<Vec<_>>();
                Ok(json!({"configured":!workers.is_empty(),"workers":workers,"runs":records}))
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
    fn worker_configuration_is_bounded_and_preserves_legacy_destination() {
        let a=json!({"host":"locuchest","guest":"100","target":"root@192.168.1.69","identityFile":"/private/a","knownHosts":"/private/hosts"});
        let b=json!({"host":"cd-floor-01","guest":"super-worker-02","target":"root@192.168.1.71","identityFile":"/private/b","knownHosts":"/private/hosts"});
        assert_eq!(worker_id(&configurations(a.clone()).unwrap()[0]), "locuchest/100");
        assert_eq!(configurations(json!({"workers":[a.clone(),b]})).unwrap().len(),2);
        assert!(configurations(json!({"workers":[a.clone(),a.clone()]})).is_err());
        let mut bad=a;bad["guest"]=json!("super-worker-02");assert!(configurations(bad).is_err());
    }
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
    // The law cases: L1 runs them here, and tools/fleet-check-test.mjs reads this constant to run the same cases
    // against check-client.mjs (L2, L4) and the observer's projection (L8). "rows" are the four supported rows in table
    // order; each case builds its rows from a base row, then "set" (a dotted key reaches into "jump"), then "long"
    // (key: n sets the key to a path of n characters, "/" and n-1 letters), then "unset" (dotted too); one row is
    // given alone, several as {"workers": [...]}.
    const LAW_CASES: &str = r##"{
"rows": [
 {"host":"locuchest","guest":"100","target":"root@192.168.1.69","identityFile":"/private/a","knownHosts":"/private/hosts"},
 {"host":"locuchest","guest":"100","target":"root@192.168.88.252","identityFile":"/private/a","knownHosts":"/private/locuchest_known_hosts"},
 {"host":"cd-floor-01","guest":"super-worker-02","target":"root@192.168.1.71","identityFile":"/private/b","knownHosts":"/private/hosts"},
 {"host":"cd-floor-01","guest":"super-worker-02","target":"fleet@127.0.0.1","port":2222,"hostKeyAlias":"super-worker-02","identityFile":"/private/guest_ed25519","knownHosts":"/private/guest_known_hosts","jump":{"target":"travis@192.168.88.254","port":22,"identityFile":"/private/super-fleet-jump","knownHosts":"/private/jump_known_hosts"}}
],
"cases": [
 {"ok":true,"rows":[{"base":0}]},
 {"ok":true,"rows":[{"base":1}]},
 {"ok":true,"rows":[{"base":2}]},
 {"ok":true,"rows":[{"base":3}]},
 {"ok":true,"rows":[{"base":1,"set":{"port":22}}]},
 {"ok":true,"rows":[{"base":3,"unset":"hostKeyAlias"}]},
 {"ok":true,"rows":[{"base":1,"set":{"identityFile":"/private/with space"}}]},
 {"ok":true,"rows":[{"base":0},{"base":2}]},
 {"ok":true,"rows":[{"base":0},{"base":3}]},
 {"ok":true,"rows":[{"base":1},{"base":2}]},
 {"ok":true,"rows":[{"base":1},{"base":3}]},
 {"ok":true,"rows":[{"base":3},{"base":1}]},
 {"ok":false,"rows":[]},
 {"ok":false,"rows":[{"base":0},{"base":1}]},
 {"ok":false,"rows":[{"base":2},{"base":3}]},
 {"ok":false,"rows":[{"base":3},{"base":3}]},
 {"ok":false,"rows":[{"base":1},{"base":2},{"base":3}]},
 {"ok":false,"rows":[{"base":2,"set":{"target":"root@192.168.88.252"}}]},
 {"ok":false,"rows":[{"base":1,"set":{"target":"root@192.168.88.254"}}]},
 {"ok":false,"rows":[{"base":1,"set":{"target":"travis@192.168.88.254"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"host":"locuchest","guest":"100"}}]},
 {"ok":false,"rows":[{"base":1,"set":{"target":"travis@192.168.88.252"}}]},
 {"ok":false,"rows":[{"base":1,"set":{"target":"root@192.168.88.253"}}]},
 {"ok":false,"rows":[{"base":2,"set":{"target":"root@192.168.88.253"}}]},
 {"ok":false,"rows":[{"base":1,"set":{"target":"root@192.168.88.2520"}}]},
 {"ok":false,"rows":[{"base":1,"set":{"target":" root@192.168.88.252"}}]},
 {"ok":false,"rows":[{"base":1,"set":{"target":"root@192.168.88.252 "}}]},
 {"ok":false,"rows":[{"base":1,"set":{"target":"root@cd-floor-01"}}]},
 {"ok":false,"rows":[{"base":2,"set":{"target":"root@cd-floor-01"}}]},
 {"ok":false,"rows":[{"base":1,"set":{"target":""}}]},
 {"ok":false,"rows":[{"base":1,"unset":"target"}]},
 {"ok":false,"rows":[{"base":1,"set":{"port":2222}}]},
 {"ok":false,"rows":[{"base":1,"set":{"port":0}}]},
 {"ok":false,"rows":[{"base":1,"set":{"port":65536}}]},
 {"ok":false,"rows":[{"base":1,"set":{"port":"22"}}]},
 {"ok":false,"rows":[{"base":0,"set":{"port":2222}}]},
 {"ok":false,"rows":[{"base":1,"set":{"guest":"super-worker-02"}}]},
 {"ok":false,"rows":[{"base":2,"set":{"host":"locuchest"}}]},
 {"ok":false,"rows":[{"base":1,"set":{"jump":{"target":"travis@192.168.88.254","port":22,"identityFile":"/private/super-fleet-jump","knownHosts":"/private/jump_known_hosts"}}}]},
 {"ok":false,"rows":[{"base":2,"set":{"hostKeyAlias":"super-worker-02"}}]},
 {"ok":false,"rows":[{"base":1,"set":{"command":"id"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"target":"root@127.0.0.1"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"target":"fleet@127.0.0.2"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.target":"root@192.168.88.254"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.target":"travis@192.168.88.253"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.target":"travis@192.168.88.2540"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.port":2222}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.port":"22"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"port":22}}]},
 {"ok":false,"rows":[{"base":3,"unset":"port"}]},
 {"ok":false,"rows":[{"base":3,"set":{"hostKeyAlias":"locuchest"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"hostKeyAlias":""}}]},
 {"ok":false,"rows":[{"base":3,"unset":"jump"}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump":null}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.command":"id"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"proxyCommand":"/bin/sh"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.identityFile":"/private/super fleet-jump"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.identityFile":"/private/super'fleet-jump"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.identityFile":"/private/super\"fleet-jump"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.identityFile":"/private/$HOME"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.identityFile":"/private/`id`"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.identityFile":"/private/a;id"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.identityFile":"/private/a\nid"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.knownHosts":"/private/jump known_hosts"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.knownHosts":"/private/a;id"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.knownHosts":"/private/a\nid"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"identityFile":"/private/guest ed25519"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"knownHosts":"/private/$(id)"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.identityFile":"private/super-fleet-jump"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.identityFile":"/"}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.identityFile":"/private/%h"}}]},
 {"ok":false,"rows":[{"base":1,"set":{"identityFile":"relative"}}]},
 {"ok":true,"rows":[{"base":1,"set":{"port":22.0}}]},
 {"ok":true,"rows":[{"base":1,"set":{"port":2.2e1}}]},
 {"ok":true,"rows":[{"base":1,"set":{"port":22.000000000000001}}]},
 {"ok":false,"rows":[{"base":1,"set":{"port":22.5}}]},
 {"ok":false,"rows":[{"base":1,"set":{"port":null}}]},
 {"ok":false,"rows":[{"base":1,"set":{"port":-22}}]},
 {"ok":true,"rows":[{"base":3,"set":{"port":2222.0}}]},
 {"ok":true,"rows":[{"base":3,"set":{"jump.port":22.0}}]},
 {"ok":false,"rows":[{"base":3,"set":{"jump.port":22.5}}]},
 {"ok":true,"rows":[{"base":3,"unset":"jump.port"}]},
 {"ok":true,"rows":[{"base":3,"long":{"jump.identityFile":513}}]},
 {"ok":false,"rows":[{"base":3,"long":{"jump.identityFile":514}}]},
 {"ok":true,"rows":[{"base":3,"long":{"knownHosts":513}}]},
 {"ok":false,"rows":[{"base":3,"long":{"knownHosts":514}}]}
]
}"##;
    fn law_put(row: &mut Value, key: &str, value: Value) {
        let mut parts: Vec<&str> = key.split('.').collect();
        let last = parts.pop().unwrap();
        let at = parts.into_iter().fold(row, |at, p| &mut at[p]);
        at[last] = value;
    }
    fn law_unset(row: &mut Value, key: &str) {
        let mut parts: Vec<&str> = key.split('.').collect();
        let last = parts.pop().unwrap();
        let at = parts.into_iter().fold(row, |at, p| &mut at[p]);
        at.as_object_mut().unwrap().remove(last);
    }
    fn law_row(cases: &Value, spec: &Value) -> Value {
        let mut row = cases["rows"][spec["base"].as_u64().unwrap() as usize].clone();
        for (key, value) in spec["set"].as_object().into_iter().flatten() {
            law_put(&mut row, key, value.clone());
        }
        for (key, n) in spec["long"].as_object().into_iter().flatten() {
            law_put(&mut row, key, json!(format!("/{}", "a".repeat(n.as_u64().unwrap() as usize - 1))));
        }
        if let Some(key) = spec["unset"].as_str() {
            law_unset(&mut row, key);
        }
        row
    }
    fn law_input(cases: &Value, case: &Value) -> Value {
        let mut rows: Vec<Value> = case["rows"].as_array().unwrap().iter().map(|s| law_row(cases, s)).collect();
        if rows.len() == 1 { rows.pop().unwrap() } else { json!({"workers": rows}) }
    }
    #[test]
    fn l1_configurations_answer_every_law_case() {
        let cases: Value = serde_json::from_str(LAW_CASES).unwrap();
        let all = cases["cases"].as_array().unwrap();
        assert!(all.len() >= 60);
        for case in all {
            assert_eq!(configurations(law_input(&cases, case)).is_ok(), case["ok"].as_bool().unwrap(), "{}", case);
        }
    }
    #[test]
    fn l1_each_supported_row_matches_only_its_own_table_row() {
        let cases: Value = serde_json::from_str(LAW_CASES).unwrap();
        for i in 0..SUPPORTED_WORKERS.len() {
            assert_eq!(table_row(&cases["rows"][i]), Some(i));
            assert_eq!(configurations(cases["rows"][i].clone()).unwrap(), vec![cases["rows"][i].clone()]);
        }
    }
    #[test]
    fn l1_no_jump_row_has_root_anywhere() {
        for &(host, guest, target, _, jump, _, alias, command) in SUPPORTED_WORKERS.iter() {
            if !jump.is_empty() {
                for f in [host, guest, target, jump, alias, command] {
                    assert!(!f.contains("root"), "{}", f);
                }
            }
        }
    }
}
