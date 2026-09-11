import {node} from './app-shell.js';
let client;
export function sessionLinks(invoke){
  if(client)return client;
  let rows=[],error='',inflight=null;
  function accept(result){rows=result.sessions??[];error='';document.dispatchEvent(new Event('surface-sessions-changed'));return rows;}
  async function refresh(){if(inflight)return inflight;inflight=invoke('surface_sessions',{request:{operation:'list'}}).then(accept).catch(e=>{rows=[];error=String(e);document.dispatchEvent(new Event('surface-sessions-changed'));throw e;}).finally(()=>inflight=null);return inflight;}
  client={get rows(){return rows;},get error(){return error;},refresh,
    async link(surface,botId){await refresh();const row=rows.find(s=>s.kind===surface.kind&&s.id===surface.id&&(s.kind!=='terminal'||s.generation===surface.generation));if(!row)throw Error('This session has closed. Open a live tab first.');if(inflight)await inflight;accept(await invoke('surface_sessions',{request:{operation:'link',session_id:row.session_id,bot_id:botId}}));},
    async unlink(id){accept(await invoke('surface_sessions',{request:{operation:'unlink',session_id:id}}));},
    async resolve(id,botId){await refresh();const row=rows.find(s=>s.session_id===id&&s.bot_id===botId);if(!row)throw Error('This session closed or is no longer linked to this bot.');return row;}
  };
  document.addEventListener('page-selected',()=>refresh().catch(()=>{}));
  setInterval(()=>{if(document.querySelector('#bot-surface:not([hidden]),.development-screen:not([hidden])'))refresh().catch(()=>{});},2000);
  refresh().catch(()=>{});return client;
}
export function initLinkedSessions({parent,invoke}){
  const links=sessionLinks(invoke),panel=node('section',undefined,'bot-linked-sessions');panel.id='bot-linked-sessions';parent.append(panel);
  let botId='',signature='';
  function paint(){const rows=links.rows.filter(s=>s.bot_id===botId),next=JSON.stringify([botId,rows,links.error]);if(next===signature)return;signature=next;panel.replaceChildren(node('h2','Linked workbench sessions'),node('p','Shared by you · Linking keeps a session handy for this bot. It does not send its contents or give the bot control.','directory-note'));
    if(links.error){panel.append(node('p','Session inventory unavailable. '+links.error,'availability-note'));return;}
    if(!rows.length){panel.append(node('p','Open Terminal or Browser, choose this bot, then select Link to bot.','directory-note'));return;}
    for(const row of rows){const item=node('div',undefined,'linked-session-row');item.dataset.sessionId=row.session_id;const text=node('div');text.append(node('strong',row.kind==='browser'?'Browser tab':row.title),node('p',(row.root||row.title)+' · '+row.state,'directory-note'));const open=node('button','Open '+(row.kind==='browser'?'Browser':'Terminal'));open.type='button';open.dataset.openLinkedSession=row.session_id;const unlink=node('button','Unlink','subtle');unlink.type='button';unlink.dataset.unlinkSession=row.session_id;item.append(text,open,unlink);panel.append(item);}
  }
  const message=node('p','','availability-note');message.setAttribute('role','status');parent.append(message);message.hidden=true;
  panel.onclick=async e=>{const open=e.target.closest('[data-open-linked-session]'),unlink=e.target.closest('[data-unlink-session]');try{if(open){const row=await links.resolve(open.dataset.openLinkedSession,botId);document.dispatchEvent(new CustomEvent('open-linked-session',{detail:{id:row.session_id,botId}}));}else if(unlink)await links.unlink(unlink.dataset.unlinkSession);message.hidden=true;}catch(error){message.hidden=false;message.textContent=String(error);}};
  document.addEventListener('surface-sessions-changed',paint);
  return {setBot(id){botId=id;paint();}};
}
