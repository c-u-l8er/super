// The one number for how large a file may be on the review path THROUGH THE
// PAGE: attached to a bot, proposed by a bot, carried in a conversation, or
// handed to the Editor's plan-linked snapshot.
//
// 256 KiB. Larger than any source file in this tree (cockpit.js, the largest,
// is 73 KB), and inside every transport it has to cross, each of which is
// named where it is enforced:
//
//   provider request  — attachments per message: 4 × this, checked in
//                       cockpit/src/bots.rs (total 1 MiB)
//   provider reply    — one reply ≤ 4 MiB (cockpit/src/bots.rs), so twelve
//                       proposals of this size fit with room for the prose
//   host file basis   — cockpit/src/workbench.rs `file_basis` and
//                       cockpit/src/attachments.rs read at most this
//   publishing        — chunks of 64 KiB through `put_review_content`; the
//                       runtime stores members up to 4 MiB
//                       (Ampd.ReviewContent.file_bytes/0), so this is the
//                       page's limit, not the store's
//   the runner        — tools/lib/proposal-test-runner.mjs checks members
//                       against the runtime's 4 MiB
//
// A provider's own context window is not a transport this page controls; a
// model that cannot take four such files says so as a provider error.
//
// What this does NOT lift: a SINGLE-file review recorded inline
// (`record_development_attempt`, 24 000 / 32 000 bytes in the runtime's
// CommandSpec). A file over those caps is reviewable as a member of a
// combined review, which is published by digest.
export const REVIEW_FILE_BYTES = 256 * 1024;
export const REVIEW_FILE_LABEL = '256 KB';
export const bytesOf = text => new TextEncoder().encode(text).length;
