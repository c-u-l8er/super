//! User-attached visual evidence, separate from acceptance and automated checks.
use base64::Engine;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    path::PathBuf,
    sync::{Mutex, OnceLock},
};
static VERSION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
pub fn version() -> u64 { VERSION.load(std::sync::atomic::Ordering::Acquire) }
static ROOT: OnceLock<PathBuf> = OnceLock::new();
static WRITE: Mutex<()> = Mutex::new(());
pub fn init(path: PathBuf) {
    let _ = ROOT.set(path.join("task-screenshots"));
}
fn key(world: &Value, task: &str, revision: u64) -> Result<String, String> {
    if !world.is_array()
        || world.as_array().unwrap().len() != 2
        || !world[0].is_string()
        || !world[1].is_u64()
        || task.len() > 100
        || task.is_empty()
        || revision == 0
    {
        return Err("Invalid screenshot task identity.".into());
    }
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(&json!([world, task, revision])).unwrap())
    ))
}
pub fn request(r: Value) -> Result<Value, String> {
    let _guard = WRITE.lock().map_err(|_| "Screenshot storage is busy.")?;
    let world = &r["world"];
    let task = r["task"].as_str().ok_or("Missing task.")?;
    let revision = r["revision"].as_u64().ok_or("Missing revision.")?;
    let id = key(world, task, revision)?;
    let root = ROOT.get().ok_or("Screenshot storage unavailable.")?;
    let path = root.join(format!("{id}.json"));
    let mut value = match std::fs::read(&path) {
        Ok(bytes) if bytes.len() <= 6_000_000 => serde_json::from_slice::<Value>(&bytes)
            .map_err(|_| "Screenshot record is unreadable.")?,
        Ok(_) => return Err("Screenshot record is too large.".into()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            json!({"world":world,"task":task,"revision":revision,"images":{}})
        }
        Err(_) => return Err("Screenshot record cannot be read.".into()),
    };
    if value["world"] != *world || value["task"] != task || value["revision"] != revision {
        return Err("Screenshot identity does not match this task revision.".into());
    }
    if r["operation"] == "list" {
        return Ok(value);
    }
    if r["operation"] == "save_output" || r["operation"] == "remove_output" {
        let side = r["side"].as_str().filter(|s| ["before", "after"].contains(s)).ok_or("Choose Before or After.")?;
        if !value["outputs"].is_object() { value["outputs"] = json!({}); }
        if r["operation"] == "remove_output" {
            value["outputs"].as_object_mut().unwrap().remove(side);
            if value["comparison"].is_null() && value["outputs"].as_object().unwrap().is_empty() && value["images"].as_object().is_none_or(|o| o.is_empty()) {
                match std::fs::remove_file(&path) { Ok(()) => {VERSION.fetch_add(1, std::sync::atomic::Ordering::Release);}, Err(e) if e.kind()==std::io::ErrorKind::NotFound => {}, Err(_) => return Err("Could not remove log.".into()) }
                return Ok(value);
            }
        } else {
            let text = r["output"]["text"].as_str().filter(|s| !s.trim().is_empty() && s.len() <= 100_000).ok_or("Choose a text log up to 100 KB.")?;
            for field in ["command", "source", "environment"] {
                if !r["output"][field].as_str().is_some_and(|s| !s.trim().is_empty() && s.len() <= 1000) { return Err("Record the command, source version and environment for this log.".into()); }
            }
            value["outputs"][side] = json!({"text":text,"command":r["output"]["command"],"source":r["output"]["source"],"environment":r["output"]["environment"],"origin":"manual-import","sha256":format!("{:x}",Sha256::digest(text.as_bytes())),"attached_at":std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs()});
        }
        retain(root, &id, &value)?;
        return Ok(value);
    }
    if r["operation"] == "save_review" {
        let review = &r["review"];
        if !review.is_object() || review.to_string().len() > 48000
            || !review["basis"]["criteria"].is_string()
            || !valid_findings(&review["findings"]) {
            return Err("Visual review is incomplete or too large.".into());
        }
        for side in ["before", "after"] {
            if !review["basis"][side].is_string() || review["basis"][side] != value["images"][side]["sha256"] {
                return Err("Screenshots changed. Run a new visual review.".into());
            }
        }
        value["review"] = review.clone();
        retain(root, &id, &value)?;
        return Ok(value);
    }
    if r["operation"] != "save" && r["operation"] != "remove" {
        return Err("Unknown screenshot operation.".into());
    }
    let side = r["side"]
        .as_str()
        .filter(|s| ["before", "after"].contains(s))
        .ok_or("Choose Before or After.")?;
    if r["operation"] == "remove" {
        let images = value["images"]
            .as_object_mut()
            .ok_or("Screenshot record is unreadable.")?;
        images.remove(side);
        if images.is_empty() && value["comparison"].is_null() && value["outputs"].as_object().is_none_or(|o| o.is_empty()) {
            match std::fs::remove_file(&path) {
                Ok(()) => { VERSION.fetch_add(1, std::sync::atomic::Ordering::Release); }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(_) => return Err("Could not remove screenshot.".into()),
            }
        } else {
            retain(root, &id, &value)?;
        }
        return Ok(value);
    }
    let data = r["data"].as_str().ok_or("Choose a PNG screenshot.")?;
    let encoded = data
        .strip_prefix("data:image/png;base64,")
        .ok_or("Only PNG screenshots are supported.")?;
    if encoded.len() > 2_800_000 {
        return Err("Screenshot exceeds 2 MB. Choose a smaller image.".into());
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|_| "Invalid PNG encoding.")?;
    if bytes.len() > 2_000_000 {
        return Err("Screenshot exceeds 2 MB.".into());
    }
    if bytes.len() < 24 || &bytes[..8] != b"\x89PNG\r\n\x1a\n" || &bytes[12..16] != b"IHDR" {
        return Err("Invalid PNG screenshot.".into());
    }
    let w = u32::from_be_bytes(bytes[16..20].try_into().unwrap());
    let h = u32::from_be_bytes(bytes[20..24].try_into().unwrap());
    if w == 0 || h == 0 || w > 4096 || h > 4096 {
        return Err("Screenshot dimensions exceed 4096 pixels.".into());
    }
    let mut decoder = png::Decoder::new(std::io::Cursor::new(&bytes));
    decoder.set_limits(png::Limits {
        bytes: 64 * 1024 * 1024,
    });
    let mut reader = decoder.read_info().map_err(|_| "Invalid PNG screenshot.")?;
    if reader.output_buffer_size() > 64 * 1024 * 1024 {
        return Err("Screenshot requires too much decoding memory.".into());
    }
    let mut decoded = vec![0; reader.output_buffer_size()];
    reader
        .next_frame(&mut decoded)
        .map_err(|_| "PNG screenshot is incomplete or damaged.")?;
    std::fs::create_dir_all(root).map_err(|_| "Cannot create screenshot storage.")?;
    if !path.exists()
        && std::fs::read_dir(root)
            .map_err(|_| "Cannot read screenshot storage.")?
            .count()
            >= 100
    {
        return Err("Screenshot storage has reached 100 task revisions.".into());
    }
    value["images"][side] = json!({"data":data,"sha256":format!("{:x}",Sha256::digest(&bytes)),"width":w,"height":h,"attached_at":std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs()});
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o700))
            .map_err(|_| "Cannot protect screenshot storage.")?;
    }
    retain(root, &id, &value)?;
    Ok(value)
}
fn retain(root: &std::path::Path, id: &str, value: &Value) -> Result<(), String> {
    std::fs::create_dir_all(root).map_err(|_| "Cannot create evidence storage.")?;
    let path = root.join(format!("{id}.json"));
    if !path.exists() && std::fs::read_dir(root).map_err(|_| "Cannot read evidence storage.")?.count() >= 100 { return Err("Evidence storage has reached 100 task revisions.".into()); }
    if serde_json::to_vec(value).map_err(|e| e.to_string())?.len() > 6_000_000 { return Err("Evidence record exceeds 6 MB.".into()); }
    #[cfg(unix)] { use std::os::unix::fs::PermissionsExt; std::fs::set_permissions(root,std::fs::Permissions::from_mode(0o700)).map_err(|_| "Cannot protect evidence storage.")?; }
    let temporary = root.join(format!("{id}.tmp"));
    std::fs::write(&temporary, serde_json::to_vec(&value).unwrap())
        .map_err(|_| "Could not save screenshot.")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| "Cannot protect screenshot.")?;
    }
    std::fs::rename(temporary, path).map_err(|_| "Could not retain screenshot.")?;
    VERSION.fetch_add(1, std::sync::atomic::Ordering::Release);
    Ok(())
}
fn valid_findings(value: &Value) -> bool {
    let text = |v: &Value, limit: usize| v.as_str().is_some_and(|s| !s.trim().is_empty() && s.len() <= limit);
    text(&value["summary"], 3000)
        && value["requirements"].as_array().is_some_and(|rows| !rows.is_empty() && rows.len() <= 20 && rows.iter().enumerate().all(|(i,r)|
            r["index"].as_u64() == Some(i as u64 + 1) && text(&r["requirement"],12000) && text(&r["reason"],3000)
            && r["status"].as_str().is_some_and(|s| ["met","missing","uncertain"].contains(&s))))
        && value["regressions"].as_array().is_some_and(|rows| rows.len() <= 20 && rows.iter().all(|r| text(r,2000)))
}
pub fn observed(snapshot: &Value, task: &str) -> Value {
    if snapshot["available"] != true {
        return json!({"available":false});
    }
    let t = &snapshot["projection"]["development_tasks"][task];
    if !t.is_object() {
        return json!({"available":false});
    }
    let w = &snapshot["world"];
    match request(
        json!({"operation":"list","world":[w["world_incarnation"],w["world_generation"]],"task":task,"revision":t["revision"]}),
    ) {
        Ok(record) => json!({"available":true,"record":record}),
        Err(_) => json!({"available":false}),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identity_is_revision_and_world_bound() {
        assert_ne!(
            key(&json!(["a", 1]), "t", 1).unwrap(),
            key(&json!(["a", 1]), "t", 2).unwrap()
        );
        assert_ne!(
            key(&json!(["a", 1]), "t", 1).unwrap(),
            key(&json!(["b", 1]), "t", 1).unwrap()
        );
        assert!(key(&json!(null), "t", 1).is_err());
    }
}
#[cfg(test)]
mod storage_tests {
    use super::*;
    #[test]
    fn attachments_persist_and_are_only_observed_for_current_identity() {
        let dir = std::env::temp_dir().join(format!("super-shot-test-{}", std::process::id()));
        init(dir.clone());
        let mut bytes = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut bytes, 1, 1);
            encoder.set_color(png::ColorType::Rgb);
            let mut writer = encoder.write_header().unwrap();
            writer.write_image_data(&[1, 2, 3]).unwrap();
        }
        let data = format!(
            "data:image/png;base64,{}",
            base64::engine::general_purpose::STANDARD.encode(&bytes)
        );
        let mut r = json!({"operation":"save","world":["fixture",1],"task":"t","revision":1,"side":"before","data":data});
        assert!(request(r.clone()).unwrap()["images"]["before"].is_object());
        r["side"] = json!("after");
        request(r.clone()).unwrap();
        r["operation"] = json!("list");
        assert_eq!(
            request(r.clone()).unwrap()["images"]
                .as_object()
                .unwrap()
                .len(),
            2
        );
        let frame = json!({"available":true,"world":{"world_incarnation":"fixture","world_generation":1},"projection":{"development_tasks":{"t":{"revision":1}}}});
        assert!(observed(&frame, "t")["record"]["images"]["before"].is_object());
        assert_eq!(observed(&frame, "unknown")["available"], false);
        assert_eq!(
            observed(&json!({"available":false}), "t")["available"],
            false
        );
        let record = request(r.clone()).unwrap();
        let mut save_review = r.clone();
        save_review["operation"] = json!("save_review");
        save_review["review"] = json!({"basis":{"criteria":"Readable names","before":record["images"]["before"]["sha256"],"after":record["images"]["after"]["sha256"]},"findings":{"summary":"Test","requirements":[{"index":1,"requirement":"Readable names","status":"met","reason":"Names are visible"}],"regressions":[]}});
        let mut invalid = save_review.clone(); invalid["review"]["findings"]["requirements"] = json!([]);
        assert!(request(invalid).is_err());
        assert!(request(save_review.clone()).unwrap()["review"].is_object());
        save_review["review"]["basis"]["before"] = json!("wrong-image");
        assert!(request(save_review).is_err());
        r["operation"] = json!("remove");
        r["side"] = json!("invalid");
        assert!(request(r.clone()).is_err());
        r["side"] = json!("before");
        let removed = request(r.clone()).unwrap();
        assert!(removed["images"]["before"].is_null());
        assert!(removed["images"]["after"].is_object());
        assert!(observed(&frame, "t")["record"]["images"]["before"].is_null());
        r["operation"] = json!("save");
        request(r.clone()).unwrap(); // Undo can restore the original bytes.
        assert!(observed(&frame, "t")["record"]["images"]["before"].is_object());
        r["operation"] = json!("remove");
        request(r.clone()).unwrap();
        r["side"] = json!("after");
        assert!(request(r.clone()).unwrap()["images"]
            .as_object()
            .unwrap()
            .is_empty());
        assert_eq!(
            std::fs::read_dir(dir.join("task-screenshots"))
                .unwrap()
                .count(),
            0
        );
        assert!(request(r.clone()).is_ok()); // Removal is idempotent.
        r["operation"] = json!("list");
        r["revision"] = json!(2);
        assert!(request(r.clone()).unwrap()["images"]
            .as_object()
            .unwrap()
            .is_empty());
        r["operation"] = json!("save");
        r["data"] = json!("data:image/svg+xml;base64,anything");
        assert!(request(r.clone()).is_err());
        r["data"] = json!(format!(
            "data:image/png;base64,{}",
            base64::engine::general_purpose::STANDARD.encode(&bytes[..24])
        ));
        assert!(request(r).is_err());
        let mut log = json!({"operation":"save_output","world":["fixture",1],"task":"log-task","revision":1,"side":"before","output":{"text":"latency_ms: 34\n","command":"node benchmark.mjs --requests 256; unit: ms","source":"commit-before","environment":"lab Linux / Node"}});
        assert_eq!(request(log.clone()).unwrap()["outputs"]["before"]["origin"],"manual-import");
        log["side"] = json!("after"); log["output"]["text"] = json!("latency_ms: 0.014\n");
        assert!(request(log.clone()).unwrap()["outputs"]["before"].is_object());
        let mut bad = log.clone(); bad["output"]["text"] = json!("x".repeat(100001)); assert!(request(bad).is_err());
        let mut bad = log.clone(); bad["output"]["source"] = json!(""); assert!(request(bad).is_err());
        log["operation"] = json!("remove"); assert!(request(log.clone()).unwrap()["outputs"]["before"].is_object());
        log["operation"] = json!("remove_output");request(log.clone()).unwrap();log["side"]=json!("before");request(log.clone()).unwrap();
        log["operation"] = json!("list");assert!(request(log).unwrap()["outputs"].is_null());
        let _ = std::fs::remove_dir_all(dir);
    }
}

/// Capture only a selected local preview, never an unrelated window or screen.
#[cfg(target_os="linux")]
pub async fn capture_preview(mut r: Value, app: tauri::AppHandle) -> Result<Value,String> {
    use tauri::Manager;
    use webkit2gtk::WebViewExt;
    let tab=r["tab"].as_u64().filter(|t| *t<8).ok_or("Choose an open local preview tab.")?;
    key(&r["world"],r["task"].as_str().ok_or("Missing task.")?,r["revision"].as_u64().ok_or("Missing revision.")?)?;
    if !["before","after"].contains(&r["side"].as_str().unwrap_or("")) {return Err("Choose Before or After.".into());}
    let label=if tab==0 {"development-preview".to_string()} else {format!("development-preview-{tab}")};
    let view=app.get_webview(&label).ok_or("Open the local app in Browser first.")?;
    let expected=view.url().map_err(|e|e.to_string())?;
    if !matches!(expected.scheme(),"http"|"https") || !matches!(expected.host_str(),Some("localhost"|"127.0.0.1"|"[::1]")) {return Err("Capture is limited to a local app preview.".into());}
    let url=expected.to_string();let target=url.clone();let (send,recv)=std::sync::mpsc::sync_channel(1);
    view.with_webview(move |platform|{
        let webview=platform.inner();let check=webview.clone();
        if webview.is_loading(){let _=send.send(Err("The preview is still loading. Wait for it to finish.".into()));return;}
        webview.snapshot(webkit2gtk::SnapshotRegion::Visible,webkit2gtk::SnapshotOptions::NONE,None::<&gtk::gio::Cancellable>,move |result|{
            let result=(||->Result<Vec<u8>,String>{
                if check.uri().as_deref()!=Some(target.as_str()) {return Err("The preview navigated during capture. Try again.".into());}
                let original=gtk::cairo::ImageSurface::try_from(result.map_err(|e|e.to_string())?).map_err(|_|"Preview did not produce a raster image.")?;
                let (w,h)=(original.width(),original.height());if w<=0||h<=0||w>4096||h>4096{return Err("Preview dimensions must be at most 4096 pixels.".into());}
                let mut surface=gtk::cairo::ImageSurface::create(gtk::cairo::Format::Rgb24,w,h).map_err(|e|e.to_string())?;
                {let ctx=gtk::cairo::Context::new(&surface).map_err(|e|e.to_string())?;ctx.set_source_rgb(1.,1.,1.);ctx.paint().map_err(|e|e.to_string())?;ctx.set_source_surface(&original,0.,0.).map_err(|e|e.to_string())?;ctx.paint().map_err(|e|e.to_string())?;}
                let stride=surface.stride() as usize;let pixels=surface.data().map_err(|e|e.to_string())?;let mut rgb=Vec::with_capacity((w*h*3) as usize);
                for y in 0..h as usize {for x in 0..w as usize {let i=y*stride+x*4;let pixel=u32::from_ne_bytes(pixels[i..i+4].try_into().unwrap());rgb.extend_from_slice(&[(pixel>>16)as u8,(pixel>>8)as u8,pixel as u8]);}}
                let mut bytes=Vec::new();{let mut encoder=png::Encoder::new(&mut bytes,w as u32,h as u32);encoder.set_color(png::ColorType::Rgb);encoder.set_depth(png::BitDepth::Eight);let mut writer=encoder.write_header().map_err(|e|e.to_string())?;writer.write_image_data(&rgb).map_err(|e|e.to_string())?;}
                if bytes.len()>2_000_000{return Err("Captured image exceeds 2 MB. Reduce the preview size.".into());}Ok(bytes)
            })();let _=send.send(result);
        });
    }).map_err(|e|e.to_string())?;
    let bytes=tauri::async_runtime::spawn_blocking(move||recv.recv_timeout(std::time::Duration::from_secs(10)).map_err(|_|"Preview capture timed out.".to_string())?).await.map_err(|e|e.to_string())??;
    r["operation"]=json!("save");r["data"]=json!(format!("data:image/png;base64,{}",base64::engine::general_purpose::STANDARD.encode(bytes)));
    // Metadata originates here; ordinary uploads cannot assert a native capture.
    save_captured(r,json!({"kind":"local-preview","url":url,"tab":tab}))
}
fn save_captured(r:Value,origin:Value)->Result<Value,String>{
    let mut value=request(r.clone())?;
    let _guard=WRITE.lock().map_err(|_|"Evidence storage is busy.")?;
    let id=key(&r["world"],r["task"].as_str().unwrap(),r["revision"].as_u64().unwrap())?;
    // Reload to prevent replacing an intervening edit with an older record.
    let path=ROOT.get().unwrap().join(format!("{id}.json"));
    let current:Value=serde_json::from_slice(&std::fs::read(path).map_err(|e|e.to_string())?).map_err(|e|e.to_string())?;
    let side=r["side"].as_str().unwrap();if current["images"][side]["sha256"]!=value["images"][side]["sha256"] {return Err("Screenshot changed during capture storage.".into());}value=current;
    value["images"][side]["capture"]=origin;retain(ROOT.get().unwrap(),&id,&value)?;Ok(value)
}

// Runner-owned comparison is separate from manually supplied logs.
pub fn retain_comparison(world:&Value,task:&str,revision:u64,run_id:&str,result:&Value)->Result<(),String>{
    let query=json!({"operation":"list","world":world,"task":task,"revision":revision});
    request(query)?;
    let _guard=WRITE.lock().map_err(|_|"Evidence storage is busy.")?;
    let id=key(world,task,revision)?;let root=ROOT.get().ok_or("Evidence storage unavailable.")?;
    let path=root.join(format!("{id}.json"));let mut value=match std::fs::read(&path){Ok(bytes)=>serde_json::from_slice::<Value>(&bytes).map_err(|e|e.to_string())?,Err(e) if e.kind()==std::io::ErrorKind::NotFound=>json!({"world":world,"task":task,"revision":revision,"images":{}}),Err(e)=>return Err(e.to_string())};
    let side=|r:&Value|{let full=r["output"].as_str().unwrap_or("");let output=full.chars().take(20000).collect::<String>();json!({"snapshot":r["snapshot_sha256"],"state":r["state"],"verdict":r["verdict"],"exit_code":r["exit_code"],"output":output,"truncated":output.len()<full.len()||r["omitted_bytes"].as_u64().unwrap_or(0)>0})};
    value["comparison"]=json!({"origin":"isolated-proposal-runner","run_id":run_id,"profile":result["profile"],"before":side(&result["baseline"]),"after":side(result),"benchmark":result["benchmark"]});retain(root,&id,&value)
}
