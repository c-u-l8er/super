/* Publishing a reviewed body from the page, and reading one back.
 *
 * The chunking is the part with edges: an empty file, a body that is exactly
 * one chunk, one that is a chunk plus a byte, and a multi-byte character that a
 * byte-wise split can land inside.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {stageContent, readContent, retainedSide, CHUNK} from '../cockpit/ui/review-content.js';

const sha = s => createHash('sha256').update(Buffer.from(s, 'utf8')).digest('hex');

/** A put that records what it was given and reassembles it, like the store does. */
function recorder({fail = null} = {}) {
  const calls = [];
  const put = async args => {
    calls.push(args);
    if (fail && calls.length === fail) return false;
    return true;
  };
  const assembled = () =>
    Buffer.concat(calls.map(c => Buffer.from(c.chunk, 'base64'))).toString('utf8');
  return {put, calls, assembled};
}

test('a small body is one final chunk and reassembles exactly', async () => {
  const text = 'before\r\n';
  const r = recorder();
  await stageContent(r.put, sha(text), text);
  assert.equal(r.calls.length, 1);
  assert.equal(r.calls[0].part, 'final');
  assert.equal(r.calls[0].offset, 0);
  assert.equal(r.assembled(), text);
});

test('an EMPTY body still publishes — a loop over zero bytes would skip it', async () => {
  const r = recorder();
  await stageContent(r.put, sha(''), '');
  assert.equal(r.calls.length, 1, 'a new file staged as its own "current" side is empty');
  assert.equal(r.calls[0].part, 'final');
  assert.equal(r.calls[0].chunk, '');
  assert.equal(r.assembled(), '');
});

test('offsets are contiguous, only the last part is final, and nothing is lost', async () => {
  const text = 'x'.repeat(CHUNK * 2 + 17);
  const r = recorder();
  const n = await stageContent(r.put, sha(text), text);
  assert.equal(n, CHUNK * 2 + 17);
  assert.equal(r.calls.length, 3);
  assert.deepEqual(r.calls.map(c => c.offset), [0, CHUNK, CHUNK * 2]);
  assert.deepEqual(r.calls.map(c => c.part), ['continue', 'continue', 'final']);
  assert.equal(r.assembled(), text);
});

test('exactly one chunk is one final call, not two', async () => {
  const text = 'y'.repeat(CHUNK);
  const r = recorder();
  await stageContent(r.put, sha(text), text);
  assert.equal(r.calls.length, 1);
  assert.equal(r.calls[0].part, 'final');
});

test('a multi-byte character split across a chunk boundary survives', async () => {
  // Byte-wise splitting can land inside a character, which is exactly why the
  // wire form is base64 rather than the text itself.
  const text = 'a'.repeat(CHUNK - 1) + '€' + 'b'.repeat(10);
  const r = recorder();
  await stageContent(r.put, sha(text), text);
  assert.equal(r.assembled(), text, 'the character must not be corrupted by the split');
  assert.equal(sha(r.assembled()), sha(text));
});

test('a body of many megabytes does not blow the stack building base64', async () => {
  const text = 'z'.repeat(CHUNK * 8);
  const r = recorder();
  await stageContent(r.put, sha(text), text);
  assert.equal(r.assembled().length, text.length);
});

test('a refused chunk stops the upload and says so', async () => {
  const text = 'w'.repeat(CHUNK * 3);
  const r = recorder({fail: 2});
  await assert.rejects(() => stageContent(r.put, sha(text), text), /did not confirm/);
  assert.equal(r.calls.length, 2, 'nothing is sent after a refusal');
});

test('a name that is not a digest is refused before anything is sent', async () => {
  const r = recorder();
  for (const bad of ['', 'nope', 'A'.repeat(64), '../etc/passwd'])
    await assert.rejects(() => stageContent(r.put, bad, 'x'), /SHA-256 digest/);
  assert.equal(r.calls.length, 0);
});

test('reading a body back returns its text', async () => {
  const invoke = async (name, args) => {
    assert.equal(name, 'review_content');
    return {state: 'available', digest: args.digest, content: 'the reviewed text'};
  };
  assert.equal(await readContent(invoke, sha('x')), 'the reviewed text');
});

test('missing and corrupt are different messages, and neither returns bytes', async () => {
  const missing = async () => ({state: 'missing'});
  await assert.rejects(() => readContent(missing, sha('x')), /no longer stored/);

  const corrupt = async () => ({state: 'corrupt'});
  await assert.rejects(() => readContent(corrupt, sha('x')), /no longer matches its digest/);

  // An unrecognised answer is not treated as success.
  const odd = async () => ({});
  await assert.rejects(() => readContent(odd, sha('x')));
});

/* ── Which side of a retained member is shown, and how it is decided ──────────
 *
 * A retired record keeps `path`, `result_sha256` and `result_bytes` and nothing else, so its
 * shared draft has no digest. The projection still builds a ref for that side — `content_ref/3`
 * returns a map whatever it is given — and the object is TRUTHY, so a caller guarding on `!ref`
 * fell through to the fetch with a null digest and the host's own argument validation was rendered
 * into the page as the file's content. These pin the four outcomes apart.
 */
const REF = d => ({digest: d, bytes: 12, state: d ? 'available' : 'missing'});

test('a body that travelled in the frame is shown inline and is never fetched', () => {
  assert.deepEqual(retainedSide('the text', REF('a'.repeat(64))), {kind: 'inline', text: 'the text'});
  assert.deepEqual(retainedSide('', null), {kind: 'inline', text: ''});   // an empty body is a body
});

test('a digest names bytes to read, and carries the size the reader is told to expect', () => {
  assert.deepEqual(retainedSide(undefined, REF('b'.repeat(64))), {kind: 'read', digest: 'b'.repeat(64), bytes: 12});
});

test('no ref at all is "Not recorded." - nothing was kept for this side', () => {
  assert.deepEqual(retainedSide(undefined, null), {kind: 'absent', text: 'Not recorded.'});
  assert.equal(retainedSide(undefined, undefined).kind, 'absent');
});

/* The defect this function exists for: every attempt on a finished plan rendered the host's
   argument-validation error where its shared draft used to be, from the day retirement shipped. */
test('a RETIRED side - a truthy ref whose digest is null - is released, never read', () => {
  const side = retainedSide(undefined, {digest: null, bytes: null, state: 'missing'});
  assert.equal(side.kind, 'released');
  assert.match(side.text, /^Released when this plan was finished\./);
  assert.ok(!('digest' in side), 'a released side offers nothing to fetch');
});

test('a released side is not confused with a side whose bytes are genuinely gone', () => {
  // digest present, blob missing: a fault, and still worth fetching so the reader is told which.
  assert.equal(retainedSide(undefined, {digest: 'c'.repeat(64), bytes: 9, state: 'missing'}).kind, 'read');
  // digest absent: a design outcome, and fetching it can only produce a type error.
  assert.equal(retainedSide(undefined, {digest: null, bytes: 9, state: 'missing'}).kind, 'released');
});
