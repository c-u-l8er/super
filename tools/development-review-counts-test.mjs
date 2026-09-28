import test from 'node:test';
import assert from 'node:assert/strict';
import {taskReviewCounts} from '../cockpit/ui/development-tasks.js';
const accepted={schema:'development-acceptance@1'};
test('plan review counts are scoped to the requested plan and real acceptance records',()=>{
 const p={development_attempts:{a:{task_ref:'one',status:'accepted',acceptance:accepted},b:{task_ref:'one',status:'recorded'},c:{task_ref:'one',status:'needs_changes'},d:{task_ref:'one',status:'dismissed'},e:{task_ref:'two',status:'accepted',acceptance:accepted},f:{task_ref:'one',status:'accepted'},g:{task_ref:'one',status:'recorded'}}};
 const before=structuredClone(p);
 assert.deepEqual(taskReviewCounts(p,'one'),{accepted:1,awaiting:2,needsChanges:1});
 assert.deepEqual(taskReviewCounts(p,'two'),{accepted:1,awaiting:0,needsChanges:0});
 assert.deepEqual(taskReviewCounts(p,'missing'),{accepted:0,awaiting:0,needsChanges:0});
 assert.deepEqual(p,before);
});
test('missing projection and missing attempt collections have no review counts',()=>{
 assert.deepEqual(taskReviewCounts(null,'one'),{accepted:0,awaiting:0,needsChanges:0});
 assert.deepEqual(taskReviewCounts({},'one'),{accepted:0,awaiting:0,needsChanges:0});
});

// T23 · a plan whose archived attempts are outside the frame's window.
import {reviewSummary} from '../cockpit/ui/development-tasks.js';
const withheldPlan=(attempts)=>({id:'one',status:'completed',archived:{schema:'archived-record-card@1',omitted:['history'],read_with:'read_development_task',attempts}});
test('T23 · the list line never reads "0 accepted" for a plan whose reviews are withheld',()=>{
 const task=withheldPlan({carried:false,count:3,refs:['da_1','da_2','da_3'],runs:4});
 const s=reviewSummary({development_attempts:{}},task);
 assert.equal(s,'3 archived reviews not in this view');
 assert.doesNotMatch(s,/0 accepted/);
 // a cancelled plan can keep undecided LIVE attempts; those still count
 assert.equal(reviewSummary({development_attempts:{x:{task_ref:'one',status:'recorded'}}},task),'3 archived reviews not in this view · 1 awaiting decision');
});
test('T23 · a carried or live plan reads exactly as before',()=>{
 const p={development_attempts:{a:{task_ref:'one',status:'accepted',acceptance:accepted},b:{task_ref:'one',status:'recorded'}}};
 for(const task of [{id:'one',status:'planned'},withheldPlan({carried:true,count:1})])
  assert.equal(reviewSummary(p,task),'1 accepted · 1 awaiting decision · 0 need changes');
});
