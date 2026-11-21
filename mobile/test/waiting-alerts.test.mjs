/* Laws for the alert pass (waiting-alerts.mjs), the sender systemd runs on the PX13. Each runs on temp folders
 * against a fake push service that decrypts what it receives, as the phone would. */
import test from 'node:test';import assert from 'node:assert/strict';
import {join} from 'node:path';import {readFileSync,statSync,writeFileSync,utimesSync,existsSync} from 'node:fs';
import {runPass,gatewayAlerts} from '../waiting-alerts.mjs';
import {pushStore,endpointId} from '../push-store.mjs';
import {NOW,T,chicago,line,board,dirs,putBoard,putConfig,phone,open,readVapid,pushService} from './waiting-fixture.mjs';
const AM='2026-11-21 09:00',PM='2026-11-21 17:00';

const SEND={mode:'send',subject:'https://super.example.ts.net'};
function world(t,{lines=[line('a')],config=SEND,phones=['a'],boardAt=T-60}={}){
  const d=dirs(t);putBoard(d.dir,board(lines,{written_at:boardAt}));if(config)putConfig(d.dir,config);
  const store=pushStore(d.mobileDir,{now:()=>NOW-60_000});store.keys();
  const ps=phones.map(n=>{const p=phone(n);store.add('dev-'+n,p.sub);return p;});
  return {...d,store,phones:ps};
}
const record=dir=>JSON.parse(readFileSync(join(dir,'alerts.json'),'utf8'));
const log=dir=>existsSync(join(dir,'alerts.log'))?readFileSync(join(dir,'alerts.log'),'utf8'):'';

const at=(w,ms,lines)=>putBoard(w.dir,board(lines,{written_at:ms/1000-60}));   // the Mac's board as of then

test('A1 · in the trial, a pass decides and logs the digest as it would send it, and never contacts the push service',async t=>{
  const w=world(t,{config:{}}),s=pushService();
  const r=await runPass({dir:w.dir,mobileDir:w.mobileDir,now:()=>NOW,fetch:s.fetch});
  assert.equal(s.calls.length,0);assert.equal(r.outcome,'shadow');assert.equal(r.slot,AM);assert.deepEqual(r.lines,['a']);
  assert.deepEqual(record(w.dir).slots[AM],{outcome:'shadow',at:T,tries:1,lines:['a']});
  assert.match(log(w.dir),/shadow: digest 09:00 trial, would send: a\n$/);
  const again=await runPass({dir:w.dir,mobileDir:w.mobileDir,now:()=>NOW+600_000,fetch:s.fetch});
  assert.equal(again.outcome,null,'a trial digest counts as done: one per digest time');
});

test('A2 · in send mode, the digest goes to every phone that turned alerts on, and each phone can read it',async t=>{
  const w=world(t,{phones:['a','b'],lines:[line('a',{chat:'+Builder · &body · Garage Cell'}),line('b',{answered_at:T-30})]}),s=pushService(201);
  const r=await runPass({dir:w.dir,mobileDir:w.mobileDir,now:()=>NOW,fetch:s.fetch});
  assert.equal(r.outcome,'sent');assert.deepEqual(r.lines,['a']);assert.equal(r.phones,2);assert.equal(s.calls.length,2);
  for(const [i,p] of w.phones.entries()){
    assert.equal(s.calls[i].url,p.endpoint);
    assert.deepEqual(open(p,s.calls[i].init.body),{title:'Waiting on you',body:'1 line, 1 new — Garage Cell',tag:'super-waiting',url:'/mobile#/attention',count:1});
    const v=readVapid(s.calls[i].init.headers.Authorization);assert.equal(v.signed,true);assert.equal(v.k,w.store.keys().publicKey);
  }
  assert.deepEqual(record(w.dir).lines.a,{key:line('a').key,digest_at:T});
  assert.deepEqual(record(w.dir).slots[AM],{outcome:'sent',at:T,tries:1,lines:['a']});
  assert.match(log(w.dir),/send: digest 09:00 sent to 2 phones: a\n$/);
});

test('A3 · one digest per digest time: later passes send nothing; at 17:00 one digest again, counting only the new line',async t=>{
  const w=world(t,{lines:[line('old',{since:T-9000}),line('new',{since:T-4000})]}),s=pushService();
  const pass=ms=>runPass({dir:w.dir,mobileDir:w.mobileDir,now:()=>ms,fetch:s.fetch});
  assert.deepEqual((await pass(NOW)).lines,['old','new']);
  assert.equal((await pass(NOW+600_000)).outcome,null);
  const pm=chicago(21,17,5);at(w,pm,[line('old',{since:T-9000}),line('new',{since:T-4000}),line('late',{since:T+600})]);
  const r=await pass(pm);assert.equal(r.slot,PM);assert.deepEqual(r.lines,['old','new','late']);
  assert.equal(s.calls.length,2);
  assert.equal(open(w.phones[0],s.calls[1].init.body).body,'3 lines, 1 new — Chat for old; Chat for new; Chat for late');
});

test('A4 · with no phone to alert, the digest is recorded as not delivered, and tried again after 30 minutes',async t=>{
  const w=world(t,{phones:[]}),s=pushService();
  const r=await runPass({dir:w.dir,mobileDir:w.mobileDir,now:()=>NOW,fetch:s.fetch});
  assert.equal(r.outcome,'failed');assert.match(r.problem,/no phone/);assert.equal(record(w.dir).slots[AM].outcome,'failed');
  assert.match(log(w.dir),/digest 09:00 not delivered \(no phone has turned alerts on\): a/);
  assert.equal((await runPass({dir:w.dir,mobileDir:w.mobileDir,now:()=>NOW+20*60_000,fetch:s.fetch})).outcome,null);
  const p=phone('late');w.store.add('dev-late',p.sub);
  at(w,NOW+31*60_000,[line('a')]);                                         // the Mac's next board: the same line
  const again=await runPass({dir:w.dir,mobileDir:w.mobileDir,now:()=>NOW+31*60_000,fetch:s.fetch});
  assert.equal(again.outcome,'sent');assert.equal(record(w.dir).slots[AM].tries,2);
  assert.equal(open(p,s.calls[0].init.body).body,'1 line, 1 new — Chat for a');
});

test('A5 · a phone the push service says has ended is skipped, until it turns alerts on again',async t=>{
  const w=world(t,{lines:[line('a',{since:T-9000})],phones:['gone','live']});
  const s=pushService(url=>url===w.phones[0].endpoint?410:201);
  assert.equal((await runPass({dir:w.dir,mobileDir:w.mobileDir,now:()=>NOW,fetch:s.fetch})).outcome,'sent','the live phone had it');
  assert.equal(record(w.dir).gone[endpointId(w.phones[0].endpoint)],T);
  const pm=chicago(21,17,5);at(w,pm,[line('a',{since:T-9000})]);s.calls.length=0;
  await runPass({dir:w.dir,mobileDir:w.mobileDir,now:()=>pm,fetch:s.fetch});
  assert.deepEqual(s.calls.map(c=>c.url),[w.phones[1].endpoint],'the ended phone is not asked again');
  pushStore(w.mobileDir,{now:()=>pm+60_000}).add('dev-gone',w.phones[0].sub);
  const morning=chicago(22,9,5);at(w,morning,[line('a',{since:T-9000})]);s.calls.length=0;
  await runPass({dir:w.dir,mobileDir:w.mobileDir,now:()=>morning,fetch:s.fetch});
  assert.equal(s.calls.length,2,'turned on again, it is alerted again');
});

test('A6 · two passes at once: the second does nothing; a lock left by a dead pass does not block for long',async t=>{
  const w=world(t),s=pushService();
  writeFileSync(join(w.dir,'alerts.lock'),'999999 0\n',{mode:0o600});
  assert.deepEqual(await runPass({dir:w.dir,mobileDir:w.mobileDir,now:()=>Date.now(),fetch:s.fetch}),{skipped:'another pass is running'},'a lock just made is held (both on the real clock)');
  assert.equal(s.calls.length,0);
  const old=(NOW-300_000)/1000;utimesSync(join(w.dir,'alerts.lock'),old,old);
  const r=await runPass({dir:w.dir,mobileDir:w.mobileDir,now:()=>NOW,fetch:s.fetch});
  assert.equal(r.outcome,'sent');assert.equal(existsSync(join(w.dir,'alerts.lock')),false,'the lock is released');
});

test("A10 · at the switch-over, a digest time the Mac already sent is not sent again by Super",async t=>{
  const w=world(t),s=pushService();
  putBoard(w.dir,board([line('a')],{mac_digests:{[AM]:{at:T-900,lines:['a']}}}));
  const r=await runPass({dir:w.dir,mobileDir:w.mobileDir,now:()=>NOW,fetch:s.fetch});
  assert.equal(r.outcome,null);assert.equal(s.calls.length,0);assert.equal(log(w.dir),'');
  assert.deepEqual(record(w.dir).slots,{},'Super records only its own digests');
});

test('A7 · an old or missing board sends nothing and leaves the record as it was',async t=>{
  const w=world(t,{boardAt:T-3600}),s=pushService();
  const r=await runPass({dir:w.dir,mobileDir:w.mobileDir,now:()=>NOW,fetch:s.fetch});
  assert.equal(r.board,'stale');assert.equal(s.calls.length,0);assert.equal(existsSync(join(w.dir,'alerts.json')),false);
  const {dir,mobileDir}=dirs(t);assert.equal((await runPass({dir,mobileDir,now:()=>NOW,fetch:s.fetch})).board,'none');
  assert.equal((await runPass({dir:join(dir,'never-made'),mobileDir,now:()=>NOW,fetch:s.fetch})).board,'none','no folder yet: nothing to do, no error');
});

test('A8 · the record, the log, the phone list and the push key are private to this user',async t=>{
  const w=world(t);await runPass({dir:w.dir,mobileDir:w.mobileDir,now:()=>NOW,fetch:pushService().fetch});
  for(const f of [join(w.dir,'alerts.json'),join(w.dir,'alerts.log'),join(w.mobileDir,'push-subscriptions.json'),join(w.mobileDir,'push-key.json')])
    assert.equal(statSync(f).mode&0o777,0o600,f);
  assert.doesNotMatch(readFileSync(join(w.dir,'alerts.log'),'utf8'),/The line for|web\.push/,'the log names threads, not their lines or endpoints');
});

test('A9 · a test alert goes only to the phone that asked, and at most one each 30 seconds',async t=>{
  const w=world(t,{phones:['a','b'],config:{subject:'https://super.example.ts.net'}}),s=pushService();let now=NOW;
  const g=gatewayAlerts({dir:w.dir,mobileDir:w.mobileDir,now:()=>now,fetch:s.fetch});
  assert.equal((await g.test(w.phones[1].endpoint)).outcome,'sent');
  assert.deepEqual(s.calls.map(c=>c.url),[w.phones[1].endpoint]);assert.equal(open(w.phones[1],s.calls[0].init.body).tag,'super-waiting-test');
  assert.match((await g.test(w.phones[0].endpoint)).detail,/30 seconds/);now+=31_000;
  assert.equal((await g.test(w.phones[0].endpoint)).outcome,'sent');
  assert.match((await g.test('https://web.push.apple.com/unknown')).detail,/not turned alerts on/);
  assert.equal(s.calls.length,2);
  assert.equal(g.info().mode,'shadow','test alerts work during the trial');
});
