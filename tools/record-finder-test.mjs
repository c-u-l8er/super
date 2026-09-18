/* Behaviour test for cockpit/ui/record-finder.js, the pure half of the palette
 * record lookup. Run with: node --test tools/
 * No DOM, no disk fixtures, no network; the module under test owns no state. */
import test from 'node:test';
import assert from 'node:assert/strict';
import {findRecords} from '../cockpit/ui/record-finder.js';

/* Shaped like the held operator projection: collections keyed by id, values are
 * records. Repositories are keyed by ref and carry `ref` instead of `id`. The
 * two plans sit in different workspaces (ws_0013, ws_0001) so a test can prove
 * the finder ignores the workspace filter. The two extra repository refs are
 * synthetic and exist only to pin the prefix / substring band boundary. */
const fixture=()=>({
 development_tasks:{
  dt_0052:{id:'dt_0052',workspace_ref:'ws_0013',title:'Prove one observable development run through Super',status:'In review'},
  dt_0063:{id:'dt_0063',workspace_ref:'ws_0001',title:'Find any Super record from the palette and jump to it',status:'Planned'},
 },
 development_attempts:{
  da_0062:{id:'da_0062',task_ref:'dt_0052',plan_title:'Prove one observable development run through Super',status:'Reviewed'},
 },
 workspaces:{ws_0013:{id:'ws_0013',name:'Super'},ws_0001:{id:'ws_0001',name:'Cockpit'}},
 goals:{gl_0021:{id:'gl_0021',title:'Ship dt_0063 and rp_0003 from the palette'}},
 lanes:{ln_0004:{id:'ln_0004',name:'Mobile companion',state:'open'}},
 bots:{bt_0034:{id:'bt_0034',name:'Super · Claude Opus 5'}},
 repositories:{
  rp_0003:{ref:'rp_0003',name:'rp_0003 · super cockpit'},
  rp_0003_mirror:{ref:'rp_0003_mirror',name:'Mirror of super'},
  mirror_rp_0003:{ref:'mirror_rp_0003',name:'Older mirror'},
 },
 workers:{wk_0011:{id:'wk_0011',purpose:'Review proposals',occupancy:'idle'}},
});
const ids=list=>list.map(r=>r.id);

test('an exact record id ranks first and routes to that record; an attempt found by its plan id routes to the plan',()=>{
 const found=findRecords(fixture(),'dt_0052');
 assert.equal(found.length,2);
 assert.deepEqual(found[0],{kind:'Development plan',id:'dt_0052',title:'Prove one observable development run through Super',status:'In review',route:{task:'dt_0052'}});
 assert.deepEqual(found[1],{kind:'Review attempt',id:'da_0062',title:'Prove one observable development run through Super',status:'Reviewed',route:{task:'dt_0052',attempt:'da_0062'}});
 const attempt=findRecords(fixture(),'da_0062');
 assert.deepEqual(ids(attempt),['da_0062']);
 assert.equal(attempt[0].kind,'Review attempt');
 assert.deepEqual(attempt[0].route,{task:'dt_0052',attempt:'da_0062'});
});

test('a title fragment is case-insensitive and finds plans in every workspace',()=>{
 const p=fixture(),lower=findRecords(p,'super');
 assert.deepEqual(findRecords(p,'SUPER'),lower);
 assert.deepEqual(findRecords(p,'  Super  '),lower);
 /* dt_0052 lives in ws_0013 and dt_0063 in ws_0001: the finder is not scoped. */
 assert.deepEqual(ids(lower.filter(r=>r.kind==='Development plan')),['dt_0052','dt_0063']);
 assert.ok(ids(lower).includes('da_0062'));
 assert.ok(ids(lower).includes('ws_0013'));
 assert.equal(lower.length,7);
 assert.deepEqual(ids(findRecords(p,'OBSERVABLE')),['dt_0052','da_0062']);
});

test('exact id beats prefix beats substring beats title, and no record is listed twice',()=>{
 const found=findRecords(fixture(),'rp_0003');
 assert.deepEqual(ids(found),['rp_0003','rp_0003_mirror','mirror_rp_0003','gl_0021']);
 assert.deepEqual(found.map(r=>r.kind),['Repository','Repository','Repository','Goal']);
 assert.deepEqual(found[0].route,{record:'rp_0003'});
 assert.equal(found[0].title,'rp_0003 · super cockpit');
 assert.equal(found[0].status,null);
 /* rp_0003 matches by exact id AND by its own name; it must appear once. */
 assert.equal(new Set(found.map(r=>r.kind+' '+r.id)).size,found.length);
 assert.deepEqual(findRecords(fixture(),'ln_0004')[0],{kind:'Lane',id:'ln_0004',title:'Mobile companion',status:'open',route:{record:'ln_0004'}});
 assert.deepEqual(findRecords(fixture(),'wk_0011')[0],{kind:'Worker',id:'wk_0011',title:'Review proposals',status:'idle',route:{record:'wk_0011'}});
});

test('limit is honoured and defaults to twelve',()=>{
 const p=fixture(),all=findRecords(p,'super',{limit:100});
 assert.equal(all.length,7);
 assert.deepEqual(findRecords(p,'super',{limit:2}),all.slice(0,2));
 assert.deepEqual(findRecords(p,'super'),all);
 /* Enough matches to prove the default is twelve rather than merely large. */
 const crowd={development_tasks:{}};
 for(let i=1;i<=15;i++){const id='dt_10'+String(i).padStart(2,'0');crowd.development_tasks[id]={id,title:'palette sweep '+i};}
 assert.equal(findRecords(crowd,'palette sweep').length,12);
 assert.equal(findRecords(crowd,'palette sweep',{limit:20}).length,15);
 assert.deepEqual(findRecords(crowd,'palette sweep',{limit:3}),findRecords(crowd,'palette sweep').slice(0,3));
 assert.deepEqual(findRecords(p,'super',{limit:0}),[]);
 assert.deepEqual(findRecords(p,'super',{limit:-3}),[]);
 /* Documents current behaviour: an explicit null limit is not replaced by the
  * default, so nothing is returned. Change module and test together if
  * clamping to the default is preferred. */
 assert.deepEqual(findRecords(p,'super',{limit:null}),[]);
});

test('a blank or non-string query, a missing projection and malformed records return empty or safe results',()=>{
 const p=fixture();
 for(const q of ['','   ','\n\t',42,0,null,undefined,{},[],true])assert.deepEqual(findRecords(p,q),[],'query '+String(q));
 assert.deepEqual(findRecords(p),[]);
 for(const bad of [null,undefined,'nope',42,true])assert.deepEqual(findRecords(bad,'dt_0052'),[],'projection '+String(bad));
 const messy={
  development_tasks:{
   dt_0099:{id:'dt_0099',title:42,status:{}},
   broken:null,
   worse:'text',
   nameless:{title:'dt_0099 twin'},
   numeric:{id:7,title:'dt_0099 number'},
  },
  development_attempts:[],
  workspaces:'nope',
  goals:null,
  lanes:{ln:{id:'ln_0004'}},
 };
 let found;
 assert.doesNotThrow(()=>{found=findRecords(messy,'dt_0099');});
 assert.deepEqual(found,[{kind:'Development plan',id:'dt_0099',title:'dt_0099',status:null,route:{task:'dt_0099'}}]);
 assert.deepEqual(findRecords(messy,'ln_0004'),[{kind:'Lane',id:'ln_0004',title:'ln_0004',status:null,route:{record:'ln_0004'}}]);
});

test('the finder is pure: repeated calls agree and the projection is never mutated',()=>{
 const p=fixture(),before=JSON.parse(JSON.stringify(p));
 const first=findRecords(p,'super'),second=findRecords(p,'super');
 assert.deepEqual(first,second);
 assert.notEqual(first,second);
 /* Results must be fresh objects, not references into the projection. */
 first[0].title='edited';first[0].route.task='edited';
 assert.deepEqual(p,before);
 assert.deepEqual(findRecords(p,'super'),second);
 assert.deepEqual(findRecords(fixture(),'rp_0003'),findRecords(fixture(),'rp_0003'));
});
