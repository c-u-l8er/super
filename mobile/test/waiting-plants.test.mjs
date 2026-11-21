/* Planted bugs for Waiting on you. Each plant is a copy of the companion with one rule switched off; the named law
 * must fail on that copy. The copies live in a temp folder; this repository is only read. If a plant's text is
 * not found exactly once, the plant itself fails, so a change to the code cannot quietly retire a plant. */
import test from 'node:test';import assert from 'node:assert/strict';
import {cpSync,mkdtempSync,readFileSync,rmSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';import {join} from 'node:path';import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const ROOT=fileURLToPath(new URL('../../',import.meta.url));
const FEED='waiting-feed.test.mjs',PUSH='push.test.mjs',ALERTS='waiting-alerts.test.mjs',GATE='waiting-gateway.test.mjs',PHONE='phone-waiting.test.mjs',OWNER='owner-connect.test.mjs';
// [what is switched off, file, [[text, replacement], ...], the law file, the law that must catch it]
export const PLANTS=[
  ['quiet hours','waiting.mjs',[["if(quiet(c,ms))return null;","if(false)return null;"]],FEED,'W6'],
  ['a missed digest is made up','waiting.mjs',[["if(x.at<=ms&&!quiet(c,x.at))slot=","if(x.at<=ms&&ms-x.at<600_000&&!quiet(c,x.at))slot="]],FEED,'W6'],
  ['the configured clock','waiting.mjs',[["at:wallClock(c.time_zone,y,mo,d,h,mi)};","at:Date.UTC(y,mo-1,d,h,mi)};"]],FEED,'W6'],
  ['the 30-minute wait','waiting.mjs',[["else if(t-l.since<after)notes[l.thread]=","else if(false)notes[l.thread]="]],FEED,'W5'],
  ['one digest per digest time','waiting.mjs',[["else if(mine&&['sent','shadow'].includes(mine.outcome)||mac){","else if(mac){"]],FEED,'W7'],
  ['a trial digest counts as done','waiting.mjs',[["else if(mine&&['sent','shadow'].includes(mine.outcome)||mac){","else if(mine&&mine.outcome==='sent'||mac){"]],FEED,'W7'],
  ['a changed Status is a new line','waiting.mjs',[["if(!s||s.key!==l.key)s=","if(!s)s="]],FEED,'W11'],
  ['the new count','waiting.mjs',[["!lines[l.thread].digest_at&&",""]],FEED,'W11'],
  ['he already wrote','waiting.mjs',[["if(answered(l))notes[l.thread]=","if(false)notes[l.thread]="]],FEED,'W8'],
  ['the busy check','waiting.mjs',[["else if(l.busy)notes[l.thread]=","else if(false)notes[l.thread]="]],FEED,'W8'],
  ['no digest from an old board','waiting.mjs',[["else if(feed.stale)notes[l.thread]=","else if(false)notes[l.thread]="]],FEED,'W12'],
  ['an old board keeps the record','waiting.mjs',[["next:feed.stale?state:{lines,slots}","next:{lines,slots}"]],FEED,'W12'],
  ["the Mac's digest counts",'waiting.mjs',[[",mac=slot?feed.mac_digests?.[slot.key]:null;",",mac=null;"]],FEED,'W9'],
  ['lines the Mac told him of are not new','waiting.mjs',[["&&l.mac_notice_at===null",""]],FEED,'W9'],
  ['the retry wait','waiting.mjs',[["else if(mine?.at&&t-mine.at<retry)notes[l.thread]=","else if(false)notes[l.thread]="]],FEED,'W10'],
  ['a board from the future','waiting.mjs',[["if(data.written_at>now+300)return refuse(","if(false)return refuse("]],FEED,'W4'],
  ['an old board is old','waiting.mjs',[["stale:age>stale_after_minutes*60,","stale:false,"]],FEED,'W4'],
  ['the schema check','waiting.mjs',[["data.schema!==FEED_SCHEMA","false"]],FEED,'W3'],
  ['a chat name and id go together','waiting.mjs',[["&&(l.chat===null)===(l.chat_id===null)",""]],FEED,'W3'],
  ["the Mac's digest record is checked",'waiting.mjs',[["!SLOT.test(k)||",""]],FEED,'W3'],
  ['unknown settings','waiting.mjs',[["if(!(k in DEFAULTS))throw Error(","if(false)throw Error("]],FEED,'W13'],
  ['each digest time once','waiting.mjs',[["&&new Set(v).size===v.length",""]],FEED,'W13'],
  ['the 200-character digest','waiting.mjs',[["if(body.length<=200)break;","break;"]],FEED,'W14'],
  ['quest names','waiting.mjs',[[".split(' · ').at(-1).trim()",".trim()"]],FEED,'W14'],
  ['a private board','private-file.mjs',[["if(stat.mode&0o077)throw Error('It is open to other users.');",""]],FEED,'W2'],
  ['a plain file, not a link','private-file.mjs',[["if(!stat.isFile())throw Error('It is not a plain file.');",""]],FEED,'W2'],
  ['the host allowlist','push.mjs',[["return hosts.some(x=>x.startsWith('.')?h.endsWith(x)&&h.length>x.length:h===x);","return true;"]],PUSH,'P4'],
  ['a loose host match','push.mjs',[["x.startsWith('.')?h.endsWith(x)&&h.length>x.length:h===x","h.endsWith(x.replace(/^\\./,''))"]],PUSH,'P4'],
  ['no redirects','push.mjs',[["redirect:'error'","redirect:'follow'"]],PUSH,'P6'],
  ['the allowlist when sending','push.mjs',[["if(!allowedEndpoint(sub?.endpoint,hosts))return {outcome:'failed',detail:'endpoint not on the allowlist'};",""]],PUSH,'P6'],
  ['the RFC 8291 key info','push.mjs',[["Buffer.from('WebPush: info\\0')","Buffer.from('WebPush: info')"]],PUSH,'P1'],
  ['a one-hour token','push.mjs',[["exp:Math.floor(nowSeconds)+3600","exp:Math.floor(nowSeconds)+172800"]],PUSH,'P3'],
  ['one record only','push.mjs',[["if(plain.length+16>RECORD)throw Error('The alert is too long to send.');",""]],PUSH,'P7'],
  ['the trial sends nothing','waiting-alerts.mjs',[["if(cfg.mode==='shadow')result.outcome='shadow';","if(cfg.mode==='never')result.outcome='shadow';"]],ALERTS,'A1'],
  ['the digest time is recorded','waiting-alerts.mjs',[["next.slots[digest.slot]={outcome:result.outcome,at:t,tries:(before.tries??0)+1,lines:threads};",""]],ALERTS,'A1'],
  ['a sent digest marks its lines','waiting-alerts.mjs',[["if(delivered)for(const l of digest.lines)next.lines[l.thread].digest_at=t;",""]],ALERTS,'A2'],
  ['the pass lock','waiting-alerts.mjs',[["if(age<LOCK_STALE_MS)return null;",""]],ALERTS,'A6'],
  ['ended phones are skipped','waiting-alerts.mjs',[["phones=listed.filter(p=>!(record.gone[endpointId(p.endpoint)]>=p.added/1000));","phones=listed;"]],ALERTS,'A5'],
  ['an ended phone is recorded','waiting-alerts.mjs',[["if(r.outcome==='gone')record.gone[endpointId(p.endpoint)]=t;",""]],ALERTS,'A5'],
  ['an old board changes no record','waiting-alerts.mjs',[["if(!feed.available||feed.stale)return result;","if(!feed.available)return result;"]],ALERTS,'A7'],
  ['one test alert each 30 seconds','waiting-alerts.mjs',[["if(now()-lastTest<30_000)return {outcome:'failed',detail:'One test alert every 30 seconds.'};",""]],ALERTS,'A9'],
  ['the board needs pairing','server.mjs',[["if(!sessions.has(sid))return send(401,{error:'Pair this device to view Super.'});","if(!sessions.has(sid)&&req.url!=='/api/waiting')return send(401,{error:'Pair this device to view Super.'});"],
    ["const value=await waiting();if(!sessions.has(sid)||sessions.get(sid).expires<=now())return send(401,{error:'Session ended.'});","const value=await waiting();"]],GATE,'G1'],
  ['Disconnect turns alerts off','server.mjs',[["publish();alerts?.forget(deviceId(sid));return send(200,{paired:false}","publish();return send(200,{paired:false}"]],GATE,'G4'],
  ['a subscription is checked','push-store.mjs',[["const clean=checkSubscription(sub,hosts);","const clean=sub;"]],GATE,'G3'],
  ['the front passes the board','private-connector.mjs',[["routes.set('/api/waiting',['GET','/api/waiting']);",""]],GATE,'G6'],
  ["an alert opens only Super's pages",'ui/sw.js',[["const place=url=>typeof url==='string'&&/^\\/(mobile)?(#\\/[a-z]+)?$/.test(url)?url:HOME;","const place=url=>url||HOME;"]],PHONE,'U7'],
  ['permission first, from the tap','ui/waiting.js',[["const permission=await Notification.requestPermission();","const permission='granted';"]],PHONE,'U6'],
  ['an old board is said to be old','ui/waiting.js',[["if(view.stale)root.append(","if(false)root.append("]],PHONE,'U2'],
  ['the count on Needs me','ui/waiting.js',[["if(b){b.setAttribute('data-count',n?String(n):'');","if(false){b.setAttribute('data-count',n?String(n):'');"]],PHONE,'U4'],
  // Connecting without a code (owner-connect.test.mjs).
  ["the desktop's code is left as it was",'server.mjs',[["const token=randomBytes(32).toString('hex'),at=now();","used=true;const token=randomBytes(32).toString('hex'),at=now();"]],OWNER,'O1'],
  ['no session without a code on TCP','server.mjs',[["if(!sessions.has(sid))return send(401,{error:'Pair this device to view Super.'});","if(req.url==='/api/pair-owner')return server.ownerServer.emit('request',req,res);if(!sessions.has(sid))return send(401,{error:'Pair this device to view Super.'});"]],OWNER,'O1'],
  ['the code-free listener does one thing','server.mjs',[["if(req.url!=='/api/pair-owner'||req.method!=='POST')return send(405,","if(false)return send(405,"]],OWNER,'O2'],
  ['six a minute','server.mjs',[["if(ownerMade>=6)return send(429,","if(false)return send(429,"]],OWNER,'O3'],
  ['counted as requests arrive','server.mjs',[["ownerMade++;let size=0;","let size=0;"],["const token=randomBytes(32).toString('hex'),at=now();","ownerMade++;const token=randomBytes(32).toString('hex'),at=now();"]],OWNER,'O3'],
  ['the code-free listener is on its private socket','server.mjs',[["if(ownerSocket)await listenPrivateSocket(server.ownerServer,ownerSocket)","if(ownerSocket)await new Promise(r=>server.ownerServer.listen(0,'127.0.0.1',r))"]],OWNER,'O7'],
  ['none of the phone’s own headers','private-connector.mjs',[["if(isApi){if(req.headers.cookie)headers.cookie=req.headers.cookie;","if(isApi){for(const [k,v] of Object.entries(req.headers))if(k!=='host')headers[k]=v;if(req.headers.cookie)headers.cookie=req.headers.cookie;"]],OWNER,'O4'],
  ['code-free sign-in goes to its socket','private-connector.mjs',[["...(owner?{socketPath:ownerSocket}:{hostname:target.hostname,port:target.port||80})","hostname:target.hostname,port:target.port||80"]],OWNER,'O4'],
  ['only at the private address (front)','private-connector.mjs',[["if(secure&&ownerSocket)routes.set('/api/pair-owner',","if(ownerSocket)routes.set('/api/pair-owner',"]],OWNER,'O5'],
  ['the front listens only on its socket','private-connector.mjs',[["await listenPrivateSocket(createConnector({origin,allowedTailscaleLogin,ownerSocket,behindServe:true}),frontSocket);","createConnector({origin,allowedTailscaleLogin,ownerSocket,behindServe:true}).listen(0,'127.0.0.1');"]],OWNER,'O7'],
  // Reached the way tailscale serve reaches a Unix socket (Codex review 3, finding 1).
  ['started behind tailscale serve','private-connector.mjs',[["ownerSocket,behindServe:true}),frontSocket);","ownerSocket}),frontSocket);"]],OWNER,'O7'],
  ['through tailscale serve','private-connector.mjs',[["const hostRight=req=>behindServe?req.headers.host==='localhost'&&req.headers['x-forwarded-host']===front.host:req.headers.host===front.host;","const hostRight=req=>req.headers.host===front.host;"]],OWNER,'O12'],
  ['only his exact forwarded name','private-connector.mjs',[["req.headers['x-forwarded-host']===front.host","String(req.headers['x-forwarded-host']).includes(front.host)"]],OWNER,'O12'],
  ['Host: localhost behind serve','private-connector.mjs',[["behindServe?req.headers.host==='localhost'&&req.headers","behindServe?req.headers"]],OWNER,'O12'],
  ['a forwarded name is not enough without serve','private-connector.mjs',[["behindServe?req.headers.host==='localhost'&&req.headers['x-forwarded-host']===front.host:","behindServe||req.headers['x-forwarded-host']?req.headers['x-forwarded-host']===front.host:"]],OWNER,'O12'],
  ['ended sessions are cleared before connecting with no code','server.mjs',[["return send(413,{error:'Request too large.'});}\n      for(const [id,s]of sessions)if(s.expires<=now())sessions.delete(id);\n","return send(413,{error:'Request too large.'});}\n"]],OWNER,'O13'],
  ['a private socket folder','private-file.mjs',[["if(!d.isDirectory()||d.uid!==me||(d.mode&0o077))throw Error(","if(!d.isDirectory())throw Error("]],OWNER,'O11'],
  ['the socket is 0600','private-file.mjs',[["  chmodSync(path,0o600);\n",""]],OWNER,'O11'],
  ['only our own old socket is replaced','private-file.mjs',[["if(!old.isSocket()||old.uid!==me)throw Error(","if(false)throw Error("]],OWNER,'O11'],
  ['connects by itself','ui/app.js',[["content.replaceChildren();void ownerConnect(false);}","content.replaceChildren();}"]],OWNER,'O8'],
  ['no connecting by itself after Disconnect','ui/app.js',[["if(!asked&&(stayOut.get()||","if(!asked&&(false||"]],OWNER,'O9'],
  ['30 seconds between tries by itself','ui/app.js',[["||Date.now()-ownerTried<30_000))return;","))return;"]],OWNER,'O10'],
  ['only at the private address (page)','ui/app.js',[["const ownerPossible=()=>location.protocol==='https:';","const ownerPossible=()=>true;"]],OWNER,'O10'],
];

function run(cwd,file){
  return new Promise(resolve=>{
    const env={...process.env};delete env.NODE_TEST_CONTEXT;
    const child=spawn(process.execPath,['--test','--test-reporter=tap',join(cwd,'mobile','test',file)],{cwd,env,stdio:['ignore','pipe','pipe']});
    let out='';child.stdout.on('data',c=>out+=c);child.stderr.on('data',c=>out+=c);
    const timer=setTimeout(()=>child.kill('SIGKILL'),120_000);
    child.on('close',code=>{clearTimeout(timer);resolve({code,out});});
  });
}
async function pool(items,n,fn){const results=[];let next=0;await Promise.all(Array.from({length:n},async()=>{while(next<items.length){const i=next++;results[i]=await fn(items[i],i);}}));return results;}

test('plants · every rule switched off is caught by its law, on a copy',async t=>{
  const temp=mkdtempSync(join(tmpdir(),'super-waiting-plants-'));t.after(()=>rmSync(temp,{recursive:true,force:true}));
  const base=join(temp,'base');
  for(const part of ['mobile','cockpit/ui','cockpit/icons'])cpSync(join(ROOT,part),join(base,part),{recursive:true});
  // The copy itself, unplanted, passes every law file the plants use: a plant is caught for its own sake.
  for(const file of new Set(PLANTS.map(p=>p[3]))){const r=await run(base,file);assert.equal(r.code,0,`the unplanted copy fails ${file}:\n${r.out.slice(-1500)}`);}
  const outcomes=await pool(PLANTS,4,async([what,file,edits,lawFile,law],i)=>{
    const copy=join(temp,'plant-'+i);cpSync(base,copy,{recursive:true});
    const path=join(copy,'mobile',file);let source=readFileSync(path,'utf8');
    for(const [from,to] of edits){const n=source.split(from).length-1;if(n!==1)return `plant "${what}" finds its text ${n} times in ${file}, not once`;source=source.replace(from,()=>to);}
    writeFileSync(path,source);
    const r=await run(copy,lawFile);
    const caught=r.code!==0&&new RegExp(`^not ok \\d+ - ${law} · `,'m').test(r.out);
    rmSync(copy,{recursive:true,force:true});
    return caught?null:`plant "${what}" (${file}) is NOT caught by ${law}`;
  });
  const missed=outcomes.filter(Boolean);
  assert.deepEqual(missed,[],missed.join('\n'));
  t.diagnostic(`${PLANTS.length} plants, each caught by its law`);
});
