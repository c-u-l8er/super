// Real Android display capture through Super's native task controls, isolated test records.
import {open} from './lib/cockpit-control.mjs';
import {createServer} from 'node:http';
import {execFileSync} from 'node:child_process';
import {mkdirSync,writeFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const out=process.env.SUPER_VISUAL_EVIDENCE_DIR||'/tmp/super-emulator-evidence';mkdirSync(out,{recursive:true});
const adb=process.env.ADB||'/home/travis/.local/opt/android-sdk/platform-tools/adb',serial=process.env.SUPER_TEST_EMULATOR||'emulator-5554';
assert.match(serial,/^emulator-\d{1,5}$/);
const command=(...args)=>execFileSync(adb,['-s',serial,...args],{encoding:'utf8',timeout:15000});
const server=createServer((req,res)=>{const after=req.url.includes('after');res.setHeader('content-type','text/html');res.end(`<html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head><body style="margin:0;background:${after?'#123d30':'#582329'};color:white;font:20px sans-serif;padding:24px"><h1>${after?'After: named machines':'Before: unnamed machines'}</h1><p>${after?'FreeBSD / cd-floor-01':'Machine 1'}</p><p>${after?'Proxmox / Locuchest':'Machine 2'}</p><p>Android capture test fixture</p></body></html>`);});
await new Promise((r,j)=>{server.once('error',j);server.listen(0,'127.0.0.1',r)});const port=server.address().port,url=`http://127.0.0.1:${port}/`;let app,ws;let debugPort;
const checks=[];
try{
 command('reverse',`tcp:${port}`,`tcp:${port}`);
 debugPort=command('forward','tcp:0','localabstract:chrome_devtools_remote').trim();
 command('shell','am','start','-a','android.intent.action.VIEW','-d',url+'before','com.android.chrome');
 app=await open({port:4607});const page=c=>app.page(c);
 let tab;
 await app.until(async()=>{try{tab=(await(await fetch(`http://127.0.0.1:${debugPort}/json/list`,{signal:AbortSignal.timeout(2000)})).json()).find(t=>t.url.startsWith(url));return !!tab;}catch{return false;}},15000,'Android fixture tab');
 ws=new WebSocket(tab.webSocketDebuggerUrl);await new Promise((r,j)=>{ws.onopen=r;ws.onerror=j;});let seq=0;const pending=new Map();
 ws.onmessage=e=>{const m=JSON.parse(e.data),p=pending.get(m.id);if(p){pending.delete(m.id);m.error?p.reject(Error(m.error.message)):p.resolve(m.result);}};
 const call=(method,params={})=>new Promise((resolve,reject)=>{const id=++seq;const timer=setTimeout(()=>{pending.delete(id);reject(Error('Chrome did not answer '+method));},10000);pending.set(id,{resolve:v=>{clearTimeout(timer);resolve(v);},reject:e=>{clearTimeout(timer);reject(e);}});ws.send(JSON.stringify({id,method,params}));});
 await page(`window.emulatorFixture={id:'emulator_task',revision:1,title:'Identify machines on Android',criteria:'Machine names are distinct'};window.emulatorWorld={world_incarnation:'emulator-fixture',world_generation:1};window.mountEvidence=async()=>{const {taskScreenshots}=await import('./task-screenshots.js');document.querySelector('[data-nav="development-tasks"]').click();document.querySelector('#development-tasks').replaceChildren(taskScreenshots({task:window.emulatorFixture,world:window.emulatorWorld,invoke:window.__TAURI__.core.invoke,current:()=>({frame:{world:window.emulatorWorld,projection:{development_tasks:{emulator_task:window.emulatorFixture}}}})}));};await window.mountEvidence();`);
 await page(`[...document.querySelectorAll('.task-screenshots > button')].find(b=>b.textContent==='Refresh emulators').click()`);
 await app.until(()=>page(`return document.querySelector('[aria-label="Emulator for Before screenshot"]')?.options.length>1`),15000,'real emulator discovery');
 for(const side of ['before','after']){
  await call('Page.navigate',{url:url+side});
  await app.until(async()=>{const r=await call('Runtime.evaluate',{expression:`document.readyState==='complete'&&document.querySelector('h1')?.textContent===${JSON.stringify(side==='before'?'Before: unnamed machines':'After: named machines')}`,returnByValue:true});return r.result.value;},15000,'Android '+side+' screen');
  await call('Runtime.evaluate',{expression:'new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))',awaitPromise:true});
  await page(`const select=document.querySelector('[aria-label="Emulator for ${side==='before'?'Before':'After'} screenshot"]');select.closest('details').open=true;select.value=${JSON.stringify(serial)};[...document.querySelectorAll('.task-screenshots button')].find(b=>b.textContent==='Capture ${side} from emulator').click()`);
  await app.until(()=>page(`return document.querySelector('.task-screenshots > [role=status]').textContent.includes('${side==='before'?'Before':'After'} emulator screenshot captured and attached')`),30000,'native emulator capture '+side);
 }
 const query={operation:'list',world:['emulator-fixture',1],task:'emulator_task',revision:1};
 const record=await page(`return window.__TAURI__.core.invoke('task_screenshots',{request:${JSON.stringify(query)}})`);
 assert.notEqual(record.images.before.sha256,record.images.after.sha256);
 for(const side of ['before','after']){const image=record.images[side];assert.equal(image.capture.kind,'android-emulator');assert.equal(image.capture.serial,serial);assert.equal(image.capture.source_verified,false);assert.match(image.capture.activity,/com.android.chrome/);assert.ok(image.width>300&&image.height>600);writeFileSync(out+'/'+side+'.png',Buffer.from(image.data.split(',')[1],'base64'));}
 checks.push('Task controls capture distinct Before and After PNGs from the actual Android display','Each capture retains emulator, OS, resolution and foreground app without claiming a source version');
 // Check the fixture pixels, not just hashes that could differ because of a clock.
 const colors=await page(`const record=await window.__TAURI__.core.invoke('task_screenshots',{request:${JSON.stringify(query)}});return Promise.all(['before','after'].map(side=>new Promise((resolve,reject)=>{const img=new Image();img.onload=()=>{const c=document.createElement('canvas');c.width=img.width;c.height=img.height;const x=c.getContext('2d');x.drawImage(img,0,0);resolve([...x.getImageData(20,Math.floor(img.height*.6),1,1).data]);};img.onerror=reject;img.src=record.images[side].data;})));`);
 assert.deepEqual(colors,[[88,35,41,255],[18,61,48,255]]);checks.push('Captured display pixels match the rendered baseline and candidate fixture');
 for(const target of ['phone123','emulator-9999','emulator-5554;id']){
  const denied=await page(`return window.__TAURI__.core.invoke('task_screenshots',{request:${JSON.stringify({...query,operation:'capture_emulator',side:'after',serial:target})}}).then(()=>false).catch(()=>true)`);assert.ok(denied);
 }
 const retained=await page(`return window.__TAURI__.core.invoke('task_screenshots',{request:${JSON.stringify(query)}})`);assert.deepEqual(retained,record);checks.push('Physical, missing and malformed targets are refused without replacing saved evidence');
 await page(`await window.mountEvidence()`);await app.until(()=>page(`return document.querySelectorAll('.screenshot-pair img').length===2&&document.querySelector('.screenshot-pair').textContent.includes('Android emulator')`),10000,'saved emulator evidence');checks.push('Reopening the task restores both images and their capture identity');
 await page(`document.querySelector('.task-screenshots').scrollIntoView({block:'start'})`);const shot=await fetch(`http://127.0.0.1:4607/session/${app.session()}/screenshot`);writeFileSync(out+'/desktop-emulator-captures.png',Buffer.from((await shot.json()).value,'base64'));
 writeFileSync(out+'/record.json',JSON.stringify(record,null,2));writeFileSync(out+'/checks.json',JSON.stringify({passed:true,checks},null,2));console.log(checks.join('\n'));
}finally{ws?.close();await app?.close();server.closeAllConnections();server.close();try{command('reverse','--remove',`tcp:${port}`);}catch{}if(debugPort)try{command('forward','--remove',`tcp:${debugPort}`);}catch{}}
