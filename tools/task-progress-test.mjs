import test from 'node:test';
import assert from 'node:assert/strict';
import {taskProgress,taskProgressRows} from '../cockpit/ui/task-progress.js';
const task={id:'t',revision:2,status:'planned',workspace_ref:'w',bot_ref:'b'};
const attempt={id:'a',task_ref:'t',task_revision:2,status:'recorded'};
const run={run_id:'r',started_at:'2026-09-10',state:'completed',outcome:{verdict:'pass',snapshot_sha256:'s'}};
const projection=(a=[])=>({development_tasks:{t:task},development_attempts:Object.fromEntries(a.map(x=>[x.id,x]))});
test('unavailable and empty tasks cannot claim execution or passing checks',()=>{assert.equal(taskProgress(null,task).state,'unavailable');assert.equal(taskProgress(projection(),task).state,'prepare');assert.equal(taskProgress(projection([attempt]),task).state,'checks_missing');});
test('failed, mismatched and unfinished profiles cannot become ready for decision',()=>{
 const p=a=>taskProgress(projection([{...attempt,test_runs:a}]),task).state;
 assert.equal(p({r:run}),'decision');
 assert.equal(p({r:{...run,outcome:{verdict:'fail'}}}),'checks_attention');
 assert.equal(p({r:run,z:{...run,run_id:'z',profile:'rust',outcome:{verdict:'pass',snapshot_sha256:'other'}}}),'checks_attention');
 assert.equal(p({r:{...run,state:'started'}}),'waiting');
});
test('completion requires a matching accepted receipt and no current open review',()=>{
 const accepted={...attempt,status:'accepted',acceptance:{schema:'development-acceptance@1',task_revision:2}};
 assert.equal(taskProgress(projection([accepted]),task).state,'finish');
 assert.equal(taskProgress(projection([{...accepted,acceptance:{schema:'development-acceptance@1',task_revision:1}}]),task).state,'prepare');
 assert.equal(taskProgress(projection([accepted,{...attempt,id:'z'}]),task).state,'checks_missing');
 assert.equal(taskProgress(projection([accepted,{...attempt,id:'old',task_revision:1,test_runs:{r:{...run,state:'started'}}}]),task).state,'waiting');
});
test('blockers and terminal plans retain honest guidance',()=>{
 assert.equal(taskProgress(projection(),{...task,status:'blocked',history:[{note:'Need design'}]}).reason,'Need design');
 for(const status of ['completed','cancelled'])assert.equal(taskProgress(projection([attempt]),{...task,status}).state,status);
 assert.equal(taskProgress(projection([{...attempt,status:'needs_changes'}]),task).state,'needs_changes');
});
test('workspace and bot lists intersect and exclude closed plans without modifying records',()=>{
 const p=projection();p.development_tasks.other={...task,id:'other',workspace_ref:'x',bot_ref:'c'};p.development_tasks.closed={...task,id:'closed',status:'completed'};
 const before=structuredClone(p);assert.deepEqual(taskProgressRows(p,'w','b').map(r=>r.task.id),['t']);assert.deepEqual(taskProgressRows(p,'w','c'),[]);assert.deepEqual(taskProgressRows(null),[]);assert.deepEqual(p,before);
});

test('combined review guidance requires tests before a decision',()=>{const task={id:'dt_set',revision:1,status:'planned'};const p={development_attempts:{a:{id:'a',schema:'development-review-set@1',task_ref:task.id,task_revision:1,status:'recorded'}}};const result=taskProgress(p,task);assert.equal(result.state,'checks_missing');assert.match(result.reason,/run the appropriate test profile/);assert.equal(result.attempt,'a');});
