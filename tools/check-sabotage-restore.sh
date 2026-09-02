#!/usr/bin/env bash
# check-sabotage-restore — the falsifier harnesses put the tree back.
#
# Both sabotage batteries `sed`-edit real source in place. An interrupt
# between the mutation and the restore leaves a sabotaged file in the working
# tree with a `.orig` beside it and nothing to announce it — and the next
# `git add -A` turns a falsifier into production code. That is not
# hypothetical: it happened to `ampd/lib/ampd/native_fd.ex` and then to
# `ampd/lib/ampd/transport.ex`, and the host battery carried a comment
# claiming an `INT` trap it did not have.
#
# Running either battery to prove this costs an hour. This costs a second:
# it asserts the traps are DECLARED in both scripts, and then exercises the
# mechanism on a reduction with the same shape.
#
# **Why a reduction and not the real thing.** Bash defers a trap until the
# current foreground command returns, and those batteries live inside
# `cargo build` and a 240 s `timeout` — so interrupting one and waiting for
# the trap is minutes, not seconds. The reduction has the same trap
# structure with a `sleep` in place of the build, which is the part under
# test.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
ok () { printf '  \033[32mheld\033[0m  %s\n' "$1"; }
no () { printf '  \033[31mFAIL\033[0m  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

printf '\n  D.1.3c·2b·0a · the harness restores the tree\n'

for f in tools/sabotage-host.sh ampd/tools/sabotage.sh; do
  if grep -qE '^trap restore_all EXIT' "$f"; then
    ok "$f restores on EXIT"
  else
    no "$f restores on EXIT" "no 'trap restore_all EXIT'"
  fi
  if grep -qE "^trap 'exit 130' INT" "$f"; then
    ok "$f exits on INT rather than continuing through a half-restored probe"
  else
    no "$f exits on INT" "no INT trap"
  fi
done

# A comment claiming a trap is worse than no trap: it tells a reader the
# protection exists. This is why that sentence is checked for.
if grep -q 'INT` trap this file already carries' tools/sabotage-host.sh; then
  no "no script claims a trap it does not have" "the stale claim is back in sabotage-host.sh"
else
  ok "no script claims a trap it does not have"
fi

# ------------------------------------------------- the mechanism, exercised
d=$(mktemp -d)
cat > "$d/probe.sh" <<'INNER'
set -uo pipefail
cd "$1"
restore_all () {
  for f in *.orig; do
    [ -e "$f" ] || continue
    mv -- "$f" "${f%.orig}"
  done
}
trap restore_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo $$ > pid
echo original > victim.txt
cp victim.txt victim.txt.orig
echo SABOTAGED > victim.txt
sleep 30
INNER

# **A new session, and the signal goes to the whole group.**
#
# Two facts had to be measured before this was right, and both were caught
# by the clock rather than by an exit code.
#
# First: bash sets SIGINT to SIG_IGN for background jobs in a non-interactive
# shell, and a child cannot trap a signal it inherited as ignored. So
# `kill -INT <pid>` did nothing at all — and the probe slept its full 30 s,
# exited normally, ran its EXIT trap on the way out, and made "restored" and
# "no residue" go GREEN having proved nothing.
#
# Second: even a signal that IS delivered is deferred. Bash runs a trap only
# when the current foreground command returns, and the probe was inside
# `sleep 30` — standing in for the `cargo build` the real battery is inside.
# So the handler fired half a minute late, which is indistinguishable from
# not firing.
#
# A real Ctrl-C has neither problem, because the terminal signals the
# foreground process GROUP: the child dies at once and bash runs the trap
# immediately after. That is what is modelled here — `setsid` gives the
# probe its own session so signalling its group cannot reach this script,
# and in a new session the probe's own pid IS the group id.
setsid bash "$d/probe.sh" "$d" &
sleep 1
during=$(cat "$d/victim.txt" 2>/dev/null)
kid=$(cat "$d/pid" 2>/dev/null)
kill -TERM -"$kid" 2>/dev/null

started=$SECONDS
# `wait` cannot see it — a new session is not this shell's child job — so
# liveness is polled on the pid the probe reported.
for _ in $(seq 1 100); do
  kill -0 "$kid" 2>/dev/null || break
  sleep 0.1
done
elapsed=$((SECONDS - started))
after=$(cat "$d/victim.txt" 2>/dev/null)
residue=$(ls "$d"/*.orig 2>/dev/null | wc -l)

[ "$during" = "SABOTAGED" ] && ok "the reduction really sabotages before the interrupt" \
  || no "the reduction really sabotages" "saw '$during'"
# **Termination is asserted by the clock, not by the exit code.** The probe
# sleeps 30 s after sabotaging; returning in under five means the trap fired
# and the script ended rather than running on. The exit *status* is not
# reliably observable from here — bash ignores SIGINT for background jobs in
# a non-interactive shell, and the wrappers that work around that (`setsid`,
# `setsid --wait`) put a process between `$!` and the probe whose status is
# the one `wait` reports. Chasing the number was measuring this harness; the
# clock measures the battery'"'"'s property.
[ "$elapsed" -lt 5 ] && ok "an interrupt ENDS the run instead of continuing (${elapsed}s of a 30s sleep)" \
  || no "an interrupt ends the run" "it ran ${elapsed}s; the trap did not stop it"
[ "$after" = "original" ] && ok "the original bytes are back" \
  || no "the original bytes are back" "saw '$after'"
[ "$residue" -eq 0 ] && ok "no .orig residue is left behind" \
  || no "no .orig residue" "$residue file(s)"

rm -rf "$d"

echo
if [ "$fail" -eq 0 ]; then
  printf '  sabotage restore: \033[32mheld\033[0m\n'
else
  printf '  sabotage restore: \033[31m%s failed\033[0m\n' "$fail"
fi
[ "$fail" -eq 0 ]
