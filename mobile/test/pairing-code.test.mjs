/* T31 L1 · the pairing code (R126): keep the 48-hex code; accept dashes, spaces, capitals and paste;
 * a wrong code still fails and still counts toward the gateway's limiter. Every pairing here goes
 * through the real ui/app.js and a real gateway (phone.mjs). The codes are throwaway test values. */
import test from 'node:test';import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';import {existsSync,mkdtempSync,readFileSync,rmSync} from 'node:fs';
import net from 'node:net';import {tmpdir} from 'node:os';import {join} from 'node:path';import {fileURLToPath} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {CODE,documentFrom,openPhone} from './phone.mjs';

const quads=code=>code.match(/.{1,4}/g);
// The desktop's own display: four-character groups, four to a line (cockpit/src/mobile_gateway.rs `grouped`).
const desktopGrouped=code=>quads(code).reduce((lines,q,i)=>{if(i%4===0)lines.push([]);lines.at(-1).push(q);return lines;},[]).map(l=>l.join(' ')).join('\n');
const variants={
  'dashed in fours':quads(CODE).join('-'),
  "the desktop's grouped display":desktopGrouped(CODE),
  'pasted with surrounding whitespace and a trailing newline':'  \n'+CODE+'\n',
  'upper case':CODE.toUpperCase(),
  'grouped with en and em dashes (iOS smart punctuation)':quads(CODE).map((q,i)=>i?(i%2?'–':'—')+q:q).join(''),
};

test('T31 L1 · one code pairs dashed, grouped, pasted, upper case or with smart dashes',async t=>{
  for(const [how,typed] of Object.entries(variants)){
    const phone=await openPhone(t);
    await phone.pair(typed);
    await phone.until(()=>!phone.$('#app').hidden,`pairing with the code ${how}`);
    assert.equal((await phone.request('/api/snapshot')).status,200,how);
    assert.equal(phone.$('#code').value,'','the field is cleared after pairing');
  }
});

test('T31 L1 · every wrong code fails and counts: after ten, even the right code is refused',async t=>{
  const phone=await openPhone(t),near=CODE.slice(0,-1)+'0';
  assert.notEqual(near,CODE);
  const wrong=['f'.repeat(48),quads(near).join('-'),near.toUpperCase(),CODE.slice(0,47),CODE+'0',CODE.slice(0,47)+'g','- - -',[...CODE].reverse().join(''),'not a code','G'.repeat(48)];
  for(const typed of wrong){
    phone.$('#notice').textContent='';
    await phone.pair(typed);
    await phone.until(()=>phone.text('#notice'),`the refusal of ${JSON.stringify(typed)}`);
    assert.match(phone.text('#notice'),/Pairing code invalid, used, or expired/,JSON.stringify(typed));
    assert.equal(phone.$('#app').hidden,true,'still unpaired');
  }
  phone.$('#notice').textContent='';
  await phone.pair(CODE);
  await phone.until(()=>phone.text('#notice'),'the answer to the right code');
  assert.equal(phone.text('#notice'),'Too many attempts. Try again in a minute.','all ten wrong codes reached the limiter');
  assert.equal(phone.$('#app').hidden,true);
  assert.equal((await phone.request('/api/snapshot')).status,401);
  phone.tab.gatewayNow+=60_001;
  await phone.pair(quads(CODE).join(' '));
  await phone.until(()=>!phone.$('#app').hidden,'pairing once the window has passed');
});

const freePort=()=>new Promise((resolve,reject)=>{const s=net.createServer();s.on('error',reject);s.listen(0,'127.0.0.1',()=>{const {port}=s.address();s.close(()=>resolve(port));});});
async function settled(read,what){for(let i=0;i<1000;i++){const v=read();if(v)return v;await delay(10);}throw Error('timed out waiting for '+what);}

test('T31 L1 · the gateway mints 48 hex (randomBytes(24)) at launch and on renewal',async t=>{
  const dir=mkdtempSync(join(tmpdir(),'t31-mint-'));t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const file=join(dir,'code'),port=await freePort();
  const child=spawn(process.execPath,[fileURLToPath(new URL('../server.mjs',import.meta.url))],{env:{PATH:process.env.PATH??'',SUPER_MOBILE_PORT:String(port),SUPER_MOBILE_PAIR_FILE:file},stdio:['pipe','ignore','ignore']});
  t.after(()=>child.kill());
  const read=()=>existsSync(file)?readFileSync(file,'utf8'):'';
  const first=await settled(()=>/\n$/.test(read())&&read(),'the launch code');
  assert.match(first,/^[0-9a-f]{48}\n$/,'the launch code is 48 hex');
  child.stdin.write(JSON.stringify({operation:'renew'})+'\n');
  const second=await settled(()=>read()!==first&&/\n$/.test(read())&&read(),'the renewed code');
  assert.match(second,/^[0-9a-f]{48}\n$/,'the renewed code is 48 hex');
  assert.notEqual(second,first);
  child.stdin.end();
});

test('T31 L1 · the form keeps one-time-code, and its help text puts paste first',()=>{
  const doc=documentFrom(readFileSync(new URL('../ui/index.html',import.meta.url),'utf8')),input=doc.querySelector('#code');
  assert.equal(input.getAttribute('autocomplete'),'one-time-code');
  assert.equal(input.getAttribute('autocapitalize'),'none');
  assert.equal(input.getAttribute('spellcheck'),'false');
  const help=doc.querySelectorAll('#pair p').find(p=>!p.classList.contains('eyebrow')&&!p.classList.contains('muted')).textContent;
  assert.match(help,/\bpaste\b/i,'the help text says to paste');
  const typing=help.search(/\btyp/i);
  assert.ok(typing<0||help.search(/\bpaste\b/i)<typing,'paste comes before typing');
  assert.match(help,/dash/i);
});
