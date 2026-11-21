/* Laws for the board as Super's own source (waiting.mjs): reading and checking it, and the digest rule (rule 9). */
import test from 'node:test';import assert from 'node:assert/strict';
import {join} from 'node:path';import {symlinkSync,writeFileSync} from 'node:fs';
import {readFeed,decide,loadConfig,digestMessage,DEFAULTS} from '../waiting.mjs';
import {NOW,T,chicago,line,board,dirs,putBoard,putConfig,key} from './waiting-fixture.mjs';

const read=(t,b,{mode,now=NOW}={})=>{const {dir}=dirs(t);putBoard(dir,b,mode);return readFeed(join(dir,'feed.json'),now);};
const states=(feed,state={},now=NOW,cfg={})=>{const r=decide(feed,state,now,cfg);return Object.fromEntries(Object.entries(r.notes).map(([k,v])=>[k,v.state]));};
const dueNow=(feed,state={},now=NOW,cfg={})=>decide(feed,state,now,cfg).digest?.lines.map(l=>l.thread)??[];
const AM='2026-11-21 09:00',PM='2026-11-21 17:00';

test('W1 · a good board reads, oldest line first, with its age',t=>{
  const f=read(t,board([line('b',{since:T-600}),line('a',{since:T-7200}),line('c',{since:T-3600})]));
  assert.equal(f.available,true);assert.equal(f.stale,false);assert.equal(f.age_seconds,60);
  assert.deepEqual(f.lines.map(l=>l.thread),['a','c','b']);
});

test('W2 · a board open to other users, a link, or a file too large is refused',t=>{
  assert.match(read(t,board([line('a')]),{mode:0o644}).reason,/open to other users/);
  assert.match(read(t,board([line('a')]),{mode:0o620}).reason,/open to other users/);
  const {dir}=dirs(t),real=join(dir,'real.json');putBoard(dir,board([]));writeFileSync(real,'{}',{mode:0o600});
  const {dir:d2}=dirs(t);symlinkSync(real,join(d2,'feed.json'));
  assert.match(readFeed(join(d2,'feed.json'),NOW).reason,/not a plain file/);
  assert.match(read(t,JSON.stringify(board([line('a',{line:'x'.repeat(300)})]))+' '.repeat(70000)).reason,/too large/);
  const {dir:d3}=dirs(t);assert.equal(readFeed(join(d3,'feed.json'),NOW).reason,'No board has come from the Mac yet.');
});

test('W3 · a board with a wrong schema, unknown fields, a bad line or a repeated thread is refused',t=>{
  const refused=[
    board([line('a')],{schema:'super-waiting@2'}),board([line('a')],{extra:1}),board([{...line('a'),extra:1}]),
    board([line('a',{thread:'Bad Name'})]),board([line('a',{key:'xyz'})]),board([line('a',{since:'yesterday'})]),
    board([line('a',{line:'two\nlines'})]),board([line('a',{line:''})]),board([line('a',{chat:null})]),
    board([line('a',{chat_id:'../etc'})]),board([line('a',{busy:'no'})]),board([line('a'),line('a')]),
    board([line('a',{since:T+3600})]),board(Array.from({length:65},(_,i)=>line('t'+i))),'not json',
    board([line('a')],{mac_digests:{yesterday:{at:T,lines:['a']}}}),board([line('a')],{mac_digests:{[AM]:{at:T,lines:['Bad Name']}}}),board([line('a')],{mac_digests:{[AM]:{at:T,lines:['a'],note:'x'}}}),
  ];
  for(const b of refused){const f=read(t,b);assert.equal(f.available,false,JSON.stringify(b).slice(0,120));assert.ok(f.reason);}
  // No open chat is a fact the board may state: both the name and the id are then null.
  assert.equal(read(t,board([line('a',{chat:null,chat_id:null})])).available,true);
  assert.equal(read(t,board([line('a')],{mac_digests:{[AM]:{at:T-900,lines:['a']}}})).available,true,"the Mac's digests may be stated");
});

test('W4 · a board dated in the future is refused; an old board is shown as old, never as now',t=>{
  assert.match(read(t,board([line('a')],{written_at:T+600})).reason,/future/);
  assert.equal(read(t,board([line('a')],{written_at:T+120})).available,true,'a couple of minutes of clock drift is allowed');
  const old=read(t,board([line('a')],{written_at:T-26*60}));
  assert.equal(old.available,true);assert.equal(old.stale,true);assert.equal(old.age_seconds,26*60);
  assert.equal(read(t,board([line('a')],{written_at:T-24*60})).stale,false);
});

test('W5 · a line joins the digest once it has waited 30 minutes, not before',t=>{
  const f=read(t,board([line('a',{since:T-29*60}),line('b',{since:T-30*60})]));
  const r=decide(f,{},NOW,{});
  assert.equal(r.digest.slot,AM);assert.deepEqual(r.digest.lines.map(l=>l.thread),['b']);
  assert.deepEqual(r.notes.a,{state:'later',at:T-29*60+1800});assert.deepEqual(r.notes.b,{state:'due',slot:AM});
});

test('W6 · digests at 09:00 and 17:00 on the configured clock; a missed one is made up later in its window; none from 22:00 to 07:00',t=>{
  const f=now=>{const {dir}=dirs(t);putBoard(dir,board([line('a',{since:now/1000-7200})],{written_at:now/1000-60}));return readFeed(join(dir,'feed.json'),now);};
  const slotAt=(now,cfg={})=>decide(f(now),{},now,cfg).digest?.slot??null;
  for(const [now,want] of [[chicago(21,8,59),null],[chicago(21,9,0),AM],[chicago(21,16,59),AM],[chicago(21,17,0),PM],
    [chicago(21,21,59),PM],[chicago(21,22,0),null],[chicago(22,0,10),null],[chicago(22,6,59),null],[chicago(22,7,0),null],[chicago(22,9,0),'2026-11-22 09:00']])
    assert.equal(slotAt(now),want,new Date(now).toISOString());
  assert.deepEqual(decide(f(chicago(21,8,30)),{},chicago(21,8,30),{}).notes.a,{state:'next',at:chicago(21,9)/1000});
  assert.deepEqual(decide(f(chicago(21,23,0)),{},chicago(21,23,0),{}).notes.a,{state:'quiet',at:chicago(22,9)/1000},'held for the morning digest');
  assert.equal(decide(f(chicago(22,7,30)),{},chicago(22,7,30),{}).notes.a.state,'next','last evening\'s window does not carry past the quiet hours');
  // The clock is the configured one, not the machine's: 23:00 in Chicago is 21:00 in Los Angeles, inside its 17:00 window.
  assert.equal(slotAt(chicago(21,23,0),{time_zone:'America/Los_Angeles'}),PM);
  assert.equal(slotAt(chicago(21,12,0),{digest_times:['12:00']}),'2026-11-21 12:00');
});

test('W7 · at most one digest per digest time: a sent or trial digest is not sent again; a line that joins later waits for the next',t=>{
  const f=read(t,board([line('a',{since:T-7200}),line('b',{since:T-3600})]));
  const done=outcome=>({lines:{},slots:{[AM]:{outcome,at:T-600,tries:1,lines:['a']}}});
  for(const [outcome,by] of [['sent','super'],['shadow','trial']]){
    const r=decide(f,done(outcome),NOW,{});
    assert.equal(r.digest,null,outcome);
    assert.deepEqual(r.notes.a,{state:'in',slot:AM,at:T-600,by});
    assert.deepEqual(r.notes.b,{state:'next',at:chicago(21,17)/1000});
  }
  // At 17:00 both go again, in the new digest.
  const pm=chicago(21,17,5),{dir}=dirs(t);putBoard(dir,board([line('a',{since:T-7200}),line('b',{since:T-3600})],{written_at:pm/1000-60}));
  assert.deepEqual(dueNow(readFeed(join(dir,'feed.json'),pm),done('sent'),pm),['a','b']);
});

test('W8 · left out of the digest: a busy chat, a line he has typed after, a line with no open chat',t=>{
  const f=read(t,board([line('busy',{busy:true}),line('answered',{answered_at:T-600}),line('before',{answered_at:T-7200}),line('nochat',{chat:null,chat_id:null})]));
  assert.deepEqual(states(f),{busy:'busy',answered:'answered',before:'due',nochat:'no-chat'});
  assert.deepEqual(dueNow(f),['before'],'a line he typed BEFORE does not count as answered');
});

test("W9 · the switch-over: a digest time the Mac already sent is not sent again, and lines the Mac told him of are not new",t=>{
  const f=read(t,board([line('a',{since:T-7200}),line('b',{since:T-3600})],{mac_digests:{[AM]:{at:T-900,lines:['a']}}}));
  const r=decide(f,{},NOW,{});
  assert.equal(r.digest,null);assert.deepEqual(r.notes.a,{state:'in',slot:AM,at:T-900,by:'mac'});assert.equal(r.notes.b.state,'next');
  const g=read(t,board([line('a',{mac_notice_at:T-90000}),line('b')]));
  const d=decide(g,{},NOW,{}).digest;assert.deepEqual(d.lines.map(l=>l.thread),['a','b']);assert.equal(d.new,1);
});

test('W10 · a digest that was not delivered is tried again after 30 minutes, not before',t=>{
  const f=read(t,board([line('a')]));
  const failed=at=>({lines:{},slots:{[AM]:{outcome:'failed',at,tries:1,lines:['a']}}});
  assert.deepEqual(dueNow(f,failed(T-29*60)),[]);
  assert.deepEqual(decide(f,failed(T-29*60),NOW,{}).notes.a,{state:'retry',slot:AM,at:T-29*60,again:T-29*60+1800});
  assert.deepEqual(dueNow(f,failed(T-30*60)),['a']);
});

test('W11 · one digest names every waiting line, oldest first, and counts the new ones; a changed Status is new again',t=>{
  const f=read(t,board([line('new',{since:T-2000}),line('old',{since:T-90000}),line('mid',{since:T-5000})]));
  const told={lines:{old:{key:key('old'),digest_at:T-40000},mid:{key:key('mid'),digest_at:T-40000}},slots:{}};
  const r=decide(f,told,NOW,{});
  assert.deepEqual(r.digest.lines.map(l=>l.thread),['old','mid','new']);assert.equal(r.digest.new,1);
  const changed=read(t,board([line('old',{since:T-90000,status:'a new line'})]));
  const c=decide(changed,told,NOW,{});assert.equal(c.digest.new,1);assert.deepEqual(c.next.lines.old,{key:key('olda new line'),digest_at:null});
});

test('W12 · an old board sends nothing and changes no record; a fresh board drops lines that stopped waiting',t=>{
  const old=read(t,board([line('a')],{written_at:T-3600}));
  const kept={lines:{gone:{key:'aaaaaaaaaaaa',digest_at:T-9000}},slots:{'2026-11-20 17:00':{outcome:'sent',at:T-60000,tries:1,lines:['gone']}}};
  const r=decide(old,kept,NOW,{});
  assert.equal(r.digest,null);assert.equal(r.notes.a.state,'stale');assert.equal(r.next,kept);
  const fresh=decide(read(t,board([line('a')])),kept,NOW,{});
  assert.deepEqual(Object.keys(fresh.next.lines),['a'],'the thread that left the board leaves the record');
  assert.deepEqual(fresh.next.slots,kept.slots,'the digest times already done stay done');
});

test('W13 · settings: unknown or bad settings are refused whole; none means the defaults (trial mode)',t=>{
  const {dir}=dirs(t);assert.deepEqual(loadConfig(dir),{...DEFAULTS});assert.equal(loadConfig(dir).mode,'shadow');
  for(const bad of [{loud:true},{quiet_from:22},{mode:'yes'},{quiet_from_hour:25},{alert_after_minutes:-1},{time_zone:'Mars/Olympus'},{push_hosts:[]},
    {digest_times:[]},{digest_times:'09:00'},{digest_times:['9:00']},{digest_times:['24:00']},{digest_times:['09:00','09:00']},{digest_times:['01:00','02:00','03:00','04:00','05:00','06:00','07:00']}]){
    putConfig(dir,bad);assert.throws(()=>loadConfig(dir),undefined,JSON.stringify(bad));}
  putConfig(dir,{quiet_from:22});assert.throws(()=>loadConfig(dir),/unknown setting: quiet_from/,'a misspelt setting is refused, never quietly ignored');
  putConfig(dir,{mode:'send',subject:'https://super.example.ts.net',digest_times:['17:00','08:30']});
  assert.equal(loadConfig(dir).mode,'send');assert.deepEqual(loadConfig(dir).digest_times,['17:00','08:30']);
});

test("W14 · the digest says rule 9's words: how many lines, how many new, the quest names, at most 200 characters",()=>{
  const d=(names,n)=>({slot:AM,new:n,lines:names.map((c,i)=>line('t'+i,{chat:c}))});
  const m=digestMessage(d(['+Builder · &body · Garage Cell','**Coordinator** · every quest · The Atlas','Chat for c'],1),5);
  assert.deepEqual(m,{title:'Waiting on you',body:'3 lines, 1 new — Garage Cell; The Atlas; Chat for c',tag:'super-waiting',url:'/mobile#/attention',count:5});
  assert.equal(digestMessage(d(['A · One'],0),1).body,'1 line, 0 new — One');
  const long=digestMessage(d(Array.from({length:30},(_,i)=>`Role · Direction · A quest named number ${i}`),30),30);
  assert.ok(long.body.length<=200,long.body);assert.match(long.body,/^30 lines, 30 new — A quest named number 0; .*; and \d+ more$/);
  assert.equal(digestMessage({slot:AM,new:1,lines:[line('nochat',{chat:null,chat_id:null})]},1).body,'1 line, 1 new — nochat');
});
