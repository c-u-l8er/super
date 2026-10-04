import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {mkdtemp,mkdir,writeFile,readFile,readdir,lstat,symlink,rm,chmod} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';
import {profilePlan,stageScript,compiledStageCommand,stageOutcome,compiledVerdict,transcriptComplete,transcriptKeeper,profileCeiling,findAsdf,pinSibling,compiledToolchainSha256,handOff,runProposalTests} from './lib/proposal-test-runner.mjs';
import {recordDescription} from '../cockpit/ui/review-profile-labels.js';

// T36 (A-13): Super's two compiled review profiles run the suites they are named for, each stage in a sandbox of its
// own, judged by the exit status the runner observes. These laws hold the closed table and its application to what
// superlane/t36/TASK.md and its amendments declare; each has a planted bug that only it catches (superlane/t36/plants.py).

const RUST='super-rust-review@1',ELIXIR='super-elixir-review@1';
const stage=(profile,name)=>profilePlan(profile).stages.find(s=>s.name===name);
const ctx={toolBinds:['--ro-bind','/t/rust','/rust'],path:'/rust/bin:/usr/bin',sibling:{binds:['--ro-bind','/run/sibling','/rrabbit']},out:'/run/candidate-host-build',built:'/run/candidate-host-build'};
const pairs=args=>{const env={};for(let i=0;i<args.length;i++)if(args[i]==='--setenv'){env[args[i+1]]=args[i+2];i+=2;}return env;};
const binds=args=>{const out=[];for(let i=0;i<args.length;i++)if(['--bind','--ro-bind'].includes(args[i])){out.push([args[i],args[i+1],args[i+2]]);i+=2;}return out;};

test('L1 · the Rust profile runs the host and cockpit suites, compiling each before its tests',()=>{
  const plan=profilePlan(RUST);
  assert.deepEqual(plan.stages,[
    {name:'host',cargo:true,script:'cargo test --no-run --offline --locked --manifest-path host/Cargo.toml || exit 125; exec cargo test --offline --locked --manifest-path host/Cargo.toml',outcomes:{0:'pass',101:'fail'}},
    {name:'cockpit',cargo:true,sibling:true,script:'cargo test --no-run --offline --locked --manifest-path cockpit/Cargo.toml || exit 125; exec cargo test --offline --locked --manifest-path cockpit/Cargo.toml',outcomes:{0:'pass',101:'fail'}}]);
  assert.deepEqual(plan.requiredFiles,['host/Cargo.toml','host/Cargo.lock','cockpit/Cargo.toml','cockpit/Cargo.lock']);
});

test('L2 · the Elixir profile builds super-host, hands on only its binary, then runs the whole ampd suite',()=>{
  const plan=profilePlan(ELIXIR);
  assert.deepEqual(plan.stages,[
    {name:'host-build',cargo:true,exports:'super-host',script:'cargo build --release --offline --locked --manifest-path host/Cargo.toml && cp host/target/release/super-host /out/super-host',outcomes:{0:'built'}},
    {name:'ampd',needs:'host-build',script:'cd ampd && { mix compile || exit 125; } && exec mix test --seed 0',outcomes:{0:'pass',2:'fail'}}]);
  assert.deepEqual(plan.requiredFiles,['ampd/mix.exs','ampd/test/test_helper.exs','host/Cargo.toml','host/Cargo.lock']);
  assert.ok(stageScript(ELIXIR,stage(ELIXIR,'ampd')).includes('mkdir -p /tmp/source/host/target/release && cp /built/super-host /tmp/source/host/target/release/super-host && chmod 755 /tmp/source/host/target/release/super-host && cd /tmp/source'));
});

test('L3 · every stage receives exactly its profile\'s environment, with a fixed git identity for Elixir',()=>{
  const elixirEnv={MIX_ENV:'test',ERL_FLAGS:'+S 2:2',XDG_STATE_HOME:'/tmp/state',CARGO_HOME:'/tmp/cargo',CARGO_BUILD_JOBS:'2',RUSTUP_TOOLCHAIN:'stable',
    GIT_AUTHOR_NAME:'Super review',GIT_AUTHOR_EMAIL:'review@super.invalid',GIT_COMMITTER_NAME:'Super review',GIT_COMMITTER_EMAIL:'review@super.invalid'};
  const rustEnv={CARGO_HOME:'/tmp/cargo',CARGO_TARGET_DIR:'/tmp/target',CARGO_BUILD_JOBS:'2',RUSTUP_TOOLCHAIN:'stable'};
  assert.deepEqual(profilePlan(ELIXIR).env,elixirEnv);assert.deepEqual(profilePlan(RUST).env,rustEnv);
  for(const s of profilePlan(ELIXIR).stages)assert.deepEqual(pairs(compiledStageCommand(ELIXIR,s,ctx)),{PATH:ctx.path,...elixirEnv},s.name);
  for(const s of profilePlan(RUST).stages)assert.deepEqual(pairs(compiledStageCommand(RUST,s,ctx)),{PATH:ctx.path,...rustEnv},s.name);
});

test('L4 · RRABBIT is captured beside the repository, bound read-only, built from a private copy, and part of the toolchain identity',async t=>{
  const work=await mkdtemp(join(tmpdir(),'t36-sibling-'));t.after(()=>rm(work,{recursive:true,force:true}));
  const repo=join(work,'super'),rr=join(work,'RRABBIT');await mkdir(repo);await mkdir(join(rr,'tier1-proof'),{recursive:true});
  await writeFile(join(rr,'tier1-proof/lib.rs'),'pub const VALUE: u32 = 7;\n');
  const git=args=>execFileSync('/usr/bin/git',['-C',rr,...args],{encoding:'utf8'}).trim();git(['init','-q']);git(['add','.']);git(['-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','sibling']);
  const first=await pinSibling(repo,join(work,'run-1'));
  assert.deepEqual(first.binds,['--ro-bind',join(work,'run-1','sibling'),'/rrabbit']);
  assert.equal(first.identity.path,'../RRABBIT');assert.equal(first.identity.head,git(['rev-parse','HEAD']));assert.equal(first.identity.files,1);
  const cockpit=compiledStageCommand(RUST,stage(RUST,'cockpit'),{...ctx,sibling:first});
  assert.deepEqual(binds(cockpit).filter(b=>b[2]==='/rrabbit'),[['--ro-bind',join(work,'run-1','sibling'),'/rrabbit']]);
  assert.match(stageScript(RUST,stage(RUST,'cockpit')),/ && cp -a \/rrabbit \/tmp\/RRABBIT && /);
  assert.ok(!binds(compiledStageCommand(RUST,stage(RUST,'host'),{...ctx,sibling:first})).some(b=>b[2]==='/rrabbit'),'the host stage does not see RRABBIT');
  await writeFile(join(rr,'tier1-proof/lib.rs'),'pub const VALUE: u32 = 8;\n');
  const second=await pinSibling(repo,join(work,'run-2'));
  assert.notEqual(second.identity.sha256,first.identity.sha256);
  assert.notEqual(compiledToolchainSha256({rust:'r',sibling:second.identity}),compiledToolchainSha256({rust:'r',sibling:first.identity}));
  const lonely=join(work,'elsewhere','super');await mkdir(lonely,{recursive:true});
  await assert.rejects(pinSibling(lonely,join(work,'run-3')),/needs RRABBIT beside the repository/);
});

test('L5 · a stage\'s outcome is the exit status the runner saw, and a run passes only when every stage did',()=>{
  const host=stage(RUST,'host'),ampd=stage(ELIXIR,'ampd'),build=stage(ELIXIR,'host-build');
  const seen=(code,more={})=>({code,signal:null,timedOut:false,launchError:null,...more});
  assert.equal(stageOutcome(host,seen(0)),'pass');assert.equal(stageOutcome(host,seen(101)),'fail');
  for(const code of [125,124,1,2,null])assert.equal(stageOutcome(host,seen(code)),'incomplete','exit '+code+' is no verdict');
  assert.equal(stageOutcome(host,seen(0,{timedOut:true})),'incomplete');assert.equal(stageOutcome(host,seen(0,{signal:'SIGKILL'})),'incomplete');assert.equal(stageOutcome(host,seen(0,{launchError:'ENOENT'})),'incomplete');
  assert.equal(stageOutcome(ampd,seen(0)),'pass');assert.equal(stageOutcome(ampd,seen(2)),'fail');assert.equal(stageOutcome(ampd,seen(1)),'incomplete');assert.equal(stageOutcome(ampd,seen(125)),'incomplete');
  assert.equal(stageOutcome(build,seen(0)),'built');assert.equal(stageOutcome(build,seen(101)),'incomplete');
  assert.deepEqual(compiledVerdict(['pass','pass']),{state:'completed',verdict:'pass'});
  assert.deepEqual(compiledVerdict(['built','fail']),{state:'completed',verdict:'fail'});
  for(const o of [['pass','incomplete'],['incomplete','not-run'],[]])assert.deepEqual(compiledVerdict(o),{state:'failed'},JSON.stringify(o));
  assert.throws(()=>transcriptComplete(RUST,['# tests 1','# fail 0']),/judged by its stages/);
});

test('L6 · a transcript keeps its start and end, joins no lines across streams, and fails closed on too many signals',()=>{
  const keeper=transcriptKeeper(),noise=Buffer.from(('x'.repeat(99)+'\n').repeat(655)),start=Buffer.from('start of the run\n');
  keeper.push(start);let total=start.length;
  while(total<15*1024*1024){keeper.push(noise);total+=noise.length;}
  for(const piece of ['# tes','ts 1132\n# fail 0\n']){keeper.push(Buffer.from(piece));total+=Buffer.byteLength(piece);}
  const kept=keeper.finish();
  assert.ok(Buffer.byteLength(kept.output)<=128*1024+64,'bounded');
  assert.ok(kept.output.startsWith('start of the run\n'));assert.ok(kept.output.endsWith('# tests 1132\n# fail 0\n'));
  assert.equal(kept.omitted_bytes,total-64*1024-64*1024);
  assert.equal(transcriptComplete('super-javascript-behavior@1',kept.signals,kept.signals_overflowed),true,'a summary split across chunks is still read');
  const small=transcriptKeeper(16),text='aaaaaaa€bbbb';small.push(Buffer.from(text));
  assert.equal(small.finish().output,text,'nothing omitted: the bytes are kept whole, even a character across the halves');
  const streams=transcriptKeeper();streams.push(Buffer.from('# te'),'stdout');streams.push(Buffer.from('sts 3\n# fail 0\n'),'stderr');streams.push(Buffer.from('\n'),'stdout');
  assert.deepEqual(streams.finish().signals,['# fail 0'],'stdout and stderr fragments never join');
  const long=transcriptKeeper();long.push(Buffer.from('y'.repeat(5000)));long.push(Buffer.from('# gates complete\n'));
  assert.deepEqual(long.finish().signals,[],'no part of an overlong line poses as a line');
  const complete=transcriptKeeper();complete.push(Buffer.from('# tests 1'+' '.repeat(5000)+'\n'));
  assert.deepEqual(complete.finish().signals,[],'an overlong line that arrives whole is not a signal either');
  const split=transcriptKeeper();split.push(Buffer.from([0xe2]),'stdout');split.push(Buffer.from('X'),'stderr');split.push(Buffer.from([0x82,0xac]),'stdout');
  const joined=split.finish();assert.equal(joined.output,'X€','a character is never split between the streams');assert.equal(joined.omitted_bytes,0);
  const cut=transcriptKeeper(16);cut.push(Buffer.from('a'.repeat(8)));cut.push(Buffer.from('€'.repeat(10)));
  const trimmed=cut.finish(),[h,t]=trimmed.output.split(/\n\[… \d+ bytes omitted …\]\n/);
  assert.equal(h,'aaaaaaaa');assert.equal(t,'€€','a cut never starts inside a character');
  assert.equal(trimmed.omitted_bytes,38-Buffer.byteLength(h)-Buffer.byteLength(t),'the omitted count is exactly what was not kept');
  const flood=transcriptKeeper();flood.push(Buffer.from('# tests 1\n# fail 0\n'));for(let i=0;i<5000;i++)flood.push(Buffer.from('# gate x ok\n'));flood.push(Buffer.from('# tests 3\n# fail 3\n'));
  const flooded=flood.finish();assert.equal(flooded.signals_overflowed,true);assert.equal(transcriptComplete('super-javascript-behavior@1',flooded.signals,flooded.signals_overflowed),false);
});

test('L7 · each profile has its own ceiling, and the CLI uses the table',async()=>{
  assert.deepEqual(['super-javascript-behavior@1',ELIXIR,RUST,'repository-document-review@1','repository-python-gate@1'].map(profileCeiling),[30000,900000,600000,30000,120000]);
  await assert.rejects(runProposalTests({repository:'/nonexistent',attempt:{},runRoot:tmpdir(),profile:RUST,timeoutMs:600001}),/Test timeout must be 100–600000 ms/);
  await assert.rejects(runProposalTests({repository:'/nonexistent',attempt:{},runRoot:tmpdir(),profile:'super-javascript-behavior@1',timeoutMs:30001}),/Test timeout must be 100–30000 ms/);
  await assert.rejects(runProposalTests({repository:'/nonexistent',attempt:{},runRoot:tmpdir(),profile:RUST,timeoutMs:600000}),/selected-file review attempt/);
  assert.match(readFileSync(new URL('./proposal-test-runner.mjs',import.meta.url),'utf8'),/timeoutMs:profileCeiling\(/);
});

test('L8 · a recorded run is described by what it ran, before and after T36',()=>{
  const now={profile:RUST,tests:['host/Cargo.toml','host/Cargo.lock','cockpit/Cargo.toml','cockpit/Cargo.lock']};
  const then={profile:RUST,tests:['tools/native-review/Cargo.toml','tools/native-review/Cargo.lock','tools/native-review/src/lib.rs']};
  assert.deepEqual(recordDescription(now),{label:'Rust: host and cockpit suites',detail:'Host and cockpit suites',toolchain:'Rust toolchain, cached dependencies and RRABBIT: '});
  assert.deepEqual(recordDescription(then),{label:'Rust (native review target, before T36)',detail:'Native review target',toolchain:'Rust toolchain and cached dependencies: '});
  assert.equal(recordDescription({profile:ELIXIR,tests:['ampd/test/development_task_test.exs','ampd/test/development_attempt_test.exs']}).detail,'Two development_* test files');
  assert.equal(recordDescription({profile:ELIXIR,tests:['ampd/mix.exs','ampd/test/test_helper.exs','host/Cargo.toml','host/Cargo.lock']}).detail,'super-host build and the whole ampd suite');
  assert.equal(recordDescription({profile:'repository-python-gate@1',tests:['a.py']}).detail,'1 repository gate');
  const panel=readFileSync(new URL('../cockpit/ui/review-test-panel.js',import.meta.url),'utf8');
  assert.match(panel,/from '\.\/review-profile-labels\.js'/);
  for(const stale of ['Focused native test target','Rust review and reply tests','Elixir plan and review tests','Rust tests cover review recovery'])assert.ok(!panel.includes(stale),stale);
});

test('L9 · asdf is found from the cockpit\'s own environment, in a closed order, executable for this user',async t=>{
  const cockpit='/home/travis/.asdf/shims:/home/travis/.cargo/bin:/home/travis/.nvm/versions/node/v25.2.1/bin:/usr/local/bin:/usr/bin:/bin';
  const exists=(...paths)=>p=>paths.includes(p);
  assert.equal(findAsdf({env:{PATH:cockpit,HOME:'/home/travis'},isExecutable:exists('/home/travis/.asdf/bin/asdf')}),'/home/travis/.asdf/bin/asdf');
  assert.equal(findAsdf({env:{PATH:'/opt/a/bin:'+cockpit,HOME:'/home/travis'},isExecutable:exists('/opt/a/bin/asdf','/home/travis/.asdf/bin/asdf')}),'/opt/a/bin/asdf','PATH wins');
  assert.equal(findAsdf({env:{PATH:cockpit,HOME:'/home/travis',ASDF_DIR:'/srv/asdf'},isExecutable:exists('/srv/asdf/bin/asdf','/home/travis/.asdf/bin/asdf')}),'/srv/asdf/bin/asdf','then ASDF_DIR');
  assert.throws(()=>findAsdf({env:{PATH:cockpit,HOME:'/home/travis'},isExecutable:exists()}),/^Error: Elixir and Erlang must be installed with asdf; no asdf executable was found on PATH, in \$ASDF_DIR\/bin or in ~\/\.asdf\/bin\.$/);
  const work=await mkdtemp(join(tmpdir(),'t36-asdf-'));t.after(()=>rm(work,{recursive:true,force:true}));
  await mkdir(join(work,'path'));await mkdir(join(work,'home/.asdf/bin'),{recursive:true});
  await writeFile(join(work,'path/asdf'),'#!/bin/sh\n');await chmod(join(work,'path/asdf'),0o644);
  await writeFile(join(work,'home/.asdf/bin/asdf'),'#!/bin/sh\n');await chmod(join(work,'home/.asdf/bin/asdf'),0o755);
  assert.equal(findAsdf({env:{PATH:join(work,'path'),HOME:join(work,'home')}}),join(work,'home/.asdf/bin/asdf'),'a file that is not executable is passed over');
});

test('L10 · each stage runs from a fresh copy into a transcript file of its own, and only super-host\'s binary passes on, as a read-only copy the runner made',async t=>{
  for(const profile of [RUST,ELIXIR])for(const s of profilePlan(profile).stages){
    assert.match(stageScript(profile,s),/cp -a \/snapshot \/tmp\/source/,s.name+' copies the snapshot afresh');
    assert.ok(stageScript(profile,s).includes('\n('+s.script+') > /tmp/stage.log 2>&1\ncode=$?\n')&&stageScript(profile,s).endsWith('\ncat /tmp/stage.log\nexit $code'),s.name+' writes to a file of its own sandbox, never to the runner\'s pipe, prints it and keeps its exit status (T43 adds the print-once lock between)');
    const writable=binds(compiledStageCommand(profile,s,ctx)).filter(b=>b[0]==='--bind').map(b=>b[2]);
    assert.deepEqual(writable,s.exports?['/out']:[],s.name+' writes nothing outside its own sandbox but its export');
  }
  const ampd=binds(compiledStageCommand(ELIXIR,stage(ELIXIR,'ampd'),ctx));
  assert.deepEqual(ampd.filter(b=>b[2]==='/built'),[['--ro-bind',ctx.built,'/built']]);
  assert.throws(()=>compiledStageCommand(ELIXIR,stage(ELIXIR,'ampd'),{...ctx,built:null}),/what the stage before it built/);
  const work=await mkdtemp(join(tmpdir(),'t36-handoff-'));t.after(()=>rm(work,{recursive:true,force:true}));
  const out=join(work,'out');await mkdir(join(out,'sub'),{recursive:true});
  await writeFile(join(out,'super-host'),'the binary');await writeFile(join(out,'extra.txt'),'smuggled');await writeFile(join(out,'sub/more'),'smuggled');
  const handed=await handOff(out,join(work,'handoff'),'super-host');
  assert.deepEqual(await readdir(handed.dir),['super-host'],'nothing else the build wrote passes on');
  assert.equal(await readFile(join(handed.dir,'super-host'),'utf8'),'the binary');assert.equal((await lstat(join(handed.dir,'super-host'))).mode&0o777,0o555);
  const linked=join(work,'linked');await mkdir(linked);await symlink(join(out,'extra.txt'),join(linked,'super-host'));
  await assert.rejects(handOff(linked,join(work,'h2'),'super-host'),/one bounded regular file/);
  const empty=join(work,'empty');await mkdir(empty);await writeFile(join(empty,'super-host'),'');
  await assert.rejects(handOff(empty,join(work,'h3'),'super-host'),/one bounded regular file/);
});
