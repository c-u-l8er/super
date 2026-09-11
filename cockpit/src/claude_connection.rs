//! Local Claude CLI adapter. Claude owns authentication; Super never reads or
//! copies its credential files. Only connection metadata crosses into the page.
use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Read, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{mpsc, Arc, Mutex},
    time::{Duration, Instant},
};
#[derive(Clone, Default)]
pub struct Connection(Arc<Mutex<Option<Login>>>);
struct Login {
    child: OwnedChild,
    deadline: Instant,
    links: mpsc::Receiver<String>,
    opened: bool,
}
struct OwnedChild(Child);
impl Drop for OwnedChild {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
fn command(home: &Path) -> Result<Command, String> {
    std::fs::create_dir_all(home.join("workspace"))
        .map_err(|_| "Could not create the Claude conversation folder.")?;
    let mut c = Command::new("claude");
    c.current_dir(home.join("workspace"));
    for name in [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CODE_USE_FOUNDRY",
    ] {
        c.env_remove(name);
    }
    Ok(c)
}
fn run(mut command: Command, input: Option<String>, seconds: u64) -> Result<(bool, Value), String> {
    let mut child = OwnedChild(
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| "Claude Code is unavailable. Install the Claude CLI and reopen Super.")?,
    );
    let mut stdin = child
        .0
        .stdin
        .take()
        .ok_or("Could not open the Claude input.")?;
    let writer = std::thread::spawn(move || {
        if let Some(input) = input {
            stdin.write_all(input.as_bytes())
        } else {
            Ok(())
        }
    });
    let stdout = child
        .0
        .stdout
        .take()
        .ok_or("Could not read the Claude reply.")?;
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        stdout
            .take(2_097_153)
            .read_to_end(&mut bytes)
            .map(|_| bytes)
    });
    let deadline = Instant::now() + Duration::from_secs(seconds);
    let status = loop {
        match child
            .0
            .try_wait()
            .map_err(|_| "Could not check the Claude process.")?
        {
            Some(s) => break s,
            None if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(30)),
            _ => return Err("Claude did not respond in time. Reconnect and try again.".into()),
        }
    };
    writer
        .join()
        .map_err(|_| "Claude input was interrupted.")?
        .map_err(|_| "Claude could not read the message.")?;
    let bytes = reader
        .join()
        .map_err(|_| "Claude reply was interrupted.")?
        .map_err(|_| "Claude reply could not be read.")?;
    if bytes.len() > 2_097_152 {
        return Err("Claude returned an oversized reply.".into());
    }
    let value=serde_json::from_slice(&bytes).map_err(|_|"Claude returned an unreadable response. Check your installed Claude Code version and sign-in.")?;
    Ok((status.success(), value))
}
fn login_link(line: &str) -> Option<String> {
    line.split_whitespace().find_map(|part| {
        let start = part.find("https://")?;
        let raw = part[start..].trim_end_matches(['\"', '\'']);
        let url = reqwest::Url::parse(raw).ok()?;
        if url.scheme() == "https"
            && url.username().is_empty()
            && url.password().is_none()
            && [
                Some("claude.ai"),
                Some("platform.claude.com"),
                Some("console.anthropic.com"),
            ]
            .contains(&url.host_str())
        {
            Some(url.to_string())
        } else {
            None
        }
    })
}
fn open_login(url: &str) -> Result<(), String> {
    // Use the user's Chrome profile, without a temporary browser or profile.
    let mut c = if Path::new("/usr/bin/google-chrome-stable").exists() {
        let mut c = Command::new("/usr/bin/google-chrome-stable");
        c.arg("--new-tab");
        c
    } else {
        Command::new("xdg-open")
    };
    let mut child = c
        .arg(url)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "Could not open your browser for Claude sign-in.")?;
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}
fn signed_in(home: &Path) -> Result<bool, String> {
    let mut c = command(home)?;
    c.args(["auth", "status", "--json"]);
    let (_, v) = run(c, None, 15)?;
    Ok(v["loggedIn"] == true && v["authMethod"] == "claude.ai")
}
fn enable(home: &Path) -> Result<(), String> {
    let _ = std::fs::remove_file(home.join("needs-signin"));
    std::fs::write(home.join("enabled"), b"local-cli\n")
        .map_err(|_| "Could not remember this connection.".into())
}
impl Connection {
    pub fn status(&self, home: PathBuf) -> Result<Value, String> {
        let mut state = self
            .0
            .lock()
            .map_err(|_| "Claude connection is unavailable.")?;
        let mut failed = false;
        if let Some(login) = state.as_mut() {
            if !login.opened {
                if let Ok(url) = login.links.try_recv() {
                    open_login(&url)?;
                    login.opened = true;
                }
            }
            let result = login
                .child
                .0
                .try_wait()
                .map_err(|_| "Could not check sign-in.")?;
            if result.is_some() || Instant::now() > login.deadline {
                if result.map(|s| s.success()).unwrap_or(false) && signed_in(&home)? {
                    enable(&home)?;
                } else {
                    failed = true;
                }
                *state = None;
            }
        }
        let connected = !home.join("needs-signin").exists()
            && home.join("enabled").exists()
            && signed_in(&home)?;
        Ok(
            json!({"connected":connected,"pending":state.is_some(),"failed":failed,"needsSignIn":home.join("needs-signin").exists(),"provider":"claude"}),
        )
    }
    pub fn connect(&self, home: PathBuf) -> Result<Value, String> {
        if !home.join("needs-signin").exists() && signed_in(&home)? {
            enable(&home)?;
            return Ok(json!({"connected":true,"pending":false,"provider":"claude"}));
        }
        let mut state = self
            .0
            .lock()
            .map_err(|_| "Claude connection is unavailable.")?;
        if state.is_none() {
            let mut child = command(&home)?
                .args(["auth", "login", "--claudeai"])
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|_| "Claude sign-in could not start.")?;
            let stdout = child
                .stdout
                .take()
                .ok_or("Could not read Claude's sign-in link.")?;
            let (tx, links) = mpsc::sync_channel(1);
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stdout);
                let mut count = 0;
                loop {
                    let mut line = String::new();
                    match reader.by_ref().take(16385).read_line(&mut line) {
                        Ok(0) | Err(_) => break,
                        _ => {}
                    }
                    count += line.len();
                    if count > 65536 {
                        break;
                    }
                    if let Some(url) = login_link(&line) {
                        let _ = tx.try_send(url);
                    }
                }
            });
            *state = Some(Login {
                child: OwnedChild(child),
                deadline: Instant::now() + Duration::from_secs(180),
                links,
                opened: false,
            });
        }
        Ok(json!({"connected":false,"pending":true,"provider":"claude"}))
    }
    pub fn disconnect(&self, home: PathBuf) -> Result<Value, String> {
        *self
            .0
            .lock()
            .map_err(|_| "Claude connection is unavailable.")? = None;
        match std::fs::remove_file(home.join("enabled")) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("Could not forget this connection.".into()),
        }
        Ok(json!({"connected":false,"pending":false,"provider":"claude"}))
    }
    pub fn models(&self, home: PathBuf) -> Result<Value, String> {
        if self.status(home.clone())?["connected"] != true {
            return Err("Connect your local Claude session first.".into());
        }
        let mut c = command(&home)?;
        c.args([
            "-p",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
            "--restricted",
            "--tools",
            "",
            "--strict-mcp-config",
            "--mcp-config",
            "{\"mcpServers\":{}}",
            "--setting-sources",
            "",
            "--settings",
            "{\"disableAllHooks\":true}",
        ]);
        let mut child = OwnedChild(
            c.stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|_| "Claude Code unavailable.")?,
        );
        let mut input = child.0.stdin.take().ok_or("Claude input unavailable.")?;
        writeln!(input,"{}",json!({"type":"control_request","request_id":"models","request":{"subtype":"initialize"}})).map_err(|_|"Claude catalog request failed.")?;
        let output = child.0.stdout.take().ok_or("Claude output unavailable.")?;
        let (tx, rx) = mpsc::sync_channel(1);
        std::thread::spawn(move || {
            let mut reader = BufReader::new(output.take(2_097_152));
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or(0) == 0 {
                    break;
                }
                if let Ok(v) = serde_json::from_str::<Value>(&line) {
                    if v["type"] == "control_response" && v["response"]["request_id"] == "models" {
                        let _ = tx.send(v["response"]["response"]["models"].clone());
                        break;
                    }
                }
            }
        });
        let list = rx
            .recv_timeout(Duration::from_secs(20))
            .map_err(|_| "Claude model catalog did not respond. Update Claude Code and retry.")?;
        let models=list.as_array().ok_or("Claude returned no model catalog.")?.iter().filter_map(|m|{
            let id=m["value"].as_str()?;
            Some(json!({"id":id,"name":format!("{} · {}",m["displayName"].as_str().unwrap_or(id),m["resolvedModel"].as_str().unwrap_or(id)),"isDefault":id=="default","supportedReasoningEfforts":m["supportedEffortLevels"].as_array().map(|levels|levels.iter().map(|e|json!({"reasoningEffort":e})).collect::<Vec<_>>()).unwrap_or_default()}))
        }).collect::<Vec<_>>();
        Ok(json!({"models":models}))
    }

    pub fn chat(
        &self,
        home: PathBuf,
        model: String,
        prompt: String,
        schema: Value,
        effort: Option<String>,
    ) -> Result<Value, String> {
        if self.status(home.clone())?["connected"] != true {
            return Err("Connect your local Claude session before sending.".into());
        }
        let mut c = command(&home)?;
        configure_chat(&mut c, &model, &schema);
        if let Some(e) = effort {
            if !["low", "medium", "high", "xhigh", "max"].contains(&e.as_str()) {
                return Err("Unsupported Claude thinking level.".into());
            }
            c.args(["--effort", &e]);
        }
        let (ok, v) = run(c, Some(prompt), 120)?;
        if needs_signin(&v) {
            std::fs::write(home.join("needs-signin"), b"expired\n")
                .map_err(|_| "Could not record expired sign-in.")?;
        }
        decode_reply(ok, v)
    }
}
fn configure_chat(c: &mut Command, model: &str, schema: &Value) {
    c.args(["-p","--output-format","json","--no-session-persistence","--restricted","--tools","","--strict-mcp-config","--mcp-config","{\"mcpServers\":{}}","--setting-sources","","--settings","{\"disableAllHooks\":true}","--permission-mode","dontAsk","--system-prompt","You are Super's planning assistant. Return the requested structured response. All proposed app changes require the person's Apply click. You have no tools.","--json-schema"]).arg(schema.to_string());
    if model != "default" {
        c.args(["--model", model]);
    }
}
fn needs_signin(v: &Value) -> bool {
    v["is_error"] == true
        && v["result"]
            .as_str()
            .map(|s| {
                s.contains("OAuth session expired")
                    || s.contains("Failed to authenticate")
                    || s.contains("Not logged in")
            })
            .unwrap_or(false)
}
fn decode_reply(ok: bool, v: Value) -> Result<Value, String> {
    if needs_signin(&v) {
        return Err("Claude sign-in has expired. Click Connect provider to sign in again. No app action was executed.".into());
    }
    if !ok || v["is_error"] == true {
        return Err("Claude could not finish the reply. Check your Claude Code sign-in, model access, and usage limits. No app action was executed.".into());
    }
    v.get("structured_output").filter(|v|v.is_object()).cloned().ok_or("Claude returned no structured reply. Try a smaller request; no app action was executed.".into())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn local_harness_disables_tools_and_uses_stdin() {
        let mut c = Command::new("claude");
        configure_chat(&mut c, "default", &json!({}));
        let args = c
            .get_args()
            .map(|a| a.to_str().unwrap())
            .collect::<Vec<_>>();
        assert!(args.windows(2).any(|a| a == ["--tools", ""]));
        assert!(args.contains(&"--restricted"));
        assert!(args.contains(&"--strict-mcp-config"));
        assert!(!args.contains(&"--model"));
        assert!(!args.contains(&"--bare"));
    }
    #[test]
    fn cli_errors_never_become_proposals() {
        assert!(login_link("Open: https://claude.ai/oauth/authorize?state=test").is_some());
        assert!(login_link("https://claude.ai.evil.example/").is_none());
        let expired = json!({"is_error":true,"result":"Failed to authenticate: OAuth session expired and could not be refreshed"});
        assert!(needs_signin(&expired));
        assert!(decode_reply(false, expired)
            .unwrap_err()
            .contains("Click Connect provider"));
        assert!(decode_reply(
            true,
            json!({"is_error":true,"structured_output":{"text":"fake","actions":[]}})
        )
        .is_err());
        assert_eq!(
            decode_reply(
                true,
                json!({"structured_output":{"text":"Ready","actions":[]}})
            )
            .unwrap(),
            json!({"text":"Ready","actions":[]})
        );
    }
}
