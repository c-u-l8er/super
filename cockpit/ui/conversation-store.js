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
/* T70 · a whole history, validated. `cap` is browser storage's 20-conversation limit; the file-backed history has
 * none (its bound is in bytes, HISTORY_BYTES). Everything else is the one rule both share. */
function validate(loaded, cap) {
  if (![1, 2].includes(loaded.version) || !Array.isArray(loaded.conversations) || (cap && loaded.conversations.length > cap)) throw new Error('Saved conversation format is not supported.');
  const out = { version: 2, conversations: [], selected: {} }, ids = new Set();
  out.conversations = loaded.conversations.map(c => {
    if (!PROVIDERS.has(c.provider) || ids.has(c.id)) throw new Error('Invalid saved conversation.');
    ids.add(c.id);
    return { id: string(c.id, 100), revision:Number.isSafeInteger(c.revision)?c.revision:1, provider: c.provider, title: string(c.title, 100), pinned: c.pinned === true, titleSource: ['manual','ai','attempted'].includes(c.titleSource)?c.titleSource:'fallback', updated: string(c.updated, 40), data: clean(c.data) };
  });
  for (const p of PROVIDERS) {
    if (out.conversations.some(c => c.provider === p && c.id === loaded.selected?.[p])) out.selected[p] = loaded.selected[p];
  }
  return out;
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
      return validate(JSON.parse(raw), 20);
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

/* T70 · the conversation history in files, through the host (`bodies.rs`, the `history_*` operations of the
 * `conversation_bodies` command): one file per conversation (named by its digest, its id inside) and an index per
 * history. Every change is published whole by the host in one operation (new files first, then the index), so a
 * history on disk is the previous publication or the next, never an index naming a file not written. Publications run
 * in order and each publishes the newest state, so a failed one is retried by the next. Browser storage is never
 * written: WebKit's quota is out of the path. No count cap; the bound is HISTORY_BYTES (and the host's 512 MiB over all).
 * A deletion is published like any change, but the conversation stays listed until the host has answered, and stays
 * whole if the host refused it.
 * The first open moves a history still in browser storage: staged, read back, compared, re-checked against the
 * browser value, promoted, and only then is the key removed. A staged copy found at start is compared again. */
export const HISTORY_BYTES = 256 * 1024 * 1024;
const INDEX_SCHEMA = 'conversation-history-index@1', FILE_SCHEMA = 'conversation-history-conversation@1';
const BEING_DELETED = 'This conversation is being deleted from this device; wait for that to finish.';
const EMPTY = () => ({version: 2, conversations: [], selected: {}});
const utf8 = t => new TextEncoder().encode(t).length;
const message = e => String(e?.message || e);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
/* The state less the conversations whose ids `gone` (a Set or a Map) holds. */
const without = (s, gone) => (!gone.size ? s : {version: 2, selected: Object.fromEntries(Object.entries(s.selected).filter(([, id]) => !gone.has(id))), conversations: s.conversations.filter(c => !gone.has(c.id))});
const encode = s => ({meta: JSON.stringify({schema: INDEX_SCHEMA, version: 2, selected: s.selected, conversations: s.conversations.map(({data, ...m}) => m)}), texts: s.conversations.map(c => JSON.stringify({schema: FILE_SCHEMA, id: c.id, provider: c.provider, data: c.data}))});
function decode(view) {
  const index = JSON.parse(view.meta);
  if (index?.schema !== INDEX_SCHEMA || !Array.isArray(index.conversations) || index.conversations.length !== view.texts.length) throw new Error('Saved conversation index format is not supported.');
  return validate({version: index.version, selected: index.selected, conversations: index.conversations.map((m, i) => {
    const f = JSON.parse(view.texts[i]);
    if (f?.schema !== FILE_SCHEMA || f.id !== m.id || f.provider !== m.provider) throw new Error('Invalid saved conversation.');
    return {...m, data: f.data};
  })}, 0);
}
const titleOf = value => (value.messages.find(m => m.role === 'user')?.content || value.draft || value.files[0]?.name || 'New conversation').trim().replace(/\s+/g, ' ').slice(0, 80) || 'New conversation';
const listOf = (state, provider) => state.conversations.filter(c => !provider || c.provider === provider).map(c => ({ id: c.id, revision:c.revision??1, provider:c.provider, title: c.title, pinned:c.pinned===true, titleSource:c.titleSource??'fallback', updated: c.updated, messageCount:c.data.entries.filter(e=>e.role==='assistant'||e.role==='result').length, state:c.data.replyPending?'Interrupted':c.data.entries.at(-1)?.role==='result'?'Needs attention':c.data.entries.at(-1)?.proposals?.length?'Needs review':c.data.draft?'Draft':'Ready' })).sort((a, b) => b.updated.localeCompare(a.updated));

export function openConversationHistory({invoke, key = STORAGE_KEY, bodies = null, legacy = null, maxBytes = HISTORY_BYTES}) {
  let state = EMPTY(), published = EMPTY(), error = null, loaded = false, chain = Promise.resolve(), seq = 0, done = 0;
  const sent = new Map(), marks = new Map(), outcomes = new Map(), removing = new Map(), listeners = new Set();
  const host = request => invoke('conversation_bodies', {request: {...request, history: key}});
  const emit = e => { for (const l of listeners) { try { l(e); } catch { /* a view's failure is its own */ } } };
  async function start() {
    const load = () => host({operation: 'history_load'}), abandon = () => host({operation: 'history_abandon'}).catch(() => {});
    let r = await load();
    const raw = legacy?.getItem(key) ?? null, from = raw === null ? null : validate(JSON.parse(raw), 0);
    const matches = view => { try { return !!view && !!from && same(decode(view), from); } catch { return false; } };
    if (!r.published && r.migrating && !matches(r.migrating)) { await host({operation: 'history_abandon'}); r.migrating = null; }
    if (!r.published && from) {
      if (!r.migrating) { const {meta, texts} = encode(from); await host({operation: 'history_publish', stage: true, meta, files: texts.map(text => ({text}))}); r = await load(); }
      if (!matches(r.migrating)) { await abandon(); throw new Error('the copy of browser storage did not read back as written; browser storage was left as it was'); }
      if (legacy.getItem(key) !== raw) { await abandon(); throw new Error('browser storage changed during the move; it was left as it was'); }
      await host({operation: 'history_promote'});
      r = await load();
    }
    if (r.published) {
      state = published = decode(r.published);
      state.conversations.forEach((c, i) => sent.set(c.id, [r.published.texts[i], r.published.files[i]]));
      if (from && legacy.getItem(key) === raw && same(state, from)) { try { legacy.removeItem(key); } catch { /* the files are the history now */ } }
    }
  }
  const ready = start().catch(e => { error = `Local history could not be loaded: ${message(e)}. Existing saved data was not changed.`; }).then(() => { loaded = true; emit({type: 'loaded'}); });
  function usable() {
    if (error) throw new Error(error);
    if (!loaded) throw new Error('Saved conversations are still being read from this device. Try again in a moment.');
  }
  function queue() { seq++; const run = chain.then(publish); chain = run.catch(() => {}); return run; }
  /* Take the new state and queue its publication; refused with nothing changed above the bound. */
  function change(next, ids) {
    usable();
    const {meta, texts} = encode(without(next, removing)), total = texts.reduce((n, t) => n + utf8(t), utf8(meta));
    if (total > maxBytes) throw new Error(`Saved conversations would exceed this device's history bound of ${maxBytes} bytes (this save makes ${total}). Delete an older saved conversation to make room; the previous history stays.`);
    state = next;
    const run = queue();
    for (const id of ids) { marks.set(id, seq); outcomes.set(id, {ok: false, saving: true, error: null, pending: [], revision: seq}); }
    return run;
  }
  /* Publish the newest state less pending deletions. Outcomes and events name only the saves it covers that nothing
   * newer superseded; a deletion it covers is settled with it: dropped on success, kept whole on failure. */
  async function publish() {
    if (done >= seq) return;
    const at = seq, gone = [...removing], s = without(state, removing), {meta, texts} = encode(s);
    const ids = [...marks].filter(([, m]) => m > done && m <= at).map(([id]) => id), live = () => ids.filter(id => marks.get(id) <= at);
    try {
      const r = await host({operation: 'history_publish', meta, files: texts.map((t, i) => { const p = sent.get(s.conversations[i].id); return p && p[0] === t ? {sha256: p[1]} : {text: t}; })});
      sent.clear(); s.conversations.forEach((c, i) => sent.set(c.id, [texts[i], r.files[i]]));
      published = s; done = at;
      for (const [id, d] of gone) { removing.delete(id); marks.delete(id); outcomes.delete(id); state = without(state, new Set([id])); d.resolve(); }
      const covered = live();
      for (const id of covered) outcomes.set(id, {ok: true, saving: false, error: null, pending: [], revision: marks.get(id)});
      emit({type: 'saved', revision: at, ids: covered});
    } catch (e) {
      const text = `Could not save on this device: ${message(e)} Your current conversation is still open.`, covered = live();
      for (const [id, d] of gone) { removing.delete(id); d.reject(e); }
      for (const id of covered) outcomes.set(id, {ok: false, saving: false, error: text, pending: [], revision: marks.get(id)});
      emit({type: 'failed', revision: at, ids: covered, error: text});
      throw new Error(text);
    }
  }
  const store = {
    get error() { return error; },
    get loaded() { return loaded; },
    ready,
    /** Resolves once every queued publication has been answered. */
    settled: () => chain.then(() => undefined),
    onChange(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    list: provider => listOf(state, provider),
    selected: provider => state.selected[provider] ?? null,
    get: (provider, id) => { const c = state.conversations.find(c => c.provider === provider && c.id === id); return c ? clean(c.data) : null; },
    /** What the host has published for this conversation; a card is "saved" only against this. */
    committed: (provider, id) => { const c = published.conversations.find(c => c.provider === provider && c.id === id); return c ? clean(c.data) : null; },
    outcome: id => outcomes.get(id) ?? null,
    owner: id => bodyOwner(key, id),
    save(provider, id, data) {
      if (!PROVIDERS.has(provider)) throw new Error('Invalid conversation provider.');
      const value = clean(data);
      usable();
      if (removing.has(id)) throw new Error(BEING_DELETED);
      const previous = state.conversations.find(c => c.id === id);
      if (previous && previous.provider !== provider) throw new Error('Conversation belongs to another provider.');
      id = previous?.id ?? crypto.randomUUID();
      const owner = bodyOwner(key, id);
      let saved = value, unpersisted = [];
      if (bodies) ({data: saved, unpersisted} = bodies.slim(value, owner));
      const record = { id, revision:(previous?.revision??0)+1, provider, title:previous?.titleSource&&previous.titleSource!=='fallback'?previous.title:titleOf(value), pinned:previous?.pinned===true, titleSource:previous?.titleSource??'fallback', updated: previous&&same(previous.data, saved)?previous.updated:new Date().toISOString(), data: saved };
      try { change({version: 2, selected: {...state.selected, [provider]: id}, conversations: [...state.conversations.filter(c => c.id !== id), record]}, [id]); }
      catch (e) { outcomes.set(id, {ok: false, saving: false, error: message(e), pending: [], revision: seq}); throw e; }
      if (bodies && unpersisted.length)
        bodies.persist(owner, unpersisted).then(() => store.refresh(provider, id), () => store.refresh(provider, id));
      return id;
    },
    /** Rewrite a record so every body persisted since it was saved is a reference. Bytes are never dropped. */
    refresh(provider, id) {
      if (!bodies || error || !loaded || removing.has(id)) return false;
      const previous = state.conversations.find(c => c.id === id && c.provider === provider);
      if (!previous) return false;
      const {data} = bodies.slim(previous.data, bodyOwner(key, id));
      if (same(data, previous.data)) return false;
      try { change({...state, conversations: state.conversations.map(c => c === previous ? {...previous, revision: (previous.revision ?? 1) + 1, data} : c)}, [id]); return true; }
      catch { return false; }
    },
    /** Resolves when the host has published the change; rejects with its failure. */
    update(provider, id, patch) {
      const previous = state.conversations.find(c => c.id === id && c.provider === provider);
      if (!previous) throw new Error('Conversation is unavailable.');
      if (removing.has(id)) throw new Error(BEING_DELETED);
      const next = {...previous, revision: (previous.revision ?? 1) + 1};
      if (typeof patch.pinned === 'boolean') next.pinned = patch.pinned;
      if (patch.title !== undefined) {
        const title = string(patch.title, 100).trim().replace(/\s+/g, ' ');
        if (!title) throw new Error('Enter a conversation title.');
        if (patch.titleSource === 'ai' && previous.titleSource === 'manual') return Promise.resolve();
        next.title = title; next.titleSource = patch.titleSource === 'ai' ? 'ai' : 'manual';
      } else if (patch.titleSource === 'attempted' && previous.titleSource === 'fallback') next.titleSource = 'attempted';
      return change({...state, conversations: state.conversations.map(c => c === previous ? next : c)}, [id]);
    },
    /** The conversation leaves the list only once the host has published its deletion; on a refusal it stays whole.
     *  Its bodies are released only after that publication. */
    remove(provider, id) {
      usable();
      if (removing.has(id)) return removing.get(id).result;
      if (!state.conversations.some(c => c.provider === provider && c.id === id)) return Promise.resolve(null);
      const d = {};
      d.result = new Promise((resolve, reject) => { d.resolve = resolve; d.reject = reject; }).then(
        () => (bodies ? bodies.release(bodyOwner(key, id)).catch(e => ({released: 0, error: message(e)})) : null),
        e => { throw new Error(`The deletion was not saved on this device (${message(e)}); the conversation is still here.`); });
      removing.set(id, d);
      queue().catch(() => {});
      return d.result;
    },
  };
  return store;
}

const opened = new Map();
export const historyKey = botId => (botId === 'assistant' ? STORAGE_KEY : `${STORAGE_KEY}:bot:${botId}`);
/** The page's one store per history: its saves run in order and no stale copy rewrites it. */
export function historyStore(options) {
  const key = options.key ?? STORAGE_KEY;
  if (!opened.has(key)) opened.set(key, openConversationHistory({...options, key}));
  return opened.get(key);
}
/** T71 · a bot's opened file-backed history, read-only, by its bot id (null if not opened); `ready` resolves once
 *  it has been read. */
export function openedHistory(botId) {
  const s = opened.get(historyKey(botId));
  return s ? {ready: s.ready, get error() { return s.error; }, get loaded() { return s.loaded; }, list: s.list, get: s.get, selected: s.selected} : null;
}
/** Every history still in browser storage, rostered or not, is opened (and so moved) now. */
export function moveBrowserHistories({invoke, bodies = null, legacy}) {
  const keys = [];
  try { for (let i = 0; i < legacy.length; i++) { const k = legacy.key(i); if (k === STORAGE_KEY || k?.startsWith(`${STORAGE_KEY}:bot:`)) keys.push(k); } }
  catch { /* no browser storage: nothing to move */ }
  return keys.map(key => historyStore({invoke, key, bodies, legacy}));
}
/** T70 · confirm a save in the store it was made in, never another: resolves to `id` only once that store's host
 *  has answered with success for it; a failure, or no save recorded there, rejects. */
export async function confirmSaved(store, id) {
  for (let i = 0; i < 1000; i++) {
    await store.settled();
    const o = store.outcome(id);
    if (!o) throw new Error('This conversation has no save on this device to confirm.');
    if (o.saving) continue;
    if (!o.ok) throw new Error(o.error || 'Could not save on this device.');
    return id;
  }
  throw new Error('The save on this device did not finish.');
}
/** T70 · a title or pin change whose failure is reported, never left unhandled. Resolves to whether it was published. */
export function settledUpdate(store, provider, id, patch, report) {
  let run;
  try { run = Promise.resolve(store.update(provider, id, patch)); } catch (e) { run = Promise.reject(e); }
  return run.then(() => true, e => { report(message(e)); return false; });
}
/** T70 · delete, and let `cleared` clear what shows the conversation only once the host has published the deletion;
 *  on a failure only `failed` runs, and nothing is cleared. Resolves to whether it was published. */
export function deleteWhenPublished(store, provider, id, {cleared, failed}) {
  let run;
  try { run = store.remove(provider, id); } catch (e) { run = Promise.reject(e); }
  return Promise.resolve(run).then(r => { cleared(r); return true; }, e => { failed(message(e)); return false; });
}
/** T70 · the bot page's conversation actions. `bots.js` runs its phone create branches, its phone draft, every title
 *  change and both deletion controls through these, over its `view`, so the tests drive the handlers the page runs.
 *  Each captures the store and the id it acts on before it waits, and nothing the view shows is cleared before that
 *  store's host has answered. `view`: botId(), provider(), conversationId(), sessions (provider -> {conversationId}),
 *  saveCurrent(), snapshot(), opened(id), fresh(text), adopt(id), setDraft(text), hold(on), reset(), status(text),
 *  changed(). */
export function createConversationActions({storeFor, view}) {
  return {
    /** A phone-created conversation, from a task discussion's `data` or a draft `text`: resolves to the id saved, once
     *  the store it was saved in has published it; rejects on a failure there. */
    async create(provider, {data = null, text = ''} = {}) {
      const store = storeFor(view.botId());
      if (!view.saveCurrent()) throw new Error('Could not save the desktop draft.');
      let id;
      if (data) { id = store.save(provider, null, data); view.opened(id); }
      else { view.fresh(text); id = store.save(provider, null, view.snapshot()); view.adopt(id); }
      return confirmSaved(store, id);
    },
    /** The phone's draft of the open conversation: confirmed in the store and for the id it was saved under. */
    async draft(text) {
      const store = storeFor(view.botId());
      view.setDraft(text);
      if (!view.saveCurrent()) throw new Error('Could not save the shared draft.');
      const id = view.conversationId();
      return confirmSaved(store, id);
    },
    /** A title or pin change for any bot, open or not: resolves to null once published, or to the failure it reported. */
    async title(botId, provider, id, patch) {
      let failure = null;
      const report = text => { failure = text; view.status(`The conversation title was not saved on this device: ${text}`); };
      try { await settledUpdate(storeFor(botId), provider, id, patch, report); } catch (e) { report(message(e)); }
      return failure;
    },
    /** Either deletion control. Until the host answers, the conversation stays listed, its session is kept and, if it
     *  is open, its draft is held read-only; after a failure all of it stays. Resolves to whether it was deleted. */
    remove(botId, provider, id) {
      const showing = () => view.botId() === botId && view.provider() === provider && view.conversationId() === id, held = showing();
      if (held) view.hold(true);
      view.status('Deleting from this device…');
      let store;
      try { store = storeFor(botId); } catch (e) { store = {remove: () => { throw e; }}; }
      return deleteWhenPublished(store, provider, id, {
        cleared: r => {
          if (held) view.hold(false);
          if (view.botId() === botId && view.sessions.get(provider)?.conversationId === id) view.sessions.delete(provider);
          if (showing()) view.reset();
          view.status(r?.error ? `Conversation deleted from this device. Its saved bodies could not be released (${r.error}); they stay on this device.` : `Conversation deleted from this device${r?.released ? `; ${r.released} saved bod${r.released === 1 ? 'y' : 'ies'} released` : ''}.`);
          view.changed();
        },
        failed: text => { if (held) view.hold(false); view.status(text); view.changed(); },
      });
    },
  };
}
