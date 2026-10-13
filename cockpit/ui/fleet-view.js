import {fleetRecords,machineKey,vmKey} from './fleet-records.js';
import {node,panel,navigate,registerRecord} from './app-shell.js';
export const fleetStatus=status=>status==='observed'?'Seen':status==='stale'?'Not seen for a while':"Can't connect";
// What a host's configured workers said when the collector asked each guest's own check endpoint for the status of an
// impossible request id. `ready` is that answer, aged by the runtime; nothing here is inferred from inventory.
export const workerSummary=h=>{const ws=h.workers??[];if(!ws.length)return {label:'—',state:'none',detail:'No worker is configured on this host.'};const ready=ws.filter(w=>w.ready);const w=ready[0]??ws[0];const last=w.lastCheck?`Last check ${w.lastCheck.verdict??w.lastCheck.state} · ${new Date(w.lastCheck.at).toLocaleString()}`:'No check has run on this device';return ready.length?{label:'Answers',state:'ready',at:w.checkedAt,detail:`${w.guest} answered a status query at ${new Date(w.checkedAt).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'})}. ${last}.`}:{label:"Didn't answer",state:'unready',at:w.checkedAt,detail:`${w.guest}: ${w.reason||'no answer'}. ${last}.`};};
// The watcher's own reason, quoted literally: the words stay outside, and the reason is only the text of a plain-text
// `code` element, so anything shaped like a record id inside it stays text. Never rephrased or parsed.
const watcherReason=reason=>{const line=node('div',undefined,'machine-reason');line.append(node('span','the watcher reported: '),node('code',reason));return line;};
const DECISION_NOTE='Machine readings never create a decision for you. Approvals about machines come to you in the chat of the lane doing that work, on your own line. Permission requests are in Mission.';
export function fleetDiagram(fleet){
 const nodes=[{id:'observer',label:'Fleet observer',state:fleet?.status==='configured'?'Inventory connected':'Not connected',detail:'Verified host observations reach this page through the runtime. They do not grant permission to execute work.',route:'fleet'}],edges=[];
 for(const h of fleet?.hosts??[]){const id='host:'+h.id,i=h.inventory;nodes.push({id,label:h.label,state:fleetStatus(h.status),detail:[i?`${i.os} · ${i.hypervisor} · ${i.logicalCpus} logical CPUs`:'',workerSummary(h).detail,h.reason,h.nextStep].filter(Boolean).join('\n'),route:'fleet',recordKey:machineKey(h.id)});edges.push({from:'observer',to:id,label:'observes host'});
  for(const g of i?.guests??[]){const gid=id+':guest:'+g.id;nodes.push({id:gid,label:g.label,state:h.status==='observed'?g.status:'Unknown',detail:'Guest reported by '+h.label+'. Guest state does not establish a Super worker assignment.',route:'fleet',recordKey:vmKey(h.id,g.id)});edges.push({from:id,to:gid,label:'hosts guest'});}
 }
 return {title:'Machines',coverage:'Observed hosts and guests · task placement is not enabled yet.',nodes,edges};
}
export function fleetPanel(fleet){
 const root=panel('fleet');root.dataset.fleetView='';
 const hosts=fleet?.hosts??[],toolbar=node('div',undefined,'machine-toolbar fleet-next');
 const count=node('span',`${hosts.length} machine${hosts.length===1?'':'s'}`,'machine-count');
 const check=node('button','Task checks','subtle');check.type='button';check.onclick=()=>navigate('continue-work',true);toolbar.append(count,check);root.append(toolbar,node('p',DECISION_NOTE,'machine-note'));
 if(fleet?.status!=='configured'){root.append(node('p',fleet?.status==='unconfigured'?'No machines connected yet. Configure a Fleet observer to add your machines.':'Machine observations are unavailable. Check the observer connection.','fleet-empty'));return root;}
 for(const e of fleetRecords(fleet))registerRecord(e.record,e.key,e.record.name);
 const headings=node('div',undefined,'machine-columns');for(const label of ['Machine','Connection','Capacity','Worker','VMs',''])headings.append(node('span',label));headings.setAttribute('aria-hidden','true');root.append(headings);
 const list=node('ul',undefined,'machine-list');
 for(const h of hosts){
  const i=h.inventory,observed=h.status==='observed',row=node('li',undefined,'machine-row');row.dataset.fleetHost=h.id;
  const button=node('button',undefined,'machine-open');button.type='button';button.dataset.recordOpen=machineKey(h.id);button.setAttribute('aria-label',`Open machine ${h.label}, ${h.id}`);
  const identity=node('span',undefined,'machine-identity');identity.append(node('strong',i?.hostname||h.label),node('span',i?`${i.os} · ${i.hypervisor==='none'?'Physical host':i.hypervisor}`:h.id,'machine-secondary'));
  const connection=node('span',undefined,'machine-connection');connection.append(node('span',fleetStatus(h.status),'machine-status '+(observed?'is-observed':'needs-attention')),node('span',new Date(h.observedAt).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'}),'machine-secondary'));connection.title=fleetStatus(h.status)+' · '+new Date(h.observedAt).toLocaleString();
  const capacity=node('span',undefined,'machine-capacity');capacity.append(node('span',i?`${i.logicalCpus} CPUs`:'Not reported'),node('span',i?`${(i.memoryBytes/2**30).toFixed(1)} GiB RAM`:'','machine-secondary'));if(!observed&&i)capacity.title='Last observed capacity';
  const ws=workerSummary(h),worker=node('span',undefined,'machine-worker');worker.append(node('span',ws.label,'machine-status '+(ws.state==='ready'?'is-observed':ws.state==='unready'?'needs-attention':'')),node('span',ws.at?new Date(ws.at).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'}):'','machine-secondary'));worker.title=ws.detail;worker.dataset.workerState=ws.state;
  const guests=node('span',i?String(i.guests?.length??0):'—','machine-vm-count');guests.dataset.unit=i?.guests?.length===1?'VM':'VMs';guests.setAttribute('aria-label',i?`${i.guests?.length??0} virtual machines`:'Virtual machine count unavailable');
  button.append(identity,connection,capacity,worker,guests,node('span','→','machine-arrow'));row.append(button);
  if(!observed&&h.reason)row.append(watcherReason(h.reason));
  for(const w of h.workers??[])if(!w.ready&&w.reason)row.append(watcherReason(w.reason));
  list.append(row);
 }
 root.append(list,node('p','Select a machine to view its details and virtual machines.','machine-help'));return root;
}
