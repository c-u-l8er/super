// Local human-operated runner; not a Carrier job or an acceptance receipt.
import {createHash} from 'node:crypto';
import {hostname,arch,platform,cpus} from 'node:os';
import {spawn,execFileSync} from 'node:child_process';
import {constants as F,statSync,accessSync,writeFileSync} from 'node:fs';
import {StringDecoder} from 'node:string_decoder';
import {mkdir,mkdtemp,readFile,writeFile,rename,rm,realpath,open,lstat,cp,readdir,readlink,chmod} from 'node:fs/promises';
import {resolve,dirname,join,relative,sep} from 'node:path';

const hash=b=>createHash('sha256').update(b).digest('hex');
const maxFiles=1024,maxFile=2*1024*1024,maxBytes=32*1024*1024,maxOutput=128*1024,maxListed=65536;
// One reviewed member's body: the runtime's Ampd.ReviewContent.file_bytes/0. The
// page limits what it will attach or accept from a bot (256 KiB); the runner
// checks what the runtime recorded.
const MEMBER_BYTES=4*1024*1024;
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
function listPaths(root){
  const listed=[...new Set(git(root,['ls-files','-z','--cached','--others','--exclude-standard']).split('\0').filter(Boolean))].sort();
  assert(listed.length&&listed.length<=maxListed,'A repository of 1–65536 Git-listed files is required.');
  return listed;
}
// `only` SCOPES the snapshot to a named set of paths. The scope is the profile's,
// never a caller's: unscoped (null) captures the whole repository exactly as
// before, and the document profile captures the reviewed documents alone — which
// is what lets a repository far larger than Super take a review at all. Git-listed,
// bounded and hashed either way.
async function capture(root,only=null){
  const paths=listPaths(root).filter(path=>!only||only.has(path));
  assert(paths.length<=maxFiles&&(only||paths.length),'Snapshot must contain 1–1024 Git-listed source files.');
  const files=new Map();let total=0;
  for(const path of paths){let file;try{file=await exactFile(root,path);}catch(e){if(e.code==='ENOENT')continue;throw e;}total+=file.data.length;assert(total<=maxBytes,'Snapshot exceeds 32 MiB.');files.set(path,file);}
  return files;
}
function manifest(files){return [...files].sort(([a],[b])=>a<b?-1:a>b?1:0).map(([path,f])=>({path,mode:f.mode,bytes:f.data.length,sha256:hash(f.data)}));}
function digest(files){return hash(JSON.stringify(manifest(files)));}
function checkFileAttempt(attempt){
  const s=attempt?.source,p=attempt?.proposed_text,d=attempt?.shared_draft;
  assert(['selected-file-basis@1','selected-file-deletion-basis@1'].includes(s?.schema)&&s.scope==='selected-file-only'&&pathOK(s.path),'A selected-file review attempt is required.');
  assert((s.schema==='selected-file-deletion-basis@1'?p===null&&/^[a-f0-9]{64}$/.test(s.disk_sha256):typeof p==='string'&&Buffer.byteLength(p)<=MEMBER_BYTES&&!p.includes('\0'))&&typeof d==='string'&&Buffer.byteLength(d)<=MEMBER_BYTES&&!d.includes('\0'),typeof d!=='string'?'Review text is missing: the record carries no body for '+s.path+'.':'Review text exceeds its bounds.');
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
// T36: **the record keeps a transcript's first and last half of its bound**, and the lines that can show how a JS,
// document or gate run ended (TAP totals, a gate's marker) are collected as they pass, however long the transcript. Each
// stream (stdout, stderr) is split into lines on its own, so fragments of one never join fragments of the other; an
// overlong line is skipped to its end, so no part of it can pose as a line of its own; and more signal lines than the
// bound fails closed (`signals_overflowed`). Super's two compiled profiles do not read text at all: their stages are
// judged by exit status (compiledStageCommand, stageOutcome).
const SIGNAL=/^(?:# gates? |# tests \d|# fail \d)/,maxSignals=4096,maxLine=4096;
// T43 (A-32): **a bounded index of the lines that name a failure,** collected like the signals from every line of every
// stream, kept or omitted: ExUnit's `  1) test <name> (<Module>)`, cargo's `test <path> ... FAILED` and node's TAP
// `not ok <n> - <name>` (at any depth). Each entry is {stage, line}, at most 512 characters, at most 16 in the order they
// arrived; a further match sets `failures_overflowed`. It points people at the failure; it is never part of a verdict.
// (The module group is closed and space-free, so the pattern stays linear on a 4,096-character line.)
const FAILURE=/^\s*(?:\d+\) test .+ \([^()\s]+\)|test \S+ \.\.\. FAILED|not ok \d+ - .+)$/,maxFailures=16,maxFailureLine=512,maxFailureCost=1024;
// T43 round 2 (Codex review 1, fix 1): what a string costs in the record, as JSON (escapes and U+FFFD included).
const jsonCost=s=>Buffer.byteLength(JSON.stringify(s))-2;
// A failure line is at most 512 characters AND at most 1,024 bytes as JSON, so 16 of them stay small in the record
// whatever control characters they carry.
const failureLine=l=>{let out='';for(const c of Array.from(l).slice(0,maxFailureLine)){if(jsonCost(out+c)>maxFailureCost)break;out+=c;}return out;};
// Cut a kept piece at whole UTF-8 characters: a head never ends inside a character, a tail never starts inside one.
const wholeHead=b=>{let e=b.length;for(let i=b.length-1,n=0;i>=0&&n<4;i--,n++){const c=b[i];if((c&0xc0)===0x80)continue;const need=c>=0xf0?4:c>=0xe0?3:c>=0xc0?2:1;e=i+need<=b.length?b.length:i;break;}return b.subarray(0,e);};
const wholeTail=b=>{let s=0;while(s<b.length&&s<4&&(b[s]&0xc0)===0x80)s++;return b.subarray(s);};
export function transcriptKeeper(limit=maxOutput,stage=null){
  const half=Math.floor(limit/2),head=[],tail=[],signals=[],failures=[],streams=new Map();
  let headBytes=0,tailBytes=0,total=0,headClosed=false,overflowed=false,failuresOverflowed=false;
  const failure=l=>{if(l.length>maxLine||!FAILURE.test(l))return;if(failures.length<maxFailures)failures.push({stage,line:failureLine(l)});else failuresOverflowed=true;};
  const line=l=>{l=l.replace(/\r$/,'');failure(l);if(l.length>maxLine||!SIGNAL.test(l))return;if(signals.length<maxSignals)signals.push(l);else overflowed=true;};
  // T43: what is kept is the bytes the stream delivered, cut per stream at whole characters (a character that a chunk
  // splits waits for the rest of it), so no character is split between stdout and stderr, nor at a cut. `total` and the
  // omitted count are the delivered bytes, never a re-encoding: an invalid byte counts as one byte (T36 counted the
  // three of its U+FFFD). Valid UTF-8 keeps exactly what T36 kept. The kept bytes are decoded only for the output.
  const keep=b=>{
    if(!b.length)return;total+=b.length;let rest=b;
    if(!headClosed){const piece=wholeHead(b.subarray(0,Math.min(half-headBytes,b.length)));if(piece.length){head.push(piece);headBytes+=piece.length;}rest=b.subarray(piece.length);if(rest.length)headClosed=true;}
    if(rest.length){tail.push(rest);tailBytes+=rest.length;while(tail.length>1&&tailBytes-tail[0].length>=half){tailBytes-=tail[0].length;tail.shift();}}
  };
  const stream=name=>{
    if(!streams.has(name)){const decoder=new StringDecoder('utf8');let carry='',discarding=false,pending=Buffer.alloc(0);
      const scan=text=>{const parts=(carry+text).split('\n');carry=parts.pop();for(const l of parts){if(discarding){discarding=false;continue;}line(l);}if(carry.length>maxLine){carry='';discarding=true;}};
      streams.set(name,{take(b){const all=pending.length?Buffer.concat([pending,b]):b,whole=wholeHead(all);pending=Buffer.from(all.subarray(whole.length));keep(whole);scan(decoder.write(b));},
        end(){keep(pending);pending=Buffer.alloc(0);scan(decoder.end());if(!discarding&&carry)line(carry);carry='';}});}
    return streams.get(name);
  };
  return {
    push(b,name='stdout'){stream(name).take(b);},
    finish(){
      for(const s of streams.values())s.end();
      const keptHead=Buffer.concat(head);let keptTail=Buffer.concat(tail);if(keptTail.length>half)keptTail=wholeTail(keptTail.subarray(keptTail.length-half));
      const kept={head:keptHead,tail:keptTail,total};
      // `kept` (the delivered bytes kept, never serialized) lets the record be fitted later with exact counts (fitKept).
      return {...fitKept(kept),signals,signals_overflowed:overflowed,failures,failures_overflowed:failuresOverflowed,kept};
    }
  };
}
// T43 round 2 (fix 1): a kept transcript as text, its JSON cost at most `cap`. Within the cap it is exactly the keeper's
// text (T36's, for valid UTF-8); over it, the head is cut back from its end and the tail from its start by the same
// number of bytes, at whole characters, until it fits. omitted_bytes is always the delivered bytes not kept.
export function fitKept({head,tail,total},cap=Infinity){
  const text=(h,t)=>{const om=total-h.length-t.length;return {output:h.toString('utf8')+(om?`\n[… ${om} bytes omitted …]\n`:'')+t.toString('utf8'),omitted_bytes:om};};
  const whole=text(head,tail);if(cap===Infinity||jsonCost(whole.output)<=cap)return whole;
  const cut=n=>text(wholeHead(head.subarray(0,Math.min(head.length,n))),wholeTail(tail.subarray(Math.max(0,tail.length-n))));
  let lo=0,hi=Math.max(head.length,tail.length);
  while(lo<hi){const mid=Math.ceil((lo+hi)/2);if(jsonCost(cut(mid).output)<=cap)lo=mid;else hi=mid-1;}
  return cut(lo);
}
// A run's transcript is its parts (one per stage, or one for a run of node or a gate): each a runner-written prefix and
// a kept transcript (or none, for a stage that never ran), joined by newlines.
export function composeParts(parts,caps=[]){
  const fitted=parts.map((p,i)=>p.kept?fitKept(p.kept,caps[i]??Infinity):{output:'',omitted_bytes:0});
  return {output:parts.map((p,i)=>p.prefix+fitted[i].output).join('\n'),omitted_bytes:fitted.reduce((n,f)=>n+f.omitted_bytes,0)};
}
// T43 round 2 (fix 1): **the outcome record always fits what the cockpit reads.** The cockpit refuses a record over 256
// KiB (cockpit/src/review_tests.rs, read()) and then reports an incomplete run instead of its outcome. A record that
// would pass OUTCOME_MAX as written (pretty JSON) has its transcripts fitted: the baseline's first, then the candidate's,
// each by one scale on its parts' JSON costs, the largest that fits. The failure index and the verdict never change.
// `transcripts_fitted` says so in the record. A record within the bound is written exactly as before.
export const OUTCOME_MAX=240*1024;
const recordBytes=r=>Buffer.byteLength(JSON.stringify(r,null,2)+'\n');
export function fitOutcome(record,sets){
  if(recordBytes(record)<=OUTCOME_MAX)return record;
  for(const {target,parts} of sets){
    if(!target||!parts?.length)continue;
    const full=parts.map(p=>p.kept?jsonCost(fitKept(p.kept).output):0);
    const apply=k=>{const c=composeParts(parts,full.map(x=>Math.floor(x*k/1000)));target.output=c.output;target.omitted_bytes=c.omitted_bytes;};
    record.transcripts_fitted=true;apply(0);if(recordBytes(record)>OUTCOME_MAX)continue;
    let lo=0,hi=1000;while(lo<hi){const mid=Math.ceil((lo+hi)/2);apply(mid);if(recordBytes(record)<=OUTCOME_MAX)lo=mid;else hi=mid-1;}
    apply(lo);return record;
  }
  return record;
}
// T43: one run's index, from its stages' in stage order, still at most 16 entries.
export function failureIndex(parts){
  const failures=[];let overflowed=false;
  for(const p of parts){for(const f of p.failures??[]){if(failures.length<maxFailures)failures.push(f);else overflowed=true;}if(p.failures_overflowed)overflowed=true;}
  return {failures,failures_overflowed:overflowed};
}
// T43 (Codex T36 round 3, nonblocking 1): **a stage asked to stop prints what it wrote first.** At the deadline or on a
// cancellation the runner creates `stop` in the stage's control directory, bound read-only at /control (a signal cannot
// reach the wrapper through bwrap's PID namespace: superlane/t43/measure/MEASURE-stop.md); the wrapper's watcher prints
// /tmp/stage.log and ends the wrapper. The group is SIGKILLed STOP_GRACE_MS after the request whatever happens.
const STOP_GRACE_MS=10000;
// `control` (a compiled stage's control directory) makes a deadline or a cancellation a stop request first; without it
// the group is SIGKILLed at once, as before. `stage` names the failure index's entries. Round 2 (fix 3): `deadline` is
// the stage's ABSOLUTE deadline (ms since the epoch); the timer is armed from it after the spawn, so no setup delay
// moves it, and the group is SIGKILLed no later than that deadline plus STOP_GRACE_MS (a cancellation before the
// deadline: its own request plus the grace). The FIRST stop reason is kept (fix 2).
async function execute(args,timeoutMs,signal,limit=maxOutput,{control=null,stage=null,deadline=null}={}){
  return new Promise(resolveResult=>{
    let timedOut=false,launchError=null,stopped=null,grace=null;const keeper=transcriptKeeper(limit,stage);
    const child=spawn('/usr/bin/bwrap',args,{env:{PATH:'/usr/bin:/bin',LANG:'C.UTF-8'},detached:true,stdio:['ignore','pipe','pipe']});
    child.stdout.on('data',b=>keeper.push(b,'stdout'));child.stderr.on('data',b=>keeper.push(b,'stderr'));
    const kill=()=>{try{process.kill(-child.pid,'SIGKILL');}catch{}};
    const stop=reason=>{if(!control)return kill();if(stopped)return;stopped=reason;const until=reason==='deadline'&&deadline!==null?deadline+STOP_GRACE_MS:Date.now()+STOP_GRACE_MS;grace=setTimeout(kill,Math.max(0,until-Date.now()));try{writeFileSync(join(control,'stop'),'',{flag:'wx',mode:0o600});}catch{kill();}};
    const cancel=()=>stop('cancellation');
    signal?.addEventListener('abort',cancel,{once:true});if(signal?.aborted)cancel();
    const timer=setTimeout(()=>{timedOut=true;stop('deadline');},deadline!==null?Math.max(0,deadline-Date.now()):timeoutMs);
    child.on('error',e=>{launchError=e.message;});
    child.on('close',(code,exitSignal)=>{clearTimeout(timer);clearTimeout(grace);signal?.removeEventListener('abort',cancel);resolveResult({code,signal:exitSignal,timedOut,launchError,stopped,ended:Date.now(),...keeper.finish()});});
  });
}

const profiles=['super-javascript-behavior@1','super-elixir-review@1','super-rust-review@1','repository-document-review@1','repository-python-gate@1'];
const checkerUrl=new URL('./document-review-check.mjs',import.meta.url);
// T36: each profile's ceiling, one table. The runner refuses a timeout above its profile's, and the CLI passes it. The
// Rust and Elixir profiles run Super's whole suites, measured cold in this sandbox at about 125 s and 236 s
// (superlane/t36/measure/), so theirs are about four times that.
const ceilings={'super-javascript-behavior@1':30000,'super-elixir-review@1':900000,'super-rust-review@1':600000,'repository-document-review@1':30000,'repository-python-gate@1':120000};
export const profileCeiling=profile=>{assert(profiles.includes(profile),'Unsupported test profile.');return ceilings[profile];};
// **T36 (A-13): Super's two compiled profiles run the suites they are named for.** Until T36 the Rust profile ran only
// tools/native-review (which no longer compiled) and the Elixir profile two of ampd's 67 test files, so neither could be
// a required check for Super's own host, cockpit or runtime code (DISCIPLINE.md §3).
//
// Closed, like the gates, and judged WITHOUT reading anything the code under test prints (Codex review 1):
// - **Each stage runs in a sandbox of its own,** from a fresh copy of the snapshot, so one suite's code cannot alter
//   another's inputs. The only thing that passes between stages is super-host's binary, from the host build to the ampd
//   suite, read-only.
// - **A stage's outcome is its exit status,** observed by the runner: a cargo stage compiles first (`--no-run`) and
//   exits 125 if that fails, so a build failure is never a test verdict; `mix compile` does the same for ampd; the
//   suites' own statuses (cargo test 101, mix test 2) are failures; anything else, a timeout or a signal is no verdict.
// - What a stage prints is kept for people, never consulted. A test that deliberately exits 0 mid-run can still fake a
//   pass in any harness: the verdict is host-reported, and acceptance reviews the diff.
const NOT_PREPARED=124,NOT_COMPILED=125;
const stages={
  // Amendment 2: tools/native-review is not run. It has not compiled since 2026-09-15 (9a930f9: review_tests.rs reaches
  // crate::screenshots and crate::worker, which it lacks), and the cockpit suite compiles and tests every module it did.
  'super-rust-review@1':[
    {name:'host',cargo:true,script:'cargo test --no-run --offline --locked --manifest-path host/Cargo.toml || exit 125; exec cargo test --offline --locked --manifest-path host/Cargo.toml',outcomes:{0:'pass',101:'fail'}},
    {name:'cockpit',cargo:true,sibling:true,script:'cargo test --no-run --offline --locked --manifest-path cockpit/Cargo.toml || exit 125; exec cargo test --offline --locked --manifest-path cockpit/Cargo.toml',outcomes:{0:'pass',101:'fail'}}],
  // ampd finds super-host at host/target/release (Ampd.Worktree.Effector), so it is built first, in its own sandbox, and
  // only its binary is handed on.
  'super-elixir-review@1':[
    {name:'host-build',cargo:true,exports:'super-host',script:'cargo build --release --offline --locked --manifest-path host/Cargo.toml && cp host/target/release/super-host /out/super-host',outcomes:{0:'built'}},
    {name:'ampd',needs:'host-build',script:'cd ampd && { mix compile || exit 125; } && exec mix test --seed 0',outcomes:{0:'pass',2:'fail'}}]};
// The files a profile requires in the snapshot, which is also the count the runtime records (1–64).
const requiredFiles={
  'super-elixir-review@1':['ampd/mix.exs','ampd/test/test_helper.exs','host/Cargo.toml','host/Cargo.lock'],
  'super-rust-review@1':['host/Cargo.toml','host/Cargo.lock','cockpit/Cargo.toml','cockpit/Cargo.lock']};
// The environment each compiled profile's sandbox receives, beyond the base HOME and LANG and the PATH its toolchains
// set: nothing else of the host's. The ampd suite's terminal tests commit to Git repositories they create, and the
// sandbox's HOME has no identity, so the identity is fixed here (without it 39 tests fail: superlane/t36/measure/).
const sandboxEnv={
  'super-elixir-review@1':{MIX_ENV:'test',ERL_FLAGS:'+S 2:2',XDG_STATE_HOME:'/tmp/state',CARGO_HOME:'/tmp/cargo',CARGO_BUILD_JOBS:'2',RUSTUP_TOOLCHAIN:'stable',GIT_AUTHOR_NAME:'Super review',GIT_AUTHOR_EMAIL:'review@super.invalid',GIT_COMMITTER_NAME:'Super review',GIT_COMMITTER_EMAIL:'review@super.invalid'},
  'super-rust-review@1':{CARGO_HOME:'/tmp/cargo',CARGO_TARGET_DIR:'/tmp/target',CARGO_BUILD_JOBS:'2',RUSTUP_TOOLCHAIN:'stable'}};
export function profilePlan(profile){
  assert(profiles.includes(profile),'Unsupported test profile.');
  return structuredClone({stages:stages[profile]??null,requiredFiles:requiredFiles[profile]??null,env:sandboxEnv[profile]??null,ceiling:ceilings[profile]});
}
// The shell a stage runs: prepare a private copy (exit 124 if that fails), then the stage's fixed command. Amendment 2:
// RRABBIT's own build script writes into its tree (tier1-proof/build.rs packages ui/road-geometry.js), so the cockpit
// stage builds from a private copy of the read-only capture; the capture and its identity are never written.
// A stage is named, and always taken from the closed table: a caller never supplies its command.
const stageOf=(profile,stage)=>{const s=stages[profile]?.find(x=>x.name===(typeof stage==='string'?stage:stage?.name));assert(s,'Not a stage of this profile.');return s;};
export function stageScript(profile,named){
  const stage=stageOf(profile,named);
  const prepare=[...(stage.cargo?['mkdir -p /tmp/cargo','cp -a /registry /tmp/cargo/registry']:[]),'cp -a /snapshot /tmp/source',...(stage.sibling?['cp -a /rrabbit /tmp/RRABBIT']:[]),...(stage.needs?['mkdir -p /tmp/source/host/target/release','cp /built/super-host /tmp/source/host/target/release/super-host','chmod 755 /tmp/source/host/target/release/super-host']:[]),'cd /tmp/source'];
  // Round 3: the code under test writes to a file of its own sandbox, never to the runner's pipe, and the file is
  // printed when the stage ends. Measured: the whole ampd suite run straight into the pipe failed 3 of 3 times (1, 1 and
  // 908 failures; superlane/t36/pipe-test.out), and 7 of 7 through a file passed. The subshell keeps the stage's exit
  // status, its reserved 125 included.
  // T43: a watcher in the background waits for the runner's stop request (/control/stop), then prints the file and ends
  // the wrapper, which tears the sandbox down. The stage stays in the foreground, its signal dispositions as before.
  return stageWrapper({prepare:prepare.join(' && '),script:stage.script});
}
// T43 round 2 (Codex review 1, fix 2): **the transcript is printed once.** The watcher and the normal end each take a
// lock first (mkdir is atomic); the one that loses prints nothing. A normal end that loses waits for the watcher, which
// prints and ends the wrapper. stageScript is the only production caller, with these paths; law F8 runs the same text
// with its own paths under /usr/bin/sh.
export function stageWrapper({prepare,script,log='/tmp/stage.log',stop='/control/stop',lock='/tmp/stage.dump',poll=1}){
  return `${prepare} || exit ${NOT_PREPARED}\n{ while [ ! -e ${stop} ]; do sleep ${poll}; done; mkdir ${lock} 2>/dev/null || exit 0; cat ${log}; kill -KILL $$; } &\n(${script}) > ${log} 2>&1\ncode=$?\nmkdir ${lock} 2>/dev/null || { wait; exit $code; }\ncat ${log}\nexit $code`;
}
// The rest of a stage's bwrap arguments after the common sandbox: its toolchains, its private RRABBIT capture, its hand-
// over directory (writable /out for the stage that exports, read-only /built for the stage that needs it), its fixed
// environment, and its script. T43: and its control directory, read-only at /control, where the runner asks it to stop.
export function compiledStageCommand(profile,named,{toolBinds,path,sibling=null,out=null,built=null,control=null}){
  const stage=stageOf(profile,named);
  assert(!stage.sibling||sibling,'This stage needs the RRABBIT capture.');assert(!stage.exports||out,'This stage needs its output directory.');assert(!stage.needs||built,'This stage needs what the stage before it built.');
  return ['--symlink','usr/bin','/bin',...toolBinds,...(stage.sibling?sibling.binds:[]),...(stage.exports?['--bind',out,'/out']:[]),...(stage.needs?['--ro-bind',built,'/built']:[]),...(control?['--ro-bind',control,'/control']:[]),
    '--setenv','PATH',path,...Object.entries(sandboxEnv[profile]).flatMap(([k,v])=>['--setenv',k,v]),'--','/bin/sh','-c',stageScript(profile,stage)];
}
// Round 2: what a stage hands on is a COPY the runner makes of the one validated file, never the build-controlled
// directory it was written to; the copy is read-only. The stage that needs it takes its own writable copy, as a fresh
// build output would be (ampd's F19a copies the binary and writes to the copy).
export async function handOff(out,to,name){
  const from=join(out,name),st=await lstat(from);
  assert(st.isFile()&&st.size>0&&st.size<=256*1024*1024,'The handed-on '+name+' must be one bounded regular file.');
  const bytes=await readFile(from);assert(bytes.length===st.size,'The handed-on file changed while it was read.');
  await mkdir(to,{mode:0o700});await writeFile(join(to,name),bytes,{flag:'wx',mode:0o555});
  return {dir:to,sha256:hash(bytes),bytes:bytes.length};
}
// Removing what a build wrote must not fail a run that already recorded its outcome, whatever permissions it left.
async function unlockTree(path){const st=await lstat(path);if(st.isSymbolicLink()||!st.isDirectory())return;await chmod(path,0o700);for(const name of await readdir(path))await unlockTree(join(path,name));}
async function removeTree(path){try{await rm(path,{recursive:true,force:true});}catch{try{await unlockTree(path);await rm(path,{recursive:true,force:true});}catch{}}}
// A stage's outcome, from what the runner itself observed.
export function stageOutcome(stage,{code,signal,timedOut,launchError}){
  if(timedOut||launchError||signal||!Number.isInteger(code))return 'incomplete';
  return stage.outcomes[code]??'incomplete';
}
// A run of stages: complete only when every stage ran to an outcome; it passes only when every stage passed (or built).
export function compiledVerdict(outcomes){
  if(!outcomes.length||outcomes.some(o=>!['pass','fail','built'].includes(o)))return {state:'failed'};
  return {state:'completed',verdict:outcomes.every(o=>o==='pass'||o==='built')?'pass':'fail'};
}
// Did a JS, document or gate run reach its end? Judged on the signal lines the stream carried; too many fails closed.
export function transcriptComplete(profile,signals,overflowed=false){
  assert(!stages[profile],'A compiled profile is judged by its stages.');
  if(overflowed)return false;
  if(profile===profiles[4])return signals.includes('# gates complete');
  return signals.some(l=>/^# tests \d+$/.test(l))&&signals.some(l=>/^# fail \d+$/.test(l));
}
// A run's state and verdict, from what the runner observed (T43 moved these lines here unchanged, so law F2 can hold
// them): a compiled profile by its stages' exit statuses, any other by its exit status once its transcript completed. A
// sandbox/loader error is not a failed application assertion. The failure index is never read here.
export function judgeRun(profile,result,{unchanged=true,aborted=false}={}){
  const compiled=Boolean(stages[profile]);
  const tapComplete=compiled?result.state==='completed':transcriptComplete(profile,result.signals??[],result.signals_overflowed);
  const state=aborted||!unchanged||result.timedOut||result.launchError||result.signal||!tapComplete?'failed':'completed';
  if(state==='completed')return {state,verdict:compiled?result.verdict:result.code===0?'pass':'fail'};
  return {state,reason:aborted?'cancelled':!unchanged?'snapshot-changed':result.timedOut?'timeout':result.launchError?'launcher-unavailable':result.signal?'terminated':'runner-did-not-complete'};
}
// One toolchain_sha256 per run (the runtime records one): the Elixir profile's covers Erlang/Elixir and the Rust that
// builds super-host; the Rust profile's covers Rust and the sibling RRABBIT, so one changed RRABBIT byte changes it.
export const compiledToolchainSha256=({elixir,rust,sibling})=>hash(JSON.stringify(elixir?{elixir,rust}:{rust,sibling}));
// T36 amendment 1: the cockpit hands the runner its own PATH, which carries asdf's shims and not the asdf command
// (~/.asdf/bin/asdf), so `asdf where` failed with ENOENT from the cockpit (superlane/t36/finding-asdf/). The command is
// found in a closed order instead.
function executableFile(path){try{accessSync(path,F.X_OK);return statSync(path).isFile();}catch{return false;}}
export function findAsdf({env=process.env,isExecutable=executableFile}={}){
  for(const dir of String(env.PATH??'').split(':').filter(Boolean)){const c=join(dir,'asdf');if(isExecutable(c))return c;}
  for(const c of [env.ASDF_DIR&&join(env.ASDF_DIR,'bin','asdf'),env.HOME&&join(env.HOME,'.asdf','bin','asdf')])if(c&&isExecutable(c))return c;
  throw Error('Elixir and Erlang must be installed with asdf; no asdf executable was found on PATH, in $ASDF_DIR/bin or in ~/.asdf/bin.');
}
// T36: the cockpit builds `../../RRABBIT/tier1-proof` from cockpit/, which is the repository's sibling RRABBIT and not
// part of its snapshot. It is captured the way the snapshot is (Git-listed, bounded, hashed), copied into the run and
// bound read-only at /rrabbit; the sandbox copies it to /tmp/RRABBIT, where cockpit/../../RRABBIT resolves from
// /tmp/source/cockpit (amendment 2).
export async function pinSibling(root,run){
  let real;try{real=await realpath(join(dirname(root),'RRABBIT'));assert(git(real,['rev-parse','--show-toplevel']).trim()===real,'');}
  catch{throw Error('The Rust profile needs RRABBIT beside the repository (../RRABBIT, a Git repository root): the cockpit builds its path dependency from there.');}
  const head=git(real,['rev-parse','--verify','HEAD^{commit}']).trim(),files=await capture(real),copy=join(run,'sibling');
  for(const [path,f] of files){const target=join(copy,path);await mkdir(dirname(target),{recursive:true,mode:0o700});await writeFile(target,f.data,{flag:'wx',mode:f.mode});}
  return {binds:['--ro-bind',copy,'/rrabbit'],identity:{path:'../RRABBIT',head,sha256:digest(files),files:files.size,bytes:[...files.values()].reduce((n,f)=>n+f.data.length,0)}};
}
// A repository that is not Super has its own gate, and running it is the only way
// Super can check its code. The CLOSED part is this table: the runner picks the
// gates by their own paths, with fixed arguments and a fixed scope. A caller names
// no command, no path and no directory — adding a repository here is a change to
// Super, reviewed like any other.
const gates=[
  {path:'tools/succession_laws_gate.py',args:['--check'],scope:['tools/','laws/','cd-core/','receipts/SUCCESSION-LAWS.md']},
  {path:'compiled/laws_gate.py',args:['--check'],scope:['compiled/','forge/','runtime/python/']},
  // R130 (2)(iii), T34: Edge R0.9's evidence gate, written by Super's bot from computedriven's brief. Its scope is
  // what the brief reads: the gate and its three static gates, the pinned reference, the tracked battery copy, the
  // frozen crates, R0.9-OPEN, the lab scripts and docs.
  {path:'tools/r09_evidence_gate.py',args:['--check'],scope:['tools/','lab/r09close/','lab/scripts/','receipts/r09-evidence/','receipts/R0.9-OPEN.md','cd-core/','cd-wire/','cd-node/','cd-micro/','cd-connect/','cd-rendezvous/','docs/']},
];
export const gatePaths=()=>gates.map(g=>g.path);
const inScope=(path,scope)=>scope.some(s=>s.endsWith('/')?path.startsWith(s):path===s);
export const gatesIn=listed=>gates.filter(g=>listed.includes(g.path));
// The snapshot each profile is entitled to. Super's own three read the whole
// repository because their suites import across it; the document profile reads only
// the documents under review and executes none of the repository's code; the gate
// profile reads what its gates declare, plus the reviewed paths.
function scopeOf(profile,members,listed){
  const reviewed=members.map(m=>m.source.path);
  if(profile===profiles[3])return new Set(reviewed);
  if(profile===profiles[4]){
    const present=gatesIn(listed);
    assert(present.length,'No gate this profile knows is in this repository: '+gatePaths().join(', ')+'.');
    const scope=present.flatMap(g=>g.scope);
    return new Set([...listed.filter(path=>inScope(path,scope)),...reviewed]);
  }
  return null;
}
const scopeName=profile=>profile===profiles[3]?'reviewed-documents-only':profile===profiles[4]?'gate-scope-and-reviewed-paths':'whole-repository';
async function pinElixirTools(run){
  const asdf=findAsdf(),roots={elixir:execFileSync(asdf,['where','elixir'],{encoding:'utf8',timeout:10000}).trim(),erlang:execFileSync(asdf,['where','erlang'],{encoding:'utf8',timeout:10000}).trim()};
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

export async function runProposalTests({repository,attempt,runRoot,nodePath=process.execPath,timeoutMs=30000,signal,profile=profiles[0],compare=false}){
  attempt=structuredClone(attempt);
  assert(profiles.includes(profile),'Unsupported test profile.');
  assert(Number.isInteger(timeoutMs)&&timeoutMs>=100&&timeoutMs<=ceilings[profile],'Test timeout must be 100–'+ceilings[profile]+' ms for '+profile+'.');
  const {source,members}=checkAttempt(attempt),root=await realpath(repository),base=await realpath(runRoot);
  assert(base!==root&&!base.startsWith(root+sep),'Run artifacts must be outside the source repository.');
  const rootIdentity=await lstat(root);assert(rootIdentity.isDirectory(),'Choose a repository directory.');
  assert(git(root,['rev-parse','--show-toplevel']).trim()===root,'Choose the repository root.');
  assert(git(root,['rev-parse','--verify','HEAD^{commit}']).trim()===source.head,'The source commit changed. Prepare a fresh review.');
  const listed=listPaths(root),scope=scopeOf(profile,members,listed);
  const files=await capture(root,scope);
  for(const member of members){
    const s=member.source,disk=files.get(s.path)?.data;
    // Missing and empty files have distinct identities; ignored members refuse.
    if(!disk){try{await lstat(join(root,s.path));throw Error('The selected file is excluded from the source snapshot: '+s.path);}catch(e){if(e.code!=='ENOENT')throw e;}}
    assert((disk?hash(disk):null)===s.disk_sha256,'The selected source file changed: '+s.path+'. Prepare a fresh review.');
  }
  const before=digest(files),second=await capture(root,scope),afterRoot=await lstat(root);
  assert(before===digest(second)&&rootIdentity.dev===afterRoot.dev&&rootIdentity.ino===afterRoot.ino&&git(root,['rev-parse','--verify','HEAD^{commit}']).trim()===source.head,'Source changed during capture. Retry with a fresh review.');
  const baselineFiles=new Map(files);
  for(const member of members){if(member.proposed_text===null)files.delete(member.source.path);else files.set(member.source.path,{data:Buffer.from(member.proposed_text),mode:files.get(member.source.path)?.mode??0o644});}
  const entries=manifest(files),snapshotDigest=digest(files);
  assert(entries.length<=maxFiles&&entries.reduce((n,f)=>n+f.bytes,0)<=maxBytes,'Proposed snapshot exceeds its bounds.');
  // Closed profiles: no caller-provided command or test path.
  const tests=profile===profiles[0]?entries.map(f=>f.path).filter(p=>/^tools\/[a-z0-9-]+-test\.mjs$/.test(p)):requiredFiles[profile]?requiredFiles[profile]:profile===profiles[4]?gatesIn(listed).map(g=>g.path):members.filter(m=>m.proposed_text!==null).map(m=>m.source.path);
  assert(tests.every(p=>files.has(p)),profile===profiles[3]?'A document review needs the documents it reviews.':profile===profiles[4]?'The snapshot is missing the gate it would run.':'The selected profile requires the Super files for that test profile.');
  assert(tests.length>0&&tests.length<=64,profile===profiles[3]?'A document review needs at least one document that is not a deletion.':profile===profiles[4]?'No gate this profile knows is in this repository.':'No supported JavaScript behavior suites found (tools/*-test.mjs, maximum 64).');
  if(profile===profiles[3]){const {isDocumentPath}=await import(checkerUrl.href);assert(tests.every(isDocumentPath),'The document profile reviews Markdown or text documents (.md, .markdown, .txt).');}
  const executable=await realpath(nodePath),nodeStat=await lstat(executable);assert(nodeStat.isFile()&&nodeStat.size<=128*1024*1024,'Node executable exceeds the runner limit.');const node=await readFile(executable);assert(node.length===nodeStat.size,'Node executable changed during capture.');
  const run=await mkdtemp(join(base,'proposal-tests-')),snapshot=join(run,'snapshot');await mkdir(snapshot,{mode:0o700});
  const record={schema:'local-proposal-test@1',provenance:'human-operated-local-runner',scope:members.length===1?'captured-git-listed-source-with-one-proposal':'captured-git-listed-source-with-proposal-set',snapshot_scope:scopeName(profile),listed_files:listed.length,profile,attempt_ref:attempt.id??null,source_basis_id:source.basis_id,source_head:source.head,source_capture_sha256:before,result_sha256:source.result_sha256,result_path:source.path??null,result_paths:members.map(m=>m.source.path),snapshot_sha256:snapshotDigest,node_sha256:hash(node),tests,timeout_ms:timeoutMs,started_at:new Date().toISOString(),state:'preparing'};
  await atomic(join(run,'manifest.json'),{schema:'proposal-test-snapshot@1',sha256:snapshotDigest,files:entries});
  try{
    for(const [path,f] of files){const target=join(snapshot,path);await mkdir(dirname(target),{recursive:true,mode:0o700});await writeFile(target,f.data,{flag:'wx',mode:f.mode});}
    const baselineSnapshot=join(run,'baseline');
    if(compare){await mkdir(baselineSnapshot,{mode:0o700});for(const [path,f] of baselineFiles){const target=join(baselineSnapshot,path);await mkdir(dirname(target),{recursive:true,mode:0o700});await writeFile(target,f.data,{flag:'wx',mode:f.mode});}await atomic(join(run,'baseline-manifest.json'),{sha256:before,files:manifest(baselineFiles)});}
    // Pin the executable bytes too; do not run a mutable installation path.
    const runtime=join(run,'node');await writeFile(runtime,node,{flag:'wx',mode:0o700});
    // T36: the Elixir profile builds super-host too, so it pins Rust beside Erlang and Elixir; the Rust profile pins the
    // sibling RRABBIT. Every pinned identity goes into one toolchain_sha256 (the runtime records one).
    const toolchain=profile===profiles[1]?await pinElixirTools(run):null,rust=profile===profiles[1]||profile===profiles[2]?await pinRustTools(run):null,sibling=profile===profiles[2]?await pinSibling(root,run):null;
    if(profile===profiles[1])record.toolchain_sha256=compiledToolchainSha256({elixir:toolchain.sha256,rust:rust.sha256});
    if(profile===profiles[2]){record.toolchain_sha256=compiledToolchainSha256({rust:rust.sha256,sibling:sibling.identity});record.sibling=sibling.identity;}
    // The document profile runs Super's own pinned check over the snapshot, never
    // anything from the repository under review; its bytes are hashed into the record.
    let checkPath=null,reviewPath=null;
    if(profile===profiles[3]){
      const checker=await readFile(checkerUrl);record.checker_sha256=hash(checker);
      checkPath=join(run,'check.mjs');await writeFile(checkPath,checker,{flag:'wx',mode:0o400});
      reviewPath=join(run,'review.json');await atomic(reviewPath,{schema:'document-review-manifest@1',documents:tests,paths:[...new Set([...listed,...tests])].sort()});
    }
    record.state='started';record.snapshot_retained=true;await atomic(join(run,'started.json'),record);
    const args=['--unshare-all','--die-with-parent','--new-session','--cap-drop','ALL','--ro-bind','/usr','/usr','--symlink','usr/lib','/lib','--symlink','usr/lib','/lib64','--proc','/proc','--dev','/dev','--tmpfs','/tmp','--dir','/runtime','--ro-bind',runtime,'/runtime/node','--ro-bind',snapshot,'/snapshot','--chdir','/snapshot','--clearenv','--setenv','PATH','/usr/bin','--setenv','HOME','/tmp','--setenv','LANG','C.UTF-8','--','/runtime/node','--test','--test-reporter=tap',...tests];
    // T36: a compiled profile runs its stages, each in a sandbox of its own (compiledStageCommand), judged by the exit
    // status the runner observes (stageOutcome), never by what the code under test prints.
    const compiled=Boolean(stages[profile]);
    const common=snap=>args.slice(0,args.indexOf('--')).map(x=>x===snapshot?snap:x);
    const toolBinds=profile===profiles[1]?[...toolchain.binds,...rust.binds]:profile===profiles[2]?rust.binds:[];
    const toolPath=profile===profiles[1]?toolchain.roots.elixir+'/bin:'+toolchain.roots.erlang+'/bin:/rust/bin:/usr/bin':'/rust/bin:/usr/bin';
    async function runStages(snap,label,timeout){
      const deadline=Date.now()+timeout,results=[];let built=null;
      for(const stage of stages[profile]){
        if(stage.needs&&results.find(r=>r.name===stage.needs)?.outcome!=='built'){results.push({name:stage.name,outcome:'not-run'});continue;}
        let out=null;if(stage.exports){out=join(run,label+'-'+stage.name);await mkdir(out,{mode:0o700});}
        const control=join(run,label+'-'+stage.name+'-control');await mkdir(control,{mode:0o700});
        // No stage starts after the run's deadline (round 2: checked after this stage's setup, which takes time too).
        if(deadline-Date.now()<=0){results.push({name:stage.name,outcome:'incomplete',timed_out:true});continue;}
        const command=[...common(snap),...compiledStageCommand(profile,stage,{toolBinds,path:toolPath,sibling,out,built,control})];
        const r=signal?.aborted?{code:null,signal:null,timedOut:false,launchError:'cancelled',output:'',omitted_bytes:0}:await execute(command,deadline-Date.now(),signal,Math.floor(maxOutput/stages[profile].length),{control,stage:stage.name,deadline});
        let outcome=stageOutcome(stage,r),handed=null;
        if(stage.exports&&outcome==='built'){try{handed=await handOff(out,join(run,label+'-'+stage.name+'-handoff'),stage.exports);built=handed.dir;}catch{outcome='incomplete';}}
        // T43: a stage asked to stop (at its deadline or by a cancellation; the first reason is kept) keeps what it had
        // printed when the request reached it, and the record says when the deadline was and when the stage ended.
        const cut=r.stopped??null;
        results.push({name:stage.name,outcome,exit_code:r.code,signal:r.signal,timed_out:r.timedOut,launch_error:r.launchError,output:r.output,omitted_bytes:r.omitted_bytes,kept:r.kept??null,failures:r.failures??[],failures_overflowed:r.failures_overflowed??false,...(cut?{cut_at:cut}:{}),...(r.ended?{deadline_at:new Date(deadline).toISOString(),ended_at:new Date(r.ended).toISOString()}:{}),...(handed?{handed_on:{name:stage.exports,sha256:handed.sha256,bytes:handed.bytes}}:{})});
      }
      const judged=compiledVerdict(results.map(r=>r.outcome)),failing=results.find(r=>Number.isInteger(r.exit_code)&&r.exit_code!==0);
      const parts=results.map(r=>({prefix:`[runner] stage ${r.name}: ${r.outcome}${Number.isInteger(r.exit_code)?' (exit '+r.exit_code+')':''}\n${r.cut_at?`[runner] stage ${r.name} was stopped at the ${r.cut_at}: what it had printed when the request reached it follows (a request, not an exact cut)\n`:''}`,kept:r.kept}));
      return {...judged,stages:results.map(({output,kept,failures,failures_overflowed,...rest})=>rest),code:failing?failing.exit_code:results.every(r=>r.exit_code===0)?0:null,
        signal:results.find(r=>r.signal)?.signal??null,timedOut:results.some(r=>r.timed_out),launchError:results.find(r=>r.launch_error&&r.launch_error!=='cancelled')?.launch_error??null,
        ...composeParts(parts),parts,...failureIndex(results)};
    }
    if(profile===profiles[4]){
      // The repository's own gate, with the runner's arguments, in the same sandbox:
      // no network, no host home, a read-only snapshot and a tmpfs. A gate that
      // refuses is a FAILED verdict; only a gate that never reaches its last line is
      // an execution failure.
      args.splice(args.indexOf('--'));
      const script=gatesIn(listed).map(g=>`if python3 ${JSON.stringify(g.path)} ${g.args.join(' ')}; then echo "# gate ${g.path} ok"; else echo "# gate ${g.path} failed"; status=1; fi`).join('; ');
      args.push('--symlink','usr/bin','/bin','--setenv','PYTHONDONTWRITEBYTECODE','1','--','/bin/sh','-c',`status=0; ${script}; echo "# gates complete"; exit $status`);
    }
    if(profile===profiles[3]){
      args.splice(args.indexOf('--'));
      args.push('--ro-bind',checkPath,'/runtime/check.mjs','--ro-bind',reviewPath,'/runtime/review.json','--setenv','SUPER_DOCUMENT_REVIEW','/runtime/review.json','--','/runtime/node','--test','--test-reporter=tap','/runtime/check.mjs');
    }
    let baselineParts=null;   // T43 round 2: the baseline transcript's parts, for fitOutcome
    if(compare&&compiled){
      const b=signal?.aborted?null:await runStages(baselineSnapshot,'baseline',timeoutMs);baselineParts=b?.parts??null;
      record.baseline={snapshot_sha256:before,tests,same_suites:true,state:b?.state==='completed'?'completed':'failed',verdict:b?.state==='completed'?b.verdict:null,exit_code:b?.code??null,stages:b?.stages??[],output:b?.output??'',omitted_bytes:b?.omitted_bytes??0,finished_at:new Date().toISOString()};
      await atomic(join(run,'baseline-outcome.json'),record.baseline);
    }else if(compare){
      const baselineArgs=args.map(a=>a===snapshot?baselineSnapshot:a),baselineTests=profile===profiles[0]?manifest(baselineFiles).map(f=>f.path).filter(p=>/^tools\/[a-z0-9-]+-test\.mjs$/.test(p)):tests;
      if(profile===profiles[0])baselineArgs.splice(baselineArgs.indexOf('--test-reporter=tap')+1,tests.length,...baselineTests);
      const b=signal?.aborted?{code:null,output:'',omitted_bytes:0}:baselineTests.length?await execute(baselineArgs,timeoutMs,signal):{code:null,output:'No baseline test suites found.',omitted_bytes:0};
      if(b.kept)baselineParts=[{prefix:'',kept:b.kept}];
      const complete=transcriptComplete(profile,b.signals??[],b.signals_overflowed);
      const completed=complete&&!signal?.aborted&&!b.timedOut&&!b.launchError&&!b.signal;
      record.baseline={snapshot_sha256:before,tests:baselineTests,same_suites:JSON.stringify(baselineTests)===JSON.stringify(tests),state:completed?'completed':'failed',verdict:completed?(b.code===0?'pass':'fail'):null,exit_code:b.code,output:b.output,omitted_bytes:b.omitted_bytes,finished_at:new Date().toISOString()};
      await atomic(join(run,'baseline-outcome.json'),record.baseline);
    }
    const aborted={state:'failed',stages:[],code:null,signal:null,timedOut:false,launchError:null,output:'',omitted_bytes:0};
    const result=signal?.aborted?aborted:compiled?await runStages(snapshot,'candidate',timeoutMs):await execute(args,timeoutMs,signal,maxOutput,{stage:profile===profiles[4]?'gate':'node'});
    const unchanged=await Promise.all(entries.map(async e=>{const f=await exactFile(snapshot,e.path);return hash(f.data)===e.sha256&&f.mode===e.mode;})).then(xs=>xs.every(Boolean));
    const judged=judgeRun(profile,result,{unchanged,aborted:signal?.aborted});
    // T43: the failure index sits beside the transcript; the verdict (judgeRun) never reads it.
    Object.assign(record,{state:judged.state,finished_at:new Date().toISOString(),exit_code:result.code,signal:result.signal,output:result.output,omitted_bytes:result.omitted_bytes,failures:result.failures??[],failures_overflowed:result.failures_overflowed??false});
    if(compiled)record.stages=result.stages;
    if(judged.state==='completed')record.verdict=judged.verdict;
    else record.reason=judged.reason;
    if(compare&&profile===profiles[0]&&!signal?.aborted)record.benchmark=await pairedBenchmark({files,baselineFiles,args,snapshot,baselineSnapshot,signal,before,after:snapshotDigest,nodeHash:record.node_sha256});
    if(signal?.aborted){record.state='failed';record.reason='cancelled';delete record.verdict;}
    // T43 round 2 (fix 1): the record the cockpit reads always fits it.
    fitOutcome(record,[{target:record.baseline,parts:baselineParts},{target:record,parts:compiled?result.parts:result.kept?[{prefix:'',kept:result.kept}]:null}]);
    await atomic(join(run,'outcome.json'),record);return {directory:run,record};
  }catch(e){record.state='failed';record.reason='runner-error';record.finished_at=new Date().toISOString();record.error=String(e.message).slice(0,1000);await atomic(join(run,'outcome.json'),record);throw e;}
  finally{await rm(join(run,'node'),{force:true});await rm(join(run,'toolchain'),{recursive:true,force:true});await rm(join(run,'sibling'),{recursive:true,force:true});for(const label of ['candidate','baseline'])for(const s of stages[profile]??[]){await removeTree(join(run,label+'-'+s.name+'-control'));if(s.exports){await removeTree(join(run,label+'-'+s.name));await removeTree(join(run,label+'-'+s.name+'-handoff'));}}}
}

// Read-only acceptance preflight. It executes no repository code and does not
// overlay a proposal: the saved checkout itself must match the tested snapshot.
export async function verifyTestedCheckout({repository,attempt,run}){
  attempt=structuredClone(attempt);run=structuredClone(run);
  const {source,members}=checkAttempt(attempt),root=await realpath(repository),outcome=run?.outcome;
  assert(run?.state==='completed'&&outcome?.verdict==='pass','A completed passing test run is required.');
  assert(outcome.result_sha256===source.result_sha256&&outcome.source_basis_id===source.basis_id,'The test result belongs to different review material.');
  // The checkout is compared against the snapshot the run actually captured, so
  // the scope is read back from the run's own profile.
  const profile=run?.profile??outcome.profile??profiles[0];
  assert(profiles.includes(profile),'Unsupported test profile.');
  assert(git(root,['rev-parse','--show-toplevel']).trim()===root,'Choose the repository root.');
  const identity=await lstat(root),head=git(root,['rev-parse','--verify','HEAD^{commit}']).trim();
  assert(head===source.head,'The source commit changed. Prepare a fresh review.');
  const scope=scopeOf(profile,members,listPaths(root));
  const files=await capture(root,scope);
  for(const member of members)assert(member.proposed_text===null?!files.has(member.source.path):files.has(member.source.path)&&hash(files.get(member.source.path).data)===member.source.result_sha256,'Save the exact reviewed proposal before accepting it. The selected file differs: '+member.source.path);
  const snapshot=digest(files);assert(snapshot===outcome.snapshot_sha256,'The repository files differ from the passing test snapshot. Prepare a fresh review and test again.');
  const second=await capture(root,scope),after=await lstat(root);
  assert(digest(second)===snapshot&&identity.dev===after.dev&&identity.ino===after.ino&&git(root,['rev-parse','--verify','HEAD^{commit}']).trim()===head,'Files changed during the acceptance check. Try again.');
  return {snapshot_sha256:snapshot,result_sha256:source.result_sha256,head};
}

// Shared bounded capture and isolation primitives for accepted-source builds.
export {capture,manifest,digest,execute,pinRustTools,atomic,listPaths,scopeOf as snapshotScope};

// Fixed benchmark protocol, executed only by the isolated proposal runner.
export function benchmarkMetrics(text){
 const value=JSON.parse(text);assert(Array.isArray(value.metrics)&&value.metrics.length>0&&value.metrics.length<=20,'Emit 1–20 benchmark metrics.');const names=new Set();
 for(const m of value.metrics){assert(typeof m.name==='string'&&m.name.length>0&&m.name.length<=80&&!names.has(m.name)&&Number.isFinite(m.value)&&m.value>=0&&['ns','us','ms','s','bytes','ops/s','items/s','count'].includes(m.unit)&&['lower','higher'].includes(m.direction),'Invalid or duplicate benchmark metric.');names.add(m.name);}
 return value.metrics.map(({name,value,unit,direction})=>({name,value,unit,direction}));
}
async function pairedBenchmark({files,baselineFiles,args,snapshot,baselineSnapshot,signal,before,after,nodeHash}){
 const path='tools/task-benchmark.mjs',a=baselineFiles.get(path),b=files.get(path);
 if(!a||!b)return {state:'not-configured',reason:'Add the same tools/task-benchmark.mjs to both source versions to compare performance.'};
 if(hash(a.data)!==hash(b.data))return {state:'incomparable',reason:'The benchmark entry point changed. Retain the same benchmark on both sides.'};
 const result={state:'running',command:['node',path],script_sha256:hash(a.data),before_snapshot:before,after_snapshot:after,node_sha256:nodeHash,environment:{host:hostname(),platform:platform(),arch:arch(),cpu:cpus()[0]?.model},warmup_runs:1,repetitions:3,samples:{before:[],after:[]},outputs:{before:[],after:[]}};
 try{
  let expected=null;
  for(let round=-1;round<3;round++)for(const side of (round%2===0?['before','after']:['after','before'])){
   assert(!signal?.aborted,'Benchmark cancelled.');const command=args.slice(0,args.indexOf('--')) .map(v=>v===snapshot?(side==='before'?baselineSnapshot:snapshot):v);command.push('--','/runtime/node',path);
   const run=await execute(command,5000,signal);assert(run.code===0&&!run.signal&&!run.timedOut&&!run.launchError&&!run.omitted_bytes,'Benchmark did not finish successfully.');
   const metrics=benchmarkMetrics(run.output),identity=JSON.stringify(metrics.map(m=>[m.name,m.unit,m.direction]));if(expected===null)expected=identity;assert(expected===identity,'Metric names, order, units or direction changed across samples.');
   if(round>=0){result.samples[side].push(metrics);result.outputs[side].push(run.output.slice(0,12000));}
  }
  result.metrics=result.samples.before[0].map((m,i)=>{const stats=side=>{const xs=result.samples[side].map(row=>row[i].value).sort((a,b)=>a-b);return {median:xs[1],min:xs[0],max:xs[2]};};const a=stats('before'),b=stats('after');return {name:m.name,unit:m.unit,direction:m.direction,before:a,after:b,change_percent:a.median===0?null:(b.median-a.median)/a.median*100};});result.state='completed';
 }catch(e){result.state=signal?.aborted?'cancelled':'failed';result.reason=String(e.message).slice(0,1000);}
 return result;
}
