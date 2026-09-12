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
| `Ampd.Projection` | publishes every member **without its bodies**, plus a `review-content-ref@1` saying where each side is and what state it is in. Applies to inline records too. |
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
| crash / restart with partials on disk | `ReviewContent.recover/0` discards every `.partial` — it cannot be verified and the uploader that knew its offset is gone — and reports how many and how many bytes. **Published blobs are never touched.** |
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

The overflow is fixed for existing records the moment the projection stops
publishing bodies — which it now does for inline members too. Inline members
remain valid, readable, testable and acceptable, bounded by the caps that shape
needs. No existing record has to move.

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

## Rolling back — settled, tested, and not free

**Reverting the code is not a rollback.** An older runtime publishes a staged
record with no bodies, and its UI, test runner and acceptance check all read
`nil` where the reviewed text should be: the record is present and unusable,
which is worse than either working or being absent. Verified against `main`'s
own `set_file?/1`, which requires exactly `shared_draft`, `proposed_text` and
`source` on every member.

So a rollback is a **conversion first, then the revert**:

    1. Quiesce the world (stop the desktop), so nothing records during it.
    2. Ampd.DevelopmentAttempt.inline_from_content/1 puts the bodies back.
       Reports {"converted" => n, "blocked" => [...], "downgradable" => bool}.
    3. Only if "downgradable" is true: revert the merge, rebuild, restart.
    4. If it is false, do NOT downgrade. Each block names the attempt, the
       path, the side and the reason.

`inline_from_content/1` performs filesystem I/O — it reads every referenced
blob — and converts **a record whole or not at all**. Two reasons a member
blocks:

| reason | meaning | what to do |
|---|---|---|
| `missing` / `corrupt` | there is nothing to put back | stage it again, then retry the conversion |
| `too-large` | the member exceeds the old inline caps (24 000 current, 32 000 proposed) | **it cannot be downgraded.** Export the record, or keep the new runtime. |

**The second row is not a defect, and it will be the common one.** The files
this change exists to make reviewable — `cockpit.js` at 72 809 bytes,
`cockpit.css` at 35 044, `projection.ex` at 34 282 — are exactly the ones the
old shape has no way to hold. A world that has reviewed any of them has no
downgrade path that preserves that review, and the honest procedure says so
before the deployment rather than after it.

Published blobs are inert to a revert: an older runtime never looks in
`review-content/`, and `collect/2` on the old code does not exist, so nothing
removes them. Leaving them in place is what makes a re-upgrade cheap.

Tested: `ROLLBACK:` cases in `ampd/test/review_content_record_test.exs` cover a
staged record converting to the exact shape the old runtime requires and
round-tripping back; a record the caps cannot represent, blocked and named; a
record whose content is gone, reported rather than inlined as empty; and an
already-inline record, reported downgradable with nothing done.



Nothing here has been merged, built into the shared checkout, or restarted.

## Isolated audit follow-up verification — 2026-09-12

813 runtime tests, 0 failures; 42 focused tests (five new); 10 publishing/reading
JavaScript tests; 8 gates held, 0 failed, 0 could not run. Warnings-as-errors
compilation and changed-file formatting passed. The gates used the unchanged
baseline cockpit binary copied into the isolated tree; Rust was not rebuilt.
No merge or restart occurred. Physical power-loss, non-Linux qualification,
downgrade after staged writes, and live phone acceptance were not tested.
