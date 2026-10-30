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
//!
//! **T70 · the conversation history lives here too, apart.** Every bot's saved conversations (once WebKit
//! localStorage values, which a full 5 MB quota stopped saving on 2026-10-11) are files under
//! `conversation-history/<hex of the history key>/`: `c-<sha256>.json` per conversation (its id is inside it) and
//! `index.json` per history, naming the files it is made of. A publication (`history_publish`) checks that every
//! named file is there and that both bounds hold (`HISTORY_BYTES` for one history, counting everything its folder
//! holds during the publication; `HISTORIES_BYTES` for all; any listing or measuring error refusing), writes the new
//! files, each atomically (exclusive temporary file, fsync, rename, fsync the folder), and only then replaces the index
//! the same way. A publication that grows a history keeps room for one more index, so a deletion always fits. A move
//! from browser storage is staged (`migrating.json`, never loaded as the history) and promoted only after the page has
//! compared it. Every write syncs the parent folders again, so a sync that failed is never skipped by a retry; a
//! missing app folder is made with each new folder's parent owed a sync until one succeeds; a published history is
//! answered by a load only once its folder chain is synced, so a promotion whose sync failed is never taken for
//! durable. Every file operation goes through a folder opened without following a link. At start, temporaries and
//! files no index names are swept. The content-addressed bodies above are unchanged.
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
    // T70 · the history beside it: temporaries and files no index names are swept before anything is answered.
    let history = History::new(app_data.join("conversation-history"), HISTORY_BYTES, HISTORIES_BYTES);
    history.sweep();
    let _ = HISTORY.set(history);
}

/// The body store's operations, and (T70) the history's `history_*` ones, on one command.
pub fn request(r: Value) -> Result<Value, String> {
    if routed_to_history(&r) {
        return HISTORY.get().ok_or("Conversation history storage is unavailable.")?.request(&r);
    }
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

// ----------------------------------------------------------------------------------------------------------------
// T70 · the conversation history, in a folder of its own beside the bodies. Every file operation is anchored to a
// folder opened without following a link (`openat` with `O_NOFOLLOW`), so neither a planted link nor a folder
// replaced by one between a check and its use leads a read, a write or a removal outside the history.
use std::ffi::{CStr, CString};
use std::io;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::io::{AsRawFd, FromRawFd};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

/// The declared bound of one history's files on disk (the page checks the same number before it asks).
pub const HISTORY_BYTES: u64 = 256 * 1024 * 1024;
/// The declared bound of every history together: `TASK.md`'s outer bound, 512 MiB.
pub const HISTORIES_BYTES: u64 = 512 * 1024 * 1024;
const HISTORY_PREFIX: &str = "super-conversations-v1";
const INDEX_FILE: &str = "index.json";
const MIGRATING_FILE: &str = "migrating.json";
const INDEX_SCHEMA: &str = "conversation-history-index@1";
const BUSY: &str = "Conversation history storage is busy.";
const UNDURABLE: &str = "Could not make the saved conversations durable.";
const UNLISTED: &str = "Saved conversations cannot be listed or measured on this device; nothing was changed.";
const NOT_PLAIN: &str = "A saved conversation folder holds a link or another entry that is not a plain file; nothing was changed.";
const NOT_FOLDER: &str = "A conversation history folder is a link or cannot be opened; nothing was changed.";

static HISTORY: OnceLock<History> = OnceLock::new();
static TEMPORARY: AtomicU64 = AtomicU64::new(0);

/// The history's operations share the bodies' command; this says which store a request is for.
fn routed_to_history(r: &Value) -> bool {
    r["operation"].as_str().map_or(false, |o| o.starts_with("history_"))
}

pub struct History {
    root: PathBuf,
    limit: u64,
    total: u64,
    lock: Mutex<()>,
    /// Folders owed a sync because a folder was made inside them; each stays owed until a sync of it succeeds.
    owed: Mutex<BTreeSet<PathBuf>>,
    /// T84: whether this instance has owed every folder above the app folder on its device once (a new instance
    /// cannot know what a stopped one left unsynced).
    chained: AtomicBool,
    hooks: Hooks,
}

/// A step the tests can fail or observe.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Point {
    SyncAncestor,
    SyncApp,
    SyncRoot,
    SyncHistory,
    ListRoot,
    ListHistory,
    RootEntry,
    HistoryEntry,
    RootMeta,
    HistoryMeta,
    WriteFile,
    SyncFile,
    RenameFile,
    Indexed,
    Prune,
}

/// Test seams: `fail` fails a step once after letting the given number of its hits pass, `seen` records completed
/// syncs and publications (tests only), `race` runs once between a publication's checks and its writes. Production
/// never sets them.
#[derive(Default)]
#[cfg_attr(not(test), allow(dead_code))]
struct Hooks {
    fail: Mutex<Vec<(Point, u32)>>,
    seen: Mutex<Vec<Point>>,
    race: Mutex<Option<Box<dyn FnOnce() + Send>>>,
    /// T84: `fail_dir` fails the next sync of a named ancestor folder once per entry, `synced` records the ancestor
    /// folders synced, in order (tests only), and `sizes` reports a size for a named entry in place of its own
    /// (tests only), so sums no test folder could hold run through the production measurement.
    fail_dir: Mutex<Vec<PathBuf>>,
    synced: Mutex<Vec<PathBuf>>,
    sizes: Mutex<BTreeMap<Vec<u8>, libc::off_t>>,
}

/// Where a publication may be stopped in the tests, to leave exactly what a crash there would leave.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Cut {
    Never,
    AfterFiles,
}

/// An index: the files a history is made of, in the page's order, and the page's own record of them (`meta`).
struct Index {
    generation: u64,
    files: Vec<String>,
    meta: String,
}

fn hex(s: &str) -> String {
    s.bytes().map(|b| format!("{b:02x}")).collect()
}

/// `super-conversations-v1` or `super-conversations-v1:bot:<id>`, bounded, without control characters. Its folder
/// is its hex, so no key becomes a path whatever it holds.
fn history_ok(k: &str) -> bool {
    let shaped = k == HISTORY_PREFIX
        || k.strip_prefix(HISTORY_PREFIX).and_then(|r| r.strip_prefix(":bot:")).map_or(false, |id| !id.is_empty());
    shaped && k.len() <= 120 && !k.chars().any(char::is_control)
}

fn dir_name(key: &str) -> Result<String, String> {
    if !history_ok(key) {
        return Err("Invalid conversation history name.".into());
    }
    Ok(hex(key))
}

/// A conversation's file is named by the SHA-256 of its bytes and holds its id: every id the page accepts (empty,
/// control characters, any Unicode) has a bounded, collision-safe name.
fn conv_file(d: &str) -> String {
    format!("c-{d}.json")
}

fn over(bound: u64, which: &str, needs: u64) -> String {
    format!(
        "Saved conversations would exceed the declared bound of {bound} bytes for {which} on this device (this save needs {needs} bytes); nothing was changed. Delete an older saved conversation to make room."
    )
}

const UNMEASURED: &str = "Saved conversations on this device are too large to measure; nothing was changed.";

fn unmeasured() -> String {
    UNMEASURED.to_string()
}

/// A sum of sizes, or a refusal: a size that cannot be added never wraps and never panics.
fn sum(a: u64, b: u64) -> Result<u64, String> {
    a.checked_add(b).ok_or_else(unmeasured)
}

/// An entry's size as measured, or a refusal when it is not a size.
fn file_size(st: &libc::stat) -> Result<u64, String> {
    u64::try_from(st.st_size).map_err(|_| unmeasured())
}

fn parse_index(raw: &[u8]) -> Result<Index, String> {
    let bad = || "The saved conversation index is malformed; nothing was changed.".to_string();
    let v: Value = serde_json::from_slice(raw).map_err(|_| bad())?;
    if v["schema"] != INDEX_SCHEMA {
        return Err(bad());
    }
    let files = v["files"]
        .as_array()
        .ok_or_else(bad)?
        .iter()
        .map(|d| d.as_str().filter(|d| named(d)).map(str::to_string))
        .collect::<Option<Vec<String>>>()
        .ok_or_else(bad)?;
    let meta = v["meta"].as_str().ok_or_else(bad)?.to_string();
    Ok(Index { generation: v["generation"].as_u64().ok_or_else(bad)?, files, meta })
}

fn cs(name: &str) -> CString {
    CString::new(name).unwrap_or_default()
}

/// `openat` relative to an open folder, never following a link in the last component (`workbench.rs`'s way).
fn open_at(d: &fs::File, name: &CStr, flags: libc::c_int, mode: libc::c_uint) -> io::Result<fs::File> {
    let fd = unsafe { libc::openat(d.as_raw_fd(), name.as_ptr(), flags | libc::O_CLOEXEC | libc::O_NOFOLLOW, mode) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { fs::File::from_raw_fd(fd) })
}

/// A file's bytes, opened without following a link; None when absent. A link, or anything not a plain file, refuses.
fn read_at(d: &fs::File, name: &str) -> Result<Option<Vec<u8>>, String> {
    let refused = || format!("{name} cannot be read on this device as a plain file; nothing was changed.");
    let mut f = match open_at(d, &cs(name), libc::O_RDONLY | libc::O_NONBLOCK, 0) {
        Ok(f) => f,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(refused()),
    };
    let mut bytes = Vec::new();
    if !f.metadata().map_or(false, |m| m.is_file()) || f.read_to_end(&mut bytes).is_err() {
        return Err(refused());
    }
    Ok(Some(bytes))
}

fn read_index(d: &fs::File, name: &str) -> Result<Option<Index>, String> {
    read_at(d, name)?.map(|raw| parse_index(&raw)).transpose()
}

/// A named file's text, re-hashed: never other bytes than the ones the index was published with.
fn read_conversation(h: &fs::File, d: &str) -> Result<String, String> {
    let bytes = read_at(h, &conv_file(d))?
        .ok_or("A saved conversation named in the index is missing on this device; nothing was changed.")?;
    if digest(&bytes) != d {
        return Err("A saved conversation on this device is corrupt (its bytes do not match its name); nothing was changed.".into());
    }
    String::from_utf8(bytes).map_err(|_| "A saved conversation on this device is not text; nothing was changed.".to_string())
}

fn rename_at(d: &fs::File, from: &str, to: &str) -> Result<(), String> {
    let (a, b) = (cs(from), cs(to));
    if unsafe { libc::renameat(d.as_raw_fd(), a.as_ptr(), d.as_raw_fd(), b.as_ptr()) } != 0 {
        return Err("Could not record the saved conversations.".into());
    }
    Ok(())
}

#[cfg(any(target_os = "linux", target_os = "android"))]
unsafe fn clear_errno() {
    *libc::__errno_location() = 0;
}
#[cfg(any(target_os = "macos", target_os = "ios"))]
unsafe fn clear_errno() {
    *libc::__error() = 0;
}

impl History {
    pub fn new(root: PathBuf, limit: u64, total: u64) -> Self {
        History {
            root,
            limit,
            total,
            lock: Mutex::new(()),
            owed: Mutex::new(BTreeSet::new()),
            chained: AtomicBool::new(false),
            hooks: Hooks::default(),
        }
    }

    fn guard(&self) -> Result<std::sync::MutexGuard<'_, ()>, String> {
        self.lock.lock().map_err(|_| BUSY.to_string())
    }

    fn hit(&self, p: Point) -> Result<(), String> {
        let mut fail = self.hooks.fail.lock().map_err(|_| BUSY.to_string())?;
        if let Some(i) = fail.iter().position(|(x, _)| *x == p) {
            if fail[i].1 == 0 {
                fail.remove(i);
                return Err(format!("injected failure at {p:?} (test)"));
            }
            fail[i].1 -= 1;
        }
        Ok(())
    }

    #[cfg(test)]
    fn note(&self, p: Point) {
        if let Ok(mut seen) = self.hooks.seen.lock() {
            seen.push(p);
        }
    }
    #[cfg(not(test))]
    fn note(&self, _: Point) {}

    fn race(&self) {
        let run = self.hooks.race.lock().ok().and_then(|mut r| r.take());
        if let Some(run) = run {
            run();
        }
    }

    /// Like `hit`, for one ancestor folder: its sync fails once for each time a test named it.
    fn hit_dir(&self, p: &Path) -> Result<(), String> {
        let mut fail = self.hooks.fail_dir.lock().map_err(|_| BUSY.to_string())?;
        if let Some(i) = fail.iter().position(|x| x.as_path() == p) {
            fail.remove(i);
            return Err(format!("injected failure at {} (test)", p.display()));
        }
        Ok(())
    }

    #[cfg(test)]
    fn note_dir(&self, p: &Path) {
        if let Ok(mut synced) = self.hooks.synced.lock() {
            synced.push(p.to_path_buf());
        }
    }
    #[cfg(not(test))]
    fn note_dir(&self, _: &Path) {}

    /// Tests only: a size reported for a named entry in place of its own.
    #[cfg(test)]
    fn sized(&self, name: &CStr, st: &mut libc::stat) {
        if let Some(size) = self.hooks.sizes.lock().ok().and_then(|s| s.get(name.to_bytes()).copied()) {
            st.st_size = size;
        }
    }
    #[cfg(not(test))]
    fn sized(&self, _: &CStr, _: &mut libc::stat) {}

    fn sync(&self, p: Point, d: &fs::File) -> Result<(), String> {
        self.hit(p)?;
        d.sync_all().map_err(|_| UNDURABLE.to_string())?;
        self.note(p);
        Ok(())
    }

    /// A folder's entries, read through its open descriptor. Any error refuses: a short list would under-count.
    fn names(&self, d: &fs::File, p: Point) -> Result<Vec<CString>, String> {
        self.hit(p)?;
        let entry = if p == Point::ListRoot { Point::RootEntry } else { Point::HistoryEntry };
        let fd = unsafe { libc::dup(d.as_raw_fd()) };
        if fd < 0 {
            return Err(UNLISTED.into());
        }
        let dir = unsafe { libc::fdopendir(fd) };
        if dir.is_null() {
            unsafe { libc::close(fd) };
            return Err(UNLISTED.into());
        }
        unsafe { libc::rewinddir(dir) };
        let mut out = Vec::new();
        let listed = loop {
            unsafe { clear_errno() };
            let e = unsafe { libc::readdir(dir) };
            if e.is_null() {
                break if io::Error::last_os_error().raw_os_error() == Some(0) { Ok(out) } else { Err(UNLISTED.to_string()) };
            }
            if let Err(x) = self.hit(entry) {
                break Err(x);
            }
            let name = unsafe { CStr::from_ptr((*e).d_name.as_ptr()) };
            if name.to_bytes() != b"." && name.to_bytes() != b".." {
                out.push(name.to_owned());
            }
        };
        unsafe { libc::closedir(dir) };
        listed
    }

    /// An entry's metadata, never through a link.
    fn stat_at(&self, d: &fs::File, name: &CStr, p: Point) -> Result<libc::stat, String> {
        self.hit(p)?;
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe { libc::fstatat(d.as_raw_fd(), name.as_ptr(), &mut st, libc::AT_SYMLINK_NOFOLLOW) } != 0 {
            return Err(UNLISTED.into());
        }
        self.sized(name, &mut st);
        Ok(st)
    }

    /// Every byte in one history folder, its index's size and its staged index's size; a link or any entry not a
    /// plain file refuses, and so does a size that cannot be added.
    fn bytes_in(&self, h: &fs::File) -> Result<(u64, u64, u64), String> {
        let (mut n, mut ix, mut staged) = (0u64, 0u64, 0u64);
        for name in self.names(h, Point::ListHistory)? {
            let st = self.stat_at(h, &name, Point::HistoryMeta)?;
            if st.st_mode & libc::S_IFMT != libc::S_IFREG {
                return Err(NOT_PLAIN.into());
            }
            let size = file_size(&st)?;
            n = sum(n, size)?;
            if name.as_bytes() == INDEX_FILE.as_bytes() {
                ix = size;
            } else if name.as_bytes() == MIGRATING_FILE.as_bytes() {
                staged = size;
            }
        }
        Ok((n, ix, staged))
    }

    /// Every byte under the history root (indexes, conversations, temporaries and orphans alike), and the largest
    /// index or staged index (`migrating.json`, which a promotion makes an index without writing anything).
    fn all_bytes(&self, root: &fs::File) -> Result<(u64, u64), String> {
        let (mut n, mut ix) = (0u64, 0u64);
        for name in self.names(root, Point::ListRoot)? {
            let st = self.stat_at(root, &name, Point::RootMeta)?;
            match st.st_mode & libc::S_IFMT {
                libc::S_IFDIR => {
                    let h = open_at(root, &name, libc::O_RDONLY | libc::O_DIRECTORY, 0).map_err(|_| UNLISTED.to_string())?;
                    let (b, i, m) = self.bytes_in(&h)?;
                    n = sum(n, b)?;
                    ix = ix.max(i).max(m);
                }
                libc::S_IFREG => n = sum(n, file_size(&st)?)?,
                _ => return Err(NOT_PLAIN.into()),
            }
        }
        Ok((n, ix))
    }

    /// The trusted anchor of an app folder: the deepest of the OS's own folders above it, the home folder (`HOME`),
    /// the temporary folder or else the file system's root. Only the anchor is reached by its path, so the OS's
    /// aliases at or above it (`/var` -> `/private/var`, `/tmp` -> `/private/tmp`, a linked `/home`) stand; nothing
    /// below it is reached by path. None for a relative folder.
    fn anchor(app: &Path) -> Option<PathBuf> {
        [std::env::var_os("HOME").map(PathBuf::from), Some(std::env::temp_dir()), Some(PathBuf::from("/"))]
            .into_iter()
            .flatten()
            .filter(|a| a.is_absolute() && app.starts_with(a))
            .max_by_key(|a| a.components().count())
    }

    /// The app folder reached from its trusted anchor (`anchor`), by every open, whether it makes folders or not. The
    /// anchor is opened by its path; every folder below it is then reached from the one before it: an existing one
    /// must be a folder and not a link (`fstatat` without following, then `openat` with `O_NOFOLLOW`, any error
    /// refusing, whatever error a platform gives a link). A missing one is made inside the one before it (`mkdirat`)
    /// when `made` is given, the folder it is made in recorded there as owing a sync; otherwise a missing one answers
    /// None. So a link anywhere below the anchor refuses, and nothing is made, opened, read or removed through it.
    fn walk(app: &Path, mut made: Option<&mut BTreeSet<PathBuf>>) -> Result<Option<fs::File>, String> {
        use std::os::unix::ffi::OsStrExt;
        use std::path::Component;
        let cannot = || "Cannot create conversation history storage.".to_string();
        let anchor = Self::anchor(app).ok_or_else(cannot)?;
        let below = app.strip_prefix(&anchor).map_err(|_| cannot())?;
        let mut d = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY)
            .open(&anchor)
            .map_err(|_| NOT_FOLDER.to_string())?;
        let mut at = anchor.clone();
        for part in below.components() {
            let Component::Normal(n) = part else { return Err(NOT_FOLDER.into()) };
            let c = CString::new(n.as_bytes()).map_err(|_| cannot())?;
            let mut st: libc::stat = unsafe { std::mem::zeroed() };
            if unsafe { libc::fstatat(d.as_raw_fd(), c.as_ptr(), &mut st, libc::AT_SYMLINK_NOFOLLOW) } == 0 {
                if st.st_mode & libc::S_IFMT != libc::S_IFDIR {
                    return Err(NOT_FOLDER.into());
                }
            } else if io::Error::last_os_error().kind() == io::ErrorKind::NotFound {
                let Some(owed) = made.as_deref_mut() else { return Ok(None) };
                owed.insert(at.clone());
                if unsafe { libc::mkdirat(d.as_raw_fd(), c.as_ptr(), 0o777) } != 0
                    && io::Error::last_os_error().kind() != io::ErrorKind::AlreadyExists
                {
                    return Err(cannot());
                }
            } else {
                return Err(NOT_FOLDER.into());
            }
            d = open_at(&d, &c, libc::O_RDONLY | libc::O_DIRECTORY, 0).map_err(|_| NOT_FOLDER.to_string())?;
            at.push(n);
        }
        Ok(Some(d))
    }

    /// The app folder, made if missing, and held open, reached by `walk` with each missing folder made. Each folder
    /// made owes its parent a sync, and the app folder's own parent is owed one every time; a new instance also owes
    /// every folder above the app folder on the app folder's device once, so what a stopped process left unsynced is
    /// synced again. A debt stays until a sync of it succeeds, so neither a retry, a later publication nor a restart
    /// skips it.
    fn ensure_app(&self, app: &Path) -> Result<fs::File, String> {
        use std::os::unix::fs::MetadataExt;
        let mut owed = self.owed.lock().map_err(|_| BUSY.to_string())?;
        let d = Self::walk(app, Some(&mut *owed))?
            .ok_or_else(|| "Cannot create conversation history storage.".to_string())?;
        if !self.chained.load(Ordering::Relaxed) {
            let dev = d.metadata().map_err(|_| UNDURABLE.to_string())?.dev();
            for p in app.ancestors().skip(1).filter(|p| !p.as_os_str().is_empty()) {
                if fs::metadata(p).map_err(|_| UNDURABLE.to_string())?.dev() != dev {
                    break;
                }
                owed.insert(p.to_path_buf());
            }
            self.chained.store(true, Ordering::Relaxed);
        }
        if let Some(p) = app.parent() {
            owed.insert(p.to_path_buf());
        }
        for p in owed.clone() {
            self.hit(Point::SyncAncestor)?;
            self.hit_dir(&p)?;
            fs::File::open(&p).and_then(|f| f.sync_all()).map_err(|_| UNDURABLE.to_string())?;
            owed.remove(&p);
            self.note(Point::SyncAncestor);
            self.note_dir(&p);
        }
        Ok(d)
    }

    /// A folder inside `parent`, never through a link. When `create`, it is made if missing and `parent` is synced
    /// whether or not it was just made: a sync that failed before is never skipped by a retry.
    fn sub(&self, parent: &fs::File, name: &str, create: bool, p: Point) -> Result<Option<fs::File>, String> {
        let c = cs(name);
        if create
            && unsafe { libc::mkdirat(parent.as_raw_fd(), c.as_ptr(), 0o700) } != 0
            && io::Error::last_os_error().kind() != io::ErrorKind::AlreadyExists
        {
            return Err("Cannot create conversation history storage.".into());
        }
        let d = match open_at(parent, &c, libc::O_RDONLY | libc::O_DIRECTORY, 0) {
            Ok(d) => d,
            Err(e) if !create && e.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(NOT_FOLDER.into()),
        };
        if create {
            self.sync(p, parent)?;
        }
        Ok(Some(d))
    }

    /// The history root, opened from the app folder without following a link.
    fn open_root(&self, create: bool) -> Result<Option<fs::File>, String> {
        let (parent, name) = match (self.root.parent(), self.root.file_name().and_then(|n| n.to_str())) {
            (Some(p), Some(n)) => (p, n),
            _ => return Err("Conversation history storage has no folder.".into()),
        };
        let app = if create {
            self.ensure_app(parent)?
        } else {
            match Self::walk(parent, None)? {
                Some(f) => f,
                None => return Ok(None),
            }
        };
        self.sub(&app, name, create, Point::SyncApp)
    }

    /// The root and one history's folder, both held open: every later step uses these, never the path again.
    fn open(&self, key: &str, create: bool) -> Result<Option<(fs::File, fs::File)>, String> {
        let name = dir_name(key)?;
        let Some(root) = self.open_root(create)? else { return Ok(None) };
        Ok(self.sub(&root, &name, create, Point::SyncRoot)?.map(|h| (root, h)))
    }

    fn write_atomic(&self, h: &fs::File, name: &str, bytes: &[u8]) -> Result<(), String> {
        let tmp = format!("{name}.{}.{}.tmp", std::process::id(), TEMPORARY.fetch_add(1, Ordering::Relaxed));
        let failed = || "Could not write the saved conversations.".to_string();
        let written = self
            .hit(Point::WriteFile)
            .and_then(|_| {
                let mut f = open_at(h, &cs(&tmp), libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL, 0o600).map_err(|_| failed())?;
                f.write_all(bytes).map_err(|_| failed())?;
                self.hit(Point::SyncFile)?;
                f.sync_all().map_err(|_| failed())
            })
            .and_then(|_| self.hit(Point::RenameFile))
            .and_then(|_| rename_at(h, &tmp, name));
        if written.is_err() {
            unsafe { libc::unlinkat(h.as_raw_fd(), cs(&tmp).as_ptr(), 0) };
        }
        written?;
        self.sync(Point::SyncHistory, h)
    }

    fn holds(&self, h: &fs::File, d: &str) -> Result<bool, String> {
        Ok(read_at(h, &conv_file(d))?.map_or(false, |b| digest(&b) == d))
    }

    fn request(&self, r: &Value) -> Result<Value, String> {
        let key = r["history"].as_str().unwrap_or("");
        match r["operation"].as_str() {
            Some("history_load") => self.load(key),
            Some("history_publish") => self.publish(key, r, r["stage"] == true, Cut::Never),
            Some("history_promote") => self.promote(key),
            Some("history_abandon") => self.abandon(key),
            _ => Err("Unknown conversation history operation.".into()),
        }
    }

    fn view(&self, h: &fs::File, ix: &Index) -> Result<Value, String> {
        let texts = ix.files.iter().map(|d| read_conversation(h, d)).collect::<Result<Vec<String>, String>>()?;
        Ok(json!({"generation": ix.generation, "meta": ix.meta, "files": ix.files, "texts": texts}))
    }

    /// The published history (or null) and, only while none is published, a staged one (or null). A published
    /// history is answered only once its folder and every folder above it are synced: its index may be the rename of
    /// a promotion or publication whose sync failed, and the page drops its browser source on this answer.
    fn load(&self, key: &str) -> Result<Value, String> {
        let _guard = self.guard()?;
        let Some((_, h)) = self.open(key, false)? else { return Ok(json!({"published": null, "migrating": null})) };
        let published = match read_index(&h, INDEX_FILE)? {
            Some(ix) => {
                let view = self.view(&h, &ix)?;
                self.open(key, true)?;
                self.sync(Point::SyncHistory, &h)?;
                view
            }
            None => Value::Null,
        };
        let migrating = match (published.is_null(), read_index(&h, MIGRATING_FILE)) {
            (true, Ok(Some(ix))) => self.view(&h, &ix).unwrap_or(Value::Null),
            _ => Value::Null,
        };
        Ok(json!({"published": published, "migrating": migrating}))
    }

    /// One publication: check, write the new files, then replace the index (or the staged index). Refused with
    /// nothing changed when a named file is absent, a bound would be exceeded or the storage cannot be measured.
    fn publish(&self, key: &str, r: &Value, stage: bool, cut: Cut) -> Result<Value, String> {
        let meta = r["meta"].as_str().ok_or("A history publication needs its index.")?;
        // Each file is new text (Some) or one already held, named by its digest (None).
        let mut wants: Vec<(String, Option<&str>)> = Vec::new();
        for w in r["files"].as_array().ok_or("A history publication names its files.")? {
            match (w["text"].as_str(), w["sha256"].as_str().filter(|d| named(d))) {
                (Some(t), _) => wants.push((digest(t.as_bytes()), Some(t))),
                (None, Some(d)) => wants.push((d.to_string(), None)),
                _ => return Err("A history publication names a file it neither writes nor holds; nothing was changed.".into()),
            }
        }
        let _guard = self.guard()?;
        let (root, h) = self.open(key, true)?.ok_or("Cannot create conversation history storage.")?;
        let old = read_at(&h, INDEX_FILE)?;
        let previous = old.map(|b| parse_index(&b)).transpose()?;
        if stage && previous.is_some() {
            return Err("This history is already kept in files; nothing was staged.".into());
        }
        let (mut after, mut added, mut fresh) = (0u64, 0u64, BTreeSet::new());
        for (d, text) in &wants {
            match text {
                Some(t) => {
                    after = sum(after, t.len() as u64)?;
                    if !self.holds(&h, d)? && fresh.insert(d.clone()) {
                        added = sum(added, t.len() as u64)?;
                    }
                }
                None => {
                    let held = read_at(&h, &conv_file(d))?
                        .filter(|b| digest(b) == *d)
                        .ok_or("A history publication names a saved conversation that was never written; nothing was changed.")?;
                    after = sum(after, held.len() as u64)?;
                }
            }
        }
        let generation = previous.map_or(0, |ix| ix.generation) + 1;
        let files: Vec<&String> = wants.iter().map(|(d, _)| d).collect();
        let index = serde_json::to_vec(&json!({"schema": INDEX_SCHEMA, "generation": generation, "files": files, "meta": meta}))
            .map_err(|_| "Could not encode the saved conversation index.")?;
        let ix = index.len() as u64;
        let after = sum(after, ix)?;
        if after > self.limit {
            return Err(over(self.limit, "one history", after));
        }
        // Three checks, separately, for one history and for all. The peak: what the folder holds during the
        // publication (everything already there, leftovers, orphans and the files being replaced included) and the new
        // files and index. What stays: the same once the replaced index is gone, with no prune credited (a prune that
        // fails after the index is replaced removes nothing), and room for one more index (of this history, and of the
        // largest index or staged index of all), so a later deletion, which only writes a smaller index, always fits.
        // What a failure leaves: a publication stopped after its new files, before its index is replaced, leaves them
        // beside the still-current history, which must still have room for its own deletion (its current index; of
        // all, the largest). Every sum is checked, all of them before any comparison: a size that cannot be added
        // refuses.
        let (held, index_len, staged_len) = self.bytes_in(&h)?;
        let replaced = if stage { staged_len } else { index_len };
        let peak = sum(sum(held, added)?, ix)?;
        let stays = sum(peak.checked_sub(replaced).ok_or_else(unmeasured)?, ix)?;
        let pending = sum(sum(held, added)?, replaced)?;
        for needs in [peak, stays, pending] {
            if needs > self.limit {
                return Err(over(self.limit, "one history", needs));
            }
        }
        let (all, largest) = self.all_bytes(&root)?;
        let all_peak = sum(sum(all, added)?, ix)?;
        let all_stays = sum(all_peak.checked_sub(replaced).ok_or_else(unmeasured)?, ix.max(largest))?;
        let all_pending = sum(sum(all, added)?, largest)?;
        for needs in [all_peak, all_stays, all_pending] {
            if needs > self.total {
                return Err(over(self.total, "all histories", needs));
            }
        }
        self.race();
        for (d, text) in &wants {
            if let Some(t) = text {
                if fresh.remove(d) {
                    self.write_atomic(&h, &conv_file(d), t.as_bytes())?;
                }
            }
        }
        if cut == Cut::AfterFiles {
            return Err("stopped after the conversation files (test)".into());
        }
        self.write_atomic(&h, if stage { MIGRATING_FILE } else { INDEX_FILE }, &index)?;
        self.note(Point::Indexed);
        let _ = self.prune(&h);
        let state = if stage { "staged" } else { "published" };
        Ok(json!({"state": state, "generation": generation, "files": files}))
    }

    /// A staged copy the page compared and found equal becomes the history, in one rename.
    fn promote(&self, key: &str) -> Result<Value, String> {
        let _guard = self.guard()?;
        let (_, h) = self.open(key, true)?.ok_or("There is no staged history to publish.")?;
        if read_index(&h, INDEX_FILE)?.is_some() {
            return Err("This history is already kept in files; the staged copy was not promoted.".into());
        }
        let staged = read_index(&h, MIGRATING_FILE)?.ok_or("There is no staged history to publish.")?;
        rename_at(&h, MIGRATING_FILE, INDEX_FILE)?;
        self.sync(Point::SyncHistory, &h)?;
        self.note(Point::Indexed);
        let _ = self.prune(&h);
        Ok(json!({"state": "published", "generation": staged.generation, "files": staged.files}))
    }

    /// A staged copy that did not compare equal is removed, with every file only it named.
    fn abandon(&self, key: &str) -> Result<Value, String> {
        let _guard = self.guard()?;
        if let Some((_, h)) = self.open(key, false)? {
            if unsafe { libc::unlinkat(h.as_raw_fd(), cs(MIGRATING_FILE).as_ptr(), 0) } == 0 {
                self.sync(Point::SyncHistory, &h)?;
            } else if io::Error::last_os_error().kind() != io::ErrorKind::NotFound {
                return Err("Could not remove the staged history.".into());
            }
            let _ = self.prune(&h);
        }
        Ok(json!({"state": "abandoned"}))
    }

    /// Remove temporaries, a staged index a published one replaced, and conversation files no index names. An
    /// unreadable index or listing refuses. A removed link is the link itself, never its target.
    fn prune(&self, h: &fs::File) -> Result<u64, String> {
        self.hit(Point::Prune)?;
        let published = read_index(h, INDEX_FILE)?;
        let migrating = if published.is_some() { None } else { read_index(h, MIGRATING_FILE)? };
        let keep: BTreeSet<String> =
            published.iter().chain(migrating.iter()).flat_map(|ix| ix.files.iter().map(|d| conv_file(d))).collect();
        let mut removed = 0u64;
        for name in self.names(h, Point::ListHistory)? {
            let n = name.to_string_lossy();
            let stale = n.ends_with(".tmp")
                || (&*n == MIGRATING_FILE && published.is_some())
                || (n.starts_with("c-") && n.ends_with(".json") && !keep.contains(&*n));
            if stale && unsafe { libc::unlinkat(h.as_raw_fd(), name.as_ptr(), 0) } == 0 {
                removed += 1;
            }
        }
        if removed > 0 {
            self.sync(Point::SyncHistory, h)?;
        }
        Ok(removed)
    }

    /// At start: prune every history folder that is a real folder. Returns how many files were removed.
    pub fn sweep(&self) -> u64 {
        let Ok(_guard) = self.guard() else { return 0 };
        let Ok(Some(root)) = self.open_root(false) else { return 0 };
        let Ok(names) = self.names(&root, Point::ListRoot) else { return 0 };
        names
            .iter()
            .filter_map(|n| open_at(&root, n, libc::O_RDONLY | libc::O_DIRECTORY, 0).ok())
            .map(|h| self.prune(&h).unwrap_or(0))
            .sum()
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

    // T70 · the history. Each test opens with the law it serves.
    use std::os::unix::fs::symlink;

    fn history(limit: u64, total: u64) -> (History, PathBuf) {
        let root = std::env::temp_dir()
            .join(format!(
                "super-history-{}-{}",
                std::process::id(),
                SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_nanos()
            ))
            .join("conversation-history");
        (History::new(root.clone(), limit, total), root)
    }
    fn reopen(root: &Path) -> History {
        History::new(root.to_path_buf(), HISTORY_BYTES, HISTORIES_BYTES)
    }
    fn gone(root: &Path) {
        fs::remove_dir_all(root.parent().unwrap()).ok();
    }
    fn hdir(root: &Path, key: &str) -> PathBuf {
        root.join(hex(key))
    }
    fn count(root: &Path, key: &str) -> usize {
        fs::read_dir(hdir(root, key)).unwrap().count()
    }
    fn op(h: &History, key: &str, mut r: Value) -> Result<Value, String> {
        r["history"] = json!(key);
        h.request(&r)
    }
    fn publish(h: &History, key: &str, files: Value) -> Result<Value, String> {
        op(h, key, json!({"operation": "history_publish", "meta": "m", "files": files}))
    }
    fn stage(h: &History, key: &str) -> Result<Value, String> {
        op(h, key, json!({"operation": "history_publish", "stage": true, "meta": "s", "files": [{"text": "one"}]}))
    }
    fn load(h: &History, key: &str) -> Value {
        op(h, key, json!({"operation": "history_load"})).unwrap()
    }
    fn texts(h: &History, key: &str) -> Value {
        load(h, key)["published"]["texts"].clone()
    }
    fn fail(h: &History, p: Point) {
        fail_nth(h, p, 0);
    }
    fn fail_nth(h: &History, p: Point, n: u32) {
        h.hooks.fail.lock().unwrap().push((p, n));
    }
    fn seen(h: &History) -> Vec<Point> {
        h.hooks.seen.lock().unwrap().clone()
    }
    fn synced_before_index(h: &History, p: Point) {
        let s = seen(h);
        let at = s.iter().position(|x| *x == Point::Indexed).expect("published");
        assert!(s[..at].contains(&p), "{p:?} was not synced before the index: {s:?}");
    }
    fn untouched(outside: &Path) {
        assert_eq!(fs::read_dir(outside).unwrap().count(), 3);
        assert_eq!(fs::read_to_string(outside.join(INDEX_FILE)).unwrap(), "outside index");
        assert_eq!(fs::read_to_string(outside.join("c-orphan.json")).unwrap(), "outside");
    }
    const K: &str = "super-conversations-v1:bot:b8225a5d";
    const K2: &str = "super-conversations-v1";

    #[test]
    fn l1_a_history_larger_than_the_webkit_quota_publishes_and_reads_back_byte_for_byte() {
        let (h, root) = history(HISTORY_BYTES, HISTORIES_BYTES);
        let big = "é✓ conversation text\r\n".repeat(300_000);
        assert!(big.len() > 6 * 1024 * 1024);
        assert_eq!(publish(&h, K, json!([{"text": &big}])).unwrap()["files"][0], digest(big.as_bytes()));
        assert_eq!(texts(&h, K)[0].as_str().unwrap().as_bytes(), big.as_bytes());
        gone(&root);
    }

    #[test]
    fn l2_a_staged_copy_survives_a_restart_and_is_the_history_only_once_promoted() {
        let (h, root) = history(HISTORY_BYTES, HISTORIES_BYTES);
        assert_eq!(stage(&h, K).unwrap()["state"], "staged");
        let h = reopen(&root);
        h.sweep();
        let got = load(&h, K);
        assert!(got["published"].is_null());
        assert_eq!(got["migrating"]["texts"][0], "one");
        op(&h, K, json!({"operation": "history_promote"})).unwrap();
        let got = load(&h, K);
        assert_eq!(got["published"]["meta"], "s");
        assert_eq!(got["published"]["texts"][0], "one");
        assert!(got["migrating"].is_null());
        assert!(stage(&h, K).is_err(), "a published history is never staged over");
        gone(&root);
    }

    #[test]
    fn l2_an_abandoned_copy_leaves_no_index_and_no_file() {
        let (h, root) = history(HISTORY_BYTES, HISTORIES_BYTES);
        stage(&h, K).unwrap();
        op(&h, K, json!({"operation": "history_abandon"})).unwrap();
        let got = load(&h, K);
        assert!(got["published"].is_null() && got["migrating"].is_null());
        assert_eq!(count(&root, K), 0);
        gone(&root);
    }

    #[test]
    fn l2_any_conversation_id_is_kept_inside_a_digest_named_file() {
        let (h, root) = history(HISTORY_BYTES, HISTORIES_BYTES);
        let ids = ["", "\u{0}\u{7}", "../../owners.json", "é✓𝄞 / .."];
        let texts_in: Vec<String> = ids.iter().map(|id| json!({"id": id}).to_string()).collect();
        publish(&h, K, Value::Array(texts_in.iter().map(|t| json!({"text": t})).collect())).unwrap();
        let mut names: Vec<String> =
            fs::read_dir(hdir(&root, K)).unwrap().flatten().map(|e| e.file_name().to_string_lossy().to_string()).collect();
        names.sort();
        let mut want: Vec<String> = texts_in.iter().map(|t| conv_file(&digest(t.as_bytes()))).collect();
        want.push(INDEX_FILE.to_string());
        want.sort();
        assert_eq!(names, want);
        assert_eq!(texts(&h, K), json!(texts_in));
        gone(&root);
    }

    #[test]
    fn l2_a_promotion_whose_folder_sync_failed_is_synced_before_a_reopen_answers_it() {
        let (h, root) = history(HISTORY_BYTES, HISTORIES_BYTES);
        stage(&h, K).unwrap();
        fail(&h, Point::SyncHistory);
        assert!(op(&h, K, json!({"operation": "history_promote"})).is_err());
        assert!(hdir(&root, K).join(INDEX_FILE).is_file(), "the rename is visible, its folder sync is not done");
        let h = reopen(&root);
        fail(&h, Point::SyncHistory);
        assert!(op(&h, K, json!({"operation": "history_load"})).is_err(), "an index not made durable is not answered");
        assert_eq!(texts(&h, K), json!(["one"]));
        let s = seen(&h);
        for p in [Point::SyncAncestor, Point::SyncApp, Point::SyncRoot, Point::SyncHistory] {
            assert!(s.contains(&p), "{p:?} was not synced before the reopened history was answered: {s:?}");
        }
        gone(&root);
    }

    #[test]
    fn l3_a_publication_stopped_after_its_files_keeps_the_previous_history_and_the_start_sweeps_the_orphans() {
        let (h, root) = history(HISTORY_BYTES, HISTORIES_BYTES);
        publish(&h, K, json!([{"text": "a1"}])).unwrap();
        let next = json!({"meta": "next", "files": [{"text": "a2"}, {"text": "b1"}]});
        assert!(h.publish(K, &next, false, Cut::AfterFiles).is_err());
        assert_eq!(texts(&h, K), json!(["a1"]));
        assert_eq!(load(&h, K)["published"]["meta"], "m");
        fs::write(hdir(&root, K).join("index.json.tmp"), "half an index").unwrap();
        assert_eq!(count(&root, K), 5);
        let h = reopen(&root);
        assert_eq!(h.sweep(), 3);
        assert_eq!(count(&root, K), 2);
        assert_eq!(texts(&h, K), json!(["a1"]));
        gone(&root);
    }

    #[test]
    fn l3_a_publication_failing_at_a_write_an_fsync_a_rename_or_a_folder_sync_is_old_or_new_whole_after_a_restart() {
        let cases = [
            (Point::WriteFile, 0, "a1"),
            (Point::WriteFile, 1, "a1"),
            (Point::SyncFile, 0, "a1"),
            (Point::SyncFile, 1, "a1"),
            (Point::RenameFile, 0, "a1"),
            (Point::RenameFile, 1, "a1"),
            (Point::SyncHistory, 0, "a1"),
            (Point::SyncHistory, 1, "a2"),
        ];
        for (p, n, want) in cases {
            let (h, root) = history(HISTORY_BYTES, HISTORIES_BYTES);
            publish(&h, K, json!([{"text": "a1"}])).unwrap();
            fail_nth(&h, p, n);
            let refused = publish(&h, K, json!([{"text": "a2"}])).unwrap_err();
            assert!(refused.contains(&format!("at {p:?} ")), "{p:?}/{n}: {refused}");
            let h = reopen(&root);
            h.sweep();
            assert_eq!(texts(&h, K), json!([want]), "{p:?}/{n}");
            assert_eq!(count(&root, K), 2, "{p:?}/{n}: every leftover was swept");
            assert!(seen(&h).contains(&Point::SyncHistory), "{p:?}/{n}: answered only once synced");
            gone(&root);
        }
    }

    #[test]
    fn l3_a_publication_naming_a_file_never_written_is_refused_and_changes_nothing() {
        let (h, root) = history(HISTORY_BYTES, HISTORIES_BYTES);
        publish(&h, K, json!([{"text": "a1"}])).unwrap();
        let refused = publish(&h, K, json!([{"sha256": digest(b"never written")}])).unwrap_err();
        assert!(refused.contains("never written"), "{refused}");
        assert!(publish(&h, K, json!([{"neither": 1}])).is_err());
        assert_eq!(texts(&h, K), json!(["a1"]));
        gone(&root);
    }

    #[test]
    fn l3_a_damaged_file_is_refused_on_load_and_never_read_as_other_bytes() {
        let (h, root) = history(HISTORY_BYTES, HISTORIES_BYTES);
        let r = publish(&h, K, json!([{"text": "kept"}])).unwrap();
        fs::write(hdir(&root, K).join(conv_file(r["files"][0].as_str().unwrap())), "kepT").unwrap();
        let refused = op(&h, K, json!({"operation": "history_load"})).unwrap_err();
        assert!(refused.contains("corrupt"), "{refused}");
        gone(&root);
    }

    #[test]
    fn l3_a_history_above_its_own_bound_or_all_histories_above_theirs_is_refused_by_name() {
        let (h, root) = history(550, 680);
        let a = publish(&h, K, json!([{"text": "a".repeat(100)}])).unwrap();
        let one = publish(&h, K, json!([{"sha256": a["files"][0]}, {"text": "b".repeat(300)}])).unwrap_err();
        assert!(one.contains("bound of 550 bytes for one history"), "{one}");
        let all = publish(&h, K2, json!([{"text": "c".repeat(200)}])).unwrap_err();
        assert!(all.contains("bound of 680 bytes for all histories"), "{all}");
        assert_eq!(texts(&h, K), json!(["a".repeat(100)]));
        assert!(load(&h, K2)["published"].is_null());
        gone(&root);
    }

    #[test]
    fn l3_one_history_counts_what_its_folder_holds_leftovers_and_replaced_files_included() {
        let (h, root) = history(600, HISTORIES_BYTES);
        let x = publish(&h, K, json!([{"text": "x".repeat(200)}])).unwrap();
        let replaced = publish(&h, K, json!([{"text": "y".repeat(150)}])).unwrap_err();
        assert!(replaced.contains("bound of 600 bytes for one history"), "{replaced}");
        fs::write(hdir(&root, K).join("c-orphan.json"), "o".repeat(300)).unwrap();
        let kept = json!([{"sha256": x["files"][0]}]);
        let left = publish(&h, K, kept.clone()).unwrap_err();
        assert!(left.contains("for one history"), "{left}");
        assert_eq!(texts(&h, K), json!(["x".repeat(200)]));
        let h = History::new(root.clone(), 600, HISTORIES_BYTES);
        assert_eq!(h.sweep(), 1);
        publish(&h, K, kept).unwrap();
        gone(&root);
    }

    #[test]
    fn l3_publications_keep_room_for_a_deletion_in_any_history() {
        let (h, root) = history(HISTORY_BYTES, 3_000);
        let meta = "m".repeat(300);
        let files = json!([{"text": "a".repeat(100)}, {"text": "b".repeat(100)}]);
        let k = op(&h, K, json!({"operation": "history_publish", "meta": meta, "files": files})).unwrap();
        let mut filled = 0;
        let refused = loop {
            match publish(&h, &format!("{K2}:bot:fill{filled}"), json!([{"text": format!("{filled:04}")}])) {
                Ok(_) => filled += 1,
                Err(e) => break e,
            }
        };
        assert!(refused.contains("for all histories"), "{refused}");
        assert!(filled > 0);
        let deletion = json!({"operation": "history_publish", "meta": meta, "files": [{"sha256": k["files"][0]}]});
        op(&h, K, deletion).unwrap();
        assert_eq!(texts(&h, K), json!(["a".repeat(100)]));
        gone(&root);
    }

    #[test]
    fn l3_temporaries_count_against_the_bound_until_the_start_sweeps_them() {
        let (h, root) = history(10_000, 1_000);
        publish(&h, K, json!([{"text": "a".repeat(100)}])).unwrap();
        fs::write(hdir(&root, K).join("c-left-over.json.tmp"), "x".repeat(600)).unwrap();
        let refused = publish(&h, K2, json!([{"text": "b".repeat(100)}])).unwrap_err();
        assert!(refused.contains("for all histories"), "{refused}");
        assert_eq!(h.sweep(), 1);
        publish(&h, K2, json!([{"text": "b".repeat(100)}])).unwrap();
        gone(&root);
    }

    #[test]
    fn l3_a_failed_parent_sync_is_never_skipped_by_the_retry_of_a_publication_or_a_migration() {
        for p in [Point::SyncApp, Point::SyncRoot] {
            let (h, root) = history(HISTORY_BYTES, HISTORIES_BYTES);
            fail(&h, p);
            assert!(publish(&h, K, json!([{"text": "one"}])).is_err(), "{p:?}");
            assert!(load(&h, K)["published"].is_null());
            h.hooks.seen.lock().unwrap().clear();
            publish(&h, K, json!([{"text": "one"}])).unwrap();
            synced_before_index(&h, p);
            stage(&h, K2).unwrap();
            fail(&h, p);
            assert!(op(&h, K2, json!({"operation": "history_promote"})).is_err(), "{p:?}");
            assert!(load(&h, K2)["published"].is_null());
            h.hooks.seen.lock().unwrap().clear();
            op(&h, K2, json!({"operation": "history_promote"})).unwrap();
            synced_before_index(&h, p);
            let h = reopen(&root);
            assert_eq!(texts(&h, K), json!(["one"]));
            assert_eq!(texts(&h, K2), json!(["one"]));
            gone(&root);
        }
    }

    #[test]
    fn l3_a_missing_app_folder_is_made_with_its_parents_synced_and_an_unsynced_one_stays_owed() {
        let base = std::env::temp_dir().join(format!(
            "super-app-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let root = base.join("app").join("conversation-history");
        let h = History::new(root.clone(), HISTORY_BYTES, HISTORIES_BYTES);
        fail(&h, Point::SyncAncestor);
        assert!(publish(&h, K, json!([{"text": "one"}])).is_err());
        assert!(base.join("app").is_dir() && !root.exists(), "nothing is made inside an unsynced folder");
        assert!(h.owed.lock().unwrap().contains(&base), "the made folder's parent still owes its sync");
        publish(&h, K, json!([{"text": "one"}])).unwrap();
        assert!(h.owed.lock().unwrap().is_empty());
        synced_before_index(&h, Point::SyncAncestor);
        assert_eq!(texts(&reopen(&root), K), json!(["one"]));
        fs::remove_dir_all(base).ok();
    }

    #[test]
    fn l3_storage_accounting_fails_closed_at_the_root_and_inside_a_history_and_the_committed_history_stays() {
        for p in [Point::ListRoot, Point::ListHistory, Point::RootEntry, Point::HistoryEntry, Point::RootMeta, Point::HistoryMeta] {
            let (h, root) = history(HISTORY_BYTES, HISTORIES_BYTES);
            publish(&h, K, json!([{"text": "a1"}])).unwrap();
            fail(&h, p);
            let refused = publish(&h, K, json!([{"text": "a2"}])).unwrap_err();
            assert!(refused.contains(&format!("at {p:?} ")), "{p:?}: {refused}");
            assert_eq!(texts(&h, K), json!(["a1"]), "{p:?}");
            let h = reopen(&root);
            h.sweep();
            assert_eq!(texts(&h, K), json!(["a1"]), "{p:?} after a restart");
            gone(&root);
        }
        let (h, root) = history(HISTORY_BYTES, HISTORIES_BYTES);
        publish(&h, K, json!([{"text": "a1"}])).unwrap();
        fs::create_dir(hdir(&root, K).join("not-a-file")).unwrap();
        assert!(publish(&h, K, json!([{"text": "a2"}])).is_err(), "an entry that is not a plain file refuses");
        assert_eq!(texts(&h, K), json!(["a1"]));
        gone(&root);
    }

    #[test]
    fn l3_linked_history_folders_and_files_are_refused_and_no_outside_target_is_read_written_or_pruned() {
        let (h, root) = history(HISTORY_BYTES, HISTORIES_BYTES);
        let outside = root.parent().unwrap().join("outside");
        fs::create_dir_all(&outside).unwrap();
        for (name, text) in [(INDEX_FILE, "outside index"), ("c-orphan.json", "outside"), ("x.tmp", "outside")] {
            fs::write(outside.join(name), text).unwrap();
        }
        let a = publish(&h, K2, json!([{"text": "a1"}])).unwrap();
        symlink(&outside, hdir(&root, K)).unwrap();
        assert!(op(&h, K, json!({"operation": "history_load"})).is_err());
        assert!(publish(&h, K, json!([{"text": "x"}])).is_err());
        assert!(publish(&h, K2, json!([{"text": "x"}])).is_err(), "a link among the histories refuses every publication");
        h.sweep();
        untouched(&outside);
        fs::remove_file(hdir(&root, K)).unwrap();
        let dir = hdir(&root, K2);
        let file = dir.join(conv_file(a["files"][0].as_str().unwrap()));
        fs::remove_file(&file).unwrap();
        symlink(outside.join("c-orphan.json"), &file).unwrap();
        assert!(op(&h, K2, json!({"operation": "history_load"})).is_err());
        assert!(publish(&h, K2, json!([{"sha256": a["files"][0]}])).is_err());
        fs::remove_file(dir.join(INDEX_FILE)).unwrap();
        symlink(outside.join(INDEX_FILE), dir.join(INDEX_FILE)).unwrap();
        assert!(op(&h, K2, json!({"operation": "history_load"})).is_err());
        assert!(publish(&h, K2, json!([{"text": "y"}])).is_err());
        h.sweep();
        untouched(&outside);
        gone(&root);
    }

    #[test]
    fn l3_a_planted_temporary_link_is_never_written_through_and_the_start_removes_only_the_link() {
        let (h, root) = history(HISTORY_BYTES, HISTORIES_BYTES);
        publish(&h, K, json!([{"text": "a1"}])).unwrap();
        let target = root.parent().unwrap().join("outside.txt");
        fs::write(&target, "outside").unwrap();
        let dir = hdir(&root, K);
        symlink(&target, dir.join("c-planted.json.tmp")).unwrap();
        let d = fs::File::open(&dir).unwrap();
        assert!(open_at(&d, &cs("c-planted.json.tmp"), libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL, 0o600).is_err());
        assert!(publish(&h, K, json!([{"text": "a2"}])).is_err(), "a link in a history folder refuses the publication");
        assert_eq!(fs::read_to_string(&target).unwrap(), "outside");
        assert_eq!(h.sweep(), 1);
        assert_eq!(fs::read_to_string(&target).unwrap(), "outside");
        publish(&h, K, json!([{"text": "a2"}])).unwrap();
        assert_eq!(texts(&h, K), json!(["a2"]));
        gone(&root);
    }

    #[test]
    fn l3_a_folder_replaced_by_a_link_between_check_and_use_never_leads_a_write_outside() {
        let (h, root) = history(HISTORY_BYTES, HISTORIES_BYTES);
        publish(&h, K, json!([{"text": "a1"}])).unwrap();
        let base = root.parent().unwrap().to_path_buf();
        let (outside, moved, path) = (base.join("outside"), base.join("moved"), hdir(&root, K));
        fs::create_dir(&outside).unwrap();
        let (p, m, o) = (path.clone(), moved.clone(), outside.clone());
        *h.hooks.race.lock().unwrap() = Some(Box::new(move || {
            fs::rename(&p, &m).unwrap();
            symlink(&o, &p).unwrap();
        }));
        publish(&h, K, json!([{"text": "a2"}])).unwrap();
        assert_eq!(fs::read_dir(&outside).unwrap().count(), 0, "nothing reached the link's target");
        assert!(moved.join(INDEX_FILE).is_file(), "the writes went to the folder that was checked");
        assert!(op(&h, K, json!({"operation": "history_load"})).is_err(), "the link is refused on the next read");
        gone(&root);
    }

    #[test]
    fn l3_history_names_never_become_paths() {
        let (h, root) = history(HISTORY_BYTES, HISTORIES_BYTES);
        for bad in ["../x", "other-key", "super-conversations-v1:bot:", "super-conversations-v1/../../x", "super-conversations-v1:bot:a\u{7}b", ""] {
            assert!(op(&h, bad, json!({"operation": "history_load"})).is_err(), "{bad:?}");
        }
        let odd = "super-conversations-v1:bot:é b/..";
        publish(&h, odd, json!([{"text": "x"}])).unwrap();
        assert!(hdir(&root, odd).is_dir());
        assert_eq!(texts(&h, odd)[0], "x");
        gone(&root);
    }

    #[test]
    fn l4_the_history_lives_apart_from_the_content_addressed_bodies() {
        let base = std::env::temp_dir().join(format!(
            "super-t70-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let s = Store::new(base.join("conversation-bodies"));
        let h = History::new(base.join("conversation-history"), HISTORY_BYTES, HISTORIES_BYTES);
        let d = put(&s, A, "a body");
        publish(&h, K, json!([{"text": "a conversation"}])).unwrap();
        assert_eq!(s.report().unwrap()["blobs"], 1);
        assert_eq!(s.get(&d).unwrap()["text"], "a body");
        assert!(routed_to_history(&json!({"operation": "history_publish"})));
        for o in ["put", "get", "release", "report", "collect"] {
            assert!(!routed_to_history(&json!({"operation": o})), "{o}");
        }
        assert!(s.request(&json!({"operation": "history_load", "history": K})).is_err());
        assert!(h.request(&json!({"operation": "put", "owner": A, "text": "x"})).is_err());
        fs::remove_dir_all(base).ok();
    }

    #[test]
    fn l5_fifty_conversations_publish_and_load_back_whole_after_a_restart() {
        let (h, root) = history(HISTORY_BYTES, HISTORIES_BYTES);
        let all: Vec<String> = (0..50).map(|i| format!("{{\"n\":{i}}}")).collect();
        let first = publish(&h, K, Value::Array(all.iter().map(|t| json!({"text": t})).collect())).unwrap();
        let mut files: Vec<Value> = first["files"].as_array().unwrap().iter().map(|d| json!({"sha256": d})).collect();
        files[7] = json!({"text": "seven, rewritten"});
        publish(&h, K, Value::Array(files)).unwrap();
        let h = reopen(&root);
        h.sweep();
        let back = texts(&h, K);
        let back = back.as_array().unwrap();
        assert_eq!(back.len(), 50);
        for (i, t) in back.iter().enumerate() {
            assert_eq!(*t, if i == 7 { "seven, rewritten".to_string() } else { all[i].clone() });
        }
        assert_eq!(count(&root, K), 51, "the replaced file was removed");
        gone(&root);
    }
}

// T84 (A-108) · Codex code review 4 of T70: M1-M5 and L1, each with the regression its row names.
#[cfg(test)]
mod t84_tests {
    use super::*;
    use std::os::unix::fs::symlink;

    const K: &str = "super-conversations-v1:bot:b8225a5d";
    const K2: &str = "super-conversations-v1";

    fn scratch(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "{tag}-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_nanos()
        ))
    }
    fn history(limit: u64, total: u64) -> (History, PathBuf) {
        let root = scratch("super-t84").join("conversation-history");
        (History::new(root.clone(), limit, total), root)
    }
    fn gone(root: &Path) {
        fs::remove_dir_all(root.parent().unwrap()).ok();
    }
    fn op(h: &History, key: &str, mut r: Value) -> Result<Value, String> {
        r["history"] = json!(key);
        h.request(&r)
    }
    fn publish(h: &History, key: &str, meta: &str, files: Value) -> Result<Value, String> {
        op(h, key, json!({"operation": "history_publish", "meta": meta, "files": files}))
    }
    fn load(h: &History, key: &str) -> Value {
        op(h, key, json!({"operation": "history_load"})).unwrap()
    }
    fn texts(h: &History, key: &str) -> Value {
        load(h, key)["published"]["texts"].clone()
    }
    fn fail(h: &History, p: Point) {
        h.hooks.fail.lock().unwrap().push((p, 0));
    }
    fn synced(h: &History) -> Vec<PathBuf> {
        h.hooks.synced.lock().unwrap().clone()
    }

    /// M1: a staged index counts as the largest index. Filling may be refused (or the promotion may be), the staged
    /// copy stays, and once promoted one of its files can always be deleted.
    #[test]
    fn m1_a_staged_large_index_keeps_deletion_room_through_interleaved_fills_and_its_promotion() {
        let (h, root) = history(HISTORY_BYTES, 3_000);
        let meta = "m".repeat(800);
        let (a, b) = ("a".repeat(10), "b".repeat(10));
        let files = json!([{"text": a}, {"text": b}]);
        let staged = op(&h, K, json!({"operation": "history_publish", "stage": true, "meta": meta, "files": files}));
        let staged = staged.unwrap();
        assert_eq!(staged["state"], "staged");
        let mut admitted = 0;
        for i in 0..12 {
            match publish(&h, &format!("{K2}:bot:fill{i}"), "m", json!([{"text": format!("{i:04}")}])) {
                Ok(_) => admitted += 1,
                Err(e) => {
                    assert!(e.contains("for all histories"), "fill {i}: {e}");
                    assert_eq!(load(&h, K)["migrating"]["texts"], json!([a, b]), "fill {i}: the staged copy stays");
                }
            }
        }
        assert!(admitted > 0, "the fills interleave between staging and promotion");
        match op(&h, K, json!({"operation": "history_promote"})) {
            Ok(_) => {
                let deletion = publish(&h, K, &meta, json!([{"sha256": staged["files"][0]}]));
                assert!(deletion.is_ok(), "a promoted history can always delete one of its files: {deletion:?}");
                assert_eq!(texts(&h, K), json!([a]));
            }
            Err(e) => {
                assert!(e.contains("for all histories"), "{e}");
                let got = load(&h, K);
                assert!(got["published"].is_null(), "a refused promotion publishes nothing");
                assert_eq!(got["migrating"]["texts"], json!([a, b]), "a refused promotion keeps the staged copy");
            }
        }
        gone(&root);
    }

    /// M2: a process stopped before its first ancestor sync; a new instance syncs the folder holding the made `base`
    /// (named, not counted) and refuses until that sync succeeds.
    #[test]
    fn m2_a_new_instance_syncs_the_folder_holding_the_first_made_one_and_refuses_until_it_is_synced() {
        let base = scratch("super-t84-m2");
        let above = base.parent().unwrap().to_path_buf();
        let root = base.join("app").join("conversation-history");
        let first = History::new(root.clone(), HISTORY_BYTES, HISTORIES_BYTES);
        fail(&first, Point::SyncAncestor);
        assert!(publish(&first, K, "m", json!([{"text": "one"}])).is_err());
        assert!(base.join("app").is_dir() && !root.exists(), "both folders were made, nothing inside them");
        assert!(synced(&first).is_empty(), "the failure came before the first ancestor sync");
        drop(first);
        let h = History::new(root.clone(), HISTORY_BYTES, HISTORIES_BYTES);
        h.hooks.fail_dir.lock().unwrap().extend([above.clone(), above.clone()]);
        for attempt in 0..2 {
            let refused = publish(&h, K, "m", json!([{"text": "one"}])).unwrap_err();
            assert!(refused.contains("injected failure at"), "attempt {attempt}: {refused}");
            assert!(!synced(&h).contains(&above), "attempt {attempt}");
            assert!(load(&h, K)["published"].is_null(), "attempt {attempt}: nothing was published");
        }
        publish(&h, K, "m", json!([{"text": "one"}])).unwrap();
        let s = synced(&h);
        assert!(s.contains(&above), "the folder holding the made base was synced: {s:?}");
        assert!(s.contains(&base), "the folder holding the made app was synced: {s:?}");
        assert_eq!(texts(&History::new(root.clone(), HISTORY_BYTES, HISTORIES_BYTES), K), json!(["one"]));
        fs::remove_dir_all(base).ok();
    }

    /// M3: a link above the missing folders is refused, and nothing is made through it.
    #[test]
    fn m3_a_link_above_the_missing_app_folders_is_refused_and_nothing_is_made_through_it() {
        let base = scratch("super-t84-m3");
        let outside = base.join("outside");
        fs::create_dir_all(&outside).unwrap();
        symlink(&outside, base.join("link")).unwrap();
        let root = base.join("link").join("new").join("app").join("conversation-history");
        let h = History::new(root.clone(), HISTORY_BYTES, HISTORIES_BYTES);
        let published = publish(&h, K, "m", json!([{"text": "one"}]));
        assert!(published.is_err(), "a publication through the link is refused: {published:?}");
        let files = json!([{"text": "one"}]);
        let staged = op(&h, K, json!({"operation": "history_publish", "stage": true, "meta": "s", "files": files}));
        assert!(staged.is_err(), "a migration through the link is refused: {staged:?}");
        assert!(op(&h, K, json!({"operation": "history_load"})).is_err(), "a load through the link is refused");
        assert_eq!(fs::read_dir(&outside).unwrap().count(), 0, "nothing was made through the link");
        assert!(fs::symlink_metadata(base.join("link")).unwrap().file_type().is_symlink());
        fs::remove_dir_all(base).ok();
    }

    /// M4 (Codex's scenario): a shrinking replacement is charged its actual peak, 1,888, and what stays plus room for
    /// one more index, separately; neither exceeds 2,000.
    #[test]
    fn m4_a_shrinking_replacement_is_charged_its_actual_peak_and_what_stays_separately() {
        let (h, root) = history(2_000, 1_000_000);
        publish(&h, K, "m", json!([{"text": "a".repeat(1_500)}])).unwrap();
        let small = "b".repeat(100);
        let replaced = publish(&h, K, "m", json!([{"text": small}]));
        assert!(replaced.is_ok(), "a save that shrinks the history fits: {replaced:?}");
        assert_eq!(texts(&h, K), json!([small]));
        gone(&root);
    }

    /// M4 (the brief's case): no prune is credited. 1,500 bytes replaced by three 10-byte files while the prune fails
    /// after the index is replaced: a publication reported successful must still let a file be deleted.
    #[test]
    fn m4_a_publication_reported_successful_leaves_room_to_delete_even_when_its_prune_fails() {
        let (h, root) = history(2_000, 1_000_000);
        let first = "a".repeat(1_500);
        publish(&h, K, "m", json!([{"text": first}])).unwrap();
        let three = ["x", "y", "z"].map(|c| c.repeat(10));
        fail(&h, Point::Prune);
        match publish(&h, K, "m", json!([{"text": three[0]}, {"text": three[1]}, {"text": three[2]}])) {
            Ok(r) => {
                let deletion = publish(&h, K, "m", json!([{"sha256": r["files"][0]}, {"sha256": r["files"][1]}]));
                assert!(deletion.is_ok(), "a reported publication always leaves room to delete: {deletion:?}");
                assert_eq!(texts(&h, K), json!([three[0], three[1]]));
            }
            Err(e) => {
                assert!(e.contains("for one history"), "{e}");
                assert_eq!(texts(&h, K), json!([first]), "a refused publication changes nothing");
            }
        }
        gone(&root);
    }

    /// M5 (Codex code review 4, section 3): one bounded history admits only what it can later delete from.
    #[test]
    fn m5_one_bounded_history_keeps_room_to_delete_from_its_first_publication() {
        let (h, root) = history(2_000, 1_000_000);
        let b = "b".repeat(10);
        let (a, first) = match publish(&h, K, "m", json!([{"text": "a".repeat(1_779)}, {"text": b}])) {
            Ok(r) => ("a".repeat(1_779), r),
            Err(e) => {
                assert!(e.contains("for one history"), "{e}");
                let a = "a".repeat(1_568);
                let r = publish(&h, K, "m", json!([{"text": a}, {"text": b}])).unwrap();
                (a, r)
            }
        };
        let deletion = publish(&h, K, "m", json!([{"sha256": first["files"][0]}]));
        assert!(deletion.is_ok(), "deleting b fits beside the old index: {deletion:?}");
        assert_eq!(texts(&h, K), json!([a]));
        gone(&root);
    }

    /// L1: sizes that cannot be added refuse as storage, in the measurement and in every peak, and never wrap or
    /// panic. The sizes are reported through the production measurement in place of the entries' own.
    #[test]
    fn l1_sizes_that_cannot_be_added_refuse_closed_in_the_measurement_and_in_every_peak() {
        const M: libc::off_t = libc::off_t::MAX;
        let cases: [(&str, bool, &[libc::off_t], bool, &str); 7] = [
            // what overflows; padding in K's folder (else the root); its sizes; K2 published first; published into
            ("one history's peak", true, &[M, M], false, K),
            ("one history's room after", true, &[M, M - 244], false, K),
            ("one history's measurement", true, &[M, M, M], false, K),
            ("all histories' peak", true, &[M, M], false, K2),
            ("all histories' room after", true, &[M, M - 244], false, K2),
            ("all histories' sum of folders", true, &[M, M], true, K2),
            ("all histories' sum of files", false, &[M, M, M], false, K2),
        ];
        for (what, in_history, sizes, before, into) in cases {
            let (h, root) = history(HISTORY_BYTES, HISTORIES_BYTES);
            if before {
                publish(&h, K2, "m", json!([{"text": "x"}])).unwrap();
            }
            let dir = if in_history { root.join(hex(K)) } else { root.clone() };
            fs::create_dir_all(&dir).unwrap();
            for (n, size) in sizes.iter().enumerate() {
                let name = format!("pad-{n}");
                fs::write(dir.join(&name), "p").unwrap();
                h.hooks.sizes.lock().unwrap().insert(name.into_bytes(), *size);
            }
            let got = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                publish(&h, into, "m", json!([{"text": "z"}]))
            }));
            match got {
                Ok(Err(e)) => assert!(e.contains("too large to measure"), "{what}: {e}"),
                Ok(Ok(r)) => panic!("{what}: a wrapped size admitted the publication: {r}"),
                Err(_) => panic!("{what}: an overflow panicked instead of refusing"),
            }
            gone(&root);
        }
    }

    /// M1 (Codex code review 1): a publication that fails after writing its conversations, before replacing its
    /// index, leaves them beside the still-current history, which must still have room to delete one of its files.
    #[test]
    fn m1_a_publication_failing_at_its_index_write_leaves_room_to_delete_from_the_current_history() {
        let (h, root) = history(2_000, 1_000_000);
        let three = ["x", "y", "z"].map(|c| c.repeat(10));
        let first = publish(&h, K, "m", json!([{"text": three[0]}, {"text": three[1]}, {"text": three[2]}])).unwrap();
        h.hooks.fail.lock().unwrap().push((Point::WriteFile, 1));
        let replaced = publish(&h, K, "m", json!([{"text": "r".repeat(1_500)}]));
        let refused = replaced.expect_err("the replacement is refused or fails at its index write");
        assert!(refused.contains("for one history") || refused.contains("at WriteFile "), "{refused}");
        h.hooks.fail.lock().unwrap().clear();
        assert_eq!(texts(&h, K), json!(three), "the current history stays");
        let deletion = publish(&h, K, "m", json!([{"sha256": first["files"][0]}, {"sha256": first["files"][1]}]));
        assert!(deletion.is_ok(), "the still-current history can always delete one of its files: {deletion:?}");
        assert_eq!(texts(&h, K), json!([three[0], three[1]]));
        gone(&root);
    }

    /// M2 (Codex code review 1): a link above a folder that already exists below it is refused too; only the trusted
    /// anchor is reached by path, and nothing is made inside the link's target.
    #[test]
    fn m3_a_link_above_an_existing_folder_is_refused_and_nothing_is_made_inside_its_target() {
        let base = scratch("super-t84-m3e");
        let outside = base.join("outside");
        fs::create_dir_all(outside.join("new")).unwrap();
        symlink(&outside, base.join("link")).unwrap();
        let root = base.join("link").join("new").join("app").join("conversation-history");
        let h = History::new(root.clone(), HISTORY_BYTES, HISTORIES_BYTES);
        let published = publish(&h, K, "m", json!([{"text": "one"}]));
        assert!(published.is_err(), "a publication through the link is refused: {published:?}");
        let files = json!([{"text": "one"}]);
        let staged = op(&h, K, json!({"operation": "history_publish", "stage": true, "meta": "s", "files": files}));
        assert!(staged.is_err(), "a migration through the link is refused: {staged:?}");
        assert!(op(&h, K, json!({"operation": "history_load"})).is_err(), "a load through the link is refused");
        assert_eq!(fs::read_dir(outside.join("new")).unwrap().count(), 0, "nothing was made inside the existing target");
        assert_eq!(fs::read_dir(&outside).unwrap().count(), 1);
        fs::remove_dir_all(base).ok();
    }

    /// M2 (Codex code review 1): the anchor is the deepest OS folder above the app folder; a relative one has none.
    #[test]
    fn m3_the_trusted_anchor_is_the_deepest_os_folder_above_the_app_folder() {
        let tmp = std::env::temp_dir();
        assert_eq!(History::anchor(&tmp.join("super-t84-anchor").join("app")), Some(tmp));
        assert_eq!(History::anchor(Path::new("/")), Some(PathBuf::from("/")));
        assert!(History::anchor(Path::new("relative/app")).is_none());
    }

    /// M2 (Codex code review 2): opens that make nothing walk from the anchor too. A whole store already behind a
    /// link below the anchor is refused by the start's sweep, a load and an abandon, and its outside bytes stay.
    #[test]
    fn m3_a_fully_existing_store_behind_a_link_is_never_swept_loaded_or_abandoned_through_it() {
        let base = scratch("super-t84-m3s");
        let outside = base.join("outside");
        let held = outside.join("new").join("app").join("conversation-history").join(hex(K));
        fs::create_dir_all(&held).unwrap();
        let staged = json!({"schema": INDEX_SCHEMA, "generation": 1, "files": [], "meta": "s"}).to_string();
        let victims = [
            ("victim.tmp", "outside temporary".to_string()),
            ("c-orphan.json", "outside orphan".to_string()),
            (MIGRATING_FILE, staged),
        ];
        for (name, text) in &victims {
            fs::write(held.join(name), text).unwrap();
        }
        symlink(&outside, base.join("link")).unwrap();
        let root = base.join("link").join("new").join("app").join("conversation-history");
        let h = History::new(root.clone(), HISTORY_BYTES, HISTORIES_BYTES);
        assert_eq!(h.sweep(), 0, "the start's sweep removes nothing through the link");
        let loaded = op(&h, K, json!({"operation": "history_load"}));
        assert!(loaded.is_err(), "a load through the link is refused: {loaded:?}");
        let abandoned = op(&h, K, json!({"operation": "history_abandon"}));
        assert!(abandoned.is_err(), "an abandon through the link is refused: {abandoned:?}");
        for (name, text) in &victims {
            assert_eq!(fs::read_to_string(held.join(name)).unwrap(), *text, "{name} outside is untouched");
        }
        assert_eq!(fs::read_dir(&held).unwrap().count(), victims.len(), "nothing outside was removed");
        fs::remove_dir_all(base).ok();
    }
}
