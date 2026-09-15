// Read markers belong to this device, not to the shared conversation revision.
export const conversationKey=c=>JSON.stringify([c.botId,c.provider,c.id]);
export function conversationStatus(c,active){
 if(active?.id===c.id&&active?.botId===c.botId&&active?.provider===c.provider&&active?.generating)return active.liveText?'Generating':'Waiting';
 return c.state||'Ready';
}
export function readTracker(storage,key){
 let seen={},primed=false;try{const raw=storage.getItem(key);primed=raw!==null;seen=JSON.parse(raw||'{}');if(!seen||typeof seen!=='object'||Array.isArray(seen))seen={};}catch{}
 return {update(items,reading){let changed=false;const result=items.map(c=>{const id=conversationKey(c),count=c.messageCount||0;if(!Object.hasOwn(seen,id)||id===reading){const next=id===reading||!primed?count:0;if(seen[id]!==next){seen[id]=next;changed=true;}}return {...c,unread:count>seen[id]};});primed=true;if(changed){const keep=new Set(items.map(conversationKey));seen=Object.fromEntries(Object.entries(seen).filter(([id])=>keep.has(id)));try{storage.setItem(key,JSON.stringify(seen));}catch{}}return result;}};
}
export function conversationGroups(items,bots,{bot='all',sort='recent',search=''}={}){
 const rows=items.filter(c=>(bot==='all'||c.botId===bot)&&c.title.toLowerCase().includes(search.toLowerCase())).sort((a,b)=>Number(b.pinned)-Number(a.pinned)||b.updated.localeCompare(a.updated)||a.id.localeCompare(b.id));
 if(sort==='bot')return [...bots].sort((a,b)=>a.name.localeCompare(b.name)).map(b=>({label:b.name,items:rows.filter(c=>c.botId===b.id)})).filter(g=>g.items.length);
 return [{label:'Pinned',items:rows.filter(c=>c.pinned)},{label:'Recent',items:rows.filter(c=>!c.pinned)}].filter(g=>g.items.length);
}
