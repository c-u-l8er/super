// Operator-owned local observer. Never accepts commands or credentials from UI.
import {readFile,open,rename} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {probe,sshArguments} from './fleet-probe.mjs';
export function configuration(value){
 if(!Array.isArray(value)||!value.length||value.length>8)throw Error('Configure one to eight hosts.');
 const seen=new Set();return value.map(h=>{
  if(!h||!/^[a-z0-9-]{1,64}$/.test(h.id)||seen.has(h.id))throw Error('Host identifiers must be unique.');seen.add(h.id);
  for(const k of ['label','hostname','nextStep'])if(typeof h[k]!=='string'||!h[k]||h[k].length>(k==='nextStep'?300:100)||/[\x00-\x1f]/.test(h[k]))throw Error('Invalid host description.');
  sshArguments(h.target,h);return {id:h.id,label:h.label,hostname:h.hostname,target:h.target,identityFile:h.identityFile,knownHosts:h.knownHosts,nextStep:h.nextStep};
 });
}
export async function collect(hosts,inspect=probe,now=Date.now){
 const rows=await Promise.all(hosts.map(async h=>{
  let result;try{result=await inspect(h.target,undefined,h);}catch{result={status:'unavailable'};}
  const valid=result.status==='observed'&&result.inventory?.hostname===h.hostname;
  return {id:h.id,label:h.label,observedAt:now(),status:valid?'observed':'unavailable',reason:valid?'':result.status==='observed'?'Host identity differs from enrollment.':'Connection check failed. Check the saved SSH connection.',nextStep:h.nextStep,...(valid?{inventory:result.inventory}:{}),workerReady:false};
 }));return {schema:'fleet-snapshot@1',hosts:rows};
}
export async function publish(path,value){
 const tmp=path+'.pending';const f=await open(tmp,'w',0o600);try{await f.writeFile(JSON.stringify(value));await f.sync();}finally{await f.close();}await rename(tmp,path);
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 const [config,output,once]=process.argv.slice(2);if(!config||!output)throw Error('Usage: fleet-collector.mjs CONFIG OUTPUT [--once]');
 const hosts=configuration(JSON.parse(await readFile(config,'utf8')));
 do{await publish(output,await collect(hosts));if(once==='--once')break;await new Promise(r=>setTimeout(r,30000));}while(true);
}
