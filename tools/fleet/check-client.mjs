// Native-only check transport. The page cannot supply commands, paths or SSH options.
import {createHash} from 'node:crypto';
import {execFile,execFileSync} from 'node:child_process';
import {readFile,writeFile,rename,open,mkdir,readdir,unlink} from 'node:fs/promises';
import {join,isAbsolute} from 'node:path';
import {pathToFileURL} from 'node:url';
export const FILES=['cockpit/ui/task-activity.js','tools/fleet-probe.mjs','tools/fleet-probe-test.mjs','tools/task-activity-test.mjs'];
export const hash=b=>createHash('sha256').update(b).digest('hex');
const assert=(ok,msg)=>{if(!ok)throw Error(msg);};
export async function atomic(path,value){
 const tmp=path+'.pending';const f=await open(tmp,'w',0o600);try{await f.writeFile(JSON.stringify(value));await f.sync();}finally{await f.close();}await rename(tmp,path);
 const dir=await open(join(path,'..'),'r');try{await dir.sync();}finally{await dir.close();}
}
export function capture(repository,binding,id){
 const env={PATH:'/usr/bin:/bin',LANG:'C.UTF-8',GIT_CONFIG_NOSYSTEM:'1',GIT_CONFIG_GLOBAL:'/dev/null',GIT_OPTIONAL_LOCKS:'0'};
 const git=args=>execFileSync('/usr/bin/git',['-c','core.fsmonitor=false','-c','core.hooksPath=/dev/null',...args],{cwd:repository,env,timeout:10000,maxBuffer:65536});
 const head=git(['rev-parse','--verify','HEAD']).toString().trim();assert(/^[a-f0-9]{40,64}$/.test(head),'A saved source commit is required.');
 const files=FILES.map(path=>{const entry=git(['ls-tree',head,'--',path]).toString();assert(/^100(644|755) blob /.test(entry),'The check requires regular committed source files: '+path);const body=git(['show',head+':'+path]);assert(body.length<=32768,'A check file exceeds 32 KiB.');return {path,body:body.toString('base64'),sha256:hash(body)};});
 return {schema:'super-fleet-request@1',id,binding:{...binding,head,host:'locuchest',guest:'100',profile:'super-fleet-behavior@1'},files,snapshot:hash(JSON.stringify(files.map(f=>[f.path,f.sha256])))};
}
export function checkedReceipt(value,request){
 assert(value&&value.id===request.id,'Remote request identity did not match.');
 if(value.state==='unknown'&&!value.schema)return {state:'unknown',reason:'Remote outcome is unavailable. Check this request again; it is never resubmitted.'};
 assert(value.schema==='super-fleet-receipt@1'&&value.advisory===true&&JSON.stringify(value.binding)===JSON.stringify(request.binding)&&value.snapshot===request.snapshot&&value.requestSha256===hash(JSON.stringify(request)),'Remote source or task identity did not match.');
 assert(['reserved','unknown','completed'].includes(value.state),'Invalid remote state.');
 if(value.state==='completed')assert(['pass','fail'].includes(value.verdict)&&Number.isSafeInteger(value.exitCode)&&typeof value.timedOut==='boolean'&&value.verdict===(value.exitCode===0&&!value.timedOut?'pass':'fail')&&typeof value.output==='string'&&Buffer.byteLength(value.output)<=65536&&Number.isSafeInteger(value.omittedBytes)&&value.omittedBytes>=0&&/^[a-f0-9]{64}$/.test(value.nodeSha256),'Invalid remote completion.');
 return {state:value.state==='reserved'?'unknown':value.state,...(value.state==='completed'?{verdict:value.verdict,output:value.output,exitCode:value.exitCode,timedOut:value.timedOut,omittedBytes:value.omittedBytes,nodeSha256:value.nodeSha256}:{}),reason:value.state==='reserved'?'The worker reserved this request; a completed result is not available yet.':value.state==='unknown'?'The worker has no confirmed outcome. This request will not be rerun.':'',startedAt:value.startedAt,finishedAt:value.finishedAt};
}
export async function transport(config,message){
 assert(config.host==='locuchest'&&config.guest==='100'&&config.target==='root@192.168.1.69','Unsupported worker configuration.');
 for(const key of ['identityFile','knownHosts'])assert(typeof config[key]==='string'&&isAbsolute(config[key])&&!config[key].includes('\0'),'Invalid transport identity.');
 return new Promise((resolve,reject)=>{
 const child=execFile('/usr/bin/ssh',['-F','/dev/null','-T','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes','-o','ForwardAgent=no','-o','ForwardX11=no','-o','ClearAllForwardings=yes','-o','ControlMaster=no','-o','ControlPath=none','-o','ConnectTimeout=6','-o','ConnectionAttempts=1','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=2','-o','UserKnownHostsFile='+config.knownHosts,'-i',config.identityFile,config.target,'super-fleet-check'],{timeout:60000,killSignal:'SIGKILL',maxBuffer:98304},(error,stdout)=>{if(error)reject(Error('Remote response was lost. Check the saved request status.'));else{try{resolve(JSON.parse(stdout));}catch{reject(Error('Remote response was incomplete. Check the saved request status.'));}}});
 child.stdin.on('error',()=>{});child.stdin.end(JSON.stringify(message));
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
  const request=capture(repository,spec.binding,spec.id);await atomic(join(dir,'request.json'),request);
  const record={schema:'device-fleet-check@1',createdAt:Date.now(),id:request.id,binding:request.binding,snapshot:request.snapshot,files:FILES,advisory:true,state:'prepared',reason:'Prepared; no remote execution started.'};await atomic(join(dir,'record.json'),record);return record;
 }
 return run(operation,dir);
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)main().then(r=>process.stdout.write(JSON.stringify(r))).catch(e=>{process.stderr.write(e.message);process.exitCode=1;});
