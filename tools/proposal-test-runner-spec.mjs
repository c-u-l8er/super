import test from 'node:test';
import {createServer} from 'node:net';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,readFile,rm,symlink} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {join,resolve} from 'node:path';
import {runProposalTests} from './lib/proposal-test-runner.mjs';
const hash=b=>createHash('sha256').update(b).digest('hex');
const base=process.env.SUPER_RUNNER_TEST_ROOT;if(!base)throw Error('Set SUPER_RUNNER_TEST_ROOT to an existing disposable test directory.');
async function fixture(t,testText="import test from 'node:test';import assert from 'node:assert/strict';import {value} from '../value.mjs';test('proposed behavior',()=>assert.equal(value,2));"){
 const work=await mkdtemp(join(base,'runner-spec-'));t.after(()=>rm(work,{recursive:true,force:true}));const repository=join(work,'repo'),runRoot=join(work,'runs');await mkdir(join(repository,'tools'),{recursive:true});await mkdir(runRoot);await writeFile(join(repository,'value.mjs'),'export const value=1;\n');await writeFile(join(repository,'tools/value-test.mjs'),testText);
 const git=args=>execFileSync('/usr/bin/git',['-C',repository,...args],{encoding:'utf8'}).trim();git(['init','-q']);git(['add','.']);git(['-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture']);
 const draft='export const value=1;\n',proposed='export const value=2;\n',source={schema:'selected-file-basis@1',scope:'selected-file-only',head:git(['rev-parse','HEAD']),path:'value.mjs',disk_sha256:hash(draft),draft_sha256:hash(draft),draft_bytes:Buffer.byteLength(draft),result_sha256:hash(proposed),result_bytes:Buffer.byteLength(proposed)};source.basis_id=hash(JSON.stringify(['selected-file-basis@1',source.head,source.path,source.disk_sha256,source.draft_sha256]));return {repository,runRoot,attempt:{id:'da_fixture',source,shared_draft:draft,proposed_text:proposed}};
}
test('runs actual tests against proposed bytes, saves start and result, preserves source',async t=>{
 const f=await fixture(t),r=await runProposalTests(f);assert.equal(r.record.state,'completed');assert.equal(r.record.verdict,'pass');assert.match(r.record.output,/# tests 1/);assert.equal(await readFile(join(f.repository,'value.mjs'),'utf8'),f.attempt.shared_draft);assert.equal(JSON.parse(await readFile(join(r.directory,'started.json'))).state,'started');assert.deepEqual(JSON.parse(await readFile(join(r.directory,'outcome.json'))),r.record);assert.equal(await readFile(join(r.directory,'snapshot/value.mjs'),'utf8'),f.attempt.proposed_text);assert.equal(r.record.snapshot_retained,true);assert.equal(JSON.parse(await readFile(join(r.directory,'manifest.json'))).sha256,r.record.snapshot_sha256);
});
test('changed proposals get distinct snapshot identities and failed assertions',async t=>{
 const f=await fixture(t),passed=await runProposalTests(f);f.attempt.proposed_text='export const value=3;\n';f.attempt.source.result_sha256=hash(f.attempt.proposed_text);f.attempt.source.result_bytes=Buffer.byteLength(f.attempt.proposed_text);const failed=await runProposalTests(f);assert.equal(failed.record.state,'completed');assert.equal(failed.record.verdict,'fail');assert.notEqual(failed.record.snapshot_sha256,passed.record.snapshot_sha256);assert.match(failed.record.output,/not ok/);
});
test('snapshot cannot write source, read the host home or inherit secrets',async t=>{
 const f=await fixture(t,"import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';test('isolation',()=>{assert.throws(()=>fs.writeFileSync('value.mjs','changed'));assert.throws(()=>fs.readFileSync('/home/travis/.profile'));assert.equal(process.env.SUPER_RUNNER_SECRET,undefined);fs.writeFileSync('/tmp/test','scratch');});");process.env.SUPER_RUNNER_SECRET='fixture-secret';try{assert.equal((await runProposalTests(f)).record.verdict,'pass');}finally{delete process.env.SUPER_RUNNER_SECRET;}
});
test('timeout is an execution failure and has no test verdict',async t=>{
 const f=await fixture(t,"setInterval(()=>{},1000);");const r=await runProposalTests({...f,timeoutMs:300});assert.equal(r.record.state,'failed');assert.equal(r.record.reason,'timeout');assert.equal(r.record.verdict,undefined);
});
test('symlinks, stale source and inconsistent proposal identities refuse before execution',async t=>{
 const f=await fixture(t);await writeFile(join(f.repository,'value.mjs'),'external edit');await assert.rejects(runProposalTests(f),/source file changed/);await writeFile(join(f.repository,'value.mjs'),f.attempt.shared_draft);await symlink('/etc/passwd',join(f.repository,'linked'));await assert.rejects(runProposalTests(f),/Symlinks/);await rm(join(f.repository,'linked'));f.attempt.proposed_text='mismatch';await assert.rejects(runProposalTests(f),/identity mismatch/);
});
test('output overflow is bounded and cannot manufacture a passing result',async t=>{
 const f=await fixture(t,"console.log('x'.repeat(200000));");const r=await runProposalTests(f);assert.ok(Buffer.byteLength(r.record.output)<=128*1024);assert.ok(r.record.omitted_bytes>0);assert.equal(r.record.state,'failed');assert.equal(r.record.verdict,undefined);
});
test('run artifacts inside the source repository refuse',async t=>{
 const f=await fixture(t);await assert.rejects(runProposalTests({...f,runRoot:f.repository}),/outside/);
});

test('tests cannot reach a listener on the host loopback network',async t=>{
 const server=createServer(socket=>socket.end('host-only'));await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>new Promise(r=>server.close(r)));
 const port=server.address().port;
 const f=await fixture(t,`import test from 'node:test';import assert from 'node:assert/strict';import net from 'node:net';test('network isolated',async()=>{const connected=await new Promise(resolve=>{const socket=net.createConnection({host:'127.0.0.1',port:${port}});socket.on('connect',()=>{socket.destroy();resolve(true)});socket.on('error',()=>resolve(false));});assert.equal(connected,false);});`);
 assert.equal((await runProposalTests(f)).record.verdict,'pass');
});

test('cancellation terminates execution without a passing verdict',async t=>{
 const f=await fixture(t,"setInterval(()=>{},1000);"),controller=new AbortController();
 const timer=setTimeout(()=>controller.abort(),700);try{const r=await runProposalTests({...f,signal:controller.signal});assert.equal(r.record.state,'failed');assert.equal(r.record.reason,'cancelled');assert.equal(r.record.verdict,undefined);}finally{clearTimeout(timer);}
});
test('cancellation before launch cannot start the test process',async t=>{
 const f=await fixture(t),controller=new AbortController();controller.abort();const r=await runProposalTests({...f,signal:controller.signal});assert.equal(r.record.reason,'cancelled');assert.equal(r.record.output,'');assert.equal(r.record.verdict,undefined);
});

test('acceptance checks the saved result and all captured source without executing tests',async t=>{
 const {verifyTestedCheckout}=await import('./lib/proposal-test-runner.mjs');const f=await fixture(t),r=await runProposalTests(f),run={state:'completed',outcome:r.record};
 await assert.rejects(verifyTestedCheckout({...f,run}),/Save the exact/);
 await writeFile(join(f.repository,'value.mjs'),f.attempt.proposed_text);
 assert.equal((await verifyTestedCheckout({...f,run})).snapshot_sha256,r.record.snapshot_sha256);
 await writeFile(join(f.repository,'extra.mjs'),'changed');await assert.rejects(verifyTestedCheckout({...f,run}),/repository files differ/);await rm(join(f.repository,'extra.mjs'));
 await writeFile(join(f.repository,'tools/value-test.mjs'),'throw Error("must never execute");');await assert.rejects(verifyTestedCheckout({...f,run}),/repository files differ/);
 await assert.rejects(verifyTestedCheckout({...f,run:{...run,outcome:{...r.record,verdict:'fail'}}}),/passing/);
});

test('unsupported profiles and missing Elixir suites refuse before execution',async t=>{
 const f=await fixture(t);await assert.rejects(runProposalTests({...f,profile:'shell'}),/Unsupported test profile/);await assert.rejects(runProposalTests({...f,profile:'super-elixir-review@1'}),/requires the Super/);
});
test('Elixir compiles in private scratch, pins tools, reports assertions and preserves captured source',async t=>{
 const f=await fixture(t);await mkdir(join(f.repository,'ampd/test'),{recursive:true});
 await writeFile(join(f.repository,'ampd/mix.exs'),`defmodule Fixture.MixProject do
 use Mix.Project
 def project, do: [app: :fixture, version: "0.1.0", deps: []]
end
`);
 await writeFile(join(f.repository,'ampd/test/test_helper.exs'),'ExUnit.start()');
 await writeFile(join(f.repository,'ampd/test/development_task_test.exs'),`defmodule FixtureTaskTest do
 use ExUnit.Case
 test "proposal" do
  assert File.read!("../value.mjs") == "export const value=2;\\n"
 end
end
`);
 await writeFile(join(f.repository,'ampd/test/development_attempt_test.exs'),`defmodule FixtureAttemptTest do
 use ExUnit.Case
 test "scratch isolation" do
  refute File.exists?("/home/travis/.profile")
  assert System.get_env("SUPER_RUNNER_SECRET") == nil
  assert {:error, :erofs} = File.write("/snapshot/value.mjs", "changed")
  File.write!("scratch", "build output")
 end
end
`);
 const passed=await runProposalTests({...f,profile:'super-elixir-review@1',timeoutMs:120000});assert.equal(passed.record.verdict,'pass',passed.record.output);assert.match(passed.record.toolchain_sha256,/^[a-f0-9]{64}$/);assert.match(passed.record.output,/2 tests, 0 failures/);assert.equal(await readFile(join(f.repository,'value.mjs'),'utf8'),f.attempt.shared_draft);await assert.rejects(readFile(join(f.repository,'ampd/scratch')),/ENOENT/);await assert.rejects(readFile(join(passed.directory,'toolchain/elixir/bin/mix')),/ENOENT/);
 f.attempt.proposed_text='export const value=3;\n';f.attempt.source.result_sha256=hash(f.attempt.proposed_text);f.attempt.source.result_bytes=Buffer.byteLength(f.attempt.proposed_text);
 const failed=await runProposalTests({...f,profile:'super-elixir-review@1',timeoutMs:120000});assert.equal(failed.record.verdict,'fail',failed.record.output);assert.match(failed.record.output,/2 tests, 1 failure/);assert.notEqual(failed.record.snapshot_sha256,passed.record.snapshot_sha256);assert.equal(failed.record.toolchain_sha256,passed.record.toolchain_sha256);
});

test('Rust compiles offline against reviewed bytes and separates assertion failures from build failures',async t=>{
 const f=await fixture(t),target=join(f.repository,'tools/native-review');await mkdir(join(target,'src'),{recursive:true});
 await writeFile(join(target,'Cargo.toml'),'[package]\nname = "review_fixture"\nversion = "0.1.0"\nedition = "2021"\n');
 await writeFile(join(target,'Cargo.lock'),'version = 4\n[[package]]\nname = "review_fixture"\nversion = "0.1.0"\n');
 await writeFile(join(target,'src/lib.rs'),`#[test] fn proposal() {assert_eq!(std::fs::read_to_string("../../value.mjs").unwrap(), "export const value=2;\\n");}
#[test] fn isolated() {assert!(!std::path::Path::new("/home/travis/.profile").exists());assert!(std::fs::write("/snapshot/value.mjs", "changed").is_err());}`);
 const run=()=>runProposalTests({...f,profile:'super-rust-review@1',timeoutMs:120000});
 const passed=await run();assert.equal(passed.record.verdict,'pass',passed.record.output);assert.match(passed.record.toolchain_sha256,/^[a-f0-9]{64}$/);assert.match(passed.record.output,/2 passed; 0 failed/);assert.equal(await readFile(join(f.repository,'value.mjs'),'utf8'),f.attempt.shared_draft);
 f.attempt.proposed_text='export const value=3;\n';f.attempt.source.result_sha256=hash(f.attempt.proposed_text);f.attempt.source.result_bytes=Buffer.byteLength(f.attempt.proposed_text);
 const failed=await run();assert.equal(failed.record.verdict,'fail',failed.record.output);assert.match(failed.record.output,/1 passed; 1 failed/);assert.notEqual(failed.record.snapshot_sha256,passed.record.snapshot_sha256);
 await writeFile(join(target,'src/lib.rs'),'this is not valid Rust');const broken=await run();assert.equal(broken.record.state,'failed');assert.equal(broken.record.verdict,undefined);assert.equal(broken.record.reason,'runner-did-not-complete');
});

async function combinedFixture(t){
 const oldTest="import test from 'node:test';import assert from 'node:assert/strict';import {value} from '../value.mjs';test('old contract',()=>assert.equal(value,1));\n";
 const newTest=oldTest.replace('old contract','new contract').replace('value,1','value,2');
 const f=await fixture(t,oldTest),first=f.attempt,source={...first.source,path:'tools/value-test.mjs',disk_sha256:hash(oldTest),draft_sha256:hash(oldTest),draft_bytes:Buffer.byteLength(oldTest),result_sha256:hash(newTest),result_bytes:Buffer.byteLength(newTest)};
 source.basis_id=hash(JSON.stringify(['selected-file-basis@1',source.head,source.path,source.disk_sha256,source.draft_sha256]));
 const files=[first,{source,shared_draft:oldTest,proposed_text:newTest}];
 f.attempt={id:'da_set',schema:'development-review-set@1',files,source:{schema:'selected-file-set-basis@1',scope:'selected-file-set-only',head:source.head,basis_id:hash(JSON.stringify(['selected-file-set-basis@1',files.map(f=>[f.source.path,f.source.basis_id])])),result_sha256:hash(JSON.stringify(['selected-file-set-result@1',files.map(f=>[f.source.path,f.source.result_sha256])]))}};
 return f;
}
test('source and test replacements pass only when applied together',async t=>{
 const f=await combinedFixture(t);
 for(const member of f.attempt.files)assert.equal((await runProposalTests({...f,attempt:member})).record.verdict,'fail');
 const r=await runProposalTests(f);assert.equal(r.record.verdict,'pass');assert.equal(r.record.scope,'captured-git-listed-source-with-proposal-set');assert.deepEqual(r.record.result_paths,['value.mjs','tools/value-test.mjs']);
 for(const member of f.attempt.files){assert.equal(await readFile(join(f.repository,member.source.path),'utf8'),member.shared_draft);assert.equal(await readFile(join(r.directory,'snapshot',member.source.path),'utf8'),member.proposed_text);}
});
test('combined acceptance requires every saved replacement and the exact tested repository',async t=>{
 const {verifyTestedCheckout}=await import('./lib/proposal-test-runner.mjs');const f=await combinedFixture(t),r=await runProposalTests(f),run={state:'completed',outcome:r.record};
 await assert.rejects(verifyTestedCheckout({...f,run}),/Save the exact/);
 await writeFile(join(f.repository,f.attempt.files[0].source.path),f.attempt.files[0].proposed_text);await assert.rejects(verifyTestedCheckout({...f,run}),/tools\/value-test/);
 await writeFile(join(f.repository,f.attempt.files[1].source.path),f.attempt.files[1].proposed_text);assert.equal((await verifyTestedCheckout({...f,run})).result_sha256,f.attempt.source.result_sha256);
 await writeFile(join(f.repository,'extra.txt'),'later edit');await assert.rejects(verifyTestedCheckout({...f,run}),/repository files differ/);
 await assert.rejects(verifyTestedCheckout({...f,run:{...run,outcome:{...r.record,result_sha256:f.attempt.files[0].source.result_sha256}}}),/different review material/);
});
test('combined capture rejects stale second files and malformed or incomplete membership',async t=>{
 const f=await combinedFixture(t);await writeFile(join(f.repository,'tools/value-test.mjs'),'external edit');await assert.rejects(runProposalTests(f),/source file changed: tools\/value-test/);await writeFile(join(f.repository,'tools/value-test.mjs'),f.attempt.files[1].shared_draft);
 for(const change of [a=>a.files.pop(),a=>a.files[1]=a.files[0],a=>a.files.reverse(),a=>a.files[1].proposed_text='forged',a=>a.source.result_sha256='0'.repeat(64),a=>a.schema='development-review-attempt@1',a=>a.files[1].source.repository_ref='other']){const a=structuredClone(f.attempt);change(a);await assert.rejects(runProposalTests({...f,attempt:a}));}
});

async function newFileCombinedFixture(t){
 const f=await fixture(t),source={...f.attempt.source,path:'tools/created-test.mjs',disk_sha256:null,draft_sha256:hash(''),draft_bytes:0};
 const text="import test from 'node:test';import assert from 'node:assert/strict';import {value} from '../value.mjs';test('new file sees combined result',()=>assert.equal(value,2));\n";
 source.result_sha256=hash(text);source.result_bytes=Buffer.byteLength(text);
 source.basis_id=hash(JSON.stringify(['selected-file-basis@1',source.head,source.path,null,source.draft_sha256]));
 const files=[f.attempt,{source,shared_draft:'',proposed_text:text}];
 f.attempt={id:'da_new_file',schema:'development-review-set@1',files,source:{schema:'selected-file-set-basis@1',scope:'selected-file-set-only',head:source.head,basis_id:hash(JSON.stringify(['selected-file-set-basis@1',files.map(f=>[f.source.path,f.source.basis_id])])),result_sha256:hash(JSON.stringify(['selected-file-set-result@1',files.map(f=>[f.source.path,f.source.result_sha256])]))}};
 return f;
}
test('new file combined review tests creation without writing it and accepts only the fully saved result',async t=>{
 const {verifyTestedCheckout}=await import('./lib/proposal-test-runner.mjs');
 const f=await newFileCombinedFixture(t),r=await runProposalTests(f),run={state:'completed',outcome:r.record},created=f.attempt.files[1];
 assert.equal(r.record.verdict,'pass',r.record.output);
 assert.ok(r.record.tests.includes(created.source.path));
 assert.equal(await readFile(join(r.directory,'snapshot',created.source.path),'utf8'),created.proposed_text);
 await assert.rejects(readFile(join(f.repository,created.source.path)),{code:'ENOENT'});
 await writeFile(join(f.repository,'value.mjs'),f.attempt.files[0].proposed_text);
 await assert.rejects(verifyTestedCheckout({...f,run}));
 await writeFile(join(f.repository,created.source.path),created.proposed_text);
 assert.equal((await verifyTestedCheckout({...f,run})).result_sha256,f.attempt.source.result_sha256);
 await writeFile(join(f.repository,created.source.path),created.proposed_text+'// later edit\n');
 await assert.rejects(verifyTestedCheckout({...f,run}));
});
test('new file combined review refuses a destination created after sharing',async t=>{
 const f=await newFileCombinedFixture(t),created=f.attempt.files[1];
 await writeFile(join(f.repository,created.source.path),'// someone else created this\n');
 await assert.rejects(runProposalTests(f),/source file changed/);
 assert.equal(await readFile(join(f.repository,created.source.path),'utf8'),'// someone else created this\n');
});

async function deletionFixture(t){
 const f=await fixture(t,"import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import {value} from '../value.mjs';test('delete obsolete file and update caller',()=>{assert.equal(value,2);assert.equal(fs.existsSync('obsolete.txt'),false);});"),draft='obsolete content\n';
 await writeFile(join(f.repository,'obsolete.txt'),draft);
 const git=args=>execFileSync('/usr/bin/git',['-C',f.repository,...args],{encoding:'utf8'}).trim();git(['add','.']);git(['-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','obsolete file']);
 f.attempt.source.head=git(['rev-parse','HEAD']);const a=f.attempt.source;a.basis_id=hash(JSON.stringify(['selected-file-basis@1',a.head,a.path,a.disk_sha256,a.draft_sha256]));
 const source={...a,schema:'selected-file-deletion-basis@1',path:'obsolete.txt',disk_sha256:hash(draft),draft_sha256:hash(draft),draft_bytes:Buffer.byteLength(draft),result_sha256:hash(JSON.stringify(['deleted-file@1','obsolete.txt'])),result_bytes:0};source.basis_id=hash(JSON.stringify(['selected-file-basis@1',source.head,source.path,source.disk_sha256,source.draft_sha256]));
 const files=[f.attempt,{source,shared_draft:draft,proposed_text:null}];
 f.attempt={id:'da_delete',schema:'development-review-set@1',files,source:{schema:'selected-file-set-basis@1',scope:'selected-file-set-only',head:source.head,basis_id:hash(JSON.stringify(['selected-file-set-basis@1',files.map(f=>[f.source.path,f.source.basis_id])])),result_sha256:hash(JSON.stringify(['selected-file-set-result@1',files.map(f=>[f.source.path,f.source.result_sha256])]))}};return f;
}
test('reviewed deletion tests absence without deleting source and accepts only absence',async t=>{
 const {verifyTestedCheckout}=await import('./lib/proposal-test-runner.mjs');const f=await deletionFixture(t),r=await runProposalTests(f),run={state:'completed',outcome:r.record};
 assert.equal(r.record.verdict,'pass',r.record.output);assert.equal(await readFile(join(f.repository,'obsolete.txt'),'utf8'),'obsolete content\n');await assert.rejects(readFile(join(r.directory,'snapshot/obsolete.txt')),{code:'ENOENT'});
 await writeFile(join(f.repository,'value.mjs'),f.attempt.files[0].proposed_text);await assert.rejects(verifyTestedCheckout({...f,run}),/obsolete/);await rm(join(f.repository,'obsolete.txt'));assert.equal((await verifyTestedCheckout({...f,run})).snapshot_sha256,r.record.snapshot_sha256);
 await writeFile(join(f.repository,'obsolete.txt'),'');await assert.rejects(verifyTestedCheckout({...f,run}),/obsolete/);
});
test('deletion identity rejects empty replacements, missing originals and forged hashes',async t=>{
 const f=await deletionFixture(t);
 for(const change of [a=>a.files[1].proposed_text='',a=>a.files[1].source.schema='selected-file-basis@1',a=>a.files[1].source.disk_sha256=null,a=>a.files[1].source.result_sha256=hash('')]){const a=structuredClone(f.attempt);change(a);await assert.rejects(runProposalTests({...f,attempt:a}));}
});
