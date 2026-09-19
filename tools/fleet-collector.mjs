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
import {readFile,readdir,open,rename} from 'node:fs/promises';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {probe,sshArguments} from './fleet-probe.mjs';
export const PROBE_ID='fc-'+'0'.repeat(32);
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
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 const args=process.argv.slice(2);const once=args.includes('--once');const ci=args.indexOf('--checks');const checks=ci>=0?args[ci+1]:null;
 const positional=args.filter((a,i)=>a!=='--once'&&a!=='--checks'&&i!==ci+1);const [config,output]=positional;
 if(!config||!output)throw Error('Usage: fleet-collector.mjs CONFIG OUTPUT [--once] [--checks CHECKS_CONFIG]');
 const hosts=configuration(JSON.parse(await readFile(config,'utf8')));
 const workers=checks?workerConfiguration(JSON.parse(await readFile(checks,'utf8'))):[];
 do{await publish(output,await collect(hosts,probe,Date.now,workers,askWorker,await lastChecks(defaultDataDir())));if(once)break;await new Promise(r=>setTimeout(r,30000));}while(true);
}
