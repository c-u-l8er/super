import {createConversationStore} from './conversation-store.js';
export function worldLineage(world){try{const w=JSON.parse(world);return Array.isArray(w)&&w.length===3&&typeof w[0]==='string'&&Number.isSafeInteger(w[1])?JSON.stringify(w.slice(0,2)):null;}catch{return null;}}
export function taskHistoryLinks(history,taskId,world){
  const lineage=worldLineage(world);if(!lineage)return [];
  return ['codex','claude','ollama','openai','anthropic'].flatMap(provider=>history.list(provider).flatMap(c=>{
    const links=history.get(provider,c.id)?.taskLinks??[];
    const refs=links.filter(l=>l.taskId===taskId&&l.lineage===lineage);
    return refs.length?[{...c,provider,revisions:[...new Set(refs.map(l=>l.revision))].sort((a,b)=>a-b)}]:[];
  })).sort((a,b)=>b.updated.localeCompare(a.updated)||a.id.localeCompare(b.id));
}
export function botConversationHistory(storage,botId){return createConversationStore({getItem:key=>storage.getItem(botId==='assistant'?key:`${key}:bot:${botId}`),setItem:()=>{throw Error('Read-only history lookup');}});}
