import test from 'node:test';
import assert from 'node:assert/strict';
import {activityStart,activityUpdate,taskActivityFor,replyFailure,replyRecovery,ACTIVITY_TEXT_LIMIT,ACTIVITY_EVENT_LIMIT} from '../cockpit/ui/task-activity.js';
const world='world',task={id:'task',revision:3,bot_ref:'bot',status:'planned'},p={bots:{bot:{client_ref:'profile'}}};
const start=()=>activityStart({id:'request',botId:'profile',world,tasks:[{id:'task',revision:3,world}],provider:'claude',model:'test'},10);
test('activity matches exact task revision, assigned bot, and runtime session',()=>{
 const value=start();assert.equal(taskActivityFor(p,task,world,[value]),value);
 for(const stale of [{...value,world:'old'},{...value,botId:'other'},{...value,tasks:[{id:'other',revision:3,world}]},{...value,tasks:[{id:'task',revision:2,world}]},{...value,tasks:[{id:'task',revision:3,world:'old'}]}])assert.equal(taskActivityFor(p,task,world,[stale]),null);
 assert.equal(taskActivityFor(null,task,world,[value]),null);assert.equal(taskActivityFor(p,{...task,status:'completed'},world,[value]),null);assert.equal(taskActivityFor(p,task,world,[]),null);
});
test('request lifecycle records meaningful events and bounded observed text',()=>{
 let s=start();s=activityUpdate(s,{id:s.id,active:true},20);s=activityUpdate(s,{id:s.id,active:true,received_bytes:9001,text:'x'.repeat(9001)},30);
 assert.equal(s.phase,'Receiving reply');assert.equal(s.text.length,ACTIVITY_TEXT_LIMIT);assert.equal(s.bytes,9001);assert.deepEqual(s.events.map(e=>e.label),['Request sent','Provider started','Assistant text received']);
 s=activityUpdate(s,{id:s.id,type:'finish',text:'Final reply'},40);assert.equal(s.status,'complete');assert.equal(s.text,'Final reply');assert.equal(s.events.at(-1).label,'Reply complete');
});
test('identical polls and late results cannot create activity or resurrect a finished reply',()=>{
 const s=start();assert.equal(activityUpdate(s,{id:'wrong',text:'leak'}),s);assert.equal(activityUpdate(s,{id:s.id}),s);
 const ended=activityUpdate(s,{id:s.id,type:'finish',error:true},20);assert.equal(ended.status,'stopped');assert.equal(activityUpdate(ended,{id:s.id,text:'late',active:true}),ended);
});
test('cancellation is observed separately from a stopped reply',()=>{
 const s=activityUpdate(start(),{id:'request',cancelled:true},20);assert.equal(s.status,'running');assert.equal(s.phase,'Cancelling reply');assert.equal(activityUpdate(s,{id:s.id,cancelled:true}),s);
});
test('byte observations never go backwards or become non-finite',()=>{
 const s=activityUpdate(start(),{id:'request',received_bytes:100,text:'A'},20);
 for(const bytes of [-1,0,NaN,Infinity])assert.equal(activityUpdate(s,{id:s.id,received_bytes:bytes}).bytes,100);
});
test('a new request starts empty; the latest matching request wins',()=>{
 const old=activityUpdate(start(),{id:'request',type:'finish',text:'Old reply'},20),next=activityStart({...start(),id:'next'},30);
 assert.equal(next.text,'');assert.equal(next.events.length,1);assert.equal(taskActivityFor(p,task,world,[old,next]),next);assert.ok(next.events.length<=ACTIVITY_EVENT_LIMIT);
});

test('failure guidance distinguishes actionable causes without retaining raw errors',()=>{
 for(const [error,kind] of [["Claude's model usage limit has been reached.",'capacity'],['Provider returned HTTP 429.','capacity'],['Claude sign-in has expired.','sign_in'],['Reply cancelled.','cancelled'],['Request timed out','timeout'],['Provider returned HTTP 503.','connection'],['Check model access and usage limits','unknown']]){
  assert.equal(replyFailure(error),kind);const ended=activityUpdate(start(),{id:'request',type:'finish',error:true,failure:error+' secret-example'},20);
  assert.equal(ended.recovery,kind);assert.equal(ended.phase,replyRecovery(kind).phase);assert.ok(!JSON.stringify(ended).includes('secret-example'));assert.match(replyRecovery(kind).detail,/Nothing is resent automatically/);assert.equal(replyRecovery('constructor').phase,'Reply stopped');
 }
});
test('cancellation observation survives a generic final error and new requests clear recovery',()=>{
 const cancelled=activityUpdate(start(),{id:'request',cancelled:true},20),ended=activityUpdate(cancelled,{id:'request',type:'finish',error:true},30);
 assert.equal(ended.phase,'Reply cancelled');assert.equal(activityStart({...ended,id:'new'},40).recovery,undefined);
});
