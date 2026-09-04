//! D.1.3c·2c·1b — the cockpit's half of the **terminal data plane**.
//!
//! Three planes, and this is the third:
//!
//! ```text
//!   AUTHORITY   ordered semantic state         ampd
//!   CONTROL     coalescible projection frames  worker.rs's Delivery valve
//!   DATA        lossless ordered bytes         here
//! ```
//!
//! **Why not the valve.** `Delivery` coalesces, and is right to: a projection
//! frame supersedes its predecessor, so dropping the older one loses nothing.
//! A byte supersedes nothing. Put terminal output on that lane and the first
//! slow page turns `ls -R /` into a plausible and wrong transcript, silently,
//! because coalescing is that lane's correct behaviour.
//!
//! **The order of operations, and it is the security-relevant part.**
//!
//! ```text
//!   1  this process creates a socketpair                  fdpass::pair_stream
//!   2  one end goes to ampd over the BRIDGE               SCM_RIGHTS
//!      ampd adopts it, parks it, returns an endpoint_ref
//!   3  `terminal_bind` is submitted on the CONTROL channel with that ref
//!      ampd resolves the authority against the BOUND PEER and only then
//!      claims the endpoint
//! ```
//!
//! Step 2 names nothing — no Worker, no generation, no actor. Step 3 is where
//! a person's authority is checked, on the socket that carries it. The
//! `endpoint_ref` never leaves this process: the page supplies `worker_ref`
//! and `expected_worker_generation`, and `worker.rs` adds the third argument.
//! **The page never receives a descriptor and never receives a reference to
//! one.**

use std::io::{Read, Write};
use std::os::unix::io::FromRawFd;
use std::os::unix::net::UnixStream;

use serde_json::{json, Value};
use tauri::ipc::Channel;

use super_host::Runtime;

const OUT: u8 = 1;
const ACK: u8 = 2;
const CLOSE: u8 = 3;

/// Terminal bytes as base64, hand-rolled.
///
/// **Not a dependency, and not `Vec<u8>` through serde either.** Terminal
/// output is arbitrary bytes — control sequences, partial UTF-8, NUL — so it
/// cannot be a JSON string as-is, and `serde_json` renders a byte vector as
/// an array of decimal numbers, which is roughly four bytes on the wire per
/// byte of terminal. This is 20 lines and the tree already hand-rolls
/// `sha256` for the same reason.
fn b64(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((bytes.len() + 2) / 3 * 4);
    for c in bytes.chunks(3) {
        let b = [c[0], *c.get(1).unwrap_or(&0), *c.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if c.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if c.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    out
}

/// The cockpit's end of one presentation.
///
/// At most one, for the same reason ampd allows at most one plane per
/// attachment: two readers of one terminal stream is not fan-out, it is each
/// of them seeing an arbitrary half.
pub struct Terminal {
    /// The pane's sink. Bound before an open is attempted, because bytes
    /// that arrive with nowhere to go are bytes this process would have to
    /// buffer — and the whole claim is that nothing on this path buffers.
    sink: Option<Channel<Value>>,
    /// Our end of the socketpair. `None` when no presentation is open.
    stream: Option<UnixStream>,
}

impl Terminal {
    pub fn new() -> Self {
        Terminal { sink: None, stream: None }
    }

    pub fn bind_sink(&mut self, sink: Channel<Value>) {
        self.sink = Some(sink);
    }

    /// Step 1 + 2: make a socketpair, hand one end to ampd over the bridge,
    /// and hold ours. Returns the `endpoint_ref` for step 3.
    ///
    /// **Refused if no sink is bound.** Otherwise the endpoint would be
    /// parked, claimed, and streaming into a process with no consumer, which
    /// is the one shape the window cannot bound: the credit would be spent
    /// on bytes nobody asked for.
    pub fn park(&mut self, rt: &Runtime) -> Result<String, String> {
        if self.sink.is_none() {
            return Err("no terminal sink is bound — the pane has not offered one".into());
        }
        if self.stream.is_some() {
            return Err("a terminal presentation is already open in this cockpit".into());
        }

        let (fd, endpoint_ref) = rt.terminal_endpoint()?;

        // SAFETY: `terminal_endpoint` returns an fd this process owns and has
        // not registered anywhere. From here `UnixStream` owns it and closes
        // it on drop — which is why the error paths below drop `s` rather
        // than calling `close_fd`, and why nothing else in this module holds
        // a `RawFd`.
        let s = unsafe { UnixStream::from_raw_fd(fd) };
        self.stream = Some(s);
        Ok(endpoint_ref)
    }

    /// Step 3 succeeded: start reading. One thread, blocking reads, and the
    /// sink is the only thing it can do with what it reads.
    pub fn started(&mut self) -> Result<(), String> {
        let s = self.stream.as_ref().ok_or("no terminal stream to read")?;
        let mut r = s.try_clone().map_err(|e| format!("terminal clone: {e}"))?;
        let sink = self.sink.clone().ok_or("no terminal sink")?;

        std::thread::spawn(move || {
            let mut buf: Vec<u8> = Vec::new();
            let mut chunk = [0u8; 16 * 1024];
            loop {
                match r.read(&mut chunk) {
                    Ok(0) | Err(_) => {
                        let _ = sink.send(json!({"schema":"terminal-close@1","code":"stream-ended"}));
                        return;
                    }
                    Ok(n) => buf.extend_from_slice(&chunk[..n]),
                }
                // **Frames are drained to exhaustion before reading again.**
                // A stream socket has no message boundaries, so one `read`
                // may carry a partial frame, several frames, or both — and a
                // reader that handled one frame per read would fall behind by
                // whatever the kernel coalesced.
                loop {
                    match emit(&buf, &sink) {
                        // The stream is length-prefixed by opcode, so an
                        // unknown one leaves no way to find the next
                        // boundary. The comment on that arm said ending the
                        // presentation was the only honest response and the
                        // loop went on reading anyway — which is how a
                        // reader resynchronises onto the middle of a frame
                        // and reports its offsets as sequence numbers.
                        Some(Frame::Unreadable) => return,
                        Some(Frame::Rest(rest)) => buf = rest,
                        None => break,
                    }
                }
            }
        });
        Ok(())
    }

    /// The pane has consumed through `seq`. Cumulative.
    pub fn ack(&mut self, seq: u64) -> Result<(), String> {
        let s = self.stream.as_mut().ok_or("no terminal presentation is open")?;
        let mut f = [0u8; 9];
        f[0] = ACK;
        f[1..].copy_from_slice(&seq.to_be_bytes());
        s.write_all(&f).map_err(|e| format!("terminal ack: {e}"))
    }

    /// Close the presentation. Idempotent — a pane that closes twice, or that
    /// closes one the stream already ended, is ordinary rather than an error.
    pub fn close(&mut self) {
        if let Some(s) = self.stream.take() {
            let _ = s.shutdown(std::net::Shutdown::Both);
        }
    }
}

enum Frame {
    /// A whole frame was consumed; here is what follows it.
    Rest(Vec<u8>),
    /// The stream cannot be resynchronised. The presentation is over.
    Unreadable,
}

/// Decode ONE frame from the front of `buf` and push it at the sink.
/// `None` means more bytes are needed.
fn emit(buf: &[u8], sink: &Channel<Value>) -> Option<Frame> {
    match buf.first() {
        Some(&OUT) if buf.len() >= 13 => {
            let seq = u64::from_be_bytes(buf[1..9].try_into().ok()?);
            let len = u32::from_be_bytes(buf[9..13].try_into().ok()?) as usize;
            if buf.len() < 13 + len {
                return None;
            }
            let _ = sink.send(json!({
                "schema": "terminal-out@1",
                "seq": seq,
                "b64": b64(&buf[13..13 + len]),
            }));
            Some(Frame::Rest(buf[13 + len..].to_vec()))
        }
        Some(&CLOSE) if buf.len() >= 3 => {
            let len = u16::from_be_bytes(buf[1..3].try_into().ok()?) as usize;
            if buf.len() < 3 + len {
                return None;
            }
            let code = String::from_utf8_lossy(&buf[3..3 + len]).to_string();
            let _ = sink.send(json!({"schema":"terminal-close@1","code":code}));
            Some(Frame::Rest(buf[3 + len..].to_vec()))
        }
        // An unknown opcode is not skippable: the stream is length-prefixed
        // by opcode, so there is no way to find the next boundary. Ending the
        // presentation is the only honest response, and `terminal-out@1`
        // ordering is precisely what must not be guessed at.
        Some(_) => {
            let _ = sink.send(json!({"schema":"terminal-close@1","code":"stream-unreadable"}));
            Some(Frame::Unreadable)
        }
        _ => None,
    }
}
