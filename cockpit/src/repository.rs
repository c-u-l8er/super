//! Repository onboarding stays in the native host. The webview requests a
//! chooser, never supplies a filesystem path, and receives no stored path.
//!
//! Opening an ALREADY REGISTERED repository in the Editor needs no chooser:
//! the page names it by its `rp_` ref, the runtime answers the folder the
//! person registered, and [`registered_root`] re-checks it is a Git
//! top-level. The ref is the only thing that crosses the webview boundary,
//! and a ref names nothing the person did not already choose in the native
//! chooser when they registered it.
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
static CHOOSER_OPEN: AtomicBool = AtomicBool::new(false);
pub struct ChooserGuard;
impl ChooserGuard {
    pub fn acquire() -> Result<Self, String> {
        CHOOSER_OPEN
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map(|_| Self)
            .map_err(|_| "A repository chooser is already open.".into())
    }
}
impl Drop for ChooserGuard {
    fn drop(&mut self) {
        CHOOSER_OPEN.store(false, Ordering::Release);
    }
}

#[cfg(target_os = "linux")]
pub fn choose(window: &tauri::Window) -> Result<Option<PathBuf>, String> {
    choose_folder(
        window,
        "Register a local Git repository",
        "Register repository",
    )
}

#[cfg(target_os = "linux")]
fn choose_folder(
    window: &tauri::Window,
    title: &str,
    accept: &str,
) -> Result<Option<PathBuf>, String> {
    use gtk::prelude::*;
    let parent = window
        .gtk_window()
        .map_err(|_| "The app window is unavailable")?;
    let dialog = gtk::FileChooserDialog::with_buttons(
        Some(title),
        Some(&parent),
        gtk::FileChooserAction::SelectFolder,
        &[
            ("Cancel", gtk::ResponseType::Cancel),
            (accept, gtk::ResponseType::Accept),
        ],
    );
    dialog.set_default_size(1000, 700);
    dialog.set_default_response(gtk::ResponseType::Accept);
    dialog.set_modal(true);
    dialog.set_local_only(true);
    dialog.set_create_folders(false);
    dialog.set_current_folder(std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    let response = dialog.run();
    let selected = if response == gtk::ResponseType::Accept {
        dialog.filename()
    } else {
        None
    };
    unsafe {
        dialog.destroy();
    }
    Ok(selected)
}

#[cfg(not(target_os = "linux"))]
pub fn choose(_window: &tauri::Window) -> Result<Option<PathBuf>, String> {
    Err("Repository selection is currently available in the Linux desktop app.".into())
}

pub fn git_root(path: &Path) -> Result<PathBuf, String> {
    let selected = path
        .canonicalize()
        .map_err(|_| "The selected folder is no longer available.")?;
    if !selected.is_dir() {
        return Err("Select a repository folder.".into());
    }
    #[cfg(target_os = "linux")]
    let result = std::process::Command::new("git")
        .arg("-C")
        .arg(&selected)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .map_err(|_| "Git is unavailable on this machine.")?;
    // T29b1 item 4: the fork lock is held across the spawn only, never the wait (amendment 1).
    #[cfg(target_os = "macos")]
    let result = {
        let spawn_guard = super_host::fdpass::spawn_guard();
        let child = std::process::Command::new("git")
            .arg("-C")
            .arg(&selected)
            .args(["rev-parse", "--show-toplevel"])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn();
        drop(spawn_guard);
        child
            .and_then(|c| c.wait_with_output())
            .map_err(|_| "Git is unavailable on this machine.")?
    };
    if !result.status.success() {
        return Err("This folder is not a Git working tree.".into());
    }
    let output = std::str::from_utf8(&result.stdout)
        .map_err(|_| "The repository folder name must be valid UTF-8.")?;
    let root = PathBuf::from(output.trim_end_matches('\n'))
        .canonicalize()
        .map_err(|_| "The repository root could not be resolved.")?;
    if root != selected {
        return Err("Choose the repository's top-level folder, rather than a subfolder.".into());
    }
    if root.to_str().is_none() {
        return Err("The repository folder name must be valid UTF-8.".into());
    }
    Ok(root)
}

pub fn register(rt: &super_host::Runtime, selected: &Path) -> Result<Value, String> {
    let root = git_root(selected)?;
    let result = rt.bridge_call(&json!({
        "schema": "bridge-command@1", "command": "register_repository", "path": root
    })).map_err(|_| "The runtime could not confirm repository registration. Check the repository list before trying again.")?;
    registration_receipt(result)
}

/// A registered repository's Git root, answered by the runtime and
/// re-validated here. Takes a reference, never a path.
pub fn registered_root(rt: &super_host::Runtime, repository_ref: &str) -> Result<PathBuf, String> {
    repository_reference(repository_ref)?;
    let result = rt
        .bridge_call(&json!({
            "schema": "bridge-command@1", "command": "registered_repository",
            "repository_ref": repository_ref
        }))
        .map_err(|_| "The runtime could not look up that repository. Check the repository list before trying again.")?;
    git_root(&registered_path(result)?)
}

/// The shape a repository reference must have before it is sent anywhere:
/// `rp_` and digits, at most 100 bytes. Anything else — a path, an empty
/// string, a ref with a suffix — is refused before the runtime is asked.
pub fn repository_reference(reference: &str) -> Result<(), String> {
    let digits = reference.strip_prefix("rp_").unwrap_or("");
    if reference.len() <= 100 && !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) {
        Ok(())
    } else {
        Err("Choose a registered repository.".into())
    }
}

/// The path out of a `registered_repository` reply, or the runtime's own
/// public refusal message.
fn registered_path(result: Value) -> Result<PathBuf, String> {
    if result["ok"] != true {
        return Err(result["refusal"]["public_message"]
            .as_str()
            .unwrap_or("That repository is not registered in this world.")
            .to_string());
    }
    let path = result["repository"]["path"]
        .as_str()
        .filter(|p| !p.is_empty())
        .ok_or("The runtime returned no folder for that repository.")?;
    Ok(PathBuf::from(path))
}

pub fn record_review_test(
    rt: &super_host::Runtime,
    operation: &str,
    mut fields: Value,
) -> Result<Value, String> {
    if ![
        "begin_development_test",
        "finish_development_test",
        "recover_development_tests",
        "prepare_development_acceptance",
    ]
    .contains(&operation)
    {
        return Err("Unknown test event.".into());
    }
    fields["schema"] = json!("bridge-command@1");
    fields["command"] = json!(operation);
    let result = rt
        .bridge_call(&fields)
        .map_err(|_| "The runtime could not confirm the test event.")?;
    if result["ok"] != true {
        return Err(result["refusal"]["public_message"]
            .as_str()
            .unwrap_or("The runtime refused this test event.")
            .into());
    }
    Ok(result["run"].clone())
}

pub fn resolve_review_test(
    rt: &super_host::Runtime,
    path: &Path,
    id: &str,
    revision: u64,
    world: [Value; 3],
) -> Result<Value, String> {
    let result=rt.bridge_call(&json!({"schema":"bridge-command@1","command":"resolve_development_test","path":path,"attempt_ref":id,"revision":revision,"world":world})).map_err(|_|"Could not resolve the saved review.")?;
    if result["ok"] != true || result["review"]["matched"] != true {
        return Err("The review or plan changed, or the selected repository does not match. Reopen the latest review and choose its repository in Editor.".into());
    }
    Ok(result["review"]["attempt"].clone())
}

pub fn match_plan(
    rt: &super_host::Runtime,
    path: &Path,
    task_ref: &str,
    revision: u64,
    world: [Value; 3],
) -> Result<Value, String> {
    if task_ref.is_empty() || task_ref.len() > 100 || revision == 0 {
        return Err("Reopen a current development plan.".into());
    }
    let result = rt.bridge_call(&json!({"schema":"bridge-command@1", "command":"match_development_repository", "path":path, "task_ref":task_ref, "revision":revision, "world":world}))
        .map_err(|_| "The runtime could not verify this repository. Try again when connected.")?;
    if result["ok"] != true || result["match"]["matched"] != true {
        return Err("The selected folder does not match the current plan's repository, or the plan changed. Open the intended repository and prepare the latest plan.".into());
    }
    Ok(result["match"].clone())
}

fn registration_receipt(result: Value) -> Result<Value, String> {
    // The bridge owns the full record. The page only gets a submission receipt;
    // its repository list continues to come from the next coherent frame.
    if result["ok"] != true {
        let code = result["refusal"]["code"]
            .as_str()
            .or_else(|| result["error"]["code"].as_str())
            .unwrap_or("repository-not-registered");
        return Err(format!("Repository registration was refused: {code}"));
    }
    let reference = result["repository"]["ref"].as_str()
        .ok_or("The runtime returned no repository reference. Check the repository list before trying again.")?;
    Ok(json!({"status": "registered", "repository_ref": reference}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};
    struct Scratch(PathBuf);
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn scratch() -> Scratch {
        let p = std::env::temp_dir().join(format!(
            "super-repository-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        Scratch(p)
    }
    #[test]
    fn accepts_git_root_and_requires_explicit_root_selection() {
        let s = scratch();
        assert!(std::process::Command::new("git")
            .args(["init", "-q"])
            .arg(&s.0)
            .status()
            .unwrap()
            .success());
        assert_eq!(git_root(&s.0).unwrap(), s.0.canonicalize().unwrap());
        let sub = s.0.join("source");
        std::fs::create_dir(&sub).unwrap();
        assert!(git_root(&sub).unwrap_err().contains("top-level"));
    }
    #[test]
    fn non_repository_and_missing_folder_have_actionable_errors() {
        let s = scratch();
        assert!(git_root(&s.0).unwrap_err().contains("not a Git"));
        assert!(git_root(&s.0.join("missing"))
            .unwrap_err()
            .contains("no longer available"));
    }
    #[test]
    fn a_repository_reference_is_a_ref_and_never_a_path() {
        for ok in ["rp_0001", "rp_0003", "rp_123456"] {
            assert!(repository_reference(ok).is_ok(), "{ok}");
        }
        for bad in ["", "rp_", "rp_x", "/home/someone/source", "rp_0003/../x", "wt_0001", "RP_0001", "rp_0003 "] {
            assert_eq!(repository_reference(bad).unwrap_err(), "Choose a registered repository.", "{bad}");
        }
        let long = format!("rp_{}", "9".repeat(98));
        assert!(repository_reference(&long).is_err());
    }
    #[test]
    fn a_registered_reply_yields_its_path_and_a_refusal_yields_its_message() {
        assert_eq!(
            registered_path(json!({"ok": true, "repository": {"ref": "rp_0001", "path": "/private/source"}})).unwrap(),
            PathBuf::from("/private/source")
        );
        assert_eq!(
            registered_path(json!({"ok": false, "refusal": {"code": "repository-unknown",
                "public_message": "That repository is not registered in this world. Register it first."}}))
                .unwrap_err(),
            "That repository is not registered in this world. Register it first."
        );
        assert!(registered_path(json!({"ok": true, "repository": {"ref": "rp_0001"}})).is_err());
        assert!(registered_path(json!({"ok": true, "repository": {"ref": "rp_0001", "path": ""}})).is_err());
    }
    #[test]
    fn submission_receipt_does_not_return_the_stored_path() {
        let receipt = registration_receipt(
            json!({"ok": true, "repository": {"ref": "rp_0001", "path": "/private/source"}}),
        )
        .unwrap();
        assert_eq!(
            receipt,
            json!({"status": "registered", "repository_ref": "rp_0001"})
        );
        assert!(
            registration_receipt(json!({"ok": false, "refusal": {"code": "world-sealed"}}))
                .unwrap_err()
                .contains("world-sealed")
        );
        assert!(registration_receipt(json!({"ok": true})).is_err());
    }
}

#[cfg(target_os = "linux")]
pub fn choose_development(window: &tauri::Window) -> Result<Option<PathBuf>, String> {
    use gtk::prelude::*;
    let parent = window
        .gtk_window()
        .map_err(|_| "The app window is unavailable.")?;
    let dialog = gtk::FileChooserDialog::with_buttons(
        Some("Open repository for local development"),
        Some(&parent),
        gtk::FileChooserAction::SelectFolder,
        &[
            ("Cancel", gtk::ResponseType::Cancel),
            ("Open repository", gtk::ResponseType::Accept),
        ],
    );
    dialog.set_modal(true);
    dialog.set_local_only(true);
    dialog.set_create_folders(false);
    dialog.set_default_size(1000, 700);
    dialog.set_default_response(gtk::ResponseType::Accept);
    dialog.set_current_folder(std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    let response = dialog.run();
    let selected = if response == gtk::ResponseType::Accept {
        dialog.filename()
    } else {
        None
    };
    unsafe {
        dialog.destroy();
    }
    Ok(selected)
}
#[cfg(not(target_os = "linux"))]
pub fn choose_development(_window: &tauri::Window) -> Result<Option<PathBuf>, String> {
    Err("Local development is currently supported on Linux.".into())
}

/// T29b1's laws on macOS (superlane/t29b/LAWS-T29B1.md): B3 (c), a spawn takes the fork lock for writing (item 4).
#[cfg(all(test, target_os = "macos"))]
mod t29b1_laws {
    use super::*;
    /// Amendment 3, B3 (d): calibrated first (an unheld git_root within 250 ms, best of three, or the hold proves
    /// nothing), then the hand-off (the worker says it is entering git_root), the fork lock held for reading 750 ms
    /// with no return allowed, released, and the return required within 5 s.
    #[test]
    fn b3_git_root_waits_for_the_fork_lock() {
        use std::time::{Duration, Instant};
        let p = std::env::temp_dir().join(format!("t29b1-{}-{}-{}", "b3", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        std::fs::create_dir_all(&p).unwrap();
        assert!(std::process::Command::new("git").args(["init", "-q"]).arg(&p).status().unwrap().success());
        let best = (0..3).map(|_| { let t = Instant::now(); git_root(&p).unwrap(); t.elapsed() }).min().unwrap();
        assert!(best <= Duration::from_millis(250), "inconclusive: an unheld git_root took {best:?} at best of three, over 250 ms");
        let held = super_host::fdpass::FD_BIRTH.read().unwrap_or_else(|e| e.into_inner());
        let (entered, entered_rx) = std::sync::mpsc::channel();
        let (done, done_rx) = std::sync::mpsc::channel();
        let q = p.clone();
        let h = std::thread::spawn(move || {
            let _ = entered.send(());
            let r = git_root(&q);
            let _ = done.send(());
            r
        });
        entered_rx.recv_timeout(Duration::from_secs(5)).expect("the worker never reached git_root");
        assert!(done_rx.recv_timeout(Duration::from_millis(750)).is_err(), "git_root returned while the fork lock was held for reading");
        drop(held);
        assert!(done_rx.recv_timeout(Duration::from_secs(5)).is_ok(), "git_root did not return within 5 s of the fork lock's release");
        assert_eq!(h.join().unwrap().unwrap(), p.canonicalize().unwrap());
        let _ = std::fs::remove_dir_all(&p);
    }
}
