//! An untrusted, loopback-only child WebView. No capability names its label.
use serde::Deserialize;
use serde_json::{json, Value};
use tauri::{Manager, Url};
const LABEL: &str = "development-preview";
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Rect {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}
fn allowed(url: &Url) -> bool {
    matches!(url.scheme(), "http" | "https")
        && url.username().is_empty()
        && url.password().is_none()
        && matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"))
}
fn address(value: &str) -> Result<Url, String> {
    if value.len() > 4096 {
        return Err("The preview address is too long.".into());
    }
    let url = Url::parse(value)
        .map_err(|_| "Enter a full local address, such as http://localhost:3000.")?;
    if !allowed(&url) {
        return Err(
            "Preview a local app at localhost, 127.0.0.1, or [::1] using HTTP or HTTPS.".into(),
        );
    }
    Ok(url)
}
pub fn surface(
    action: String,
    url: Option<String>,
    rect: Option<Rect>,
    tab: u8,
    app: tauri::AppHandle,
) -> Result<Value, String> {
    if tab > 7 {
        return Err("Up to eight browser tabs are supported.".into());
    }
    let label = if tab == 0 {
        LABEL.to_owned()
    } else {
        format!("{LABEL}-{tab}")
    };
    if action == "worker_hide" {
        if let Some(w) = app.get_webview("terminal") {
            w.hide().map_err(|e| e.to_string())?;
        }
        return Ok(json!({"visible":false}));
    }
    if action == "hide_all" || action == "open" || action == "layout" {
        for (name, view) in app.webviews() {
            if (name == LABEL || name.starts_with(&format!("{LABEL}-")))
                && (action == "hide_all" || name != label)
            {
                view.hide().map_err(|e| e.to_string())?;
            }
        }
        if action == "hide_all" {
            return Ok(json!({"visible":false}));
        }
    }
    if action == "status" {
        let tabs: Vec<Value> = (0..8)
            .filter_map(|id| {
                let name = if id == 0 {
                    LABEL.to_owned()
                } else {
                    format!("{LABEL}-{id}")
                };
                app.get_webview(&name)
                    .map(|v| json!({"id":id,"url":v.url().ok().map(|u|u.to_string())}))
            })
            .collect();
        return Ok(json!({"tabs":tabs}));
    }
    let existing = app.get_webview(&label);
    match action.as_str() {
        "hide" => {
            if let Some(w) = existing {
                w.hide().map_err(|e| e.to_string())?;
            }
            return Ok(json!({"visible":false}));
        }
        "close" => {
            if let Some(w) = existing {
                w.close().map_err(|e| e.to_string())?;
                app.state::<crate::surface_sessions::Sessions>()
                    .forget_browser(tab);
            }
            return Ok(json!({"visible":false}));
        }
        "open" | "layout" | "worker_layout" => {}
        _ => return Err("Unknown browser action.".into()),
    }
    let location = if action == "open" {
        Some(address(url.as_deref().ok_or("Enter a preview address.")?)?)
    } else {
        None
    };
    let r = rect.ok_or("The browser area is unavailable.")?;
    let main = app
        .get_window("main")
        .ok_or("The app window is unavailable.")?;
    let size = main.inner_size().map_err(|e| e.to_string())?;
    let scale = main.scale_factor().map_err(|e| e.to_string())?;
    if ![r.x, r.y, r.width, r.height].iter().all(|n| n.is_finite())
        || r.x < 0.
        || r.y < 0.
        || r.width < 40.
        || r.height < 40.
        || r.x + r.width > size.width as f64 / scale + 1.
        || r.y + r.height > size.height as f64 / scale + 1.
    {
        return Err("The browser area is too small. Enlarge the app window.".into());
    }
    if action == "worker_layout" {
        let w = app
            .get_webview("terminal")
            .ok_or("Worker terminal is not open.")?;
        position(&w, &r)?;
        w.show().map_err(|e| e.to_string())?;
        return Ok(json!({"visible":true}));
    }
    if let Some(w) = existing {
        position(&w, &r)?;
        if let Some(url) = location {
            w.navigate(url).map_err(|e| e.to_string())?;
        }
        w.show().map_err(|e| e.to_string())?;
    } else if let Some(url) = location {
        app.state::<crate::surface_sessions::Sessions>()
            .forget_browser(tab);
        let w = main
            .add_child(
                tauri::webview::WebviewBuilder::new(&label, tauri::WebviewUrl::External(url))
                    .on_navigation(allowed)
                    .on_new_window(|_, _| tauri::webview::NewWindowResponse::Deny),
                tauri::LogicalPosition::new(r.x, r.y),
                tauri::LogicalSize::new(r.width, r.height),
            )
            .map_err(|e| e.to_string())?;
        position(&w, &r)?;
    }
    Ok(json!({"visible":app.get_webview(&label).is_some()}))
}
// Tauri's Linux child WebViews are packed in a vertical GtkBox; their
// set_position/set_size methods do not position them inside the cockpit.
// Put the untrusted widget in a GTK overlay without changing its IPC label.
#[cfg(target_os = "linux")]
fn position(view: &tauri::Webview, r: &Rect) -> Result<(), String> {
    let (send, receive) = std::sync::mpsc::sync_channel(1);
    let (x, y, width, height) = (
        r.x.round() as i32,
        r.y.round() as i32,
        r.width.round() as i32,
        r.height.round() as i32,
    );
    view.with_webview(move |platform| {
        use gtk::prelude::*;
        let result = (|| {
            let widget: gtk::Widget = platform.inner().upcast();
            let parent = widget.parent().ok_or("The preview has no native parent.")?;
            if let Ok(container) = parent.clone().downcast::<gtk::Box>() {
                let overlay = if let Some(existing) = container
                    .children()
                    .into_iter()
                    .find(|w| w.widget_name() == "super-development-overlay")
                {
                    existing
                        .downcast::<gtk::Overlay>()
                        .map_err(|_| "The preview container is unavailable.")?
                } else {
                    let main = container
                        .children()
                        .into_iter()
                        .find(|w| w != &widget && w.type_().name() == "WebKitWebView")
                        .ok_or("The cockpit widget is unavailable.")?;
                    let overlay = gtk::Overlay::new();
                    overlay.set_widget_name("super-development-overlay");
                    overlay.set_hexpand(true);
                    overlay.set_vexpand(true);
                    container.remove(&main);
                    overlay.add(&main);
                    container.pack_start(&overlay, true, true, 0);
                    main.set_size_request(1, 1);
                    main.show();
                    overlay.show();
                    overlay
                };
                container.remove(&widget);
                overlay.add_overlay(&widget);
                overlay.set_overlay_pass_through(&widget, false);
            } else if parent.downcast::<gtk::Overlay>().is_err() {
                return Err("The preview container is unsupported.");
            }
            widget.set_halign(gtk::Align::Start);
            widget.set_valign(gtk::Align::Start);
            widget.set_margin_start(x);
            widget.set_margin_top(y);
            widget.set_size_request(width, height);
            widget.show();
            Ok(())
        })()
        .map_err(str::to_owned);
        let _ = send.send(result);
    })
    .map_err(|e| e.to_string())?;
    receive
        .recv_timeout(std::time::Duration::from_secs(3))
        .map_err(|_| "The browser layout did not finish.".to_owned())?
}
#[cfg(not(target_os = "linux"))]
fn position(view: &tauri::Webview, r: &Rect) -> Result<(), String> {
    view.set_position(tauri::LogicalPosition::new(r.x, r.y))
        .map_err(|e| e.to_string())?;
    view.set_size(tauri::LogicalSize::new(r.width, r.height))
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn local_addresses_only() {
        for u in [
            "http://localhost:3000",
            "http://127.0.0.1:8080/a?b=c",
            "https://[::1]:4443/",
        ] {
            assert!(address(u).is_ok(), "{u}");
        }
        for u in [
            "file:///etc/passwd",
            "tauri://localhost",
            "javascript:alert(1)",
            "http://localhost.evil.test",
            "http://user@localhost:3000",
            "https://example.com",
            "http://192.168.1.1",
        ] {
            assert!(address(u).is_err(), "{u}");
        }
    }
}
