import {open} from './lib/cockpit-control.mjs';import assert from 'node:assert/strict';import {writeFileSync,mkdtempSync,renameSync,mkdirSync} from 'node:fs';
const out=process.env.SUPER_VISUAL_EVIDENCE_DIR||'/tmp/fleet-native',dir=mkdtempSync('/tmp/fleet-smoke-'),file=dir+'/snapshot.json',port=4798;mkdirSync(out,{recursive:true});process.env.SUPER_FLEET_SNAPSHOT=file;
const rows=[{id:'freebsd',label:'FreeBSD research',observedAt:Date.now(),status:'observed',reason:'',nextStep:'Prepare a Linux check guest under bhyve.',inventory:{hostname:'cd-floor-01',os:'FreeBSD',release:'15.1',logicalCpus:16,memoryBytes:30854651904,hypervisor:'bhyve',guests:[{id:'wifibox',label:'Wifibox',status:'present'}]}},{id:'proxmox',label:'Locuchest',observedAt:Date.now(),status:'observed',reason:'',nextStep:'Connect the pilot guest to a task-bound check.',inventory:{hostname:'locuchest',os:'Linux',release:'7.0.2',logicalCpus:16,memoryBytes:30242045952,hypervisor:'proxmox',guests:[{id:'100',label:'super-worker-01',status:'running'}]}}];
function save(value={schema:'fleet-snapshot@1',hosts:rows}){writeFileSync(file+'.pending',JSON.stringify(value));renameSync(file+'.pending',file);}
save();let app;const checks=[];const check=(n,v)=>{assert.ok(v,n);checks.push(n);console.log(n);};
const shot=async n=>{const r=await fetch(`http://127.0.0.1:${port}/session/${app.session()}/screenshot`);writeFileSync(`${out}/${n}.png`,Buffer.from((await r.json()).value,'base64'));};
try{
 app=await open({port});await app.until(async()=>(await app.projection()).fleet?.hosts?.length===2,10000,'fleet projection');
 await app.page(`document.querySelector('[data-nav=fleet]').click()`);
 check('Fleet has one frame-owned screen',await app.page(`return document.querySelectorAll('[data-screen=fleet]').length===1&&!document.querySelector('[data-screen=fleet]').hidden`));
 check('Named hosts, bhyve and the actual guest relationship are visible',await app.page(`const s=document.querySelector('[data-screen=fleet]').textContent;return s.includes('bhyve hypervisor')&&s.includes('super-worker-01')&&s.includes('Wifibox')`));await shot('01_Fleet');
 await app.page(`document.querySelector('[data-record-open="machine:proxmox"]').click()`);
 check('Machine opens a dedicated detail page',await app.page(`return document.querySelector('[data-screen=record] h1')?.textContent==='Locuchest'`));await shot('05_Machine');
 await app.page(`document.querySelector('[data-record-tab=work]').click();document.querySelector('[data-record-open="vm:proxmox:100"]').click()`);
 check('VM opens a host-scoped detail page',await app.page(`return document.querySelector('[data-screen=record]')?.dataset.recordKey==='vm:proxmox:100'&&document.querySelector('[data-screen=record]').textContent.includes('super-worker-01')`));await shot('06_VM');
 await app.page(`document.querySelector('[data-record-tab=work]').click();document.querySelector('[data-record-open="machine:proxmox"]').click()`);
 check('VM links back to its actual host',await app.page(`return document.querySelector('[data-screen=record]').dataset.recordKey==='machine:proxmox'`));
 await app.page(`document.querySelector('[data-nav=fleet]').click()`);

 await app.page(`document.querySelector('.fleet-next button').click()`);check('Fleet offers a direct route to task checks',await app.page(`return !document.querySelector('#work-focus').hidden`));await app.page(`document.querySelector('[data-nav=fleet]').click()`);
 const before=await app.page(`return window.cockpit.frames`);await new Promise(r=>setTimeout(r,2200));const after=await app.page(`return window.cockpit.frames`);check('Unchanged inventory does not create idle frame traffic',after-before<=2);
 await app.page(`document.querySelector('#toggle-schematics').click()`);await app.until(()=>app.page(`return !!document.querySelector('[data-schematic-node="host:proxmox:guest:100"]')&&!document.querySelector('.schematic-note').hasAttribute('aria-busy')`),20000,'fleet layout');
 check('Schematic contains distinct hosts and guests',await app.page(`return document.querySelectorAll('[data-schematic-node]').length===5`));await shot('02_Fleet_Schematic');
 await app.page(`document.querySelector('#toggle-schematics').click()`);
 rows[0].observedAt=Date.now()-100000;save();await app.until(()=>app.page(`return document.querySelector('[data-fleet-host=freebsd]').textContent.includes('Observation expired')`),8000,'expiry');
 check('Expired observations withdraw guest state',await app.page(`return document.querySelector('[data-fleet-host=freebsd] .fleet-guests').textContent.includes('unknown')`));
 rows[1].status='unavailable';rows[1].reason='Connection check failed.';rows[1].observedAt=Date.now();save();await app.until(()=>app.page(`return document.querySelector('[data-fleet-host=proxmox]').textContent.includes('Connection needs attention')`),8000,'failure');
 check('Failed host no longer displays prior guest as running',await app.page(`return !document.querySelector('[data-fleet-host=proxmox]').textContent.includes('super-worker-01')`));await shot('03_Connection_Recovery');
 rows[0].observedAt=Date.now();rows[1].status='observed';rows[1].reason='';save();await app.until(()=>app.page(`return document.querySelector('[data-fleet-host=proxmox]').textContent.includes('super-worker-01')`),8000,'recovery');
 check('A new successful observation restores the guest',true);
 await fetch(`http://127.0.0.1:${port}/session/${app.session()}/window/rect`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({width:720,height:820})});
 check('Small window does not overflow horizontally',await app.page(`return document.documentElement.scrollWidth<=innerWidth+1`));await shot('04_Small_Fleet');
 save({schema:'invalid'});await app.until(()=>app.page(`return document.querySelector('.fleet-empty')?.textContent.includes('unavailable')`),8000,'bad snapshot');check('Invalid snapshot cannot preserve earlier host inventory',await app.page(`return !document.querySelector('[data-fleet-host]')`));
 writeFileSync(`${out}/checks.json`,JSON.stringify({passed:true,checks},null,2));
}finally{await app?.close();}
