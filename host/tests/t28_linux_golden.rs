//! T28 · **L8** — Linux is unchanged (`superlane/t28/TASK.md`). On the default build only:
//!
//! * a capture of THIS tree, made by the base's own capture code (`t28_linux_golden/capture.rs`, byte for byte
//!   `superlane/t28/golden/src/capture.rs`; laws.py checks the copy), equals the golden captured at `b497c345` before any
//!   T28 code (`data/t28-linux-golden.json`, byte for byte `golden/out/t28-linux-golden-b497c345.json`): every bridge send
//!   shape's records, control messages and flags, and the guarded source texts (`HostBridge.loop/1` and the Linux bridge
//!   functions in `fdpass.rs`) by sha256;
//! * both ends of `bridge::pair()` are `SOCK_SEQPACKET`, and the bridge module's own sends put on the wire exactly the
//!   records `fdpass`'s do, so a selector or a send that drifted from them shows;
//! * the release build has `framed-bridge` off (the feature is not a default).
#![cfg(not(feature = "framed-bridge"))]

#[path = "t28_linux_golden/capture.rs"]
mod capture;

use serde_json::Value;
use std::os::fd::RawFd;
use std::path::Path;
use super_host::{bridge, fdpass};

fn so_type(fd: RawFd) -> i32 {
    let mut t: libc::c_int = 0;
    let mut l = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
    assert_eq!(unsafe { libc::getsockopt(fd, libc::SOL_SOCKET, libc::SO_TYPE, &mut t as *mut _ as *mut _, &mut l) }, 0);
    t
}

/// Every record the peer can read now: its bytes, its control messages' (len, level, type) and descriptor count, and
/// its flags. Rights are closed.
fn records(fd: RawFd) -> Vec<(Vec<u8>, Vec<(usize, i32, i32)>, usize, i32)> {
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
            break;
        }
        let (mut cm, mut fds) = (vec![], 0usize);
        unsafe {
            let mut c = libc::CMSG_FIRSTHDR(&msg);
            while !c.is_null() {
                let k = ((*c).cmsg_len as usize - libc::CMSG_LEN(0) as usize) / 4;
                let p = libc::CMSG_DATA(c) as *const RawFd;
                for i in 0..k {
                    libc::close(std::ptr::read_unaligned(p.add(i)));
                }
                fds += k;
                cm.push(((*c).cmsg_len as usize, (*c).cmsg_level, (*c).cmsg_type));
                c = libc::CMSG_NXTHDR(&msg, c);
            }
        }
        out.push((buf[..n as usize].to_vec(), cm, fds, msg.msg_flags));
    }
    out
}

fn spares(n: usize) -> Vec<RawFd> {
    (0..n).map(|_| fdpass::spare_fd().unwrap()).collect()
}

#[test]
fn l8_a_capture_of_this_tree_equals_the_golden_captured_at_the_base() {
    let tree = Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
    let now = capture::golden(&tree);
    let base: Value = serde_json::from_str(include_str!("data/t28-linux-golden.json")).unwrap();
    assert_eq!(now["shapes"], base["shapes"], "a Linux bridge send shape changed on the wire");
    let src = base["source"].as_object().unwrap();
    assert_eq!(src.len(), now["source"].as_object().unwrap().len());
    for (k, v) in src {
        assert_eq!(now["source"][k]["sha256"], v["sha256"], "{k}'s text changed");
    }
}

#[test]
fn l8_the_bridge_is_seqpacket_and_its_sends_put_fdpass_records_on_the_wire() {
    let p = bridge::pair().unwrap();
    assert_eq!((so_type(p.0), so_type(p.1)), (libc::SOCK_SEQPACKET, libc::SOCK_SEQPACKET), "the Linux bridge is not SEQPACKET");
    let plain = br#"{"schema":"bridge-command@1","command":"status"}"#.to_vec();
    let bind = br#"{"schema":"bridge-command@1","command":"bind_agent_channel","actor":"agent:t28-l8"}"#.to_vec();
    for (n, ours) in [(0usize, plain.clone()), (1, bind.clone()), (3, bind.clone()), (5, bind.clone())] {
        let r = spares(n);
        let a = fdpass::pair_seqpacket().unwrap();
        if n == 0 {
            fdpass::send_bridge_plain(a.0, &ours).unwrap();
            bridge::send_plain(p.0, &ours).unwrap();
        } else {
            fdpass::send_bridge_with_fds(a.0, &ours, &r).unwrap();
            bridge::send_with_fds(p.0, &ours, &r).unwrap();
        }
        assert_eq!(records(p.1), records(a.1), "{n} rights: the bridge's send is not fdpass's on the wire");
        for f in r.iter().chain([&a.0, &a.1]) {
            fdpass::close_fd(*f);
        }
    }
    let a = fdpass::pair_seqpacket().unwrap();
    fdpass::send_bridge_plain_nowait(a.0, &plain).unwrap();
    bridge::send_plain_nowait(p.0, &plain).unwrap();
    assert_eq!(records(p.1), records(a.1), "the no-wait send is not fdpass's on the wire");
    for f in [a.0, a.1, p.0, p.1] {
        fdpass::close_fd(f);
    }
}

#[test]
fn l8_the_release_build_has_framed_bridge_off() {
    let toml = std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("Cargo.toml")).unwrap();
    let mut in_features = false;
    for line in toml.lines().map(str::trim) {
        if line.starts_with('[') {
            in_features = line == "[features]";
            continue;
        }
        if in_features && line.starts_with("default") {
            assert!(!line.contains("framed-bridge"), "framed-bridge is a default feature: {line}");
        }
    }
    assert!(toml.contains("framed-bridge = []"), "the test feature is not declared");
}
