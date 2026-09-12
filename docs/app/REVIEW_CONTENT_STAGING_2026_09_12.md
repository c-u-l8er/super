# Staged review content — implementation, recovery and deployment

**Status: complete and tested, NOT deployed.** The design and the comparison it
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

**The parent directory is not fsynced, because Erlang cannot open one** —
`:file.open/2` answers `{:error, :eisdir}` with and without `:raw`. A crash in
the window between the rename and the filesystem committing it can lose the
*name* of a blob whose *bytes* were durable. Two things make that safe rather
than silent: content is published **before** the attempt that references it is
recorded, and a missing blob is a reported state that blocks acceptance. The
recovery is to stage it again.

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
So it is provided as two tested pure functions and **no command**:

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

## Verification

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

**Rolling back** is `git revert` of the merge plus a rebuild and the same
restart. Published content is inert to a rollback: an older runtime simply does
not look in `review-content/`, and no record written by it names a digest.

Nothing here has been merged, built into the shared checkout, or restarted.
