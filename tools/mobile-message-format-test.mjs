import {test} from 'node:test';import assert from 'node:assert/strict';
import {messageBlocks,messageSpans} from '../mobile/ui/conversations.js';
test('development reply has headings, numbered steps, quotes and exact code',()=>{
 const value=messageBlocks('# Plan\n\n1. **Inspect** the app\n2. Run `npm test`\n> Keep pairing\n\n```sh\n  npm test\n# literal heading\n```');
 assert.deepEqual(value.map(b=>b.kind),['heading','item','item','quote','code']);assert.equal(value[4].text,'  npm test\n# literal heading');assert.equal(value[1].marker,'1.');
});
test('unfinished streamed fences and emphasis never drop text',()=>{assert.equal(messageBlocks('```js\nconst x = 1;')[0].text,'const x = 1;');assert.deepEqual(messageSpans('unfinished **bold'),[{kind:'plain',text:'unfinished **bold'}]);});
test('HTML, image and executable links stay inert literal text',()=>{const text='<img src=x onerror=alert(1)> [open](javascript:alert(1)) ![pixel](https://a)';assert.equal(messageBlocks(text)[0].text,text);assert.equal(messageSpans(text)[0].text,text);});
test('inline code preserves literal emphasis and characters',()=>assert.deepEqual(messageSpans('Use `**x** <y>` and **bold**.'),[{kind:'plain',text:'Use '},{kind:'code',text:'**x** <y>'},{kind:'plain',text:' and '},{kind:'strong',text:'bold'},{kind:'plain',text:'.'}]));
