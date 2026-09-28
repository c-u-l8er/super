/* T24 · the downgrade: a version-2 conversation store back to version 1, its file bodies re-inlined from the device
 * body store. It exists for one reason: rolling Super back to a build before T24. Such a build refuses a version-2
 * store ("format is not supported") and changes nothing, so no data is lost — but history is unreadable until the
 * stores are version 1 again.
 *
 * Pure: `downgradeValue` takes the raw stored value and a blob reader, and returns the version-1 value or the reasons
 * it cannot. Nothing here touches storage; the CLI (`tools/conversation-bodies-downgrade.mjs`) does.
 *
 * NOTHING IS INVENTED. A reference whose blob is missing, corrupt, or that was only ever a pending placeholder has no
 * bytes to put back. By default that refuses the key. Only with `dropUnrecoverable` does it become explicit history
 * loss, reported item by item: a proposal keeps its saved text and loses its recovery record (a build before T24
 * shows it as history that cannot be applied), and an unreadable attachment or draft file is removed.
 */
import {createHash} from 'node:crypto';
import {bodySlots, valueAt, isBodyRef} from '../../cockpit/ui/conversation-bodies.js';
import {createConversationStore, STORAGE_KEY} from '../../cockpit/ui/conversation-store.js';

export const QUOTA_BYTES = 5 * 1024 * 1024;
export const isConversationKey = k => k === STORAGE_KEY || k.startsWith(`${STORAGE_KEY}:bot:`);
/* WebKit's own accounting (String::sizeInBytes): 1 byte per character when every character is Latin-1, else 2. */
export const webkitBytes = s => (/^[\x00-\xff]*$/.test(s) ? s.length : 2 * s.length);

const sha = t => createHash('sha256').update(Buffer.from(t, 'utf8')).digest('hex');

/** A blob reader over a body store directory: {state: 'available', text} | {state: 'missing'|'corrupt'}. */
export function blobReader(readFile) {
  return ref => {
    let bytes;
    try { bytes = readFile(ref.sha256); } catch { return {state: 'missing'}; }
    if (createHash('sha256').update(bytes).digest('hex') !== ref.sha256 || bytes.length !== ref.bytes) return {state: 'corrupt'};
    try { return {state: 'available', text: new TextDecoder('utf-8', {fatal: true}).decode(bytes)}; } catch { return {state: 'corrupt'}; }
  };
}

/**
 * @param raw     the stored value of one conversation key
 * @param read    ref -> {state, text?}
 * @returns {state: 'unchanged'|'downgraded'|'refused'|'unreadable', value?, problems, dropped, inlined}
 */
export function downgradeValue(raw, read, {dropUnrecoverable = false, validateWith = null} = {}) {
  let parsed;
  try { parsed = JSON.parse(raw); } catch { return {state: 'unreadable', problems: ['not JSON'], dropped: [], inlined: 0}; }
  if (parsed.version === 1) return {state: 'unchanged', problems: [], dropped: [], inlined: 0};
  if (parsed.version !== 2 || !Array.isArray(parsed.conversations)) return {state: 'unreadable', problems: [`version ${parsed.version}`], dropped: [], inlined: 0};
  const problems = [], dropped = [];
  let inlined = 0;
  const conversations = parsed.conversations.map(c => {
    const data = JSON.parse(JSON.stringify(c.data));
    const unresolved = [];
    for (const s of bodySlots(data)) {
      const v = valueAt(data, s.path);
      if (!isBodyRef(v)) continue;
      const r = v.pending ? {state: 'pending'} : read(v);
      if (r.state === 'available') { valueAt(data, s.path.slice(0, -1))[s.path.at(-1)] = r.text; inlined++; continue; }
      unresolved.push({...s, state: r.state});
      problems.push(`${c.id}: ${s.kind}${s.name ? ' ' + s.name : ''} is ${r.state}${v.sha256 ? ' (' + v.sha256.slice(0, 16) + '…)' : ''}`);
    }
    if (unresolved.length && dropUnrecoverable) {
      // Proposals: keep the saved text, lose the recovery record. Attachments and draft files: remove.
      const lostProposals = new Set(unresolved.filter(u => u.kind.startsWith('proposal')).map(u => `${u.entry}:${u.index}`));
      for (const key of lostProposals) {
        const [i, k] = key.split(':').map(Number);
        const p = data.entries[i].proposals[k];
        data.entries[i].proposals[k] = p.text;
        dropped.push(`${c.id}: proposal ${key} (${p.recovery?.path ?? 'unknown path'}) kept as history only`);
      }
      for (const u of unresolved.filter(u => u.kind === 'attachment')) {
        const [, mi, , ai] = u.path;
        data.messages[mi].attachments[ai] = null;
        dropped.push(`${c.id}: attachment ${u.name} removed from message ${mi}`);
      }
      for (const m of data.messages) if (m.attachments) m.attachments = m.attachments.filter(Boolean);
      for (const u of unresolved.filter(u => u.kind === 'draft file')) { data.files[u.path[1]] = null; dropped.push(`${c.id}: draft file ${u.name} removed`); }
      data.files = data.files.filter(Boolean);
    }
    return {...c, data};
  });
  if (problems.length && !dropUnrecoverable) return {state: 'refused', problems, dropped, inlined};
  const value = JSON.stringify({...parsed, version: 1, conversations});
  // The result must be a version-1 store with every body inline, and must load under the store code — and, when a
  // pre-T24 tree is named, under THAT tree's store code, which is what will read it after a rollback.
  const left = conversations.flatMap(c => bodySlots(c.data).filter(s => isBodyRef(valueAt(c.data, s.path))));
  if (left.length) return {state: 'refused', problems: [...problems, `${left.length} reference(s) left after the downgrade`], dropped, inlined};
  for (const create of [createConversationStore, ...(validateWith ? [validateWith] : [])]) {
    const store = create({getItem: k => (k === STORAGE_KEY ? value : null), setItem: () => { throw Error('read-only'); }});
    if (store.error) return {state: 'refused', problems: [...problems, `the version-1 value does not load: ${store.error}`], dropped, inlined};
  }
  return {state: 'downgraded', value, problems, dropped, inlined, sha256: sha(value)};
}
