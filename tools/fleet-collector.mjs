// Operator-owned local observer. Never accepts commands or credentials from UI.
//
// Two observations per host, kept apart because they answer different questions:
//   inventory   what the host is (fleet-probe.mjs over the observe key)
//   readiness   whether a configured Super worker on it ANSWERS — the guest's own
//               check endpoint is asked for the status of a request id that cannot
//               exist (`fc-` + 32 zeros); an answer of any state proves the whole
//               path (ssh → hypervisor bridge → guest → endpoint), a refusal or a
//               lost connection proves nothing and reads as not ready.
// `workerReady` is DERIVED from the readiness answers, never written as a constant:
// a host with no configured worker has none, and a worker whose answer is old is
// aged out by Ampd.Fleet on the runtime side.
//
// Backoff (T48). Each host's inventory probe and each configured worker's readiness
// ask is a TARGET with its own failure count, never shared. The loop ticks every 30 s
// and publishes a snapshot on every tick, but contacts only the targets that are DUE:
// after a target's n-th consecutive failure it is next due min(30 s × 2^(n-1), 900 s)
// after that attempt began (30, 60, 120, 240, 480, 900, 900, … s); a success makes it
// due on every tick again. A target that is not due is not contacted at all and
// publishes exactly its last attempt's row, never better: not observed / not ready,
// the last attempt's time (so the runtime ages it to stale) and the last reason naming
// the next attempt. The state is in memory only: a restart starts every target due.
import {readFile,readdir,open,rename} from 'node:fs/promises';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {probe,sshArguments} from './fleet-probe.mjs';
export const PROBE_ID='fc-'+'0'.repeat(32);
export const TICK_MS=30000,BACKOFF_CAP_MS=900000;
// A timer can wake a moment before the wall clock agrees; a target falling due within
// this margin of a tick is attempted on that tick rather than one tick (30 s) late.
// The margin applies only while the delay is below the cap. A retry that starts early
// counts its next delay from that earlier start, so the gain adds up, but only over the
// five delays below the cap (at most 5 s in all). Once the delay is capped, the full
// 900 s from the previous attempt's start is required, with no margin, so capped attempts
// stay at least 900 s apart (at most 4 in any hour) however long each cycle takes.
export const EARLY_MS=1000;
// Ampd.Fleet refuses a reason longer than this many UTF-8 bytes (and with it the snapshot).
export const REASON_BYTES=300;
export function configuration(value){
 if(!Array.isArray(value)||!value.length||value.length>8)throw Error('Configure one to eight hosts.');
 const seen=new Set();return value.map(h=>{
  if(!h||!/^[a-z0-9-]{1,64}$/.test(h.id)||seen.has(h.id))throw Error('Host identifiers must be unique.');seen.add(h.id);
  for(const k of ['label','hostname','nextStep'])if(typeof h[k]!=='string'||!h[k]||h[k].length>(k==='nextStep'?300:100)||/[\x00-\x1f]/.test(h[k]))throw Error('Invalid host description.');
  sshArguments(h.target,h);return {id:h.id,label:h.label,hostname:h.hostname,target:h.target,identityFile:h.identityFile,knownHosts:h.knownHosts,nextStep:h.nextStep};
 });
}
// The check transport's own worker list (fleet-checks config.json): host, guest, target, keys.
export function workerConfiguration(value){
 const rows=value&&Array.isArray(value.workers)?value.workers:[];
 if(rows.length>2)throw Error('Configure at most two workers.');
 return rows.map(w=>{
  if(!w||!/^[a-z0-9-]{1,64}$/.test(w.host)||typeof w.guest!=='string'||!/^[A-Za-z0-9_.-]{1,64}$/.test(w.guest))throw Error('Invalid worker identity.');
  return {host:w.host,guest:w.guest,target:w.target,identityFile:w.identityFile,knownHosts:w.knownHosts};
 });
}
export async function askWorker(config){
 const {transport}=await import('./fleet/check-client.mjs');
 return transport(config,{operation:'status',id:PROBE_ID});
}
// The newest completed check this device ran on that worker, from the device's own
// ledger (cockpit/src/fleet_checks.rs writes <data>/fleet-checks/<world>/<id>/record.json).
export async function lastChecks(dataDir){
 const out=[];
 try{
  for(const world of await readdir(dataDir)){
   let runs=[];try{runs=await readdir(join(dataDir,world));}catch{continue;}
   for(const id of runs){
    if(!/^fc-[a-f0-9]{32}$/.test(id))continue;
    try{const r=JSON.parse(await readFile(join(dataDir,world,id,'record.json'),'utf8'));
     if(r&&r.binding&&typeof r.binding.host==='string'&&typeof r.binding.guest==='string'&&typeof r.state==='string')out.push({host:r.binding.host,guest:r.binding.guest,id:r.id,state:r.state,verdict:typeof r.verdict==='string'?r.verdict:null,at:Number(r.finishedAt||r.createdAt||0)});
    }catch{}
   }
  }
 }catch{}
 return out;
}
export function defaultDataDir(env=process.env){
 const base=env.XDG_DATA_HOME||join(env.HOME||'/nonexistent','.local/share');
 return join(base,'com.computedriven.super.cockpit','fleet-checks');
}
export async function readiness(worker,ask=askWorker,now=Date.now){
 const checkedAt=now();
 try{
  const answer=await ask(worker);
  const ready=!!answer&&typeof answer==='object'&&typeof answer.state==='string'&&answer.id===PROBE_ID;
  return {guest:worker.guest,ready,checkedAt,reason:ready?'':String(answer&&answer.error||'The worker did not answer a status query.').slice(0,300)};
 }catch(e){return {guest:worker.guest,ready:false,checkedAt,reason:String(e.message||e).slice(0,300)};}
}
export async function collect(hosts,inspect=probe,now=Date.now,workers=[],ask=askWorker,ledger=[]){
 const rows=await Promise.all(hosts.map(async h=>{
  const mine=workers.filter(w=>w.host===h.id);
  const [result,answers]=await Promise.all([
   inspect(h.target,undefined,h).catch(()=>({status:'unavailable'})),
   Promise.all(mine.map(w=>readiness(w,ask,now)))
  ]);
  const valid=result.status==='observed'&&result.inventory?.hostname===h.hostname;
  const ws=answers.map(a=>{const last=ledger.filter(l=>l.host===h.id&&l.guest===a.guest).sort((p,q)=>q.at-p.at)[0];return {...a,lastCheck:last?{id:last.id,state:last.state,verdict:last.verdict,at:last.at}:null};});
  return {id:h.id,label:h.label,observedAt:now(),status:valid?'observed':'unavailable',reason:valid?'':result.status==='observed'?'Host identity differs from enrollment.':'Connection check failed. Check the saved SSH connection.',nextStep:h.nextStep,...(valid?{inventory:result.inventory}:{}),workers:ws,workerReady:ws.some(w=>w.ready)};
 }));return {schema:'fleet-snapshot@1',hosts:rows};
}
export async function publish(path,value){
 const tmp=path+'.pending';const f=await open(tmp,'w',0o600);try{await f.writeFile(JSON.stringify(value));await f.sync();}finally{await f.close();}await rename(tmp,path);
}
// The schedule: pure functions of the per-target state, the time and the attempt results.
// state: {[key]:{failures,dueAt,reason,seenAt}}; a target with no entry is healthy (due).
export function hostKey(h){return 'host:'+h.id;}
export function workerKey(w){return 'worker:'+w.host+'/'+w.guest;}
export function backoffDelay(failures){return Math.min(TICK_MS*2**(failures-1),BACKOFF_CAP_MS);}
// Due from EARLY_MS before dueAt while the delay is below the cap; once capped, only from dueAt.
export function due(state,key,at){const s=state[key];if(!s)return true;return at>=s.dueAt-(backoffDelay(s.failures)<BACKOFF_CAP_MS?EARLY_MS:0);}
// at: when this tick's attempts began. results: [{key,ok,reason,seenAt}], one per attempted target.
export function schedule(state,at,results){
 const next={...state};
 for(const r of results){
  if(r.ok){delete next[r.key];continue;}
  const failures=(state[r.key]?.failures||0)+1;
  next[r.key]={failures,dueAt:at+backoffDelay(failures),reason:String(r.reason||''),seenAt:r.seenAt};
 }
 return next;
}
function localClock(ms){const d=new Date(ms),p=n=>String(n).padStart(2,'0');return p(d.getHours())+':'+p(d.getMinutes())+':'+p(d.getSeconds());}
const utf8Bytes=cp=>cp<0x80?1:cp<0x800?2:cp<0x10000?3:4;
// The longest prefix of text that fits in budget UTF-8 bytes, cut only between whole
// characters. A lone surrogate has no UTF-8 form: it is written as U+FFFD, as an encoder
// would, so the result survives a round trip through UTF-8 unchanged.
export function utf8Prefix(text,budget){
 let out='',used=0;
 for(const ch of String(text)){
  const cp=ch.codePointAt(0),lone=cp>=0xd800&&cp<=0xdfff,n=lone?3:utf8Bytes(cp);
  if(used+n>budget)break;
  out+=lone?'�':ch;used+=n;
 }
 return out;
}
// The last failure's reason naming the next attempt. The retry text is kept whole and the
// reason in front of it is cut to the UTF-8 bytes left, so the whole is at most
// REASON_BYTES bytes as Ampd.Fleet counts them.
export function retryReason(entry){
 const tail=` Retrying at ${localClock(entry.dueAt)} (${entry.failures} failed checks).`;
 const reason=utf8Prefix(entry.reason||'',Math.max(0,REASON_BYTES-Buffer.byteLength(tail,'utf8')));
 return reason?reason+tail:tail.slice(1);
}
// One tick: contacts the due targets only and publishes every host. A due target's row is
// exactly what `collect` gives; a target in backoff repeats its last failure, never better.
export async function observe(hosts,state={},{inspect=probe,now=Date.now,workers=[],ask=askWorker,ledger=[]}={}){
 const at=now(),attempts=[];
 const rows=await Promise.all(hosts.map(async h=>{
  const mine=workers.filter(w=>w.host===h.id),hk=hostKey(h),probeDue=due(state,hk,at);
  const [result,answers]=await Promise.all([
   probeDue?inspect(h.target,undefined,h).catch(()=>({status:'unavailable'})):null,
   Promise.all(mine.map(async w=>{
    const k=workerKey(w),s=state[k];
    if(!due(state,k,at))return {guest:w.guest,ready:false,checkedAt:s.seenAt,reason:retryReason(s)};
    const a=await readiness(w,ask,now);attempts.push({key:k,ok:a.ready,reason:a.reason,seenAt:a.checkedAt});return a;
   }))
  ]);
  const ws=answers.map(a=>{const last=ledger.filter(l=>l.host===h.id&&l.guest===a.guest).sort((p,q)=>q.at-p.at)[0];return {...a,lastCheck:last?{id:last.id,state:last.state,verdict:last.verdict,at:last.at}:null};});
  if(!probeDue){const s=state[hk];return {id:h.id,label:h.label,observedAt:s.seenAt,status:'unavailable',reason:retryReason(s),nextStep:h.nextStep,workers:ws,workerReady:ws.some(w=>w.ready)};}
  const valid=result.status==='observed'&&result.inventory?.hostname===h.hostname,observedAt=now();
  const reason=valid?'':result.status==='observed'?'Host identity differs from enrollment.':'Connection check failed. Check the saved SSH connection.';
  attempts.push({key:hk,ok:valid,reason,seenAt:observedAt});
  return {id:h.id,label:h.label,observedAt,status:valid?'observed':'unavailable',reason,nextStep:h.nextStep,...(valid?{inventory:result.inventory}:{}),workers:ws,workerReady:ws.some(w=>w.ready)};
 }));
 return {at,snapshot:{schema:'fleet-snapshot@1',hosts:rows},state:schedule(state,at,attempts),attempts};
}
const wait=ms=>new Promise(r=>setTimeout(r,ms));
// The loop: publishes on every tick, whatever is in backoff. Every collaborator is injectable;
// ticks bounds the run (1 is --once). Each failed attempt and each recovery is traced to log.
export async function run({hosts,workers=[],output,inspect=probe,ask=askWorker,now=Date.now,sleep=wait,ledger=()=>lastChecks(defaultDataDir()),write=publish,log=line=>console.error(line),ticks=Infinity}){
 let state={};
 for(let tick=0;tick<ticks;tick++){
  if(tick)await sleep(TICK_MS);
  const r=await observe(hosts,state,{inspect,now,workers,ask,ledger:await ledger()});
  await write(output,r.snapshot);
  for(const a of r.attempts){
   const s=r.state[a.key],when=new Date(r.at).toISOString();
   if(s)log(`fleet-collector ${when} ${a.key} failed (${s.failures} in a row); next attempt ${new Date(s.dueAt).toISOString()}`);
   else if(state[a.key])log(`fleet-collector ${when} ${a.key} answered after ${state[a.key].failures} failed checks`);
  }
  state=r.state;
 }
 return state;
}
// The command line, parsed exactly as before T48.
export function commandLine(args){
 const once=args.includes('--once');const ci=args.indexOf('--checks');const checks=ci>=0?args[ci+1]:null;
 const positional=args.filter((a,i)=>a!=='--once'&&a!=='--checks'&&i!==ci+1);const [config,output]=positional;
 if(!config||!output)throw Error('Usage: fleet-collector.mjs CONFIG OUTPUT [--once] [--checks CHECKS_CONFIG]');
 return {config,output,once,checks};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 const {config,output,once,checks}=commandLine(process.argv.slice(2));
 const hosts=configuration(JSON.parse(await readFile(config,'utf8')));
 const workers=checks?workerConfiguration(JSON.parse(await readFile(checks,'utf8'))):[];
 await run({hosts,workers,output,ticks:once?1:Infinity,...(once?{log:()=>{}}:{})});
}
