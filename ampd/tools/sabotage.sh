#!/usr/bin/env bash
# Prove each C1.1.1 falsifier by sabotage: stub the fix out, confirm the
# test goes RED, restore. A test that passes with the fix disabled is an
# invariant check, not a falsifier, and saying so is the difference
# between evidence and decoration.
#
# Run from ampd/:  bash tools/sabotage.sh
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0

# **Restore the tree on any exit, not just the happy one.**
#
# Every probe mutates the working tree in place and puts it back
# afterwards. `Ctrl-C` in the middle of one, a killed runner, or a machine
# that goes away leaves a sabotaged source file behind — and the next thing
# to read that tree has no way to know. The harness already wrote one
# sabotage permanently into `Ampd.Bridge` through a different bug; that one
# was caught by a loud `mv`, and this one would not be.
restore_all () {
  for f in lib/ampd/*.ex.orig lib/*.ex.orig; do
    [ -e "$f" ] || continue
    mv -- "$f" "${f%.orig}"
    touch -- "${f%.orig}"
    echo "  restored ${f%.orig}" >&2
  done
  rm -rf /tmp/ampd-pair-* 2>/dev/null
}
# **A signal trap that only restores does not stop the script.**
#
# `trap restore_all EXIT INT TERM` was directionally right and did not
# finish the job: on `INT` the handler runs, returns, and — with no
# `set -e` — execution continues from wherever it was, with every `.orig`
# just restored out from under the probe that is still running. The next
# `mv "$f.orig" "$f"` then fails against a file that is no longer there.
#
# So the signals *exit*, and the single `EXIT` trap owns restoration. 130
# and 143 are the conventional 128+SIGINT and 128+SIGTERM, so a caller can
# still tell which one arrived.
trap restore_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# probe <name> <test-file> <sed-expr> <file> [<sed-expr> <file> ...]
#
# **More than one pair, because a property can have more than one
# implementation.** F.8.2.2 gave `Ampd.Bridge` a `DOWN` backstop that frees
# the human-control claim when a connection dies — which meant the probe
# for "a closed socket frees the claim everywhere" stopped falsifying: it
# disabled `channel_closed/1` and the backstop covered for it. The property
# still held; the probe had quietly become a test of one redundant route.
# Disabling every route is what proves the law.
probe () {
  local name="$1" tf="$2"; shift 2
  local -a files=()

  # **Back a file up once, however many expressions target it.** Copying
  # again on the second pair would capture the file as the first sabotage
  # left it, and the restore would then write that sabotage back into the
  # tree permanently. It did exactly that once, to `Ampd.Bridge`, and the
  # only reason it was caught is that the duplicate `mv` failed loudly
  # afterwards. A harness that can corrupt the source it is testing is a
  # worse defect than anything it can find.
  while [ "$#" -ge 2 ]; do
    case " ${files[*]-} " in
      *" $2 "*) : ;;
      *) cp "$2" "$2.orig"; files+=("$2") ;;
    esac
    sed -i "$1" "$2"
    shift 2
  done

  local changed=0
  for f in "${files[@]}"; do cmp -s "$f" "$f.orig" || changed=1; done

  if [ "$changed" -eq 1 ]; then
    # A sabotage that does not COMPILE turns every test red, which this
    # harness would otherwise read as "falsified" — the strongest possible
    # result, awarded for breaking the build. That is not evidence about
    # the fix; it is evidence about the sed expression. Check separately.
    if ! mix compile >/dev/null 2>&1; then
      echo "  BROKE THE BUILD  $name — red because it did not compile, which proves nothing"
      fail=$((fail+1))
    elif mix test "$tf" >/dev/null 2>&1; then
      echo "  NOT A FALSIFIER  $name — passed with the fix disabled"
      fail=$((fail+1))
    else
      echo "  falsified        $name"
      pass=$((pass+1))
    fi
  else
    echo "  SABOTAGE MISSED  $name — the pattern did not match; the probe proved nothing"
    fail=$((fail+1))
  fi

  for f in "${files[@]}"; do mv "$f.orig" "$f"; touch "$f"; done

  # A probe runs the suite with a fix disabled, so it can leave behind
  # exactly what that fix prevents. The leak probe is the clear case: it
  # disables `socketpair/1`'s cleanup and then creates thirty of them.
  # Leaving those on disk makes the NEXT gate — the host battery's search
  # for a path into a channel — fail on this harness's litter rather than
  # on the runtime. Clean up after ourselves.
  rm -rf /tmp/ampd-pair-* 2>/dev/null
}

echo "sabotage battery — each line stubs one fix and expects RED"

probe "sealed journal must not crash the boot" test/bootstrap_test.exs \
  '/def handle_call(:recover, _f, %{sealed: reason} = st) when reason != nil/d' \
  lib/ampd/effects.ex

probe "seal_code matches by prefix, not substring" test/world_test.exs \
  's|String.starts_with?(reason, "WORLD-META-UNSUPPORTED") -> "world-meta-unsupported"|String.contains?(reason, "UNTRUSTED") -> "recovery-state-untrusted"|' \
  lib/ampd/refusal.ex

probe "version is read before shape" test/world_test.exs \
  's|m\["schema_version"\] > @schema_version -> :unsupported|not shape_ok?(m) -> :malformed|' \
  lib/ampd/world.ex

probe "consent binds to world lineage" test/lineage_test.exs \
  's|lin = Ampd.World.lineage() \|\| %{}|lin = %{}|' \
  lib/ampd/gateway.ex

# Targets the context builder by its function head. The previous form of
# this probe matched `"actor" => actor,` — which appears in `handle_call`
# for `:attach` as well, where `request` is not in scope, so it broke the
# build and was scored as the strongest possible result. It never proved
# anything about the fix.
probe "actor comes from the binding, not the payload" test/identity_test.exs \
  's|def authoritative_context(%{"actor" => actor}, request) do|def authoritative_context(%{"actor" => actor}, request) do\n    actor = (request \|\| %{})["actor"] \|\| actor|' \
  lib/ampd/peer.ex

probe "the free-text reason is replaced, not trimmed" test/identity_test.exs \
  's|else: Map.put(res, "reason", r\["public_message"\])|else: res|' \
  lib/ampd/refusal.ex

probe "an agent projection filters by actor" test/identity_test.exs \
  's|&(&1\["status"\] == "active" and &1\["actor"\] == actor)|\&(\&1["status"] == "active")|' \
  lib/ampd/projection.ex

probe "a grant request is not a grant draft" test/identity_test.exs \
  's|"reason" => opts\["reason"\]$|"reason" => opts["reason"], "status" => "granted"|' \
  lib/ampd/control.ex

# --- C1.1.2: the transport acceptance battery -----------------------

probe "revoke names one grant, not a capability" test/boundary_test.exs \
  's|Authority.revoke_one(grant_id)|Authority.revoke_matching(%{"capability" => "github.repo.read"}, Ampd.GrantRegistry.matching(%{"capability" => "github.repo.read"}) \|> Enum.map(\& \&1["id"]))|' \
  lib/ampd/control.ex

probe "an unenforceable duration is inert" test/boundary_test.exs \
  's|      _ -> false$|      _ -> true|' \
  lib/ampd/core.ex

probe "an unenforceable duration is never minted" test/boundary_test.exs \
  's|not Ampd.Core.duration?(dur) ->|false ->|' \
  lib/ampd/grant_registry.ex

probe "approval may not widen a request" test/boundary_test.exs \
  's|Core.duration_rank(dur) > Core.duration_rank(q\["requested_duration"\] \|\| "workspace") ->|false ->|' \
  lib/ampd/authority.ex

probe "a discovered pack confers nothing (gateway)" test/boundary_test.exs \
  's|pk\["installation"\] not in \["installed", "builtin"\] ->|false ->|' \
  lib/ampd/gateway.ex

probe "a discovered pack confers nothing (mint)" test/boundary_test.exs \
  's|cap != nil and not installed_surface?(cap) ->|false ->|' \
  lib/ampd/grant_registry.ex

probe "commands report the transition, not the command" test/boundary_test.exs \
  's|def settled({:refused, r}, _on_ok), do: %{"allow" => false, "reason" => r\["public_message"\], "refusal" => r}|def settled({:refused, _r}, on_ok), do: on_ok.(nil)|' \
  lib/ampd/control.ex

probe "redaction is centralized and exhaustive" test/boundary_test.exs \
  's|def agent_code("actor-mismatch"), do: "authority-missing"||' \
  lib/ampd/refusal.ex

# NOT probed, on purpose: "a stale peer handle cannot resolve".
#
# Stubbing the epoch check out leaves the test GREEN, because a crashed
# `Peer` comes back with an empty `peers` map and `Map.get/2` returns nil
# whatever the handle says. The epoch is redundant *today* — it is there so
# fail-closed stays true if the table ever gains a handoff or persistence
# path, which is precisely the kind of insurance that cannot be falsified
# until the thing it insures against exists.
#
# It stays in the code and out of this battery. Counting it here would be
# claiming evidence this round does not have.

# The old form replaced `try do` with `if true do`, which is a syntax
# error — red for the wrong reason, and scored as falsified for two
# rounds. Totality now lives in `Ampd.CommandSpec.bind/2`, whose catch-all
# clause is what makes an argument of *any* shape an error rather than a
# FunctionClauseError, so that is what this stubs.
#
# NOT probed, and not counted: the `rescue` in `Ampd.Wire.command/3`.
# `bind/2` fills every declared field, so a decoded command always reaches
# `Ampd.Control` at exactly the declared arity and the rescue is no longer
# reachable through this path. It stays as a guard against a future
# `Ampd.Control` clause the spec does not know about — insurance against a
# thing that does not exist yet, which is precisely what cannot be
# falsified by a test.
probe "the decoder is total over any argument shape" test/boundary_test.exs \
  's|  defp bind_spec(_spec, args),|  defp bind_spec_unreachable(_spec, args),|' \
  lib/ampd/command_spec.ex

probe "the wire never interns an atom" test/boundary_test.exs \
  's|nil -> {:error, "unknown-command", %{"command" => word}}|nil -> {:ok, String.to_atom(word), []}|' \
  lib/ampd/command_spec.ex

# --- C1.1: the transport, and the three corrections folded into it ---

probe "a bulk revocation names the exact set, not a count" test/boundary_test.exs \
  's|if current != expected do|if length(current) != length(expected) do|' \
  lib/ampd/grant_registry.ex

# **The linearization probe.** This does not disable the comparison — it
# moves it, by re-deriving the confirmed set in `Ampd.Control` from a fresh
# read and passing *that* down. The check still runs, still inside the
# coordinator, and still compares two identical lists. What is lost is the
# only thing that mattered: the set being compared is no longer the set the
# operator confirmed. If the test stays green under this, the exact-set
# check is decoration over a re-evaluated query.
probe "the confirmed set is the operator's, not a fresh query" test/boundary_test.exs \
  's|Authority.revoke_matching(scope, expected_ids)|Authority.revoke_matching(scope, Ampd.GrantRegistry.matching(scope) \|> Enum.map(\& \&1["id"]))|' \
  lib/ampd/control.ex

probe "a field limit means the field, not its first level" test/command_spec_test.exs \
  's|case Ampd.Frame.logical_size(v, max) do|case {:ok, 0} do|' \
  lib/ampd/command_spec.ex

probe "the requested duration is the one that is checked" test/boundary_test.exs \
  's|dur = Map.get(f, "requested_duration") \|\| "workspace"|dur = "workspace"|' \
  lib/ampd/grant_registry.ex

probe "a malformed request cannot be ranked" test/boundary_test.exs \
  's|not Core.duration?(q\["requested_duration"\] \|\| "workspace") ->|false ->|' \
  lib/ampd/authority.ex

probe "consent binds to the pack contract it was asked under" test/boundary_test.exs \
  's|stale_pack(q) != nil ->|false ->|' \
  lib/ampd/authority.ex

probe "identity cannot be claimed in a frame" test/transport_test.exs \
  's|Enum.any?(~w(peer_id actor channel), &Map.has_key?(f, &1)) ->|false ->|' \
  lib/ampd/frame.ex

# The single-use listener is gone: there is no socket file to retire,
# because there is no socket file. What is falsifiable is that the test
# which SEARCHES for one actually finds it — so this leaks the transient
# path `socketpair/1` unlinks, and requires the scan to go red.
probe "a leaked socket path is detected by the search that looks for one" test/transport_test.exs \
  's|^    File.rm(path)$|    _leaked = path|; s|^    File.rm_rf(dir)$|    _leaked2 = dir|' \
  lib/ampd/transport.ex

probe "the runtime pushes; the UI does not poll" test/transport_test.exs \
  's|if Process.whereis(Ampd.Subscriptions), do: Ampd.Subscriptions.changed()|:ok|' \
  lib/ampd/authority_coordinator.ex

probe "the channel partition is the spec's, not a second list" test/transport_test.exs \
  's|@human Ampd.CommandSpec.exclusive_to(:human_control)|@human []|' \
  lib/ampd/control.ex

probe "a pushed projection is the channel's own" test/transport_test.exs \
  's|defp project_for(%{"channel" => :agent, "actor" => a}) when is_binary(a), do: Ampd.Projection.agent(a)|defp project_for(%{"channel" => :agent, "actor" => a}) when is_binary(a), do: Ampd.Projection.operator()|' \
  lib/ampd/subscriptions.ex

# **Both routes, since F.8.2.2.** The graceful one — the connection telling
# the bridge it is going — and the backstop the bridge now has for a
# connection that never got to say so. With only the first disabled this
# passed, because the second covered it, and a probe that a redundant
# mechanism rescues proves nothing about the property.
probe "a closed socket frees the claim everywhere" test/transport_test.exs \
  's|if Process.whereis(Ampd.Bridge), do: Ampd.Bridge.channel_closed(self())|:ok|' \
  lib/ampd/transport.ex \
  's@control_open: st.control_open and ch.kind != :human_control@control_open: st.control_open@' \
  lib/ampd/bridge.ex

probe "the world manifest and the stores share one directory" test/world_test.exs \
  's|  defp dir, do: Ampd.Store.data_dir()|  defp dir, do: "priv/data-elsewhere"|' \
  lib/ampd/world.ex

# --- C1.1 corrections: identity lifetime, continuity, bounded projection ---

# Restores the defect exactly: a binding that no longer resolves produces
# a fabricated one, which is what caching the peer record amounted to.
probe "a subscription re-resolves its binding, never caches it" test/transport_test.exs \
  's|    case Ampd.Peer.resolve(peer_id) do|    case Ampd.Peer.resolve(peer_id) \|\| %{"id" => peer_id, "channel" => :agent, "actor" => "kestrel"} do|' \
  lib/ampd/subscriptions.ex

probe "a dead Peer closes the channels it named" test/transport_test.exs \
  's|          ref = Process.monitor(Ampd.Peer)|          ref = make_ref()|' \
  lib/ampd/transport.ex

probe "a coordinator restart changes the epoch" test/transport_test.exs \
  's|    {:ok, %{seq: 0, epoch: :crypto.strong_rand_bytes(4) \|> Base.encode16(case: :lower)},|    {:ok, %{seq: 0, epoch: "fixed"},|' \
  lib/ampd/authority_coordinator.ex

probe "the live projection is bounded" test/transport_test.exs \
  's|    recent = Enum.take(sorted, @history_window)|    recent = sorted|' \
  lib/ampd/projection.ex

probe "a history page does not repeat what it already returned" test/transport_test.exs \
  's|        c -> Enum.drop_while(sorted, \&(\&1\["id"\] >= c))|        _c -> sorted|' \
  lib/ampd/projection.ex

# --- F.8: evidence losslessness and the projection an agent can grow ---

# Restores the off-by-one exactly: `next_cursor` names the first OMITTED
# item while the fetch drops everything `>= cursor`, so that item is
# skipped. It passed the old test, which asserted pages did not overlap
# and did not repeat — never that they had no hole.
probe "paging loses no record at a page boundary" test/transport_test.exs \
  's|      "next_cursor" => if(more?, do: List.last(items)\["id"\], else: nil)|      "next_cursor" => from \|> Enum.drop(limit) \|> List.first() \|> then(\&(\&1 \&\& \&1["id"]))|' \
  lib/ampd/projection.ex

probe "a projection window's cursor means the same as a page's" test/transport_test.exs \
  's|      "next_cursor" => if(more?, do: List.last(recent)\["id"\], else: nil),|      "next_cursor" => sorted \|> Enum.drop(@history_window) \|> List.first() \|> then(\&(\&1 \&\& \&1["id"])),|' \
  lib/ampd/projection.ex

probe "an agent cannot grow its own projection without bound" test/transport_test.exs \
  's|        GrantRegistry.requests() \|> mine.() \|> Enum.filter(\&(\&1\["status"\] == "pending")),|        GrantRegistry.requests() \|> mine.(),|' \
  lib/ampd/projection.ex

# --- F.8.2: the receiver owns what it receives ---

probe "a bridge with no descriptor sink is refused, not opened" test/native_fd_test.exs \
  's|  def admissible?(fd, sink_available?), do: is_integer(fd) and fd >= 0 and sink_available?|  def admissible?(fd, _sink_available?), do: is_integer(fd) and fd >= 0|' \
  lib/ampd/bridge.ex

# --- F.8.2.2: a channel handoff is a transaction ---
#
# These ARE reachable from inside the BEAM, unlike the descriptor rounds:
# the defect is above raw-descriptor adoption, so a socket-handle channel
# runs exactly the same code an SCM_RIGHTS one does.

probe "Ampd.Bridge closes the socket of a connection that died" test/lifecycle_test.exs \
  's|        if how == :died, do: Ampd.Transport.Connection.rollback(ch.sock, ch.peer)|        _ = how|' \
  lib/ampd/bridge.ex

# `@` as the delimiter, not `|`: the line being replaced is an Elixir
# map-update, so `%{st | ...}` closes an `s|…|…|` expression halfway
# through and `sed` rejects it. Reported SABOTAGE MISSED, which was true.
probe "a crashed control channel releases the human's claim" test/lifecycle_test.exs \
  's@control_open: st.control_open and ch.kind != :human_control@control_open: st.control_open@' \
  lib/ampd/bridge.ex

# Both `rollback` calls in `await/5`, because they are the same law at two
# exits — the child died, or the child never finished. The first form of
# this probe tried to disable only the timeout one with a two-line `sed`
# pattern, which cannot match: `sed` works a line at a time, and the probe
# reported SABOTAGE MISSED rather than proving anything.
probe "a failed startup is rolled back, not merely refused" test/lifecycle_test.exs \
  's|^          rollback(sock, peer_id)$|          :ok|' \
  lib/ampd/transport.ex

# F.8.2.2's refusal branch waited a flat second for `DOWN` and then
# returned WITHOUT rolling back. This restores the escape by disabling the
# rollback `settle/5` performs — the `DOWN` branch keeps its own, so the
# suspended-`Peer` probe above still measures what it measures.
probe "a refusal is not observable until the channel it refused is gone" test/lifecycle_test.exs \
  's|^      rollback(sock, peer_id)$|      :ok|' \
  lib/ampd/transport.ex

# Restores the wire refusal frame. It does not leak — `settle/5` still
# disposes — it *stalls*: `socket:send/2` waits forever on a peer that is
# not reading, so the refusal takes the full startup deadline to arrive.
# A channel that never committed has no reader by construction.
probe "a refused channel is never written to" test/lifecycle_test.exs \
  's|^          send(parent, {:bound, self(), {:refused, r}})$|          send(parent, {:bound, self(), {:refused, r}}); Wire.send_frame(sock, %{"schema" => "reply@1", "client_request_id" => nil, "result" => %{"allow" => false}})|' \
  lib/ampd/transport.ex

probe "a world reset invalidates the channels bound to the old world" test/lifecycle_test.exs \
  's|    if Process.whereis(Ampd.Bridge), do: Ampd.Bridge.reset()|    _ = :no_bridge_reset|' \
  lib/ampd/bootstrap.ex

# Fire-and-forget, exactly as it was: tell each connection to stop and
# return without proving any of them did.
probe "a world reset does not complete until its channels are gone" test/lifecycle_test.exs \
  '/def handle_call(:reset, _f, st) do/,/^  end/{s@        Process.exit(pid, :kill)@        send(pid, :stop)@}' \
  lib/ampd/bridge.ex \
  's@      Ampd.Transport.Connection.rollback(ch.sock, ch.peer)@      _ = ch@' \
  lib/ampd/bridge.ex

# **The fence, at the linearization point.** GPT's requested sabotage:
# remove `expected == current` and require the old kestrel request to
# appear in the world that replaced its own.
probe "an authority operation executes only in the world its channel was bound to" test/lifecycle_test.exs \
  's|    if stale_incarnation?(expected, current) do|    if false and stale_incarnation?(expected, current) do|' \
  lib/ampd/authority_coordinator.ex

# **The generation half of the fence — F.8.2.5's whole subject.**
#
# F.8.2.4 fenced on `installation_id` alone, so a restore (same
# installation, next generation) let a command formed in the ending
# incarnation linearize into the one that replaced it. This restores that
# narrowing exactly and requires all three queued-work witnesses to go red.
probe "a generation advance ends the incarnation, it does not merely stale a cache" test/incarnation_test.exs \
  's|    expected\["installation_id"\] != current\["installation_id"\] or|    expected["installation_id"] != current["installation_id"] or false and|' \
  lib/ampd/authority_coordinator.ex

# The other half, and the reason the fence above is safe to tighten:
# without the barrier, fencing on generation would leave every live channel
# permanently unable to act with nothing torn down and nothing told.
probe "a lineage advance closes every channel bound to the incarnation that ended" test/incarnation_test.exs \
  's|      close_channels!()|      _ = :no_barrier|' \
  lib/ampd/authority.ex

# The expectation has to be captured when the CHANNEL is bound. This probe
# proves it must **exist** — with `nil` the fence is skipped entirely.
probe "a channel carries the incarnation it was bound to" test/lifecycle_test.exs \
  's|        "world_lineage" => Ampd.World.lineage()|        "world_lineage" => nil|' \
  lib/ampd/peer.ex

# **And this one proves it is sampled at BIND time rather than submission,
# which is a different claim and F.8.2.4 did not have a probe for it.**
#
# The probe above only removes the expectation. The one that would show the
# sample *point* has to run against a witness where the two differ, and the
# queued-behind-a-restore witnesses are not it: the coordinator is
# suspended there, so the restore has not executed when the command is
# submitted and both samples read the same world. Measured — this sabotage
# leaves all three of them green, and only the bridge-interposition witness
# (`test/incarnation_test.exs:345`, where the manifest is already at
# generation 2 while the channel is still bound to 1) goes red.
# W.1 gave `Ampd.Control.served/3` one binding that both fences read, so
# this now sabotages the *source* of the expectation rather than one of its
# two uses — which is what the claim was always about.
probe "the expected incarnation is the channel's, not the one current at submission" test/incarnation_test.exs \
  's|    lineage = peer\["world_lineage"\]|    lineage = Ampd.World.lineage()|' \
  lib/ampd/control.ex

# One value pinned by one witness is indistinguishable from a hard-coded
# string, and the two branches carry different remediations: a generation
# advance is this world's next incarnation and the host reattaches to it; a
# new installation has nothing to reattach to.
probe "the refusal names which half of the incarnation moved" test/incarnation_test.exs \
  's|        "discontinuity" => if(installation_changed, do: "installation", else: "generation"),|        "discontinuity" => "generation",|' \
  lib/ampd/authority_coordinator.ex

# `Ampd.Gateway.perform/5` receives the coordinator's `refusal@1` through
# the same `{:refused, _}` tuple it uses for its own authorization
# verdicts, and `request_effect` is the one command that does not pass
# through `Ampd.Control.settled/2`. Without the schema clause the agent
# receives a bare `refusal@1` — no `allow` key, and `operator_detail`
# still attached, past the dual-disclosure boundary.
probe "a fenced effect request is normalized like every other refusal" test/incarnation_test.exs \
  's|      {:refused, %{"schema" => "refusal@1"} = r} ->|      {:refused, %{"schema" => "refusal@0"} = r} ->|' \
  lib/ampd/gateway.ex

# A new installation starts at generation 1 again and the coordinator
# survives the reset, so without the incarnation nothing in the frame
# distinguishes a factory reset from an ordinary advance.
# Both sites, because `framed/2` builds the world half twice: once on the
# optimistic path via `continuity/0` and once on the pessimistic one, where
# the cursor comes from inside the total order and the world half does not.
# Sabotaging one leaves the other answering correctly.
probe "a continuity frame names which world it is, not merely how far along" test/lifecycle_test.exs \
  's@        "world_incarnation" => Ampd.World.incarnation_of(lin),@        "world_incarnation" => "constant",@' \
  lib/ampd/projection.ex \
  's@                "world_incarnation" => Ampd.World.incarnation_of(lin),@                "world_incarnation" => "constant",@' \
  lib/ampd/projection.ex

# **RE-AIMED at D.1.3c·2b·1.** `own/3` now stores the owning pid alongside
# the id — `{id, pid}` — so the old anchor, which named the previous map
# shape byte for byte, matched nothing and the probe silently proved nothing
# for one whole battery run. Nothing gated it: `check-sabotage-anchors.sh`
# read `tools/sabotage-host.sh` and not this file. It reads both now.
probe "an identity does not outlive the process that asked for it" test/lifecycle_test.exs \
  's|  defp own(owners, pid, id), do: Map.put(owners, Process.monitor(pid), {id, pid})|  defp own(owners, _pid, _id), do: owners|' \
  lib/ampd/peer.ex

# --- W.1: the cockpit observes one world incarnation ------------------

# **Two pairs, because the read fence has two routes.** Disabling the one
# in `Ampd.Control.served/3` alone leaves every read still refused by the
# one inside `Ampd.Projection.framed/2` — measured, and it is exactly the
# redundancy trap this harness's `probe()` documents. Disabling every route
# is what proves the law.
probe "a read is fenced to the incarnation its channel was bound to" test/cockpit_test.exs \
  's|      nil -> in_lineage(peer, lineage, cmd, args)|      _any -> in_lineage(peer, lineage, cmd, args)|' \
  lib/ampd/control.ex \
  's|  def fence(expected) do|  def fence(_ignored) do\n    expected = nil|' \
  lib/ampd/projection.ex

# The cursor sampled before the build is a label, not a measurement.
probe "the cursor on a frame is compared after the build, not only before" test/cockpit_test.exs \
  's|        if now == before,|        if true or now == before,|' \
  lib/ampd/projection.ex

# The optimistic seqlock alone is defeated by a world that moves during
# every attempt — 40 of 40 reads failed to settle when this was measured.
# The fallback assembles the frame inside the total order; without it, a
# busy world is served frames whose grant list and authority digest were
# read at different revisions.
probe "a busy world is observed coherently, not merely observed" test/cockpit_test.exs \
  's|        {cursor, content} = ordered_observe(attempts, fun)|        {cursor, content} = {continuity(), fun.()}|' \
  lib/ampd/projection.ex

# **THE MULTIPLICITY CONSTRAINT, FALSIFIED.**
#
# `Ampd.CommandSpec` declares `retry: :once` for reads that write as they
# decide — `Ampd.Refusal.new/2` records into `Ampd.RefusalLog` as it
# constructs. `Ampd.Control` routes them to `framed_once/2`, which passes
# `attempts = 0`, which selects `observe_once/1`.
#
# Before W.1.4 that last hop did not exist: `framed_once` skipped the
# optimistic loop in `Projection` and then handed the function to
# `observe/1`, which speculated up to three more times. Measured with a
# function that ticks the clock itself: three executions, deterministically.
#
# Sending the once-clause back to `observe/1` restores exactly that, and
# `multiplicity_test.exs` must go RED for it.
probe "a read that may run once is speculated on anyway" test/multiplicity_test.exs \
  's|  defp ordered_observe(0, fun), do: Ampd.AuthorityCoordinator.observe_once(fun)|  defp ordered_observe(0, fun), do: Ampd.AuthorityCoordinator.observe(fun)|' \
  lib/ampd/projection.ex

# And the layer below it: `observe_once/1` must not acquire a loop. Giving
# it `coherent/3`'s bounded rebuild is the change someone makes while
# "unifying" the two, and it silently reinstates the defect.
probe "the exactly-once observation rebuilds like the retry-safe one" test/multiplicity_test.exs \
  's|    do: {:reply, survivable(fn -> once(fun, st) end), st}|    do: {:reply, survivable(fn -> coherent(fun, st, 3) end), st}|' \
  lib/ampd/authority_coordinator.ex

# A read that counted as an ordered operation would advance the revision it
# is reporting — a cursor that changes because it was looked at, and a push
# that is its own reason for another push.
probe "an observation is ordered but is not an operation" test/cockpit_test.exs \
  '/def handle_call({:observe, fun}, _from, st),/,+1{s|    do: {:reply, survivable(fn -> coherent(fun, st, 3) end), st}|    do: run(fn -> coherent(fun, st, 3) end, st)|}' \
  lib/ampd/authority_coordinator.ex

probe "the world incarnation is 128 bits" test/cockpit_test.exs \
  's|    \|> binary_part(0, 16)|    \|> binary_part(0, 8)|' \
  lib/ampd/world.ex

# `Ampd.CommandSpec` is the single declaration of which commands read. A
# read misdeclared as a mutation is never framed, so its reply carries no
# cursor at all — and a client cannot tell a missing cursor from an
# unchanged one.
probe "every read is declared a read in command-spec@1" test/cockpit_test.exs \
  's|"agent_projection" => %{cmd: :agent_projection, channel: :agent, kind: :read,|"agent_projection" => %{cmd: :agent_projection, channel: :agent, kind: :mutation,|' \
  lib/ampd/command_spec.ex

# --- W.1.1: the cockpit holds a live renderable view ------------------

# **Three routes, because three modules can change what a projection
# shows without moving any authority.** `peers`, `channels` and
# `recent_refusals` are all in `operator-projection@2`, and none of them
# is under the coordinator. Disabling one leaves the others announcing.
probe "runtime topology reaches the cockpit without an authority mutation" test/cockpit_test.exs \
  's|  defp touched, do: Ampd.AuthorityCoordinator.touched()|  defp touched, do: :ok|' \
  lib/ampd/peer.ex \
  's|              Ampd.AuthorityCoordinator.touched()|              _ = :no_touch|' \
  lib/ampd/bridge.ex \
  's|        Ampd.AuthorityCoordinator.touched()|        _ = :no_touch|' \
  lib/ampd/bridge.ex

# The second clock itself. Without it, a topology change announces to
# subscribers and every field a client can compare is unchanged — so the
# frame is classified as already seen and the change is invisible anyway.
# W.1.2 moved the clock out of this process entirely, so the old target —
# a `handle_cast(:touched)` clause that incremented a field — no longer
# exists. The separation now lives in `cursor_of/1` reading the live clock
# rather than a number the coordinator keeps for itself; collapsing the two
# is what makes a topology change indistinguishable from nothing happening.
probe "the view clock is not the authority clock" test/cockpit_test.exs \
  's|          "view_revision" => Ampd.ViewClock.read()}|          "view_revision" => st.seq}|' \
  lib/ampd/authority_coordinator.ex

probe "a refusal reaches the operator's diagnostic view" test/cockpit_test.exs \
  's|^    Ampd.AuthorityCoordinator.touched()$|    _ = :no_touch|' \
  lib/ampd/refusal_log.ex

# A subscription is a lease. `:one_for_one` means `Ampd.Subscriptions` can
# restart while every socket stays up and every `subs` entry is gone — no
# EOF, no frame, no error, and a host that holds LIVE LOCAL forever.
probe "a subscribed channel does not outlive its subscription" test/cockpit_test.exs \
  's|        {:DOWN, _other, :process, _pid, _reason} ->|        {:DOWN, _other, :process, _pid, _reason} when false ->|' \
  lib/ampd/transport.ex

# `kind: :read` was taken to mean safe-to-retry. `Ampd.Refusal.new/2`
# records as it constructs, so a read that can refuse writes as it decides
# — four recorded refusals for one client command, measured.
probe "a read that constructs a refusal is executed exactly once" test/cockpit_test.exs \
  's|        cmd in @retry_once -> Projection.framed_once(lineage, run)|        cmd in [] -> Projection.framed_once(lineage, run)|' \
  lib/ampd/control.ex

# --- W.1.2: the runtime announces its epoch, the clock names the view ---

# **Line-anchored, because the same line appears three times.** Announcing
# a change is what `run/2` and `touched/0` also do; only the one in
# `handle_continue(:announce, …)` is the restart announcement, and
# sabotaging all three would prove something much broader than the claim.
#
# Without it, `Continuity::NewRuntime` is classifiable and never
# observable: `:one_for_one` replaces the coordinator with a new epoch
# while every channel and every subscription survives, and nothing says so.
probe "a new runtime incarnation announces its epoch" test/cockpit_test.exs \
  '115 s|^    if Process.whereis(Ampd.Subscriptions), do: Ampd.Subscriptions.changed()$|    _ = :silent_restart|' \
  lib/ampd/authority_coordinator.ex

# The clock must be advanced by the mutator, synchronously, rather than
# announced to a process that may be busy — it was a cast to the
# coordinator, which could not process it while assembling the very frame
# the number was supposed to describe.
probe "the view clock ticks at the source, synchronously" test/cockpit_test.exs \
  '137 s|^    Ampd.ViewClock.tick()$|    _ = :no_tick|' \
  lib/ampd/authority_coordinator.ex

# And it is sampled AFTER the content, so the label is a bound on what is
# in the frame rather than a guess about it. Measured before: cursor
# `view_revision 2` beside content containing a refusal that belonged to
# view 3.
probe "the ordered cursor is sampled after the content, never before" test/cockpit_test.exs \
  's|  defp sample_after(st, _before), do: cursor_of(st)|  defp sample_after(st, before), do: Map.put(cursor_of(st), "view_revision", before)|' \
  lib/ampd/authority_coordinator.ex

# --- D.1.3b·2c ------------------------------------------------------------
#
# The execution basis, unbound at admission. The ticket goes back to carrying
# `profile_basis` and `floor_basis` only, and a payload that changed between
# admission and commit becomes indistinguishable from the one that was agreed
# to — which is the state review found the source in.
probe "the carrier execution basis is bound at admission" test/carrier_test.exs \
  's|        "carrier_basis" => basis,|        "carrier_basis_unbound" => basis,|' \
  lib/ampd/carrier.ex

# Absent reading as agreement. `basis_moved/2` returns `nil` for "they agree",
# so a comparison that skipped when either side was missing would let a host
# opt out of the whole check by omitting a field — the direction that fails
# open, which is the only direction that is a lie about an identity claim.
probe "an absent execution basis is a mismatch, never a skip" test/carrier_test.exs \
  's|      not is_map(actual) -> \["actual-basis-absent"\]|      not is_map(actual) -> []|' \
  lib/ampd/carrier.ex

# The reap debt, not recorded before the announcement. This is the TCB race:
# `Ampd.Peer` still ends membership, the announcement is still dropped when
# the reaper is down, and nothing survives the gap for a restarted one to
# find. Every record-shaped assertion still passes.
probe "a reap debt outlives the announcement that was lost" test/carrier_test.exs \
  's|    st = pend(st, inc)|    st = st|' \
  lib/ampd/peer.ex

# And the sweep that reads it. With `handle_continue` gone the debt is
# recorded and never acted on, which is a durable leak rather than a race —
# strictly worse than the bug it replaced, and the reason the probe is here.
probe "a restarted reaper converges what it did not hear" test/carrier_test.exs \
  's|    {:ok, %{unconfirmed: \[\]}, {:continue, :converge}}|    {:ok, %{unconfirmed: []}}|' \
  lib/ampd/carrier/reaper.ex

# The floor row that replaced the one which claimed to bind the payload and
# did not. Reverted to the old predicate, a placeholder digest passes.
probe "the confinement floor requires a well-formed execution basis" test/carrier_test.exs \
  's|      {:attested, "execution_basis_is_well_formed", &execution_basis_ok?(&1\["execution_basis"\])}|      {:attested, "execution_basis_is_well_formed", \&is_map(\&1["execution_basis"])}|' \
  lib/ampd/carrier/floor.ex

# --- D.1.3b·2d · the runtime incarnation fence ----------------------------
#
# J1 and its neighbours. The BEAM half of the fence — the part that notices
# the incarnation changed and refuses to start anything until the physical
# set has been established empty.

# J1 · The Gate ignores the death of the registry it is bound to. Every
#      other mechanism still works: membership still ends, the Reaper still
#      runs, the supervisor still restarts Ampd.Peer. Only the physical set
#      of the dead incarnation is left standing — which is E29 exactly.
#      NOTE: `@` delimiter, not `|`. Both of these expressions carry an
#      Elixir map-update `%{st | ...}`, and with `s|…|…|` sed reads that pipe
#      as the end of the pattern. Both reported SABOTAGE MISSED — which is the
#      harness refusing to score a probe whose sed matched nothing, exactly as
#      it should, rather than counting it as a pass.
probe "the gate notices the peer registry dying" test/carrier_test.exs \
  's@    {:noreply, converge(witness(%{st | peer_pid: nil}))}@    {:noreply, st}@' \
  lib/ampd/carrier/machine.ex

# The transition itself. Leaving the monitor in place but treating a NEW
# incarnation as already-synchronized is the subtler version of J1: the Gate
# reacts, and reacts by doing nothing.
probe "an incarnation transition drains before it unfences" test/carrier_test.exs \
  's@                drain_then_ready(st, pid, epoch)@                (publish(:ready, epoch); %{st | lifecycle: :ready, peer_pid: monitor(pid, st), peer_epoch: epoch})@' \
  lib/ampd/carrier/machine.ex

# The drain must actually be asked for. A fence that unfences on a reply it
# never requested is a fence in name only.
probe "the fence asks the machine to empty the physical set" test/carrier_test.exs \
  's|    case Ampd.Carrier.machine().drain(epoch) do|    case {:ok, %{"remaining" => 0}} do|' \
  lib/ampd/carrier/machine.ex

# H · admission refuses BEFORE persisting a ticket. Without this every
# innocent start during the restart window writes START_ADMITTED, meets a
# fenced Gate, and wedges its Worker on a reconciliation the runtime's own
# recovery manufactured.
probe "admission refuses while the machine is unsynchronized" test/carrier_test.exs \
  's|         :ok <- machine_synchronized(),|         :ok <- :ok,|' \
  lib/ampd/carrier.ex

# --- D.1.3c·1 · the possessed terminal, at the admission boundary ----------
#
# `super-host verify` proves the mechanism; `E31` proves the runtime refuses
# an embodiment whose terminal relationship does not hold. These attack the
# floor rows that do the refusing.
#
# **Every one WEAKENS a predicate rather than deleting a row**, and that is
# not tidiness. `E28` asserts the row count as an exact constant, so removing
# a row turns the file red through E28 and the probe would score `falsified`
# for a reason that has nothing to do with the row it names — the same defect
# as a sabotage that disables more than the fix it targets. Names unchanged
# means `digest/0` unchanged, so only the intended falsifier moves.

# L1 · The row that notices stdio is not a terminal at all. Weakened, a
#      Carrier built the pre-D.1.3c way — /dev/null and a log file — commits.
probe "stdio that is not a terminal is refused" test/carrier_test.exs \
  's@       &(String.starts_with?(get_in(&1, \["fds", "0"\]) || "", "/dev/pts/"))},@       \&(is_map(\&1) or String.starts_with?(get_in(\&1, ["fds", "0"]) || "", "/dev/pts/"))},@' \
  lib/ampd/carrier/floor.ex

# L2 · Three terminals on 0/1/2 instead of one. The descriptor set is still
#      exactly {0,1,2,3} and each entry is still a pts, so every other row
#      passes — this is the only one that can see it.
probe "three different terminals on 0, 1 and 2 are refused" test/carrier_test.exs \
  's@           \[t, t, t\] when is_binary(t) -> true@           [t, _u, _v] when is_binary(t) -> true@' \
  lib/ampd/carrier/floor.ex

# L3 · **The load-bearing one.** A Carrier that had got hold of somebody
#      else's terminal satisfies session_leader, controlling_terminal and
#      foreground — all three are readings of its own /proc. Only this row,
#      which is TIOCGSID asked of the descriptor the host holds, can refuse
#      it.
probe "a terminal that is not the host's master is refused" test/carrier_test.exs \
  's@       &(get_in(&1, \["terminal", "is_this_host_master"\]) == true)},@       \&(is_map(\&1) or get_in(\&1, ["terminal", "is_this_host_master"]) == true)},@' \
  lib/ampd/carrier/floor.ex

# L4 · Resize authority. A host that had started permitting TIOCSWINSZ to
#      payloads is offering a different bargain, and the basis is where the
#      runtime gets to notice rather than be told.
probe "a host claiming resize authority for the Carrier is refused" test/carrier_test.exs \
  's@       &(get_in(&1, \["terminal", "resize_authority"\]) == "super-host")},@       \&(is_map(\&1) or get_in(\&1, ["terminal", "resize_authority"]) == "super-host")},@' \
  lib/ampd/carrier/floor.ex

# L5 · **The join.** c·1a's row, and the one the other four cannot cover for:
#      weakened, a Carrier whose controlling terminal is the host's while its
#      0/1/2 are somebody else's commits. Every other row passes that state —
#      one pty on stdio, exact descriptor set, session leader, ctty present,
#      and the ctty really is the host's. Unix keeps "what I am using" and
#      "what is my controlling terminal" apart, so only this row joins them.
probe "stdio that is not the host's own slave is refused" test/carrier_test.exs \
  's@       &(get_in(&1, \["terminal", "stdio_is_this_host_slave"\]) == true)},@       \&(is_map(\&1) or get_in(\&1, ["terminal", "stdio_is_this_host_slave"]) == true)},@' \
  lib/ampd/carrier/floor.ex

# --- D.1.3b·2e · the token is not the transition ---------------------------
#
# Review's closing objection to 2d. The four probes above all falsify through
# a *different* epoch, which is the same weakness the E29 tests had: they
# establish that the fence works when the identifier happens to disagree.
# `Ampd.Peer.new_epoch/0` minted 32 bits, and `converge/1` decided drainage by
# comparing them, so a real discontinuity could be represented as equality.
#
# K1 · The whole repair, in one line. Without the publish, `converge/1` finds
#      the term it published before the death — `{:ready, X}` — compares it
#      against a replacement that also minted X, concludes "same incarnation",
#      and unfences over a physical set belonging to the dead one. Every
#      other probe in this block stays green while it does, because they all
#      arrange for the epochs to differ.
#      NOTE: a range address, because `publish(:fenced, nil)` appears in four
#      places and the other three are the boot-ordering retries. `s@…@@`
#      alone would stub all of them, and a probe that disables more than the
#      fix it names cannot say which one the red came from.
probe "a witnessed transition fences whatever the replacement minted" test/carrier_test.exs \
  '/defp witness(st) do/,/^  end/{s@    publish(:fenced, nil)@    :ok@}' \
  lib/ampd/carrier/machine.ex

# K2 · The same defect reached the other way. `Peer.reset/0` re-mints in
#      place, so no `:DOWN` fires and the cast is the *only* evidence that
#      exists; dropping it leaves the Gate with nothing but the comparison.
probe "an in-place incarnation change is not inferred from the token" test/carrier_test.exs \
  's@  def handle_cast(:peer_incarnation_changed, st), do: {:noreply, converge(witness(st))}@  def handle_cast(:peer_incarnation_changed, st), do: {:noreply, converge(st)}@' \
  lib/ampd/carrier/machine.ex

# K3 · The width, which is the second line rather than the first. It protects
#      the one residue the published term cannot: a Gate that died across the
#      transition, whose only evidence is the comparison. Narrowing the mint
#      back to four bytes is not observable from a test — a collision would
#      have to occur — so this is NOT probed here and NOT counted. It is
#      gated by `tools/check-epoch-mint.sh`, which reads the built BEAM, and
#      recorded here so the absence is a decision rather than an oversight.

# NOT probed, and not counted: `Ampd.Peer`'s `dead?/1` guard.
#
# Stubbing it leaves the suite GREEN, and the reason is worth writing down
# rather than hiding: the two halves of "an identity exists only while the
# process that asked for it does" are **redundant for every case this
# battery can construct**. With the guard disabled, a call from a dead
# caller still creates the binding — and `Process.monitor/1` on a dead pid
# delivers `DOWN` immediately, so the very next message drops it again.
#
# The guard is not therefore pointless: it stops the phantom binding from
# existing at all, where the monitor only removes it one message later, and
# `Ampd.Peer.list/0` is observable in between. But a window that narrow
# cannot be observed deterministically from outside the process, so there
# is no test here that can fail when it is gone. It stays in the code and
# out of this count, like the `Peer` epoch above it.

# NOT probed here: a startup is monitored rather than merely waited on.
#
# The obvious sabotage — `spawn_monitor` back to `spawn` — is not one:
# `spawn` followed by `Process.monitor` is equivalent, including for a
# process that has already exited. Written that way it passed with the fix
# disabled, which is the definition of not a falsifier. What the monitor is
# *for* is falsified by the rollback probe above.

# --- D.1.3c·2b·1 · semantic terminal possession ----------------------------
#
# Nine probes, and each names a distinct thing that would otherwise be a
# sentence. The rule this lane keeps re-learning: **a gate is not evidence
# unless we know what would make it fail.** Every one of these was written by
# asking what single line, removed, leaves the whole suite green.

# L1 · The identity the host establishes is BELIEVED, not assumed. Before this
#      slice `interpret/2` checked descriptor cardinality and nothing about
#      what the answer said, so `attached: true` with three nil identities and
#      one socket was a clean success.
probe "an attach answer with no physical identity is not a success" test/terminal_possession_test.exs \
  '/def malformed_identity(obs) do/,/^  end/{s@    |> Enum.reverse()@    |> Enum.reverse() |> Enum.drop(99)@}' \
  lib/ampd/carrier/terminal.ex

# L2 · A malformed field is not a default. The two-valued reading
#      `is_binary(r) and r != ""` makes every non-string `refused` silently
#      equal to absent, which is how `refused: 0` alongside `attached: true`
#      passed as a clean success.
probe "a malformed refusal field is malformed rather than absent" test/terminal_possession_test.exs \
  's@  defp shape(_, _), do: :malformed@  defp shape(_, _), do: :absent@' \
  lib/ampd/carrier/terminal.ex

# L3 · B2 re-derives, and it is not B1 doing it twice. Without this the world
#      may move between installing COMMITTING and finalising ACTIVE, and an
#      authorisation granted under one world state is laundered into another.
probe "the second ordered transaction re-derives the world again" test/terminal_possession_test.exs \
  's@  defp moved_again(ticket), do: moved(ticket)@  defp moved_again(_ticket), do: nil@' \
  lib/ampd/carrier/terminal.ex

# L4 · The lifetime witness is PROVED. A prepared attachment monitoring the
#      wrong process is indistinguishable from a correct one right up until
#      the process it should have been watching dies.
probe "an active attachment's lifetime witness must be the peer's own owner" test/terminal_possession_test.exs \
  's@        bound_owner != owner ->@        bound_owner == nil ->@' \
  lib/ampd/carrier/terminal.ex

# L5 · And the owner is the process that established the binding, never the
#      singleton registry. `Ampd.Peer` outlives every binding it holds, so an
#      attachment bound to it survives the death of the connection whose peer
#      it belongs to — a stream owned on behalf of a peer that is gone.
probe "the peer owner is the establishing process, not the registry" test/terminal_possession_test.exs \
  '/def handle_call({:owner_pid, peer_id}, _f, st) do/,/^  end/{s@    {:reply, pid, st}@    _ = pid; {:reply, Process.whereis(__MODULE__), st}@}' \
  lib/ampd/peer.ex

# L6 · The reverse direction of the terminal dependency, and it has to be a
#      monitor: `:kill` skips `terminate/2`, so a record that relied on the
#      dying process announcing itself would survive exactly the case it must
#      not.
probe "the semantic record does not outlive the process owning its stream" test/terminal_possession_test.exs \
  's@        ref = Process.monitor(pid)@        ref = make_ref()@' \
  lib/ampd/peer.ex

# L7 · The terminal relation is subordinate to the Carrier relation, and the
#      funnel that makes that true had to be built — four sites wrote
#      `st.carriers` on removal and only two shared any code.
probe "ending the carrier relation ends the terminal relation" test/terminal_possession_test.exs \
  '/defp release_carrier(st, peer_id) do/,/^  end/{s@    |> release_terminal(peer_id)@@}' \
  lib/ampd/peer.ex

# L8 · PREPARED is not ACTIVE. Collapsing them is the window this state was
#      added to close: the stream becomes usable while the World still says
#      COMMITTING.
probe "a prepared attachment is not yet a possession" test/terminal_possession_test.exs \
  's@         %{s | phase: :prepared, record: record, owner: owner, owner_ref: owner_ref, setup_ref: nil}}@         %{s | phase: :active, record: record, owner: owner, owner_ref: owner_ref, setup_ref: nil}}@' \
  lib/ampd/terminal_attachment.ex

# L9 · A refused B2 leaves nothing behind, and the convergence lives WITH the
#      refusal rather than in the caller. `K.11` found the first version of
#      this: the refusal was correct, by the right name, and the COMMITTING
#      record it refused was still there afterwards.
probe "a refused commit removes the record it installed" test/terminal_possession_test.exs \
  's@      converge(peer_ref, current, record, pid)@      _ = {peer_ref, current, record, pid}@' \
  lib/ampd/carrier/terminal.ex

# L10 · A refused B1 converges its own stream. Leaving it to the caller makes
#       "B1 refuses and the stream closes" a property of one call path rather
#       than of B1, and the falsifiers drive B1 directly.
probe "a refused admission does not leave the stream running" test/terminal_possession_test.exs \
  '/defp do_b1(ticket, obs, pid) do/,/^  end/{s@        kill_owner(pid)@        :ok@}' \
  lib/ampd/carrier/terminal.ex

# L11 · A stream owner dying under an ordered transaction refuses the
#       transaction. Without the catch, the `GenServer.call` exits the caller
#       — and inside `transact/1` the caller IS the total order, so one lost
#       attachment becomes a control-plane outage. `Process.alive?/1` cannot
#       close this: the answer is stale the instant it returns.
probe "a dead stream owner refuses the commit rather than the total order" test/terminal_possession_test.exs \
  's@    :exit, _ -> :gone@    :exit, e -> exit({:rethrown, e})@' \
  lib/ampd/carrier/terminal.ex

# L12 · The registry holding the record is a third lifetime. `Ampd.Peer` dying
#       takes every `terminal-attachment@1` with it, and a stream owner that
#       survived would hold the host's single attachment slot with nothing in
#       the runtime referring to it. There is no reaper for attachments.
probe "a stream does not outlive the registry that holds its record" test/terminal_possession_test.exs \
  '/def init(%{sock: sock, setup: setup, identity: identity}) do/,/^  end/{s@      p -> Process.monitor(p)@      _p -> nil@}' \
  lib/ampd/terminal_attachment.ex

# L13 · Possession is the conjunction. Bytes are gated by the owner'"'"'s own
#       phase; a resize never touches the owner, so it is the one operation
#       that could be performed on half a possession — in the window B2 opens
#       between finalising the World record and finalising the stream.
probe "a resize is refused until the stream has finished becoming active" test/terminal_possession_test.exs \
  '/def resize_record(record, rows, cols) when is_map(record) do/,/^  end/{s@      stream_phase(current\["peer_ref"\]) != :active ->@      false ->@}' \
  lib/ampd/carrier/terminal.ex

# L14 · Cancellation is addressed the way finalisation is. An unaddressed
#       removal lets a failed commit drop a record a LATER commit installed in
#       the slot it vacated.
probe "removing a terminal record is addressed by identity" test/terminal_possession_test.exs \
  '/def handle_call({:remove_terminal, peer_id, aref, aepoch}, _f, st) do/,/^  end/{s@      r\["attachment_ref"\] != aref or r\["attachment_epoch"\] != aepoch ->@      false ->@}' \
  lib/ampd/peer.ex

# L15 · A busy owner is an ACTIVE owner. `read/1` and `write/2` run their
#       socket call synchronously inside the attachment process, and
#       PROVISIONAL and PREPARED refuse bytes without blocking — so exactly
#       one phase can fail to answer in time, which makes a timeout the
#       answer rather than an absence of one. Reading it as `:gone` refuses a
#       legitimate resize of a terminal that is merely printing.
probe "a terminal that is busy is not mistaken for one that is not yet possessed" test/terminal_possession_test.exs \
  '/defp stream_phase(peer_ref) do/,/^  end/{s@          :unreachable -> :active@          :unreachable -> :gone@}' \
  lib/ampd/carrier/terminal.ex

# NOT probed, and not counted: `Ampd.Carrier.Terminal.release/1`'"'"'s identity
# addressing.
#
# Review found the shape — a queued release removing whatever is in the slot
# by the time it runs, rather than the attachment its caller meant — and the
# repair is in the source. It is **defence in depth, not a closed defect**,
# and the difference is worth writing down rather than hiding behind a probe
# that would score NOT A FALSIFIER.
#
# For the substitution to occur, a replacement must be installed between the
# release being queued and it running. Installing one means ORDERED B1, which
# is a transaction, which queues *behind* the release — the coordinator is
# FIFO, so the replacement cannot exist yet. The defect is unconstructible
# through the only caller `Ampd.Peer.install_terminal/3` has.
#
# That guarantee rests on a convention rather than a mechanism:
# `install_terminal/3` is public and is not behind the `Ampd.Ordered` guard,
# so a future unordered caller would make this reachable. The addressing is
# there for that day.

# --- C1.0b·2 · ordered participant failure semantics -----------------------
#
# Nine probes. The weak proposition — "a registry crash does not crash the
# coordinator" — is easy to satisfy and worthless on its own: a coordinator
# that survives by calling every failure a refusal reports "did not happen"
# about mutations that did. So most of these attack the CLASSIFICATION rather
# than the survival.

# M1 · The survival itself. Restoring the exiting call is the defect the slice
#      exists for, and it takes the total order down with the registry.
probe "an ordered transaction survives a participant it cannot reach" test/ordered_participant_test.exs \
  's@    if inside?() do@    if false do@' \
  lib/ampd/participant.ex

# M2 · A timeout is not a refusal. The request was abandoned; the WORK was
#      not, so calling it "not applied" is a claim the caller cannot make and
#      the mutation can land behind the transaction that refused.
probe "a timed-out mutation is not reported as one that did not happen" test/ordered_participant_test.exs \
  's@  defp after_timeout(:mutate), do: :indeterminate@  defp after_timeout(:mutate), do: :not_applied@' \
  lib/ampd/participant.ex

# M3 · Nor is a death. Without a witness there is no evidence either way, and
#      "no evidence" is not "did not happen".
probe "a mutation whose participant died is not reported as one that did not" test/ordered_participant_test.exs \
  's@  defp after_death(:mutate, nil), do: :indeterminate@  defp after_death(:mutate, nil), do: :not_applied@' \
  lib/ampd/participant.ex

# M4 · **The asymmetry.** Consulting the witness after a timeout reads a world
#      that has not settled: the participant is alive, still holds the
#      request, and applies it afterwards. A false NOT_APPLIED is worse than
#      an honest unknown.
probe "a witness is not consulted while the participant still holds the request" test/ordered_participant_test.exs \
  's@        raise Failure.new(after_timeout(class), server, op, :timeout)@        raise Failure.new(after_death(class, witness), server, op, :timeout)@' \
  lib/ampd/participant.ex

# M5 · A mutation classified as a read gets a read's failure semantics, which
#      is how an indeterminate write becomes a retryable "basis unavailable".
probe "every mutation tag is classified as one" test/ordered_participant_test.exs \
  's@ install_terminal activate_terminal remove_terminal)a@ activate_terminal remove_terminal)a@' \
  lib/ampd/peer.ex

# M6 · The coordinator's catch must match the boundary's own exception. Aimed
#      elsewhere, the failure propagates and the total order dies — which is
#      the pre-slice behaviour wearing the new machinery.
probe "the coordinator catches the failure the boundary raises" test/ordered_participant_test.exs \
  '/defp classify(fun) do/,/^  end/{s@    e in Ampd.Participant.Failure -> {:participant_failed, e}@    e in RuntimeError -> {:participant_failed, e}@}' \
  lib/ampd/authority_coordinator.ex

# M7 · A read that established nothing must not move the world. The
#      indeterminate arm above it deliberately does — the two are different
#      classes and this probe reddens if the distinction is erased downward.
probe "an unavailable read does not advance the ordered revision" test/ordered_participant_test.exs \
  '/{:participant_failed, failure} ->/,+1{s@        {:reply, {:refused, Ampd.Participant.refusal(failure)}, st}@        applied({:refused, Ampd.Participant.refusal(failure)}, st)@}' \
  lib/ampd/authority_coordinator.ex

# M7b · And the other direction. An indeterminate mutation that ANNOUNCES
#       nothing leaves every subscriber rendering a world that may no longer
#       be true, with nothing to correct it — the LIVE LOCAL defect, reached
#       through the one class that cannot say whether it happened.
#
#       It is the view clock, not the ordered revision: `Ampd.RefusalLog`
#       normally ticks it as a side effect of building any refusal, so the
#       falsifier drives this with that process absent and only the explicit
#       call can move it.
probe "an indeterminate mutation announces even with no refusal log" test/ordered_participant_test.exs \
  '/{:participant_failed, %{outcome: :indeterminate} = failure} ->/,/{:reply/{s@        touched()@        :ok@}' \
  lib/ampd/authority_coordinator.ex

# M8 · A witness that FINDS the mutation does not make the operation a
#      success, and must not narrow it to "did not happen" either — the
#      caller never received the answer, so it is still not repeatable.
probe "a witness that finds the mutation does not report it absent" test/ordered_participant_test.exs \
  's@      :applied -> :indeterminate@      :applied -> :not_applied@' \
  lib/ampd/participant.ex

# M9 · Retryability is the operator-facing half of the classification. An
#      indeterminate mutation marked retryable invites the second execution
#      the class exists to forbid.
probe "an indeterminate mutation is never marked retryable" test/ordered_participant_test.exs \
  's@      retryable: f.outcome in \[:unavailable, :not_applied\],@      retryable: true,@' \
  lib/ampd/participant.ex

# M10 · **No layer acts on an unknown as though it were a decision.** Reaping
#       is an action taken on the assumption that membership was not granted,
#       and an indeterminate commit is exactly the case where that assumption
#       is what is unknown. Reaping there leaves the runtime holding a live
#       incarnation whose process is dead.
probe "an indeterminate commit does not reap the carrier it may have committed" test/ordered_participant_test.exs \
  '/def settle_commit(ticket, obs, refusal) do/,/^  end/{s@    if refusal\["code"\] == "participant-indeterminate" do@    if false do@}' \
  lib/ampd/carrier.ex

# M11 · **The read path.** The slice claimed an ordered participant failure no
#       longer takes the total order down, having guarded the transaction path
#       only. An observation walks a dozen registries and is what the cockpit
#       uses on every frame.
probe "an observation survives the registry it was reading" test/ordered_participant_test.exs \
  '/defp survivable(fun) do/,/^  end/{s@    e in Ampd.Participant.Failure -> {:participant_failed, e}@    e in ArgumentError -> {:participant_failed, e}@}' \
  lib/ampd/authority_coordinator.ex

# M12 · A witness runs while the total order is held. Unbounded, one that
#       never returns is worse than a crash: the process stays alive, so
#       nothing restarts it and everything queues behind it permanently.
probe "a witness cannot hold the total order open" test/ordered_participant_test.exs \
  '/defp run_witness(witness) do/,/^  end/{s@      witness_deadline_ms() ->@      99_999 ->@}' \
  lib/ampd/participant.ex

# M12b · And the LINK, which is a different hazard from the exception. A
#        `Task` links to its caller; the caller is the coordinator. The task
#        body catching everything is not the same as there being no link.
#        Sabotaged by ADDING the link rather than by swapping the primitive:
#        `spawn_link/1` returns a bare pid, so swapping it would redden this
#        on a MatchError — red for a reason that has nothing to do with links,
#        which is a probe that proves nothing while looking like it works.
probe "a witness that dies abnormally does not kill its caller" test/ordered_participant_test.exs \
  '/defp run_witness(witness) do/,/^  end/{s@    receive do@    Process.link(pid)\n    receive do@}' \
  lib/ampd/participant.ex

# M13 · `@ordered_ops` answers "must be called by the coordinator";
#       classification answers "a lost reply may mean it happened". Collapsing
#       them classifies `close_store` — which closes the dets handle and is
#       deliberately unordered — as a read.
probe "a mutation that is not ordered is still a mutation" test/ordered_participant_test.exs \
  's|  @client_mutations @ordered_ops ++ \[:close_store\]|  @client_mutations @ordered_ops|' \
  lib/ampd/loci.ex

# M14 · Disposal belongs to every way out of B1, not to one branch of it. A
#       participant failure in `moved/1` unwinds past the refusal branch that
#       kills the owner.
probe "a participant failure in B1 still disposes of the stream owner" test/terminal_possession_test.exs \
  '/e in Ampd.Participant.Failure ->/,+1{s@      kill_owner(pid)@      :ok@}' \
  lib/ampd/carrier/terminal.ex

# NOT probed here: descriptor ownership on the receiving side.
#
# The integer path is reached only by an SCM_RIGHTS receive from the host.
# Nothing in this suite can construct one — `Ampd.Transport.socketpair/1`
# returns a socket handle and takes the other branch, and every descriptor
# a BEAM test can name belongs to an OTP socket, so taking it corrupts
# OTP's bookkeeping rather than modelling the case.
#
# **This note was already here in F.8.1, and it was not enough.** Saying
# "measured elsewhere" is only true if somewhere else actually measures it,
# and the host battery of the day checked `growth <= 14` for a claim of
# ten, never sent a surplus descriptor, and never sent a rejected command
# carrying one — so a leak of one descriptor per *command* sat under 39
# green falsifiers and 171 green tests for a whole revision. The five
# probes that would have caught it are in `tools/sabotage-host.sh`, and
# they run the real host against a real runtime because that is the only
# place the case exists.

# ============================================================ C1.0b·2·1
#
# The closure round. C1.0b·2 converted two participants; the reachability
# census (`tools/ordered-reachability.exs`) named the rest, and these probes
# are what stop the conversion from being a source-enumeration exercise.
#
# Each one removes a different half of the same claim: that a crossing is
# routed through the boundary AND carries a class AND is cut correctly when
# the participant does not answer.

# The class is a list, so it can be deleted without touching a call site —
# which turns every mutation in the registry into a read, and every lost
# reply into a retryable "nothing was mutated".
probe "a mutation in a converted registry is classified as one" test/ordered_closure_test.exs \
  's|def class(tag), do: if(tag in @participant_mutations, do: :mutate, else: :read)|def class(_tag), do: :read|' \
  lib/ampd/grant_registry.ex

# The funnel, bypassed. This is what the tree looked like before the round:
# an absent participant exits the caller, and the caller is the total order.
probe "an ordered call to an absent registry does not exit the coordinator" test/ordered_closure_test.exs \
  's|Ampd.Participant.call(__MODULE__, msg, class(tag), timeout: timeout)|GenServer.call(__MODULE__, msg, timeout)|' \
  lib/ampd/approvals.ex

probe "the worktree registry answers through the boundary" test/ordered_closure_test.exs \
  's|Ampd.Participant.call(__MODULE__, msg, class(tag), timeout: timeout)|GenServer.call(__MODULE__, msg, timeout)|' \
  lib/ampd/worktree.ex

# The two lists answer two questions, and only one direction is a defect:
# an op served ONLY for the coordinator that is classified a read gives an
# indeterminate write a retryable "nothing was mutated".
probe "an ordered op is not classified as a read" test/ordered_closure_test.exs \
  's|@participant_mutations ~w(close_store load_state world end_run reset)a|@participant_mutations ~w(close_store load_state end_run reset)a|' \
  lib/ampd/session.ex

# The two-participant cut. `if false` makes an INDETERMINATE activation
# compensate, which removes the World record of a possession that may be
# about to become live.
probe "a stream owner that did not answer is not compensated for" test/terminal_possession_test.exs \
  's|^      if e.reason == :timeout,$|      if false,|' \
  lib/ampd/carrier/terminal.ex

# The deadline that outlived its own budget for as long as nothing read it.
probe "the embodiment measurement fits inside the transaction budget" test/effect_channel_test.exs \
  's|@identity_deadline_ms 12_000|@identity_deadline_ms 30_000|' \
  lib/ampd/embodiment.ex

# Absent measurement must refuse, not raise. Without the rescue the
# boundary's exception leaves through the coordinator and a fail-closed
# measurement becomes a failed transaction.
probe "an unreachable embodiment cache is still fail-closed" test/ordered_closure_test.exs \
  's|    e in Ampd.Participant.Failure ->|    e in Ampd.Participant.NoSuchFailure ->|' \
  lib/ampd/embodiment.ex

echo
# **PREFIXED AT W.1.4.2, BECAUSE THIS LINE AND `sabotage-host.sh`'s WERE THE
# SAME BYTES.** Both printed `N falsified · M did not`, and
# `emit-measurements.mjs` reads figures out of the release log by regex. So
# the moment this battery entered the chain, `host_falsifiers` would have
# matched whichever battery printed first and recorded it under the other
# one's name — a fresh drift defect created by the round whose subject is
# drift. `bot`, `guard` and `count` sabotage were already prefixed; these two
# were the ones nobody had needed to tell apart yet.
echo "beam sabotage: $pass falsified · $fail did not"
[ "$fail" -eq 0 ]
