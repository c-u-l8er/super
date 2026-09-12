import test from 'node:test';
import assert from 'node:assert/strict';
import {REVIEW_FILE_BYTES,bytesOf} from '../cockpit/ui/review-limits.js';
import {checkFileProposal} from '../cockpit/ui/file-proposal.js';
import {relatedFileSelection,validateContextBatch} from '../cockpit/ui/related-files.js';

// One number, enforced at every page-side edge: exactly the limit passes, one
// byte over is refused. cockpit.js — the file this exists for — is well inside.
const at=(n)=>'x'.repeat(n);
test('the limit is one number, and cockpit.js is inside it',()=>{
  assert.equal(REVIEW_FILE_BYTES,256*1024);
  assert.ok(bytesOf(at(73_000))<REVIEW_FILE_BYTES);
});
test('a bot proposal at the limit is accepted and one byte over is refused',()=>{
  const ref={session:'one',generation:2,key:'a.js',draft:'d'},current={session:'one',generation:2,file:{path:'a.js',draft:'d'}};
  assert.equal(checkFileProposal(ref,{path:'a.js',content:at(REVIEW_FILE_BYTES)},current),at(REVIEW_FILE_BYTES));
  assert.throws(()=>checkFileProposal(ref,{path:'a.js',content:at(REVIEW_FILE_BYTES+1)},current),/too large/);
});
test('an Editor file at the limit is selectable and one byte over is refused',()=>{
  const file=n=>({path:'a.js',original:'o',draft:at(n)});
  assert.equal(relatedFileSelection([file(REVIEW_FILE_BYTES)]).length,1);
  assert.throws(()=>relatedFileSelection([file(REVIEW_FILE_BYTES+1)]),/too large/);
  const item=n=>({reference:{},attachment:{name:'a.js',content:at(n)}});
  assert.equal(validateContextBatch([item(REVIEW_FILE_BYTES)],0).length,1);
  assert.throws(()=>validateContextBatch([item(REVIEW_FILE_BYTES+1)],0));
});
