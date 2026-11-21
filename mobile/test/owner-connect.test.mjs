/* Laws for connecting his phone without a code. The gateway hands out such sessions only on its own code-free
 * listener (server.mjs ownerServer), which main puts on a private Unix socket. The private HTTPS front checks his
 * Tailscale login and is itself on a private Unix socket (private-connector.mjs), so no process on the machine can
 * reach either with a made-up login over TCP (Codex review 2, findings 1 and 2). Also the socket helper
 * (private-file.mjs) and the phone page (ui/app.js in the T31 phone, phone.mjs). */
import test from 'node:test';import assert from 'node:assert/strict';import http from 'node:http';
import {chmodSync,existsSync,lstatSync,mkdirSync,mkdtempSync,rmSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';import {join} from 'node:path';import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {createGateway} from '../server.mjs';
import {createConnector} from '../private-connector.mjs';
import {listenPrivateSocket} from '../private-file.mjs';
import {CODE,openPhone} from './phone.mjs';

const ORIGIN='http://127.0.0.1:4318',FRONT='https://super-mobile.example.ts.net',OWNER='owner@example.com';
const WORLD=async()=>({available:true,projection:{development_tasks:{}}});
// Short folders: a Unix socket path must stay under about 100 bytes.
const temp=t=>{const d=mkdtempSync(join(tmpdir(),'so-'));t.after(()=>rmSync(d,{recursive:true,force:true}));return d;};
const delay=ms=>new Promise(r=>setTimeout(r,ms));
const freePort=async()=>{const s=http.createServer();await new Promise(r=>s.listen(0,'127.0.0.1',r));const {port}=s.address();await new Promise(r=>s.close(r));return port;};
const closing=(t,server)=>t.after(()=>{server.closeAllConnections?.();server.close();});
const listen=async(t,server,port=0)=>{await new Promise(r=>server.listen(port,'127.0.0.1',r));closing(t,server);return server.address().port;};
/** One request, to a TCP port or a socket path, as `host`; resolves with status, headers and the parsed body. */
const call=(where,host,origin,path,{method='GET',login,headers={},body}={})=>new Promise((resolve,reject)=>{
  const req=http.request({...(typeof where==='string'?{socketPath:where}:{host:'127.0.0.1',port:where}),path,method,headers:{Host:host,...(origin?{Origin:origin}:{}),...(login?{'Tailscale-User-Login':login}:{}),...(body!==undefined?{'Content-Type':'application/json'}:{}),...headers}},
    res=>{const c=[];res.on('data',x=>c.push(x));res.on('end',()=>{let json=null;try{json=JSON.parse(Buffer.concat(c));}catch{}resolve({status:res.statusCode,headers:res.headers,json});});});
  req.on('error',reject);req.end(body===undefined?undefined:typeof body==='string'?body:JSON.stringify(body));});
const cookieOf=r=>r.headers['set-cookie']?.[0]?.split(';')[0];

/** A gateway on TCP, with its code-free listener on a private socket in a fresh folder. */
async function gateway(t){
  const time={now:1_800_000_000_000},dir=temp(t),socket=join(dir,'m','owner.sock');
  const server=createGateway({origin:ORIGIN,pairingCode:CODE,now:()=>time.now,snapshot:WORLD});
  const port=await listen(t,server);await listenPrivateSocket(server.ownerServer,socket);closing(t,server.ownerServer);
  const tcp=(path,{cookie,headers={},...o}={})=>call(port,'127.0.0.1:4318',ORIGIN,path,{...o,headers:{...(cookie?{Cookie:cookie}:{}),...headers}});
  const owner=(o={})=>call(socket,'127.0.0.1:4318',ORIGIN,'/api/pair-owner',{method:'POST',body:{},...o});
  return {tcp,owner,socket,time,port};
}
/** A front on its own private socket, in front of a stub gateway (TCP) and a stub code-free listener (socket). */
async function front(t,{origin=FRONT,ownerSocket='stub'}={}){
  const seen=[],dir=temp(t);
  const record=(req,res)=>{seen.push({line:req.method+' '+req.url,headers:req.headers});res.writeHead(200,{'Content-Type':'application/json','Set-Cookie':'super_mobile=x; HttpOnly'});res.end('{}');};
  const observerPort=await listen(t,http.createServer(record));
  let socket=ownerSocket;
  if(ownerSocket==='stub'){socket=join(dir,'g','owner.sock');const stub=http.createServer((req,res)=>{req.via='owner-socket';seen.push({line:'owner-socket '+req.method+' '+req.url,headers:req.headers});res.writeHead(200,{'Content-Type':'application/json','Set-Cookie':'super_mobile=y; HttpOnly'});res.end('{"paired":true}');});await listenPrivateSocket(stub,socket);closing(t,stub);}
  const connector=createConnector({origin,observerOrigin:`http://127.0.0.1:${observerPort}`,allowedTailscaleLogin:OWNER,ownerSocket:socket});
  const frontSocket=join(dir,'f','front.sock');await listenPrivateSocket(connector,frontSocket);closing(t,connector);
  return {seen,frontSocket,ask:(path,{login=OWNER,...o}={})=>call(frontSocket,new URL(origin).host,origin,path,{login,...o})};
}

test("O1 · the code-free listener gives an ordinary eight-hour session; the gateway's TCP port gives none; the desktop's code still pairs",async t=>{
  const {tcp,owner}=await gateway(t);
  const r=await owner();assert.equal(r.status,200);assert.deepEqual(r.json,{paired:true,by:'owner'});
  const cookie=cookieOf(r);assert.match(cookie,/^super_mobile=[0-9a-f]{64}$/);
  assert.match(r.headers['set-cookie'][0],/HttpOnly; SameSite=Strict; Path=\/; Max-Age=28800/);
  assert.equal((await tcp('/api/snapshot',{cookie})).status,200);
  for(const headers of [{},{'Tailscale-User-Login':OWNER},{'x-super-owner-key':'a1'.repeat(32)}]){
    const w=await tcp('/api/pair-owner',{method:'POST',body:{},headers});assert.notEqual(w.status,200);assert.equal(cookieOf(w),undefined,'no session over TCP');
  }
  assert.equal((await tcp('/api/pair',{method:'POST',body:{code:CODE}})).status,200,"the desktop's code is left as it was");
});

test('O2 · the code-free listener does that one thing: POST /api/pair-owner, a small body',async t=>{
  const {owner,socket}=await gateway(t);
  assert.equal((await call(socket,'127.0.0.1:4318',ORIGIN,'/api/pair-owner')).status,405);
  assert.equal((await call(socket,'127.0.0.1:4318',ORIGIN,'/api/snapshot')).status,405);
  assert.equal((await call(socket,'127.0.0.1:4318',ORIGIN,'/api/pair',{method:'POST',body:{code:CODE}})).status,405,'not the code route');
  assert.equal((await owner({body:'x'.repeat(2000)})).status,413);
});

test('O3 · six sessions a minute, counted as requests arrive, so seven at once give six; then none until the minute is over',async t=>{
  const g=await gateway(t);
  // Seven requests whose bodies have not come yet: each counts as it arrives, so the seventh is refused at once.
  const open=()=>{let resolve;const done=new Promise(r=>resolve=r);
    const req=http.request({socketPath:g.socket,path:'/api/pair-owner',method:'POST',headers:{Host:'127.0.0.1:4318','Content-Type':'application/json','Content-Length':'2'}},res=>{res.resume();res.on('end',()=>resolve(res.statusCode));});
    req.on('error',()=>{});req.flushHeaders();return {req,done};};
  const seven=Array.from({length:7},open);await delay(150);for(const s of seven)s.req.end('{}');
  assert.deepEqual((await Promise.all(seven.map(s=>s.done))).sort(),[200,200,200,200,200,200,429]);
  assert.equal((await g.owner()).status,429);
  g.time.now+=61_000;assert.equal((await g.owner()).status,200);
});

test('O4 · the front sends code-free sign-in only to the code-free socket, only for his login, and passes on none of the phone’s own headers',async t=>{
  const {seen,ask}=await front(t);
  const r=await ask('/api/pair-owner',{method:'POST',body:'{}',headers:{'x-super-owner-key':'z','X-Forwarded-For':'1.2.3.4'}});
  assert.equal(r.status,200);assert.match(r.headers['set-cookie'][0],/; Secure/);
  const last=seen.at(-1);assert.equal(last.line,'owner-socket POST /api/pair-owner');
  assert.deepEqual(Object.keys(last.headers).filter(k=>!['host','origin','content-type','content-length','connection'].includes(k)),[],'only what the front sets itself');
  await ask('/api/waiting');assert.equal(seen.at(-1).line,'GET /api/waiting','everything else still goes to the gateway');
  const n=seen.length;
  assert.equal((await ask('/api/pair-owner',{method:'POST',body:'{}',login:'someone-else@example.com'})).status,403);
  assert.equal((await ask('/api/pair-owner',{method:'POST',body:'{}',login:null})).status,403);
  assert.equal((await ask('/api/pair-owner',{method:'POST',body:'{}',headers:{Origin:'https://evil.example'}})).status,403);
  assert.equal((await ask('/api/pair-owner')).status,405);
  assert.equal(seen.length,n,'nothing refused reaches the gateway');
});

test('O5 · only at the private HTTPS address, and a missing code-free socket says to use a code',async t=>{
  const missing=await front(t,{ownerSocket:join(temp(t),'nothing.sock')});
  const r=await missing.ask('/api/pair-owner',{method:'POST',body:'{}'});
  assert.equal(r.status,503);assert.equal(r.json.error,'Connecting without a code is not available right now. Use a pairing code.');
  const plain=await front(t,{origin:'http://127.0.0.1:4319'});
  assert.equal((await plain.ask('/api/pair-owner',{method:'POST',body:'{}',login:null})).status,405,'plain HTTP has no such route');
  const none=await front(t,{ownerSocket:null});assert.equal((await none.ask('/api/pair-owner',{method:'POST',body:'{}'})).status,405);
  assert.equal(plain.seen.length+none.seen.length,0);
});

test('O6 · through the front, his phone connects with no code and reads Super',async t=>{
  const port=await freePort(),origin=`http://127.0.0.1:${port}`,dir=temp(t);
  const server=createGateway({origin,pairingCode:CODE,snapshot:WORLD});await listen(t,server,port);
  const ownerSocket=join(dir,'m','owner.sock');await listenPrivateSocket(server.ownerServer,ownerSocket);closing(t,server.ownerServer);
  const connector=createConnector({origin:FRONT,observerOrigin:origin,allowedTailscaleLogin:OWNER,ownerSocket});
  const frontSocket=join(dir,'f','front.sock');await listenPrivateSocket(connector,frontSocket);closing(t,connector);
  const ask=(path,o={})=>call(frontSocket,new URL(FRONT).host,FRONT,path,{login:OWNER,...o});
  const r=await ask('/api/pair-owner',{method:'POST',body:'{}'});
  assert.equal(r.status,200);assert.match(r.headers['set-cookie'][0],/; Secure/);
  const s=await ask('/api/snapshot',{headers:{Cookie:cookieOf(r)}});assert.equal(s.status,200);assert.equal(s.json.mode,'read-only');
  assert.equal((await ask('/api/snapshot')).status,401,'no cookie, no view');
});

/** Start a module as its own process; wait for `ready` on stdout or stderr; stop it by closing stdin or a signal. */
async function started(t,file,env,ready){
  const e={...process.env,...env};delete e.NODE_TEST_CONTEXT;if(!('SUPER_MOBILE_ORIGIN' in env))delete e.SUPER_MOBILE_ORIGIN;
  const child=spawn(process.execPath,[fileURLToPath(new URL(file,import.meta.url))],{cwd:tmpdir(),env:e,stdio:['pipe','pipe','pipe']});
  let out='';child.stdout.on('data',c=>out+=c);child.stderr.on('data',c=>out+=c);
  t.after(()=>{if(child.exitCode===null)child.kill('SIGKILL');});
  for(let i=0;i<250&&!ready.test(out);i++)await delay(20);
  return {child,out:()=>out,stop:async()=>{child.stdin.end();child.kill('SIGTERM');if(child.exitCode===null)await new Promise(r=>child.on('close',r));}};
}

test('O7 · started, the gateway puts its code-free listener on a 0600 socket beside the session file, and the front listens only on its own 0600 socket',async t=>{
  const d=temp(t),mobile=join(d,'m');mkdirSync(mobile,{mode:0o700});
  const port=await freePort();
  const g=await started(t,'../server.mjs',{SUPER_MOBILE_PORT:String(port),SUPER_MOBILE_PAIR_FILE:join(d,'code'),SUPER_MOBILE_SESSION_FILE:join(mobile,'sessions.json')},/Super mobile observer/);
  assert.match(g.out(),/Super mobile observer/,'the gateway started');assert.doesNotMatch(g.out(),/no connecting without a code/);
  const sock=join(mobile,'owner.sock'),s=lstatSync(sock);
  assert.ok(s.isSocket());assert.equal(s.mode&0o777,0o600);assert.equal(existsSync(join(mobile,'front-key.json')),false,'no key file');
  const r=await call(sock,'127.0.0.1:4318',ORIGIN,'/api/pair-owner',{method:'POST',body:{}});assert.equal(r.status,200);
  await g.stop();
  const f=await started(t,'../private-connector.mjs',{SUPER_MOBILE_PRIVATE_ORIGIN:FRONT,SUPER_MOBILE_TAILSCALE_LOGIN:OWNER,SUPER_MOBILE_FRONT_SOCKET:join(d,'f','front.sock'),SUPER_MOBILE_OWNER_SOCKET:sock},/listening on /);
  assert.match(f.out(),new RegExp(`listening on ${join(d,'f','front.sock').replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}\\.`));
  const fs=lstatSync(join(d,'f','front.sock'));assert.ok(fs.isSocket());assert.equal(fs.mode&0o777,0o600);assert.equal(lstatSync(join(d,'f')).mode&0o777,0o700);
  assert.equal((await call(join(d,'f','front.sock'),new URL(FRONT).host,FRONT,'/api/waiting')).status,403,'no login, no way in');
  await f.stop();
});

test('O11 · a private socket: a 0700 folder of ours, a 0600 socket, only our own old socket replaced',async t=>{
  const d=temp(t),open=join(d,'open');mkdirSync(open,{mode:0o755});chmodSync(open,0o755);
  await assert.rejects(listenPrivateSocket(http.createServer(),join(open,'s.sock')),/not private to this user/);
  const dir=join(d,'p');mkdirSync(dir,{mode:0o700});const file=join(dir,'s.sock');writeFileSync(file,'not a socket');
  await assert.rejects(listenPrivateSocket(http.createServer(),file),/Something other than our socket/);assert.ok(lstatSync(file).isFile(),'left in place');
  rmSync(file);
  const first=http.createServer();await listenPrivateSocket(first,file);assert.equal(lstatSync(file).mode&0o777,0o600);
  await new Promise(r=>first.close(r));
  const old=http.createServer();await new Promise(r=>old.listen(join(dir,'left.sock'),r));closing(t,old);
  const again=http.createServer();await listenPrivateSocket(again,join(dir,'left.sock'));closing(t,again);assert.ok(lstatSync(join(dir,'left.sock')).isSocket(),'our own old socket is replaced');
  const made=join(d,'new','s.sock');const m=http.createServer();await listenPrivateSocket(m,made);closing(t,m);assert.equal(lstatSync(join(d,'new')).mode&0o777,0o700);
  await assert.rejects(listenPrivateSocket(http.createServer(),'relative.sock'),/absolute path/);
});

const posts=phone=>phone.requests.filter(r=>r==='POST /api/pair-owner').length;
const connected=phone=>phone.until(()=>phone.$('#app').hidden===false&&phone.$('#pair').hidden===true&&phone.text('#status')==='● Connected','the app, connected');

test('O8 · at the private address the page connects by itself: no code, one request, the app on screen',async t=>{
  const phone=await openPhone(t,{front:true});
  await connected(phone);
  assert.deepEqual(phone.requests.filter(r=>r.startsWith('POST')),['POST /api/pair-owner']);
  assert.equal(phone.$('#pair').hidden,true);assert.equal(phone.$('#code').value,'');
});

test('O9 · after Disconnect it stays out, through a reload, until he taps Connect this phone',async t=>{
  const phone=await openPhone(t,{front:true});await connected(phone);
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
  const refused=await openPhone(t,{front:'unavailable'});
  assert.equal(posts(refused),1);assert.equal(refused.$('#pair').hidden,false);assert.equal(refused.$('#owner').hidden,false);
  assert.equal(refused.text('#notice'),'','a try by itself says nothing');
  assert.match(refused.text('#pair-intro'),/Tailscale sign-in shows this phone is yours/);
  refused.tap('#refresh');await refused.idle();assert.equal(posts(refused),1,'not again within 30 seconds');
  refused.tap('#owner-connect');await refused.idle();assert.equal(posts(refused),2,'a tap always asks');
  assert.equal(refused.text('#notice'),'Connecting without a code is not available right now. Use a pairing code.');
  await refused.pair(CODE);await connected(refused);
});
