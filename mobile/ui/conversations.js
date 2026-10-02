import {referenceText} from './references.js';
import {conversationGroups,conversationKey,conversationStatus,readTracker} from './conversation-list.js';
import {conversationIdentity,holdingHint,sameConversation} from './conversation-turns.js';
// Small, text-only Markdown subset. HTML, images and URLs remain inert text.
/** @param {string} text */
export function messageBlocks(text){
 const lines=String(text).replace(/\r\n?/g,'\n').split('\n'),blocks=[];let paragraph=[];
 const flush=()=>{if(paragraph.length){blocks.push({kind:'paragraph',text:paragraph.join('\n'),marker:''});paragraph=[]}};
 for(let i=0;i<lines.length;i++){
  const line=lines[i],fence=line.match(/^\s{0,3}(`{3,}|~{3,})(.*)$/);
  if(fence){flush();const code=[];let closed=false;for(i++;i<lines.length;i++){const end=lines[i].trim();if(end.length>=fence[1].length&&end.split('').every(c=>c===fence[1][0])){closed=true;break}code.push(lines[i]);}blocks.push({kind:'code',text:code.join('\n'),marker:fence[2].trim().slice(0,40)});if(!closed)break;continue;}
  const heading=line.match(/^\s{0,3}#{1,6}\s+(.+)$/),item=line.match(/^\s{0,3}([-+*]|\d+[.)])\s+(.+)$/),quote=line.match(/^\s{0,3}>\s?(.*)$/);
  if(!line.trim()){flush();continue;}
  if(heading||item||quote){flush();blocks.push({kind:heading?'heading':item?'item':'quote',text:heading?heading[1]:item?item[2]:quote[1],marker:item?(/^\d/.test(item[1])?item[1]:'•'):''});continue;}
  paragraph.push(line);
 }
 flush();return blocks;
}
/** @param {string} text */
export function messageSpans(text){
 const parts=[];let plain='';const flush=()=>{if(plain){parts.push({kind:'plain',text:plain});plain=''}};
 for(let i=0;i<text.length;){
  const mark=text[i]==='`'?'`':text.slice(i,i+2)==='**'?'**':null;
  const end=mark?text.indexOf(mark,i+mark.length):-1;
  if(mark&&end>i+mark.length){flush();parts.push({kind:mark==='`'?'code':'strong',text:text.slice(i+mark.length,end)});i=end+mark.length;}
  else{plain+=text[i];i++;}
 }
 flush();return parts;
}

/* Chat text follows the desktop's reference rule: a record id is a reference. */
const el=(tag,text)=>{const n=document.createElement(tag);if(text!=null){if(tag==='pre'||tag==='code'||tag==='textarea'||tag==='input'||tag==='option')n.textContent=text;else referenceText(n,text,undefined,{display:'id'});}return n;};
export function initConversations(root,visible,{taskInfo=()=>null,onTask=()=>{}}={}){
 let discussion=null;const tracker=readTracker(localStorage,'super-mobile-read-v1');
 const filterBot=el('select'),sort=el('select');filterBot.setAttribute('aria-label','Filter by bot');sort.setAttribute('aria-label','Sort conversations');for(const [value,label] of [['recent','Most recent'],['bot','Group by bot']]){const o=el('option',label);o.value=value;sort.append(o)}
 const discussionCard=el('div'),discussionTitle=el('h2'),discussionNote=el('p'),startDiscussion=el('button','Start discussion'),cancelDiscussion=el('button','Cancel');discussionCard.className='chat-discussion';discussionCard.hidden=true;discussionCard.append(discussionTitle,discussionNote,startDiscussion,cancelDiscussion);
 const latest=el('button','Latest messages ↓'),tasks=el('div');latest.hidden=true;latest.className='chat-latest';tasks.className='chat-linked-tasks';
 const dismiss=el('button','Dismiss message');dismiss.hidden=true;
 const conflict=el('div'),keep=el('button','Keep my draft against this revision'),useDesktop=el('button','Use desktop draft');
 // Hidden until a loaded conversation says the drafts really differ (T31 F4); the poll below shows them.
 conflict.hidden=keep.hidden=useDesktop.hidden=true;
 const heading=el('h1','Conversations'),note=el('p'),list=el('div'),title=el('input'),rename=el('button','Save title'),pin=el('button','Pin'),fresh=el('button','New conversation'),messages=el('div'),live=el('pre'),draft=el('textarea'),model=el('input'),effort=el('select'),send=el('button','Send'),save=el('button','Save draft to desktop'),retry=el('button','Retry pending request');
 title.maxLength=100;title.setAttribute('aria-label','Conversation title');draft.maxLength=8000;draft.rows=4;draft.setAttribute('aria-label','Message');model.setAttribute('aria-label','Exact connected model');model.placeholder='Enter the exact connected model';effort.setAttribute('aria-label','Thinking level');
 const label=(text,input)=>{const n=el('label',text);n.append(input);return n;};
 for(const b of [rename,pin,fresh,save,send])b.disabled=true;retry.hidden=true;
 const header=el('div'),subtitle=el('p'),openChats=el('button','Chats'),openOptions=el('button','•••'),thread=el('div'),composer=el('div'),toolbar=el('div'),modelChoice=el('button','Choose model'),chatPanel=el('dialog'),optionsPanel=el('dialog'),confirmModel=el('button','Select connected model');
 header.className='chat-header';thread.className='chat-thread';composer.className='chat-composer';toolbar.className='chat-tools';subtitle.className='chat-subtitle';draft.placeholder='Message your assistant…';draft.rows=2;send.textContent='Send ↑';
 const headerText=el('div');headerText.append(heading,subtitle);header.append(openChats,headerText,openOptions);openOptions.setAttribute('aria-label','Conversation settings');
 const setupPanel=(panel,name)=>{const top=el('div'),close=el('button','Done');top.className='chat-panel-header';top.append(el('h2',name),close);panel.append(top);panel.className='chat-panel';close.onclick=()=>panel.close();};
 setupPanel(chatPanel,'Conversations');setupPanel(optionsPanel,'Conversation settings');
 chatPanel.append(filterBot,sort,fresh,el('p','Opening a conversation also selects it on desktop.'),list);
 optionsPanel.append(el('h3','Model & thinking'),confirmModel,label('Thinking',effort),el('h3','Conversation'),label('Title',title),rename,pin,el('h3','Draft'),save);
 openChats.onclick=()=>chatPanel.showModal();openOptions.onclick=()=>{titleRevision=view?.active.revision;optionsPanel.showModal()};modelChoice.onclick=()=>optionsPanel.showModal();confirmModel.onclick=()=>{if(view?.active.model){model.value=view.active.model;confirmModel.textContent='Selected · '+model.value;modelChoice.textContent=model.value+' ⌄';updateComposer();}};
 thread.append(messages,live,tasks);toolbar.append(modelChoice,send);composer.append(note,dismiss,conflict,keep,useDesktop,draft,toolbar,retry);root.append(header,discussionCard,thread,latest,composer,chatPanel,optionsPanel);
 let nearBottom=true,lastLive='';const follow=()=>{if(nearBottom)requestAnimationFrame(()=>{thread.scrollTop=thread.scrollHeight});else latest.hidden=false;};latest.onclick=()=>{nearBottom=true;thread.scrollTop=thread.scrollHeight;latest.hidden=true;};thread.onscroll=()=>{nearBottom=thread.scrollHeight-thread.clientHeight-thread.scrollTop<90;if(nearBottom)latest.hidden=true;};

 let recoveryBlocked=false,available=false,connectionNotice='Connecting to desktop…',feedback={kind:'info',message:''};
 const report=(message,kind='error')=>{feedback={message,kind};renderFeedback();};
 // The single generation slot is desktop state, not local state. Derive the hint
 // on every render so it clears itself the moment the turn ends, the open
 // conversation owns it, or the connection drops. Never stored as feedback.
 // Identity comes from conversation-turns.js, which reconciles a row's `id`
 // with the open view's `conversationId`; never hand-compare those fields here.
 const heldElsewhere=()=>{const turn=view?.turn,a=view?.active;if(!available||!turn||!a)return '';if(sameConversation(turn,conversationIdentity(a)))return '';const held=view.conversations?.find(c=>sameConversation(turn,conversationIdentity(c)));return holdingHint(turn,held?.title||'')||'';};
 const renderFeedback=()=>{const hint=heldElsewhere(),priority=!!pending||['error','uncertain'].includes(feedback.kind);note.textContent=!available?[connectionNotice,...(['error','uncertain'].includes(feedback.kind)?[feedback.message]:[])].filter(Boolean).join('\n'):priority||!hint?feedback.message:hint;note.hidden=available&&!pending&&!['error','uncertain'].includes(feedback.kind)&&!hint;note.dataset.kind=feedback.kind;note.setAttribute('role','status');note.setAttribute('aria-live','polite');dismiss.hidden=recoveryBlocked||!available||!!pending||!['error','uncertain'].includes(feedback.kind);};
 dismiss.onclick=()=>report('','info');
 const updateComposer=()=>{const a=view?.active;discussionCard.hidden=!discussion;startDiscussion.disabled=recoveryBlocked||!available||!!pending||!!a?.busy||!discussion||!taskInfo(discussion);cancelDiscussion.disabled=!!pending;if(discussion){discussionTitle.textContent='Discuss · '+discussion.title;discussionNote.textContent=taskInfo(discussion)?'Prepare a new draft with '+(view?.bots.find(b=>b.id===a?.botId)?.name??'your assistant')+'. Review it before sending.':'This task changed. Reopen its review to continue.';}draft.disabled=!!pending;send.disabled=recoveryBlocked||!available||!!pending||!!a?.busy||!!view?.turn||!a?.id||!draft.value.trim()||!a.model||model.value!==a.model;retry.hidden=!pending;renderFeedback();};
 let view=null,key='',pending=null,lastMessages='',dirty=false,draftRevision=null,titleRevision=null,titleDirty=false;try{pending=JSON.parse(localStorage.getItem('super-mobile-pending')||'null')}catch{recoveryBlocked=true;feedback={kind:'error',message:'Pending request could not be read. Inspect desktop before sending.'};}
 if(pending)feedback={kind:'pending',message:'A request is awaiting confirmation. Retry checks the same request.'};
 const draftKey=()=> 'super-mobile-draft:'+key;
 const api=async(path,body)=>{const r=await fetch('/api/'+path,{method:body?'POST':'GET',headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(5000)});const data=await r.json();if(!r.ok||data.error)throw Object.assign(Error(data.error||'Conversation connection unavailable.'),{refused:!!data.error&&r.status!==503});return data;};
 const persist=()=>localStorage.setItem('super-mobile-pending',JSON.stringify(pending));
 const dispatch=async(first=false)=>{const q=pending;if(!q)return;try{await api('conversation',q);if(pending?.id===q.id)report('Waiting for desktop confirmation.','pending');}catch(e){if(pending?.id!==q.id)return;const refused=first===true&&e.refused;if(refused){pending=null;persist();}report(e.message+(refused?' Nothing queued; your draft is retained.':' Your draft is retained; retry uses the same request identity.'));}finally{updateComposer();}};
 const command=async(operation,extra={})=>{
  if(recoveryBlocked||pending||!available)return;const a=view?.active;if(!a)return;if(operation==='open'||operation==='create'){chatPanel.close();nearBottom=true;}
  pending={id:crypto.randomUUID(),createdAt:Date.now(),operation,botId:a.botId,provider:a.provider,conversationId:a.id,revision:operation==='draft'||operation==='send'?(draftRevision??a.revision):operation==='update'&&extra.title!==undefined?(titleRevision??a.revision):a.revision,...extra};
  try{persist();report('Sending request to desktop…','pending');updateComposer();await dispatch(true);}catch(e){pending=null;report('Could not retain request locally. Nothing sent.');updateComposer();}
 };
 startDiscussion.onclick=()=>{if(discussion&&taskInfo(discussion))command('create',{taskContext:{taskId:discussion.taskId,revision:discussion.revision,lineage:discussion.lineage}})};cancelDiscussion.onclick=()=>{discussion=null;updateComposer()};
 title.oninput=()=>{titleDirty=true};
 title.onfocus=()=>{titleRevision=view?.active.revision};
 keep.onclick=()=>{draftRevision=view.active.revision;localStorage.setItem(draftKey(),JSON.stringify({text:draft.value,revision:draftRevision}));};useDesktop.onclick=()=>{dirty=false;localStorage.removeItem(draftKey());draft.value=view.active.data?.draft??'';updateComposer();};
 draft.oninput=()=>{if(!dirty)draftRevision=view?.active.revision;dirty=true;try{localStorage.setItem(draftKey(),JSON.stringify({text:draft.value,revision:draftRevision}));}catch{report('Could not save this draft locally.');}updateComposer();};
 rename.onclick=()=>command('update',{title:title.value});pin.onclick=()=>command('update',{pinned:!view?.conversations?.find(c=>c.id===view.active.id&&c.botId===view.active.botId)?.pinned});fresh.onclick=()=>command('create');
 save.onclick=()=>command('draft',{text:draft.value});send.onclick=()=>command('send',{text:draft.value,model:model.value.trim(),effort:effort.value});retry.onclick=()=>dispatch();
 async function poll(){
  if(visible())try{
   const data=await api('conversations');if(!data.available)throw Error('Desktop conversation view unavailable. Draft retained on this device.');view=data.view;view.conversations=tracker.update(view.conversations,nearBottom&&!chatPanel.open&&!optionsPanel.open?conversationKey(view.active):null);available=true;connectionNotice='';
   if(pending){const receipt=data.receipts?.find(r=>r.id===pending.id);if(receipt){if(receipt.state==='done'&&pending.operation==='create'&&pending.taskContext)discussion=null;report(receipt.message,receipt.state==='done'?'info':receipt.state==='uncertain'?'uncertain':'error');if(receipt.state==='done'&&pending.operation==='update')titleDirty=false;const sent=pending.operation==='send',sentKey=JSON.stringify([pending.botId,pending.provider,pending.conversationId]);if(receipt.state==='done'&&pending.operation==='draft'&&draft.value===pending.text&&view.active.data?.draft===pending.text){dirty=false;draftRevision=view.active.revision;localStorage.removeItem(draftKey());}pending=null;persist();if(receipt.state==='done'&&sent){localStorage.removeItem('super-mobile-draft:'+sentKey);if(key===sentKey){dirty=false;draft.value='';}}}}
   const a=view.active;heading.textContent=view.conversations.find(c=>c.id===a.id&&c.botId===a.botId)?.title||'New conversation';subtitle.textContent=(view.bots.find(b=>b.id===a.botId)?.name||'Assistant')+' · Connected';modelChoice.textContent=(model.value===a.model&&a.model?a.model:'Choose model')+' ⌄';confirmModel.textContent=(model.value===a.model?'✓ ':'Select · ')+(a.model||'Connect a provider on desktop');confirmModel.disabled=!a.model;const newKey=JSON.stringify([a.botId,a.provider,a.id]);
   if(key!==newKey){nearBottom=true;latest.hidden=true;lastLive='';key=newKey;const saved=localStorage.getItem(draftKey());dirty=saved!==null;const local=saved?JSON.parse(saved):null;draft.value=local?.text??a.data?.draft??'';draftRevision=local?.revision??a.revision;titleRevision=null;titleDirty=false;model.value='';lastMessages='';}
   else if(!dirty&&document.activeElement!==draft)draft.value=a.data?.draft??'';

   list.replaceChildren();const choices=JSON.stringify(view.bots);if(filterBot.dataset.choices!==choices){const selected=filterBot.value||'all';filterBot.dataset.choices=choices;filterBot.replaceChildren();for(const b of [{id:'all',name:'All bots'},...view.bots]){const o=el('option',b.name);o.value=b.id;filterBot.append(o)}filterBot.value=selected;}
   for(const group of conversationGroups(view.conversations,view.bots,{bot:filterBot.value||'all',sort:sort.value})){list.append(el('h3',group.label));for(const c of group.items){const state=conversationStatus(c,view.turn),b=el('button',c.title),meta=el('small',(c.pinned&&group.label!=='Pinned'?'Pinned · ':'')+(c.unread?'● New reply · ':'')+state+' · '+(view.bots.find(b=>b.id===c.botId)?.name??c.botId));b.className='chat-list-row';meta.dataset.state=state;meta.className=c.unread?'chat-unread':'';b.append(meta);b.disabled=recoveryBlocked||!!pending||a.busy;b.onclick=()=>command('open',{botId:c.botId,provider:c.provider,conversationId:c.id,revision:c.revision});list.append(b);}}
const otherBots=el('details');otherBots.append(el('summary','Start with another bot'));for(const bot of view.bots){const b=el('button','Open bot · '+bot.name);b.disabled=recoveryBlocked||!!pending||a.busy;b.onclick=()=>command('open',{botId:bot.id,provider:bot.provider,conversationId:null});otherBots.append(b);}list.append(otherBots);
   const c=view.conversations.find(c=>c.id===a.id&&c.botId===a.botId);if(!titleDirty&&document.activeElement!==title)title.value=c?.title??'';pin.textContent=c?.pinned?'Unpin':'Pin';
   model.placeholder=a.model?'Connected: '+a.model+' — enter to confirm':'Connect a provider on desktop';
   const levels=JSON.stringify(a.efforts);if(effort.dataset.levels!==levels){effort.dataset.levels=levels;effort.replaceChildren(...(a.efforts??['']).map(v=>{const o=el('option',v||'Provider effort');o.value=v;return o;}));effort.value=a.effort;}
   const raw=JSON.stringify(a.data?.entries??[]);if(raw!==lastMessages){messages.replaceChildren();for(const e of a.data?.entries??[]){const bubble=el('article');bubble.className=e.role==='user'?'chat-user':'chat-assistant';bubble.append(el('h3',e.role==='user'?'You':view.bots.find(b=>b.id===a.botId)?.name||'Assistant'));if(e.role==='user')bubble.append(el('p',e.text));else appendMessage(bubble,e.text);messages.append(bubble);}lastMessages=raw;follow();}
   const changed=dirty&&draftRevision!==a.revision;conflict.hidden=keep.hidden=useDesktop.hidden=!changed;conflict.textContent='Desktop changed while you edited. Desktop draft: '+(a.data?.draft||'(empty)');
   live.hidden=!a.generating;const liveText=a.generating?(a.liveText||a.status):'';if(liveText!==lastLive){live.textContent=liveText;lastLive=liveText;follow();}tasks.replaceChildren();for(const link of a.data?.taskLinks??[]){const info=taskInfo(link),button=el('button',info?'View task · '+info.title:'Task '+link.taskId+' · refresh required');button.disabled=!info;button.onclick=()=>onTask(link);tasks.append(button);}
   for(const b of [rename,pin,save])b.disabled=recoveryBlocked||!!pending||a.busy||!a.id;fresh.disabled=recoveryBlocked||!!pending||a.busy;updateComposer();
  }catch(e){available=false;connectionNotice=e.message;subtitle.textContent='Reconnecting';for(const label of list.querySelectorAll('small')){delete label.dataset.state;label.textContent='Status unavailable · Reconnecting';}updateComposer();messages.replaceChildren();tasks.replaceChildren();latest.hidden=true;lastMessages='';live.textContent='Reconnect to read shared messages.';for(const b of [...list.querySelectorAll('button'),rename,pin,fresh,save,send])b.disabled=true;}
  setTimeout(poll,view?.turn?350:1000);
 }
 poll();
 return {discuss:context=>{discussion=context;updateComposer();}};
}

function appendMessage(root,text){
 for(const block of messageBlocks(text)){
  if(block.kind==='code'){const box=el('section'),language=el('div',block.marker||'Code'),code=el('pre',block.text);box.className='message-code';box.append(language,code);root.append(box);continue;}
  const node=el(block.kind==='heading'?'h4':block.kind==='quote'?'blockquote':'p');if(block.kind==='item'){node.className='message-item';node.append(el('span',block.marker+' '));}
  for(const part of messageSpans(block.text))node.append(el(part.kind==='strong'?'strong':part.kind==='code'?'code':'span',part.text));root.append(node);
 }
}
