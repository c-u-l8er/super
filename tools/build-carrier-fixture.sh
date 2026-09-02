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
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

(cd carrier-fixture && CARGO_TARGET_DIR="$tmp" cargo build --release "$@")

fresh="$tmp/release/super-carrier-fixture"

if [ ! -x "$fresh" ]; then
  printf '\033[31mFAIL\033[0m  the fixture did not build\n' >&2
  exit 1
fi

# Asserted on the artifact this invocation produced, before it is allowed
# anywhere near the canonical path.
if file "$fresh" | grep -q 'dynamically linked'; then
  printf '\033[31mFAIL\033[0m  the freshly built fixture is DYNAMICALLY linked.\n' >&2
  printf '      carrier-fixture/.cargo/config.toml did not apply — check for a\n' >&2
  printf '      stray RUSTFLAGS/CARGO_BUILD_RUSTFLAGS in the environment.\n' >&2
  exit 1
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
  printf '\033[31mFAIL\033[0m  the installed fixture is not the one just built\n' >&2
  exit 1
fi

printf '  \033[32mheld\033[0m  the Carrier payload is freshly built and statically linked · %s\n' \
  "$(file -b "$root/$out" | cut -d, -f1-2)"
