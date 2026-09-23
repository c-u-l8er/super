import test from 'node:test';import assert from 'node:assert/strict';
import {recoveryRecord,validateRecovery,recoveredReference,checkRecoveredBasis,unavailableReason,RECOVERY_SCHEMA} from '../cockpit/ui/proposal-recovery.js';
const basis={schema:'selected-file-basis@1',basis_id:'b'.repeat(64),head:'h'.repeat(40),path:'a/b.js',disk_sha256:'d'.repeat(64),draft_sha256:'e'.repeat(64),draft_bytes:6,unsaved:false};
const reference={kind:'editor',key:'a/b.js',title:'a/b.js',original:'before',draft:'before',source:basis,task:{id:'dt_1',revision:2,world:'["w",1]'},session:'s1',generation:3};
const proposal={path:'a/b.js',content:'after'};
test('a live reference with a basis becomes a recovery record carrying target, content, basis and plan',()=>{
  const r=recoveryRecord(reference,proposal);
  assert.equal(r.schema,RECOVERY_SCHEMA);assert.equal(r.path,'a/b.js');assert.equal(r.content,'after');assert.equal(r.draft,'before');assert.equal(r.original,'before');
  assert.equal(r.source.disk_sha256,basis.disk_sha256);assert.deepEqual(r.task,{id:'dt_1',revision:2,world:'["w",1]'});
  assert.ok(!('draft_bytes' in r.source),'only the identity fields of the basis are kept');
});
test('a share without a basis is NOT recoverable, and a basis is never manufactured',()=>{
  assert.equal(recoveryRecord({...reference,source:undefined},proposal),null);
  assert.equal(recoveryRecord({...reference,draft:undefined},proposal),null);
  assert.equal(recoveryRecord(reference,{...proposal,path:'other.js'}),null,'a proposal for a path other than the shared one is not tied to this basis');
  assert.match(unavailableReason('Proposed file edit\nx.js · 3 bytes'),/before proposals kept their original basis/);
  assert.match(unavailableReason({text:'x'}),/without its original basis/);
  assert.equal(unavailableReason({text:'x',recovery:recoveryRecord(reference,proposal)}),null);
});
test('validation refuses malformed, mismatched and oversized records',()=>{
  const good=recoveryRecord(reference,proposal);
  assert.deepEqual(validateRecovery(good),good);
  assert.throws(()=>validateRecovery({...good,schema:'x'}),/Invalid proposal recovery/);
  assert.throws(()=>validateRecovery({...good,path:'../b.js'}),/Invalid recovery path/);
  assert.throws(()=>validateRecovery({...good,source:{...good.source,path:'c.js'}}),/different file/);
  assert.throws(()=>validateRecovery({...good,content:'x'.repeat(262145)}),/Invalid recovery content/);
  assert.throws(()=>validateRecovery({...good,task:{id:'dt_1',revision:0,world:'w'}}),/plan link/);
  assert.throws(()=>validateRecovery({...good,source:{...good.source,schema:'other'}}),/Invalid recovery basis/);
});
test('a recovered reference is unbound until the host re-verifies the disk digest; head and basis_id may move',()=>{
  const record=recoveryRecord(reference,proposal),ref=recoveredReference(record);
  assert.equal(ref.recovered,true);assert.equal(ref.session,undefined);assert.equal(ref.generation,undefined);assert.equal(ref.key,'a/b.js');assert.equal(ref.draft,'before');
  const fresh={...basis,head:'g'.repeat(40),basis_id:'z'.repeat(64)};
  assert.equal(checkRecoveredBasis(record,fresh),fresh,'a later commit does not invalidate a proposal whose file is unchanged');
  assert.throws(()=>checkRecoveredBasis(record,{...fresh,disk_sha256:'f'.repeat(64)}),/outdated.*newer work.*Nothing has been written/s);
  assert.throws(()=>checkRecoveredBasis(record,{...fresh,path:'other.js'}),/different file/);
  assert.throws(()=>checkRecoveredBasis(record,null),/did not return a file basis/);
});
test('a proposal against a file that did not exist recovers with a null disk digest and must still match',()=>{
  const r=recoveryRecord({...reference,original:null,draft:'',source:{...basis,disk_sha256:null}},{path:'a/b.js',content:'new'});
  assert.equal(r.original,null);assert.equal(r.source.disk_sha256,null);
  assert.ok(checkRecoveredBasis(r,{...basis,disk_sha256:null}));
  assert.throws(()=>checkRecoveredBasis(r,{...basis,disk_sha256:'d'.repeat(64)}),/outdated/);
});
