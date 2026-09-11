//! Recoverable human-operated file-set writes. The durable journal is private Git
//! metadata; it is not a runtime acceptance receipt. Recovery never guesses over
//! an unrelated edit. A journal survives until all directory writes are synced.
use super::*;
use serde::Serialize;
const JOURNAL: &str = "super-apply-journal-v1.json";
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Edit {
    pub path: String,
    pub original: Option<String>,
    #[serde(deserialize_with = "required_content")]
    pub content: Option<String>,
}
// Missing content is not permission to delete. Only an explicit JSON null is.
fn required_content<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<String>, D::Error> {
    Option::<String>::deserialize(d)
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Journal {
    version: u32,
    device: u64,
    inode: u64,
    files: Vec<Edit>,
    #[serde(default)]
    modes: BTreeMap<String, u32>,
}
pub(super) struct Store {
    dir: File,
    _lock: File,
}
impl Store {
    fn open(session: &Session) -> Result<Self, String> {
        let root = basis_root(session)?;
        let raw = git_read(root, &["rev-parse", "--absolute-git-dir"])?;
        let path = String::from_utf8(raw).map_err(error)?;
        let dir = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
            .open(path.trim_end())
            .map_err(error)?;
        let lock = open_at(
            &dir,
            "super-apply.lock",
            libc::O_RDWR | libc::O_CREAT | libc::O_NONBLOCK,
            0o600,
        )?;
        if !lock.metadata().map_err(error)?.is_file() {
            return Err("Change-set lock is not a regular file.".into());
        }
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err("Another Super window is applying this repository. Try again.".into());
        }
        Ok(Self { dir, _lock: lock })
    }
    fn read(&self, root: &File) -> Result<Option<Journal>, String> {
        let mut f = match open_at(&self.dir, JOURNAL, libc::O_RDONLY | libc::O_NONBLOCK, 0) {
            Ok(f) => f,
            Err(e) => {
                let name = CString::new(JOURNAL).unwrap();
                let mut st = std::mem::MaybeUninit::<libc::stat>::uninit();
                if unsafe {
                    libc::fstatat(
                        self.dir.as_raw_fd(),
                        name.as_ptr(),
                        st.as_mut_ptr(),
                        libc::AT_SYMLINK_NOFOLLOW,
                    )
                } < 0
                    && std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT)
                {
                    return Ok(None);
                }
                return Err(e);
            }
        };
        let meta = f.metadata().map_err(error)?;
        if !meta.is_file() || meta.len() > 10 * 1024 * 1024 {
            return Err(
                "Change-set recovery journal is invalid; preserve it for inspection.".into(),
            );
        }
        let mut bytes = Vec::new();
        Read::by_ref(&mut f)
            .take(10 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(error)?;
        let j: Journal = serde_json::from_slice(&bytes).map_err(|_| {
            "Change-set recovery journal is unreadable; preserve it for inspection."
        })?;
        let m = root.metadata().map_err(error)?;
        if ![1, 2].contains(&j.version)
            || (j.version == 1 && j.files.iter().any(|e| e.content.is_none()))
            || j.device != m.dev()
            || j.inode != m.ino()
        {
            return Err("Change-set recovery belongs to a different repository folder.".into());
        }
        validate(&j.files)?;
        if j.modes.values().any(|m| *m > 0o777)
            || (j.version == 2
                && (j.modes.len() != j.files.len()
                    || j.files.iter().any(|e| !j.modes.contains_key(&e.path))))
        {
            return Err("Invalid recovery permissions.".into());
        }
        Ok(Some(j))
    }
    fn write(&self, j: &Journal) -> Result<(), String> {
        let temp = format!(
            ".super-apply-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_err(error)?
                .as_nanos()
        );
        let from = CString::new(temp.clone()).map_err(error)?;
        let to = CString::new(JOURNAL).unwrap();
        let mut f = open_at(
            &self.dir,
            &temp,
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
            0o600,
        )?;
        let result = (|| {
            f.write_all(&serde_json::to_vec(j).map_err(error)?)
                .map_err(error)?;
            f.sync_all().map_err(error)?;
            if unsafe {
                libc::renameat2(
                    self.dir.as_raw_fd(),
                    from.as_ptr(),
                    self.dir.as_raw_fd(),
                    to.as_ptr(),
                    libc::RENAME_NOREPLACE,
                )
            } != 0
            {
                return Err(error(std::io::Error::last_os_error()));
            }
            self.dir.sync_all().map_err(error)
        })();
        if result.is_err() {
            unsafe {
                libc::unlinkat(self.dir.as_raw_fd(), from.as_ptr(), 0);
            }
        }
        result
    }
    fn clear(&self) -> Result<(), String> {
        let name = CString::new(JOURNAL).unwrap();
        if unsafe { libc::unlinkat(self.dir.as_raw_fd(), name.as_ptr(), 0) } != 0 {
            return Err(error(std::io::Error::last_os_error()));
        }
        self.dir.sync_all().map_err(error)
    }
}
use std::os::unix::fs::OpenOptionsExt;
fn validate(files: &[Edit]) -> Result<(), String> {
    if files.len() < 2 || files.len() > 4 {
        return Err("Apply between two and four files together.".into());
    }
    let mut paths = Vec::new();
    for e in files {
        let parsed = parts(&e.path)?;
        if parsed.is_empty() || parsed.join("/") != e.path {
            return Err("Use a canonical relative file path.".into());
        }
        if e.content
            .as_ref()
            .is_some_and(|s| s.len() > FILE_LIMIT || s.contains('\0'))
            || (e.content.is_none() && e.original.is_none())
            || e.original
                .as_ref()
                .is_some_and(|s| s.len() > FILE_LIMIT || s.contains('\0'))
        {
            return Err("Change-set files must be UTF-8 text up to 1 MiB.".into());
        }
        for p in &paths {
            let p: &String = p;
            if p == &e.path
                || p.starts_with(&(e.path.clone() + "/"))
                || e.path.starts_with(&(p.clone() + "/"))
            {
                return Err("Change-set paths overlap.".into());
            }
        }
        paths.push(e.path.clone());
    }
    Ok(())
}
fn disk(root: &File, path: &str) -> Result<Option<String>, String> {
    let (parent, name) = file_parent(root, path)?;
    match open_at(&parent, &name, libc::O_RDONLY | libc::O_NONBLOCK, 0) {
        Ok(mut f) => Ok(Some(read_text(&mut f)?)),
        Err(e) => {
            let n = CString::new(name).map_err(error)?;
            let mut st = std::mem::MaybeUninit::<libc::stat>::uninit();
            if unsafe {
                libc::fstatat(
                    parent.as_raw_fd(),
                    n.as_ptr(),
                    st.as_mut_ptr(),
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            } < 0
                && std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT)
            {
                Ok(None)
            } else {
                Err(e)
            }
        }
    }
}
fn file_mode(root: &File, path: &str) -> Result<u32, String> {
    let (p, n) = file_parent(root, path)?;
    let f = open_at(&p, &n, libc::O_RDONLY | libc::O_NONBLOCK, 0)?;
    Ok(f.metadata().map_err(error)?.permissions().mode() & 0o777)
}
fn capture_modes(root: &File, files: &[Edit]) -> Result<BTreeMap<String, u32>, String> {
    files
        .iter()
        .map(|e| {
            Ok((
                e.path.clone(),
                if e.original.is_some() {
                    file_mode(root, &e.path)?
                } else {
                    0o644
                },
            ))
        })
        .collect()
}
fn preflight(root: &File, files: &[Edit], recover: bool) -> Result<(), String> {
    for e in files {
        let current = disk(root, &e.path)?;
        if current != e.original && (!recover || current != e.content) {
            return Err(format!("{} changed on disk. No additional files were written; resolve the conflict before continuing.",e.path));
        }
    }
    Ok(())
}
fn perform(
    root: &File,
    files: &[Edit],
    restore: bool,
    modes: &BTreeMap<String, u32>,
) -> Result<(), String> {
    preflight(root, files, true)?;
    for e in files {
        if disk(root, &e.path)?.is_some() {
            if let Some(mode) = modes.get(&e.path) {
                if file_mode(root, &e.path)? != *mode {
                    return Err(format!("{} permissions changed; recovery refused.", e.path));
                }
            }
        }
    }
    for e in files {
        let current = disk(root, &e.path)?;
        let target = if restore {
            e.original.clone()
        } else {
            e.content.clone()
        };
        if current == target {
            // A previous process may have stopped after rename but before the
            // directory sync. Recovery must flush even an already-matching file.
            file_parent(root, &e.path)?.0.sync_all().map_err(error)?;
            continue;
        }
        if current != e.original && current != e.content {
            return Err(format!(
                "{} changed during application. Open change-set recovery.",
                e.path
            ));
        }
        match target {
            Some(text) => {
                save_mode(
                    root,
                    &e.path,
                    current,
                    text,
                    if restore {
                        modes.get(&e.path).copied()
                    } else {
                        None
                    },
                )?;
            }
            None => {
                let (parent, name) = file_parent(root, &e.path)?;
                let name = CString::new(name).map_err(error)?;
                if unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), 0) } != 0 {
                    return Err(error(std::io::Error::last_os_error()));
                }
            }
        }
        file_parent(root, &e.path)?.0.sync_all().map_err(error)?;
    }
    // A concurrent edit never turns a mismatching result into reported success.
    for e in files {
        let target = if restore {
            e.original.clone()
        } else {
            e.content.clone()
        };
        if disk(root, &e.path)? != target {
            return Err("Files changed during application. Open change-set recovery.".into());
        }
    }
    Ok(())
}
pub fn status(session: &Session) -> Result<Value, String> {
    let store = Store::open(session)?;
    let root = session.directory.as_ref().unwrap();
    Ok(match store.read(root)? {
        None => Value::Null,
        Some(j) => {
            json!({"paths":j.files.iter().map(|e|&e.path).collect::<Vec<_>>(),"state":"recovery-required"})
        }
    })
}
pub fn apply(session: &Session, files: Vec<Edit>) -> Result<Value, String> {
    validate(&files)?;
    let store = Store::open(session)?;
    let root = session.directory.as_ref().unwrap();
    if store.read(root)?.is_some() {
        return Err("Finish the pending change-set recovery first.".into());
    }
    preflight(root, &files, false)?;
    let m = root.metadata().map_err(error)?;
    let modes = capture_modes(root, &files)?;
    store.write(&Journal {
        version: 2,
        device: m.dev(),
        inode: m.ino(),
        files: files.clone(),
        modes: modes.clone(),
    })?;
    perform(root, &files, false, &modes)?;
    store.clear()?;
    Ok(
        json!({"state":"applied","paths":files.iter().map(|e|&e.path).collect::<Vec<_>>(),"files":files.iter().map(|e|json!({"path":e.path,"content":e.content})).collect::<Vec<_>>() }),
    )
}
pub fn recover(session: &Session, restore: bool) -> Result<Value, String> {
    let store = Store::open(session)?;
    let root = session.directory.as_ref().unwrap();
    let j = store.read(root)?.ok_or("No pending change set.")?;
    perform(root, &j.files, restore, &j.modes)?;
    store.clear()?;
    Ok(
        json!({"state":if restore{"restored"}else{"applied"},"paths":j.files.iter().map(|e|&e.path).collect::<Vec<_>>(),"files":j.files.iter().map(|e|json!({"path":e.path,"content":if restore{e.original.clone()}else{e.content.clone()}})).collect::<Vec<_>>() }),
    )
}
pub fn guard(session: &Session) -> Result<Store, String> {
    let store = Store::open(session)?;
    if store.read(session.directory.as_ref().unwrap())?.is_some() {
        Err("Resolve change-set recovery before saving individual files.".into())
    } else {
        Ok(store)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (PathBuf, Session) {
        let p = std::env::temp_dir().join(format!(
            "super-set-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        assert!(Command::new("git")
            .args(["init", "-q"])
            .arg(&p)
            .status()
            .unwrap()
            .success());
        std::fs::write(p.join("a"), "old a").unwrap();
        std::fs::write(p.join("b"), "old b").unwrap();
        let s = Session {
            root: Some(p.clone()),
            directory: Some(File::open(&p).unwrap()),
            ..Session::default()
        };
        (p, s)
    }
    fn edits() -> Vec<Edit> {
        vec![
            Edit {
                path: "a".into(),
                original: Some("old a".into()),
                content: Some("new a".into()),
            },
            Edit {
                path: "b".into(),
                original: Some("old b".into()),
                content: Some("new b".into()),
            },
        ]
    }
    fn interrupted(s: &Session, e: &[Edit]) {
        let store = Store::open(s).unwrap();
        let root = s.directory.as_ref().unwrap();
        let m = root.metadata().unwrap();
        store
            .write(&Journal {
                version: 2,
                device: m.dev(),
                inode: m.ino(),
                files: e.to_vec(),
                modes: capture_modes(root, e).unwrap(),
            })
            .unwrap();
        perform(root, &e[..1], false, &capture_modes(root, e).unwrap()).unwrap();
        file_parent(root, &e[0].path).unwrap().0.sync_all().unwrap();
    }
    #[test]
    fn set_applies_and_refuses_stale_second_without_writing_first() {
        let (p, s) = fixture();
        let e = edits();
        std::fs::write(p.join("b"), "outside").unwrap();
        assert!(apply(&s, e.clone()).is_err());
        assert_eq!(std::fs::read_to_string(p.join("a")).unwrap(), "old a");
        assert!(status(&s).unwrap().is_null());
        std::fs::write(p.join("b"), "old b").unwrap();
        apply(&s, e).unwrap();
        assert_eq!(std::fs::read_to_string(p.join("a")).unwrap(), "new a");
        assert_eq!(std::fs::read_to_string(p.join("b")).unwrap(), "new b");
        assert!(status(&s).unwrap().is_null());
        std::fs::remove_dir_all(p).unwrap();
    }
    #[test]
    fn interrupted_set_reopens_and_finishes() {
        let (p, s) = fixture();
        interrupted(&s, &edits());
        drop(s);
        let s = Session {
            root: Some(p.clone()),
            directory: Some(File::open(&p).unwrap()),
            ..Session::default()
        };
        assert!(!status(&s).unwrap().is_null());
        assert!(guard(&s).is_err());
        recover(&s, false).unwrap();
        assert_eq!(std::fs::read_to_string(p.join("b")).unwrap(), "new b");
        assert!(status(&s).unwrap().is_null());
        std::fs::remove_dir_all(p).unwrap();
    }
    #[test]
    fn interrupted_restore_refuses_outside_edit_then_restores_originals() {
        let (p, s) = fixture();
        interrupted(&s, &edits());
        std::fs::write(p.join("b"), "outside").unwrap();
        assert!(recover(&s, true).is_err());
        assert_eq!(std::fs::read_to_string(p.join("a")).unwrap(), "new a");
        std::fs::write(p.join("b"), "old b").unwrap();
        recover(&s, true).unwrap();
        assert_eq!(std::fs::read_to_string(p.join("a")).unwrap(), "old a");
        std::fs::remove_dir_all(p).unwrap();
    }
    #[test]
    fn restore_removes_only_the_new_file_with_exact_result() {
        let (p, s) = fixture();
        let mut e = edits();
        e[0] = Edit {
            path: "created".into(),
            original: None,
            content: Some("new file".into()),
        };
        interrupted(&s, &e);
        recover(&s, true).unwrap();
        assert!(!p.join("created").exists());
        assert_eq!(std::fs::read_to_string(p.join("b")).unwrap(), "old b");
        std::fs::remove_dir_all(p).unwrap();
    }
    #[test]
    fn rejects_symlink_members_overlapping_paths_and_concurrent_owner() {
        let (p, s) = fixture();
        let mut e = edits();
        e[1].path = "a/child".into();
        assert!(apply(&s, e).is_err());
        std::fs::remove_file(p.join("b")).unwrap();
        std::os::unix::fs::symlink(p.join("a"), p.join("b")).unwrap();
        assert!(apply(&s, edits()).is_err());
        let _lock = Store::open(&s).unwrap();
        assert!(status(&s).is_err());
        std::fs::remove_dir_all(p).unwrap();
    }
}

#[cfg(test)]
mod deletion_tests {
    use super::*;
    #[test]
    fn deletion_requires_explicit_content_and_existing_original() {
        assert!(serde_json::from_value::<Edit>(json!({"path":"old","original":"before"})).is_err());
        let deleted: Edit =
            serde_json::from_value(json!({"path":"old","original":"before","content":null}))
                .unwrap();
        assert!(deleted.content.is_none());
        assert!(validate(&[
            deleted,
            Edit {
                path: "missing".into(),
                original: None,
                content: None
            }
        ])
        .is_err());
    }
    #[test]
    fn deletion_restores_original_permissions_and_refuses_recreated_content() {
        let p = std::env::temp_dir().join(format!(
            "super-delete-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        assert!(Command::new("git")
            .args(["init", "-q"])
            .arg(&p)
            .status()
            .unwrap()
            .success());
        std::fs::write(p.join("old.sh"), "echo old\n").unwrap();
        std::fs::set_permissions(p.join("old.sh"), std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::write(p.join("use.txt"), "old").unwrap();
        let s = Session {
            root: Some(p.clone()),
            directory: Some(File::open(&p).unwrap()),
            ..Session::default()
        };
        let root = s.directory.as_ref().unwrap();
        let files = vec![
            Edit {
                path: "old.sh".into(),
                original: Some("echo old\n".into()),
                content: None,
            },
            Edit {
                path: "use.txt".into(),
                original: Some("old".into()),
                content: Some("new".into()),
            },
        ];
        let modes = capture_modes(root, &files).unwrap();
        let meta = root.metadata().unwrap();
        {
            let store = Store::open(&s).unwrap();
            store
                .write(&Journal {
                    version: 2,
                    device: meta.dev(),
                    inode: meta.ino(),
                    files: files.clone(),
                    modes: modes.clone(),
                })
                .unwrap();
        }
        perform(root, &files[..1], false, &modes).unwrap();
        assert!(!p.join("old.sh").exists());
        std::fs::write(p.join("old.sh"), "outside").unwrap();
        assert!(recover(&s, true).is_err());
        std::fs::remove_file(p.join("old.sh")).unwrap();
        recover(&s, true).unwrap();
        assert_eq!(
            std::fs::read_to_string(p.join("old.sh")).unwrap(),
            "echo old\n"
        );
        assert_eq!(file_mode(root, "old.sh").unwrap(), 0o755);
        apply(&s, files).unwrap();
        assert!(!p.join("old.sh").exists());
        assert_eq!(std::fs::read_to_string(p.join("use.txt")).unwrap(), "new");
        std::fs::remove_dir_all(p).unwrap();
    }
}
