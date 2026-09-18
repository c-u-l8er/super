/* Behaviour test for cockpit/ui/references.js — the reference renderer.
 * Run with: node --test tools/
 * A ten-line fake DOM stands in for the browser: enough for createElement,
 * text nodes, dataset, closest and the demotion query. No jsdom. */
import test from 'node:test';
import assert from 'node:assert/strict';

class Text{constructor(t){this.textContent=String(t);this.nodeType=3;}}
class El{
  constructor(tag){this.tagName=tag.toUpperCase();this.children=[];this.dataset={};this.attrs={};this.parentElement=null;this.title='';this.href='';this.className='';}
  append(...nodes){for(const n of nodes){n.parentElement=this;this.children.push(n);}}
  replaceChildren(){this.children=[];}
  set textContent(v){this.children=[new Text(v)];}
  get textContent(){return this.children.map(c=>c.textContent).join('');}
  setAttribute(k,v){this.attrs[k]=String(v);} getAttribute(k){return this.attrs[k]??null;}
  closest(sel){const tags=sel.split(',').map(s=>s.trim().toUpperCase());let e=this;while(e){if(tags.includes(e.tagName))return e;if(sel.startsWith('[data-')&&e.dataset[sel.slice(6,-1).replace(/-([a-z])/g,(_,c)=>c.toUpperCase())]!==undefined)return e;e=e.parentElement;}return null;}
  descendants(){return this.children.flatMap(c=>c instanceof El?[c,...c.descendants()]:[]);}
  querySelectorAll(sel){/* supports "ctrl a[data-record-ref], …" and "[data-record-ref]" */
    const parts=sel.split(',').map(s=>s.trim());return this.descendants().filter(e=>parts.some(p=>{const [ctrl,leaf]=p.includes(' ')?p.split(' '):[null,p];
      const isLeaf=leaf.startsWith('a[')?e.tagName==='A'&&e.dataset.recordRef!==undefined:leaf==='[data-record-ref]'?e.dataset.recordRef!==undefined:false;
      return isLeaf&&(!ctrl||!!(e.parentElement&&e.parentElement.closest(ctrl)));}));}
  replaceWith(n){const i=this.parentElement.children.indexOf(this);this.parentElement.children[i]=n;n.parentElement=this.parentElement;}
}
globalThis.document={createElement:t=>new El(t),createTextNode:t=>new Text(t)};
const refs=await import('../cockpit/ui/references.js');
const {referenceText,setReferenceFrame,setReferenceRouting,reference,referenceKinds,referencePattern,demoteNestedReferences,readable}=refs;

const projection={
  workspaces:{ws_0001:{id:'ws_0001',name:'Super'}},goals:{gl_0001:{id:'gl_0001',title:'Build Super'}},
  lanes:{ln_0001:{id:'ln_0001',goal_ref:'gl_0001',actor:'bot_opaque'}},workers:{wk_0001:{id:'wk_0001',purpose:'Serve'}},
  bots:{bt_0034:{id:'bt_0034',actor:'bot_opaque',name:'Super · Claude Opus 5'}},repositories:{rp_0003:{ref:'rp_0003',name:'super-live'}},
  development_tasks:{dt_0052:{id:'dt_0052',title:'Prove one observable development run through Super',revision:6,status:'planned'}},
  development_attempts:{da_0062:{id:'da_0062',task_ref:'dt_0052',plan_title:'Prove one observable development run through Super',status:'accepted'}},
};
const frame={world:{world_incarnation:'w',world_generation:1,projection_epoch:'e'},projection};
const links=el=>el.descendants().filter(e=>e.dataset.recordRef!==undefined);

test('the pattern covers every kind in the table, plans and attempts included, escaped or not',()=>{
  const kinds=referenceKinds();
  assert.deepEqual(kinds.map(k=>k.prefix).sort(),['bt','da','dt','gl','ln','rp','wk','ws']);
  for(const k of kinds)assert.ok(referencePattern().test(`${k.prefix}_0001`),k.prefix);
  assert.deepEqual('see dt_0052, da_0062 and rp\\_0003'.match(referencePattern()),['dt_0052','da_0062','rp\\_0003']);
  assert.ok(!referencePattern().test('ef_0001'),'evidence ids are not reference kinds and stay plain');
  assert.equal(kinds.find(k=>k.prefix==='dt').collection,'development_tasks');
  assert.equal(kinds.find(k=>k.prefix==='da').collection,'development_attempts');
});

test('the frame indexes plans and attempts with their own routes and labels',()=>{
  setReferenceFrame(frame);
  assert.equal(reference('dt_0052').key,'development-task:dt_0052');
  assert.equal(reference('dt_0052').label,'Prove one observable development run through Super');
  assert.equal(reference('da_0062').key,'development-attempt:da_0062');
  assert.equal(reference('da_0062').label,'Review of Prove one observable development run through Super');
  assert.equal(reference('da\\_0062').id,'da_0062');
  assert.equal(readable('dt_0052'),'Prove one observable development run through Super');
  setReferenceFrame(null);
});

test('label display: a paragraph shows the name as a link and the id in the tooltip',()=>{
  setReferenceFrame(frame);const p=new El('p');referenceText(p,'Plan dt_0052 is on bt_0034');
  const [plan,bot]=links(p);
  assert.equal(plan.tagName,'A');assert.equal(plan.textContent,'Prove one observable development run through Super');
  assert.equal(plan.dataset.recordRef,'dt_0052');assert.equal(plan.dataset.recordKind,'Development plan');
  assert.equal(plan.title,'Development plan: dt_0052 — open current record');
  assert.equal(bot.textContent,'Super · Claude Opus 5');assert.equal(p.textContent,'Plan Prove one observable development run through Super is on Super · Claude Opus 5');
  assert.equal(p.dataset.referenceDisplay,'label');setReferenceFrame(null);
});

test('id display: the id stays visible and the name moves to the tooltip',()=>{
  setReferenceFrame(frame);const span=new El('span');referenceText(span,'dt_0052 · rev 6 · planned',undefined,{display:'id'});
  const [plan]=links(span);assert.equal(plan.tagName,'A');assert.equal(plan.textContent,'dt_0052');
  assert.equal(plan.title,'Development plan: Prove one observable development run through Super — open current record');
  assert.equal(span.textContent,'dt_0052 · rev 6 · planned');assert.equal(span.dataset.referenceDisplay,'id');setReferenceFrame(null);
});

test('inside a button or summary the reference is a tooltip span, never a nested link',()=>{
  setReferenceFrame(frame);
  for(const tag of ['button','summary','label','a']){const el=new El(tag);referenceText(el,'Development plan · dt_0052 · title',undefined,{display:'id'});
    const [r]=links(el);assert.equal(r.tagName,'SPAN',tag);assert.equal(r.className,'record-ref');assert.equal(r.dataset.recordRef,'dt_0052');assert.equal(r.href,'');
    assert.equal(r.title,'Development plan: Prove one observable development run through Super');}
  const button=new El('button'),inner=new El('span');button.append(inner);referenceText(inner,'rp_0003');
  assert.equal(links(inner)[0].tagName,'SPAN','a span already inside a button renders a span');
  setReferenceFrame(null);
});

test('a link built before its control existed is demoted once the frame lands',()=>{
  setReferenceFrame(frame);const title=new El('span');referenceText(title,'Lane ln_0001');assert.equal(links(title)[0].tagName,'A');
  const button=new El('button');button.append(title);const root=new El('div');root.append(button);
  demoteNestedReferences(root);const [r]=links(title);
  assert.equal(r.tagName,'SPAN');assert.equal(r.className,'record-ref');assert.equal(r.dataset.recordRef,'ln_0001');assert.equal(r.textContent,'bot_opaque','label display survives demotion');
  assert.equal(r.title,'Lane: ln_0001');
  const p=new El('p');referenceText(p,'gl_0001');root.append(p);demoteNestedReferences(root);assert.equal(links(p)[0].tagName,'A','a link in prose is left alone');
  setReferenceFrame(null);
});

test('a surface that cannot open a kind renders it as a tooltip span',()=>{
  setReferenceFrame(frame);setReferenceRouting(kind=>kind==='Development plan');
  const p=new El('p');referenceText(p,'dt_0052 and bt_0034');const [plan,bot]=links(p);
  assert.equal(plan.tagName,'A');assert.equal(bot.tagName,'SPAN');assert.equal(bot.title,'Bot: bt_0034');
  setReferenceRouting(null);const q=new El('p');referenceText(q,'bt_0034');assert.equal(links(q)[0].tagName,'A');setReferenceFrame(null);
});

test('text without an id takes the fast path and carries no render state; labels never mix worlds',()=>{
  setReferenceFrame(frame);const p=new El('p');referenceText(p,'No ids here');assert.equal(p.textContent,'No ids here');assert.equal(p.dataset.rawText,undefined);
  const q=new El('p');referenceText(q,'zz_0001 is not a kind');assert.equal(links(q).length,0);assert.equal(q.dataset.rawText,undefined);
  setReferenceFrame(null);const r=new El('p');referenceText(r,'dt_0052');assert.equal(links(r).length,0);assert.equal(r.textContent,'dt_0052');assert.equal(r.dataset.rawText,'dt_0052','an unresolved id keeps its render state so a later frame can link it');
});

test('the palette finder searches nothing the table cannot link',async()=>{
  const {readFileSync}=await import('node:fs');
  const finder=readFileSync(new URL('../cockpit/ui/record-finder.js',import.meta.url),'utf8');
  const searched=[...finder.matchAll(/^\s*\['([a-z_]+)','([^']+)'/gm)].map(m=>m[1]);
  assert.ok(searched.length>=6);const known=new Set(referenceKinds().map(k=>k.collection));
  for(const c of searched)assert.ok(known.has(c),c);
});
