#!/usr/bin/env bash
# Prove each F.8.2 descriptor falsifier by sabotage — **at the OS
# boundary**, because that is the only place these can be measured.
#
# `ampd/tools/sabotage.sh` says so itself, and said it before this round:
# a descriptor with no Erlang owner is reachable only from an `SCM_RIGHTS`
# receive, and nothing inside the BEAM can construct one. So the leak lived
# for a whole revision inside a suite that could not have seen it, and
# F.8.1 concluded from 39 green falsifiers and 171 green tests that the
# residue was bounded. It was not. This file is the answer to "how would
# we have known": stub one fix out, run the real host against a real
# runtime, and require the named check to go RED.
#
# Run from the release root:  bash tools/sabotage-host.sh
set -uo pipefail
cd "$(dirname "$0")/.."

# ---------------------------------------------------------------- evidence
#
# **Every execution writes its own immutable log, and a rerun may not erase
# the run that caused it.** C1.0b·2·1 lost a battery log exactly that way:
# the run that found a real non-falsifier was overwritten by the re-run its
# own finding triggered, so the bundle could describe that miss only from
# memory. Evidence is append-only from here.
#
# The caller's own redirection still works and is untouched — this is a tee,
# not a replacement. `set -C` makes the create fail rather than clobber if a
# path ever collides, and the name carries the second and the commit so two
# runs of the same tree are still distinguishable.
__runs="$(cd "$(dirname "$0")" && pwd)/../.sabotage-runs"
mkdir -p "$__runs"
__stamp="$(date -u +%Y%m%dT%H%M%SZ)"
__sha="$(git rev-parse --short=12 HEAD 2>/dev/null || echo nogit)"
__run_log="$__runs/host-$__stamp-$__sha.log"
( set -C; : > "$__run_log" ) || { echo "REFUSING: $__run_log already exists" >&2; exit 1; }
exec > >(tee -a "$__run_log") 2>&1
echo "# host battery · $__stamp · $__sha"

HOST=./host/target/release/super-host
[ -x "$HOST" ] || { echo "build the host first: cargo build --release --manifest-path host/Cargo.toml" >&2; exit 1; }

pass=0; fail=0

# **Restore the tree on any exit, and this file did not.**
#
# `ampd/tools/sabotage.sh` has carried an EXIT trap since W.1.4 for exactly
# this reason; this one carried a *comment* referring to "the `INT` trap this
# file already carries" and no trap at all. The comment is the worse half: it
# tells a reader the protection exists.
#
# It is not hypothetical. Interrupting this battery mid-probe left
# `ampd/lib/ampd/native_fd.ex` sabotaged in the working tree with its `.orig`
# beside it — the module whose entire job is that every received descriptor
# has an exit, silently altered, one `git add -A` away from being committed.
#
# The signals *exit* rather than restore-and-continue, and the single EXIT
# trap owns restoration: a handler that only restores would return into a
# probe still running, with every `.orig` pulled out from under it. 130 and
# 143 are the conventional 128+SIGINT and 128+SIGTERM, so a caller can still
# tell which arrived. Same reasoning, same shape, as the ampd battery.
#
# One nuance, because verifying this trap is what taught it: bash defers a
# trap until the current foreground command returns, and this script spends
# most of its life inside `cargo build` or a 240 s `timeout`. A real Ctrl-C
# is prompt anyway — the terminal signals the whole process GROUP, so the
# child dies at once and the trap runs immediately after. A bare
# `kill -INT <script-pid>` does not, and appears to do nothing for as long
# as the child takes. It is not stuck; it is waiting.
restore_all () {
  for f in host/src/*.rs.orig ampd/lib/ampd/*.ex.orig ampd/lib/ampd/*/*.ex.orig; do
    [ -e "$f" ] || continue
    mv -- "$f" "${f%.orig}"
    touch -- "${f%.orig}"
    echo "  restored ${f%.orig}" >&2
  done
}
trap restore_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# probe <name> <expected-RED check substring> <file> <sed-expr>...
probe () {
  local name="$1" expect="$2" f="$3"; shift 3
  cp "$f" "$f.orig"
  for e in "$@"; do sed -i "$e" "$f"; done

  if cmp -s "$f" "$f.orig"; then
    echo "  SABOTAGE MISSED  $name — the pattern did not match; the probe proved nothing"
    fail=$((fail+1))
    mv "$f.orig" "$f"; touch "$f"; return
  fi

  # A sabotage that does not compile turns the whole battery red, which
  # would otherwise be scored as the strongest possible result — awarded
  # for breaking the build. Check separately, exactly as the BEAM battery
  # does.
  # A Rust probe has to rebuild the thing it is sabotaging; an Elixir one
  # only has to recompile the runtime the host drives. Same separate
  # compile check either way, for the same reason.
  if [[ "$f" == host/* ]]; then
    built=$(cargo build --release --manifest-path host/Cargo.toml 2>&1) && rc=0 || rc=1
  else
    (cd ampd && mix compile >/dev/null 2>&1) && rc=0 || rc=1
  fi

  if [ "$rc" -ne 0 ]; then
    echo "  BROKE THE BUILD  $name — red because it did not compile, which proves nothing"
    fail=$((fail+1))
  else
    # **Through a file, with a deadline — not a command substitution.**
    #
    # `out=$(… 2>&1)` reads the pipe until EOF, and EOF does not arrive
    # when the host exits while the `ampd` it spawned is still alive
    # holding the inherited stdout. A sabotage that makes the host die
    # abnormally is therefore a sabotage that hangs this harness forever:
    # measured at **1h46m** on probe 11, with a `.orig` left in the tree
    # the whole time and an orphaned BEAM holding the pipe open.
    #
    # That is the same class of defect as the missing EXIT trap above — a
    # harness that can wedge or corrupt the source it is testing is worse
    # than anything it can find. A file has no writer to wait on, and
    # `timeout` bounds a host that genuinely hangs.
    out_file=$(mktemp)
    timeout 240 "$HOST" verify >"$out_file" 2>&1
    rc=$?
    out=$(cat "$out_file")
    rm -f "$out_file"

    # Reap anything the sabotaged host left behind, so the next probe does
    # not start against this one's litter.
    pkill -f "mix run --no-halt" 2>/dev/null

    if [ "$rc" -eq 124 ]; then
      echo "  TIMED OUT        $name — the host did not finish in 240s; nothing was proved"
      fail=$((fail+1))
      mv "$f.orig" "$f"; touch "$f"
      if [[ "$f" == host/* ]]; then
        cargo build --release --manifest-path host/Cargo.toml >/dev/null 2>&1
      else
        (cd ampd && mix compile >/dev/null 2>&1)
      fi
      return
    fi

    if grep -q "FAILED.*$expect" <<<"$out"; then
      echo "  falsified        $name"
      echo "                   → $(grep -o "FAILED.*$expect[^—]*—[^\"]*" <<<"$out" | head -1 | cut -c1-150)"
      pass=$((pass+1))
    else
      echo "  NOT A FALSIFIER  $name — '$expect' passed with the fix disabled"
      fail=$((fail+1))
    fi
  fi

  mv "$f.orig" "$f"; touch "$f"

  if [[ "$f" == host/* ]]; then
    cargo build --release --manifest-path host/Cargo.toml >/dev/null 2>&1
  else
    (cd ampd && mix compile >/dev/null 2>&1)
  fi
}

echo "host sabotage battery — each line stubs one fix and expects a named check RED"

# 1 · The sink itself, on the bind path. This is F.8.1's residue exactly:
#     the channel works, the descriptor is never freed.
probe "an adopted descriptor is disposed of" \
  "closing every channel returns the runtime to its baseline" \
  ampd/lib/ampd/native_fd.ex \
  '110,120 s|^            discard(fd)$|            :ok|'

# 2 · F.8.1's setting, restored verbatim: `dup: false` and no sink. The
#     runtime keeps working, and every channel it ever opened costs a
#     descriptor forever.
probe "F.8.1's dup:false adoption leaks one descriptor per channel" \
  "closing every channel returns the runtime to its baseline" \
  ampd/lib/ampd/native_fd.ex \
  's|:socket.open(fd, %{dup: true}) do|:socket.open(fd, %{dup: false}) do|' \
  '110,120 s|^            discard(fd)$|            :ok|'

# 3 · The sink on the *rejected* path — the half F.8.1 never sent a
#     descriptor down, and the reason its "bounded by channels, not
#     traffic" claim was false.
probe "a rejected command's descriptors are disposed of" \
  "thirty rejected commands leave the runtime at its baseline" \
  ampd/lib/ampd/transport.ex \
  's|    defp close_fd(fd), do: Ampd.NativeFd.discard(fd)|    defp close_fd(_fd), do: :ok|'

# 4 · The flag `dup(2)` drops. Nothing in F.8.1 or in the ruling that
#     prescribed `dup: true` mentions this: `dup(2)` does not copy
#     `FD_CLOEXEC`, so the fix for the leak silently undoes the fix for
#     inheritance unless the flag is put back.
probe "the FD_CLOEXEC that dup(2) drops is put back" \
  "every descriptor the runtime took for a channel is close-on-exec" \
  ampd/lib/ampd/native_fd.ex \
  's|         :ok <- set_cloexec(fd) do|         :ok <- (fn _ -> :ok end).(fd) do|'

# 5 · A refusal is not a disposal. Restoring F.8.2's fast-refusal branch
#     leaves the runtime keeping the descriptor of every control claim it
#     turns down — reachable by asking for something you are not permitted
#     to have, which is the one move a hostile local process always has.
probe "a refused control claim disposes of the channel it arrived on" \
  "a hundred refused control claims cost the runtime nothing" \
  ampd/lib/ampd/bridge.ex \
  's|^      dispose(fd_or_socket)$|      _ = fd_or_socket|'

# 6 · The bridge is adopted the same way a channel is. Restoring the old
#     line leaves the runtime holding the bridge *as* the raw inherited
#     descriptor, inheritable, for the life of the process.
probe "the inherited bridge descriptor is adopted, not merely wrapped" \
  "the raw inherited bridge descriptor is closed" \
  ampd/lib/ampd/bridge.ex \
  's|            case Ampd.NativeFd.adopt_socket(fd) do|            case :socket.open(fd, %{dup: false}) do|'

# --- W.1: the cockpit, in Rust ---------------------------------------

# 7 · The distinction the whole of F.8.2.5 is about, collapsed. A runtime
#     restart and a world discontinuity both mean "discard what you hold";
#     only one of them means "and the authority you hold is no longer
#     yours". A host that answers RESNAPSHOT to a restore keeps a
#     capability the runtime has already closed.
probe "a world discontinuity is not merely a new runtime" \
  "a new incarnation classifies as REACQUIRE" \
  host/src/lib.rs \
  's|            return Continuity::NewIncarnation;|            return Continuity::NewRuntime;|'

# 8 · The loop's reason to exist. Without the EOF check, a control channel
#     that died is never noticed: the host sits holding a dead capability,
#     rendering the last projection it happened to receive, forever. This
#     is the state F.8.2.5 shipped in, and it reported it as such.
probe "a control channel at EOF is noticed without being asked" \
  "the host reacquires human control and returns to LIVE LOCAL" \
  host/src/lib.rs \
  's|            Some(c) => c.closed(),|            Some(_c) => false,|'

# 9 · W.1 said LIVE LOCAL meant "holding a projection" and the struct had
#     no field for one. Dropping the projection while keeping the cursor is
#     exactly the state it shipped in, and the next step would have been a
#     WebView fetching the view separately — a second sample.
probe "LIVE LOCAL means the cockpit is holding the view" \
  "LIVE LOCAL means the cockpit is holding the view" \
  host/src/lib.rs \
  's|        self.projection = Some(frame\["projection"\].clone());|        self.projection = None;|'

# 10 · The stream is driven by the view revision. Comparing the authority
#      revision ignores every frame in which only the runtime changed — a
#      channel opening, a channel dying, a refusal landing.
probe "the cockpit stream is driven by the view revision" \
  "a channel opening reaches the cockpit without an authority mutation" \
  host/src/lib.rs \
  's|        let r = v\["view_revision"\].as_u64().unwrap_or(0);|        let r = v["revision"].as_u64().unwrap_or(0);|'

# 11 · A runtime restart must be resnapshotted, not reacquired. Collapsing
#      it into the incarnation branch costs the person the human-control
#      capability that a restart is specifically defined not to touch.
# **Bumping the counter, not nulling the channel.** The first form of this
# sabotage set `self.chan = None`, which makes the battery's later EOF
# witness `unwrap()` a `None` and abort the host mid-run — so the probe
# went red for a panic rather than for the property, and took the harness
# down with it. A sabotage has to model the defect, not break the measuring
# instrument.
probe "a runtime restart keeps the person's authority" \
  "a runtime restart is resnapshotted, not reacquired" \
  host/src/lib.rs \
  's|            Continuity::NewRuntime => {|            Continuity::NewRuntime => { self.reacquisitions += 1;|'

# 12 · Cursor fields fail closed. The lenient reader turns a missing
#      authority revision into a zero, and a zero is a number a WebView
#      renders as fact.
probe "a cursor field that is absent is not invented" \
  "a frame with no revision is refused rather than defaulted" \
  host/src/lib.rs \
  's|            authority_revision: v\["revision"\].as_u64()?,|            authority_revision: v["revision"].as_u64().unwrap_or(0),|'

# ---------------------------------------------------------------- D.1.3b
#
# The confinement checks are the ones most able to go green over nothing:
# every one of them would pass if the mechanism were absent and the probe
# simply failed for its own reasons. These four stub a specific row of the
# floor and name the check that must notice.

# 14 · no_new_privs removed. `landlock_restrict_self` and
#      `seccomp(SET_MODE_FILTER)` both refuse without it, so this is also the
#      probe that proves `install` is not silently tolerating its own errors.
probe "removing no_new_privs is noticed" \
  "a confined Carrier starts" \
  host/src/confine.rs \
  's|        if prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0 {|        if false {|'

# 15 · The seccomp filter, not installed. Landlock stays, so the filesystem
#      rows still pass — which is the point: the syscall rows must fail on
#      their own and not be carried by the filesystem policy.
probe "a Carrier with no seccomp filter is noticed" \
  "seccomp is observed in filter mode with at least one filter attached" \
  host/src/carrier.rs \
  's|                prepared.install(expected_parent)|                { let _ = (\&prepared, expected_parent); Ok(()) }|'

# 16 · The environment, inherited rather than constructed. `env_clear` is one
#      call and its absence hands the Carrier `AMPD_BRIDGE_FD` by name.
probe "an inherited environment is noticed" \
  "the Carrier's environment is constructed, not inherited" \
  host/src/carrier.rs \
  's|            .env_clear()|            |'

# 17 · The ruleset descriptor left where the kernel put it — which is fd 3,
#      the number the control channel is placed on. This is the bug this
#      slice hit for real; the probe exists so it cannot come back quietly.
probe "the ruleset descriptor colliding with the allowlist is noticed" \
  "the Landlock ruleset descriptor sits above the Carrier's allowlist" \
  host/src/confine.rs \
  's|    let rs = relocate_above_allowlist(rs as RawFd)?;|    let rs = rs as RawFd;|'

# --- the negative syscall census -------------------------------------
#
# These three answer the review objection directly. Every one of them
# leaves the *mechanism* fully installed — Landlock, seccomp and
# no_new_privs all still enforce — and removes exactly one number from
# the deny list. If the census were reading a general property rather
# than issuing the syscall, all three would stay green.

# 18 · The anonymous file. `memfd_create` produces a file with no name on
#      any filesystem, so Landlock — whose entire vocabulary is pathnames
#      — cannot see it. Nothing but this list closes it, which is why its
#      absence has to be loud.
probe "memfd_create left reachable is noticed" \
  "memfd_create is refused inside a Carrier" \
  host/src/confine.rs \
  's|^    319, // memfd_create$|    // 319, // memfd_create|'

# 19 · The other half of the same escape. `execve` is deliberately
#      permitted and bounded by Landlock's FS_EXECUTE grant; `execveat`
#      takes a descriptor instead of a path and is bounded by nothing at
#      all unless it is on this list.
probe "execveat left reachable is noticed" \
  "execveat_other_binary is refused inside a Carrier" \
  host/src/confine.rs \
  's|^    322, // execveat$|    // 322, // execveat|'

# 20 · Process creation. The fixture needs none of it and the probe no
#      longer forks, so this is pure policy — and it is the row whose
#      first version went green over a fork that had already been
#      refused, which is the defect the rewrite removed.
probe "fork left reachable is noticed" \
  "fork is refused inside a Carrier" \
  host/src/confine.rs \
  's|^    57,  // fork$|    // 57,  // fork|'

# 20 · The Carrier's control endpoint, leaked instead of dropped. This is the
#      exact residue of the handshake bug source review found: the channel
#      works, the descriptor is never freed, and only a many-cycle census
#      notices.
probe "a leaked control endpoint is noticed" \
  "100 start/stop cycles leave the host descriptor table at baseline" \
  host/src/carrier.rs \
  's|        drop(self.control.take());|        std::mem::forget(self.control.take());|'

# --- D.1.3b·2c · execution identity and the physical reap ------------
#
# Three probes for the three claims this closure adds. Each removes one
# fix and expects the check that exists to catch it to go RED — the
# alternative being twelve new green rows whose green nobody has tested.

# 21 · The TOCTOU itself, restored. Digesting the pathname *after* exec is
#      exactly what the source did, and it needs no attacker: an ordinary
#      concurrent build in that window is enough. With this reverted the
#      host attests B while the live process is A.
#
#      **This probe reported NOT A FALSIFIER on its first run and the probe
#      was right.** The check it names called `running_image_digest` directly,
#      so it measured the function while claiming to measure "what the host
#      attests", and reverting the attestation left it green. The attestation
#      is built by one shared `carrier_attestation`, which both `start_one`
#      and the battery now read — so this line is the production path.
probe "attesting the pathname instead of the running image is noticed" \
  "replacing the pathname after exec does not change what the host attests" \
  host/src/lib.rs \
  's|"execution_basis": execution_basis(running_image_digest(c.pid)),|"execution_basis": execution_basis(installed_payload_digest(\&carrier::fixture_path().unwrap())),|'

# 22 · The admission basis, removed from the channel. Without it the
#      runtime has nothing to bind at admission, so a payload swapped
#      between admission and commit is indistinguishable from the one that
#      was agreed to. The runtime refuses the channel outright — which is
#      the fail-closed direction — so the production join is what goes red.
probe "a carrier channel carrying no execution basis is noticed" \
  "the host creates the Carrier lifecycle channel and passes it over the bridge" \
  host/src/lib.rs \
  's|                "carrier_basis": carrier_basis,|                "carrier_basis_disabled": carrier_basis,|'

# 23 · The reap of an orphaned Carrier, stubbed. `Ampd.Peer` still drops
#      the incarnation, so membership still ends and every record-shaped
#      assertion still passes — which is precisely the D.1.3b·2a defect,
#      and precisely why the freeze criterion needed a check that asks the
#      kernel instead.
probe "an orphaned Carrier that is never reaped is noticed" \
  "losing the real owning Peer really ends the Carrier's OS process" \
  ampd/lib/ampd/carrier/reaper.ex \
  's|def handle_cast({:orphaned, inc}, st), do: {:noreply, reap(inc, st)}|def handle_cast({:orphaned, _inc}, st), do: {:noreply, st}|'

# --- D.1.3b·2d · the runtime incarnation fence -----------------------
#
# J2 and the host-side half of E. Both leave the fence's BEAM machinery
# intact and break only the host's side of it, which is the half a
# BEAM-only battery cannot see at all.

# 24 · The drain answers without doing anything. This is the failure mode
#      that matters most, because every record-shaped assertion still
#      passes: the map is emptied, the reply says `remaining: 0`, and the
#      processes are still there. Only /proc can tell the difference.
#
#      **`mem::forget`, not "skip the terminate".** The first version of this
#      probe swapped `live.drain()` for `std::mem::take(&mut live)`, which
#      empties the map exactly as `drain` does — it sabotaged nothing and the
#      battery said so. Removing the `terminate` call alone would not work
#      either: `Carrier`'s `Drop` reaps anything still holding its control
#      endpoint, which is the invariant D.1.3b·2a added on purpose. Leaking
#      the value is the only way to make the host truly not reap.
probe "a drain that reports success without reaping is noticed" \
  "every drained Carrier is gone from /proc when the drain answers" \
  host/src/lib.rs \
  's|                    c.terminate(3_000);|                    std::mem::forget(c);|'

# 25 · The host's own epoch guard, removed. This is the second line of
#      defence: even with the Gate fenced correctly, a Gate that restarted
#      alongside the Peer has nothing to compare, and this is what stops a
#      start landing in a set that belongs to a dead incarnation.
probe "a start into another incarnation's physical set is noticed" \
  "a start under a NEW incarnation is refused while the old set is non-empty" \
  host/src/lib.rs \
  's|                    Some(cur) if \*cur != want \&\& !live.is_empty() => json!({|                    Some(cur) if false \&\& *cur != want \&\& !live.is_empty() => json!({|'

# 26 · D.1.3b·2e. The numbering-space guard, removed — which restores the
#      filter exactly as D.1.3b froze it. `fork` is on `DENIED`, the
#      architecture check passes because x32 *reports* `AUDIT_ARCH_X86_64`,
#      and `BPF_JEQ nr, 57` then misses `57 | 0x40000000`. Measured before
#      the guard: 23 of the 28 numbers in `DENIED` reached their handler this
#      way, and `fork` did not merely bypass the filter — it forked.
#
#      The expectation names `fork_x32` rather than the count, because that
#      is the row where a Carrier gained a descendant, and a descendant is
#      the physical-lifetime claim failing rather than a confinement row.
probe "a denylist that covers only one syscall numbering space is noticed" \
  "fork_x32 is refused inside a Carrier" \
  host/src/confine.rs \
  's|        jump(BPF_JMP \| BPF_JGE \| BPF_K, X32_SYSCALL_BIT, 0, 1),|        jump(BPF_JMP \| BPF_JGE \| BPF_K, 0xffff_ffff, 0, 1),|'

# 27 · The model the consistency check compares against, not the filter
#      itself. `confine::denies/1` answers "does the policy SAY this is
#      refused"; `verify` cross-references it against what the census
#      MEASURED. Reverting it to bare list membership leaves the filter
#      correct and the description of it stale, which is the failure mode
#      that check exists for — and is why it is probed separately from the
#      guard above.
probe "a policy description that has gone stale against the filter is noticed" \
  "the filter's configured deny list names every syscall the census measured refused" \
  host/src/confine.rs \
  's|    nr >= X32_SYSCALL_BIT \|\| DENIED.contains(&nr)|    DENIED.contains(\&nr)|'

# --- D.1.3c·1 · the possessed terminal --------------------------------------

# 28 · The host stops establishing the controlling terminal, and does
#      everything else. The Carrier still gets a pty on 0/1/2 and still
#      becomes a session leader — which is exactly the middle stage the
#      staged falsifier exists to name, and exactly the state that "it has a
#      terminal" would have accepted.
probe "a pty on stdio that is nobody's controlling terminal is noticed" \
  "the Carrier has a controlling terminal, deliberately established" \
  host/src/carrier.rs \
  's|                    if ioctl_int(s, crate::pty::TIOCSCTTY, 0) < 0 {|                    if false \&\& ioctl_int(s, crate::pty::TIOCSCTTY, 0) < 0 {|'

# 29 · The allow-list becomes a pass-through. Every terminal ioctl is then
#      permitted, including TIOCSTI — which is input injection into the
#      Carrier's own terminal, and the operation CVE-2019-7303 was about.
#      NOTE: a range address. `f.push(stmt(BPF_RET | BPF_K, deny));` occurs
#      in three clauses and only the ioctl one is under test; the first
#      version of this probe tried to wrap the block in `if true {} else`
#      and produced invalid Rust, which the battery scored BROKE THE BUILD —
#      correctly, since red-because-it-did-not-compile proves nothing.
probe "an ioctl allow-list that permits everything is noticed" \
  "a Carrier may NOT inject bytes into its own input queue" \
  host/src/confine.rs \
  '/let n = IOCTL_ALLOWED.len() as u8;/,/OFF_NR));/{s|        f.push(stmt(BPF_RET \| BPF_K, deny));|        f.push(stmt(BPF_RET \| BPF_K, SECCOMP_RET_ALLOW));|}'

# 30 · **The comparison width, and this probe had to be re-aimed.**
#
#      It first expected `TIOCSTI with a garbage high half` to go red and
#      scored NOT A FALSIFIER — correctly. Under an ALLOW-list a request
#      with garbage high bits is refused whichever half is compared, because
#      it is on no list either way. The CVE-2019-7303 bypass is a DENY-list
#      property, and the ruling's choice of an allow-list removed it.
#
#      What the width still decides is whether the filter agrees with the
#      kernel, and only a PERMITTED request can show it: `TCGETS |
#      garbage<<32` IS `TCGETS` to a kernel that truncates `cmd`, so a
#      filter reading the other half refuses a call the kernel would run.
probe "an ioctl filter that reads the half the kernel discards is noticed" \
  "a PERMITTED ioctl still runs with a garbage high half" \
  host/src/confine.rs \
  's|        f.push(stmt(BPF_LD \| BPF_W \| BPF_ABS, OFF_ARG1));|        f.push(stmt(BPF_LD \| BPF_W \| BPF_ABS, OFF_ARG1 + 4));|'

# 31 · The terminal is handed over but not owned, so nothing disposes of it
#      when the Carrier goes. `Carrier`'s `Drop` is what makes "the PTY
#      cannot outlive the Carrier" true by construction rather than by a
#      cleanup somebody has to remember.
#      NOTE: this attacks `Pty`'s disposal, not `Carrier`'s field. Nulling
#      the field instead — `std::mem::forget(pty.take())` — scored NOT A
#      FALSIFIER, and the reason is worth keeping: with no `Pty` there is no
#      master fd, `master_fd` falls back to -1, and "the host holds no
#      master afterwards" becomes vacuously true. A sabotage destructive
#      enough to break the checks *before* the one it targets can satisfy
#      that one by accident.
probe "a terminal that outlives its Carrier is noticed" \
  "dropping the Carrier disposes of its terminal" \
  host/src/pty.rs \
  's|        unsafe { close(self.master) };|        let _ = self.master;|'

# 32 · The host keeps its copy of the slave. Everything works — the Carrier
#      has its terminal, bytes flow both ways — and the hangup never fires,
#      because a pty hangs up on the LAST close and the host is still
#      holding one. A death signal that never arrives.
probe "a host that never lets go of the slave is noticed" \
  "the Carrier's death is the end of the terminal" \
  host/src/carrier.rs \
  's|                p.close_slave();|                let _ = \&p;|'

# --- D.1.3c·1a · the exact-slave correspondence -----------------------------

# 33 · **The join, removed.** The predicate answers `true` for any terminal,
#      which is what the v3 floor amounted to: stdio is *a* pty and the ctty
#      is the host's, with nothing saying they are the same one. Caught only
#      by the decoy row — the positive row still passes, because the Carrier
#      really is on the host's slave.
probe "a stdio-is-my-slave predicate that accepts any terminal is noticed" \
  "answers FALSE for a terminal this host holds but did not give the Carrier" \
  host/src/pty.rs \
  's|            fstat_rdev_of_path(\&format!("/proc/{pid}/fd/{fd}")) == Some(slave_rdev)|            fstat_rdev_of_path(\&format!("/proc/{pid}/fd/{fd}")).is_some()|'

# 34 · The predicate is right and the attestation does not carry it, so the
#      floor has nothing to require. That is the D.1.3b·2a shape exactly —
#      an attested object the runtime demanded and the host never emitted —
#      and it is caught at the World join rather than in the terminal
#      section, because the refusal is an admission refusal.
probe "an attestation that omits the stdio correspondence is noticed" \
  "a real agent starts a real confined Carrier and it JOINS THE WORLD" \
  host/src/lib.rs \
  's|        "stdio_is_this_host_slave": crate::pty::stdio_is_slave(c.pid, p.slave_rdev()),|        "stdio_is_this_host_slave_OMITTED": false,|'

# 35 · Only fd 0 is checked. A Carrier reading the host's terminal and
#      writing somewhere else satisfies every other row: 0/1/2 are still one
#      displayed target to the observed census, the ctty is still the host's.
probe "a correspondence that checks only fd 0 is noticed" \
  "a split stdio is refused" \
  host/src/pty.rs \
  's|        && (0..=2).all(\|fd\| {|        \&\& (0..=0).all(\|fd\| {|'

echo '  --- D.1.3c·2 · the terminal attachment ---'

# The rule from D.1.3c·1a's §I still governs and it bit twice there: a
# sabotage destructive enough to break the checks BEFORE the one it targets
# can satisfy that one by accident. Every probe below is aimed at a check
# whose neighbours stay green, and the ones that could not be written that way
# are named at the bottom instead of being faked.

# 36 · The pump keeps its duplicate of the master forever. Everything works —
#      bytes flow, EOF arrives, the Carrier dies on time — and the host
#      accumulates one pseudoterminal master per attachment for the life of
#      the process. This is host probe 31's defect one descriptor along, and
#      it is invisible to every check that is not a census.
probe "a pump that never returns its duplicate of the master is noticed" \
  "detaching returned the pump" \
  host/src/attach.rs \
  's|^    unsafe { close(master) };|    let _ = master; // SABOTAGE: leaked|'

# 37 · The stall counter never counts. **This attacks the evidence, and that
#      is deliberate.** The claim "a consumer that stops reading stalls the
#      pump instead of growing the host" is only ever visible as a counter,
#      so a probe that could not turn the counter off would be a probe that
#      never tested whether the check is anchored to anything.
probe "a backpressure claim resting on a counter that cannot move is noticed" \
  "stalls the pump instead of growing the host" \
  host/src/attach.rs \
  's|                stats.stalled_out.fetch_add(1, Ordering::Relaxed);|                (); // SABOTAGE: no stall recorded|'

# 38 · The terminal address stops being an address. Every operation names a
#      terminal and the host agrees with all of them, so a resize minted
#      against a Carrier that no longer exists lands on whatever holds the
#      ref now.
probe "a terminal address that accepts any carrier epoch is noticed" \
  "wrong carrier epoch is refused" \
  host/src/carrier.rs \
  's|        if req\["carrier_epoch"\].as_str().unwrap_or("") != self.incarnation {|        if false {|'

# 39 · The pty epoch specifically. `carrier_epoch` still has to match, which
#      is why this probe and 39 are separate: today the two move together, so
#      a single probe could not tell "the pty epoch is checked" from "the
#      carrier epoch happens to have caught it".
probe "a terminal address that ignores the pty epoch is noticed" \
  "another terminal's pty epoch is refused" \
  host/src/carrier.rs \
  's|        if want != have {|        if false {|'

# 40 · A second attachment on one terminal. **This slice DOES answer a
#      cardinality question** — a Carrier has 0..1 live physical attachment —
#      and the earlier wording here said it "declines to answer", which was
#      wrong while the host actively refuses. It is a mechanism constraint of
#      this slice, not a claim that a terminal can never have several
#      observers: fan-out above one physical attachment stays available.
probe "a terminal that can be attached twice is noticed" \
  "cannot be attached twice" \
  host/src/carrier.rs \
  's|            if a.live() {|            if false {|'

# 41 · The attach op hands over the MASTER instead of the private stream
#      endpoint. Bytes still flow in both directions and every functional
#      check stays green — the holder now has terminal control, a route to
#      TIOCSWINSZ and TIOCSTI, and the ability to hang up the Carrier. Only
#      the question "what kind of thing is this" can see it.
probe "an attachment that hands over the terminal master is noticed" \
  "received is a socket endpoint" \
  host/src/carrier.rs \
  's|        let (a, far) = crate::attach::Attachment::open(p)?;|        let (a, far) = crate::attach::Attachment::open(p)?; let far = p.master();|'

echo '  --- D.1.3c·2a·1 · attachment incarnation and the orphaned endpoint ---'

# 42 · Detach addresses the TERMINAL rather than the attachment. Every one of
#      the three physical identities is current in a request minted against a
#      replaced attachment — same Carrier, same incarnation, same terminal —
#      so a stale detach tears down whatever attachment happens to occupy the
#      slot now. This is the hole `attachment_epoch` exists to close, and
#      nothing but the fourth identity can see it.
probe "a detach that addresses the terminal instead of the attachment is noticed" \
  "detach replayed from a REPLACED attachment is refused" \
  host/src/lib.rs \
  '/Some("pty-detach")/,/Some("pty-resize")/ s|c.attachment_address(\&req)|c.terminal_address(\&req)|'

# 43 · The same for resize, separately, because they are two ops and a probe
#      that reddened both would not show which one is wired.
probe "a resize that addresses the terminal instead of the attachment is noticed" \
  "resize replayed from a REPLACED attachment is refused" \
  host/src/lib.rs \
  '/Some("pty-resize")/,$ s|c.attachment_address(\&req)|c.terminal_address(\&req)|'

# 44 · The attach guard refuses on the FIELD being present rather than on the
#      attachment being live. A holder that vanished without detaching then
#      occupies the slot forever: the pump is gone, the stream is gone, and
#      the Carrier is permanently unattachable while otherwise perfectly
#      alive. Physical fact changed, registry fact did not.
#
#      Aimed at `Carrier::attach` and not at the op. Probe 40 was aimed at an
#      op-level guard and scored NOT A FALSIFIER, because the same rule was
#      also enforced one layer down; the duplicate guard is gone and both
#      probes now patch the one place that knows the rule.
probe "an attachment slot that cannot be reclaimed after its holder vanishes is noticed" \
  "leaves a RECLAIMABLE slot" \
  host/src/carrier.rs \
  's|            if a.live() {|            if true {|'

# 45 · The attachment ref is minted narrow again — a 12-hex slice of the
#      128-bit source, which is what it was until c·2a·2 and what a future
#      "shorten it for the cockpit" would reach for. 48 bits was harmless
#      while no host operation read the ref and the runtime had no name for
#      an attachment; c·2b indexes `terminal-attachment@1` by it. This is
#      the deterministic gate against re-truncation: the width is measured
#      on the minted value, so narrowing it anywhere between the CSPRNG and
#      the wire turns the check red rather than passing a source grep.
probe "an attachment ref minted narrower than its source is noticed" \
  "the attachment ref is a FULL 128-bit mint" \
  host/src/attach.rs \
  's|format!("ta_{}", crate::new_epoch())|format!("ta_{}", \&crate::new_epoch()[..12])|'

# NOT probed, and not counted — recorded rather than left as a silence.
#
#   `Carrier::terminate`'s call to `Attachment::settle`. **This probe was
#   written, run, and scored NOT A FALSIFIER**, so it is recorded here rather
#   than kept as a green line that proves nothing. Removing the settle leaves
#   "the pump ends because the TERMINAL hung up" passing, because `terminate`
#   polls `try_wait` on a 20 ms tick and the pump wakes on `POLLHUP`
#   immediately — the pump has always concluded before `terminate` returns.
#   The settle is therefore insurance against a timing coincidence rather
#   than a mechanism with an observable consequence, and saying so is the
#   honest version of a battery that would otherwise imply it was tested.
#
#   Chasing that NOT A FALSIFIER is what found the busy-spin: a hangup seen
#   while the outbound buffer was full was re-reported by every `poll` and
#   never concluded, so a pump whose consumer had stopped would hold a core
#   until it started again. That defect is fixed (`master_hup`), and it too
#   has no probe — a spinning thread makes no check red. It is measured only
#   in the sense that the fix is what let this note be written.
#
#   The field ORDER in `Carrier` (`attachment` before `pty`). Swapping them
#   closes the host's master before the pump is joined, which is a real
#   defect — but `drop(c)` runs both disposals before any check can look, so
#   the difference is transient and no census can see it. It is a comment on
#   the struct and a probe that would report NOT A FALSIFIER, which is worse
#   than an honest gap.
#
#   The 64 KiB buffer constant. Every value that is not zero produces the
#   same green battery; the number is a resource decision, not a property.
#
#   The explicit reclaim in `Carrier::attach` — taking and closing a finished
#   attachment BEFORE opening the new one. Removing it is not observable:
#   `self.attachment = Some(a)` drops the old value, and `Attachment::drop`
#   joins the pump and closes the descriptor just as surely. The explicit form
#   bounds PEAK descriptor use — one duplicate returned before the next is
#   allocated, rather than two live at once — and no census in this battery
#   samples during that window. Kept for the bound, recorded as unprobed.

echo
# Prefixed at W.1.4.2 — see the matching note in `ampd/tools/sabotage.sh`.
# These two lines were byte-identical, and the log is parsed by regex.
echo "host sabotage: $pass falsified · $fail did not"
[ "$fail" -eq 0 ]
