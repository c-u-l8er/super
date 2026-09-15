import {open} from './lib/cockpit-control.mjs';
import {createServer} from 'node:http';
import {mkdirSync,writeFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const out=process.env.SUPER_VISUAL_EVIDENCE_DIR||'/tmp/super-preview-evidence';mkdirSync(out,{recursive:true});
let after=false;const server=createServer((req,res)=>{res.setHeader('content-type','text/html');res.end(`<html><body style="margin:0;background:${after?'#123d30':'#582329'};color:white;font:24px sans-serif;padding:40px"><h1>${after?'After: clear machine names':'Before: unnamed machines'}</h1><p>${after?'FreeBSD / cd-floor-01':'Machine 1'}</p><p>${after?'Proxmox / Locuchest':'Machine 2'}</p></body></html>`);});await new Promise(r=>server.listen(0,'127.0.0.1',r));const url='http://127.0.0.1:'+server.address().port;let app;const checks=[];
try{
 app=await open({port:4607});const page=c=>app.page(c);
 await page(`window.previewFixture={id:'preview_task',revision:1,title:'Identify the machines',criteria:'Machine names are distinct'};const world={world_incarnation:'preview-fixture',world_generation:1};const {taskScreenshots}=await import('./task-screenshots.js');document.querySelector('[data-nav="development-tasks"]').click();const panel=taskScreenshots({task:window.previewFixture,world,invoke:window.__TAURI__.core.invoke,current:()=>({frame:{world,projection:{development_tasks:{preview_task:window.previewFixture}}}})});document.querySelector('#development-tasks').replaceChildren(panel);`);
 for(const side of ['before','after']){
  after=side==='after';await page(`await window.__TAURI__.core.invoke('browser_surface',{action:'open',tab:0,url:'${url}',rect:{x:310,y:130,width:650,height:460}})`);
  await app.until(()=>page(`return window.__TAURI__.core.invoke('task_screenshots',{request:{operation:'capture_preview',world:['preview-fixture',1],task:'preview_task',revision:1,side:'${side}',tab:0}}).then(r=>({sha:r.images.${side}.sha256})).catch(()=>null)`),15000,'capture '+side);
  await page(`await window.__TAURI__.core.invoke('browser_surface',{action:'hide_all'});[...document.querySelectorAll('.task-screenshots > button')].find(b=>b.textContent==='Refresh preview tabs').click()`);
  await app.until(()=>page(`return document.querySelector('[aria-label="Preview for ${side==='before'?'Before':'After'} screenshot"]')?.options.length>1`),10000,'preview choices');
  await page(`const select=document.querySelector('[aria-label="Preview for ${side==='before'?'Before':'After'} screenshot"]');select.value='0';[...document.querySelectorAll('.task-screenshots button')].find(b=>b.textContent==='Capture ${side} from preview').click()`);
  await app.until(()=>page(`return document.querySelector('.task-screenshots > [role=status]').textContent.includes('${side==='before'?'Before':'After'} preview captured and attached')`),15000,'capture from hidden preview through task controls');
 }
 const record=await page(`return window.__TAURI__.core.invoke('task_screenshots',{request:{operation:'list',world:['preview-fixture',1],task:'preview_task',revision:1}})`);assert.notEqual(record.images.before.sha256,record.images.after.sha256);assert.equal(record.images.before.capture.url,url+'/');assert.equal(record.images.after.capture.kind,'local-preview');checks.push('Native capture retains distinct pixels from the selected local app before and after','Task controls capture and attach a hidden local preview without a file upload','Capture records its actual URL and viewport');
 for(const side of ['before','after'])writeFileSync(out+'/'+side+'.png',Buffer.from(record.images[side].data.split(',')[1],'base64'));
 const denied=await page(`return window.__TAURI__.core.invoke('task_screenshots',{request:{operation:'capture_preview',world:['preview-fixture',1],task:'preview_task',revision:1,side:'after',tab:8}}).then(()=>false).catch(()=>true)`);assert.ok(denied);checks.push('Invalid target cannot capture another surface');
 await page(`document.querySelector('.task-screenshots').scrollIntoView({block:'start'})`);const shot=await fetch(`http://127.0.0.1:4607/session/${app.session()}/screenshot`);writeFileSync(out+'/desktop-preview-captures.png',Buffer.from((await shot.json()).value,'base64'));writeFileSync(out+'/preview-checks.json',JSON.stringify({passed:true,checks},null,2));console.log(checks.join('\n'));
}finally{await app?.close();server.close();}
