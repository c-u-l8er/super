import http from 'node:http';
import {fileURLToPath} from 'node:url';
// A local-only composition layer. Host access stays on the paired observer;
// this process never receives the Super runtime's command channel.
// Which side of the chain a request came from. The raw user agent is never
// logged; 'app' vs 'browser' is the only distinction that matters, because the
// two hold separate sessions and each needs its own pairing code.
const clientKind=ua=>!ua?'unknown':/Expo|okhttp|CFNetwork/i.test(ua)?'app':/Mozilla/i.test(ua)?'browser':'other';
export function createConnector({origin='http://127.0.0.1:4319',uiOrigin='http://localhost:3000',observerOrigin='http://127.0.0.1:4318',allowedTailscaleLogin,accessLog}={}){
 const front=new URL(origin),ui=new URL(uiOrigin),observer=new URL(observerOrigin);
 for(const endpoint of [ui,observer])if(endpoint.protocol!=='http:'||!['localhost','127.0.0.1'].includes(endpoint.hostname)||endpoint.pathname!=='/'||endpoint.search||endpoint.hash||endpoint.username||endpoint.password)throw Error('Only loopback HTTP origins are supported.');
 const secure=front.protocol==='https:';
 if(front.origin!==origin||front.username||front.password||(!secure&&!(front.protocol==='http:'&&['localhost','127.0.0.1'].includes(front.hostname))))throw Error('Invalid connector origin.');
 if(secure&&(!front.hostname.endsWith('.ts.net')||!allowedTailscaleLogin))throw Error('Private HTTPS requires an exact Tailscale origin and owner login.');
 const routes=new Map([['/api/observer/snapshot',['GET','/api/snapshot']],['/api/observer/pair',['POST','/api/pair']],['/api/observer/logout',['POST','/api/logout']]]);
 routes.set('/api/conversations',['GET','/api/conversations']);routes.set('/api/conversation',['POST','/api/conversation']);
 const companionAssets=new Map([['/conversations.js','/conversations.js'],['/mobile','/'],['/mobile/','/'],['/app.js','/app.js'],['/style.css','/style.css'],['/task-progress.js','/task-progress.js'],['/review-test-coverage.js','/review-test-coverage.js']]);
 for(const operation of ['snapshot','pair','logout'])routes.set('/api/'+operation,[operation==='snapshot'?'GET':'POST','/api/'+operation]);
 return http.createServer((req,res)=>{void handle(req,res).catch(()=>{if(!res.headersSent)res.writeHead(503);res.end()})});
 async function handle(req,res){
  // Opt-in and off by default. Method, path, status, elapsed, whether an owner
  // identity header was present, and app-or-browser. Never a cookie, a body,
  // a pairing code or the identity itself.
  if(accessLog){const startedAt=Date.now();res.on('finish',()=>{try{accessLog({
   at:new Date().toISOString(),method:req.method,path:String(req.url).split('?')[0].slice(0,64),
   status:res.statusCode,ms:Date.now()-startedAt,
   identity:secure?(req.headers['tailscale-user-login']?'present':'absent'):'n/a',
   client:clientKind(req.headers['user-agent'])})}catch{}})}
  const reject=(status,message)=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify({error:message}))};
  if(req.headers.host!==front.host||(req.headers.origin&&req.headers.origin!==front.origin))return reject(403,'Origin refused.');
  if(secure&&req.headers['tailscale-user-login']!==allowedTailscaleLogin)return reject(403,'Owner access required.');
  const isApi=req.url.startsWith('/api/');const route=routes.get(req.url)??(/^\/api\/screenshots\?task=[A-Za-z0-9_-]{1,100}$/.test(req.url)?['GET',req.url]:null);
  if(isApi&&(!route||req.method!==route[0]))return reject(405,'Observation only.');
  if(req.method==='POST'&&req.headers.origin!==front.origin)return reject(403,'Same-origin request required.');
  if(!isApi&&!['GET','HEAD'].includes(req.method))return reject(405,'Read-only interface.');
  const asset=companionAssets.get(req.url);if(asset&&req.method!=='GET')return reject(405,'Read-only interface.');
  const target=isApi||asset?observer:ui;
  const headers={host:target.host};
  // Vite uses Accept to distinguish a stylesheet from its JS import wrapper.
  // Preserve rendering headers without passing observer cookies to the UI.
  if(!isApi&&!asset)for(const name of ['accept','accept-language','rsc','next-router-state-tree','next-router-prefetch','next-url']){
   if(req.headers[name]!==undefined)headers[name]=req.headers[name];
  }
  if(isApi){if(req.headers.cookie)headers.cookie=req.headers.cookie;if(req.method==='POST'){headers.origin=observer.origin;headers['content-type']=req.headers['content-type']??''}}
  let body=Buffer.alloc(0);
  if(req.method==='POST'){for await(const chunk of req){body=Buffer.concat([body,chunk]);if(body.length>(req.url==='/api/conversation'?12000:1024))return reject(413,'Request too large.')}headers['content-length']=String(body.length)}
  const upstream=http.request({hostname:target.hostname,port:target.port||80,path:route?route[1]:asset||req.url,method:req.method,headers,timeout:5000},reply=>{const outgoing={...reply.headers,'cache-control':'no-store'};if(secure&&outgoing['set-cookie'])outgoing['set-cookie']=outgoing['set-cookie'].map(value=>/;\s*Secure(?:;|$)/i.test(value)?value:value+'; Secure');delete outgoing['transfer-encoding'];res.writeHead(reply.statusCode??502,outgoing);reply.pipe(res)});
  upstream.on('timeout',()=>upstream.destroy());upstream.on('error',()=>{if(!res.headersSent)reject(503,'Local host connection unavailable.');else res.destroy()});
  upstream.end(body);
 }
}
if(process.argv[1]===fileURLToPath(import.meta.url)){
 const origin=process.env.SUPER_MOBILE_PRIVATE_ORIGIN,allowedTailscaleLogin=process.env.SUPER_MOBILE_TAILSCALE_LOGIN;
 if(!origin||!allowedTailscaleLogin)throw Error('Configure the exact private origin and owner identity.');
 createConnector({origin,allowedTailscaleLogin}).listen(4320,'127.0.0.1',()=>console.log('Private mobile connector listening on loopback.'));
}
