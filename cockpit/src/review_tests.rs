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
        #[serde(default)]
        compare: bool,
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

// ── Device-local test history: retention, not a wall ─────────────────────────
//
// Every run RETAINS its snapshot — a full copy of the reviewed repository — which
// is the only reason the count was ever capped. Measured on this machine
// 2026-09-19: **202 MB across three worlds, 184 MB in ten runs of the live one**,
// 8–18 MB per run. The cap was a bare `>= 32` with nothing behind it, so when the
// live world reached it EVERY profile run was refused until 24 records were moved
// out by hand — the app stopped being able to test at all, and the only way back
// was a person with a shell.
//
// A cap with no retention is a wall. What history needs is what was run and what
// it decided: the record. What it does not need is a second copy of a repository
// that `verify_acceptance` never reads — that re-captures the checkout and
// compares digests, and nothing reads a retained snapshot after its run finishes.
//
// So the newest few finished runs keep their snapshot and the rest are RELEASED:
// the record stays, and says `snapshot_retained: false`, which is the literal
// truth of the promise the old refusal made. Records themselves move to
// `archive/` — still on disk, out of the count — once the live directory passes
// its high-water mark, oldest first. Both run on every start, so a world already
// at the cap heals on its next run instead of being stuck exactly where nothing
// can be tested. The arithmetic: 4 x ~18 MB retained + 128 x ~60 KB of records is
// about 80 MB per world, against the 184 MB that ten runs held before.
const RETAINED_SNAPSHOTS: usize = 4;
const RECORDS_HIGH: usize = 128;
const RECORDS_LOW: usize = 96;

/// A run id is `run-<pid>-<nanos>`, so the NANOS orders it. Sorting the file name
/// would order by pid, which is neither time nor anything else.
fn run_order(stem: &str) -> u128 {
    stem.rsplit('-').next().and_then(|n| n.parse().ok()).unwrap_or(0)
}

/// A run still in flight owns its snapshot; anything else is finished, including a
/// record this build cannot read.
fn in_flight(record: &Value) -> bool {
    matches!(record["state"].as_str(), Some("starting") | Some("running"))
}

/// Every record in one world's history, newest first.
fn history(base: &Path) -> Result<Vec<(PathBuf, Value)>, String> {
    let mut rows = Vec::new();
    for entry in fs::read_dir(base).map_err(err)? {
        let path = entry.map_err(err)?.path();
        if path.extension().is_some_and(|x| x == "json") {
            let record = read(&path).unwrap_or_else(|_| json!({"state": "unreadable"}));
            rows.push((path, record));
        }
    }
    rows.sort_by_key(|(path, _)| {
        std::cmp::Reverse(run_order(path.file_stem().and_then(|s| s.to_str()).unwrap_or("")))
    });
    Ok(rows)
}

/// Release what history does not need and archive what the live directory cannot
/// hold. Never touches a run in flight, and is idempotent.
fn retire_history(base: &Path) -> Result<usize, String> {
    let rows = history(base)?;
    let mut finished = 0usize;
    for (path, record) in &rows {
        if in_flight(record) {
            continue;
        }
        finished += 1;
        if finished <= RETAINED_SNAPSHOTS {
            continue;
        }
        let snapshot = path.with_extension("");
        if snapshot.is_dir() {
            fs::remove_dir_all(&snapshot).map_err(err)?;
            let mut released = record.clone();
            if released["result"].is_object() {
                released["result"]["snapshot_retained"] = json!(false);
            }
            released["snapshot_released"] = json!(true);
            save(path, &released)?;
        }
    }
    if rows.len() >= RECORDS_HIGH {
        let archive = base.join("archive");
        fs::create_dir_all(&archive).map_err(err)?;
        fs::set_permissions(&archive, fs::Permissions::from_mode(0o700)).map_err(err)?;
        let mut over = rows.len().saturating_sub(RECORDS_LOW);
        for (path, record) in rows.iter().rev() {
            if over == 0 {
                break;
            }
            if in_flight(record) {
                continue;
            }
            let name = path.file_name().ok_or("Invalid history record name.")?;
            fs::rename(path, archive.join(name)).map_err(err)?;
            let snapshot = path.with_extension("");
            if snapshot.is_dir() {
                let to = archive.join(snapshot.file_name().ok_or("Invalid history run name.")?);
                fs::rename(&snapshot, to).map_err(err)?;
            }
            over -= 1;
        }
    }
    Ok(history(base)?.len())
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
        compare: bool,
    ) -> Result<Value, String> {
        if ![
            "super-javascript-behavior@1",
            "super-elixir-review@1",
            "super-rust-review@1",
            "repository-document-review@1",
            "repository-python-gate@1",
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
        let records = retire_history(&base)?;
        if records >= RECORDS_HIGH {
            return Err(format!(
                "Local test history holds {records} runs for this world and none of them can be retired — finish or recover the runs still in flight. Existing records are preserved."
            ));
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
        // The document profile's check runs from Super's own pinned bytes, so it
        // travels with the runner rather than out of the repository under review.
        fs::write(
            dir.join("lib/document-review-check.mjs"),
            include_str!("../../tools/lib/document-review-check.mjs"),
        )
        .map_err(err)?;
        fs::write(
            dir.join("attempt.json"),
            serde_json::to_vec(&resolve_review_bodies(&attempt)?).map_err(err)?,
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
            .arg(if compare { "compare" } else { "candidate-only" })
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
            if finished["result"]["baseline"].is_object() {
                if let Err(message)=crate::screenshots::retain_comparison(&json!([world[0],world[1]]),attempt["task_ref"].as_str().unwrap_or(""),attempt["task_revision"].as_u64().unwrap_or(0),&id,&finished["result"]) {finished["evidence_error"]=json!(message);}
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
mod retention_tests {
    use super::*;

    /// One world's history directory, private to one test.
    fn world(name: &str) -> PathBuf {
        let d = std::env::temp_dir()
            .join(format!("super-review-tests-retention-{}", std::process::id()))
            .join(name);
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    /// A finished run and the snapshot it retained, or one still in flight.
    fn run(base: &Path, pid: u32, nanos: u128, state: &str) -> String {
        let id = format!("run-{pid}-{nanos}");
        let dir = base.join(&id);
        fs::create_dir_all(dir.join("snapshot")).unwrap();
        fs::write(dir.join("snapshot/value.mjs"), "export const value = 1;\n").unwrap();
        save(
            &base.join(format!("{id}.json")),
            &json!({"schema":"device-review-tests@1","run_id":id,"state":state,
                    "result":{"state":state,"verdict":"pass","snapshot_retained":true}}),
        )
        .unwrap();
        id
    }

    fn json_count(base: &Path) -> usize {
        fs::read_dir(base)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
            .count()
    }

    #[test]
    fn a_run_is_ordered_by_its_nanos_and_not_by_the_pid_in_front_of_them() {
        // The pid comes first in the name, so sorting the name sorts by pid. The
        // first version of this did exactly that and retired the newest run.
        assert!(run_order("run-9-200") > run_order("run-1000-100"));
        assert_eq!(run_order("nonsense"), 0);
    }

    #[test]
    fn the_newest_snapshots_are_kept_and_the_rest_released_with_their_records_intact() {
        let base = world("release");
        let ids: Vec<_> = (1..=7)
            .map(|n| run(&base, 1000 + n as u32, 100 + n as u128, "completed"))
            .collect();

        assert_eq!(retire_history(&base).unwrap(), 7);

        // Every record is still here — that is the promise the old refusal made.
        assert_eq!(json_count(&base), 7);
        for (i, id) in ids.iter().enumerate() {
            let newest_four = i >= ids.len() - RETAINED_SNAPSHOTS;
            let record = read(&base.join(format!("{id}.json"))).unwrap();
            assert_eq!(
                base.join(id).is_dir(),
                newest_four,
                "{id}: snapshot retention is wrong"
            );
            assert_eq!(
                record["result"]["snapshot_retained"].as_bool().unwrap(),
                newest_four,
                "{id}: the record does not say what is on disk"
            );
            assert_eq!(record["result"]["verdict"], "pass", "{id}: the verdict is gone");
        }

        // Retiring twice is retiring once.
        let before: Vec<_> = ids.iter().map(|i| base.join(i).is_dir()).collect();
        retire_history(&base).unwrap();
        let after: Vec<_> = ids.iter().map(|i| base.join(i).is_dir()).collect();
        assert_eq!(before, after);
    }

    #[test]
    fn a_run_in_flight_keeps_its_snapshot_however_old_it_is() {
        let base = world("in-flight");
        let stuck = run(&base, 1, 1, "running");
        let starting = run(&base, 2, 2, "starting");
        for n in 3..=9 {
            run(&base, 100 + n as u32, n as u128, "completed");
        }
        retire_history(&base).unwrap();
        assert!(base.join(&stuck).is_dir(), "a running run lost its snapshot");
        assert!(base.join(&starting).is_dir(), "a starting run lost its snapshot");
    }

    #[test]
    fn the_oldest_records_move_to_archive_when_the_directory_passes_its_mark_and_are_still_there() {
        let base = world("archive");
        let ids: Vec<_> = (1..=RECORDS_HIGH)
            .map(|n| run(&base, 1000 + n as u32, 100 + n as u128, "completed"))
            .collect();

        let left = retire_history(&base).unwrap();
        assert_eq!(left, RECORDS_LOW);
        assert_eq!(json_count(&base), RECORDS_LOW);

        let moved = RECORDS_HIGH - RECORDS_LOW;
        for id in ids.iter().take(moved) {
            assert!(!base.join(format!("{id}.json")).exists(), "{id} is still live");
            assert!(
                base.join("archive").join(format!("{id}.json")).exists(),
                "{id} was destroyed rather than archived"
            );
        }
        for id in ids.iter().skip(moved) {
            assert!(base.join(format!("{id}.json")).exists(), "{id} was archived too early");
        }
        // The archive is out of the count, so the next run is admitted.
        assert!(retire_history(&base).unwrap() < RECORDS_HIGH);
    }

    #[test]
    fn an_unreadable_record_is_retired_rather_than_pinning_a_snapshot_forever() {
        let base = world("unreadable");
        for n in 1..=6 {
            run(&base, 100 + n as u32, n as u128, "completed");
        }
        fs::write(base.join("run-1-1.json"), "{not json").unwrap();
        fs::create_dir_all(base.join("run-1-1/snapshot")).unwrap();
        retire_history(&base).unwrap();
        assert!(!base.join("run-1-1").is_dir(), "an unreadable record pinned its snapshot");
        assert!(base.join("run-1-1.json").exists(), "an unreadable record was destroyed");
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


/// Put the reviewed bodies back into an attempt before a runner sees it.
///
/// Review content is published separately and a recorded attempt names it by
/// digest, so `development_attempts` can be projected without carrying file
/// text. The test runner and the acceptance check need the actual bytes, and
/// they need **the bytes that were reviewed** rather than whatever is on disk
/// now — so they are read from the content store and re-hashed here, once, and
/// handed over inline.
///
/// A member that already carries its own bytes is left exactly as it is: that
/// is the shape recorded before content was published separately, and it is
/// still valid material.
///
/// **Missing or corrupt content fails the whole operation.** There is no
/// fallback to the working tree: a test or an acceptance run against bytes
/// nobody reviewed is worse than one that does not happen.
///
/// **Every consumer of a record's bodies goes through here** — test start,
/// acceptance check, accepted build, preview launch and the accepted-source
/// verification in `main.rs`. The first version applied it to the first two
/// only; driving the cockpit showed a staged set that tested and was accepted
/// and whose accepted build then failed with "Review text exceeds its bounds."
/// — the runner's shape assertion reading a body that was never resolved.
pub(crate) fn resolve_review_bodies(attempt: &Value) -> Result<Value, String> {
    resolve_review_bodies_in(
        attempt,
        &crate::worker::world_dir().join("review-content").join("blobs"),
    )
}

/// The resolver over an explicit blob directory.
///
/// **The directory is a parameter so that a unit test never computes the
/// product world path.** The first version of these tests called
/// `worker::world_dir()` under `cargo test`, where nothing sets
/// `SUPER_WORLD_MODE`, and published their fixtures into
/// `~/.local/state/super/worlds/default/review-content/blobs` — the user's
/// real world — which is where four test strings were found on 2026-09-12.
fn resolve_review_bodies_in(attempt: &Value, blobs: &Path) -> Result<Value, String> {
    let mut attempt = attempt.clone();

    let read = |digest: &Value, path: &str, side: &str| -> Result<String, String> {
        let d = digest.as_str().unwrap_or_default();
        if d.len() != 64 || !d.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
            return Err(format!("{path}: the {side} content is not named by a digest."));
        }
        let bytes = fs::read(blobs.join(d))
            .map_err(|_| format!("{path}: the {side} reviewed content is no longer stored. Stage the proposal again."))?;
        let actual = {
            use sha2::{Digest, Sha256};
            let mut h = Sha256::new();
            h.update(&bytes);
            format!("{:x}", h.finalize())
        };
        if actual != d {
            return Err(format!("{path}: the {side} reviewed content no longer matches its digest."));
        }
        String::from_utf8(bytes).map_err(|_| format!("{path}: reviewed content is not text."))
    };

    let resolve = |member: &mut Value| -> Result<(), String> {
        if member.get("shared_draft").and_then(|v| v.as_str()).is_some() {
            return Ok(());
        }
        let source = member.get("source").cloned().unwrap_or(Value::Null);
        let path = source.get("path").and_then(|v| v.as_str()).unwrap_or("?").to_string();
        let deletion = source.get("schema").and_then(|v| v.as_str())
            == Some("selected-file-deletion-basis@1");
        let draft = read(source.get("draft_sha256").unwrap_or(&Value::Null), &path, "current")?;
        member["shared_draft"] = json!(draft);
        member["proposed_text"] = if deletion {
            Value::Null
        } else {
            json!(read(source.get("result_sha256").unwrap_or(&Value::Null), &path, "proposed")?)
        };
        Ok(())
    };

    if let Some(files) = attempt.get_mut("files").and_then(|f| f.as_array_mut()) {
        for member in files.iter_mut() {
            resolve(member)?;
        }
    } else if attempt.get("source").is_some() {
        resolve(&mut attempt)?;
    }
    Ok(attempt)
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
            serde_json::to_vec(&resolve_review_bodies(attempt)?).map_err(err)?,
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

#[cfg(test)]
mod review_content_tests {
    use super::*;
    use sha2::{Digest, Sha256};

    fn sha(b: &[u8]) -> String {
        let mut h = Sha256::new();
        h.update(b);
        format!("{:x}", h.finalize())
    }

    /// A blob directory private to one test. Never the product world: see
    /// `resolve_review_bodies_in`.
    fn blobs(name: &str) -> PathBuf {
        let d = std::env::temp_dir()
            .join(format!("super-review-content-test-{}", std::process::id()))
            .join(name);
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    /// Publish a blob where `resolve_review_bodies_in` will look for it.
    fn publish(blobs: &Path, body: &str) -> String {
        let d = sha(body.as_bytes());
        fs::write(blobs.join(&d), body).unwrap();
        d
    }

    fn member(path: &str, draft: &str, proposed: &str) -> Value {
        json!({"source": {
            "path": path,
            "schema": "selected-file-basis@1",
            "draft_sha256": sha(draft.as_bytes()),
            "result_sha256": sha(proposed.as_bytes()),
        }})
    }

    #[test]
    fn resolves_staged_bodies_and_leaves_inline_members_alone() {
        let blobs = blobs("resolves");
        publish(&blobs, "current text");
        publish(&blobs, "proposed text");
        let inline = json!({
            "source": {"path": "b.js", "schema": "selected-file-basis@1"},
            "shared_draft": "kept as it is",
            "proposed_text": "also kept"
        });
        let attempt = json!({"files": [member("a.js", "current text", "proposed text"), inline]});

        let out = resolve_review_bodies_in(&attempt, &blobs).expect("resolves");
        let files = out["files"].as_array().unwrap();
        assert_eq!(files[0]["shared_draft"], "current text");
        assert_eq!(files[0]["proposed_text"], "proposed text");
        // An inline member carries its own bytes and is not touched.
        assert_eq!(files[1]["shared_draft"], "kept as it is");
    }

    #[test]
    fn missing_content_fails_the_whole_operation_rather_than_falling_back() {
        let attempt = json!({"files": [member("gone.js", "never published", "nor this")]});
        let e = resolve_review_bodies_in(&attempt, &blobs("missing")).expect_err("must refuse");
        assert!(e.contains("gone.js"), "the message names the file: {e}");
        assert!(e.contains("no longer stored"), "and says which fault it is: {e}");
    }

    #[test]
    fn content_that_no_longer_hashes_to_its_name_is_refused_as_corrupt() {
        let blobs = blobs("corrupt");
        let d = publish(&blobs, "honest bytes");
        fs::write(blobs.join(&d), "tampered bytes").unwrap();

        let attempt = json!({"files": [member("a.js", "honest bytes", "honest bytes")]});
        let e = resolve_review_bodies_in(&attempt, &blobs).expect_err("must refuse");
        assert!(e.contains("no longer matches its digest"), "{e}");
    }

    #[test]
    fn a_deletion_member_resolves_its_current_side_and_a_null_proposal() {
        let blobs = blobs("deletion");
        publish(&blobs, "about to be deleted");
        let mut m = member("gone.js", "about to be deleted", "");
        m["source"]["schema"] = json!("selected-file-deletion-basis@1");
        let out = resolve_review_bodies_in(&json!({"files": [m]}), &blobs).expect("resolves");
        assert_eq!(out["files"][0]["shared_draft"], "about to be deleted");
        assert!(out["files"][0]["proposed_text"].is_null());
    }

    #[test]
    fn a_name_that_is_not_a_digest_cannot_reach_the_filesystem() {
        let mut m = member("a.js", "x", "y");
        m["source"]["draft_sha256"] = json!("../../../../etc/passwd");
        let e = resolve_review_bodies_in(&json!({"files": [m]}), &blobs("traversal")).expect_err("must refuse");
        assert!(e.contains("not named by a digest"), "{e}");
    }
}
