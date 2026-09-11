import {capture,manifest,digest,execute,pinRustTools,atomic,verifyTestedCheckout} from './proposal-test-runner.mjs';
import {mkdir,mkdtemp,writeFile,readFile,lstat,realpath,rm,copyFile} from 'node:fs/promises';
import {join,dirname,sep} from 'node:path';
import {createHash} from 'node:crypto';
const hash=b=>createHash('sha256').update(b).digest('hex');
const assert=(ok,message)=>{if(!ok)throw Error(message);};
export async function runAcceptedBuild({repository,attempt,runRoot,signal,timeoutMs=900000}){
  attempt=structuredClone(attempt);const decision=attempt?.acceptance;
  assert(attempt?.status==='accepted'&&decision?.schema==='development-acceptance@1'&&decision.source_basis_id===attempt.source.basis_id&&decision.result_sha256===attempt.source.result_sha256,'An accepted result is required for building.');
  assert(Number.isInteger(timeoutMs)&&timeoutMs>=100&&timeoutMs<=1800000,'Invalid build time limit.');
  const root=await realpath(repository),base=await realpath(runRoot);assert(base!==root&&!base.startsWith(root+sep),'Build artifacts must be outside the source repository.');
  const checked=await verifyTestedCheckout({repository:root,attempt,run:attempt.test_runs[decision.run_id]});
  assert(checked.snapshot_sha256===decision.snapshot_sha256,'The accepted snapshot differs from the passing run.');
  const files=await capture(root);assert(digest(files)===checked.snapshot_sha256,'Source changed before build capture.');
  for(const path of ['cockpit/Cargo.toml','cockpit/Cargo.lock','ampd/mix.exs'])assert(files.has(path),'The cockpit build requires '+path+'.');
  const dir=await mkdtemp(join(base,'accepted-build-')),snapshot=join(dir,'snapshot'),scratch=join(dir,'scratch'),artifact=join(dir,'artifact');
  await mkdir(snapshot,{mode:0o700});await mkdir(scratch,{mode:0o700});await mkdir(artifact,{mode:0o700});
  const record={schema:'local-accepted-build@1',local_only:true,profile:'super-cockpit-release@1',attempt_ref:attempt.id,accepted_at:decision.accepted_at,snapshot_sha256:decision.snapshot_sha256,result_sha256:decision.result_sha256,source_head:checked.head,started_at:new Date().toISOString(),state:'preparing'};
  try{
    for(const [path,f] of files){const target=join(snapshot,path);await mkdir(dirname(target),{recursive:true,mode:0o700});await writeFile(target,f.data,{flag:'wx',mode:f.mode});}
    await atomic(join(dir,'manifest.json'),{snapshot_sha256:decision.snapshot_sha256,files:manifest(files)});
    if(signal?.aborted)throw Error('Build cancelled before launch.');
    const tools=await pinRustTools(dir);record.toolchain_sha256=tools.sha256;
    const args=['--unshare-all','--die-with-parent','--new-session','--cap-drop','ALL','--ro-bind','/usr','/usr','--symlink','usr/lib','/lib','--symlink','usr/lib','/lib64','--symlink','usr/bin','/bin','--proc','/proc','--dev','/dev','--tmpfs','/tmp','--ro-bind',snapshot,'/snapshot','--bind',scratch,'/work',...tools.binds,'--clearenv','--setenv','PATH','/rust/bin:/usr/bin','--setenv','HOME','/work/home','--setenv','LANG','C.UTF-8','--setenv','CARGO_HOME','/work/cargo','--setenv','CARGO_TARGET_DIR','/work/target','--setenv','CARGO_BUILD_JOBS','2','--setenv','RUSTUP_TOOLCHAIN','stable','--chdir','/work','--','/bin/sh','-c','mkdir -p /work/cargo /work/home && cp -a /registry /work/cargo/registry && cp -a /snapshot /work/source && cd /work/source && exec cargo build --offline --locked --release --manifest-path cockpit/Cargo.toml --bin super-cockpit'];
    record.state='running';await atomic(join(dir,'started.json'),record);
    const result=signal?.aborted?{code:null,output:'',omitted_bytes:0}:await execute(args,timeoutMs,signal);
    Object.assign(record,{output:result.output,omitted_bytes:result.omitted_bytes,exit_code:result.code});
    if(signal?.aborted||result.code!==0){record.state='failed';record.reason=signal?.aborted?'cancelled':result.timedOut?'timeout':'build-failed';}
    else{
      const source=join(scratch,'target/release/super-cockpit'),stat=await lstat(source);
      assert(stat.isFile()&&!stat.isSymbolicLink()&&stat.size>4&&stat.size<=256*1024*1024&&await realpath(source)===source,'Build did not produce a bounded regular cockpit executable.');
      const bytes=await readFile(source);assert(bytes.subarray(0,4).equals(Buffer.from([127,69,76,70])),'Build output is not a Linux executable.');
      const output=join(artifact,'super-cockpit');await writeFile(output,bytes,{flag:'wx',mode:0o700});
      await writeFile(join(artifact,'launch-super.sh'),'#!/bin/sh\nset -eu\nartifact_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\nexport AMPD_DIR="$artifact_dir/../snapshot/ampd"\nexec "$artifact_dir/super-cockpit" "$@"\n',{flag:'wx',mode:0o700});
      record.state='completed';record.artifact={path:output,sha256:hash(bytes),bytes:bytes.length,launcher:join(artifact,'launch-super.sh')};
    }
  }catch(e){record.state='failed';record.reason=signal?.aborted?'cancelled':'build-error';record.output=String(e.message).slice(0,1200);}
  finally{record.finished_at=new Date().toISOString();await atomic(join(dir,'outcome.json'),record);await rm(scratch,{recursive:true,force:true});await rm(join(dir,'toolchain'),{recursive:true,force:true});}
  return {directory:dir,record};
}
