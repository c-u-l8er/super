import {node,navigate} from './app-shell.js';
import {conversationGroups,conversationKey,conversationStatus,readTracker,scopedFilter} from './conversation-list.js';
export function initConversationSidebar({root,fresh,get,open,update,remove}){
 const rail=document.getElementById('rail-bots'),list=node('section',undefined,'conversation-sidebar');rail.append(list);
 const heading=node('h2',undefined,'conversation-title');root.querySelector('.bot-conversation').prepend(heading);
 fresh.textContent='＋';fresh.title='New conversation';fresh.setAttribute('aria-label','New conversation');
 const notice=node('p','','availability-note');notice.setAttribute('role','status');let signature='',filter='all',order='recent',query='';
 const tracker=readTracker(localStorage,'super-conversation-read-desktop-v1');
 const act=(label,fn)=>{const b=node('button',label,'subtle');b.type='button';b.onclick=async()=>{try{await fn();notice.textContent='';}catch(e){notice.textContent=e.message;}};return b;};
 const controls=node('div',undefined,'conversation-controls'),search=node('input'),bots=node('select'),sort=node('select');search.placeholder='Search conversations';search.setAttribute('aria-label','Search conversations');bots.setAttribute('aria-label','Filter by bot');sort.setAttribute('aria-label','Sort conversations');for(const [v,t]of [['recent','Most recent'],['bot','Group by bot']]){const o=node('option',t);o.value=v;sort.append(o)}controls.append(search,bots,sort);search.oninput=()=>{query=search.value;signature='';render()};bots.onchange=()=>{filter=bots.value;signature='';render()};sort.onchange=()=>{order=sort.value;signature='';render()};
 const rows=node('div'),top=node('div',undefined,'conversation-list-heading');top.append(node('h2','Conversations'),fresh);
 // The directory is reached from the top of the list, not from a control below
 // it: with a long conversation list the old bottom button was off-screen. It
 // navigates directly rather than clicking a hidden rail proxy.
 const directory=node('button',undefined,'subtle conversation-directory'),directoryLabel=node('span','← All bots'),elsewhere=node('small','','conversation-elsewhere');directory.type='button';directory.title='Show every bot';directory.append(directoryLabel);directory.setAttribute('aria-label','All bots — open the bot directory');directory.onclick=()=>{notice.textContent='';navigate('bots',true);};
 /* Unread conversations this view hides are announced on the directory button,
  * because it is the one control that is always visible and is already the way
  * to reach them. The badge is a CHILD of that button, never a sibling:
  * .conversation-sidebar > button is pinned by tools/bot-navigation-smoke.mjs
  * and by two other driven smokes as the single way back. The wording carries
  * the count in text, so it survives without colour and without the badge. */
 const unreadPhrase=n=>n+(n===1?' unread conversation':' unread conversations')+' not shown in this view';
 const hint=node('p','A reply is generating — other chats unlock when it finishes, or cancel it from the conversation.','rail-hint');hint.hidden=true;
 list.append(directory,top,controls,rows,hint,notice);
 /* An explicit bot choice is the person speaking; a rerender is not. Only the
  * paths that mean "I chose this bot" call this, and a refused or pending
  * switch never reaches it, so the chosen scope survives both. */
 function scopeToBot(id){filter=id;query='';search.value='';signature='';render();}
 function render(){
  const state=get(),{bot,selected,provider,busy,active}=state,visible=!root.hidden;
  filter=scopedFilter(filter,state.bots);
  list.hidden=!visible;for(const child of rail.children)if(child!==list)child.hidden=visible;
  const reading=visible&&!document.hidden&&!root.querySelector('.bot-conversation').hidden&&root.querySelector('#bot-transcript').dataset.follow!=='false'?conversationKey(active):null;
  const items=tracker.update(state.items,reading),current=items.find(c=>c.botId===bot.id&&c.id===selected&&c.provider===provider);heading.textContent=current?.title||'New conversation';
  const sig=JSON.stringify([items,state.bots,selected,provider,busy,active?.generating,!!active?.liveText,filter,order,query]);if(sig===signature)return;signature=sig;
  const choices=JSON.stringify(state.bots.map(b=>[b.id,b.name]));if(bots.dataset.choices!==choices){bots.dataset.choices=choices;bots.replaceChildren();for(const b of [{id:'all',name:'All conversations'},...state.bots]){const o=node('option',b.name);o.value=b.id;bots.append(o)}}
  if(bots.value!==filter)bots.value=filter;
  rows.replaceChildren();
  const groups=conversationGroups(items,state.bots,{bot:filter,sort:order,search:query}),shown=new Set(groups.flatMap(g=>g.items).map(conversationKey)),elsewhereCount=items.filter(c=>c.unread&&!shown.has(conversationKey(c))).length;
  /* The count is exactly what this render left out — the rendered groups are the
   * only source, so the bot scope and the search text are both accounted for,
   * keys mean no conversation is counted twice, and there is no second filter
   * that could drift from conversationGroups. Seeing it changes nothing: the
   * scope, the order, the search and the selection are the person's. */
  directory.replaceChildren(directoryLabel);elsewhere.textContent=' · ● '+elsewhereCount+' unread elsewhere';directory.title=elsewhereCount?'Show every bot · '+unreadPhrase(elsewhereCount):'Show every bot';directory.setAttribute('aria-label','All bots — open the bot directory'+(elsewhereCount?' · '+unreadPhrase(elsewhereCount):''));if(elsewhereCount){directory.append(elsewhere);directory.dataset.unread=String(elsewhereCount);}else delete directory.dataset.unread;
  for(const group of groups){
   rows.append(node('h3',group.label,'rail-label'));
   for(const c of group.items){
    const row=node('div',undefined,'conversation-row'),choose=act(c.title,()=>open(c.botId,c.provider,c.id));choose.className='nav-item conversation-link';choose.dataset.conversation=c.id;const here=c.botId===bot.id&&c.id===selected&&c.provider===provider;choose.setAttribute('aria-current',here?'page':'false');choose.title=busy&&!here?'A reply is generating. This chat unlocks when it finishes.':c.title;choose.disabled=busy&&!here;
    const status=conversationStatus(c,active),badge=node('small',(c.unread?'● New reply · ':'')+status,'conversation-state');badge.dataset.state=status;choose.append(badge,node('small',state.bots.find(b=>b.id===c.botId)?.name+' · '+c.provider));
    const more=node('details',undefined,'conversation-menu'),summary=node('summary','•••');summary.setAttribute('aria-label','Options for '+c.title);more.append(summary);more.ontoggle=()=>{if(more.open)for(const other of rows.querySelectorAll('details[open]'))if(other!==more)other.open=false;};
    const menu=node('div',undefined,'conversation-menu-panel'),pin=act(c.pinned?'Unpin conversation':'Pin conversation',()=>update(c.botId,c.provider,c.id,{pinned:!c.pinned}));
    const rename=node('form'),title=node('input');title.value=c.title;title.maxLength=100;title.required=true;title.setAttribute('aria-label','Conversation title');const save=node('button','Save title');save.type='submit';rename.append(title,save);rename.onsubmit=e=>{e.preventDefault();try{update(c.botId,c.provider,c.id,{title:title.value});}catch(error){notice.textContent=error.message;}};
    const del=act('Delete conversation',()=>remove(c.botId,c.provider,c.id));del.classList.add('danger');for(const control of [pin,title,save,del])control.disabled=busy;
    menu.append(pin,rename,del);more.append(menu);row.append(choose,more);rows.append(row);
   }
  }
  if(!rows.children.length)rows.append(node('p','No matching conversations','rail-hint'));
  /* Every row is disabled while a reply runs, because opening another chat
   * would have to save and swap the conversation the reply is still writing
   * into. That constraint is real; being unable to tell it from a dead UI is
   * not. At extended reasoning levels a reply can hold this for minutes, so
   * the reason is said out loud, next to the control that lifts it. */
  hint.hidden=!busy;
 }
 document.addEventListener('page-selected',render);document.addEventListener('visibilitychange',render);root.querySelector('#bot-transcript').addEventListener('scroll',render);new MutationObserver(render).observe(root,{attributes:true,attributeFilter:['hidden']});return {render,scopeToBot};
}
