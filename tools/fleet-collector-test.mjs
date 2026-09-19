import test from 'node:test';import assert from 'node:assert/strict';
import {configuration,collect,publish,readiness,workerConfiguration,PROBE_ID} from './fleet-collector.mjs';
import {fleetDiagram} from '../cockpit/ui/fleet-view.js';
import {mkdtemp,readFile,rm,stat} from 'node:fs/promises';import {tmpdir} from 'node:os';import {join} from 'node:path';
const host={id:'floor',label:'FreeBSD research',hostname:'cd-floor-01',target:'cd-floor-01',nextStep:'Prepare a bhyve guest'};
test('configuration rejects duplicate identities and unsafe connection targets',()=>{assert.equal(configuration([host]).length,1);for(const h of [[host,host],[{...host,target:'-oProxyCommand=bad'}],[{...host,identityFile:'relative'}]])assert.throws(()=>configuration(h));});
test('only the enrolled hostname can become observed',async()=>{for(const result of [{status:'unavailable'},{status:'observed',inventory:{hostname:'wrong'}}]){const r=await collect([host],async()=>result,()=>100);assert.equal(r.hosts[0].status,'unavailable');assert.equal(r.hosts[0].inventory,undefined);}});
test('a failed refresh removes the prior successful inventory',async()=>{const ok=await collect([host],async()=>({status:'observed',inventory:{hostname:host.hostname}}));const failed=await collect([host],async()=>{throw Error('offline');});assert.equal(ok.hosts[0].workerReady,false);assert.equal(failed.hosts[0].status,'unavailable');assert.equal(failed.hosts[0].inventory,undefined);});
test('atomic snapshot publication preserves complete JSON and owner-only access',async()=>{const dir=await mkdtemp(join(tmpdir(),'fleet-'));try{const file=join(dir,'snapshot');await publish(file,{first:true});await publish(file,{second:true});assert.deepEqual(JSON.parse(await readFile(file)),{second:true});assert.equal((await stat(file)).mode&0o777,0o600);}finally{await rm(dir,{recursive:true,force:true});}});
test('diagram distinguishes physical host from guest and suppresses expired guest state',()=>{const fleet={status:'configured',hosts:[{...host,status:'stale',inventory:{os:'FreeBSD',hypervisor:'bhyve',logicalCpus:16,guests:[{id:'wifibox',label:'Wifibox',status:'present'}]}}]};const d=fleetDiagram(fleet);assert.equal(d.nodes.length,3);assert.equal(d.nodes[2].state,'Unknown');assert.equal(d.edges[1].label,'hosts guest');});
const worker={host:'floor',guest:'super-worker-02',target:'root@192.168.1.71',identityFile:'/k',knownHosts:'/kh'};
const inventory=async()=>({status:'observed',inventory:{hostname:host.hostname}});
test('worker readiness is derived from the guest endpoint answering a status query, never assumed',async()=>{
 const answered=async()=>({state:'unknown',id:PROBE_ID,reason:'No durable receipt found.'});
 const r=await collect([host],inventory,()=>100,[worker],answered);
 assert.equal(r.hosts[0].workerReady,true);assert.deepEqual(r.hosts[0].workers.map(w=>[w.guest,w.ready,w.checkedAt,w.reason]),[['super-worker-02',true,100,'']]);
});
test('a lost connection, an error answer or a foreign id reads as not ready, with the reason',async()=>{
 for(const [ask,reason] of [[async()=>{throw Error('Remote response was lost.');},'Remote response was lost.'],[async()=>({error:'Invalid request ID'}),'Invalid request ID'],[async()=>({state:'unknown',id:'fc-'+'1'.repeat(32)}),'The worker did not answer a status query.']]){
  const r=await collect([host],inventory,()=>100,[worker],ask);
  assert.equal(r.hosts[0].workerReady,false);assert.equal(r.hosts[0].workers[0].ready,false);assert.equal(r.hosts[0].workers[0].reason,reason);
 }
});
test('a host with no configured worker carries no worker and is never ready',async()=>{
 const r=await collect([host],inventory,()=>100,[{...worker,host:'elsewhere'}],async()=>({state:'unknown',id:PROBE_ID}));
 assert.deepEqual(r.hosts[0].workers,[]);assert.equal(r.hosts[0].workerReady,false);
});
test('the newest completed check on that worker rides along from the device ledger',async()=>{
 const ledger=[{host:'floor',guest:'super-worker-02',id:'fc-'+'a'.repeat(32),state:'completed',verdict:'pass',at:50},{host:'floor',guest:'super-worker-02',id:'fc-'+'b'.repeat(32),state:'unknown',verdict:null,at:70},{host:'other',guest:'x',id:'fc-'+'c'.repeat(32),state:'completed',verdict:'fail',at:99}];
 const r=await collect([host],inventory,()=>100,[worker],async()=>({state:'unknown',id:PROBE_ID}),ledger);
 assert.deepEqual(r.hosts[0].workers[0].lastCheck,{id:'fc-'+'b'.repeat(32),state:'unknown',verdict:null,at:70});
 assert.equal((await readiness(worker,async()=>({state:'unknown',id:PROBE_ID}),()=>5)).checkedAt,5);
});
test('worker configuration is bounded and typed',()=>{
 assert.equal(workerConfiguration({workers:[worker]}).length,1);assert.equal(workerConfiguration({}).length,0);
 assert.throws(()=>workerConfiguration({workers:[worker,worker,worker]}));assert.throws(()=>workerConfiguration({workers:[{...worker,guest:'bad guest'}]}));
});
