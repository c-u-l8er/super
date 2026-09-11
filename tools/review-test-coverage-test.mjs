import test from 'node:test';
import assert from 'node:assert/strict';
import {reviewTestCoverage} from '../cockpit/ui/review-test-coverage.js';
const run=(id,profile,verdict='pass',snapshot='same',state='completed')=>({run_id:id,started_at:id,profile,state,outcome:{verdict,snapshot_sha256:snapshot}});
test('only profiles actually run are required; legacy JavaScript remains supported',()=>{assert.equal(reviewTestCoverage({}).ready,false);assert.equal(reviewTestCoverage({a:run('1')}).ready,true);});
test('a later passing profile cannot hide another profile failure',()=>{const c=reviewTestCoverage({a:run('1','js','fail'),b:run('2','rust')});assert.equal(c.ready,false);assert.equal(c.rows.find(r=>r.profile==='js').status,'failed');});
test('only the latest result per profile counts and snapshots must agree',()=>{const runs={a:run('1','js','fail'),b:run('2','rust'),c:run('3','js','pass','changed')};assert.equal(reviewTestCoverage(runs).ready,false);runs.d=run('4','rust','pass','changed');assert.equal(reviewTestCoverage(runs).ready,true);});
test('pending or interrupted runs cannot be hidden by a completed result',()=>{assert.equal(reviewTestCoverage({a:run('1','js'),b:run('2','rust',null,null,'failed')}).ready,false);assert.equal(reviewTestCoverage({a:run('1','js',null,null,'started'),b:run('2','js')}).ready,false);});

test('required profiles cannot disappear behind another passing profile',()=>{const runs={a:run('1','js')};const c=reviewTestCoverage(runs,['js','rust']);assert.equal(c.ready,false);assert.equal(c.rows.find(r=>r.profile==='rust').status,'missing');runs.b=run('2','rust','fail');assert.equal(reviewTestCoverage(runs,['js','rust']).ready,false);runs.c=run('3','rust');assert.equal(reviewTestCoverage(runs,['js','rust']).ready,true);});
