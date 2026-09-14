import test from 'node:test';
import assert from 'node:assert/strict';
import {recordLabel,setReferenceFrame,readable} from '../cockpit/ui/references.js';
const projection={goals:{gl_0001:{id:'gl_0001',title:'Build Super'}},bots:{bt_0001:{id:'bt_0001',actor:'bot_opaque',name:'Fable'}},lanes:{ln_0001:{id:'ln_0001',goal_ref:'gl_0001',actor:'bot_opaque'}},repositories:{rp_0001:{ref:'rp_0001',name:'Super source'}}};
test('lane labels use actual goal and bot names with a stable secondary identity',()=>{assert.equal(recordLabel('ln_0001',{projection,withId:true}),'Build Super · Fable (ln_0001)');});
test('repository labels use names and references consistently',()=>{assert.equal(recordLabel('rp_0001',{projection,withId:true}),'Super source (rp_0001)');});
test('missing names fall back to the exact identity without opaque actor labels',()=>{assert.equal(recordLabel('ln_0001',{projection:{lanes:projection.lanes}}),'ln_0001');assert.equal(recordLabel('rp_9999',{projection}),'rp_9999');});
test('an explicit projection never resolves records from another world cache',()=>{setReferenceFrame({world:{world_incarnation:'other',world_generation:1,projection_epoch:'epoch'},projection});assert.equal(recordLabel('rp_0001',{projection:{}}),'rp_0001');assert.equal(recordLabel('rp_0001'),'Super source');setReferenceFrame(null);assert.equal(recordLabel('rp_0001'),'rp_0001');});
test('existing reference rendering continues to resolve normal and escaped IDs',()=>{setReferenceFrame({world:{world_incarnation:'w',world_generation:1,projection_epoch:'e'},projection});assert.equal(readable('gl_0001 and rp\\_0001'),'Build Super and Super source');setReferenceFrame(null);});
