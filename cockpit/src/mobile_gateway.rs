//! Opt-in observation bridge. The child gets a projection reader, never a
//! runtime/control descriptor, queue, terminal, filesystem command or credential.
use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Write},
    path::PathBuf,
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::Instant,
};
type Observation = Arc<Mutex<Option<(Instant, Value)>>>;
static OBSERVATION: OnceLock<Observation> = OnceLock::new();
/// Set once the child is spawned; cleared when its reader loop ends.
static ALIVE: AtomicBool = AtomicBool::new(false);
/// The path only. The code itself is read on demand and never held here.
static PAIR_FILE: OnceLock<PathBuf> = OnceLock::new();
/// The child's stdin, shared with its reader thread.
///
/// The protocol is the child asking and this process answering, so the handle
/// lived inside that thread. Renewal is the one message that goes the other
/// way, so the handle is shared rather than owned — and only ever from here:
/// it is a pipe to a child this process spawned, reachable by nothing on the
/// network.
static INSTRUCT: OnceLock<Arc<Mutex<std::process::ChildStdin>>> = OnceLock::new();
/// The gateway's own window, in seconds. See `mobile/server.mjs`.
const PAIRING_LIFETIME: u64 = 600;

/// Four-character groups, four to a line.
///
/// Forty-eight hexadecimal characters read off a monitor and typed into a
/// phone is where pairing goes wrong. The companion strips the separators
/// again before sending, so this is presentation and nothing else.
fn grouped(code: &str) -> String {
    let quads: Vec<String> = code
        .as_bytes()
        .chunks(4)
        .map(|c| String::from_utf8_lossy(c).into_owned())
        .collect();
    quads
        .chunks(4)
        .map(|line| line.join(" "))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Who is currently paired, as the gateway last reported it.
///
/// The gateway owns the sessions; this only reads what it wrote beside the
/// pairing file. Identifiers there are derived from a session one way, so the
/// desktop can tell two devices apart without either token existing outside
/// the gateway. A file that is missing, torn or malformed is simply no list.
fn reported(pair_file: &std::path::Path) -> Value {
    let mut path = pair_file.as_os_str().to_os_string();
    path.push(".devices.json");
    let nothing = json!({"devices": [], "code_used": false});
    let Ok(raw) = std::fs::read_to_string(PathBuf::from(path)) else {
        return nothing;
    };
    if raw.len() > 64 * 1024 {
        return nothing;
    }
    let Ok(parsed) = serde_json::from_str::<Value>(&raw) else {
        return nothing;
    };
    if parsed["schema"] != "super-mobile-devices@1" {
        return nothing;
    }
    let Some(devices) = parsed["devices"].as_array() else {
        return nothing;
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    // The gateway sweeps on its own schedule; a desktop that has not been asked
    // for a snapshot in a while would otherwise show a session that has ended.
    let live: Vec<Value> = devices
        .iter()
        .filter(|d| d["expires"].as_u64().map_or(false, |e| e > now))
        .filter(|d| d["id"].as_str().map_or(false, |i| i.len() <= 32))
        .cloned()
        .collect();
    json!({"devices": live, "code_used": parsed["code_used"] == true})
}

/// The code as a scannable square, so nobody types forty-eight characters.
///
/// The payload is the code and nothing else — no URL, no scheme, no host. A
/// code that travelled inside a link would end up in a history, a log or a
/// handler's arguments, which is exactly what `mobile/server.mjs` refuses to
/// do with it. A phone that scans this reads a bare string.
///
/// Returned as a matrix rather than an image: the page draws the squares, so
/// no markup crosses the boundary and there is nothing to inject.
fn qr(code: &str) -> Value {
    let Ok(encoded) = qrcode::QrCode::new(code.as_bytes()) else {
        return Value::Null;
    };
    let modules: String = encoded
        .to_colors()
        .iter()
        .map(|c| if *c == qrcode::Color::Dark { '1' } else { '0' })
        .collect();
    json!({"width": encoded.width(), "modules": modules})
}

/// What this window is told about the phone companion.
///
/// The code is the owner's own, admitting a **read-only** view of the very
/// runtime this window already shows in full, so showing it here is not an
/// escalation — it is the same secret a person would otherwise `cat` out of
/// the file. It is read on demand, never cached, and refused unless it still
/// looks like a code this gateway minted.
pub fn status() -> Value {
    let Some(path) = PAIR_FILE.get() else {
        return json!({"enabled": false, "alive": false, "code": null, "reason": "not-enabled"});
    };
    let alive = ALIVE.load(Ordering::Relaxed);
    let state = reported(path);
    let devices = state["devices"].clone();
    let spent = state["code_used"] == true;
    let withheld = |reason: &str| {
        json!({"enabled": true, "alive": alive, "code": null, "reason": reason,
               "devices": state["devices"].clone()})
    };

    let Ok(age) = std::fs::metadata(path)
        .and_then(|m| m.modified())
        .map(|m| m.elapsed().map(|d| d.as_secs()).unwrap_or(0))
    else {
        return withheld("no-code");
    };
    if age >= PAIRING_LIFETIME {
        return withheld("expired");
    }
    let Ok(raw) = std::fs::read_to_string(path) else {
        return withheld("unreadable");
    };
    let code = raw.trim();
    // A file that is not a code this gateway wrote is not shown as one.
    if code.is_empty() || code.len() > 128 || !code.chars().all(|c| c.is_ascii_hexdigit()) {
        return withheld("unrecognised");
    }
    // One use. Offering a spent code, with a countdown beside it, is an
    // invitation to stand there typing something that cannot work.
    if spent {
        return withheld("used");
    }
    json!({
        "enabled": true,
        "alive": alive,
        "code": grouped(code),
        "qr": qr(code),
        "devices": devices,
        "seconds_left": PAIRING_LIFETIME - age,
        "reason": null,
    })
}
pub fn publish(frame: impl FnOnce() -> Value) {
    if let Some(shared) = OBSERVATION.get() {
        if let Ok(mut held) = shared.lock() {
            *held = Some((Instant::now(), frame()));
        }
    }
}
pub fn snapshot(held: &Option<(Instant, Value)>) -> Value {
    let Some((at, frame)) = held else {
        return json!({"available":false});
    };
    if at.elapsed().as_secs() >= 3 || frame["state"] != "live-local" {
        return json!({"available":false});
    }
    let mut projection = serde_json::Map::new();
    for name in [
        "workspaces",
        "goals",
        "lanes",
        "bots",
        "workers",
        "development_tasks",
        "development_attempts",
    ] {
        projection.insert(name.into(), frame["projection"][name].clone());
    }
    json!({"available":true,"world":frame["world"],"projection":projection})
}
/// Ask the companion for a fresh pairing code.
///
/// The code is generated in the child and written to the 0600 file this
/// process already reads it from; it never travels back up the pipe. Existing
/// sessions are untouched, which is the whole point — the alternative was
/// restarting the host, and that revokes every device to issue one code.
pub fn renew() -> Value {
    if !ALIVE.load(Ordering::Relaxed) {
        return json!({"ok": false, "reason": "not-running"});
    }
    let Some(input) = INSTRUCT.get() else {
        return json!({"ok": false, "reason": "not-enabled"});
    };
    let Ok(mut writer) = input.lock() else {
        return json!({"ok": false, "reason": "unavailable"});
    };
    if writeln!(writer, "{}", json!({"operation": "renew"})).is_err() {
        return json!({"ok": false, "reason": "unreachable"});
    }
    json!({"ok": true})
}
pub fn start() {
    let Ok(script) = std::env::var("SUPER_MOBILE_GATEWAY") else {
        return;
    };
    let Ok(node) = std::env::var("SUPER_MOBILE_NODE") else {
        eprintln!("mobile: SUPER_MOBILE_NODE must name Node's absolute path");
        return;
    };
    if !std::path::Path::new(&script).is_absolute() || !std::path::Path::new(&node).is_absolute() {
        eprintln!("mobile: absolute executable and script paths required");
        return;
    }
    let shared = OBSERVATION
        .get_or_init(|| Arc::new(Mutex::new(None)))
        .clone();
    let mut command = Command::new(node);
    command
        .arg(script)
        .env_clear()
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    for key in [
        "SUPER_MOBILE_PORT",
        "SUPER_MOBILE_ORIGIN",
        "SUPER_MOBILE_PAIR_FILE",
    ] {
        if let Ok(v) = std::env::var(key) {
            command.env(key, v);
        }
    }
    let mut child = match command.spawn() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("mobile: could not start observer: {e}");
            return;
        }
    };
    if let Ok(file) = std::env::var("SUPER_MOBILE_PAIR_FILE") {
        let _ = PAIR_FILE.set(PathBuf::from(file));
    }
    ALIVE.store(true, Ordering::Relaxed);
    let input = Arc::new(Mutex::new(child.stdin.take().unwrap()));
    let _ = INSTRUCT.set(input.clone());
    std::thread::spawn(move || {
        let mut output = BufReader::new(child.stdout.take().unwrap());
        loop {
            // Bound the line before allocation; the only recognized operation is read.
            let mut line = Vec::new();
            let mut limited = std::io::Read::take(&mut output, 256);
            if limited.read_until(b'\n', &mut line).is_err() || line.last() != Some(&b'\n') {
                break;
            }
            let Ok(request) = serde_json::from_slice::<Value>(&line) else {
                break;
            };
            if request["operation"] != "snapshot"
                || request["id"].as_str().map_or(true, |s| s.len() > 64)
            {
                break;
            }
            let result = shared
                .lock()
                .map(|held| snapshot(&held))
                .unwrap_or(json!({"available":false}));
            let sent = input
                .lock()
                .map(|mut writer| writeln!(writer, "{}", json!({"id":request["id"],"snapshot":result})).is_ok())
                .unwrap_or(false);
            if !sent {
                break;
            }
        }
        ALIVE.store(false, Ordering::Relaxed);
        let _ = child.kill();
        let _ = child.wait();
    });
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unavailable_and_old_observations_withdraw() {
        assert_eq!(snapshot(&None)["available"], false);
        assert_eq!(
            snapshot(&Some((
                Instant::now() - std::time::Duration::from_secs(4),
                json!({"state":"live-local"})
            )))["available"],
            false
        );
        assert_eq!(
            snapshot(&Some((Instant::now(), json!({"state":"reacquire"}))))["available"],
            false
        );
    }
    #[test]
    fn observation_does_not_export_arbitrary_projection_fields() {
        let s = snapshot(&Some((
            Instant::now(),
            json!({"state":"live-local","world":{"projection_epoch":"a"},"projection":{"development_tasks":{},"private":"secret"}}),
        )));
        assert_eq!(s["available"], true);
        assert!(s["projection"].get("private").is_none());
    }
}
