// A saved combined review staged again from its recorded bytes: the refusals
// name the file and the fact, the items it yields are the ones the existing
// combined-review check accepts, and nothing is asked of a provider.
import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {savedReviewSet,savedReviewBodies,savedReviewItem,savedReviewItems} from '../cockpit/ui/saved-review.js';
import {checkProposalSet} from '../cockpit/ui/file-proposal-set.js';
import {sha256Text} from '../cockpit/ui/review-content.js';
const sha=t=>createHash('sha256').update(t).digest('hex');
const HEAD='a'.repeat(40);
function member(path,current,proposed,{disk=current,deletion=false,inline=false}={}){
  const source={schema:deletion?'selected-file-deletion-basis@1':'selected-file-basis@1',scope:'selected-file-only',path,head:HEAD,disk_sha256:disk===null?null:sha(disk),draft_sha256:sha(current),draft_bytes:Buffer.byteLength(current),result_sha256:deletion?sha(JSON.stringify(['deleted-file@1',path])):sha(proposed),result_bytes:deletion?0:Buffer.byteLength(proposed),unsaved:disk!==current,repository_ref:'rp_0001',task_ref:'dt_0001',task_revision:2,world:['w',1,'e']};
  source.basis_id=sha(JSON.stringify(['selected-file-basis@1',HEAD,path,source.disk_sha256,source.draft_sha256]));
  return inline?{source,shared_draft:current,proposed_text:deletion?null:proposed}:{source};
}
function fixture(opts={}){
  const files=[member('index.html','<h1>Before</h1>\n','<h1>After</h1>\n',opts),member('cockpit.js','// red\n','// blue\n',opts)];
  const attempt={id:'da_0007',schema:'development-review-set@1',status:'recorded',revision:1,task_ref:'dt_0001',task_revision:2,client_ref:'c',files,source:{schema:'selected-file-set-basis@1'}};
  const task={id:'dt_0001',revision:2,status:'planned'};
  const store=new Map();for(const f of files){store.set(f.source.draft_sha256,f.source.path==='index.html'?'<h1>Before</h1>\n':'// red\n');if(f.source.schema==='selected-file-basis@1')store.set(f.source.result_sha256,f.source.path==='index.html'?'<h1>After</h1>\n':'// blue\n');}
  const reads=[];const read=async d=>{reads.push(d);if(!store.has(d))throw Error('This file’s reviewed content is no longer stored. Stage the proposal again; it cannot be shown or accepted.');return store.get(d);};
  return {attempt,task,files,store,reads,read};
}
const ctx={session:'s1',generation:3,task:{id:'dt_0001',revision:2,world:'["w",1,"e"]'}};
const diskOf=text=>({original:text,draft:text,originalSha256:text===null?null:sha(text)});

test('the page hash agrees with the runtime’s digest',async()=>{assert.equal(await sha256Text('// red\n'),sha('// red\n'));assert.equal(await sha256Text(''),sha(''));});

test('a recorded, open combined review on its own plan revision is staged; nothing else is',()=>{
  const f=fixture();const members=savedReviewSet(f.attempt,f.task);
  assert.deepEqual(members.map(m=>m.path),['index.html','cockpit.js']);assert.equal(members[0].inline,null);assert.equal(members[0].deletion,false);
  for(const [why,mutate] of [
    ['no attempt',f=>{f.attempt=null;}],
    ['a single-file review',f=>{f.attempt.schema='development-attempt@1';delete f.attempt.files;}],
    ['an accepted review',f=>{f.attempt.status='accepted';}],
    ['a dismissed review',f=>{f.attempt.status='dismissed';}],
    ['another plan',f=>{f.task.id='dt_0002';}],
    ['a cancelled plan',f=>{f.task.status='cancelled';}],
    ['a completed plan',f=>{f.task.status='completed';}],
    ['one member',f=>{f.attempt.files=f.attempt.files.slice(0,1);}],
    ['a member with no basis',f=>{delete f.attempt.files[1].source.basis_id;}],
    ['a member with no result',f=>{delete f.attempt.files[1].source.result_sha256;}],
    ['a deletion of a new file',f=>{f.attempt.files[1].source.schema='selected-file-deletion-basis@1';f.attempt.files[1].source.disk_sha256=null;}],
    ['one path twice',f=>{f.attempt.files[1].source.path='index.html';}],
  ]){const g=fixture();mutate(g);assert.throws(()=>savedReviewSet(g.attempt,g.task),undefined,why);}
});

test('a plan revision that moved is not a refusal, and the file refusals name the file',()=>{
  const f=fixture();f.task.revision=3;assert.equal(savedReviewSet(f.attempt,f.task).length,2,'criteria are immutable: a later plan revision does not stale a saved review');
  const g=fixture();delete g.attempt.files[1].source.result_sha256;assert.throws(()=>savedReviewSet(g.attempt,g.task),/^Error: cockpit\.js: /);
});

test('bodies are read through the host by digest and checked by the page’s own hash',async()=>{
  const f=fixture();const bodies=await savedReviewBodies(savedReviewSet(f.attempt,f.task),f.read,sha256Text);
  assert.deepEqual(bodies,[{path:'index.html',current:'<h1>Before</h1>\n',proposed:'<h1>After</h1>\n'},{path:'cockpit.js',current:'// red\n',proposed:'// blue\n'}]);
  assert.equal(f.reads.length,4);
});

test('a missing body refuses the whole review, naming the file, and no later body is read',async()=>{
  const f=fixture();f.store.delete(f.files[0].source.result_sha256);
  await assert.rejects(savedReviewBodies(savedReviewSet(f.attempt,f.task),f.read,sha256Text),/^Error: index\.html: This file’s reviewed content is no longer stored/);
  assert.equal(f.reads.length,2);
});

test('a body that does not hash to its name is refused as corrupt even when the host returned it',async()=>{
  const f=fixture();f.store.set(f.files[1].source.result_sha256,'// tampered\n');
  await assert.rejects(savedReviewBodies(savedReviewSet(f.attempt,f.task),f.read,sha256Text),/cockpit\.js: the proposed text does not match its digest/);
  const g=fixture();g.store.set(g.files[0].source.draft_sha256,'other\n');
  await assert.rejects(savedReviewBodies(savedReviewSet(g.attempt,g.task),g.read,sha256Text),/index\.html: the reviewed current text does not match its digest/);
});

test('an inline record supplies its own bodies and the host is not asked; its bodies are still checked',async()=>{
  const f=fixture({inline:true});const members=savedReviewSet(f.attempt,f.task);assert.ok(members[0].inline);
  const bodies=await savedReviewBodies(members,f.read,sha256Text);assert.equal(f.reads.length,0);assert.equal(bodies[1].proposed,'// blue\n');
  f.attempt.files[1].proposed_text='// changed inline\n';
  await assert.rejects(savedReviewBodies(savedReviewSet(f.attempt,f.task),f.read,sha256Text),/cockpit\.js: the proposed text does not match its digest/);
});

test('a deletion member reads only its current side and proposes null',async()=>{
  const f=fixture();f.attempt.files[1]=member('cockpit.js','// red\n',null,{deletion:true});f.store.set(f.attempt.files[1].source.draft_sha256,'// red\n');
  const members=savedReviewSet(f.attempt,f.task);const bodies=await savedReviewBodies(members,f.read,sha256Text);
  assert.equal(bodies[1].proposed,null);assert.equal(f.reads.length,3);
  const item=savedReviewItem(members[1],bodies[1],diskOf('// red\n'),sha('// red\n'),ctx);assert.equal(item.proposal.content,null);assert.equal(item.reference.original,'// red\n');
});

test('each file is checked against the repository as it is now: changed, vanished, appeared, or edited in the Editor',async()=>{
  const f=fixture();const members=savedReviewSet(f.attempt,f.task),bodies=await savedReviewBodies(members,f.read,sha256Text);
  const m=members[1],b=bodies[1];
  assert.throws(()=>savedReviewItem(m,b,diskOf('// green\n'),sha('// green\n'),ctx),/cockpit\.js changed on disk since it was reviewed \(now [0-9a-f]{12}, reviewed at [0-9a-f]{12}\)/);
  assert.throws(()=>savedReviewItem(m,b,{original:null,draft:''},null,ctx),/cockpit\.js no longer exists in the repository/);
  assert.throws(()=>savedReviewItem(m,b,{original:'// red\n',draft:'// red\n// mine\n'},sha('// red\n'),ctx),/cockpit\.js has unsaved edits in the Editor/);
  const fresh=fixture({disk:null});const nm=savedReviewSet(fresh.attempt,fresh.task)[1],nb=(await savedReviewBodies([nm],fresh.read,sha256Text))[0];
  assert.throws(()=>savedReviewItem(nm,nb,diskOf('// red\n'),sha('// red\n'),ctx),/cockpit\.js was reviewed as a new file but now exists/);
  const created=savedReviewItem(nm,nb,{original:null,draft:''},null,ctx);assert.equal(created.reference.original,null);assert.equal(created.reference.draft,'// red\n');
});

test('an Editor draft equal to the review’s own shared draft is not a conflict',async()=>{
  const f=fixture({disk:'// saved\n'});const m=savedReviewSet(f.attempt,f.task)[1],b=(await savedReviewBodies([m],f.read,sha256Text))[0];
  const item=savedReviewItem(m,b,{original:'// saved\n',draft:'// red\n'},sha('// saved\n'),ctx);
  assert.equal(item.reference.draft,'// red\n');assert.equal(item.reference.original,'// saved\n');
  assert.throws(()=>savedReviewItem(m,b,{original:'// saved\n',draft:'// other\n'},sha('// saved\n'),ctx),/unsaved edits/);
});

test('the items it yields are exactly what the combined-review check accepts, bound to this session, plan and generation',async()=>{
  const f=fixture();const members=savedReviewSet(f.attempt,f.task),bodies=await savedReviewBodies(members,f.read,sha256Text);
  const files=new Map([['index.html',diskOf('<h1>Before</h1>\n')],['cockpit.js',diskOf('// red\n')]]);
  const items=savedReviewItems(members,bodies,files,ctx);
  const tabs=new Map([...files].map(([path,f])=>[path,{path,original:f.original,draft:f.draft}]));
  const current=r=>({session:'s1',generation:3,file:tabs.get(r.key),task:{id:'dt_0001',revision:2,status:'planned'},world:'["w",1,"e"]'});
  assert.deepEqual(checkProposalSet(items,current),[{path:'index.html',text:'<h1>After</h1>\n'},{path:'cockpit.js',text:'// blue\n'}]);
  assert.deepEqual(items[1].reference.source,f.files[1].source);
  assert.throws(()=>checkProposalSet(items,r=>({...current(r),generation:4})),/repository changed/);
  assert.deepEqual(checkProposalSet(items,r=>({...current(r),task:{id:'dt_0001',revision:3,status:'planned'}})).map(i=>i.path),['index.html','cockpit.js'],'a later plan revision is the same plan');
  assert.throws(()=>checkProposalSet(items,r=>({...current(r),task:{id:'dt_0001',revision:2,status:'cancelled'}})),/plan changed/);
  assert.throws(()=>savedReviewItems(members,bodies,new Map([...files].slice(0,1)),ctx),/cockpit\.js: not every file was read/);
});
