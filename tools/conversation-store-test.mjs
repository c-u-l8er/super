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

/* T70 · the file-backed history, through a fake host that keeps the files in memory and can be made to fail. */
import {createHash} from 'node:crypto';
import {openConversationHistory,moveBrowserHistories,openedHistory,confirmSaved,createConversationActions,HISTORY_BYTES} from '../cockpit/ui/conversation-store.js';
const sha=t=>createHash('sha256').update(t).digest('hex');
function host({fail=()=>false,failIndex=()=>false,tamper=t=>t}={}){
  const dirs=new Map(),calls=[],view=(d,ix)=>ix&&{generation:ix.generation,meta:ix.meta,files:ix.files,texts:ix.files.map(f=>d.files.get(f))};
  const invoke=async(command,{request:r})=>{
    assert.equal(command,'conversation_bodies');calls.push(r);
    if(fail(r))throw new Error('disk write failed (test)');
    if(!dirs.has(r.history))dirs.set(r.history,{files:new Map(),index:null,migrating:null});
    const d=dirs.get(r.history);
    if(r.operation==='history_load')return {published:view(d,d.index),migrating:d.index?null:view(d,d.migrating)};
    if(r.operation==='history_promote'){if(d.index||!d.migrating)throw new Error('nothing to promote');d.index=d.migrating;d.migrating=null;return {state:'published'};}
    if(r.operation==='history_abandon'){d.migrating=null;return {state:'abandoned'};}
    if(r.operation!=='history_publish')throw new Error('Unknown conversation history operation.');
    if(r.stage&&d.index)throw new Error('already kept in files');
    const files=r.files.map(f=>{if(typeof f.text==='string'){d.files.set(sha(f.text),tamper(f.text));return sha(f.text);}if(!d.files.has(f.sha256))throw new Error('never written');return f.sha256;});
    if(failIndex(r))throw new Error('index write failed (test)');
    d[r.stage?'migrating':'index']={generation:(d.index?.generation??0)+1,files,meta:r.meta};
    return {state:r.stage?'staged':'published',files};
  };
  return {invoke,dirs,calls,publishes:()=>calls.filter(r=>r.operation==='history_publish').length};
}
function browser(entries=[]){const values=new Map(entries);return {values,get length(){return values.size;},key:i=>[...values.keys()][i]??null,getItem:k=>values.get(k)??null,setItem:(k,v)=>values.set(k,v),removeItem:k=>values.delete(k)};}
const open=async(h,o={})=>{const s=openConversationHistory({invoke:h.invoke,...o});await s.ready;return s;};
const legacyOf=n=>{const disk=browser(),old=createConversationStore(disk);for(let i=0;i<n;i++)old.save(i%2?'claude':'ollama',null,{...data(),draft:`Conversation ${i}`});return {disk,old,raw:disk.getItem(STORAGE_KEY)};};
/* Holds the next publication at the host until released; `entered` resolves once it is inside. */
function gate(h){let wait=null,signal=null;return {invoke:async(c,a)=>{if(wait&&a.request.operation==='history_publish'){const w=wait;wait=null;signal();await w;}return h.invoke(c,a);},hold(){let release;wait=new Promise(r=>{release=r;});const entered=new Promise(r=>{signal=r;});return {entered,release:()=>release()};}};}
const keyOf=b=>`${STORAGE_KEY}:bot:${b}`;
/* The bot page's own handlers (`createConversationActions`, which bots.js runs) over a page whose open bot,
 * conversation, draft and stashed sessions the tests switch and inspect. */
function page(stores){
  const p={bot:'a',provider:'ollama',id:null,draft:'',held:false,statuses:[],sessions:new Map()};
  const store=()=>stores[p.bot];
  const view={botId:()=>p.bot,provider:()=>p.provider,conversationId:()=>p.id,sessions:p.sessions,
    saveCurrent:()=>{if(p.held)return false;if(!p.id&&!p.draft)return true;try{p.id=store().save(p.provider,p.id,{...data(),draft:p.draft});return true;}catch{return false;}},
    snapshot:()=>({...data(),draft:p.draft}),opened:id=>{p.id=id;p.draft=store().get(p.provider,id)?.draft??'';},
    fresh:text=>{p.id=null;p.draft=text;},adopt:id=>{p.id=id;},setDraft:text=>{p.draft=text;},
    hold:on=>{p.held=on;},reset:()=>{p.id=null;p.draft='';},status:t=>p.statuses.push(t),changed:()=>{}};
  p.actions=createConversationActions({storeFor:id=>stores[id],view});
  return p;
}

test('L1 a 6 MB history saves with every browser-storage write refused, and reads back byte for byte',async()=>{
  const h=host(),legacy=browser();let refused=0;legacy.setItem=()=>{refused++;const e=new Error('quota');e.name='QuotaExceededError';throw e;};
  const big={...data(),messages:Array.from({length:40},(_,k)=>({role:k%2?'assistant':'user',content:`${k} `+'é✓ x'.repeat(37_000),attachments:[]}))};
  assert.ok(new TextEncoder().encode(JSON.stringify(big)).length>6_000_000);
  const s=await open(h,{legacy}),id=s.save('claude',null,big);await s.settled();
  assert.equal(s.outcome(id).ok,true);assert.equal(refused,0,'browser storage is never written');
  assert.deepEqual((await open(h,{legacy})).get('claude',id),big);
});
test('L2 the first start moves a 20-conversation history and removes the key only after it reads back equal',async()=>{
  const {disk,old,raw}=legacyOf(20),h=host(),s=await open(h,{legacy:disk});
  assert.equal(s.error,null);assert.equal(disk.getItem(STORAGE_KEY),null);
  for(const c of JSON.parse(raw).conversations)assert.deepEqual(s.get(c.provider,c.id),old.get(c.provider,c.id));
  assert.deepEqual(s.list(),old.list());assert.equal(s.selected('claude'),old.selected('claude'));assert.deepEqual((await open(h)).list(),old.list());
});
test('L2 a copy that fails, or reads back different, leaves the key and publishes nothing',async()=>{
  for(const h of [host({fail:r=>r.operation==='history_publish'}),host({tamper:t=>t.replace('Review','Rewrite')})]){
    const {disk,raw}=legacyOf(2),s=await open(h,{legacy:disk});
    assert.match(s.error,/could not be loaded/);assert.equal(disk.getItem(STORAGE_KEY),raw);
    assert.equal(h.dirs.get(STORAGE_KEY).index,null);assert.throws(()=>s.save('ollama',null,data()),/could not be loaded/);
  }
});
test('L2 an unequal copy whose cleanup failed is never loaded on the next start, which moves again',async()=>{
  let bad=true;const h=host({tamper:t=>bad?t.replace('Review','Rewrite'):t,fail:r=>bad&&r.operation==='history_abandon'}),{disk,old}=legacyOf(2);
  assert.match((await open(h,{legacy:disk})).error,/did not read back/);assert.ok(h.dirs.get(STORAGE_KEY).migrating,'left staged');
  bad=false;const s=await open(h,{legacy:disk});
  assert.equal(s.error,null);assert.deepEqual(s.list(),old.list());assert.equal(disk.getItem(STORAGE_KEY),null);
});
test('L2 a start stopped after the copy was staged, before its comparison, promotes it on the next start',async()=>{
  let n=0;const h=host({fail:r=>r.operation==='history_load'&&++n===2}),{disk,old}=legacyOf(3);
  assert.ok((await open(h,{legacy:disk})).error);assert.ok(h.dirs.get(STORAGE_KEY).migrating);assert.equal(h.dirs.get(STORAGE_KEY).index,null);assert.ok(disk.getItem(STORAGE_KEY));
  const s=await open(h,{legacy:disk});assert.deepEqual(s.list(),old.list());assert.equal(disk.getItem(STORAGE_KEY),null);
});
test('L2 a browser value that changed during the move keeps its key',async()=>{
  const {disk,raw}=legacyOf(2),h=host({fail:r=>{if(r.stage)disk.setItem(STORAGE_KEY,raw.replace('Conversation 0','Edited 0'));return false;}});
  const s=await open(h,{legacy:disk});assert.match(s.error,/changed during the move/);assert.notEqual(disk.getItem(STORAGE_KEY),null);assert.equal(h.dirs.get(STORAGE_KEY).index,null);
});
test('L2 every browser history moves, rostered or not, with any id the store accepts',async()=>{
  const v=JSON.parse(legacyOf(5).raw),ids=['','\u0000\u0007','../../owners.json','\ud800','é✓𝄞'.repeat(20)];
  v.conversations.forEach((c,i)=>{c.id=ids[i];});v.selected={claude:ids[1]};
  const key=`${STORAGE_KEY}:bot:unrostered-t70`,disk=browser([[key,JSON.stringify(v)]]),h=host();
  const [s]=moveBrowserHistories({invoke:h.invoke,legacy:disk});await s.ready;
  assert.equal(s.error,null);assert.equal(disk.getItem(key),null);assert.equal(openedHistory('unrostered-t70').list().length,5);
  const back=await open(h,{key});assert.deepEqual(back.list().map(c=>c.id).sort(),[...ids].sort());assert.equal(back.selected('claude'),ids[1]);
});
test('L3 a failed save of A then a good save of B publishes both, and a restart loads both',async()=>{
  let failing=true;const h=host({fail:r=>failing&&r.operation==='history_publish'}),s=await open(h);
  const a=s.save('ollama',null,data());await s.settled();assert.equal(s.outcome(a).ok,false);assert.equal(s.committed('ollama',a),null);
  failing=false;const b=s.save('claude',null,{...data(),draft:'B'});await s.settled();
  assert.equal(s.outcome(a).ok,true);assert.equal(s.outcome(b).ok,true);
  const back=await open(h);assert.equal(back.error,null);assert.deepEqual(back.get('ollama',a),data());assert.equal(back.get('claude',b).draft,'B');
});
test('L3 a file written whose index write fails leaves the previous history after a restart, and an update reports it',async()=>{
  let failing=false;const h=host({failIndex:()=>failing}),s=await open(h),id=s.save('ollama',null,data());await s.settled();
  failing=true;s.save('ollama',id,{...data(),draft:'New'});await s.settled();
  assert.equal(s.outcome(id).ok,false);assert.equal(s.committed('ollama',id).draft,'Continue');
  await assert.rejects(s.update('ollama',id,{title:'Renamed'}),/index write failed/);
  const back=await open(h);assert.equal(back.get('ollama',id).draft,'Continue');assert.notEqual(back.list()[0].title,'Renamed');
});
test('L3 a save is saved only when the host answers, and a superseded failure is ignored',async()=>{
  const h=host();let n=0,release,entered;const held=new Promise(r=>{release=r;}),inside=new Promise(r=>{entered=r;});
  const s=await open({invoke:async(c,a)=>{if(a.request.operation==='history_publish'&&++n===1){entered();await held;throw new Error('first write lost');}return h.invoke(c,a);}});
  const id=s.save('ollama',null,data());assert.equal(s.outcome(id).saving,true);assert.equal(s.committed('ollama',id),null);
  await inside;
  s.save('ollama',id,{...data(),draft:'Newer'});const events=[];s.onChange(e=>events.push([e.type,e.ids]));
  release();await s.settled();
  assert.deepEqual(events,[['failed',[]],['saved',[id]]]);assert.equal(s.outcome(id).ok,true);assert.equal(s.committed('ollama',id).draft,'Newer');
});
test('L3 a history above its declared bound is refused by name and the previous one stays',async()=>{
  const h=host(),s=await open(h,{maxBytes:4000}),id=s.save('ollama',null,data());await s.settled();const before=h.publishes();
  assert.throws(()=>s.save('ollama',id,{...data(),draft:'x'.repeat(5000)}),/history bound of 4000 bytes/);
  assert.equal(h.publishes(),before);assert.equal(s.get('ollama',id).draft,'Continue');
  assert.equal((await open(h)).get('ollama',id).draft,'Continue');assert.equal(HISTORY_BYTES,256*1024*1024);
});
test('L3 both phone create branches confirm in the store they were made in and return its id, across a bot switch',async()=>{
  for(const branch of [{data:{...data(),draft:'Task'}},{text:'Typed on the phone'}]){
    let failing=false;const ga=gate(host({fail:r=>failing&&r.operation==='history_publish'}));
    const stores={a:await open(ga,{key:keyOf('a')}),b:await open(host(),{key:keyOf('b')})},p=page(stores);
    for(const fails of [false,true]){
      failing=fails;const held=ga.hold(),run=p.actions.create('ollama',branch);await held.entered;
      const made=p.id;p.bot='b';p.id=stores.b.save('ollama',null,{...data(),draft:'Other bot'});held.release();
      if(fails)await assert.rejects(run,/disk write failed/,'a failure is never reported as a creation');
      else{assert.equal(await run,made,'the id saved, not the one open now');assert.ok(stores.a.get('ollama',made));assert.equal(stores.b.get('ollama',made),null);}
      p.bot='a';p.id=null;p.draft='';
    }
  }
});
test('L3 the phone draft is confirmed in its own store for its own id, across a bot switch',async()=>{
  let failing=false;const ga=gate(host({fail:r=>failing&&r.operation==='history_publish'}));
  const stores={a:await open(ga,{key:keyOf('a')}),b:await open(host(),{key:keyOf('b')})},p=page(stores);
  p.id=stores.a.save('ollama',null,data());await stores.a.settled();const id=p.id;
  for(const fails of [false,true]){
    failing=fails;const held=ga.hold(),run=p.actions.draft(fails?'Lost':'Kept');await held.entered;
    p.bot='b';p.id=stores.b.save('ollama',null,{...data(),draft:'Other bot'});held.release();
    if(fails)await assert.rejects(run,/disk write failed/);else assert.equal(await run,id);
    p.bot='a';p.id=id;
  }
  assert.equal(stores.a.committed('ollama',id).draft,'Kept');
  await assert.rejects(confirmSaved(stores.b,id),/no save/,'a store with no outcome for it never confirms it');
});
test('L3 a title change that fails is reported by the page, for the open bot and another, never left unhandled',async()=>{
  let failing=false;const mk=key=>open(host({fail:r=>failing&&r.operation==='history_publish'}),{key});
  const stores={a:await mk(keyOf('a')),b:await mk(keyOf('b'))},p=page(stores);
  const a=stores.a.save('ollama',null,data()),b=stores.b.save('claude',null,data());await stores.a.settled();await stores.b.settled();
  failing=true;
  assert.match(await p.actions.title('a','ollama',a,{title:'Renamed',titleSource:'ai'}),/disk write failed/);
  assert.match(await p.actions.title('b','claude',b,{titleSource:'attempted'}),/disk write failed/,'a bot that is not open');
  assert.match(await p.actions.title('b','claude','missing',{titleSource:'attempted'}),/unavailable/);
  assert.equal(p.statuses.filter(t=>/title was not saved/.test(t)).length,3);
  failing=false;assert.equal(await p.actions.title('a','ollama',a,{title:'Renamed'}),null);assert.equal(stores.a.list()[0].title,'Renamed');
});
test('L3 both deletion controls keep the list entry, the session and the open draft until the deletion is published',async()=>{
  let failing=false;const h=host({fail:r=>failing&&r.operation==='history_publish'}),g=gate(h);
  const stores={a:await open(g,{key:keyOf('a')})},s=stores.a,p=page(stores);
  const shown=s.save('ollama',null,data()),other=s.save('ollama',null,{...data(),draft:'Elsewhere'}),third=s.save('ollama',null,{...data(),draft:'Third'});await s.settled();
  const listed=id=>s.list('ollama').some(c=>c.id===id);
  for(const [id,isOpen] of [[shown,true],[other,false]]){
    p.id=isOpen?id:third;p.draft='Open draft';p.sessions.set('ollama',{conversationId:id});
    failing=true;assert.equal(await p.actions.remove('a','ollama',id),false);
    assert.ok(listed(id));assert.equal(p.sessions.get('ollama')?.conversationId,id);assert.equal(p.draft,'Open draft');assert.equal(p.held,false);
    assert.match(p.statuses.at(-1),/deletion was not saved/);
    failing=false;const held=g.hold(),run=p.actions.remove('a','ollama',id);await held.entered;
    assert.ok(listed(id),'listed while pending');assert.equal(p.sessions.get('ollama')?.conversationId,id);assert.equal(p.draft,'Open draft');assert.equal(p.held,isOpen);
    held.release();assert.equal(await run,true);
    assert.equal(listed(id),false);assert.equal(p.sessions.has('ollama'),false);assert.equal(p.held,false);
    assert.equal(p.draft,isOpen?'':'Open draft');assert.equal(p.id,isOpen?null:third);
  }
  assert.deepEqual((await open(h,{key:keyOf('a')})).list().map(c=>c.id),[third]);
});
test('L4 the file-backed history refuses an invalid record exactly as browser storage does',async()=>{
  const h=host(),s=await open(h),d=data();d.entries[0].proposals=[{text:'x',recovery:{schema:'proposal-recovery@1',path:'a.js'}}];
  assert.throws(()=>s.save('claude',null,d),/Invalid recovery/);
  const p=patched();p.recovery={...p.recovery,content:'tampered'};d.entries[0].proposals=[p];
  assert.throws(()=>s.save('claude',null,d),/does not reproduce its recorded content/);assert.equal(h.publishes(),0);
});
test('L5 the 21st and the 50th conversation save, and 50 load back whole after a restart',async()=>{
  const h=host(),s=await open(h),ids=[];for(let i=0;i<50;i++)ids.push(s.save('ollama',null,{...data(),draft:`Conversation ${i}`}));await s.settled();
  assert.equal(s.outcome(ids[20]).ok,true);assert.equal(s.outcome(ids[49]).ok,true);
  const back=await open(h);assert.equal(back.error,null);assert.equal(back.list('ollama').length,50);
  ids.forEach((id,i)=>assert.equal(back.get('ollama',id).draft,`Conversation ${i}`));
});
