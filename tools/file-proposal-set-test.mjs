import test from 'node:test';
import assert from 'node:assert/strict';
import {checkProposalSet,prepareProposalSet,proposalSetMaterial} from '../cockpit/ui/file-proposal-set.js';
function fixture(){
 const task={id:'dt_1',revision:2,status:'planned'},files=new Map();
 const items=['source.js','source.test.mjs'].map(path=>{files.set(path,{path,original:'old',draft:'old'});return {reference:{session:'s',generation:3,key:path,original:'old',draft:'old',task:{id:task.id,revision:2,world:'w'},source:{head:'head',repository_ref:'repo'}},proposal:{path,content:'new '+path}};});
 const current=r=>({session:'s',generation:3,file:files.get(r.key),task,world:'w'});
 return {items,files,current,task};
}
test('a coherent set returns complete drafts without changing files',()=>{const f=fixture();assert.deepEqual(checkProposalSet(f.items,f.current),[{path:'source.js',text:'new source.js'},{path:'source.test.mjs',text:'new source.test.mjs'}]);assert.equal(f.files.get('source.js').draft,'old');});
test('duplicates, mixed plans, commits, sessions and missing references refuse the entire set',()=>{
 for(const mutate of [f=>f.items[1]=f.items[0],f=>f.items[1].reference.task.id='other',f=>f.items[1].reference.source.head='other',f=>f.items[1].reference.generation++,f=>f.items[1].reference.session='other',f=>f.items[1].reference=undefined,f=>f.items[1].reference.source=null]){const f=fixture();mutate(f);assert.throws(()=>checkProposalSet(f.items,f.current));assert.equal(f.files.get('source.js').draft,'old');}
});
test('a stale or closed second file refuses the set before any draft changes',()=>{
 for(const mutate of [f=>f.files.get('source.test.mjs').draft='mine',f=>f.files.get('source.test.mjs').original='saved',f=>f.files.delete('source.test.mjs'),f=>f.task.revision++,f=>f.task.status='completed']){const f=fixture();mutate(f);assert.throws(()=>checkProposalSet(f.items,f.current));assert.equal(f.files.get('source.js').draft,'old');}
});
test('sets enforce file counts and complete text bounds',()=>{const f=fixture();assert.throws(()=>checkProposalSet(f.items.slice(0,1),f.current));assert.throws(()=>checkProposalSet([...f.items,...f.items,...f.items],f.current));f.items[1].proposal.content='é'.repeat(16001);assert.throws(()=>checkProposalSet(f.items,f.current));f.items[1].proposal.content='';assert.equal(checkProposalSet(f.items,f.current)[1].text,'');});
test('verification failure on a later file does not return a partial set',async()=>{const f=fixture(),seen=[];await assert.rejects(prepareProposalSet(f.items,f.current,async r=>{seen.push(r.key);if(seen.length===2)throw Error('Disk changed');}),/Disk changed/);assert.equal(seen.length,2);assert.equal(f.files.get('source.js').draft,'old');});
test('draft changes while checking and cancelled reviews refuse staging',async()=>{const f=fixture();await assert.rejects(prepareProposalSet(f.items,f.current,async()=>{f.files.get('source.test.mjs').draft='new work';}),/draft changed/);const g=fixture();await assert.rejects(prepareProposalSet(g.items,g.current,async()=>{},()=>false),/Review closed/);});
test('successful verification checks all files then returns the set',async()=>{const f=fixture(),seen=[];const result=await prepareProposalSet(f.items,f.current,async r=>seen.push(r.key));assert.equal(result.length,2);assert.deepEqual(seen,['source.js','source.test.mjs']);assert.equal(f.files.get('source.test.mjs').draft,'old');});

test('retained set includes every exact draft and verified native source without staging',async()=>{const f=fixture();const material=await proposalSetMaterial(f.items,f.current,async r=>({path:r.key,basis_id:'verified-'+r.key}));assert.equal(material.files.length,2);assert.deepEqual(material.files[1],{source:{path:'source.test.mjs',basis_id:'verified-source.test.mjs'},shared_draft:'old',proposed_text:'new source.test.mjs'});assert.equal(f.files.get('source.js').draft,'old');});

test('explicit deletion stays null in staged and retained material and requires an existing file',async()=>{const f=fixture();f.items[1].proposal.content=null;assert.equal(checkProposalSet(f.items,f.current)[1].text,null);const material=await proposalSetMaterial(f.items,f.current,async r=>({path:r.key}));assert.equal(material.files[1].proposed_text,null);assert.equal(f.files.get('source.test.mjs').draft,'old');f.items[1].reference.original=null;f.files.get('source.test.mjs').original=null;assert.throws(()=>checkProposalSet(f.items,f.current),/existing file/);});
