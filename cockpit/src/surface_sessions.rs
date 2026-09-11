//! Device-local links to existing human-operated surfaces. These are neither
//! runtime assignments nor provider tools; no process or navigation is started.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};
use tauri::Manager;
#[derive(Default)]
pub struct Sessions(Mutex<Inventory>);
#[derive(Default)]
struct Inventory {
    epoch: String,
    next: u64,
    rows: BTreeMap<String, Surface>,
}
#[derive(Clone, Serialize)]
struct Surface {
    session_id: String,
    kind: String,
    id: u64,
    generation: u64,
    title: String,
    root: Option<String>,
    state: String,
    bot_id: Option<String>,
}
#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
    List,
    Link { session_id: String, bot_id: String },
    Unlink { session_id: String },
}
impl Inventory {
    fn sync(&mut self, mut incoming: BTreeMap<String, Surface>) {
        if self.epoch.is_empty() {
            self.epoch = format!(
                "{}-{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos()
            );
        }
        for (key, row) in &mut incoming {
            if let Some(old) = self.rows.get(key) {
                row.session_id = old.session_id.clone();
                row.bot_id = old.bot_id.clone();
            } else {
                self.next += 1;
                row.session_id = format!("{}-{}", self.epoch, self.next);
            }
        }
        self.rows = incoming;
    }
    fn apply(&mut self, request: Request) -> Result<Value, String> {
        let (id, bot) = match request {
            Request::List => return Ok(json!({"sessions":self.rows.values().collect::<Vec<_>>()})),
            Request::Link { session_id, bot_id } => {
                if bot_id.is_empty()
                    || bot_id.len() > 100
                    || !bot_id
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
                {
                    return Err("Invalid bot profile.".into());
                }
                (session_id, Some(bot_id))
            }
            Request::Unlink { session_id } => (session_id, None),
        };
        let row = self
            .rows
            .values_mut()
            .find(|s| s.session_id == id)
            .ok_or("That development session has closed. Refresh the list.")?;
        row.bot_id = bot;
        Ok(json!({"sessions":self.rows.values().collect::<Vec<_>>()}))
    }
}
impl Sessions {
    pub fn forget_browser(&self, id: u8) {
        if let Ok(mut s) = self.0.lock() {
            s.rows.remove(&format!("browser:{id}"));
        }
    }
    pub fn request(
        &self,
        request: Request,
        shells: Value,
        browsers: Value,
    ) -> Result<Value, String> {
        let mut rows = BTreeMap::new();
        let generation = shells["generation"].as_u64().unwrap_or(0);
        for shell in shells["shells"].as_array().into_iter().flatten() {
            let id = shell["id"].as_u64().ok_or("Invalid shell inventory.")?;
            rows.insert(
                format!("terminal:{generation}:{id}"),
                Surface {
                    session_id: String::new(),
                    kind: "terminal".into(),
                    id,
                    generation,
                    title: format!("Shell {id}"),
                    root: shells["root"].as_str().map(str::to_owned),
                    state: if shell["running"] == true {
                        "running"
                    } else {
                        "exited"
                    }
                    .into(),
                    bot_id: None,
                },
            );
        }
        for browser in browsers["tabs"].as_array().into_iter().flatten() {
            let id = browser["id"].as_u64().ok_or("Invalid browser inventory.")?;
            rows.insert(
                format!("browser:{id}"),
                Surface {
                    session_id: String::new(),
                    kind: "browser".into(),
                    id,
                    generation: 0,
                    title: browser["url"]
                        .as_str()
                        .unwrap_or("Local browser")
                        .chars()
                        .take(4096)
                        .collect(),
                    root: None,
                    state: "open".into(),
                    bot_id: None,
                },
            );
        }
        let mut inventory = self.0.lock().map_err(|_| "Session links are busy.")?;
        inventory.sync(rows);
        inventory.apply(request)
    }
}
pub fn request(request: Request, app: tauri::AppHandle) -> Result<Value, String> {
    let shells = app
        .state::<crate::workbench::Workbench>()
        .request(crate::workbench::Request::Status)?;
    let browsers = crate::preview::surface("status".into(), None, None, 0, app.clone())?;
    app.state::<Sessions>().request(request, shells, browsers)
}
#[cfg(test)]
mod tests {
    use super::*;
    fn shells(id: u64, g: u64) -> Value {
        json!({"generation":g,"root":"/repo","shells":[{"id":id,"running":true,"output":"PRIVATE OUTPUT"}]})
    }
    fn browsers() -> Value {
        json!({"tabs":[{"id":0,"url":"http://localhost:3000"}]})
    }
    fn empty() -> Value {
        json!({"tabs":[],"shells":[]})
    }
    #[test]
    fn links_follow_native_lifetime_without_copying_output() {
        let s = Sessions::default();
        let list = s.request(Request::List, shells(1, 1), empty()).unwrap();
        let id = list["sessions"][0]["session_id"]
            .as_str()
            .unwrap()
            .to_owned();
        s.request(
            Request::Link {
                session_id: id.clone(),
                bot_id: "assistant".into(),
            },
            shells(1, 1),
            empty(),
        )
        .unwrap();
        let reopened = s.request(Request::List, shells(1, 1), empty()).unwrap();
        assert_eq!(reopened["sessions"][0]["bot_id"], "assistant");
        assert!(!reopened.to_string().contains("PRIVATE OUTPUT"));
        assert!(s
            .request(Request::Unlink { session_id: id }, shells(1, 2), empty())
            .is_err());
        assert!(
            s.request(Request::List, shells(1, 2), empty()).unwrap()["sessions"][0]["bot_id"]
                .is_null()
        );
    }
    #[test]
    fn reused_browser_slot_never_inherits_its_old_link() {
        let s = Sessions::default();
        let list = s.request(Request::List, empty(), browsers()).unwrap();
        let id = list["sessions"][0]["session_id"]
            .as_str()
            .unwrap()
            .to_owned();
        s.request(
            Request::Link {
                session_id: id.clone(),
                bot_id: "assistant".into(),
            },
            empty(),
            browsers(),
        )
        .unwrap();
        s.forget_browser(0);
        let next = s.request(Request::List, empty(), browsers()).unwrap();
        assert_ne!(next["sessions"][0]["session_id"], id);
        assert!(next["sessions"][0]["bot_id"].is_null());
        assert!(s
            .request(
                Request::Link {
                    session_id: id,
                    bot_id: "assistant".into()
                },
                empty(),
                browsers()
            )
            .is_err());
    }
    #[test]
    fn closing_and_process_restart_clear_links() {
        let s = Sessions::default();
        let id = s.request(Request::List, shells(1, 1), empty()).unwrap()["sessions"][0]
            ["session_id"]
            .as_str()
            .unwrap()
            .to_owned();
        assert!(
            s.request(Request::List, empty(), empty()).unwrap()["sessions"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert!(s
            .request(
                Request::Unlink {
                    session_id: id.clone()
                },
                empty(),
                empty()
            )
            .is_err());
        let fresh = Sessions::default()
            .request(Request::List, shells(1, 1), empty())
            .unwrap();
        assert_ne!(fresh["sessions"][0]["session_id"], id);
    }
}
