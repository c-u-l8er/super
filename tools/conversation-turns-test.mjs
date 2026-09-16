import test from 'node:test';
import assert from 'node:assert/strict';
import {createTurnRegistry,turnStatus,conversationIdentity,sameConversation,holdingRefusal,holdingHint,turnLabel,TURN_STATES} from '../cockpit/ui/conversation-turns.js';

const A={botId:'assistant',provider:'codex',conversationId:'c-a'};
const rowA=(o={})=>({botId:'assistant',provider:'codex',id:'c-a',title:'Alpha',...o});
const rowB=(o={})=>({botId:'assistant',provider:'codex',id:'c-b',title:'Beta',...o});
const start=(r,o={})=>r.begin({...A,requestId:'req-1',messageCount:2,title:'Alpha',draft:'hello',files:[{name:'a.txt',content:'x'}],userMessage:{role:'user',content:'hello'},...o});

test('no browser is present',()=>{assert.equal(typeof globalThis.document,'undefined');assert.equal(typeof globalThis.window,'undefined');});

test('an idle registry holds nothing',()=>{const r=createTurnRegistry();
 assert.equal(r.inFlight(),false);assert.equal(r.current(),null);assert.equal(r.token(),null);assert.equal(r.request(),null);
 assert.equal(r.owns(rowA()),false);assert.equal(r.turnFor('assistant','codex','c-a'),null);assert.equal(r.statusFor(rowA()),null);
 assert.equal(r.matches(null),false);assert.equal(r.matches(1),false);});

test('a turn is owned by the conversation it was sent from',()=>{const r=createTurnRegistry(),token=start(r);
 assert.equal(r.inFlight(),true);assert.equal(r.matches(token),true);assert.equal(r.matches(token+1),false);
 assert.equal(r.owns(rowA()),true);assert.ok(r.turnFor('assistant','codex','c-a'));
 assert.equal(r.owns(rowB()),false,'a different conversation does not own it');
 assert.equal(r.owns(rowA({botId:'other'})),false,'a different bot does not own it');
 assert.equal(r.owns(rowA({provider:'claude'})),false,'a different provider bucket does not own it');
 assert.equal(r.turnFor('assistant','codex','c-b'),null);});

test('status follows the owning conversation, not the one being looked at',()=>{const r=createTurnRegistry();start(r);
 const turn=r.current();
 assert.equal(turnStatus(turn,rowA()),'Waiting');
 assert.equal(turnStatus(turn,rowB()),null,'a row that does not own the turn gets no turn status');
 assert.equal(turnStatus(turn,rowA({state:'Ready'})),'Waiting','a saved state never hides a live turn');
 assert.equal(turnStatus(null,rowA()),null);assert.equal(turnStatus(turn,null),null);
 assert.equal(r.statusFor(rowA()),'Waiting');});

test('waiting becomes generating on text and cancelling on request',()=>{const r=createTurnRegistry(),token=start(r);
 assert.equal(r.statusFor(rowA()),'Waiting');
 r.observe(token,{phase:'Thinking'});assert.equal(r.statusFor(rowA()),'Waiting','a phase alone is not prose');
 r.observe(token,{text:'partial answer'});assert.equal(r.statusFor(rowA()),'Generating');
 r.requestCancel(token);assert.equal(r.statusFor(rowA()),'Cancelling');
 for(const state of [r.statusFor(rowA())])assert.ok(TURN_STATES.includes(state));});

test('the slot is one and the refusal names the holder',()=>{const r=createTurnRegistry();start(r);
 assert.throws(()=>start(r,{conversationId:'c-b',title:'Beta'}),e=>{assert.match(e.message,/Alpha/);assert.doesNotMatch(e.message,/^Wait\b/);return true;});
 assert.equal(r.current().conversationId,'c-a','a refused begin leaves the held turn alone');});

test('begin refuses a turn with no identity',()=>{const r=createTurnRegistry();
 assert.throws(()=>r.begin({provider:'codex',messageCount:0}),/bot/);
 assert.throws(()=>r.begin({botId:'assistant',messageCount:0}),/provider/);
 assert.throws(()=>r.begin({botId:'assistant',provider:'codex',messageCount:-1}),/message count/);
 assert.throws(()=>r.begin({botId:'assistant',provider:'codex',messageCount:1.5}),/message count/);
 assert.equal(r.inFlight(),false);});

test('a first message adopts the id the store mints',()=>{const r=createTurnRegistry(),token=start(r,{conversationId:null});
 assert.equal(r.owns({botId:'assistant',provider:'codex',conversationId:null}),true);
 assert.equal(r.owns(rowA()),false);
 assert.equal(r.adopt(token,'c-a'),true);
 assert.equal(r.owns(rowA()),true);
 assert.equal(r.owns({botId:'assistant',provider:'codex',conversationId:null}),false);
 assert.equal(r.adopt(token+1,'c-z'),false,'a stale token cannot move the turn');
 assert.equal(r.current().conversationId,'c-a');
 assert.equal(r.retitle(token,'Renamed'),true);assert.equal(r.current().title,'Renamed');});

test('the request descriptor carries the turn provider, not the open one',()=>{const r=createTurnRegistry(),token=start(r,{provider:'claude',requestId:'req-9'});
 const request=r.request();
 assert.equal(request.requestId,'req-9');assert.equal(request.provider,'claude');assert.equal(request.token,token);
 assert.equal(request.botId,'assistant');assert.equal(request.conversationId,'c-a');assert.equal(request.cancelRequested,false);
 assert.equal(r.requestCancel(request.token),true);assert.equal(r.request().cancelRequested,true);
 assert.throws(()=>{request.provider='codex';});});

test('stale tokens are ignored everywhere',()=>{const r=createTurnRegistry(),token=start(r),stale=token+7;
 assert.equal(r.observe(stale,{text:'wrong'}),false);
 assert.equal(r.requestCancel(stale),false);
 assert.equal(r.finish(stale),null);
 assert.equal(r.inFlight(),true);assert.equal(r.current().text,'');assert.equal(r.current().cancelRequested,false);});

test('counters read both spellings and cancellation is observed',()=>{const r=createTurnRegistry(),token=start(r);
 assert.equal(r.observe(token,{received_bytes:1200,reasoning_bytes:300}),true);
 assert.equal(r.current().receivedBytes,1200);assert.equal(r.current().reasoningBytes,300);
 r.observe(token,{receivedBytes:2400,reasoningBytes:600});
 assert.equal(r.current().receivedBytes,2400);assert.equal(r.current().reasoningBytes,600);
 r.observe(token,{phase:'Waiting for provider',active:true});
 assert.equal(r.current().phase,'Waiting for provider');
 r.observe(token,{});assert.equal(r.current().receivedBytes,2400,'an empty patch changes nothing');
 r.observe(token,{cancelled:true});assert.equal(r.current().cancelRequested,true);});

test('finish frees the slot once and hands back what it cleared',()=>{const r=createTurnRegistry(),token=start(r);
 r.observe(token,{text:'partial'});
 const done=r.finish(token);
 assert.equal(done.text,'partial');assert.equal(done.conversationId,'c-a');assert.equal(done.messageCount,2);
 assert.equal(r.inFlight(),false);assert.equal(r.current(),null);assert.equal(r.matches(token),false);
 assert.equal(r.finish(token),null,'finishing twice is not an error and does not resurrect');
 assert.equal(r.statusFor(rowA()),null);
 const next=start(r,{conversationId:'c-b'});
 assert.notEqual(next,token);assert.equal(r.owns(rowB()),true);});

test('what the turn was sent with is kept, copied and frozen',()=>{const r=createTurnRegistry();
 const files=[{name:'a.txt',content:'x'}],token=start(r,{files,draft:'unsent words'});
 files.push({name:'b.txt',content:'y'});
 const turn=r.current();
 assert.equal(turn.sent.files.length,1,'the attachment list is copied, not aliased');
 assert.equal(turn.sent.draft,'unsent words');
 assert.equal(turn.sent.userMessage.content,'hello');
 assert.equal(turn.messageCount,2);
 assert.throws(()=>{turn.text='forged';});
 assert.throws(()=>{turn.sent.draft='forged';});
 r.observe(token,{text:'real'});
 assert.equal(turn.text,'','a held snapshot never moves under the caller');
 assert.equal(r.current().text,'real');});

test('identity helpers accept a row or a view',()=>{
 assert.deepEqual(conversationIdentity(rowA()),A);
 assert.deepEqual(conversationIdentity({botId:'assistant',provider:'codex',conversationId:'c-a'}),A);
 assert.deepEqual(conversationIdentity({botId:'assistant',provider:'codex'}),{botId:'assistant',provider:'codex',conversationId:null});
 assert.deepEqual(conversationIdentity(null),{botId:null,provider:null,conversationId:null});
 assert.equal(sameConversation(A,{...A}),true);
 assert.equal(sameConversation(A,{...A,conversationId:'c-b'}),false);
 assert.equal(sameConversation(A,null),false);assert.equal(sameConversation(null,A),false);});

test('the refusal and the hint both name a conversation',()=>{const r=createTurnRegistry();start(r);
 const turn=r.current();
 assert.match(holdingRefusal(turn),/Alpha/);
 assert.match(holdingRefusal(turn,'Renamed live'),/Renamed live/,'a live title overrides the recorded one');
 assert.match(holdingHint(turn,'Renamed live'),/Renamed live/);
 assert.doesNotMatch(holdingHint(turn),/unlock/,'other chats no longer unlock later — they are already open');
 assert.equal(turnLabel(null),'“another conversation”');
 assert.equal(turnLabel({title:''},''),'“another conversation”');});
