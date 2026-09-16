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
pub struct Connection(Arc<Mutex<Option<Login>>>, Arc<Mutex<ReplyState>>);
#[derive(Default)]
struct ReplyState {
    id: String,
    active: bool,
    cancelled: bool,
    text: String,
    bytes: usize,
    /// Reasoning MAGNITUDE only. The CLI already redacts the content — a
    /// `thinking_delta` carries `"thinking":""` and an `estimated_tokens`
    /// count — so there is nothing here to leak even by accident.
    thinking: u64,
    /// Private accumulator for the structured reply as it streams. NEVER
    /// exposed: `reply_status` does not carry it and nothing returns it. Only
    /// the decoded `text` field is lifted out of it into `text` above, so
    /// proposed actions and every other tool argument stay on this side.
    partial: String,
    phase: String,
}
/// The public `text` field of a structured reply that has not finished
/// arriving, and nothing else from it.
///
/// `--json-schema` makes the whole reply one tool argument, so a model that
/// writes straight into the schema emits `input_json_delta` and no
/// `text_delta` at all — which is a reply streaming past a page that is shown
/// none of it. Forwarding the raw partial JSON would put proposed file
/// contents and every other action argument across the boundary, so the
/// prefix is decoded here and only the prose crosses, exactly as before.
fn structured_prefix(partial: &str) -> Option<String> {
    let rest = partial.trim_start().strip_prefix('{')?.trim_start();
    let rest = rest.strip_prefix("\"text\"")?.trim_start();
    let rest = rest.strip_prefix(':')?.trim_start();
    let rest = rest.strip_prefix('"')?;
    let mut encoded = String::new();
    let bytes: Vec<char> = rest.chars().collect();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            '"' => break,
            '\\' => {
                let size = if bytes.get(i + 1) == Some(&'u') { 6 } else { 2 };
                if i + size > bytes.len() { break; }
                encoded.extend(&bytes[i..i + size]);
                i += size;
            }
            c => { encoded.push(c); i += 1; }
        }
    }
    serde_json::from_str::<String>(&format!("\"{encoded}\"")).ok()
}
struct ReplyGuard(Arc<Mutex<ReplyState>>);
impl Drop for ReplyGuard {
    fn drop(&mut self) { if let Ok(mut state) = self.0.lock() { state.active = false; } }
}
fn observe_reply(state: &mut ReplyState, event: &Value) {
    // Only public assistant text crosses into the page. Never forward raw events,
    // reasoning, signatures, tool arguments, or provider connection metadata.
    let delta = &event["event"]["delta"];
    if event["type"] == "stream_event" && delta["type"] == "text_delta" {
        if let Some(text) = delta["text"].as_str() {
            state.bytes = state.bytes.saturating_add(text.len());
            if state.text.len() + text.len() <= 65536 { state.text.push_str(text); }
            state.phase = "Receiving reply".into();
        }
    } else if event["type"] == "stream_event" && delta["type"] == "input_json_delta" {
        // Measured 2026-09-16: a request that produced three file proposals
        // emitted NO text_delta at all — the model wrote directly into the
        // schema — so the page sat on "Preparing reply" for the 106 s it took
        // to write the answer. The raw argument never crosses; only its
        // decoded `text` field does.
        if let Some(chunk) = delta["partial_json"].as_str() {
            if state.partial.len() + chunk.len() <= 262_144 { state.partial.push_str(chunk); }
            if let Some(prose) = structured_prefix(&state.partial) {
                if prose.len() > state.text.len() && prose.len() <= 65536 {
                    state.bytes = state.bytes.saturating_add(prose.len() - state.text.len());
                    state.text = prose;
                    state.phase = "Receiving reply".into();
                }
            }
        }
    } else if event["type"] == "stream_event" && delta["type"] == "thinking_delta" {
        // Measured 2026-09-16 with opus[1m] at xhigh on a request shaped like
        // real work: 170 of 262 seconds elapsed before the first visible token,
        // and for all of it this function had no branch to take — so `phase`
        // sat on whatever `content_block_start` left and `bytes` stayed 0,
        // which the page renders as one frozen line. The count is cumulative,
        // so take the larger value rather than adding.
        if let Some(tokens) = delta["estimated_tokens"].as_u64() {
            state.thinking = state.thinking.max(tokens);
        }
        if state.text.is_empty() {
            state.phase = format!("Thinking · {} tokens", state.thinking);
        }
    } else if event["type"] == "system" && event["subtype"] == "init" {
        state.phase = "Provider started".into();
    } else if event["type"] == "stream_event" && event["event"]["type"] == "content_block_start" {
        state.phase = "Preparing reply".into();
    } else if event["type"] == "result" {
        state.phase = "Checking reply".into();
    }
}
fn run_reply(mut command: Command, input: String, state: Arc<Mutex<ReplyState>>, seconds: u64) -> Result<(bool, Value), String> {
    let _guard = ReplyGuard(state.clone());
    let mut child = OwnedChild(command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null())
        .spawn().map_err(|_| "Claude Code is unavailable. Install the Claude CLI and reopen Super.")?);
    let mut stdin = child.0.stdin.take().ok_or("Claude input unavailable.")?;
    std::thread::spawn(move || { let _ = stdin.write_all(input.as_bytes()); });
    let stdout = child.0.stdout.take().ok_or("Claude output unavailable.")?;
    let (tx, rx) = mpsc::sync_channel(16);
    std::thread::spawn(move || {
        let mut reader = BufReader::new(stdout.take(8_388_609));
        loop {
            let mut line = String::new();
            match reader.by_ref().take(2_097_153).read_line(&mut line) {
                Ok(0) => break,
                Ok(_) => { if tx.send(Ok(line)).is_err() { break; } }
                Err(_) => { let _ = tx.send(Err("Claude reply could not be read.")); break; }
            }
        }
    });
    let deadline = Instant::now() + Duration::from_secs(seconds);
    let mut total = 0;
    let mut result = None;
    loop {
        if state.lock().map_err(|_| "Reply status unavailable.")?.cancelled {
            return Err("Reply cancelled. Your draft is restored. No app action was executed.".into());
        }
        if Instant::now() >= deadline { return Err("Claude did not respond in time. Your draft is restored; try again.".into()); }
        match rx.recv_timeout(Duration::from_millis(30)) {
            Ok(line) => {
                let line = line?;
                total += line.len();
                if line.len() > 2_097_152 || total > 8_388_608 { return Err("Claude returned an oversized reply.".into()); }
                let event: Value = serde_json::from_str(&line).map_err(|_| "Claude returned an unreadable response.")?;
                observe_reply(&mut *state.lock().map_err(|_| "Reply status unavailable.")?, &event);
                if event["type"] == "result" { result = Some(event); }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                if let Some(status) = child.0.try_wait().map_err(|_| "Claude process unavailable.")? {
                    return result.map(|v| (status.success(), v)).ok_or("Claude ended without a reply. Your draft is restored.".into());
                }
                std::thread::sleep(Duration::from_millis(30));
            }
        }
    }
}
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
                Some("claude.com"),
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
/// What one look at the connection means. `connected` and `needs_sign_in` are
/// what the page is told; `clear_latch` says the remembered `needs-signin` file
/// is stale and should be deleted; `start_login` says a browser sign-in is the
/// only way forward.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Decision {
    connected: bool,
    needs_sign_in: bool,
    clear_latch: bool,
    start_login: bool,
}
/// Reality outranks memory. `needs-signin` is only a latch written by a failed
/// reply; it must never outvote a locally signed-in CLI, or the person is sent
/// through a browser login they do not need. `enabled` still gates `connected`,
/// so clearing a stale latch cannot resurrect a provider the person forgot.
/// Pure on purpose: the whole latch decision is unit-testable without a network
/// or a real `claude` binary.
fn decide(enabled: bool, latched: bool, signed_in: bool) -> Decision {
    Decision {
        connected: enabled && signed_in,
        needs_sign_in: latched && !signed_in,
        clear_latch: latched && signed_in,
        start_login: !signed_in,
    }
}
impl Connection {
    pub fn reply_status(&self, id: &str) -> Result<Value, String> {
        let state = self.1.lock().map_err(|_| "Reply status unavailable.")?;
        if state.id != id { return Ok(json!({"active":false})); }
        Ok(json!({"active":state.active,"cancelled":state.cancelled,"received_bytes":state.bytes,"thinking_tokens":state.thinking,"text":state.text,"phase":state.phase}))
    }
    pub fn cancel_reply(&self, id: &str) -> Result<Value, String> {
        let mut state = self.1.lock().map_err(|_| "Reply status unavailable.")?;
        if state.id != id || !state.active { return Err("This reply is no longer running.".into()); }
        state.cancelled = true;
        Ok(json!({"cancelled":true}))
    }

    pub fn status(&self, home: PathBuf) -> Result<Value, String> {
        let mut state = self
            .0
            .lock()
            .map_err(|_| "Claude connection is unavailable.")?;
        let mut failed = false;
        // At most one `claude auth status` per call: the pending-login branch
        // records what it learned so the decision below reuses it.
        let mut probed: Option<bool> = None;
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
                if result.map(|s| s.success()).unwrap_or(false) {
                    let now = signed_in(&home)?;
                    probed = Some(now);
                    if now {
                        enable(&home)?;
                    } else {
                        failed = true;
                    }
                } else {
                    failed = true;
                }
                *state = None;
            }
        }
        // Read the files after the login branch, which may have just written
        // `enabled` and removed the latch.
        let enabled = home.join("enabled").exists();
        let latched = home.join("needs-signin").exists();
        let is_signed_in = match probed {
            Some(known) => known,
            // Only ask the CLI when a remembered connection could be reported
            // as connected. With no `enabled` file the answer cannot change the
            // report, so an unknown CLI counts as unsigned and no process runs.
            None if enabled => signed_in(&home)?,
            None => false,
        };
        let decision = decide(enabled, latched, is_signed_in);
        if decision.clear_latch {
            // Self-heal: the latch is stale, the CLI was signed back in
            // elsewhere. Best effort; a failure here is re-healed next call.
            let _ = std::fs::remove_file(home.join("needs-signin"));
        }
        Ok(
            json!({"connected":decision.connected,"pending":state.is_some(),"failed":failed,"needsSignIn":decision.needs_sign_in,"provider":"claude"}),
        )
    }
    pub fn connect(&self, home: PathBuf) -> Result<Value, String> {
        // Ask the CLI before trusting the latch. Connecting is the act of
        // remembering, so `enabled` is true by construction here; `enable()`
        // writes it and removes any stale `needs-signin`.
        let decision = decide(true, home.join("needs-signin").exists(), signed_in(&home)?);
        if !decision.start_login {
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
        request_id: Option<String>,
        images: Vec<String>,
    ) -> Result<Value, String> {
        if self.status(home.clone())?["connected"] != true {
            return Err("Connect your local Claude session before sending.".into());
        }
        let mut c = command(&home)?;
        configure_chat(&mut c, &model, &schema);
        let mut budget = reply_budget(None);
        if let Some(e) = effort {
            if !["low", "medium", "high", "xhigh", "max"].contains(&e.as_str()) {
                return Err("Unsupported Claude thinking level.".into());
            }
            budget = reply_budget(Some(e.as_str()));
            c.args(["--effort", &e]);
        }
        let id = request_id.ok_or("Reply identity required.")?;
        if id.is_empty() || id.len() > 128 { return Err("Invalid reply identity.".into()); }
        *self.1.lock().map_err(|_| "Reply status unavailable.")? = ReplyState {
            id, active: true, phase: "Waiting for provider".into(), ..ReplyState::default()
        };
        let input = if images.is_empty() { prompt } else {
            c.args(["--input-format", "stream-json"]);
            format!("{}\n", json!({"type":"user","message":{"role":"user","content":crate::bots::image_content("anthropic", &prompt, &images)},"parent_tool_use_id":null}))
        };
        let (ok, v) = run_reply(c, input, self.1.clone(), budget)?;
        if needs_signin(&v) {
            std::fs::write(home.join("needs-signin"), b"expired\n")
                .map_err(|_| "Could not record expired sign-in.")?;
        }
        decode_reply(ok, v)
    }
}
/// How long one reply may take, by the reasoning level the person chose.
///
/// Measured 2026-09-16, opus[1m], the CLI flags `configure_chat` builds, on a
/// request shaped like real work (two sources attached, a complete replacement
/// file requested): 170.3s of reasoning before the first visible token, result
/// at 262.5s. Two larger requests — one at xhigh, one at high — ran past the
/// flat 300s budget and the person lost the whole turn to "did not respond in
/// time". Extended reasoning is the thing the higher levels are for; a budget
/// that cannot contain it makes them unusable. The person can still stop a
/// reply at any point with Cancel, so this is a ceiling, not a wait.
fn reply_budget(effort: Option<&str>) -> u64 {
    match effort {
        Some("max") => 1800,
        Some("xhigh") => 900,
        Some("high") => 600,
        _ => 300,
    }
}
fn configure_chat(c: &mut Command, model: &str, schema: &Value) {
    c.args(["-p","--output-format","stream-json","--verbose","--include-partial-messages","--no-session-persistence","--restricted","--tools","","--strict-mcp-config","--mcp-config","{\"mcpServers\":{}}","--setting-sources","","--settings","{\"disableAllHooks\":true}","--permission-mode","dontAsk","--system-prompt","You are Super's planning assistant. Return the requested structured response. All proposed app changes require the person's Apply click. You have no tools.","--json-schema"]).arg(schema.to_string());
    if model != "default" {
        c.args(["--model", model]);
    }
}
fn failure_text(v: &Value) -> String {
    let mut parts = vec![v["result"].as_str().unwrap_or("")];
    if let Some(errors) = v["errors"].as_array() { parts.extend(errors.iter().take(8).filter_map(Value::as_str)); }
    parts.join("\n")
}
fn needs_signin(v: &Value) -> bool {
    let text = failure_text(v);
    (v["is_error"] == true || v["subtype"] == "error_during_execution")
        && ["OAuth session expired", "Failed to authenticate", "Not logged in"].iter().any(|s| text.contains(s))
}

fn decode_reply(ok: bool, v: Value) -> Result<Value, String> {
    if needs_signin(&v) {
        return Err("Claude sign-in has expired. Click Connect provider to sign in again. No app action was executed.".into());
    }
    if v["is_error"] == true && v["result"].as_str().is_some_and(|s| {
        s.contains("You've reached your") && s.contains("limit")
    }) {
        return Err("Claude's model usage limit has been reached. Your sign-in is still connected. Wait for capacity to reset, choose another available model, or manage usage in Claude. Your draft is restored; no app action was executed.".into());
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
    fn model_capacity_failure_is_not_expired_authentication() {
        let reply = json!({"is_error":true,"result":"You've reached your Fable limit. Switch to another model, or manage usage credits at claude.ai/settings/usage?from=cc_cli_limit_message, to continue."});
        assert!(!needs_signin(&reply));
        let error = decode_reply(false, reply).unwrap_err();
        assert!(error.contains("model usage limit"));
        assert!(error.contains("sign-in is still connected"));
        assert!(!error.contains("Connect provider"));
        let success = json!({"is_error":false,"result":"You've reached your Fable limit","structured_output":{"text":"quoted example"}});
        assert_eq!(decode_reply(true, success).unwrap()["text"], "quoted example");
        let structured_expired = json!({"subtype":"error_during_execution","errors":["Failed to authenticate: OAuth session expired"]});
        assert!(needs_signin(&structured_expired));
        assert!(decode_reply(false, structured_expired).unwrap_err().contains("sign-in has expired"));
        let expired = json!({"is_error":true,"result":"Failed to authenticate: OAuth session expired"});
        assert!(decode_reply(false, expired).unwrap_err().contains("sign-in has expired"));
    }
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
    #[test]
    fn stale_latch_yields_to_a_signed_in_cli() {
        // Signed back in outside Super: connected, the latch is dropped, and no
        // browser sign-in is started. This is "why do I have to keep connecting".
        let healed = decide(true, true, true);
        assert!(healed.connected);
        assert!(healed.clear_latch);
        assert!(!healed.start_login);
        assert!(!healed.needs_sign_in);
        // Latch and a genuinely signed-out CLI: still needs a sign-in, nothing
        // is cleared, and the browser flow is the only way forward.
        let expired = decide(true, true, false);
        assert!(!expired.connected);
        assert!(expired.needs_sign_in);
        assert!(!expired.clear_latch);
        assert!(expired.start_login);
        // Forgotten connection: a signed-in CLI does not resurrect it, with or
        // without a latch to clear.
        let forgotten = decide(false, false, true);
        assert!(!forgotten.connected);
        assert!(!forgotten.needs_sign_in);
        let forgotten_latched = decide(false, true, true);
        assert!(!forgotten_latched.connected);
        assert!(forgotten_latched.clear_latch);
        // Ordinary connected state: nothing to clear, nothing to report.
        let steady = decide(true, false, true);
        assert_eq!(
            steady,
            Decision { connected: true, needs_sign_in: false, clear_latch: false, start_login: false }
        );
        // Never connected while the CLI is signed out, whatever is remembered.
        for enabled in [true, false] {
            for latched in [true, false] {
                let d = decide(enabled, latched, false);
                assert!(!d.connected);
                assert!(!d.clear_latch);
                assert!(d.start_login);
            }
        }
    }
    #[test]
    fn expired_sign_in_classification_is_unchanged() {
        for text in ["OAuth session expired", "Failed to authenticate", "Not logged in"] {
            assert!(needs_signin(&json!({"is_error":true,"result":text})));
            assert!(needs_signin(&json!({"subtype":"error_during_execution","errors":[text]})));
            assert!(decode_reply(false, json!({"is_error":true,"result":text}))
                .unwrap_err()
                .contains("Claude sign-in has expired. Click Connect provider to sign in again."));
        }
        // Not a sign-in problem: no latch-worthy classification.
        assert!(!needs_signin(&json!({"is_error":false,"result":"OAuth session expired"})));
        assert!(!needs_signin(&json!({"is_error":true,"result":"Claude could not finish the reply"})));
        assert!(!needs_signin(&json!({"structured_output":{"text":"Ready"}})));
        // A latch written by that classification still reports needsSignIn
        // while the CLI stays signed out.
        let expired = json!({"is_error":true,"result":"Failed to authenticate: OAuth session expired"});
        assert!(decide(true, needs_signin(&expired), false).needs_sign_in);
    }
}

#[cfg(test)]
mod streaming_tests {
    use super::*;
    #[test]
    fn public_output_only_and_bounded() {
        let mut s = ReplyState::default();
        observe_reply(&mut s, &json!({"type":"stream_event","event":{"delta":{"type":"thinking_delta","thinking":"private"}}}));
        observe_reply(&mut s, &json!({"type":"stream_event","event":{"delta":{"type":"input_json_delta","partial_json":"secret"}}}));
        assert!(s.text.is_empty());
        observe_reply(&mut s, &json!({"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Hello"}}}));
        assert_eq!(s.text, "Hello");
        assert_eq!(s.bytes, 5);
        observe_reply(&mut s, &json!({"type":"stream_event","event":{"delta":{"type":"text_delta","text":"x".repeat(65536)}}}));
        assert_eq!(s.text, "Hello");
        assert_eq!(s.bytes, 65541);
    }
    #[test]
    fn reasoning_shows_progress_without_ever_carrying_its_content() {
        let mut s = ReplyState::default();
        // A real thinking_delta is already redacted by the CLI — `"thinking":""`
        // with a cumulative `estimated_tokens`. Feed it a non-empty one anyway:
        // nothing that crosses into the page may contain it.
        observe_reply(&mut s, &json!({"type":"stream_event","event":{"delta":{"type":"thinking_delta","thinking":"private chain of thought","estimated_tokens":50}}}));
        assert!(s.text.is_empty());
        assert_eq!(s.bytes, 0, "reasoning must never be counted as assistant text");
        assert_eq!(s.thinking, 50);
        assert_eq!(s.phase, "Thinking · 50 tokens");
        assert!(!s.phase.contains("private"));
        // Cumulative, not additive, and it keeps moving so the line is not frozen.
        observe_reply(&mut s, &json!({"type":"stream_event","event":{"delta":{"type":"thinking_delta","thinking":"","estimated_tokens":1200}}}));
        assert_eq!(s.phase, "Thinking · 1200 tokens");
        // A late lower count never walks the signal backwards.
        observe_reply(&mut s, &json!({"type":"stream_event","event":{"delta":{"type":"thinking_delta","thinking":"","estimated_tokens":7}}}));
        assert_eq!(s.thinking, 1200);
        // A signature is still ignored entirely.
        let before = s.phase.clone();
        observe_reply(&mut s, &json!({"type":"stream_event","event":{"delta":{"type":"signature_delta","signature":"CAISpSQKpgEIERgC"}}}));
        assert_eq!(s.phase, before);
        assert!(s.text.is_empty());
        // Visible text takes the line over, and reasoning cannot reclaim it.
        observe_reply(&mut s, &json!({"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Hello"}}}));
        assert_eq!(s.text, "Hello");
        assert_eq!(s.phase, "Receiving reply");
        observe_reply(&mut s, &json!({"type":"stream_event","event":{"delta":{"type":"thinking_delta","thinking":"","estimated_tokens":9000}}}));
        assert_eq!(s.phase, "Receiving reply");
        assert_eq!(s.text, "Hello");
    }
    #[test]
    fn a_structured_reply_streams_its_prose_and_never_its_actions() {
        let mut s = ReplyState::default();
        let chunks = [
            "{\"text\": \"Fixing the la",
            "tch.\\nIt is stale.\", \"actions\": [{\"name\": \"propose_file_edit\",",
            " \"args\": {\"path\": \"a.rs\", \"content\": \"SECRET FILE BODY\"}}]}",
        ];
        let mut seen = Vec::new();
        for c in chunks {
            observe_reply(&mut s, &json!({"type":"stream_event","event":{"delta":{"type":"input_json_delta","partial_json":c}}}));
            seen.push(s.text.clone());
        }
        // It arrives progressively rather than all at the end.
        assert_eq!(seen[0], "Fixing the la");
        assert_eq!(s.text, "Fixing the latch.\nIt is stale.");
        assert_eq!(s.phase, "Receiving reply");
        // The action arguments are on the far side of the boundary and stay there.
        assert!(!s.text.contains("SECRET FILE BODY"));
        assert!(!s.text.contains("propose_file_edit"));
        assert!(!s.phase.contains("SECRET"));
        // And the raw accumulator is never handed to the page.
        let c = Connection::default();
        *c.1.lock().unwrap() = ReplyState { id: "one".into(), active: true, ..s };
        let status = c.reply_status("one").unwrap();
        assert_eq!(status["text"], "Fixing the latch.\nIt is stale.");
        assert!(status.get("partial").is_none());
        assert!(!status.to_string().contains("SECRET FILE BODY"));
    }
    #[test]
    fn a_structured_reply_that_is_not_prose_yet_crosses_nothing() {
        let mut s = ReplyState::default();
        for junk in ["secret", "{\"actions\": [", "{\"tex", "not json at all"] {
            observe_reply(&mut s, &json!({"type":"stream_event","event":{"delta":{"type":"input_json_delta","partial_json":junk}}}));
        }
        assert!(s.text.is_empty(), "nothing may cross before the text field is readable");
        assert_eq!(s.bytes, 0);
    }
    #[test]
    fn the_reply_budget_matches_the_reasoning_being_paid_for() {
        assert_eq!(reply_budget(None), 300);
        assert_eq!(reply_budget(Some("low")), 300);
        assert_eq!(reply_budget(Some("medium")), 300);
        assert_eq!(reply_budget(Some("high")), 600);
        assert_eq!(reply_budget(Some("xhigh")), 900);
        assert_eq!(reply_budget(Some("max")), 1800);
        // An unknown level is refused before it reaches here; if one ever does,
        // it gets the conservative budget rather than an unbounded wait.
        assert_eq!(reply_budget(Some("enormous")), 300);
        // Every level must outlast the 262.5 s measured for one ordinary request.
        for e in ["low", "medium", "high", "xhigh", "max"] {
            assert!(reply_budget(Some(e)) >= 300);
        }
    }
    #[test]
    fn current_login_destination_and_spoofs() {
        assert!(login_link("https://claude.com/cai/oauth/authorize?state=example").is_some());
        for url in ["https://claude.com.evil.test/oauth", "http://claude.com/oauth", "https://user@claude.com/oauth"] { assert!(login_link(url).is_none()); }
    }
    #[test]
    fn reply_identity_protects_cancel_and_preview() {
        let c = Connection::default();
        *c.1.lock().unwrap() = ReplyState {id:"one".into(),active:true,text:"hello".into(),..ReplyState::default()};
        assert_eq!(c.reply_status("other").unwrap(),json!({"active":false}));
        assert!(c.cancel_reply("other").is_err());
        assert!(c.cancel_reply("one").is_ok());
        assert!(c.1.lock().unwrap().cancelled);
    }
    #[cfg(unix)]
    #[test]
    fn stream_is_visible_before_final_result_and_cancel_stops_child() {
        let state = Arc::new(Mutex::new(ReplyState {id:"test".into(),active:true,..ReplyState::default()}));
        let mut command = Command::new("python3");
        command.args(["-c", "import json,time;print(json.dumps({'type':'stream_event','event':{'delta':{'type':'text_delta','text':'Visible now'}}}),flush=True);time.sleep(10)"]);
        let held = state.clone();
        let handle = std::thread::spawn(move || run_reply(command,String::new(),held,3));
        let deadline = Instant::now()+Duration::from_secs(2);
        while state.lock().unwrap().text.is_empty() && Instant::now()<deadline {std::thread::sleep(Duration::from_millis(10));}
        assert_eq!(state.lock().unwrap().text,"Visible now");
        assert!(state.lock().unwrap().active);
        state.lock().unwrap().cancelled = true;
        assert!(handle.join().unwrap().unwrap_err().contains("cancelled"));
        assert!(!state.lock().unwrap().active);
    }
    #[cfg(unix)]
    #[test]
    fn successful_final_result_and_auth_failure_are_separate() {
        for (value,success) in [
            (json!({"type":"result","structured_output":{"text":"done","actions":[]}}),true),
            (json!({"type":"result","is_error":true,"result":"OAuth session expired"}),false)
        ] {
            let mut command = Command::new("python3");
            command.args(["-c", "import sys;print(sys.argv[1])", &value.to_string()]);
            let state=Arc::new(Mutex::new(ReplyState {active:true,..ReplyState::default()}));
            let (ok,value)=run_reply(command,String::new(),state.clone(),2).unwrap();
            assert_eq!(decode_reply(ok,value).is_ok(),success);
            assert!(!state.lock().unwrap().active);
        }
    }
}
