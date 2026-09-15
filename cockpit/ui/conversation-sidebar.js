import {node} from './app-shell.js';
import {conversationGroups,conversationKey,conversationStatus,readTracker} from './conversation-list.js';
export function initConversationSidebar({root,fresh,get,open,update,remove}){
 const rail=document.getElementById('rail-bots'),list=node('section',undefined,'conversation-sidebar');rail.append(list);
 const heading=node('h2',undefined,'conversation-title');root.querySelector('.bot-conversation').prepend(heading);
 fresh.textContent='＋';fresh.title='New conversation';fresh.setAttribute('aria-label','New conversation');
 const notice=node('p','','availability-note');notice.setAttribute('role','status');let signature='',filter='all',order='recent',query='';
 const tracker=readTracker(localStorage,'super-conversation-read-desktop-v1');
 const act=(label,fn)=>{const b=node('button',label,'subtle');b.type='button';b.onclick=async()=>{try{await fn();notice.textContent='';}catch(e){notice.textContent=e.message;}};return b;};
 const controls=node('div',undefined,'conversation-controls'),search=node('input'),bots=node('select'),sort=node('select');search.placeholder='Search conversations';search.setAttribute('aria-label','Search conversations');bots.setAttribute('aria-label','Filter by bot');sort.setAttribute('aria-label','Sort conversations');for(const [v,t]of [['recent','Most recent'],['bot','Group by bot']]){const o=node('option',t);o.value=v;sort.append(o)}controls.append(search,bots,sort);search.oninput=()=>{query=search.value;signature='';render()};bots.onchange=()=>{filter=bots.value;signature='';render()};sort.onchange=()=>{order=sort.value;signature='';render()};
 const rows=node('div'),top=node('div',undefined,'conversation-list-heading');top.append(node('h2','Conversations'),fresh);list.append(top,controls,rows,act('Manage bots',()=>document.querySelector('#rail-bots [data-nav="bots"]')?.click()),notice);
 function render(){
  const state=get(),{bot,selected,provider,busy,active}=state,visible=!root.hidden;
  list.hidden=!visible;for(const child of rail.children)if(child!==list)child.hidden=visible;
  const reading=visible&&!document.hidden&&!root.querySelector('.bot-conversation').hidden&&root.querySelector('#bot-transcript').dataset.follow!=='false'?conversationKey(active):null;
  const items=tracker.update(state.items,reading),current=items.find(c=>c.botId===bot.id&&c.id===selected&&c.provider===provider);heading.textContent=current?.title||'New conversation';
  const sig=JSON.stringify([items,state.bots,selected,provider,busy,active?.generating,!!active?.liveText,filter,order,query]);if(sig===signature)return;signature=sig;
  const choices=JSON.stringify(state.bots.map(b=>[b.id,b.name]));if(bots.dataset.choices!==choices){bots.dataset.choices=choices;bots.replaceChildren();for(const b of [{id:'all',name:'All bots'},...state.bots]){const o=node('option',b.name);o.value=b.id;bots.append(o)}bots.value=filter;}
  rows.replaceChildren();
  for(const group of conversationGroups(items,state.bots,{bot:filter,sort:order,search:query})){
   rows.append(node('h3',group.label,'rail-label'));
   for(const c of group.items){
    const row=node('div',undefined,'conversation-row'),choose=act(c.title,()=>open(c.botId,c.provider,c.id));choose.className='nav-item conversation-link';choose.dataset.conversation=c.id;choose.setAttribute('aria-current',c.botId===bot.id&&c.id===selected&&c.provider===provider?'page':'false');choose.title=c.title;choose.disabled=busy;
    const status=conversationStatus(c,active),badge=node('small',(c.unread?'● New reply · ':'')+status,'conversation-state');badge.dataset.state=status;choose.append(badge,node('small',state.bots.find(b=>b.id===c.botId)?.name+' · '+c.provider));
    const more=node('details',undefined,'conversation-menu'),summary=node('summary','•••');summary.setAttribute('aria-label','Options for '+c.title);more.append(summary);more.ontoggle=()=>{if(more.open)for(const other of rows.querySelectorAll('details[open]'))if(other!==more)other.open=false;};
    const menu=node('div',undefined,'conversation-menu-panel'),pin=act(c.pinned?'Unpin conversation':'Pin conversation',()=>update(c.botId,c.provider,c.id,{pinned:!c.pinned}));
    const rename=node('form'),title=node('input');title.value=c.title;title.maxLength=100;title.required=true;title.setAttribute('aria-label','Conversation title');const save=node('button','Save title');save.type='submit';rename.append(title,save);rename.onsubmit=e=>{e.preventDefault();try{update(c.botId,c.provider,c.id,{title:title.value});}catch(error){notice.textContent=error.message;}};
    const del=act('Delete conversation',()=>remove(c.botId,c.provider,c.id));del.classList.add('danger');for(const control of [pin,title,save,del])control.disabled=busy;
    menu.append(pin,rename,del);more.append(menu);row.append(choose,more);rows.append(row);
   }
  }
  if(!rows.children.length)rows.append(node('p','No matching conversations','rail-hint'));
 }
 document.addEventListener('page-selected',render);document.addEventListener('visibilitychange',render);root.querySelector('#bot-transcript').addEventListener('scroll',render);new MutationObserver(render).observe(root,{attributes:true,attributeFilter:['hidden']});return {render};
}
