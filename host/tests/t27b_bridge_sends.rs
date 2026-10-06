//! T27b's scans of `src/lib.rs`.
//!
//! B3: every send on the bridge is size-checked, so none can hand the runtime a cut command. Since round 3 every send
//! goes through `Runtime`'s two bridge senders, which use `fdpass::send_bridge_plain` (or its no-wait form) and
//! `fdpass::send_bridge_with_fds`.
//!
//! B7 (round 3, Codex review 2, finding 1): every checked send is INSIDE those two senders, and each of them drains an
//! owed reply first and marks its own reply owed, so no send escapes the reply accounting.

fn src() -> String {
    std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/src/lib.rs")).unwrap()
}

/// The text of `fn <name>` (an `impl Runtime` method, indented four spaces), from its signature to its closing brace.
fn body<'a>(src: &'a str, name: &str) -> &'a str {
    let i = src.find(&format!("    fn {name}(")).unwrap_or_else(|| panic!("no fn {name}"));
    let j = src[i..].find("\n    }\n").expect("the end of the fn") + i;
    &src[i..j]
}

const SENDERS: [&str; 2] = ["bridge_send_plain", "bridge_send_with_fds"];

/// `src` without the two senders' bodies.
fn outside_the_senders(src: &str) -> String {
    let mut rest = src.to_string();
    for s in SENDERS {
        let b = body(src, s).to_string();
        rest = rest.replacen(&b, "", 1);
    }
    rest
}

#[test]
fn every_bridge_send_is_size_checked() {
    let src = src();
    for raw in ["fdpass::send_plain(self.bridge", "fdpass::send_with_fd(self.bridge", "fdpass::send_with_fds(self.bridge"] {
        assert!(!src.contains(raw), "an unchecked bridge send: {raw}");
    }
    for s in SENDERS {
        assert!(body(&src, s).contains("fdpass::send_bridge_"), "{s} does not send through a size-checked sender");
    }
    // Not vacuous: T27b found 8 bridge sends, and round 3's bounded call is a ninth. Counted wherever they are.
    let sites = src.matches("self.bridge_send_plain(").count() + src.matches("self.bridge_send_with_fds(").count();
    let direct = outside_the_senders(&src).matches("fdpass::send_bridge_").count();
    assert!(sites + direct >= 9, "{} size-checked bridge sends; T27b round 3 counts 9", sites + direct);
}

#[test]
fn b7_every_checked_bridge_send_is_inside_the_reply_accounting() {
    let src = src();
    assert!(
        !outside_the_senders(&src).contains("fdpass::send_bridge_"),
        "a bridge send outside bridge_send_plain and bridge_send_with_fds escapes the owed-reply accounting"
    );
    for s in SENDERS {
        let b = body(&src, s);
        assert!(b.contains("self.bridge_drain("), "{s} sends without draining an owed reply first");
        assert!(b.contains("bridge_owed.store(true"), "{s} sends without marking its reply owed");
    }
}
