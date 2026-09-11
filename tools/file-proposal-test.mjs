import test from 'node:test';import assert from 'node:assert/strict';import {checkFileProposal} from '../cockpit/ui/file-proposal.js';
const ref={session:'one',generation:2,key:'index.html',draft:'before'},proposal={path:'index.html',content:'after'},current={session:'one',generation:2,file:{path:'index.html',draft:'before'}};
test('only the exact shared editor snapshot can become a draft',()=>assert.equal(checkFileProposal(ref,proposal,current),'after'));
test('changed drafts and replaced repositories do not accept old proposals',()=>{for(const state of [{...current,session:'two'},{...current,generation:3},{...current,file:{path:'index.html',draft:'new work'}},{...current,file:null}])assert.throws(()=>checkFileProposal(ref,proposal,state));});
test('unshared files, excerpts and oversized proposals are refused',()=>{for(const [r,p] of [[null,proposal],[{...ref,draft:undefined},proposal],[ref,{...proposal,path:'other.html'}],[ref,{...proposal,content:'x'.repeat(32001)}]])assert.throws(()=>checkFileProposal(r,p,current));});
test('empty replacement text is reviewable and never mutates the current draft',()=>{assert.equal(checkFileProposal(ref,{...proposal,content:''},current),'');assert.equal(current.file.draft,'before');});
test('plan-linked proposals require the same available plan revision',()=>{
 const reference={...ref,task:{id:'dt_1',revision:2,world:'world-one'}},state={...current,world:'world-one',task:{id:'dt_1',revision:2,status:'planned'}};
 assert.equal(checkFileProposal(reference,proposal,state),'after');
 for(const changed of [{...state,world:'world-two'},{...state,task:null},{...state,task:{...state.task,revision:3}},{...state,task:{...state.task,status:'cancelled'}}])assert.throws(()=>checkFileProposal(reference,proposal,changed),/plan changed/);
});
