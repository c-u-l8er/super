import test from 'node:test';
import assert from 'node:assert/strict';
import {comparisonNotes} from '../cockpit/ui/task-run-evidence.js';
const before={id:'a',profile:'tests',machine:'host1',revision:1,snapshot:'old',toolchain:'node1'};
test('a later source is comparable but is not declared an improvement',()=>assert.deepEqual(comparisonNotes(before,{...before,id:'b',snapshot:'new'}),[]));
test('same run and same source cannot demonstrate a change',()=>assert.equal(comparisonNotes(before,before).length,2));
test('machine, profile, revision and toolchain differences are disclosed',()=>assert.equal(comparisonNotes(before,{id:'b',profile:'bench',machine:'host2',revision:2,snapshot:'new',toolchain:'node2'}).length,4));
test('missing baseline is explicit',()=>assert.match(comparisonNotes(null,before)[0],/Choose two/));
