import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {checkDocument,checkDocumentBytes,linkTargets,repositoryTarget,resolveAgainst,isDocumentPath} from './lib/document-review-check.mjs';
import {capture,manifest} from './lib/proposal-test-runner.mjs';

// The document profile's check, and the scoped snapshot that lets a repository
// Super is not take a review at all. The two belong in one file because they are
// one claim: a repository of any size is admissible when the snapshot is the
// reviewed documents and the check is Super's own.

const paths=['README.md','docs/design.md','docs/spec/kernel.md','src/main.rs'];
const doc=(text,path='docs/design.md')=>checkDocument({path,text,paths});

test('a well-formed document has nothing to report',()=>{
  assert.deepEqual(doc('# Title\n\nSee [the kernel](spec/kernel.md) and [main](../src/main.rs).\n'),[]);
});
test('bytes that are not UTF-8 are reported before anything else',()=>{
  assert.deepEqual(checkDocumentBytes({path:'docs/design.md',bytes:Buffer.from([0x23,0xff,0xfe,0x0a]),paths}),['is not valid UTF-8']);
  assert.deepEqual(checkDocumentBytes({path:'docs/design.md',bytes:Buffer.from('# ok\n'),paths}),[]);
});
test('a document must be whole: non-empty, newline-terminated, no NUL, no CR',()=>{
  assert.deepEqual(doc(''),['is empty']);
  assert.deepEqual(doc('# Title'),['does not end with a newline']);
  assert.deepEqual(doc('# Title\r\n'),['contains a carriage return']);
  assert.deepEqual(doc('# Title\0\n'),['contains a NUL byte']);
});
test('a merge conflict and an unclosed fence are refused',()=>{
  assert.deepEqual(doc('# T\n\n<<<<<<< HEAD\na\n=======\nb\n>>>>>>> other\n'),
    ['line 3 is a merge conflict marker','line 5 is a merge conflict marker','line 7 is a merge conflict marker']);
  assert.deepEqual(doc('# T\n\n```\nopen\n'),['has an unclosed fenced block']);
  assert.deepEqual(doc('# T\n\n```\nclosed\n```\n'),[]);
});
test('a link to a path the repository does not have is refused, with its line',()=>{
  assert.deepEqual(doc('# T\n\n[gone](spec/missing.md)\n'),['line 3 links to spec/missing.md, which is not in the repository']);
  assert.deepEqual(doc('# T\n\n[up](../README.md) [dir](spec) [here](design.md)\n'),[]);
  assert.deepEqual(doc('# T\n\n[out](../../escape.md)\n'),['line 3 links to ../../escape.md, which is not in the repository']);
});
test('what is not a repository path is not checked as one',()=>{
  for(const target of ['https://example.invalid/x','#anchor','mailto:a@b.invalid','/site/page','every 2','law'])
    assert.equal(repositoryTarget(target),null,target);
  assert.equal(repositoryTarget('docs/x.md#section'),'docs/x.md');
  assert.equal(resolveAgainst('docs/design.md','../src/main.rs'),'src/main.rs');
  assert.equal(resolveAgainst('README.md','../up.md'),null);
});
test('fenced and inline code are content, not links',()=>{
  const wrl='# T\n\n```wrl\n[door:L1](law){sig_in}\n[spinner:sp](w=16, n=8)\n```\n\nand `[x](y.md)` inline.\n';
  assert.deepEqual(linkTargets(wrl),[]);
  assert.deepEqual(doc(wrl),[]);
});
test('only documents are documents',()=>{
  for(const p of ['a.md','A.MD','notes/b.markdown','c.txt'])assert.equal(isDocumentPath(p),true,p);
  for(const p of ['a.rs','b.mjs','c',''])assert.equal(isDocumentPath(p),false,p);
  assert.deepEqual(checkDocument({path:'src/main.rs',text:'# T\n',paths}),['is not a document (.md, .markdown, .txt)']);
});

// The bound that shut TRVM and computedriven out: 1024 Git-listed files. A
// repository twice that size is admissible when the snapshot is scoped to the
// document under review.
async function bigRepository(t,count=2000){
  const root=await mkdtemp(join(process.env.TMPDIR??tmpdir(),'document-review-'));
  t.after(()=>rm(root,{recursive:true,force:true}));
  await mkdir(join(root,'many'));
  await Promise.all(Array.from({length:count},(_,i)=>writeFile(join(root,'many',`f${i}.txt`),`file ${i}\n`)));
  await writeFile(join(root,'note.md'),'# Note\n\nOne reviewed document beside [many](many).\n');
  execFileSync('/usr/bin/git',['-C',root,'init','-q'],{env:{PATH:'/usr/bin:/bin',HOME:root,GIT_CONFIG_NOSYSTEM:'1',GIT_CONFIG_GLOBAL:'/dev/null'}});
  return root;
}
test('a 2000-file repository refuses a whole-repository snapshot and admits a scoped one',async t=>{
  const root=await bigRepository(t);
  await assert.rejects(capture(root),/1–1024 Git-listed source files/);
  const files=await capture(root,new Set(['note.md']));
  assert.deepEqual(manifest(files).map(f=>f.path),['note.md']);
  assert.ok(manifest(files)[0].bytes<32*1024*1024);
});
test('a scoped snapshot takes only Git-listed paths, and an unlisted one is simply absent',async t=>{
  const root=await bigRepository(t,10);
  await writeFile(join(root,'.gitignore'),'ignored.md\n');
  await writeFile(join(root,'ignored.md'),'# Ignored\n');
  assert.deepEqual(manifest(await capture(root,new Set(['ignored.md','note.md']))).map(f=>f.path),['note.md']);
});
