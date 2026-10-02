/* T31 L5 (tasks), L6 (truthful labels), L7 (disconnect), L8 (bots): the real ui/app.js against a real gateway. */
import test from 'node:test';import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {ACTOR,CODE,fixtureWorld,openPhone} from './phone.mjs';

async function paired(t,view){
  const phone=await openPhone(t);
  await phone.pair(CODE);
  await phone.until(()=>phone.text('#content h1')==='Needs your attention.','Needs me after pairing');
  if(view){const h1={tasks:'Development tasks.',bots:'Your bots.',stack:'Connected stack.'}[view];phone.tap(`[data-view=${view}]`);await phone.until(()=>phone.text('#content h1')===h1,view);}
  return phone;
}
const css=readFileSync(new URL('../ui/style.css',import.meta.url),'utf8');

test('T31 L5 · Tasks lists attention, then open, newest first; Done and All add the finished plans last',async t=>{
  const phone=await paired(t,'tasks');
  assert.deepEqual(phone.cards(),['dt_0007','dt_0005','dt_0004','dt_0006','dt_0003'],'Open: attention plans, then the other open plans, no finished plan');
  assert.equal(phone.$('.filters [aria-pressed=true]').textContent,'Open · 5');
  const length=phone.history.length;
  phone.tap(phone.button('All ·'));
  await phone.until(()=>phone.cards().length===8,'All');
  assert.deepEqual(phone.cards(),['dt_0007','dt_0005','dt_0004','dt_0006','dt_0003','dt_0008','dt_0002','dt_0001']);
  assert.equal(phone.hash,'#/tasks?show=all');
  assert.equal(phone.history.length,length,'a filter replaces the entry; it is not a step');
  phone.tap(phone.button('Done ·'));
  await phone.until(()=>phone.cards().length===3,'Done');
  assert.deepEqual(phone.cards(),['dt_0008','dt_0002','dt_0001']);
  assert.equal(phone.hash,'#/tasks?show=done');
  phone.tap('[data-view=attention]');
  await phone.until(()=>phone.text('#content h1')==='Needs your attention.','Needs me');
  assert.deepEqual(phone.cards(),['dt_0007','dt_0005','dt_0004'],'Needs me: attention only, newest first');
});

test("T31 L5 · each badge carries its state's tone, and the five tones have five colours",async t=>{
  const phone=await paired(t,'tasks');
  phone.tap(phone.button('All ·'));
  await phone.until(()=>phone.cards().length===8,'All');
  const tone=Object.fromEntries(phone.$$('#content article.card').map(c=>[/\b(dt_\d+)\b/.exec(c.querySelector('.meta').textContent)[1],c.querySelector('.badge').dataset.tone]));
  assert.deepEqual(tone,{dt_0007:'attention',dt_0005:'alert',dt_0004:'alert',dt_0006:'open',dt_0003:'open',dt_0008:'closed',dt_0002:'done',dt_0001:'closed'});
  const colours=['alert','attention','open','done','closed'].map(t=>new RegExp(`\\.badge\\[data-tone=${t}\\]\\{color:(#[0-9a-f]{3,6})\\}`,'i').exec(css)?.[1]?.toLowerCase());
  assert.ok(colours.every(Boolean),`every tone has a colour rule: ${colours}`);
  assert.equal(new Set(colours).size,5,`five tones, five colours: ${colours}`);
});

test('T31 L6 · Stack says the phone can send messages and opens conversations on the desktop',async t=>{
  const phone=await paired(t,'stack');
  const text=phone.text('#content');
  assert.doesNotMatch(text,/Observation access/);
  assert.doesNotMatch(text,/read-only/i);
  assert.match(text,/send messages/);
  assert.match(text,/Opening a conversation here also opens it on the desktop/);
});

test('T31 L6 · the README says what a paired phone can do, and how to give it the code',()=>{
  const readme=readFileSync(new URL('../README.md',import.meta.url),'utf8');
  assert.doesNotMatch(readme,/read-only/i,'the companion is not read-only');
  const section=name=>{const at=readme.indexOf('## '+name);assert.ok(at>=0,`a "${name}" section`);const rest=readme.slice(at+3);const end=rest.search(/\n## /);return end<0?rest:rest.slice(0,end);};
  const can=section('What a paired phone can do');
  assert.match(can,/send a message/i);
  assert.match(can,/also selects it on the desktop/i);
  const code=section('Pairing code');
  for(const word of [/paste/i,/dash/i,/capital/i,/48 hexadecimal/])assert.match(code,word);
});

test('T31 L7 · Disconnect asks first; the question outlives a redraw; only Disconnect ends the session',async t=>{
  const phone=await paired(t,'stack');
  const cookie=phone.tab.cookie;
  phone.tap(phone.button('Disconnect this device'));
  await phone.until(()=>phone.text('#content').includes('Disconnect this phone?'),'the question');
  assert.equal(phone.$('#app').hidden,false);
  assert.equal((await phone.request('/api/snapshot')).status,200,'one tap does not end the session');
  phone.world=fixtureWorld({workspaces:2});
  await phone.tick(2000);
  await phone.until(()=>phone.$$('#content dd')[0]?.textContent==='2','the two-second redraw');
  assert.match(phone.text('#content'),/Disconnect this phone\?/,'the question survives the redraw');
  phone.tap(phone.button('Cancel'));
  await phone.until(()=>!phone.text('#content').includes('Disconnect this phone?'),'Cancel');
  assert.equal((await phone.request('/api/snapshot')).status,200);
  phone.tap(phone.button('Disconnect this device'));
  await phone.until(()=>phone.text('#content').includes('Disconnect this phone?'),'the question again');
  phone.tap(phone.button('Disconnect'));
  await phone.until(()=>!phone.$('#pair').hidden,'the pairing form');
  assert.equal((await phone.request('/api/snapshot',{cookie})).status,401,'the session ended');
});

test('T31 L8 · Bots never shows an actor id, and a tap opens that bot’s plans',async t=>{
  const phone=await paired(t,'bots');
  const text=phone.text('#content');
  assert.doesNotMatch(text,/bot_[0-9a-f]{32}/,'no raw actor');
  assert.ok(!text.includes(ACTOR));
  assert.match(text,/Builder/);assert.match(text,/bt_0001/);
  const length=phone.history.length;
  phone.tap(phone.button('Builder'));
  await phone.until(()=>phone.text('#content h1')==='Development tasks.','Tasks for Builder');
  assert.equal(phone.hash,'#/tasks?bot=bt_0001');
  assert.equal(phone.history.length,length+1,'the tap is a step');
  assert.deepEqual(phone.cards(),['dt_0005','dt_0006','dt_0003'],"only Builder's open plans");
  phone.tap(phone.button('Bot · Builder'));
  await phone.until(()=>phone.cards().length===5,'every bot again');
  assert.equal(phone.hash,'#/tasks');
});
