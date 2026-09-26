import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createConversationStore, STORAGE_KEY } from '../cockpit/ui/conversation-store.js';
function storage(){ const values=new Map();return {getItem:k=>values.get(k)??null,setItem:(k,v)=>values.set(k,v)}; }
const data=()=>({messages:[{role:'user',content:'Review project',attachments:[{name:'project.md',content:'project material'}]}],entries:[{referenceWorld:null,role:'assistant',label:'Assistant',text:'Review ready',proposals:['Proposed workspace']}],draft:'Continue',files:[{name:'next.md',content:'next material'}],includeContext:true,replyPending:false});
test('restart restores separate provider histories and attachment content',()=>{const disk=storage(),s=createConversationStore(disk),id=s.save('ollama',null,data());const other=s.save('openai',null,{...data(),draft:'Different'});const reopened=createConversationStore(disk);assert.equal(reopened.selected('ollama'),id);assert.deepEqual(reopened.get('ollama',id),data());assert.equal(reopened.get('ollama',other),null);assert.throws(()=>reopened.save('openai',id,data()),/another provider/);});
test('only presentation fields persist; returned data cannot mutate saved history',()=>{const disk=storage(),s=createConversationStore(disk),d=data();d.apiKey='secret';d.entries[0].token='authority';const id=s.save('ollama',null,d);assert.ok(!disk.getItem(STORAGE_KEY).includes('secret'));assert.ok(!disk.getItem(STORAGE_KEY).includes('authority'));s.get('ollama',id).messages[0].content='mutated';assert.equal(s.get('ollama',id).messages[0].content,'Review project');});
test('failed writes preserve last successful save',()=>{const disk=storage(),s=createConversationStore(disk),id=s.save('ollama',null,data()),before=disk.getItem(STORAGE_KEY);disk.setItem=()=>{throw Error('quota');};assert.throws(()=>s.save('ollama',id,{...data(),draft:'New'}),/Could not save/);assert.equal(disk.getItem(STORAGE_KEY),before);assert.equal(s.get('ollama',id).draft,'Continue');});
test('malformed history is reported and never overwritten',()=>{const disk=storage();disk.setItem(STORAGE_KEY,'broken');const s=createConversationStore(disk);assert.match(s.error,/could not be loaded/);assert.throws(()=>s.save('ollama',null,data()));assert.equal(disk.getItem(STORAGE_KEY),'broken');});
test('history limit requires explicit deletion instead of eviction',()=>{const s=createConversationStore(storage());let first;for(let i=0;i<20;i++){const id=s.save('ollama',null,data());first??=id;}assert.throws(()=>s.save('ollama',null,data()),/20 saved/);assert.ok(s.get('ollama',first));s.remove('openai',first);assert.ok(s.get('ollama',first));s.remove('ollama',first);assert.equal(s.get('ollama',first),null);s.save('ollama',null,data());assert.equal(s.list('ollama').length,20);});
test('interrupted reply keeps recovery metadata and draft attachments',()=>{const disk=storage(),s=createConversationStore(disk),id=s.save('ollama',null,{...data(),replyPending:true});assert.equal(createConversationStore(disk).get('ollama',id).replyPending,true);assert.equal(createConversationStore(disk).get('ollama',id).files[0].content,'next material');});

test('history preserves all eight proposals allowed by the provider adapter',()=>{const disk=storage(),s=createConversationStore(disk),d=data();d.entries[0].proposals=Array.from({length:8},(_,i)=>`Proposal ${i+1}`);const id=s.save('ollama',null,d);assert.deepEqual(createConversationStore(disk).get('ollama',id).entries[0].proposals,d.entries[0].proposals);});

test('pins and manual titles survive replies and restart without moving recency',()=>{const disk=storage(),s=createConversationStore(disk),id=s.save('ollama',null,data()),updated=s.list()[0].updated;s.update('ollama',id,{pinned:true,title:'My chosen title'});assert.equal(s.list()[0].updated,updated);s.save('ollama',id,{...data(),draft:'More work'});s.update('ollama',id,{title:'AI suggestion',titleSource:'ai'});const item=createConversationStore(disk).list()[0];assert.equal(item.title,'My chosen title');assert.equal(item.pinned,true);assert.equal(item.titleSource,'manual');});
test('all-provider list keeps identity and generated titles without granting actions',()=>{const s=createConversationStore(storage()),id=s.save('ollama',null,data());s.save('claude',null,data());s.update('ollama',id,{titleSource:'attempted'});s.update('ollama',id,{title:'Review project plan',titleSource:'ai'});assert.equal(s.list().length,2);assert.equal(s.list('ollama')[0].titleSource,'ai');assert.throws(()=>s.update('claude',id,{pinned:true}),/unavailable/);assert.throws(()=>s.update('ollama',id,{title:' '}),/Enter/);});
import {recoveryRecord} from '../cockpit/ui/proposal-recovery.js';
const recoverable=()=>{const basis={schema:'selected-file-basis@1',basis_id:'b'.repeat(64),head:'h'.repeat(40),path:'a.js',disk_sha256:'d'.repeat(64),draft_sha256:'e'.repeat(64)};return {text:'Proposed file edit\na.js · 5 bytes',recovery:recoveryRecord({kind:'editor',key:'a.js',original:'old',draft:'old',source:basis,task:null},{path:'a.js',content:'after'})};};
test('a proposal saved with its recovery record comes back exactly, beside legacy string proposals',()=>{
  const disk=storage(),s=createConversationStore(disk),d=data();d.entries[0].proposals=['legacy text',recoverable()];
  const id=s.save('claude',null,d);const back=createConversationStore(disk).get('claude',id).entries[0].proposals;
  assert.equal(back[0],'legacy text');assert.deepEqual(back[1],recoverable());
  assert.equal(back[1].recovery.content,'after');assert.equal(back[1].recovery.source.disk_sha256,'d'.repeat(64));
});
test('a proposal whose recovery record does not validate is refused whole, never downgraded to text',()=>{
  const disk=storage(),s=createConversationStore(disk),d=data();d.entries[0].proposals=[{text:'x',recovery:{schema:'proposal-recovery@1',path:'a.js'}}];
  assert.throws(()=>s.save('claude',null,d),/Invalid recovery/);
  assert.equal(disk.getItem(STORAGE_KEY),null,'nothing was written');
});
const patched=()=>{const r=recoverable();const edits=[{old_text:'old',new_text:'new'}];return {text:'Proposed patch\na.js · 1 edit · 3 bytes after the patch',recovery:recoveryRecord({kind:'editor',key:'a.js',original:'old',draft:'old',source:r.recovery.source,task:null},{path:'a.js',content:'new'},{schema:'file-patch@1',edits})};};
test('T22b · a patch proposal is saved with its patch and comes back exactly, self-verifying',()=>{
  const disk=storage(),s=createConversationStore(disk),d=data();d.entries[0].proposals=[recoverable(),patched()];
  const id=s.save('claude',null,d);const back=createConversationStore(disk).get('claude',id).entries[0].proposals;
  assert.deepEqual(back[0],recoverable(),'a full-content record is unchanged beside it');assert.ok(!('patch' in back[0].recovery));
  assert.deepEqual(back[1],patched());assert.deepEqual(back[1].recovery.patch,{schema:'file-patch@1',edits:[{old_text:'old',new_text:'new'}]});
});
test('T22b · a patch record whose content is not the patch applied to its draft is refused whole',()=>{
  const disk=storage(),s=createConversationStore(disk),d=data(),p=patched();p.recovery={...p.recovery,content:'tampered'};d.entries[0].proposals=[p];
  assert.throws(()=>s.save('claude',null,d),/does not reproduce its recorded content/);
  assert.equal(disk.getItem(STORAGE_KEY),null,'nothing was written');
});
