// Test the native app's actual review-recovery and Codex reply modules.
// This focused target does not compile Tauri or launch the desktop UI.
#[path = "../../../cockpit/src/review_tests.rs"]
pub mod review_tests;
#[path = "../../../cockpit/src/codex_connection.rs"]
pub mod codex_connection;

#[path = "../../../cockpit/src/accepted_builds.rs"]
pub mod accepted_builds;

#[path = "../../../cockpit/src/accepted_preview.rs"]
pub mod accepted_preview;
