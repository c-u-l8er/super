import test from 'node:test';
import assert from 'node:assert/strict';
import {recordGuidance} from '../cockpit/ui/record-guidance.js';
const p={goals:{g:{id:'g',workspace_ref:'a'},other:{id:'other',workspace_ref:'b'}},repositories:{r:{ref:'r'}},lanes:{l:{id:'l',goal_ref:'g',repository_ref:'r',actor:'builder'},o:{id:'o',goal_ref:'other',actor:'other'}},workers:{w:{id:'w',locus_ref:'l',status:'open',occupancy:'OFFLINE'},closed:{id:'closed',locus_ref:'l',status:'closed'}}};
test('workspace guidance counts only related delivered records',()=>{const s=recordGuidance(p,'Workspace',{id:'a'});assert.equal(s.lanes.length,1);assert.equal(s.workers.length,2);assert.deepEqual(s.states,{OFFLINE:1,closed:1});assert.deepEqual(s.flags.map(f=>f.record),['worker:w']);});
test('empty workspace links to a prefilled goal form',()=>{const s=recordGuidance(p,'Workspace',{id:'empty'});assert.deepEqual(s.flags[0].form,{field:'goal_ws',value:'empty',focus:'goal_title'});});
test('closed workers do not satisfy lane staffing',()=>{const data={...p,workers:{closed:p.workers.closed}};assert.equal(recordGuidance(data,'Lane',p.lanes.l).flags[0].form.field,'worker_lane');});
test('bot and repository scopes follow actual actor and repository relationships',()=>{assert.equal(recordGuidance(p,'Bot',{actor:'builder'}).workers.length,2);assert.equal(recordGuidance(p,'Repository',{ref:'r'}).lanes[0].id,'l');assert.equal(recordGuidance(p,'Bot',{actor:'missing'}).workers.length,0);});
test('missing repository and unstaffed lane remain actionable independently',()=>{const s=recordGuidance(p,'Goal',p.goals.other);assert.equal(s.flags.length,2);assert.equal(s.flags[0].nav,'repositories');assert.equal(s.flags[1].form.value,'o');});
