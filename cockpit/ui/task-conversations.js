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

// The phone supplies only identity. Draft content comes from a live desktop view.
export function taskDiscussion(projection,world,context){
 const lineage=worldLineage(world),task=projection?.development_tasks?.[context?.taskId];
 if(!lineage||!context||context.lineage!==lineage||!task||!Number.isSafeInteger(context.revision)||context.revision<1||task.revision!==context.revision)
  throw Error('This task changed or is unavailable. Reopen its review before starting a discussion.');
 const draft=`Discuss this task: ${task.title}
Task: ${task.id} · Revision ${task.revision}
Status: ${task.status}

Acceptance criteria:
${task.criteria||'No criteria recorded.'}

Help me review the next step.`;
 if(draft.length>8000)throw Error('This task is too large for a mobile draft. Start its discussion on desktop.');
 return {messages:[],entries:[],files:[],includeContext:false,draft,taskLinks:[{taskId:task.id,revision:task.revision,lineage}]};
}
