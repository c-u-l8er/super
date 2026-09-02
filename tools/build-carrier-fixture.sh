#!/usr/bin/env bash
# build-carrier-fixture — the one way the Carrier payload is built.
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
out=carrier-fixture/target/release/super-carrier-fixture

# The `cd` IS the build rule. Not `--manifest-path`, ever.
build () { (cd carrier-fixture && cargo build --release "$@"); }

# Static, as judged at the artifact rather than at the configuration that
# was supposed to produce it.
is_static () { [ -x "$root/$out" ] && ! file "$root/$out" | grep -q 'dynamically linked'; }

build "$@"

# **A wrong artifact can survive a successful build, twice over.** Cargo
# hard-links `target/release/<name>` from `deps/<name>-<hash>` and then
# calls itself up to date by fingerprint, so:
#
#   - a binary planted at the output path is not replaced; and
#   - because that path is a HARD LINK, anything that wrote *through* it
#     corrupted the deps artifact as well — under a hash whose fingerprint
#     is still considered current.
#
# Both were reproduced here. Neither is exotic: the first is "someone
# copied a binary around", the second is the same act one inode deeper. So
# a failed check forces a real recompile rather than another link, and only
# then gives up.
if ! is_static; then
  printf '  the fixture is not static — forcing a rebuild
' >&2
  # `cargo clean -p` is not the tool: it reports "Removed 0 files" and
  # leaves both the binary and its deps artifact in place. The fingerprint
  # is what has to be invalidated, so the source mtime is what moves.
  find carrier-fixture/src -name '*.rs' -exec touch {} +
  rm -f "$root/$out"
  build "$@"
fi

if [ ! -x "$root/$out" ]; then
  printf '\033[31mFAIL\033[0m  the fixture did not build: %s\n' "$out" >&2
  exit 1
fi

if ! is_static; then
  printf '\033[31mFAIL\033[0m  the fixture is DYNAMICALLY linked, and a forced\n' >&2
  printf '      rebuild did not fix it. Its .cargo/config.toml is not being\n' >&2
  printf '      read — check for a --manifest-path build or a stray\n' >&2
  printf '      CARGO_BUILD_RUSTFLAGS/RUSTFLAGS in the environment.\n' >&2
  exit 1
fi

printf '  \033[32mheld\033[0m  the Carrier payload is statically linked · %s\n' \
  "$(file -b "$root/$out" | cut -d, -f1-2)"
