// The desktop remains the single owner of conversation history and provider calls.
// Persist a request receipt BEFORE dispatch. An interrupted dispatch is never replayed.
const KEY='super-mobile-conversation-receipts-v1';
export function requestLedger(storage,now=Date.now){
 let entries;try{entries=JSON.parse(storage.getItem(KEY)||'[]');if(!Array.isArray(entries))throw Error();}catch{throw Error('Mobile request history is unreadable. No mobile changes were made.');}
 const write=()=>storage.setItem(KEY,JSON.stringify(entries));
 return {async run(request,perform){
  const encoded=JSON.stringify(request),hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(encoded)))).map(b=>b.toString(16).padStart(2,'0')).join('');
  const old=entries.find(e=>e.id===request.id);
  if(old){if(old.hash!==hash)throw Error('Request identity was reused with different content.');return old.receipt;}
  if(!Number.isSafeInteger(request.createdAt)||Math.abs(now()-request.createdAt)>120000)throw Error('This request expired. Refresh before making a new request.');
  entries=entries.filter(e=>now()-e.at<300000);if(entries.length>=500)throw Error('Too many mobile requests. Wait before trying again.');
  const entry={id:request.id,hash,at:now(),receipt:{id:request.id,state:'uncertain',message:'Dispatch was interrupted or is still running. Inspect the conversation before sending again.'}};
  entries.push(entry);write();
  try{const result=await perform(request);entry.receipt={id:request.id,state:'done',...result};}
  catch(error){entry.receipt={id:request.id,state:'error',message:String(error.message||error)};}
  write();return entry.receipt;
 }};
}
export function initMobileConversationBridge({invoke,view,perform,storage=localStorage}){
 let ledger;try{ledger=requestLedger(storage);}catch{return;}
 let previous='',receipts=[];
 async function tick(){
  try{
   const next=view(),raw=JSON.stringify(next),request={receipts};if(raw!==previous)request.view=next;
   const reply=await invoke('conversation_exchange',{request});previous=raw;receipts=[];
   for(const command of reply.requests??[]){try{receipts.push(await ledger.run(command,perform));}catch(error){receipts.push({id:command.id,state:'error',message:String(error.message||error)});}}
  }catch{previous='';}
  setTimeout(tick,750);
 }
 tick();
}
