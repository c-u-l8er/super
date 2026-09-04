//! The [&] Super cockpit.
//!
//! ```text
//!   World                        authoritative state
//!     │
//!   ampd                         the only thing that decides
//!     │
//!   CockpitLoop                  in `super_host`, unmodified — one
//!     │                          implementation of the continuity
//!     │                          hierarchy, shared with `super-host verify`
//!     │
//!   Channel<CockpitFrame>        ordered · at most one un-acknowledged
//!     │                          · bound by the frontend, never global
//!   WebView                      renders the frame · emits intents
//!     │
//!   intent()                     back into the human control channel
//! ```
//!
//! # The one law this program exists to hold
//!
//! **The cockpit renders the world; it never decides it.** A successful
//! intent changes nothing on screen. What changes the screen is a frame,
//! and a frame comes from `ampd`.
//!
//! That is easy to say and very easy to lose at exactly this hop: the
//! natural way to write a desktop app is to update the row when the call
//! succeeds, because the call succeeding *means* the row is gone. It does
//! not. It means the runtime accepted the request; whether the row is gone
//! is a fact about the world, and the world says so in its own time and in
//! its own frame. W.1 spent four rounds establishing that a projection is
//! truthful. A WebView that renders its own optimism throws all of it away
//! one function call from the end.
//!
//! # Two gates, and W.2 shipped only the inner one
//!
//! ```text
//!   may THIS WEBVIEW invoke `intent` at all?    Tauri's ACL
//!                                               capabilities/default.json
//!                                               granted to the webview
//!                                               labelled `main`, alone
//!   what may an allowed webview ASK FOR?        worker::INTENT_SURFACE
//! ```
//!
//! W.2 had the second and not the first. Application commands registered
//! through `invoke_handler` are, by default, reachable from **every**
//! window and webview in the application — so the capability file said the
//! cockpit "may listen for frames and nothing else" while `intent` was
//! open to anything the process ever opened. With one product window that
//! was not exploitable; it was also not the boundary, and the boundary is
//! the point. `build.rs` now declares the commands to the ACL, so
//! `allow-intent` is a permission that has to be granted.
//!
//! # W.2.2 · granted to a WEBVIEW, and W.2.1 granted it to a WINDOW
//!
//! ```text
//!   tauri-2.11.5 · src/ipc/authority.rs · resolve_access
//!
//!     cmd.webviews.iter().any(|w| w.matches(webview))
//!       ||                                            ← an OR
//!     cmd.windows.iter().any(|w| w.matches(window))
//!
//!   and src/webview/mod.rs calls it with
//!     window  = self.window().label()
//!     webview = self.label()
//! ```
//!
//! So a capability naming `windows: ["main"]` is satisfied by the window
//! label alone and the webview's own label is never consulted. Tauri says
//! so in `acl/capability.rs` too: *"the capability will be enabled on all
//! the webviews of that window, regardless of the value of `webviews`"*.
//!
//! W.2.1 shipped `windows: ["main"]` and proved its boundary against a
//! **separate `WebviewWindow`** — which passes, and which is not the
//! topology Super is being built toward:
//!
//! ```text
//!   what W.2.1 proved            what Super will actually be
//!
//!   Window "main"                Window "main"
//!     └ cockpit    granted         ├ WebView "main"     cockpit
//!   Window "pane"                  ├ WebView "browser"  a page
//!     └ pane       denied ✓        └ WebView "machine"  a Motor surface
//!                                        ↑ under `windows`, both granted
//! ```
//!
//! A Motor pane, a browser pane or a game pane must not acquire
//! human-control authority by being drawn inside the same desktop window.
//! The grant is therefore `webviews: ["main"]` with **no `windows` key at
//! all**, and `SUPER_COCKPIT_PANE=1` opens the witness as a real child
//! webview of `main` via `Window::add_child` — the same primitive those
//! panes will use. `tools/check-webview-acl.mjs` fails if `windows` ever
//! comes back, because the substitution is one word and reopens the class
//! silently.

mod terminal;
mod worker;

/// The terminal surface's label and page. **Constants, not parameters.**
/// `terminal_surface` takes a boolean and nothing a page could point at
/// something else — see its doc comment.
const TERMINAL_LABEL: &str = "terminal";
const TERMINAL_URL: &str = "terminal.html";

use std::path::PathBuf;
use std::sync::mpsc::sync_channel;

use serde_json::{json, Value};
use tauri::ipc::Channel;
use tauri::{Manager, State};

use worker::{Msg, Queues};

/// Hand the worker somewhere to send frames.
///
/// **This is the ordering fix.** The frontend constructs the channel,
/// installs `onmessage`, and only then invokes this; the worker holds no
/// sink until it arrives and therefore cannot address a frame to nobody.
/// W.2 used a global `emit` against a listener that registers
/// asynchronously — and because a frame that is emitted-and-missed is
/// still marked in flight, losing that race wedged the valve permanently.
///
/// **On the control lane, and awaited off the painting thread.** Every
/// command below that touches the valve is `async` and does its blocking
/// send inside `spawn_blocking`: a synchronous Tauri command runs on the
/// GTK main thread, so a lane that was momentarily full would have frozen
/// the window instead of waiting a millisecond.
///
/// **W.2.3.3 · and it names the binding.** See [`worker::StreamId`]: the
/// page's terminal state fires an un-awaited `unbind` and a person's *Try
/// again* fires a `bind` behind it, and nothing between the two invokes
/// orders them — each command is its own `async_runtime::spawn` and its own
/// `spawn_blocking`. The lane orders what is in it; it does not order the
/// two hops that put things there.
#[tauri::command]
async fn bind_frame_stream(
    stream: worker::StreamId,
    channel: Channel<Value>,
    queue: State<'_, Queues>,
) -> Result<(), String> {
    control(&queue, Msg::Bind { stream, sink: channel }).await
}

/// **W.2.3.2 · the page says it has stopped listening, so the host stops
/// writing.**
///
/// Retiring a `Channel` callback stops this page reading. It does nothing
/// about the host, which goes on sending heartbeats — and, if the valve ever
/// reopens, frames — into a webview that has stopped consuming them. Under a
/// permanently broken transport that is exactly the cost the terminal
/// UNAVAILABLE state exists to end rather than relocate, and on Tauri's
/// >8192 path a send whose script never runs leaves a whole projection in
/// `ChannelDataIpcQueue` that nothing page-side can reclaim.
///
/// The symmetric partner of [`bind_frame_stream`].
///
/// **W.2.3.3 CORRECTION — this doc comment used to end "on the same control
/// lane, so it cannot overtake or be overtaken by a bind", and that is not a
/// guarantee the mechanism provides.** A `SyncSender` orders the messages in
/// it. Reaching it takes two unordered hops per command — Tauri answers an
/// async command by `crate::async_runtime::spawn` (`ipc/mod.rs`
/// `respond_async`), and [`control`] then does its blocking send inside
/// `spawn_blocking`, a pool with no ordering between tasks. Two invokes the
/// page issued in order are two independent futures racing to the lane.
///
/// That is the W.2.1 defect shape exactly: **prose describing a boundary
/// that does not exist reads as coverage and is worse than no boundary.**
/// The ordering is now carried by the message rather than asserted about the
/// transport — this names the binding it tears down, and
/// [`worker::Delivery::unbind`] obeys it only for the binding it is holding.
#[tauri::command]
async fn unbind_frame_stream(
    stream: worker::StreamId,
    queue: State<'_, Queues>,
) -> Result<(), String> {
    control(&queue, Msg::Unbind(stream)).await
}

/// One place where a control message is enqueued, so there is one policy
/// rather than four.
///
/// The send blocks and the block happens in `spawn_blocking`. Both halves
/// matter and they are different repairs: **blocking** is what stops a
/// release being discarded, and **`spawn_blocking`** is what stops the wait
/// happening on the thread that paints the window.
async fn control(queue: &State<'_, Queues>, m: Msg) -> Result<(), String> {
    let q = queue.inner().clone();
    tauri::async_runtime::spawn_blocking(move || q.control(m))
        .await
        .map_err(|e| format!("control join: {e}"))?
}

/// Submit one mutation to the world and return **what the runtime decided**.
///
/// The return value is the runtime's own `result` object — a receipt. It is
/// what a person needs to know that their click was heard, that it was
/// refused, and why. It is not a view, and the renderer does not draw from
/// it: see `ui/cockpit.js`, where the resolution of this promise is
/// deliberately joined to nothing.
///
/// **`async`, and blocking inside a blocking pool.** A synchronous Tauri
/// command runs on the main thread, which on GTK is the thread painting the
/// window: a click that waited there for the runtime would freeze the
/// surface it is trying to keep truthful.
///
/// **The one lane that may make a person wait.** The bounded send moved
/// inside `spawn_blocking` too — W.2.1 did it in the async body, so a full
/// lane parked a Tauri async worker rather than a blocking-pool thread.
#[tauri::command]
async fn intent(
    name: String,
    args: Value,
    queue: State<'_, Queues>,
) -> Result<Value, String> {
    if !worker::INTENT_SURFACE.contains(&name.as_str()) {
        return Err(format!("not an intent this cockpit can submit: {name}"));
    }

    let (reply, wait) = sync_channel(1);
    let q = queue.inner().clone();

    // The worker is the single caller on the control channel; this waits
    // for its turn, and the wait is bounded by the runtime's own deadlines
    // rather than a second one invented here.
    tauri::async_runtime::spawn_blocking(move || {
        q.intent(Msg::Intent { name, args, reply })?;
        wait.recv().unwrap_or_else(|_| Err("no reply from the cockpit worker".into()))
    })
    .await
    .map_err(|e| format!("intent join: {e}"))?
}

/// The WebView has painted frame `seq`. Until this arrives no newer frame
/// is sent.
///
/// **This is the message whose loss wedges the stream, and W.2.1 sent it
/// with `try_send`.** `in_flight` is released here and nowhere else, so a
/// dropped ack closes the valve for the life of the page — and `cockpit.js`
/// does not await it, so the rejection had nowhere to be seen either.
#[tauri::command]
async fn frame_ack(seq: u64, queue: State<'_, Queues>) -> Result<(), String> {
    control(&queue, Msg::Ack { seq }).await
}

/// An interaction has begun; hold the surface still until it ends.
///
/// **Keyed, because interactions overlap.** W.2 spelled this `ready: false`
/// against a single boolean, so two rapid clicks each took the hold and the
/// first to finish released it — reflowing the list underneath the second
/// one while its outcome was still unknown. That is the product rule
/// broken by the mechanism meant to keep it.
#[tauri::command]
async fn hold_begin(id: String, queue: State<'_, Queues>) -> Result<(), String> {
    control(&queue, Msg::HoldBegin(id)).await
}

/// The other message whose loss wedges the stream. A key that is never
/// removed keeps `holds` non-empty, and `Delivery::open` never returns true
/// again.
#[tauri::command]
async fn hold_end(id: String, queue: State<'_, Queues>) -> Result<(), String> {
    control(&queue, Msg::HoldEnd(id)).await
}

/// D.1.3c·2c·1b — **the terminal pane offers its byte sink.**
///
/// Granted to the `terminal` webview and to nothing else. It is a separate
/// capability file rather than another permission on `default.json`, because
/// `default.json` grants the cockpit `intent` — and a pane that could submit
/// intents would be a terminal renderer holding a person's authority.
///
/// The sink must be bound before a presentation is opened. Bytes with
/// nowhere to go are bytes this process would have to buffer, and the claim
/// of the data plane is that nothing on it buffers.
#[tauri::command]
async fn terminal_stream(channel: Channel<Value>, queue: State<'_, Queues>) -> Result<(), String> {
    control(&queue, Msg::TerminalSink { sink: channel }).await
}

/// The pane has **consumed** through `seq` — xterm's write callback, not the
/// arrival of the message. Cumulative, and the only thing that returns
/// credit: with none outstanding the runtime stops pulling, the socketpair
/// fills, and the Carrier blocks in `write(2)`.
///
/// On the control lane for the same reason `frame_ack` is. An acknowledgement
/// that can be discarded under load wedges the stream it exists to unwedge.
#[tauri::command]
async fn terminal_ack(seq: u64, queue: State<'_, Queues>) -> Result<(), String> {
    control(&queue, Msg::TerminalAck { seq }).await
}

/// **D.1.3c·2c·1b·1 — the terminal surface, as a product surface.**
///
/// Until this slice, both the untrusted witness pane and the terminal
/// webview were created only under `SUPER_COCKPIT_PANE=1`. That variable is
/// a W.2.2 *testing* witness — `tools/cockpit-battery.mjs` sets it to prove
/// a refusal — and it had quietly become the switch that decided whether
/// Super has a terminal at all. Normal Super therefore rendered *Watch
/// terminal* on every `PRESENT` Worker and could not have shown one: no
/// terminal webview, so no sink, so [`terminal::Terminal::park`] refuses
/// before a socket is ever made. **A capability reachable only from a test
/// harness is not a capability.**
///
/// So the two are separated. `SUPER_COCKPIT_PANE` now governs only the
/// untrusted pane. The terminal surface is created here, lazily, when a
/// person asks to watch one — which is also better than the old fixed
/// child at (560, 600): a terminal nobody opened should not be occupying
/// the window.
///
/// **What the page may designate: nothing.** `open` is a boolean. The
/// label and the URL are the two constants below and are not parameters,
/// so this cannot be turned into "create a webview at a URL of my
/// choosing" by supplying a different argument — the same structural
/// argument D.1.3c·2c·1a makes about input and resize.
/// `tools/check-webview-acl.mjs` holds that shape.
///
/// Returns `bound` so the caller can wait for the pane to offer its sink
/// rather than racing `terminal_bind` against a page that is still loading.
#[tauri::command]
async fn terminal_surface(
    open: bool,
    app: tauri::AppHandle,
    queue: State<'_, Queues>,
) -> Result<Value, String> {
    if !open {
        control(&queue, Msg::TerminalClose).await?;
        if let Some(w) = app.get_webview(TERMINAL_LABEL) {
            w.close().map_err(|e| format!("terminal surface: {e}"))?;
        }
        return Ok(json!({"present": false, "bound": false}));
    }

    if app.get_webview(TERMINAL_LABEL).is_none() {
        let main = app.get_window("main").ok_or("no main window to host the terminal")?;
        // Sized from the window rather than pinned, so the surface is a
        // product pane and not a fixed rectangle chosen for a battery.
        let (w, h) = match main.inner_size() {
            Ok(s) => {
                let f = main.scale_factor().unwrap_or(1.0);
                (s.width as f64 / f, s.height as f64 / f)
            }
            Err(_) => (900., 700.),
        };
        // Bottom-right quadrant. Derived from the window rather than
        // pinned, and deliberately clear of the bottom-LEFT rectangle the
        // untrusted witness pane occupies when `SUPER_COCKPIT_PANE=1`:
        // under the battery both exist at once, and a terminal drawn over
        // the pane would fail the refusal probe for a reason that has
        // nothing to do with authority.
        let th = (h * 0.35).clamp(160., 320.);
        main.add_child(
            tauri::webview::WebviewBuilder::new(
                TERMINAL_LABEL,
                tauri::WebviewUrl::App(TERMINAL_URL.into()),
            ),
            tauri::LogicalPosition::new(w / 2., h - th),
            tauri::LogicalSize::new(w / 2., th),
        )
        .map_err(|e| format!("terminal surface: {e}"))?;
    }

    let (reply, wait) = sync_channel(1);
    control(&queue, Msg::TerminalBound { reply }).await?;
    let bound = wait
        .recv_timeout(std::time::Duration::from_secs(2))
        .map_err(|_| "no reply from the cockpit worker".to_string())?;

    Ok(json!({"present": true, "bound": bound}))
}

/// The pane is done looking. **Read-only, and there is nothing else here.**
/// No input, no resize, no dormant method for either — D.1.3c·2c·1a's scope
/// is structural: a power with no entry point cannot be reached by supplying
/// a different argument.
#[tauri::command]
async fn terminal_close(queue: State<'_, Queues>) -> Result<(), String> {
    control(&queue, Msg::TerminalClose).await
}

/// Where `ampd` is. `AMPD_DIR`, or `ampd/` beside the working directory —
/// the same resolution `super-host` uses, because two answers to "which
/// runtime" is two products.
fn ampd_dir() -> PathBuf {
    std::env::var("AMPD_DIR").map(PathBuf::from).unwrap_or_else(|_| {
        std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")).join("ampd")
    })
}

fn main() {
    // `--intents` prints the surface as data so a gate can compare it with
    // `Ampd.CommandSpec` instead of with a comment. It does not start a
    // runtime and does not open a window.
    if std::env::args().any(|a| a == "--intents") {
        println!("{}", json!({"schema": "intent-surface@1", "intents": worker::INTENT_SURFACE}));
        return;
    }

    // `--fixture-check` answers "would the demo fixture be allowed to write
    // into the world this launch would open?" for the environment it is
    // given. It is the judgement, extracted — a gate that had to boot a
    // runtime against a person's world and watch it not be touched is a
    // gate nobody would run twice.
    if std::env::args().any(|a| a == "--fixture-check") {
        let probe = std::env::temp_dir().join("super-cockpit-fixture-check");
        let world = worker::world_for(&probe);
        println!(
            "{}",
            json!({
                "schema": "fixture-check@1",
                "world": world.path().to_string_lossy(),
                "ephemeral": matches!(world, super_host::WorldDir::Ephemeral(_)),
                "fixture_allowed": worker::fixture_allowed(&world),
            })
        );
        return;
    }

    let dir = ampd_dir();
    if !dir.join("mix.exs").exists() {
        eprintln!("no ampd/ at {} — set AMPD_DIR", dir.display());
        std::process::exit(2);
    }

    let fixture = std::env::var("SUPER_COCKPIT_FIXTURE").as_deref() == Ok("1");
    let pane = std::env::var("SUPER_COCKPIT_PANE").as_deref() == Ok("1");

    // **Two lanes, both bounded.** An unbounded queue between a WebView and
    // a socket is a way for a wedged runtime to become a memory leak instead
    // of a visible state, and `acquiring` on screen is the honest form of
    // that. What W.2.1 got wrong was not the bound — it was discarding the
    // messages that reopen the valve when the bound was reached. See the
    // header of `worker.rs`.
    let depth = worker::queue_depth();
    let (ctl_tx, ctl_rx) = sync_channel::<worker::Msg>(depth);
    let (tx, rx) = sync_channel::<worker::Msg>(depth);

    tauri::Builder::default()
        .manage(Queues { intents: tx, control: ctl_tx })
        .invoke_handler(tauri::generate_handler![
            bind_frame_stream,
            unbind_frame_stream,
            intent,
            frame_ack,
            hold_begin,
            hold_end,
            terminal_stream,
            terminal_ack,
            terminal_close,
            terminal_surface
        ])
        .setup(move |app| {
            let cfg = worker::Config { ampd_dir: dir.clone(), fixture };
            std::thread::spawn(move || worker::run(ctl_rx, rx, cfg));

            // **The untrusted-pane boundary, opened INSIDE the trusted
            // window.** W.2.1 opened it as a separate `WebviewWindow`, which
            // proved a boundary Super is not going to have: the panes this
            // is a stand-in for — a browser, a Motor surface, a game — are
            // child webviews of the cockpit window, and under a
            // window-scoped capability they would have inherited every
            // permission the cockpit holds. `add_child` is the primitive
            // they will be built with, so it is the primitive the refusal is
            // measured against.
            //
            // Placed low and left, clear of the grant rows, because the
            // battery clicks a real button in the cockpit and an occluding
            // webview would break that for a reason unrelated to authority.
            // Nothing renders in it and nothing is meant to.
            if pane {
                let main = app
                    .get_window("main")
                    .ok_or("no main window to host the pane")?;
                main.add_child(
                    tauri::webview::WebviewBuilder::new(
                        "pane",
                        tauri::WebviewUrl::App("pane.html".into()),
                    ),
                    tauri::LogicalPosition::new(0., 600.),
                    tauri::LogicalSize::new(520., 200.),
                )?;

                // **D.1.3c·2c·1b·1 — the terminal webview used to be created
                // here too, and that was the defect.** It is granted three
                // commands and no fourth, which makes it the first surface
                // in this application holding *some* authority and not the
                // cockpit's — the shape every later pane will have. But it
                // is a PRODUCT surface, and this branch is a test witness.
                // Creating it here meant normal Super offered *Watch
                // terminal* on a `PRESENT` Worker and had nowhere to put
                // one. It is created by `terminal_surface` now, when a
                // person asks for it, in every configuration.
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("the cockpit failed to start");
}
