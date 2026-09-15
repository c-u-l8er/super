import {test} from 'node:test';import assert from 'node:assert/strict';
import {requestLedger} from '../cockpit/ui/mobile-conversation-bridge.js';
const storage=()=>{const m=new Map();return {getItem:k=>m.get(k),setItem:(k,v)=>m.set(k,v)}};
const request=()=>({id:crypto.randomUUID(),createdAt:1000,operation:'send',text:'message'});
test('duplicate sends and reloads replay the receipt rather than the provider call',async()=>{const s=storage(),q=request();let calls=0;const perform=()=>{calls++;return {message:'sent'}};await requestLedger(s,()=>1000).run(q,perform);await requestLedger(s,()=>1000).run(q,perform);assert.equal(calls,1)});
test('changed content cannot reuse an old request identity',async()=>{const l=requestLedger(storage(),()=>1000),q=request();await l.run(q,()=>({message:'sent'}));await assert.rejects(l.run({...q,text:'different'},()=>assert.fail()),/different content/)});
test('expired requests cannot be dispatched after the deduplication window',async()=>{await assert.rejects(requestLedger(storage(),()=>500000).run(request(),()=>assert.fail()),/expired/)});
test('failure to persist prevents a provider call',async()=>{const s={getItem:()=>null,setItem:()=>{throw Error('disk full')}};await assert.rejects(requestLedger(s,()=>1000).run(request(),()=>assert.fail()),/disk full/)});
test('an interrupted dispatch stays uncertain on reload and is not resent',async()=>{const s=storage(),q=request();let release;const pending=requestLedger(s,()=>1000).run(q,()=>new Promise(r=>release=r));await new Promise(r=>setTimeout(r,10));const receipt=await requestLedger(s,()=>1000).run(q,()=>assert.fail());assert.equal(receipt.state,'uncertain');release({message:'sent'});await pending;});
