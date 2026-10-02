//! T27 · **L1**, the configured half — on x86-64 the filter's model is T26's.
//!
//! `confine.rs`'s unit test holds the two BPF programs to T26's bytes. This
//! holds the model `verify` asks questions of (`denies`, `ioctl_allowed`) to
//! T26's answers, over every number a deny list could plausibly name and the
//! whole 16-bit ioctl space. T26's numbers are written here as golden data,
//! taken from `superlane/t27/golden/out/dump.txt` (computed from `1069cdc`'s own
//! `confine.rs`), and here is outside `host/src`, which L2 keeps free of them.
#![cfg(target_arch = "x86_64")]

use super_host::confine;

const T26_DENIED: [u32; 28] = [
    56, 57, 58, 62, 101, 139, 155, 161, 165, 166, 175, 176, 234, 248, 250, 272, 298, 308, 310, 311,
    313, 319, 321, 322, 424, 434, 435, 438,
];
const T26_IOCTL_ALLOWED: [u32; 3] = [0x5401, 0x540f, 0x5413];
const X32_SYSCALL_BIT: u32 = 0x4000_0000;
const T26_EXECVE: u32 = 59;

#[test]
fn t27_l1_the_configured_model_is_t26s_on_x86_64() {
    let denied: Vec<u32> = (0..1024).filter(|n| confine::denies(*n)).collect();
    assert_eq!(denied, T26_DENIED, "denies() over 0..1024");
    for nr in [X32_SYSCALL_BIT, X32_SYSCALL_BIT | T26_EXECVE, X32_SYSCALL_BIT | 57, u32::MAX] {
        assert!(confine::denies(nr), "the x32 space is refused whole: {nr:#x}");
    }
    assert!(!confine::denies(T26_EXECVE), "execve stays permitted (Landlock bounds it)");
    let ioctls: Vec<u32> = (0..0x1_0000).filter(|r| confine::ioctl_allowed(*r)).collect();
    assert_eq!(ioctls, T26_IOCTL_ALLOWED, "ioctl_allowed() over the 16-bit space");
}
