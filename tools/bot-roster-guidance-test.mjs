import test from 'node:test';
import assert from 'node:assert/strict';
import {createBotRoster,ROSTER_KEY} from '../cockpit/ui/bot-roster.js';
import {createConversationStore} from '../cockpit/ui/conversation-store.js';
import {summarizeWork} from '../cockpit/ui/work-guidance.js';
const memory=()=>{const map=new Map();return {getItem:k=>map.get(k),setItem:(k,v)=>map.set(k,v)};};
test('roster persists separate identities and strips unsupported authority fields',()=>{
 const storage=memory(),r=createBotRoster(storage),b=r.save({name:'Builder',role:'Implementation',instructions:'Work on Super',group:'Super',provider:'ollama',grants:['*']});
 assert.equal(createBotRoster(storage).get(b.id).name,'Builder');assert.equal(r.get(b.id).grants,undefined);assert.equal(r.list().length,2);
});
test('failed roster writes and malformed data preserve existing records',()=>{
 const storage=memory(),r=createBotRoster(storage);storage.setItem=()=>{throw Error('quota');};assert.throws(()=>r.save({name:'X',role:'Y',instructions:'',group:'Z',provider:'codex'}),/Could not save/);assert.equal(r.list().length,1);
 const broken=memory();broken.setItem(ROSTER_KEY,'{broken');const bad=createBotRoster(broken);assert.ok(bad.error);assert.throws(()=>bad.save(bad.get('assistant')));assert.equal(broken.getItem(ROSTER_KEY),'{broken');
});
test('bot namespaces preserve legacy history and isolate same-provider drafts',()=>{
 const storage=memory(),legacy=createConversationStore(storage),other=createConversationStore({getItem:k=>storage.getItem(k+':bot:builder'),setItem:(k,v)=>storage.setItem(k+':bot:builder',v)});
 const data=draft=>({messages:[],entries:[],files:[],draft,includeContext:false});
 const a=legacy.save('ollama',null,data('Original draft')),b=other.save('ollama',null,data('Builder draft'));
 assert.equal(legacy.get('ollama',a).draft,'Original draft');assert.equal(other.get('ollama',b).draft,'Builder draft');assert.equal(other.get('ollama',a),null);assert.equal(legacy.get('ollama',b),null);
});
test('guidance separates selected work from global approvals and bounded outcomes',()=>{
 const p={workspaces:{a:{id:'a'},b:{id:'b'}},goals:{x:{id:'x',workspace_ref:'a'},y:{id:'y',workspace_ref:'b'}},lanes:{l:{id:'l',goal_ref:'x'}},workers:{w:{id:'w',locus_ref:'l',status:'closed'}},grant_requests:[{}],pending_approvals:[{}],validations:{total:100,recent:[{kind:'validation_job_started@1'},{kind:'validation_job_outcome@1',state:'completed',verdict:'fail'},{kind:'validation_job_outcome@1',state:'failed',reason:'basis-stale'}]}};
 const a=summarizeWork(p,'a');assert.equal(a.goals.length,1);assert.equal(a.unassignedGoals.length,0);assert.equal(a.unstaffedLanes.length,1);assert.equal(a.pending,2);assert.equal(a.evidenceTotal,100);assert.deepEqual(a.validation,{'Completed · fail':1,'failed · basis-stale':1});
 const b=summarizeWork(p,'b');assert.equal(b.workers.length,0);assert.equal(b.unassignedGoals.length,1);assert.equal(b.pending,2);assert.deepEqual(summarizeWork({}).counts,{});
});

test('open offline workers remain visibly incomplete setup',()=>{
 const s=summarizeWork({workers:{w:{id:'w',status:'open',occupancy:'OFFLINE'}}});
 assert.equal(s.offlineWorkers.length,1);assert.deepEqual(s.counts,{OFFLINE:1});
});
