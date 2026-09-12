// Same-process Super/road integration, in an ephemeral runtime world.
import {spawn, spawnSync} from 'node:child_process';
import {resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
const ROOT=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const temporary=mkdtempSync(resolve(tmpdir(),'super-road-test-'));
const base='http://127.0.0.1:4487';
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
let session, held=0;
const check=(name, ok)=>{if(!ok)throw Error(name);held++;console.log(`held · ${name}`);};
const driver=spawn('tauri-driver',['--port','4487','--native-port','4488','--native-driver','/usr/bin/WebKitWebDriver'],{
  detached:true,stdio:['ignore','inherit','inherit'],env:{...process.env,GDK_BACKEND:'x11',
    AMPD_DIR:`${ROOT}/ampd`,SUPER_WORLD_MODE:'ephemeral',SUPER_COCKPIT_FIXTURE:'1',SUPER_COCKPIT_PANE:'0',SUPER_ROAD:'0'}});
const stop=()=>{try{process.kill(-driver.pid,'SIGKILL');}catch{}};
process.on('exit',()=>{stop();rmSync(temporary,{recursive:true,force:true});});
async function wd(method,path,body){
  const r=await fetch(base+path,{method,headers:{'content-type':'application/json'},body:body===undefined?undefined:JSON.stringify(body)});
  const j=await r.json();if(j.value?.error)throw Error(j.value.message);return j.value;
}
const sc=script=>wd('POST',`/session/${session}/execute/sync`,{script,args:[]});
const select=handle=>wd('POST',`/session/${session}/window`,{handle});
async function click(selector){const e=await wd('POST',`/session/${session}/element`,{using:'css selector',value:selector});
  await wd('POST',`/session/${session}/element/${Object.values(e)[0]}/click`,{});}
async function until(fn){for(let i=0;i<80;i++){const v=await fn();if(v)return v;await sleep(150);}throw Error('timed out waiting for integration state');}
async function surface(label){for(const h of await wd('GET',`/session/${session}/window/handles`)){
  await select(h);if(await sc(`return window.__TAURI_INTERNALS__?.metadata?.currentWebview?.label === ${JSON.stringify(label)};`))return h;}return null;}
const denied=(command,args={})=>sc(`return window.__TAURI__.core.invoke(${JSON.stringify(command)},${JSON.stringify(args)}).then(()=>false,e=> /not allowed|denied|forbidden/i.test(String(e)));`);
function roadWindow(){
  const list=spawnSync('xprop',['-root','_NET_CLIENT_LIST'],{encoding:'utf8'}).stdout||'';
  return [...list.matchAll(/0x[0-9a-f]+/g)].map(m=>m[0]).find(id=>/Super \(CD\).*road/.test(spawnSync('xprop',['-id',id,'WM_NAME'],{encoding:'utf8'}).stdout||''));
}
try{
  await until(async()=>{try{await fetch(base+'/status');return true;}catch{return false;}});
  const created=await wd('POST','/session',{capabilities:{alwaysMatch:{'tauri:options':{application:`${ROOT}/cockpit/target/release/super-cockpit`}}}});
  session=created.sessionId;
  const cockpit=await until(()=>surface('main'));
  await until(()=>sc("return !!document.getElementById('open-road')?.onclick;"));
  await click('#open-road');
  let road=await until(()=>surface('cd-road'));
  await until(()=>sc("return document.body.dataset.ready === '1';"));
  await sc("window.__roadErrors=[];window.addEventListener('error',e=>window.__roadErrors.push(e.message));window.addEventListener('unhandledrejection',e=>window.__roadErrors.push(String(e.reason)));return true;");
  check('cockpit opens a live road in the same application session',!!road && road!==cockpit);
  check('road recognizes its Super host',await sc("return !document.getElementById('cockpit').hidden;"));
  const generation=await sc('return window.__ROAD_GENERATION;');
  check('road cannot submit cockpit intents',await denied('intent'));
  check('road cannot open terminals',await denied('terminal_surface',{open:true}));
  check('road cannot choose repositories',await denied('choose_repository'));
  await click('#fullscreen');
  await until(()=>sc("return window.__apply('fullscreen').then(r=>r.ok&&r.result.fullscreen);"));
  await sleep(700);
  check('road enters native fullscreen inside Super',true);
  const start=await sc('return window.__roadScene.snapshot();');
  check('camera starts before the entrance gantry',start.position[2]>start.entranceZ);
  await click('#entrance');
  await until(()=>sc("return window.__roadScene.snapshot().phase==='driving' && window.__roadScene.snapshot().position[2]<window.__roadScene.snapshot().entranceZ;"));
  check('entrance drives through the gantry into the lane',true);
  await click('#lane');
  await until(()=>sc("return window.__roadScene.snapshot().phase==='ramp';"));
  check('lane switch travels on a ramp with no live pane',await sc("return window.__apply('status').then(r=>!r.result.present);"));
  check('driving cannot interrupt a ramp',await sc("return window.__roadScene.drive(144).then(r=>r===false);"));
  await until(()=>sc("return window.__roadScene.snapshot().lane==='summaries'&&window.__roadScene.snapshot().phase==='driving';"));
  check('ramp enters the named destination lane',await sc("return Math.abs(window.__roadScene.snapshot().position[0]-1200)<.01&&document.getElementById('enter').textContent.includes('DIGEST');"));
  if(process.argv[2])check('capture destination lane',spawnSync('import',['-window',roadWindow(),process.argv[2].replace(/\.png$/,'-summaries.png')]).status===0);
  await click('#enter');
  const digest=await until(()=>sc("return window.__apply('status').then(r=>r.ok&&r.result.present?r.result:null);"));
  const digestPane=await until(()=>surface(digest.pane_label));
  await until(()=>sc("return document.body.dataset.ready==='1';"));
  check('destination entrance opens Digest',await sc("return window.__paneProbe().package==='digest';"));
  await select(road);
  check('destination lane sign aligns with the native read frame',await sc("const a=window.__roadScene.snapshot().readRect,b=document.getElementById('readframe').getBoundingClientRect();return ['x','y','width','height'].every(k=>Math.abs(a[k]-b[k])<2);"));
  await click('#leave');
  await until(()=>sc("return window.__roadScene.snapshot().phase==='driving';"));
  check('leaving Digest restores its own lane',await sc("return window.__roadScene.snapshot().lane==='summaries'&&Math.abs(window.__roadScene.snapshot().position[0]-1200)<.01;"));
  await click('#lane');
  await until(()=>sc("return window.__roadScene.snapshot().lane==='documents'&&window.__roadScene.snapshot().phase==='driving';"));
  check('reverse ramp returns to Documents',await sc("return Math.abs(window.__roadScene.snapshot().position[0])<.01;"));
  const beforeKey=await sc('return window.__roadScene.snapshot().position[2];');
  await sc("window.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowUp'})); return true;");
  await until(()=>sc(`return window.__roadScene.snapshot().phase==='driving' && window.__roadScene.snapshot().position[2]<${beforeKey};`));
  check('arrow navigation advances along the forward axis',true);
  const parked=await sc('return window.__roadScene.snapshot().position[2];');
  if(process.argv[2]){
    const id=roadWindow();
    if(!id)throw Error('road X11 window not found');
    check('capture integrated road',spawnSync('import',['-window',id,process.argv[2]]).status===0);
  }
  await click('#sign-notes');
  check('camera approaches before a pane exists',await sc("return window.__apply('status').then(r=>!r.result.present&&window.__roadScene.snapshot().phase==='approaching');"));
  const live=await until(()=>sc("return window.__apply('status').then(r=>r.ok&&r.result.present?r.result:null);"));
  const pane=await until(()=>surface(live.pane_label));
  check('the integrated road opens its packaged app pane',!!pane);
  check('app pane cannot submit cockpit intents',await denied('intent'));
  check('app pane cannot open additional roads',await denied('open_road'));
  check('app pane cannot switch to the cockpit',await denied('road_cockpit',{generation}));
  await select(road);await click('#cockpit');
  await until(()=>sc("return window.__apply('status').then(r=>r.ok&&!r.result.present);"));
  check('return sign tears down the live pane',true);
  await until(()=>sc("return window.__apply('fullscreen').then(r=>r.ok&&!r.result.fullscreen);"));
  check('return sign leaves fullscreen',true);
  check('leaving restores the saved lane position',await sc(`return window.__roadScene.snapshot().phase==='driving'&&Math.abs(window.__roadScene.snapshot().position[2]-(${parked}))<.01;`));
  await select(cockpit);
  check('cockpit cannot invoke road pane commands',await denied('road_promote'));
  await click('#open-road');
  check('opening again reuses the existing road',await surface('cd-road')===road);
  // Close the actual desktop window. WebKitDriver DELETE/window closes its
  // browsing context, leaving Tauri's native window alive without a renderer.
  const closing=roadWindow();if(!closing)throw Error('no road window to close');
  const closer=resolve(temporary,'close-window');
  if(spawnSync('cc',[`${ROOT}/tools/close-test-window.c`,'-lX11','-o',closer]).status!==0)
    throw Error('could not build the native close helper');
  if(spawnSync(closer,[closing]).status!==0)throw Error('native road close failed');
  await until(async()=>!(await wd('GET',`/session/${session}/window/handles`)).includes(road));
  await select(cockpit);await click('#open-road');
  console.log('reopening the closed road');
  road=await until(()=>surface('cd-road'));
  await until(()=>sc("return document.body.dataset.ready==='1';"));
  check('reopening mints a new road generation',await sc(`return window.__ROAD_GENERATION>${generation};`));
  check('old road generation is refused',await sc(`return window.__apply('place',{dash:1,side:1},{generation:${generation}}).then(r=>!r.ok);`));
  console.log(`Super road: ${held} held · 0 failed`);
}catch(e){console.error(`FAILED · ${e.message}`);try{console.error(await sc('return {text:document.body.innerText.slice(-1800),camera:window.__roadScene?.snapshot(),errors:window.__roadErrors};'));}catch{}process.exitCode=1;}
finally{try{if(session)await wd('DELETE',`/session/${session}`);}catch{}stop();}
