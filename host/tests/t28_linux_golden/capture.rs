//! capture.rs (T28 L8, predeclared in superlane/t28/BASE.md): what the peer of a real Linux bridge pair receives for
//! every bridge send shape, byte for byte, and the source texts L8 guards. Only the base's public `fdpass` functions are
//! called; the peer is raw `recvmsg` (256 KiB of data, 4 KiB of control, MSG_DONTWAIT | MSG_CMSG_CLOEXEC) repeated until
//! EAGAIN, so a split, merged or extra record shows. Rights are distinct pipes, compared with what was sent by
//! dev/ino and closed. Deterministic: nothing run-dependent (descriptor numbers, inodes, times) is recorded.
use serde_json::{json, Map, Value};
use std::os::fd::RawFd;
use std::path::Path;
use super_host::{fdpass, sha256};

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn ino(fd: RawFd) -> (u64, u64) {
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    assert_eq!(unsafe { libc::fstat(fd, &mut st) }, 0, "fstat {fd}");
    (st.st_dev as u64, st.st_ino as u64)
}

fn so_type(fd: RawFd) -> i32 {
    let mut t: libc::c_int = 0;
    let mut l = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
    assert_eq!(unsafe { libc::getsockopt(fd, libc::SOL_SOCKET, libc::SO_TYPE, &mut t as *mut _ as *mut _, &mut l) }, 0);
    t
}

/// Every record the peer can read now, in order, until EAGAIN.
fn drain(fd: RawFd, sent: &[RawFd]) -> Value {
    let mut out = vec![];
    loop {
        let mut buf = vec![0u8; 256 * 1024];
        let mut ctrl = vec![0u8; 4096];
        let mut iov = libc::iovec { iov_base: buf.as_mut_ptr() as *mut _, iov_len: buf.len() };
        let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = ctrl.as_mut_ptr() as *mut _;
        msg.msg_controllen = ctrl.len() as _;
        let n = unsafe { libc::recvmsg(fd, &mut msg, libc::MSG_DONTWAIT | libc::MSG_CMSG_CLOEXEC) };
        if n < 0 {
            let e = std::io::Error::last_os_error();
            assert_eq!(e.raw_os_error(), Some(libc::EAGAIN), "the peer's recvmsg: {e}");
            break;
        }
        let (mut cmsgs, mut got) = (vec![], vec![]);
        unsafe {
            let mut c = libc::CMSG_FIRSTHDR(&msg);
            while !c.is_null() {
                let len = (*c).cmsg_len as usize;
                let data = len - libc::CMSG_LEN(0) as usize;
                let mut fds = vec![];
                if (*c).cmsg_level == libc::SOL_SOCKET && (*c).cmsg_type == libc::SCM_RIGHTS {
                    let p = libc::CMSG_DATA(c) as *const RawFd;
                    for i in 0..data / std::mem::size_of::<RawFd>() {
                        fds.push(std::ptr::read_unaligned(p.add(i)));
                    }
                }
                cmsgs.push(json!({"cmsg_len": len, "level": (*c).cmsg_level, "type": (*c).cmsg_type, "fds": fds.len()}));
                got.extend(fds);
                c = libc::CMSG_NXTHDR(&msg, c);
            }
        }
        let same = got.len() == sent.len() && got.iter().zip(sent).all(|(g, s)| ino(*g) == ino(*s));
        let cloexec: Vec<bool> = got.iter().map(|g| unsafe { libc::fcntl(*g, libc::F_GETFD) } & libc::FD_CLOEXEC != 0).collect();
        for g in &got {
            unsafe { libc::close(*g) };
        }
        out.push(json!({
            "len": n, "bytes": hex(&buf[..n as usize]), "msg_flags": msg.msg_flags,
            "msg_controllen": msg.msg_controllen, "cmsgs": cmsgs, "rights": got.len(),
            "rights_are_the_files_sent_in_order": same, "rights_cloexec": cloexec,
        }));
    }
    Value::Array(out)
}

fn pipes(n: usize) -> (Vec<RawFd>, Vec<RawFd>) {
    let (mut r, mut w) = (vec![], vec![]);
    for _ in 0..n {
        let mut p = [0; 2];
        assert_eq!(unsafe { libc::pipe2(p.as_mut_ptr(), libc::O_CLOEXEC) }, 0);
        r.push(p[0]);
        w.push(p[1]);
    }
    (r, w)
}

/// One shape on a fresh bridge pair: the sender's result and what the peer receives.
fn shape(send: impl FnOnce(RawFd, &[RawFd]) -> std::io::Result<()>, rights: usize) -> Value {
    let p = fdpass::pair_seqpacket().expect("pair_seqpacket");
    let (r, w) = pipes(rights);
    let res = send(p.0, &r);
    let peer = drain(p.1, &r);
    let types = json!({"ours": so_type(p.0), "theirs": so_type(p.1)});
    for fd in r.iter().chain(&w).chain([&p.0, &p.1]) {
        unsafe { libc::close(*fd) };
    }
    let result = match res {
        Ok(()) => json!({"ok": true}),
        Err(e) => json!({"ok": false, "kind": format!("{:?}", e.kind()), "error": e.to_string()}),
    };
    json!({"sender": result, "rights_sent": rights, "so_type": types, "peer": peer})
}

/// The text from the line starting `start` to the first later line that is exactly `end`, and its sha256.
fn block(text: &str, start: &str, end: &str) -> Value {
    let lines: Vec<&str> = text.split('\n').collect();
    let i = lines.iter().position(|l| l.starts_with(start)).unwrap_or_else(|| panic!("no line starting {start:?}"));
    let j = (i + 1..lines.len()).find(|&k| lines[k] == end).unwrap_or_else(|| panic!("no end {end:?} after {start:?}"));
    let t = lines[i..=j].join("\n");
    json!({"lines": format!("{}-{}", i + 1, j + 1), "bytes": t.len(), "sha256": sha256::digest(t.as_bytes())})
}

pub fn golden(tree: &Path) -> Value {
    let plain = br#"{"schema":"bridge-command@1","command":"status"}"#.to_vec();
    let bind = br#"{"schema":"bridge-command@1","command":"bind_agent_channel","actor":"agent:t28-golden"}"#.to_vec();
    let rejected: [(&str, Vec<u8>); 3] = [
        ("rejected-unknown-command", br#"{"schema":"bridge-command@1","command":"not-a-command"}"#.to_vec()),
        ("rejected-not-json", b"<<<not a frame>>>".to_vec()),
        ("rejected-bind-refused-actor", serde_json::to_vec(&json!({
            "schema": "bridge-command@1", "command": "bind_agent_channel", "actor": "x".repeat(200)})).unwrap()),
    ];
    let mut s = Map::new();
    let b = plain.clone();
    s.insert("plain".into(), shape(move |fd, _| fdpass::send_bridge_plain(fd, &b), 0));
    let b = plain.clone();
    s.insert("plain-nowait".into(), shape(move |fd, _| fdpass::send_bridge_plain_nowait(fd, &b), 0));
    for n in [1usize, 3, 5] {
        let b = bind.clone();
        s.insert(format!("rights-{n}"), shape(move |fd, r| fdpass::send_bridge_with_fds(fd, &b, r), n));
    }
    for (name, b) in rejected {
        s.insert(name.into(), shape(move |fd, r| fdpass::send_bridge_with_fds(fd, &b, r), 3));
    }
    s.insert("limit-8192".into(), shape(|fd, _| fdpass::send_bridge_plain(fd, &vec![b'x'; 8192]), 0));
    s.insert("over-limit-8193".into(), shape(|fd, _| fdpass::send_bridge_plain(fd, &vec![b'x'; 8193]), 0));
    s.insert("over-limit-8193-with-rights".into(), shape(|fd, r| fdpass::send_bridge_with_fds(fd, &vec![b'x'; 8193], r), 1));
    s.insert("empty".into(), shape(|fd, _| fdpass::send_bridge_plain(fd, b""), 0));
    let tx = std::fs::read_to_string(tree.join("ampd/lib/ampd/transport.ex")).unwrap();
    let fd = std::fs::read_to_string(tree.join("host/src/fdpass.rs")).unwrap();
    let mut src = Map::new();
    src.insert("transport.ex HostBridge.loop/1".into(), block(&tx, "    defp loop(sock) do", "    end"));
    for f in ["pair_seqpacket", "send_bridge_plain", "send_bridge_with_fds", "send_bridge_plain_nowait", "recv_msg", "recv_msg_nowait",
              "send_plain", "send_with_fds", "send_with_fds_count", "bridge_command_fits"] {
        let start = if fd.contains(&format!("\npub fn {f}(")) { format!("pub fn {f}(") } else { format!("fn {f}(") };
        src.insert(format!("fdpass.rs {f}"), block(&fd, &start, "}"));
    }
    json!({"schema": "t28-linux-golden@1", "shapes": s, "source": src})
}
