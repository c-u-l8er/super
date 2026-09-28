import {REVIEW_FILE_BYTES} from './review-limits.js';
import {validateRecoveryShape} from './proposal-recovery.js';
import {isBodyRef, validBodyRef, inlineBodies} from './conversation-bodies.js';
/* Local presentation history. Never stores credentials, runtime authority, or
 * executable proposals. Failed writes leave the previous saved history intact.
 *
 * T24 · version 2. File bodies (attachments, draft files, a proposal's draft, original and content) may be
 * references to the device body store (`conversation-bodies.js`, `cockpit/src/bodies.rs`) instead of inline text.
 * A version-1 store loads unchanged; every write is version 2. The version-1 code refuses a version-2 store as
 * "not supported" and changes nothing, so a rollback cannot misread one. */
export const STORAGE_KEY = 'super-conversations-v1';
const PROVIDERS = new Set(['codex', 'claude', 'ollama', 'openai', 'anthropic']);
const MAX_SIZE = 3_000_000;
function string(value, max) {
  if (typeof value !== 'string' || value.length > max) throw new Error('Conversation exceeds the supported text limit.');
  return value;
}
function array(value, max, convert) {
  if (!Array.isArray(value) || value.length > max) throw new Error('Conversation exceeds the supported history limit.');
  return value.map(convert);
}
const body = (value, max) => (isBodyRef(value) ? validBodyRef(value) : string(value, max));
/* T24 · where a proposal came from, and what replaced it. Small, bounded, and recorded only for proposals made after
 * T24: an older record without them is not given invented ones. */
function position(p) {
  if (!p || !Number.isSafeInteger(p.entry) || p.entry < 0 || !Number.isSafeInteger(p.index) || p.index < 0) throw new Error('Invalid proposal position.');
  return {entry: p.entry, index: p.index};
}
function provenance(v) {
  const opt = (x, max) => (x === null || x === undefined ? null : string(x, max));
  return {provider: string(v.provider, 40), model: opt(v.model, 200), request_id: opt(v.request_id, 100), received_at: string(v.received_at, 40)};
}
/* A proposal is either its saved text (history only) or {text, recovery}: the text plus the record
 * that lets the Editor review it after a restart. A recovery record that does not validate is a
 * hard error, never silently downgraded to text: a proposal must not lose its basis on the way
 * through storage without anyone noticing. */
function proposal(p) {
  if (typeof p === 'string') return string(p, 20000);
  if (!p || typeof p !== 'object') throw new Error('Invalid saved proposal.');
  const out = { text: string(p.text, 20000), recovery: validateRecoveryShape(p.recovery) };
  if (p.provenance) out.provenance = provenance(p.provenance);
  if (p.supersedes?.length) out.supersedes = array(p.supersedes, 8, position);
  if (p.superseded_by) out.superseded_by = position(p.superseded_by);
  return out;
}
function files(value) {
  return array(value, 4, f => ({ name: string(f.name, 255), content: body(f.content, REVIEW_FILE_BYTES) }));
}
function clean(data) {
  return {
    ...(data.taskLinks?.length?{taskLinks:array(data.taskLinks,80,l=>{
      if(!Number.isSafeInteger(l.revision)||l.revision<1)throw new Error('Invalid task conversation revision.');
      const lineage=JSON.parse(string(l.lineage,500));
      if(!Array.isArray(lineage)||lineage.length!==2||typeof lineage[0]!=='string'||!Number.isSafeInteger(lineage[1]))throw new Error('Invalid task conversation world.');
      return {taskId:string(l.taskId,100),revision:l.revision,lineage:JSON.stringify(lineage)};
    })}:{}),
    messages: array(data.messages, 80, m => {
      if (!['user', 'assistant'].includes(m.role)) throw new Error('Invalid saved message.');
      return { role: m.role, content: string(m.content, 160000), attachments: files(m.attachments ?? []) };
    }),
    entries: array(data.entries, 180, e => {
      if (!['user', 'assistant', 'result'].includes(e.role)) throw new Error('Invalid saved conversation entry.');
      return { referenceWorld: typeof e.referenceWorld==='string'?string(e.referenceWorld,500):null, role: e.role, label: string(e.label, 500), text: string(e.text, 160000),
        proposals: array(e.proposals ?? [], 8, proposal) };
    }),
    draft: string(data.draft, 8000), files: files(data.files),
    includeContext: data.includeContext === true, replyPending: data.replyPending === true,
  };
}
/** The owner a conversation's bodies are held under in the device body store. */
export const bodyOwner = (key, id) => `conv:${key}:${id}`;
/**
 * `options.bodies` — the device body service. Without it (read-only lookups, older tests) the store behaves as it
 * did: whatever it is given is saved as it is.
 * `options.key` — the localStorage key this store is really kept under, which names the bodies' owner.
 */
export function createConversationStore(storage, {bodies = null, key = STORAGE_KEY} = {}) {
  let state = { version: 2, conversations: [], selected: {} }, error = null;
  const outcomes = new Map(); // conversation id -> {ok, error, pending: [texts]}
  /* The stored value, parsed and validated. Used at construction, and again by `refresh`, which must work on what
   * is in storage NOW: several store objects can exist for one key (the live bot's and short-lived ones), and a
   * delayed rewrite from a stale one would overwrite newer conversations. */
  function read() {
    const out = { version: 2, conversations: [], selected: {} };
    const raw = storage.getItem(STORAGE_KEY);
    if (raw) {
      if (raw.length > MAX_SIZE) throw new Error('Saved conversations exceed the supported limit.');
      const loaded = JSON.parse(raw);
      if (![1, 2].includes(loaded.version) || !Array.isArray(loaded.conversations) || loaded.conversations.length > 20) throw new Error('Saved conversation format is not supported.');
      const ids = new Set();
      out.conversations = loaded.conversations.map(c => {
        if (!PROVIDERS.has(c.provider) || ids.has(c.id)) throw new Error('Invalid saved conversation.');
        ids.add(c.id);
        return { id: string(c.id, 100), revision:Number.isSafeInteger(c.revision)?c.revision:1, provider: c.provider, title: string(c.title, 100), pinned: c.pinned === true, titleSource: ['manual','ai','attempted'].includes(c.titleSource)?c.titleSource:'fallback', updated: string(c.updated, 40), data: clean(c.data) };
      });
      for (const p of PROVIDERS) {
        if (out.conversations.some(c => c.provider === p && c.id === loaded.selected?.[p])) out.selected[p] = loaded.selected[p];
      }
    }
    return out;
  }
  try { state = read(); }
  catch (e) { error = `Local history could not be loaded: ${e.message}. Existing saved data was not changed.`; }
  function commit(next) {
    if (error) throw new Error(error);
    const raw = JSON.stringify({...next, version: 2});
    if (raw.length > MAX_SIZE) throw new Error('Local history is full. Delete an older saved conversation to make room.');
    try { storage.setItem(STORAGE_KEY, raw); }
    catch { throw new Error('Could not save locally. Your current conversation is still open; free storage before closing Super.'); }
    state = {...next, version: 2};
  }
  const store = {
    error,
    list: provider => state.conversations.filter(c => !provider || c.provider === provider).map(c => ({ id: c.id, revision:c.revision??1, provider:c.provider, title: c.title, pinned:c.pinned===true, titleSource:c.titleSource??'fallback', updated: c.updated, messageCount:c.data.entries.filter(e=>e.role==='assistant'||e.role==='result').length, state:c.data.replyPending?'Interrupted':c.data.entries.at(-1)?.role==='result'?'Needs attention':c.data.entries.at(-1)?.proposals?.length?'Needs review':c.data.draft?'Draft':'Ready' })).sort((a, b) => b.updated.localeCompare(a.updated)),
    selected: provider => state.selected[provider] ?? null,
    get: (provider, id) => {
      const c = state.conversations.find(c => c.provider === provider && c.id === id);
      return c ? clean(c.data) : null;
    },
    /** How the last save of this conversation went: `ok`, the error if not, and the texts it could only save as
     *  pending placeholders. A card is "saved" only against this. */
    outcome: id => outcomes.get(id) ?? null,
    owner: id => bodyOwner(key, id),
    save(provider, id, data) {
      if (!PROVIDERS.has(provider)) throw new Error('Invalid conversation provider.');
      const value = clean(data);
      const previous = state.conversations.find(c => c.id === id);
      if (previous && previous.provider !== provider) throw new Error('Conversation belongs to another provider.');
      if (!previous && state.conversations.length >= 20) throw new Error('You have 20 saved conversations. Delete an older one to make room.');
      id = previous?.id ?? crypto.randomUUID();
      const owner = bodyOwner(key, id);
      let saved = value, unpersisted = [];
      if (bodies) ({data: saved, unpersisted} = bodies.slim(value, owner));
      const title = (value.messages.find(m => m.role === 'user')?.content || value.draft || value.files[0]?.name || 'New conversation').trim().replace(/\s+/g, ' ').slice(0, 80) || 'New conversation';
      const record = data => ({ id, revision:(previous?.revision??0)+1, provider, title:previous?.titleSource&&previous.titleSource!=='fallback'?previous.title:title, pinned:previous?.pinned===true, titleSource:previous?.titleSource??'fallback', updated: previous&&JSON.stringify(previous.data)===JSON.stringify(data)?previous.updated:new Date().toISOString(), data });
      const next = data => ({ version: 2, selected: { ...state.selected, [provider]: id }, conversations: [...state.conversations.filter(c => c.id !== id), record(data)] });
      let pending = [];
      try { commit(next(saved)); }
      catch (first) {
        /* Only bodies that are NEW in memory may become placeholders. A body the committed record already holds
         * inline stays inline: replacing it would drop bytes that survive a restart today. */
        const committed = inlineBodies(previous?.data);
        pending = bodies ? unpersisted.filter(t => !committed.has(t)) : [];
        if (!pending.length) { outcomes.set(id, {ok: false, error: String(first.message || first), pending: []}); throw first; }
        try { commit(next(bodies.pendingize(saved, owner, pending))); }
        catch (second) { outcomes.set(id, {ok: false, error: String(second.message || second), pending: []}); throw second; }
      }
      outcomes.set(id, {ok: true, error: null, pending});
      if (bodies && unpersisted.length)
        bodies.persist(owner, unpersisted).then(() => store.refresh(provider, id), () => store.refresh(provider, id));
      return id;
    },
    /** Rewrite a committed record so every body persisted since it was saved is a reference. Bytes are never
     *  dropped: an inline text stays inline and a placeholder stays a placeholder unless its reference exists. */
    refresh(provider, id) {
      if (!bodies || error) return false;
      let fresh;
      try { fresh = read(); } catch { return false; }
      const previous = fresh.conversations.find(c => c.id === id && c.provider === provider);
      if (!previous) return false;
      const owner = bodyOwner(key, id);
      const {data} = bodies.slim(previous.data, owner);
      const outcome = outcomes.get(id);
      const stillPending = (outcome?.pending ?? []).filter(t => bodies.stateOf(owner, t) !== 'persisted');
      if (JSON.stringify(data) === JSON.stringify(previous.data)) {
        state = fresh;
        if (outcome) outcomes.set(id, {...outcome, pending: stillPending});
        return false;
      }
      try {
        // Read and write happen in one synchronous step: nothing can save in between.
        commit({...fresh, conversations: fresh.conversations.map(c => c === previous ? {...previous, revision: (previous.revision ?? 1) + 1, data} : c)});
        outcomes.set(id, {ok: true, error: null, pending: stillPending});
        return true;
      } catch (e) {
        outcomes.set(id, {ok: outcome?.ok ?? false, error: outcome?.error ?? null, pending: stillPending, refreshError: String(e.message || e)});
        return false;
      }
    },
    update(provider,id,patch) {
      const previous=state.conversations.find(c=>c.id===id&&c.provider===provider);
      if(!previous)throw new Error('Conversation is unavailable.');
      const next={...previous,revision:(previous.revision??1)+1};
      if(typeof patch.pinned==='boolean')next.pinned=patch.pinned;
      if(patch.title!==undefined){
        const title=string(patch.title,100).trim().replace(/\s+/g,' ');
        if(!title)throw new Error('Enter a conversation title.');
        if(patch.titleSource==='ai'&&previous.titleSource==='manual')return;
        next.title=title;next.titleSource=patch.titleSource==='ai'?'ai':'manual';
      }else if(patch.titleSource==='attempted'&&previous.titleSource==='fallback')next.titleSource='attempted';
      commit({...state,conversations:state.conversations.map(c=>c===previous?next:c)});
    },
    /** Delete the record FIRST; release its bodies only after that is committed. A failed release keeps bodies
     *  nobody references (a leak), never the other way round. */
    remove(provider, id) {
      const selected = { ...state.selected };
      if (selected[provider] === id) delete selected[provider];
      const had = state.conversations.some(c => c.provider === provider && c.id === id);
      commit({ version: 2, selected, conversations: state.conversations.filter(c => !(c.provider === provider && c.id === id)) });
      outcomes.delete(id);
      return had && bodies ? bodies.release(bodyOwner(key, id)) : Promise.resolve(null);
    },
  };
  return store;
}
