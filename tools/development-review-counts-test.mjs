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
