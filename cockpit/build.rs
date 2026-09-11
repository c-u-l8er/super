//! **The application's own commands are declared to the ACL here, and W.2
//! did not do this.**
//!
//! Tauri's default is that commands registered through `invoke_handler` are
//! reachable from every window and webview in the application. Capabilities
//! then look like they are describing the whole authority surface while
//! describing only the plugin half of it: W.2's capability said the cockpit
//! "may listen for frames and nothing else" beside an `intent` command that
//! any webview the process ever opened could have called.
//!
//! `AppManifest::commands` autogenerates an `allow-$command` / `deny-$command`
//! permission for each name, which makes them grantable — and therefore
//! withholdable. `capabilities/default.json` grants them to `main`.
//!
//! Adding a command to `invoke_handler` without adding it here leaves it
//! outside the ACL again, so the two lists are checked against each other by
//! `tools/check-webview-acl.mjs` rather than by whoever remembers.
fn main() {
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&[
            "bind_frame_stream",
            "unbind_frame_stream",
            "intent",
            "choose_repository",
            "choose_workbench",
            "development_request",
            "review_tests",
            "browser_surface",
            "surface_sessions",
            "choose_attachments",
            "desktop_window",
            "mobile_status",
            "mobile_new_code",
            "bot_configure",
            "bot_forget_key",
            "bot_chat",
            "bot_connection",
            "bot_claude_connection",
            "bot_local_models",
            "bot_models",
            "frame_ack",
            "hold_begin",
            "hold_end",
            "terminal_stream",
            "terminal_ack",
            "terminal_close",
            "terminal_surface",
        ]),
    ))
    .expect("failed to run tauri-build");
}
