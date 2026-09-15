import {node} from './app-shell.js';

export function taskScreenshots({task,world,invoke,current}) {
 const panel=node('section',undefined,'task-screenshots attempt-checks');
 panel.append(node('h3','Before and after'),node('p',`Revision ${task.revision} · Attach PNG images up to 2 MB and 4096 pixels per side. Paired mobile devices can view them. Images do not replace checks or acceptance.`,'availability-note'));
 const gallery=node('div',undefined,'screenshot-pair'),notice=node('p'),undo=node('button','Undo removal');
 notice.setAttribute('role','status');undo.type='button';undo.hidden=true;panel.append(gallery,notice,undo);
 const lineage=[world.world_incarnation,world.world_generation],request={world:lineage,task:task.id,revision:task.revision};
 let busy=false,removed=null;
 const stillCurrent=()=>{const c=current(),w=c?.frame?.world;return panel.isConnected&&w&&JSON.stringify([w.world_incarnation,w.world_generation])===JSON.stringify(lineage)&&c.frame.projection?.development_tasks?.[task.id]?.revision===task.revision&&!c.withdrawn&&!c.unavailable&&!c.stalled;};
 const requireCurrent=()=>{if(!stillCurrent())throw Error('Task or connection changed. Reopen the task.');};
 function setBusy(value){busy=value;panel.setAttribute('aria-busy',String(value));panel.querySelectorAll('input,button').forEach(control=>control.disabled=value);}
 async function change(side,operation,data,previous) {
  if(busy)return;
  const label=side==='before'?'Before':'After';
  try {
   requireCurrent();setBusy(true);notice.textContent=operation==='remove'?'Removing screenshot…':'Saving screenshot…';
   // File reading is asynchronous; recheck the observed task before saving.
   if(typeof data==='function')data=await data();
   requireCurrent();
   const record=await invoke('task_screenshots',{request:{...request,operation,side,...(data?{data}:{})}});
   if(!stillCurrent())return;
   removed=operation==='remove'?{side,data:previous.data}:null;
   undo.hidden=!removed;paint(record);
   notice.textContent=`${label} screenshot ${operation==='remove'?'removed':'saved'} for revision ${task.revision}.`;
   setBusy(false);
   gallery.querySelector(`[aria-label="Attach ${label} screenshot"]`)?.focus();
  }catch(e){if(panel.isConnected)notice.textContent=String(e.message||e);}
  finally{setBusy(false);}
 }
 undo.onclick=()=>{if(removed)change(removed.side,'save',removed.data);};
 function paint(record) {
  gallery.replaceChildren();
  for(const side of ['before','after']) {
   const label=side==='before'?'Before':'After',card=node('figure');card.append(node('figcaption',label));
   const image=record.images?.[side];
   if(image){const img=node('img');img.src=image.data;img.alt=`${label} screenshot for ${task.title}, revision ${task.revision}`;img.loading='lazy';card.append(img,node('p',`Attached ${new Date(image.attached_at*1000).toLocaleString()}`,'availability-note'));}
   else card.append(node('p','No screenshot attached.','availability-note'));
   const input=node('input');input.type='file';input.accept='image/png';input.setAttribute('aria-label','Attach '+label+' screenshot');input.disabled=busy;
   input.onchange=()=>{
    const file=input.files[0];if(!file||busy)return;
    if(file.size>2_000_000){notice.textContent='Choose a PNG no larger than 2 MB.';input.value='';return;}
    change(side,'save',()=>new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(Error('Could not read screenshot.'));reader.readAsDataURL(file);}));
   };
   card.append(node('p',image?'Replace screenshot':'Add screenshot','availability-note'),input);
   if(image){const remove=node('button','Remove '+label.toLowerCase()+' screenshot');remove.type='button';remove.disabled=busy;remove.onclick=()=>change(side,'remove',null,image);card.append(remove);}
   gallery.append(card);
  }
 }
 invoke('task_screenshots',{request:{...request,operation:'list'}}).then(record=>{if(stillCurrent())paint(record);}).catch(e=>{if(panel.isConnected)notice.textContent=String(e);});
 return panel;
}
