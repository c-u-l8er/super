// One-shot host inventory over an already trusted SSH connection. No enrollment.
// A host observation says what the host IS (OS, capacity, tools, guests); it never
// says whether a Super worker on it answers — that is a separate question the
// collector asks the guest's own check endpoint (fleet-collector.mjs `readiness`).
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {pathToFileURL} from 'node:url';
const execute=promisify(execFile);
const script=`set -eu
export LC_ALL=C
printf 'schema=super-host-probe@1\n'
printf 'hostname=%s\n' "$(hostname)"
printf 'os=%s\n' "$(uname -s)"
printf 'release=%s\n' "$(uname -r)"
printf 'arch=%s\n' "$(uname -m)"
printf 'user=%s\n' "$(id -un)"
case "$(uname -s)" in
 FreeBSD) printf 'cpus=%s\n' "$(sysctl -n hw.ncpu)"; printf 'memory_bytes=%s\n' "$(sysctl -n hw.physmem)";;
 Linux) printf 'cpus=%s\n' "$(getconf _NPROCESSORS_ONLN)"; awk '/^MemTotal:/ {printf "memory_bytes=%.0f\\n", $2*1024}' /proc/meminfo;;
 *) exit 65;;
esac
for tool in git node elixir erl cargo; do
 if command -v "$tool" >/dev/null 2>&1; then printf 'tool_%s=yes\n' "$tool"; else printf 'tool_%s=no\n' "$tool"; fi
done
if command -v bhyve >/dev/null 2>&1; then
 printf 'hypervisor=bhyve\\n'
 json='['; sep=''
 for n in $(ls /dev/vmm 2>/dev/null); do
  case "$n" in *[!A-Za-z0-9_.-]*) continue;; esac
  # A vmm device is a guest that was created; only a bhyve process is a guest that runs.
  # The bracket keeps this shell's own command line out of the match.
  first=$(printf '%s' "$n" | cut -c1); rest=$(printf '%s' "$n" | cut -c2-)
  if pgrep -qf "bhyve: [$first]$rest" 2>/dev/null; then st=running; else st=stopped; fi
  json="$json$sep{\\"id\\":\\"$n\\",\\"label\\":\\"$n\\",\\"status\\":\\"$st\\"}"; sep=','
 done
 printf 'guests_json=%s\\n' "$json]"
fi
printf 'end=super-host-probe@1\n'
`;
export function sshArguments(target,options={}){
 if(typeof target!=='string'||target.length>253||! /^(?:[a-zA-Z0-9_][a-zA-Z0-9_.-]*@)?[a-zA-Z0-9][a-zA-Z0-9_.-]*$/.test(target))throw Error('Use a configured SSH alias or user@hostname.');
 const extra=[];for(const [key,flag] of [['identityFile','-i'],['knownHosts','-o']])if(options[key]){if(typeof options[key]!=='string'||!options[key].startsWith('/')||/[\r\n\0]/.test(options[key]))throw Error('SSH identity paths must be absolute.');extra.push(flag,key==='knownHosts'?'UserKnownHostsFile='+options[key]:options[key]);}
 return [...extra,'-T','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=6','-o','ConnectionAttempts=1','-o','ForwardAgent=no','-o','ForwardX11=no','-o','ClearAllForwardings=yes','-o','ControlMaster=no','-o','ControlPath=none',target,'sh -c '+"'"+script.replaceAll("'","'\\''")+"'"];
}
export function parseInventory(output){
 if(typeof output!=='string'||output.length>16384)throw Error('Host response is too large.');
 const fields=Object.create(null);
 for(const line of output.trimEnd().split('\n')){
  const match=/^([a-z_]+)=([^\r\n\x00-\x1f]*)$/.exec(line);
  if(!match||Object.hasOwn(fields,match[1]))throw Error('Malformed host response.');
  fields[match[1]]=match[2];
 }
 if(fields.schema!=='super-host-probe@1'||fields.end!==fields.schema)throw Error('Incomplete host response.');
 if(!['Linux','FreeBSD'].includes(fields.os))throw Error('Unsupported host OS.');
 for(const key of ['hostname','release','arch','user'])if(!fields[key]||fields[key].length>255)throw Error('Missing host identity.');
 for(const key of ['cpus','memory_bytes'])if(!/^\d+$/.test(fields[key]??'')||!Number.isSafeInteger(Number(fields[key]))||Number(fields[key])<=0)throw Error('Invalid host capacity.');
 const tools={};for(const name of ['git','node','elixir','erl','cargo']){const v=fields['tool_'+name];if(!['yes','no'].includes(v))throw Error('Missing tool observation.');tools[name]=v==='yes';}
 const hypervisor=fields.hypervisor||'none';if(!['none','bhyve','proxmox'].includes(hypervisor))throw Error('Unknown hypervisor.');
 const guests=fields.guests_json?JSON.parse(fields.guests_json):(fields.guest_names||'').split(',').filter(Boolean).map(name=>({id:name,label:name,status:'present'}));
 if(!Array.isArray(guests)||guests.length>24||guests.some(g=>!g||typeof g.id!=='string'||g.id.length>64||typeof g.label!=='string'||g.label.length>100||!['running','stopped','present','unknown'].includes(g.status)))throw Error('Invalid guests.');
 return {hypervisor,guests,hostname:fields.hostname,os:fields.os,release:fields.release,arch:fields.arch,user:fields.user,logicalCpus:Number(fields.cpus),memoryBytes:Number(fields.memory_bytes),tools};
}
export async function probe(target,run=execute,options={}){
 const args=sshArguments(target,options),started=Date.now();
 try{
  const {stdout}=await run('ssh',args,{timeout:12000,killSignal:'SIGKILL',maxBuffer:16384,encoding:'utf8'});
  return {schema:'super-host-observation@1',target,observedAt:new Date().toISOString(),durationMs:Date.now()-started,status:'observed',inventory:parseInventory(stdout)};
 }catch(error){
  return {schema:'super-host-observation@1',target,observedAt:new Date().toISOString(),durationMs:Date.now()-started,status:'unavailable',reason:String(error.stderr||error.message).slice(0,1000)};
 }
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 try{if(process.argv.length!==3)throw Error('Usage: node tools/fleet-probe.mjs SSH_ALIAS');const result=await probe(process.argv[2]);console.log(JSON.stringify(result,null,2));if(result.status!=='observed')process.exitCode=1;}catch(e){console.error(e.message);process.exitCode=2;}
}
