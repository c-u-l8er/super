/* T31 L4 · the draft-conflict note: the real ui/conversations.js in phone.mjs's page. */
import test from 'node:test';import assert from 'node:assert/strict';
import {FakeEvent,chatView,openChat} from './phone.mjs';

test('T31 L4 · the draft-conflict note stays hidden until a loaded conversation really conflicts',async t=>{
  let visible=false,answer=chatView({revision:3});
  const chat=await openChat(t,{visible:()=>visible,answer:()=>answer});
  const keep=chat.button('Keep my draft against this revision'),useDesktop=chat.button('Use desktop draft'),conflict=keep.previousElementSibling;
  const shown=()=>[conflict,keep,useDesktop].map(e=>!e.hidden);
  assert.deepEqual(shown(),[false,false,false],'loading: nothing to conflict with yet');
  visible=true;
  await chat.tick(1000);
  await chat.until(()=>chat.root.querySelector('h1').textContent==='Pinned talk','the conversation');
  assert.deepEqual(shown(),[false,false,false],'loaded, no local edit');
  const draft=chat.root.querySelector('textarea');
  draft.value='my words';draft.dispatchEvent(new FakeEvent('input'));
  answer=chatView({revision:4,draft:'desktop words'});
  await chat.tick(1000);
  await chat.until(()=>!keep.hidden,'the conflict (positive control)');
  assert.deepEqual(shown(),[true,true,true]);
  assert.match(conflict.textContent,/desktop words/);
});
