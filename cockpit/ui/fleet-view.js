import {fleetRecords,machineKey,vmKey} from './fleet-records.js';
import {node,panel,navigate,registerRecord} from './app-shell.js';
export const fleetStatus=status=>({observed:'Recently observed',unavailable:'Connection needs attention',stale:'Observation expired'})[status]||'Not observed';
export function fleetDiagram(fleet){
 const nodes=[{id:'observer',label:'Fleet observer',state:fleet?.status==='configured'?'Inventory connected':'Not connected',detail:'Verified host observations reach this page through the runtime. They do not grant permission to execute work.',route:'fleet'}],edges=[];
 for(const h of fleet?.hosts??[]){const id='host:'+h.id,i=h.inventory;nodes.push({id,label:h.label,state:fleetStatus(h.status),detail:[i?`${i.os} · ${i.hypervisor} · ${i.logicalCpus} logical CPUs`:'',h.reason,h.nextStep].filter(Boolean).join('\n'),route:'fleet',recordKey:machineKey(h.id)});edges.push({from:'observer',to:id,label:'observes host'});
  for(const g of i?.guests??[]){const gid=id+':guest:'+g.id;nodes.push({id:gid,label:g.label,state:h.status==='observed'?g.status:'Unknown',detail:'Guest reported by '+h.label+'. Guest state does not establish a Super worker assignment.',route:'fleet',recordKey:vmKey(h.id,g.id)});edges.push({from:id,to:gid,label:'hosts guest'});}
 }
 return {title:'Fleet & placement',coverage:'Observed hosts and guests · task placement is not enabled yet.',nodes,edges};
}
export function fleetPanel(fleet){
 const root=panel('fleet');root.dataset.fleetView='';
 const hosts=fleet?.hosts??[],toolbar=node('div',undefined,'machine-toolbar fleet-next');
 const count=node('span',`${hosts.length} machine${hosts.length===1?'':'s'}`,'machine-count');
 const check=node('button','Task checks','subtle');check.type='button';check.onclick=()=>navigate('continue-work',true);toolbar.append(count,check);root.append(toolbar);
 if(fleet?.status!=='configured'){root.append(node('p',fleet?.status==='unconfigured'?'No machines connected yet. Configure a Fleet observer to add your machines.':'Machine observations are unavailable. Check the observer connection.','fleet-empty'));return root;}
 for(const e of fleetRecords(fleet))registerRecord(e.record,e.key,e.record.name);
 const headings=node('div',undefined,'machine-columns');for(const label of ['Machine','Connection','Capacity','VMs',''])headings.append(node('span',label));headings.setAttribute('aria-hidden','true');root.append(headings);
 const list=node('ul',undefined,'machine-list');
 for(const h of hosts){
  const i=h.inventory,observed=h.status==='observed',row=node('li',undefined,'machine-row');row.dataset.fleetHost=h.id;
  const button=node('button',undefined,'machine-open');button.type='button';button.dataset.recordOpen=machineKey(h.id);button.setAttribute('aria-label',`Open machine ${h.label}, ${h.id}`);
  const identity=node('span',undefined,'machine-identity');identity.append(node('strong',i?.hostname||h.label),node('span',i?`${i.os} · ${i.hypervisor==='none'?'Physical host':i.hypervisor}`:h.id,'machine-secondary'));
  const connection=node('span',undefined,'machine-connection');connection.append(node('span',observed?'Observed':h.status==='stale'?'Out of date':'Unavailable','machine-status '+(observed?'is-observed':'needs-attention')),node('span',new Date(h.observedAt).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'}),'machine-secondary'));connection.title=fleetStatus(h.status)+' · '+new Date(h.observedAt).toLocaleString();
  const capacity=node('span',undefined,'machine-capacity');capacity.append(node('span',i?`${i.logicalCpus} CPUs`:'Not reported'),node('span',i?`${(i.memoryBytes/2**30).toFixed(1)} GiB RAM`:'','machine-secondary'));if(!observed&&i)capacity.title='Last observed capacity';
  const guests=node('span',i?String(i.guests?.length??0):'—','machine-vm-count');guests.dataset.unit=i?.guests?.length===1?'VM':'VMs';guests.setAttribute('aria-label',i?`${i.guests?.length??0} virtual machines`:'Virtual machine count unavailable');
  button.append(identity,connection,capacity,guests,node('span','→','machine-arrow'));row.append(button);list.append(row);
 }
 root.append(list,node('p','Select a machine to view its details and virtual machines.','machine-help'));return root;
}
