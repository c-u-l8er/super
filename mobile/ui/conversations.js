const el=(tag,text)=>{const n=document.createElement(tag);if(text!=null)n.textContent=text;return n;};
export function initConversations(root,visible){
 const conflict=el('div'),keep=el('button','Keep my draft against this revision'),useDesktop=el('button','Use desktop draft');
 const heading=el('h1','Conversations'),note=el('p'),list=el('div'),title=el('input'),rename=el('button','Save title'),pin=el('button','Pin'),fresh=el('button','New conversation'),messages=el('div'),live=el('pre'),draft=el('textarea'),model=el('input'),effort=el('select'),send=el('button','Send'),save=el('button','Save draft to desktop'),retry=el('button','Retry pending request');
 title.maxLength=100;title.setAttribute('aria-label','Conversation title');draft.maxLength=8000;draft.rows=4;draft.setAttribute('aria-label','Message');model.setAttribute('aria-label','Exact connected model');model.placeholder='Enter the exact connected model';effort.setAttribute('aria-label','Thinking level');
 const label=(text,input)=>{const n=el('label',text);n.append(input);return n;};
 for(const b of [rename,pin,fresh,save,send])b.disabled=true;retry.hidden=true;
 root.append(heading,note,list,fresh,label('Title',title),rename,pin,messages,live,label('Message',draft),conflict,keep,useDesktop,label('Model (required for Send)',model),label('Thinking',effort),save,send,retry);
 let view=null,key='',pending=null,lastMessages='',dirty=false,draftRevision=null,titleRevision=null,titleDirty=false;try{pending=JSON.parse(localStorage.getItem('super-mobile-pending')||'null')}catch{}
 const draftKey=()=> 'super-mobile-draft:'+key;
 const api=async(path,body)=>{const r=await fetch('/api/'+path,{method:body?'POST':'GET',headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(5000)});const data=await r.json();if(!r.ok||data.error)throw Object.assign(Error(data.error||'Conversation connection unavailable.'),{refused:!!data.error&&r.status!==503});return data;};
 const persist=()=>localStorage.setItem('super-mobile-pending',JSON.stringify(pending));
 const dispatch=async(first=false)=>{try{await api('conversation',pending);note.textContent='Request received. Waiting for desktop confirmation.';}catch(e){const refused=first===true&&e.refused;if(refused){pending=null;persist();}note.textContent=e.message+(refused?' Nothing queued; your draft is retained.':' Your draft is retained; retry uses the same request identity.');}};
 const command=async(operation,extra={})=>{
  if(pending)return;const a=view?.active;if(!a)return;
  pending={id:crypto.randomUUID(),createdAt:Date.now(),operation,botId:a.botId,provider:a.provider,conversationId:a.id,revision:operation==='draft'||operation==='send'?(draftRevision??a.revision):operation==='update'&&extra.title!==undefined?(titleRevision??a.revision):a.revision,...extra};
  try{persist();await dispatch(true);}catch(e){pending=null;note.textContent='Could not retain request locally. Nothing sent.';}
 };
 title.oninput=()=>{titleDirty=true};
 title.onfocus=()=>{titleRevision=view?.active.revision};
 keep.onclick=()=>{draftRevision=view.active.revision;localStorage.setItem(draftKey(),JSON.stringify({text:draft.value,revision:draftRevision}));};useDesktop.onclick=()=>{dirty=false;localStorage.removeItem(draftKey());draft.value=view.active.data?.draft??'';};
 draft.oninput=()=>{if(!dirty)draftRevision=view?.active.revision;dirty=true;try{localStorage.setItem(draftKey(),JSON.stringify({text:draft.value,revision:draftRevision}));}catch{note.textContent='Could not save this draft locally.';}};
 rename.onclick=()=>command('update',{title:title.value});pin.onclick=()=>command('update',{pinned:!view?.conversations?.find(c=>c.id===view.active.id&&c.botId===view.active.botId)?.pinned});fresh.onclick=()=>command('create');
 save.onclick=()=>command('draft',{text:draft.value});send.onclick=()=>command('send',{text:draft.value,model:model.value.trim(),effort:effort.value});retry.onclick=()=>dispatch();
 async function poll(){
  if(visible())try{
   const data=await api('conversations');if(!data.available)throw Error('Desktop conversation view unavailable. Draft retained on this device.');view=data.view;
   if(pending){const receipt=data.receipts?.find(r=>r.id===pending.id);if(receipt){note.textContent=receipt.message;if(receipt.state==='done'&&pending.operation==='update')titleDirty=false;const sent=pending.operation==='send',sentKey=JSON.stringify([pending.botId,pending.provider,pending.conversationId]);if(receipt.state==='done'&&pending.operation==='draft'&&draft.value===pending.text&&view.active.data?.draft===pending.text){dirty=false;draftRevision=view.active.revision;localStorage.removeItem(draftKey());}pending=null;persist();if(receipt.state==='done'&&sent){localStorage.removeItem('super-mobile-draft:'+sentKey);if(key===sentKey){dirty=false;draft.value='';}}}}
   const a=view.active,newKey=JSON.stringify([a.botId,a.provider,a.id]);
   if(key!==newKey){key=newKey;const saved=localStorage.getItem(draftKey());dirty=saved!==null;const local=saved?JSON.parse(saved):null;draft.value=local?.text??a.data?.draft??'';draftRevision=local?.revision??a.revision;titleRevision=null;titleDirty=false;model.value='';lastMessages='';}
   else if(!dirty&&document.activeElement!==draft)draft.value=a.data?.draft??'';
   if(!pending&&!note.textContent)note.textContent='Shared with desktop. Opening a conversation also opens it there.';
   list.replaceChildren();for(const bot of view.bots){const b=el('button','Open bot · '+bot.name);b.disabled=!!pending||a.busy;b.onclick=()=>command('open',{botId:bot.id,provider:bot.provider,conversationId:null});list.append(b);}for(const c of [...view.conversations].sort((x,y)=>Number(y.pinned)-Number(x.pinned)||y.updated.localeCompare(x.updated))){const b=el('button',(c.pinned?'Pinned · ':'')+(view.bots.find(b=>b.id===c.botId)?.name??c.botId)+' · '+c.title);b.disabled=!!pending||a.busy;b.onclick=()=>command('open',{botId:c.botId,provider:c.provider,conversationId:c.id,revision:c.revision});list.append(b);}
   const c=view.conversations.find(c=>c.id===a.id&&c.botId===a.botId);if(!titleDirty&&document.activeElement!==title)title.value=c?.title??'';pin.textContent=c?.pinned?'Unpin':'Pin';
   model.placeholder=a.model?'Connected: '+a.model+' — enter to confirm':'Connect a provider on desktop';
   const levels=JSON.stringify(a.efforts);if(effort.dataset.levels!==levels){effort.dataset.levels=levels;effort.replaceChildren(...(a.efforts??['']).map(v=>{const o=el('option',v||'Provider effort');o.value=v;return o;}));effort.value=a.effort;}
   const raw=JSON.stringify(a.data?.entries??[]);if(raw!==lastMessages){messages.replaceChildren();for(const e of a.data?.entries??[]){messages.append(el('h3',e.label||e.role),el('p',e.text));}lastMessages=raw;}
   const changed=dirty&&draftRevision!==a.revision;conflict.hidden=keep.hidden=useDesktop.hidden=!changed;conflict.textContent='Desktop changed while you edited. Desktop draft: '+(a.data?.draft||'(empty)');
   live.textContent=a.busy?(a.liveText||a.status):a.status;
   draft.disabled=!!pending;for(const b of [rename,pin,save,send])b.disabled=!!pending||a.busy||!a.id;fresh.disabled=!!pending||a.busy;retry.hidden=!pending;
  }catch(e){note.textContent=e.message;messages.replaceChildren();lastMessages='';live.textContent='Reconnect to read shared messages.';for(const b of [...list.querySelectorAll('button'),rename,pin,fresh,save,send])b.disabled=true;}
  setTimeout(poll,1000);
 }
 poll();
}
