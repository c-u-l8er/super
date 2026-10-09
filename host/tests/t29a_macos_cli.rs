//! T29a · **A2**, the CLI's half (`superlane/t29a/TASK.md`): on macOS the Carrier floor's three subcommands and `verify`
//! refuse by name, through the built `super-host`, with exit code 2 and nothing on stdout.
#![cfg(target_os = "macos")]

use std::process::Command;

const FLOOR: &str = "carriers and terminals run on a Linux node until M2";
const BATTERY: &str = "the acceptance battery runs on Linux until M2";

fn run(args: &[&str], ampd_dir: &std::path::Path) -> (Option<i32>, String, String) {
    let o = Command::new(env!("CARGO_BIN_EXE_super-host")).args(args).env("AMPD_DIR", ampd_dir).output().unwrap();
    (o.status.code(), String::from_utf8_lossy(&o.stdout).into_owned(), String::from_utf8_lossy(&o.stderr).into_owned())
}

#[test]
fn a2_the_cli_s_carrier_floor_and_verify_refuse_by_name() {
    // An `ampd/` that passes the CLI's mix.exs check, so `verify` reaches its own arm.
    let d = std::env::temp_dir().join(format!("t29a-a2-cli-{}", std::process::id()));
    std::fs::create_dir_all(&d).unwrap();
    std::fs::write(d.join("mix.exs"), "").unwrap();
    for (cmd, text) in [("effect", FLOOR), ("identity", FLOOR), ("carrier-orphan-fixture", FLOOR), ("verify", BATTERY)] {
        let (code, out, err) = run(&[cmd], &d);
        assert_eq!(code, Some(2), "super-host {cmd}: exit {code:?}, stderr {err}");
        assert_eq!(err.trim_end(), format!("super-host {cmd}: {text}"), "super-host {cmd}");
        assert!(out.is_empty(), "super-host {cmd} printed on stdout: {out}");
    }
    std::fs::remove_dir_all(&d).unwrap();
}
