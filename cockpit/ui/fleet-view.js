import {fleetRecords,machineKey,vmKey} from './fleet-records.js';
import {node,panel,navigate,detail} from './app-shell.js';
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
 const intro=node('section',undefined,'fleet-next');intro.append(node('h2','Inspect machines, then check your task'),node('p','Open Continue work to run configured remote checks and read their results. Each check keeps its task revision and committed source; guest inventory alone does not establish worker readiness.'));const check=node('button','Open task checks','subtle');check.type='button';check.onclick=()=>navigate('continue-work',true);intro.append(check);root.append(intro);
 if(fleet?.status!=='configured'){root.append(node('p',fleet?.status==='unconfigured'?'No fleet observer is configured yet.':'Fleet observations are unavailable. Check the local observer connection.','fleet-empty'));return root;}
 const entries=fleetRecords(fleet),byKey=new Map(entries.map(e=>[e.key,e.record]));
 const grid=node('div',undefined,'fleet-grid');for(const h of fleet.hosts??[]){const card=node('section',undefined,'fleet-host'),i=h.inventory;card.dataset.fleetHost=h.id;card.append(detail(byKey.get(machineKey(h.id)),machineKey(h.id),h.label));card.append(node('p',fleetStatus(h.status),'fleet-state'));
  if(i){card.append(node('p',`${i.os} ${i.release} · ${i.hypervisor==='none'?'Host':i.hypervisor==='bhyve'?'bhyve hypervisor':'Proxmox hypervisor'}`),node('p',`${i.logicalCpus} logical CPUs · ${(i.memoryBytes/2**30).toFixed(1)} GiB RAM${h.status==='observed'?'':' · last observed capacity'}`));}
  card.append(node('p',`Last check ${new Date(h.observedAt).toLocaleString()}`,'fleet-time'));if(h.reason)card.append(node('p',h.reason));
  const guests=node('ul',undefined,'fleet-guests');for(const g of i?.guests??[]){const li=node('li');li.append(detail(byKey.get(vmKey(h.id,g.id)),vmKey(h.id,g.id),g.label));guests.append(li);}if(guests.children.length)card.append(node('h3','Guests'),guests);else card.append(node('p',h.status==='observed'?'No guests reported.':'Guest state is unavailable.'));
  card.append(node('p',h.nextStep,'fleet-next-step'));grid.append(card);
 }root.append(grid);return root;
}
