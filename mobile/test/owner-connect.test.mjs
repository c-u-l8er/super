/* Laws for connecting his phone without a code: the gateway's /api/pair-owner (server.mjs), the private HTTPS front
 * that adds the key (private-connector.mjs), the key file the gateway writes at start, and the phone page (ui/app.js
 * in the T31 phone, phone.mjs). At the private address his Tailscale login already shows the phone is his. */
import test from 'node:test';import assert from 'node:assert/strict';import http from 'node:http';
import {chmodSync,mkdirSync,mkdtempSync,readFileSync,rmSync,statSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';import {join} from 'node:path';import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {createGateway} from '../server.mjs';
import {createConnector} from '../private-connector.mjs';
import {CODE,openPhone} from './phone.mjs';

const ORIGIN='http://127.0.0.1:4318',KEY='a1'.repeat(32),OTHER='b2'.repeat(32);
const FRONT='https://super-mobile.example.ts.net',OWNER='owner@example.com';
const WORLD=async()=>({available:true,projection:{development_tasks:{}}});
const temp=t=>{const d=mkdtempSync(join(tmpdir(),'super-owner-'));t.after(()=>rmSync(d,{recursive:true,force:true}));return d;};
const delay=ms=>new Promise(r=>setTimeout(r,ms));
const freePort=async()=>{const s=http.createServer();await new Promise(r=>s.listen(0,'127.0.0.1',r));const {port}=s.address();await new Promise(r=>s.close(r));return port;};
const listen=async(t,server,port=0)=>{await new Promise(r=>server.listen(port,'127.0.0.1',r));t.after(()=>{server.closeAllConnections?.();server.close();});return server.address().port;};
/** One request to 127.0.0.1:port, as `host`; resolves with status, headers and the parsed body. */
const call=(port,host,origin,path,{method='GET',login,headers={},body}={})=>new Promise((resolve,reject)=>{
  const req=http.request({host:'127.0.0.1',port,path,method,headers:{Host:host,Origin:origin,...(login?{'Tailscale-User-Login':login}:{}),...(body!==undefined?{'Content-Type':'application/json'}:{}),...headers}},
    res=>{const c=[];res.on('data',x=>c.push(x));res.on('end',()=>{let json=null;try{json=JSON.parse(Buffer.concat(c));}catch{}resolve({status:res.statusCode,headers:res.headers,json});});});
  req.on('error',reject);req.end(body===undefined?undefined:typeof body==='string'?body:JSON.stringify(body));});
const cookieOf=r=>r.headers['set-cookie']?.[0]?.split(';')[0];

async function gateway(t,{ownerKey=KEY}={}){
  const time={now:1_800_000_000_000};
  const server=createGateway({origin:ORIGIN,pairingCode:CODE,ownerKey,now:()=>time.now,snapshot:WORLD});
  const port=await listen(t,server);
  const request=(path,{cookie,headers={},...options}={})=>call(port,'127.0.0.1:4318',ORIGIN,path,{...options,headers:{...(cookie?{Cookie:cookie}:{}),...headers}});
  const owner=(key=KEY)=>request('/api/pair-owner',{method:'POST',body:{},headers:key===null?{}:{'x-super-owner-key':key}});
  return {request,owner,time};
}
const keyFile=(t,{key=KEY,mode=0o600,schema='super-mobile-front-key@1'}={})=>{const f=join(temp(t),'front-key.json');writeFileSync(f,JSON.stringify({schema,key}),{mode});chmodSync(f,mode);return f;};
async function front(t,{ownerKeyFile,origin=FRONT}={}){
  const seen=[];
  const observer=http.createServer((req,res)=>{seen.push({line:req.method+' '+req.url,key:req.headers['x-super-owner-key']??null});res.writeHead(200,{'Content-Type':'application/json','Set-Cookie':'super_mobile=x; HttpOnly'});res.end('{}');});
  const observerPort=await listen(t,observer);
  const connector=createConnector({origin,observerOrigin:`http://127.0.0.1:${observerPort}`,allowedTailscaleLogin:OWNER,ownerKeyFile});
  const port=await listen(t,connector);
  return {seen,ask:(path,{login=OWNER,...options}={})=>call(port,new URL(origin).host,origin,path,{login,...options})};
}

test("O1 · the front's key gives an ordinary eight-hour session, and the desktop's one-use code still pairs",async t=>{
  const {request,owner}=await gateway(t);
  const r=await owner();assert.equal(r.status,200);assert.deepEqual(r.json,{paired:true,by:'owner'});
  const cookie=cookieOf(r);assert.match(cookie,/^super_mobile=[0-9a-f]{64}$/);
  assert.match(r.headers['set-cookie'][0],/HttpOnly; SameSite=Strict; Path=\/; Max-Age=28800/);
  assert.equal((await request('/api/snapshot',{cookie})).status,200);
  assert.equal((await request('/api/pair',{method:'POST',body:{code:CODE}})).status,200,"the desktop's code is left as it was");
});

test('O2 · no key, a wrong key, or a gateway with no key is refused, and wrong keys count with wrong codes',async t=>{
  const {request,owner}=await gateway(t);
  assert.equal((await owner(null)).status,403);assert.equal((await owner(OTHER)).status,403);assert.equal((await owner(KEY.slice(0,63))).status,403);
  assert.equal((await request('/api/pair-owner')).status,401,'GET is no way in');
  for(let i=0;i<7;i++)await owner(OTHER);
  const closed=await owner();assert.equal(closed.status,429,'ten wrong tries close it for a minute, the right key too');assert.equal(cookieOf(closed),undefined);
  assert.equal((await request('/api/pair',{method:'POST',body:{code:CODE}})).status,429,'and codes with it');
  const none=await gateway(t,{ownerKey:null});assert.equal((await none.owner(KEY)).status,403);assert.equal((await none.owner('')).status,403);
  const short=await gateway(t,{ownerKey:'abc'});assert.equal((await short.owner('abc')).status,403,'a key that is not 64 hex characters is no key');
});

test('O3 · six sessions a minute without a code, then none until the minute is over',async t=>{
  const g=await gateway(t);
  for(let i=0;i<6;i++)assert.equal((await g.owner()).status,200,'session '+(i+1));
  assert.equal((await g.owner()).status,429);
  g.time.now+=61_000;assert.equal((await g.owner()).status,200);
});

test("O4 · the front adds the key from the gateway's private file, only for his login, and never passes on a key the phone sent",async t=>{
  const {seen,ask}=await front(t,{ownerKeyFile:keyFile(t)});
  const r=await ask('/api/pair-owner',{method:'POST',body:'{}',headers:{'x-super-owner-key':OTHER}});
  assert.equal(r.status,200);assert.match(r.headers['set-cookie'][0],/; Secure/);
  assert.deepEqual(seen.at(-1),{line:'POST /api/pair-owner',key:KEY},"the file's key, not the phone's");
  await ask('/api/waiting',{headers:{'x-super-owner-key':KEY}});await ask('/api/pair',{method:'POST',body:'{"code":"x"}',headers:{'x-super-owner-key':KEY}});
  assert.deepEqual(seen.slice(-2),[{line:'GET /api/waiting',key:null},{line:'POST /api/pair',key:null}],'a key the phone sends goes nowhere');
  const n=seen.length;
  assert.equal((await ask('/api/pair-owner',{method:'POST',body:'{}',login:'someone-else@example.com'})).status,403);
  assert.equal((await ask('/api/pair-owner',{method:'POST',body:'{}',login:null})).status,403);
  assert.equal((await ask('/api/pair-owner',{method:'POST',body:'{}',headers:{Origin:'https://evil.example'}})).status,403);
  assert.equal((await ask('/api/pair-owner')).status,405);
  assert.equal(seen.length,n,'nothing refused reaches the gateway');
});

test('O5 · no key without a private, well-formed key file, and only at the private HTTPS address',async t=>{
  for(const [what,file] of [['open to others',keyFile(t,{mode:0o644})],['missing',join(temp(t),'front-key.json')],['not a key',keyFile(t,{key:'zz'})],['another schema',keyFile(t,{schema:'x'})]]){
    const {seen,ask}=await front(t,{ownerKeyFile:file});
    const r=await ask('/api/pair-owner',{method:'POST',body:'{}'});
    assert.equal(r.status,503,what);assert.match(r.json.error,/Use a pairing code/,what);assert.equal(seen.length,0,what+': nothing passed on');
  }
  const plain=await front(t,{ownerKeyFile:keyFile(t),origin:'http://127.0.0.1:4319'});
  assert.equal((await plain.ask('/api/pair-owner',{method:'POST',body:'{}',login:null})).status,405,'plain HTTP has no such route');
  const none=await front(t,{ownerKeyFile:null});assert.equal((await none.ask('/api/pair-owner',{method:'POST',body:'{}'})).status,405);
  assert.equal(plain.seen.length+none.seen.length,0);
});

test('O6 · through the front, his phone connects with no code and reads Super',async t=>{
  const port=await freePort(),origin=`http://127.0.0.1:${port}`;
  await listen(t,createGateway({origin,pairingCode:CODE,ownerKey:KEY,snapshot:WORLD}),port);
  const connector=createConnector({origin:FRONT,observerOrigin:origin,allowedTailscaleLogin:OWNER,ownerKeyFile:keyFile(t)});
  const frontPort=await listen(t,connector),ask=(path,o={})=>call(frontPort,new URL(FRONT).host,FRONT,path,{login:OWNER,...o});
  const r=await ask('/api/pair-owner',{method:'POST',body:'{}'});
  assert.equal(r.status,200);assert.match(r.headers['set-cookie'][0],/; Secure/);
  const s=await ask('/api/snapshot',{headers:{Cookie:cookieOf(r)}});assert.equal(s.status,200);assert.equal(s.json.mode,'read-only');
  assert.equal((await ask('/api/snapshot')).status,401,'no cookie, no view');
});

test('O7 · the gateway writes a new private key file beside the session file at each start',async t=>{
  const d=temp(t),mobile=join(d,'mobile');mkdirSync(mobile,{mode:0o700});
  const start=async n=>{
    const env={...process.env,SUPER_MOBILE_PORT:String(await freePort()),SUPER_MOBILE_PAIR_FILE:join(d,'code-'+n),SUPER_MOBILE_SESSION_FILE:join(mobile,'sessions.json')};
    delete env.NODE_TEST_CONTEXT;delete env.SUPER_MOBILE_ORIGIN;
    const child=spawn(process.execPath,[fileURLToPath(new URL('../server.mjs',import.meta.url))],{cwd:d,env,stdio:['pipe','ignore','pipe']});
    let err='';child.stderr.on('data',c=>err+=c);
    for(let i=0;i<250&&!err.includes('Super mobile observer');i++)await delay(20);
    try{
      assert.match(err,/Super mobile observer/,'the gateway started');
      const f=join(mobile,'front-key.json');return {mode:statSync(f).mode&0o777,value:JSON.parse(readFileSync(f,'utf8'))};
    }finally{child.stdin.end();await new Promise(r=>child.exitCode!==null?r():child.on('close',r));}
  };
  const a=await start(1),b=await start(2);
  assert.equal(a.mode,0o600);assert.deepEqual(Object.keys(a.value).sort(),['key','schema']);
  assert.equal(a.value.schema,'super-mobile-front-key@1');assert.match(a.value.key,/^[0-9a-f]{64}$/);
  assert.notEqual(a.value.key,b.value.key,'a new key at each start');
});

const posts=phone=>phone.requests.filter(r=>r==='POST /api/pair-owner').length;
const connected=phone=>phone.until(()=>phone.$('#app').hidden===false&&phone.$('#pair').hidden===true&&phone.text('#status')==='● Connected','the app, connected');

test('O8 · at the private address the page connects by itself: no code, one request, the app on screen',async t=>{
  const phone=await openPhone(t,{front:KEY});
  await connected(phone);
  assert.deepEqual(phone.requests.filter(r=>r.startsWith('POST')),['POST /api/pair-owner']);
  assert.equal(phone.$('#pair').hidden,true);assert.equal(phone.$('#code').value,'');
});

test('O9 · after Disconnect it stays out, through a reload, until he taps Connect this phone',async t=>{
  const phone=await openPhone(t,{front:KEY});await connected(phone);
  phone.tap('[data-view=stack]');await phone.until(()=>phone.text('#content h1')==='Connected stack.','the stack view');
  phone.tap(phone.button('Disconnect this device'));
  await phone.until(()=>phone.text('#content').includes('Disconnect this phone?'),'the question');
  assert.match(phone.text('#content'),/To connect again, tap Connect this phone\./);
  phone.tap(phone.button('Disconnect'));
  await phone.until(()=>!phone.$('#pair').hidden,'the pair screen');
  assert.equal(phone.text('#notice'),'Device disconnected. Tap Connect this phone to connect again.');
  const before=posts(phone);
  await phone.reload();await phone.idle();
  assert.equal(phone.$('#pair').hidden,false);assert.equal(posts(phone),before,'no connecting by itself after Disconnect');
  assert.equal(phone.$('#owner').hidden,false);
  phone.tap('#owner-connect');await connected(phone);assert.equal(posts(phone),before+1);
  await phone.reload();await connected(phone);assert.equal(posts(phone),before+1,'the session carries on; Connect cleared the stay-out');
});

test('O10 · elsewhere the code is the only way; at the private address a refused try waits 30 seconds and a tap says why',async t=>{
  const plain=await openPhone(t);
  assert.equal(plain.$('#owner').hidden,true);assert.equal(posts(plain),0);assert.match(plain.text('#pair-intro'),/^Paste the one-use pairing code/);
  const refused=await openPhone(t,{front:KEY,ownerKey:OTHER});
  assert.equal(posts(refused),1);assert.equal(refused.$('#pair').hidden,false);assert.equal(refused.$('#owner').hidden,false);
  assert.equal(refused.text('#notice'),'','a try by itself says nothing');
  assert.match(refused.text('#pair-intro'),/Tailscale sign-in shows this phone is yours/);
  refused.tap('#refresh');await refused.idle();assert.equal(posts(refused),1,'not again within 30 seconds');
  refused.tap('#owner-connect');await refused.idle();assert.equal(posts(refused),2,'a tap always asks');
  assert.equal(refused.text('#notice'),'Connecting without a code works only at the private address.');
  await refused.pair(CODE);await connected(refused);
});
