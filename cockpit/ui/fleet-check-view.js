import {node} from './app-shell.js';
const views=new Map();
function worldPair(world){try{return JSON.parse(world)?.slice(0,2);}catch{return null;}}
export function remoteChecksFor(task,world){const value=views.get(JSON.stringify([worldPair(world),task?.id]));return (value?.runs??[]).filter(r=>r.binding.revision===task?.revision);}
export function remoteLabel(r){return r.active?'Checking on super-worker-01':r.state==='completed'?(r.verdict==='pass'?'Remote checks passed':'Remote checks failed'):r.state==='prepared'?'Prepared · not sent':'Remote outcome unconfirmed';}
export function initFleetChecks({root,context,invoke}){
 const panel=node('details',undefined,'attempt-checks fleet-task-check');panel.dataset.fleetTaskChecks='';const summary=node('summary','Remote checks'),explain=node('p','Check the committed task activity and fleet connection files on super-worker-01. This small profile is advisory: unsaved edits, review proposals and the rest of the app are not tested.','directory-note'),start=node('button','Check committed files on super-worker-01','subtle'),notice=node('p','','availability-note'),history=node('div');start.type='button';panel.append(summary,explain,start,notice,history);root.append(panel);
 let signature='',busy=false,polling=false,epoch=0,key='';
 async function refresh(){
  const c=context(),next=JSON.stringify([c.world,c.task?.id,c.task?.revision]);if(next!==key){key=next;epoch++;signature='';history.replaceChildren();notice.textContent='';}
  panel.hidden=!c.task;start.hidden=!c.task||['completed','cancelled'].includes(c.task?.status);if(!c.task||!c.world||polling)return;polling=true;const captured=epoch;
  try{
   const result=await invoke('fleet_checks',{request:{operation:'list',world:JSON.parse(c.world),task_ref:c.task.id}});if(captured!==epoch||JSON.stringify([context().world,context().task?.id,context().task?.revision])!==next)return;
   const cachekey=JSON.stringify([JSON.parse(c.world).slice(0,2),c.task.id]);if(JSON.stringify(views.get(cachekey))!==JSON.stringify(result)){views.set(cachekey,result);while(views.size>32)views.delete(views.keys().next().value);document.dispatchEvent(new Event('fleet-checks-changed'));}
   start.disabled=busy||!result.configured||result.runs.some(r=>r.active||r.state==='unknown');
   if(notice.textContent==='Request saved. The remote result will appear here.'&&result.runs.at(-1)?.state==='completed'&&!result.runs.at(-1)?.active)notice.textContent='Remote result received. Review the output below.';
   const sig=JSON.stringify(result);if(signature===sig)return;signature=sig;
   const opened=new Set([...history.querySelectorAll('details[open]')].map(d=>d.dataset.remoteOutput));history.replaceChildren();
   if(!result.configured)history.append(node('p','Remote checks are not configured on this device.'));
   if(!result.runs.length)history.append(node('p','No remote check for this task yet. Choose its repository in Editor, then run this check.'));
   for(const r of result.runs){const row=node('article',undefined,'development-attempt');row.dataset.remoteCheck=r.id;row.append(node('h4',remoteLabel(r)),node('p',`Plan revision ${r.binding.revision}${r.binding.revision===c.task.revision?'':' · earlier plan'} · committed source ${r.binding.head.slice(0,12)}`,'directory-note'));if(r.reason)row.append(node('p',r.reason));
    const detail=node('details');detail.dataset.remoteOutput=r.id;detail.open=opened.has(r.id);detail.append(node('summary','Output and checked files'),node('p','Snapshot: '+r.snapshot,'directory-note'),node('p','Request: '+r.id,'directory-note'),node('p',r.files.join(', '),'directory-note'));if(r.output)detail.append(node('pre',r.output,'attempt-text'));if(r.omittedBytes)detail.append(node('p','Some output was omitted.'));row.append(detail);
    if(r.state==='unknown'&&!r.active){const check=node('button','Check remote status','subtle');check.type='button';check.onclick=async()=>{if(busy)return;busy=true;check.disabled=true;try{await invoke('fleet_checks',{request:{operation:'reconcile',world:JSON.parse(c.world),id:r.id}});}catch(e){notice.textContent=String(e);}finally{busy=false;signature='';refresh();}};row.append(check);}history.append(row);
   }
  }catch(e){notice.textContent=String(e);}finally{polling=false;}
 }
 start.onclick=async()=>{const c=context();if(busy||!c.task)return;busy=true;start.disabled=true;notice.textContent='Checking this plan and capturing committed files…';try{const selected=await invoke('development_request',{request:{operation:'status'}});await invoke('fleet_checks',{request:{operation:'start',world:JSON.parse(c.world),task_ref:c.task.id,revision:c.task.revision,generation:selected.generation}});notice.textContent='Request saved. The remote result will appear here.';}catch(e){notice.textContent=String(e);}finally{busy=false;signature='';refresh();}};
 const timer=setInterval(()=>{if(!panel.isConnected){clearInterval(timer);return;}refresh();},1200);refresh();return {panel,refresh};
}
