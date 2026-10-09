import test from 'node:test';import assert from 'node:assert/strict';
import {configuration,collect,publish,readiness,workerConfiguration,PROBE_ID} from './fleet-collector.mjs';
import {TICK_MS,BACKOFF_CAP_MS,EARLY_MS,backoffDelay,due,schedule,retryReason,observe,run,commandLine,hostKey,workerKey} from './fleet-collector.mjs';
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
// T48 laws (L1-L8). Every law drives the loop on a fake clock: `sleep` only moves the clock on,
// so ticks land exactly on the 30-second marks (publishMs adds a publish time, for the drifting
// loop). The stand-in probe and ask record every contact; there is no SSH, no network and no
// real wait. Times in the expectations are seconds from T0.
const T0=Date.UTC(2026,9,8,6,0,0);
const answer={state:'unknown',id:PROBE_ID};
const refusedProbe={status:'unavailable',reason:'ssh: connect to host port 22: Connection refused'};
const REFUSED='Connection refused.',PROBE_FAILED='Connection check failed. Check the saved SSH connection.';
const L1_TIMES=[0,30,90,210,450,930,1830,2730,3630];
const clockText=ms=>{const d=new Date(ms);return [d.getHours(),d.getMinutes(),d.getSeconds()].map(n=>String(n).padStart(2,'0')).join(':');};
const retryTail=(dueAt,n)=>` Retrying at ${clockText(dueAt)} (${n} failed checks).`;
const healthy=async(_target,_runner,h)=>({status:'observed',inventory:{hostname:h.hostname}});
// probeOk(host,seconds) and askOk(worker,seconds) script each target's answer by the tick's time;
// probeAnswer(host,seconds), when given, returns the probe's whole answer instead.
async function simulate({hosts,workers=[],ticks,probeOk=()=>true,probeAnswer=null,askOk=()=>true,refusal=REFUSED,ledger=[],publishMs=0}){
 const clock={t:T0},contacts=[],writes=[],logs=[],at=()=>(clock.t-T0)/1000;let sleeps=0;
 await run({hosts,workers,output:'snapshot',ticks,now:()=>clock.t,sleep:async ms=>{sleeps++;clock.t+=ms;},
  inspect:async(_target,_runner,h)=>{contacts.push({target:'probe '+h.id,at:at()});if(probeAnswer)return probeAnswer(h,at());return probeOk(h,at())?{status:'observed',inventory:{hostname:h.hostname}}:refusedProbe;},
  ask:async w=>{contacts.push({target:'ask '+w.host+'/'+w.guest,at:at()});if(askOk(w,at()))return answer;throw Error(refusal);},
  ledger:async()=>ledger,
  write:async(path,value)=>{const text=JSON.stringify(value);writes.push({at:at(),path,text,value:JSON.parse(text)});clock.t+=publishMs;},
  log:line=>logs.push(line)});
 return {contacts,writes,logs,sleeps,times:target=>contacts.filter(c=>c.target===target).map(c=>c.at)};
}
test('L1 a host probe refused on every attempt is attempted at exactly 0, 30, 90, 210, 450, 930, 1830, 2730, 3630 s',async()=>{
 const r=await simulate({hosts:[host],ticks:122,probeOk:()=>false});
 assert.deepEqual(r.times('probe floor'),L1_TIMES);
});
test('L1 a worker refused on every attempt is asked at exactly the same times',async()=>{
 const r=await simulate({hosts:[host],workers:[worker],ticks:122,askOk:()=>false});
 assert.deepEqual(r.times('ask floor/super-worker-02'),L1_TIMES);
});
test('L1 the schedule: after the n-th failure a target is next due min(30 s x 2^(n-1), 900 s) after that attempt began',()=>{
 assert.equal(TICK_MS,30000);assert.equal(BACKOFF_CAP_MS,900000);
 assert.deepEqual([1,2,3,4,5,6,7,8,9,10].map(n=>backoffDelay(n)/1000),[30,60,120,240,480,900,900,900,900,900]);
 let state={},at=T0;const delays=[];
 assert.equal(due(state,'k',at),true);
 for(let n=1;n<=9;n++){
  state=schedule(state,at,[{key:'k',ok:false,reason:'refused',seenAt:at}]);
  assert.equal(state.k.failures,n);
  assert.equal(due(state,'k',at),false);assert.equal(due(state,'k',at+TICK_MS/2),false);assert.equal(due(state,'k',state.k.dueAt),true);
  delays.push((state.k.dueAt-at)/1000);at=state.k.dueAt;
 }
 assert.deepEqual(delays,[30,60,120,240,480,900,900,900,900]);
});
test('L1 the trace has one line per failed attempt at the times of L1, and none for a healthy target',async()=>{
 const r=await simulate({hosts:[host],ticks:122,probeOk:()=>false});
 const lines=r.logs.map(l=>/^fleet-collector (\S+) (\S+) failed \((\d+) in a row\); next attempt (\S+)$/.exec(l));
 assert.ok(lines.every(Boolean),r.logs.join('\n'));
 assert.deepEqual(lines.map(m=>(Date.parse(m[1])-T0)/1000),L1_TIMES);
 assert.deepEqual(lines.map(m=>Number(m[3])),[1,2,3,4,5,6,7,8,9]);
 assert.deepEqual(lines.map(m=>(Date.parse(m[4])-Date.parse(m[1]))/1000),[30,60,120,240,480,900,900,900,900]);
 const quiet=await simulate({hosts:[host],workers:[worker],ticks:10});
 assert.deepEqual(quiet.logs,[]);
});
test('L1 the due boundary: below the cap due from EARLY_MS before the due time, once capped only at the full delay',()=>{
 assert.equal(EARLY_MS,1000);
 let state={},at=T0;const capped=[];
 for(let n=1;n<=8;n++){
  state=schedule(state,at,[{key:'k',ok:false,reason:'refused',seenAt:at}]);
  const d=state.k.dueAt,delay=backoffDelay(n);
  assert.equal(d,at+delay,'due time after failure '+n);
  if(delay<BACKOFF_CAP_MS){
   assert.equal(due(state,'k',d-EARLY_MS-1),false,'one millisecond outside the margin after failure '+n);
   assert.equal(due(state,'k',d-EARLY_MS),true,'at the margin edge after failure '+n);
   assert.equal(due(state,'k',d),true,'at the due time after failure '+n);
   at=d-EARLY_MS;
  }else{
   capped.push(n);
   assert.equal(due(state,'k',d-EARLY_MS),false,'at the margin edge once capped, failure '+n);
   assert.equal(due(state,'k',d-1),false,'one millisecond early once capped, failure '+n);
   assert.equal(due(state,'k',d),true,'at the full delay once capped, failure '+n);
   at=d;
  }
 }
 assert.deepEqual(capped,[6,7,8]);
});
test('L1 the delay counts from when the tick began, not from when the attempt finished',async()=>{
 const clock={t:T0};
 const inspect=async()=>{await null;clock.t+=7000;return refusedProbe;};
 const ask=async()=>{await null;clock.t+=4000;throw Error(REFUSED);};
 const options={inspect,now:()=>clock.t,workers:[worker],ask};
 let r=await observe([host],{},options);
 assert.equal(r.at,T0);assert.equal(clock.t,T0+11000);
 assert.equal(r.state[hostKey(host)].dueAt,T0+30000);assert.equal(r.state[workerKey(worker)].dueAt,T0+30000);
 clock.t=T0+30000;
 r=await observe([host],r.state,options);
 assert.equal(r.at,T0+30000);assert.equal(clock.t,T0+41000);
 assert.equal(r.state[hostKey(host)].dueAt,T0+90000);assert.equal(r.state[workerKey(worker)].dueAt,T0+90000);
});
test('L2 a success after failures makes the target due on the very next tick, and a later failure starts again at 30 s',async()=>{
 const ok=(_,t)=>t===210||t===240;
 const r=await simulate({hosts:[host],workers:[worker],ticks:13,probeOk:ok,askOk:ok});
 for(const target of ['probe floor','ask floor/super-worker-02'])assert.deepEqual(r.times(target),[0,30,90,210,240,270,300,360],target);
 const at210=r.writes.find(w=>w.at===210).value.hosts[0];
 assert.equal(at210.status,'observed');assert.equal(at210.workers[0].ready,true);
 assert.ok(r.logs.some(l=>l.includes('answered after 3 failed checks')),r.logs.join('\n'));
});
test('L2 the schedule forgets the failures on the first success',()=>{
 let state={};
 for(const s of [0,30,90])state=schedule(state,T0+s*1000,[{key:'k',ok:false,reason:'refused',seenAt:T0+s*1000}]);
 state=schedule(state,T0+210000,[{key:'k',ok:true,reason:'',seenAt:T0+210000}]);
 assert.equal(due(state,'k',T0+240000),true);
 state=schedule(state,T0+270000,[{key:'k',ok:false,reason:'refused',seenAt:T0+270000}]);
 assert.equal(state.k.failures,1);assert.equal(state.k.dueAt,T0+300000);
});
test('L3 one target failing changes no other target: hosts, their workers and the other worker are independent',async()=>{
 const hosts=[{...host,id:'down'},{...host,id:'up'}];
 const workers=[{...worker,host:'down',guest:'w-down'},{...worker,host:'up',guest:'w-up'}];
 const r=await simulate({hosts,workers,ticks:20,probeOk:h=>h.id==='up',askOk:w=>w.guest==='w-down'});
 const every=Array.from({length:20},(_,i)=>i*30);
 assert.deepEqual(r.times('probe down'),[0,30,90,210,450]);
 assert.deepEqual(r.times('probe up'),every);
 assert.deepEqual(r.times('ask down/w-down'),every);
 assert.deepEqual(r.times('ask up/w-up'),[0,30,90,210,450]);
 const at60=r.writes.find(w=>w.at===60).value.hosts;
 assert.equal(at60[0].status,'unavailable');assert.equal(at60[0].workers[0].ready,true);assert.equal(at60[0].workerReady,true);
 assert.equal(at60[1].status,'observed');assert.equal(at60[1].workers[0].ready,false);assert.equal(at60[1].workerReady,false);
});
test('L3 two workers on the same host: one refusing changes neither the other worker nor the host probe',async()=>{
 const workers=[{...worker,guest:'w-good'},{...worker,guest:'w-bad'}];
 const r=await simulate({hosts:[host],workers,ticks:16,askOk:w=>w.guest==='w-good'});
 const every=Array.from({length:16},(_,i)=>i*30);
 assert.deepEqual(r.times('probe floor'),every);
 assert.deepEqual(r.times('ask floor/w-good'),every);
 assert.deepEqual(r.times('ask floor/w-bad'),[0,30,90,210,450]);
 const at60=r.writes.find(w=>w.at===60).value.hosts[0];
 assert.equal(at60.status,'observed');
 assert.deepEqual(at60.workers.map(w=>[w.guest,w.ready]),[['w-good',true],['w-bad',false]]);
 assert.equal(at60.workers[1].reason,REFUSED+retryTail(T0+90000,2));assert.equal(at60.workerReady,true);
});
test('L4 a target in backoff is not contacted on that tick: no probe, no ask',async()=>{
 const r=await simulate({hosts:[host],workers:[worker],ticks:16,probeOk:()=>false,askOk:()=>false});
 const attempted=[0,30,90,210,450];
 for(let at=0;at<=450;at+=30)for(const target of ['probe floor','ask floor/super-worker-02'])
  assert.equal(r.contacts.filter(c=>c.at===at&&c.target===target).length,attempted.includes(at)?1:0,target+' at '+at+' s');
});
test('L4 observe calls neither the injected probe nor the injected ask for a target that is not due',async()=>{
 const state=schedule({},T0,[{key:hostKey(host),ok:false,reason:PROBE_FAILED,seenAt:T0},{key:workerKey(worker),ok:false,reason:REFUSED,seenAt:T0}]);
 const called=[];
 const r=await observe([host],state,{inspect:async()=>{called.push('probe');return {status:'observed',inventory:{hostname:host.hostname}};},now:()=>T0+TICK_MS/2,workers:[worker],ask:async()=>{called.push('ask');return answer;}});
 assert.deepEqual(called,[]);assert.deepEqual(r.attempts,[]);
});
test('L5 every tick publishes, and a target in backoff publishes its last attempt, never better',async()=>{
 const r=await simulate({hosts:[host],workers:[worker],ticks:4,probeOk:(_,t)=>t===0,askOk:(_,t)=>t===0});
 assert.deepEqual(r.writes.map(w=>[w.at,w.path]),[[0,'snapshot'],[30,'snapshot'],[60,'snapshot'],[90,'snapshot']]);
 assert.deepEqual(r.contacts.filter(c=>c.at===90),[]);
 assert.equal(r.writes[0].value.hosts[0].status,'observed');
 const row=r.writes[3].value.hosts[0];
 assert.equal('inventory' in row,false);
 assert.deepEqual(row,{id:'floor',label:host.label,observedAt:T0+60000,status:'unavailable',reason:PROBE_FAILED+retryTail(T0+120000,2),nextStep:host.nextStep,workers:[{guest:worker.guest,ready:false,checkedAt:T0+60000,reason:REFUSED+retryTail(T0+120000,2),lastCheck:null}],workerReady:false});
});
test('L5 in the live loop a probe answering another hostname is a failure: the host backs off and no row carries inventory',async()=>{
 const r=await simulate({hosts:[host],ticks:4,probeAnswer:()=>({status:'observed',inventory:{hostname:'imposter',os:'Linux'}})});
 const DIFFERS='Host identity differs from enrollment.';
 assert.deepEqual(r.times('probe floor'),[0,30,90]);
 const rows=r.writes.map(w=>w.value.hosts[0]);
 assert.equal(rows.length,4);
 for(const row of rows){assert.equal(row.status,'unavailable');assert.equal('inventory' in row,false);assert.equal(row.workerReady,false);}
 assert.deepEqual(rows.map(x=>x.reason),[DIFFERS,DIFFERS,DIFFERS+retryTail(T0+90000,2),DIFFERS]);
 assert.deepEqual(rows.map(x=>x.observedAt),[T0,T0+30000,T0+30000,T0+90000]);
});
test('L6 24 simulated hours of permanent refusal: exactly 8 attempts in the first hour and 4 in every later hour, per target',async()=>{
 const r=await simulate({hosts:[host],workers:[worker],ticks:2880,probeOk:()=>false,askOk:()=>false});
 const expected=[8,...Array(23).fill(4)];
 for(const target of ['probe floor','ask floor/super-worker-02']){
  const hours=Array(24).fill(0);for(const t of r.times(target))hours[Math.floor(t/3600)]++;
  assert.deepEqual(hours,expected,target);
  assert.ok(hours[0]<=9&&hours.slice(1).every(n=>n<=4),target);
  assert.equal(r.times(target).length,100,target);
 }
});
test('L6 a drifting loop (a 30 s sleep and a 1 s publish) over 24 simulated hours of refusal stays within the bound, per target',async()=>{
 const day=86400,ticks=Math.ceil(day/31);
 const r=await simulate({hosts:[host],workers:[worker],ticks,probeOk:()=>false,askOk:()=>false,publishMs:1000});
 const last=r.writes[r.writes.length-1].at;
 assert.equal(r.writes.length,ticks);assert.ok(last<day&&last+31>=day,String(last));
 for(const target of ['probe floor','ask floor/super-worker-02']){
  const times=r.times(target),hours=Array(24).fill(0);
  for(const t of times)hours[Math.floor(t/3600)]++;
  assert.ok(hours[0]<=9,target+' first hour: '+hours[0]);
  for(let h=1;h<24;h++)assert.ok(hours[h]<=4,target+' hour '+h+': '+hours[h]);
  assert.ok(times.length<=100,target+' in 24 h: '+times.length);
  assert.ok(hours.every(n=>n>=1),target+' is still retried in every hour: '+hours.join(','));
  for(let j=5;j+1<times.length;j++)assert.ok(times[j+1]-times[j]>=900,target+' capped attempts at '+times[j]+' and '+times[j+1]+' s');
 }
});
test('L7 healthy targets are attempted on every tick and each snapshot is byte for byte what collect gives',async()=>{
 const hosts=[host,{...host,id:'second',label:'Second host',hostname:'cd-floor-02',target:'cd-floor-02'}];
 const workers=[worker,{...worker,host:'second',guest:'super-worker-03'}];
 const ledger=[{host:'floor',guest:'super-worker-02',id:'fc-'+'a'.repeat(32),state:'completed',verdict:'pass',at:50}];
 const r=await simulate({hosts,workers,ticks:5,ledger});
 const every=[0,30,60,90,120];
 for(const target of ['probe floor','probe second','ask floor/super-worker-02','ask second/super-worker-03'])assert.deepEqual(r.times(target),every,target);
 assert.equal(r.writes.length,5);
 for(const w of r.writes)assert.equal(w.text,JSON.stringify(await collect(hosts,healthy,()=>T0+w.at*1000,workers,async()=>answer,ledger)));
 assert.deepEqual(r.logs,[]);
});
test('L8 --once is one collect and one publish: one tick writes the bytes of collect once and never sleeps',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'fleet-'));
 try{
  const file=join(dir,'snapshot');let sleeps=0;const ask=async()=>answer;
  await run({hosts:[host],workers:[worker],output:file,inspect:healthy,ask,now:()=>T0,sleep:async()=>{sleeps++;},ledger:async()=>[],log:()=>{},ticks:1});
  assert.equal(sleeps,0);
  assert.equal(await readFile(file,'utf8'),JSON.stringify(await collect([host],healthy,()=>T0,[worker],ask,[])));
 }finally{await rm(dir,{recursive:true,force:true});}
});
test('L8 the command line reads CONFIG OUTPUT [--once] [--checks CHECKS_CONFIG] as before',()=>{
 assert.deepEqual(commandLine(['--once','hosts.json','snapshot.json']),{config:'hosts.json',output:'snapshot.json',once:true,checks:null});
 assert.deepEqual(commandLine(['hosts.json','snapshot.json','--checks','checks.json']),{config:'hosts.json',output:'snapshot.json',once:false,checks:'checks.json'});
 assert.deepEqual(commandLine(['hosts.json','snapshot.json','--once','--checks','checks.json']),{config:'hosts.json',output:'snapshot.json',once:true,checks:'checks.json'});
 assert.deepEqual(commandLine(['--checks','checks.json','hosts.json','snapshot.json']),{config:'hosts.json',output:'snapshot.json',once:false,checks:'checks.json'});
 for(const args of [[],['--once'],['hosts.json','--checks','checks.json']])assert.throws(()=>commandLine(args),{message:'Usage: fleet-collector.mjs CONFIG OUTPUT [--once] [--checks CHECKS_CONFIG]'});
});
test('L8 a reason never exceeds 300 characters, and a cut reason still names the next attempt',async()=>{
 const long='x'.repeat(1000);
 let state={};for(const at of [T0,T0+30000])state=schedule(state,at,[{key:'k',ok:false,reason:long,seenAt:at}]);
 const text=retryReason(state.k);
 assert.ok(text.length<=300,String(text.length));assert.ok(text.endsWith(retryTail(T0+90000,2)),text);
 const r=await simulate({hosts:[host],workers:[worker],ticks:3,askOk:()=>false,refusal:long});
 const w=r.writes[2].value.hosts[0].workers[0];
 assert.equal(w.ready,false);assert.ok(w.reason.length<=300,String(w.reason.length));assert.ok(w.reason.endsWith(retryTail(T0+90000,2)),w.reason);
 for(const {value} of r.writes)for(const h of value.hosts){assert.ok(h.reason.length<=300);for(const x of h.workers)assert.ok(x.reason.length<=300);}
});
test('L8 a backoff reason fits 300 UTF-8 bytes, keeps the retry text whole and never splits a character',async()=>{
 for(const [refusal,bytes] of [['é'.repeat(150),2],['😀'.repeat(100),4]]){
  const r=await simulate({hosts:[host],workers:[worker],ticks:3,askOk:()=>false,refusal});
  assert.equal(r.writes[1].value.hosts[0].workers[0].ready,false);
  const w=r.writes[2].value.hosts[0].workers[0],tail=retryTail(T0+90000,2);
  assert.equal(w.ready,false);assert.equal(w.checkedAt,T0+30000);
  assert.ok(Buffer.byteLength(w.reason,'utf8')<=300,String(Buffer.byteLength(w.reason,'utf8')));
  assert.ok(w.reason.endsWith(tail),w.reason);
  assert.equal(Buffer.from(w.reason,'utf8').toString('utf8'),w.reason);
  assert.equal(w.reason,[...refusal].slice(0,Math.floor((300-Buffer.byteLength(tail,'utf8'))/bytes)).join('')+tail);
 }
 const tail=retryTail(T0+30000,1);
 for(const [reason,kept] of [['x'.repeat(258)+'😀','x'.repeat(258)],['a\ud83d','a�'],['\ude00b','�b']]){
  const text=retryReason({failures:1,dueAt:T0+30000,reason,seenAt:T0});
  assert.equal(text,kept+tail);
  assert.ok(Buffer.byteLength(text,'utf8')<=300,String(Buffer.byteLength(text,'utf8')));
  assert.equal(Buffer.from(text,'utf8').toString('utf8'),text);
 }
});
