//! Linux Secret Service storage scoped to Super and one provider. Secrets are
//! passed on stdin, never in command arguments, and never returned to the page.
use std::{
    io::{Read, Write},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};
fn supported(provider: &str) -> Result<(), String> {
    if ["openai", "anthropic"].contains(&provider) {
        Ok(())
    } else {
        Err("This provider does not use a saved API key.".into())
    }
}
#[cfg(target_os = "linux")]
fn run(operation: &str, provider: &str, secret: Option<&str>) -> Result<Option<String>, String> {
    supported(provider)?;
    let mut command = Command::new("secret-tool");
    command.arg(operation);
    if operation == "store" {
        command.arg("--label=Super provider API key");
    }
    command.args([
        "application",
        "com.computedriven.super.cockpit",
        "provider",
        provider,
    ]);
    let mut child = command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()
        .map_err(|_| "The system keychain helper is unavailable. Install secret-tool or use a session-only key.")?;
    if let Some(mut stdin) = child.stdin.take() {
        if let Some(secret) = secret {
            stdin
                .write_all(secret.as_bytes())
                .map_err(|_| "Could not pass the key to the system keychain.")?;
        }
    }
    let deadline = Instant::now() + Duration::from_secs(30);
    let status = loop {
        match child
            .try_wait()
            .map_err(|_| "Could not check the system keychain.")?
        {
            Some(status) => break status,
            None if Instant::now() < deadline => thread::sleep(Duration::from_millis(25)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("The keychain did not respond. Unlock it and try again, or use a session-only key.".into());
            }
        }
    };
    if !status.success() {
        if operation == "lookup" && status.code() == Some(1) {
            return Ok(None);
        }
        return Err(
            "The system keychain could not complete this operation. Unlock it and try again."
                .into(),
        );
    }
    let mut result = String::new();
    if let Some(out) = child.stdout.take() {
        out.take(4098)
            .read_to_string(&mut result)
            .map_err(|_| "Could not read the keychain result.")?;
    }
    if result.len() > 4097 {
        return Err("The saved key exceeds the supported size.".into());
    }
    Ok(Some(result.trim_end_matches('\n').into()))
}
/// T29b1 item 5 (amendment 2): on macOS the login Keychain through `/usr/bin/security`, a CLI as `secret-tool` is.
/// The service is Linux's `application` attribute and the account the provider. The secret NEVER enters argv: a store is
/// one `add-generic-password` line that `security -i` reads from stdin (it honours double quotes and `\"`, measured), and
/// a lookup reads `find-generic-password -w`'s stdout. A key the quoted line cannot carry safely is refused by name.
#[cfg(target_os = "macos")]
fn run(operation: &str, provider: &str, secret: Option<&str>) -> Result<Option<String>, String> {
    supported(provider)?;
    const SERVICE: &str = "com.computedriven.super.cockpit";
    let mut command = Command::new(security_program());
    let mut input = String::new();
    match operation {
        "store" => {
            let secret = secret.ok_or("There is no key to save.")?;
            if secret.is_empty()
                || secret.len() > 4096
                || !secret.bytes().all(|b| (0x21..=0x7e).contains(&b) && b != b'"' && b != b'\\')
            {
                return Err("This key has characters the macOS keychain helper cannot take safely. Use a session-only key.".into());
            }
            command.arg("-i");
            input = format!(
                "add-generic-password -U -a \"{provider}\" -s \"{SERVICE}\" -l \"Super provider API key\" -w \"{secret}\"\n"
            );
        }
        "lookup" => {
            command.args(["find-generic-password", "-a", provider, "-s", SERVICE, "-w"]);
        }
        "clear" => {
            command.args(["delete-generic-password", "-a", provider, "-s", SERVICE]);
        }
        _ => return Err("Unknown keychain operation.".into()),
    }
    let spawn_guard = super_host::fdpass::spawn_guard();
    let child = command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn();
    drop(spawn_guard);
    let mut child = child.map_err(|_| "The system keychain helper (security) is unavailable. Use a session-only key.")?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(input.as_bytes())
            .map_err(|_| "Could not pass the key to the system keychain.")?;
    }
    let deadline = Instant::now() + Duration::from_secs(30);
    let status = loop {
        match child
            .try_wait()
            .map_err(|_| "Could not check the system keychain.")?
        {
            Some(status) => break status,
            None if Instant::now() < deadline => thread::sleep(Duration::from_millis(25)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("The keychain did not respond. Unlock it and try again, or use a session-only key.".into());
            }
        }
    };
    if !status.success() {
        if operation != "store" && status.code() == Some(44) {
            return Ok(None);
        }
        return Err("The system keychain could not complete this operation (security). Unlock it and try again.".into());
    }
    if operation != "lookup" {
        return Ok(None);
    }
    let mut result = String::new();
    if let Some(out) = child.stdout.take() {
        out.take(4098)
            .read_to_string(&mut result)
            .map_err(|_| "Could not read the keychain result.")?;
    }
    if result.len() > 4097 {
        return Err("The saved key exceeds the supported size.".into());
    }
    Ok(Some(result.trim_end_matches('\n').into()))
}
/// The program behind macOS's `run`: `/usr/bin/security`, or a stand-in a test names (test builds only; amendment 2).
#[cfg(target_os = "macos")]
fn security_program() -> std::path::PathBuf {
    #[cfg(test)]
    if let Some(p) = TEST_SECURITY.lock().unwrap_or_else(|e| e.into_inner()).clone() {
        return p;
    }
    std::path::PathBuf::from("/usr/bin/security")
}
#[cfg(all(test, target_os = "macos"))]
static TEST_SECURITY: std::sync::Mutex<Option<std::path::PathBuf>> = std::sync::Mutex::new(None);
pub fn load(provider: &str) -> Result<Option<String>, String> {
    run("lookup", provider, None)
}
pub fn save(provider: &str, key: &str) -> Result<(), String> {
    run("store", provider, Some(key)).map(|_| ())
}
pub fn forget(provider: &str) -> Result<(), String> {
    run("clear", provider, None).map(|_| ())
}
