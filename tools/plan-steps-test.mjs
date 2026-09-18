import test from 'node:test';
import assert from 'node:assert/strict';
import {planSteps,completionReason,STEPS} from '../cockpit/ui/plan-steps.js';

const task=(over={})=>({id:'dt_0052',revision:5,status:'planned',required_checks:{profiles:['super-javascript-behavior@1']},history:[{at:'2026-09-18T14:00:00Z',status:'planned',note:'x'}],...over});
const run={run_id:'run-1',state:'completed',profile:'super-javascript-behavior@1',outcome:{verdict:'pass',test_count:45,snapshot_sha256:'2cf7be6cfafa0000000000000000000000000000000000000000000000000000'}};
const accepted={id:'da_0062',task_ref:'dt_0052',task_revision:5,status:'accepted',source:{path:'mobile/ui/conversations.js'},test_runs:{'run-1':run},acceptance:{schema:'development-acceptance@1',task_revision:5,run_id:'run-1',snapshot_sha256:run.outcome.snapshot_sha256}};
const states=r=>r.steps.map(s=>s.state).join(' ');

test('a fresh plan is at Prepare and nothing is done',()=>{
 const r=planSteps({development_attempts:{}},task());
 assert.deepEqual(r.steps.map(s=>s.key),STEPS.map(([k])=>k));
 assert.equal(states(r),'current todo todo todo todo');
 assert.equal(r.current,'prepare');assert.equal(r.finishable,false);
});
test('an accepted result at this revision makes Finish the current step, everything before it done',()=>{
 const r=planSteps({development_attempts:{da_0062:accepted}},task());
 assert.equal(states(r),'done done done done current');
 assert.equal(r.current,'finish');assert.equal(r.finishable,true);
});
test('a recorded proposal with no checks is at Run checks; a running check is blocked there',()=>{
 const recorded={...accepted,id:'da_0070',status:'recorded',acceptance:undefined,test_runs:{}};
 assert.equal(states(planSteps({development_attempts:{da_0070:recorded}},task())),'done done current todo todo');
 const running={...recorded,test_runs:{r:{run_id:'r',state:'started'}}};
 assert.equal(states(planSteps({development_attempts:{da_0070:running}},task())),'done done blocked todo todo');
});
test('a blocked plan is blocked at the first step; completed and cancelled plans have no current step',()=>{
 assert.equal(states(planSteps({development_attempts:{}},task({status:'blocked'}))),'blocked todo todo todo todo');
 const done=planSteps({development_attempts:{da_0062:accepted}},task({status:'completed'}));
 assert.equal(states(done),'done done done done done');assert.equal(done.current,null);assert.equal(done.completed,true);
 assert.equal(planSteps({development_attempts:{}},task({status:'cancelled'})).cancelled,true);
});
test('an accepted result at an OLDER revision still finishes the plan: criteria are immutable, a note only bumps the revision',()=>{
 const r=planSteps({development_attempts:{da_0062:accepted}},task({revision:6}));
 assert.equal(r.finishable,true);assert.equal(r.current,'finish');
});
test('the drafted reason names the accepted attempt, file, test count and snapshot, and fits the 250-character input',()=>{
 const p={development_attempts:{da_0062:accepted,da_0030:{id:'da_0030',task_ref:'dt_0052',task_revision:3,status:'recorded'}}};
 const text=completionReason(p,task());
 assert.equal(text,'Accepted at revision 5 — da_0062 (mobile/ui/conversations.js): 45 tests passed on snapshot 2cf7be6cfafa. 2 review attempts recorded. Criteria met.');
 assert.ok(text.length<=250);
});
test('no accepted result, no draft; and a long draft falls back to ids and still fits',()=>{
 assert.equal(completionReason({development_attempts:{}},task()),'');
 assert.equal(completionReason(null,task()),'');
 const many={};for(let i=0;i<6;i++){many['da_01'+i]={...accepted,id:'da_01'+i,source:{path:'a/very/long/path/to/some/deeply/nested/module/file-number-'+i+'.js'}};}
 const text=completionReason({development_attempts:many},task());
 assert.ok(text.length<=250,String(text.length));
 assert.ok(text.startsWith('Accepted at revision 5 — da_010, da_011'));
});
