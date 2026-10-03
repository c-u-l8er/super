/* T31 L2 (scroll) and L3 (history): the real ui/app.js in phone.mjs's page, against a real gateway. */
import test from 'node:test';import assert from 'node:assert/strict';
import {CODE,fixtureWorld,openPhone} from './phone.mjs';

async function onTasks(t){
  const phone=await openPhone(t);
  await phone.pair(CODE);
  await phone.until(()=>phone.text('#content h1')==='Needs your attention.','Needs me after pairing');
  phone.tap('[data-view=tasks]');
  await phone.until(()=>phone.text('#content h1')==='Development tasks.','the Tasks list');
  return phone;
}

test('T31 L2 · a plan opens at its top, the redraw keeps the scroll, back returns to the list where it was',async t=>{
  const phone=await onTasks(t);
  phone.window.scrollY=900;
  phone.tap(phone.button('Second open plan'));
  await phone.until(()=>phone.text('#content h1')==='Second open plan','the plan');
  assert.equal(phone.window.scrollY,0,'the plan starts at its top, not at the list offset');
  phone.window.scrollY=420;
  phone.world=fixtureWorld({revision6:3});
  await phone.tick(2000);
  await phone.until(()=>phone.text('#content .meta')?.includes('Revision 3'),'the two-second redraw');
  assert.equal(phone.window.scrollY,420,'a redraw of the same place leaves the scroll alone');
  phone.history.back();
  await phone.until(()=>phone.text('#content h1')==='Development tasks.','the list after back');
  assert.equal(phone.window.scrollY,900,'back returns to the list where it was left');
});

test('T31 L3 · a plan is a history entry: back, forward, tabs and ← Back',async t=>{
  const phone=await onTasks(t);
  assert.equal(phone.hash,'#/tasks');
  const listAt=phone.tab.index,length=phone.history.length;
  phone.tap(phone.button('Second open plan'));
  await phone.until(()=>phone.text('#content h1')==='Second open plan','the plan');
  assert.equal(phone.hash,'#/tasks/dt_0006');
  assert.equal(phone.history.length,length+1,'opening a plan pushes an entry');
  phone.history.back();
  await phone.until(()=>phone.text('#content h1')==='Development tasks.','the list after back');
  assert.equal(phone.hash,'#/tasks');
  assert.equal(phone.tab.leftPage,false,'back stayed in the page');
  phone.history.forward();
  await phone.until(()=>phone.text('#content h1')==='Second open plan','the plan after forward');
  phone.tap(phone.button('← Back'));
  await phone.until(()=>phone.text('#content h1')==='Development tasks.','the list after ← Back');
  assert.equal(phone.tab.index,listAt,'← Back went back; it did not add an entry');
  assert.equal(phone.hash,'#/tasks');
  phone.tap('[data-view=bots]');
  await phone.until(()=>phone.text('#content h1')==='Your bots.','Bots');
  assert.equal(phone.hash,'#/bots');
  assert.equal(phone.tab.index,listAt+1,'a tab tap pushes');
  phone.history.back();
  await phone.until(()=>phone.text('#content h1')==='Development tasks.','Tasks after back from Bots');
});

test('T31 L3 · a reload comes back to the same place; an unknown URL to Needs me',async t=>{
  const phone=await onTasks(t);
  phone.tap(phone.button('Second open plan'));
  await phone.until(()=>phone.text('#content h1')==='Second open plan','the plan');
  await phone.reload();
  await phone.until(()=>phone.text('#content h1')==='Second open plan','the plan after a reload');
  assert.equal(phone.hash,'#/tasks/dt_0006');
  await phone.reload({dropState:true});
  await phone.until(()=>phone.text('#content h1')==='Second open plan','the plan from the hash alone');
  for(const hash of ['#/nowhere','#/tasks/<script>','#/stack/dt_0006/extra','#tasks']){
    phone.tab.entries[phone.tab.index]={state:null,url:phone.tab.resolve(hash)};
    await phone.reload();
    await phone.until(()=>phone.text('#content h1')==='Needs your attention.',`Needs me for ${hash}`);
    assert.equal(phone.hash,'#/attention',hash);
  }
});
