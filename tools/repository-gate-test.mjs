import test from 'node:test';
import assert from 'node:assert/strict';
import {gatePaths,gatesIn,snapshotScope} from './lib/proposal-test-runner.mjs';

// repository-python-gate@1 is closed the way the other profiles are closed: the
// gates it may run, their arguments and the paths they need are a table inside
// Super. A caller supplies none of it — it supplies only the files it reviewed.

const members=paths=>paths.map(path=>({source:{path}}));
const filler=n=>Array.from({length:n},(_,i)=>`bench/data/f${i}.json`);
const trvm=[...filler(1500),'compiled/laws_gate.py','compiled/laws.py','compiled/emit_c.py','forge/spinner_bench.py','runtime/python/compiler.py','runtime/c/ic32.c','README.md'];

test('the allowlist is Super own, and a repository is admitted only by having one of its gates',()=>{
  assert.deepEqual(gatePaths(),['tools/succession_laws_gate.py','compiled/laws_gate.py']);
  assert.deepEqual(gatesIn(trvm).map(g=>g.path),['compiled/laws_gate.py']);
  assert.deepEqual(gatesIn(['README.md','tools/whatever.py']),[]);
  for(const g of gatesIn(trvm))assert.deepEqual(g.args,['--check']);
});
test('the gate scope is what its gates declare plus the reviewed paths, and nothing else',()=>{
  const scope=snapshotScope('repository-python-gate@1',members(['compiled/laws.py','docs/note.md']),trvm);
  assert.deepEqual([...scope].sort(),['compiled/emit_c.py','compiled/laws.py','compiled/laws_gate.py','docs/note.md','forge/spinner_bench.py','runtime/python/compiler.py']);
  assert.ok(scope.size<=1024,'a 1500-file repository stays far inside the snapshot bound');
  assert.equal(scope.has('runtime/c/ic32.c'),false);
  assert.equal(scope.has('bench/data/f0.json'),false);
});
test('a repository with no gate this profile knows is refused, by name',()=>{
  assert.throws(()=>snapshotScope('repository-python-gate@1',members(['a.py']),['a.py','README.md']),
    /No gate this profile knows is in this repository: tools\/succession_laws_gate\.py, compiled\/laws_gate\.py\./);
});
test('every other profile keeps the scope it had',()=>{
  assert.deepEqual([...snapshotScope('repository-document-review@1',members(['docs/note.md']),trvm)],['docs/note.md']);
  for(const p of ['super-javascript-behavior@1','super-elixir-review@1','super-rust-review@1'])
    assert.equal(snapshotScope(p,members(['tools/x.mjs']),trvm),null,p);
});
