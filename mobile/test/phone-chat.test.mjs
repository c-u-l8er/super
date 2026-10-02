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

/* T31 L12 (N2, found in the Simulator): an empty thread was a blank panel. */
test('T31 L12 · the thread says it is loading, then that it has no messages; a lost connection says so; never blank',async t=>{
  let visible=false,mode='empty';
  const answer=()=>{if(mode==='down')throw Error('Conversation connection unavailable.');return chatView({entries:mode==='empty'?[]:undefined});};
  const chat=await openChat(t,{visible:()=>visible,answer});
  const thread=chat.root.querySelector('.chat-thread'),empty=thread.querySelector('.chat-empty'),live=thread.children.find(e=>e.localName==='pre');
  assert.equal(empty.hidden,false);assert.equal(empty.textContent,'Loading messages…');
  assert.equal(live.hidden,true,'no empty live box while loading');
  visible=true;
  await chat.tick(1000);
  await chat.until(()=>empty.textContent==='No messages yet.','the empty state');
  assert.equal(empty.hidden,false);
  mode='messages';
  await chat.tick(1000);
  await chat.until(()=>thread.querySelectorAll('article').length===2,'the messages');
  assert.equal(empty.hidden,true,'messages replace the empty state');
  mode='down';
  await chat.tick(1000);
  await chat.until(()=>!live.hidden,'the reconnect line');
  assert.equal(live.textContent,'Reconnect to read shared messages.');
  assert.equal(empty.hidden,true);
});
