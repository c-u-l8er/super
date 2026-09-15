import {outputAttachments} from './task-output-attachments.js';
import {node} from './app-shell.js';
import {visualReview} from './visual-review.js';

export function taskScreenshots({task,world,invoke,current}) {
 const panel=node('section',undefined,'task-screenshots attempt-checks');
 panel.append(node('h3','Before and after'),node('p',`Revision ${task.revision} · Attach PNG images up to 2 MB and 4096 pixels per side. Paired mobile devices can view them. Images do not replace checks or acceptance.`,'availability-note'));
 const gallery=node('div',undefined,'screenshot-pair'),notice=node('p'),undo=node('button','Undo removal');
 notice.setAttribute('role','status');undo.type='button';undo.hidden=true;panel.append(gallery,notice,undo);
 const lineage=[world.world_incarnation,world.world_generation],request={world:lineage,task:task.id,revision:task.revision};
 let busy=false,removed=null,record={},reviewUI=null,outputUI=null,previewTabs=[],emulators=[];
 const stillCurrent=()=>{const c=current(),w=c?.frame?.world;return panel.isConnected&&w&&JSON.stringify([w.world_incarnation,w.world_generation])===JSON.stringify(lineage)&&c.frame.projection?.development_tasks?.[task.id]?.revision===task.revision&&!c.withdrawn&&!c.unavailable&&!c.stalled;};
 const requireCurrent=()=>{if(!stillCurrent())throw Error('Task or connection changed. Reopen the task.');};
 function setBusy(value){busy=value;panel.setAttribute('aria-busy',String(value));panel.querySelectorAll('input,button,select').forEach(control=>control.disabled=value);if(!value)reviewUI?.refresh();}
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
 function paint(nextRecord) {
  record=nextRecord;
  gallery.replaceChildren();
  for(const side of ['before','after']) {
   const label=side==='before'?'Before':'After',card=node('figure');card.append(node('figcaption',label));
   const image=record.images?.[side];
   if(image){const img=node('img');img.src=image.data;img.alt=`${label} screenshot for ${task.title}, revision ${task.revision}`;img.loading='lazy';const expand=node('button','Open '+label.toLowerCase()+' image');expand.type='button';expand.onclick=()=>{const dialog=node('dialog',undefined,'screenshot-preview'),close=node('button','Close image'),full=node('img');close.type='button';full.src=image.data;full.alt=img.alt;close.onclick=()=>dialog.close();dialog.append(close,full);dialog.addEventListener('close',()=>{dialog.remove();expand.focus();});panel.append(dialog);dialog.showModal();};card.append(img,expand,node('p',`Attached ${new Date(image.attached_at*1000).toLocaleString()}`,'availability-note'));}
   else card.append(node('p',side==='before'?'Show the starting screen.':'Show the result of this task.','directory-note'));
   const input=node('input');input.type='file';input.accept='image/png';input.setAttribute('aria-label','Attach '+label+' screenshot');input.disabled=busy;
   input.onchange=()=>{
    const file=input.files[0];if(!file||busy)return;
    if(file.size>2_000_000){notice.textContent='Choose a PNG no larger than 2 MB.';input.value='';return;}
    change(side,'save',()=>new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(Error('Could not read screenshot.'));reader.readAsDataURL(file);}));
   };
   const upload=node('label',undefined,'screenshot-upload');upload.append(node('span',image?'Replace screenshot':'Add '+label.toLowerCase()+' screenshot'),input);card.append(upload);
   if(image){const remove=node('button','Remove '+label.toLowerCase()+' screenshot');remove.type='button';remove.disabled=busy;remove.onclick=()=>change(side,'remove',null,image);card.append(remove);}
   const previewLabel=node('label','Local preview to capture','field'),preview=node('select');preview.setAttribute('aria-label','Preview for '+label+' screenshot');const blank=node('option','Choose an open Browser tab');blank.value='';preview.append(blank);for(const tab of previewTabs){const option=node('option',`Tab ${tab.id+1} · ${tab.url}`);option.value=String(tab.id);preview.append(option);}previewLabel.append(preview);const capture=node('button','Capture '+side+' from preview');capture.type='button';capture.disabled=busy||!previewTabs.length;capture.onclick=async()=>{if(busy)return;if(preview.value===''){notice.textContent='Choose the local app tab to capture.';return;}try{requireCurrent();setBusy(true);notice.textContent='Capturing the local app preview…';const next=await invoke('task_screenshots',{request:{...request,operation:'capture_preview',side,tab:Number(preview.value)}});if(stillCurrent()){paint(next);notice.textContent=label+' preview captured and attached.';}}catch(e){notice.textContent=String(e.message||e);}finally{setBusy(false);}};
   card.append(previewLabel,capture);
   const emulatorLabel=node('label','Android emulator','field'),emulator=node('select');emulator.setAttribute('aria-label','Emulator for '+label+' screenshot');const noDevice=node('option',emulators.length?'Choose an emulator':'Refresh emulators to find running devices');noDevice.value='';emulator.append(noDevice);for(const device of emulators){const option=node('option',device.model+' · '+device.serial);option.value=device.serial;emulator.append(option);}emulatorLabel.append(emulator);
   const captureEmulator=node('button','Capture '+side+' from emulator');captureEmulator.type='button';captureEmulator.disabled=busy||!emulators.length;
   captureEmulator.onclick=async()=>{if(busy)return;if(!emulator.value){notice.textContent='Choose the emulator showing the intended app screen.';return;}try{requireCurrent();setBusy(true);notice.textContent='Capturing the emulator display…';const next=await invoke('task_screenshots',{request:{...request,operation:'capture_emulator',side,serial:emulator.value}});if(stillCurrent()){removed=null;undo.hidden=true;paint(next);notice.textContent=label+' emulator screenshot captured and attached.';}}catch(e){if(panel.isConnected)notice.textContent=String(e.message||e);}finally{setBusy(false);}};
   const deviceControls=node('details');deviceControls.append(node('summary','Capture an Android emulator'),node('p','Open the intended app in a running emulator, then capture its full display. This does not launch or verify a source version.','directory-note'),emulatorLabel,captureEmulator);card.append(deviceControls);
   if(image?.capture){const origin=image.capture;card.append(node('p',origin.kind==='android-emulator'?`Android emulator · ${origin.model} · ${origin.serial} · Android ${origin.android} · ${image.width} × ${image.height} full display · ${origin.activity} · app source version unverified`:'Captured local preview: '+origin.url+' · app source version unverified','directory-note'));}
   gallery.append(card);
  }
  if(!reviewUI){reviewUI=visualReview({task,request,invoke,current,getRecord:()=>record,onSaved:paint});panel.append(reviewUI.panel);}
  const outputOpen=outputUI?.open;
  const nextOutput=outputAttachments({record,save:async(side,operation,output)=>{requireCurrent();if(busy)throw Error('Evidence is being saved. Try again.');setBusy(true);try{const next=await invoke('task_screenshots',{request:{...request,side,operation,output}});if(stillCurrent()){paint(next);notice.textContent=(side==='before'?'Before':'After')+' log '+(operation==='save_output'?'saved.':'removed.');}}finally{setBusy(false);}}});
  nextOutput.open=outputOpen||!!record.outputs?.before||!!record.outputs?.after;
  if(outputUI)outputUI.replaceWith(nextOutput);else panel.append(nextOutput);outputUI=nextOutput;
  reviewUI.refresh();
 }
 const refreshEmulators=node('button','Refresh emulators');refreshEmulators.type='button';refreshEmulators.onclick=async()=>{if(busy)return;try{requireCurrent();setBusy(true);notice.textContent='Finding running Android emulators…';const value=await invoke('task_screenshots',{request:{operation:'list_emulators'}});if(stillCurrent()){emulators=value.devices||[];paint(record);notice.textContent=emulators.length?'Choose the emulator under Before or After.':'No running emulator found. Start an Android emulator, open the app, then refresh.';}}catch(e){if(panel.isConnected)notice.textContent=String(e.message||e);}finally{setBusy(false);}};panel.append(refreshEmulators);
 const refreshPreviews=node('button','Refresh preview tabs');refreshPreviews.type='button';const loadPreviews=()=>invoke('browser_surface',{action:'status'}).then(value=>{previewTabs=(value.tabs||[]).filter(t=>/^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(?=[:/]|$)/.test(t.url||''));if(stillCurrent()&&!busy)paint(record);}).catch(()=>{});refreshPreviews.onclick=loadPreviews;panel.append(refreshPreviews);loadPreviews();
 invoke('task_screenshots',{request:{...request,operation:'list'}}).then(record=>{if(stillCurrent())paint(record);}).catch(e=>{if(panel.isConnected)notice.textContent=String(e);});
 return panel;
}
