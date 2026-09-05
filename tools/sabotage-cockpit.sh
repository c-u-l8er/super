#!/usr/bin/env bash
# Prove each W.2 / W.2.1 check by sabotage — **through a real WebView**,
# because the properties are about a DOM and an ACL and there is nowhere
# else they exist.
#
# The W.2 flagship is the easiest test in this project to write vacuously.
# "Click revoke, then assert the row is still there" passes against a
# cockpit that removes the row optimistically, as long as the assertion
# lands in the millisecond before the frame arrives — and on a fast machine
# it usually will. So the question this file answers is the only one that
# matters about that battery: **with the fix disabled, does it go red?**
#
# W.2.1 adds three properties whose falsifiers are the same shape, and each
# of them is a defect W.2 actually shipped:
#
#   the ACL is the outer gate    a command outside it is reachable from
#                                every webview the process opens
#   a late sink is caught up     a page that binds after the world went
#                                live is otherwise blank forever
#   holds are keyed              a boolean lets one interaction release
#                                another interaction's hold
#
# Run from the release root:  bash tools/sabotage-cockpit.sh
set -uo pipefail
cd "$(dirname "$0")/.."

APP=./cockpit/target/release/super-cockpit
[ -x "$APP" ] || { echo "build the cockpit first: cargo build --release --manifest-path cockpit/Cargo.toml" >&2; exit 1; }
command -v tauri-driver >/dev/null || { echo "tauri-driver is not installed: cargo install tauri-driver" >&2; exit 1; }

pass=0; fail=0

rebuild () {
  # **The payloads too, and R0a is why.** A probe that sabotages
  # `dogfood/src/main.rs` and rebuilds only the cockpit is a probe that never
  # runs its own sabotage: the installed payload is a separate artifact with
  # a separate build rule (`tools/build-payloads.sh` — the `cd` into the
  # crate is that rule, because `.cargo/config.toml` pins `+crt-static` and
  # cargo reads it from the working directory). It would score NOT A
  # FALSIFIER against a fix that was never disabled, which is the one
  # outcome this file exists to make impossible.
  bash tools/build-payloads.sh >/dev/null 2>&1 &&
    cargo build --release --manifest-path cockpit/Cargo.toml >/dev/null 2>&1
}

# Every probe rebuilds, including the ones that only touch `ui/` or
# `capabilities/`: the frontend is embedded in the binary by
# `tauri::generate_context!` and the capability is compiled into it, so a
# sabotage that is not rebuilt is a sabotage that never runs — and it would
# score as "NOT A FALSIFIER" against a fix that was never disabled.
#
# **`expect` may name MORE THAN ONE check, separated by `%%`, and every one
# of them must go red.** W.2.2 adds a single defect — a discarded control
# message — that wedges the frame stream through two different fields,
# `in_flight` and `holds`. Two probes running the identical sabotage to grep
# two different lines would be the same four-minute battery twice; one probe
# that requires both lines is the same evidence and half the wall clock.
# It also refuses a repair that fixes one field and not the other.
#
# **`SABOTAGE_DRYRUN=1` checks every pattern still matches, and nothing else.**
#
# A probe is anchored on a line of source. A later round rewrites that line
# for its own reasons and the pattern silently stops matching — the probe
# still runs, still looks like a probe, and proves nothing. The harness has
# always reported that honestly as SABOTAGE MISSED; the trouble is the price
# of finding out, which is a rebuild and a battery per probe and, on the run
# that prompted this, an hour inside a release chain before the first one
# spoke up. W.2.3.2 rewrote two lines that W.2.3.1's probes were anchored on
# and broke both.
#
# The dry run does the copy, the sed and the comparison — the whole of the
# question — and skips the rebuild and the battery. Seconds instead of
# hours, and it is worth running before every chain.
#
#     SABOTAGE_DRYRUN=1 bash tools/sabotage-cockpit.sh
#
# **Four probes were dead and a dry run said so.** `cockpit/ui/cockpit.js`
# split `const grants = (p.grants ?? []).map` into two statements and
# `cockpit/capabilities/default.json` reformatted `"webviews": ["main"],`
# onto three lines. Neither change altered any behaviour and both silently
# retired a falsifier: one for the frame-rebuild property and three for the
# webview ACL. They were already missing at `b470a1b` — measured by running
# `SABOTAGE_DRYRUN=1` against a stashed tree — so this is drift being
# repaired, not damage being undone. It is also the argument for running the
# dry run: it costs seconds and it is the only thing that can see a probe
# that has stopped asking its question.
#
# probe <name> <runner> <expected-RED substring>[%%<another>…] <file> <sed-expr>...
probe () {
  local name="$1" runner="$2" expect="$3" f="$4"; shift 4
  cp "$f" "$f.orig"
  for e in "$@"; do sed -i "$e" "$f"; done

  if cmp -s "$f" "$f.orig"; then
    echo "  SABOTAGE MISSED  $name — the pattern did not match; the probe proved nothing"
    fail=$((fail+1))
    mv "$f.orig" "$f"; touch "$f"; return
  fi

  if [ -n "${SABOTAGE_DRYRUN:-}" ]; then
    echo "  pattern ok       $name"
    pass=$((pass+1))
    mv "$f.orig" "$f"; touch "$f"; return
  fi

  if ! rebuild; then
    echo "  BROKE THE BUILD  $name — red because it did not compile, which proves nothing"
    fail=$((fail+1))
    mv "$f.orig" "$f"; touch "$f"; rebuild; return
  fi

  # Through a file with a deadline, never a command substitution — see the
  # note in `tools/sabotage-host.sh`. A `$(…)` here waits for EOF on a pipe
  # an orphaned BEAM is holding open, and that cost 1h46m once already.
  out_file=$(mktemp)
  case "$runner" in
    # **The deadline is sized for the SABOTAGED run, not the healthy one.**
    # A probe disables a fix, so the battery spends its `waitSoft` budgets
    # instead of satisfying them — W.2.3.3's binding probes add about ninety
    # seconds of expired waits on top of a battery that grew by a third this
    # round. A TIMED OUT probe reports a failure and refuses the release,
    # which costs a whole chain to discover; the margin is cheaper.
    battery)  timeout 900 node tools/cockpit-battery.mjs      >"$out_file" 2>&1; rc=$? ;;
    # **W.2.3.3** — the second deadline is unreachable at the shipped retry
    # depth, so its falsifier runs against the gate that reaches it. Short:
    # one live-local, one fault, one lease.
    maint)    timeout 480 node tools/cockpit-maintenance.mjs  >"$out_file" 2>&1; rc=$? ;;
    surface)  timeout 240 node tools/check-intent-surface.mjs >"$out_file" 2>&1; rc=$? ;;
    acl)      timeout 60  node tools/check-webview-acl.mjs    >"$out_file" 2>&1; rc=$? ;;
    fixture)  timeout 60  bash tools/check-fixture-guard.sh   >"$out_file" 2>&1; rc=$? ;;
    # R0a. Slower than `acl` and faster than `battery`: one cockpit, one
    # click, one eight-second measurement window.
    join)     timeout 300 node tools/terminal-join-probe.mjs   >"$out_file" 2>&1; rc=$? ;;
  esac
  out=$(cat "$out_file"); rm -f "$out_file"

  pkill -f "mix run --no-halt" 2>/dev/null
  pkill -f "tauri-driver" 2>/dev/null

  if [ "$rc" -eq 124 ]; then
    echo "  TIMED OUT        $name — nothing was proved"
    fail=$((fail+1))
    mv "$f.orig" "$f"; touch "$f"; rebuild; return
  fi

  local missed="" e
  local rest="$expect%%"
  while [ -n "$rest" ]; do
    e="${rest%%\%\%*}"; rest="${rest#*%%}"
    [ -n "$e" ] || continue
    grep -q "FAILED.*$e" <<<"$out" || missed="$missed'$e' "
  done

  if [ -z "$missed" ]; then
    echo "  falsified        $name"
    pass=$((pass+1))
  else
    echo "  NOT A FALSIFIER  $name — ${missed}passed with the fix disabled"
    fail=$((fail+1))
  fi

  mv "$f.orig" "$f"; touch "$f"; rebuild
}

echo "cockpit sabotage battery — each line stubs one fix and expects a named check RED"

# 1 · THE W.2 DEFECT ITSELF. The four-line version of `submit` that every
#     desktop app is written with: the call succeeded, so remove the row.
#     It renders a world nobody asserted, and it throws away the whole of
#     W.1 one function call from the end.
probe "the renderer does not draw its own optimism" battery \
  "the intent succeeded and the grant is STILL on screen" \
  cockpit/ui/cockpit.js \
  's|    receipt(name, refusal ? .refused. : .accepted., refusal ?? ..);|    receipt(name, refusal ? "refused" : "accepted", refusal ?? ""); if (!refusal) document.querySelector(`#world .row[data-id="${args.grant_id}"]`)?.remove();|'

# **PROBES 2 AND 3 NAME THE 1.5-SECOND CHECK, NOT THE IMMEDIATE ONE.**
#
# Both used to expect `no frame has been delivered`, which is asserted the
# moment the receipt appears. With the hold disabled the frame does arrive —
# but the worker replies to the intent and only *then* takes its next
# 80 ms turn, and this battery polls for the receipt every 250 ms, so
# roughly one run in three observes the receipt inside the window before the
# frame lands. The check passes, the probe reports NOT A FALSIFIER, and it
# refuses a release over a fix that is working.
#
# Measured, not guessed: the same sabotage run by hand turned all three
# checks red; the release chain a minute earlier had it green.
#
# `it is a state and not a race: 1.5 s later …` asserts the same two facts —
# the row is still there and no frame has arrived — a second and a half
# after the reply, which is eighteen worker turns. It cannot be won by
# luck in either direction, and it is the check whose NAME is the claim
# these two fixes exist to make true.
#
# 2 · The host half of the same law. With the hold set ignored, the frame a
#     revocation produces arrives while the renderer has said it is busy —
#     so the row leaves the screen under the cursor that is still on it,
#     and the "state, not a race" assertion becomes a race again.
probe "the host honours a holding renderer" battery \
  "it is a state and not a race" \
  cockpit/src/worker.rs \
  's|        self.sink.is_some() \&\& self.in_flight.is_none() \&\& self.holds.is_empty()|        self.sink.is_some() \&\& self.in_flight.is_none()|'

# 3 · The renderer half of the hold. Submitting without taking one first
#     leaves the frame free to arrive mid-call, which is the timing window
#     a vacuous version of this battery would have been measuring all
#     along.
probe "a submission takes its hold before it is sent" battery \
  "it is a state and not a race" \
  cockpit/ui/cockpit.js \
  's|^  await window.cockpit.holdBegin(id);$|  ;|'

# 4 · The DOM is derived. Rendering the grant list from the first frame
#     forever is a screen that was true once — which is the failure this
#     whole product is about, arrived at from the other direction.
probe "the world region is rebuilt from the frame, not remembered" battery \
  "the grant leaves the screen only when a frame says so" \
  cockpit/ui/cockpit.js \
  's|const grants = liveGrants.map|const grants = (window.__firstGrants = window.__firstGrants ?? liveGrants).map|'

# 5 · A read on the intent surface. The cockpit would then have a second,
#     uncursored way to learn the world — no incarnation, no epoch, no
#     revision — and could render from that instead.
probe "the intent surface admits no read" surface \
  "no intent on the surface is a read" \
  cockpit/src/worker.rs \
  's|^    "approve_grant_request",$|    "approve_grant_request", "operator_projection",|'

# 6 · The fixture's guard. Without it, a launch with `SUPER_COCKPIT_FIXTURE=1`
#     and no world mode set mints demo authority inside the world a person
#     actually uses.
probe "the demo fixture is refused against a person's world" fixture \
  "the fixture is refused against a persistent world" \
  cockpit/src/worker.rs \
  's|^    matches!(world, WorldDir::Ephemeral(_))$|    true|'

# --- W.2.1 -----------------------------------------------------------

# 7 · **W.2's actual defect, restored.** Drop `intent` from the ACL
#     manifest and it goes back to being an application command outside
#     the ACL — reachable from every webview the process opens, while the
#     capability file goes on describing a boundary that is not there.
probe "a registered command outside the ACL is caught statically" acl \
  "every registered command is declared to the ACL" \
  cockpit/build.rs \
  's|^                "intent",$||'

# 8 · The ACL, load-bearing at runtime. Granting the capability to the
#     untrusted pane is the one-word version of hosting a browser pane
#     carelessly, and the pane can then revoke a person's grants.
probe "the ACL is what refuses the untrusted pane" battery \
  "an unprivileged webview may not invoke intent at all" \
  cockpit/capabilities/default.json \
  '/"webviews": \[/{n;s|"main"|"main",\n    "pane"|}'

# 9 · **The W.2 first-frame race, made visible.** If binding a sink does
#     not clear what the previous page was told, a sink that arrives after
#     the world is already live is fed nothing until the world next
#     changes — which is the wedge W.2 shipped, reachable deterministically
#     by reloading the page.
#
#     **Re-anchored in W.2.3.3**, which gave `Delivery::bind` a second
#     parameter. The address range stopped matching, the sed inside it
#     therefore ran over the whole file, and `unbind` — which clears the
#     same field for the same reason — took the edit instead. The dry run
#     caught it in seconds; it is exactly why the dry run exists.
probe "a sink that binds late is brought up to the current state" battery \
  "a sink that binds after the world is already live" \
  cockpit/src/worker.rs \
  '/    fn bind(&mut self, stream: StreamId, sink: Channel<Value>) {/,/^    }$/ s|^        self.sent = None;$||'

# 10 · **Holds as a boolean.** `clear()` on any release is precisely what
#      `paused: bool` did: the first interaction to finish frees the
#      surface while the second one is still waiting on its outcome.
#
#      **The indentation is load-bearing and it moved.** W.2.2 lifted the
#      match arms out of `drain` into `apply`, so this line went from
#      sixteen spaces to twelve and this sed stopped matching — silently,
#      reporting SABOTAGE MISSED half an hour into a release. That is the
#      same class as `sabotage-host.sh` probes 7–12 going dead when the
#      host became a library: a probe that no longer applies its sabotage
#      still runs, still costs a rebuild, and proves nothing.
probe "an interaction hold is keyed, not a shared flag" battery \
  "one interaction ending does not release another" \
  cockpit/src/worker.rs \
  's|^            delivery.holds.remove(&id);$|            let _ = \&id; delivery.holds.clear();|'

# --- W.2.2 -----------------------------------------------------------

# 11 · **W.2.1's ACL, restored — and this is the finding itself, measured.**
#      One word: `webviews` back to `windows`. Tauri resolves a command
#      against (window label, webview label) with an OR, so a capability
#      naming the WINDOW is satisfied by every webview drawn inside it —
#      and the pane is a child webview of `main`. W.2.1's own battery
#      could not have caught this, because its pane was a separate window
#      and a separate window is denied under either spelling.
#
#      This probe is what turns "current Tauri says so in a doc comment"
#      into "this pane invoked `intent` and was allowed to".
probe "a window-scoped grant reaches every webview inside that window" battery \
  "an unprivileged webview may not invoke intent at all" \
  cockpit/capabilities/default.json \
  's|"webviews": \[|"windows": [|'

# 12 · And the static gate that stops it coming back. The runtime probe
#      above needs a build, a display and four minutes; this one is the
#      cheap guard that runs first in the chain and refuses the word.
probe "the word 'windows' is refused before anything is built" acl \
  "the capability names no window" \
  cockpit/capabilities/default.json \
  's|"webviews": \[|"windows": [|'

# 13 · **W.2.1's QUEUE, RESTORED — the second finding, measured.** Control
#      messages go back onto the mutation lane and back to `try_send`,
#      which is exactly what shipped. `SyncSender::try_send` on a full
#      buffer returns `Full` and **the message is not sent**, so the
#      release that would reopen the valve is discarded by the congestion
#      it exists to clear: `holds` never empties, `in_flight` is never
#      cleared, and no frame is ever delivered again. `cockpit.js` does not
#      await `ack`, so in the shipped product nothing would have said so.
#
#      Both named checks must go red. They wedge through different fields
#      and a repair that fixed one would leave the other shipping.
probe "a release and an acknowledgement survive a saturated queue" battery \
  "a release issued while the mutation lane is saturated is admitted%%an acknowledgement issued while the mutation lane is saturated is admitted" \
  cockpit/src/worker.rs \
  's@^        self.control.send(m).map_err(|_| "the cockpit worker has stopped".to_string())$@        self.intents.try_send(m).map_err(|e| e.to_string())@'

# 14 · The static half of the same rule, and the cheap one. `try_send` is
#      refused by name, so the class cannot return through someone picking
#      the wrong of two methods that differ by four characters — in a file
#      whose prose would go on describing a lane that could not drop.
probe "a lossy send is refused by name" acl \
  "no valve-control message is sent lossily" \
  cockpit/src/worker.rs \
  's@^        self.control.send(m).map_err(|_| "the cockpit worker has stopped".to_string())$@        self.intents.try_send(m).map_err(|e| e.to_string())@'

# --- W.2.3 -----------------------------------------------------------

# 15 · **THE W.2.2 WEDGE, RESTORED.** Without retransmission, one frame that
#      is sent successfully and never reaches the renderer closes the valve
#      for good — which is exactly what W.2.2 did once and could not be made
#      to do again. The mechanism is upstream and documented: wry's
#      WebKitGTK `eval` hands the script to `run_javascript` and returns
#      `Ok(())` without inspecting the asynchronous result (wry#1644).
#
#      Both named checks must go red: the frame must fail to come back AND
#      the same-bytes assertion must fail with it, because a "recovery" that
#      invents a newer state would satisfy the first alone.
#
#      **W.2.3.3 RE-POINTED THE FIRST NAME, AND THE REASON IS THIS ROUND'S
#      OWN FIX.** The check used to be satisfied by any new frame, which was
#      specific enough while a lost frame wedged the stream forever. The
#      projection deadline ends that state: with retransmission disabled the
#      page now withdraws within one lease, rebinds, and is sent the current
#      world on a fresh channel — so frames move and the probe went NOT A
#      FALSIFIER after three green rounds. A retransmission does not rebind,
#      so the check names the CHANNEL now. A fix that makes an old witness's
#      failure mode recoverable has not repaired the witness.
probe "an unacknowledged frame is sent again" battery \
  "and it is sent again on the same channel%%the retransmission is the SAME sequence" \
  cockpit/src/worker.rs \
  's@^        self.retransmits += 1;$@        if true { return; } self.retransmits += 1;@'

# 16 · **The heartbeat.** Without it a page cannot tell a world that has
#      nothing to say from a link that can no longer say anything, and the
#      lease below has nothing to run on.
probe "the link speaks for itself when the world is quiet" battery \
  "the link says it is alive on its own%%the page withdraws LIVE LOCAL when it hears nothing" \
  cockpit/src/worker.rs \
  's@^        self.beat_at = Instant::now();$@        self.beat_at = Instant::now(); if true { return; }@'

# 17 · **The lease.** With the withdrawal removed the page goes on showing a
#      world nobody is maintaining, and goes on offering buttons that submit
#      authority against it — which is a worse failure than a crash, because
#      it looks exactly like a working cockpit.
#
#      **W.2.3.1 adds a second required line to this same sabotage rather
#      than a second probe.** The lease has to withdraw under BOTH faults —
#      an application-level loss and a gap in the transport — and the whole
#      finding of W.2.3.1 is that a property asserted under one fault is not
#      evidence for the other. But the sabotage that removes the lease is
#      one line either way, and two probes running it to grep two different
#      names would be the same battery twice. That is what `%%` is for.
#
#      **Re-anchored in W.2.3.2.** This used to sed the line
#      `if (Date.now() - c.heard_at > c.lease_ms) withdraw();`, which that
#      round rewrote into a shared deadline test. The pattern stopped
#      matching and the probe reported SABOTAGE MISSED — correctly, and an
#      hour into a release chain. A sabotage anchored on a line a later
#      round rewrites proves nothing while still looking like a probe; see
#      SABOTAGE_DRYRUN above, which exists because of this.
probe "a dead stream withdraws the claim rather than looking quiet" battery \
  "the page withdraws LIVE LOCAL when it hears nothing%%the lease withdraws the stale world under a transport gap" \
  cockpit/ui/cockpit.js \
  's@^  if (silent) return withdraw(.silence.);$@  if (silent) return;@'

# 18 · **Sequence dedup.** A retransmission is the same frame arriving
#      twice. Rendering it again reflows the list under a person's cursor
#      for no new information, and the stale case walks the world backwards
#      after a recovery.
probe "a repeated frame is applied once, not twice" battery \
  "a frame already applied is not rendered again%%and a frame older than one already applied" \
  cockpit/ui/cockpit.js \
  's@^  if (msg.seq <= c.applied) {$@  if (false) {@'

# 19 · **The valve diagnosis.** W.2.2 wedged and five downstream checks
#      failed without naming which of `sink`, `in_flight` or `holds` had
#      stayed set. A heartbeat that carries no diagnosis is that round
#      again.
probe "a closed valve names the term that closed it" battery \
  "it carries the valve diagnosis" \
  cockpit/src/worker.rs \
  's@^            "open": self.open(),$@@'

# 20 · **W.2.3.1 · a bounded retry that does not say so is silence.** With
#      the limit off the heartbeat the page cannot tell a repair that is
#      still coming from a host that has stopped trying — the same class as
#      W.2.2's undiagnosable valve, one field along.
probe "a bounded retry says it is bounded" battery \
  "whether the host is still trying" \
  cockpit/src/worker.rs \
  's@^            "retry_limit": self.retry_limit,$@@'

# 21 · **W.2.3.1 · reacquisition is a LOOP.** This restores W.2.3's line
#      exactly: `withdraw()` returns early once the page has withdrawn, and
#      only a delivered message clears that flag — so one rebind is
#      attempted, ever. Against a single gapped channel it looks like a
#      working recovery. Against two it is a page wedged on *stream lost*
#      forever, which is W.2.2's defect one layer further out: a recovery
#      path whose own failure is permanent silence.
#
#      Three named checks, because the failure has three visible halves and
#      a repair that produced only one would not be a recovery.
#      **Re-anchored in W.2.3.2**, which replaced `reacquire()` with a
#      budgeted `nextCandidate()`. Stubbing the loop's call leaves
#      `withdraw()`'s single attempt intact, which is precisely W.2.3.1's
#      behaviour: one candidate, ever.
probe "one rebind is not a recovery" battery \
  "reacquisition keeps trying%%and a FRESH channel restores LIVE LOCAL%%the world region is rebuilt from that frame" \
  cockpit/ui/cockpit.js \
  's@^    if (silent) return nextCandidate();$@    return;@'

# 22 · **W.2.3.1 · only a frame may end a withdrawal.** W.2.3 called
#      `restore()` from the heartbeat arm, so evidence the LINK was alive
#      cleared a claim about the WORLD.
#
#      **Falsified against the static check, not the battery, and that is
#      the honest place for it.** On the shipped host a fresh channel's
#      first message is always a frame — the loop delivers before it beats
#      — so there is no window in which a heartbeat reaches a withdrawn
#      page first, and a battery witness for it would be waiting on an
#      ordering in another process rather than on this rule. Which is
#      precisely why the rule should not depend on that ordering.
probe "only a frame may end a withdrawal, not a heartbeat" acl \
  "a withdrawal is ended by a frame and by nothing else" \
  cockpit/ui/cockpit.js \
  's@^    c.lease_ms = msg.lease_ms ?? 0;$@    c.lease_ms = msg.lease_ms ?? 0; if (c.withdrawn) restore();@'

# 23 · **W.2.3.1 · the abandoned channel is retired.** A `Channel` cleans
#      itself up when its message index reaches the `end` index Tauri sends
#      on drop — the one count a permanent hole guarantees it never
#      reaches. Without the explicit retirement the callback stays
#      registered with a whole projection per buffered frame behind it, and
#      every recovery adds another.
probe "the channel a rebind replaces is retired" battery \
  "the wedged channel is retired rather than left registered" \
  cockpit/ui/cockpit.js \
  's@^  retire(c.channel);$@@'

# 24 · **W.2.3.1 · and the witness itself must reach the transport.** With
#      the channel unnamed, a sabotage can only reach `window.cockpit
#      .deliver` — above the ordering layer whose failure the round is
#      about. That is precisely the gap this round exists to close, so it
#      is checked rather than assumed.
probe "a witness that cannot name the transport cannot model the failure" battery \
  "the page names the transport it is bound to" \
  cockpit/ui/cockpit.js \
  's@^  c.channel_id = frames.id;$@  c.channel_id = null;@'

# 25 · **W.2.3.2 · a local budget recovery can re-mint is not a budget.**
#      `RETRY_LIMIT` bounds sends per channel; without the candidate limit
#      the page builds another channel, and another, forever. Under a
#      permanently broken transport that is an unbounded global retry — and
#      on Tauri's >8192 path every send whose script never ran parks a whole
#      projection in `ChannelDataIpcQueue`, Rust-side state no page-side
#      retirement can reclaim.
probe "a recovery that can re-mint its own budget is not bounded" battery \
  "reaches a terminal state instead of retrying forever%%and it stops SPENDING%%a deliberate retry begins a new bounded episode" \
  cockpit/ui/cockpit.js \
  's@^  if (c.candidates >= CANDIDATE_LIMIT) return unavailable();$@@'

# 26 · **W.2.3.2 · the candidate deadline.** This restores W.2.3.1's
#      asymmetry exactly: 3 s for a replacement channel against the host's
#      advertised 6 s lease for an established one. A healthy candidate
#      whose first frame takes four seconds is then killed at three, and so
#      is the next — a permanent outage manufactured out of a merely slow
#      recovery, by the mechanism that exists to end outages.
probe "a candidate is judged by the same deadline as the stream it replaces" battery \
  "a slow but healthy candidate is not killed by the recovery" \
  cockpit/ui/cockpit.js \
  's@^  const silent = c.link_heard_at > 0 && Date.now() - c.link_heard_at > c.lease_ms;$@  const silent = c.link_heard_at > 0 \&\& Date.now() - c.link_heard_at > (c.withdrawn ? 3000 : c.lease_ms);@'

# 27 · **W.2.3.2 · unbinding is what ends the cost.** Retiring the callback
#      stops the PAGE reading. Only this stops the HOST writing, and a
#      terminal state that merely stops listening has relocated the resource
#      cost rather than ended it.
probe "the terminal state tells the host to stop, not just itself" battery \
  "and the HOST stops sending" \
  cockpit/ui/cockpit.js \
  's@.*unbind_frame_stream.*catch.*@  /* not unbound */;@'

# 28 · **W.2.3.2 · and the diagnostic collection.** Small beside the Tauri
#      payload queue, but it grows fastest in exactly the failure it exists
#      to describe — an unbounded collection inside a bounded-recovery
#      mechanism is the defect in miniature.
probe "the retirement log is bounded too" battery \
  "the diagnostic collection is bounded too" \
  cockpit/ui/cockpit.js \
  's@^    if (window.cockpit.retired.length > RETIRED_KEPT) window.cockpit.retired.shift();$@@'

# 29 · **W.2.3.3 · the host said it had given up and the page kept claiming.**
#      This is W.2.3.2 restored exactly. The heartbeat has carried
#      `in_flight.exhausted` since W.2.3.1, the battery has checked the FIELD
#      EXISTS since W.2.3.1, and nothing in the page ever read it — so the
#      one message able to say *the state you are showing has been abandoned*
#      was, by arriving, the thing that kept the lease from firing. The
#      cockpit went on offering authority against a projection it had been
#      told was superseded and undeliverable.
#
#      **The expected-RED list is exactly two, and choosing them was the
#      whole difficulty.** With this path disabled the page does NOT go on
#      claiming forever — the projection deadline added by the same round
#      catches the same stuck frame about a lease later and withdraws as
#      `unmaintained`. So "it withdrew" and "it recovered" both still pass,
#      and a probe naming them would report a fix that had been deleted as
#      working, several seconds late. What cannot survive the deletion is the
#      REASON, and the fact that neither deadline had expired when it fired.
#      Measured both ways by hand before this list was written.
probe "an abandoned delivery revokes the projection claim" battery \
  "the page stops claiming the projection it can no longer be shown a successor to%%while NEITHER deadline had expired" \
  cockpit/ui/cockpit.js \
  's@^      if (!c.withdrawn && !c.unavailable) withdraw(.exhausted.);$@      if (false) withdraw("exhausted");@'

# 30 · **W.2.3.3 · one clock for two facts.** The exhaustion path above is
#      not the whole repair — it depends on the host reporting a specific
#      field, and a host that stopped reporting it (or a retry depth at which
#      it is not yet true) would leave the page claiming forever again. The
#      second deadline is the one that does not depend on the diagnosis.
#
#      This sabotage collapses the clocks back into W.2.3.2's single one: the
#      heartbeat refreshes the projection clock whatever its valve says, so a
#      frame that is stuck between the runtime and the page is bought another
#      lease every 1.5 s, forever.
#
#      **Falsified against `cockpit-maintenance`, not the battery**, because
#      at the shipped retry depth the exhaustion statement always arrives
#      first and this deadline can never fire. See that file's header.
probe "link liveness is not projection maintenance" maint \
  "the page stops claiming a projection nothing has confirmed for a whole lease%%while the link was alive and the host had not given up" \
  cockpit/ui/cockpit.js \
  's@^    if (!unseen) c.projection_at = Date.now();$@    c.projection_at = Date.now();@'

# 31 · **W.2.3.3 · a teardown from a position that no longer exists.**
#      `unavailable()` fires an un-awaited `unbind_frame_stream`; a person's
#      *Try again* fires `bind_frame_stream` behind it; and nothing in the
#      IPC orders them — each command is its own `async_runtime::spawn` and
#      its own `spawn_blocking`. `main.rs` claimed the shared control lane
#      did, which is prose describing a boundary that does not exist.
probe "a stale teardown may not destroy the stream that replaced it" battery \
  "a teardown addressed to a superseded binding is refused" \
  cockpit/src/worker.rs \
  's@^        if self.stream.as_ref() != Some(&stream) {$@        if false {@'

# 32 · **W.2.3.3 · and a sink offered from one.** A superseded bind carries a
#      channel the page has already retired; adopting it points the host at a
#      sink nobody reads and costs a whole lease to discover.
probe "a stale bind may not displace the binding that replaced it" battery \
  "a sink offered from one is refused too" \
  cockpit/src/worker.rs \
  's@^            if cur.page == stream.page \&\& stream.generation <= cur.generation {$@            if false {@'

# 33 · **W.2.3.3 · a stale completion may not write to the active locus.**
#      W.2.3.2's `bind()` wrote the deadline clock in the continuation of its
#      own invoke, so a slow or saturated bind minted extra lease time for
#      the candidate it produced — while the comment two functions above said
#      the candidate's deadline began at the attempt and was not restarted by
#      binding. The code and the brief disagreed and the code was running.
#
#      **Held statically, and that is the honest place for it.** A bind that
#      resolves in a millisecond moves the clock by a millisecond, so there
#      is no dynamic window to witness; the property is *which lines may
#      write a clock*, and that is exactly what the ACL check counts. Same
#      argument as probe 22.
probe "a stale completion may not restart the deadline it is not part of" acl \
  "the link clock is advanced by an arriving message and by a candidate attempt" \
  cockpit/ui/cockpit.js \
  's@^      window.cockpit.bound = true;$@      window.cockpit.bound = true; window.cockpit.link_heard_at = Date.now();@'

echo
# **The dry run must NOT print the line the release chain records.**
# ------------------------------------------------ R0a · I Speak
#
# **The source of the bytes, falsified.** `tools/terminal-join-probe.mjs`
# asserts `SUPER-DOGFOOD-R0-READY` appears in a real xterm after a real
# click. That assertion is green for one of two reasons and they are not the
# same: because the payload wrote the marker to its own terminal, or because
# some other layer put the string on the screen.
#
# So the write is removed and nothing else is. The Carrier still starts, the
# terminal is still PRESENT, the presentation still opens, the sink still
# binds and the page still beats — the probe's first six rows stay green,
# which is the whole point. Only the marker rows go red, and they go red
# together, because there is no other producer.
#
# Deliberately NOT the reverse experiment. Injecting the marker from the
# host or the page as a positive control would build the very bypass this
# probe exists to rule out, and it would then live in the tree.
# **One expectation, and the other fifteen rows staying green is the other
# half of the evidence.** The identity line below the marker still writes,
# so the plane still carries a frame and every transport row — contiguity,
# credit, no fault — stays green. A sabotage that turned the whole probe red
# would be consistent with having broken the Carrier; this one is only
# consistent with having removed the marker.
#
# `@` as the sed delimiter, not `|`: the line being replaced contains `||`,
# and `s|…||…|` terminates in the middle of the pattern. The battery would
# report SABOTAGE MISSED, which is at least honest, but the delimiter is
# cheaper than the discovery.
probe "a payload that does not write its own marker is noticed" join \
  "the marker SUPER-DOGFOOD-R0-READY reached a real xterm" \
  dogfood/src/main.rs \
  's@        if writeln!(t, "{MARKER}").is_err() || t.flush().is_err() {@        if false {@'

# `emit-measurements.mjs` extracts `cockpit_falsifiers` with
# `^cockpit sabotage: (\d+) falsified · (\d+) did not$`. A dry run printing
# that would file 28 patterns-that-matched under the name of 28
# fixes-that-were-falsified — a figure that is not merely wrong but wrong in
# the direction of claiming more evidence than exists. This is W.1.4.1's
# trap 4 exactly, where two harnesses printed byte-identical summaries.
if [ -n "${SABOTAGE_DRYRUN:-}" ]; then
  echo "cockpit sabotage DRY RUN: $pass patterns matched · $fail missed"
else
  echo "cockpit sabotage: $pass falsified · $fail did not"
fi
[ "$fail" -eq 0 ]
