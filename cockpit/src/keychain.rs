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
pub fn load(provider: &str) -> Result<Option<String>, String> {
    run("lookup", provider, None)
}
pub fn save(provider: &str, key: &str) -> Result<(), String> {
    run("store", provider, Some(key)).map(|_| ())
}
pub fn forget(provider: &str) -> Result<(), String> {
    run("clear", provider, None).map(|_| ())
}
