// Native-only check transport. The page cannot supply commands, paths or SSH options.
import {createHash} from 'node:crypto';
import {execFile,execFileSync} from 'node:child_process';
import {readFile,writeFile,rename,open,mkdir,readdir,unlink} from 'node:fs/promises';
import {join,isAbsolute} from 'node:path';
import {pathToFileURL} from 'node:url';
export const FILES=['cockpit/ui/task-activity.js','tools/fleet-probe.mjs','tools/fleet-probe-test.mjs','tools/task-activity-test.mjs'];
export const hash=b=>createHash('sha256').update(b).digest('hex');
const assert=(ok,msg)=>{if(!ok)throw Error(msg);};
// The supported workers, field for field the same rows as SUPPORTED_WORKERS in cockpit/src/fleet_checks.rs (law L3).
// jumpTarget '' and jumpPort 0 mean a direct row; command '' means the worker's own forced command decides.
export const WORKER_TABLE=Object.freeze([
 Object.freeze({host:'locuchest',guest:'100',target:'root@192.168.1.69',port:22,jumpTarget:'',jumpPort:0,hostKeyAlias:'',command:''}),
 Object.freeze({host:'locuchest',guest:'100',target:'root@192.168.88.252',port:22,jumpTarget:'',jumpPort:0,hostKeyAlias:'',command:''}),
 Object.freeze({host:'cd-floor-01',guest:'super-worker-02',target:'root@192.168.1.71',port:22,jumpTarget:'',jumpPort:0,hostKeyAlias:'',command:''}),
 Object.freeze({host:'cd-floor-01',guest:'super-worker-02',target:'fleet@127.0.0.1',port:2222,jumpTarget:'travis@192.168.88.254',jumpPort:22,hostKeyAlias:'super-worker-02',command:'super-fleet-check'}),
]);
const UNSUPPORTED='Unsupported worker configuration.';
// The root bridge's bounds (tools/fleet/bhyve-bridge.py), applied here to the jump row.
const GUEST_MESSAGE_LIMIT=196608,ANSWER_LIMIT=98304,GUEST_TIMEOUT=55000;
const GUEST_UNAVAILABLE='Guest response unavailable; reconcile the same request';
const DIRECT_KEYS=['host','guest','target','port','identityFile','knownHosts'];
const JUMP_ROW_KEYS=[...DIRECT_KEYS,'jump','hostKeyAlias'];
const JUMP_KEYS=['target','port','identityFile','knownHosts'];
// OpenSSH runs a ProxyCommand through a shell, so every path in a jump row matches this.
const JUMP_PATH=/^\/[A-Za-z0-9._\/-]{1,512}$/;
const own=(o,k)=>Object.prototype.hasOwnProperty.call(o,k);
const plain=v=>v!==null&&typeof v==='object'&&!Array.isArray(v);
const only=(o,keys)=>Object.keys(o).every(k=>keys.includes(k));
// An absent port is 22; a present one must equal the table's integer (never a string).
const portOf=o=>own(o,'port')?o.port:22;
export async function atomic(path,value){
 const tmp=path+'.pending';const f=await open(tmp,'w',0o600);try{await f.writeFile(JSON.stringify(value));await f.sync();}finally{await f.close();}await rename(tmp,path);
 const dir=await open(join(path,'..'),'r');try{await dir.sync();}finally{await dir.close();}
}
export function destination(value){
 assert(value&&(value.host==='locuchest'&&value.guest==='100'||value.host==='cd-floor-01'&&value.guest==='super-worker-02'),'Unsupported check destination.');return {host:value.host,guest:value.guest};
}
// The one check: the SSH argument vector from the matched table row and the config's checked paths only, or a refusal.
// The config is read exactly once; nothing after this line reads it again.
export function supportedTarget(config){
 let c;try{c=JSON.parse(JSON.stringify(config));}catch{c=undefined;}
 assert(plain(c),UNSUPPORTED);
 const row=WORKER_TABLE.find(r=>c.host===r.host&&c.guest===r.guest&&c.target===r.target&&portOf(c)===r.port&&(r.jumpTarget===''?only(c,DIRECT_KEYS):only(c,JUMP_ROW_KEYS)&&(!own(c,'hostKeyAlias')||c.hostKeyAlias===r.hostKeyAlias)&&plain(c.jump)&&only(c.jump,JUMP_KEYS)&&c.jump.target===r.jumpTarget&&portOf(c.jump)===r.jumpPort));
 assert(row,UNSUPPORTED);
 if(row.jumpTarget===''){
  assert([c.identityFile,c.knownHosts].every(p=>typeof p==='string'&&isAbsolute(p)&&!p.includes('\0')),UNSUPPORTED);
  return ['-F','/dev/null','-T','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes','-o','ForwardAgent=no','-o','ForwardX11=no','-o','ClearAllForwardings=yes','-o','ControlMaster=no','-o','ControlPath=none','-o','ConnectTimeout=6','-o','ConnectionAttempts=1','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=2','-o','UserKnownHostsFile='+c.knownHosts,'-i',c.identityFile,row.target,'super-fleet-check'];
 }
 assert([c.identityFile,c.knownHosts,c.jump.identityFile,c.jump.knownHosts].every(p=>typeof p==='string'&&JUMP_PATH.test(p)),UNSUPPORTED);
 const address=row.target.slice(row.target.indexOf('@')+1);
 // -W opens only the permitted tunnel; the jump account's forced command never runs.
 const proxy=['/usr/bin/ssh','-F','/dev/null','-T','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes','-o','ForwardAgent=no','-o','UserKnownHostsFile='+c.jump.knownHosts,'-o','ConnectTimeout=5','-i',c.jump.identityFile,'-p',String(row.jumpPort),'-W',address+':'+row.port,row.jumpTarget].join(' ');
 return ['-F','/dev/null','-T','-p',String(row.port),'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes','-o','ForwardAgent=no','-o','ClearAllForwardings=yes','-o','HostKeyAlias='+row.hostKeyAlias,'-o','UserKnownHostsFile='+c.knownHosts,'-o','ConnectTimeout=5','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=2','-i',c.identityFile,'-o','ProxyCommand='+proxy,row.target,row.command];
}
export function capture(repository,binding,id,target={host:'locuchest',guest:'100'}){
 const selected=destination(target);
 const env={PATH:'/usr/bin:/bin',LANG:'C.UTF-8',GIT_CONFIG_NOSYSTEM:'1',GIT_CONFIG_GLOBAL:'/dev/null',GIT_OPTIONAL_LOCKS:'0'};
 const git=args=>execFileSync('/usr/bin/git',['-c','core.fsmonitor=false','-c','core.hooksPath=/dev/null',...args],{cwd:repository,env,timeout:10000,maxBuffer:65536});
 const head=git(['rev-parse','--verify','HEAD']).toString().trim();assert(/^[a-f0-9]{40,64}$/.test(head),'A saved source commit is required.');
 const files=FILES.map(path=>{const entry=git(['ls-tree',head,'--',path]).toString();assert(/^100(644|755) blob /.test(entry),'The check requires regular committed source files: '+path);const body=git(['show',head+':'+path]);assert(body.length<=32768,'A check file exceeds 32 KiB.');return {path,body:body.toString('base64'),sha256:hash(body)};});
 return {schema:'super-fleet-request@1',id,binding:{...binding,head,host:selected.host,guest:selected.guest,profile:'super-fleet-behavior@1'},files,snapshot:hash(JSON.stringify(files.map(f=>[f.path,f.sha256])))};
}
export function checkedReceipt(value,request){
 assert(value&&value.id===request.id,'Remote request identity did not match.');
 if(value.state==='unknown'&&!value.schema)return {state:'unknown',reason:'Remote outcome is unavailable. Check this request again; it is never resubmitted.'};
 assert(value.schema==='super-fleet-receipt@1'&&value.advisory===true&&JSON.stringify(value.binding)===JSON.stringify(request.binding)&&value.snapshot===request.snapshot&&value.requestSha256===hash(JSON.stringify(request)),'Remote source or task identity did not match.');
 assert(['reserved','unknown','completed'].includes(value.state),'Invalid remote state.');
 if(value.state==='completed')assert(['pass','fail'].includes(value.verdict)&&Number.isSafeInteger(value.exitCode)&&typeof value.timedOut==='boolean'&&value.verdict===(value.exitCode===0&&!value.timedOut?'pass':'fail')&&typeof value.output==='string'&&Buffer.byteLength(value.output)<=65536&&Number.isSafeInteger(value.omittedBytes)&&value.omittedBytes>=0&&/^[a-f0-9]{64}$/.test(value.nodeSha256),'Invalid remote completion.');
 return {state:value.state==='reserved'?'unknown':value.state,...(value.state==='completed'?{verdict:value.verdict,output:value.output,exitCode:value.exitCode,timedOut:value.timedOut,omittedBytes:value.omittedBytes,nodeSha256:value.nodeSha256}:{}),reason:value.state==='reserved'?'The worker reserved this request; a completed result is not available yet.':value.state==='unknown'?'The worker has no confirmed outcome. This request will not be rerun.':'',startedAt:value.startedAt,finishedAt:value.finishedAt};
}
// The guest message, as the root bridge checked it: exactly {operation:'start',request} or {operation:'status',id},
// at most 196,608 bytes of the text actually sent.
function guestMessage(message){
 let text;try{text=JSON.stringify(message);}catch{}
 assert(typeof text==='string'&&Buffer.byteLength(text)<=GUEST_MESSAGE_LIMIT,'Invalid guest message.');
 const m=JSON.parse(text),keys=plain(m)?Object.keys(m).sort().join(','):'';
 assert(m&&(m.operation==='start'&&keys==='operation,request'||m.operation==='status'&&keys==='id,operation'),'Invalid guest message.');
 return text;
}
export async function transport(config,message,spawn=execFile){
 const args=supportedTarget(config);
 // Only the jump row has a ProxyCommand; the root bridge's bounds apply to it here, before anything is spawned.
 const guest=args.some(a=>a.startsWith('ProxyCommand='));
 const input=guest?guestMessage(message):JSON.stringify(message);
 const lost=guest?GUEST_UNAVAILABLE:'Remote response was lost. Check the saved request status.';
 const incomplete=guest?GUEST_UNAVAILABLE:'Remote response was incomplete. Check the saved request status.';
 return new Promise((resolve,reject)=>{
 const child=spawn('/usr/bin/ssh',args,{timeout:guest?GUEST_TIMEOUT:60000,killSignal:'SIGKILL',maxBuffer:ANSWER_LIMIT},(error,stdout)=>{
  if(error||!(typeof stdout==='string'||Buffer.isBuffer(stdout))||Buffer.byteLength(stdout)>ANSWER_LIMIT){reject(Error(lost));return;}
  try{resolve(JSON.parse(stdout));}catch{reject(Error(incomplete));}
 });
 child.stdin.on('error',()=>{});child.stdin.end(input);
 });
}
export async function run(operation,dir,send=transport){
 const request=JSON.parse(await readFile(join(dir,'request.json'),'utf8')),file=join(dir,'record.json');
 const record=JSON.parse(await readFile(file,'utf8'));
 const config=JSON.parse(await readFile(join(dir,'transport.json'),'utf8'));
 if(operation==='start'){
   // Crash after this durable marker can only be reconciled, never dispatched again.
   const f=await open(join(dir,'sent'),'wx',0o600);await f.sync();await f.close();
   record.state='unknown';record.reason='Awaiting a confirmed remote result. Check status if the connection is interrupted.';await atomic(file,record);
 }
 assert(['start','status'].includes(operation),'Unsupported operation.');
 try{Object.assign(record,checkedReceipt(await send(config,operation==='start'?{operation,request}:{operation:'status',id:request.id}),request));}
 catch{record.state='unknown';record.reason='The remote result could not be confirmed. Check status to retrieve this same request; it will not run twice.';}
 await atomic(file,record);return record;
}
async function main(){
 const [operation,dir,repository]=process.argv.slice(2);
 if(operation==='prepare'){
  const spec=JSON.parse(await readFile(join(dir,'spec.json'),'utf8'));
  const request=capture(repository,spec.binding,spec.id,spec.destination);await atomic(join(dir,'request.json'),request);
  const record={schema:'device-fleet-check@1',createdAt:Date.now(),id:request.id,binding:request.binding,snapshot:request.snapshot,files:FILES,advisory:true,state:'prepared',reason:'Prepared; no remote execution started.'};await atomic(join(dir,'record.json'),record);return record;
 }
 return run(operation,dir);
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)main().then(r=>process.stdout.write(JSON.stringify(r))).catch(e=>{process.stderr.write(e.message);process.exitCode=1;});
