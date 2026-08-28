//! `super-host`, the binary. Every line of it is in the library, because
//! the Tauri cockpit runs the same `CockpitLoop` and a second copy of a
//! state machine is a second set of laws.
fn main() {
    std::process::exit(super_host::cli());
}
