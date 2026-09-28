//! Conversation bodies on this device: the file text a saved conversation needs, named by its SHA-256.
//!
//! **Why this exists.** A saved conversation carried every shared file, every attachment and every proposal's
//! draft, original and content inline in one WebKit localStorage value. On 2026-09-27 that storage held 4.99 MiB of
//! its ~5 MB quota, `saveCurrent` threw, the error reached only a status line, and a restart lost four bot proposals
//! (`superlane/gate3/out-r3/RESULT.md`, limit 1). File bodies were 63 % of it. They live here now, and the saved
//! record keeps `{schema: "conversation-body@1", sha256, bytes}` in their place.
//!
//! **Durable before it is named, owned before it is referenced.** A `put`:
//!   1. writes `staging/<digest>.<n>.partial` and fsyncs it,
//!   2. re-reads what was written and hashes it,
//!   3. renames it to `blobs/<digest>` and fsyncs the directory,
//!   4. records the owner in `owners.json` (temporary file, fsync, rename, fsync the directory),
//!   and only then answers `stored`. The page writes a reference only after that answer, so a record can never
//!   name a body that is not on disk or not owned. A crash between the steps leaves a partial (swept), an unowned
//!   blob (collected after the grace period, and nothing references it) or an owned, unreferenced blob (kept until
//!   its conversation is deleted) — never a reference to nothing.
//!
//! **Reads re-hash**, the rule `review_content` follows: a blob answers `available`, `missing` or `corrupt`, and
//! never other bytes.
//!
//! **Retention is ownership, and ownership is only ever released by a person.** An owner is a saved conversation
//! (`conv:<store key>:<conversation id>`) or a migration original (`migration:<store key>`). A body loses an owner
//! only when that conversation is deleted or that original released. Collection removes a blob only when no owner
//! holds it AND it is older than `GRACE` — the grace covers a body written a moment before its owner is recorded.
//! An unreadable manifest refuses every mutation and every collection: read as empty, it would make everything
//! collectable.
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::{Duration, SystemTime},
};

/// A file body: the attachment and review limit (`attachments::REVIEW_FILE_BYTES`).
pub const BODY_BYTES: usize = crate::attachments::REVIEW_FILE_BYTES;
/// A migration original: a whole saved-conversation value (the store refuses above 3,000,000 UTF-16 units).
pub const ORIGINAL_BYTES: usize = 12 * 1024 * 1024;
/// The whole store.
pub const STORE_BYTES: u64 = 512 * 1024 * 1024;
pub const GRACE: Duration = Duration::from_secs(60 * 60);
const MANIFEST_SCHEMA: &str = "conversation-body-owners@1";

static STORE: OnceLock<Store> = OnceLock::new();

/// Called once at setup with the app data directory. Sweeps what an interrupted run left behind.
pub fn init(app_data: PathBuf) {
    let store = Store::new(app_data.join("conversation-bodies"));
    let _ = store.collect(SystemTime::now());
    let _ = STORE.set(store);
}

pub fn request(r: Value) -> Result<Value, String> {
    STORE.get().ok_or("Conversation body storage is unavailable.")?.request(&r)
}

pub struct Store {
    root: PathBuf,
    lock: Mutex<()>,
}

/// Where a `put` may be stopped in the tests, to leave exactly what a crash at that point would leave.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Stop {
    Never,
    AfterStaged,
    AfterRenamed,
}

fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn named(d: &str) -> bool {
    d.len() == 64 && d.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// `conv:<key>:<id>` or `migration:<key>`, printable and bounded. Never a path: it names a manifest entry only.
fn owner_ok(o: &str) -> bool {
    (o.starts_with("conv:") || o.starts_with("migration:"))
        && o.len() <= 300
        && o.bytes().all(|b| b.is_ascii_alphanumeric() || b":._-".contains(&b))
}

fn sync_dir(p: &Path) -> Result<(), String> {
    fs::File::open(p).and_then(|f| f.sync_all()).map_err(|_| "Could not make the body store durable.".to_string())
}

#[cfg(unix)]
fn private(p: &Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    let _ = fs::set_permissions(p, fs::Permissions::from_mode(mode));
}
#[cfg(not(unix))]
fn private(_: &Path, _: u32) {}

impl Store {
    pub fn new(root: PathBuf) -> Self {
        Store { root, lock: Mutex::new(()) }
    }
    fn blobs(&self) -> PathBuf {
        self.root.join("blobs")
    }
    fn staging(&self) -> PathBuf {
        self.root.join("staging")
    }
    fn manifest_path(&self) -> PathBuf {
        self.root.join("owners.json")
    }

    fn request(&self, r: &Value) -> Result<Value, String> {
        match r["operation"].as_str() {
            Some("put") => {
                let owner = r["owner"].as_str().ok_or("A body needs an owner.")?;
                let text = r["text"].as_str().ok_or("A body must be text.")?;
                let original = r["kind"] == "original";
                self.put(owner, text, original, Stop::Never)
            }
            Some("get") => self.get(r["sha256"].as_str().unwrap_or("")),
            Some("release") => self.release(r["owner"].as_str().unwrap_or("")),
            Some("report") => self.report(),
            Some("collect") => self.collect(SystemTime::now()),
            _ => Err("Unknown conversation body operation.".into()),
        }
    }

    fn ensure_dirs(&self) -> Result<(), String> {
        for d in [&self.root, &self.blobs(), &self.staging()] {
            fs::create_dir_all(d).map_err(|_| "Cannot create conversation body storage.")?;
            private(d, 0o700);
        }
        Ok(())
    }

    /// The owners, or a refusal. A manifest that exists and does not parse is NOT an empty one.
    fn owners(&self) -> Result<BTreeMap<String, BTreeSet<String>>, String> {
        let path = self.manifest_path();
        let raw = match fs::read(&path) {
            Ok(raw) => raw,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(BTreeMap::new()),
            Err(_) => return Err("The body retention manifest cannot be read; nothing was changed.".into()),
        };
        let v: Value = serde_json::from_slice(&raw)
            .map_err(|_| "The body retention manifest is unreadable; nothing was changed or collected.")?;
        if v["schema"] != MANIFEST_SCHEMA || !v["owners"].is_object() {
            return Err("The body retention manifest has an unknown format; nothing was changed or collected.".into());
        }
        let mut out = BTreeMap::new();
        for (owner, list) in v["owners"].as_object().unwrap() {
            let set: BTreeSet<String> = list
                .as_array()
                .ok_or("The body retention manifest is malformed; nothing was changed or collected.")?
                .iter()
                .filter_map(|d| d.as_str().filter(|d| named(d)).map(str::to_string))
                .collect();
            out.insert(owner.clone(), set);
        }
        Ok(out)
    }

    fn write_owners(&self, owners: &BTreeMap<String, BTreeSet<String>>) -> Result<(), String> {
        let body = serde_json::to_vec(&json!({"schema": MANIFEST_SCHEMA, "owners": owners}))
            .map_err(|_| "Could not encode the body retention manifest.")?;
        let tmp = self.root.join("owners.json.tmp");
        let mut f = fs::File::create(&tmp).map_err(|_| "Could not write the body retention manifest.")?;
        f.write_all(&body)
            .and_then(|_| f.sync_all())
            .map_err(|_| "Could not write the body retention manifest.")?;
        private(&tmp, 0o600);
        fs::rename(&tmp, self.manifest_path()).map_err(|_| "Could not record the body retention manifest.")?;
        sync_dir(&self.root)
    }

    fn stored_bytes(&self) -> u64 {
        fs::read_dir(self.blobs())
            .map(|it| it.flatten().filter_map(|e| e.metadata().ok()).map(|m| m.len()).sum())
            .unwrap_or(0)
    }

    /// Hash of a blob's bytes, or None when it is absent or unreadable.
    fn blob_digest(&self, d: &str) -> Option<String> {
        let mut bytes = Vec::new();
        fs::File::open(self.blobs().join(d)).ok()?.read_to_end(&mut bytes).ok()?;
        Some(digest(&bytes))
    }

    fn put(&self, owner: &str, text: &str, original: bool, stop: Stop) -> Result<Value, String> {
        if !owner_ok(owner) {
            return Err("Invalid body owner.".into());
        }
        if original && !owner.starts_with("migration:") {
            return Err("Only a migration may store an original.".into());
        }
        let limit = if original { ORIGINAL_BYTES } else { BODY_BYTES };
        let bytes = text.as_bytes();
        if bytes.len() > limit {
            return Err(format!("A body is limited to {} bytes; this one is {}.", limit, bytes.len()));
        }
        let d = digest(bytes);
        let _guard = self.lock.lock().map_err(|_| "Conversation body storage is busy.")?;
        // Read the manifest FIRST: if ownership cannot be recorded, nothing is written.
        let mut owners = self.owners()?;
        self.ensure_dirs()?;
        let target = self.blobs().join(&d);
        if self.blob_digest(&d).as_deref() != Some(d.as_str()) {
            if self.stored_bytes() + bytes.len() as u64 > STORE_BYTES {
                return Err("The device body store is full (512 MiB). Delete older saved conversations to make room.".into());
            }
            let partial = self.staging().join(format!(
                "{d}.{}.partial",
                SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|t| t.as_nanos()).unwrap_or(0)
            ));
            {
                let mut f = fs::File::create(&partial).map_err(|_| "Could not write the body.")?;
                f.write_all(bytes).and_then(|_| f.sync_all()).map_err(|_| "Could not write the body.")?;
            }
            private(&partial, 0o600);
            let mut written = Vec::new();
            fs::File::open(&partial)
                .and_then(|mut f| f.read_to_end(&mut written))
                .map_err(|_| "Could not re-read the written body.")?;
            if digest(&written) != d {
                let _ = fs::remove_file(&partial);
                return Err("The body did not read back as written; nothing was stored.".into());
            }
            if stop == Stop::AfterStaged {
                return Err("stopped after staging (test)".into());
            }
            fs::rename(&partial, &target).map_err(|_| "Could not store the body.")?;
            sync_dir(&self.blobs())?;
            sync_dir(&self.staging())?;
        }
        if stop == Stop::AfterRenamed {
            return Err("stopped after rename (test)".into());
        }
        owners.entry(owner.to_string()).or_default().insert(d.clone());
        self.write_owners(&owners)?;
        Ok(json!({"state": "stored", "sha256": d, "bytes": bytes.len()}))
    }

    fn get(&self, d: &str) -> Result<Value, String> {
        if !named(d) {
            return Err("A body is named by a SHA-256 digest in lower-case hex.".into());
        }
        let mut bytes = Vec::new();
        match fs::File::open(self.blobs().join(d)).and_then(|mut f| f.read_to_end(&mut bytes)) {
            Err(_) => return Ok(json!({"state": "missing", "sha256": d})),
            Ok(_) => {}
        }
        if digest(&bytes) != d {
            return Ok(json!({"state": "corrupt", "sha256": d}));
        }
        match String::from_utf8(bytes) {
            Ok(text) => Ok(json!({"state": "available", "sha256": d, "bytes": text.len(), "text": text})),
            Err(_) => Ok(json!({"state": "corrupt", "sha256": d, "reason": "not text"})),
        }
    }

    fn release(&self, owner: &str) -> Result<Value, String> {
        if !owner_ok(owner) {
            return Err("Invalid body owner.".into());
        }
        let _guard = self.lock.lock().map_err(|_| "Conversation body storage is busy.")?;
        let mut owners = self.owners()?;
        let released = owners.remove(owner).map(|s| s.len()).unwrap_or(0);
        if released > 0 {
            self.write_owners(&owners)?;
        }
        Ok(json!({"released": released}))
    }

    fn report(&self) -> Result<Value, String> {
        let owners = self.owners()?;
        let owned: BTreeSet<&String> = owners.values().flatten().collect();
        let (mut blobs, mut bytes, mut unowned) = (0u64, 0u64, 0u64);
        for e in fs::read_dir(self.blobs()).into_iter().flatten().flatten() {
            blobs += 1;
            bytes += e.metadata().map(|m| m.len()).unwrap_or(0);
            if !owned.contains(&e.file_name().to_string_lossy().to_string()) {
                unowned += 1;
            }
        }
        let partials = fs::read_dir(self.staging()).map(|it| it.count()).unwrap_or(0);
        Ok(json!({"blobs": blobs, "bytes": bytes, "owners": owners.len(), "owned": owned.len(),
                  "unowned": unowned, "partials": partials}))
    }

    /// Remove what no owner holds and what is older than the grace period; sweep stale partials.
    fn collect(&self, now: SystemTime) -> Result<Value, String> {
        let _guard = self.lock.lock().map_err(|_| "Conversation body storage is busy.")?;
        let owners = self.owners()?;
        let owned: BTreeSet<String> = owners.into_values().flatten().collect();
        let old = |p: &Path| {
            fs::metadata(p)
                .and_then(|m| m.modified())
                .map(|t| now.duration_since(t).unwrap_or(Duration::ZERO) >= GRACE)
                .unwrap_or(false)
        };
        let (mut collected, mut kept_young, mut swept) = (0u64, 0u64, 0u64);
        for e in fs::read_dir(self.blobs()).into_iter().flatten().flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if owned.contains(&name) {
                continue;
            }
            if old(&e.path()) {
                if fs::remove_file(e.path()).is_ok() {
                    collected += 1;
                }
            } else {
                kept_young += 1;
            }
        }
        for e in fs::read_dir(self.staging()).into_iter().flatten().flatten() {
            if old(&e.path()) && fs::remove_file(e.path()).is_ok() {
                swept += 1;
            }
        }
        if collected + swept > 0 {
            let _ = sync_dir(&self.blobs());
            let _ = sync_dir(&self.staging());
        }
        Ok(json!({"collected": collected, "kept_young": kept_young, "swept": swept}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> (Store, PathBuf) {
        let root = std::env::temp_dir().join(format!(
            "super-bodies-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_nanos()
        ));
        (Store::new(root.clone()), root)
    }
    fn put(s: &Store, owner: &str, text: &str) -> String {
        s.put(owner, text, false, Stop::Never).unwrap()["sha256"].as_str().unwrap().to_string()
    }
    fn later() -> SystemTime {
        SystemTime::now() + GRACE + Duration::from_secs(1)
    }
    const A: &str = "conv:super-conversations-v1:bot:x:1111";
    const B: &str = "conv:super-conversations-v1:bot:x:2222";

    #[test]
    fn exact_bytes_round_trip_including_crlf_unicode_and_empty() {
        let (s, root) = store();
        for text in ["", "before\r\nafter\n", "é✓ 𝄞 — \u{feff}BOM", &"x".repeat(BODY_BYTES)] {
            let d = put(&s, A, text);
            assert_eq!(d, digest(text.as_bytes()));
            let got = s.get(&d).unwrap();
            assert_eq!(got["state"], "available");
            assert_eq!(got["text"].as_str().unwrap().as_bytes(), text.as_bytes());
        }
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn bounds_and_names_are_refused_before_anything_is_written() {
        let (s, root) = store();
        assert!(s.put(A, &"x".repeat(BODY_BYTES + 1), false, Stop::Never).is_err());
        assert!(s.put("../etc", "x", false, Stop::Never).is_err());
        assert!(s.put("conv:a/b", "x", false, Stop::Never).is_err());
        assert!(s.put(A, "x", true, Stop::Never).is_err(), "only a migration may store an original");
        assert!(s.put("migration:super-conversations-v1", &"y".repeat(BODY_BYTES + 1), true, Stop::Never).is_ok());
        assert!(s.get("../owners.json").is_err());
        assert!(s.get(&"A".repeat(64)).is_err(), "upper-case is not a digest here");
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn missing_and_corrupt_are_told_apart_and_never_answered_with_other_bytes() {
        let (s, root) = store();
        let d = put(&s, A, "hello");
        assert_eq!(s.get(&digest(b"other")).unwrap()["state"], "missing");
        fs::write(s.blobs().join(&d), "hellp").unwrap();
        let got = s.get(&d).unwrap();
        assert_eq!(got["state"], "corrupt");
        assert!(got.get("text").is_none());
        // A second put of the same text REPAIRS a corrupt blob rather than trusting it.
        put(&s, A, "hello");
        assert_eq!(s.get(&d).unwrap()["state"], "available");
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn a_put_stopped_after_staging_leaves_no_blob_and_no_owner() {
        let (s, root) = store();
        assert!(s.put(A, "draft body", false, Stop::AfterStaged).is_err());
        let d = digest(b"draft body");
        assert_eq!(s.get(&d).unwrap()["state"], "missing");
        assert!(s.owners().unwrap().get(A).is_none());
        assert_eq!(s.report().unwrap()["partials"], 1);
        // Young partials survive a collection; stale ones are swept.
        assert_eq!(s.collect(SystemTime::now()).unwrap()["swept"], 0);
        assert_eq!(s.collect(later()).unwrap()["swept"], 1);
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn a_put_stopped_after_rename_leaves_an_unowned_blob_that_only_ages_out() {
        let (s, root) = store();
        assert!(s.put(A, "orphan", false, Stop::AfterRenamed).is_err());
        let d = digest(b"orphan");
        assert_eq!(s.get(&d).unwrap()["state"], "available");
        assert!(s.owners().unwrap().get(A).is_none(), "the page was never told it was stored");
        assert_eq!(s.collect(SystemTime::now()).unwrap()["kept_young"], 1);
        assert_eq!(s.collect(later()).unwrap()["collected"], 1);
        assert_eq!(s.get(&d).unwrap()["state"], "missing");
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn an_owned_body_is_never_collected_however_old() {
        let (s, root) = store();
        let d = put(&s, A, "needed by a saved proposal");
        let far = SystemTime::now() + Duration::from_secs(10 * 365 * 24 * 3600);
        assert_eq!(s.collect(far).unwrap()["collected"], 0);
        assert_eq!(s.get(&d).unwrap()["state"], "available");
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn releasing_one_conversation_keeps_a_body_another_still_owns() {
        let (s, root) = store();
        let shared = put(&s, A, "shared attachment");
        put(&s, B, "shared attachment");
        let only_a = put(&s, A, "only in A");
        assert_eq!(s.release(A).unwrap()["released"], 2);
        let r = s.collect(later()).unwrap();
        assert_eq!(r["collected"], 1);
        assert_eq!(s.get(&shared).unwrap()["state"], "available");
        assert_eq!(s.get(&only_a).unwrap()["state"], "missing");
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn an_unreadable_manifest_refuses_puts_and_collection_instead_of_reading_as_empty() {
        let (s, root) = store();
        let d = put(&s, A, "kept");
        fs::write(s.manifest_path(), "{not json").unwrap();
        assert!(s.put(A, "new", false, Stop::Never).is_err());
        assert!(s.collect(later()).is_err());
        assert_eq!(s.get(&d).unwrap()["state"], "available", "reads do not depend on the manifest");
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn a_leftover_manifest_temporary_is_ignored() {
        let (s, root) = store();
        let d = put(&s, A, "kept");
        fs::write(s.root.join("owners.json.tmp"), "{\"half\":").unwrap();
        assert!(s.owners().unwrap()[A].contains(&d));
        assert_eq!(s.collect(later()).unwrap()["collected"], 0);
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn the_request_surface_names_its_operations() {
        let (s, root) = store();
        let r = s.request(&json!({"operation": "put", "owner": A, "text": "via request"})).unwrap();
        assert_eq!(r["state"], "stored");
        let got = s.request(&json!({"operation": "get", "sha256": r["sha256"]})).unwrap();
        assert_eq!(got["text"], "via request");
        assert!(s.request(&json!({"operation": "delete"})).is_err());
        fs::remove_dir_all(root).ok();
    }
}
