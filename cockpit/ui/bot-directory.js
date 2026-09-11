import { heldProjection, registeredBot, registrationUnavailable, runtimeWorld, profileOf, botFields, waitForBot } from './runtime-bots.js';
import {node,navigate} from './app-shell.js';
import {createBotRoster,providers} from './bot-roster.js';
export function initBotDirectory({select,current,runtimeCurrent,runtimeBotActions,canSave}) {
  const localRoster=createBotRoster(localStorage);
  const roster={error:localRoster.error,save:b=>localRoster.save(b),get:id=>{const r=registeredBot(runtimeCurrent,id);return r?profileOf(r):localRoster.get(id);},list:()=>{const profiles=new Map(localRoster.list().map(b=>[b.id,b]));for(const r of Object.values(heldProjection(runtimeCurrent)?.bots??{}))profiles.set(r.client_ref,profileOf(r));return [...profiles.values()];}};
  const canvas=document.getElementById('workspace-canvas');
  const directory=node('section',undefined,'app-screen');directory.dataset.screen='bots';directory.hidden=true;
  const creation=node('section',undefined,'app-screen');creation.dataset.screen='new-bot';creation.hidden=true;
  directory.id='bot-directory';creation.id='bot-creation';canvas.append(directory,creation);
  const notice=node('p',roster.error||'','bot-status');notice.setAttribute('role','status');
  const button=(text,route,cls='subtle')=>{const b=node('button',text,cls);b.type='button';b.dataset.nav=route;return b;};
  creation.append(button('← All bots','bots'),node('p','SUPER / BOTS / CREATE','eyebrow'),node('h1','Create bot'),node('p','Give this bot a name, a purpose, and a provider. Its conversations are saved separately on this device.','screen-description'));
  const form=node('form',undefined,'bot-profile-form');
  const fields={};let editing=null,editingRecord=null,editingWorld=null,saving=false,renderSignature='';
  for(const [key,label,max,multi] of [['name','Name',80],['role','Role',100],['group','Group',80],['instructions','Instructions',4000,true]]){
    const control=node(multi?'textarea':'input');control.name=key;control.id='new-bot-'+key;control.maxLength=max;control.required=!multi;if(multi)control.rows=5;
    const wrap=node('label',label,'field');wrap.append(control);form.append(wrap);fields[key]=control;
  }
  fields.group.value='General';
  const provider=node('select');provider.id='new-bot-provider';for(const id of providers){const o=node('option',id==='codex'?'ChatGPT / Codex':id==='claude'?'Claude · local session':id);o.value=id;provider.append(o);}
  const label=node('label','Provider','field');label.append(provider);form.append(label);
  const save=node('button','Create bot','primary');save.type='submit';save.id='create-bot-submit';
  form.append(node('p','Created bots start as conversational profiles. Runtime execution and capability delegation require the runtime bot contract.','availability-note'),save,button('Cancel','bots'),notice);creation.append(form);
  function render(){
    const signature=JSON.stringify([roster.list(),heldProjection(runtimeCurrent)?Object.values(heldProjection(runtimeCurrent).bots??{}).map(b=>[b.id,b.revision]):null]);if(signature===renderSignature)return;renderSignature=signature;
    directory.replaceChildren(node('p','SUPER / BOTS','eyebrow'),node('h1','Bots'),node('p','Choose a persistent role for your work. Each bot has its own page, instructions, and saved conversations.','screen-description'),button('+ Create bot','new-bot','primary'));
    if(roster.error)directory.append(node('p',roster.error,'availability-note'));
    const rail=document.getElementById('bot-roster-links');if(rail)rail.replaceChildren();
    const groups=[...new Set(roster.list().map(b=>b.group))];
    for(const group of groups){
      directory.append(node('h2',group));if(rail)rail.append(node('p',group.toUpperCase(),'rail-label'));
      for(const bot of roster.list().filter(b=>b.group===group)){
        const row=node('article',undefined,'bot-profile-card');row.append(button(bot.name,'bot:'+bot.id,'record-trigger'),node('p',bot.role,'record-row-subtitle'),node('p',bot.instructions||'No instructions yet.','directory-note'),node('span',!heldProjection(runtimeCurrent)?'Runtime status unavailable':registeredBot(runtimeCurrent,bot.id)?'Registered in runtime':'Local conversational profile','status-chip'));
        directory.append(row);
        if(rail){const link=button('','bot:'+bot.id,'nav-item bot-roster-link');const copy=node('span',bot.name);copy.append(node('small',bot.role));link.append(copy);link.classList.toggle('on',current()?.id===bot.id);rail.append(link);}
      }
    }
  }
  form.addEventListener('submit',async e=>{
    e.preventDefault();if(!form.reportValidity()||saving)return;
    if(!canSave()){notice.textContent='Wait for the current bot operation to finish.';return;}
    const value=Object.fromEntries([['id',editing||''],...Object.entries(fields).map(([key,c])=>[key,c.value]),['provider',provider.value]]);
    saving=true;save.disabled=true;
    try{
      let bot;
      if(editingRecord){
        if(runtimeWorld(runtimeCurrent)!==editingWorld||!heldProjection(runtimeCurrent))throw new Error('The runtime changed or disconnected. Reopen the bot profile before saving.');
        const args={bot_ref:editingRecord.id,revision:editingRecord.revision,...botFields(value,editingRecord.workspace_ref)};
        if(!await runtimeBotActions.update(args))throw new Error('The profile update was refused. Check Activity and reopen the latest profile.');
        await waitForBot(runtimeCurrent,editingWorld,p=>p.bots?.[editingRecord.id]?.revision>editingRecord.revision);
        bot=roster.get(value.id);
      }else bot=roster.save(value);
      notice.textContent='';form.reset();fields.group.value='General';render();saving=false;navigate('bot:'+bot.id,true);
    }catch(error){notice.textContent=String(error);}finally{saving=false;save.disabled=false;}
  });
  document.addEventListener('before-page-select',e=>{
    if(saving){e.preventDefault();return;}
    if(e.detail.id==='new-bot'||e.detail.id==='edit-bot'){
      creation.dataset.screen=e.detail.id;
      if(e.detail.id==='edit-bot'){
        if(registrationUnavailable(runtimeCurrent,current()?.id)){e.preventDefault();document.querySelector('#bot-status').textContent='Reconnect to edit this registered bot.';return;}
        const bot=roster.get(current()?.id);if(!bot){e.preventDefault();return;}
        editing=bot.id;editingRecord=registeredBot(runtimeCurrent,bot.id);editingWorld=runtimeWorld(runtimeCurrent);for(const [key,control] of Object.entries(fields))control.value=bot[key];provider.value=bot.provider;
      }else if(editing){form.reset();fields.group.value='General';editing=null;editingRecord=null;}
      label.hidden=!!editing;creation.querySelector('h1').textContent=editing?'Edit bot':'Create bot';save.textContent=editing?'Save bot':'Create bot';return;
    }
    if(!e.detail.id.startsWith('bot:'))return;
    const bot=roster.get(e.detail.id.slice(4));if(!bot||!select(bot)){e.preventDefault();return;}
    document.getElementById('bot-surface').dataset.screen=e.detail.id;
  });
  document.addEventListener('shell-ready',()=>{renderSignature='';render();});document.addEventListener('runtime-view-rendered',render);new MutationObserver(render).observe(document.getElementById('world'),{childList:true});render();
  return roster;
}
