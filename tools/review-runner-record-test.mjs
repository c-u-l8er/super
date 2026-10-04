import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {StringDecoder} from 'node:string_decoder';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {transcriptKeeper,failureIndex,judgeRun,stageOutcome,compiledVerdict,profilePlan,composeParts,fitOutcome,OUTCOME_MAX,stageWrapper} from './lib/proposal-test-runner.mjs';
import {runFailures} from '../cockpit/ui/review-test-panel.js';

// T43 (A-32; superlane/t43/TASK.md): a review run's record names its first failures, keeps a timed-out stage's
// transcript, and counts omitted bytes as they arrived. One law per change, each with a planted bug that only it catches
// (superlane/t43/plants.py). F3 is a Rust test in cockpit/src/review_tests.rs; F4 runs in the real sandbox
// (tools/proposal-test-runner-spec.mjs), as T36's sandbox laws did. Round 2 (Codex review 1): F7, the record always fits
// what the cockpit reads (its cockpit half is a Rust test too), and F8, a stage's transcript is printed once.

const JS='super-javascript-behavior@1',RUST='super-rust-review@1',ELIXIR='super-elixir-review@1';

test('F1 · the failure index comes from every line, kept or omitted, in order, with its stage, at most 16',()=>{
  const keeper=transcriptKeeper(undefined,'ampd'),noise=Buffer.from(('x'.repeat(99)+'\n').repeat(655));let total=0;
  const push=text=>{const b=Buffer.from(text);keeper.push(b);total+=b.length;};
  push('Compiling 77 files (.ex)\n');while(total<7*1024*1024){keeper.push(noise);total+=noise.length;}
  const lines=['  1) test a session reopens after a restart (Ampd.SessionTest)','test host::tests::planted ... FAILED','not ok 3 - the card shows the reviewed bytes','  2) test describe block keeps (its) parentheses (Ampd.ReviewTest)'];
  push('\n'+lines[0]+'\r\n     ** (MatchError) no match\n');push(lines[1].slice(0,9));push(lines[1].slice(9)+'\n');push('test host::tests::fine ... ok\n'+lines[2]+'\n  1) doctest Ampd.x/1 (1) (Ampd.DocTest)\n'+lines[3]+'\n');
  while(total<15*1024*1024){keeper.push(noise);total+=noise.length;}
  push('1133 tests, 2 failures\n');
  const kept=keeper.finish();
  for(const l of lines)assert.ok(!kept.output.includes(l),'the line is in the omitted middle: '+l);
  assert.deepEqual(kept.failures,lines.map(line=>({stage:'ampd',line})),'exactly the four, in order, with their stage');
  assert.equal(kept.failures_overflowed,false);
  const many=transcriptKeeper(1024,'host');for(let i=1;i<=17;i++)many.push(Buffer.from(`test t${i} ... FAILED\n`));
  const flooded=many.finish();assert.equal(flooded.failures.length,16);assert.equal(flooded.failures[15].line,'test t16 ... FAILED');assert.equal(flooded.failures_overflowed,true,'a 17th match overflows');
  const long=transcriptKeeper(1024,'node');long.push(Buffer.from('not ok 1 - '+'é'.repeat(700)+'\n'));
  assert.equal(Array.from(long.finish().failures[0].line).length,512,'a line is cut to 512 characters');
  const host=transcriptKeeper(1024,'host'),ampd=transcriptKeeper(1024,'ampd');
  host.push(Buffer.from('test a ... FAILED\n'));for(let i=0;i<16;i++)ampd.push(Buffer.from(`  ${i+1}) test b${i} (M)\n`));
  const merged=failureIndex([host.finish(),{failures:[]},ampd.finish()]);
  assert.deepEqual(merged.failures.slice(0,2),[{stage:'host',line:'test a ... FAILED'},{stage:'ampd',line:'  1) test b0 (M)'}],'stages in order');
  assert.equal(merged.failures.length,16);assert.equal(merged.failures_overflowed,true,'one run keeps at most 16 across its stages');
});

test('F2 · the index never changes a verdict: exit status alone decides',()=>{
  const noted=[{stage:'node',line:'not ok 1 - printed by a passing suite'}];
  assert.deepEqual(judgeRun(JS,{code:0,signals:['# tests 2','# fail 0'],failures:noted}),{state:'completed',verdict:'pass'},'exit 0 with not ok lines passes');
  assert.deepEqual(judgeRun(JS,{code:1,signals:['# tests 2','# fail 1'],failures:[]}),{state:'completed',verdict:'fail'},'exit 1 with no matched line fails');
  assert.deepEqual(judgeRun(JS,{code:0,signals:['# tests 2'],failures:noted}),{state:'failed',reason:'runner-did-not-complete'},'an incomplete transcript stays incomplete');
  assert.deepEqual(judgeRun(RUST,{state:'completed',verdict:'pass',failures:[{stage:'host',line:'test x ... FAILED'}]}),{state:'completed',verdict:'pass'});
  assert.deepEqual(judgeRun(ELIXIR,{state:'completed',verdict:'fail',failures:[]}),{state:'completed',verdict:'fail'});
  assert.deepEqual(judgeRun(ELIXIR,{state:'failed',timedOut:true,failures:noted}),{state:'failed',reason:'timeout'});
  const ampd=profilePlan(ELIXIR).stages.find(s=>s.name==='ampd');
  assert.equal(stageOutcome(ampd,{code:0,signal:null,timedOut:false,launchError:null,failures:noted}),'pass');
  assert.deepEqual(compiledVerdict(['built','pass']),{state:'completed',verdict:'pass'});
});

// T36's keeper, verbatim from cd3bcbc (tools/lib/proposal-test-runner.mjs:86-116), as the reference for valid UTF-8.
const referenceKeeper=(()=>{const maxOutput=128*1024;
const SIGNAL=/^(?:# gates? |# tests \d|# fail \d)/,maxSignals=4096,maxLine=4096;
// Cut a kept piece at whole UTF-8 characters: a head never ends inside a character, a tail never starts inside one.
const wholeHead=b=>{let e=b.length;for(let i=b.length-1,n=0;i>=0&&n<4;i--,n++){const c=b[i];if((c&0xc0)===0x80)continue;const need=c>=0xf0?4:c>=0xe0?3:c>=0xc0?2:1;e=i+need<=b.length?b.length:i;break;}return b.subarray(0,e);};
const wholeTail=b=>{let s=0;while(s<b.length&&s<4&&(b[s]&0xc0)===0x80)s++;return b.subarray(s);};
function transcriptKeeper(limit=maxOutput){
  const half=Math.floor(limit/2),head=[],tail=[],signals=[],streams=new Map();
  let headBytes=0,tailBytes=0,total=0,headClosed=false,overflowed=false;
  const line=l=>{l=l.replace(/\r$/,'');if(l.length>maxLine||!SIGNAL.test(l))return;if(signals.length<maxSignals)signals.push(l);else overflowed=true;};
  // What is kept is decoded per stream first, so every kept piece is whole characters of one stream: no character is
  // split between stdout and stderr, nor at a cut, and the omitted count is exactly what was not kept.
  const keep=text=>{
    if(!text)return;const b=Buffer.from(text,'utf8');total+=b.length;let rest=b;
    if(!headClosed){const piece=wholeHead(b.subarray(0,Math.min(half-headBytes,b.length)));if(piece.length){head.push(piece);headBytes+=piece.length;}rest=b.subarray(piece.length);if(rest.length)headClosed=true;}
    if(rest.length){tail.push(rest);tailBytes+=rest.length;while(tail.length>1&&tailBytes-tail[0].length>=half){tailBytes-=tail[0].length;tail.shift();}}
  };
  const stream=name=>{
    if(!streams.has(name)){const decoder=new StringDecoder('utf8');let carry='',discarding=false;
      const scan=text=>{const parts=(carry+text).split('\n');carry=parts.pop();for(const l of parts){if(discarding){discarding=false;continue;}line(l);}if(carry.length>maxLine){carry='';discarding=true;}};
      streams.set(name,{take(b){const text=decoder.write(b);keep(text);scan(text);},end(){const text=decoder.end();keep(text);scan(text);if(!discarding&&carry)line(carry);carry='';}});}
    return streams.get(name);
  };
  return {
    push(b,name='stdout'){stream(name).take(b);},
    finish(){
      for(const s of streams.values())s.end();
      const keptHead=Buffer.concat(head);let keptTail=Buffer.concat(tail);if(keptTail.length>half)keptTail=wholeTail(keptTail.subarray(keptTail.length-half));
      const omitted=total-keptHead.length-keptTail.length;
      return {output:keptHead.toString('utf8')+(omitted?`\n[… ${omitted} bytes omitted …]\n`:'')+keptTail.toString('utf8'),omitted_bytes:omitted,signals,signals_overflowed:overflowed};
    }
  };
}
return transcriptKeeper;})();

test('F5 · omitted bytes count what the streams delivered; valid UTF-8 keeps exactly what T36 kept',()=>{
  const ff=transcriptKeeper(2);ff.push(Buffer.from([0xff,0xff]));const r=ff.finish();
  const keptBytes=(r.output.match(/�/g)??[]).length;
  assert.equal(r.omitted_bytes,2-keptBytes,'two ff bytes, limit 2: what was delivered and not kept (T36 reported 6)');
  assert.ok(r.omitted_bytes<=2);
  const mixed=transcriptKeeper(8);mixed.push(Buffer.from([0x61,0xff,0x62,0xc3]),'stdout');mixed.push(Buffer.from('0123456789'),'stderr');mixed.push(Buffer.from([0xa9,0xfe]),'stdout');
  const m=mixed.finish(),[h,t]=m.output.split(/\n\[… \d+ bytes omitted …\]\n/);
  const raw=s=>Array.from(s).reduce((n,c)=>n+(c==='�'?1:Buffer.byteLength(c)),0);
  assert.equal(m.omitted_bytes,16-raw(h)-raw(t??''),'invalid bytes count once each, kept or not');
  // Valid UTF-8: every case gives the reference's output, omitted count and signals.
  let seed=43;const rnd=n=>{seed=(seed*1103515245+12345)%2147483648;return seed%n;};
  const alphabet=['a','b','\n','é','ß','€','✓','𝄞','😀','# tests 1\n','# fail 0\n'];let cases=0;
  for(const limit of [2,3,4,5,6,7,8,9,12,16,24,32,64]){
    for(let s=0;s<17;s++){
      const text=Array.from({length:1+rnd(14)},()=>alphabet[rnd(alphabet.length)]).join(''),bytes=Buffer.from(text);
      const ends=[];{let o=0;for(const ch of text){o+=Buffer.byteLength(ch);ends.push(o);}}
      for(let c=0;c<5;c++){
        const ours=transcriptKeeper(limit),theirs=referenceKeeper(limit);let at=0;
        // One stream: chunks cut at any byte. Two streams: cut only at a character's end, so each stream stays valid.
        while(at<bytes.length){
          const near=ends.filter(e=>e>at&&e<=at+6),end=c%2?(near.length?near[rnd(near.length)]:ends.find(e=>e>at)):at+1+rnd(Math.min(6,bytes.length-at));
          const piece=bytes.subarray(at,end),name=c%2&&rnd(2)?'stderr':'stdout';ours.push(piece,name);theirs.push(piece,name);at=end;
        }
        const a=ours.finish(),b=theirs.finish();
        assert.deepEqual([a.output,a.omitted_bytes,a.signals,a.signals_overflowed],[b.output,b.omitted_bytes,b.signals,b.signals_overflowed],`limit ${limit} text ${JSON.stringify(text)} chunking ${c}`);
        cases++;
      }
    }
  }
  assert.equal(cases,13*17*5);
});

test('F6 · the panel shows up to 3 failures, how many more, and that the verdict comes from the exit status',()=>{
  const five=Array.from({length:5},(_,i)=>({stage:i<1?'host':'cockpit',line:`test t${i} ... FAILED`}));
  const shown=runFailures({failures:five,failures_overflowed:false});
  assert.deepEqual(shown.lines,['host: test t0 ... FAILED','cockpit: test t1 ... FAILED','cockpit: test t2 ... FAILED']);
  assert.equal(shown.more,'and 2 more');
  assert.match(shown.note,/exit status/);
  assert.match(runFailures({failures:Array.from({length:16},(_,i)=>({stage:'ampd',line:`  ${i+1}) test x (M)`})),failures_overflowed:true}).more,/^and 13 more \(the record keeps 16; the run printed further failures\)$/);
  assert.equal(runFailures({failures:[{stage:'node',line:'not ok 1 - x'}]}).more,null);
  for(const none of [{failures:[]},{},null,{failures:'forged'}])assert.equal(runFailures(none),null);
  const panel=readFileSync(new URL('../cockpit/ui/review-test-panel.js',import.meta.url),'utf8');
  const at=panel.indexOf('const failed=runFailures(result);'),details=panel.indexOf("const output=node('details')");
  assert.ok(at>0&&at<details,'the panel reads the index before it shows the transcript');
  for(const use of ['for(const line of failed.lines)box.append(','if(failed.more)box.append(','box.append(node(\'p\',failed.note,'])assert.ok(panel.slice(at,details).includes(use),use);
});

const recordBytes=r=>Buffer.byteLength(JSON.stringify(r,null,2)+'\n');
test('F7 · the outcome record always fits what the cockpit reads, with exact counts; within the bound it is written as before',()=>{
  const rs=readFileSync(new URL('../cockpit/src/review_tests.rs',import.meta.url),'utf8');
  assert.match(rs,/\.len\(\) > 256 \* 1024/,'the cockpit reads at most 256 KiB');
  assert.ok(OUTCOME_MAX+16*1024<=256*1024,'the runner\'s bound leaves room for the run record the cockpit saves around it');
  // Two stages of 256 KiB of ff bytes and 17 failure lines of control characters each, for a candidate and its baseline.
  const lines=Array.from({length:17},(_,i)=>'not ok '+(i+1)+' - '+'\x01'.repeat(600)+'\n').join('');
  const stage=name=>{const k=transcriptKeeper(64*1024,name);for(let i=0;i<64;i++)k.push(Buffer.alloc(4096,0xff));k.push(Buffer.from(lines));return k.finish();};
  const run=()=>{const s=[stage('host-build'),stage('ampd')];return {parts:s.map((r,i)=>({prefix:`[runner] stage ${i}\n`,kept:r.kept})),...failureIndex(s)};};
  const c=run(),b=run();
  for(const f of c.failures)assert.ok(Buffer.byteLength(JSON.stringify(f.line))-2<=1024&&f.line.startsWith('not ok'),'a failure line is at most 1,024 bytes as JSON');
  const record={schema:'local-proposal-test@1',state:'completed',verdict:'fail',...composeParts(c.parts),failures:c.failures,failures_overflowed:c.failures_overflowed,stages:[{name:'host-build'},{name:'ampd'}],
    baseline:{state:'completed',verdict:'pass',...composeParts(b.parts)}};
  assert.ok(recordBytes(record)>OUTCOME_MAX,'as kept, the record would be refused: '+recordBytes(record));
  const counts=out=>out.split(/\n?\[runner\] stage \d\n/).slice(1).map(text=>{const m=text.match(/\n\[… (\d+) bytes omitted …\]\n/);return {omitted:m?Number(m[1]):0,kept:Array.from(text.replace(/\n\[… \d+ bytes omitted …\]\n/,'')).length};});
  const beforeC=counts(record.output),beforeB=counts(record.baseline.output);
  const index=JSON.stringify([record.failures,record.failures_overflowed]);
  fitOutcome(record,[{target:record.baseline,parts:b.parts},{target:record,parts:c.parts}]);
  assert.ok(recordBytes(record)<=OUTCOME_MAX,'fitted: '+recordBytes(record));
  assert.equal(record.transcripts_fitted,true);assert.deepEqual([record.state,record.verdict,record.baseline.verdict],['completed','fail','pass']);
  assert.equal(JSON.stringify([record.failures,record.failures_overflowed]),index,'the index never changes');
  // Fitting moves bytes from kept to omitted, exactly: per part, kept + omitted is what it was before fitting (each ff
  // decodes to one U+FFFD, every other character here is one byte). That it is what was delivered is F5's law.
  for(const [t,before] of [[record,beforeC],[record.baseline,beforeB]]){
    const now=counts(t.output);assert.deepEqual(now.map(x=>x.kept+x.omitted),before.map(x=>x.kept+x.omitted),'kept + omitted unchanged by fitting');
    assert.ok(now.every((x,i)=>x.kept<=before[i].kept));assert.equal(t.omitted_bytes,now.reduce((n,x)=>n+x.omitted,0));
  }
  assert.ok(record.baseline.output.length<record.output.length,'the baseline is fitted first');
  const k=transcriptKeeper();k.push(Buffer.from('ok\n'));const small={state:'completed',verdict:'pass',...composeParts([{prefix:'',kept:k.finish().kept}]),failures:[]},as=JSON.stringify(small);
  fitOutcome(small,[{target:small,parts:[{prefix:'',kept:null}]}]);assert.equal(JSON.stringify(small),as,'a record within the bound is untouched');
});

// F8 runs the wrapper's own text (stageWrapper, as stageScript builds it) under /usr/bin/sh with paths of its own and a
// 50 ms poll. When the wrapper's shell ends, its process group is killed, as the sandbox's PID namespace is torn down.
async function wrapped(t,body,{stopAt=null,lockHeld=false}={}){
  const d=await mkdtemp(join(tmpdir(),'t43-f8-'));t.after(()=>rm(d,{recursive:true,force:true}));
  if(lockHeld)await mkdir(join(d,'lock'));
  const script=stageWrapper({prepare:'true',script:body,log:join(d,'log'),stop:join(d,'stop'),lock:join(d,'lock'),poll:0.05});
  return new Promise(done=>{
    const started=Date.now(),child=spawn('/usr/bin/sh',['-c',script],{detached:true,stdio:['ignore','pipe','pipe'],env:{PATH:'/usr/bin:/bin'}});let out='';
    child.stdout.on('data',b=>out+=b);child.stderr.on('data',b=>out+=b);
    const timer=stopAt===null?null:setTimeout(()=>writeFile(join(d,'stop'),''),stopAt);
    child.on('exit',()=>{try{process.kill(-child.pid,'SIGKILL');}catch{}});
    child.on('close',(code,signal)=>{clearTimeout(timer);done({code,signal,out,ms:Date.now()-started});});
  });
}
test('F8 · a stage\'s transcript is printed once, whichever of the stop request and the normal end comes first',async t=>{
  const stopped=await wrapped(t,'echo one; echo two; sleep 5',{stopAt:300});
  assert.equal(stopped.out,'one\ntwo\n','a stop while the stage runs: the watcher prints it once');assert.equal(stopped.signal,'SIGKILL');assert.ok(stopped.ms<2500,stopped.ms+' ms');
  const ended=await wrapped(t,'echo one; exit 3');
  assert.equal(ended.out,'one\n','a normal end prints it once');assert.equal(ended.code,3,'and keeps the stage\'s exit status');
  const mainLoses=await wrapped(t,'echo one; exit 3',{stopAt:300,lockHeld:true});
  assert.equal(mainLoses.out,'','a normal end that finds the lock taken prints nothing');
  const watcherLoses=await wrapped(t,'echo one; sleep 0.6',{stopAt:100,lockHeld:true});
  assert.equal(watcherLoses.out,'','a watcher that finds the lock taken prints nothing');
  for(const ms of [40,80,120,160,200,240]){const r=await wrapped(t,'echo one; sleep 0.15',{stopAt:ms});assert.equal(r.out,'one\n',`stop at ${ms} ms near the end: printed once`);}
});
