import {initMobileConversationBridge} from './mobile-conversation-bridge.js';
import {conversationReply,titleInstruction,streamingReply} from './conversation-title.js';
import {beginTaskActivity,observeTaskActivity,replyFailure} from './task-activity.js';
import {initBotActivity} from './bot-activity.js';
import {REVIEW_FILE_BYTES,REVIEW_FILE_LABEL} from './review-limits.js';
import {worldLineage,taskHistoryLinks,taskDiscussion} from './task-conversations.js';
import {publishTaskSession} from './task-session.js';
import {validateContextBatch} from './related-files.js';
import {initBotWork} from './bot-work-view.js';
import { heldProjection, registeredBot, registrationUnavailable, runtimeWorld, profileOf, botFields, waitForBot } from './runtime-bots.js';
import { referenceText, renderMessage, referenceWorld, refreshReferenceText } from './references.js';
/* Conversation state is separate from runtime projection state. Model output
 * supplies proposals only; an explicit Apply click uses existing human controls. */
import { node, selectedWorkspace, bindDisclosure, navigate } from './app-shell.js';
import { initBotDirectory } from './bot-directory.js';
import {initConversationSidebar} from './conversation-sidebar.js';
import { createConversationStore } from './conversation-store.js';
export function initBots({ invoke, apply, current, runtimeBotActions }) {
  const root = document.getElementById('bot-surface');
  let conversationSidebar=null,liveReply=null,streamText='';
  /* Opening a saved chat also navigates to its bot, and that navigation is the
   * app moving, not the person choosing a bot. Only an explicit choice rescopes
   * the conversation list, so browsing every conversation survives opening one. */
  let conversationNavigation=false;
  const openingConversation=fn=>{conversationNavigation=true;try{return fn();}finally{conversationNavigation=false;}};
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
  const transcript=node('div',undefined,'bot-transcript');transcript.id='bot-transcript';transcript.setAttribute('role','log');transcript.setAttribute('aria-live','polite');transcript.setAttribute('aria-label','Conversation messages');transcript.tabIndex=0;
  transcript.addEventListener('scroll',()=>{transcript.dataset.follow=String(transcript.scrollHeight-transcript.scrollTop-transcript.clientHeight<100);});
  const composer=node('form',undefined,'bot-composer');
  const input=node('textarea');input.id='bot-message';input.rows=3;input.maxLength=8000;input.placeholder='What would you like to organize?';input.setAttribute('aria-label','Message to workspace assistant');
  const send=node('button','Send','primary');send.id='bot-send';send.type='submit';
  const cancelReply=node('button','Cancel reply');cancelReply.type='button';cancelReply.id='bot-cancel-reply';cancelReply.hidden=true;
  let replyId=null,replyPoll=null;
  cancelReply.onclick=async()=>{const id=replyId;if(!id)return;cancelReply.disabled=true;try{await invoke(managedCommand(provider.value),{operation:'cancel_reply',requestId:id});if(replyId===id)status.textContent='Cancelling reply…';}catch(error){if(replyId===id){status.textContent=String(error);cancelReply.disabled=false;}}};
  const fresh=node('button','New conversation');fresh.type='button';fresh.id='bot-new';
  const effort=node('select');effort.id='bot-effort';effort.setAttribute('aria-label','Thinking level');
  const attach=node('input');attach.type='file';attach.multiple=true;attach.id='bot-attachments';attach.accept='.txt,.md,.json,.csv,.js,.ts,.tsx,.jsx,.rs,.py,.ex,.exs,.html,.css,.yaml,.yml,.toml,.xml,.log';
  attach.hidden=true;const attachButton=node('button','Attach files…');attachButton.type='button';attachButton.id='bot-attach';
  const attached=node('div');attached.id='bot-attachment-list';
  const toolbar=node('div',undefined,'connection-row');toolbar.append(field('Thinking',effort),attach,attachButton,send,cancelReply);
  composer.append(input,attached,toolbar);
  const reload=node('button','Refresh models');reload.type='button';reload.id='bot-refresh-models';connectionRow.insertBefore(reload,manage);
  const historyPicker=node('select');historyPicker.id='bot-history';historyPicker.setAttribute('aria-label','Saved conversations for this provider');
  const deleteConversation=node('button','Delete saved conversation');deleteConversation.type='button';deleteConversation.id='bot-delete-conversation';
  const historyStatus=node('p','Conversations and text attachments are saved on this device.','availability-note');historyStatus.id='bot-save-status';historyStatus.setAttribute('role','status');
  const historyRow=node('div',undefined,'connection-row');historyRow.append(field('Saved conversations',historyPicker),deleteConversation);
  const conversation=node('section',undefined,'bot-conversation');
  const activity=initBotActivity({root:conversation,connect,input,cancel:cancelReply});
  const botSettings=node('section',undefined,'bot-settings-panel');botSettings.id='bot-settings';botSettings.append(conversation.querySelector('#bot-activity'),connection,settings,sharing,historyStatus,historyRow);historyRow.hidden=true;
  const settingsStatus=node('p',status.textContent,'bot-status');settingsStatus.id='bot-settings-status';settingsStatus.setAttribute('role','status');botSettings.prepend(settingsStatus);new MutationObserver(()=>{settingsStatus.textContent=status.textContent;}).observe(status,{childList:true,subtree:true,characterData:true});
  conversation.append(status,transcript,composer);root.append(conversation);
  const workView=initBotWork({root,conversation,settings:botSettings,current,invoke});
  let taskReply=null,taskReplyRefs=[],taskRecovery=null;
  let active=null, busy=false, messages=[], proposals=[], pending=false, poll=null;
  const preferences=new Map(), sessions=new Map();let selected=provider.value,catalog=[],files=[];
  const newHistory=()=>createConversationStore({getItem:key=>localStorage.getItem(storageKey(key)),setItem:(key,value)=>localStorage.setItem(storageKey(key),value)});
  let history=newHistory();
  let conversationTaskLinks=[];
  let conversationId=null,lastSaved='',pendingTurn=null,restoring=false,historyNavigation=0;
  function updateHistory(){
    const items=history.list(selected), options=[{id:'',title:'New conversation'},...items];
    if(historyPicker.options.length!==options.length||options.some((o,i)=>historyPicker.options[i]?.value!==o.id||historyPicker.options[i]?.textContent!==o.title)){
      historyPicker.replaceChildren();for(const item of options){const option=node('option',item.title);option.value=item.id;historyPicker.append(option);}
    }
    historyPicker.value=conversationId??'';deleteConversation.disabled=busy||!conversationId;conversationSidebar?.render();
  }
  function snapshot(){
    return {...(conversationTaskLinks.length?{taskLinks:conversationTaskLinks}:{}),messages:pendingTurn?messages.slice(0,pendingTurn.messageCount):messages,
      entries:[...transcript.children].filter(e=>!e.classList.contains('live-reply')).map(e=>({role:e.classList.contains('bot-user')?'user':e.classList.contains('bot-assistant')?'assistant':'result',label:e.querySelector('.eyebrow')?.textContent??'',text:e.querySelector('.bot-message-text')?.dataset.rawText??e.querySelector('.bot-message-text')?.textContent??'',referenceWorld:e.querySelector('.bot-message-text')?.dataset.referenceWorld||null,proposals:[...e.querySelectorAll('.bot-proposal:not(.bot-proposal-set)')].map(p=>p.dataset.savedText??[...p.children].filter(c=>c.tagName!=='BUTTON').map(c=>c.dataset.rawText??c.textContent).join('\n'))})),
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
    conversationTaskLinks=[];taskReply=null;taskReplyRefs=[];taskRecovery=null;activity.reset();
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
    showFiles();updateHistory();restoring=false;transcript.dataset.follow='true';requestAnimationFrame(()=>{transcript.scrollTop=transcript.scrollHeight;});
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
  function publishSession(){publishTaskSession({botId:bot.id,world:runtimeWorld(current),ready:!!active,reply:taskReply,recovery:taskRecovery,tasks:taskReplyRefs.length?taskReplyRefs:files.map(f=>editReferences.get(f)?.task).filter(Boolean),prepared:!busy&&files.some(f=>editReferences.get(f)?.task),message:taskReply==='Waiting for reply'?'Request in progress. Task activity shows observed assistant output.':status.textContent});}
  new MutationObserver(publishSession).observe(status,{childList:true});
  function refresh() {
    conversationSidebar?.render();
    activity.refresh({id:bot.id,name:bot.name,model:active?.model,ready:!!active,pending,busy,hasProposals:proposals.some(p=>p.state==='proposed')});
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
  attach.addEventListener('change',async()=>{if(busy)return;busy=true;refresh();const chosen=[...attach.files];attach.value='';try{const additions=[];for(const f of chosen){if(files.length+additions.length>=4||f.size>REVIEW_FILE_BYTES)throw new Error('Attach up to four text/code files, each at most '+REVIEW_FILE_LABEL+'.');const content=new TextDecoder('utf-8',{fatal:true}).decode(await f.arrayBuffer());if(content.includes('\0')||!/\.(txt|md|json|csv|js|ts|tsx|jsx|rs|py|ex|exs|html|css|yaml|yml|toml|xml|log)$/i.test(f.name))throw new Error('This attachment type is not supported yet. Choose a UTF-8 text or code file.');additions.push({name:f.name,content});}files.push(...additions);showFiles();status.textContent='Attachments will be shared with the selected provider when you send.';}catch(error){status.textContent=String(error);}finally{busy=false;refresh();}});
  function showModels(){modelPicker.replaceChildren();const list=[...catalog];if(active&&!list.some(m=>m.id===active.model))list.push({id:active.model,name:active.model});for(const m of list){const o=node('option',m.name||m.id);o.value=m.id;modelPicker.append(o);}modelPicker.hidden=!active;if(active)modelPicker.value=active.model;showEfforts();}
  function showEfforts(){const info=catalog.find(m=>m.id===active?.model)??(provider.value==='claude'?catalog.find(m=>m.id.replace(/\[1m\]$/,'')===active?.model):null);const levels=info?.supportedReasoningEfforts?.map(x=>x.reasoningEffort)??[];effort.replaceChildren();for(const value of ['',...levels]){const o=node('option',value?value[0].toUpperCase()+value.slice(1):'Provider default');o.value=value;effort.append(o);}const saved=preferences.get(provider.value)?.efforts?.[active?.model];effort.value=levels.includes(saved)?saved:'';}
  effort.addEventListener('change',()=>rememberChoice(provider.value,{efforts:{...preferences.get(provider.value)?.efforts,[active.model]:effort.value}}));
  function stash(){saveCurrent();sessions.set(selected,{active,messages,proposals,catalog,files,draft:input.value,children:[...transcript.childNodes],taskLinks:conversationTaskLinks,status:status.textContent,conversationId,includeContext:include.checked});}
  let changingBot=false,loadingProvider=false;
  provider.addEventListener('change',async()=>{
    historyNavigation++;
    if(!changingBot&&!saveCurrent()){provider.value=selected;return;}
    taskReply=null;taskReplyRefs=[];taskRecovery=null;root.querySelectorAll('.task-conversation-backlink').forEach(n=>n.remove());
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
  fresh.addEventListener('click',()=>{if(busy||!saveCurrent())return;historyNavigation++;reset();workView.conversation();status.textContent=active?'New conversation. Ready for your message.':'Configure a provider first.';refresh();});
  composer.addEventListener('submit',async e=>{
    e.preventDefault();const draft=input.value;const sentFiles=[...files];const sentReferences=sentFiles.map(f=>editReferences.get(f)).filter(Boolean);const text=input.value.trim();if(busy||!active||(!text&&!files.length))return;
    if(messages.length>=44){status.textContent='Start a new conversation to continue.';return;}
    const wantsTitle=!conversationId||history.list(selected).find(c=>c.id===conversationId)?.titleSource==='fallback';
    const frame=live(),origin=worldKey(frame),workspace=selectedWorkspace();
    const turnContext=context();
    taskReplyRefs=sentReferences.map(r=>r.task).filter(Boolean);taskReply='Waiting for reply';taskRecovery=null;
    const activityId=crypto.randomUUID();beginTaskActivity({id:activityId,botId:bot.id,world:runtimeWorld(current),tasks:taskReplyRefs,provider:active.provider,model:active.model});
    pendingTurn={draft,files:sentFiles,messageCount:messages.length};transcript.dataset.follow='true';requestAnimationFrame(()=>{transcript.scrollTop=transcript.scrollHeight;});
    messages.push({role:'user',content:text,attachments:sentFiles});line('user',[text,...sentFiles.map(f=>`Attached: ${f.name}`)].join('\n'));input.value='';files=[];showFiles();busy=true;refresh();status.textContent=active.provider==='codex'?'Waiting for Codex… Large file replies can take up to five minutes.':`Waiting for ${active.provider}… Replies can take up to ${active.provider==='claude'?({max:'30',xhigh:'15',high:'10'}[effort.value]||'five'):'two'} minutes.`;saveCurrent();
    activity.start(['codex','claude'].includes(active.provider));
    streamText='';liveReply=node('article',undefined,'bot-assistant live-reply');liveReply.append(node('p','Generating…','eyebrow'),node('div','','bot-message-text'));transcript.append(liveReply);
    /* The bubble is where a person looks while they wait, and it said
 * "Waiting for reply…" for every second of reasoning — which at extended
 * thinking levels is minutes of a screen that looks stuck. Until prose
 * arrives, show what the provider is actually doing; the phase carries a
 * magnitude that climbs, so the wait reads as work rather than a hang. */
    const observeLive=r=>{if(!pendingTurn)return;activity.observe(r);if(typeof r.text==='string'){streamText=streamingReply(r.text,['codex','claude'].includes(active.provider));const working=r.phase&&r.phase!=='Waiting for provider'?r.phase+'…':'Waiting for reply…';liveReply.querySelector('.bot-message-text').textContent=streamText||working;liveReply.querySelector('.eyebrow').textContent=streamText?'Generating…':/^Thinking/.test(r.phase||'')?'Thinking…':'Generating…';if(transcript.dataset.follow!=='false')transcript.scrollTop=transcript.scrollHeight;}conversationSidebar?.render();};
    const onEvent=new window.__TAURI__.core.Channel();onEvent.onmessage=observeLive;
    replyId=['codex','claude'].includes(active.provider)?crypto.randomUUID():null;
    if(replyId){const id=replyId,p=active.provider;const poll=async()=>{try{const r=await invoke(managedCommand(p),{operation:'reply_status',requestId:id});if(replyId!==id)return;cancelReply.hidden=!r.active;cancelReply.disabled=r.cancelled;observeLive(r);observeTaskActivity(activityId,r);if(r.active&&!r.cancelled)status.textContent=r.received_bytes?`Receiving ${managedName(p)} reply… ${r.received_bytes.toLocaleString()} bytes of assistant text received.`:`${r.phase||'Waiting for provider'}…`;}catch{}if(replyId===id)replyPoll=setTimeout(poll,300);};poll();}
    try {
      const reply=await invoke('bot_chat' ,{onEvent,turn:{expected_model:active.model,request_id:replyId,provider:active.provider,messages,context:turnContext,bot_instructions:`Name: ${bot.name}\nRole: ${bot.role}\n${bot.instructions}\n${wantsTitle?titleInstruction:''}`,effort:effort.value||null}});
      const titled=conversationReply(reply.text,wantsTitle);reply.text=titled.text;
      liveReply?.remove();liveReply=null;
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
      observeTaskActivity(activityId,{type:'finish',text:reply.text||''});activity.finish(false);taskReply='Reply received';pendingTurn=null;status.textContent='Reply received.';
      replyId=null;clearTimeout(replyPoll);cancelReply.hidden=true;
      saveCurrent();
      if(conversationId&&wantsTitle){try{history.update(selected,conversationId,titled.title?{title:titled.title,titleSource:'ai'}:{titleSource:'attempted'});}catch{/* Reply remains usable if local title storage is full. */}}

    }catch(error){if(streamText)line('result','Interrupted reply (partial):\n'+streamText);taskRecovery=replyFailure(error);observeTaskActivity(activityId,{type:'finish',error:true,failure:String(error)});activity.finish(true);taskReply='Reply did not complete';pendingTurn=null;messages.pop();if(!input.value)input.value=draft;files=sentFiles;showFiles();status.textContent=String(error);line('result',String(error));if(active?.provider==='claude'&&String(error).includes('sign-in has expired')){active=null;modelPicker.hidden=true;}}
    finally{liveReply?.remove();liveReply=null;streamText='';replyId=null;clearTimeout(replyPoll);cancelReply.hidden=true;busy=false;saveCurrent();refresh();if(transcript.dataset.follow!=='false')transcript.scrollTop=transcript.scrollHeight;}
  });
  historyPicker.addEventListener('change',()=>{if(busy)return;historyNavigation++;const id=historyPicker.value;if(!saveCurrent()){updateHistory();return;}restoreSaved(id||null);saveCurrent();refresh();});
  deleteConversation.addEventListener('click',()=>{if(busy||!conversationId)return;if(!confirm('Delete this saved conversation and its locally saved attachments?'))return;try{history.remove(selected,conversationId);sessions.delete(selected);reset();historyStatus.textContent='Conversation deleted from this device.';refresh();}catch(error){historyStatus.textContent=String(error);}});
  input.addEventListener('input',()=>{historyNavigation++;saveCurrent();});
  document.addEventListener('before-page-select',()=>{historyNavigation++;});
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
  botSettings.prepend(board);
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
  const roster=initBotDirectory({runtimeCurrent:current,runtimeBotActions,canSave:()=>!busy&&!runtimeBusy&&!pending,current:()=>bot,select:next=>{
    const chosen=!conversationNavigation;
    if(next.id===bot.id){bot=next;showIdentity();if(chosen)conversationSidebar?.scopeToBot(next.id);return true;}
    if(busy||pending||runtimeBusy){status.textContent='Wait for the current reply or connection to finish before switching bots.';return false;}
    if(!saveCurrent())return false;
    root.querySelectorAll('.task-conversation-backlink').forEach(n=>n.remove());
    conversationTaskLinks=[];taskReply=null;taskReplyRefs=[];taskRecovery=null;activity.reset();bot=next;history=newHistory();preferences.clear();sessions.clear();
    try{for(const [p,v] of JSON.parse(localStorage.getItem(storageKey('super-provider-preferences'))||'[]'))preferences.set(p,v);}catch{}
    let remembered=bot.provider;try{remembered=localStorage.getItem(storageKey('super-last-provider'))||remembered;}catch{}
    provider.value=[...provider.options].some(o=>o.value===remembered)?remembered:bot.provider;
    active=null;messages=[];proposals=[];files=[];catalog=[];conversationId=null;lastSaved='';pendingTurn=null;
    transcript.replaceChildren();input.value='';changingBot=true;showIdentity();provider.dispatchEvent(new Event('change'));
    if(chosen)conversationSidebar?.scopeToBot(bot.id);
    return true;
  }});
  document.addEventListener('runtime-view-rendered',showIdentity);
  new MutationObserver(showIdentity).observe(document.getElementById('world'),{childList:true});
  showIdentity();
  const storeFor=id=>id===bot.id?history:createConversationStore({getItem:key=>localStorage.getItem(id==='assistant'?key:`${key}:bot:${id}`),setItem:(key,value)=>localStorage.setItem(id==='assistant'?key:`${key}:bot:${id}`,value)});
  conversationSidebar=initConversationSidebar({root,fresh,get:()=>({bot,items:roster.list().flatMap(b=>storeFor(b.id).list().map(c=>({...c,botId:b.id}))),bots:roster.list(),active:{id:conversationId,botId:bot.id,provider:selected,generating:!!pendingTurn,liveText:streamText},selected:conversationId,provider:selected,busy:busy||pending}),
    update:(b,p,id,patch)=>{storeFor(b).update(p,id,patch);updateHistory();},
    remove:(b,p,id)=>{if(!confirm('Delete this conversation and its saved attachments?'))return;storeFor(b).remove(p,id);sessions.delete(p);if(bot.id===b&&conversationId===id)reset();updateHistory();},
    open:async(b,p,id)=>{if(busy||pending||!saveCurrent())return;if(b!==bot.id){openingConversation(()=>navigate('bot:'+b,true));for(let i=0;(loadingProvider||busy)&&i<100;i++)await new Promise(r=>setTimeout(r,100));if(bot.id!==b||busy||loadingProvider)throw Error('Connection setup is still busy. Try again shortly.');}let token=++historyNavigation;if(p!==selected){provider.value=p;provider.dispatchEvent(new Event('change'));token=historyNavigation;for(let i=0;(loadingProvider||busy)&&i<300&&token===historyNavigation;i++)await new Promise(r=>setTimeout(r,100));}if(token!==historyNavigation||selected!==p)return;if(busy||loadingProvider){status.textContent='Connection setup is still busy. Reopen this conversation when it finishes.';return;}restoreSaved(id);saveCurrent();refresh();workView.conversation();}
  });conversationSidebar.render();

  document.addEventListener('open-saved-task-conversation',e=>{
    const request={...e.detail},token=++historyNavigation;let tries=0;
    const open=()=>{
      if(token!==historyNavigation)return;
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
    const {botId}=e.detail;let items;historyNavigation++;
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
  initMobileConversationBridge({invoke,view:()=>({
    bots:roster.list().map(b=>({id:b.id,name:b.name,provider:b.provider})),
    conversations:roster.list().flatMap(b=>storeFor(b.id).list().map(c=>({...c,botId:b.id}))),
    active:{botId:bot.id,provider:selected,id:conversationId,model:active?.model??null,effort:effort.value,efforts:[...effort.options].map(o=>o.value),busy:busy||pending||runtimeBusy,generating:!!pendingTurn,status:status.textContent,
      revision:history.list(selected).find(c=>c.id===conversationId)?.revision??null,
      data:conversationId?history.get(selected,conversationId):null,
      liveText:pendingTurn?streamText:''}
  }),perform:async request=>{
    if(busy||pending||runtimeBusy||loadingProvider)throw Error('A desktop conversation operation is in progress. Wait for it to finish.');
    if(!roster.get(request.botId))throw Error('That bot is unavailable.');
    if(!['codex','claude','ollama','openai','anthropic'].includes(request.provider))throw Error('Unknown conversation provider.');
    if(request.operation==='open'){
      const candidate=storeFor(request.botId).list(request.provider).find(c=>c.id===request.conversationId);
      if(request.conversationId&&!candidate)throw Error('That conversation is unavailable.');
      openingConversation(()=>navigate('bot:'+request.botId,true));
      for(let i=0;(loadingProvider||busy)&&i<100;i++)await new Promise(r=>setTimeout(r,100));
      if(bot.id!==request.botId||busy||loadingProvider)throw Error('Desktop connection setup is still busy. Try opening again after it finishes.');
      if(selected!==request.provider){provider.value=request.provider;provider.dispatchEvent(new Event('change'));for(let i=0;(loadingProvider||busy)&&i<100;i++)await new Promise(r=>setTimeout(r,100));}
      if(bot.id!==request.botId||selected!==request.provider||busy||loadingProvider)throw Error('The selected conversation changed during connection setup.');
      if(request.conversationId&&!history.get(selected,request.conversationId))throw Error('This conversation was removed while opening.');if(!saveCurrent())throw Error('Could not save the desktop draft.');restoreSaved(request.conversationId);saveCurrent();refresh();workView.conversation();return {message:'Conversation opened on phone and desktop.'};
    }
    if(request.botId!==bot.id||request.provider!==selected)throw Error('Open this bot and provider on the desktop before changing its conversation.');
    if(request.operation==='create'){
      if(request.taskContext!==undefined){
        const data=taskDiscussion(heldProjection(current),runtimeWorld(current),request.taskContext);
        if(!saveCurrent())throw Error('Could not save the desktop draft.');
        const id=history.save(selected,null,data);restoreSaved(id);lastSaved=JSON.stringify(snapshot());updateHistory();refresh();workView.conversation();
        return {message:'Task discussion prepared. Review the draft and choose a model before sending.',conversationId:id};
      }
      if(!saveCurrent())throw Error('Could not save the desktop draft.');reset();input.value=typeof request.text==='string'?request.text.slice(0,8000):'';
      if(!input.value)input.value='';
      conversationId=history.save(selected,null,snapshot());lastSaved=JSON.stringify(snapshot());updateHistory();refresh();return {message:'Conversation created.',conversationId};
    }
    const record=history.list(selected).find(c=>c.id===request.conversationId);
    if(!record||record.revision!==request.revision)throw Error('This conversation changed on another screen. Refresh before editing.');
    if(request.operation==='update'){
      history.update(selected,record.id,{...(typeof request.title==='string'?{title:request.title}:{}),...(typeof request.pinned==='boolean'?{pinned:request.pinned}:{})});updateHistory();return {message:'Conversation updated.'};
    }
    if(conversationId!==request.conversationId)throw Error('Open this conversation before editing or sending.');
    if(typeof request.text!=='string'||request.text.length>8000)throw Error('Enter a message of at most 8,000 characters.');
    if(request.operation==='send'){
      if(!active||typeof request.model!=='string'||!request.model.trim()||request.model!==active.model)throw Error('Select the exact connected model before sending. No default model will be used.');
      if(![...effort.options].some(o=>o.value===(request.effort??'')))throw Error('The requested thinking level is unavailable.');
      if(!request.text.trim())throw Error('Enter a message before sending.');
      if(messages.length>=44)throw Error('Start a new conversation to continue.');
      if(files.length)throw Error('This desktop draft has attachments. Review and send them from desktop.');
      effort.value=request.effort??'';
    }
    input.value=request.text;if(!saveCurrent())throw Error('Could not save the shared draft.');
    if(request.operation==='send'){composer.requestSubmit();return {message:'Message dispatched. Follow its progress in this conversation.'};}
    if(request.operation!=='draft')throw Error('Unsupported conversation operation.');
    return {message:'Draft saved on desktop.'};
  }});

}
