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
  's@    Enum.each(st.channels, fn {pid, _ch} -> Process.exit(pid, :kill) end)@    Enum.each(st.channels, fn {pid, _ch} -> send(pid, :stop) end)@' \
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

probe "an identity does not outlive the process that asked for it" test/lifecycle_test.exs \
  's|  defp own(owners, pid, id), do: Map.put(owners, Process.monitor(pid), id)|  defp own(owners, _pid, _id), do: owners|' \
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
  's|  def handle_call({:observe_once, fun}, _from, st), do: {:reply, once(fun, st), st}|  def handle_call({:observe_once, fun}, _from, st), do: {:reply, coherent(fun, st, 3), st}|' \
  lib/ampd/authority_coordinator.ex

# A read that counted as an ordered operation would advance the revision it
# is reporting — a cursor that changes because it was looked at, and a push
# that is its own reason for another push.
probe "an observation is ordered but is not an operation" test/cockpit_test.exs \
  's|  def handle_call({:observe, fun}, _from, st), do: {:reply, coherent(fun, st, 3), st}|  def handle_call({:observe, fun}, _from, st), do: run(fn -> coherent(fun, st, 3) end, st)|' \
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
  '66 s|^    Ampd.AuthorityCoordinator.touched()$|    _ = :no_touch|' \
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
