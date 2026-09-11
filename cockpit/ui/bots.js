import {worldLineage,taskHistoryLinks} from './task-conversations.js';
import {publishTaskSession} from './task-session.js';
import {validateContextBatch} from './related-files.js';
import {initBotWork} from './bot-work-view.js';
import { heldProjection, registeredBot, registrationUnavailable, runtimeWorld, profileOf, botFields, waitForBot } from './runtime-bots.js';
import { referenceText, renderMessage, referenceWorld, refreshReferenceText } from './references.js';
/* Conversation state is separate from runtime projection state. Model output
 * supplies proposals only; an explicit Apply click uses existing human controls. */
import { node, selectedWorkspace, bindDisclosure } from './app-shell.js';
import { initBotDirectory } from './bot-directory.js';
import { createConversationStore } from './conversation-store.js';
export function initBots({ invoke, apply, current, runtimeBotActions }) {
  const root = document.getElementById('bot-surface');
  root.dataset.screen='bot:assistant';
  let bot={id:'assistant',name:'Workspace assistant',group:'General',role:'Planning',instructions:'Help organize work into clear, reviewable steps.',provider:'codex'};
  const editReferences=new WeakMap();
  const storageKey=key=>bot.id==='assistant'?key:`${key}:bot:${bot.id}`;
  root.append(node('p','SUPER / BOTS','eyebrow'),node('h1','Workspace assistant'),node('p','Plan your work, then apply the steps you choose.','screen-description'));
  const connection=node('section',undefined,'bot-connection');
  const provider=node('select');provider.id='bot-provider';provider.setAttribute('aria-label','Provider');
  for(const [id,title] of [['codex','ChatGPT / Codex'],['claude','Claude · local session'],['ollama','Ollama · local'],['openai','OpenAI API'],['anthropic','Anthropic API']]){const o=node('option',title);o.value=id;provider.append(o);}
  const connect=node('button','Connect provider','primary');connect.type='button';connect.id='bot-connect';
  const manage=node('button','Manage connections','subtle');manage.type='button';manage.id='bot-manage';
  const connectionNote=node('p','Sign in with ChatGPT in your browser. Your connection is managed automatically.','connection-note');
  const modelPicker=node('select');modelPicker.id='bot-model-picker';modelPicker.setAttribute('aria-label','Connected model');modelPicker.hidden=true;
  provider.value='codex';try{const last=localStorage.getItem(storageKey('super-last-provider'));if([...provider.options].some(o=>o.value===last))provider.value=last;}catch{}
  const connectionRow=node('div',undefined,'connection-row');connectionRow.append(provider,connect,modelPicker,manage);connection.append(connectionRow,connectionNote);
  const settings=node('details',undefined,'bot-settings');settings.open=false;settings.hidden=true;settings.append(node('summary','Manage connections · advanced'));bindDisclosure(settings);
  const form=node('form',undefined,'bot-config');
  function field(label,control){const wrap=node('label',label,'field');wrap.append(control);return wrap;}
  const model=node('input');model.id='bot-model';model.placeholder='Model ID';model.maxLength=200;
  const key=node('input');key.id='bot-api-key';key.type='password';key.autocomplete='off';key.placeholder='Leave blank to use your saved key';
  const endpoint=node('input');endpoint.id='bot-endpoint';endpoint.value='http://127.0.0.1:11434';
  const keyField=field('API key',key),endpointField=field('Local Ollama address',endpoint),modelField=field('Model override',model);
  const remember=node('input');remember.type='checkbox';remember.checked=true;remember.id='bot-remember-key';
  const rememberField=field('Save securely in system keychain',remember);
  const forget=node('button','Forget saved key');forget.type='button';forget.id='bot-forget-key';
  const disconnect=node('button','Disconnect ChatGPT');disconnect.type='button';disconnect.id='bot-disconnect';
  const save=node('button','Save connection','primary');save.type='submit';save.id='bot-configure';
  form.append(modelField,keyField,endpointField,rememberField,save,forget,disconnect);settings.append(form);
  settings.append(node('p','Direct API connections need a key once. Saved keys stay in your system keychain. ChatGPT sign-in is managed by Codex.','availability-note'));
  const status=node('p','Connect a provider to start chatting.','bot-status');status.id='bot-status';status.setAttribute('role','status');
  const sharing=node('label',undefined,'bot-sharing');
  const include=node('input');include.type='checkbox';include.checked=true;include.id='bot-context';
  const sharingText=node('span');sharing.append(include,sharingText);
  const transcript=node('div',undefined,'bot-transcript');transcript.id='bot-transcript';transcript.setAttribute('role','log');transcript.setAttribute('aria-live','polite');
  const composer=node('form',undefined,'bot-composer');
  const input=node('textarea');input.id='bot-message';input.rows=3;input.maxLength=8000;input.placeholder='What would you like to organize?';input.setAttribute('aria-label','Message to workspace assistant');
  const send=node('button','Send','primary');send.id='bot-send';send.type='submit';
  const cancelReply=node('button','Cancel reply');cancelReply.type='button';cancelReply.id='bot-cancel-reply';cancelReply.hidden=true;
  let replyId=null,replyPoll=null;
  cancelReply.onclick=async()=>{const id=replyId;if(!id)return;cancelReply.disabled=true;try{await invoke('bot_connection',{operation:'cancel_reply',requestId:id});if(replyId===id)status.textContent='Cancelling reply…';}catch(error){if(replyId===id){status.textContent=String(error);cancelReply.disabled=false;}}};
  const fresh=node('button','New conversation');fresh.type='button';fresh.id='bot-new';
  const effort=node('select');effort.id='bot-effort';effort.setAttribute('aria-label','Thinking level');
  const attach=node('input');attach.type='file';attach.multiple=true;attach.id='bot-attachments';attach.accept='.txt,.md,.json,.csv,.js,.ts,.tsx,.jsx,.rs,.py,.ex,.exs,.html,.css,.yaml,.yml,.toml,.xml,.log';
  attach.hidden=true;const attachButton=node('button','Attach files…');attachButton.type='button';attachButton.id='bot-attach';
  const attached=node('div');attached.id='bot-attachment-list';
  const toolbar=node('div',undefined,'connection-row');toolbar.append(field('Thinking',effort),attach,attachButton,send,cancelReply,fresh);
  composer.append(input,attached,toolbar);
  const reload=node('button','Refresh models');reload.type='button';reload.id='bot-refresh-models';connectionRow.insertBefore(reload,manage);
  const historyPicker=node('select');historyPicker.id='bot-history';historyPicker.setAttribute('aria-label','Saved conversations for this provider');
  const deleteConversation=node('button','Delete saved conversation');deleteConversation.type='button';deleteConversation.id='bot-delete-conversation';
  const historyStatus=node('p','Conversations and text attachments are saved on this device.','availability-note');historyStatus.id='bot-save-status';historyStatus.setAttribute('role','status');
  const historyRow=node('div',undefined,'connection-row');historyRow.append(field('Saved conversations',historyPicker),deleteConversation);
  const conversation=node('section',undefined,'bot-conversation');
  conversation.append(connection,settings,status,historyRow,historyStatus,sharing,transcript,composer);root.append(conversation);
  const workView=initBotWork({root,conversation,current,invoke});
  let taskReply=null,taskReplyRefs=[];
  let active=null, busy=false, messages=[], proposals=[], pending=false, poll=null;
  const preferences=new Map(), sessions=new Map();let selected=provider.value,catalog=[],files=[];
  const newHistory=()=>createConversationStore({getItem:key=>localStorage.getItem(storageKey(key)),setItem:(key,value)=>localStorage.setItem(storageKey(key),value)});
  let history=newHistory();
  let conversationTaskLinks=[];
  let conversationId=null,lastSaved='',pendingTurn=null,restoring=false;
  function updateHistory(){
    const items=history.list(selected), options=[{id:'',title:'New conversation'},...items];
    if(historyPicker.options.length!==options.length||options.some((o,i)=>historyPicker.options[i]?.value!==o.id||historyPicker.options[i]?.textContent!==o.title)){
      historyPicker.replaceChildren();for(const item of options){const option=node('option',item.title);option.value=item.id;historyPicker.append(option);}
    }
    historyPicker.value=conversationId??'';deleteConversation.disabled=busy||!conversationId;
  }
  function snapshot(){
    return {...(conversationTaskLinks.length?{taskLinks:conversationTaskLinks}:{}),messages:pendingTurn?messages.slice(0,pendingTurn.messageCount):messages,
      entries:[...transcript.children].map(e=>({role:e.classList.contains('bot-user')?'user':e.classList.contains('bot-assistant')?'assistant':'result',label:e.querySelector('.eyebrow')?.textContent??'',text:e.querySelector('.bot-message-text')?.dataset.rawText??e.querySelector('.bot-message-text')?.textContent??'',referenceWorld:e.querySelector('.bot-message-text')?.dataset.referenceWorld||null,proposals:[...e.querySelectorAll('.bot-proposal:not(.bot-proposal-set)')].map(p=>p.dataset.savedText??[...p.children].filter(c=>c.tagName!=='BUTTON').map(c=>c.dataset.rawText??c.textContent).join('\n'))})),
      draft:pendingTurn?.draft??input.value,files:pendingTurn?.files??files,includeContext:include.checked,replyPending:!!pendingTurn};
  }
  function saveCurrent(){
    if(restoring)return true;
    const data=snapshot(),encoded=JSON.stringify(data);
    if(!conversationId&&!data.messages.length&&!data.entries.length&&!data.draft&&!data.files.length){updateHistory();return true;}
    if(encoded===lastSaved)return true;
    try{conversationId=history.save(selected,conversationId,data);lastSaved=encoded;historyStatus.textContent='Saved on this device · includes messages and text attachments. Provider credentials are stored separately.';updateHistory();return true;}
    catch(error){historyStatus.textContent=String(error);return false;}
  }
  function restoreSaved(id){
    conversationTaskLinks=[];taskReply=null;taskReplyRefs=[];
    root.querySelectorAll('.task-conversation-backlink').forEach(n=>n.remove());
    restoring=true;conversationId=id;lastSaved='';messages=[];proposals=[];files=[];pendingTurn=null;input.value='';transcript.replaceChildren();
    const saved=id?history.get(selected,id):null;
    if(saved){
      conversationTaskLinks=saved.taskLinks??[];
      messages=saved.messages;files=saved.files;input.value=saved.draft;include.checked=saved.includeContext;
      for(const e of saved.entries){const entry=line(e.role,e.text);renderMessage(entry.querySelector('.bot-message-text'),e.text,e.referenceWorld??null);referenceText(entry.querySelector('.eyebrow'),e.label,e.referenceWorld??null);
        for(const text of e.proposals){const card=node('div',undefined,'bot-proposal');card.dataset.savedText=text;card.append(node('div',undefined,'bot-message-text'),node('p','Saved proposal history · no action is restored. Ask the assistant for a fresh proposal to apply.','availability-note'));renderMessage(card.querySelector('.bot-message-text'),text,e.referenceWorld??null);entry.append(card);}
      }
      if(saved.replyPending)line('result','The previous reply was not completed in this conversation. Your draft and attachments are restored; nothing was resent.');
      status.textContent='Saved conversation reopened. Historical proposals are read-only. Links look up current records; the original message is preserved.';
      historyStatus.textContent='Saved locally · messages and attachments return here. No message is sent by reopening.';
    }else if(history.error){historyStatus.textContent=history.error;}
    showFiles();updateHistory();restoring=false;
  }
  try{for(const [p,v] of JSON.parse(localStorage.getItem(storageKey('super-provider-preferences'))||'[]'))preferences.set(p,v);}catch{}
  function rememberChoice(p,v){preferences.set(p,{...preferences.get(p),...v});try{localStorage.setItem(storageKey('super-provider-preferences'),JSON.stringify([...preferences]));localStorage.setItem(storageKey('super-last-provider'),p);}catch{}}

  const names={open_workspace:'Create workspace',open_goal:'Create goal',open_lane:'Create lane',open_worker:'Assign worker'};
  function live() { const c=current(); return c?.frame?.projection && !c.withdrawn && !c.unavailable && !c.stalled && document.querySelector('#world [data-screen]') ? c.frame : null; }
  // Compare world identity, not advancing view/authority revisions.
  function worldKey(frame) { const w=frame?.world;return w ? JSON.stringify([w.world_incarnation,w.world_generation,w.projection_epoch]) : null; }
  function context() {
    const f=live();if (!include.checked || !f) return {available:false};
    const p=f.projection,ws=selectedWorkspace();
    const workspaces=Object.values(p.workspaces??{}).filter(w=>!ws||w.id===ws).map(({id,name})=>({id,name}));
    const goals=Object.values(p.goals??{}).filter(g=>!ws||g.workspace_ref===ws).map(({id,title,workspace_ref})=>({id,title,workspace_ref}));
    const ids=new Set(goals.map(g=>g.id));
    const lanes=Object.values(p.lanes??{}).filter(l=>!ws||ids.has(l.goal_ref)).map(({id,actor,goal_ref,repository_ref})=>({id,actor,goal_ref,repository_ref}));
    const laneIds=new Set(lanes.map(l=>l.id));
    const workers=Object.values(p.workers??{}).filter(w=>!ws||laneIds.has(w.locus_ref)).map(({id,locus_ref,purpose,status,occupancy})=>({id,locus_ref,purpose,status,occupancy}));
    return {available:true,world:f.world,workspace_view:ws||'all',workspaces,goals,lanes,workers,repositories:Object.values(p.repositories??{}).map(({ref})=>({ref}))};
  }
  function publishSession(){publishTaskSession({botId:bot.id,world:runtimeWorld(current),ready:!!active,reply:taskReply,tasks:taskReplyRefs,message:status.textContent});}
  new MutationObserver(publishSession).observe(status,{childList:true});
  function refresh() {
    publishSession();
    const cloud=['openai','anthropic'].includes(provider.value),isCodex=provider.value==='codex',isClaude=provider.value==='claude',managed=isCodex||isClaude;keyField.hidden=!cloud;endpointField.hidden=provider.value!=='ollama';rememberField.hidden=!cloud;forget.hidden=!cloud;disconnect.hidden=!managed;modelField.hidden=managed;save.hidden=managed;disconnect.textContent=isClaude?'Disconnect Claude from Super':'Disconnect ChatGPT';
    connect.disabled=busy||pending;provider.disabled=busy;modelPicker.disabled=busy;connect.textContent=pending?'Waiting for sign-in…':active?'Reconnect':'Connect provider';
    connectionNote.textContent=isClaude?'Use your local Claude Code sign-in. Claude manages the credentials; account access and limits apply.':isCodex?'Sign in with ChatGPT in your browser. Your connection is managed automatically.':cloud?'Connect using your saved key. Add or replace a key in Manage connections.':'Use models running on your computer. No API key needed.';
    sharingText.textContent=` Include workspace names, goals, lane/worker summaries and repository references with messages sent to ${active?.provider??provider.value}. Only files you explicitly attach are included; API keys are never included.`;
    historyPicker.disabled=busy;deleteConversation.disabled=busy||!conversationId;
    send.disabled=busy||!active;fresh.disabled=busy;effort.disabled=busy;attach.disabled=busy;attachButton.disabled=busy;reload.disabled=busy||!active;
    for(const n of form.elements)n.disabled=busy;
    include.disabled=busy;
    for(const a of proposals) a.button.disabled=busy||a.state!=='proposed'||(['propose_file_edit','review_file_set'].includes(a.name)?!a.reference:(!live()||worldKey(live())!==a.world||selectedWorkspace()!==a.workspace));
  }
  function line(role,text) {
    const entry=node('article',undefined,`bot-message bot-${role}`);
    entry.append(node('p',role==='user'?'You':role==='assistant'?`${bot.name} · ${active?.provider??'Bot'} · ${active?.model??''}`:'App result','eyebrow'),node('div',undefined,'bot-message-text'));
    renderMessage(entry.querySelector('.bot-message-text'),text);transcript.append(entry);return entry;
  }
  function reset() { restoreSaved(null); }
  function showFiles(){attached.replaceChildren();for(const f of files){const row=node('div');const remove=node('button',`Remove ${f.name}`);remove.type='button';remove.addEventListener('click',()=>{if(busy)return;files=files.filter(x=>x!==f);showFiles();});row.append(node('span',`${f.name} · ${f.content.length} characters `),remove);attached.append(row);}}
  attachButton.addEventListener('click',async()=>{if(busy)return;busy=true;refresh();status.textContent='Choose files in the attachment window.';try{const result=await invoke('choose_attachments');if(files.length+result.files.length>4)throw new Error('Attach up to four files per message. Remove a file before adding more.');files.push(...result.files);showFiles();status.textContent=result.files.length?'Files attached. They will be shared when you send.':'File selection cancelled.';saveCurrent();}catch(error){status.textContent=String(error);}finally{busy=false;refresh();}});
  attach.addEventListener('change',async()=>{if(busy)return;busy=true;refresh();const chosen=[...attach.files];attach.value='';try{const additions=[];for(const f of chosen){if(files.length+additions.length>=4||f.size>32000)throw new Error('Attach up to four text/code files, each at most 32 KB.');const content=new TextDecoder('utf-8',{fatal:true}).decode(await f.arrayBuffer());if(content.includes('\0')||!/\.(txt|md|json|csv|js|ts|tsx|jsx|rs|py|ex|exs|html|css|yaml|yml|toml|xml|log)$/i.test(f.name))throw new Error('This attachment type is not supported yet. Choose a UTF-8 text or code file.');additions.push({name:f.name,content});}files.push(...additions);showFiles();status.textContent='Attachments will be shared with the selected provider when you send.';}catch(error){status.textContent=String(error);}finally{busy=false;refresh();}});
  function showModels(){modelPicker.replaceChildren();const list=[...catalog];if(active&&!list.some(m=>m.id===active.model))list.push({id:active.model,name:active.model});for(const m of list){const o=node('option',m.name||m.id);o.value=m.id;modelPicker.append(o);}modelPicker.hidden=!active;if(active)modelPicker.value=active.model;showEfforts();}
  function showEfforts(){const info=catalog.find(m=>m.id===active?.model)??(provider.value==='claude'?catalog.find(m=>m.id.replace(/\[1m\]$/,'')===active?.model):null);const levels=info?.supportedReasoningEfforts?.map(x=>x.reasoningEffort)??[];effort.replaceChildren();for(const value of ['',...levels]){const o=node('option',value?value[0].toUpperCase()+value.slice(1):'Provider default');o.value=value;effort.append(o);}const saved=preferences.get(provider.value)?.efforts?.[active?.model];effort.value=levels.includes(saved)?saved:'';}
  effort.addEventListener('change',()=>rememberChoice(provider.value,{efforts:{...preferences.get(provider.value)?.efforts,[active.model]:effort.value}}));
  function stash(){saveCurrent();sessions.set(selected,{active,messages,proposals,catalog,files,draft:input.value,children:[...transcript.childNodes],taskLinks:conversationTaskLinks,status:status.textContent,conversationId,includeContext:include.checked});}
  let changingBot=false,loadingProvider=false;
  provider.addEventListener('change',async()=>{
    if(!changingBot&&!saveCurrent()){provider.value=selected;return;}
    taskReply=null;taskReplyRefs=[];root.querySelectorAll('.task-conversation-backlink').forEach(n=>n.remove());
    if(!changingBot)stash();changingBot=false;selected=provider.value;const saved=preferences.get(selected),session=sessions.get(selected);model.value=saved?.model??'';endpoint.value=saved?.endpoint??'http://127.0.0.1:11434';key.value='';
    active=session?.active??null;messages=session?.messages??[];proposals=session?.proposals??[];catalog=session?.catalog??[];files=session?.files??[];input.value=session?.draft??'';transcript.replaceChildren(...session?.children??[]);
    conversationTaskLinks=session?.taskLinks??[];
    conversationId=session?.conversationId??null;lastSaved='';include.checked=session?.includeContext??true;
    pending=false;clearTimeout(poll);status.textContent=session?.status??'Connect this provider to begin.';
    if(!session)restoreSaved(history.selected(selected));
    rememberChoice(selected,{});showModels();showFiles();updateHistory();refresh();
    loadingProvider=true;try { if(active){await refreshModels();}else if(saved?.model&&!['codex','claude'].includes(selected)){connect.click();}else if(['codex','claude'].includes(selected)){const p=selected;busy=true;refresh();try{const r=await invoke(managedCommand(p),{operation:'status'});if(r.connected)await activateManaged(p);}catch(error){status.textContent=String(error);}finally{busy=false;refresh();}} } finally {loadingProvider=false;}
  });
  for(const control of [model,key,endpoint])control.addEventListener('input',()=>{active=null;status.textContent='Apply these provider settings before sending.';refresh();});
  form.addEventListener('submit',async e=>{
    e.preventDefault();if(busy)return;busy=true;refresh();
    const setting={provider:provider.value,model:model.value.trim(),api_key:key.value||null,endpoint:endpoint.value,remember_key:remember.checked};
    try {
      const configured=await invoke('bot_configure',{settings:setting});
      rememberChoice(setting.provider,{model:setting.model,endpoint:setting.endpoint});key.value='';active=configured;await refreshModels(true);
      status.textContent=`${active.provider} · ${active.model} ready. Connection is checked when you send.`;settings.open=false;settings.hidden=true;settings.querySelector('summary').setAttribute('aria-expanded','false');
    } catch(error){status.textContent=String(error);} finally{setting.api_key=null;busy=false;refresh();}
  });
  forget.addEventListener('click',async()=>{
    if(busy)return;busy=true;refresh();
    try{await invoke('bot_forget_key',{provider:provider.value});active=null;key.value='';remember.checked=true;status.textContent='Saved key removed. Enter a key to connect again.';}
    catch(error){status.textContent=String(error);}
    finally{busy=false;refresh();}
  });
  manage.addEventListener('click',()=>{settings.hidden=!settings.hidden;settings.open=!settings.hidden;settings.querySelector('summary').setAttribute('aria-expanded',String(settings.open));});
  const managedCommand=p=>p==='claude'?'bot_claude_connection':'bot_connection';
  const managedName=p=>p==='claude'?'Claude':'ChatGPT';
  async function activateManaged(p){
    const result=await invoke(managedCommand(p),{operation:'models'});
    if(provider.value!==p)return;
    const models=result.models;catalog=models;if(!models.length)throw new Error('No models are available for this account.');
    modelPicker.replaceChildren();for(const m of models){const o=node('option',m.name||m.id);o.value=m.id;modelPicker.append(o);}
    const saved=preferences.get(p)?.model;
    if(saved&&!models.some(m=>m.id===saved)){const o=node('option',`${saved} (saved choice)`);o.value=saved;modelPicker.append(o);}modelPicker.value=saved||(models.find(m=>m.isDefault)||models[0]).id;
    active=await invoke('bot_configure',{settings:{provider:p,model:modelPicker.value}});
    rememberChoice(p,{model:active.model});showModels();modelPicker.hidden=false;status.textContent=`Connected to ${managedName(p)}. Ready for your message.`;
  }
  async function refreshModels(internal=false){if((busy&&!internal)||!active)return;busy=true;refresh();try{const p=provider.value;if(['codex','claude'].includes(p)){catalog=(await invoke(managedCommand(p),{operation:'models'})).models;}else if(p==='ollama'){catalog=(await invoke('bot_local_models',{endpoint:endpoint.value})).models.map(id=>({id,name:id}));}else{catalog=(await invoke('bot_models',{provider:p})).models;}showModels();status.textContent=`Model list refreshed at ${new Date().toLocaleTimeString()}. Model choice preserved.`;}catch(error){status.textContent=`Could not refresh models. Previous choices retained. ${error}`;}finally{busy=false;refresh();}}
  reload.addEventListener('click',()=>refreshModels());
  async function checkSignIn(p){
    if(provider.value!==p||!pending)return;
    try{const result=await invoke(managedCommand(p),{operation:'status'});
      if(provider.value!==p)return;
      if(result.connected){pending=false;busy=true;refresh();await activateManaged(p);}
      else if(result.failed||!result.pending){pending=false;status.textContent=p==='claude'?'Sign-in did not complete. Sign in with Claude Code, then connect again.':'Sign-in did not complete. Unlock your system keychain and connect again.';}
      else poll=setTimeout(()=>checkSignIn(p),1500);
    }catch(error){pending=false;status.textContent=String(error);}
    finally{busy=false;refresh();}
  }
  connect.addEventListener('click',async()=>{
    if(busy||pending)return;busy=true;active=null;refresh();
    try{
      if(['codex','claude'].includes(provider.value)){
        const p=provider.value;const result=await invoke(managedCommand(p),{operation:'connect'});
        if(result.connected)await activateManaged(p);
        else{pending=true;status.textContent='Finish signing in in your browser. Super will connect automatically.';poll=setTimeout(()=>checkSignIn(p),1500);}
      }else if(provider.value==='ollama'){
        const result=await invoke('bot_local_models',{endpoint:endpoint.value});
        if(!result.models.length)throw new Error('No local models found. Add a model in Ollama, then connect again.');
        modelPicker.replaceChildren();for(const id of result.models){const o=node('option',id);o.value=id;modelPicker.append(o);}
        const saved=preferences.get('ollama')?.model;modelPicker.value=result.models.includes(saved)?saved:result.models[0];
        active=await invoke('bot_configure',{settings:{provider:'ollama',model:modelPicker.value,endpoint:endpoint.value}});catalog=result.models.map(id=>({id,name:id}));showModels();modelPicker.hidden=false;rememberChoice('ollama',{model:active.model,endpoint:endpoint.value});status.textContent='Connected to Ollama. Ready for your message.';
      }else{
        const choice=preferences.get(provider.value);if(!choice?.model){settings.hidden=false;settings.open=true;throw new Error('Add this provider’s API key and model once in Manage connections. Future connections use your saved key.');}
        active=await invoke('bot_configure',{settings:{provider:provider.value,model:choice.model}});showModels();await refreshModels(true);status.textContent='Saved connection ready.';
      }
    }catch(error){status.textContent=String(error);if(['openai','anthropic'].includes(provider.value)){settings.hidden=false;settings.open=true;}}
    finally{busy=false;refresh();}
  });
  modelPicker.addEventListener('change',async()=>{
    if(busy)return;busy=true;active=null;refresh();
    try{active=await invoke('bot_configure',{settings:{provider:provider.value,model:modelPicker.value,endpoint:endpoint.value}});rememberChoice(provider.value,{model:active.model,endpoint:endpoint.value});showEfforts();status.textContent='Model switched. Conversation preserved.';}
    catch(error){status.textContent=String(error);}finally{busy=false;refresh();}
  });
  disconnect.addEventListener('click',async()=>{
    if(busy)return;busy=true;clearTimeout(poll);refresh();
    try{const p=provider.value;await invoke(managedCommand(p),{operation:'disconnect'});pending=false;active=null;modelPicker.hidden=true;saveCurrent();status.textContent=p==='claude'?'Claude disconnected from Super. Your Claude Code login is unchanged.':'ChatGPT disconnected from Super.';}
    catch(error){status.textContent=String(error);}finally{busy=false;refresh();}
  });
  // Only restore the selected connection. Claude requires an explicit prior
  // Connect in Super; its marker contains no credentials.
  if(['codex','claude'].includes(provider.value)){
    const p=provider.value;
    invoke(managedCommand(p),{operation:'status'}).then(async result=>{if(result.needsSignIn&&provider.value===p)status.textContent='Claude sign-in has expired. Connect provider to sign in again.';if(result.connected&&provider.value===p&&!busy&&!active){busy=true;refresh();try{await activateManaged(p);}finally{busy=false;refresh();}}}).catch(()=>{});
  }
  fresh.addEventListener('click',()=>{if(busy||!saveCurrent())return;reset();status.textContent=active?'New conversation. Ready for your message.':'Configure a provider first.';refresh();});
  composer.addEventListener('submit',async e=>{
    e.preventDefault();const draft=input.value;const sentFiles=[...files];const sentReferences=sentFiles.map(f=>editReferences.get(f)).filter(Boolean);const text=input.value.trim();if(busy||!active||(!text&&!files.length))return;
    if(messages.length>=44){status.textContent='Start a new conversation to continue.';return;}
    const frame=live(),origin=worldKey(frame),workspace=selectedWorkspace();
    const turnContext=context();
    taskReplyRefs=sentReferences.map(r=>r.task).filter(Boolean);taskReply='Waiting for reply';
    pendingTurn={draft,files:sentFiles,messageCount:messages.length};
    messages.push({role:'user',content:text,attachments:sentFiles});line('user',[text,...sentFiles.map(f=>`Attached: ${f.name}`)].join('\n'));input.value='';files=[];showFiles();busy=true;refresh();status.textContent=active.provider==='codex'?'Waiting for Codex… Large file replies can take up to five minutes.':`Waiting for ${active.provider}… Replies can take up to two minutes.`;saveCurrent();
    replyId=active.provider==='codex'?crypto.randomUUID():null;
    if(replyId){const id=replyId;const poll=async()=>{try{const r=await invoke('bot_connection',{operation:'reply_status',requestId:id});if(replyId!==id)return;cancelReply.hidden=!r.active;cancelReply.disabled=r.cancelled;if(r.active&&!r.cancelled)status.textContent=r.received_bytes?`Receiving Codex reply… ${r.received_bytes.toLocaleString()} bytes received. Large file replies can take up to five minutes.`:'Waiting for Codex… Large file replies can take up to five minutes.';}catch{}if(replyId===id)replyPoll=setTimeout(poll,300);};poll();}
    try {
      const reply=await invoke('bot_chat' ,{turn:{request_id:replyId,provider:active.provider,messages,context:turnContext,bot_instructions:`Name: ${bot.name}\nRole: ${bot.role}\n${bot.instructions}`,effort:effort.value||null}});
      const entry=line('assistant',reply.text||'Review the proposed step below.');
      messages.push({role:'assistant',content:[reply.text,reply.actions.length?`Proposed only, not executed: ${JSON.stringify(reply.actions)}`:''].filter(Boolean).join('\n')});
      const fileEdits=reply.actions.filter(a=>a.name==='propose_file_edit');
      if(fileEdits.length>1){
        const items=fileEdits.map(a=>({proposal:a.args,reference:sentReferences.filter(r=>r.key===a.args.path).at(-1)}));
        const card=node('div',undefined,'bot-proposal bot-proposal-set'),button=node('button','Review files together','primary'),result=node('p','Review all replacements before staging. Nothing has changed.','bot-status');button.type='button';button.dataset.reviewFileSet='';
        card.append(node('h2',fileEdits.length+' proposed file edits'),node('p',fileEdits.map(a=>a.args.path).join(' · '),'proposal-field'),result,button);entry.append(card);
        proposals.push({name:'review_file_set',button,state:'proposed',reference:items.every(i=>i.reference)});
        button.onclick=()=>{if(button.disabled)return;const detail={items,error:null};if(!document.dispatchEvent(new CustomEvent('review-file-proposal-set',{detail,cancelable:true})))result.textContent=detail.error||'The combined review could not open.';else result.textContent='Combined review opened. Staging leaves all files unsaved.';};
      }
      for(const action of reply.actions){
        if(action.name==='propose_file_edit'){
          const reference=sentReferences.filter(r=>r.key===action.args.path).at(-1),proposal=node('div',undefined,'bot-proposal'),button=node('button','Review in Editor','primary'),result=node('p',reference?'Proposed · no file changed':'Share this file from Editor and request a fresh proposal to review it.','bot-status');button.type='button';
          proposal.append(node('h2','Proposed file edit'),node('p',action.args.path+(action.args.content===null?' · Delete file — use combined review':' · '+new TextEncoder().encode(action.args.content).length+' bytes'),'proposal-field'),result,button);const a={...action,button,state:'proposed',reference};proposals.push(a);
          button.onclick=()=>{if(button.disabled)return;const detail={reference,proposal:action.args,error:null,onIdentity:record=>{proposal.querySelector('.proposal-source-record')?.remove();const identity=node('details',undefined,'proposal-source-record');identity.append(node('summary','Recorded source and result'),node('pre',JSON.stringify(record,null,2)));proposal.append(identity);saveCurrent();}};const event=new CustomEvent('review-file-proposal',{detail,cancelable:true});if(!document.dispatchEvent(event)){result.textContent=detail.error||'The file review could not open.';return;}result.textContent='Review opened in Editor. The file stays unchanged until you choose a draft and Save.';};entry.append(proposal);continue;
        }

        const proposal=node('div',undefined,'bot-proposal');proposal.append(node('h2',names[action.name]??action.name));
        for(const [field,value] of Object.entries(action.args))proposal.append(node('p',`${field.replaceAll('_',' ')}: ${value}`,'proposal-field'));
        const button=node('button','Apply this step','primary'),dismiss=node('button','Dismiss');
        button.type=dismiss.type='button';const result=node('p','Proposed · no change made','bot-status');
        const a={...action,button,state:'proposed',world:origin,workspace};proposals.push(a);
        button.addEventListener('click',async()=>{
          if(button.disabled||a.state!=='proposed')return;
          a.state='submitting';busy=true;refresh();result.textContent='Submitting to the runtime…';dismiss.disabled=true;
          let outcome;
          try {const accepted=await apply(a.name,a.args);a.state=accepted?'accepted':'refused';outcome=accepted?'Request accepted. World changes are confirmed by subsequent runtime frames.':'Request was refused or not confirmed. Check Activity and the live workspace before trying again.';}
          catch{a.state='unconfirmed';outcome='The request was not confirmed. Check Activity and the live workspace before trying again.';}
          result.textContent=outcome;line('result',`${names[a.name]}: ${outcome}`);
          messages.push({role:'user',content:`App submission result for ${a.name} ${JSON.stringify(a.args)}: ${outcome}`});busy=false;refresh();
        });
        dismiss.addEventListener('click',()=>{if(busy||a.state!=='proposed')return;a.state='dismissed';result.textContent='Dismissed · no change made';dismiss.disabled=true;messages.push({role:'user',content:`I dismissed the proposed ${a.name} action. It was not executed.`});refresh();});
        proposal.append(result,button,dismiss);entry.append(proposal);
      }
      taskReply='Reply received';pendingTurn=null;status.textContent='Reply received. Proposed steps run only when you apply them.';
    }catch(error){taskReply='Reply did not complete';pendingTurn=null;messages.pop();if(!input.value)input.value=draft;files=sentFiles;showFiles();status.textContent=String(error);line('result',String(error));if(active?.provider==='claude'&&String(error).includes('sign-in has expired')){active=null;modelPicker.hidden=true;}}
    finally{replyId=null;clearTimeout(replyPoll);cancelReply.hidden=true;busy=false;saveCurrent();refresh();transcript.lastElementChild?.scrollIntoView({block:'nearest'});}
  });
  historyPicker.addEventListener('change',()=>{if(busy)return;const id=historyPicker.value;if(!saveCurrent()){updateHistory();return;}restoreSaved(id||null);saveCurrent();refresh();});
  deleteConversation.addEventListener('click',()=>{if(busy||!conversationId)return;if(!confirm('Delete this saved conversation and its locally saved attachments?'))return;try{history.remove(selected,conversationId);sessions.delete(selected);reset();historyStatus.textContent='Conversation deleted from this device.';refresh();}catch(error){historyStatus.textContent=String(error);}});
  input.addEventListener('input',saveCurrent);
  include.addEventListener('change',saveCurrent);
  window.addEventListener('pagehide',saveCurrent);
  window.addEventListener('beforeunload',saveCurrent);
  restoreSaved(history.selected(selected));
  new MutationObserver(saveCurrent).observe(transcript,{childList:true,subtree:true,characterData:true});
  new MutationObserver(saveCurrent).observe(attached,{childList:true});
  input.addEventListener('keydown',e=>{if((e.ctrlKey||e.metaKey)&&e.key==='Enter'){e.preventDefault();composer.requestSubmit();}});
  document.addEventListener('workspace-view-change',refresh);
  document.addEventListener('runtime-view-rendered',()=>{refreshReferenceText(transcript);refresh();});
  // Host frames and withdrawals keep proposal controls current without
  // replacing conversation DOM or drafts.
  new MutationObserver(refresh).observe(document.getElementById('world'),{childList:true});
  if(!['codex','claude'].includes(provider.value)&&preferences.get(provider.value)?.model)queueMicrotask(()=>connect.click());
  model.value=preferences.get(provider.value)?.model??'';endpoint.value=preferences.get(provider.value)?.endpoint??endpoint.value;showEfforts();refresh();
  const board=node('section',undefined,'bot-identity-board');
  root.insertBefore(board,root.querySelector('.record-tabs'));
  let identitySignature='',runtimeBusy=false,registrationWorkspace='';
  function showIdentity(){
    workView.refresh(bot.id);
    const record=registeredBot(current,bot.id),p=heldProjection(current);
    if(record)bot={...bot,...profileOf(record)};
    const signature=JSON.stringify([bot,record,p?Object.values(p.workspaces??{}).map(w=>[w.id,w.name]):null,runtimeBusy]);
    if(signature===identitySignature)return;identitySignature=signature;
    root.querySelector('h1').textContent=bot.name;
    root.querySelector('.screen-description').textContent=bot.role+' · '+(bot.instructions||'Add a clear purpose when creating your bot.');
    input.setAttribute('aria-label','Message to '+bot.name);
    board.replaceChildren(node('span',!p?'Runtime status unavailable':record?'Registered in runtime':'Local conversational profile','status-chip'),node('span','Human-reviewed proposals','status-chip'),node('p','Delegation and coding execution are not connected yet. Registration does not grant permissions or start work.','availability-note'));
    if(record){
      board.append(node('p',`Workspace: ${record.workspace_ref} · Profile revision ${record.revision}`,'directory-note'));
      const inspect=node('button','Inspect runtime identity','subtle');inspect.dataset.recordOpen='bot:'+record.id;inspect.type='button';board.append(inspect);
      const remove=node('button','Remove runtime registration…','subtle');remove.id='bot-remove-runtime';remove.type='button';remove.disabled=busy||runtimeBusy;
      remove.addEventListener('click',async()=>{
        if(busy||runtimeBusy||!confirm('Remove this runtime bot identity? This is refused while it has lanes, active grants, requests or effects. Local conversations remain.'))return;
        const origin=runtimeWorld(current);runtimeBusy=true;showIdentity();
        try{if(!await runtimeBotActions.remove({bot_ref:record.id}))throw new Error('Removal was refused. Check Activity for the reason.');await waitForBot(current,origin,p=>!p.bots?.[record.id]);status.textContent='Runtime registration removed. Local conversation history is preserved.';}
        catch(e){status.textContent=String(e);}finally{runtimeBusy=false;showIdentity();}
      });board.append(remove);
    }else{
      const picker=node('select');picker.id='bot-register-workspace';picker.setAttribute('aria-label','Workspace for this bot');const empty=node('option','Choose a workspace');empty.value='';picker.append(empty);
      for(const ws of Object.values(p?.workspaces??{})){const option=node('option',ws.name||ws.id);option.value=ws.id;picker.append(option);}
      picker.value=registrationWorkspace||selectedWorkspace();
      const register=node('button','Register in workspace','primary');register.id='bot-register-runtime';register.type='button';register.disabled=busy||runtimeBusy||!p||!picker.value;
      picker.addEventListener('change',()=>{registrationWorkspace=picker.value;register.disabled=busy||runtimeBusy||!p||!picker.value;});
      register.addEventListener('click',async()=>{
        if(busy||runtimeBusy||!heldProjection(current)||!picker.value)return;
        const fields=botFields(bot,picker.value),origin=runtimeWorld(current);runtimeBusy=true;showIdentity();
        try{if(!await runtimeBotActions.register(fields))throw new Error('Registration was refused. Check Activity for the reason.');await waitForBot(current,origin,p=>Object.values(p.bots??{}).some(b=>b.client_ref===bot.id));status.textContent='Bot identity registered. No permissions were granted and no execution was started.';}
        catch(e){status.textContent=String(e);}finally{runtimeBusy=false;showIdentity();}
      });board.append(picker,register);
      if(!p)board.append(node('p','Reconnect to check this profile’s runtime registration.','availability-note'));
    }
    const edit=node('button','Edit bot','subtle');edit.type='button';edit.disabled=!!registrationUnavailable(current,bot.id);edit.dataset.nav='edit-bot';board.append(edit);
  }
  initBotDirectory({runtimeCurrent:current,runtimeBotActions,canSave:()=>!busy&&!runtimeBusy&&!pending,current:()=>bot,select:next=>{
    if(next.id===bot.id){bot=next;showIdentity();return true;}
    if(busy||pending||runtimeBusy){status.textContent='Wait for the current reply or connection to finish before switching bots.';return false;}
    if(!saveCurrent())return false;
    root.querySelectorAll('.task-conversation-backlink').forEach(n=>n.remove());
    conversationTaskLinks=[];taskReply=null;taskReplyRefs=[];bot=next;history=newHistory();preferences.clear();sessions.clear();
    try{for(const [p,v] of JSON.parse(localStorage.getItem(storageKey('super-provider-preferences'))||'[]'))preferences.set(p,v);}catch{}
    let remembered=bot.provider;try{remembered=localStorage.getItem(storageKey('super-last-provider'))||remembered;}catch{}
    provider.value=[...provider.options].some(o=>o.value===remembered)?remembered:bot.provider;
    active=null;messages=[];proposals=[];files=[];catalog=[];conversationId=null;lastSaved='';pendingTurn=null;
    transcript.replaceChildren();input.value='';changingBot=true;showIdentity();provider.dispatchEvent(new Event('change'));return true;
  }});
  document.addEventListener('runtime-view-rendered',showIdentity);
  new MutationObserver(showIdentity).observe(document.getElementById('world'),{childList:true});
  showIdentity();

  document.addEventListener('open-saved-task-conversation',e=>{
    const request={...e.detail};let tries=0;
    const open=()=>{
      if(bot.id!==request.botId||runtimeWorld(current)!==request.world){status.textContent='The bot or world changed. Reopen the task to select its saved conversation.';return;}
      if(loadingProvider||(busy&&!pendingTurn)){if(++tries<100){setTimeout(open,100);return;}status.textContent='Provider setup is still busy. Reopen the task and try again.';return;}
      if(busy||pending||runtimeBusy){status.textContent='Finish the current reply or connection before reopening saved history.';return;}
      const task=heldProjection(current)?.development_tasks?.[request.taskId];
      if(!task||heldProjection(current)?.bots?.[task.bot_ref]?.client_ref!==bot.id||!taskHistoryLinks(history,task.id,request.world).some(c=>c.id===request.conversationId&&c.provider===request.provider)){status.textContent='This linked conversation is unavailable or was deleted. Reopen the task to refresh its history.';return;}
      if(!saveCurrent())return;
      if(selected!==request.provider){stash();selected=request.provider;provider.value=selected;active=null;catalog=[];key.value='';model.value=preferences.get(selected)?.model??'';endpoint.value=preferences.get(selected)?.endpoint??'http://127.0.0.1:11434';}
      restoreSaved(request.conversationId);saveCurrent();showModels();refresh();workView.conversation();
      const back=node('button','Return to development plan','subtle');back.type='button';back.dataset.developmentTask=task.id;back.classList.add('task-conversation-backlink');composer.before(back);
    };open();
  });
  document.addEventListener('open-task-conversation',e=>{if(bot.id!==e.detail.botId){e.preventDefault();return;}workView.conversation();});
  document.addEventListener('bot-surface-context',e=>{
    const {botId}=e.detail;let items;
    try{
      if(bot.id!==botId||(busy&&!loadingProvider)||pending||runtimeBusy)throw Error('Finish the current bot operation before attaching files.');
      items=validateContextBatch(e.detail.items??[{reference:e.detail.reference,attachment:e.detail.attachment}],files.length);
    }catch(error){e.preventDefault();e.detail.error=String(error.message||error);status.textContent=e.detail.error;return;}
    const newLinks=[...conversationTaskLinks];
    for(const {reference} of items){const t=reference.task,lineage=worldLineage(t?.world);if(t&&lineage&&!newLinks.some(l=>l.taskId===t.id&&l.revision===t.revision&&l.lineage===lineage))newLinks.push({taskId:t.id,revision:t.revision,lineage});}
    if(newLinks.length>80){e.preventDefault();e.detail.error='This conversation has too many plan links. Start a new conversation.';status.textContent=e.detail.error;return;}
    conversationTaskLinks=newLinks;
    for(const {reference,attachment} of items){if(reference.kind==='editor'&&typeof reference.draft==='string')editReferences.set(attachment,reference);files.push(attachment);}
    workView.conversation();showFiles();saveCurrent();
    root.querySelectorAll('.task-conversation-backlink').forEach(n=>n.remove());
    root.querySelector('.linked-surface')?.remove();
    const group=node(items.length===1?'button':'div',items.length===1?'Linked: '+items[0].reference.title:undefined,'linked-surface connection-row');group.dataset.botId=bot.id;
    if(items.length===1){group.type='button';group.onclick=()=>document.dispatchEvent(new CustomEvent('open-development-surface',{detail:items[0].reference}));}else for(const {reference} of items){const link=node('button','Linked: '+reference.title,'subtle');link.type='button';link.onclick=()=>document.dispatchEvent(new CustomEvent('open-development-surface',{detail:reference}));group.append(link);}
    for(const task of new Map(items.filter(i=>i.reference.task).map(i=>[i.reference.task.id,i.reference.task])).values()){const back=node('button','Return to development plan','subtle');back.type='button';back.dataset.developmentTask=task.id;composer.before(back);back.classList.add('task-conversation-backlink');}
    composer.before(group);status.textContent=items.length===1?'Surface snapshot attached. Add a message and Send when ready.':items.length+' file snapshots attached. Review the attachments, then Send when ready.';input.focus();
  });
  document.addEventListener('page-selected',()=>{const link=root.querySelector('.linked-surface');if(link)link.hidden=link.dataset.botId!==bot.id;});

}
