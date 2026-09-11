import {taskProgress} from '/task-progress.js';
const $=s=>document.querySelector(s), content=$('#content'), notice=$('#notice');
let current=null,view='attention',selected=null,busy=false,paired=false,lastSuccess=0,serial=0;
const node=(tag,text,cls)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(cls)e.className=cls;return e;};
const button=(label,fn,cls)=>{const e=node('button',label,cls);e.onclick=fn;return e;};
const rows=p=>Object.values(p?.development_tasks??{});
const attentionStates=new Set(['blocked','needs_changes','checks_missing','checks_attention','decision','finish']);
const api=async(path,body)=>{const r=await fetch('/api/'+path,{method:body?'POST':'GET',headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined,cache:'no-store',signal:AbortSignal.timeout(4000)});const v=await r.json();if(!r.ok){const e=Error(v.error);e.status=r.status;throw e;}return v;};
function withdraw(message){current=null;selected=null;$('#status').textContent=message;render();}
function render(){
  content.replaceChildren();document.querySelectorAll('[data-view]').forEach(b=>b.setAttribute('aria-current',b.dataset.view===view?'page':'false'));
  if(!current?.available){content.append(node('h1','Host unavailable'),node('p','Reconnect to see current tasks. No saved state is being shown as live.','empty'));return;}
  const p=current.projection,all=rows(p),open=all.filter(t=>!['cancelled','completed'].includes(t.status));
  if(selected){const task=p.development_tasks?.[selected];if(!task){selected=null;render();return;}
    content.append(button('← Back',()=>{selected=null;render();},'back'),node('span',task.status,'badge'),node('h1',task.title),node('p',task.criteria));
    const progress=taskProgress(p,task),next=node('section',undefined,'card');next.append(node('h2','Next action'),node('p',progress.label),node('p',progress.reason,'muted'));content.append(next);
    content.append(node('h2','Review evidence'),node('p','Inspect retained results here. File checks, decisions and execution remain in desktop Super.','muted'));
    const attempts=Object.values(p.development_attempts??{}).filter(a=>a.task_ref===task.id);
    if(!attempts.length)content.append(node('p','No review has been recorded for this plan.','empty'));
    for(const a of attempts){const card=node('article',undefined,'card');card.append(node('span',a.status,'badge'),node('h2',a.title||'Retained review'),node('p',`Plan revision ${a.task_revision}${a.task_revision!==task.revision?' · Earlier revision':''}`,'meta'));
      for(const r of Object.values(a.test_runs??{}))card.append(node('p',`${r.profile??'Check'} · ${r.state} · ${r.outcome?.verdict??'No final verdict'}`,'meta'));
      if(a.acceptance)card.append(node('p','An acceptance is retained. This does not confirm that files still match on disk.','muted'));
      const details=node('details');details.append(node('summary','Inspect retained review record'),node('pre',JSON.stringify(a,null,2)));card.append(details);content.append(card);}
    const history=node('details');history.append(node('summary','Plan history'),node('pre',JSON.stringify(task.history,null,2)));content.append(history);return;
  }
  if(view==='attention'||view==='tasks'){
    const needs=open.filter(t=>attentionStates.has(taskProgress(p,t).state));
    content.append(node('p','SUPER / YOUR WORK','eyebrow'),node('h1',view==='attention'?'Needs your attention.':'Development tasks.'));
    const summary=node('div',undefined,'summary');summary.append(node('span',String(view==='attention'?needs.length:all.length),'count'),node('p',view==='attention'?`${needs.length===1?'plan needs':'plans need'} a decision or follow-up\n${open.length} open ${open.length===1?'plan':'plans'} in this host`:'retained plans in this host'));content.append(summary);
    const show=view==='attention'?needs:all;
    if(!show.length)content.append(node('p',view==='attention'?'No decisions or follow-ups in the current task records.':'No development plans yet. Create one in desktop Super.','empty'));
    for(const t of show){const progress=taskProgress(p,t),card=node('article',undefined,'card');card.append(node('span',progress.state.replaceAll('_',' '),'badge'),button(t.title,()=>{selected=t.id;render();},'open'),node('p',progress.label),node('p',`${p.bots?.[t.bot_ref]?.name??'Assigned bot'} · Revision ${t.revision}`,'meta'));content.append(card);}
  }else if(view==='bots'){
    content.append(node('h1','Your bots.'),node('p','Registered identities on this Super host. Registration does not mean a process is running.','muted'));
    const bots=Object.values(p.bots??{});if(!bots.length)content.append(node('p','No bots registered.','empty'));
    for(const b of bots){const card=node('article',undefined,'card');card.append(node('h2',b.name),node('p',b.actor,'meta'),node('p',`${open.filter(t=>t.bot_ref===b.id).length} open plans`));content.append(card);}
  }else{
    content.append(node('h1','Connected stack.'),node('p','One Super host · Observation access','muted'));
    const card=node('section',undefined,'card');card.append(node('h2','Host inventory'));const dl=node('dl');for(const [name,label]of [['workspaces','Workspaces'],['goals','Goals'],['lanes','Lanes'],['workers','Worker records']])dl.append(node('dt',label),node('dd',String(Object.keys(p[name]??{}).length)));card.append(dl,node('p','Worker records do not certify process liveness.','muted'));content.append(card);
    content.append(node('p','Closing this page does not stop the host. This alpha needs desktop Super to remain open.','muted'),button('Disconnect this device',async()=>{serial++;await api('logout',{});paired=false;current=null;$('#app').hidden=true;$('#pair').hidden=false;notice.textContent='Device disconnected. Restart the host observer to pair again.';}));
  }
}
async function refresh(){if(busy)return;busy=true;const request=serial;try{const next=await api('snapshot');if(request!==serial||document.hidden)return;paired=true;$('#pair').hidden=true;$('#app').hidden=false;const identity=w=>JSON.stringify([w?.world_incarnation,w?.world_generation,w?.projection_epoch]);const changed=current&&identity(current.world)!==identity(next.world);const redraw=JSON.stringify(current)!==JSON.stringify(next);current=next;lastSuccess=Date.now();$('#status').textContent=next.available?'● Connected · Read-only':'Host reconnecting';if(changed)selected=null;if(redraw)render();}catch(e){if(request!==serial)return;if(e.status===401){paired=false;$('#app').hidden=true;$('#pair').hidden=false;current=null;}else{withdraw('Disconnected');if(paired)notice.textContent='The connection was interrupted. We’ll retry while this page is open.';}}finally{busy=false;}}
$('#pair-form').onsubmit=async e=>{e.preventDefault();try{await api('pair',{code:$('#code').value.trim()});$('#code').value='';notice.textContent='';await refresh();}catch(e){notice.textContent=e.message;}};
$('#refresh').onclick=()=>{notice.textContent='';refresh();};
document.querySelectorAll('[data-view]').forEach(b=>b.onclick=()=>{view=b.dataset.view;selected=null;render();});
document.addEventListener('visibilitychange',()=>{serial++;if(document.hidden){withdraw('Paused while away');}else refresh();});
setInterval(()=>{if(current&&Date.now()-lastSuccess>6000)withdraw('Connection expired');if(paired&&!document.hidden)refresh();},2000);
refresh();
