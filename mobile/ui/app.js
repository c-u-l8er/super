import {initConversations} from '/conversations.js';
import {taskProgress} from '/task-progress.js';
const $=s=>document.querySelector(s), content=$('#content'), notice=$('#notice');
let current=null,view='attention',selected=null,busy=false,paired=false,lastSuccess=0,serial=0,lastWorld=null;
const node=(tag,text,cls)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(cls)e.className=cls;return e;};
const button=(label,fn,cls)=>{const e=node('button',label,cls);e.onclick=fn;return e;};
const rows=p=>Object.values(p?.development_tasks??{});
const attentionStates=new Set(['blocked','needs_changes','checks_missing','checks_attention','decision','finish']);
const api=async(path,body)=>{const r=await fetch('/api/'+path,{method:body?'POST':'GET',headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined,cache:'no-store',signal:AbortSignal.timeout(4000)});const v=await r.json();if(!r.ok){const e=Error(v.error);e.status=r.status;throw e;}return v;};
function withdraw(message){current=null;$('#status').textContent=message;render();}
initConversations(document.querySelector('#conversations'),()=>view==='chat'&&paired);
function render(){
  document.body.classList.toggle('chat-mode',view==='chat');
  document.querySelectorAll('[data-view]').forEach(b=>b.setAttribute('aria-current',b.dataset.view===view?'page':'false'));content.hidden=view==='chat';$('#conversations').hidden=view!=='chat';if(view==='chat')return;
  content.replaceChildren();document.querySelectorAll('[data-view]').forEach(b=>b.setAttribute('aria-current',b.dataset.view===view?'page':'false'));
  if(!current?.available){content.append(node('h1','Host unavailable'),node('p','Reconnect to see current tasks. No saved state is being shown as live.','empty'));return;}
  const p=current.projection,all=rows(p),open=all.filter(t=>!['cancelled','completed'].includes(t.status));
  if(selected){const task=p.development_tasks?.[selected];if(!task){selected=null;render();return;}
    content.append(button('← Back',()=>{selected=null;render();},'back'),node('span',task.status,'badge'),node('h1',task.title),node('p',`${task.id} · Revision ${task.revision}`,'meta'),node('p',task.criteria));
    const shots=node('section',undefined,'card');shots.append(node('h2','Before and after'),node('p','Attached screenshots for this task revision.','muted'));
    const load=button('View screenshots and logs',async()=>{load.disabled=true;try{const response=await api('screenshots?task='+encodeURIComponent(task.id));if(!shots.isConnected)return;if(!response.available||response.record.revision!==task.revision||JSON.stringify(response.record.world)!==JSON.stringify([current?.world?.world_incarnation,current?.world?.world_generation]))throw Error('Task observation changed. Refresh and reopen its screenshots.');load.remove();for(const side of ['before','after']){const figure=node('figure'),label=side==='before'?'Before':'After';figure.append(node('figcaption',label));const image=response.record.images?.[side];if(image){const img=node('img');img.src=image.data;img.alt=label+' screenshot for '+task.title+', revision '+task.revision;const expand=button('Open '+label.toLowerCase()+' image',()=>{const dialog=node('dialog'),full=node('img'),close=button('Close image',()=>dialog.close());dialog.className='evidence-image-viewer';full.src=image.data;full.alt=img.alt;dialog.append(close,full);dialog.addEventListener('close',()=>{dialog.remove();if(expand.isConnected)expand.focus();});shots.append(dialog);dialog.showModal();});figure.append(img,expand);if(image.capture?.kind==='android-emulator'){const c=image.capture;figure.append(node('p',`Android emulator · Android ${c.android} · ${image.width} × ${image.height}`,'muted'));const details=node('details');details.append(node('summary','Capture details'),node('p',`${c.model} · ${c.serial} · Full display · ${c.activity} · app source version unverified`,'muted'));figure.append(details);}else if(image.capture?.kind==='local-preview')figure.append(node('p','Local preview · '+image.capture.url+' · app source version unverified','muted'));}else figure.append(node('p','No screenshot attached.','muted'));shots.append(figure);}for(const side of ['before','after']){const log=response.record.outputs?.[side];if(log){const box=node('section');box.append(node('h3',side==='before'?'Before log':'After log'),node('p','Imported log · origin unverified','muted'),node('p',log.command),node('p',log.source+' · '+log.environment,'muted'),node('pre',log.text));shots.append(box);}}appendRunComparison(shots,response.record.comparison);appendVisualReview(shots,response.record,task);}catch(e){if(shots.isConnected){load.disabled=false;load.textContent='Retry screenshots';shots.append(node('p',e.message,'muted'));}}});shots.append(load);content.append(shots);
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
    for(const t of show){const progress=taskProgress(p,t),card=node('article',undefined,'card');card.append(node('span',progress.state.replaceAll('_',' '),'badge'),button(t.title,()=>{selected=t.id;render();},'open'),node('p',progress.label),node('p',`${t.id} · ${p.bots?.[t.bot_ref]?.name??'Assigned bot'} · Revision ${t.revision}`,'meta'));content.append(card);}
  }else if(view==='bots'){
    content.append(node('h1','Your bots.'),node('p','Registered identities on this Super host. Registration does not mean a process is running.','muted'));
    const bots=Object.values(p.bots??{});if(!bots.length)content.append(node('p','No bots registered.','empty'));
    for(const b of bots){const card=node('article',undefined,'card');card.append(node('h2',b.name),node('p',`${b.id} · ${b.actor}`,'meta'),node('p',`${open.filter(t=>t.bot_ref===b.id).length} open plans`));content.append(card);}
  }else{
    content.append(node('h1','Connected stack.'),node('p','One Super host · Observation access','muted'));
    const card=node('section',undefined,'card');card.append(node('h2','Host inventory'));const dl=node('dl');for(const [name,label]of [['workspaces','Workspaces'],['goals','Goals'],['lanes','Lanes'],['workers','Worker records']])dl.append(node('dt',label),node('dd',String(Object.keys(p[name]??{}).length)));card.append(dl,node('p','Worker records do not certify process liveness.','muted'));content.append(card);
    content.append(node('p','Closing this page does not stop the host. This alpha needs desktop Super to remain open.','muted'),button('Disconnect this device',async()=>{serial++;try{await api('logout',{});paired=false;current=null;selected=null;lastWorld=null;content.replaceChildren();$('#app').hidden=true;$('#pair').hidden=false;notice.textContent='Device disconnected. In desktop Super, open Mobile device and choose New pairing code to connect again.';}catch{withdraw('Disconnect not confirmed');notice.textContent='Could not confirm disconnection. Restore the connection and try again, or restart the desktop observer to end all device sessions.';}}));
  }
}
async function refresh(){if(busy)return;busy=true;const request=serial;try{const next=await api('snapshot');if(request!==serial||document.hidden)return;paired=true;$('#pair').hidden=true;$('#app').hidden=false;const identity=w=>JSON.stringify([w?.world_incarnation,w?.world_generation,w?.projection_epoch]);const nextWorld=next.available?identity(next.world):null;const changed=lastWorld&&nextWorld&&lastWorld!==nextWorld;if(nextWorld)lastWorld=nextWorld;const redraw=JSON.stringify(current)!==JSON.stringify(next);current=next;lastSuccess=Date.now();$('#status').textContent=next.available?'● Connected':'Host reconnecting';if(next.available)notice.textContent='';if(changed)selected=null;if(redraw)render();}catch(e){if(request!==serial)return;if(e.status===401){if(paired)notice.textContent='This session ended. Ask desktop Super for a new pairing code.';paired=false;$('#app').hidden=true;$('#pair').hidden=false;current=null;selected=null;lastWorld=null;content.replaceChildren();}else{withdraw('Disconnected');if(paired)notice.textContent='The connection was interrupted. We’ll retry while this page is open.';}}finally{busy=false;}}
$('#pair-form').onsubmit=async e=>{e.preventDefault();serial++;try{await api('pair',{code:$('#code').value.replace(/\s/g,'')});$('#code').value='';notice.textContent='';paired=true;await refresh();}catch(e){notice.textContent=e.message;}};
$('#refresh').onclick=()=>{notice.textContent='';refresh();};
document.querySelectorAll('[data-view]').forEach(b=>b.onclick=()=>{view=b.dataset.view;selected=null;render();});
document.addEventListener('visibilitychange',()=>{serial++;if(document.hidden){withdraw('Paused while away');}else refresh();});
setInterval(()=>{if(current&&Date.now()-lastSuccess>6000)withdraw('Connection expired');if(paired&&!document.hidden)refresh();},2000);
refresh();

function appendVisualReview(container,record,task){
 const review=record.review;if(!review?.findings?.requirements)return;
 const e=review.basis?.evidence,a=e?current?.projection?.development_attempts?.[e.attempt]:null;
 const stale=review.basis.criteria!==task.criteria||['before','after'].some(side=>review.basis[side]!==record.images?.[side]?.sha256)||(e&&(a?.revision!==e.attempt_revision||visualRunIdentity(a.test_runs)!==e.test_runs_identity));
 container.append(node('h3',stale?'Previous visual review — evidence changed':'Visual review'),node('p',review.findings.summary),node('p','AI findings · '+review.provider+' · '+(review.model||'configured model'),'muted'));
 for(const row of review.findings.requirements){container.append(node('h4',row.requirement),node('p',({met:'Visually met',missing:'Missing',uncertain:'Needs verification'})[row.status]+': '+row.reason));}
 if(review.findings.regressions.length){container.append(node('h4','Possible regressions'));for(const text of review.findings.regressions)container.append(node('p',text));}
 container.append(node('p',stale?'Open the desktop and run a new review.':review.inspected_at?'Marked inspected on desktop. This does not accept the task.':'Inspect these findings on the desktop before accepting the tested result.','muted'),node('p',e?'Linked evidence: '+e.label+'. Image capture origin is unverified.':'Image-only review. No tested build linked.','muted'));
}

function visualRunIdentity(runs){return JSON.stringify(Object.values(runs||{}).map(r=>({id:r.run_id,profile:r.profile,state:r.state,verdict:r.outcome?.verdict,snapshot:r.outcome?.snapshot_sha256,result:r.outcome?.result_sha256})).sort((a,b)=>String(a.id).localeCompare(String(b.id))));}

function appendRunComparison(container,comparison){
 if(!comparison)return;const panel=node('section');panel.append(node('h3','Recorded baseline comparison'),node('p',comparison.profile+' · '+comparison.run_id,'muted'));
 for(const side of ['before','after']){const r=comparison[side];panel.append(node('h3',(side==='before'?'Before proposal':'After proposal')+' · '+(r.verdict||r.state)),node('p','Source: '+r.snapshot,'muted'),node('pre',r.output||'No output recorded.'));if(r.truncated)panel.append(node('p','Output shortened. Full log stays on the desktop.','muted'));}
 const b=comparison.benchmark;if(b){panel.append(node('h3','Benchmark · '+b.state));if(b.reason)panel.append(node('p',b.reason));for(const m of b.metrics||[])panel.append(node('p',`${m.name}: ${m.before.median} → ${m.after.median} ${m.unit} (${m.direction} is better)`));}container.append(panel);
}
