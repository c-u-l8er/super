import http from 'node:http';
import {createHash, randomBytes, randomUUID, timingSafeEqual} from 'node:crypto';
import {readFile, rename, writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {createInterface} from 'node:readline';
const assets = new Map([['/', ['ui/index.html','text/html']], ['/app.js',['ui/app.js','text/javascript']], ['/style.css',['ui/style.css','text/css']], ['/task-progress.js',['../cockpit/ui/task-progress.js','text/javascript']], ['/review-test-coverage.js',['../cockpit/ui/review-test-coverage.js','text/javascript']]]);
const equal=(a,b)=>typeof a==='string'&&Buffer.byteLength(a)===Buffer.byteLength(b)&&timingSafeEqual(Buffer.from(a),Buffer.from(b));
// App or browser, and nothing finer. The two hold separate sessions and each
// needs its own code, which is the only distinction worth reporting; the raw
// user agent is a fingerprint and is never kept.
const kindOf=ua=>!ua?'unknown':/Expo|okhttp|CFNetwork/i.test(ua)?'app':/Mozilla/i.test(ua)?'browser':'other';
// Distinguishes two devices without exposing either session. One way, truncated.
const deviceId=token=>createHash('sha256').update('super-mobile-device:'+token).digest('hex').slice(0,6);
export function createGateway({snapshot, pairingCode, origin, now=Date.now, onDevices}) {
  const publicURL=new URL(origin);
  if(publicURL.origin!==origin || (publicURL.protocol!=='https:' && !(publicURL.protocol==='http:'&&['localhost','127.0.0.1'].includes(publicURL.hostname)))) throw Error('Use HTTPS, or loopback HTTP for development.');
  let pairUntil=now()+600_000, used=false, failures=0, windowEnd=now()+60_000;
  const sessions=new Map(), secure=publicURL.protocol==='https:';
  // Who is reading, for the desktop to show. Identifiers are derived from the
  // session one way; no token, cookie or user agent leaves this map.
  let published='';
  const devices=()=>[...sessions].map(([token,s])=>({id:deviceId(token),kind:s.kind,paired_at:s.pairedAt,last_seen:s.lastSeen,expires:s.expires}));
  const publish=()=>{
    if(!onDevices)return;
    // `used` travels with the list because a one-use code that has been spent
    // must stop being offered; a desktop still showing it is showing a lie.
    const state={devices:devices(),code_used:used},line=JSON.stringify(state);
    if(line===published)return;               // only when it actually changed
    published=line;
    try{onDevices(state);}catch{/* reporting must never break a read */}
  };
  const cookie=(v,age=28800)=>`super_mobile=${v}; HttpOnly; SameSite=Strict; Path=/; Max-Age=${age}${secure?'; Secure':''}`;
  const server=http.createServer({maxHeaderSize:8192,requestTimeout:5000,headersTimeout:5000},async(req,res)=>{
    const send=(status,data,headers={})=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer','Content-Security-Policy':"default-src 'self'; connect-src 'self'; script-src 'self'; style-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",...headers});res.end(typeof data==='string'?data:JSON.stringify(data));};
    try {
      if(req.headers.host!==publicURL.host || (req.headers.origin&&req.headers.origin!==origin))return send(403,{error:'Connection origin refused.'});
      if(req.method==='POST'&&req.headers.origin!==origin)return send(403,{error:'A same-origin request is required.'});
      if(req.method==='GET'&&assets.has(req.url)){
        const [path,type]=assets.get(req.url);return send(200,await readFile(new URL(path,import.meta.url),'utf8'),{'Content-Type':type+'; charset=utf-8'});
      }
      const sid=(req.headers.cookie??'').split(';').map(x=>x.trim()).find(x=>x.startsWith('super_mobile='))?.slice(13);
      for(const [id,s]of sessions)if(s.expires<=now())sessions.delete(id);
      publish();
      if(req.url==='/api/pair'&&req.method==='POST'){
        if(req.headers['content-type']!=='application/json')return send(415,{error:'JSON required.'});
        if(now()>windowEnd){windowEnd=now()+60_000;failures=0;}
        if(failures>=10)return send(429,{error:'Too many attempts. Try again in a minute.'});
        const chunks=[];let size=0;for await(const chunk of req){size+=chunk.length;if(size>1024){send(413,{error:'Request too large.'});req.destroy();return;}chunks.push(chunk);}
        let body;try{body=JSON.parse(Buffer.concat(chunks).toString());}catch{return send(400,{error:'Invalid JSON.'});}
        if(!body||typeof body!=='object'||Array.isArray(body)||Object.keys(body).some(k=>k!=='code'))return send(400,{error:'A pairing code is required.'});
        if(used||now()>pairUntil||!equal(body.code,pairingCode)){failures++;return send(401,{error:'Pairing code invalid, used, or expired. Ask the desktop for a fresh code.'});}
        used=true;const token=randomBytes(32).toString('hex');const at=now();
        sessions.set(token,{expires:at+28_800_000,pairedAt:at,lastSeen:at,kind:kindOf(req.headers['user-agent'])});
        publish();
        return send(200,{paired:true},{'Set-Cookie':cookie(token)});
      }
      if(!sessions.has(sid))return send(401,{error:'Pair this device to view Super.'});
      sessions.get(sid).lastSeen=now();publish();
      if(req.url==='/api/logout'&&req.method==='POST'){sessions.delete(sid);publish();return send(200,{paired:false},{'Set-Cookie':cookie('',0)});}
      if(req.url==='/api/snapshot'&&req.method==='GET'){
        let timer;try{const value=await Promise.race([snapshot(),new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('timeout')),2500);})]);
          // Recheck revocation and expiry after waiting for the host.
          if(!sessions.has(sid)||sessions.get(sid).expires<=now())return send(401,{error:'Session ended.'});
          return send(200,{schema:'super-mobile-observation@1',mode:'read-only',...value});
        }finally{clearTimeout(timer);}
      }
      return send(405,{error:'This companion provides observation only.'});
    }catch{return send(503,{error:'Host unavailable. Reconnect to see current state.'});}
  });
  server.maxConnections=32;server.keepAliveTimeout=3000;
  /**
   * Replace the one-use code without restarting.
   *
   * A code was minted once per launch, so spending it — by pairing, or by a
   * device disconnecting itself — left no way back except restarting the host,
   * which revokes every other session as collateral. Renewal is the narrow
   * thing that was actually wanted: a new code, a fresh ten minutes, and every
   * existing session left exactly as it was.
   *
   * Reachable only from the process that spawned this one, over its stdin
   * pipe. Nothing on the network can call it, and the code itself is generated
   * here rather than handed in.
   */
  server.renewPairing=next=>{
    if(typeof next!=='string'||!/^[0-9a-f]{32,128}$/.test(next))return false;
    pairUntil=now()+600_000;used=false;failures=0;windowEnd=now()+60_000;pairingCode=next;
    publish();
    return true;
  };
  return server;
}
if(process.argv[1]===fileURLToPath(import.meta.url)){
  const port=Number(process.env.SUPER_MOBILE_PORT??4318);
  if(!Number.isInteger(port)||port<1024||port>65535)throw Error('Invalid mobile port.');
  const origin=process.env.SUPER_MOBILE_ORIGIN??`http://127.0.0.1:${port}`;
  const pairFile=process.env.SUPER_MOBILE_PAIR_FILE;
  if(!pairFile?.startsWith('/'))throw Error('Set SUPER_MOBILE_PAIR_FILE to a new absolute path.');
  const code=randomBytes(24).toString('hex');
  let pending=null;
  const lines=createInterface({input:process.stdin});
  lines.on('line',line=>{try{
    const r=JSON.parse(line);
    // The desktop asking for a fresh code. The code is generated here and
    // written to the 0600 file the desktop already reads; it never travels
    // back up this pipe, and nothing is logged.
    if(r.operation==='renew'){void renew();return;}
    if(pending?.id===r.id){pending.resolve(r.snapshot);clearTimeout(pending.timer);pending=null;}
  }catch{}});
  const snapshot=()=>{
    if(pending)return pending.promise;
    const id=randomUUID();let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});
    const timer=setTimeout(()=>{pending=null;reject(Error('Host timeout'));},2000);
    pending={id,promise,resolve,reject,timer};process.stdout.write(JSON.stringify({operation:'snapshot',id})+'\n');return promise;
  };
  // Who is paired, for the desktop to show. A sibling of the pairing file, so
  // it inherits that directory's privacy and lifetime; written then renamed so
  // a reader never sees half of one. It carries derived identifiers only — no
  // token, no cookie, no user agent.
  const devicesFile=pairFile+'.devices.json';
  let writing=Promise.resolve();
  const onDevices=state=>{
    const body=JSON.stringify({schema:'super-mobile-devices@1',updated:Date.now(),...state});
    writing=writing.then(async()=>{
      await writeFile(devicesFile+'.new',body,{mode:0o600});
      await rename(devicesFile+'.new',devicesFile);
    }).catch(()=>{});
  };
  const server=createGateway({snapshot,pairingCode:code,origin,onDevices});
  // Exclusive creation refuses old files and symlinks; never log the code.
  await writeFile(pairFile,code+'\n',{mode:0o600,flag:'wx'});
  // Written then renamed, like the devices file beside it, so a desktop
  // reading it never sees half a code — and so the file's mtime, which is what
  // the desktop ages the code by, moves with the code it holds.
  const renew=async()=>{
    const next=randomBytes(24).toString('hex');
    try{
      await writeFile(pairFile+'.next',next+'\n',{mode:0o600});
      await rename(pairFile+'.next',pairFile);
      server.renewPairing(next);
    }catch{/* a code that could not be written is not a code */}
  };
  lines.on('close',()=>{server.closeAllConnections();server.close();process.exit(0);});
  server.listen(port,'127.0.0.1',()=>process.stderr.write(`Super mobile observer: ${origin}; one-use pairing code in ${pairFile} (10 minutes).\n`));
}
