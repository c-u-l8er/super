/* The Mobile page: it exists, it is reachable from the rail and the menu, and
   it reports the companion's real state rather than a hopeful one. */
import {spawn} from 'node:child_process';
import {mkdtempSync,writeFileSync,mkdirSync,readFileSync} from 'node:fs';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const testRoot=process.env.DEVELOPMENT_TEST_ROOT??mkdtempSync('/tmp/super-mobile-page-');
mkdirSync(testRoot,{recursive:true});
const temp=mkdtempSync(resolve(testRoot,'mobile-page-'));
const pairFile=resolve(temp,'code');
const port=Number(process.env.MOBILE_SMOKE_PORT??4479);
const gatewayPort=Number(process.env.MOBILE_SMOKE_GATEWAY_PORT??4331);
const base=`http://127.0.0.1:${port}`;
const shots=process.env.MOBILE_SCREENSHOTS;
// Most desktops are started without the companion. The page has to say so
// plainly rather than looking broken or, worse, looking ready.
const off=process.env.MOBILE_SMOKE_DISABLED==='1';
// A world of its own: this must not take the lock a real desktop is holding.
const driver=spawn('tauri-driver',['--port',String(port),'--native-port',String(port+1),'--native-driver','/usr/bin/WebKitWebDriver'],
  {cwd:root,detached:true,stdio:['ignore','pipe','pipe'],env:{...process.env,
    GDK_BACKEND:'x11',XDG_DATA_HOME:temp+'/data',AMPD_DIR:root+'/ampd',
    SUPER_WORLD_MODE:'ephemeral',SUPER_COCKPIT_FIXTURE:'0',SUPER_COCKPIT_PANE:'0',
    WEBKIT_DISABLE_COMPOSITING_MODE:'1',
    ...(off?{}:{
      SUPER_MOBILE_GATEWAY:root+'/mobile/server.mjs',
      SUPER_MOBILE_NODE:process.env.SUPER_MOBILE_NODE??process.execPath,
      SUPER_MOBILE_PAIR_FILE:pairFile,
      SUPER_MOBILE_PORT:String(gatewayPort)})}});
let session=null,log='';
driver.stdout.on('data',b=>log=(log+b).slice(-6000));driver.stderr.on('data',b=>log=(log+b).slice(-6000));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function wd(method,path,body){
  const r=await fetch(base+path,{method,headers:{'content-type':'application/json'},
    body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(45000)});
  const j=await r.json();if(!r.ok||j.value?.error)throw Error(JSON.stringify(j));return j.value;}
const script=(s,args=[])=>wd('POST',`/session/${session}/execute/sync`,{script:s,args});
async function until(fn,ms=20000){const end=Date.now()+ms;while(Date.now()<end){const v=await fn().catch(()=>null);if(v)return v;await sleep(200);}throw Error('timed out');}
async function shot(name){if(!shots)return;mkdirSync(shots,{recursive:true});
  writeFileSync(resolve(shots,name+'.png'),Buffer.from(await wd('GET',`/session/${session}/screenshot`),'base64'));}
let checks=0;const check=(name,ok)=>{assert.ok(ok,name);checks++;console.log('held '+name);};
try{
  await until(async()=>{try{await fetch(base+'/status');return true;}catch{return false;}});
  session=(await wd('POST','/session',{capabilities:{alwaysMatch:{'tauri:options':{application:root+'/cockpit/target/release/super-cockpit'}}}})).sessionId;
  await until(()=>script('return !!document.getElementById("app-navigation")'));

  check('the Mobile page is a declared screen',
    await until(()=>script('return !!document.querySelector(\'[data-nav="mobile"]\')')));
  check('it is reachable from the header menu',
    await script('return [...document.querySelectorAll("#desktop-menus button")].some(b=>b.textContent.includes("Pair a phone"))'));
  check('the page finder can find it',
    await script('return !!document.querySelector(\'[data-nav="mobile"]\')'));

  // Through the rail, the way a person would.
  await script('document.querySelector(\'[data-rail-mode="runtime"]\').click()');
  await sleep(300);
  await script('document.querySelector(\'[data-nav="mobile"]\').click()');
  const page=await until(()=>script('const p=document.querySelector(\'[data-screen="mobile"]\');return p&&!p.hidden?p.textContent:null;'));
  check('the rail link opens it',page.includes('Read this runtime from your phone')||page.includes('companion'));
  check('it states the companion cannot act',/cannot approve|never do/i.test(page));

  const status=await until(()=>script('return window.__TAURI__.core.invoke("mobile_status").then(v=>({v})).catch(e=>({e:String(e)}))').then(r=>r?.v?{...r.v,__ok:true}:null));
  if(off){
    check('mobile_status answers even with no companion',status.__ok===true);
    check('it reports the companion not enabled',status.enabled===false);
    check('it offers no code',status.code===null);
    const quiet=await until(()=>script('return document.querySelector("[data-mobile-status]").textContent||null'));
    check('the page says Not running rather than looking ready',/Not running/.test(quiet));
    check('and it does not show a countdown',!/left/.test(quiet));
    check('the instructions are still there to act on',
      (await script('return document.querySelector(\'[data-screen="mobile"]\').textContent')).includes('start-local.sh'));
    await shot('mobile-page-disabled');
    console.log(`\nmobile page (companion off): ${checks} held · 0 failed`);
  } else {
  check('mobile_status is granted to this webview and answers',status.__ok===true);
  check('it reports the companion enabled',status.enabled===true);
  check('it reports the observer alive',status.alive===true);
  check('it supplies a code in four-character groups',
    typeof status.code==='string'&&/^[0-9a-f]{4}( [0-9a-f]{4}){3}\n/.test(status.code));
  check('the grouped code is the code on disk',
    status.code.replace(/\s+/g,'')===readFileSync(pairFile,'utf8').trim());
  check('it reports time remaining inside the ten minutes',
    Number.isInteger(status.seconds_left)&&status.seconds_left>0&&status.seconds_left<=600);

  await until(()=>script('return document.querySelector("[data-mobile-status] .mobile-code")?document.querySelector("[data-mobile-status]").textContent:null'));
  const live=await script('return document.querySelector("[data-mobile-status]").textContent');
  check('the page paints the running state and the code',/Running/.test(live)&&/left/.test(live));
  check('the painted code matches the one on disk',
    live.replace(/\s+/g,'').includes(readFileSync(pairFile,'utf8').trim()));
  check('the code is offered as a scannable square',
    Number.isInteger(status.qr?.width) && status.qr.width >= 21 &&
    typeof status.qr.modules === 'string' && status.qr.modules.length === status.qr.width ** 2);
  check('the square carries the bare code, never a URL',
    !/https?:|:\/\//.test(JSON.stringify(status.qr)));
  check('the page draws it',
    await script('const s=document.querySelector("[data-mobile-status] svg.mobile-qr");return !!s&&s.querySelector("path").getAttribute("d").length>100'));
  check('and offers a copy that drops the reading spaces',
    await script('return !!document.querySelector("[data-mobile-status] .mobile-copy")'));
  await shot('mobile-page');

  // The page must not become a control surface by accident.
  // Pair a device for real, and see whether the desktop notices.
  check('nothing is connected before anything pairs',Array.isArray(status.devices)&&status.devices.length===0);
  const paired=await fetch(`http://127.0.0.1:${gatewayPort}/api/pair`,{method:'POST',
    headers:{host:`127.0.0.1:${gatewayPort}`,origin:`http://127.0.0.1:${gatewayPort}`,
             'content-type':'application/json','user-agent':'Expo/57 CFNetwork/3826 Darwin/24.6.0'},
    body:JSON.stringify({code:readFileSync(pairFile,'utf8').trim()})});
  check('the gateway accepted the pairing',paired.status===200);
  const after=await until(async()=>{
    const r=await script('return window.__TAURI__.core.invoke("mobile_status").then(v=>({v})).catch(()=>null)');
    return r?.v?.devices?.length?r.v:null;});
  const [device]=after.devices;
  check('the desktop shows the connected device',after.devices.length===1);
  check('it knows it is the app, not a browser',device.kind==='app');
  check('it is named by a short derived identifier',typeof device.id==='string'&&device.id.length===6&&/^[0-9a-f]+$/.test(device.id));
  check('it reports when it paired and last read',Number.isInteger(device.paired_at)&&Number.isInteger(device.last_seen)&&device.expires>device.paired_at);
  // The whole point of deriving the identifier.
  const cookie=String(paired.headers.get('set-cookie')??'').replace(/^super_mobile=/,'').split(';')[0];
  const payload=JSON.stringify(after);
  check('no session token reaches the desktop',cookie.length>32&&!payload.includes(cookie));
  check('and no user agent does either',!/CFNetwork|Darwin|Expo\//.test(payload));
  await until(()=>script('return /connected/.test(document.querySelector("[data-mobile-status]").textContent)?1:null'));
  const painted=await script('return document.querySelector("[data-mobile-status]").textContent');
  check('the page says how many are connected',/Running · 1 connected/.test(painted));
  check('and lists the device with when it last read',/Super Mobile/.test(painted)&&/last read/.test(painted));
  check('a spent one-use code stops being offered',
    (await script('return window.__TAURI__.core.invoke("mobile_status").then(v=>v.code===null&&v.reason==="used")'))===true);
  await until(()=>script('return /has been used/.test(document.querySelector("[data-mobile-status]").textContent)?1:null'));
  check('and the page says so instead of showing a countdown',
    !/left/.test(await script('return document.querySelector("[data-mobile-status]").textContent')));
  await shot('mobile-page-connected');

  const spent=readFileSync(pairFile,'utf8').trim();
  // The way back. Before this button the only route out of a spent or expired
  // code was restarting Super, which revokes every session to issue one code —
  // so a phone that disconnected itself could not reconnect at all.
  check('a spent code offers a new one',
    (await script('return document.querySelector(".mobile-new-code")?1:null'))===1);
  check('and says it will not disconnect anyone',
    /does not disconnect/.test(await script('return document.querySelector("[data-mobile-status]").textContent')));
  await script('document.querySelector(".mobile-new-code").click(); return 1');
  await until(()=>script('return window.__TAURI__.core.invoke("mobile_status").then(v=>v.code?1:null)'));
  const renewed=await script('return window.__TAURI__.core.invoke("mobile_status")');
  check('the companion issues a fresh code without restarting',
    typeof renewed.code==='string'&&renewed.reason===null);
  check('the fresh code is the one now on disk',
    renewed.code.replace(/\s+/g,'')===readFileSync(pairFile,'utf8').trim());
  check('and it is not the code that was just spent',renewed.code.replace(/\s+/g,'')!==spent);
  check('the device that was already paired is still connected',
    Array.isArray(renewed.devices)&&renewed.devices.length===1);
  const stillReading=await fetch(`http://127.0.0.1:${gatewayPort}/api/snapshot`,
    {headers:{host:`127.0.0.1:${gatewayPort}`,cookie:`super_mobile=${cookie}`}});
  check('and its session still reads',stillReading.status===200);
  await until(()=>script('return /left/.test(document.querySelector("[data-mobile-status]").textContent)?1:null'));
  check('the page shows the new code with its countdown',
    /left/.test(await script('return document.querySelector("[data-mobile-status]").textContent')));
  await shot('mobile-page-renewed');

  const acl=await script('return window.__TAURI__.core.invoke("mobile_status",{}).then(()=>"ok").catch(e=>String(e))');
  check('mobile_status takes no argument that could steer it',acl==='ok');
  console.log(`\nmobile page: ${checks} held · 0 failed`);
  }
}finally{
  if(session)await wd('DELETE',`/session/${session}`).catch(()=>{});
  try{process.kill(-driver.pid,'SIGTERM');}catch{}
  if(process.exitCode)console.error(log.slice(-1500));
}
