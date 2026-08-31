#!/usr/bin/env bash
# check-epoch-mint — the incarnation token's width, and the absence of the
# door that lets a test pin it.
#
# `Ampd.Peer.epoch/0` stopped being a freshness token at D.1.3b·2d. It is now
# the fence between physical Carrier universes: `Ampd.Carrier.Machine.Gate`
# and the Rust host both key "which live process set belongs to whom" on it,
# and the published claim about it — a Carrier's physical lifetime cannot
# outlive the incarnation that admitted it — is absolute. Review's objection
# was that the mint was four CSPRNG bytes, a scale on which an actual
# discontinuity can be *represented as equality*. It is sixteen now.
#
# The falsifier for the other half of that repair (`E30`) has to reproduce a
# collision on demand, so `Ampd.Peer.mint_epoch/0` carries a `:test`-only
# clause that reads a pinned value out of a `:persistent_term`. **That is a
# door that forges runtime identity**, and prose saying it is compiled out is
# not a gate — an earlier draft of this very slice claimed a gate that did
# not exist, and an audit caught it.
#
# So this asks the artifact rather than the source. `Mix.env() == :test` is
# evaluated at compile time, so the atom is in the `:test` BEAM's atom table
# and absent from the `:prod` one. Both directions are checked: a gate that
# would pass against a module with no door at all is measuring nothing, and
# would go green forever if `E30` were deleted tomorrow.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
ok () { printf '  \033[32mheld\033[0m  %s\n' "$1"; }
no () { printf '  \033[31mFAIL\033[0m  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

printf '\n  D.1.3b·2e · the incarnation mint\n'

# ---------------------------------------------------------------- 1 · width
src=ampd/lib/ampd/peer.ex
mints=$(grep -c 'strong_rand_bytes(16) |> Base.encode16' "$src")
narrow=$(grep -n 'strong_rand_bytes(4)' "$src")

if [ "$mints" -ge 1 ] && [ -z "$narrow" ]; then
  ok "the peer incarnation epoch is minted from 16 CSPRNG bytes ($mints site(s))"
else
  no "the peer incarnation epoch is minted from 16 CSPRNG bytes" \
     "16-byte mints=$mints; 4-byte mints still present: ${narrow:-none}"
fi

# `Ampd.AuthorityCoordinator` keeps a four-byte epoch and that is deliberate:
# it makes a projection revision stream comparable across a coordinator
# restart, gates no effect and starts no process, and a collision there costs
# a stale cockpit render until the next mutation. Named here so that the
# asymmetry is a decision on the record rather than something this gate
# forgot to look at.
if grep -q 'strong_rand_bytes(4)' ampd/lib/ampd/authority_coordinator.ex; then
  ok "the coordinator's projection epoch is deliberately NOT widened (rendering, not a fence)"
else
  no "the coordinator's projection epoch is deliberately NOT widened" \
     "it changed; if that was intentional, this gate needs re-ruling"
fi

# --------------------------------------------------- 2 · the door, measured
#
# **`cd ampd` and not `mix -C`, and the first draft of this gate got it
# wrong.** There is no `mix.exs` at `super/`, so running `mix compile` from
# here fails with "Could not find a Mix.Project" — and with the `|| true`
# below swallowing it, the gate graded whatever BEAM files happened to be
# lying on disk from an earlier manual build. It passed. A gate that goes
# green over work it did not do is the exact shape it exists to catch, so
# the compile is checked rather than tolerated.
for env in prod test; do
  if ! (cd ampd && MIX_ENV=$env mix compile --no-deps-check >/dev/null 2>&1); then
    no "the :$env BEAM was built" "mix compile failed under MIX_ENV=$env"
  fi
done

beam () { echo "ampd/_build/$1/lib/ampd/ebin/Elixir.Ampd.Peer.beam"; }
count () { strings "$(beam "$1")" 2>/dev/null | grep -c 'forced_epoch' || true; }

if [ ! -f "$(beam prod)" ] || [ ! -f "$(beam test)" ]; then
  no "both BEAM environments were built" "missing $(beam prod) or $(beam test)"
else
  p=$(count prod)
  t=$(count test)

  if [ "$p" -eq 0 ]; then
    ok "the pinned-epoch door is absent from the :prod BEAM (0 references)"
  else
    no "the pinned-epoch door is absent from the :prod BEAM" \
       "$p reference(s) — runtime identity is forgeable in a release"
  fi

  # The control. Without it this gate passes against a module that never had
  # the door, which is the shape of a check that cannot fail.
  if [ "$t" -ge 1 ]; then
    ok "the door IS present in the :test BEAM, so the check above can fail ($t)"
  else
    no "the door IS present in the :test BEAM" \
       "0 references — either E30 is gone or this gate is measuring nothing"
  fi
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf '  epoch mint: \033[32mheld\033[0m\n\n'
else
  printf '  epoch mint: \033[31m%d failed\033[0m\n\n' "$fail"
  exit 1
fi
