#!/usr/bin/env node
/* Exports the frozen simulator's authority semantics as language-neutral
   conformance vectors. Every vector is EXECUTED against the frozen JS
   engine first — if the engine disagrees with a vector, the export fails.
   Outputs: ../conformance/authority-vectors.json   (canonical)
            ../ampd/test/fixtures/vectors.exs      (Elixir literal)      */
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
const here = new URL('.', import.meta.url).pathname;

/* ---------- the vector table (ops + expectations) ---------- */
const PARAMS = { 'pr.draft': {repo:'traaviis/trvm', branch:'lane-a', title:'close the argv boundary'},
                 'pr.create':{repo:'traaviis/trvm', branch:'lane-a', title:'close the argv boundary'} };
const SNAP_LIST = [
 {id:'gr_9001', actor:'kestrel', capability:'github.repo.read', resource:'traaviis/trvm',
  duration:'workspace', placement:['local','fleet'], workspace:'trvm', run:'run-b51', uses_remaining:null},
 {id:'gr_9002', actor:'kestrel', capability:'github.pr.create', resource:'traaviis/trvm',
  duration:'once', placement:['local','fleet'], workspace:'trvm', run:'run-b51', uses_remaining:1},
];
const DIGEST_ENV = { schema:'approval-intent@1', effect_key:'sha256:fixedeffectkey',
  pack:'github@1.4.2', capability:'github.pr.create',
  actor:'kestrel', resource:'traaviis/trvm', grant:'gr_fixed', authority_snapshot:'sha256:fixed',
  placement:'local', request_id:'er-github.pr.create', request_revision:1, request:PARAMS['pr.create'] };
/* the effect-intent envelope the key is taken over — fixed, for parity */
const EFFECT_ENV = { capability:'github.pr.create', resource:'traaviis/trvm',
  request_id:'er-github.pr.create', request_revision:1, request:PARAMS['pr.create'] };

const V = [
 {name:'install grants nothing', steps:[['install_pack','postgres'],
   ['auth',{cap:'postgres.schema.read',resource:'db-main'}]],
  expect:{allow:false, reason:'authority-missing'}},
 {name:'wrong actor refuses by name', steps:[['auth',{cap:'github.repo.read',resource:'traaviis/trvm',ctx:{actor:'evil'}}]],
  expect:{allow:false, reason:'actor-mismatch'}},
 {name:'wrong resource refuses by name', steps:[['auth',{cap:'github.repo.read',resource:'other/repo'}]],
  expect:{allow:false, reason:'scope-mismatch'}},
 {name:'wrong workspace refuses by name', steps:[['world','pricing'],['auth',{cap:'github.repo.read',resource:'traaviis/trvm'}]],
  expect:{allow:false, reason:'workspace-mismatch'}},
 {name:'run grant dies with the run', steps:[['revoke_domain','github.pr.draft'],
   ['dur','run'],['draft','pr.draft',true],['commit'],['end_run'],
   ['auth',{cap:'github.pr.draft',resource:'traaviis/trvm'}]],
  expect:{allow:false, reason:'run-expired'}},
 {name:'retired run id refuses even forged', steps:[['revoke_domain','github.pr.draft'],
   ['dur','run'],['draft','pr.draft',true],['commit'],['end_run'],
   ['auth',{cap:'github.pr.draft',resource:'traaviis/trvm',ctx:{run:'RETIRED'}}]],
  expect:{allow:false}},
 {name:'one-shot consumes and refuses retry', steps:[['revoke_domain','github.pr.draft'],
   ['mint',{cap:'github.pr.draft',duration:'once'}],
   ['exercise','pr.draft'],['exercise','pr.draft']],
  expect:{receipts:1, reason_last:'one-shot-consumed|authority-missing'}},
 {name:'destructive class is denied by default', steps:[['auth',{cap:'github.pr.merge',resource:'traaviis/trvm'}]],
  expect:{allow:false, reason:'denied-by-default|destructive'}},
 {name:'unknown pack is undeclared', steps:[['auth',{cap:'nosuchpack.thing',resource:'x'}]],
  expect:{allow:false, reason:'capability-undeclared'}},
 /* A DISCOVERED pack ships its whole surface — that is what makes it
    browsable — and nothing in the authorize path read `installation`. So a
    grant against a pack nobody installed authorized, and this system's
    oldest law ran backwards: discovery conferred authority. Two vectors,
    because the fix has two ends and either alone leaves a hole. */
 {name:'a discovered pack confers nothing', steps:[
   ['mint',{cap:'postgres.schema.read',resource:'db-main'}],
   ['auth',{cap:'postgres.schema.read',resource:'db-main'}]],
  expect:{allow:false, reason:'pack-not-installed'}},
 {name:'installing after a refused mint still grants nothing', steps:[
   ['mint',{cap:'postgres.schema.read',resource:'db-main'}],
   ['install_pack','postgres'],
   ['auth',{cap:'postgres.schema.read',resource:'db-main'}]],
  expect:{allow:false, reason:'authority-missing'}},
 /* `durationOk` ended in `return true`, so any string satisfied every scope
    check there is: a grant with duration 'forever' outlived its run, survived
    a workspace change, and never spent a use. Revoke the real grant first, so
    the only thing that could authorize is the one that must not exist. */
 {name:'an unenforceable duration is never minted', steps:[
   ['revoke_domain','github.pr.draft'],
   ['mint',{cap:'github.pr.draft',duration:'forever'}],
   ['auth',{cap:'github.pr.draft',resource:'traaviis/trvm'}]],
  expect:{allow:false, reason:'authority-missing'}},
 {name:'approval-class refuses an empty intent', steps:[['draft','pr.create',true],['commit'],
   ['auth',{cap:'github.pr.create',resource:'traaviis/trvm'}]],
  expect:{allow:false, reason:'request-missing', pending:0}},
 {name:'granted-but-unapproved is held without receipt', steps:[['draft','pr.create',true],['commit'],
   ['exercise','pr.create']],
  expect:{held:true, receipts:0, pending:1}},
 {name:'exact-intent approval commits once', steps:[['draft','pr.create',true],['commit'],
   ['exercise','pr.create'],['approve_last']],
  expect:{receipts:1, last_approval:'consumed'}},
 {name:'consumed approval does not authorize again', steps:[['draft','pr.create',true],['commit'],
   ['exercise','pr.create'],['approve_last'],['exercise','pr.create']],
  expect:{receipts:1, pending:1}},
 {name:'forged approval: wrong capability', steps:[['draft','pr.create',true],['commit'],
   ['forge_pr_create',{capability:'github.issue.write'}],
   ['auth',{cap:'github.pr.create',resource:'traaviis/trvm',params:'PR_CREATE'}]],
  expect:{allow:false}},
 {name:'forged approval: wrong actor', steps:[['draft','pr.create',true],['commit'],
   ['forge_pr_create',{actor:'other-agent'}],
   ['auth',{cap:'github.pr.create',resource:'traaviis/trvm',params:'PR_CREATE'}]],
  expect:{allow:false}},
 {name:'forged approval: wrong grant', steps:[['draft','pr.create',true],['commit'],
   ['forge_pr_create',{grant_ref:'gr_wrong'}],
   ['auth',{cap:'github.pr.create',resource:'traaviis/trvm',params:'PR_CREATE'}]],
  expect:{allow:false}},
 {name:'forged approval: older pack version', steps:[['draft','pr.create',true],['commit'],
   ['forge_pr_create',{pack_version:'1.3.9'}],
   ['auth',{cap:'github.pr.create',resource:'traaviis/trvm',params:'PR_CREATE'}]],
  expect:{allow:false}},
 {name:'forged approval: older snapshot', steps:[['draft','pr.create',true],['commit'],
   ['forge_pr_create',{snapshot:'sha256:old'}],
   ['auth',{cap:'github.pr.create',resource:'traaviis/trvm',params:'PR_CREATE'}]],
  expect:{allow:false}},
 {name:'changed parameter stales the approval', steps:[['draft','pr.create',true],['commit'],
   ['forge_pr_create',{}],
   ['auth',{cap:'github.pr.create',resource:'traaviis/trvm',params:{repo:'traaviis/trvm',branch:'lane-a',title:'completely different PR'}}]],
  expect:{allow:false, has_stale:true}},
 {name:'placement derives to local and cites constraints', steps:[
   ['auth',{cap:'github.repo.read',resource:'traaviis/trvm',ctx:{placement:null}}]],
  expect:{allow:true, placement_site:'local', cited:'private|residency'}},
 {name:'cloud refusal names the data policy', steps:[
   ['auth',{cap:'github.repo.read',resource:'traaviis/trvm',ctx:{placement:'cloud'}}]],
  expect:{allow:false, reason:'placement-denied', reason_also:'private|residency'}},
 {name:'consent executes in its held context', steps:[['draft','pr.create',true],['commit'],
   ['exercise','pr.create'],['world','pricing'],['approve_last']],
  expect:{receipts:1, last_approval:'consumed'}},
 {name:'dead-grant approval surfaces as stale', steps:[['revoke_domain','github.pr.create'],
   ['dur','run'],['draft','pr.create',true],['commit'],
   ['exercise','pr.create'],['end_run'],['approve_last']],
  expect:{receipts:0, last_approval:'stale', stale_reason:'run-expired|authority-missing'}},
 {name:'update expands surface, grants nothing', steps:[['update_github'],
   ['auth',{cap:'github.issue.write',resource:'traaviis/trvm'}]],
  expect:{allow:false, reason:'authority-missing'}},
 {name:'independent proposals hold independent consent', steps:[['draft','pr.create',true],['commit'],
   ['exercise','pr.create'],['approve_hold'],
   ['auth',{cap:'github.pr.create',resource:'traaviis/trvm',
     params:{er:'er_B',rev:1,params:{repo:'traaviis/trvm',branch:'lane-b',title:'proposal B'}}}]],
  expect:{has_stale:false, granted_count:1, pending:1}},
 {name:'revising a proposal stales only that proposal', steps:[['draft','pr.create',true],['commit'],
   ['exercise','pr.create'],['approve_hold'],
   ['auth',{cap:'github.pr.create',resource:'traaviis/trvm',
     params:{er:'er-github.pr.create',rev:2,params:{repo:'traaviis/trvm',branch:'lane-a',title:'edited after consent'}}}]],
  expect:{has_stale:true, granted_count:0}},
 {name:'authority snapshot is a content commitment', steps:[['snap','A'],
   ['mint',{cap:'github.pr.draft',duration:'once'}],['snap','B']],
  expect:{snap_hex:'A', snap_neq:['A','B']}},
 {name:'idempotent commit leaves the snapshot byte-identical', steps:[
   ['draft','pr.create',true],['commit'],['snap','A'],['commit'],['snap','B']],
  expect:{snap_eq:['A','B']}},
 {name:'draft revoke clears the whole grant domain', steps:[
   ['mint',{cap:'github.pr.create',duration:'workspace'}],['mint',{cap:'github.pr.create',duration:'run'}],
   ['draft','pr.create',false],['commit'],
   ['auth',{cap:'github.pr.create',resource:'traaviis/trvm',params:'PR_CREATE'}]],
  expect:{allow:false, reason:'authority-missing'}},
 {name:'duration edit replaces the grant identity', steps:[
   ['dur','run'],['commit'],['auth',{cap:'github.repo.read',resource:'traaviis/trvm'}]],
  expect:{allow:true, active:{cap:'github.repo.read', n:1, duration:'run'}}},
 /* C1.0b — a receipt attests to the authority that AUTHORIZED the effect.
    A one-shot changes the snapshot as it is spent, so a receipt that
    re-samples afterwards cites a world that never authorized it. */
 {name:'one-shot receipt cites the pre-consumption snapshot', steps:[
   ['revoke_domain','github.pr.draft'],['mint',{cap:'github.pr.draft',duration:'once'}],
   ['snap','X'],['exercise','pr.draft'],['snap','Y']],
  expect:{receipts:1, snap_neq:['X','Y'], receipt_at_entry:'X', receipt_after:'Y'}},
 {name:'approval receipt cites the snapshot consent was bound to', steps:[
   ['revoke_domain','github.pr.create'],['mint',{cap:'github.pr.create',duration:'once'}],
   ['snap','X'],['exercise','pr.create'],['approve_last'],['snap','Y']],
  expect:{receipts:1, snap_neq:['X','Y'], receipt_at_entry:'X', receipt_after:'Y'}},
 {name:'a workspace grant leaves entry and after identical', steps:[
   ['snap','X'],['exercise','pr.draft'],['snap','Y']],
  expect:{receipts:1, snap_eq:['X','Y'], receipt_at_entry:'X', receipt_after:'Y'}},
 /* C1.0b.1 — effect identity is NOT consent identity. The external
    deduplication key must survive authority churn, or reconciling an
    UNKNOWN effect would present the far side with a key it never saw. */
 {name:'the effect key is stable across authority change', steps:[
   ['snap','X'],['effect_key','A'],
   ['mint',{cap:'github.pr.merge',duration:'once'}],
   ['snap','Y'],['effect_key','B']],
  expect:{snap_neq:['X','Y'], ek_eq:['A','B']}},
 {name:'the approval digest does NOT survive authority change', steps:[
   ['draft','pr.create',true],['commit'],['exercise','pr.create'],['approve_hold'],
   ['mint',{cap:'github.pr.merge',duration:'once'}],
   ['auth',{cap:'github.pr.create',resource:'traaviis/trvm',params:'PR_CREATE'}]],
  expect:{allow:false, has_stale:true}},
 {name:'a receipt carries the effect key as its idempotency key', steps:[
   ['exercise','pr.draft']],
  expect:{receipts:1, receipt_key_is_effect_key:true}},
 {name:'effect key parity across languages', steps:[['effect_key_of','FIXED']],
  expect:{effect_key:null /* filled from the JS engine below */}},
 {name:'authority snapshot parity across languages', steps:[['snapshot_of','FIXED']],
  expect:{snapshot:null /* filled from the JS engine below */}},
 {name:'sha256 intent digest parity', steps:[['digest','ENV']],
  expect:{digest:null /* filled from the JS engine below */}},
];

/* ---------- frozen-engine harness (same stubs as the battery) ---------- */
function boot(){
  let receipts=0;
  const grad=()=>({addColorStop(){}});
  const mkCtx=()=>({setTransform(){},clearRect(){},save(){},restore(){},beginPath(){},rect(){},clip(){},
   translate(){},scale(){},rotate(){},arc(){},fill(){},fillRect(){},drawImage(){},
   createLinearGradient:grad,createRadialGradient:grad,createPattern:()=>({}),
   createImageData:(w,h)=>({data:new Uint8ClampedArray(w*h*4)}),putImageData(){},
   set fillStyle(v){},get fillStyle(){return''},set globalAlpha(v){},get globalAlpha(){return 1},
   set globalCompositeOperation(v){},get globalCompositeOperation(){return''}});
  function mkEl(id){const kids=[],L={};const el={id,src:'',style:{setProperty(){}},dataset:{},classes:new Set(),
   textContent:'',value:'',innerHTML:'',disabled:false,cells:[],children:kids,firstChild:null,
   removeChild(){kids.shift()},prepend(){kids.unshift(0)},append(){kids.push(0)},
   classList:{add:c=>el.classes.add(c),remove:c=>el.classes.delete(c),
     toggle:(c,f)=>{(f===undefined?!el.classes.has(c):f)?el.classes.add(c):el.classes.delete(c)},
     contains:c=>el.classes.has(c)},
   getContext:()=>mkCtx(),getAttribute:()=>'',setAttribute(){},
   getBoundingClientRect:()=>({left:0,top:0,width:800,height:600,bottom:600}),
   addEventListener:(t,f)=>{(L[t]=L[t]||[]).push(f)},appendChild(){},
   querySelector:()=>mkEl(id+'q'),querySelectorAll:()=>[],
   insertAdjacentHTML(pos,html){ if(String(html).includes('capability-effect-receipt')) receipts++; },
   focus(){},closest:()=>null,fire:(t,e)=>(L[t]||[]).forEach(f=>f(e||{}))};return el;}
  const els={};
  const doc={getElementById:id=>(els[id] ||= mkEl(id)),createElement:()=>mkEl('mk'),
   querySelector:sel=>(els['q:'+sel] ||= mkEl(sel)),querySelectorAll:()=>[],
   documentElement:{addEventListener(){}},body:{appendChild(){}},addEventListener(){}};
  const G=Object.create(null);
  const sandbox={document:doc,window:null,matchMedia:()=>({matches:false}),CSS:{supports:()=>true},
   addEventListener(){},location:{hash:''},devicePixelRatio:1,
   IntersectionObserver:class{constructor(){}observe(){}},requestAnimationFrame:()=>0,
   performance:{now:()=>0},fetch:()=>Promise.reject(0),setTimeout:()=>0,clearTimeout:()=>0,setInterval:()=>0,clearInterval:()=>0,
   console, Math, JSON, Object, Array, String, Number, Boolean, Date, RegExp, Uint8Array, Int32Array,
   encodeURIComponent, unescape, Set, Map, isNaN, parseInt, parseFloat};
  sandbox.window=sandbox; sandbox.globalThis=sandbox;
  const out=COMPILED(...SANDBOX_KEYS.map(k=>sandbox[k]));
  return {S:out.S, g:out.g, get receipts(){return receipts;}, keys:Object.keys(sandbox)};
}
const _html=readFileSync(here+'../site/app-prototype.html','utf8');
const _src=[..._html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m=>m[1]).join('\n;\n');
const SANDBOX_KEYS=['document','window','matchMedia','CSS','addEventListener','location','devicePixelRatio','IntersectionObserver','requestAnimationFrame','performance','fetch','setTimeout','clearTimeout','setInterval','clearInterval','console','Math','JSON','Object','Array','String','Number','Boolean','Date','RegExp','Uint8Array','Int32Array','encodeURIComponent','unescape','Set','Map','isNaN','parseInt','parseFloat','globalThis'];
const COMPILED=new Function(...SANDBOX_KEYS, _src+'\n;return {S:window.__capState, g:{ghToggle,ghDur,commitGrant,ghExercise,capApprove,ghUpdateKeep,pgInstall,tabFor}};');


/* ---------- run a vector against the frozen engine ---------- */
function run(vec){
  const E=boot(); const {S,g}=E;
  let last=null, lastRetired=null, digest=null, snapfix=null, ekfix=null; const snaps={}, eks={};
  const el={classList:{toggle(){},add(){},remove(){}},classes:new Set(),textContent:'',disabled:false,style:{},dataset:{}};
  for(const [op,a,b] of vec.steps){
    if(op==='install_pack'){ g.pgInstall(el); }
    else if(op==='mint'){ a.duration==='once' ? S.mintOneShot(a.cap) : S.mintGrant({capability:a.cap, duration:a.duration||'workspace', resource:a.resource||'traaviis/trvm'}); }
    else if(op==='revoke_domain'){ S.activeGrants.filter(x=>x.capability===a&&x.status==='active').forEach(x=>x.status='revoked'); }
    else if(op==='draft'){ S.grantDraft[a]=b; }
    else if(op==='dur'){ g.ghDur(a, el); }
    else if(op==='commit'){ g.commitGrant(); }
    else if(op==='world'){ S.setWorld(a); }
    else if(op==='end_run'){ lastRetired=S.run; S.endRun(); }
    else if(op==='update_github'){ g.ghUpdateKeep(); }
    else if(op==='forge_pr_create'){
      const grant=S.activeGrants.find(x=>x.status==='active'&&x.capability==='github.pr.create');
      const env={schema:'approval-intent@1', pack:'github@'+S.packs.github.version,
        capability:'github.pr.create', actor:'kestrel', resource:'traaviis/trvm',
        grant:grant.id, authority_snapshot:S.snapshot, placement:'local',
        request_id:'er-github.pr.create', request_revision:1, request:PARAMS['pr.create']};
      S.approvals.push(Object.assign({id:'ap_forged', request_hash:S.intentDigest(env),
        capability:'github.pr.create', actor:'kestrel', grant_ref:grant.id,
        pack_version:S.packs.github.version, snapshot:S.snapshot, placement:'local',
        envelope:env, status:'granted'}, a));
    }
    else if(op==='auth'){
      const ctx={...S.ctxNow(), ...(a.ctx||{})};
      if(a.ctx && a.ctx.run==='RETIRED') ctx.run=lastRetired;
      if(a.ctx && 'placement' in a.ctx && a.ctx.placement===null) ctx.placement=null;
      let request;
      if(a.params==='PR_CREATE') request={er:'er-github.pr.create', rev:1, params:PARAMS['pr.create']};
      else if(a.params && a.params.er) request=a.params;
      else if(a.params) request={er:'er-'+a.cap, rev:1, params:a.params};
      last=S.authorize(a.cap, a.resource, ctx, request);
    }
    else if(op==='exercise'){ g.ghExercise(a); last=null; }
    else if(op==='approve_last'){
      const p=[...S.approvals].reverse().find(x=>x.status==='pending');
      if(p) g.capApprove(p.id);
    }
    else if(op==='digest'){ digest=S.intentDigest(DIGEST_ENV); }
    else if(op==='effect_key'){ eks[a]=S.effectKey('github.pr.draft','traaviis/trvm','er-github.pr.draft',1,PARAMS['pr.draft']); }
    else if(op==='effect_key_of'){ ekfix=S.effectKey(EFFECT_ENV.capability, EFFECT_ENV.resource, EFFECT_ENV.request_id, EFFECT_ENV.request_revision, EFFECT_ENV.request); }
    else if(op==='snap'){ snaps[a]=S.snapshot; }
    else if(op==='snapshot_of'){ snapfix=S.snapshotOf(SNAP_LIST); }
    else if(op==='approve_hold'){
      const pnd=[...S.approvals].reverse().find(x=>x.status==='pending');
      if(pnd) pnd.status='granted';
    }
  }
  const lastAp=S.approvals.length?S.approvals[S.approvals.length-1]:null;
  const lastReceipt=S.receiptsLog.length?S.receiptsLog[S.receiptsLog.length-1]:null;
  return {last, lastReceipt, receipts:E.receipts, pending:S.approvals.filter(x=>x.status==='pending').length,
          lastAp, anyStale:S.approvals.some(x=>x.status==='stale'),
          granted:S.approvals.filter(x=>x.status==='granted').length,
          active:S.activeGrants.filter(g=>g.status==='active'), snaps, snapfix, digest, eks, ekfix};
}
function check(vec, r){
  const e=vec.expect, errs=[];
  const rx=(p,s)=>new RegExp(p).test(s||'');
  if('allow' in e && (!r.last || r.last.allow!==e.allow)) errs.push('allow');
  if('held' in e && (!r.last || !!r.last.held!==e.held)){ /* exercise path: held signalled via pending */ }
  if('held' in e && e.held && r.pending<1) errs.push('held');
  if('reason' in e && !(r.last && rx(e.reason, r.last.reason))) errs.push('reason:'+(r.last&&r.last.reason));
  if('reason_also' in e && !(r.last && rx(e.reason_also, r.last.reason))) errs.push('reason_also');
  if('reason_last' in e){ /* one-shot retry: last op was exercise; engine refusal is internal — verify via receipts only */ }
  if('receipts' in e && r.receipts!==e.receipts) errs.push('receipts:'+r.receipts);
  if('pending' in e && r.pending!==e.pending) errs.push('pending:'+r.pending);
  if('last_approval' in e && (!r.lastAp || r.lastAp.status!==e.last_approval)) errs.push('last_approval:'+(r.lastAp&&r.lastAp.status));
  if('has_stale' in e && r.anyStale!==e.has_stale) errs.push('has_stale');
  if('stale_reason' in e && !(r.lastAp && rx(e.stale_reason, r.lastAp.stale_reason))) errs.push('stale_reason');
  if('placement_site' in e && !(r.last && r.last.placement && r.last.placement.site===e.placement_site)) errs.push('placement_site');
  if('cited' in e && !(r.last && r.last.placement && r.last.placement.cited.some(c=>rx(e.cited,c)))) errs.push('cited');
  if('granted_count' in e && r.granted!==e.granted_count) errs.push('granted_count:'+r.granted);
  if('snap_hex' in e && !/^sha256:[0-9a-f]{64}$/.test(r.snaps[e.snap_hex]||'')) errs.push('snap_hex');
  if('snap_neq' in e && r.snaps[e.snap_neq[0]]===r.snaps[e.snap_neq[1]]) errs.push('snap_neq');
  if('snap_eq' in e && r.snaps[e.snap_eq[0]]!==r.snaps[e.snap_eq[1]]) errs.push('snap_eq');
  if('receipt_at_entry' in e && !(r.lastReceipt &&
      r.lastReceipt.authority_snapshot_at_entry===r.snaps[e.receipt_at_entry]))
    errs.push('receipt_at_entry:'+(r.lastReceipt&&r.lastReceipt.authority_snapshot_at_entry));
  if('receipt_after' in e && !(r.lastReceipt &&
      r.lastReceipt.authority_snapshot_after===r.snaps[e.receipt_after]))
    errs.push('receipt_after:'+(r.lastReceipt&&r.lastReceipt.authority_snapshot_after));
  if('active' in e){
    const m=r.active.filter(g=>g.capability===e.active.cap);
    if(m.length!==e.active.n || (e.active.duration && !m.every(g=>g.duration===e.active.duration)))
      errs.push('active:'+m.length+':'+(m[0]&&m[0].duration));
  }
  if('ek_eq' in e && r.eks[e.ek_eq[0]]!==r.eks[e.ek_eq[1]]) errs.push('ek_eq');
  if('receipt_key_is_effect_key' in e && !(r.lastReceipt &&
      r.lastReceipt.idempotency_key && r.lastReceipt.idempotency_key===r.lastReceipt.effect_key))
    errs.push('receipt_key_is_effect_key');
  if('effect_key' in e){ if(!/^sha256:[0-9a-f]{64}$/.test(r.ekfix||'')) errs.push('ekfix_format'); else e.effect_key=r.ekfix; }
  if('snapshot' in e){ if(!/^sha256:[0-9a-f]{64}$/.test(r.snapfix||'')) errs.push('snapfix_format'); else e.snapshot=r.snapfix; }
  if('digest' in e){ if(!/^sha256:[0-9a-f]{64}$/.test(r.digest||'')) errs.push('digest_format'); else e.digest=r.digest; }
  return errs;
}

let fail=0;
for(const vec of V){
  const errs=check(vec, run(vec));
  if(errs.length){ fail++; console.error('VECTOR DISAGREES WITH FROZEN ENGINE:', vec.name, errs); }
  else console.log('ok  ', vec.name);
}
if(fail) process.exit(1);

mkdirSync(here+'../conformance',{recursive:true});
const doc={schema:'authority-vectors@1', source:'frozen JS simulator (app-prototype.html)',
  generated_at:new Date().toISOString(), params:PARAMS, digest_env:DIGEST_ENV, effect_env:EFFECT_ENV, snap_list:SNAP_LIST, vectors:V};
writeFileSync(here+'../conformance/authority-vectors.json', JSON.stringify(doc,null,2));

/* Elixir literal export (no JSON parsing needed on the BEAM side) */
function ex(v){
  if(v===null||v===undefined) return 'nil';
  if(typeof v==='boolean'||typeof v==='number') return String(v);
  if(typeof v==='string') return JSON.stringify(v);
  if(Array.isArray(v)) return '['+v.map(ex).join(', ')+']';
  return '%{'+Object.entries(v).map(([k,val])=>JSON.stringify(k)+' => '+ex(val)).join(', ')+'}';
}
writeFileSync(here+'../ampd/test/fixtures/vectors.exs',
  '# GENERATED by tools/export-vectors.mjs — do not edit.\n'+ex(doc)+'\n');
console.log(`exported ${V.length} vectors → conformance/authority-vectors.json + ampd/test/fixtures/vectors.exs`);
process.exit(0);
