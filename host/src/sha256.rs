//! SHA-256, written out by hand.
//!
//! # Why this is not a crate
//!
//! `fdpass.rs` is hand-written because the trust model rests on four
//! syscalls. This is hand-written for the adjacent reason: it computes the
//! identity that a capability's embodiment basis is bound to, and adding a
//! dependency to compute an identity means the identity now depends on a
//! supply chain the census does not measure. `host` has exactly one
//! declared dependency and D.1.1b does not make it two.
//!
//! # Why it is trustworthy anyway
//!
//! Not because it is short. Because it is **checked against another
//! implementation on every test run**: `test/locus_test.exs` hashes the
//! same bytes with Erlang's `:crypto.hash(:sha256, …)` — OpenSSL — and
//! asserts the two agree on the real `super-host` and `git` binaries on
//! this machine. A hand-written primitive nobody cross-checks is the worst
//! of both worlds; this one is cross-checked against a different language's
//! different implementation, on real multi-megabyte inputs, as a falsifier.
//!
//! FIPS 180-4 §6.2. No streaming API is exposed beyond what `digest_file`
//! needs, because the only thing this host hashes is a file.

use std::fs::File;
use std::io::{self, Read};

const K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// Streaming state. Kept private: a partially-consumed hasher that anything
/// could feed is a way to produce a digest over bytes nobody enumerated.
struct Sha256 {
    h: [u32; 8],
    buf: [u8; 64],
    buffered: usize,
    len: u64,
}

impl Sha256 {
    fn new() -> Self {
        Sha256 {
            h: [
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
                0x5be0cd19,
            ],
            buf: [0u8; 64],
            buffered: 0,
            len: 0,
        }
    }

    fn compress(&mut self, block: &[u8]) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                block[i * 4],
                block[i * 4 + 1],
                block[i * 4 + 2],
                block[i * 4 + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }

        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = self.h;

        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let t1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);

            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }

        self.h[0] = self.h[0].wrapping_add(a);
        self.h[1] = self.h[1].wrapping_add(b);
        self.h[2] = self.h[2].wrapping_add(c);
        self.h[3] = self.h[3].wrapping_add(d);
        self.h[4] = self.h[4].wrapping_add(e);
        self.h[5] = self.h[5].wrapping_add(f);
        self.h[6] = self.h[6].wrapping_add(g);
        self.h[7] = self.h[7].wrapping_add(hh);
    }

    fn update(&mut self, mut data: &[u8]) {
        self.len = self.len.wrapping_add(data.len() as u64);

        if self.buffered > 0 {
            let want = 64 - self.buffered;
            let take = want.min(data.len());
            self.buf[self.buffered..self.buffered + take].copy_from_slice(&data[..take]);
            self.buffered += take;
            data = &data[take..];
            if self.buffered == 64 {
                let block = self.buf;
                self.compress(&block);
                self.buffered = 0;
            }
        }

        while data.len() >= 64 {
            let (block, rest) = data.split_at(64);
            self.compress(block);
            data = rest;
        }

        if !data.is_empty() {
            self.buf[..data.len()].copy_from_slice(data);
            self.buffered = data.len();
        }
    }

    fn finish(mut self) -> [u8; 32] {
        let bits = self.len.wrapping_mul(8);

        // 0x80, then zeroes, then the 64-bit big-endian bit length.
        self.update(&[0x80]);
        // `update` counted that byte into `len`; the padding length is
        // computed from `buffered` instead, so the count does not matter.
        while self.buffered != 56 {
            self.update(&[0x00]);
        }
        // Written directly rather than through `update`, which would count
        // the length field into the length.
        self.buf[56..64].copy_from_slice(&bits.to_be_bytes());
        let block = self.buf;
        self.compress(&block);

        let mut out = [0u8; 32];
        for (i, word) in self.h.iter().enumerate() {
            out[i * 4..i * 4 + 4].copy_from_slice(&word.to_be_bytes());
        }
        out
    }
}

fn hex(bytes: &[u8]) -> String {
    const D: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(D[(b >> 4) as usize] as char);
        s.push(D[(b & 0x0f) as usize] as char);
    }
    s
}

/// `sha256:<hex>` over `data`.
///
/// Prefixed the same way `Ampd.Core.intent_digest/1` prefixes: a bare hex
/// string does not say what produced it, and an unlabelled digest in
/// committed evidence is a value nobody can re-derive with confidence.
pub fn digest(data: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(data);
    format!("sha256:{}", hex(&h.finish()))
}

/// `sha256:<hex>` over the contents of `path`.
///
/// Streamed in 64 KiB chunks. Reading a multi-megabyte executable into one
/// allocation to hash it works and is the kind of thing that stops working
/// on the first unusual input.
pub fn digest_file(path: &std::path::Path) -> io::Result<String> {
    digest_reader(File::open(path)?)
}

/// `sha256:<hex>` over everything an already-open handle yields.
///
/// Exists so `/proc/self/exe` can be **opened** rather than read as a
/// string and re-opened. Those are not the same operation:
/// `proc_exe_link()` hands back the stored `struct file`'s path, so
/// opening the magic link reaches the inode this process is executing,
/// while opening the *text* of the link re-resolves a pathname that may
/// since have been renamed over. Both succeed; they hash different bytes.
/// It is also the only form that works at all for a process exec'd from a
/// `memfd`, where the link text is `/memfd:… (deleted)` and names nothing.
pub fn digest_reader<R: Read>(mut r: R) -> io::Result<String> {
    let mut h = Sha256::new();
    let mut chunk = vec![0u8; 64 * 1024];
    loop {
        let n = r.read(&mut chunk)?;
        if n == 0 {
            break;
        }
        h.update(&chunk[..n]);
    }
    Ok(format!("sha256:{}", hex(&h.finish())))
}
