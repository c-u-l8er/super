// One-shot host inventory over an already trusted SSH connection. No enrollment.
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
printf 'end=super-host-probe@1\n'
`;
export function sshArguments(target){
 if(typeof target!=='string'||target.length>253||! /^(?:[a-zA-Z0-9_][a-zA-Z0-9_.-]*@)?[a-zA-Z0-9][a-zA-Z0-9_.-]*$/.test(target))throw Error('Use a configured SSH alias or user@hostname.');
 return ['-T','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=6','-o','ConnectionAttempts=1','-o','ForwardAgent=no','-o','ForwardX11=no','-o','ClearAllForwardings=yes','-o','ControlMaster=no','-o','ControlPath=none',target,'sh -c '+"'"+script.replaceAll("'","'\\''")+"'"];
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
 return {hostname:fields.hostname,os:fields.os,release:fields.release,arch:fields.arch,user:fields.user,logicalCpus:Number(fields.cpus),memoryBytes:Number(fields.memory_bytes),tools};
}
export async function probe(target,run=execute){
 const args=sshArguments(target),started=Date.now();
 try{
  const {stdout}=await run('ssh',args,{timeout:12000,killSignal:'SIGKILL',maxBuffer:16384,encoding:'utf8'});
  return {schema:'super-host-observation@1',target,observedAt:new Date().toISOString(),durationMs:Date.now()-started,status:'observed',inventory:parseInventory(stdout),workerReady:false};
 }catch(error){
  return {schema:'super-host-observation@1',target,observedAt:new Date().toISOString(),durationMs:Date.now()-started,status:'unavailable',reason:String(error.stderr||error.message).slice(0,1000),workerReady:false};
 }
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 try{if(process.argv.length!==3)throw Error('Usage: node tools/fleet-probe.mjs SSH_ALIAS');const result=await probe(process.argv[2]);console.log(JSON.stringify(result,null,2));if(result.status!=='observed')process.exitCode=1;}catch(e){console.error(e.message);process.exitCode=2;}
}
