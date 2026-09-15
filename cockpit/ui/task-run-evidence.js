import {node} from './app-shell.js';
import {runtimeWorld} from './runtime-bots.js';

// Compare retained observations; an earlier run is not automatically an unchanged-code baseline.
export function comparisonNotes(before,after){
 const notes=[];
 if(!before||!after)return ['Choose two recorded runs to compare.'];
 if(before.id===after.id)notes.push('The same run is selected on both sides.');
 if(before.profile!==after.profile)notes.push('Different check profiles: results are not directly comparable.');
 if(before.machine!==after.machine)notes.push('Different machines: timings are not directly comparable.');
 if(before.revision!==after.revision)notes.push('These runs belong to different task revisions.');
 if(before.snapshot&&before.snapshot===after.snapshot)notes.push('Both runs checked the same source snapshot; this does not demonstrate a code change.');
 if(before.toolchain!==after.toolchain)notes.push('The toolchain identity differs; compare performance with care.');
 return notes;
}
export function taskRunEvidence({task,invoke,current}){
 const panel=node('section',undefined,'task-run-evidence task-screenshots');
 panel.append(node('h3','Tests and terminal results'),node('p','Recorded output is collected here automatically. Compare an earlier run with a later run; neither label establishes an unchanged-code baseline. Benchmarks need matching commands, inputs, machines and units.','directory-note'));
 const status=node('p'),refresh=node('button','Refresh recorded runs'),pair=node('div',undefined,'screenshot-pair'),notes=node('div');refresh.type='button';status.setAttribute('role','status');panel.append(refresh,status,pair,notes);
 const origin=runtimeWorld(current);let signature='',rows=[],busy=false,selected={before:'',after:''};
 const valid=()=>panel.isConnected&&runtimeWorld(current)===origin&&current()?.frame?.projection?.development_tasks?.[task.id]?.revision===task.revision&&!current()?.unavailable&&!current()?.withdrawn&&!current()?.stalled;
 function draw(){
  pair.replaceChildren();notes.replaceChildren();
  for(const side of ['before','after']){
   const box=node('article'),label=node('label',side==='before'?'Earlier run':'Later run','field'),select=node('select');select.setAttribute('aria-label',side==='before'?'Earlier recorded run':'Later recorded run');
   const empty=node('option','Choose a recorded run');empty.value='';select.append(empty);
   for(const r of rows){const option=node('option',`${r.profile} · ${r.machine} · ${r.verdict} · revision ${r.revision} · ${r.at||r.id}`);option.value=r.id;select.append(option);}select.value=selected[side];select.onchange=()=>{selected[side]=select.value;draw();};label.append(select);box.append(label);
   const r=rows.find(r=>r.id===selected[side]);
   if(r){box.append(node('h4',r.verdict),node('p',r.id,'directory-note'),node('p',`Source: ${r.snapshot||'not recorded'}`,'directory-note'),node('p',r.confirmed?'Outcome recorded by the runner.':'Outcome is incomplete or unconfirmed.','directory-note'));if(r.exit!==undefined)box.append(node('p','Exit code: '+r.exit));const output=node('pre',r.output||'No output retained.','attempt-text');box.append(output);if(r.truncated)box.append(node('p','Output is shortened. This is not the complete log.','availability-note'));}
   pair.append(box);
  }
  for(const text of comparisonNotes(...['before','after'].map(s=>rows.find(r=>r.id===selected[s]))))notes.append(node('p',text,'availability-note'));
 }
 async function load(){
  if(busy||!valid())return;busy=true;refresh.disabled=true;if(!rows.length)status.textContent='Loading recorded output…';
  const captured=current().frame.projection;signature=JSON.stringify(captured.development_attempts);const attempts=Object.values(captured.development_attempts||{}).filter(a=>a.task_ref===task.id);const found=[];let failures=0;
  await Promise.all(attempts.map(async a=>{let runs=[];try{runs=(await invoke('review_tests',{request:{operation:'list',world:JSON.parse(origin),attempt_ref:a.id}})).runs||[];}catch{failures++;}
   const saved=a.test_runs||{},ids=new Set([...runs.map(r=>r.run_id),...Object.keys(saved)]);
   for(const id of ids){const local=runs.find(r=>r.run_id===id),record=saved[id],r=local?.result||record?.outcome||{};found.push({id:a.id+'/'+id,profile:r.profile||record?.profile||'Local tests',machine:'This device',revision:a.task_revision,snapshot:r.snapshot_sha256,toolchain:r.toolchain_sha256||r.node_sha256,verdict:r.verdict||local?.state||record?.state||'unknown',confirmed:record?.state==='completed',at:r.finished_at||record?.started_at||'',output:r.output,truncated:!!r.omitted_bytes||(!local?.result&&!!r.output_omitted),exit:r.exit_code});}
  }));
  try{const remote=await invoke('fleet_checks',{request:{operation:'list',world:JSON.parse(origin),task_ref:task.id}});for(const r of remote.runs||[])found.push({id:r.id,profile:'Remote committed-file checks',machine:[r.binding?.host,r.binding?.guest].filter(Boolean).join(' / ')||'Unknown host',revision:r.binding?.revision,snapshot:r.snapshot||r.binding?.head,verdict:r.verdict||r.state,confirmed:r.state==='completed',at:r.finishedAt?new Date(r.finishedAt).toISOString():r.createdAt?new Date(r.createdAt).toISOString():'',toolchain:r.nodeSha256,exit:r.exitCode,output:r.output,truncated:!!r.omittedBytes});}catch{failures++;}
  if(valid()){rows=found.sort((a,b)=>String(a.at).localeCompare(String(b.at))||a.id.localeCompare(b.id));for(const side of ['before','after'])if(!rows.some(r=>r.id===selected[side]))selected[side]='';if(!selected.after)selected.after=rows.at(-1)?.id||'';const latest=rows.find(r=>r.id===selected.after);if(!selected.before)selected.before=rows.filter(r=>r.id!==latest?.id&&r.profile===latest?.profile&&r.machine===latest?.machine).at(-1)?.id||'';draw();status.textContent=`${rows.length} recorded runs.${failures?' Some local history could not be loaded.':''}${!rows.length?' Run task checks to capture output. No baseline has been recorded.':''}`;}
  busy=false;refresh.disabled=false;
 }
 refresh.onclick=load;
 const timer=setInterval(()=>{if(!panel.isConnected){clearInterval(timer);return;}if(valid()&&signature!==JSON.stringify(current().frame.projection.development_attempts))load();},3000);
 setTimeout(load,0);return panel;
}
