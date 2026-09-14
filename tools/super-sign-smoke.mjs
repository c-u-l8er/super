import {open} from './lib/cockpit-control.mjs';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {execFileSync} from 'node:child_process';
const port=4891;let app;
async function wd(path,body){const r=await fetch(`http://127.0.0.1:${port}/session/${app.session()}${path}`,{method:body?'POST':'GET',headers:{'content-type':'application/json'},body:body?JSON.stringify(body):undefined});const j=await r.json();if(j.value?.error)throw Error(j.value.message);return j.value;}
async function surface(label){for(const handle of await wd('/window/handles')){await wd('/window',{handle});if(await app.page('return window.__TAURI_INTERNALS__?.metadata?.currentWebview?.label')===label)return handle;}return null;}
try{
 app=await open({port,real:process.env.SUPER_SIGN_REAL==='1',fixture:process.env.SUPER_SIGN_REAL!=='1'});await app.native('open_road');
 const road=await app.until(()=>surface('cd-road'),20000,'road');
 await app.until(()=>app.page("return document.querySelector('#road').classList.contains('reading')"),20000,'embedded sign');
 await assert.rejects(()=>app.native('intent',{name:'open_workspace',args:{name:'untrusted-road'}}),/not allowed|denied|forbidden/i);
 assert.ok(await app.page("return !!document.querySelector('#sign-super') && document.querySelector('#cockpit').hidden"));
 const rect=await app.page("return document.querySelector('#readframe').getBoundingClientRect().toJSON()");
 const main=await app.until(()=>surface('main'),10000,'embedded app');
 assert.ok(await app.page("return document.documentElement.dataset.roadEmbedded==='true' && !!window.cockpit.frame.projection"));
 const viewport=await app.page('return {width:innerWidth,height:innerHeight}');assert.ok(Math.abs(viewport.width-rect.width)<3 && Math.abs(viewport.height-rect.height)<3,JSON.stringify({viewport,rect}));
 if(process.env.SUPER_SIGN_REAL!=='1'){
  const server=createServer((req,res)=>res.end('<button id="probe" onclick="this.textContent=\'Clicked\'">Test preview</button>'));await new Promise(r=>server.listen(0,'127.0.0.1',r));
  try{await app.native('browser_surface',{action:'open',url:'http://127.0.0.1:'+server.address().port,rect:{x:240,y:140,width:400,height:200}});await app.until(()=>surface('development-preview'),10000,'nested preview');assert.ok(await app.page('return innerWidth===400 && innerHeight===200'));await assert.rejects(()=>app.native('super_sign',{visible:false}),/not allowed|denied|forbidden/i);await wd('/window',{handle:main});await app.native('browser_surface',{action:'close'});}finally{server.close();}
 }
 await app.page("window.__signPersistence='retained';document.querySelector('#focus-home').click()");
 await wd('/window',{handle:road});
 execFileSync('/usr/bin/python3',['tools/development-capture-window.py',String(process.pid),'/home/travis/Documents/Codex/2026-09-12/le/outputs/road-sign/Embedded_Super.png']);
 await app.page("document.querySelector('#leave').click()");
 await app.until(()=>app.page("return !document.querySelector('#road').classList.contains('reading') && window.__roadScene.snapshot().phase==='driving'"),10000,'leave');
 execFileSync('/usr/bin/python3',['tools/development-capture-window.py',String(process.pid),'/home/travis/Documents/Codex/2026-09-12/le/outputs/road-sign/Super_On_The_Road.png']);
 await app.page("document.querySelector('#sign-super').click()");
 await app.until(()=>app.page("return document.querySelector('#road').classList.contains('reading')"),10000,'reenter');
 await wd('/window',{handle:main});assert.equal(await app.page('return window.__signPersistence'),'retained');
 await wd('/window',{handle:road});await wd('/window/rect',{width:1280,height:900});await new Promise(r=>setTimeout(r,1000));const resized=await app.page("return document.querySelector('#readframe').getBoundingClientRect().toJSON()");await wd('/window',{handle:main});await app.until(()=>app.page('return Math.abs(innerWidth-arguments[0])<3 && Math.abs(innerHeight-arguments[1])<3',[resized.width,resized.height]),10000,'resized sign');
 console.log('PASS: live Super sign, runtime connection, leave/reenter, and same-session state.');
}catch(e){console.log(await app.page("return {text:document.body.innerText,probe:window.__probe?.()}"));throw e;}finally{if(app)await app.close();}
