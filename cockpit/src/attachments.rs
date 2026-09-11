//! The native chooser owns file paths; the webview receives validated text only.
use serde_json::{json, Value};
use std::{
    io::Read,
    path::{Path, PathBuf},
};
const EXTENSIONS: &[&str] = &[
    "txt", "md", "json", "csv", "js", "ts", "tsx", "jsx", "rs", "py", "ex", "exs", "html", "css",
    "yaml", "yml", "toml", "xml", "log",
];
#[cfg(target_os = "linux")]
pub fn choose(window: &tauri::Window) -> Result<Vec<PathBuf>, String> {
    use gtk::prelude::*;
    let parent = window
        .gtk_window()
        .map_err(|_| "The app window is unavailable.")?;
    choose_dialog(parent.upcast_ref(), |_| {})
}
#[cfg(target_os = "linux")]
fn choose_dialog(
    parent: &gtk::Window,
    configure: impl FnOnce(&gtk::FileChooserNative),
) -> Result<Vec<PathBuf>, String> {
    use gtk::prelude::*;
    let dialog = gtk::FileChooserNative::new(
        Some("Attach text or code files"),
        Some(parent),
        gtk::FileChooserAction::Open,
        Some("Attach"),
        Some("Cancel"),
    );
    dialog.set_modal(true);
    dialog.set_local_only(true);
    dialog.set_select_multiple(true);
    let filter = gtk::FileFilter::new();
    filter.set_name(Some("Text and code files"));
    for ext in EXTENSIONS {
        filter.add_pattern(&format!("*.{ext}"));
    }
    dialog.add_filter(filter);
    configure(&dialog);
    let response = dialog.run();
    let files = if response == gtk::ResponseType::Accept {
        dialog.filenames()
    } else {
        vec![]
    };
    dialog.destroy();
    Ok(files)
}
#[cfg(not(target_os = "linux"))]
pub fn choose(_window: &tauri::Window) -> Result<Vec<PathBuf>, String> {
    Err("Native attachments are currently supported on Linux.".into())
}
fn read(path: &Path) -> Result<Value, String> {
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or("The filename is not valid UTF-8.")?;
    if name.len() > 255
        || !EXTENSIONS.contains(
            &path
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("")
                .to_ascii_lowercase()
                .as_str(),
        )
    {
        return Err("Choose a supported text or code file.".into());
    }
    let file = std::fs::File::open(path).map_err(|_| "The selected file could not be opened.")?;
    if !file
        .metadata()
        .map_err(|_| "Could not inspect the file.")?
        .is_file()
    {
        return Err("Choose a regular file.".into());
    }
    let mut bytes = vec![];
    file.take(32001)
        .read_to_end(&mut bytes)
        .map_err(|_| "Could not read the file.")?;
    if bytes.len() > 32000 || bytes.contains(&0) {
        return Err("Choose a UTF-8 text file no larger than 32 KB.".into());
    }
    let content = String::from_utf8(bytes).map_err(|_| "Choose a UTF-8 text file.")?;
    Ok(json!({"name":name,"content":content}))
}
pub fn read_selected(paths: Vec<PathBuf>) -> Result<Value, String> {
    if paths.len() > 4 {
        return Err("Choose up to four files at a time.".into());
    }
    let files = paths
        .iter()
        .map(|p| read(p))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(json!({"files":files}))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reads_text_without_returning_paths_and_refuses_binary_or_oversize() {
        let dir = std::env::temp_dir().join(format!("super-attachments-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("notes.md");
        std::fs::write(&path, "hello").unwrap();
        assert_eq!(
            read(&path).unwrap(),
            json!({"name":"notes.md","content":"hello"})
        );
        std::fs::write(&path, [0, 1]).unwrap();
        assert!(read(&path).is_err());
        std::fs::write(&path, vec![b'a'; 32001]).unwrap();
        assert!(read(&path).is_err());
        assert!(read_selected(vec![path; 5]).is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[cfg(target_os = "linux")]
    #[test]
    #[ignore = "requires a desktop display"]
    fn native_chooser_opens_and_returns_the_selected_file() {
        use gtk::prelude::*;
        gtk::init().unwrap();
        let parent = gtk::Window::new(gtk::WindowType::Toplevel);
        parent.set_title("Super attachment chooser test");
        parent.show_all();
        let path =
            std::env::temp_dir().join(format!("super-native-attachment-{}.md", std::process::id()));
        std::fs::write(&path, "chosen text").unwrap();
        let selected = choose_dialog(&parent, |dialog| {
            assert!(dialog.set_filename(&path));
            let dialog = dialog.clone();
            gtk::glib::timeout_add_local_once(std::time::Duration::from_millis(400), move || {
                assert!(dialog.is_visible());
                dialog.emit_by_name::<()>("response", &[&gtk::ffi::GTK_RESPONSE_ACCEPT]);
            });
        })
        .unwrap();
        assert_eq!(selected, vec![path.clone()]);
        assert_eq!(
            read_selected(selected).unwrap()["files"][0]["content"],
            "chosen text"
        );
        unsafe {
            parent.destroy();
        }
        std::fs::remove_file(path).unwrap();
    }
}
