#!/usr/bin/env bash
# build-payloads — the one way an installed Carrier payload is built.
#
# **Two payloads as of R0a, and the list below IS what "installed" means.**
# `carrier::payload_path()` picks the production payload from this set and
# `carrier::fixture_path()` names the confinement fixture; nothing else in
# the tree decides what a Carrier runs, and no protocol field can (D.1.2).
# So a payload that is not built here is not installed, and adding one is
# adding a line to `PAYLOADS`.
#
# It was `build-carrier-fixture.sh` and built one. Splitting it in two would
# have duplicated every hard-won line below into a file that then drifts —
# the `cd` that is the build rule, the private CARGO_TARGET_DIR that makes
# provenance structural, the `cp`-not-`mv` that stops a write going through
# a `deps/` hard link. One entry point, a table, and the same assertions on
# every artifact.
#
# **The working directory is part of this build's configuration.**
#
# `carrier-fixture/.cargo/config.toml` pins `-C target-feature=+crt-static`,
# and it has to: Landlock's execute grant names exactly one inode, so a
# dynamically linked payload would need `FS_EXECUTE` across all of
# `/usr/lib` — which is not a confinement. The linkage is a policy decision,
# which is why it lives in version control rather than in a shell history.
#
# But cargo discovers `.cargo/config.toml` from the **current directory and
# its ancestors**, not from the package `--manifest-path` names. So:
#
#     cd carrier-fixture && cargo build --release            static-pie
#     cargo build --release --manifest-path carrier-fixture/Cargo.toml
#       from the repo root                                   DYNAMIC
#
# The second is an ordinary, supported cargo invocation that produces a
# binary with the same name, in the same place, at a plausible size — and
# every Carrier start then fails `EACCES`, nineteen acceptance checks go red
# at once, and none of them says why. The runtime reports
# `carrier-execution-basis-changed`, which points at the digest rather than
# at the linkage.
#
# `super-host verify` now catches the wrong artifact. This exists so the
# release path cannot manufacture it: one entry point, and it asserts the
# result rather than trusting the configuration it just relied on. A build
# rule that is only *believed* to have applied is the thing that failed here
# the first time.
set -euo pipefail
cd "$(dirname "$0")/.."

root=$(pwd)

# crate directory : binary name. The binary name is also the basename
# `carrier::payload_path()` and `carrier::fixture_path()` look for beside
# `super-host`, so these two strings are the whole installation contract.
PAYLOADS=(
  "carrier-fixture:super-carrier-fixture"
  "dogfood:super-dogfood"
)

build_one () {
  local crate="$1" bin="$2"
  local out="$crate/target/release/$bin"

# **Built into a fresh target directory, then installed.**
#
# The first version built in place and only forced a recompile when the
# existing artifact looked *dynamic*. That closed the case it had just been
# bitten by and left the general one open: cargo calls itself up to date by
# fingerprint, so a planted or stale **statically linked** binary at the
# output path passes "not dynamic" and is never rebuilt. The predicate was
# checking embodiment when the question is provenance.
#
# So the build cannot see the canonical target directory at all. A private
# CARGO_TARGET_DIR has no fingerprints to trust and no output to leave
# alone, which makes "this binary came from this invocation of this source"
# structural rather than inferred. The fixture is tiny — a full build is
# about two seconds — so there is nothing to trade away.
#
# The `cd` is still the build rule: cargo reads `.cargo/config.toml` from
# the working directory, not from the package `--manifest-path` names, and
# that file is where `+crt-static` is pinned. Landlock's execute grant names
# one inode, so a dynamic payload would need FS_EXECUTE across /usr/lib.
  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  (cd "$crate" && CARGO_TARGET_DIR="$tmp" cargo build --release "${EXTRA[@]}")

  local fresh="$tmp/release/$bin"

  if [ ! -x "$fresh" ]; then
    printf '\033[31mFAIL\033[0m  %s did not build\n' "$bin" >&2
    return 1
  fi

  # Asserted on the artifact this invocation produced, before it is allowed
  # anywhere near the canonical path.
  if file "$fresh" | grep -q 'dynamically linked'; then
    printf '\033[31mFAIL\033[0m  the freshly built %s is DYNAMICALLY linked.\n' "$bin" >&2
    printf '      %s/.cargo/config.toml did not apply — check for a\n' "$crate" >&2
    printf '      stray RUSTFLAGS/CARGO_BUILD_RUSTFLAGS in the environment.\n' >&2
    return 1
  fi

  # `cp` and not `mv`: the canonical path may be a hard link into a `deps/`
  # tree, and writing *through* such a link is how a previous session
  # corrupted the deps artifact under a still-current fingerprint. Removing it
  # first breaks the link rather than following it.
  mkdir -p "$(dirname "$root/$out")"
  rm -f "$root/$out"
  cp "$fresh" "$root/$out"
  chmod +x "$root/$out"

  if file "$root/$out" | grep -q 'dynamically linked'; then
    printf '\033[31mFAIL\033[0m  the installed %s is not the one just built\n' "$bin" >&2
    return 1
  fi

  printf '  \033[32mheld\033[0m  %-24s freshly built and statically linked · %s\n' \
    "$bin" "$(file -b "$root/$out" | cut -d, -f1-2)"
}

EXTRA=("$@")
rc=0
for entry in "${PAYLOADS[@]}"; do
  build_one "${entry%%:*}" "${entry##*:}" || rc=1
done
exit $rc
