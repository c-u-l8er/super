#!/usr/bin/env bash
# sabotage-validation — R0b.R's falsifiers, falsified.
#
# R13's rule, stated plainly: **do not count a green functional test as
# proof until stubbing the mechanism makes the intended row red.** A suite
# that stays green when its subject is removed is measuring something else,
# and this tree has a measured scar for that — `sabotage-counts.sh` found a
# gate that had never refused anything at all.
#
# So each case here removes exactly ONE mechanism from a COPY of the tree,
# runs the R7 suite against the copy, and requires a NAMED test to fail. A
# case that merely makes the suite red somewhere is not a catch: a stub that
# breaks compilation would otherwise score as evidence for every row at once.
#
#     bash tools/sabotage-validation.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

CAUGHT=0; NOT=0; BROKE=0; UNAPPLIED=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The copy carries `ampd/_build` (2.8 MB) and `host/target` (24 MB)
# deliberately — a rebuild per case would dominate the runtime, and the Rust
# host is not what is being sabotaged.
#
# **`cockpit/target` is excluded and that is not an optimisation.** It is
# 1.1 GB, `$WORK` is under `/tmp`, and `/tmp` on this machine is a 16 GB
# tmpfs that runs chronically near full. MASTER plus one live copy would be
# 2.2 GB of it, per case, for a binary no case touches — and a tmpfs that
# fills does not fail this harness cleanly, it fails everything on the box.
# The cockpit is not sabotaged here and the ExUnit suite does not need it.
#
# `priv/data` goes too: it is a world, not source, and a stale one copied 22
# times is 22 chances to measure the wrong ledger.
MASTER="$WORK/master"; mkdir -p "$MASTER"
tar -cf - --exclude=./ampd/.elixir_ls --exclude='./*.zip' \
          --exclude=./ampd/erl_crash.dump --exclude=./old_scrap \
          --exclude=./cockpit/target --exclude=./ampd/priv/data . \
  | tar -xf - -C "$MASTER"

fresh () { rm -rf "$WORK/t"; cp -a "$MASTER" "$WORK/t"; T="$WORK/t"; }

# **The data dir is one fixed absolute path for every checkout on this
# machine** (`config/config.exs` sets `/tmp/ampd-test-data` and `rm -rf`s it
# at config load). Two suites running at once therefore delete each other's
# world mid-run, and the failures that produces look like ordinary red rows.
# Each case gets its own directory so a case cannot be scored against
# another case's wreckage.
run_suite () {                        # run_suite <dir> → stdout of the suite
  ( cd "$1/ampd" && AMPD_DATA_DIR="$WORK/data-$$-$RANDOM" \
      mix test test/validation_job_test.exs 2>&1 )
}

# case_ <label> <want-failure-text> <file> <old-substring> <new-substring>
#
# **The edit is proven, not assumed.** The first version of this harness
# embedded Python in the shell string and the quoting did not survive; every
# stub silently failed to apply, the suite stayed green, and eighteen cases
# were scored NOT A FALSIFIER. A harness that cannot tell "the mechanism was
# removed and nothing noticed" from "the mechanism was never removed" is
# reporting the wrong verdict with total confidence — which is the same
# defect it exists to find. So the substitution is exact, and a miss is
# `UNAPPLIED`, never a verdict about the suite.
case_ () {
  local label="$1" want="$2" file="$3" old="$4" new="$5"
  fresh
  if ! OLD="$old" NEW="$new" python3 -c '
import os, sys
p = sys.argv[1]
s = open(p).read()
old, new = os.environ["OLD"], os.environ["NEW"]
if old not in s:
    sys.exit(3)
open(p, "w").write(s.replace(old, new, 1))
' "$T/$file"; then
    printf '  \033[35mUNAPPLIED\033[0m  %s\n' "$label"
    printf '           the substring is not in %s — the stub never landed\n' "$file"
    UNAPPLIED=$((UNAPPLIED+1)); return
  fi

  local out; out=$(run_suite "$T")

  if grep -q 'Compilation failed\|(CompileError)\|(SyntaxError)' <<<"$out"; then
    printf '  \033[33mBROKE\033[0m  %s — the stub did not compile, so it proves nothing\n' "$label"
    BROKE=$((BROKE+1)); return
  fi
  if grep -qF "$want" <<<"$out"; then
    printf '  \033[32mcaught\033[0m  %s\n' "$label"
    printf '           → %s\n' "$want"
    CAUGHT=$((CAUGHT+1))
  else
    printf '  \033[31mNOT A FALSIFIER\033[0m  %s\n' "$label"
    printf '           the suite stayed green with the mechanism removed\n'
    printf '           wanted a failure naming: %s\n' "$want"
    NOT=$((NOT+1))
  fi
}

echo
echo "sabotage-validation — R0b.R · one mechanism removed per case"
# **Name the tree.** The log carried no commit, so a bundle quoting its
# verdict could not say which source the 35 catches were about — and the
# whole discipline of this round is that a measurement names the identity it
# measured. The host battery's harness has always done this; this one did not.
printf '# HEAD %s · %s\n' \
  "$(git rev-parse --short=12 HEAD 2>/dev/null || echo nogit)" \
  "$(date -u +%Y%m%dT%H%M%SZ)"
[ -n "$(git status --porcelain 2>/dev/null)" ] && printf '# DIRTY: %s\n' \
  "$(git status --porcelain | tr '\n' ';')"
echo

# ------------------------------- R0b.R·1 · the RECEIVING admission point
# **The cases are DATA, not shell.** They were 36 inline `case_` invocations
# whose arguments are multi-line Elixir fragments, quoted for `sh`. Editing
# that by pattern cost this round four separate self-inflicted breakages —
# every one a deletion whose bound ("the line does not end in a backslash")
# cannot describe a block containing multi-line strings, each leaving a
# syntactically broken fragment behind. `bash -n` caught all four, which is
# the only reason none shipped.
#
# A failure mode that recurs is a failure mode to remove, not to patch again.
# The cases now live in `sabotage-validation.cases.json`, where a fragment is
# a JSON string and there is no quoting to get wrong, and this loop runs them.
CASES="$(dirname "$0")/sabotage-validation.cases.json"
[ -f "$CASES" ] || { echo "REFUSING: no $CASES" >&2; exit 2; }

# **Pre-flight: every anchor must occur EXACTLY ONCE in its file.**
# Zero means the stub will not land and the case scores UNAPPLIED — which is
# honest but costs a full run to learn. More than one is worse: the stub
# silently edits whichever came first, and a case that names the OUTCOME path
# while stubbing the START path reports NOT A FALSIFIER about a function it
# never touched. Both happened this round. Checked in seconds, up front.
python3 - "$CASES" <<'PREFLIGHT' || exit 2
import json, sys
bad = 0
for c in json.load(open(sys.argv[1])):
    n = open(c['file']).read().count(c['old'])
    if n != 1:
        first = c['old'].strip().splitlines()[0][:56]
        print(f"  REFUSING  {c['label']}\n            anchor occurs {n}x in {c['file']} — {first}")
        bad += 1
if bad:
    print(f"\n  {bad} anchor(s) not exactly-once; a stub that does not land proves nothing")
sys.exit(1 if bad else 0)
PREFLIGHT

count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$CASES")
i=0
while [ "$i" -lt "$count" ]; do
  # One field per read, so a fragment containing newlines, quotes or
  # backslashes never has to survive a shell word split.
  field () { python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))[int(sys.argv[2])]
sys.stdout.write(c.get(sys.argv[3], ""))
' "$CASES" "$i" "$1"; }

  section=$(field section)
  [ -n "$section" ] && printf '\n  \033[2m%s\033[0m\n' "$section"

  case_ "$(field label)" "$(field want)" "$(field file)" "$(field old)" "$(field new)"
  i=$((i + 1))
done

echo
printf 'sabotage-validation: %d caught · %d NOT A FALSIFIER · %d did not compile · %d unapplied\n' \
  "$CAUGHT" "$NOT" "$BROKE" "$UNAPPLIED"
[ "$NOT" -eq 0 ] && [ "$BROKE" -eq 0 ] && [ "$UNAPPLIED" -eq 0 ]
