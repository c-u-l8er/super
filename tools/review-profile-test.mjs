import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';
import {profilePlan,suiteScript,transcriptComplete,transcriptKeeper,profileCeiling,findAsdf,pinSibling,compiledToolchainSha256,runProposalTests} from './lib/proposal-test-runner.mjs';

// T36 (A-13): Super's two compiled review profiles run the suites they are named for. These laws hold the closed
// table to what superlane/t36/TASK.md and AMENDMENT-1.md declare; each has a planted bug that only it catches
// (superlane/t36/plants.py).

const RUST='super-rust-review@1',ELIXIR='super-elixir-review@1';
const CARGO_DONE='^test result: (ok|FAILED)[.] [0-9]+ passed; [0-9]+ failed;';

test('L1 · the Rust profile runs the host and cockpit suites, each offline and locked',()=>{
  const plan=profilePlan(RUST);
  assert.deepEqual(plan.suites,[
    {name:'host',command:'cargo test --offline --locked --manifest-path host/Cargo.toml',done:CARGO_DONE},
    {name:'cockpit',command:'cargo test --offline --locked --manifest-path cockpit/Cargo.toml',done:CARGO_DONE}]);
  assert.deepEqual(plan.requiredFiles,['host/Cargo.toml','host/Cargo.lock','cockpit/Cargo.toml','cockpit/Cargo.lock']);
  const script=suiteScript(RUST);let at=-1;
  for(const s of plan.suites){const i=script.indexOf("'"+s.command+"'");assert.ok(i>at,s.name+' runs, in order');at=i;}
  assert.match(script,/echo "# suites complete"\nexit \$status$/);
});

test('L2 · the Elixir profile builds super-host, then runs the whole ampd suite',()=>{
  const plan=profilePlan(ELIXIR);
  assert.deepEqual(plan.suites,[
    {name:'host-build',command:'cargo build --release --offline --locked --manifest-path host/Cargo.toml',done:'^ *Finished `release` profile'},
    {name:'ampd',command:'cd ampd && mix test --seed 0',done:'^[0-9]+ tests?, [0-9]+ failures?',needsPrevious:true}]);
  assert.deepEqual(plan.requiredFiles,['ampd/mix.exs','ampd/test/test_helper.exs','host/Cargo.toml','host/Cargo.lock']);
  assert.ok(plan.requiredFiles.length<=64,'the runtime records 1–64');
  assert.doesNotMatch(suiteScript(ELIXIR),/mix test [^']*\.exs/);
});

test('L3 · the Elixir sandbox receives exactly the declared environment, with a fixed git identity',()=>{
  assert.deepEqual(profilePlan(ELIXIR).env,{MIX_ENV:'test',ERL_FLAGS:'+S 2:2',XDG_STATE_HOME:'/tmp/state',CARGO_HOME:'/tmp/cargo',CARGO_BUILD_JOBS:'2',RUSTUP_TOOLCHAIN:'stable',
    GIT_AUTHOR_NAME:'Super review',GIT_AUTHOR_EMAIL:'review@super.invalid',GIT_COMMITTER_NAME:'Super review',GIT_COMMITTER_EMAIL:'review@super.invalid'});
  assert.deepEqual(profilePlan(RUST).env,{CARGO_HOME:'/tmp/cargo',CARGO_TARGET_DIR:'/tmp/target',CARGO_BUILD_JOBS:'2',RUSTUP_TOOLCHAIN:'stable'});
});

test('L4 · RRABBIT is captured beside the repository, bound read-only, built from a private copy, and part of the toolchain identity',async t=>{
  const work=await mkdtemp(join(tmpdir(),'t36-sibling-'));t.after(()=>rm(work,{recursive:true,force:true}));
  const repo=join(work,'super'),rr=join(work,'RRABBIT');await mkdir(repo);await mkdir(join(rr,'tier1-proof'),{recursive:true});
  await writeFile(join(rr,'tier1-proof/lib.rs'),'pub const VALUE: u32 = 7;\n');
  const git=args=>execFileSync('/usr/bin/git',['-C',rr,...args],{encoding:'utf8'}).trim();git(['init','-q']);git(['add','.']);git(['-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','sibling']);
  const first=await pinSibling(repo,join(work,'run-1'));
  assert.deepEqual(first.binds,['--ro-bind',join(work,'run-1','sibling'),'/rrabbit']);
  assert.match(suiteScript(RUST),/^mkdir -p \/tmp\/cargo && cp -a \/registry \/tmp\/cargo\/registry && cp -a \/snapshot \/tmp\/source && cp -a \/rrabbit \/tmp\/RRABBIT \|\| exit 1\n/);
  assert.doesNotMatch(suiteScript(ELIXIR),/rrabbit/);
  assert.equal(first.identity.path,'../RRABBIT');assert.equal(first.identity.head,git(['rev-parse','HEAD']));assert.equal(first.identity.files,1);
  await writeFile(join(rr,'tier1-proof/lib.rs'),'pub const VALUE: u32 = 8;\n');
  const second=await pinSibling(repo,join(work,'run-2'));
  assert.notEqual(second.identity.sha256,first.identity.sha256);
  assert.notEqual(compiledToolchainSha256({rust:'r',sibling:second.identity}),compiledToolchainSha256({rust:'r',sibling:first.identity}));
  const lonely=join(work,'elsewhere','super');await mkdir(lonely,{recursive:true});
  await assert.rejects(pinSibling(lonely,join(work,'run-3')),/needs RRABBIT beside the repository/);
});

test('L5 · a run is complete only when every suite reported its summary and the script reached its end',()=>{
  const run=(...cockpit)=>['test result: ok. 2 passed; 0 failed; 0 ignored;','# suite host exit 0',...cockpit,'# suites complete'];
  assert.equal(transcriptComplete(RUST,run('test result: FAILED. 1 passed; 1 failed; 0 ignored;','# suite cockpit exit 101')),true,'a failing suite still completes');
  assert.equal(transcriptComplete(RUST,run()),false,'the cockpit suite never reported');
  assert.equal(transcriptComplete(RUST,run('# suite cockpit did-not-complete exit 101')),false,'it did not compile');
  assert.equal(transcriptComplete(RUST,['# suite cockpit exit 0',...run('# suite cockpit did-not-complete exit 101')]),false,'an earlier line cannot vouch for it');
  assert.equal(transcriptComplete(RUST,run('# suite cockpit exit 0').slice(0,-1)),false,'the script never reached its end');
  assert.equal(transcriptComplete(ELIXIR,['# suite host-build exit 0','1132 tests, 0 failures, 64 skipped','# suite ampd exit 0','# suites complete']),true);
  assert.equal(transcriptComplete(ELIXIR,['# suite host-build did-not-complete exit 101','# suite ampd did-not-complete exit -','# suites complete']),false);
  assert.equal(transcriptComplete('super-javascript-behavior@1',['# tests 3','# fail 0']),true);
  assert.equal(transcriptComplete('repository-python-gate@1',['# gate tools/x.py ok','# gates complete']),true);
});

test('L6 · a 15 MB transcript keeps its end, and its summary still proves completion',()=>{
  const keeper=transcriptKeeper(),noise=Buffer.from(('x'.repeat(99)+'\n').repeat(655)),start=Buffer.from('# suite host-build exit 0\n');
  keeper.push(start);let total=start.length;
  while(total<15*1024*1024){keeper.push(noise);total+=noise.length;}
  for(const piece of ['1132 tests, 0 fai','lures, 64 skipped\n# suite ampd exit 0\n# suit','es complete\n']){keeper.push(Buffer.from(piece));total+=Buffer.byteLength(piece);}
  const kept=keeper.finish();
  assert.ok(Buffer.byteLength(kept.output)<=128*1024+64,'bounded');
  assert.ok(kept.output.startsWith('# suite host-build exit 0\n'),'the start is kept');
  assert.ok(kept.output.endsWith('1132 tests, 0 failures, 64 skipped\n# suite ampd exit 0\n# suites complete\n'),'the end is kept');
  assert.equal(kept.omitted_bytes,total-64*1024-64*1024);
  assert.ok(kept.signals.includes('1132 tests, 0 failures, 64 skipped'),'a summary split across chunks is still read');
  assert.equal(transcriptComplete(ELIXIR,kept.signals),true);
});

test('L7 · each profile has its own ceiling, and the CLI uses the table',async()=>{
  assert.deepEqual(['super-javascript-behavior@1',ELIXIR,RUST,'repository-document-review@1','repository-python-gate@1'].map(profileCeiling),[30000,900000,600000,30000,120000]);
  await assert.rejects(runProposalTests({repository:'/nonexistent',attempt:{},runRoot:tmpdir(),profile:RUST,timeoutMs:600001}),/Test timeout must be 100–600000 ms/);
  await assert.rejects(runProposalTests({repository:'/nonexistent',attempt:{},runRoot:tmpdir(),profile:'super-javascript-behavior@1',timeoutMs:30001}),/Test timeout must be 100–30000 ms/);
  await assert.rejects(runProposalTests({repository:'/nonexistent',attempt:{},runRoot:tmpdir(),profile:RUST,timeoutMs:600000}),/selected-file review attempt/);
  assert.match(readFileSync(new URL('./proposal-test-runner.mjs',import.meta.url),'utf8'),/timeoutMs:profileCeiling\(/);
});

test('L8 · the review panel says what each profile runs',()=>{
  const panel=readFileSync(new URL('../cockpit/ui/review-test-panel.js',import.meta.url),'utf8');
  assert.ok(panel.includes("'super-rust-review@1':'Rust: host and cockpit suites'"));
  assert.ok(panel.includes("'super-elixir-review@1':'Elixir: the whole ampd suite'"));
  for(const stale of ['Focused native test target','Rust review and reply tests','Elixir plan and review tests','Rust tests cover review recovery','native review suites'])assert.ok(!panel.includes(stale),stale);
});

test('L9 · asdf is found from the cockpit\'s own environment, in a closed order',()=>{
  const cockpit='/home/travis/.asdf/shims:/home/travis/.cargo/bin:/home/travis/.nvm/versions/node/v25.2.1/bin:/usr/local/bin:/usr/bin:/bin';
  const exists=(...paths)=>p=>paths.includes(p);
  assert.equal(findAsdf({env:{PATH:cockpit,HOME:'/home/travis'},isExecutable:exists('/home/travis/.asdf/bin/asdf')}),'/home/travis/.asdf/bin/asdf');
  assert.equal(findAsdf({env:{PATH:'/opt/a/bin:'+cockpit,HOME:'/home/travis'},isExecutable:exists('/opt/a/bin/asdf','/home/travis/.asdf/bin/asdf')}),'/opt/a/bin/asdf','PATH wins');
  assert.equal(findAsdf({env:{PATH:cockpit,HOME:'/home/travis',ASDF_DIR:'/srv/asdf'},isExecutable:exists('/srv/asdf/bin/asdf','/home/travis/.asdf/bin/asdf')}),'/srv/asdf/bin/asdf','then ASDF_DIR');
  assert.throws(()=>findAsdf({env:{PATH:cockpit,HOME:'/home/travis'},isExecutable:exists()}),/^Error: Elixir and Erlang must be installed with asdf; no asdf executable was found on PATH, in \$ASDF_DIR\/bin or in ~\/\.asdf\/bin\.$/);
});
