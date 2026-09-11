import {test} from 'node:test';
import assert from 'node:assert/strict';
import {creationDestination,confirmedDestination} from '../cockpit/ui/creation-navigation.js';
const origin={world:'world-a',route:3,seq:10};
for(const [name,kind,collection,prefix] of [['open_workspace','workspace','workspaces','position-workspace'],['open_goal','goal','goals','goal'],['open_lane','lane','lanes','lane'],['open_worker','worker','workers','worker']])test(`${kind} opens only after its exact returned ID is projected`,()=>{
 const pending=creationDestination(name,{allow:true,[kind]:{id:'new-id'}},origin);
 assert.equal(pending.key,`${prefix}:new-id`);
 assert.equal(confirmedDestination(pending,{seq:11,projection:{[collection]:{other:{id:'other'}}}},'world-a',3).pending,pending);
 assert.equal(confirmedDestination(pending,{seq:10,projection:{[collection]:{'new-id':{}}}},'world-a',3).key,undefined);
 assert.equal(confirmedDestination(pending,{seq:11,projection:{[collection]:{'new-id':{}}}},'world-a',3).key,`${prefix}:new-id`);
});
test('refusal and malformed receipts never schedule navigation',()=>{
 for(const result of [{refusal:{code:'refused'}},{allow:false,workspace:{id:'ws_1'}},{allow:true,workspace:{}},null])assert.equal(creationDestination('open_workspace',result,origin),null);
});
test('changing page or world cancels a pending redirect',()=>{
 const p=creationDestination('open_workspace',{allow:true,workspace:{id:'ws_1'}},origin);
 assert.deepEqual(confirmedDestination(p,null,'world-b',3),{pending:null});
 assert.deepEqual(confirmedDestination(p,null,'world-a',4),{pending:null});
});
