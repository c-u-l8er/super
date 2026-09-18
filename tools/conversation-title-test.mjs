import test from 'node:test';import assert from 'node:assert/strict';import {conversationReply,emptyFirstReply} from '../cockpit/ui/conversation-title.js';
test('requested AI title becomes metadata and is removed from conversation prose',()=>{assert.deepEqual(conversationReply('<conversation-title>Improve machine navigation</conversation-title>Here is the plan.',true),{title:'Improve machine navigation',text:'Here is the plan.'});});
test('ordinary replies and unrequested markup remain intact',()=>{for(const [text,requested] of [['Ordinary reply',true],['<conversation-title>Literal example</conversation-title>Reply',false],['<conversation-title> </conversation-title>Reply',true],['<conversation-title><script></conversation-title>Reply',true]])assert.deepEqual(conversationReply(text,requested),{text});});
test('generated title is bounded without truncating the reply',()=>{const r=conversationReply('<conversation-title>'+'a'.repeat(100)+'</conversation-title>Full answer',true);assert.equal(r.title.length,80);assert.equal(r.text,'Full answer');});
test('a header the model never closed, alone, yields its title and an empty reply',()=>{
  // Measured 2026-09-18: the whole structured text of a first reply was this header, 78 bytes, no note, no action.
  assert.deepEqual(conversationReply('<conversation-title>Persist the Cancelled fold state on record pages (dt_0069)',true),{title:'Persist the Cancelled fold state on record pages (dt_0069)',text:''});
  assert.deepEqual(conversationReply('<conversation-title>Only a title</conversation-title>',true),{title:'Only a title',text:''});
  for(const text of ['<conversation-title>Unclosed\nBut here is the answer.','<conversation-title></conversation-title>','<conversation-title>   '])assert.equal(conversationReply(text,true).title,undefined,text);
  assert.equal(conversationReply('<conversation-title>Unclosed\nBut here is the answer.',true).text,'<conversation-title>Unclosed\nBut here is the answer.');
  assert.deepEqual(conversationReply('<conversation-title>Literal, not requested',false),{text:'<conversation-title>Literal, not requested'});
});
test('a first reply with no prose and no proposal is empty; a title alone does not make it a reply',()=>{
  assert.equal(emptyFirstReply(conversationReply('<conversation-title>Persist the fold (dt_0069)',true),[]),true);
  assert.equal(emptyFirstReply(conversationReply('<conversation-title>T</conversation-title>',true),[]),true);
  assert.equal(emptyFirstReply(conversationReply('',true),[]),true);
  assert.equal(emptyFirstReply(conversationReply('<conversation-title>T</conversation-title>Here is the note.',true),[]),false);
  assert.equal(emptyFirstReply(conversationReply('<conversation-title>T</conversation-title>',true),[{name:'propose_file_edit',args:{path:'a.js',content:'x'}}]),false);
  assert.equal(emptyFirstReply(conversationReply('Plain answer',true),[]),false);
});
