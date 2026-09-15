//! Operator-requested Android emulator screenshots. No commands or executable paths
//! come from the webview; physical devices are deliberately excluded.
use serde_json::{json, Value};
use std::{io::Read, path::PathBuf, process::{Command, Stdio}, time::{Duration, Instant}};

fn adb_path() -> Result<PathBuf, String> {
    let mut candidates = Vec::new();
    for name in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
        if let Some(root) = std::env::var_os(name) { candidates.push(PathBuf::from(root).join("platform-tools/adb")); }
    }
    if let Some(home) = std::env::var_os("HOME") {
        candidates.push(PathBuf::from(&home).join(".local/opt/android-sdk/platform-tools/adb"));
        candidates.push(PathBuf::from(home).join("Android/Sdk/platform-tools/adb"));
    }
    candidates.push(PathBuf::from("/usr/bin/adb"));
    candidates.into_iter().find(|p| p.is_file()).ok_or("Android SDK is unavailable. Install Android platform tools to capture an emulator.".into())
}
fn serial_valid(s: &str) -> bool {
    s.strip_prefix("emulator-").is_some_and(|n| !n.is_empty() && n.len() <= 5 && n.bytes().all(|b| b.is_ascii_digit()))
}
fn devices(output: &str) -> Vec<Value> {
    output.lines().filter_map(|line| {
        let mut words = line.split_whitespace();
        let serial = words.next()?;
        if !serial_valid(serial) || words.next()? != "device" { return None; }
        let model = words.find_map(|w| w.strip_prefix("model:")).unwrap_or("Android emulator").replace('_', " ");
        Some(json!({"serial":serial,"model":model}))
    }).collect()
}
fn run(args: &[&str], limit: usize) -> Result<Vec<u8>, String> {
    let mut child = Command::new(adb_path()?).args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().map_err(|_| "Could not start Android platform tools.")?;
    let stdout = child.stdout.take().ok_or("Android output unavailable.")?;
    let reader = std::thread::spawn(move || { let mut bytes = Vec::new(); stdout.take((limit + 1) as u64).read_to_end(&mut bytes).map(|_| bytes) });
    let start = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Ok(status),
            Ok(None) if start.elapsed() < Duration::from_secs(10) => std::thread::sleep(Duration::from_millis(25)),
            _ => { let _ = child.kill(); let _ = child.wait(); break Err("Android capture timed out or disconnected."); }
        }
    };
    let bytes = reader.join().map_err(|_| "Could not read Android output.")?.map_err(|_| "Could not read Android output.")?;
    if !status?.success() { return Err("Android command failed. Check that the selected emulator is running and unlocked.".into()); }
    if bytes.len() > limit { return Err("Android capture exceeds the supported size.".into()); }
    Ok(bytes)
}
fn text(args: &[&str], limit: usize) -> Result<String, String> {
    String::from_utf8(run(args, limit)?).map(|s| s.trim().to_string()).map_err(|_| "Invalid Android response.".into())
}
fn activity(serial: &str) -> Result<String, String> {
    let output = text(&["-s", serial, "shell", "dumpsys", "activity", "activities"], 1_000_000)?;
    output.lines().find(|line| line.contains("mResumedActivity:") || line.contains("topResumedActivity="))
        .and_then(|line| line.split_whitespace().find(|s| s.contains('/') && !s.contains('{')))
        .map(|s| s.trim_end_matches('}').to_owned()).filter(|s| s.len() <= 300)
        .ok_or("No foreground app was identified. Unlock the emulator and open the screen to capture.".into())
}
pub fn list() -> Result<Value, String> { Ok(json!({"devices":devices(&text(&["devices", "-l"], 32_000)?)})) }
pub fn capture(mut request: Value) -> Result<Value, String> {
    let serial = request["serial"].as_str().filter(|s| serial_valid(s)).ok_or("Choose a running Android emulator.")?.to_owned();
    // Validate storage identity before reading the device; caller cannot submit origin metadata.
    let mut query = request.clone(); query["operation"] = json!("list"); crate::screenshots::request(query)?;
    if !["before", "after"].iter().any(|s| request["side"] == *s) { return Err("Choose Before or After.".into()); }
    if !list()?["devices"].as_array().unwrap().iter().any(|d| d["serial"] == serial) { return Err("Selected emulator is no longer available. Refresh emulators.".into()); }
    let prop = |name| text(&["-s", &serial, "shell", "getprop", name], 4096);
    if prop("ro.kernel.qemu")? != "1" { return Err("Only Android emulators can be captured here.".into()); }
    if prop("sys.boot_completed")? != "1" { return Err("Android is still starting. Wait until the app is visible.".into()); }
    let model = prop("ro.product.model")?;
    let android = prop("ro.build.version.release")?;
    let foreground = activity(&serial)?;
    let bytes = run(&["-s", &serial, "exec-out", "screencap", "-p"], 2_000_000)?;
    if foreground != activity(&serial)? { return Err("The foreground app changed during capture. Open the intended screen and retry.".into()); }
    use base64::Engine;
    request["operation"] = json!("save");
    request["data"] = json!(format!("data:image/png;base64,{}", base64::engine::general_purpose::STANDARD.encode(bytes)));
    crate::screenshots::save_captured(request, json!({"kind":"android-emulator","serial":serial,"model":model,"android":android,"activity":foreground,"source_verified":false,"surface":"full-display"}))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn discovery_excludes_physical_offline_and_invalid_targets() {
        let found = devices("List of devices attached\nemulator-5554 device product:sdk model:Pixel_7 transport_id:1\nphone123 device model:Phone\nemulator-5556 offline\nemulator-5558 unauthorized\nemulator-5554;id device\n");
        assert_eq!(found, vec![json!({"serial":"emulator-5554","model":"Pixel 7"})]);
        for value in ["", "emulator-", "emulator-5554;id", "127.0.0.1:5555", "emulator-123456", "device"] { assert!(!serial_valid(value)); }
    }
}
