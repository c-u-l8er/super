//! T27 · **L5** — on a target T27 does not support, the build stops at a
//! `compile_error!`; it never compiles.
//!
//! Measured on the Mac at `1069cdc` (2026-10-02): `cargo check -p super-host`
//! PASSED on macOS arm64, because the host declared `syscall(2)` by hand with
//! x86-64 Linux numbers — a Mac build would have run and made the wrong calls
//! (macOS's syscall 16 is `chown`). libc's numbers fix every Linux
//! architecture; nothing fixes Landlock or `TIOCGPTPEER` on macOS. So the
//! crate root refuses any non-Linux target by name, and every Linux-only
//! module is compiled for Linux only.
//!
//! This test reads `host/src/lib.rs` and holds that structure: it cannot
//! build for macOS here (that target is not installed, and installing it is a
//! download). Its behavioural half is `superlane/t27/platform-gate.sh`, which
//! checks a copy of the crate with the predicate made false and requires
//! exactly one error, this gate's; the Mac session confirms the real one.

use std::path::PathBuf;

const GATE: &str = "#[cfg(target_os = \"linux\")]";
const REFUSE: &str = "#[cfg(not(target_os = \"linux\"))]";
/// Modules that are not behind the gate, and why: each must be plain Rust.
const PORTABLE: &[&str] = &["sha256"];

fn lib_rs() -> String {
    std::fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src/lib.rs")).unwrap()
}

/// Root-level lines: those outside `mod linux_layer { … } // mod linux_layer`,
/// comments and blank lines dropped.
fn root_lines(src: &str) -> Vec<(usize, String)> {
    let mut out = Vec::new();
    let mut inside = false;
    for (i, l) in src.lines().enumerate() {
        let t = l.trim();
        if t == "mod linux_layer {" {
            inside = true;
            out.push((i + 1, t.to_string()));
            continue;
        }
        if inside {
            if l == "} // mod linux_layer" {
                inside = false;
                out.push((i + 1, t.to_string()));
            }
            continue;
        }
        if t.is_empty() || t.starts_with("//") {
            continue;
        }
        out.push((i + 1, t.to_string()));
    }
    out
}

#[test]
fn t27_l5_a_non_linux_target_is_refused_by_name_and_linux_pieces_are_gated() {
    let src = lib_rs();
    let lines = root_lines(&src);
    let at = |k: usize| lines.get(k).map(|(_, t)| t.as_str()).unwrap_or("");

    // 1 · the refusal: under exactly the negated predicate, naming its successors
    let r = lines
        .iter()
        .position(|(_, t)| t == REFUSE)
        .expect("lib.rs has no #[cfg(not(target_os = \"linux\"))] at its root");
    assert_eq!(at(r + 1), "compile_error!(", "the refusal is not a compile_error! at the crate root");
    let msg_from = src.find("compile_error!(").unwrap();
    let msg = &src[msg_from..msg_from + src[msg_from..].find(");").unwrap()];
    for needed in ["Linux", "T28", "T29"] {
        assert!(msg.contains(needed), "the refusal does not name {needed}: {msg}");
    }

    // 2 · every crate-root item is the refusal, a gated item, a portable module,
    //     or doc text — nothing compiles for a non-Linux target but `PORTABLE`
    let mut k = 0;
    let mut gated_mods = Vec::new();
    let mut saw_layer = false;
    let mut saw_reexport = false;
    while k < lines.len() {
        let t = at(k).to_string();
        if t.starts_with("//!") || t.starts_with("///") {
            k += 1;
            continue;
        }
        if t == REFUSE {
            // the refusal's own macro call, to its closing `);`
            k += 1;
            while k < lines.len() && !at(k).ends_with(");") {
                k += 1;
            }
            k += 1;
            continue;
        }
        if t == GATE {
            let item = at(k + 1).to_string();
            if let Some(m) = item.strip_prefix("pub mod ").and_then(|m| m.strip_suffix(';')) {
                gated_mods.push(m.to_string());
            } else if item == "pub use linux_layer::*;" {
                saw_reexport = true;
            } else if item == "mod linux_layer {" {
                saw_layer = true;
                assert_eq!(at(k + 2), "} // mod linux_layer", "something sits between the layer's open and close");
                k += 1;
            } else {
                panic!("lib.rs:{} gated item of an unexpected shape: {item}", lines[k + 1].0);
            }
            k += 2;
            continue;
        }
        if let Some(m) = t.strip_prefix("pub mod ").and_then(|m| m.strip_suffix(';')) {
            assert!(PORTABLE.contains(&m), "lib.rs:{} `pub mod {m};` is not behind the gate", lines[k].0);
            k += 1;
            continue;
        }
        panic!("lib.rs:{} an ungated item at the crate root: {t}", lines[k].0);
    }
    assert!(saw_layer, "the Linux layer module was not found behind the gate");
    assert!(saw_reexport, "the Linux layer's re-export was not found behind the gate");
    for m in ["effect", "fdpass", "confine", "pty", "attach", "carrier", "verify"] {
        assert!(gated_mods.iter().any(|g| g == m), "`{m}` is not declared behind the gate: {gated_mods:?}");
    }

    // 3 · a portable module is portable: no libc, no unix extension, no /proc, no unsafe
    //     (in its code; its comments may name what it is used for)
    for m in PORTABLE {
        let body: String = std::fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(format!("src/{m}.rs")))
            .unwrap()
            .lines()
            .filter(|l| !l.trim_start().starts_with("//"))
            .collect::<Vec<_>>()
            .join("\n");
        for bad in ["libc::", "std::os::", "/proc", "unsafe", "extern \"C\""] {
            assert!(!body.contains(bad), "{m}.rs is declared portable and contains `{bad}`");
        }
    }
}
