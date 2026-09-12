# Staged review content — implementation, recovery and deployment

**Status: original implementation plus isolated audit corrections, NOT deployed.** The design and the comparison it
came from are in `REVIEW_CONTENT_LIMITS_2026_09_12.md`. This is what was built,
how it recovers, and exactly what deploying it would do.

## The correction that shaped it

An earlier draft called this store a cache and said losing it was "a cache
miss". That was wrong. A digest *identifies* content; it cannot reconstitute it.
If the bytes behind a recorded attempt are gone, the review cannot be read, the
test cannot run and the result cannot be accepted — so this is **durable review
material with retention rules**, and its absence is a named, blocking state
rather than a silent fallback.

It is still not an **authority** store. `Ampd.World.authority_stores/0` holds
the stores whose absence is indistinguishable from an order nobody gave;
absence here is distinguishable and *refuses*. So it adds no seal and no way for
a world to fail to open — and it is not exempt from backup.

## Correction to the overflow rationale

The original handoff claimed two maximal recorded reviews make the shipped
world unviewable. Its test encodes synthetic maps without recording them.
Both main (`ecd545f`) and this branch enforce a **64 KiB aggregate attempt
admission limit**, including encoded size and test-result reservations, in
`DevelopmentAttempt.persist`. A real capacity probe was refused with
`attempt-directory-full` before fifty twelve-member reviews could be stored.
The synthetic test therefore does not establish the claimed reachable failure.
Large-file submission limits remain real and staging still addresses them.
The fifty-attempt count is an upper bound, not a promise that every legal shape
fits fifty times. Do not remove the aggregate guard based on the synthetic test.

## What was built

| | |
|---|---|
| `Ampd.ReviewContent` | content addressed by SHA-256. Chunked publication, **fsync per chunk**, hashed and checked to be UTF-8 text before rename, re-hashed on read. Bounds per chunk (64 KiB), per file (4 MiB) and per store (256 MiB). `recover/0`, `referenced/1`, `collect/2`, `report/1`, `absorb/1`. |
| `put_review_content` | a human-control mutation, base64 chunks, **outside the ordered transaction** — writing and fsyncing a file inside the coordinator is the unbounded round trip `check-dispatch-partition.mjs` refuses. |
| `review_content` (host) | reading a body back. **Not an intent**: `check-intent-surface.mjs` refuses a read on the intent surface. Digest validated as 64 hex *before* being joined to a path; granted to webview `main` alone. |
| `Ampd.DevelopmentAttempt` | members may be **staged** (`%{"source" => …}` alone) or **inline** (legacy, unchanged). Four distinct refusals. Testing and acceptance refuse when content is not available. |
| `Ampd.Projection` | publishes every **staged** member without its bodies, plus a `review-content-ref@1` saying where each side is and what state it is in. **Inline members keep their bodies** (corrected 2026-09-12, see below): their bytes live in the record and nowhere else, and the store's 64 KiB admission bounds them. |
| `cockpit/src/review_tests.rs` | `resolve_review_bodies` puts the reviewed bytes back, **re-hashed**, before the test runner or the acceptance check sees them. Missing or corrupt fails the operation. |
| `cockpit/ui/review-content.js` | `stageContent` / `readContent`. Called from `file-proposal-set.js` while saving a combined review — a step inside submitting, never an operation the page offers on its own. |

### Why a member needs no new fields

`source.draft_sha256` is already the current text's content address and
`source.result_sha256` the proposed text's. A staged member is therefore its
`source` alone: **a member cannot name one thing and carry another**, because
there is only one place the address is written.

## The four refusals, kept apart

| code | when | carries |
|---|---|---|
| `review-file-count` | fewer than 2 or more than 12 members | the count and the bounds |
| `review-file-too-large` | one side of one file over its cap | path, side, size, cap |
| `review-set-too-large` | the members together over the set cap | total, cap |
| `review-content-invalid` | not text, a bad digest, a size that disagrees, a basis that does not bind its content | path, side |
| `review-content-unavailable` | content missing or corrupt at record, test or acceptance | path, side, digest, which state |

None carries file content back to the caller; a test asserts a secret in a
refused file does not appear in its refusal.

## Durability, exactly as far as it goes

Publication is: append, **fsync each chunk**, hash what was written, check it is
text, rename into `blobs/`.

**Correction, 2026-09-12:** the prior claim that Erlang cannot open a directory
was false. The documented `:directory` option works: on this Linux host with
OTP 28, `:file.open(path, [:read, :raw, :directory])` followed by `:file.sync/1`
returns `:ok`. See [Erlang file documentation](https://www.erlang.org/docs/25/man/file.html)
and [Linux fsync documentation](https://man7.org/linux/man-pages/man2/fsync.2.html).

The follow-up syncs `blobs/`, `staging/`, `review-content/`, and the existing
world directory before publication returns success. Re-publication verifies
existing bytes and re-establishes file and directory sync before acknowledging
them. Failed sync or directory creation returns `review-content-storage-error`.
Corrupt existing bytes return `review-content-unavailable`, never success.
This relies on the world's existing directory having been durably established.
No physical power-loss experiment or non-Linux filesystem validation was run.

Submission retry starts at zero. The store now accepts a repeated range only
when it exactly matches the staged bytes, without appending them twice. A
changed range still refuses. This makes the page's retry behavior usable after
a lost response or interrupted submission.

## Recovery

| event | what happens |
|---|---|
| upload interrupted mid-file | the `.partial` stays; the same submission resumes from the offset the store reports. A mismatched offset is refused, never sought. |
| crash / restart with partials on disk | `ReviewContent.recover/0`, called from `Ampd.Application.start/2` as the world opens (it had no caller until 2026-09-12), discards every `.partial` — it cannot be verified and the uploader that knew its offset is gone — and reports how many and how many bytes. **Published blobs are never touched.** |
| a blob is deleted | `status/1` → `:missing`. The projection says `missing` for that side, the plan page says so instead of rendering blank, and testing and acceptance refuse. |
| a blob is edited | `verify/1` → `:corrupt`, separately from missing, because they call for different actions. The host re-hashes before any runner sees a byte. |
| the whole directory is lost | every referenced digest reports `missing`; nothing is accepted; records are intact and can be re-staged from source. |

## Retention, collection and backup

* Content referenced by a recorded attempt is retained for as long as that
  attempt exists.
* `collect/2` removes **only** blobs nothing references **and** older than
  `grace_ms/0` (1 hour). The grace period is not politeness: content is
  published a moment before the record that names it, and a collector without
  one would delete the upload in flight.
* An inline member references nothing — it carries its bytes — so it does not
  keep unrelated content alive.
* **Backup must include `ReviewContent.paths/0`** (`<world>/review-content/blobs`).
  A backup that takes only `*.dets` takes the attempts and not the material they
  are about.

## Migration of existing inline attempts

**Compatibility is the strategy; migration is optional and not wired.**

Inline members remain valid, readable, testable and acceptable, bounded by
the caps that shape needs and by the store's 64 KiB admission, and their bodies
still travel in the projection (there is nowhere else to read them from). No
existing record has to move.

What migrating buys is the space those bodies take in the `loci` authority
store, which `Ampd.Store.save/2` rewrites whole on every unrelated mutation. It
is a real cost, bounded, and only for records written before staging existed.
So it is provided as two tested functions and **no command**. `absorb/1` performs filesystem I/O; it is not pure:

    1. Ampd.ReviewContent.absorb/1          publishes the inline bodies.
                                             Writes only into the content store,
                                             touches no record, idempotent.
    2. Ampd.DevelopmentAttempt.migrate_inline/1
                                             rewrites members to name their
                                             content — ONLY where both sides are
                                             published and verify. Anything else
                                             is left exactly as it is.

Wiring them is its own proposal, and it can now go through review, because the
mechanism this change adds is what makes a proposal of that size reviewable.

## Original implementation verification (reported before this audit)

    ampd                                    808 tests · 0 failures   (771 before)
    cockpit (Rust)                           76 passed · 0 failed    (71 before)
    14 JavaScript suites                     89 pass · 0 fail
    tools/gates.sh                            8 held · 0 failed

Covered: transport and storage limits at the boundary (exactly at the cap
accepted, one byte over refused by name); oversized rejection for chunk, file
and set; **bounded projections at the supported attempt limit** — fifty recorded
change sets encode inside one frame, where two of the old shape did not;
unauthorized access (agents receive no `development_attempts`, and the command
is refused on the agent channel); interrupted uploads (resume, and recovery
discarding partials while keeping published blobs); missing and corrupt content
at every consumer; stale source (a basis that does not bind its content, members
from different commits, a superseded plan revision); all-or-nothing (a set with
one bad member records nothing, and the same request succeeds whole once the
missing half is published); and acceptance bound to the exact reviewed content.

A change set carrying `cockpit/ui/cockpit.js` — 72 809 bytes, which the old caps
excluded outright — records with a **request under 8 000 bytes**.

## Deploying it — the exact steps, none of which have been taken

    # 1. Merge the branch into the shared checkout.
    cd /home/travis/ProjectAmp2/super
    git merge --no-ff review-content-staging

    # 2. Build. The running desktop keeps its own inode and is unaffected.
    (cd ampd && mix compile --warnings-as-errors && mix test)
    (cd cockpit && cargo build --release && cargo test --release)
    tools/gates.sh

    # 3. Restart the desktop. THIS is the deployment, and it is the step that
    #    costs something: every paired phone session is revoked.
    systemctl --user stop super-desktop
    systemd-run --user --unit=super-desktop --same-dir \
      --setenv=PATH="$HOME/.asdf/shims:<node bin>:/usr/local/bin:/usr/bin:/bin" \
      --setenv=LANG=en_US.UTF-8 --setenv=SUPER_MOBILE_PANEL=1 \
      /home/travis/ProjectAmp2/super/mobile/start-local.sh

    # 4. Re-pair the phone from the panel, or Runtime → Mobile device →
    #    "New pairing code" (no further restart, existing sessions untouched).

## Rolling back — a whole-world procedure, with the old runtime as the judge

**Reverting the code is not a rollback.** An older runtime publishes a staged
record with no bodies, and its UI, test runner and acceptance check all read
`nil` where the reviewed text should be: the record is present and unusable,
which is worse than either working or being absent. Verified against `main`'s
own `set_file?/1`, which requires exactly `shared_draft`, `proposed_text` and
`source` on every member — and verified again below by opening an unconverted
world under the actual old runtime, which fails at the first member.

**A per-record conversion is necessary and not sufficient.** The audit of
`inline_from_content/1` found three gaps, all real:

1. it checked members against the old per-file caps but never the old
   **64 KiB directory** that `persist/2` enforces over the whole collection,
   nor the **4 608-byte reserve** it keeps per unfinished test run — so a
   world whose every record converted could still be one the old runtime would
   refuse at its next mutation with `attempt-directory-full`;
2. it never checked the old **two-to-four member** limit, and this runtime
   admits twelve;
3. it returned converted state in memory and the documented procedure said
   nothing about writing it durably or about proving the old runtime could use
   the result.

All three are closed by `Ampd.Downgrade` and its entry point:

    tools/downgrade-world.sh <world-dir> [--check] [--report <file>]

`Downgrade.preflight/1` converts, then applies the **old runtime's rules,
copied from `cf3931f` rather than imported from the current module** (so a
later relaxation here cannot quietly relax the downgrade check): member count
2..4, the old member shape and caps with the basis binding, at most 50
attempts, and the whole collection encoded plus the reserve inside 64 KiB. It
reports every fault by name — `missing`, `corrupt`, `too-large`, `file-count`,
`shape`, `attempt-limit`, `directory-too-large` — with the attempt, path and
side, and `headroom_bytes`: what the old runtime can still record afterwards.

`Downgrade.run/2` is the durable procedure, in this order and for these
reasons: refuse while `world.lock` is held (the wrapper holds that same
`flock(2)` for the whole run, which is the only way to close the window
between a probe and the write); refuse a manifest this build does not trust;
open `loci.dets` **read-only** under a private table name (a store not closed
cleanly is refused, not repaired); preflight; and only if downgradable, copy
`loci.dets` to `loci.dets.before-downgrade-<utc>` and sync it, write the
converted state, `dets` sync, close, sync the directory, then **re-open and
compare**. A refusal writes nothing: measured byte-identical.

Every rule was falsified before it was trusted: widening the member limit,
the directory budget, the reserve, the lock check and the "write anyway"
branch each turn exactly the tests written for them red
(`ampd/test/downgrade_test.exs`, 9 tests).

### Measured, 2026-09-12 — the old runtime opening the converted world

Two disposable worlds were written **by this runtime** (`tools/downgrade-fixture.exs`,
`MIX_ENV=test` for the reference effector, `AMPD_DATA_DIR` for the location):
two staged sets, one inline set and one single-file attempt; world B also a
staged set carrying a 31 000-byte member.

| | world A | world B |
|---|---|---|
| `downgrade-world.sh` | exit 0 · converted 2 · encoded 38 105 B · headroom 27 431 B · backup taken · read back verified | exit 2 · `too-large` `cockpit/ui/big.js` current 31 000 > 24 000 · `loci.dets` byte-identical before and after |
| old runtime `cf3931f` (`tools/old-runtime-check.exs`) | opens unsealed · 8 members in 4 attempts all carry bodies · projection encodes at 40 581 B with bodies · **three sets taken through `begin_test → finish_test(pass) → prepare_acceptance → accept`, status `accepted`** · single-file `check_text` reads the bodies · the converted members re-submitted are **admitted by the old `set_file?/1`** · directory then 47 312 of 65 536 B | fails at the first staged member: *"no current body — the old runtime reads nil here"* |
| old runtime on the **unconverted** copy of A | fails at the first staged member, the same way | — |

The unconverted run is the negative control: it is GPT's premise made
observable, and it proves the check can fail.

**Headroom is the number to watch.** The first old-runtime run re-recorded a
set *before* the acceptances and was refused `attempt-directory-full` on the
next test start: the old 64 KiB is shared by every review, run and acceptance
the old runtime will ever record after the downgrade. The preflight reports
`headroom_bytes` for that reason.

**What was not done under the old runtime:** its cockpit's own test runner
and page were not driven — the old binary is not built in isolation here. The
old runtime's admission, projection, test-run, acceptance and text-check
paths were exercised through its own modules.

### Two things the wrapper adds, and one it never does

It creates `world.lock` if no host has ever opened the world (a fixture world;
a real one always has it), and it leaves the backup beside the store. It never
creates a manifest, never repairs a store, and never writes on a refusal.

## Found by driving the real UI — 2026-09-12

The runtime suite was green at every step above and none of this was visible
in it. Each item was found by the cockpit, under `tauri-driver`, in a
disposable saved world.

1. **No change set could be saved from the page at all.** `put_review_content`
   declared `offset` as `{:count, 4_194_304}`, and a count refuses zero — the
   offset of the first chunk of every file. The page's very first publish was
   refused `invalid-command-arguments`, the dialog read *"The runtime did not
   confirm review content for …"*, and nothing was recorded. The runtime tests
   called `ReviewContent.put/4` directly and never went through the command.
   Fixed with an `{:offset, max}` type that admits zero, and a test that
   publishes through `Control.command/3` at offset 0 and at a chunk boundary —
   red against the count type, green against the offset type.
2. **Inline records had become unreadable in the page.** The projection
   dropped bodies from inline members too, but an inline member's bytes are in
   the record, not in the content store, so `review_content` answered
   `missing` for content that was right there — every single-file attempt and
   every record written before staging. Inline members keep their bodies in
   the projection again; they are bounded by the store's 64 KiB admission, and
   the frame overflow the stripping was written against was retracted at
   `cf3931f`. Staged members are still published without bodies.
3. **The Rust unit tests wrote into the user's real world.** `review_tests.rs`
   published its fixtures through `worker::world_dir()`, which under
   `cargo test` resolves to `~/.local/state/super/worlds/default`. Four test
   strings (`current text`, `proposed text`, `tampered bytes`, `about to be
   deleted`) were found in that world's `review-content/blobs` at 14:32 on
   2026-09-12. The resolver now takes its blob directory as a parameter and
   the tests use a per-test temporary directory. The four stray blobs were
   **left in place** — they are inert to the running runtime and are for
   Travis to remove; nothing here touches the real world.
4. **Two smokes clicked an unscoped record link** (`development-acceptance`,
   `development-crash`: *element not interactable*), the same selector the
   change-set smoke scopes to `[data-screen=record]`. Scoped the same way.
   Whether they passed on `main` was not established.
5. **Every smoke that asserted file bodies from the projection** now reads
   them back through the `review_content` host command — what a person
   opening the review sees, not a field the frame stopped carrying.

6. **The page cannot produce a large member at all — the headline case has
   no UI route yet.** The runtime records members up to 4 MiB (the cockpit.js
   case in `review_content_record_test`), but the page's own limits are the
   old caps: `related-files.js` and the Editor's Discuss route refuse to hand
   a bot a file over 24 000 bytes, and `file-proposal.js` refuses a bot's
   proposed file over 32 000 (*"The file proposal is invalid or too large."*,
   measured with a 34 KB proposal). So through the cockpit a review member is
   still at most 24 000 / 32 000 bytes, and reviewing `cockpit.js` in Super
   still needs a page route for large attachments and large proposals. Not
   changed here — those are prompt-size decisions, not storage ones — and
   recorded so the headline is not overclaimed. What staging buys through the
   page today is the frame: fifty reviews of the page's maximum size fit,
   where two of the old shape did not.

7. **A staged set could be tested and accepted, and then not built.** Only
   the test start and the acceptance check resolved bodies; the accepted
   build, the preview launch and the accepted-source verification passed the
   store record straight through, so the runner's shape assertion failed with
   *"Review text exceeds its bounds."* — reporting a body that was never
   resolved as a size fault. The old runtime's combined smoke passes this step
   (52 held); the branch's stopped at 35. Every consumer now goes through
   `resolve_review_bodies`.

8. **Crash recovery was documented and never wired.** `ReviewContent.recover/0`
   — "run when a world opens" — had no caller, so an actual process restart
   left the interrupted `.partial` in place (the smoke's restart step found
   it). It now runs in `Ampd.Application.start/2` as the world opens, and a
   test restarts the application and asserts the partial is gone and every
   published blob kept — red with the call removed, green with it.

`tools/review-content-ui-smoke.mjs` is the cycle GPT asked for, through the
actual cockpit: a change set at the largest sizes the page allows (20 KB
current, 28 KB proposed — see 6), recorded by digest; both bodies read back
byte-for-byte; the plan page and the test runner refusing when the
proposed blob is deleted (*no longer stored*) and, separately, when it is
tampered (*no longer matches its digest*), with no run recorded; the same
review testing to a pass once the bytes are restored; and an actual process
restart that discards a `.partial` upload, keeps every published blob, and
reopens the record with its content readable and its passing run intact.

## Isolated audit follow-up verification — 2026-09-12

813 runtime tests, 0 failures; 42 focused tests (five new); 10 publishing/reading
JavaScript tests; 8 gates held, 0 failed, 0 could not run. Warnings-as-errors
compilation and changed-file formatting passed. The gates used the unchanged
baseline cockpit binary copied into the isolated tree; Rust was not rebuilt.
No merge or restart occurred. Physical power-loss, non-Linux qualification,
downgrade after staged writes, and live phone acceptance were not tested.

## Verification, 2026-09-12 — rollback settled and the UI cycle driven

Reported apart, as asked: unit tests, the UI, and the old runtime.

**Runtime and host tests.** ampd **831 tests · 0 failures** (821 before this
round; the new ones: 9 for `Ampd.Downgrade`, 1 command-path publish at offset
0, 1 application-restart recovery — each falsified before it was trusted).
cockpit (Rust) **76 passed · 0 failed · 1 ignored**; the PTY test
`interactive_shells_have_separate_outputs_resize_and_interrupt` fails under
load (three cockpits or a concurrent `cargo test` on the machine) and passes
alone — twice. `tools/gates.sh` **8 held · 0 failed · 0 could not run**.
Formatting checked on every changed Elixir file.

**Through the actual UI**, `tauri-driver` + WebKitWebDriver under Xvfb, each
smoke alone on the final binary and source (they are load-sensitive: run
concurrently, the native chooser helper misses its dialog and the page shows
"Reconnect"):

| smoke | held |
|---|---|
| `development-change-set-smoke` — propose → submit → reopen → restart | 31 |
| `change-set-apply-smoke` — apply | 31 |
| `deletion-review-smoke` — a deletion member, by digest | 38 |
| `development-crash-smoke` — crash recovery | 34 |
| `development-acceptance-smoke` — test → accept, real restart | 40 |
| `combined-testing-smoke` — test → apply → accept → accepted build | 52 |
| `review-content-ui-smoke` — largest page-allowed files by digest; missing and corrupt refused; restored passes; restart discards the partial | 32 |

The same smokes on the first binary of this round: `development-change-set`
could not save a review at all (item 1), `combined-testing` stopped at 35
(item 7), and the restart step of `review-content-ui` failed (item 8).

**Under the old runtime** (`cf3931f`, its own modules, `MIX_ENV=test
AMPD_DATA_DIR=<world>`): see the table under *Rolling back* — the converted
world opens unsealed, every body present, three sets accepted through its own
test-run and acceptance records, the single-file text check reads bodies, the
converted members are re-admitted by its own `set_file?/1`; the unconverted
copy and the refused world both fail at the first member. Its cockpit was not
driven.

**Not done, still.** No physical power-loss test; no non-Linux filesystem; no
live phone; the old cockpit's own runner was not driven against a converted
world; and the page still cannot produce a member over 24 000 / 32 000 bytes
(item 6), so the cockpit.js case is a runtime fact, not a UI one.

Nothing here has been merged into the shared checkout, built there, or
restarted; the running desktop, the paired phone and the held proposals were
not touched. The four stray test blobs in the real world's
`review-content/blobs` (item 3) were left for Travis.

