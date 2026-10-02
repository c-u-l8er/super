import {initConversations} from '/conversations.js';
import {taskProgress} from '/task-progress.js';
import {withheldAttemptsNote} from '/archived-record.js';
import {referenceText,setReferenceFrame,setReferenceRouting} from './references.js';
const $=s=>document.querySelector(s), content=$('#content'), notice=$('#notice');
let current=null,view='attention',selected=null,busy=false,paired=false,lastSuccess=0,serial=0,lastWorld=null;
/* T31 · where the person is: the view, the open plan and the Tasks filter. It
 * lives in the URL's hash and in history, so Safari's back swipe returns from a
 * plan to its list and a reload or pull-to-refresh comes back to the same place
 * (F3). `shown` is the place last drawn: a redraw of the same place keeps the
 * scroll, a new place starts at the top or where history left it (F2). */
let show='open',botFilter=null,shown=null,restore=null,asking=false;
const VIEWS=['attention','tasks','chat','bots','stack'],SHOWS=['open','done','all'];
const place=()=>({view,plan:selected,show,bot:botFilter});
const placeHash=s=>{const q=[s.show!=='open'?'show='+s.show:'',s.bot?'bot='+s.bot:''].filter(Boolean).join('&');return '#/'+s.view+(s.plan?'/'+s.plan:'')+(q?'?'+q:'');};
function parsePlace(hash){
  const s={view:'attention',plan:null,show:'open',bot:null},m=/^#\/([a-z]+)(?:\/(dt_\d{1,9}))?(?:\?([\w=&]*))?$/.exec(String(hash??''));
  if(!m||!VIEWS.includes(m[1]))return s;s.view=m[1];if(m[2]&&(s.view==='attention'||s.view==='tasks'))s.plan=m[2];
  for(const part of (m[3]??'').split('&')){const [k,v]=part.split('=');if(k==='show'&&SHOWS.includes(v))s.show=v;if(k==='bot'&&/^bt_\d{1,9}$/.test(v))s.bot=v;}
  return s;
}
const adopt=s=>{({view,plan:selected,show,bot:botFilter}=s);asking=false;};
// A correction (the plan vanished, the world was replaced, the session ended) rewrites the entry; it is not a step.
const settle=()=>{try{history.replaceState(history.state,'',placeHash(place()));}catch{}};
function go(next,{replace=false}={}){
  const from=place(),to={...from,...next},hash=placeHash(to);
  if(!replace&&hash===placeHash(from)){window.scrollTo(0,0);return;}
  try{
    if(replace)history.replaceState({...history.state,back:!!history.state?.back&&!!to.plan},'',hash);
    else{history.replaceState({...history.state,scroll:window.scrollY},'',placeHash(from));history.pushState({back:!from.plan&&!!to.plan},'',hash);}
  }catch{}
  adopt(to);render();
}
// iOS turns a typed "--" into a dash of its own; every dash and every space is separation, never code (R126).
const pairingCode=raw=>String(raw??'').replace(/[\s\p{Pd}]/gu,'').toLowerCase();
/* The same reference rule as the desktop (cockpit/ui/references.js): a record
 * id in any text is a reference. The phone shows the id and puts the name in
 * the tooltip; it can open a plan (or an attempt's plan), so only those two
 * kinds render as links — the rest are tooltip spans. */
const PLAIN_TEXT_TAGS=new Set(['pre','code','textarea','input','select','option']);
setReferenceRouting(kind=>kind==='Development plan'||kind==='Review attempt');
const node=(tag,text,cls)=>{const e=document.createElement(tag);if(cls)e.className=cls;if(text!==undefined){if(PLAIN_TEXT_TAGS.has(tag))e.textContent=text;else referenceText(e,text,undefined,{display:'id'});}return e;};
content.addEventListener('click',e=>{const a=e.target.closest('a[data-record-ref]');if(!a)return;e.preventDefault();const p=current?.projection,id=a.dataset.recordRef;const task=p?.development_tasks?.[id]??p?.development_tasks?.[p?.development_attempts?.[id]?.task_ref];if(!task)return;go({view:'tasks',plan:task.id});});
const button=(label,fn,cls)=>{const e=node('button',label,cls);e.onclick=fn;return e;};
const rows=p=>Object.values(p?.development_tasks??{});
const attentionStates=new Set(['blocked','needs_changes','checks_missing','checks_attention','decision','finish']);
/* T31 F5: attention first, then open, then done; the newest plan first inside each. */
const phase=state=>attentionStates.has(state)?0:state==='completed'||state==='cancelled'?2:1;
const idNumber=t=>Number(/\d+$/.exec(String(t.id))?.[0]??0);
const ordered=(p,list)=>list.map(t=>({t,progress:taskProgress(p,t)})).sort((a,b)=>phase(a.progress.state)-phase(b.progress.state)||idNumber(b.t)-idNumber(a.t));
const TONES={blocked:'alert',needs_changes:'alert',checks_attention:'alert',checks_missing:'attention',decision:'attention',finish:'attention',completed:'done',accepted:'done',cancelled:'closed',dismissed:'closed'};
const badge=state=>{const e=node('span',String(state).replaceAll('_',' '),'badge');e.dataset.tone=TONES[state]??'open';return e;};
const PROVIDERS={claude:'Claude',codex:'Codex',ollama:'Ollama',openai:'OpenAI',anthropic:'Anthropic'};
const api=async(path,body)=>{const r=await fetch('/api/'+path,{method:body?'POST':'GET',headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined,cache:'no-store',signal:AbortSignal.timeout(4000)});const v=await r.json();if(!r.ok){const e=Error(v.error);e.status=r.status;throw e;}return v;};
function withdraw(message){current=null;setReferenceFrame(null);$('#status').textContent=message;render();}
const linkedTask=link=>current?.available&&JSON.stringify([current.world?.world_incarnation,current.world?.world_generation])===link.lineage&&current.projection?.development_tasks?.[link.taskId]?.revision===link.revision?current.projection.development_tasks[link.taskId]:null;
const chat=initConversations(document.querySelector('#conversations'),()=>view==='chat'&&paired,{taskInfo:linkedTask,onTask:link=>{if(!linkedTask(link))return;go({view:'tasks',plan:link.taskId});}});
function render(){
  draw();
  const key=placeHash(place());if(key!==shown){shown=key;if(view!=='chat')window.scrollTo(0,restore??0);}restore=null;
}
function draw(){
  document.body.classList.toggle('chat-mode',view==='chat');
  document.querySelectorAll('[data-view]').forEach(b=>b.setAttribute('aria-current',b.dataset.view===view?'page':'false'));content.hidden=view==='chat';$('#conversations').hidden=view!=='chat';if(view==='chat')return;
  content.replaceChildren();document.querySelectorAll('[data-view]').forEach(b=>b.setAttribute('aria-current',b.dataset.view===view?'page':'false'));
  if(!current?.available){content.append(node('h1','Host unavailable'),node('p','Reconnect to see current tasks. No saved state is being shown as live.','empty'));return;}
  const p=current.projection,all=rows(p),open=all.filter(t=>!['cancelled','completed'].includes(t.status));
  if(selected){const task=p.development_tasks?.[selected];if(!task){selected=null;settle();render();return;}
    // Back is a step back in history when this page opened the plan from a list; otherwise it rewrites the entry.
    const head=node('div',undefined,'detail-head');head.append(button('← Back',()=>{if(history.state?.back)history.back();else go({plan:null},{replace:true});},'back'),badge(taskProgress(p,task).state));
    content.append(head,node('h1',task.title),node('p',`${task.id} · Revision ${task.revision}`,'meta'),node('p',task.criteria,'criteria'));
    content.append(button('Discuss task',()=>{const link={taskId:task.id,revision:task.revision,lineage:JSON.stringify([current?.world?.world_incarnation,current?.world?.world_generation])};if(!linkedTask(link))return;chat.discuss({...link,title:task.title});go({view:'chat',plan:null});}));
    const shots=node('section',undefined,'card');shots.append(node('h2','Before and after'),node('p','Attached screenshots for this task revision.','muted'));
    const load=button('View screenshots and logs',async()=>{load.disabled=true;try{const response=await api('screenshots?task='+encodeURIComponent(task.id));if(!shots.isConnected)return;if(!response.available||response.record.revision!==task.revision||JSON.stringify(response.record.world)!==JSON.stringify([current?.world?.world_incarnation,current?.world?.world_generation]))throw Error('Task observation changed. Refresh and reopen its screenshots.');load.remove();for(const side of ['before','after']){const figure=node('figure'),label=side==='before'?'Before':'After';figure.append(node('figcaption',label));const image=response.record.images?.[side];if(image){const img=node('img');img.src=image.data;img.alt=label+' screenshot for '+task.title+', revision '+task.revision;const expand=button('Open '+label.toLowerCase()+' image',()=>{const dialog=node('dialog'),full=node('img'),close=button('Close image',()=>dialog.close());dialog.className='evidence-image-viewer';full.src=image.data;full.alt=img.alt;dialog.append(close,full);dialog.addEventListener('close',()=>{dialog.remove();if(expand.isConnected)expand.focus();});shots.append(dialog);dialog.showModal();});figure.append(img,expand);if(image.capture?.kind==='android-emulator'){const c=image.capture;figure.append(node('p',`Android emulator · Android ${c.android} · ${image.width} × ${image.height}`,'muted'));const details=node('details');details.append(node('summary','Capture details'),node('p',`${c.model} · ${c.serial} · Full display · ${c.activity} · app source version unverified`,'muted'));figure.append(details);}else if(image.capture?.kind==='local-preview')figure.append(node('p','Local preview · '+image.capture.url+' · app source version unverified','muted'));}else figure.append(node('p','No screenshot attached.','muted'));shots.append(figure);}for(const side of ['before','after']){const log=response.record.outputs?.[side];if(log){const box=node('section');box.append(node('h3',side==='before'?'Before log':'After log'),node('p','Imported log · origin unverified','muted'),node('p',log.command),node('p',log.source+' · '+log.environment,'muted'),node('pre',log.text));shots.append(box);}}appendRunComparison(shots,response.record.comparison);appendVisualReview(shots,response.record,task);}catch(e){if(shots.isConnected){load.disabled=false;load.textContent='Retry screenshots';shots.append(node('p',e.message,'muted'));}}});shots.append(load);content.append(shots);
    const progress=taskProgress(p,task),next=node('section',undefined,'card');next.append(node('h2','Next action'),node('p',progress.label),node('p',progress.reason,'muted'));content.append(next);
    content.append(node('h2','Review evidence'),node('p','Inspect retained results here. File checks, decisions and execution remain in desktop Super.','muted'));
    const attempts=Object.values(p.development_attempts??{}).filter(a=>a.task_ref===task.id);
    // T23: a finished plan outside the frame's window has attempts the frame does not carry.
    const kept=withheldAttemptsNote(task);
    if(kept)content.append(node('p',kept,'muted'));else if(!attempts.length)content.append(node('p','No review has been recorded for this plan.','empty'));
    for(const a of attempts){const card=node('article',undefined,'card');card.append(badge(a.status),node('h2',a.title||'Retained review'),node('p',`Plan revision ${a.task_revision}${a.task_revision!==task.revision?' · Earlier revision':''}`,'meta'));
      for(const r of Object.values(a.test_runs??{}))card.append(node('p',`${r.profile??'Check'} · ${r.state} · ${r.outcome?.verdict??'No final verdict'}`,'meta'));
      if(a.acceptance)card.append(node('p','An acceptance is retained. This does not confirm that files still match on disk.','muted'));
      const details=node('details');details.append(node('summary','Inspect retained review record'),node('pre',JSON.stringify(a,null,2)));card.append(details);content.append(card);}
    const planHistory=node('details');planHistory.append(node('summary','Plan history'),node('pre',JSON.stringify(task.history,null,2)));content.append(planHistory);return;
  }
  if(view==='attention'||view==='tasks'){
    const needs=ordered(p,open).filter(r=>attentionStates.has(r.progress.state));
    content.append(node('p','SUPER / YOUR WORK','eyebrow'),node('h1',view==='attention'?'Needs your attention.':'Development tasks.'));
    const mine=ordered(p,all).filter(r=>!botFilter||r.t.bot_ref===botFilter),fits=r=>show==='all'||(show==='done')===(phase(r.progress.state)===2);
    const list=view==='attention'?needs:mine.filter(fits);
    if(view==='tasks'){
      const bar=node('div',undefined,'filters');
      for(const [value,label] of [['open','Open'],['done','Done'],['all','All']]){const n=mine.filter(r=>value==='all'||(value==='done')===(phase(r.progress.state)===2)).length,chip=button(`${label} · ${n}`,()=>go({show:value},{replace:true}));chip.setAttribute('aria-pressed',String(show===value));bar.append(chip);}
      if(botFilter){const chip=button(`Bot · ${p.bots?.[botFilter]?.name??botFilter} ✕`,()=>go({bot:null},{replace:true}),'chip');chip.setAttribute('aria-label','Show the plans of every bot');bar.append(chip);}
      content.append(bar);
    }
    const summary=node('div',undefined,'summary');summary.append(node('span',String(list.length),'count'),node('p',view==='attention'?`${needs.length===1?'plan needs':'plans need'} a decision or follow-up\n${open.length} open ${open.length===1?'plan':'plans'} in this host`:{open:'open plans',done:'finished plans',all:'retained plans in this host'}[show]));content.append(summary);
    if(!list.length)content.append(node('p',view==='attention'?'No decisions or follow-ups in the current task records.':all.length?'No plans match this filter.':'No development plans yet. Create one in desktop Super.','empty'));
    for(const {t,progress} of list){const card=node('article',undefined,'card');card.append(badge(progress.state),button(t.title,()=>go({plan:t.id}),'open'),node('p',progress.label),node('p',`${t.id} · ${p.bots?.[t.bot_ref]?.name??'Assigned bot'} · Revision ${t.revision}`,'meta'));content.append(card);}
  }else if(view==='bots'){
    content.append(node('h1','Your bots.'),node('p','Registered identities on this Super host. Registration does not mean a process is running. Tap a bot to see its plans.','muted'));
    const bots=Object.values(p.bots??{});if(!bots.length)content.append(node('p','No bots registered.','empty'));
    // The actor (`bot_` and 32 hex) is an opaque runtime identity, not something a person reads (F10).
    for(const b of bots){const card=node('article',undefined,'card'),live=open.filter(t=>t.bot_ref===b.id).length,total=all.filter(t=>t.bot_ref===b.id).length;card.append(button(b.name,()=>go({view:'tasks',plan:null,bot:b.id}),'open'),node('p',[b.id,PROVIDERS[b.provider]??b.provider].filter(Boolean).join(' · '),'meta'),node('p',`${live} open ${live===1?'plan':'plans'} · ${total} in all`));content.append(card);}
  }else{
    content.append(node('h1','Connected stack.'),node('p','One Super host · Tasks, review evidence and chat','muted'));
    const can=node('section',undefined,'card');can.append(node('h2','What this phone can do'));
    for(const line of ['Read plans, review evidence and screenshots.','Chat with your bots: open, start, rename and pin conversations, save drafts and send messages. A message you send runs on desktop Super, with its provider.','Opening a conversation here also opens it on the desktop.','Decisions, file changes, checks and acceptance stay on the desktop.'])can.append(node('p',line));
    content.append(can);
    const card=node('section',undefined,'card');card.append(node('h2','Host inventory'));const dl=node('dl');for(const [name,label]of [['workspaces','Workspaces'],['goals','Goals'],['lanes','Lanes'],['workers','Worker records']])dl.append(node('dt',label),node('dd',String(Object.keys(p[name]??{}).length)));card.append(dl,node('p','Worker records do not certify process liveness.','muted'));content.append(card);
    content.append(node('p','Closing this page does not stop the host. This alpha needs desktop Super to remain open.','muted'));
    // F9: one tap asks; only Disconnect ends the session. The question outlives the 2 s redraw.
    // N3: it opens at the foot of the page, so it is brought into view once, as it opens (never on a redraw);
    // style.css's scroll margins keep its buttons clear of the tab bar and the status bar.
    if(!asking)content.append(button('Disconnect this device',()=>{asking=true;render();content.querySelector('.confirm')?.scrollIntoView({block:'nearest'});},'danger'));
    else{const ask=node('section',undefined,'card confirm');ask.append(node('h2','Disconnect this phone?'),node('p','To connect again you will need a new pairing code from desktop Super.','muted'),button('Disconnect',disconnect,'danger'),button('Cancel',()=>{asking=false;render();}));content.append(ask);}
  }
}
async function disconnect(){serial++;try{await api('logout',{});asking=false;paired=false;current=null;selected=null;lastWorld=null;content.replaceChildren();$('#app').hidden=true;$('#pair').hidden=false;notice.textContent='Device disconnected. In desktop Super, open Mobile device and choose New pairing code to connect again.';}catch{asking=false;withdraw('Disconnect not confirmed');notice.textContent='Could not confirm disconnection. Restore the connection and try again, or restart the desktop observer to end all device sessions.';}}
async function refresh(){if(busy)return;busy=true;const request=serial;try{const next=await api('snapshot');if(request!==serial||document.hidden)return;paired=true;$('#pair').hidden=true;$('#app').hidden=false;const identity=w=>JSON.stringify([w?.world_incarnation,w?.world_generation,w?.projection_epoch]);const nextWorld=next.available?identity(next.world):null;const changed=lastWorld&&nextWorld&&lastWorld!==nextWorld;if(nextWorld)lastWorld=nextWorld;const redraw=JSON.stringify(current)!==JSON.stringify(next);current=next;setReferenceFrame(next.available?next:null);lastSuccess=Date.now();$('#status').textContent=next.available?'● Connected':'Host reconnecting';if(next.available)notice.textContent='';if(changed&&selected){selected=null;settle();}if(redraw)render();}catch(e){if(request!==serial)return;if(e.status===401){if(paired)notice.textContent='This session ended. Ask desktop Super for a new pairing code.';paired=false;$('#app').hidden=true;$('#pair').hidden=false;current=null;selected=null;settle();lastWorld=null;content.replaceChildren();}else{withdraw('Disconnected');if(paired)notice.textContent='The connection was interrupted. We’ll retry while this page is open.';}}finally{busy=false;}}
/* T31 N1: one pair request at a time. Return and then a tap on Connect sent two, and the browser's "Fetch is aborted"
 * reached the notice. Connect is disabled while one is in flight; a failure with no answer from the gateway (aborted,
 * timed out, offline) is said plainly, and the gateway's own refusals are shown as it words them. */
let pairing=false;
$('#pair-form').onsubmit=async e=>{e.preventDefault();if(pairing)return;pairing=true;const connect=$('#pair-form button');connect.disabled=true;serial++;try{await api('pair',{code:pairingCode($('#code').value)});$('#code').value='';notice.textContent='';paired=true;await refresh();}catch(e){notice.textContent=e.status?e.message:'Could not reach desktop Super. Check the connection, then connect again.';}finally{pairing=false;connect.disabled=false;}};
$('#refresh').onclick=()=>{notice.textContent='';refresh();};
document.querySelectorAll('[data-view]').forEach(b=>b.onclick=()=>go({view:b.dataset.view,plan:null,bot:null}));
window.addEventListener('popstate',e=>{adopt(parsePlace(location.hash));restore=e.state?.scroll??0;render();});
try{history.scrollRestoration='manual';}catch{}
adopt(parsePlace(location.hash));try{history.replaceState(history.state??{},'',placeHash(place()));}catch{}
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
