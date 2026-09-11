/* Local presentation history. Never stores credentials, runtime authority, or
 * executable proposals. Failed writes leave the previous saved history intact. */
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
function files(value) {
  return array(value, 4, f => ({ name: string(f.name, 255), content: string(f.content, 32000) }));
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
        proposals: array(e.proposals ?? [], 8, p => string(p, 20000)) };
    }),
    draft: string(data.draft, 8000), files: files(data.files),
    includeContext: data.includeContext === true, replyPending: data.replyPending === true,
  };
}
export function createConversationStore(storage) {
  let state = { version: 1, conversations: [], selected: {} }, error = null;
  try {
    const raw = storage.getItem(STORAGE_KEY);
    if (raw) {
      if (raw.length > MAX_SIZE) throw new Error('Saved conversations exceed the supported limit.');
      const loaded = JSON.parse(raw);
      if (loaded.version !== 1 || !Array.isArray(loaded.conversations) || loaded.conversations.length > 20) throw new Error('Saved conversation format is not supported.');
      const ids = new Set();
      state.conversations = loaded.conversations.map(c => {
        if (!PROVIDERS.has(c.provider) || ids.has(c.id)) throw new Error('Invalid saved conversation.');
        ids.add(c.id);
        return { id: string(c.id, 100), provider: c.provider, title: string(c.title, 100), updated: string(c.updated, 40), data: clean(c.data) };
      });
      for (const p of PROVIDERS) {
        if (state.conversations.some(c => c.provider === p && c.id === loaded.selected?.[p])) state.selected[p] = loaded.selected[p];
      }
    }
  } catch (e) { error = `Local history could not be loaded: ${e.message}. Existing saved data was not changed.`; }
  function commit(next) {
    if (error) throw new Error(error);
    const raw = JSON.stringify(next);
    if (raw.length > MAX_SIZE) throw new Error('Local history is full. Delete an older saved conversation to make room.');
    try { storage.setItem(STORAGE_KEY, raw); }
    catch { throw new Error('Could not save locally. Your current conversation is still open; free storage before closing Super.'); }
    state = next;
  }
  return {
    error,
    list: provider => state.conversations.filter(c => c.provider === provider).map(c => ({ id: c.id, title: c.title, updated: c.updated })).sort((a, b) => b.updated.localeCompare(a.updated)),
    selected: provider => state.selected[provider] ?? null,
    get: (provider, id) => {
      const c = state.conversations.find(c => c.provider === provider && c.id === id);
      return c ? clean(c.data) : null;
    },
    save(provider, id, data) {
      if (!PROVIDERS.has(provider)) throw new Error('Invalid conversation provider.');
      const value = clean(data);
      const previous = state.conversations.find(c => c.id === id);
      if (previous && previous.provider !== provider) throw new Error('Conversation belongs to another provider.');
      if (!previous && state.conversations.length >= 20) throw new Error('You have 20 saved conversations. Delete an older one to make room.');
      id = previous?.id ?? crypto.randomUUID();
      const title = (value.messages.find(m => m.role === 'user')?.content || value.draft || value.files[0]?.name || 'New conversation').trim().replace(/\s+/g, ' ').slice(0, 80) || 'New conversation';
      const record = { id, provider, title, updated: new Date().toISOString(), data: value };
      commit({ version: 1, selected: { ...state.selected, [provider]: id }, conversations: [...state.conversations.filter(c => c.id !== id), record] });
      return id;
    },
    remove(provider, id) {
      const selected = { ...state.selected };
      if (selected[provider] === id) delete selected[provider];
      commit({ version: 1, selected, conversations: state.conversations.filter(c => !(c.provider === provider && c.id === id)) });
    },
  };
}
