# Reviewing a change to Super's own files — 2026-09-12

**Status: a design, for a ruling. Nothing here is built.**

Super cannot review a complete change to its own larger source files. This is
the record of what actually stops it, the two ways to fix it, and the one change
that cannot itself go through review.

## What stops it, measured

Submitting the second held dogfood proposal (seven files) against this
repository on 2026-09-12 produced two refusals from two different layers:

    7 files   frame of 336202 bytes exceeds the 262144 byte limit
    2 files   attempt-fields-invalid — "A change set needs two to four
              complete, valid file replacements."

The second probe used two files, a legal count, so only the bytes could be at
fault. There are **four** independent ceilings, and a change set carries whole
file text rather than a diff:

| ceiling | value | where |
|---|---|---|
| members per set | 2 to 4 | `development_attempt.ex` `create_set/2` |
| one file, current text | 24 000 B | `command_spec.ex` `shared_draft`, `development_attempt.ex` `set_file?/1` |
| one file, proposed text | 32 000 B | `command_spec.ex` `proposed_text`, `set_file?/1` |
| the whole `material` map | 240 000 B | `command_spec.ex`, by `Frame.logical_size/2` |
| the encoded frame | 262 144 B | `host/src/lib.rs` `MAX_FRAME`, `ampd/lib/ampd/frame.ex` `@max_bytes`, and the socket driver's `packet_size` |

Against Super's own tree that excludes, among others:

| file | current | proposed |
|---|---|---|
| `cockpit/ui/cockpit.js` | 72 809 | 73 187 |
| `cockpit/ui/cockpit.css` | 35 044 | 35 692 |
| `ampd/lib/ampd/projection.ex` | 34 282 | 35 441 |

So Super cannot review a change to its own UI entry point, its own stylesheet,
or its own projection. The proposal that needs all three is the one already held.

### A second cost, not previously counted

`development_attempts` live in the **`loci` authority store**, and
`Ampd.Store.save/2` writes the whole state term. Measured on the live world
after recording one three-file change set (`da_0030`):

    whole loci state                 50 146 bytes
      development_attempts           30 632      61%
      development_tasks              15 111
      everything else                 4 403

One change set is most of an authority store, and every unrelated mutation —
opening a workspace, creating a plan, closing a worker — rewrites those bytes.
A four-file set of the files above would be roughly 214 KB of text, making the
store about ten times its present size, rewritten on every world mutation.

## Option A — raise the limits together

Raise `MAX_FRAME` on both sides and the driver's `packet_size`, the two
`CommandSpec` string caps, the `material` map cap, the two `set_file?/1` caps
and the member count, as one coordinated change.

**For it.** It is the smallest diff and the fastest to ship. It changes no
shapes, so nothing downstream learns a new vocabulary.

**Against it.**

1. *It is sized to one proposal, not to the problem.* Carrying the held
   proposal needs a frame near 512 KB. The next change that touches
   `cockpit.js` plus three more files needs more. The input is "a file in this
   repository", and files grow. There is no number that is right, only a number
   that is not yet wrong.
2. *It weakens a stated property of the transport, for every frame, to serve
   one.* `frame.ex` says the limit is enforced by the socket driver before the
   bytes are copied into the VM, because "a limit that allocates the thing it
   is rejecting is a limit that makes the attack cheaper." `packet_size` bounds
   **all** frames, including every projection snapshot. Raising it to carry
   review text raises the per-message allocation of the whole link.
3. *It makes the authority store grow without bound*, per the measurement above.

## Option B — stage the content, address it by digest

Content is uploaded before the change set, in bounded chunks, into a store of
its own. The change set then carries **digests and metadata, not bytes**.

**For it.**

1. *The change-set frame stops depending on file size.* A member becomes a
   path, two digests and the existing source fields — a few hundred bytes. A
   four-file set fits the **present** 256 KB frame with room to spare, and
   would fit a much smaller one. The limit that refuses before allocating stays
   exactly where it is.
2. *It removes a duplication that is already there.* A member already carries
   `draft_sha256`, `result_sha256` and a `basis_id` computed from them. It
   carries the hash **and** the bytes, and the runtime recomputes the hash from
   the bytes to check they agree. Addressing content by digest is the shape the
   record already has.
3. *Review content leaves the authority store.* Content is **not** authority:
   losing it should be a cache miss, and the attempt that references it is
   still on record and can be re-supplied. So it belongs in a store that is
   **not** in `@authority_stores`, which also means this adds no seal, no
   recovery-manifest entry and no new thing that can make a world unopenable.
4. *Chunking is bounded by construction.* Each chunk is its own small frame, so
   an 8 MB file and a 2 KB file put the same pressure on the link.

**Against it.**

1. A new store, a new command pair, and a content lifetime question (what
   removes content no attempt references).
2. All-or-nothing now spans two steps. Recording must refuse unless **every**
   referenced digest resolves to stored content whose bytes hash to it —
   otherwise a set could be recorded naming content that does not exist.
3. An upload is a write by a person that is not yet reviewable material, so it
   needs its own bound: a per-upload cap and a total cap, or it is a way to
   fill a disk.

## Recommendation

**Option B, keeping every limit Option A would have raised.** The point is not
that the limits are too low; it is that the *frame* is the wrong thing to be
measuring file content with. Under B:

* the member count stays a stated limit, raised deliberately to what a review
  can actually be read at, not to whatever the frame allows;
* per-file and per-set byte caps stay, enforced on the **stored content**,
  where the number can be large without any frame being large;
* the frame limit does not move at all.

This is not "remove the limits". It is "put each limit on the thing it is
about".

## The four errors, kept apart

Today `set_file?/1` folds membership, byte caps, text validity and every digest
into one boolean, so a two-file set that is too large is refused with *"A change
set needs two to four complete, valid file replacements"* — a sentence about
counting, when the count was two. A person reads it and counts their files.

Four distinct refusals, each naming what failed and, where it applies, which
file:

| code | means | carries |
|---|---|---|
| `review-file-count` | fewer than the minimum or more than the maximum members | the count given, and the bounds |
| `review-file-too-large` | one member's current or proposed content exceeds the per-file cap | the path, which side, the size, the cap |
| `review-set-too-large` | the members together exceed the per-set cap | the total, the cap |
| `review-content-invalid` | not valid text, a NUL byte, a digest that disagrees with its bytes, or content that was never uploaded | the path and which of those |

None of them discloses file contents back to the caller.

## The bootstrap

A change that adds staged upload cannot be submitted through staged upload, and
the running desktop is the thing being changed. So exactly one change has to
reach `super/` outside the review mechanism: **the mechanism itself** — the
command definitions, the content store, the validator and its refusals.

That change should be as small as it can be and should be the last one made
this way. Everything after it, including the held repository-label proposal,
goes through review.

It is presented as a diff for a ruling before it is applied to the running
system, because applying it means replacing the binary Travis's desktop is
running and restarting it, which revokes every paired phone session.

## Not proposed

* Removing or silently widening any limit.
* Splitting an atomic change into partial submissions. A subset of the held
  proposal that fits today's caps is an incomplete change wearing a complete
  one's record: without `projection.ex` nothing publishes a name and the other
  files do nothing.
* Any path that records or accepts material without the runtime validating it.

---

# Addendum, same day — two findings from building it, and the fork they reach

## A third cost — RETRACTED the same day, and the retraction is the point

> **This section was wrong and is kept for the record rather than edited away.**
> It claimed a shipped world could be made unviewable by recording two maximal
> change sets. It cannot. `Ampd.DevelopmentAttempt.persist/2` — on shipped main,
> predating all of this — caps the whole persisted `development_attempts`
> collection at **64 KiB encoded** plus a reserve per unfinished test run, and
> refuses `attempt-directory-full` while **preserving what is already recorded**.
> The store refuses long before a frame is threatened.
>
> The tests cited below encoded **synthetic maps** and never went through
> admission, so they measured arithmetic about a shape and were presented as
> reachability. That is the error: a measurement that bypasses the guard cannot
> establish a failure the guard exists to prevent. They are now named
> `ARITHMETIC ONLY` and the reachable version records through the real path and
> asserts `attempt-directory-full`.
>
> **What survives, and still justifies staging:** the *submission* ceiling is
> real and was measured on the wire — seven files refused at
> `frame of 336202 bytes exceeds the 262144 byte limit` — and the per-file caps
> exclude `cockpit.js`, `cockpit.css` and `projection.ex` outright. And the
> 64 KiB guard is a second, independent argument **for** staging rather than
> against it: one real three-file inline change set (`da_0030`) was 30 632
> bytes, 47% of the entire budget for a world, and two inline 20 KB files do not
> fit at all. With bodies published separately a record is its metadata, so the
> same budget holds roughly sixteen times as many reviews. **Keep the guard.**
>
> Found by the session that picked this up, 2026-09-12.

## A third cost, as it was claimed

`Ampd.Projection` publishes `"development_attempts" => Ampd.Loci.development_attempts()`
— **the whole collection, with all inlined text, in every frame.** Receipts,
validations and `effects_history` are passed through `window/1`, which keeps the
newest fifty. Attempts are not windowed at all.

So recorded review material is not merely stored; it is re-published on every
frame, against a 262 144-byte frame limit. `ampd/test/review_content_test.exs`
measures it rather than arguing it:

    ONE maximal change set already occupies most of a frame        > 224 000 B, fits
    TWO maximal change sets cannot be published at all             > frame limit
    the attempt limit permits an order of magnitude more           50 x 4 x 56 000

A member may carry 24 000 bytes of current text and 32 000 of proposed, a set
may hold four, and the runtime's own `attempt-limit` permits **fifty** sets. Two
of maximum size make the projection unpublishable — so **the world stops being
viewable, over material that is already recorded and cannot be unrecorded.**

**The sentence that followed here said "this is reachable in the runtime as it
ships". It is not — see the retraction above.** The comparison is still settled,
for the reasons that survive: content has to leave the *projection*, not only the
command. Option A cannot reach it — raising the frame to fit two sets leaves
three over the line.

## What is built and tested

Held at `~/Documents/Codex/2026-09-10/wh/outputs/super-bootstrap-review-content/`,
**not committed and not applied**:

| | |
|---|---|
| `Ampd.ReviewContent` | content-addressed staging beside the world, deliberately outside `@authority_stores` — losing it is a cache miss. Chunked, bounded per chunk / per file / per store, hashed on completion and **re-hashed on the way out**, so a blob edited on disk behind the store is not served. |
| `put_review_content` | one human-control mutation, base64 chunks, **outside the ordered transaction** — writing a file inside the coordinator is the unbounded host round trip `check-dispatch-partition.mjs` exists to keep out. |
| `cockpit/src/worker.rs` | one name on `INTENT_SURFACE`. |

Evidence: **14 tests · 0 failures**, whole ampd suite **785 · 0** (771 before).
A 600 000-byte blob stages and reads back byte for byte; `cockpit/ui/cockpit.js`
and `ampd/lib/ampd/projection.ex` both stage. Refusals proved by name for a
digest that disagrees with its bytes, a lost write offset, an oversized chunk,
an oversized file (with its partial discarded), a name that is not a digest, and
a blob edited behind the store. The chunk boundary is tested **inclusive**:
exactly at the limit is accepted, one over is refused.

## The fork, which `check-intent-surface.mjs` found and I did not

With the runtime half in place the gate went red twice, and the second one is
the design question:

    declared by the runtime, absent from the cockpit: put_review_content
    on INTENT_SURFACE, absent from ui/cockpit.js: put_review_content
      — appending a name to the const does not make a person able to perform it

The gate's law is that an intent must be **submittable from the page**. Adding a
wiring line with nothing calling it would satisfy the letter and be exactly the
cosmetic green the gate's own comment was written to refuse, so it was not done.

That makes the honest bootstrap larger than three files, and **which way it goes
is a ruling, not a detail**:

1. **Is staging content an operation a person performs, or a step inside one?**
   If it is a step, modelling it as its own human-control mutation is what the
   gate is objecting to, and it may belong on the **host** surface beside
   `development_request` and `review_tests` — which already read and write
   repository files from the Rust side — rather than on the intent surface.
2. **Does a recorded attempt store digests or bytes?** It must store digests, or
   the authority store and the projection keep the weight. But consumers read
   `proposed_text` off the record through the projection: the combined-review
   UI, `tools/lib/proposal-test-runner.mjs`, and acceptance preflight. They
   would fetch content on demand instead. That is the blast radius, and it is
   the reason this stopped here rather than guessing.

**Once the mechanism carries a complete change, the UI's use of it can be the
first thing reviewed through it** — `cockpit/ui/cockpit.js` is 72 809 bytes and
is precisely what the new mechanism exists to carry. Only the runtime half has
to arrive outside review.
