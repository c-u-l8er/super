/* T31 L9 (layout) and L10 (task detail), plus the harness check that the phone loads what the gateway serves.
 * CSS laws compute, from ui/style.css, the declarations that apply at a viewport width: base rules plus
 * min-width/max-width media, in source order, for an exact selector. They hold the rules iOS depends on; the
 * pixels are for the Simulator. */
import test from 'node:test';import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {CODE,CRITERIA,chatView,openChat,openPhone,served} from './phone.mjs';

function parse(source){
  const css=source.replace(/\/\*[\s\S]*?\*\//g,''),rules=[];let i=0;
  const skipBlock=()=>{let depth=0;for(;i<css.length;i++){if(css[i]==='{')depth++;else if(css[i]==='}'&&--depth===0){i++;return;}}};
  const read=media=>{
    while(i<css.length){
      while(/\s/.test(css[i]??''))i++;if(i>=css.length)return;
      if(css[i]==='}'){i++;return;}
      if(css.startsWith('@media',i)){const open=css.indexOf('{',i);const condition=css.slice(i+6,open).trim();i=open+1;read(condition);continue;}
      if(css[i]==='@'){skipBlock();continue;}
      const open=css.indexOf('{',i),close=css.indexOf('}',open);
      rules.push({media,selectors:css.slice(i,open).split(',').map(s=>s.trim().replace(/\s+/g,' ')),
        decls:css.slice(open+1,close).split(';').map(d=>d.trim()).filter(Boolean).map(d=>{const k=d.indexOf(':');return [d.slice(0,k).trim(),d.slice(k+1).trim()];})});
      i=close+1;
    }
  };
  read(null);return rules;
}
const rules=parse(readFileSync(new URL('../ui/style.css',import.meta.url),'utf8'));
const applies=(media,width)=>{if(!media)return true;const m=/^\((min|max)-width:(\d+)px\)$/.exec(media.replace(/\s+/g,''));return !!m&&(m[1]==='min'?width>=Number(m[2]):width<=Number(m[2]));};
const declared=(selector,width)=>rules.filter(r=>applies(r.media,width)&&r.selectors.includes(selector)).flatMap(r=>r.decls);
const computed=(selector,property,width=390)=>declared(selector,width).filter(([k])=>k===property).at(-1)?.[1];
const marginTop=(selector,width)=>{let top;for(const [k,v] of declared(selector,width)){if(k==='margin')top=v.split(/\s+/)[0];if(k==='margin-top')top=v;}return top;};
const px=v=>{const m=/^(-?[\d.]+)px$/.exec(v??'');assert.ok(m,`a px value, got ${v}`);return Number(m[1]);};

test('T31 L9 · under 600 px the header and the title are compact; from 600 px they are as before',()=>{
  assert.ok(px(computed('header','height',390))<=56,`header ${computed('header','height',390)} at 390 px`);
  assert.ok(px(computed('h1','font-size',390))<=28,`h1 ${computed('h1','font-size',390)} at 390 px`);
  assert.ok(px(marginTop('.eyebrow',390))<=12,`eyebrow top margin ${marginTop('.eyebrow',390)} at 390 px`);
  assert.equal(computed('header','height',800),'76px');
  assert.equal(computed('h1','font-size',800),'40px');
});

test('T31 L9 · the page starts below the status bar, and chat mode fits inside it',()=>{
  assert.equal(computed('body','padding-top'),'env(safe-area-inset-top)');
  assert.equal(computed('body::before','position'),'fixed');
  assert.equal(computed('body::before','top'),'0');
  assert.equal(computed('body::before','height'),'env(safe-area-inset-top)');
  assert.equal(computed('body.chat-mode main','height'),'100%','chat mode fills the padded body, not 100dvh under it');
});

test('T31 L9 · the five nav labels do not wrap',()=>{
  assert.equal(computed('nav button','white-space'),'nowrap');
});

test('T31 L9 · a pin is a word where it is needed, never the ⌑ glyph',async t=>{
  assert.ok(!readFileSync(served('conversations.js'),'utf8').includes('⌑'),'no U+2311 in conversations.js');
  const chat=await openChat(t,{answer:()=>chatView()});
  await chat.tick(1000);
  const row=title=>chat.root.querySelectorAll('button.chat-list-row').find(b=>b.childNodes[0]?.textContent===title);
  await chat.until(()=>row('Pinned talk'),'the list');
  const headings=()=>chat.root.querySelectorAll('h3').map(h=>h.textContent);
  assert.ok(headings().includes('Pinned'));
  assert.doesNotMatch(row('Pinned talk').querySelector('small').textContent,/Pinned/,'under "Pinned" the row is just its title');
  chat.root.querySelectorAll('select').find(s=>s.getAttribute('aria-label')==='Sort conversations').value='bot';
  await chat.tick(1000);
  await chat.until(()=>headings().includes('Builder'),'grouped by bot');
  assert.match(row('Pinned talk').querySelector('small').textContent,/^Pinned · /,'grouped by bot, the row says it is pinned');
  assert.doesNotMatch(row('Other talk').querySelector('small').textContent,/Pinned/);
});

test('T31 L10 · ← Back and the badge stack in a column, and the criteria keep their lines',async t=>{
  const phone=await openPhone(t);
  await phone.pair(CODE);
  await phone.until(()=>phone.text('#content h1')==='Needs your attention.','Needs me');
  phone.tap('[data-view=tasks]');
  await phone.until(()=>phone.text('#content h1')==='Development tasks.','Tasks');
  phone.tap(phone.button('Second open plan'));
  await phone.until(()=>phone.text('#content h1')==='Second open plan','the plan');
  const back=phone.button('← Back'),badge=phone.$('#content .badge');
  assert.equal(back.parentElement,badge.parentElement,'one container holds both');
  assert.ok(back.parentElement.classList.contains('detail-head'),'and it is the detail head');
  assert.equal(computed('.detail-head','display'),'flex');
  assert.equal(computed('.detail-head','flex-direction'),'column');
  assert.ok(px(computed('.detail-head','gap'))>=8,'with a gap between them');
  assert.equal(phone.$('#content .criteria').textContent,CRITERIA);
  assert.equal(computed('.criteria','white-space'),'pre-wrap');
});

test('T31 harness · the phone loads exactly what the gateway serves',async t=>{
  const phone=await openPhone(t);
  const imports=['app.js','conversations.js'].flatMap(f=>[...readFileSync(served(f),'utf8').matchAll(/from\s*'(\/[\w.-]+\.js)'/g)].map(m=>m[1]));
  assert.ok(imports.length>=3,`absolute imports found: ${imports}`);
  for(const path of [...new Set(['/app.js','/conversations.js',...imports])]){
    const r=await phone.request(path,{cookie:null});
    assert.equal(r.status,200,path);
    assert.equal(r.text,readFileSync(served(path.slice(1)),'utf8'),`${path} as the harness loads it`);
  }
  assert.equal((await phone.request('/',{cookie:null})).text,readFileSync(new URL('../ui/index.html',import.meta.url),'utf8'));
});
