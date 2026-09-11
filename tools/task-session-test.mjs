import test from 'node:test';import assert from 'node:assert/strict';
import {taskSessionView} from '../cockpit/ui/task-session.js';
const task={id:'t',revision:2,bot_ref:'b'},p={bots:{b:{client_ref:'client'}}},value={botId:'client',world:'w',ready:true,reply:'Waiting for reply',message:'Waiting',tasks:[{id:'t',revision:2,world:'w'}]};
test('only matching task revision, bot and world receive task reply status',()=>{
 assert.equal(taskSessionView(p,task,'w',value).label,'Waiting for reply');
 for(const tasks of [[],[{id:'other',revision:2,world:'w'}],[{id:'t',revision:1,world:'w'}],[{id:'t',revision:2,world:'old'}]])assert.equal(taskSessionView(p,task,'w',{...value,tasks}).label,'Provider connected');
 for(const change of [{botId:'other'},{world:'old'}])assert.equal(taskSessionView(p,task,'w',{...value,...change}).label,'Connection not checked in this view');
});
test('withdrawal and reload never restore a live reply or connection',()=>{assert.equal(taskSessionView(null,task,'w',value).available,false);assert.equal(taskSessionView(p,task,'w',null).label,'Connection not checked in this view');assert.equal(taskSessionView(p,task,null,value).available,false);});
test('disconnected bot and failed task reply remain distinguishable',()=>{assert.equal(taskSessionView(p,task,'w',{...value,ready:false,reply:null}).label,'Provider needs connection');assert.equal(taskSessionView(p,task,'w',{...value,reply:'Reply did not complete'}).label,'Reply did not complete');});
