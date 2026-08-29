//! The frame pump: one thread, which owns the runtime, the human control
//! channel and the `CockpitLoop`, and is the only thing in this process
//! that may speak to either.
//!
//! # Why a thread and not a Tauri command per call
//!
//! `Chan` is one reader and one writer with no correlation between two
//! concurrent callers — the F.8 lesson, recorded in the host: *one reader,
//! one writer, many logical callers*. A Tauri command runs on whatever
//! thread the runtime hands it, so exposing the channel to commands
//! directly would put eight WebView clicks on one socket and produce the
//! corrupt stream that measured 2 replies out of 96. Every message into
//! the world therefore goes through this queue, and the socket has exactly
//! one caller for its whole life.
//!
//! # The sink, and why W.2 was racy
//!
//! W.2 pushed frames with `app.emit("cockpit-frame", …)`. Two things were
//! wrong with that, and only one of them was visible.
//!
//! **A global event has no addressee.** `emit` reaches every listener in
//! the application — the wrong shape for a stream whose whole subject is
//! *the authoritative view*, and exactly the wrong shape once Super hosts
//! a pane it does not trust.
//!
//! **A listener registers asynchronously, and an event is not a queue.**
//! The frontend's `listen()` returns a promise; the worker's first `emit`
//! could land before it resolved, and nothing would ever redeliver it.
//! Combined with the one-frame-in-flight valve that is not a dropped
//! frame, it is a **wedge**: the frame is marked in flight, the page never
//! sees it, nothing is ever acknowledged, and no later frame may be sent.
//! The cockpit sits on *Waiting for the first frame* forever. W.2's
//! battery passed because runtime startup gave the page enough time on
//! this machine, which is timing evidence and not an ordering guarantee.
//!
//! So the stream is a [`Channel`] the *frontend constructs*: it installs
//! its handler first and then hands the sink over, and this worker cannot
//! send until it holds one. There is no interval in which a frame can be
//! addressed to nobody.
//!
//! **A new sink has been told nothing.** [`Delivery::bind`] therefore
//! clears `sent`, so whoever binds — the first page, or the same page
//! after a reload — is brought up to the current state rather than waiting
//! for the world to change next. Without that, a late sink is a blank
//! cockpit attached to a healthy runtime.
//!
//! # The valve, and why one boolean was not enough
//!
//! Delivery opens only when there is a sink, no frame is outstanding, and
//! **no interaction is holding**. W.2 spelled the last one `paused: bool`,
//! and a boolean does not compose: two overlapping submissions each pause,
//! the first to finish resumes, and the second interaction's list reflows
//! underneath it while its outcome is still unknown. Holds are keyed now —
//! `hold_begin(id)` / `hold_end(id)` — and delivery waits for the set to
//! empty. That is the same defect shape as `superseded_by` collapsing
//! three continuity answers into one bit.
//!
//! # Two lanes, and W.2.1 had one — which could refuse the message that
//! # reopens the valve
//!
//! ```text
//!   intents      bounded · blocking          a wedged runtime must not
//!     Intent                                 become a memory leak
//!
//!   control      bounded · blocking ·        every one of these RELEASES
//!     Bind       DRAINED FIRST               something the valve is
//!     Ack                                    waiting on
//!     HoldBegin
//!     HoldEnd
//! ```
//!
//! W.2.1 put all five on one `sync_channel(64)` and sent the last four with
//! `try_send`, whose contract is that a full buffer returns `Full` and **the
//! message is not sent**. That is survivable for a message meaning "try
//! again". `Ack` and `HoldEnd` are not those messages:
//!
//! ```text
//!   Ack(seq) dropped        in_flight stays Some(seq)   →  open() false forever
//!   HoldEnd(id) dropped     holds keeps id              →  open() false forever
//! ```
//!
//! and the frontend does not retry — `cockpit.js` calls `ack` without
//! awaiting it at all. So the valve closes and never reopens, and the queue
//! that can only be full *because* mutations are in flight is exactly the
//! condition under which the messages clearing them are discarded:
//!
//! > **the congestion signal prevents the message that clears congestion.**
//!
//! The rule this round adopts, which is not about cockpits:
//!
//! > **New work may be refused BUSY. A message whose absence can leave a
//! > gate permanently closed may not use lossy delivery — it must enqueue,
//! > or move the system to a state that says so.**
//!
//! Both lanes are still bounded, so the memory-leak argument above is
//! intact; both now block, so nothing is discarded, and the block happens
//! in `spawn_blocking` rather than on the thread painting the window (see
//! `main.rs`). **Control is drained to empty before a single intent is
//! taken**, so an acknowledgement never queues behind sixty-four unread
//! round trips to the runtime.
//!
//! **Two claims here, and only one of them is measured. Say which.**
//!
//! *Nothing is discarded* is measured, deterministically, by the two
//! saturation witnesses in `tools/cockpit-battery.mjs` and falsified by
//! `tools/sabotage-cockpit.sh`. That is the defect W.2.1 shipped and the
//! reason this round exists.
//!
//! *Control before mutations* is an argument about latency, and this
//! battery cannot tell the two orders apart — [`drain`] empties **both**
//! lanes before `lp.turn` computes a frame, so a hold enqueued before its
//! intent is in force by the time any frame is evaluated whichever lane is
//! read first. The flagship's mandatory intermediate state rests on that
//! drain-then-evaluate structure, not on the lane order. The order is here
//! because a release that waits behind sixty-four blocking calls is a
//! stalled frame stream during exactly the traffic that produced it — a
//! real cost with no witness in this file, and it is written down as such
//! rather than counted as one.
//!
//! # W.2.3 · a successful send is not a delivery
//!
//! W.2.2 closed both lanes against loss and its flagship still wedged once,
//! unreproducibly. The cause is one layer further out and it is not exotic:
//!
//! ```text
//!   Delivery::push
//!     └ Channel::send                       returns Ok(())
//!         └ webview.eval                    (payload < 8192 bytes)
//!             └ wry WebKitGTK eval          returns Ok(()) — and with no
//!                 └ run_javascript          callback the ASYNCHRONOUS
//!                                           Result is dropped unread
//! ```
//!
//! `wry-0.55.1/src/webkitgtk/mod.rs` passes the script to `run_javascript`
//! with a closure that inspects `result` only `if let Some(callback)`, and
//! Tauri passes none. Upstream wry#1644 (open, 23 Dec 2025) reports exactly
//! this: Tauri `Channel` messages lost and the channel hanging, because
//! unsuccessful `run_javascript` calls are silently ignored. So the host can
//! be told a frame was delivered when no JavaScript ever ran, and a valve
//! that treats *sent* as *received* closes for the life of the page.
//!
//! The rule, which is the end-to-end argument arriving inside the cockpit:
//!
//! > **A liveness-critical message is delivered when the CONSUMER says so.
//! > Absence of acknowledgement must produce retry, recovery, or an explicit
//! > loss of the claim — never permanent silence.**
//!
//! Three things follow, and each has a witness:
//!
//! ```text
//!   the whole packet is kept    InFlight { seq, payload, sent_at, attempts }
//!     └ retransmit_due          the SAME bytes again, never a newer state
//!
//!   the link speaks for itself  beat() — not a frame, not counted, never
//!     └ carries valve()         writes the world region; and it is what
//!                               lets a closed valve NAME the term that
//!                               closed it, which W.2.2 could not do
//!
//!   the page may stop claiming  a lease in `ui/cockpit.js`: hear nothing
//!                               for longer than it and LIVE LOCAL is
//!                               withdrawn, the world region cleared and
//!                               authority disabled. A timeout may say *I
//!                               no longer know this is maintained*. It may
//!                               never invent world state.
//! ```

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::mpsc::{Receiver, SyncSender};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tauri::ipc::Channel;

use super_host::{Cockpit, CockpitFrame, ProjectionCursor, Runtime, WorldDir};

/// The only things the WebView may ask this process to do.
///
/// **Every name here is a `kind: :mutation` on the `:human_control`
/// channel in `Ampd.CommandSpec`, and there is no read among them.** A
/// cockpit that could ask for a projection would have a second way to
/// learn the world, and a second way to learn the world is a second source
/// of truth however carefully the first one is built. Reads arrive as
/// frames or they do not arrive.
///
/// `subscribe` and `unsubscribe` are `:both` mutations and are deliberately
/// absent: they belong to the loop's own lifecycle, and a WebView that
/// could unsubscribe could blind the surface it is rendering.
///
/// `tools/check-intent-surface.mjs` proves the two halves of that paragraph
/// against `Ampd.CommandSpec` itself rather than against this comment.
///
/// **This is the inner of two gates and it is the weaker one.** It decides
/// what a webview that is allowed to invoke `intent` *at all* may ask for.
/// Whether a given webview may invoke it is Tauri's ACL, declared in
/// `capabilities/default.json` and granted to the webview labelled `main`
/// alone — proved by `tools/cockpit-battery.mjs` against an unprivileged
/// second webview **inside the same window**, which is the topology a
/// browser or Motor pane will have and the one W.2.1's separate-window
/// witness did not establish.
pub const INTENT_SURFACE: &[&str] = &[
    "approve_grant_request",
    "deny_grant_request",
    "revoke_grant",
    "revoke_capability_domain",
    "approve_effect",
    "deny_effect",
    // D.1.1a. Opening a position is an authority operation: `open_lane`
    // names the actor that may occupy it, and that is a person deciding
    // who stands where. It was reachable through the API and not through
    // the person's own surface, which `tools/check-intent-surface.mjs`
    // caught and refused.
    //
    // **These three words were not enough on their own, and adding only
    // them would have been the worse failure.** The gate reads this const,
    // so appending strings turns it green while a person still cannot open
    // anything. What makes the gate's proposition true is the form in
    // `ui/cockpit.js` and the loci block in `operator-projection@2` that
    // gives the form something to choose from.
    "open_workspace",
    "open_goal",
    "open_lane",
];

/// **W.2.3.3 · which established position a bind or unbind is addressed to.**
///
/// `main.rs` used to claim that a `bind` and an `unbind` could not overtake
/// one another because they travelled the same control lane. **The lane
/// orders messages that are already in it.** Getting them there is an
/// `async_runtime::spawn` per command — `ipc/mod.rs` `respond_async` — and
/// then a `spawn_blocking` per send, so two invokes the page issued in order
/// are two independent tasks racing to a `SyncSender`. The page's terminal
/// state fires an un-awaited `unbind` and a person's *Try again* fires a
/// `bind` right behind it; nothing in that path orders them, and an unbind
/// that arrived second would have torn down the stream the retry had just
/// established.
///
/// **The generation alone is not the identity, and a counter would have
/// broken the reload.** A reloaded page is a new page whose counter starts
/// over, so a host refusing everything at or below the generation it already
/// held would refuse it a stream permanently — a cockpit that survives a
/// dead transport and dies of `F5`. *Which page* and *which attempt by that
/// page* are two facts, and collapsing them into one number is the same
/// mistake as `heard_at`. So generations are compared **only within a
/// page**, and a different page is always the newer locus.
#[derive(Clone, Debug, PartialEq, Eq, serde::Deserialize)]
pub struct StreamId {
    pub page: String,
    pub generation: u64,
}

pub enum Msg {
    /// The frontend has installed its handler and is handing over the sink.
    /// **Nothing is sent before this arrives.** Control lane.
    Bind {
        stream: StreamId,
        sink: Channel<Value>,
    },
    /// **W.2.3.2** — the page has given up on re-establishing a stream and
    /// has stopped consuming. Drops the sink, so the host stops producing.
    /// Not a failure and not a reconnection: a page that says so is in a
    /// better state than one that stops reading silently. Control lane.
    ///
    /// **W.2.3.3** — and it names the stream it is tearing down, so one
    /// addressed to a binding that has already been replaced is refused
    /// rather than obeyed.
    Unbind(StreamId),
    /// Submit one mutation. The reply is the runtime's own reply frame,
    /// which is a *receipt of what was decided*, never a view. **The one
    /// variant on the mutation lane**, and the only one whose refusal under
    /// load is honest rather than destructive.
    Intent {
        name: String,
        args: Value,
        reply: SyncSender<Result<Value, String>>,
    },
    /// The WebView has rendered frame `seq`. Releases `in_flight`.
    /// Control lane.
    Ack { seq: u64 },
    /// An interaction has begun, and the surface must hold still until it
    /// ends. Keyed, because interactions overlap. Control lane.
    HoldBegin(String),
    /// Releases one key from `holds`. Control lane.
    HoldEnd(String),
}

/// The two senders, handed to Tauri's command layer as one piece of state.
///
/// **Both sends block and neither drops. `try_send` does not appear in this
/// program any more**, and that absence is half the W.2.2 repair: there is
/// no call site left that can discard a message, so no later edit can
/// reintroduce the class by picking the wrong one of two similar methods.
///
/// **The lane a message travels is decided by which of these two methods
/// its command calls, and not by its type.** One enum over two channels is
/// deliberate: it is what makes the defect W.2.1 shipped reachable by a
/// one-word edit, and therefore what lets `tools/sabotage-cockpit.sh` prove
/// the repair is load-bearing rather than assert it. There are exactly five
/// call sites, all in `main.rs`, each naming its lane in one line. The cost
/// is that the compiler does not enforce the split; the falsifier is what
/// does, which is this project's usual trade and is stated here so the next
/// reader does not "tighten" it into something unfalsifiable.
///
/// `Clone` because a Tauri `State` cannot be moved into `spawn_blocking`;
/// `SyncSender` clones share one buffer, so the bound is the bound however
/// many clones exist.
#[derive(Clone)]
pub struct Queues {
    pub intents: SyncSender<Msg>,
    pub control: SyncSender<Msg>,
}

impl Queues {
    /// Enqueue a valve-control message, waiting if the lane is full.
    ///
    /// The wait cannot deadlock: the worker never blocks on anything the
    /// frontend must feed it. [`drain`] is `try_recv`, `lp.turn` has a
    /// deadline, and an intent's reply goes to a `sync_channel(1)` whose
    /// receiver is already parked. So a full lane means a busy worker, and
    /// a busy worker always comes back to [`drain`].
    pub fn control(&self, m: Msg) -> Result<(), String> {
        self.control.send(m).map_err(|_| "the cockpit worker has stopped".to_string())
    }

    /// Enqueue a mutation. **This is the lane that may make a person wait**,
    /// and the bound is what stops a wedged runtime becoming a memory leak.
    pub fn intent(&self, m: Msg) -> Result<(), String> {
        self.intents.send(m).map_err(|_| "the cockpit worker has stopped".to_string())
    }
}

/// How deep each lane is.
///
/// **Bounded, and the bound is the point**: an unbounded queue between a
/// WebView and a socket is a way for a wedged runtime to become a memory
/// leak instead of a visible `acquiring`. `SUPER_COCKPIT_QUEUE` sets it,
/// because saturation is a state this system has to be *provably* correct
/// in and 64 deep is a state a test can only reach by racing. It is a
/// depth, not a mode: there is no branch anywhere on its value, and the
/// code path at 1 is the code path at 64.
pub fn queue_depth() -> usize {
    std::env::var("SUPER_COCKPIT_QUEUE")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|n| *n > 0)
        .unwrap_or(64)
}

/// How long an un-acknowledged frame waits before it is sent **again, as
/// itself**. Comfortably longer than a render, short enough that a person
/// does not sit in front of a stale surface.
const RETRY_AFTER: Duration = Duration::from_millis(1200);

/// How many times an outstanding frame is sent again before the host stops
/// and lets the page's lease do the work.
///
/// **W.2.3.1 · retransmission does not repair every loss, and the ones it
/// cannot repair it makes worse.** Tauri 2.11.5's JavaScript `Channel`
/// carries a transport index of its own, incremented on every
/// `Channel::send`, and its receiving callback delivers a message only when
/// that index equals the one it is waiting for — anything ahead of a
/// missing index is buffered, not delivered. So a send whose `eval` never
/// ran takes an index out of the sequence permanently, and **a
/// retransmission arrives under a NEW index and is buffered behind the
/// hole it was sent to fill**. W.2.3 claimed retransmission closed
/// wry#1644; it closes loss *above* that ordering layer, and nothing sent
/// on the same channel can close loss below it.
///
/// Retrying anyway is not free. Above `MAX_JSON_DIRECT_EXECUTE_THRESHOLD`
/// Tauri parks the body in `ChannelDataIpcQueue` and asks the page to fetch
/// it, and the entry is removed **by the fetch** — so every send whose
/// script never ran leaves a whole projection in a map this process cannot
/// reach. Three attempts is a bounded cost inside one lease; unbounded
/// retransmission into an unrepairable gap is a leak with no ceiling.
///
/// **W.2.3.3 · `SUPER_COCKPIT_RETRY` sets it, and it is a DEPTH, not a
/// mode** — the same rule as [`queue_depth`]: nothing anywhere branches on
/// its value, and the code path at 64 is the code path at 3.
///
/// It exists because W.2.3.3 adds two withdrawal paths and only one of them
/// is reachable at 3. `exhausted` goes true 2.4 s after a frame is first
/// sent, comfortably inside the 6 s lease, so the *projection* deadline —
/// the page hearing healthy heartbeats for a whole lease while a frame it
/// has never seen sits stuck — can never fire while the exhaustion path is
/// in front of it. A mechanism with no falsifier is not something this
/// project ships, so `tools/cockpit-maintenance.mjs` runs the shipped code
/// at a depth where the repair is still nominally in progress and the second
/// deadline is the only thing that can end it.
pub fn retry_limit() -> u32 {
    std::env::var("SUPER_COCKPIT_RETRY")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .filter(|n| *n > 0)
        .unwrap_or(3)
}

/// How often the host says *I am still here* on the same Channel.
const HEARTBEAT_EVERY: Duration = Duration::from_millis(1500);

/// How long the page may hear nothing at all before it stops claiming the
/// projection is being maintained. Several heartbeats wide, because one
/// lost heartbeat is not a dead stream.
const LEASE_MS: u64 = 6000;

/// A frame that has been sent and not yet acknowledged — **kept whole**.
///
/// W.2.2 kept only `Option<u64>`, the sequence. That is enough to know a
/// frame is outstanding and not enough to do anything about it: the payload
/// was gone, so the only way out of a lost delivery was for the world to
/// move again and produce a *different* state. This keeps the bytes, so the
/// answer to silence is **the same frame again**, not a newer one — a
/// retransmission must not be an opportunity to skip a state the person was
/// entitled to see.
struct InFlight {
    seq: u64,
    payload: Value,
    sent_at: Instant,
    attempts: u32,
}

/// At most one un-acknowledged frame, only ever the newest state, and only
/// ever to a sink that exists.
struct Delivery {
    seq: u64,
    sink: Option<Channel<Value>>,
    in_flight: Option<InFlight>,
    /// **A set, not a boolean.** One interaction ending must not release
    /// another interaction's hold.
    holds: BTreeSet<String>,
    /// What the WebView was last *sent* — which is not what the loop
    /// holds, and the difference is the whole point of this struct.
    sent: Option<(Cockpit, ProjectionCursor)>,
    /// The newest state that has not been sent. Kept so `coalesced` counts
    /// *states superseded* and not *turns of the loop*: without it every
    /// 80 ms tick against an unchanged held state would increment a figure
    /// the WebView is going to be shown.
    held: Option<(Cockpit, ProjectionCursor)>,
    /// How many distinct states were superseded while delivery was closed.
    /// Reported on the next frame, because a valve that silently drops is
    /// indistinguishable from a valve that never had anything to drop.
    coalesced: u64,
    /// ── W.2.3 · so a closed valve can say which term closed it ─────────
    last_ack: Option<(u64, Instant)>,
    last_send_ok: bool,
    beat_at: Instant,
    retransmits: u64,
    /// ── W.2.3.3 · WHICH binding the sink belongs to ────────────────────
    /// Kept when the sink is dropped by a failed send, deliberately: the
    /// generation is what refuses a stale bind, and forgetting it would let
    /// a superseded attempt from the same page win the race to re-adopt.
    stream: Option<StreamId>,
    stale_binds: u64,
    stale_unbinds: u64,
    /// Read once, at construction. See [`retry_limit`].
    retry_limit: u32,
}

impl Delivery {
    fn new() -> Delivery {
        Delivery {
            seq: 0,
            sink: None,
            in_flight: None,
            holds: BTreeSet::new(),
            sent: None,
            held: None,
            coalesced: 0,
            last_ack: None,
            last_send_ok: true,
            beat_at: Instant::now(),
            retransmits: 0,
            stream: None,
            stale_binds: 0,
            stale_unbinds: 0,
            retry_limit: retry_limit(),
        }
    }

    /// Adopt a sink. **Everything the old page was told is forgotten**, and
    /// deliberately: a frame outstanding to a page that has gone will never
    /// be acknowledged, and a page that has just arrived has been told
    /// nothing. Clearing `sent` is what makes the next turn send the
    /// current state instead of waiting for the world to move — without
    /// it, a sink that binds late is a blank cockpit attached to a healthy
    /// runtime, and a reload is indistinguishable from a dead world.
    ///
    /// **W.2.3.3 · and it is refused when it comes from a position the page
    /// has already left.** A superseded attempt by the SAME page carries a
    /// channel that page has retired; adopting it would point the host at a
    /// sink nobody reads and cost a full lease to discover. A DIFFERENT page
    /// is always the newer locus — see [`StreamId`] for why that half cannot
    /// be a number.
    fn bind(&mut self, stream: StreamId, sink: Channel<Value>) {
        if let Some(cur) = &self.stream {
            if cur.page == stream.page && stream.generation <= cur.generation {
                self.stale_binds += 1;
                return;
            }
        }
        self.stream = Some(stream);
        self.sink = Some(sink);
        self.in_flight = None;
        self.holds.clear();
        self.sent = None;
        self.held = None;
        self.coalesced = 0;
    }

    /// **W.2.3.2 · the page has stopped consuming, so stop producing.**
    ///
    /// The same clearing as [`Delivery::bind`] minus the sink, and it must
    /// be the same clearing: a retained `in_flight` would mean the next
    /// `bind` inherited an outstanding frame addressed to a page that no
    /// longer exists, which is W.2.1's first-frame wedge arriving by a new
    /// route.
    ///
    /// Deliberately NOT a reason to stop beating in general — `beat()`
    /// already returns when there is no sink, and a later `bind` starts
    /// everything again. This is a state, not a shutdown.
    ///
    /// **W.2.3.3 · exact match, and nothing weaker.** Unlike `bind`, where a
    /// newer page wins, an unbind is only ever obeyed for the binding it
    /// names: this is the message that destroys a working stream, and a
    /// destructive instruction from a position that no longer exists must be
    /// refused rather than interpreted. That covers the ordering hazard the
    /// page cannot close — the un-awaited unbind from UNAVAILABLE overtaking
    /// the bind a person's *Try again* issued behind it.
    fn unbind(&mut self, stream: StreamId) {
        if self.stream.as_ref() != Some(&stream) {
            self.stale_unbinds += 1;
            return;
        }
        self.stream = None;
        self.sink = None;
        self.in_flight = None;
        self.holds.clear();
        self.sent = None;
        self.held = None;
        self.coalesced = 0;
    }

    fn ack(&mut self, seq: u64) {
        if self.in_flight.as_ref().map(|f| f.seq) == Some(seq) {
            self.in_flight = None;
        }
        // Recorded even for a duplicate acknowledgement of an already
        // released frame: it is evidence the page is alive and applying.
        self.last_ack = Some((seq, Instant::now()));
    }

    /// **Three conditions, and they are three different facts.** There is
    /// somewhere to send; the last frame has landed; no interaction is
    /// waiting on an outcome. W.2 had the second and spelled the third
    /// with a boolean, and did not have the first at all.
    fn open(&self) -> bool {
        self.sink.is_some() && self.in_flight.is_none() && self.holds.is_empty()
    }

    /// Whether `frame` is something the WebView has not been shown.
    fn differs(&self, frame: &CockpitFrame) -> bool {
        match &self.sent {
            None => true,
            Some((state, cursor)) => *state != frame.state || *cursor != frame.world,
        }
    }

    /// **Which term of `open()` is false, as data.**
    ///
    /// W.2.2's flagship wedged once and the round could not say why, because
    /// all three terms produce the same silence and `bind` clears all three
    /// — so a reload recovered from whichever it was and told us nothing.
    /// Five downstream checks failed and the field that closed the valve had
    /// to be guessed at. It rides the heartbeat, which is the only thing
    /// that escapes a closed valve, so the diagnosis reaches the page in
    /// exactly the situation it is needed.
    fn valve(&self) -> Value {
        json!({
            "open": self.open(),
            "sink": self.sink.is_some(),
            "in_flight": self.in_flight.as_ref().map(|f| json!({
                "seq": f.seq,
                "age_ms": f.sent_at.elapsed().as_millis() as u64,
                "attempts": f.attempts,
                // **The host has stopped trying and is saying so.** A
                // retransmission that has run out of attempts is not the
                // same state as one that is still coming, and a page that
                // could not tell them apart would be waiting on a repair
                // nobody is still attempting.
                "exhausted": f.attempts >= self.retry_limit,
            })),
            "retry_limit": self.retry_limit,
            // ── W.2.3.3 · the binding this sink belongs to, and what the
            // host has refused. A page that could not see a refusal would
            // have no way to tell a stale unbind that was correctly ignored
            // from one that was obeyed and quietly killed its stream.
            "stream": self.stream.as_ref().map(|s| json!({
                "page": s.page, "generation": s.generation,
            })),
            "stale_binds": self.stale_binds,
            "stale_unbinds": self.stale_unbinds,
            "holds": self.holds.iter().cloned().collect::<Vec<_>>(),
            "last_ack": self.last_ack.as_ref().map(|(seq, at)| json!({
                "seq": seq, "age_ms": at.elapsed().as_millis() as u64,
            })),
            "last_send_ok": self.last_send_ok,
            "retransmits": self.retransmits,
        })
    }

    /// Send a new frame and keep it until it is acknowledged.
    fn deliver(&mut self, seq: u64, payload: Value) {
        self.in_flight = Some(InFlight {
            seq,
            payload: payload.clone(),
            sent_at: Instant::now(),
            attempts: 1,
        });
        self.push(payload);
    }

    /// **The answer to silence.** An outstanding frame older than
    /// [`RETRY_AFTER`] goes again, same sequence and same bytes.
    ///
    /// This exists because a producer-side success is not a delivery.
    /// `Channel::send` for a payload under Tauri's 8 KB threshold calls
    /// `webview.eval`, and wry's WebKitGTK `eval` hands the script to
    /// `run_javascript` and returns `Ok(())` **without inspecting the
    /// asynchronous result** — with no callback, the `Result` is dropped
    /// (`wry-0.55.1/src/webkitgtk/mod.rs`, and upstream wry#1644 reports
    /// exactly this losing Tauri Channel messages and hanging the channel).
    /// So the host can be told a frame was delivered when no JavaScript
    /// ever ran. W.2.2 treated that as impossible and wedged forever.
    ///
    /// **Bounded** — see [`RETRY_LIMIT`]. Past it the frame stays
    /// outstanding, the valve stays closed, and `beat()` says so; the page's
    /// lease is what turns that into a withdrawal and a fresh channel.
    /// Sending the same bytes a fourth time cannot repair a lost transport
    /// index, and on the fetch transport it parks another projection in
    /// upstream state that only a page-side fetch can reclaim.
    fn retransmit_due(&mut self) {
        let limit = self.retry_limit;
        let due = match &self.in_flight {
            Some(f) => f.sent_at.elapsed() >= RETRY_AFTER && f.attempts < limit,
            None => false,
        };
        if !due {
            return;
        }
        let payload = match &mut self.in_flight {
            Some(f) => {
                f.attempts += 1;
                f.sent_at = Instant::now();
                f.payload.clone()
            }
            None => return,
        };
        self.retransmits += 1;
        self.push(payload);
    }

    /// *I am still here, and here is why you are not being sent anything.*
    ///
    /// **Not a frame.** It carries no projection and no cursor, the page
    /// does not count it, and it never writes the world region — a
    /// heartbeat is a statement about the link, not about the world. It is
    /// sent whether or not the valve is open, because a valve that is
    /// closed is exactly when the page most needs to know the difference
    /// between *the world is quiet* and *the stream is dead*.
    fn beat(&mut self) {
        if self.sink.is_none() || self.beat_at.elapsed() < HEARTBEAT_EVERY {
            return;
        }
        self.beat_at = Instant::now();
        let payload = json!({
            "schema": "cockpit-heartbeat@1",
            "lease_ms": LEASE_MS,
            "valve": self.valve(),
        });
        self.push(payload);
    }

    /// Hand one payload to the sink, or drop the sink.
    ///
    /// A channel whose page has gone errors here, and a sink that cannot be
    /// written to is not a sink. **But `Ok` is not delivery** — see
    /// [`Delivery::retransmit_due`]. Everything above this line treats a
    /// successful send as a request that the page *probably* received, and
    /// the acknowledgement as the only evidence that it did.
    fn push(&mut self, payload: Value) {
        let gone = match self.sink.as_ref() {
            None => return,
            Some(sink) => sink.send(payload).is_err(),
        };
        self.last_send_ok = !gone;
        if gone {
            self.sink = None;
            self.in_flight = None;
            self.sent = None;
        }
    }
}

/// The frame as the WebView receives it. Hand-built rather than derived,
/// because `super_host` carries no serde and the host has no business
/// growing a dependency for the benefit of one consumer.
fn frame_json(seq: u64, frame: &CockpitFrame, reacquisitions: u64, coalesced: u64) -> Value {
    json!({
        "schema": "cockpit-frame@1",
        "seq": seq,
        "state": match frame.state {
            Cockpit::Acquiring => "acquiring",
            Cockpit::LiveLocal => "live-local",
            Cockpit::Resnapshot => "resnapshot",
            Cockpit::Reacquire => "reacquire",
        },
        "world": {
            "world_incarnation": frame.world.world_incarnation,
            "world_generation": frame.world.world_generation,
            "projection_epoch": frame.world.projection_epoch,
            "authority_revision": frame.world.authority_revision,
            "view_revision": frame.world.view_revision,
        },
        "reacquisitions": reacquisitions,
        "coalesced": coalesced,
        "projection": frame.projection,
    })
}

/// Where the world lives for this launch.
///
/// `SUPER_WORLD_MODE=ephemeral` is the battery's world: created under the
/// runtime directory and destroyed on shutdown. Anything else is the
/// person's world, which this program never deletes — the rule
/// `WorldDir::Persistent` exists to state.
pub fn world_for(dir: &PathBuf) -> WorldDir {
    match std::env::var("SUPER_WORLD_MODE").as_deref() {
        Ok("ephemeral") => WorldDir::ephemeral(dir),
        _ => WorldDir::product(
            &std::env::var("SUPER_WORLD").unwrap_or_else(|_| "default".into()),
        ),
    }
}

/// Whether the fixture may write into `world`.
///
/// **Extracted from the I/O deliberately.** The whole of the judgement is
/// here, and `seed_fixture` is the only caller — so a gate can exercise the
/// rule without booting a runtime against a person's world in order to
/// watch it not be touched, which is a check nobody would run twice.
/// `super-cockpit --fixture-check` prints this answer for the configured
/// world, and `tools/sabotage-cockpit.sh` falsifies it here.
pub fn fixture_allowed(world: &WorldDir) -> bool {
    matches!(world, WorldDir::Ephemeral(_))
}

/// The demo authority the flagship test revokes.
///
/// **Ordinary commands on ordinary channels.** It binds an agent channel,
/// the agent asks, the person approves — the sequence a real first grant
/// takes, with no privileged route into the registry. `Ampd.TestFixture`
/// is not reachable from here and should not be: a fixture that can mint
/// authority without a person is the thing this runtime exists to make
/// impossible.
///
/// **Refused against a persistent world.** A fixture that can write into
/// the person's world is a fixture that will, once, on the wrong launch.
fn seed_fixture(rt: &Runtime) -> Result<(super_host::Chan, String), String> {
    if !fixture_allowed(&rt.world()) {
        return Err("the fixture is refused against a world it did not create".into());
    }

    let kestrel = rt.agent_channel("kestrel")?;
    let asked = kestrel
        .call(
            "request_grant",
            json!({
                "capability": "github.pr.create",
                "resource": "traaviis/trvm",
                "options": {"duration": "run", "reason": "close the argv boundary"}
            }),
        )
        .map_err(|e| format!("request_grant: {e}"))?;

    let request_id = asked["result"]["grant_request"]["id"]
        .as_str()
        .ok_or_else(|| format!("no grant request in {asked}"))?
        .to_string();

    // Handed back rather than dropped: the grant is bound to a live agent,
    // and closing the channel here would take `kestrel` out of the very
    // topology the fixture exists to populate — the projection would show
    // a grant held by nobody.
    Ok((kestrel, request_id))
}

/// Extra pending grant requests, so a frame can be measured on the far side
/// of Tauri's Channel size threshold.
///
/// **Real world content, not a padded payload.** Tauri delivers a Channel
/// message under `MAX_JSON_DIRECT_EXECUTE_THRESHOLD` (8192 bytes) with
/// `webview.eval`, and anything larger by a different route: it parks the
/// body, tells the page to fetch it, and ends the page-side promise in
/// `.catch(console.error)`. Those are two transports with two failure
/// modes, and until W.2.3 this product had only ever run on one of them —
/// the fixture frame measures 2,342 bytes.
///
/// The honest way to reach the other is more of what a real world has in
/// it, so this asks for `n` further grants as `kestrel` does, through
/// `request_grant`, and leaves them pending. `Ampd.Projection.operator/0`
/// carries `grant_requests` in full, so the frame grows by roughly what a
/// request costs. **Nothing here is a shortcut into the registry**, and
/// nothing is approved: a fixture that mints authority without a person is
/// the thing the runtime exists to make impossible.
fn seed_bulk(chan: &super_host::Chan, n: usize) {
    for i in 0..n {
        let _ = chan.call(
            "request_grant",
            json!({
                "capability": "github.pr.create",
                "resource": format!("traaviis/bulk-{i:03}"),
                "options": {
                    "duration": "run",
                    "reason": format!(
                        "frame-size witness {i:03}: this request exists so a cockpit frame \
                         crosses Tauri's 8192-byte Channel threshold with real projection \
                         content rather than padding"
                    ),
                },
            }),
        );
    }
}

/// How many extra pending requests the fixture seeds. Zero by default: the
/// flagship's world is the small one, and this is only turned up by the
/// gate that measures the large-payload transport.
pub fn bulk_requests() -> usize {
    std::env::var("SUPER_COCKPIT_BULK")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(0)
}

pub struct Config {
    pub ampd_dir: PathBuf,
    pub fixture: bool,
}

/// Drain both lanes. Returns false once either has closed.
///
/// **CONTROL FIRST, TO EMPTY.** An `Ack` or a `HoldEnd` never waits behind
/// a queue of mutations, each of which is a full round trip to the runtime.
/// W.2.1's single lane could not offer that even with the drops repaired:
/// the message that clears congestion queued behind the congestion.
///
/// **Both lanes are emptied before the caller computes a frame**, and that
/// — not the order — is what keeps a hold in force before the intent it
/// brackets. See the note in this file's header, which says which of the
/// two claims has a witness under it and which does not.
fn drain(
    ctl: &Receiver<Msg>,
    rx: &Receiver<Msg>,
    delivery: &mut Delivery,
    chan: Option<&super_host::Chan>,
) -> bool {
    loop {
        match ctl.try_recv() {
            Ok(m) => apply(m, delivery, chan),
            Err(std::sync::mpsc::TryRecvError::Empty) => break,
            Err(std::sync::mpsc::TryRecvError::Disconnected) => return false,
        }
    }

    loop {
        match rx.try_recv() {
            Ok(m) => apply(m, delivery, chan),
            Err(std::sync::mpsc::TryRecvError::Empty) => return true,
            Err(std::sync::mpsc::TryRecvError::Disconnected) => return false,
        }
    }
}

/// One message, applied. Blocking is confined to the `Intent` arm — which
/// is why draining control to empty *first* costs nothing and waiting
/// behind mutations costs a full round trip each.
fn apply(m: Msg, delivery: &mut Delivery, chan: Option<&super_host::Chan>) {
    match m {
        Msg::Bind { stream, sink } => delivery.bind(stream, sink),
        Msg::Unbind(stream) => delivery.unbind(stream),
        Msg::Ack { seq } => delivery.ack(seq),
        Msg::HoldBegin(id) => {
            delivery.holds.insert(id);
        }
        Msg::HoldEnd(id) => {
            delivery.holds.remove(&id);
        }
        Msg::Intent { name, args, reply } => {
            let out = match chan {
                None => Err("no control channel — the cockpit is not live".to_string()),
                Some(c) => c
                    .call(&name, args)
                    .map(|v| v["result"].clone())
                    .map_err(|e| e.to_string()),
            };
            let _ = reply.send(out);
        }
    }
}

/// Run until the process ends. Errors are frames, not panics — a cockpit
/// that dies silently is worse than one that says `acquiring`.
pub fn run(ctl: Receiver<Msg>, rx: Receiver<Msg>, cfg: Config) {
    let dir = std::env::temp_dir().join(format!("super-cockpit-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);

    let mut delivery = Delivery::new();

    let rt = match Runtime::start(&cfg.ampd_dir, world_for(&dir)) {
        Ok(r) => r,
        Err(e) => {
            // **Parked, not dropped.** W.2 emitted this diagnostic once and
            // returned; if the page had not finished registering, the only
            // account of why the cockpit is dead was gone for good. Here it
            // waits for a sink and keeps waiting, so whoever eventually
            // binds is told — including a page that arrives after a reload.
            let note = format!("the runtime did not start: {e}");
            loop {
                if !drain(&ctl, &rx, &mut delivery, None) {
                    return;
                }
                if delivery.open() && delivery.sent.is_none() {
                    delivery.seq += 1;
                    let seq = delivery.seq;
                    delivery.sent = Some((Cockpit::Acquiring, ProjectionCursor::default()));
                    delivery.deliver(seq, json!({
                        "schema": "cockpit-frame@1", "seq": seq, "state": "acquiring",
                        "world": Value::Null, "reacquisitions": 0, "coalesced": 0,
                        "projection": Value::Null, "note": note,
                    }));
                }
                // A dead runtime is still a live link, and the page is
                // entitled to know which of the two it is looking at.
                delivery.retransmit_due();
                delivery.beat();
                std::thread::sleep(Duration::from_millis(120));
            }
        }
    };

    let seeded = if cfg.fixture { seed_fixture(&rt).ok() } else { None };
    let (_kestrel, fixture_request) = match seeded {
        Some((c, id)) => (Some(c), Some(id)),
        None => (None, None),
    };

    // The large-frame witness, and only when it is asked for. It runs on
    // the agent channel the fixture already opened, so it cannot happen
    // against a world the fixture was refused.
    if let (Some(chan), n) = (_kestrel.as_ref(), bulk_requests()) {
        if n > 0 {
            seed_bulk(chan, n);
        }
    }

    let mut lp = super_host::CockpitLoop::new(&rt);
    let _ = lp.acquire();

    // The fixture's grant request is approved through the same control
    // channel the person's clicks use, once that channel exists.
    if let (Some(request_id), Some(chan)) = (fixture_request, lp.channel()) {
        let _ = chan.call(
            "approve_grant_request",
            json!({"request_id": request_id, "duration": "run"}),
        );
    }

    loop {
        // Drained before the world is touched, so a click never waits
        // behind a projection poll. `lp.channel()` is read here rather than
        // hoisted out of the loop: a reacquisition replaces it.
        if !drain(&ctl, &rx, &mut delivery, lp.channel()) {
            return;
        }

        lp.turn(Duration::from_millis(80));

        let frame = lp.frame();
        if delivery.differs(&frame) {
            let now = (frame.state.clone(), frame.world.clone());
            if !delivery.open() {
                // Newer than what the page may be shown, and it will be
                // sent as one state when delivery opens.
                if delivery.held.as_ref() != Some(&now) {
                    delivery.coalesced += 1;
                    delivery.held = Some(now);
                }
            } else {
                delivery.seq += 1;
                let seq = delivery.seq;
                let payload = frame_json(seq, &frame, lp.reacquisitions, delivery.coalesced);
                delivery.coalesced = 0;
                delivery.held = None;
                delivery.sent = Some(now);
                delivery.deliver(seq, payload);
            }
        }

        // **After the frame decision, never instead of it.** A retransmission
        // is the same bytes going again; a heartbeat is the link speaking for
        // itself. Neither may invent a state, and neither is allowed to be
        // the thing that moves the screen.
        delivery.retransmit_due();
        delivery.beat();
    }
}
