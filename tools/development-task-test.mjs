import test from 'node:test';
import assert from 'node:assert/strict';
import {taskScope} from '../cockpit/ui/development-tasks.js';
const p={bots:{bt_1:{client_ref:'builder'},bt_2:{client_ref:'reviewer'}},development_tasks:{dt_1:{id:'dt_1',workspace_ref:'ws_1',bot_ref:'bt_1'},dt_2:{id:'dt_2',workspace_ref:'ws_2',bot_ref:'bt_2'},dt_3:{id:'dt_3',workspace_ref:'ws_1',bot_ref:'bt_2'}}};
test('task views intersect workspace and actual bot identity',()=>{
 assert.deepEqual(taskScope(p,'ws_1','builder').map(t=>t.id),['dt_1']);
 assert.deepEqual(taskScope(p,'ws_1','reviewer').map(t=>t.id),['dt_3']);
 assert.deepEqual(taskScope(p,'ws_2','builder'),[]);
 assert.equal(taskScope(p).length,3);
});
test('withdrawn or unknown identity never supplies stale task assignments',()=>{
 assert.deepEqual(taskScope(null),[]);
 assert.deepEqual(taskScope(p,'','missing'),[]);
 assert.deepEqual(taskScope({...p,bots:{}},'','builder'),[]);
});
