//! T27b B3 (the scan): every send on the bridge in `src/lib.rs` goes through the size-checked senders
//! (`fdpass::send_bridge_plain`, `fdpass::send_bridge_with_fds`), so none can hand the runtime a cut command.
#[test]
fn every_bridge_send_is_size_checked() {
    let src = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/src/lib.rs")).unwrap();
    for raw in ["fdpass::send_plain(self.bridge", "fdpass::send_with_fd(self.bridge", "fdpass::send_with_fds(self.bridge"] {
        assert!(!src.contains(raw), "an unchecked bridge send: {raw}");
    }
    let n = src.matches("fdpass::send_bridge_").count();
    assert!(n >= 8, "{n} size-checked bridge sends; T27b found 8 bridge sends");
}
