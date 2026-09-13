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
cleanly is refused, not repaired); preflight; and only if downgradable, write
in three phases that the report names:

| phase | what happens | on failure the report says |
|---|---|---|
| `backup` | create `loci.dets.before-downgrade-<utc>` **exclusively** (a name that did not exist — a second run in the same second gets `-1`, never an overwrite), copy the store into it, sync the copy, **then sync the directory so the name is durable** | `mutation_began: false, written: false` — every byte of the world as it was |
| `write` | open read-write, insert, `dets` sync, close, sync the directory | `mutation_began: true, written: false`, the backup path, and `recover`: restore from it before any runtime opens the world |
| `verify` | re-open read-only and compare | `written: true, verified: false` |

`Downgrade.restore/2` (`tools/downgrade-world.sh <world> --restore <backup>`)
puts a backup back the same way: copy, sync the file, sync the directory, read
back. The audit's two findings — the backup's directory entry was not synced
before the store changed, and a failure after the mutation began reported
`written: false` as if nothing had changed — are both closed by this shape.

Falsified before trusted, all of it. `fail_at:` is failure injection at each
boundary (`after_backup_created`, `after_backup_copied`, `after_backup_synced`,
`after_backup_durable`, `after_open`, `after_insert`, `after_sync`,
`after_close`, `before_verify`): the five before the mutation leave the store
byte-identical and say so; the four after it say the mutation began, the backup
equals the original store, `restore/2` brings the state back exactly, and the
next run converts under a *new* backup name. `trace:` pins the **order** of
durability calls — copy, sync the copy, sync the directory, and only then open
the store read-write — which no inspection of the disk afterwards can show.
Sabotage confirmed each: removing the pre-mutation directory sync fails the
order test; overwriting instead of exclusive create fails five; reporting a
post-mutation failure as untouched fails four. `ampd/test/downgrade_test.exs`,
21 tests. A real `kill -9` inside the write was not performed; the injection
returns where the real step would fail, with the same bytes on disk up to
that point.

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

## The large-file workflow, finished through the page — 2026-09-12 (round 3)

Item 6 above said the page could not produce a large member. Every limit on
the path was traced and moved to **one number per layer**, named where it is
enforced, rather than raised where it happened to bite:

| layer | where | was | now | why this number |
|---|---|---|---|---|
| page: Editor → bot (related files, Discuss route, file picker, plan context, conversation store) | `cockpit/ui/review-limits.js` `REVIEW_FILE_BYTES` | 24 000 / 32 000 | **256 KiB** | larger than any file in this tree (cockpit.js is 73 KB); a provider prompt of four such files is 1 MiB |
| page: a bot's proposed file | `file-proposal.js` | 32 000 | 256 KiB | the same number |
| host: attachment read, plan-linked file basis | `attachments.rs::REVIEW_FILE_BYTES`, `workbench.rs::file_basis` | 32 000 / 24 000 | 256 KiB | the same number, in Rust |
| host: provider bridge | `bots.rs` — per attachment, total per message, reply body | 32 000 / 256 000 / 1 MiB | 256 KiB / 1 MiB / **4 MiB** | twelve proposals of 256 KiB, escaped, fit one reply |
| publishing | `put_review_content` chunk `{:string, 92_000}`; page `CHUNK` 64 KiB | — | unchanged | 64 KiB decoded is 87 384 base64 chars, inside the field; the frame is 256 KiB |
| runtime store | `Ampd.ReviewContent.file_bytes/0` | 4 MiB | unchanged | the store's limit, not the page's |
| the runner and the accepted build | `tools/lib/proposal-test-runner.mjs` `MEMBER_BYTES`; `tools/proposal-test-runner.mjs` record cap | 24 000 / 32 000; 64 KiB record | **4 MiB** per member; 64 MiB record | the runner checks what the runtime recorded, and a resolved record carries its bodies |
| a **single-file** inline review | `record_development_attempt` in `CommandSpec` | 24 000 / 32 000 | **unchanged** | inline bodies live in the 64 KiB `loci` directory; a large file is reviewable as a member of a combined review, published by digest |

Twelve numbers, one per edge, and a JavaScript suite (`tools/review-limits-test.mjs`)
that holds each page edge at exactly the limit and one byte over. The Rust
tests that pinned the old numbers moved with them (76 passed).

**Not a transport this page controls:** a provider's context window. Four
files of 256 KiB is about a quarter of a million tokens; a model that cannot
take them says so as a provider error, which the page already surfaces.

**Found on the way, fixed in round 4 below:** after a restart, a saved
combined review had no apply control — the transcript restores none (by
design, since 2fc6bdc) and the plan page offered none — so the person asked
the bot again and staged the re-issued proposal; the record and its
acceptance were the original. The large-file smoke still does exactly that,
as the record of the gap. And the runner refuses to start until the plan's
repository is chosen in the Editor again (*"Choose the plan's repository in
Editor first."*), which is the native chooser: a restart fact a person meets,
and one the saved-review action shares by design.

`tools/large-file-review-smoke.mjs` is the demonstration: the real
`cockpit/ui/cockpit.js` (73 KB) copied into a disposable repository, attached
from the Editor by the page's own related-files control, proposed back by the
provider fixture with one changed line, reviewed in the combined dialog,
recorded by digest — two publish chunks, and the record itself under 8 KB —
reopened after an actual process restart, tested to a pass, applied, accepted,
and built by the accepted-build runner into an executable that prints both
accepted files. No record is injected and no validation is bypassed. Results
are in the verification section.

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

## Verification, 2026-09-12 — round 3 (durability, the large file, the old cockpit)

Reported apart again.

**Runtime and host tests.** ampd **843 tests · 0 failures** (12 new: nine
failure-injection and ordering cases for the writer, backup naming, restore;
the whole `downgrade_test.exs` is 21). cockpit (Rust) **76 passed · 0
failed · 1 ignored**, with the three cap tests moved to the new limit and
holding exactly the limit as accepted. **24 JavaScript suites pass** (one
new, `review-limits-test.mjs`). `tools/gates.sh` **8 held**. Formatting
checked.

**Through the actual UI**, one smoke at a time:

| smoke | held |
|---|---|
| `large-file-review-smoke` — the real cockpit.js attached from the Editor, proposed back, recorded by digest in two chunks, restarted, repository re-chosen, tested, re-proposed, applied, accepted, built, previewed | **56** |
| `old-cockpit-downgrade-smoke` — this cockpit records by digest; `downgrade-world.sh` converts under the lock; the cockpit built from `cf3931f` opens the world, shows both retained files, runs its tests to a pass, refuses acceptance until the files are saved, accepts | **27** |
| the seven smokes of round 2, on the final page code, one at a time | change-set 31 · apply 31 · deletion 38 · crash 34 · acceptance 40 · combined 52 · review-content 32 |

Run back-to-back on one port, two of the seven failed once each — the apply
smoke's provider connect never enabled, and a combined build "ended without a
complete result" with an empty error file — and both passed when run alone
straight after. Neither reproduced; both are recorded here rather than
smoothed over.

**Under the old runtime**, this time its cockpit too: phase 3 above is the
old binary and the old `ampd`, driven through their own page, against a
world this runtime wrote and the tool converted. Applying the files in that
phase is the smoke writing them (see the note on restart facts).

**Not done, still.** No `kill -9` inside the write itself (injection returns
where the step would fail, with the same bytes on disk to that point); no
physical power loss; no non-Linux filesystem; no live phone; a single-file
inline review is still capped at 24 000 / 32 000 (a large file is reviewed
as a member of a combined review); the four stray blobs stay where they are.

Nothing here has been merged into the shared checkout, built there, or
restarted; production data, phone sessions and held proposals were not
touched.

## Round 4 — a saved review is staged again from its own bytes, not asked for again (2026-09-13)

Round 3 recorded a product gap: after a restart the transcript restores no
apply control and the plan page offered none, so the person asked the bot
again and staged the *re-issued* proposal. The reviewed bytes were already on
the plan. Regenerating them costs a provider call and can return a different
proposal — the record and its acceptance would then describe one thing and the
files another.

**What was built.** A plan-page action on a saved combined review, *Stage saved
review in Editor* (`development-tasks.js` → `stage-saved-review` event →
`development.js`), and a pure module `cockpit/ui/saved-review.js` that turns
the record into the items the existing combined-review dialog accepts. The
dialog (`file-proposal-set-review.js`), its *Stage all drafts*, and the Editor's
*Apply staged change set* are then the same controls, running the same checks,
as for a proposal that arrived a moment ago — the dialog is headed *Saved review
da_NNNN · N files* and offers no second save. No new host command, no new
intent: bodies are read through the `review_content` host command that
already existed, and the write stays behind the apply control.

What the action does, in order, and what it refuses by name:

| step | refusal |
|---|---|
| the record: a combined review, open (not accepted/dismissed), on the plan's current revision, plan not cancelled/completed, 2–4 members with complete bases | *"Review da_0007 was recorded against plan revision 2; the plan is at revision 3"*, … |
| the Editor: a repository chosen and the plan linked (Prepare file request → Open repository, the native chooser); no review or change set already open | *"Choose the plan's repository in Editor first"* |
| every body, read back through the host (which re-hashes and tells missing from corrupt) **and re-hashed in the page** against the digest the record names; an inline record supplies its own bodies and is checked the same way | *"cockpit.js: This file's reviewed content is no longer stored"*, *"… no longer matches its digest"* |
| every file **as the disk holds it now**, never as an open tab remembers it: hash equals the recorded `disk_sha256`; a new-file member must still be absent; a reviewed file must still exist | *"cockpit.js changed on disk since it was reviewed (now 1a2b…, reviewed at 3c4d…)"*, *"… was reviewed as a new file but now exists"*, *"… no longer exists"* |
| an open tab with its own unsaved edit that is not the review's shared draft | *"cockpit.js has unsaved edits in the Editor. Save or reload it"* |
| then, and only then: a tab per file showing the review's shared draft, the dialog over the record's bytes; *Stage all drafts* re-runs `verifyPlan` (`match_plan` + `file_basis`) per file and yields unsaved drafts; *Apply staged change set* re-verifies every basis again and writes atomically through `apply_set` | the existing refusals |

Half a set is never staged: any refusal is for the whole review, before a tab
changes. Retained content restores no permission to write — staging produces
drafts, and the apply control is what a person presses to write.

**Found by driving the real UI, again.** Two defects, neither visible to the
unit suite:

1. **A recovered tab's `original` is not the disk.** The first cut of the
   handler took an open tab's `original` as the file's current bytes. After a
   restart the Editor's recovery restored the cockpit.js tab with the bytes it
   last saw, the file had been changed on disk, and the dialog opened over it
   — the apply-time `file_basis` would still have refused the write, but the
   refusal this action exists to give never came. Every member is now read
   from disk; a clean tab follows the disk, a dirty one keeps its draft for the
   conflict check.
2. **`node --check` is not a parse.** The dialog function already declared
   `let saved=false` for its own save flag; a new parameter named `saved`
   shadowing it is a SyntaxError in every engine. `node --check` passed
   (V8's lazy pre-parser does not check function bodies), the built page
   failed to evaluate, and the cockpit sat at the static *Connecting to your
   local runtime…* with a runtime that had in fact started — indistinguishable
   from a runtime fault until a WebDriver `import('./x.js')` from inside the
   page named the error. `node -e "import('./x.js')"` is the check; the
   modules that touch `window` fail with a ReferenceError, which is the
   distinction that matters.

**Verification.** Unit: `tools/saved-review-test.mjs` **11 · 0**, falsified three
ways (the disk-changed check, the page re-hash, the accepted/dismissed refusal
each removed → 1, 2 and 1 tests red); **26 JavaScript suites pass**
(`cockpit-control-check.mjs`, then still named `-test`, fails when a smoke holds
its port and passes alone — coordination, not the app). `tools/gates.sh` **8 held** (ACL 35,
intent surface 6). Runtime and Rust suites were not changed and not rerun.

Through the actual UI, `tools/saved-review-resume-smoke.mjs` alone on the
final binary: **45 held** — propose → record by digest → kill → restart →
refused with no repository → repository chosen → required check fails then
passes → acceptance refused unsaved → refused missing → refused corrupt →
refused changed on disk → refused unsaved Editor edit → staged from the
record (dialog headed *Saved review da_0007 · 2 files*, no save control) →
record unchanged → apply refused over a changed file → applied together, no
journal → accepted with the original identity, files and passing run →
fixture build. The provider fixture counted **0 calls after the restart**.
`tools/large-file-review-smoke.mjs` re-run on the final binary (with the
promoted files): **56 held**, unchanged — it still records the bot-asked-again
path, as the record of the gap this round closed. Its first three runs each
stopped on something real: the page that never
evaluated (defect 2), the recovered tab (defect 1), and twice an assertion of
mine that asked the coarse diff summary for a line it is bounded not to show
(600 rows of a 2,176-line file are all removals) — the summary shows
`- // color: red`, the columns show both lines, and the apply step proves the
staged bytes on disk.

**The isolated self-build cycle — the actual application, not the fixture
crate.** `tools/super-self-build-dogfood.mjs`, on the final code, **16 held**:
a fresh `git clone` of this tree at `95a8bc4` in a disposable world
(`self-build-fixture`), one registered repository (the clone), a plan
requiring the JavaScript profile; the provider fixture (not ChatGPT) proposed
two Super files — `cockpit/ui/task-progress.js` (the next action for a
tested review now names the saved-review path) and `tools/task-progress-test.mjs`
(a test that asserts it); recorded by digest at the clone's HEAD, nothing in
the clone changed; killed and restarted; refused without a repository; the
clone chosen again; **Super's own 24 suites, the new assertion included,
passed in the runner's sandbox**; the saved review staged from its recorded
bytes with **no provider call after the restart** (one call in the whole
cycle); one apply wrote both files; acceptance bound them to the passing
snapshot `8d32e7ce…`; *Build accepted app* ran the real
`super-cockpit-release@1` profile — cargo, `--offline --locked --release`,
two jobs, in bwrap — in **358 s** and produced a **20,368,632-byte ELF**,
sha256 `5acedc3c…`, **byte-identical to the previous run's build** from a
snapshot that differed only in a tools file; the build's captured snapshot
carries the accepted files exactly; the artifact was then launched as a
cockpit of its own, in a third disposable world with its runtime from the
snapshot, served frames, and its own page — asked through `import()` —
exported the saved-review module and produced the accepted wording. The two
accepted files were then copied from that snapshot into this branch, checked
against the build manifest (`1551757`).

Three things the cycle found, all reported apart from the application:

- **Super's required JavaScript check could not pass on Super's own tree from
  f7e6209 (2026-09-11) to c3b7578 (2026-09-13).** The profile runs every
  `tools/*-test.mjs` of the snapshot in the sandbox — no display, no driver —
  and `cockpit-control-test.mjs` drove a real cockpit under that name: 137 of
  138 assertions, one `not ok`. The 2026-09-10 real-provider cycle passed
  because the file did not exist yet. Renamed `cockpit-control-check.mjs`
  (application finding; it still passes alone, 10 held).
- The cycle's own assertions were wrong three times (coordination, not the
  app): it expected a repository record to carry a name (that projection
  change is a held proposal); it hand-typed a suite count (now derived from
  the clone); and it asked `strings` for page text that Tauri embeds
  compressed — the tree's own binary has none either. The launched artifact
  is the instrument.
- Its Editor tree walk looked for the next folder before the asynchronous
  listing rendered and pressed *Up* at the root for forty minutes; the walk
  now waits for the folder header. Two earlier runs had passed that step by
  timing.

Evidence: `~/build/smoke-selfbuild.log`, the summary at
`~/build/smoke-root/super-self-build-NlQNxD/self-build-summary.json`,
screenshots under `~/build/smoke-root/shots-selfbuild/`, the failed runs'
artifacts retained under `~/build/smoke-root/`.

**Not done.** A single-file inline review is not resumed this way (its text is
on the plan and its dialog is the single-file one); the self-build cycle used
the provider fixture, not ChatGPT; no physical power loss; no non-Linux
filesystem; no live phone; nothing merged, built in the shared checkout, or
restarted; the four stray blobs stay where they are.
