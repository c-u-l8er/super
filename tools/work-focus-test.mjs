import test from 'node:test';import assert from 'node:assert/strict';
import {workFocus,focusChoice,saveFocus} from '../cockpit/ui/work-focus.js';
const world='world-a';const task=(id,status='planned')=>({id,title:id,status,revision:1,bot_ref:'bot',history:[],criteria:'Do it'});
const p={bots:{bot:{client_ref:'profile',name:'Fable'}},development_tasks:{a:task('a'),b:task('b')},development_attempts:{}};
test('runtime restart preserves focus but a different world generation does not',()=>{const values=new Map(),s={getItem:k=>values.get(k),setItem:(k,v)=>values.set(k,v)};saveFocus(s,JSON.stringify(['world',1,'old-epoch']),'b');assert.equal(focusChoice(s,JSON.stringify(['world',1,'new-epoch'])),'b');assert.equal(focusChoice(s,JSON.stringify(['world',2,'new-epoch'])),null);});
test('focus survives reload and is isolated by world',()=>{const values=new Map(),s={getItem:k=>values.get(k),setItem:(k,v)=>values.set(k,v)};saveFocus(s,world,'b');assert.equal(focusChoice(s,world),'b');assert.equal(focusChoice(s,'other'),null);assert.equal(workFocus(p,world,focusChoice(s,world)).task.id,'b');});
test('only completed or cancelled plans leave the queue',()=>{const q=structuredClone(p);q.development_tasks.a.status='completed';assert.equal(workFocus(q,world,'a').task.id,'b');q.development_tasks.b.status='blocked';assert.equal(workFocus(q,world,'b').task.id,'b');assert.equal(workFocus(q,world,'b').label,'Resolve this task’s blocker');});
test('active reply belongs to the exact bot, task revision, and world',()=>{const session={botId:'profile',world,reply:'Waiting for reply',tasks:[{id:'a',revision:1,world}]};assert.equal(workFocus(p,world,'a',session).waiting,true);assert.equal(workFocus(p,world,'b',session).waiting,false);for(const changed of [{...session,world:'other'},{...session,botId:'other'},{...session,tasks:[{id:'a',revision:2,world}]}])assert.equal(workFocus(p,world,'a',changed).step,1);});
test('completed reply leads to review, not automatic completion',()=>{const v=workFocus(p,world,'a',{botId:'profile',world,reply:'Reply received',tasks:[{id:'a',revision:1,world}]});assert.equal(v.step,3);assert.equal(v.target,'conversation');assert.equal(v.queue.length,2);});
test('withdrawal never reuses cached task guidance',()=>{const v=workFocus(null,world,'a');assert.equal(v.state,'unavailable');assert.equal(v.task,undefined);assert.equal(workFocus(p,null,'a').state,'unavailable');});
test('accepted review requires explicit plan completion',()=>{const q=structuredClone(p);q.development_attempts.r={id:'r',task_ref:'a',task_revision:1,status:'accepted',acceptance:{schema:'development-acceptance@1',task_revision:1}};const v=workFocus(q,world,'a');assert.equal(v.step,5);assert.equal(v.task.id,'a');assert.equal(v.label,'Confirm this task is finished');});

test('restored attachments cannot hide failure recovery behind send guidance',()=>{
 const session={botId:'profile',world,reply:'Reply did not complete',prepared:true,recovery:'capacity',tasks:[{id:'a',revision:1,world}]};
 assert.equal(workFocus(p,world,'a',session).label,'Review model availability');
 assert.equal(workFocus(p,world,'a',{...session,recovery:'sign_in'}).label,'Reconnect the assigned bot');
 assert.equal(workFocus(p,world,'b',session).step,1);
 assert.equal(workFocus(p,world,'a',{...session,tasks:[{id:'a',revision:2,world}]}).step,1);
});
