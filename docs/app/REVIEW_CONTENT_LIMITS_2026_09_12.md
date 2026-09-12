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
