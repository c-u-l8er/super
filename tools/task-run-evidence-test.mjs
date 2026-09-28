import test from 'node:test';
import assert from 'node:assert/strict';
import {comparisonNotes} from '../cockpit/ui/task-run-evidence.js';
const before={id:'a',profile:'tests',machine:'host1',revision:1,snapshot:'old',toolchain:'node1'};
test('a later source is comparable but is not declared an improvement',()=>assert.deepEqual(comparisonNotes(before,{...before,id:'b',snapshot:'new'}),[]));
test('same run and same source cannot demonstrate a change',()=>assert.equal(comparisonNotes(before,before).length,2));
test('machine, profile, revision and toolchain differences are disclosed',()=>assert.equal(comparisonNotes(before,{id:'b',profile:'bench',machine:'host2',revision:2,snapshot:'new',toolchain:'node2'}).length,4));
test('missing baseline is explicit',()=>assert.match(comparisonNotes(null,before)[0],/Choose two/));
// T23 · the status line for a plan whose archived attempts are outside the frame's window.
import {runEvidenceStatus} from '../cockpit/ui/task-run-evidence.js';
const withheldPlan={id:'t',status:'completed',archived:{schema:'archived-record-card@1',omitted:['history'],read_with:'read_development_task',attempts:{carried:false,count:2,refs:['da_1','da_2'],runs:3}}};
test('T23 · a withheld plan is never told its checks have no baseline',()=>{
 const s=runEvidenceStatus(0,0,withheldPlan);
 assert.match(s,/^0 recorded runs in this view\./);
 assert.match(s,/2 review attempts and 3 profile runs are kept in the world/);
 assert.doesNotMatch(s,/No baseline has been recorded|Run task checks/);
});
test('T23 · any other plan reads exactly as before',()=>{
 assert.equal(runEvidenceStatus(0,0,{id:'t'}),'0 recorded runs. Run task checks to capture output. No baseline has been recorded.');
 assert.equal(runEvidenceStatus(2,1,{id:'t'}),'2 recorded runs. Some local history could not be loaded.');
});
