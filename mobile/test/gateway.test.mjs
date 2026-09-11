import test from 'node:test';import assert from 'node:assert/strict';import http from 'node:http';
import {createGateway} from '../server.mjs';
async function setup(t){let clock=0;const server=createGateway({origin:'http://127.0.0.1:4318',pairingCode:'fixture-code',now:()=>clock,snapshot:async()=>({available:true,projection:{development_tasks:{}}})});await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>{server.closeAllConnections();server.close();});
 const request=(path,{method='GET',cookie,body,origin='http://127.0.0.1:4318',host='127.0.0.1:4318'}={})=>new Promise((resolve,reject)=>{const req=http.request({host:'127.0.0.1',port:server.address().port,path,method,headers:{Host:host,...(origin?{Origin:origin}:{}),...(cookie?{Cookie:cookie}:{}),...(body?{'Content-Type':'application/json'}:{})}},res=>{let text='';res.on('data',c=>text+=c);res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,text}));});req.on('error',reject);req.end(body?JSON.stringify(body):undefined);});
 const pair=async(code='fixture-code')=>{const r=await request('/api/pair',{method:'POST',body:{code}});assert.equal(r.status,200);return r.headers['set-cookie'][0].split(';')[0];};return {request,pair,server,advance:n=>clock+=n};}
test('unauthenticated observation and mutation are refused',async t=>{const {request}=await setup(t);assert.equal((await request('/api/snapshot')).status,401);assert.equal((await request('/api/intent',{method:'POST',body:{}})).status,401);});
test('one-use pairing grants observation, never mutation; logout revokes cookie',async t=>{const {request,pair}=await setup(t);const cookie=await pair();assert.equal((await request('/api/snapshot',{cookie})).status,200);assert.equal((await request('/api/pair',{method:'POST',body:{code:'fixture-code'}})).status,401);assert.equal((await request('/api/intent',{method:'POST',cookie,body:{operation:'approve'}})).status,405);assert.equal((await request('/api/logout',{method:'POST',cookie,body:{}})).status,200);assert.equal((await request('/api/snapshot',{cookie})).status,401);});
test('cross-origin pairing, DNS rebinding, and missing write origin fail',async t=>{const {request}=await setup(t);for(const opts of [{origin:'https://attacker.invalid'},{origin:null},{host:'attacker.invalid'}])assert.equal((await request('/api/pair',{method:'POST',body:{code:'fixture-code'},...opts})).status,403);});
test('pairing and session expiration are enforced',async t=>{const s=await setup(t);s.advance(600001);assert.equal((await s.request('/api/pair',{method:'POST',body:{code:'fixture-code'}})).status,401);const a=await setup(t),cookie=await a.pair();a.advance(28800001);assert.equal((await a.request('/api/snapshot',{cookie})).status,401);});
test('assets have a closed allowlist and no cache',async t=>{const {request,pair}=await setup(t);const r=await request('/');assert.equal(r.status,200);assert.equal(r.headers['cache-control'],'no-store');const cookie=await pair();assert.equal((await request('/../server.mjs',{cookie})).status,405);});
test('insecure remote origins are rejected',()=>{assert.throws(()=>createGateway({origin:'http://192.168.1.20:4318'}));});
test('failed pairing is throttled without granting a session',async t=>{const {request}=await setup(t);for(let i=0;i<10;i++)assert.equal((await request('/api/pair',{method:'POST',body:{code:'wrong'}})).status,401);assert.equal((await request('/api/pair',{method:'POST',body:{code:'fixture-code'}})).status,429);});
test('cookies are HttpOnly and same-site and GET cannot logout',async t=>{const {request}=await setup(t);const r=await request('/api/pair',{method:'POST',body:{code:'fixture-code'}});const c=r.headers['set-cookie'][0];assert.match(c,/HttpOnly/);assert.match(c,/SameSite=Strict/);assert.equal((await request('/api/logout',{cookie:c.split(';')[0]})).status,405);});

const FRESH='a'.repeat(48);
test('a renewed code pairs again and leaves every existing session alone',async t=>{
 const {request,pair,server,advance}=await setup(t);
 const first=await pair();
 // Spent: the whole reason this exists. Before renewal the only way back was
 // restarting the host, which revokes the session above as collateral.
 assert.equal((await request('/api/pair',{method:'POST',body:{code:'fixture-code'}})).status,401);
 assert.equal(server.renewPairing(FRESH),true);
 const second=await pair(FRESH);
 assert.notEqual(second,first);
 // Both devices are now reading. That is the point of a second code.
 assert.equal((await request('/api/snapshot',{cookie:first})).status,200);
 assert.equal((await request('/api/snapshot',{cookie:second})).status,200);
 // The old code does not come back to life.
 assert.equal((await request('/api/pair',{method:'POST',body:{code:'fixture-code'}})).status,401);
 // And the new one is one-use like any other.
 assert.equal((await request('/api/pair',{method:'POST',body:{code:FRESH}})).status,401);
 // Ten fresh minutes, not the remainder of the old window.
 assert.equal(server.renewPairing('b'.repeat(48)),true);
 advance(600001);
 assert.equal((await request('/api/pair',{method:'POST',body:{code:'b'.repeat(48)}})).status,401);
});

test('renewal refuses anything that is not a code, and clears the throttle',async t=>{
 const {request,server}=await setup(t);
 for(const bad of ['','short','NOTHEX'.repeat(8),'a'.repeat(129),null,undefined,42,{},['a'.repeat(48)]])
  assert.equal(server.renewPairing(bad),false,JSON.stringify(bad));
 // A locked-out device is the likeliest reason someone asks for a new code;
 // handing them one that is still rate-limited would be no answer at all.
 for(let i=0;i<10;i++)await request('/api/pair',{method:'POST',body:{code:'wrong'}});
 assert.equal((await request('/api/pair',{method:'POST',body:{code:'fixture-code'}})).status,429);
 assert.equal(server.renewPairing(FRESH),true);
 assert.equal((await request('/api/pair',{method:'POST',body:{code:FRESH}})).status,200);
});

test('renewal is not reachable over HTTP',async t=>{
 // It is a method on the server object, called by the process that spawned
 // this one over its stdin pipe. Nothing routes to it.
 const {request,pair}=await setup(t);
 const cookie=await pair();
 for(const path of ['/api/renew','/api/new-code','/api/pairing'])
  assert.equal((await request(path,{method:'POST',cookie,body:{}})).status,405,path);
});
