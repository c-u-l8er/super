//! Official Codex app-server integration. Super owns a separate Codex home;
//! login tokens and refresh remain inside Codex, never inside the webview.
use serde_json::{json, Value};
use std::{
    collections::VecDeque,
    io::{BufRead, BufReader, Read, Write},
    path::PathBuf,
    process::{Child, ChildStdin, Command, Stdio},
    sync::{mpsc, Arc, Mutex},
    time::{Duration, Instant},
};
#[derive(Clone, Default)]
pub struct Connection(Arc<Mutex<Option<Rpc>>>, Arc<Mutex<ReplyState>>);
#[derive(Default)]
struct ReplyState {
    id: String,
    active: bool,
    cancelled: bool,
    bytes: usize,
}
struct Rpc {
    child: Child,
    input: ChildStdin,
    output: mpsc::Receiver<Value>,
    next: u64,
    home: PathBuf,
    login: Option<String>,
    login_failed: bool,
    events: VecDeque<Value>,
    reply: Option<Arc<Mutex<ReplyState>>>,
}
// A live reply may exceed two minutes; unrelated events must not keep it alive.
struct ReplyDeadline {
    hard: Instant,
    idle: Instant,
}
impl ReplyDeadline {
    fn new(now: Instant) -> Self {
        Self {
            hard: now + Duration::from_secs(300),
            idle: now + Duration::from_secs(120),
        }
    }
    fn deadline(&self) -> Instant {
        self.hard.min(self.idle)
    }
    fn observe(&mut self, now: Instant, event: &Value, thread_id: &str) {
        if event["params"]["threadId"] != thread_id {
            return;
        }
        let progress = match event["method"].as_str() {
            Some("item/agentMessage/delta") => event["params"]["delta"]
                .as_str()
                .map(|s| !s.is_empty())
                .unwrap_or(false),
            Some("item/completed") => true,
            _ => false,
        };
        if progress {
            self.idle = now + Duration::from_secs(120);
        }
    }
}
impl Drop for Rpc {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
impl Rpc {
    fn start(home: PathBuf) -> Result<Self, String> {
        Self::start_program(home, "codex")
    }
    fn start_program(home: PathBuf, program: impl AsRef<std::ffi::OsStr>) -> Result<Self, String> {
        std::fs::create_dir_all(home.join("workspace"))
            .map_err(|_| "Could not create Super's connection folder.")?;
        let mut cmd = Command::new(program);
        cmd.args([
            "app-server",
            "--stdio",
            "-c",
            "cli_auth_credentials_store=\"keyring\"",
            "-c",
            "sandbox_mode=\"read-only\"",
            "-c",
            "approval_policy=\"never\"",
            "-c",
            "web_search=\"disabled\"",
            "-c",
            "tools.view_image=false",
        ]);
        for feature in [
            "shell_tool",
            "multi_agent",
            "apps",
            "shell_snapshot",
            "memories",
            "tool_suggest",
            "skill_mcp_dependency_install",
        ] {
            cmd.args(["--disable", feature]);
        }
        cmd.env("CODEX_HOME", &home)
            .env_remove("OPENAI_API_KEY")
            .env_remove("CODEX_API_KEY")
            .current_dir(home.join("workspace"));
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| "Codex is not available. Install the Codex CLI and reopen Super.")?;
        let input = child
            .stdin
            .take()
            .ok_or("Could not open the Codex connection.")?;
        let output = child
            .stdout
            .take()
            .ok_or("Could not read the Codex connection.")?;
        let (tx, rx) = mpsc::sync_channel(128);
        std::thread::spawn(move || {
            let mut reader = BufReader::new(output);
            loop {
                let mut line = String::new();
                match reader.by_ref().take(2_097_153).read_line(&mut line) {
                    Ok(0) | Err(_) => break,
                    _ => {}
                }
                if line.len() > 2_097_152 {
                    break;
                }
                if let Ok(value) = serde_json::from_str(&line) {
                    if tx.send(value).is_err() {
                        break;
                    }
                }
            }
        });
        let mut rpc = Self {
            child,
            input,
            output: rx,
            next: 0,
            home,
            login: None,
            login_failed: false,
            events: VecDeque::new(),
            reply: None,
        };
        rpc.call(
            "initialize",
            json!({"clientInfo":{"name":"super_cockpit","title":"Super","version":"0.1.0"}}),
            20,
        )?;
        rpc.write(json!({"method":"initialized"}))?;
        Ok(rpc)
    }
    fn write(&mut self, v: Value) -> Result<(), String> {
        writeln!(self.input, "{v}")
            .and_then(|_| self.input.flush())
            .map_err(|_| "The Codex connection closed. Connect again.".into())
    }
    fn receive(&mut self, deadline: Instant) -> Result<Value, String> {
        let v = loop {
            if self
                .reply
                .as_ref()
                .is_some_and(|r| r.lock().map(|r| r.active && r.cancelled).unwrap_or(true))
            {
                return Err(
                    "Codex reply cancelled. Your message and attachments are restored.".into(),
                );
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err("Codex did not respond in time. Connect again.".into());
            }
            match self
                .output
                .recv_timeout(remaining.min(Duration::from_millis(100)))
            {
                Ok(v) => break v,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err("The Codex connection closed. Connect again.".into())
                }
            }
        };
        if v["method"] == "account/login/completed" {
            self.login = None;
            self.login_failed = v["params"]["success"] != true;
        }
        // This assistant exposes proposals, never permission or tool execution.
        if v.get("method").is_some() && v.get("id").is_some() {
            self.write(json!({"id":v["id"],"error":{"code":-32601,"message":"Super does not authorize this operation."}}))?;
        }
        Ok(v)
    }
    fn call(&mut self, method: &str, params: Value, seconds: u64) -> Result<Value, String> {
        self.next += 1;
        let id = self.next;
        self.write(json!({"id":id,"method":method,"params":params}))?;
        let deadline = Instant::now() + Duration::from_secs(seconds);
        loop {
            let v = self.receive(deadline)?;
            if v["id"] == id && v.get("method").is_none() {
                if v.get("error").is_some() {
                    return Err(format!("Codex could not complete {method}. Check your connection and unlock the system keychain."));
                }
                return Ok(v["result"].clone());
            }
            if [Some("item/completed"), Some("turn/completed")].contains(&v["method"].as_str()) {
                if self.events.len() >= 128 {
                    return Err("Codex returned too many pending events.".into());
                }
                self.events.push_back(v);
            }
        }
    }
    fn status(&mut self) -> Result<Value, String> {
        let v = self.call("account/read", json!({"refreshToken":false}), 15)?;
        let connected = v["account"]["type"] == "chatgpt";
        Ok(
            json!({"connected":connected,"pending":self.login.is_some(),"failed":self.login_failed,"provider":"codex"}),
        )
    }
}
impl Connection {
    fn with<T>(
        &self,
        home: PathBuf,
        f: impl FnOnce(&mut Rpc) -> Result<T, String>,
    ) -> Result<T, String> {
        let mut guard = self.0.lock().map_err(|_| "Connection is unavailable.")?;
        if guard
            .as_mut()
            .map(|r| r.child.try_wait().ok().flatten().is_some())
            .unwrap_or(false)
        {
            *guard = None;
        }
        if guard.is_none() {
            *guard = Some(Rpc::start(home)?);
        }
        let result = f(guard.as_mut().unwrap());
        // A timed-out RPC cannot safely be reused with unread turn events.
        if result
            .as_ref()
            .err()
            .map(|e| e.contains("in time") || e.contains("closed") || e.contains("cancelled"))
            .unwrap_or(false)
        {
            *guard = None;
        }
        result
    }
    pub fn status(&self, home: PathBuf) -> Result<Value, String> {
        self.with(home, |r| r.status())
    }
    pub fn connect(&self, home: PathBuf) -> Result<Value, String> {
        self.with(home, |r| {
            let status = r.status()?;
            if status["connected"] == true || status["pending"] == true {
                return Ok(status);
            }
            let v = r.call(
                "account/login/start",
                json!({"type":"chatgpt","useHostedLoginSuccessPage":true}),
                20,
            )?;
            r.login = v["loginId"].as_str().map(str::to_owned);
            r.login_failed = false;
            let url = v["authUrl"]
                .as_str()
                .ok_or("Codex did not return a sign-in link.")?;
            if !official_login_url(url) {
                return Err("Codex returned an unexpected sign-in destination.".into());
            }
            let mut browser = Command::new("xdg-open")
                .arg(url)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|_| {
                    "Could not open your browser. Check your default browser and try again."
                })?;
            std::thread::spawn(move || {
                let _ = browser.wait();
            });
            Ok(json!({"connected":false,"pending":true,"provider":"codex"}))
        })
    }
    pub fn disconnect(&self, home: PathBuf) -> Result<Value, String> {
        self.with(home, |r| {
            if let Some(id) = r.login.take() {
                r.call("account/login/cancel", json!({"loginId":id}), 15)?;
            }
            r.call("account/logout", json!({}), 15)?;
            r.login_failed = false;
            r.status()
        })
    }
    pub fn models(&self, home: PathBuf) -> Result<Value, String> {
        self.with(home,|r|{
        if r.status()?["connected"]!=true{return Err("Connect ChatGPT first.".into());}
        let mut data=Vec::new();let mut cursor=Value::Null;
        for _ in 0..20 {
            let v=r.call("model/list",json!({"limit":100,"cursor":cursor}),20)?;
            data.extend(v["data"].as_array().ok_or("No models were returned.")?.iter().filter(|m|m["hidden"]!=true).map(|m|json!({"id":m["model"],"name":m["displayName"],"isDefault":m["isDefault"],"supportedReasoningEfforts":m["supportedReasoningEfforts"],"defaultReasoningEffort":m["defaultReasoningEffort"]})));
            let next=v["nextCursor"].clone();if next.is_null(){return Ok(json!({"models":data}));}if next==cursor{return Err("Model catalog pagination stalled.".into());}cursor=next;
        }
        Err("Model catalog exceeded the page limit.".into())
    })
    }
    #[cfg(test)]
    pub fn chat(
        &self,
        home: PathBuf,
        model: String,
        prompt: String,
        schema: Value,
        effort: Option<String>,
    ) -> Result<Value, String> {
        self.chat_tracked(home, model, prompt, schema, effort, None)
    }
    pub fn chat_tracked(
        &self,
        home: PathBuf,
        model: String,
        prompt: String,
        schema: Value,
        effort: Option<String>,
        request_id: Option<String>,
    ) -> Result<Value, String> {
        if let Some(id) = &request_id {
            if id.is_empty()
                || id.len() > 80
                || !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
            {
                return Err("Invalid reply identity.".into());
            }
            let mut r = self.1.lock().map_err(|_| "Reply state unavailable.")?;
            if r.active {
                return Err("A reply is already active.".into());
            }
            *r = ReplyState {
                id: id.clone(),
                active: true,
                cancelled: false,
                bytes: 0,
            };
        }
        let result=self.with(home,|r|{
        r.reply=request_id.as_ref().map(|_|self.1.clone());
        if r.status()?["connected"]!=true{return Err("Connect ChatGPT before sending a message.".into());}
        r.events.clear();
        let start=r.call("thread/start",json!({"model":model,"cwd":r.home.join("workspace"),"ephemeral":true,"sandbox":"read-only","approvalPolicy":"never","baseInstructions":"You are Super's planning assistant. Return only the requested JSON. Never use tools. Proposed actions are data for human review; you cannot execute them."}),25)?;
        let id=start["thread"]["id"].as_str().ok_or("Codex did not start a conversation.")?.to_owned();
        let result=(||{
            r.call("turn/start",json!({"threadId":id,"input":[{"type":"text","text":prompt}],"outputSchema":schema,"effort":effort}),20)?;
            let mut budget=ReplyDeadline::new(Instant::now());let mut answer=String::new();
            loop {let v=match r.events.pop_front(){Some(v)=>v,None=>r.receive(budget.deadline())?};budget.observe(Instant::now(),&v,&id);if v["params"]["threadId"]!=id{continue;}
                if v["method"]=="item/agentMessage/delta" { if let Some(text)=v["params"]["delta"].as_str() {if let Some(control)=&r.reply {if let Ok(mut state)=control.lock(){state.bytes=state.bytes.saturating_add(text.len());}}} }
                if v["method"]=="item/completed" && v["params"]["item"]["type"]=="agentMessage" { answer=v["params"]["item"]["text"].as_str().unwrap_or("").into(); }
                if v["method"]=="turn/completed" {
                    if v["params"]["turn"]["status"]!="completed"{return Err("Codex could not finish this reply. Check your account availability and try again.".into());}
                    return serde_json::from_str(&answer).map_err(|_|"Codex returned an unreadable reply. No action was executed.".into());
                }
            }
        })();
        if result.is_ok(){let _=r.call("thread/unsubscribe",json!({"threadId":id}),5);}
        result
    });
        if request_id.is_some() {
            let mut state = self.1.lock().map_err(|_| "Reply state unavailable.")?;
            state.active = false;
            if state.cancelled {
                return Err(
                    "Codex reply cancelled. Your message and attachments are restored.".into(),
                );
            }
        }
        result
    }
    pub fn reply_status(&self, id: &str) -> Result<Value, String> {
        let s = self.1.lock().map_err(|_| "Reply state unavailable.")?;
        Ok(
            json!({"active":s.id==id&&s.active,"cancelled":s.id==id&&s.cancelled,"received_bytes":if s.id==id{s.bytes}else{0}}),
        )
    }
    pub fn cancel_reply(&self, id: &str) -> Result<Value, String> {
        let mut s = self.1.lock().map_err(|_| "Reply state unavailable.")?;
        if s.id != id || !s.active {
            return Err("That reply is no longer active.".into());
        }
        s.cancelled = true;
        Ok(json!({"cancelled":true}))
    }
}
fn official_login_url(raw: &str) -> bool {
    reqwest::Url::parse(raw)
        .map(|u| {
            u.scheme() == "https"
                && u.username().is_empty()
                && u.password().is_none()
                && [Some("auth.openai.com"), Some("chatgpt.com")].contains(&u.host_str())
        })
        .unwrap_or(false)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn login_destination_is_official_https() {
        assert!(official_login_url(
            "https://auth.openai.com/authorize?state=example"
        ));
        assert!(!official_login_url("https://auth.openai.com.example.org/"));
        assert!(!official_login_url("http://chatgpt.com/"));
    }
}

#[cfg(all(test, unix))]
mod protocol_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    #[test]
    fn early_completion_events_survive_the_turn_start_response() {
        let home = std::env::temp_dir().join(format!("super-codex-rpc-{}", std::process::id()));
        std::fs::create_dir_all(&home).unwrap();
        let fixture = home.join("fixture.py");
        std::fs::write(&fixture,r#"#!/usr/bin/python3
import json,sys
for line in sys.stdin:
 r=json.loads(line);m=r.get('method');i=r.get('id')
 if i is None:continue
 result={}
 if m=='account/read':result={'account':{'type':'chatgpt'}}
 if m=='thread/start':
  assert r['params']['sandbox']=='read-only'
  assert r['params']['ephemeral'] is True
  result={'thread':{'id':'fixture-thread'}}
 if m=='turn/start':
  assert r['params']['effort']=='high'
  print(json.dumps({'method':'item/completed','params':{'threadId':'fixture-thread','item':{'type':'agentMessage','text':json.dumps({'text':'Plan ready','actions':[]})}}}),flush=True)
  print(json.dumps({'method':'turn/completed','params':{'threadId':'fixture-thread','turn':{'status':'completed'}}}),flush=True)
 print(json.dumps({'id':i,'result':result}),flush=True)
"#).unwrap();
        std::fs::set_permissions(&fixture, std::fs::Permissions::from_mode(0o700)).unwrap();
        let rpc = Rpc::start_program(home.clone(), fixture).unwrap();
        let connection = Connection(Arc::new(Mutex::new(Some(rpc))), Arc::default());
        let reply = connection
            .chat(
                home.clone(),
                "fixture".into(),
                "plan".into(),
                json!({"type":"object"}),
                Some("high".into()),
            )
            .unwrap();
        assert_eq!(reply, json!({"text":"Plan ready","actions":[]}));
        drop(connection);
        std::fs::remove_dir_all(home).unwrap();
    }
}

#[cfg(test)]
mod reply_deadline_tests {
    use super::*;
    fn delta(thread: &str, text: &str) -> Value {
        json!({"method":"item/agentMessage/delta","params":{"threadId":thread,"delta":text}})
    }
    #[test]
    fn live_reply_can_finish_after_the_old_two_minute_limit() {
        let now = Instant::now();
        let mut b = ReplyDeadline::new(now);
        b.observe(
            now + Duration::from_secs(119),
            &delta("current", "more"),
            "current",
        );
        assert_eq!(b.deadline(), now + Duration::from_secs(239));
        assert!(b.deadline() > now + Duration::from_secs(180));
    }
    #[test]
    fn no_progress_still_times_out_after_two_minutes() {
        let now = Instant::now();
        let mut b = ReplyDeadline::new(now);
        for e in [
            delta("other", "more"),
            delta("current", ""),
            json!({"method":"account/rateLimits/updated","params":{"threadId":"current"}}),
        ] {
            b.observe(now + Duration::from_secs(119), &e, "current");
        }
        assert_eq!(b.deadline(), now + Duration::from_secs(120));
    }
    #[test]
    fn ongoing_stream_cannot_exceed_five_minutes() {
        let now = Instant::now();
        let mut b = ReplyDeadline::new(now);
        for seconds in [100, 200, 299] {
            b.observe(
                now + Duration::from_secs(seconds),
                &delta("current", "more"),
                "current",
            );
        }
        assert_eq!(b.deadline(), now + Duration::from_secs(300));
    }
}

#[cfg(all(test, unix))]
mod cancellation_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    #[test]
    fn cancel_interrupts_a_stream_without_waiting_for_completion_and_rejects_stale_ids() {
        let home = std::env::temp_dir().join(format!("super-reply-cancel-{}", std::process::id()));
        std::fs::create_dir_all(&home).unwrap();
        let file = home.join("fixture.py");
        std::fs::write(&file,r#"#!/usr/bin/python3
import sys,json,time
for line in sys.stdin:
 r=json.loads(line);i=r.get('id');m=r.get('method')
 if i is None:continue
 result={}
 if m=='account/read':result={'account':{'type':'chatgpt'}}
 if m=='thread/start':result={'thread':{'id':'current'}}
 print(json.dumps({'id':i,'result':result}),flush=True)
 if m=='turn/start':
  for n in range(100):
   print(json.dumps({'method':'item/agentMessage/delta','params':{'threadId':'current','delta':'abc'}}),flush=True);time.sleep(.1)
"#).unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o700)).unwrap();
        let rpc = Rpc::start_program(home.clone(), file).unwrap();
        let c = Connection(Arc::new(Mutex::new(Some(rpc))), Arc::default());
        let worker = c.clone();
        let worker_home = home.clone();
        let t = std::thread::spawn(move || {
            worker.chat_tracked(
                worker_home,
                "fixture".into(),
                "test".into(),
                json!({}),
                None,
                Some("request-one".into()),
            )
        });
        let end = Instant::now() + Duration::from_secs(3);
        while c.reply_status("request-one").unwrap()["received_bytes"]
            .as_u64()
            .unwrap()
            == 0
        {
            assert!(Instant::now() < end);
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(c.cancel_reply("previous-request").is_err());
        assert_eq!(c.reply_status("request-one").unwrap()["cancelled"], false);
        let start = Instant::now();
        assert_eq!(c.cancel_reply("request-one").unwrap()["cancelled"], true);
        assert!(t.join().unwrap().unwrap_err().contains("cancelled"));
        assert!(start.elapsed() < Duration::from_secs(2));
        assert_eq!(c.reply_status("request-one").unwrap()["active"], false);
        assert!(c.cancel_reply("request-one").is_err());
        assert!(c.0.lock().unwrap().is_none());
        drop(c);
        std::fs::remove_dir_all(home).unwrap();
    }
}
