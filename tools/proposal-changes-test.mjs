import test from 'node:test';import assert from 'node:assert/strict';
import {proposalChanges,displayLine} from '../cockpit/ui/proposal-changes.js';
import {taskFileAttachment} from '../cockpit/ui/task-file-context.js';
test('identical drafts produce no changed rows',()=>assert.deepEqual(proposalChanges('one\ntwo\n','one\ntwo\n'),{rows:[],added:0,removed:0,coarse:false,truncated:false,omitted:0,unchanged:true}));
test('insertions and deletions retain original and proposed line numbers',()=>{
 const d=proposalChanges('a\nb\nc\n','a\nx\nc\n');assert.equal(d.added,1);assert.equal(d.removed,1);
 assert.deepEqual(d.rows,[{kind:'removed',oldLine:2,newLine:null,text:'b\n'},{kind:'added',oldLine:null,newLine:2,text:'x\n'}]);
 assert.equal(proposalChanges('','new\n').added,1);assert.equal(proposalChanges('old\n','').removed,1);
});
test('separate edits preserve the unchanged interior',()=>{
 const d=proposalChanges('a\nb\nc\nd\ne\n','a\nx\nc\ny\ne\n');
 assert.equal(d.added,2);assert.equal(d.removed,2);assert.deepEqual(d.rows.filter(r=>r.kind==='context'),[{kind:'context',oldLine:3,newLine:3,text:'c\n'}]);
});
test('final newlines, CRLF and whitespace-only edits are visible',()=>{
 for(const [a,b] of [['a','a\n'],['a\r\n','a\n'],['a \n','a\n']]){const d=proposalChanges(a,b);assert.equal(d.unchanged,false);assert.equal(d.added,1);assert.equal(d.removed,1);}
 assert.equal(displayLine('a\r\n'),'a ⟦CRLF⟧');assert.equal(displayLine('a'),'a ⟦no final newline⟧');
});
test('comparison and rendering limits are explicit and counts remain complete',()=>{
 const a='old\n'.repeat(1000),b='new\n'.repeat(1000),d=proposalChanges(a,b);assert.equal(d.coarse,true);assert.equal(d.added,1000);assert.equal(d.removed,1000);assert.equal(d.rows.length,600);assert.equal(d.omitted,1400);
});
test('plan-file attachment preserves exact source text and labels unverified matching',()=>{
 const task={id:'dt_1',revision:2,title:'Improve review',criteria:'Show changed lines.'};const draft='<script>example</script>\n';const text=taskFileAttachment(task,'review.html',draft);
 assert.ok(text.includes('dt_1 (revision 2)'));assert.ok(text.includes(task.criteria));assert.ok(text.endsWith(draft));assert.ok(text.includes('has not been verified'));
 assert.throws(()=>taskFileAttachment(task,'file','x'.repeat(32000)),/attachment limit/);
});

test('attachment claims a repository match only for its exact plan receipt',()=>{
 const task={id:'dt_1',revision:2,repository_ref:'rp_1',title:'Review',criteria:'Keep bytes'};
 const match={matched:true,task_ref:'dt_1',revision:2,repository_ref:'rp_1'};
 assert.ok(taskFileAttachment(task,'file','bytes',match).includes('matched the plan'));
 for(const wrong of [{...match,revision:1},{...match,repository_ref:'rp_2'},{...match,task_ref:'dt_2'}])assert.ok(taskFileAttachment(task,'file','bytes',wrong).includes('has not been verified'));
});

test('source identity survives attachment text without changing exact draft bytes',()=>{
 const task={id:'dt_1',revision:2,repository_ref:'rp_1',title:'Review',criteria:'Keep bytes'};
 const source={schema:'selected-file-basis@1',scope:'selected-file-only',basis_id:'basis',head:'commit',draft_sha256:'draft-hash'};
 const text=taskFileAttachment(task,'file','draft\r\n',undefined,source);
 assert.ok(text.includes(JSON.stringify(source)));assert.ok(text.includes('other working-tree files are not captured'));assert.ok(text.endsWith('draft\r\n'));
});
