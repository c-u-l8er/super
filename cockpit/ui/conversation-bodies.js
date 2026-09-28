/* T24 · the file bodies of a saved conversation, kept on this device by SHA-256.
 *
 * A saved conversation used to carry every attachment, every draft file and every proposal's draft, original and
 * content inline in one localStorage value. On 2026-09-27 that storage was full, a save threw, the error went to a
 * status line, and a restart lost four bot proposals. File bodies were 63 % of it. They are stored by the host now
 * (`cockpit/src/bodies.rs`), and the record keeps a reference in their place:
 *
 *     {schema: 'conversation-body@1', sha256, bytes}
 *
 * THE ORDER IS THE WHOLE POINT. A body becomes a reference only after the host answered `stored` — written, fsynced,
 * re-read, renamed, and its OWNER recorded — and only when the host's digest equals the one computed here. Until then
 * the body stays inline in the record, where it already survives a restart. Only a body that is new in memory and
 * cannot fit inline becomes a `pending` placeholder, and a placeholder is never read as a body: after a restart it
 * says the body was not saved.
 *
 * OWNERSHIP IS PER CONVERSATION. A reference in a conversation's record is always owned by that conversation, so a
 * body shared by two conversations survives the deletion of either. `known` is therefore keyed by owner: a text
 * persisted for one conversation is persisted again (deduplicated by the host) before another may reference it.
 */
import {bytesOf} from './review-limits.js';

export const BODY_SCHEMA = 'conversation-body@1';
const HEX = /^[0-9a-f]{64}$/;

export const isBodyRef = v => !!v && typeof v === 'object' && v.schema === BODY_SCHEMA;

/** A reference as it may be saved, or a thrown refusal. */
export function validBodyRef(v) {
  if (!isBodyRef(v)) throw Error('Invalid saved body reference.');
  if (!Number.isSafeInteger(v.bytes) || v.bytes < 0) throw Error('Invalid saved body size.');
  if (v.pending === true) {
    if (typeof v.pending_id !== 'string' || !/^[A-Za-z0-9-]{1,64}$/.test(v.pending_id)) throw Error('Invalid pending body.');
    return {schema: BODY_SCHEMA, pending: true, pending_id: v.pending_id, bytes: v.bytes};
  }
  if (!HEX.test(v.sha256)) throw Error('Invalid saved body digest.');
  return {schema: BODY_SCHEMA, sha256: v.sha256, bytes: v.bytes};
}

/** Every place a FILE body sits in a conversation's saved data. Message and reply TEXT are not bodies. */
export function bodySlots(data) {
  const slots = [];
  (data?.messages ?? []).forEach((m, i) => (m?.attachments ?? []).forEach((f, j) =>
    slots.push({path: ['messages', i, 'attachments', j, 'content'], kind: 'attachment', name: f?.name ?? ''})));
  (data?.files ?? []).forEach((f, j) => slots.push({path: ['files', j, 'content'], kind: 'draft file', name: f?.name ?? ''}));
  (data?.entries ?? []).forEach((e, i) => (e?.proposals ?? []).forEach((p, k) => {
    if (p && typeof p === 'object' && p.recovery && typeof p.recovery === 'object')
      for (const field of ['content', 'draft', 'original'])
        slots.push({path: ['entries', i, 'proposals', k, 'recovery', field], kind: `proposal ${field}`, entry: i, index: k, name: p.recovery.path ?? ''});
  }));
  return slots;
}
export const valueAt = (obj, path) => path.reduce((o, k) => (o == null ? o : o[k]), obj);
function setAt(obj, path, value) { valueAt(obj, path.slice(0, -1))[path.at(-1)] = value; }
const copy = v => (v === undefined ? v : JSON.parse(JSON.stringify(v)));

/** The inline texts a record holds in its body slots. */
export function inlineBodies(data) {
  const out = new Set();
  for (const s of bodySlots(data)) { const v = valueAt(data, s.path); if (typeof v === 'string') out.add(v); }
  return out;
}

export async function sha256Hex(text) {
  const d = await globalThis.crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(d)].map(b => b.toString(16).padStart(2, '0')).join('');
}

export function createBodyService({invoke, digest = sha256Hex} = {}) {
  const known = new Map();      // owner -> Map(text -> ref): persisted AND owned by that owner
  const inflight = new Map();   // `${owner}\0${text}` -> promise
  const failed = new Map();     // owner -> Map(text -> reason)
  const pendingText = new Map();// pending_id -> {owner, text}
  const listeners = new Set();
  const forOwner = (m, owner) => { if (!m.has(owner)) m.set(owner, new Map()); return m.get(owner); };
  const notify = owner => { for (const fn of listeners) try { fn(owner); } catch {} };
  const call = request => invoke('conversation_bodies', {request});

  async function putOne(owner, text, kind = 'body') {
    if (typeof text !== 'string') throw Error('A body must be text.');
    if (!text.isWellFormed()) throw Error('This text contains characters that cannot be stored exactly (an unpaired surrogate).');
    const [local, r] = await Promise.all([digest(text), call({operation: 'put', owner, text, ...(kind === 'original' ? {kind} : {})})]);
    if (r?.state !== 'stored') throw Error('The device body store did not confirm the write.');
    if (r.sha256 !== local || r.bytes !== bytesOf(text)) throw Error('The device body store confirmed different bytes than were sent; nothing references them.');
    return {schema: BODY_SCHEMA, sha256: r.sha256, bytes: r.bytes};
  }

  const service = {
    /** The persisted, owned reference for a text, or null. */
    refFor: (owner, text) => known.get(owner)?.get(text) ?? null,
    /** 'persisted' | 'writing' | 'failed' | 'unknown' */
    stateOf(owner, text) {
      if (service.refFor(owner, text)) return 'persisted';
      if (inflight.has(`${owner}\0${text}`)) return 'writing';
      if (failed.get(owner)?.has(text)) return 'failed';
      return 'unknown';
    },
    failureOf: (owner, text) => failed.get(owner)?.get(text) ?? null,
    pendingTextOf: id => pendingText.get(id)?.text ?? null,
    on(fn) { listeners.add(fn); return () => listeners.delete(fn); },

    /** Replace every body this owner has persisted with its reference. Everything else stays as it is: inline text
     *  stays inline (and is listed to persist), a reference stays a reference, a pending placeholder whose text has
     *  since been persisted becomes that reference. */
    slim(data, owner) {
      const out = copy(data), unpersisted = [];
      for (const s of bodySlots(out)) {
        const v = valueAt(out, s.path);
        if (typeof v === 'string') {
          const ref = service.refFor(owner, v);
          if (ref) setAt(out, s.path, {...ref}); else unpersisted.push(v);
        } else if (isBodyRef(v) && v.pending === true) {
          const p = pendingText.get(v.pending_id);
          const ref = p && p.owner === owner ? service.refFor(owner, p.text) : null;
          if (ref) setAt(out, s.path, {...ref});
        }
      }
      return {data: out, unpersisted: [...new Set(unpersisted)]};
    },

    /** Replace the given inline texts with explicit pending placeholders (used only when a record cannot fit with
     *  them inline). The text is held in memory under its placeholder id until it is persisted. */
    pendingize(data, owner, texts) {
      const want = new Set(texts), ids = new Map(), out = copy(data);
      for (const s of bodySlots(out)) {
        const v = valueAt(out, s.path);
        if (typeof v !== 'string' || !want.has(v)) continue;
        if (!ids.has(v)) { const id = crypto.randomUUID(); ids.set(v, id); pendingText.set(id, {owner, text: v}); }
        setAt(out, s.path, {schema: BODY_SCHEMA, pending: true, pending_id: ids.get(v), bytes: bytesOf(v)});
      }
      return out;
    },

    /** Persist texts for an owner. Resolves when every text is persisted; rejects with the first failure after all
     *  were attempted. Each outcome is recorded, so a card can say which of its bodies failed and why. */
    async persist(owner, texts) {
      const errors = [];
      await Promise.all([...new Set(texts)].map(text => {
        if (service.refFor(owner, text)) return null;
        const key = `${owner}\0${text}`;
        if (!inflight.has(key)) {
          inflight.set(key, putOne(owner, text).then(ref => { forOwner(known, owner).set(text, ref); failed.get(owner)?.delete(text); },
            error => { forOwner(failed, owner).set(text, String(error?.message || error)); throw error; })
            .finally(() => { inflight.delete(key); notify(owner); }));
          notify(owner);
        }
        return inflight.get(key).catch(e => errors.push(e));
      }));
      if (errors.length) throw errors[0];
    },

    /** The migration's original: a whole saved value, stored as-is and read back before anything relies on it. */
    async putOriginal(owner, text) {
      const ref = await putOne(owner, text, 'original');
      const back = await service.get(ref.sha256);
      if (back.state !== 'available' || back.text !== text) throw Error('The original did not read back byte-identical.');
      return ref;
    },

    /** The bytes behind a reference, re-hashed by the host: {state: 'available', text} | {state: 'missing'|'corrupt'}. */
    async get(sha256) {
      const r = await call({operation: 'get', sha256});
      if (r?.state === 'available') {
        if (await digest(r.text) !== sha256) return {state: 'corrupt'};
        return {state: 'available', text: r.text};
      }
      return {state: r?.state === 'corrupt' ? 'corrupt' : 'missing'};
    },

    /** Rebuild a record's texts. References this owner's record holds are owned by it (they were written only after
     *  a stored answer for that owner), so each resolved text becomes known for it. Nothing is invented: an
     *  unresolvable slot keeps its reference and is reported with the reason. */
    async resolve(data, owner) {
      const out = copy(data), problems = [];
      await Promise.all(bodySlots(out).map(async s => {
        const v = valueAt(out, s.path);
        if (!isBodyRef(v)) return;
        if (v.pending === true) {
          const p = pendingText.get(v.pending_id);
          if (p && p.owner === owner) { setAt(out, s.path, p.text); return; }
          problems.push({...s, state: 'pending'}); return;
        }
        const r = await service.get(v.sha256).catch(() => ({state: 'missing'}));
        if (r.state !== 'available' || bytesOf(r.text) !== v.bytes) { problems.push({...s, state: r.state === 'available' ? 'corrupt' : r.state, sha256: v.sha256}); return; }
        setAt(out, s.path, r.text);
        forOwner(known, owner).set(r.text, {schema: BODY_SCHEMA, sha256: v.sha256, bytes: v.bytes});
      }));
      return {data: out, problems};
    },

    async release(owner) {
      const r = await call({operation: 'release', owner});
      known.delete(owner); failed.delete(owner);
      for (const [id, p] of pendingText) if (p.owner === owner) pendingText.delete(id);
      return r;
    },
    report: () => call({operation: 'report'}),
  };
  return service;
}

/** What a body problem says on its card or attachment. Never "no content": the record names the body, and the
 *  reason it cannot be read is a different fact for each state. */
export function problemText(p) {
  const what = p.kind === 'attachment' || p.kind === 'draft file' ? `The ${p.kind} ${p.name}` : `This proposal's ${p.kind.replace('proposal ', '')} text`;
  if (p.state === 'pending') return `${what} was not saved to this device before Super closed. It cannot be restored.`;
  if (p.state === 'corrupt') return `${what} no longer matches its recorded digest on this device. It cannot be used.`;
  return `${what} is missing from this device's body store. It cannot be restored.`;
}
