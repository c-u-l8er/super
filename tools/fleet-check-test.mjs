import test from 'node:test';import assert from 'node:assert/strict';import {mkdtemp,mkdir,writeFile,readFile} from 'node:fs/promises';import {execFileSync} from 'node:child_process';import {join} from 'node:path';
import {capture,checkedReceipt,hash,run,atomic,FILES} from './fleet/check-client.mjs';
import {supportedTarget,transport,WORKER_TABLE} from './fleet/check-client.mjs';
const bind={world:['world',1],task:'dt_1',revision:2};
async function repo(){const root=await mkdtemp('/tmp/fleet-check-');execFileSync('git',['init','-q',root]);for(const p of FILES){await mkdir(join(root,p,'..'),{recursive:true});await writeFile(join(root,p),'// committed\n');}execFileSync('git',['add','.'],{cwd:root});execFileSync('git',['-c','user.name=Test','-c','user.email=test@example.invalid','commit','-qm','test'],{cwd:root});return root;}
function result(r){return {schema:'super-fleet-receipt@1',id:r.id,binding:r.binding,snapshot:r.snapshot,requestSha256:hash(JSON.stringify(r)),advisory:true,state:'completed',verdict:'pass',exitCode:0,timedOut:false,output:'tests passed',omittedBytes:0,nodeSha256:'a'.repeat(64)};}
// T49: the law cases live once, in cockpit/src/fleet_checks.rs (LAW_CASES); L2 and L4 run the same cases as L1.
const RUST=new URL('../cockpit/src/fleet_checks.rs',import.meta.url);
const FIELDS=['host','guest','target','port','jumpTarget','jumpPort','hostKeyAlias','command'];
const STATUS={operation:'status',id:'fc-'+'a'.repeat(32)};
const GUEST_UNAVAILABLE='Guest response unavailable; reconcile the same request';
async function lawCases(){const m=/const LAW_CASES: &str = r##"([\s\S]*?)"##;/.exec(await readFile(RUST,'utf8'));assert.ok(m,'LAW_CASES is missing from fleet_checks.rs');return JSON.parse(m[1]);}
function lawRow(cases,spec){const row=structuredClone(cases.rows[spec.base]);for(const [key,value] of Object.entries(spec.set??{})){const parts=key.split('.'),last=parts.pop();parts.reduce((at,p)=>at[p],row)[last]=structuredClone(value);}if(spec.unset)delete row[spec.unset];return row;}
const accepts=row=>{try{supportedTarget(row);return true;}catch(e){assert.equal(e.message,'Unsupported worker configuration.');return false;}};
// A stand-in for execFile: it records the call and imitates execFile's timeout and maxBuffer on a simulated elapsed
// time (ms); nothing waits and no process or socket is opened.
function fakeSpawn({stdout='{"id":"fc-answer"}',code=0,ms=1}={}){
 const calls=[];
 const spawn=(program,args,options,callback)=>{
  const call={program,args,options,input:undefined};calls.push(call);
  setImmediate(()=>{
   const limit=options?.maxBuffer??1024*1024;
   if(options?.timeout>0&&ms>=options.timeout)callback(Object.assign(Error('killed'),{killed:true,signal:options.killSignal??'SIGTERM'}),'');
   else if(Buffer.byteLength(stdout)>limit)callback(Object.assign(Error('maxBuffer exceeded'),{code:'ERR_CHILD_PROCESS_STDIO_MAXBUFFER'}),stdout.slice(0,limit));
   else if(code!==0)callback(Object.assign(Error('exit '+code),{code}),stdout);
   else callback(null,stdout);
  });
  return {stdin:{on(){},end(data){call.input=String(data);}}};
 };
 spawn.calls=calls;return spawn;
}
const DIRECT=(target,knownHosts,identityFile)=>['-F','/dev/null','-T','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes','-o','ForwardAgent=no','-o','ForwardX11=no','-o','ClearAllForwardings=yes','-o','ControlMaster=no','-o','ControlPath=none','-o','ConnectTimeout=6','-o','ConnectionAttempts=1','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=2','-o','UserKnownHostsFile='+knownHosts,'-i',identityFile,target,'super-fleet-check'];
const JUMP=(guestId,guestHosts,jumpId,jumpHosts)=>['-F','/dev/null','-T','-p','2222','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes','-o','ForwardAgent=no','-o','ClearAllForwardings=yes','-o','HostKeyAlias=super-worker-02','-o','UserKnownHostsFile='+guestHosts,'-o','ConnectTimeout=5','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=2','-i',guestId,'-o','ProxyCommand=/usr/bin/ssh -F /dev/null -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -o ForwardAgent=no -o UserKnownHostsFile='+jumpHosts+' -o ConnectTimeout=5 -i '+jumpId+' -p 22 -W 127.0.0.1:2222 travis@192.168.88.254','fleet@127.0.0.1','super-fleet-check'];
const EXPECTED=[DIRECT('root@192.168.1.69','/private/hosts','/private/a'),DIRECT('root@192.168.88.252','/private/locuchest_known_hosts','/private/a'),DIRECT('root@192.168.1.71','/private/hosts','/private/b'),JUMP('/private/guest_ed25519','/private/guest_known_hosts','/private/super-fleet-jump','/private/jump_known_hosts')];
// A config whose every field answers its first read truthfully and every later read with a root target or a hostile path.
const POISON={string:'root@192.168.88.66',number:2223,object:{target:'root@192.168.88.66',port:22,identityFile:'/tmp/x',knownHosts:'/tmp/x'}};
function readOnce(value){const out={};for(const [k,v] of Object.entries(value)){const first=v&&typeof v==='object'?readOnce(v):v;let reads=0;Object.defineProperty(out,k,{enumerable:true,get:()=>reads++?POISON[typeof v]:first});}return out;}
test('capture uses exact committed files and excludes dirty text',async()=>{const p=await repo();await writeFile(join(p,FILES[0]),'dirty');const r=capture(p,bind,'fc-'+'a'.repeat(32));assert.equal(Buffer.from(r.files[0].body,'base64').toString(),'// committed\n');assert.deepEqual(r.files.map(f=>f.path),FILES);assert.equal(r.binding.task,'dt_1');});
test('remote success cannot cross task, source, request or outcome identities',async()=>{const r=capture(await repo(),bind,'fc-'+'a'.repeat(32));assert.equal(checkedReceipt(result(r),r).verdict,'pass');for(const patch of [{id:'other'},{snapshot:'wrong'},{binding:{...r.binding,revision:3}},{requestSha256:'wrong'},{advisory:false},{exitCode:1},{timedOut:true}])assert.throws(()=>checkedReceipt({...result(r),...patch},r));});
test('lost response is reconciled by status only, and start cannot repeat',async()=>{const p=await repo(),r=capture(p,bind,'fc-'+'a'.repeat(32)),dir=await mkdtemp('/tmp/fleet-ledger-');await atomic(join(dir,'request.json'),r);await atomic(join(dir,'record.json'),{id:r.id,state:'prepared'});await atomic(join(dir,'transport.json'),{});let sends=[];const send=async(_,m)=>{sends.push(m.operation);if(m.operation==='start')throw Error('lost');return result(r);};assert.equal((await run('start',dir,send)).state,'unknown');assert.equal((await run('status',dir,send)).verdict,'pass');await assert.rejects(run('start',dir,send));assert.deepEqual(sends,['start','status']);assert.equal(JSON.parse(await readFile(join(dir,'record.json'))).verdict,'pass');});
test('missing remote receipt stays unknown without fabricating success',async()=>{const r=capture(await repo(),bind,'fc-'+'a'.repeat(32));assert.equal(checkedReceipt({id:r.id,state:'unknown'},r).state,'unknown');assert.throws(()=>checkedReceipt({id:r.id,state:'completed'},r));});
test('bhyve request and receipt retain their own destination',async()=>{const root=await repo(),id='fc-'+'d'.repeat(32),a=capture(root,bind,id),b=capture(root,bind,id,{host:'cd-floor-01',guest:'super-worker-02'});assert.equal(b.binding.host,'cd-floor-01');assert.equal(b.binding.guest,'super-worker-02');assert.equal(checkedReceipt(result(b),b).verdict,'pass');assert.throws(()=>checkedReceipt(result(a),b));assert.throws(()=>capture(root,bind,id,{host:'locuchest',guest:'super-worker-02'}));});
test('L2 supportedTarget gives the same answer as configurations() on every shared law case',async()=>{
 const cases=await lawCases();let singles=0;
 for(const c of cases.cases){
  const rows=c.rows.map(s=>lawRow(cases,s));
  if(rows.length===1){singles++;assert.equal(accepts(rows[0]),c.ok,JSON.stringify(c));}
  else if(c.ok)for(const row of rows)assert.equal(accepts(row),true,JSON.stringify(c));
 }
 assert.ok(singles>=50);
});
test('L3 the Rust and JavaScript worker tables agree field by field',async()=>{
 const src=await readFile(RUST,'utf8');
 const body=/const SUPPORTED_WORKERS: \[[^\]]*\] = \[([\s\S]*?)\];/.exec(src);assert.ok(body,'SUPPORTED_WORKERS is missing from fleet_checks.rs');
 const rust=[...body[1].matchAll(/\(([^()]*)\)/g)].map(m=>[...m[1].matchAll(/"([^"\\]*)"|(\d+)/g)].map(f=>f[1]!==undefined?f[1]:Number(f[2])));
 assert.equal(rust.length,4);
 assert.ok(Object.isFrozen(WORKER_TABLE)&&WORKER_TABLE.every(r=>Object.isFrozen(r)));
 assert.deepEqual(WORKER_TABLE.map(r=>{assert.deepEqual(Object.keys(r),FIELDS);return FIELDS.map(k=>r[k]);}),rust);
});
test('L4 transport refuses an unsupported row with its message and spawns nothing',async()=>{
 const cases=await lawCases();
 const refused=[undefined,null,{},[],'root@192.168.88.252',...cases.cases.filter(c=>!c.ok&&c.rows.length===1).map(c=>lawRow(cases,c.rows[0]))];
 assert.ok(refused.length>=50);
 for(const row of refused){const spawn=fakeSpawn();await assert.rejects(transport(row,STATUS,spawn),{message:'Unsupported worker configuration.'});assert.equal(spawn.calls.length,0,JSON.stringify(row));}
});
test('L6 each supported row spawns exactly its specified ssh argument vector',async()=>{
 const cases=await lawCases();assert.equal(cases.rows.length,4);
 for(const [i,row] of cases.rows.entries()){
  assert.deepEqual(supportedTarget(row),EXPECTED[i]);
  const spawn=fakeSpawn();assert.deepEqual(await transport(row,STATUS,spawn),{id:'fc-answer'});
  assert.equal(spawn.calls.length,1);const [call]=spawn.calls;
  assert.equal(call.program,'/usr/bin/ssh');assert.deepEqual(call.args,EXPECTED[i]);assert.equal(call.input,JSON.stringify(STATUS));
  if(i<3)assert.deepEqual(call.options,{timeout:60000,killSignal:'SIGKILL',maxBuffer:98304});
 }
});
test('L6 the jump vector takes only its four checked paths from the config and names no root',async()=>{
 const cases=await lawCases();
 const moved=lawRow(cases,{base:3,set:{identityFile:'/keys/g',knownHosts:'/keys/gh','jump.identityFile':'/keys/j','jump.knownHosts':'/keys/jh'}});
 assert.deepEqual(supportedTarget(moved),JUMP('/keys/g','/keys/gh','/keys/j','/keys/jh'));
 for(const args of [supportedTarget(cases.rows[3]),supportedTarget(moved)]){assert.ok(!args.some(a=>a.includes('root')));assert.equal(args.filter(a=>a.startsWith('ProxyCommand=')).length,1);}
});
test('L6 the vector comes from one reading of the config, never a later one',async()=>{
 const cases=await lawCases();
 for(const [i,row] of cases.rows.entries()){
  assert.deepEqual(supportedTarget(readOnce(row)),EXPECTED[i]);
  const spawn=fakeSpawn();await transport(readOnce(row),STATUS,spawn);assert.deepEqual(spawn.calls[0].args,EXPECTED[i]);
 }
});
test('L7 a malformed or oversized guest message is refused before spawning',async()=>{
 const row=(await lawCases()).rows[3],room=196608-JSON.stringify({operation:'start',request:''}).length;
 const bad=[undefined,null,[],'status',{},{operation:'run',id:'x'},{operation:'start'},{operation:'status'},{operation:'start',request:{},id:'x'},{operation:'status',id:'x',request:{}},{operation:'status',id:'x',extra:1},{operation:'start',request:undefined},{operation:'start',request:'x'.repeat(room+1)}];
 for(const message of bad){const spawn=fakeSpawn();await assert.rejects(transport(row,message,spawn));assert.equal(spawn.calls.length,0,String(JSON.stringify(message)).slice(0,80));}
 const spawn=fakeSpawn();await transport(row,{operation:'start',request:'x'.repeat(room)},spawn);
 assert.equal(spawn.calls.length,1);assert.equal(Buffer.byteLength(spawn.calls[0].input),196608);
});
test('L7 a non-zero exit, an answer over 98,304 bytes or a call past 55 s reads as unavailable',async()=>{
 const row=(await lawCases()).rows[3],answer='{"id":"fc-answer"}';
 for(const fake of [fakeSpawn({stdout:answer,code:1}),fakeSpawn({stdout:answer+' '.repeat(98305-answer.length)}),fakeSpawn({stdout:answer,ms:55001})]){await assert.rejects(transport(row,STATUS,fake),{message:GUEST_UNAVAILABLE});assert.equal(fake.calls.length,1);}
 for(const fake of [fakeSpawn({stdout:answer+' '.repeat(98304-answer.length)}),fakeSpawn({stdout:answer,ms:54999})])assert.deepEqual(await transport(row,STATUS,fake),{id:'fc-answer'});
});
test('L7 the guest call is bounded as the root bridge bounded it',async()=>{
 const spawn=fakeSpawn();await transport((await lawCases()).rows[3],STATUS,spawn);
 assert.deepEqual(spawn.calls[0].options,{timeout:55000,killSignal:'SIGKILL',maxBuffer:98304});
});
test('L7 an unavailable guest call leaves the request unknown, never a result',async()=>{
 const cases=await lawCases(),id='fc-'+'e'.repeat(32),r=capture(await repo(),bind,id,{host:'cd-floor-01',guest:'super-worker-02'}),pass=JSON.stringify(result(r));
 const attempt=async fake=>{const dir=await mkdtemp('/tmp/fleet-guest-');await atomic(join(dir,'request.json'),r);await atomic(join(dir,'record.json'),{id,state:'prepared'});await atomic(join(dir,'transport.json'),cases.rows[3]);return run('status',dir,(config,message)=>transport(config,message,fake));};
 assert.equal((await attempt(fakeSpawn({stdout:pass}))).verdict,'pass');
 for(const fake of [fakeSpawn({stdout:pass,code:1}),fakeSpawn({stdout:pass+' '.repeat(98305)}),fakeSpawn({stdout:pass,ms:55001})]){const record=await attempt(fake);assert.equal(record.state,'unknown');assert.equal(record.verdict,undefined);assert.equal(fake.calls.length,1);}
});
