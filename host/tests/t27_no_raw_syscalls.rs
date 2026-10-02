//! T27 · **L2** — no numeric syscall literal and no raw `extern` block in
//! `host/src`.
//!
//! Until T27 the host spelled its syscalls as x86-64 numbers (`444`, `317`,
//! the whole seccomp deny list) through its own `extern "C"` blocks, which made
//! the floor x86-64's floor and nothing else's. Since T27 every number comes
//! from `libc::SYS_*` and every C function from the libc crate. This test is
//! what keeps it that way: it reads every `host/src/*.rs` at test time (so a
//! new file is covered without being listed), strips comments, and refuses
//!
//!   1. an `extern "C" {` block;
//!   2. a `syscall(` whose first argument is not `libc::SYS_…`;
//!   3. a `SYS_*` or `NR_*` constant defined by a number;
//!   4. a BPF comparison against a numeric literal (`BPF_K, <digit>`);
//!   5. `denies(<digit>`;
//!   6. a numeric entry in `confine.rs`'s `DENIED` or `verify.rs`'s `CENSUS`,
//!      both of which must be found (a renamed table must not switch this off).
//!
//! It lives in `host/tests`, outside `host/src`, so its own patterns are not
//! scanned.

use std::path::PathBuf;

/// The source with every comment replaced by spaces, strings and code kept.
/// A small state machine rather than a regex, because `"//"` inside a string
/// is not a comment and `/* … */` can sit in the middle of an expression.
fn strip_comments(src: &str) -> String {
    let b: Vec<char> = src.chars().collect();
    let mut out = String::with_capacity(src.len());
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        let next = b.get(i + 1).copied();
        if c == '/' && next == Some('/') {
            while i < b.len() && b[i] != '\n' {
                i += 1;
            }
            continue;
        }
        if c == '/' && next == Some('*') {
            let mut depth = 0;
            while i < b.len() {
                if b[i] == '/' && b.get(i + 1) == Some(&'*') {
                    depth += 1;
                    i += 2;
                } else if b[i] == '*' && b.get(i + 1) == Some(&'/') {
                    depth -= 1;
                    i += 2;
                    if depth == 0 {
                        break;
                    }
                } else {
                    out.push(if b[i] == '\n' { '\n' } else { ' ' });
                    i += 1;
                }
            }
            out.push(' ');
            continue;
        }
        if c == 'r' && (next == Some('"') || next == Some('#')) && !prev_is_ident(&b, i) {
            // a raw string: r"…" or r#"…"#
            let mut j = i + 1;
            let mut hashes = 0;
            while b.get(j) == Some(&'#') {
                hashes += 1;
                j += 1;
            }
            if b.get(j) == Some(&'"') {
                let close: String = std::iter::once('"').chain(std::iter::repeat('#').take(hashes)).collect();
                let rest: String = b[j + 1..].iter().collect();
                let end = rest.find(&close).map(|e| j + 1 + rest[..e].chars().count() + close.len()).unwrap_or(b.len());
                out.extend(&b[i..end]);
                i = end;
                continue;
            }
        }
        if c == '"' {
            out.push(c);
            i += 1;
            while i < b.len() {
                out.push(b[i]);
                if b[i] == '\\' {
                    if let Some(&e) = b.get(i + 1) {
                        out.push(e);
                    }
                    i += 2;
                    continue;
                }
                i += 1;
                if b[i - 1] == '"' {
                    break;
                }
            }
            continue;
        }
        if c == '\'' {
            // a char literal ('x', '\n', '\'') or a lifetime ('a)
            if next == Some('\\') {
                let mut j = i + 3;
                while j < b.len() && b[j] != '\'' {
                    j += 1;
                }
                out.extend(&b[i..=j.min(b.len() - 1)]);
                i = j + 1;
                continue;
            }
            if b.get(i + 2) == Some(&'\'') {
                out.extend(&b[i..i + 3]);
                i += 3;
                continue;
            }
        }
        out.push(c);
        i += 1;
    }
    out
}

fn prev_is_ident(b: &[char], i: usize) -> bool {
    i > 0 && (b[i - 1].is_alphanumeric() || b[i - 1] == '_')
}

fn starts_numeric(s: &str) -> bool {
    s.trim_start().chars().next().is_some_and(|c| c.is_ascii_digit())
}

/// The text between `open` and the first `close` after it.
fn table<'a>(src: &'a str, open: &str, close: &str) -> Option<&'a str> {
    let a = src.find(open)? + open.len();
    let z = src[a..].find(close)? + a;
    Some(&src[a..z])
}

fn without_cfg_attrs(s: &str) -> String {
    let mut out = s.to_string();
    while let Some(a) = out.find("#[cfg(") {
        let z = out[a..].find(")]").map(|z| a + z + 2).unwrap_or(out.len());
        out.replace_range(a..z, " ");
    }
    out
}

fn line_of(src: &str, at: usize) -> usize {
    src[..at].matches('\n').count() + 1
}

#[test]
fn t27_l2_no_numeric_syscall_literal_and_no_raw_extern_in_host_src() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
        .expect("host/src")
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|x| x == "rs"))
        .collect();
    files.sort();
    assert!(files.len() >= 10, "scanned only {} files in {dir:?}", files.len());

    let mut bad: Vec<String> = Vec::new();
    let mut saw_denied = false;
    let mut saw_census = false;

    for f in &files {
        let name = f.file_name().unwrap().to_string_lossy().to_string();
        let code = strip_comments(&std::fs::read_to_string(f).unwrap());

        // 1 · an extern block
        let mut from = 0;
        while let Some(k) = code[from..].find("extern \"C\"") {
            let at = from + k;
            let after = code[at + "extern \"C\"".len()..].trim_start();
            if after.starts_with('{') {
                bad.push(format!("{name}:{} a raw extern \"C\" block", line_of(&code, at)));
            }
            from = at + 1;
        }

        // 2 · syscall( with anything but libc::SYS_ first
        let mut from = 0;
        while let Some(k) = code[from..].find("syscall(") {
            let at = from + k;
            let before = code[..at].chars().next_back();
            let is_call = !before.is_some_and(|c| c.is_alphanumeric() || c == '_');
            if is_call && !code[at + "syscall(".len()..].trim_start().starts_with("libc::SYS_") {
                bad.push(format!("{name}:{} syscall( without libc::SYS_ first", line_of(&code, at)));
            }
            from = at + 1;
        }

        for (i, l) in code.lines().enumerate() {
            let t = l.trim_start();
            // 3 · SYS_*/NR_* defined by a number
            for kw in ["const ", "static "] {
                if let Some(rest) = t.strip_prefix(kw).or_else(|| t.strip_prefix("pub ").and_then(|r| r.strip_prefix(kw))) {
                    let id: String = rest.chars().take_while(|c| c.is_alphanumeric() || *c == '_').collect();
                    if (id.starts_with("SYS_") || id.starts_with("NR_")) && rest.contains('=') {
                        let rhs = rest.split_once('=').unwrap().1;
                        if starts_numeric(rhs) {
                            bad.push(format!("{name}:{} {id} defined by a number", i + 1));
                        }
                    }
                }
            }
            // 4 · a BPF comparison against a numeric literal
            let mut from = 0;
            while let Some(k) = l[from..].find("BPF_K") {
                let at = from + k + "BPF_K".len();
                if let Some(rest) = l[at..].trim_start().strip_prefix(',') {
                    if starts_numeric(rest) {
                        bad.push(format!("{name}:{} a BPF comparison against a number", i + 1));
                    }
                }
                from = at;
            }
            // 5 · denies(<digit>
            if let Some(k) = l.find("denies(") {
                if starts_numeric(&l[k + "denies(".len()..]) {
                    bad.push(format!("{name}:{} denies() asked of a number", i + 1));
                }
            }
        }

        // 6 · the two tables: every entry named
        if name == "confine.rs" {
            if let Some(body) = table(&code, "const DENIED: &[u32] = &[", "];") {
                saw_denied = true;
                for item in without_cfg_attrs(body).split(',').map(str::trim).filter(|s| !s.is_empty()) {
                    let item = item.strip_prefix('(').and_then(|i| i.strip_suffix(')')).unwrap_or(item);
                    let ok = item.strip_prefix("libc::SYS_").and_then(|r| r.strip_suffix(" as u32")).is_some_and(|n| {
                        !n.is_empty() && n.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
                    });
                    if !ok {
                        bad.push(format!("confine.rs DENIED entry {item:?} is not libc::SYS_<name> as u32"));
                    }
                }
            }
        }
        if name == "verify.rs" {
            if let Some(body) = table(&code, "const CENSUS: &[(&str, u32, &str)] = &[", "];") {
                saw_census = true;
                for row in without_cfg_attrs(body).split("),").map(str::trim).filter(|s| !s.is_empty()) {
                    let fields: Vec<&str> = row.trim_start_matches('(').splitn(3, ", ").collect();
                    let nr = fields.get(1).copied().unwrap_or("");
                    let ok = nr.starts_with("libc::SYS_")
                        && (nr.ends_with(" as u32") || nr.ends_with(" as u32 | 0x4000_0000"));
                    if !ok {
                        bad.push(format!("verify.rs CENSUS row {row:?}: its number is not libc::SYS_<name>"));
                    }
                }
            }
        }
    }

    assert!(saw_denied, "confine.rs's DENIED table was not found: the guard would be blind to it");
    assert!(saw_census, "verify.rs's CENSUS table was not found: the guard would be blind to it");
    assert!(bad.is_empty(), "raw syscall numbers or extern blocks in host/src:\n  {}", bad.join("\n  "));
}

#[test]
fn t27_l2_the_guard_sees_what_it_refuses() {
    // The guard's own falsifier: each shape it refuses, written the way T26
    // wrote it, must be visible after comment stripping, and a comment or a
    // string mentioning it must not be.
    let t26 = "extern \"C\" {\n    fn close(fd: i32) -> i32;\n}\nconst SYS_IOCTL: i64 = 16; // ioctl\n\
               f.push(jump(BPF_JMP | BPF_JEQ | BPF_K, 157 /* prctl */, 0, 3));\nlet r = syscall(16, fd);\n";
    let s = strip_comments(t26);
    assert!(s.contains("extern \"C\" {"));
    assert!(s.contains("const SYS_IOCTL: i64 = 16;"));
    assert!(s.contains("BPF_K, 157 "));
    assert!(s.contains("syscall(16"));
    assert!(!s.contains("prctl"), "a block comment survived: {s}");
    let quiet = strip_comments("// syscall(16, …) was x86-64's\nlet u = \"http://x\"; // extern \"C\" {\n");
    assert!(!quiet.contains("syscall(16") && !quiet.contains("extern"), "{quiet}");
    assert!(quiet.contains("\"http://x\""), "a string was taken for a comment: {quiet}");
}
