import test from 'node:test';import assert from 'node:assert/strict';
import {schematicLayout,adjacentNodes,clampZoom} from '../cockpit/ui/schematics-layout.js';
test('paths use only existing endpoints and positions stay stable as state changes',()=>{const nodes=[{id:'a'},{id:'b'}],edges=[{from:'a',to:'b',label:'flows'},{from:'a',to:'missing'}];const a=schematicLayout(nodes,edges,2),b=schematicLayout(nodes.map(n=>({...n,state:'running'})),edges,2);assert.deepEqual(a,b);assert.equal(a.paths.length,1);assert.ok(a.paths[0].path.startsWith('M '));});
test('tracing includes direct connections without lighting unrelated work',()=>{assert.deepEqual([...adjacentNodes('a',[{from:'a',to:'b'},{from:'c',to:'a'},{from:'b',to:'d'}])].sort(),['a','b','c']);});
test('zoom has bounded readable steps',()=>{assert.equal(clampZoom(.1),.5);assert.equal(clampZoom(3),1.5);assert.equal(clampZoom(.89999999),.9);});
