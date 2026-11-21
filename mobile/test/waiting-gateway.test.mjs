/* Laws for the gateway's Waiting on you routes (server.mjs) and the private HTTPS front (private-connector.mjs). */
import test from 'node:test';import assert from 'node:assert/strict';import http from 'node:http';
import {join} from 'node:path';
import {createGateway} from '../server.mjs';
import {createConnector} from '../private-connector.mjs';
import {waitingView} from '../waiting.mjs';
import {gatewayAlerts} from '../waiting-alerts.mjs';
import {pushStore} from '../push-store.mjs';
import {NOW,T,line,board,dirs,putBoard,putConfig,phone,pushService} from './waiting-fixture.mjs';

const ORIGIN='http://127.0.0.1:4318';
async function setup(t,{lines=[line('a',{since:T-7200}),line('b',{since:T-600})]}={}){
  const d=dirs(t);putBoard(d.dir,board(lines));putConfig(d.dir,{subject:'https://super.example.ts.net'});
  const service=pushService();
  const server=createGateway({origin:ORIGIN,pairingCode:'fixture-code',now:()=>NOW,snapshot:async()=>({available:true,projection:{development_tasks:{}}}),
    waiting:async()=>waitingView(d.dir,NOW),alerts:gatewayAlerts({dir:d.dir,mobileDir:d.mobileDir,now:()=>NOW,fetch:service.fetch})});
  await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>{server.closeAllConnections();server.close();});
  const request=(path,{method='GET',cookie,body,origin=ORIGIN,type='application/json'}={})=>new Promise((resolve,reject)=>{
    const req=http.request({host:'127.0.0.1',port:server.address().port,path,method,headers:{Host:'127.0.0.1:4318',...(origin?{Origin:origin}:{}),...(cookie?{Cookie:cookie}:{}),...(body!==undefined?{'Content-Type':type}:{})}},
      res=>{const chunks=[];res.on('data',c=>chunks.push(c));res.on('end',()=>{const buf=Buffer.concat(chunks);let json=null;try{json=JSON.parse(buf);}catch{}resolve({status:res.statusCode,headers:res.headers,buf,json});});});
    req.on('error',reject);req.end(body===undefined?undefined:typeof body==='string'?body:JSON.stringify(body));});
  const pair=async()=>{const r=await request('/api/pair',{method:'POST',body:{code:'fixture-code'}});assert.equal(r.status,200);return r.headers['set-cookie'][0].split(';')[0];};
  return {...d,request,pair,service,store:()=>pushStore(d.mobileDir)};
}

test('G1 · the board needs a paired session',async t=>{
  const {request}=await setup(t);
  for(const path of ['/api/waiting','/api/push'])assert.equal((await request(path)).status,401,path);
  for(const op of ['subscribe','unsubscribe','status','test'])assert.equal((await request('/api/push/'+op,{method:'POST',body:{}})).status,401,op);
});

test("G2 · the gateway serves Super's view of the board: oldest first, a note for each line, its age and the open count",async t=>{
  const {request,pair}=await setup(t),cookie=await pair();
  const r=await request('/api/waiting',{cookie});
  assert.equal(r.status,200);assert.equal(r.headers['cache-control'],'no-store');
  const v=r.json;assert.equal(v.schema,'super-waiting-view@1');assert.equal(v.available,true);assert.equal(v.stale,false);assert.equal(v.age_seconds,60);
  assert.equal(v.mode,'shadow');assert.equal(v.now,T);assert.equal(v.open,2);
  assert.deepEqual(v.lines.map(l=>[l.thread,l.alert.state]),[['a','due'],['b','later']]);
  assert.deepEqual(Object.keys(v.lines[0]).sort(),['alert','chat','chat_id','line','since','thread'],'the view carries no more than the phone needs');
});

test('G3 · alert routes take same-origin JSON only; a push service off the list is refused; on, status, test and off work',async t=>{
  const {request,pair,service,store}=await setup(t),cookie=await pair(),p=phone();
  const info=(await request('/api/push',{cookie})).json;assert.equal(info.available,true);assert.match(info.publicKey,/^B[A-Za-z0-9_-]{86}$/);assert.equal(info.can_send,true);
  assert.equal((await request('/api/push/subscribe',{method:'POST',cookie,body:p.sub,origin:'https://evil.example'})).status,403);
  assert.equal((await request('/api/push/subscribe',{method:'POST',cookie,body:p.sub,type:'text/plain'})).status,415);
  assert.equal((await request('/api/push/subscribe',{method:'POST',cookie,body:'x'.repeat(3000)})).status,413);
  const evil=await request('/api/push/subscribe',{method:'POST',cookie,body:{...p.sub,endpoint:'https://evil.example/collect'}});
  assert.equal(evil.status,400);assert.match(evil.json.error,/not one Super sends to/);
  assert.equal((await request('/api/push/subscribe',{method:'POST',cookie,body:{...p.sub,extra:1}})).status,400);
  assert.equal((await request('/api/push/subscribe',{method:'POST',cookie,body:{...p.sub,expirationTime:null}})).status,200);
  assert.deepEqual(store().list().map(x=>x.endpoint),[p.endpoint]);
  assert.deepEqual((await request('/api/push/status',{method:'POST',cookie,body:{endpoint:p.endpoint}})).json,{known:true,gone:false});
  assert.equal((await request('/api/push/test',{method:'POST',cookie,body:{endpoint:p.endpoint}})).json.outcome,'sent');
  assert.deepEqual(service.calls.map(c=>c.url),[p.endpoint]);
  assert.equal((await request('/api/push/unsubscribe',{method:'POST',cookie,body:{endpoint:p.endpoint}})).json.removed,true);
  assert.deepEqual(store().list(),[]);
  assert.equal((await request('/api/push/status',{method:'POST',cookie,body:{endpoint:p.endpoint,more:1}})).status,400);
  assert.equal((await request('/api/push/remove-all',{method:'POST',cookie,body:{}})).status,405);
});

test("G4 · Disconnect this device also turns that device's alerts off",async t=>{
  const s=await setup(t),one=await s.pair();
  const a=phone('a');await s.request('/api/push/subscribe',{method:'POST',cookie:one,body:a.sub});
  assert.equal(s.store().list().length,1);
  assert.equal((await s.request('/api/logout',{method:'POST',cookie:one,body:{}})).status,200);
  assert.deepEqual(s.store().list(),[]);
});

test('G5 · the service worker, the manifest, the icons and the /mobile page are served without a session, with their types',async t=>{
  const {request}=await setup(t);
  const want={'/sw.js':/^text\/javascript/,'/waiting.js':/^text\/javascript/,'/manifest.webmanifest':/^application\/manifest\+json/,'/mobile':/^text\/html/,'/icon-512.png':/^image\/png$/,'/icon-128.png':/^image\/png$/};
  for(const [path,type] of Object.entries(want)){const r=await request(path);assert.equal(r.status,200,path);assert.match(r.headers['content-type'],type,path);assert.equal(r.headers['cache-control'],'no-store');}
  const png=(await request('/icon-512.png')).buf;assert.deepEqual([...png.subarray(1,4)],[80,78,71]);assert.equal(png.readUInt32BE(16),512);
  const m=(await request('/manifest.webmanifest')).json;assert.equal(m.display,'standalone');assert.equal(m.start_url,'/mobile#/attention');assert.ok(m.icons.some(i=>i.sizes==='512x512'));
  const page=(await request('/mobile')).buf.toString();assert.match(page,/rel="manifest" href="\/manifest.webmanifest"/);assert.match(page,/rel="apple-touch-icon"/);assert.match(page,/id="waiting"/);
  assert.equal((await request('/sw.js',{method:'POST',body:{}})).status,401,'assets are read-only');
});

test('G6 · the private HTTPS front passes the new routes, with the same methods, and still checks the owner',async t=>{
  const seen=[];const observer=http.createServer((req,res)=>{seen.push(req.method+' '+req.url);res.writeHead(200,{'Content-Type':'application/json'});res.end('{}');});
  await new Promise(r=>observer.listen(0,'127.0.0.1',r));t.after(()=>observer.close());
  const front='https://super-mobile.example.ts.net',connector=createConnector({origin:front,observerOrigin:`http://127.0.0.1:${observer.address().port}`,allowedTailscaleLogin:'owner@example.com'});
  await new Promise(r=>connector.listen(0,'127.0.0.1',r));t.after(()=>connector.close());
  const ask=(path,method='GET',login='owner@example.com',body)=>new Promise((resolve,reject)=>{const req=http.request({host:'127.0.0.1',port:connector.address().port,path,method,headers:{Host:'super-mobile.example.ts.net',Origin:front,'Tailscale-User-Login':login,...(body?{'Content-Type':'application/json'}:{})}},res=>{res.resume();res.on('end',()=>resolve(res.statusCode));});req.on('error',reject);req.end(body);});
  for(const path of ['/api/waiting','/api/push','/sw.js','/manifest.webmanifest','/waiting.js','/icon-512.png','/icon-128.png'])assert.equal(await ask(path),200,path);
  for(const op of ['subscribe','unsubscribe','status','test'])assert.equal(await ask('/api/push/'+op,'POST','owner@example.com','{"endpoint":"x"}'),200,op);
  assert.equal(await ask('/api/push/subscribe','POST','owner@example.com',JSON.stringify({endpoint:'https://web.push.apple.com/'+'x'.repeat(1500)})),200,'a full subscription fits');
  assert.equal(await ask('/api/waiting','POST','owner@example.com','{}'),405);assert.equal(await ask('/api/push/test'),405);
  assert.equal(await ask('/api/waiting','GET','someone-else@example.com'),403);
  assert.deepEqual(seen.filter(s=>s.includes('/api/')).slice(0,2),['GET /api/waiting','GET /api/push']);
});
