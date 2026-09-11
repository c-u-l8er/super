import test from 'node:test';
import assert from 'node:assert/strict';
import {botWork,watchable} from '../cockpit/ui/bot-work.js';
const p={bots:{b:{client_ref:'local',actor:'actor',workspace_ref:'ws'}},goals:{g:{workspace_ref:'ws'},other:{workspace_ref:'other'}},lanes:{l:{id:'l',actor:'actor',goal_ref:'g'},wrong:{id:'wrong',actor:'else',goal_ref:'g'},cross:{id:'cross',actor:'actor',goal_ref:'other'}},workers:{w:{id:'w',locus_ref:'l',status:'open',terminal:'PRESENT'},foreign:{id:'foreign',locus_ref:'wrong'}},carrier_attempts:{a:{ticket_id:'a',locus_ref:'l'},b:{ticket_id:'b',locus_ref:'wrong'}}};
test('work follows registered actor and workspace, never profile names or groups',()=>{const d=botWork(p,'local');assert.deepEqual(d.lanes.map(l=>l.id),['l']);assert.deepEqual(d.workers.map(w=>w.id),['w']);assert.deepEqual(d.attempts.map(a=>a.ticket_id),['a']);});
test('unregistered and unavailable states contain no old assignments',()=>{assert.equal(botWork(p,'unknown').state,'unregistered');assert.deepEqual(botWork(null,'local').workers,[]);assert.equal(botWork(null,'local').state,'unavailable');});
test('terminal viewing requires an open worker and explicitly present terminal',()=>{assert.equal(watchable(p.workers.w),true);for(const w of [{status:'closed',terminal:'PRESENT'},{status:'open',terminal:'ABSENT'},{status:'open'},null])assert.equal(watchable(w),false);});
