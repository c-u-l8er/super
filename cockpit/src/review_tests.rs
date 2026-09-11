//! Local human-operated test history; never a runtime validation or acceptance receipt.
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    io::Read,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
pub type Report = Arc<dyn Fn(&str, Value) -> Result<Value, String> + Send + Sync>;
#[derive(Default, Clone)]
pub struct Runs(
    Arc<Mutex<BTreeMap<String, Arc<Mutex<Child>>>>>,
    Arc<Mutex<BTreeMap<String, Pending>>>,
    Arc<Mutex<BTreeSet<String>>>,
);
// Only the native completion path can populate this map. Never reconstruct an outcome
// from the page or the local index when retrying a runtime report.
#[derive(Clone)]
struct Pending {
    fields: Value,
    receipt: PathBuf,
    record: Value,
}
#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
    LaunchBuild {
        generation: u64,
        attempt_ref: String,
        revision: u64,
        world: [Value; 3],
        build_id: String,
    },
    PreviewStatus {
        world: [Value; 3],
    },
    StopPreview {
        world: [Value; 3],
        build_id: String,
    },
    BuildAccepted {
        generation: u64,
        attempt_ref: String,
        revision: u64,
        world: [Value; 3],
    },
    ListBuilds {
        world: [Value; 3],
        attempt_ref: String,
    },
    CancelBuild {
        world: [Value; 3],
        build_id: String,
    },
    VerifyAccepted {
        generation: u64,
        attempt_ref: String,
        revision: u64,
        world: [Value; 3],
    },
    Accept {
        generation: u64,
        attempt_ref: String,
        revision: u64,
        world: [Value; 3],
        run_id: String,
        note: String,
    },
    Start {
        generation: u64,
        attempt_ref: String,
        revision: u64,
        world: [Value; 3],
        #[serde(default = "default_profile")]
        profile: String,
    },
    List {
        world: [Value; 3],
        attempt_ref: String,
    },
    Cancel {
        world: [Value; 3],
        run_id: String,
    },
    Retry {
        world: [Value; 3],
        run_id: String,
    },
}
fn default_profile() -> String {
    "super-javascript-behavior@1".into()
}
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
fn world_dir(data: &Path, world: &[Value; 3]) -> Result<PathBuf, String> {
    if !world[0].is_string() || !world[1].is_u64() {
        return Err("Current runtime identity is unavailable.".into());
    }
    let key = format!(
        "{:x}",
        Sha256::digest(json!([world[0], world[1]]).to_string())
    );
    let path = data.join("review-tests").join(key);
    fs::create_dir_all(&path).map_err(err)?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).map_err(err)?;
    Ok(path)
}
fn save(path: &Path, value: &Value) -> Result<(), String> {
    let temp = path.with_extension("tmp");
    fs::write(&temp, serde_json::to_vec(value).map_err(err)?).map_err(err)?;
    fs::rename(temp, path).map_err(err)
}
fn read(path: &Path) -> Result<Value, String> {
    let f = fs::File::open(path).map_err(err)?;
    if f.metadata().map_err(err)?.len() > 256 * 1024 {
        return Err("Local test record exceeds its limit.".into());
    }
    let mut bytes = Vec::new();
    f.take(256 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(err)?;
    serde_json::from_slice(&bytes).map_err(err)
}
fn runtime_outcome(record: &Value, attempt: &Value) -> Value {
    let r = &record["result"];
    let output = r["output"]
        .as_str()
        .or_else(|| record["message"].as_str())
        .unwrap_or("");
    let preview: String = output.chars().filter(|c| *c != '\0').take(256).collect();
    json!({"state":if r["state"]=="completed"{"completed"}else{"failed"},"verdict":r["verdict"],
        "reason":if r.is_null(){json!("runner-error")}else{r["reason"].clone()},
        "source_basis_id":if r.is_null(){attempt["source"]["basis_id"].clone()}else{r["source_basis_id"].clone()},"result_sha256":if r.is_null(){attempt["source"]["result_sha256"].clone()}else{r["result_sha256"].clone()},
        "profile":r["profile"].as_str().or_else(||record["profile"].as_str()).unwrap_or("super-javascript-behavior@1"),"toolchain_sha256":r["toolchain_sha256"],"snapshot_sha256":r["snapshot_sha256"],"node_sha256":r["node_sha256"],
        "test_count":r["tests"].as_array().map(Vec::len).unwrap_or(0),"output":preview,
        "output_omitted":preview!=output||r["omitted_bytes"].as_u64().unwrap_or(0)>0})
}
impl Runs {
    fn finish(&self, receipt: PathBuf, mut record: Value, fields: Value, report: &Report) -> Value {
        let id = fields["run_id"].as_str().unwrap().to_owned();
        record["runtime_save_error"] = json!(true);
        let mut pending = self.1.lock().unwrap_or_else(|e| e.into_inner());
        pending.insert(
            id.clone(),
            Pending {
                fields,
                receipt,
                record: record.clone(),
            },
        );
        if let Some(item) = pending.get_mut(&id) {
            if let Ok(run) = report("finish_development_test", item.fields.clone()) {
                item.record["runtime_record"] = run;
                item.record["runtime_save_error"] = json!(false);
                record = item.record.clone();
                if save(&item.receipt, &record).is_ok() {
                    pending.remove(&id);
                    return record;
                }
            }
            let _ = save(&item.receipt, &item.record);
            record = item.record.clone();
        }
        record
    }
    fn retry(&self, world: [Value; 3], run_id: String, report: &Report) -> Result<Value, String> {
        let mut pending = self.1.lock().map_err(|_| "Test recording is busy.")?;
        let item = pending.get_mut(&run_id).ok_or(
            "No trusted completion is available in this app session. Tests were not rerun.",
        )?;
        if item.fields["world"] != json!(world) {
            return Err("The runtime changed. This completion cannot be retried here.".into());
        }
        let run = report("finish_development_test", item.fields.clone())?;
        item.record["runtime_record"] = run;
        item.record["runtime_save_error"] = json!(false);
        if let Some(parent) = item.receipt.parent() {
            fs::create_dir_all(parent).map_err(err)?;
            fs::set_permissions(parent, fs::Permissions::from_mode(0o700)).map_err(err)?;
        }
        save(&item.receipt, &item.record)?;
        let record = item.record.clone();
        pending.remove(&run_id);
        Ok(record)
    }
    pub fn start(
        &self,
        data: &Path,
        world: [Value; 3],
        root: PathBuf,
        attempt: Value,
        report: Report,
        profile: String,
    ) -> Result<Value, String> {
        if ![
            "super-javascript-behavior@1",
            "super-elixir-review@1",
            "super-rust-review@1",
        ]
        .contains(&profile.as_str())
        {
            return Err("Unsupported test profile.".into());
        }
        let base = world_dir(data, &world)?;
        let mut active = self.0.lock().map_err(|_| "Tests are busy.")?;
        if self.1.lock().map_err(|_| "Test recording is busy.")?.len() >= 32 {
            return Err("Retry pending outcomes before starting more tests.".into());
        }
        if !active.is_empty() {
            return Err("Finish or cancel the active test run first.".into());
        }
        if fs::read_dir(&base)
            .map_err(err)?
            .filter_map(Result::ok)
            .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
            .count()
            >= 32
        {
            return Err("Local test history reached its 32-run limit for this world. Existing records are preserved.".into());
        }
        let id = format!(
            "run-{}-{}",
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
        fs::write(
            dir.join("runner.mjs"),
            include_str!("../../tools/proposal-test-runner.mjs"),
        )
        .map_err(err)?;
        fs::write(
            dir.join("lib/proposal-test-runner.mjs"),
            include_str!("../../tools/lib/proposal-test-runner.mjs"),
        )
        .map_err(err)?;
        fs::write(
            dir.join("attempt.json"),
            serde_json::to_vec(&attempt).map_err(err)?,
        )
        .map_err(err)?;
        let receipt = base.join(format!("{id}.json"));
        let mut record = json!({"schema":"device-review-tests@1","run_id":id,"attempt_ref":attempt["id"],"world":[world[0],world[1]],"result_sha256":attempt["source"]["result_sha256"],"profile":profile,"state":"starting","local_only":true});
        save(&receipt, &record)?;
        let output = fs::File::create(dir.join("launcher.json")).map_err(err)?;
        let errors = fs::File::create(dir.join("launcher-error.txt")).map_err(err)?;
        match report(
            "begin_development_test",
            json!({"attempt_ref":attempt["id"],"fields":{"run_id":id,"revision":attempt["revision"],"path":root,"world":world,"profile":profile}}),
        ) {
            Ok(run) => {
                record["runtime_record"] = run;
                save(&receipt, &record)?;
            }
            Err(message) => {
                record["state"] = json!("failed");
                record["message"] = json!(format!("Tests were not launched: {message}"));
                save(&receipt, &record)?;
                return Err(message);
            }
        }
        let child = Command::new("node")
            .arg(dir.join("runner.mjs"))
            .arg(root)
            .arg(dir.join("attempt.json"))
            .arg(&dir)
            .arg(&profile)
            .stdin(Stdio::null())
            .stdout(output)
            .stderr(errors)
            .spawn();
        let child = match child {
            Ok(c) => Arc::new(Mutex::new(c)),
            Err(_) => {
                record["state"] = json!("failed");
                record["message"] = json!("Node could not start. Install Node and reopen Super.");
                let outcome = runtime_outcome(&record, &attempt);
                record=self.finish(receipt,record,json!({"attempt_ref":attempt["id"],"run_id":id,"world":world,"outcome":outcome}),&report);
                return Ok(record);
            }
        };
        active.insert(id.clone(), child.clone());
        record["state"] = json!("running");
        save(&receipt, &record)?;
        let state = self.clone();
        let initial = record.clone();
        std::thread::spawn(move || {
            loop {
                let done = child
                    .lock()
                    .ok()
                    .and_then(|mut c| c.try_wait().ok())
                    .flatten()
                    .is_some();
                if done {
                    break;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            let result = (|| -> Result<Value, String> {
                let launch = read(&dir.join("launcher.json"))?;
                let result_dir = PathBuf::from(
                    launch["directory"]
                        .as_str()
                        .ok_or("Test run did not return a result location.")?,
                )
                .canonicalize()
                .map_err(err)?;
                if !result_dir.starts_with(dir.canonicalize().map_err(err)?) {
                    return Err("Invalid test result location.".into());
                }
                read(&result_dir.join("outcome.json"))
            })();
            let mut finished = initial;
            match result {
                Ok(result) => {
                    finished["state"] = result["state"].clone();
                    finished["result"] = result;
                }
                Err(_) => {
                    finished["state"] = json!("failed");
                    let message =
                        fs::read_to_string(dir.join("launcher-error.txt")).unwrap_or_default();
                    finished["message"] = json!(if message.is_empty() {
                        "The runner ended without a complete result.".into()
                    } else {
                        message.chars().take(1200).collect::<String>()
                    });
                }
            }
            let outcome = runtime_outcome(&finished, &attempt);
            state.finish(
                receipt,
                finished,
                json!({"attempt_ref":attempt["id"],"run_id":id,"world":world,"outcome":outcome}),
                &report,
            );
            if let Ok(mut rows) = state.0.lock() {
                rows.remove(&id);
            }
        });
        Ok(record)
    }
    pub fn request(&self, data: &Path, request: Request, report: Report) -> Result<Value, String> {
        match request {
            Request::List { world, attempt_ref } => {
                let key = json!([world, attempt_ref]).to_string();
                let mut recovered = self.2.lock().map_err(|_| "Recovery is busy.")?;
                if !recovered.contains(&key) {
                    report(
                        "recover_development_tests",
                        json!({"attempt_ref":attempt_ref,"world":world}),
                    )?;
                    recovered.insert(key);
                }
                drop(recovered);
                let base = world_dir(data, &world)?;
                let active = self.0.lock().map_err(|_| "Test status is busy.")?;
                let mut rows = Vec::new();
                for entry in fs::read_dir(base).map_err(err)?.filter_map(Result::ok) {
                    if entry.path().extension().is_none_or(|x| x != "json") {
                        continue;
                    }
                    let mut row = read(&entry.path())?;
                    if row["attempt_ref"] != attempt_ref {
                        continue;
                    }
                    if ["starting", "running"].contains(&row["state"].as_str().unwrap_or(""))
                        && !active.contains_key(row["run_id"].as_str().unwrap_or(""))
                    {
                        row["state"] = json!("interrupted");
                        row["message"]=json!("The app stopped before a final result was recorded. This run has no passing verdict.");
                    }
                    row["retryable"] = json!(false);
                    rows.push(row);
                }
                // Overlay trusted in-memory completions, including when the local cache is lost.
                let pending = self.1.lock().map_err(|_| "Test recording is busy.")?;
                for (id, item) in pending.iter().filter(|(_, p)| {
                    p.fields["world"] == json!(world) && p.fields["attempt_ref"] == attempt_ref
                }) {
                    rows.retain(|r| r["run_id"] != *id);
                    let mut row = item.record.clone();
                    row["retryable"] = json!(true);
                    rows.push(row);
                }
                rows.sort_by_key(|r| r["run_id"].as_str().unwrap_or("").to_owned());
                Ok(json!({"runs":rows}))
            }
            Request::Retry { world, run_id } => self.retry(world, run_id, &report),
            Request::Cancel { world, run_id } => {
                if !run_id
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-')
                {
                    return Err("Invalid test run.".into());
                }
                let base = world_dir(data, &world)?;
                read(&base.join(format!("{run_id}.json")))?;
                let active = self.0.lock().map_err(|_| "Test status is busy.")?;
                if let Some(child) = active.get(&run_id) {
                    let mut child = child.lock().map_err(|_| "Test cancellation is busy.")?;
                    if child.try_wait().map_err(err)?.is_none() {
                        unsafe {
                            libc::kill(child.id() as i32, libc::SIGTERM);
                        }
                    }
                }
                Ok(json!({"status":"cancellation_requested"}))
            }
            Request::LaunchBuild { .. }
            | Request::PreviewStatus { .. }
            | Request::StopPreview { .. }
            | Request::BuildAccepted { .. }
            | Request::ListBuilds { .. }
            | Request::CancelBuild { .. }
            | Request::VerifyAccepted { .. }
            | Request::Accept { .. }
            | Request::Start { .. } => Err("Start requires native repository verification.".into()),
        }
    }
}

#[cfg(test)]
mod recovery_tests {
    use super::*;
    fn fixture() -> (Runs, PathBuf, [Value; 3], Value, Value) {
        let dir = std::env::temp_dir().join(format!(
            "super-retry-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let world = [json!("fixture-world"), json!(1), json!("epoch")];
        let base = world_dir(&dir, &world).unwrap();
        let record = json!({"run_id":"run-fixture","attempt_ref":"attempt-fixture","state":"completed","result":{"verdict":"fail","output":"original result"}});
        let fields = json!({"world":world,"run_id":"run-fixture","attempt_ref":"attempt-fixture","outcome":{"verdict":"fail","output":"original result"}});
        (
            Runs::default(),
            base.join("run-fixture.json"),
            world,
            record,
            fields,
        )
    }
    fn unavailable() -> Report {
        Arc::new(|op, _| {
            if op == "recover_development_tests" {
                Ok(json!({}))
            } else {
                Err("Runtime unavailable".into())
            }
        })
    }
    #[test]
    fn lost_ack_retry_resends_exact_native_completion_and_clears_pending() {
        let (runs, path, world, record, fields) = fixture();
        let calls = Arc::new(Mutex::new(Vec::new()));
        let seen = calls.clone();
        let report: Report = Arc::new(move |op, value| {
            assert_eq!(op, "finish_development_test");
            let mut seen = seen.lock().unwrap();
            seen.push(value);
            if seen.len() == 1 {
                Err("Acknowledgement lost".into())
            } else {
                Ok(json!({"state":"completed"}))
            }
        });
        assert_eq!(
            runs.finish(path.clone(), record, fields.clone(), &report)["runtime_save_error"],
            true
        );
        // A forged cache result must never become the retry payload.
        save(&path, &json!({"outcome":{"verdict":"pass"}})).unwrap();
        let result = runs.retry(world, "run-fixture".into(), &report).unwrap();
        assert_eq!(result["runtime_save_error"], false);
        assert_eq!(*calls.lock().unwrap(), vec![fields.clone(), fields]);
        assert!(runs.1.lock().unwrap().is_empty());
        fs::remove_dir_all(path.parent().unwrap().parent().unwrap().parent().unwrap()).unwrap();
    }
    #[test]
    fn wrong_world_and_missing_session_never_report() {
        let (runs, path, world, record, fields) = fixture();
        runs.finish(path.clone(), record, fields, &unavailable());
        let never: Report = Arc::new(|_, _| panic!("must not report"));
        let mut changed = world.clone();
        changed[2] = json!("new-epoch");
        assert!(runs
            .retry(changed, "run-fixture".into(), &never)
            .unwrap_err()
            .contains("runtime changed"));
        assert!(Runs::default()
            .retry(world, "run-fixture".into(), &never)
            .unwrap_err()
            .contains("No trusted completion"));
        fs::remove_dir_all(path.parent().unwrap().parent().unwrap().parent().unwrap()).unwrap();
    }
    #[test]
    fn repeated_failure_retains_completion_and_cache_loss_is_recoverable() {
        let (runs, path, world, record, fields) = fixture();
        runs.finish(path.clone(), record, fields.clone(), &unavailable());
        assert!(runs
            .retry(world.clone(), "run-fixture".into(), &unavailable())
            .is_err());
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
        let data = path.parent().unwrap().parent().unwrap().parent().unwrap();
        let listed = runs
            .request(
                data,
                Request::List {
                    world: world.clone(),
                    attempt_ref: "attempt-fixture".into(),
                },
                unavailable(),
            )
            .unwrap();
        assert_eq!(listed["runs"][0]["retryable"], true);
        assert_eq!(listed["runs"][0]["result"]["verdict"], "fail");
        let report: Report = Arc::new(move |_, value| {
            assert_eq!(value, fields);
            Ok(json!({"state":"completed"}))
        });
        runs.retry(world, "run-fixture".into(), &report).unwrap();
        assert_eq!(read(&path).unwrap()["runtime_save_error"], false);
        fs::remove_dir_all(data).unwrap();
    }
    #[test]
    fn editable_cache_cannot_advertise_a_trusted_retry() {
        let (runs, path, world, mut record, _) = fixture();
        record["retryable"] = json!(true);
        record["runtime_save_error"] = json!(true);
        save(&path, &record).unwrap();
        let data = path.parent().unwrap().parent().unwrap().parent().unwrap();
        let listed = runs
            .request(
                data,
                Request::List {
                    world,
                    attempt_ref: "attempt-fixture".into(),
                },
                unavailable(),
            )
            .unwrap();
        assert_eq!(listed["runs"][0]["retryable"], false);
        fs::remove_dir_all(data).unwrap();
    }
    #[test]
    fn retry_request_cannot_supply_an_outcome() {
        assert!(serde_json::from_value::<Request>(json!({"operation":"retry","world":["w",1,"e"],"run_id":"run-fixture","outcome":{"verdict":"pass"}})).is_err());
    }
}

pub fn verify_acceptance(
    data: &Path,
    root: &Path,
    attempt: &Value,
    run_id: &str,
) -> Result<Value, String> {
    let run = &attempt["test_runs"][run_id];
    if run["state"] != "completed" || run["outcome"]["verdict"] != "pass" {
        return Err("Choose a completed passing test run.".into());
    }
    let dir = data.join(format!(
        "acceptance-check-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(err)?
            .as_nanos()
    ));
    fs::create_dir_all(&dir).map_err(err)?;
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).map_err(err)?;
    let checked = (|| -> Result<Value, String> {
        fs::create_dir(dir.join("lib")).map_err(err)?;
        fs::write(
            dir.join("check.mjs"),
            include_str!("../../tools/proposal-acceptance-check.mjs"),
        )
        .map_err(err)?;
        fs::write(
            dir.join("lib/proposal-test-runner.mjs"),
            include_str!("../../tools/lib/proposal-test-runner.mjs"),
        )
        .map_err(err)?;
        fs::write(
            dir.join("attempt.json"),
            serde_json::to_vec(attempt).map_err(err)?,
        )
        .map_err(err)?;
        fs::write(dir.join("run.json"), serde_json::to_vec(run).map_err(err)?).map_err(err)?;
        let stdout = fs::File::create(dir.join("result.json")).map_err(err)?;
        let stderr = fs::File::create(dir.join("error.txt")).map_err(err)?;
        let mut child = Command::new("node")
            .arg(dir.join("check.mjs"))
            .arg(root)
            .arg(dir.join("attempt.json"))
            .arg(dir.join("run.json"))
            .stdin(Stdio::null())
            .stdout(stdout)
            .stderr(stderr)
            .spawn()
            .map_err(err)?;
        let started = std::time::Instant::now();
        loop {
            if let Some(status) = child.try_wait().map_err(err)? {
                if !status.success() {
                    return Err(fs::read_to_string(dir.join("error.txt"))
                        .unwrap_or_else(|_| "The file check failed.".into()));
                }
                break;
            }
            if started.elapsed() > Duration::from_secs(30) {
                let _ = child.kill();
                let _ = child.wait();
                return Err("The acceptance file check timed out.".into());
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let checked = read(&dir.join("result.json"))?;
        if checked["snapshot_sha256"] != run["outcome"]["snapshot_sha256"]
            || checked["result_sha256"] != attempt["source"]["result_sha256"]
            || checked["head"] != attempt["source"]["head"]
        {
            return Err("The native check did not confirm the tested content.".into());
        }
        Ok(checked)
    })();
    let _ = fs::remove_dir_all(dir);
    checked
}

// Read-only observation of the accepted record, never another acceptance or build receipt.
fn accepted_run(attempt: &Value) -> Result<&str, String> {
    let decision = &attempt["acceptance"];
    let id = decision["run_id"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("No accepted test run is retained.")?;
    let refs = decision["profile_run_refs"]
        .as_object()
        .filter(|r| !r.is_empty())
        .ok_or("Accepted profile coverage is unavailable.")?;
    if attempt["status"] != "accepted"
        || decision["schema"] != "development-acceptance@1"
        || decision["task_revision"] != attempt["task_revision"]
        || decision["source_basis_id"] != attempt["source"]["basis_id"]
        || decision["result_sha256"] != attempt["source"]["result_sha256"]
        || !refs.values().any(|r| r == id)
    {
        return Err("The retained acceptance does not match this review.".into());
    }
    for (profile, run_ref) in refs {
        let run_id = run_ref
            .as_str()
            .ok_or("Invalid accepted profile reference.")?;
        let run = &attempt["test_runs"][run_id];
        let outcome = &run["outcome"];
        if run["state"] != "completed"
            || outcome["verdict"] != "pass"
            || run["profile"]
                .as_str()
                .unwrap_or("super-javascript-behavior@1")
                != profile
            || outcome["snapshot_sha256"] != decision["snapshot_sha256"]
            || outcome["result_sha256"] != decision["result_sha256"]
            || outcome["source_basis_id"] != decision["source_basis_id"]
        {
            return Err("Accepted test coverage is unavailable or inconsistent.".into());
        }
    }
    Ok(id)
}
pub fn verify_accepted_result(data: &Path, root: &Path, attempt: &Value) -> Result<Value, String> {
    let run_id = accepted_run(attempt)?;
    verify_acceptance(data, root, attempt, run_id).map_err(|e| {
        e.replace(
            "Save the exact reviewed proposal before accepting it.",
            "The saved files no longer match the accepted result.",
        )
    })
}

#[cfg(test)]
mod accepted_tests {
    use super::*;
    fn accepted() -> Value {
        json!({"status":"accepted","task_revision":1,"source":{"basis_id":"basis","result_sha256":"result"},"acceptance":{"schema":"development-acceptance@1","task_revision":1,"run_id":"r","source_basis_id":"basis","result_sha256":"result","snapshot_sha256":"snapshot","profile_run_refs":{"super-javascript-behavior@1":"r"}},"test_runs":{"r":{"state":"completed","profile":"super-javascript-behavior@1","outcome":{"verdict":"pass","source_basis_id":"basis","result_sha256":"result","snapshot_sha256":"snapshot"}}}})
    }
    #[test]
    fn accepted_check_uses_retained_decision_coverage() {
        let a = accepted();
        assert_eq!(accepted_run(&a).unwrap(), "r");
    }
    #[test]
    fn nonaccepted_or_substituted_records_refuse() {
        for key in ["status", "acceptance", "test_runs", "source"] {
            let mut a = accepted();
            a[key] = Value::Null;
            assert!(accepted_run(&a).is_err());
        }
        for key in ["source_basis_id", "result_sha256", "snapshot_sha256"] {
            let mut a = accepted();
            a["test_runs"]["r"]["outcome"][key] = json!("other");
            assert!(accepted_run(&a).is_err());
        }
        let mut a = accepted();
        a["acceptance"]["profile_run_refs"]["super-rust-review@1"] = json!("missing");
        assert!(accepted_run(&a).is_err());
    }
    #[test]
    fn accepted_check_request_cannot_supply_source_or_outcomes() {
        let request = json!({"operation":"verify_accepted","generation":1,"attempt_ref":"da_1","revision":2,"world":["w",1,"e"]});
        assert!(serde_json::from_value::<Request>(request.clone()).is_ok());
        let mut build = request.clone();
        build["operation"] = json!("build_accepted");
        assert!(serde_json::from_value::<Request>(build.clone()).is_ok());
        build["command"] = json!("arbitrary");
        assert!(serde_json::from_value::<Request>(build).is_err());
        for key in [
            "path",
            "attempt",
            "run_id",
            "outcome",
            "acceptance",
            "command",
        ] {
            let mut changed = request.clone();
            changed[key] = json!("forged");
            assert!(serde_json::from_value::<Request>(changed).is_err());
        }
    }
}
