// Local human-operated runner; not a Carrier job or an acceptance receipt.
import {createHash} from 'node:crypto';
import {spawn,execFileSync} from 'node:child_process';
import {constants as F} from 'node:fs';
import {mkdir,mkdtemp,readFile,writeFile,rename,rm,realpath,open,lstat,cp,readdir,readlink} from 'node:fs/promises';
import {resolve,dirname,join,relative,sep} from 'node:path';

const hash=b=>createHash('sha256').update(b).digest('hex');
const maxFiles=1024,maxFile=2*1024*1024,maxBytes=32*1024*1024,maxOutput=128*1024;
const env={PATH:'/usr/bin:/bin',LANG:'C.UTF-8',GIT_CONFIG_NOSYSTEM:'1',GIT_CONFIG_GLOBAL:'/dev/null',GIT_OPTIONAL_LOCKS:'0',GIT_TERMINAL_PROMPT:'0'};
const git=(root,args)=>execFileSync('/usr/bin/git',['-c','core.fsmonitor=false','-c','core.hooksPath=/dev/null',...args],{cwd:root,env,encoding:'utf8',timeout:10000,maxBuffer:1024*1024});
function pathOK(path){return typeof path==='string'&&path.length<=1024&&!path.includes('\0')&&!path.includes('\\')&&path.split('/').every(p=>p&&!['.','..','.git'].includes(p));}
function assert(ok,message){if(!ok)throw Error(message);}
async function atomic(path,value){const temp=path+'.tmp';await writeFile(temp,JSON.stringify(value,null,2)+'\n',{flag:'wx',mode:0o600});await rename(temp,path);}
async function exactFile(root,path){
  assert(pathOK(path),'Invalid snapshot path.');
  const target=join(root,path);
  const chain=[];for(let p=target;p!==root;p=dirname(p))chain.unshift(p);for(const p of chain)assert(!(await lstat(p)).isSymbolicLink(),'Symlinks are not supported in a test snapshot.');
  const fd=await open(target,F.O_RDONLY|F.O_NOFOLLOW|F.O_NONBLOCK);
  try{
    assert(await realpath('/proc/self/fd/'+fd.fd)===target,'The source path changed during capture.');
    const before=await fd.stat();assert(before.isFile()&&before.size<=maxFile,'Snapshot requires regular files of at most 2 MiB.');
    const buffer=Buffer.alloc(maxFile+1);let length=0;while(length<buffer.length){const {bytesRead}=await fd.read(buffer,length,buffer.length-length,null);if(!bytesRead)break;length+=bytesRead;}const data=buffer.subarray(0,length);const after=await fd.stat();
    assert(data.length<=maxFile&&before.size===after.size&&before.mtimeMs===after.mtimeMs&&before.ctimeMs===after.ctimeMs,'A source file changed during capture.');
    return {data,mode:before.mode&0o111?0o755:0o644};
  }finally{await fd.close();}
}
async function capture(root){
  const paths=[...new Set(git(root,['ls-files','-z','--cached','--others','--exclude-standard']).split('\0').filter(Boolean))].sort();
  assert(paths.length&&paths.length<=maxFiles,'Snapshot must contain 1–1024 Git-listed source files.');
  const files=new Map();let total=0;
  for(const path of paths){let file;try{file=await exactFile(root,path);}catch(e){if(e.code==='ENOENT')continue;throw e;}total+=file.data.length;assert(total<=maxBytes,'Snapshot exceeds 32 MiB.');files.set(path,file);}
  return files;
}
function manifest(files){return [...files].sort(([a],[b])=>a<b?-1:a>b?1:0).map(([path,f])=>({path,mode:f.mode,bytes:f.data.length,sha256:hash(f.data)}));}
function digest(files){return hash(JSON.stringify(manifest(files)));}
function checkFileAttempt(attempt){
  const s=attempt?.source,p=attempt?.proposed_text,d=attempt?.shared_draft;
  assert(['selected-file-basis@1','selected-file-deletion-basis@1'].includes(s?.schema)&&s.scope==='selected-file-only'&&pathOK(s.path),'A selected-file review attempt is required.');
  assert((s.schema==='selected-file-deletion-basis@1'?p===null&&/^[a-f0-9]{64}$/.test(s.disk_sha256):typeof p==='string'&&Buffer.byteLength(p)<=32000&&!p.includes('\0'))&&typeof d==='string'&&Buffer.byteLength(d)<=24000&&!d.includes('\0'),'Review text exceeds its bounds.');
  assert(s.result_sha256===(p===null?hash(JSON.stringify(['deleted-file@1',s.path])):hash(p))&&s.result_bytes===(p===null?0:Buffer.byteLength(p))&&s.draft_sha256===hash(d)&&s.draft_bytes===Buffer.byteLength(d),'Review content identity mismatch.');
  assert(/^[a-f0-9]{40}(?:[a-f0-9]{24})?$/.test(s.head),'A concrete source commit is required.');
  assert(s.basis_id===hash(JSON.stringify(['selected-file-basis@1',s.head,s.path,s.disk_sha256,s.draft_sha256])),'Review source basis mismatch.');
  return s;
}
function checkAttempt(attempt){
  if(attempt?.schema!=='development-review-set@1'){
    assert(!attempt?.files,'A combined review requires its explicit schema.');
    return {source:checkFileAttempt(attempt),members:[attempt]};
  }
  const source=attempt.source,members=attempt.files;
  assert(source?.schema==='selected-file-set-basis@1'&&source.scope==='selected-file-set-only'&&Array.isArray(members)&&members.length>=2&&members.length<=4,'A bounded combined review is required.');
  const paths=new Set();
  for(const member of members){
    const s=checkFileAttempt(member);
    assert(!member.files&&!paths.has(s.path),'Duplicate or nested review members are not supported.');paths.add(s.path);
    assert(s.head===source.head&&s.task_ref===source.task_ref&&s.task_revision===source.task_revision&&s.repository_ref===source.repository_ref&&JSON.stringify(s.world)===JSON.stringify(source.world),'Combined review members have different source contexts.');
  }
  assert([...paths].every(p=>![...paths].some(q=>p!==q&&q.startsWith(p+'/'))),'Conflicting file and directory paths in the combined review.');
  assert(source.basis_id===hash(JSON.stringify(['selected-file-set-basis@1',members.map(m=>[m.source.path,m.source.basis_id])])),'Combined source identity mismatch.');
  assert(source.result_sha256===hash(JSON.stringify(['selected-file-set-result@1',members.map(m=>[m.source.path,m.source.result_sha256])])),'Combined result identity mismatch.');
  return {source,members};
}
async function execute(args,timeoutMs,signal){
  return new Promise(resolveResult=>{
    let bytes=0,output=[],omitted=0,timedOut=false,launchError=null;
    const child=spawn('/usr/bin/bwrap',args,{env:{PATH:'/usr/bin:/bin',LANG:'C.UTF-8'},detached:true,stdio:['ignore','pipe','pipe']});
    const append=b=>{const keep=Math.max(0,maxOutput-bytes);if(keep)output.push(b.subarray(0,keep));bytes+=Math.min(keep,b.length);omitted+=Math.max(0,b.length-keep);};
    child.stdout.on('data',append);child.stderr.on('data',append);
    const cancel=()=>{try{process.kill(-child.pid,'SIGKILL');}catch{}};
    signal?.addEventListener('abort',cancel,{once:true});if(signal?.aborted)cancel();
    const timer=setTimeout(()=>{timedOut=true;try{process.kill(-child.pid,'SIGKILL');}catch{}},timeoutMs);
    child.on('error',e=>{launchError=e.message;});
    child.on('close',(code,exitSignal)=>{clearTimeout(timer);signal?.removeEventListener('abort',cancel);resolveResult({code,signal:exitSignal,timedOut,launchError,output:Buffer.concat(output).toString('utf8'),omitted_bytes:omitted});});
  });
}

const profiles=['super-javascript-behavior@1','super-elixir-review@1','super-rust-review@1'];
async function pinElixirTools(run){
  const roots={elixir:execFileSync('asdf',['where','elixir'],{encoding:'utf8',timeout:10000}).trim(),erlang:execFileSync('asdf',['where','erlang'],{encoding:'utf8',timeout:10000}).trim()};
  async function inventory(root){
    const rows=[];let bytes=0;
    async function walk(path=''){
      for(const name of (await readdir(join(root,path))).sort()){
        const rel=path?path+'/'+name:name,full=join(root,rel),st=await lstat(full);
        assert(rows.length<20000,'Toolchain contains too many files.');
        if(st.isSymbolicLink())rows.push([rel,'link',await readlink(full)]);
        else if(st.isDirectory())await walk(rel);
        else {assert(st.isFile()&&st.size<64*1024*1024,'Unsupported toolchain file.');bytes+=st.size;assert(bytes<256*1024*1024,'Toolchain exceeds 256 MiB.');rows.push([rel,st.mode&0o777,hash(await readFile(full))]);}
      }
    }
    await walk();return hash(JSON.stringify(rows));
  }
  const binds=[],identities={};
  for(const [name,path] of Object.entries(roots)){
    assert(path.includes('/installs/'+name+'/')&&await realpath(path)===path,'Use an installed asdf '+name+' toolchain.');
    const before=await inventory(path),copy=join(run,'toolchain',name);await cp(path,copy,{recursive:true,dereference:false,verbatimSymlinks:true});
    assert(await inventory(copy)===before&&await inventory(path)===before,'Toolchain changed while copying.');
    binds.push('--ro-bind',copy,path);identities[name]=before;
  }
  return {binds,roots,sha256:hash(JSON.stringify(identities))};
}

async function pinRustTools(run){
  const compiler=await realpath(execFileSync('rustup',['which','rustc'],{encoding:'utf8',timeout:10000}).trim());
  const root=dirname(dirname(compiler));assert(root.includes('/toolchains/'),'Use an installed rustup toolchain.');
  const cargoHome=process.env.CARGO_HOME||join(process.env.HOME,'.cargo');
  async function fingerprint(root){
    const rows=[];let bytes=0,entries=0;
    async function walk(path=''){
      for(const name of (await readdir(join(root,path))).sort()){
        assert(++entries<=30000,'Rust test inputs contain too many entries.');
        const rel=path?path+'/'+name:name,full=join(root,rel),st=await lstat(full);
        if(st.isSymbolicLink())rows.push([rel,'link',await readlink(full)]);
        else if(st.isDirectory())await walk(rel);
        else {assert(st.isFile()&&st.size<=512*1024*1024,'Unsupported Rust test input.');bytes+=st.size;assert(bytes<=1024*1024*1024,'Rust test inputs exceed 1 GiB.');rows.push([rel,st.mode&0o777,hash(await readFile(full))]);}
      }
    }
    await walk();return hash(JSON.stringify(rows));
  }
  const identities={},rust=join(run,'toolchain/rust'),registry=join(run,'toolchain/registry');
  for(const [name,from,to] of [['rust-bin',join(root,'bin'),join(rust,'bin')],['rust-lib',join(root,'lib'),join(rust,'lib')],['cargo-cache',join(cargoHome,'registry/cache'),join(registry,'cache')],['cargo-index',join(cargoHome,'registry/index'),join(registry,'index')]]){
    const before=await fingerprint(from);await cp(from,to,{recursive:true,dereference:false,verbatimSymlinks:true});assert(await fingerprint(to)===before&&await fingerprint(from)===before,'Rust test inputs changed while copying.');identities[name]=before;
  }
  return {binds:['--ro-bind',rust,'/rust','--ro-bind',registry,'/registry'],sha256:hash(JSON.stringify(identities))};
}

export async function runProposalTests({repository,attempt,runRoot,nodePath=process.execPath,timeoutMs=30000,signal,profile=profiles[0]}){
  attempt=structuredClone(attempt);
  assert(profiles.includes(profile),'Unsupported test profile.');
  assert(Number.isInteger(timeoutMs)&&timeoutMs>=100&&timeoutMs<=120000,'Test timeout must be 100–120000 ms.');
  const {source,members}=checkAttempt(attempt),root=await realpath(repository),base=await realpath(runRoot);
  assert(base!==root&&!base.startsWith(root+sep),'Run artifacts must be outside the source repository.');
  const rootIdentity=await lstat(root);assert(rootIdentity.isDirectory(),'Choose a repository directory.');
  assert(git(root,['rev-parse','--show-toplevel']).trim()===root,'Choose the repository root.');
  assert(git(root,['rev-parse','--verify','HEAD^{commit}']).trim()===source.head,'The source commit changed. Prepare a fresh review.');
  const files=await capture(root);
  for(const member of members){
    const s=member.source,disk=files.get(s.path)?.data;
    // Missing and empty files have distinct identities; ignored members refuse.
    if(!disk){try{await lstat(join(root,s.path));throw Error('The selected file is excluded from the source snapshot: '+s.path);}catch(e){if(e.code!=='ENOENT')throw e;}}
    assert((disk?hash(disk):null)===s.disk_sha256,'The selected source file changed: '+s.path+'. Prepare a fresh review.');
  }
  const before=digest(files),second=await capture(root),afterRoot=await lstat(root);
  assert(before===digest(second)&&rootIdentity.dev===afterRoot.dev&&rootIdentity.ino===afterRoot.ino&&git(root,['rev-parse','--verify','HEAD^{commit}']).trim()===source.head,'Source changed during capture. Retry with a fresh review.');
  for(const member of members){if(member.proposed_text===null)files.delete(member.source.path);else files.set(member.source.path,{data:Buffer.from(member.proposed_text),mode:files.get(member.source.path)?.mode??0o644});}
  const entries=manifest(files),snapshotDigest=digest(files);
  assert(entries.length<=maxFiles&&entries.reduce((n,f)=>n+f.bytes,0)<=maxBytes,'Proposed snapshot exceeds its bounds.');
  // Closed profiles: no caller-provided command or test path.
  const tests=profile===profiles[0]?entries.map(f=>f.path).filter(p=>/^tools\/[a-z0-9-]+-test\.mjs$/.test(p)):profile===profiles[1]?['ampd/test/development_task_test.exs','ampd/test/development_attempt_test.exs']:['tools/native-review/Cargo.toml','tools/native-review/Cargo.lock','tools/native-review/src/lib.rs'];
  assert(tests.every(p=>files.has(p)),'The selected profile requires the Super files for that test profile.');
  assert(tests.length>0&&tests.length<=64,'No supported JavaScript behavior suites found (tools/*-test.mjs, maximum 64).');
  const executable=await realpath(nodePath),nodeStat=await lstat(executable);assert(nodeStat.isFile()&&nodeStat.size<=128*1024*1024,'Node executable exceeds the runner limit.');const node=await readFile(executable);assert(node.length===nodeStat.size,'Node executable changed during capture.');
  const run=await mkdtemp(join(base,'proposal-tests-')),snapshot=join(run,'snapshot');await mkdir(snapshot,{mode:0o700});
  const record={schema:'local-proposal-test@1',provenance:'human-operated-local-runner',scope:members.length===1?'captured-git-listed-source-with-one-proposal':'captured-git-listed-source-with-proposal-set',profile,attempt_ref:attempt.id??null,source_basis_id:source.basis_id,source_head:source.head,source_capture_sha256:before,result_sha256:source.result_sha256,result_path:source.path??null,result_paths:members.map(m=>m.source.path),snapshot_sha256:snapshotDigest,node_sha256:hash(node),tests,timeout_ms:timeoutMs,started_at:new Date().toISOString(),state:'preparing'};
  await atomic(join(run,'manifest.json'),{schema:'proposal-test-snapshot@1',sha256:snapshotDigest,files:entries});
  try{
    for(const [path,f] of files){const target=join(snapshot,path);await mkdir(dirname(target),{recursive:true,mode:0o700});await writeFile(target,f.data,{flag:'wx',mode:f.mode});}
    // Pin the executable bytes too; do not run a mutable installation path.
    const runtime=join(run,'node');await writeFile(runtime,node,{flag:'wx',mode:0o700});
    const toolchain=profile===profiles[1]?await pinElixirTools(run):profile===profiles[2]?await pinRustTools(run):null;if(toolchain)record.toolchain_sha256=toolchain.sha256;
    record.state='started';record.snapshot_retained=true;await atomic(join(run,'started.json'),record);
    const args=['--unshare-all','--die-with-parent','--new-session','--cap-drop','ALL','--ro-bind','/usr','/usr','--symlink','usr/lib','/lib','--symlink','usr/lib','/lib64','--proc','/proc','--dev','/dev','--tmpfs','/tmp','--dir','/runtime','--ro-bind',runtime,'/runtime/node','--ro-bind',snapshot,'/snapshot','--chdir','/snapshot','--clearenv','--setenv','PATH','/usr/bin','--setenv','HOME','/tmp','--setenv','LANG','C.UTF-8','--','/runtime/node','--test','--test-reporter=tap',...tests];
    if(profile===profiles[1]){
      const command=args.indexOf('--');args.splice(command);
      args.push('--symlink','usr/bin','/bin',...toolchain.binds,'--setenv','PATH',toolchain.roots.elixir+'/bin:'+toolchain.roots.erlang+'/bin:/usr/bin','--setenv','MIX_ENV','test','--setenv','ERL_FLAGS','+S 2:2','--setenv','XDG_STATE_HOME','/tmp/state','--','/bin/sh','-c','cp -a /snapshot /tmp/source && cd /tmp/source/ampd && exec mix test test/development_task_test.exs test/development_attempt_test.exs --seed 0');
    }
    if(profile===profiles[2]){
      args.splice(args.indexOf('--'));
      args.push('--symlink','usr/bin','/bin',...toolchain.binds,'--setenv','PATH','/rust/bin:/usr/bin','--setenv','CARGO_HOME','/tmp/cargo','--setenv','CARGO_TARGET_DIR','/tmp/target','--setenv','CARGO_BUILD_JOBS','2','--setenv','RUSTUP_TOOLCHAIN','stable','--','/bin/sh','-c','mkdir -p /tmp/cargo && cp -a /registry /tmp/cargo/registry && cp -a /snapshot /tmp/source && cd /tmp/source && exec cargo test --offline --locked --manifest-path tools/native-review/Cargo.toml --lib -- --test-threads=1');
    }
    const result=signal?.aborted?{code:null,signal:null,timedOut:false,launchError:null,output:'',omitted_bytes:0}:await execute(args,timeoutMs,signal);
    const unchanged=await Promise.all(entries.map(async e=>{const f=await exactFile(snapshot,e.path);return hash(f.data)===e.sha256&&f.mode===e.mode;})).then(xs=>xs.every(Boolean));
    const tapComplete=profile===profiles[2]?/test result: (?:ok|FAILED)\. \d+ passed; \d+ failed;/.test(result.output):profile===profiles[1]?/\d+ tests?, \d+ failures?/.test(result.output):/# tests \d+\r?\n/.test(result.output)&&/# fail \d+\r?\n/.test(result.output);
    // A sandbox/loader error is not a failed application assertion.
    const state=signal?.aborted||!unchanged||result.timedOut||result.launchError||result.signal||!tapComplete?'failed':'completed';
    Object.assign(record,{state,finished_at:new Date().toISOString(),exit_code:result.code,signal:result.signal,output:result.output,omitted_bytes:result.omitted_bytes});
    if(state==='completed')record.verdict=result.code===0?'pass':'fail';
    else record.reason=signal?.aborted?'cancelled':!unchanged?'snapshot-changed':result.timedOut?'timeout':result.launchError?'launcher-unavailable':result.signal?'terminated':'runner-did-not-complete';
    await atomic(join(run,'outcome.json'),record);return {directory:run,record};
  }catch(e){record.state='failed';record.reason='runner-error';record.finished_at=new Date().toISOString();record.error=String(e.message).slice(0,1000);await atomic(join(run,'outcome.json'),record);throw e;}
  finally{await rm(join(run,'node'),{force:true});await rm(join(run,'toolchain'),{recursive:true,force:true});}
}

// Read-only acceptance preflight. It executes no repository code and does not
// overlay a proposal: the saved checkout itself must match the tested snapshot.
export async function verifyTestedCheckout({repository,attempt,run}){
  attempt=structuredClone(attempt);run=structuredClone(run);
  const {source,members}=checkAttempt(attempt),root=await realpath(repository),outcome=run?.outcome;
  assert(run?.state==='completed'&&outcome?.verdict==='pass','A completed passing test run is required.');
  assert(outcome.result_sha256===source.result_sha256&&outcome.source_basis_id===source.basis_id,'The test result belongs to different review material.');
  assert(git(root,['rev-parse','--show-toplevel']).trim()===root,'Choose the repository root.');
  const identity=await lstat(root),head=git(root,['rev-parse','--verify','HEAD^{commit}']).trim();
  assert(head===source.head,'The source commit changed. Prepare a fresh review.');
  const files=await capture(root);
  for(const member of members)assert(member.proposed_text===null?!files.has(member.source.path):files.has(member.source.path)&&hash(files.get(member.source.path).data)===member.source.result_sha256,'Save the exact reviewed proposal before accepting it. The selected file differs: '+member.source.path);
  const snapshot=digest(files);assert(snapshot===outcome.snapshot_sha256,'The repository files differ from the passing test snapshot. Prepare a fresh review and test again.');
  const second=await capture(root),after=await lstat(root);
  assert(digest(second)===snapshot&&identity.dev===after.dev&&identity.ino===after.ino&&git(root,['rev-parse','--verify','HEAD^{commit}']).trim()===head,'Files changed during the acceptance check. Try again.');
  return {snapshot_sha256:snapshot,result_sha256:source.result_sha256,head};
}

// Shared bounded capture and isolation primitives for accepted-source builds.
export {capture,manifest,digest,execute,pinRustTools,atomic};
