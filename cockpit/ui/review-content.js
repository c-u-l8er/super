// Publishing review material, as a step inside submitting a proposal.
//
// A change set names its files by digest and the bytes are published first, so
// a submission's frame stops depending on the size of the files it describes.
// The digests are not new fields: `source.draft_sha256` is already the current
// text's content address and `source.result_sha256` the proposed text's, so a
// member cannot name one thing and carry another.
//
// This is not a user-facing operation. Nothing in the page offers "upload a
// file"; `proposalSetMaterial` calls it while completing "submit this
// proposal", and a failure here fails the submission.

/** 64 KiB of DECODED bytes, matching `Ampd.ReviewContent.chunk_bytes/0`. */
export const CHUNK = 64 * 1024;

/* `btoa(String.fromCharCode(...bytes))` spreads 65 536 arguments and overflows
   the call stack. Built in 8 KiB runs instead, which is well inside every
   engine's argument limit. */
function base64(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 8192)
    s += String.fromCharCode.apply(null, bytes.subarray(i, Math.min(i + 8192, bytes.length)));
  return btoa(s);
}

/**
 * Publish `text` under `digest`, in chunks, through the `put_review_content`
 * intent.
 *
 * Resumable by construction: each call states the offset it continues from and
 * the runtime refuses a mismatch rather than seeking, so a retry after a
 * partial upload either continues correctly or is told it cannot.
 *
 * An empty file is one final chunk of nothing — a real case (a new file staged
 * as its own "current" side) and one a loop over a zero-length array would
 * silently skip, publishing nothing under a digest the record then names.
 */
export async function stageContent(put, digest, text) {
  if (typeof digest !== 'string' || !/^[0-9a-f]{64}$/.test(digest))
    throw Error('Review content must be named by a SHA-256 digest.');
  const bytes = new TextEncoder().encode(text ?? '');
  if (bytes.length === 0) {
    if (!(await put({digest, offset: 0, chunk: '', part: 'final'})))
      throw Error('The runtime did not confirm review content for ' + digest.slice(0, 12) + '.');
    return bytes.length;
  }
  for (let at = 0; at < bytes.length; at += CHUNK) {
    const end = Math.min(at + CHUNK, bytes.length);
    const ok = await put({
      digest,
      offset: at,
      chunk: base64(bytes.subarray(at, end)),
      part: end >= bytes.length ? 'final' : 'continue',
    });
    if (!ok)
      throw Error('The runtime did not confirm review content for ' + digest.slice(0, 12) +
        '. Nothing was recorded; submitting again continues from where it stopped.');
  }
  return bytes.length;
}

/**
 * Read a published body back.
 *
 * Through the `review_content` HOST command, never an intent: a read on the
 * intent surface is refused, because a cockpit that can ask the world a
 * question has a second, unpaired source of truth.
 *
 * Returns the text, or throws naming the state. It never falls back to other
 * bytes — `missing` and `corrupt` are different facts and a reader is told
 * which.
 */
export async function readContent(invoke, digest) {
  const r = await invoke('review_content', {digest});
  if (r?.state === 'available') return r.content;
  if (r?.state === 'corrupt')
    throw Error('This file’s reviewed content no longer matches its digest. It cannot be shown or accepted.');
  throw Error('This file’s reviewed content is no longer stored. Stage the proposal again; it cannot be shown or accepted.');
}

/**
 * What to show for ONE side of a retained review member, decided before anything is fetched.
 *
 * Four outcomes, because they are four different facts and a reader must be able to tell them
 * apart:
 *
 *   * `inline`   — the body travelled in the frame; show it.
 *   * `read`     — a digest names it in the content store; fetch it.
 *   * `released` — the record was RETIRED and this side was deliberately dropped. A retired member
 *     keeps `path`, `result_sha256` and `result_bytes` and nothing else, so the shared draft has no
 *     digest to fetch. This is a design outcome, not a fault.
 *   * `absent`   — nothing was recorded for this side at all.
 *
 * `released` exists because the projection's `content_ref/3` builds a ref for a side whose digest
 * is null (`%{"digest" => nil, "bytes" => nil, "state" => "missing"}`), and that object is TRUTHY.
 * A caller guarding only on `!ref` therefore fell through to the fetch with a null digest, and the
 * host's own argument validation — `invalid args \`digest\` for command \`review_content\`:
 * invalid type: null, expected a string` — was painted into the page as the file's content. Every
 * attempt on a finished plan rendered that from the day retirement shipped.
 */
export function retainedSide(inline, ref) {
  if (typeof inline === 'string') return {kind: 'inline', text: inline};
  if (!ref) return {kind: 'absent', text: 'Not recorded.'};
  if (ref.digest === null || ref.digest === undefined)
    return {
      kind: 'released',
      text: 'Released when this plan was finished. Retirement keeps what history needs — the reviewed result, the acceptance, the notes and every run’s verdict — and drops the working copy.',
    };
  return {kind: 'read', digest: ref.digest, bytes: ref.bytes};
}

/**
 * SHA-256 of `text` as lower-case hex — the page's own hash, for checking a
 * body read back against the digest that names it rather than taking the
 * host's word for the bytes it is about to stage.
 */
export async function sha256Text(text) {
  const bytes = new TextEncoder().encode(text ?? '');
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, '0')).join('');
}
