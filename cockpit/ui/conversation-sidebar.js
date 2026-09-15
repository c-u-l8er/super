import {node} from './app-shell.js';
export function initConversationSidebar({root,fresh,get,open,update,remove}){
  const rail=document.getElementById('rail-bots'),list=node('section',undefined,'conversation-sidebar');rail.append(list);
  const heading=node('h2',undefined,'conversation-title');root.querySelector('.bot-conversation').prepend(heading);
  const notice=node('p','','availability-note');notice.setAttribute('role','status');let signature='';
  const act=(label,fn)=>{const b=node('button',label,'subtle');b.type='button';b.onclick=async()=>{try{await fn();notice.textContent='';}catch(e){notice.textContent=e.message;}};return b;};
  function render(){
    const {bot,items,selected,provider,busy}=get();const visible=!root.hidden;
    list.hidden=!visible;for(const child of rail.children)if(child!==list)child.hidden=visible;
    const current=items.find(c=>c.id===selected&&c.provider===provider);heading.textContent=current?.title||'New conversation';
    const sig=JSON.stringify([bot.id,bot.name,items,selected,provider,busy]);if(sig===signature)return;signature=sig;
    const back=act('← All bots',()=>document.querySelector('#bot-directory')&&document.querySelector('#rail-bots [data-nav="bots"]').click());
    list.replaceChildren(back,node('h2',bot.name),fresh);
    for(const [label,pinned] of [['Pinned',true],['Recent',false]]){
      list.append(node('h3',label,'rail-label'));const group=items.filter(c=>c.pinned===pinned);
      if(!group.length)list.append(node('p',pinned?'No pinned conversations':'No recent conversations','rail-hint'));
      for(const c of group){
        const row=node('div',undefined,'conversation-row'),choose=act(c.title,()=>open(c.provider,c.id));choose.className='nav-item conversation-link';choose.dataset.conversation=c.id;choose.setAttribute('aria-current',c.id===selected&&c.provider===provider?'page':'false');choose.title=c.title;choose.disabled=busy;
        choose.append(node('small',`${c.provider} · ${new Date(c.updated).toLocaleDateString()}`));
        const more=node('details',undefined,'conversation-menu');more.append(node('summary','⋯'));more.querySelector('summary').setAttribute('aria-label','Options for '+c.title);
        const pin=act(c.pinned?'Unpin':'Pin',()=>update(c.provider,c.id,{pinned:!c.pinned}));
        const rename=node('form'),title=node('input');title.value=c.title;title.maxLength=100;title.required=true;title.setAttribute('aria-label','Conversation title');const save=node('button','Save title');save.type='submit';rename.append(title,save);rename.onsubmit=e=>{e.preventDefault();try{update(c.provider,c.id,{title:title.value});}catch(error){notice.textContent=error.message;}};
        const del=act('Delete conversation',()=>remove(c.provider,c.id));for(const control of [pin,title,save,del])control.disabled=busy;
        more.append(pin,rename,del);row.append(choose,more);list.append(row);
      }
    }list.append(notice);
  }
  document.addEventListener('page-selected',render);new MutationObserver(render).observe(root,{attributes:true,attributeFilter:['hidden']});return {render};
}
