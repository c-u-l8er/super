# W.1.4.2 — the measurement described a set the hash did not

**Artifact: `and-super-rev-w142.zip`, with `and-super-rev-w142.receipt.json` beside it.
Predecessor: `W.1.4.1`, `sha256:b05b8922…8166`.**

> **Release-evidence only. The runtime is not touched.** `observe_once`, multiplicity routing and
> `RefusalLog` are exactly as W.1.4.1 shipped them. Your §4 chase is right and I have not reopened
> anything.

You found that W.1.4.1's receipt recorded **113 text assets** while the archive it binds contains
**112**, and you named the mechanism. Both are correct. I reproduced it, and then went looking for
the rest of the class, which turned out to be larger than one file and pointed in both directions.

---

## 0 · Measured — `site/proof/measurements.json`

Figures are in the receipt; this document references it rather than restating it. Two numbers
belong in prose because they are the *subject* of the round rather than a measure of its health:

```
check-source-hygiene, run against the W.1.4.1 artifact

  clean extracted W.1.4.1                          112
  + one previous and-super-rev-*.receipt.json      113
  − it again                                       112
```

That is your hypothesis, reproduced deterministically on this box. The receipt said 113 about an
archive containing 112.

---

## 1 · Confirmed, and the mechanism is exactly as you described it

`release.sh` ran the hygiene gate at stage 3 and `rm -f ./and-super-rev-*` at stage 27, with
packaging at stage 28. W.1.4 shipped immediately before W.1.4.1, so `and-super-rev-w14.receipt.json`
was in the tree when the gate counted, and gone when the packager ran.

What makes it worth a round rather than a patch: **nothing was transcribed.** Both numbers came out
of the same tool, on the same tree, within the same minute. The arc that produced
`emit-measurements.mjs` was aimed at humans retyping figures, and this defect has no human in it.
The figure was machine-generated, hash-bound, and describing different bytes than the ones it was
bound to.

Your law is the right generalisation and I have written it into the source:

> **A release measurement must quantify the same artifact set the receipt binds.
> Measurement scope is part of artifact identity.**

---

## 2 · Three more, found by looking for the class rather than the instance

Your finding says one non-shipping file was counted. The inverse turned out to be true of more
files, and one of them is not small.

### 2.1 · `ampd/erl_crash.dump` shipped in every archive, and no gate ever read it

**5,066,337 bytes** — 940,874 compressed, **40% of the W.1.4.1 archive**. A BEAM crash dump from a
runtime that died during boot on 2026-08-22 (`Slogan: Runtime terminating during boot`), 153,829
lines of scheduler and atom-table state.

It is named in the repo's own `.gitignore`, under a comment saying crash dumps are not history worth
carrying. It was invisible to the hygiene gate because `.dump` matched no textual extension, and it
was invisible to both packagers because neither skip-list mentioned it. **Nothing had an opinion
about it in either direction**, which is how it rode along.

I checked it for disclosure before deciding severity, because "40% of a review artifact is an
unread crash dump" deserves better than a guess. The scan hits are atom-table entries, not values:
`password`, `get_password`, `srp_user_secret_nif` and `srp_host_secret_nif` are OTP crypto and `:io`
function names, and every `token` hit is `Elixir.String.Tokenizer`. No home paths, no environment
block. So this is weight and unread bytes, not a leak — but an archive that ships five megabytes no
gate has read is making a claim about bytes it never opened.

### 2.2 · Three shipped files were outside the gate that exists to protect them

| shipped in W.1.4.1 | why the gate could not see it |
|---|---|
| `ampd/c_src/ampd_fd_nif.c` | `.c` was not in the textual extension list |
| `host/Cargo.lock` | `.lock` was not either |
| `site/preview/preview-meta.json` | the walker skipped every directory named `preview` |

The C file is the sharp one. `release.sh` ships it *specifically to be compiled at the far end* —
its own comment says "Ship the twelve lines of C; let the compiler task build it where it will run"
— and the gate whose stated purpose is *no NUL in any text asset* could not see it. This is the
W.1.3.2 defect with the file changed: a parity gap that is currently harmless.

### 2.3 · There were two packagers and they excluded different sets

`release.sh` chose between `zip` and python on whether the `zip` binary happened to be installed.
The `zip` path excludes neither `.git` nor `.elixir_ls`; the python path excludes both; neither
excludes `deps`, which the hygiene walker did. **The bytes a revision names depended on the
toolchain of the box that packaged it** — in the script that carries the paragraph titled *A
revision must name one byte history*.

It never fired: `super/` has no `.git` of its own, `.elixir_ls` and `ampd/deps` are absent, and this
box has no `zip`. One `mix deps.get` before a release is all it would have taken.

---

## 3 · What changed

**`tools/release-scope.mjs` — new.** One declaration of what a release contains. The hygiene gate
walks it, the packager writes it, the replay re-derives it. Before this there were four disagreeing
definitions — the hygiene walker's skip-list, the `zip` globs, the python tuple, and `.gitignore` —
and no two described the same set.

Previous artifacts (`*.zip`, `and-super-rev-*.receipt.json`) are excluded from **every** walk. That
is the class fix rather than the ordering fix, and it is where I deviated from your proposal — see
§6.

**`tools/package.mjs` — new.** One packager, over `shipped()`, in sorted order. It **refuses** to
package a file the declaration does not classify as either textual or opaque, which is what would
have stopped 2.1: silence is no longer an available answer.

**`tools/replay-artifact.mjs` — new.** Your item 4, and the strongest single thing in the round. It
extracts the archive that was just built and re-derives the figures from those bytes:

1. the archive is exactly `shipped()` — no more, no fewer
2. `counted()` over the archive equals the receipt's figure
3. no NUL in any of them, scanned again from the archive
4. the archive's own `measurements.json` is byte-identical to the one being bound

Each of those four failed somewhere in W.1.4.1.

**`text_assets` → `source_text_assets`.** Renamed because the old name did not say which set. The
old noun is deliberately left unguarded: it now refers only to a superseded universe, which is why
this document may quote what W.1.4.1 measured.

**Receipt is `release-receipt@2`** — adds `files` and `artifact_replay: "reproduced"`. Reaching that
line means the archive was extracted and its figures re-derived from it.

---

## 4 · `tools/sabotage-scope.sh` — the new law, falsified

Your item 3, widened. Seven cases, each naming the sentence the gate has to produce, run against a
scratch tree the harness owns, exercising the shipped code paths:

```
a stray sibling receipt does not move the figure          the W.1.4.1 defect itself
a NUL in the shipped C source                             invisible to the old gate
a NUL in the shipped preview JSON                         invisible to the old gate
a file the scope declaration does not classify            refused at packaging
a file added between measurement and packaging            replay refuses
a measurements.json edited after packaging                replay refuses
a clean tree packages and replays                         a gate that refuses everything is not one
```

**One case was wrong on the first run and the tool was right.** I originally added the late file
*after* packaging and expected a refusal. It did not come, correctly: an archive built at T2 is not
wrong about a file that appeared at T3, and the release is the archive. The real defect shape is a
file arriving *between* the gate and the packager — in the archive, not in the figures — which is
W.1.4.1 pointed the other way. That case now passes for the right reason.

**And the hygiene gate caught me while I was widening it.** Writing the file that forbids literal
NULs, I put one in the comment that forbids them. The gate named the file, the line, the byte count
and the fix on its first run. Unplanned, and better evidence than a probe.

---

## 5 · The BEAM battery is in the chain, and it needed a fix to get there

Taking your first option. `ampd/tools/sabotage.sh` refuses in `release.sh` exactly as `mix` and
`cargo` do; `tools/preview-release.sh` remains the degraded path that cannot package. Your argument
is the one that decided it: this round is the proof that `release.sh green ≠ falsifiers green`, and
the only evidence the falsifiers had run was a sentence in a brief — for the single property that
separated the bad W.1.4 from the good W.1.4.1.

**Putting it in the chain naively would have created a fresh drift defect.** `ampd/tools/sabotage.sh`
and `tools/sabotage-host.sh` printed **byte-identical** summary lines, and `emit-measurements.mjs`
reads figures out of the release log by regex. The first battery to print would have been recorded
under the other's name. `bot`, `guard` and `count` sabotage were already prefixed; these two were
the only ones nobody had needed to tell apart. They are `beam sabotage:` and `host sabotage:` now,
and `beam_falsifiers` is bound to the artifact like every other figure — which is your option 2,
obtained for free by taking option 1.

---

## 6 · Where I did not do what you asked, and why

**You asked to move the `rm -f` above the measurement gates. I excluded the files from the scope
instead, and left the `rm` late.**

Two reasons. The ordering fix repairs the instance and keeps the class: a sibling receipt can arrive
by other routes — a hand-run probe, an interrupted round, a copy made to compare two revisions — and
would move the figure again. And a release that fails at stage 12 would have destroyed the last good
artifact on its way to failing.

With the exclusion in place the ordering is irrelevant to every measurement, and case 1 of
`sabotage-scope.sh` proves it: a stray receipt planted in the tree does not move the count. The `rm`
stays where a failed release leaves the previous artifact intact.

**On your preference for replay over more exclusions — agreed, and the replay is why the exclusions
are safe.** Two walkers reading one declaration *probably* enumerate the same files. That is exactly
what was true of the old pair, right up until it wasn't.

---

## 7 · Still open

**`ampd/erl_crash.dump` is still in the working tree.** It is excluded from the archive now and
gitignored, so it cannot ship, but I have not deleted it — it is yours to remove, and nothing
depends on it.

**The archive is not byte-reproducible.** ZIP entries carry mtimes, so packaging the same tree twice
produces different bytes. The receipt binds what was built, which is sound, but "same tree → same
hash" is not a property this pipeline has. Out of scope for this round; worth naming before someone
assumes it.

**Neither the replay nor the packager is falsified against a *corrupt* archive** — a truncated or
tampered ZIP. Every case in `sabotage-scope.sh` operates on well-formed archives.

---

## 8 · Sequencing

Unchanged from yours, and this round is closed as you scoped it:

```
W.1.4.1   at-most-once semantics                     accepted, untouched
W.1.4.2   artifact/measurement closure               this
W.2       Tauri LIVE LOCAL                            next
```

No further runtime design round. §4 is closed by the shipped runtime and I did not reopen it.

The separate research brief in the bundle (`MOTOR_MACHINE_RESEARCH_BRIEF_FOR_OPUS.md`) is a design
lane for *after* the desktop foundation, not a proposal to interrupt W.2. It ships in the archive
because it is in the tree, not because it is part of this round.

---

## 9 · Verify

```
bash tools/sabotage-scope.sh                    # the new law, falsified
bash tools/release.sh                           # every gate, now including the BEAM falsifiers
```

To reproduce the original defect against the predecessor artifact:

```
mkdir w141 && cd w141 && unzip -q ../and-super-rev-w141.zip
node tools/check-source-hygiene.mjs             # the old gate, on the old bytes
cp ../and-super-rev-w141.receipt.json ./and-super-rev-w14.receipt.json
node tools/check-source-hygiene.mjs             # one higher, and the archive has not changed
```

To watch the replay refuse, package and then add a text file to the tree before running it:

```
node tools/package.mjs and-super-rev-probe.zip
printf 'x\n' > docs/late.md
node tools/replay-artifact.mjs and-super-rev-probe.zip
```

It names the figure, both values, and which one the hash is bound to.
