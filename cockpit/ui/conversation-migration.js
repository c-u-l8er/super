/* T24 · moving the file bodies of EXISTING saved conversations out of localStorage.
 *
 * Ruled: preserve conversations, and do not remove an original until its retrieval is verified. So, per store key,
 * nothing replaces the stored value until all of this holds:
 *
 *   1. the raw value itself is stored as a body (owner `migration:<key>`) and read back byte-identical — the
 *      original, outside localStorage, before anything else happens;
 *   2. every inline file body is stored under its conversation's owner;
 *   3. the slim value, with every reference resolved back through the host (which re-hashes), equals the original
 *      parsed value exactly;
 *   4. the key still holds the raw value read in step 1 (nothing saved in between) — read and write are one
 *      synchronous step, so nothing can interleave;
 *   5. the key reads back as what was written.
 *
 * Any failure leaves the key byte-identical and is reported; running again resumes (the host deduplicates). A store
 * that does not load cleanly is not migrated: its problem is reported and its value left as it is. The originals stay
 * owned until a person releases them.
 */
import {STORAGE_KEY, createConversationStore, bodyOwner} from './conversation-store.js';
import {bodySlots, valueAt, isBodyRef} from './conversation-bodies.js';

export const MIGRATION_RECEIPTS = 'super-conversation-bodies-migration-v1';
export const isConversationKey = k => k === STORAGE_KEY || k.startsWith(`${STORAGE_KEY}:bot:`);

const inlineCount = parsed => (parsed.conversations ?? []).reduce((n, c) =>
  n + bodySlots(c.data).filter(s => typeof valueAt(c.data, s.path) === 'string').length, 0);

/* Rebuild a slim store value into texts, through the host. Returns null if any reference does not resolve. */
async function resolveAll(value, key, bodies) {
  const out = JSON.parse(JSON.stringify(value));
  for (const c of out.conversations) {
    const {data, problems} = await bodies.resolve(c.data, bodyOwner(key, c.id));
    if (problems.length) return null;
    c.data = data;
  }
  return out;
}

export async function migrateKey(storage, key, bodies) {
  const raw = storage.getItem(key);
  if (raw === null) return {key, state: 'empty'};
  let parsed;
  try { parsed = JSON.parse(raw); } catch { return {key, state: 'unreadable', detail: 'not JSON; left as it is'}; }
  const probe = createConversationStore({getItem: k => (k === STORAGE_KEY ? raw : null), setItem: () => { throw Error('read-only'); }});
  if (probe.error) return {key, state: 'not loadable', detail: probe.error};
  const moving = inlineCount(parsed);
  if (!moving) return {key, state: 'nothing to move', version: parsed.version};

  // 1. the original, outside localStorage, read back byte-identical
  const original = await bodies.putOriginal(`migration:${key}`, raw);
  // 2. every inline body, under its conversation
  for (const c of parsed.conversations) {
    const owner = bodyOwner(key, c.id);
    const texts = bodySlots(c.data).map(s => valueAt(c.data, s.path)).filter(v => typeof v === 'string');
    await bodies.persist(owner, texts);
  }
  // 3. the slim value, and proof that it resolves back to exactly the original
  const next = {...parsed, version: 2, conversations: parsed.conversations.map(c => {
    const {data, unpersisted} = bodies.slim(c.data, bodyOwner(key, c.id));
    if (unpersisted.length) throw Error(`A body of conversation ${c.id} was not persisted.`);
    return {...c, data};
  })};
  const back = await resolveAll(next, key, bodies);
  const same = back && JSON.stringify(back.conversations) === JSON.stringify(parsed.conversations) &&
    JSON.stringify(back.selected ?? null) === JSON.stringify(parsed.selected ?? null);
  if (!same) return {key, state: 'verification failed', detail: 'the slim value did not resolve back to the original; left as it is', original};
  const written = JSON.stringify(next);
  // 4. compare-and-set, 5. read back
  if (storage.getItem(key) !== raw) return {key, state: 'changed during migration', detail: 'left as it is; it migrates on the next start', original};
  try { storage.setItem(key, written); }
  catch (e) { return {key, state: 'write refused', detail: String(e?.message || e), original}; }
  if (storage.getItem(key) !== written) return {key, state: 'read-back mismatch', detail: 'the stored value is not what was written', original};
  const refs = next.conversations.reduce((n, c) => n + bodySlots(c.data).filter(s => isBodyRef(valueAt(c.data, s.path))).length, 0);
  return {key, state: 'migrated', original, before: raw.length, after: written.length, bodies: refs};
}

/** Every conversation store key on this device. `storage` must enumerate: {length, key(i), getItem, setItem}. */
export async function migrateConversationStores(storage, bodies) {
  const keys = [];
  for (let i = 0; i < storage.length; i++) { const k = storage.key(i); if (k && isConversationKey(k)) keys.push(k); }
  const results = [];
  for (const key of keys.sort()) {
    try { results.push(await migrateKey(storage, key, bodies)); }
    catch (e) { results.push({key, state: 'failed', detail: String(e?.message || e)}); }
  }
  /* The receipt says which blob holds each original. It is small; if even it cannot be saved the migrations
   * above still stand, and the receipt's absence is itself reported. */
  const migrated = results.filter(r => r.state === 'migrated');
  if (migrated.length) {
    try {
      const prior = JSON.parse(storage.getItem(MIGRATION_RECEIPTS) || '[]');
      storage.setItem(MIGRATION_RECEIPTS, JSON.stringify([...prior, ...migrated.map(r => ({key: r.key, original: r.original, before: r.before, after: r.after, bodies: r.bodies, at: new Date().toISOString()}))].slice(-100)));
    } catch { results.push({key: MIGRATION_RECEIPTS, state: 'receipt not saved'}); }
  }
  return results;
}
