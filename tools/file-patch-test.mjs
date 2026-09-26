import test from 'node:test';import assert from 'node:assert/strict';
import {applyFilePatch,checkPatchEdits,patchRecord,validatePatchRecord,PATCH_SCHEMA,PATCH_MAX_EDITS,PATCH_MAX_BYTES} from '../cockpit/ui/file-patch.js';
import {REVIEW_FILE_BYTES} from '../cockpit/ui/review-limits.js';

const base='function a(){\n  return 1;\n}\nfunction b(){\n  return 2;\n}\n';
test('T22b · one exact replacement changes that span and nothing else',()=>{
  assert.equal(applyFilePatch(base,[{old_text:'return 1;',new_text:'return 10;'}]),base.replace('return 1;','return 10;'));
});
test('T22b · every edit is located in the SHARED snapshot, not in the result of an earlier edit',()=>{
  // Edit 1 creates text that edit 2 quotes; sequential application would find it, snapshot application must not.
  assert.throws(()=>applyFilePatch(base,[{old_text:'return 1;',new_text:'return 3;'},{old_text:'return 3;',new_text:'x'}]),/Edit 2 does not apply: its old_text is not in the shared file/);
  // Order of edits does not matter; each lands where it was in the snapshot.
  const two=[{old_text:'return 2;',new_text:'return 20;'},{old_text:'return 1;',new_text:'return 10;'}];
  assert.equal(applyFilePatch(base,two),base.replace('return 1;','return 10;').replace('return 2;','return 20;'));
  assert.equal(applyFilePatch(base,[...two].reverse()),applyFilePatch(base,two));
});
test('T22b · absent, repeated and overlapping old_text are refused whole, by name',()=>{
  assert.throws(()=>applyFilePatch(base,[{old_text:'return 1;',new_text:'y'},{old_text:'nope',new_text:'z'}]),/Edit 2 does not apply: its old_text is not in the shared file\. Nothing was applied\./);
  assert.throws(()=>applyFilePatch(base,[{old_text:'function',new_text:'fn'}]),/Edit 1 does not apply: its old_text occurs 2 times/);
  assert.throws(()=>applyFilePatch('aaa',[{old_text:'aa',new_text:'b'}]),/occurs 2 times/,'overlapping occurrences of one old_text count');
  assert.throws(()=>applyFilePatch(base,[{old_text:'function a(){',new_text:'x'},{old_text:'a(){\n  return 1',new_text:'y'}]),/Edits 1 and 2 overlap/);
});
test('T22b · touching spans are allowed; empty new_text deletes; whitespace and CR are exact',()=>{
  assert.equal(applyFilePatch('abcdef',[{old_text:'abc',new_text:'X'},{old_text:'def',new_text:'Y'}]),'XY');
  assert.equal(applyFilePatch(base,[{old_text:'  return 1;\n',new_text:''}]),base.replace('  return 1;\n',''));
  assert.throws(()=>applyFilePatch('a\r\nb\r\n',[{old_text:'a\nb',new_text:'c'}]),/not in the shared file/,'a CRLF file is matched as CRLF, never normalized');
  assert.equal(applyFilePatch('a\r\nb\r\n',[{old_text:'a\r\nb',new_text:'c'}]),'c\r\n');
  assert.throws(()=>applyFilePatch(base,[{old_text:'return  1;',new_text:'x'}]),/not in the shared file/);
});
test('T22b · multi-byte text is matched and spliced on whole characters',()=>{
  const s='héllo 🙂 wörld 🙂 end';
  assert.equal(applyFilePatch(s,[{old_text:'wörld 🙂',new_text:'monde 😀'}]),'héllo 🙂 monde 😀 end');
  assert.throws(()=>applyFilePatch(s,[{old_text:'\ud83d',new_text:'x'}]),/unpaired surrogate/);
  assert.throws(()=>applyFilePatch(s,[{old_text:'end',new_text:'\ude42'}]),/unpaired surrogate/);
});
test('T22b · shape: exactly {old_text,new_text}, non-empty old_text, no NUL, bounded count and size',()=>{
  for(const bad of [undefined,null,{},[],'x']) assert.throws(()=>checkPatchEdits(bad),/no edits|edits/);
  assert.throws(()=>checkPatchEdits([{old_text:'a'}]),/exactly old_text and new_text/);
  assert.throws(()=>checkPatchEdits([{old_text:'a',new_text:'b',why:'c'}]),/exactly old_text and new_text/);
  assert.throws(()=>checkPatchEdits([{old_text:1,new_text:'b'}]),/both text/);
  assert.throws(()=>checkPatchEdits([{old_text:'',new_text:'b'}]),/Edit 1 has empty old_text/);
  assert.throws(()=>checkPatchEdits([{old_text:'a',new_text:'b\0'}]),/NUL/);
  assert.throws(()=>checkPatchEdits(Array.from({length:PATCH_MAX_EDITS+1},(_,i)=>({old_text:'k'+i,new_text:''}))),/at most 64 are allowed/);
  assert.equal(checkPatchEdits(Array.from({length:PATCH_MAX_EDITS},(_,i)=>({old_text:'k'+i,new_text:''}))).length,PATCH_MAX_EDITS);
  assert.throws(()=>checkPatchEdits([{old_text:'a',new_text:'é'.repeat(PATCH_MAX_BYTES/2)}]),/bytes of text; at most 65536/,'the bound is BYTES, not characters');
  assert.throws(()=>applyFilePatch('a\0b',[{old_text:'a',new_text:'c'}]),/not text this patch can apply to/);
});
test('T22b · a result over the review limit is refused, not truncated',()=>{
  const big='x'.repeat(REVIEW_FILE_BYTES-10)+'END';
  // big is REVIEW_FILE_BYTES-7 long; 'END' → k bytes gives REVIEW_FILE_BYTES-10+k: 10 fits exactly, 11 does not.
  assert.equal(applyFilePatch(big,[{old_text:'END',new_text:'y'.repeat(10)}]).length,REVIEW_FILE_BYTES);
  assert.throws(()=>applyFilePatch(big,[{old_text:'END',new_text:'y'.repeat(11)}]),/larger than the review limit/);
});
test('T22b · the recovery form keeps the edits exactly and nothing else',()=>{
  const edits=[{old_text:'return 1;',new_text:'return 10;'}];
  assert.deepEqual(patchRecord(edits),{schema:PATCH_SCHEMA,edits});
  assert.deepEqual(validatePatchRecord(patchRecord(edits)),patchRecord(edits));
  assert.throws(()=>validatePatchRecord({schema:'file-patch@2',edits}),/Invalid recovery patch/);
  assert.throws(()=>validatePatchRecord({schema:PATCH_SCHEMA,edits,extra:1}),/Invalid recovery patch/);
  assert.throws(()=>validatePatchRecord({schema:PATCH_SCHEMA,edits:[]}),/no edits/);
});

// A seeded generator, so a failure is reproducible from the printed seed.
function rng(seed){let s=seed>>>0||1;return()=>{s^=s<<13;s>>>=0;s^=s>>17;s^=s<<5;s>>>=0;return s/4294967296;};}
test('T22b · property: bytes outside the edited spans never change, and each span becomes exactly its new_text',()=>{
  const alphabet='ab\n é🙂{}();';let exercised=0,editsSeen=0;
  for(let seed=1;seed<=400;seed++){
    const r=rng(seed),pick=n=>Math.floor(r()*n),chars=[...alphabet];
    const text=Array.from({length:40+pick(400)},()=>chars[pick(chars.length)]).join('')+'';
    // choose disjoint spans over whole characters, keep only those whose text occurs once in the base
    const cps=[...text];const offsets=[];let o=0;for(const c of cps){offsets.push(o);o+=c.length;}offsets.push(o);
    const cuts=[...new Set(Array.from({length:2+pick(10)},()=>pick(cps.length+1)))].sort((x,y)=>x-y);
    const edits=[],kept=[];
    for(let i=0;i+1<cuts.length;i+=2){const s=offsets[cuts[i]],e=offsets[cuts[i+1]];const old=text.slice(s,e);
      if(!old||text.indexOf(old)!==s||text.indexOf(old,s+1)!==-1)continue;
      const nt=Array.from({length:pick(6)},()=>chars[pick(chars.length)]).join('');edits.push({old_text:old,new_text:nt});kept.push({s,e,nt});}
    if(!edits.length)continue;
    const shuffled=[...edits].sort(()=>r()-0.5);
    const got=applyFilePatch(text,shuffled);exercised++;editsSeen+=edits.length;
    let want='',from=0;for(const k of kept){want+=text.slice(from,k.s)+k.nt;from=k.e;}want+=text.slice(from);
    assert.equal(got,want,`seed ${seed}`);
  }
  assert.ok(exercised>=200&&editsSeen>=exercised,`only ${exercised} seeds (${editsSeen} edits) exercised the property`);
});
import {reviewableActions} from '../cockpit/ui/file-patch.js';
test('T22b · a reply\'s patch becomes a reviewable file proposal against the latest shared snapshot; nothing else moves',()=>{
  const shared={'big.js':[{draft:'old one'},{draft:'const a=1;\nconst b=2;\n'}]};
  const referenceFor=p=>(shared[p]??[]).at(-1);
  const setup={name:'open_workspace',args:{name:'W'}},edit={name:'propose_file_edit',args:{path:'x.js',content:'c'}};
  const patch={name:'propose_file_patch',args:{path:'big.js',edits:[{old_text:'b=2',new_text:'b=3'}]}};
  const actions=[setup,edit,patch],before=JSON.stringify(actions);
  const shown=reviewableActions(actions,referenceFor);
  assert.equal(shown[0],setup);assert.equal(shown[1],edit,'other actions pass through as the same objects');
  assert.deepEqual(shown[2],{name:'propose_file_edit',args:{path:'big.js',content:'const a=1;\nconst b=3;\n'},patch:{schema:PATCH_SCHEMA,edits:patch.args.edits}});
  assert.equal(JSON.stringify(actions),before,'the reply (and so the conversation history) keeps the patch as sent');
});
test('T22b · a patch with no shared snapshot, or one that does not apply, stays a refused patch that says why',()=>{
  const p=(path,edits)=>({name:'propose_file_patch',args:{path,edits}});
  const [none,noDraft,absent,twice]=reviewableActions([p('gone.js',[{old_text:'a',new_text:'b'}]),p('nodraft.js',[{old_text:'a',new_text:'b'}]),p('f.js',[{old_text:'zzz',new_text:'b'}]),p('f.js',[{old_text:'a',new_text:'b'}])],
    path=>({'nodraft.js':{key:'nodraft.js'},'f.js':{draft:'a a'}})[path]);
  assert.match(none.refused,/Share this file from Editor/);assert.equal(none.name,'propose_file_patch');
  assert.match(noDraft.refused,/Share this file from Editor/);
  assert.match(absent.refused,/Edit 1 does not apply: its old_text is not in the shared file/);
  assert.match(twice.refused,/occurs 2 times/);
  for(const r of [none,noDraft,absent,twice]){assert.ok(!('content' in r.args)&&!r.patch,'a refused patch carries no derived content');}
});
