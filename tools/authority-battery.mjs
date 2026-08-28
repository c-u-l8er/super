#!/usr/bin/env node
/* Negative battery for the capability law. Loads the prototype headlessly
   and fails the release if any authority boundary can be bypassed:
   selection must not grant; ungranted/denied exercise must not receipt;
   one-shots must consume; catalog tabs must derive from install state.  */
import { readFileSync } from 'node:fs';
const here = new URL('.', import.meta.url).pathname;

let receipts = 0;
const grad = () => ({addColorStop(){}});
const mkCtx = () => ({ setTransform(){},clearRect(){},save(){},restore(){},beginPath(){},rect(){},clip(){},
  translate(){},scale(){},rotate(){},arc(){},fill(){},fillRect(){},drawImage(){},
  createLinearGradient:grad,createRadialGradient:grad,createPattern:()=>({}),
  createImageData:(w,h)=>({data:new Uint8ClampedArray(w*h*4)}),putImageData(){},
  set fillStyle(v){},get fillStyle(){return''},set globalAlpha(v){},get globalAlpha(){return 1},
  set globalCompositeOperation(v){},get globalCompositeOperation(){return''} });
function mkEl(id){ const listeners={};
  const kids=[];
  const el = { id, style:{setProperty(){}}, dataset:{}, classes:new Set(),
    textContent:'', value:'', innerHTML:'', disabled:false, cells:[],
    children:kids, firstChild:null, removeChild(){kids.shift()}, prepend(){kids.unshift(0); el.firstChild=el;}, append(){kids.push(0)},
    classList:{ add:c=>el.classes.add(c), remove:c=>el.classes.delete(c),
      toggle:(c,f)=>{ (f===undefined? !el.classes.has(c):f) ? el.classes.add(c):el.classes.delete(c); },
      contains:c=>el.classes.has(c) },
    getContext:()=>mkCtx(), getAttribute:()=>'', setAttribute(){},
    getBoundingClientRect:()=>({left:0,top:0,width:800,height:600,bottom:600}),
    addEventListener:(t,f)=>{(listeners[t]=listeners[t]||[]).push(f)},
    appendChild(){}, querySelector:()=>mkEl(id+'-q'), querySelectorAll:()=>[],
    insertAdjacentHTML(pos, html){ if(String(html).includes('capability-effect-receipt')) receipts++; },
    focus(){}, closest:()=>null, fire:(t,e)=>(listeners[t]||[]).forEach(f=>f(e||{})) };
  return el;
}
const els = {};
const doc = {
  getElementById: id => (els[id] ||= mkEl(id)),
  createElement: () => mkEl('mk'),
  querySelector: sel => (els['q:'+sel] ||= mkEl(sel)),
  querySelectorAll: () => [],
  documentElement:{addEventListener(){}},
  body:{appendChild(){}},
  addEventListener(){},
};
global.document = doc; global.window = global;
global.matchMedia = () => ({matches:false});
global.CSS = {supports:()=>true};
global.addEventListener = () => {};
global.location = {hash:''};
global.devicePixelRatio = 1;
global.IntersectionObserver = class{constructor(){}observe(){}};
global.requestAnimationFrame = () => 0;
global.performance = {now:()=>0};
global.fetch = () => Promise.reject(0);
global.setTimeout = (f)=>0; global.clearTimeout=()=>0;

const html = readFileSync(here+'../site/app-prototype.html','utf8');
const src = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m=>m[1]).join('\n;\n');
try { (0,eval)(src); } catch(e){ console.error('BOOT THROW:', e.message); process.exit(1); }

const S = global.__capState;
import { createHash } from 'node:crypto';
/* THE BATTERY COUNTS ITSELF.

   Nothing derived this number until W.1.3.2a. The review brief said 148
   browser assertions and the blueprint said 64, both typed by hand, while
   the battery actually emitted 150 — and 64 had been wrong since W.1.3.
   That is the same defect `stamp-counts.mjs` exists to prevent for vectors
   and BEAM tests, in the one suite it did not cover. A count that is
   transcribed rather than measured drifts silently in exactly the
   direction that flatters the round. */
const fails = [];
let attempted = 0;
const t = (name, cond) => { attempted++; if(!cond){ fails.push(name); console.error('FAIL', name); } else console.log('ok  ', name); };
const ctx = () => S.ctxNow();
const el = () => mkEl('x');

/* ============ C0.2 — still enforced ============ */
global.ghToggle('pr.create', el());
t('selection edits draft only', S.grantDraft['pr.create']===true &&
  !S.activeGrants.some(g=>g.capability==='github.pr.create'));
global.ghToggle('pr.create', el());

let a = S.authorize('github.repo.read','traaviis/trvm',{...ctx(),actor:'evil_other_agent'});
t('wrong actor refuses',      !a.allow && /actor-mismatch/.test(a.reason));
a = S.authorize('github.repo.read','some-other/repository',ctx());
t('wrong repo refuses',       !a.allow && /scope-mismatch/.test(a.reason));
a = S.authorize('github.repo.read','traaviis/trvm',{...ctx(),placement:'cloud'});
t('wrong placement refuses',  !a.allow && /placement-denied/.test(a.reason));
S.setWorld('pricing');
a = S.authorize('github.repo.read','traaviis/trvm',ctx());
t('other workspace refuses',  !a.allow && /workspace-mismatch/.test(a.reason));
S.setWorld('trvm');

const seeded = S.activeGrants.find(g=>g.capability==='github.pr.draft' && g.duration==='workspace');
seeded.status='revoked';
S.mintOneShot('github.pr.draft');
const r0 = receipts;
global.ghExercise('pr.draft');
t('one-shot authorizes once',          receipts===r0+1);
global.ghExercise('pr.draft');
t('consumed one-shot refuses retry',   receipts===r0+1);

global.ghDur('run', el());
S.grantDraft['pr.draft']=true;
global.commitGrant();
global.ghExercise('pr.draft');
t('run grant authorizes in-run',       receipts===r0+2);
S.endRun();
global.ghExercise('pr.draft');
t('ended run refuses',                 receipts===r0+2);
S.activeGrants.filter(g=>g.capability==='github.pr.draft'&&g.status==='active').forEach(g=>g.status='revoked');
S.grantDraft['pr.draft']=false;
global.ghDur('workspace', el());

/* ============ C0.3 — consent identity & provenance ============ */

/* the label must be true: real canonical SHA-256 */
t('sha256 is actual SHA-256',
  S.sha256hex('abc') === createHash('sha256').update('abc').digest('hex'));
t('canonical form is key-order independent',
  S.canon({b:1,a:{d:2,c:[3,{f:4,e:5}]}}) === S.canon({a:{c:[3,{e:5,f:4}],d:2},b:1}));
t('intent digests are 64-hex sha256',
  /^sha256:[0-9a-f]{64}$/.test(S.intentDigest({x:1})));

/* approval-class effects refuse an empty intent */
global.ghEsc('workspace');                    /* durable pr.create eligibility */
a = S.authorize('github.pr.create','traaviis/trvm',ctx());
t('missing intent refuses, never hashes {}', !a.allow && /request-missing/.test(a.reason) &&
  !S.approvals.some(x=>x.status==='pending'));

/* held → approve exact → committed once */
const r1 = receipts;
global.ghExercise('pr.create');
let pend = S.approvals.find(x=>x.status==='pending');
t('granted-but-unapproved is HELD',    receipts===r1 && !!pend);
global.capApprove(pend.id);
t('exact-intent approval commits once', receipts===r1+1 && pend.status==='consumed');

/* forged approvals with the right digest but wrong identity must never authorize */
const grant = S.activeGrants.find(g=>g.status==='active' && g.capability==='github.pr.create');
const params={repo:'traaviis/trvm',branch:'lane-a',title:'close the argv boundary'};
const env={ schema:'approval-intent@1', pack:'github@'+S.packs.github.version,
  capability:'github.pr.create', actor:'kestrel', resource:'traaviis/trvm',
  grant:grant.id, authority_snapshot:S.snapshot, placement:'local',
  request_id:'er-github.pr.create', request_revision:1, request:params };
const digest=S.intentDigest(env);
function forged(over){ return Object.assign({ id:'ap_forged', request_hash:digest,
  capability:'github.pr.create', actor:'kestrel', grant_ref:grant.id,
  pack_version:S.packs.github.version, snapshot:S.snapshot, placement:'local',
  envelope:env, status:'granted' }, over); }
function tryForged(name, over){
  const before=S.approvals.length;
  S.approvals.push(forged(over));
  const res=S.authorize('github.pr.create','traaviis/trvm',ctx(),{params});
  t(name, !res.allow);
  S.approvals.splice(before);                  /* remove the forgery + any pending it caused */
}
tryForged('approval for another capability refuses', {capability:'github.issue.write'});
tryForged('approval for another actor refuses',      {actor:'other-agent'});
tryForged('approval under another grant refuses',    {grant_ref:'gr_wrong'});
tryForged('approval from older pack version stales', {pack_version:'1.3.9'});
tryForged('approval from older snapshot stales',     {snapshot:'sha256:old…'});
tryForged('approval from another placement refuses', {placement:'cloud'});

/* modified request after consent → old approval STALE, effect held */
const r2=receipts;
S.approvals.push(forged({id:'ap_live'}));
const res2=S.authorize('github.pr.create','traaviis/trvm',ctx(),
  {params:{...params, title:'completely different PR'}});
t('changed parameter stales the approval', !res2.allow &&
  S.approvals.find(x=>x.id==='ap_live').status==='stale' && receipts===r2);
S.approvals.length=0;

/* two grants in the domain, draft unchecks → BOTH revoked */
S.activeGrants.filter(g=>g.capability==='github.pr.create'&&g.status==='active').forEach(g=>g.status='revoked');
S.mintGrant({capability:'github.pr.create', duration:'workspace'});
S.mintGrant({capability:'github.pr.create', duration:'run'});
S.grantDraft['pr.create']=false;
global.commitGrant();
t('draft revoke clears the WHOLE domain',
  !S.activeGrants.some(g=>g.capability==='github.pr.create' && g.status==='active'));

/* duration edit = revoke old, mint new */
S.grantDraft['repo.read']=true;
global.ghDur('run', el());
global.commitGrant();
const rr=S.activeGrants.filter(g=>g.capability==='github.repo.read'&&g.status==='active');
t('workspace→run replaces the grant', rr.length===1 && rr[0].duration==='run');

/* idempotence: same desired grant twice → no change */
const n0=S.activeGrants.length;
global.commitGrant();
t('same desired grant is idempotent', S.activeGrants.length===n0 &&
  S.activeGrants.filter(g=>g.capability==='github.repo.read'&&g.status==='active').length===1);
global.ghDur('workspace', el());
global.commitGrant();     /* restore repo.read to workspace duration */

/* ============ C0.4 — placement derivation, held-context consent, pack generality ============ */

/* placement is derived and cited, not asserted */
a = S.authorize('github.repo.read','traaviis/trvm',{...ctx(), placement:null});
t('placement derives to local by default', a.allow && a.placement && a.placement.site==='local');
t('the derivation cites its constraints',  a.placement.cited.length>=2 &&
  a.placement.cited.some(c=>/private|residency/.test(c)));
a = S.authorize('github.repo.read','traaviis/trvm',{...ctx(), placement:'cloud'});
t('cloud refusal names the policy',        !a.allow && /placement-denied/.test(a.reason) &&
  /(private|residency)/.test(a.reason));

/* receipts are durable model objects that cite the derivation */
S.mintGrant({capability:'github.pr.draft', duration:'workspace'});
const rl0=S.receiptsLog.length;
global.ghExercise('pr.draft');
const rec=S.receiptsLog[S.receiptsLog.length-1];
t('receipt model entry exists',            S.receiptsLog.length===rl0+1 && rec.committed===true);
t('receipt cites grant + snapshot + derivation', !!rec.grant_ref && !!rec.authority_snapshot_at_entry &&
  rec.placement && rec.placement.cited && rec.placement.cited.length>0);
t('workspace-grant receipt: entry and after agree',
  rec.authority_snapshot_at_entry===rec.authority_snapshot_after);
S.activeGrants.filter(g=>g.capability==='github.pr.draft'&&g.status==='active').forEach(g=>g.status='revoked');

/* C1.0b — a one-shot receipt must cite the snapshot that AUTHORIZED it.
   Before this, emitReceipt re-sampled authoritySnapshot() *after* the
   one-shot was consumed, so the receipt attested to a world that had
   never authorized the effect. */
const osBefore = S.authoritySnapshot();
S.mintOneShot('github.pr.draft');
const osEntry = S.authoritySnapshot();
global.ghExercise('pr.draft');
const osAfter = S.authoritySnapshot();
const rec1 = S.receiptsLog[S.receiptsLog.length-1];
t('minting the one-shot moved the snapshot',      osBefore!==osEntry);
t('consuming the one-shot moved it again',        osEntry!==osAfter);
t('one-shot receipt cites the PRE-consumption snapshot',
  rec1.authority_snapshot_at_entry===osEntry);
t('one-shot receipt also records what remains',   rec1.authority_snapshot_after===osAfter);

/* C1.0b.1 — effect identity ≠ consent identity. The external dedup key must
   survive authority churn; the approval digest must not. */
const ekBefore = S.effectKey('github.pr.draft','traaviis/trvm','er-github.pr.draft',1,
  {repo:'traaviis/trvm', branch:'lane-a', title:'close the argv boundary'});
S.mintOneShot('github.pr.merge');                    // authority moves
const ekAfter = S.effectKey('github.pr.draft','traaviis/trvm','er-github.pr.draft',1,
  {repo:'traaviis/trvm', branch:'lane-a', title:'close the argv boundary'});
t('the effect key survives an authority change',  ekBefore===ekAfter);
t('the effect key is a real sha256',              /^sha256:[0-9a-f]{64}$/.test(ekBefore));
t('effect-intent carries no actor/grant/snapshot',
  !('actor' in S.effectIntent('c','r','e',1,{})) &&
  !('grant' in S.effectIntent('c','r','e',1,{})) &&
  !('authority_snapshot' in S.effectIntent('c','r','e',1,{})));
t('receipt idempotency key IS the effect key',    rec1.idempotency_key===rec1.effect_key &&
  !!rec1.effect_key);
t('receipt keeps the approval digest separately', 'approval_digest' in rec1);
S.activeGrants.filter(g=>g.capability==='github.pr.merge'&&g.status==='active').forEach(g=>g.status='revoked');

/* consent executes in its HELD context, not ambient state */
S.grantDraft['pr.create']=true;
global.commitGrant();
const rA=receipts;
global.ghExercise('pr.create');
let pendA = S.approvals.find(x=>x.status==='pending');
S.setWorld('pricing');                          /* ambient world flips between hold and approve */
global.capApprove(pendA.id);
t('approval executes in the held context',  receipts===rA+1 && pendA.status==='consumed');
S.setWorld('trvm');

/* when the grant genuinely dies before approval, staleness is SURFACED */
S.activeGrants.filter(g=>g.capability==='github.pr.create'&&g.status==='active').forEach(g=>g.status='revoked');
global.ghDur('run', el());
global.commitGrant();                            /* run-scoped pr.create */
const runId=S.run;
const rB=receipts;
global.ghExercise('pr.create');
let pendB = S.approvals.find(x=>x.status==='pending');
S.endRun();
global.capApprove(pendB.id);
t('dead-grant approval surfaces as stale',  receipts===rB && pendB.status==='stale' &&
  /run-expired|authority-missing/.test(pendB.stale_reason||''));

/* retired run ids can never match again, even forged */
a = S.authorize('github.pr.create','traaviis/trvm',{...ctx(), run:runId},{params:{x:1}});
t('retired run id refuses even when forged', !a.allow);
S.activeGrants.filter(g=>g.capability==='github.pr.create'&&g.status==='active').forEach(g=>g.status='revoked');
S.grantDraft['pr.create']=false;
global.ghDur('workspace', el());

/* authorize is pack-generic */
S.mintGrant({capability:'browser.public.navigate', duration:'workspace', resource:'public-web'});
a = S.authorize('browser.public.navigate','public-web',ctx());
t('another pack authorizes through the same gateway', a.allow===true);
a = S.authorize('nosuchpack.anything','x',ctx());
t('unknown pack refuses as undeclared',     !a.allow && /capability-undeclared/.test(a.reason));
/* postgres is still DISCOVERED here, so the true reason is that its pack is
   not installed — the deny flag is a property of a surface that is not in
   force yet. Asserting `denied-by-default` at this point was reading a
   refusal from a pack nobody had installed and calling it policy. */
a = S.authorize('postgres.query.write','db-main',ctx());
t('a discovered pack refuses before its policy is even consulted',
                                            !a.allow && /pack-not-installed/.test(a.reason));
a = S.mintGrant({capability:'postgres.query.write', duration:'workspace', resource:'db-main'});
t('a discovered pack cannot be granted against',
                                            !!a.refused && /capability-undeclared/.test(a.refused));

/* ============ C1.0a — commitment, coexistence, revision ============ */

/* the snapshot is a real commitment: 64-hex, content-addressed, order-free */
t('authority snapshot is real sha256', /^sha256:[0-9a-f]{64}$/.test(S.snapshot));
const snapA=S.snapshot;
const shot=S.mintOneShot('github.pr.draft');
t('minting authority changes the snapshot', S.snapshot!==snapA);
shot.status='revoked';
t('revoking restores no stale snapshot', S.snapshot===snapA);
const lst=S.activeGrants.filter(g=>g.status==='active');
t('snapshot is insertion-order independent', S.snapshotOf(lst)===S.snapshotOf([...lst].reverse()));

/* independent proposals coexist; only a revision of the SAME proposal stales */
S.approvals.length=0;                 /* clean consent ledger for this section */
S.grantDraft['pr.create']=true; global.commitGrant();
const gA=S.activeGrants.find(g=>g.status==='active'&&g.capability==='github.pr.create');
const pA={repo:'traaviis/trvm',branch:'lane-a',title:'proposal A'};
const envA={schema:'approval-intent@1',pack:'github@'+S.packs.github.version,
  capability:'github.pr.create',actor:'kestrel',resource:'traaviis/trvm',
  grant:gA.id,authority_snapshot:S.snapshot,placement:'local',
  request_id:'er_A',request_revision:1,request:pA};
S.approvals.push({id:'ap_A',request_hash:S.intentDigest(envA),capability:'github.pr.create',
  actor:'kestrel',grant_ref:gA.id,pack_version:S.packs.github.version,snapshot:S.snapshot,
  placement:'local',envelope:envA,status:'granted'});
S.authorize('github.pr.create','traaviis/trvm',ctx(),
  {er:'er_B',rev:1,params:{repo:'traaviis/trvm',branch:'lane-b',title:'proposal B'}});
t('independent proposal B leaves A granted',
  S.approvals.find(x=>x.id==='ap_A').status==='granted' &&
  S.approvals.some(x=>x.status==='pending'));
S.authorize('github.pr.create','traaviis/trvm',ctx(),
  {er:'er_A',rev:2,params:{...pA,title:'proposal A, edited'}});
t('revision 2 stales only its own proposal',
  S.approvals.find(x=>x.id==='ap_A').status==='stale' &&
  !S.approvals.filter(x=>x.id!=='ap_A').some(x=>x.status==='stale'));
S.approvals.length=0;
S.activeGrants.filter(g=>g.capability==='github.pr.create'&&g.status==='active').forEach(g=>g.status='revoked');
S.grantDraft['pr.create']=false;

/* ============ surface / update / tabs (C0.1) ============ */
t('issue.write absent before update',  !S.packs.github.surface['issue.write']);
a = S.authorize('github.issue.write','traaviis/trvm',ctx());
t('undeclared capability refuses',     !a.allow && /capability-undeclared/.test(a.reason));
global.ghUpdateKeep();
t('update expands the surface',        !!S.packs.github.surface['issue.write']);
t('update leaves the draft alone',     !S.grantDraft['issue.write']);
t('update grants nothing',             !S.activeGrants.some(g=>g.capability==='github.issue.write'));
global.ghToggle('issue.write', el());
a = S.authorize('github.issue.write','traaviis/trvm',ctx());
t('uncommitted selection is unauthorized', !a.allow);

t('postgres starts in discover', global.tabFor(S.packs.postgres)==='discover');
global.pgInstall(el());
t('install moves postgres to installed', global.tabFor(S.packs.postgres)==='installed');

/* Installing reveals the surface — and grants nothing. Only now is the
   pack's own deny policy the thing that answers. */
t('install grants nothing',            !S.activeGrants.some(g=>g.capability.startsWith('postgres.')));
a = S.authorize('postgres.schema.read','db-main',ctx());
t('installed but ungranted is authority-missing', !a.allow && /authority-missing/.test(a.reason));
a = S.authorize('postgres.query.write','db-main',ctx());
t('postgres write is denied-by-default', !a.allow && /denied-by-default/.test(a.reason));

/* ============ BOTS — the third root (W.1.3.1 closure) ============

   A Bot is a conversational role over the world, and a conversational
   surface is exactly where a governed system stops being governed: prose
   has no cursor, no citation, and nothing in it can fail closed.

   W.1.3 built the machinery and got two things wrong that these assertions
   now pin. It said *an utterance is a frame* — but a frame is coherent by
   construction and an utterance assembled from several live reads is not,
   so its own witness proved only that the cursor was not older than the
   last read. And it tied whole utterances to the view revision, which moves
   when a channel opens, so a conversation would go entirely red within
   minutes including the claims nothing had falsified.

   The law is now: **an utterance is a cited derivation from one coherent
   frame**, and freshness belongs to the claim.                            */
const B = global.__botState;
t('bots layer exports its own surface', !!B && Array.isArray(B.bots));

/* ---- L1 · creating a Bot confers zero authority ---- */
const fresh = B.newBot('Probe');
t('a new bot holds no capability',      B.actionGrants(fresh).length===0);
t('a new bot observes nothing',         B.observationGrants(fresh).length===0);
t('a new bot delegates to nobody',      fresh.delegates.length===0);
let d = B.botDelegate(fresh.id,'lane.spawn','kestrel');
t('a new bot cannot delegate',          !d.ok && /delegation-exceeds-holder/.test(d.refused));

/* Observation is a GRANT, not a field. W.1.3 kept `observes: ['lanes']`
   beside the real authority model, which is two sources for one fact. */
t('observation is expressed as a grant',
  B.observationGrants(B.botOf('bot_ada')).every(g=>g.capability.startsWith('super.observe.')));
t('a grant may name one resource',
  B.mayObserve(B.botOf('bot_ada'),'bot','bot_auditor') && !B.mayObserve(B.botOf('bot_ada'),'bot','bot_scout'));

/* ---- L4 · a Bot may cite only what its projection contained ----

   THE W.1.3 BYPASS. `botSay` asked only whether a claim had a citation,
   never whether the Bot could observe the cited thing — so Scout, who
   observes evidence and runtime, could assert three lanes were running.
   Citations and observation authority are different gates.                */
const scoutFrame = B.botFrame('bot_scout');
t('scout does not observe lanes',       !B.mayObserve(B.botOf('bot_scout'),'lanes'));
t('scout\'s projection contains no lane',
  Object.keys(scoutFrame.objects).every(k=>scoutFrame.objects[k].kind!=='lanes'));
let u = B.botSay('bot_scout','three lanes are running',
  [{t:'3 of 3 lanes are running', kind:'snapshot', source_object:'lane:lane-a'}], scoutFrame);
t('citing an unobserved object refuses', !!u.refused && /unobserved-citation/.test(u.refused));

const adaFrame = B.botFrame('bot_ada');
t('ada\'s projection does contain lanes', !!adaFrame.objects['lane:lane-a']);
u = B.botSay('bot_ada','lane a is running',
  [{t:'lane-a is running', kind:'snapshot', source_object:'lane:lane-a'}], adaFrame);
t('citing an observed object is said',   !u.refused && u.claims.length===1);

u = B.botSay('bot_ada','no source', [{t:'three lanes', kind:'snapshot'}], adaFrame);
t('an uncited claim is refused',         !!u.refused && /uncited-claim/.test(u.refused));
u = B.botSay('bot_ada','no frame', [{t:'x', kind:'snapshot', source_object:'lane:lane-a'}], null);
t('an utterance with no frame is refused', !!u.refused && /frame-required/.test(u.refused));
u = B.botSay('bot_ada','bad kind', [{t:'x', kind:'vibes', source_object:'lane:lane-a'}], adaFrame);
t('a claim must declare a known kind',   !!u.refused && /unclassified-claim/.test(u.refused));

/* ---- L6 · nothing global escapes into a Bot's output ----

   `agent-projection@2` omits `authority_snapshot` because it commits to
   EVERY actor's grants, so a limited principal watching it learns that
   authority moved somewhere it may not see. W.1.3 put exactly that digest
   on every bot utterance so a Bot could tell whether its view was stale.
   It can tell from its own view.                                          */
const blindFrame = B.botFrame(fresh.id);
t('a zero-observation projection is empty', Object.keys(blindFrame.objects).length===0);
t('a bot cursor carries no global authority digest',
  blindFrame.cursor.projection_digest !== S.authoritySnapshot() &&
  blindFrame.cursor.snapshot === undefined);
t('the digest commits to the bot\'s own projection',
  blindFrame.cursor.projection_digest !== adaFrame.cursor.projection_digest);
const blindBrief = B.botBrief(fresh.id);
t('a blind bot reports nothing about the world', blindBrief.claims.length===0 && blindBrief.blind===true);

/* The board is the Bot's own program and must render only its projection.
   W.1.3 computed `activeGrants.length` here regardless, so a Bot with no
   observation grant still displayed a count of everyone's authority. */
global.botNow = fresh.id;
global.renderBots();
const board = (els['q:#botboard'] ? els['q:#botboard'].innerHTML : '');
t('a blind bot\'s board shows no global grant count', !/\d+\s+active grant/.test(board));
t('a blind bot\'s board shows no approval queue',     !/\d+\s+effects? held/.test(board));
global.botNow = 'bot_ada';

/* ---- L3 · one coherent frame, and the torn-projection witness ----

   THE OTHER W.1.3 DEFECT. Its witness moved the world mid-assembly and
   asserted only `cursor.view >= readAt` — which proves the cursor is not
   OLDER than the last read and says nothing about whether the claims form
   a coherent view. Two claims read at views 20 and 21, stamped 21, labelled
   CURRENT: a torn projection wearing a coherent label.

   A frame is built once and handed over, so every claim in an utterance
   comes from the same view by construction rather than by timing.         */
const f1 = B.botFrame('bot_ada');
const digestAtBuild = f1.cursor.projection_digest;
S.authorize('postgres.query.write','db-main',ctx());     /* the world moves */
t('a frame is immutable once built',    f1.cursor.projection_digest === digestAtBuild);
const u2 = B.botSay('bot_ada','derived later', [
  {t:'a', kind:'snapshot', source_object:'lane:lane-a'},
  {t:'b', kind:'snapshot', source_object:'lane:lane-b'}], f1);
t('every claim shares one basis',       u2.basis.projection_digest === digestAtBuild);
t('the basis names the bot it belongs to', u2.basis.bot === 'bot_ada');
t('a frame carries no global clock',    f1.cursor.view === undefined);
t('a coherent frame says so',           f1.coherence === 'COHERENT');

/* ---- UNESTABLISHED is not STALE, and it is not a badge ----

   STALE          this WAS a coherent statement about world state P, and P
                  is no longer current. Still evidence.
   UNESTABLISHED  we never established that these facts coexisted in ANY
                  world state. Not old truth — unestablished truth.

   W.1.3.1 returned `settled:false` and let the Bot speak anyway with a
   warning beside it. A warning does not turn a possibly impossible
   conjunction into a derivation.                                          */
const unest = {schema:'bot-projection@1', bot:'bot_ada', objects:f1.objects,
               cursor:f1.cursor, coherence:'UNESTABLISHED', settled:false};
let uu = B.botSay('bot_ada','from an unsettled frame',
  [{t:'3 of 3 lanes are running', kind:'snapshot', source_object:'lane:lane-a'}], unest);
t('an unestablished frame supports no factual claim',
  !!uu.refused && /unestablished-basis/.test(uu.refused));
t('UNESTABLISHED is a named coherence state, not a boolean',
  B.COHERENCE.includes('UNESTABLISHED') && B.COHERENCE.includes('COHERENT'));

/* ---- L5 · freshness is per claim, and per claim KIND ---- */
const dframe = B.botFrame('bot_ada');
const receiptObj = Object.keys(dframe.objects).find(k=>dframe.objects[k].kind==='receipts');
const durable = B.botSay('bot_ada','history', [
  {t:'3 lanes running',    kind:'snapshot',       source_object:'lane:lane-a'},
  {t:'I recommend lane b', kind:'interpretation', source_object:'bot:bot_auditor'}], dframe);
t('nothing is stale in a fresh derivation', B.uttStale(durable)===0);
S.authorize('postgres.query.write','db-main',ctx());     /* moves the gateway counters, which ada observes */
t('the snapshot claim goes stale',      B.claimStale(durable.claims[0], durable.basis)===true);
t('the interpretation does not',        B.claimStale(durable.claims[1], durable.basis)===false);
t('only one of two is stale',           B.uttStale(durable)===1);
t('staleness is a label, not a deletion',
  B.botOf('bot_ada').feed.indexOf(durable) >= 0 && durable.claims.length===2);

/* THE CLASS IS THE OBJECT'S TO GIVE, NOT THE CLAIM'S TO DECLARE.

   `claimStale` exempts everything that is not `snapshot`, so labelling a
   live lane state `durable` made it eternal truth — a model that guesses
   wrong, or a program with a bug, could opt any fact out of decay just by
   naming it. Each frame object declares which classes it can support.     */
uu = B.botSay('bot_ada','eternal',
  [{t:'lane-a is running', kind:'durable', source_object:'lane:lane-a'}], B.botFrame('bot_ada'));
t('a live object cannot support a durable claim',
  !!uu.refused && /claim-class-mismatch/.test(uu.refused));
t('a live object does support a snapshot claim',
  !B.botSay('bot_ada','ok',[{t:'x',kind:'snapshot',source_object:'lane:lane-a'}],B.botFrame('bot_ada')).refused);
t('a durable class needs a durable object',
  receiptObj === undefined || /receipt:/.test(receiptObj));

/* ---- L5b · EVERY KIND LOSES VALIDITY ITS OWN WAY ----

   W.1.3.2 documented four claim classes and implemented two states:
   `snapshot` could stale and the other three were immortal, because
   `claimStale` opened with `if(kind !== 'snapshot') return false`. So Ada
   could say "github.pr.create is mine to propose" as a `decision`, the
   grant could be revoked, and the conversation went on presenting the
   decision as holding. The prose promised a mechanism the code did not
   have — this arc's most-repeated defect, this time inside its own claim
   model.

       snapshot        CURRENT | STALE          the projection moved
       durable         ESTABLISHED | RETRACTED  the world withdrew it
       decision        VALID | INVALIDATED      the authority behind it died
       interpretation  BASIS-BOUND              never current, never false   */
t('each kind declares its own validity states',
  B.CLAIM_VALIDITY.snapshot.join()==='CURRENT,STALE' &&
  B.CLAIM_VALIDITY.durable.join()==='ESTABLISHED,RETRACTED' &&
  B.CLAIM_VALIDITY.decision.join()==='VALID,INVALIDATED' &&
  B.CLAIM_VALIDITY.interpretation.join()==='BASIS-BOUND');

/* GPT's decision witness, against Ada's real grant object. */
const decFrame = B.botFrame('bot_ada');
const grantObj = 'grant:bot_ada:github.pr.create';
t('ada\'s frame contains her own grant object', !!decFrame.objects[grantObj]);
const decU = B.botSay('bot_ada','what is mine to propose',
  [{t:'github.pr.create is mine to propose and yours to approve',
    kind:'decision', source_object:grantObj}], decFrame);
t('a decision claim is said',            !decU.refused && decU.claims.length===1);
t('and it is VALID while the grant lives',
  B.claimValidity(decU.claims[0], decU.basis)==='VALID');
const keptGrant = B.botOf('bot_ada').grants.find(g=>g.capability==='github.pr.create');
B.revokeBotGrant('bot_ada','github.pr.create');
t('the grant really went',               !B.botOf('bot_ada').grants.some(g=>g.capability==='github.pr.create'));
t('a revoked grant INVALIDATES the decision it authorized',
  B.claimValidity(decU.claims[0], decU.basis)==='INVALIDATED');
t('and INVALIDATED does not hold',       B.claimStale(decU.claims[0], decU.basis)===true);
B.botOf('bot_ada').grants.push(keptGrant);     /* fixture restored */
t('restoring the grant re-validates it',
  B.claimValidity(decU.claims[0], decU.basis)==='VALID');

/* The durable witness. Nothing in the product retracts a receipt, so the
   register is spliced directly — the claim reads the real log, not a flag
   a test invented for itself. */
const durFrame = B.botFrame('bot_ada');
const rcptKey  = Object.keys(durFrame.objects).find(k=>durFrame.objects[k].kind==='receipts');
const durU = B.botSay('bot_ada','the record',
  [{t:'a receipt was written and nothing removes one', kind:'durable', source_object:rcptKey}], durFrame);
t('a durable claim is said',             !durU.refused);
t('and it is ESTABLISHED',               B.claimValidity(durU.claims[0], durU.basis)==='ESTABLISHED');
t('the durable claim carries its resolved resource',
  durU.claims[0].cited[0].kind==='receipts' && durU.claims[0].cited[0].resource===durFrame.objects[rcptKey].resource);
const rIdx = S.receiptsLog.findIndex(r=>r.id===durFrame.objects[rcptKey].resource);
const rGone = S.receiptsLog.splice(rIdx,1)[0];
t('a retracted object RETRACTS the durable claim',
  B.claimValidity(durU.claims[0], durU.basis)==='RETRACTED');

/* AND THE VALIDITY CHECK MAY NOT BECOME THE NEXT SIDE CHANNEL.

   `durable` is the one kind whose truth condition lives outside the Bot's
   projection, so it is the one that could tell a Bot about a world it may
   not observe. A Bot that has LOST the grant naming the receipt must not
   thereby learn the receipt was retracted. */
const keptObs = B.botOf('bot_ada').grants.find(g=>g.capability==='super.observe.receipts');
B.revokeBotGrant('bot_ada','super.observe.receipts');
t('a bot that lost the grant is NOT told the object was retracted',
  B.claimValidity(durU.claims[0], durU.basis)==='ESTABLISHED');
B.botOf('bot_ada').grants.push(keptObs);
t('and a bot that still observes it IS',
  B.claimValidity(durU.claims[0], durU.basis)==='RETRACTED');
S.receiptsLog.splice(rIdx,0,rGone);            /* fixture restored */
t('restoring the receipt re-establishes the claim',
  B.claimValidity(durU.claims[0], durU.basis)==='ESTABLISHED');

/* An interpretation is bound to its basis and is never a claim about now.
   W.1.3.2's brief demonstrated the class with "Auditor is visible to me",
   which is a presence claim — true of a moment, false the moment the
   observation grant naming Auditor is revoked, and filed in the one class
   that never expires. */
const iFrame = B.botFrame('bot_ada');
const iU = B.botSay('bot_ada','routing',
  [{t:'Auditor is in my projection',   kind:'snapshot',       source_object:'bot:bot_auditor'},
   {t:'I would route verification to Auditor', kind:'interpretation', source_object:'bot:bot_auditor'}], iFrame);
t('one object supports both classes',    !iU.refused && iU.claims.length===2);
t('the presence claim is CURRENT while the projection holds',
  B.claimValidity(iU.claims[0], iU.basis)==='CURRENT');
t('the recommendation is BASIS-BOUND',   B.claimValidity(iU.claims[1], iU.basis)==='BASIS-BOUND');
const keptSee = B.botOf('bot_ada').grants.find(g=>g.capability==='super.observe.bot');
B.revokeBotGrant('bot_ada','super.observe.bot');
t('revoking the sight STALES the presence claim',
  B.claimValidity(iU.claims[0], iU.basis)==='STALE');
t('and leaves the recommendation BASIS-BOUND',
  B.claimValidity(iU.claims[1], iU.basis)==='BASIS-BOUND');
t('a BASIS-BOUND claim still holds',     B.claimStale(iU.claims[1], iU.basis)===false);
B.botOf('bot_ada').grants.push(keptSee);       /* fixture restored */

/* AGGREGATES CITE WHAT ESTABLISHED THEM. "3 of 3 lanes are running" was
   derived from three lanes and cited one. */
const af = B.botFrame('bot_ada');
t('the frame carries a derived collection', !!af.objects['lanes:summary']);
t('a collection names its members', (af.objects['lanes:summary'].members||[]).length===3);
uu = B.botSay('bot_ada','aggregate',
  [{t:'3 of 3 lanes are running', kind:'snapshot', source_object:'lanes:summary'}], af);
t('an aggregate citing only the summary is incomplete',
  !!uu.refused && /incomplete-provenance/.test(uu.refused));
uu = B.botSay('bot_ada','aggregate',
  [{t:'3 of 3 lanes are running', kind:'snapshot',
    source_objects:['lanes:summary'].concat(af.objects['lanes:summary'].members)}], af);
t('an aggregate citing every contributor is said', !uu.refused);
t('the brief\'s own aggregate cites all three lanes',
  (B.botBrief('bot_ada').claims.find(c=>/of 3 lanes/.test(c.t))||{}).source_objects?.length === 4);

/* ---- L6b · A BOT LEARNS ITS VIEW CHANGED ONLY WHEN ITS OWN VIEW CHANGED ----

   W.1.3.1 removed `authoritySnapshot()` from the cursor and left
   `view: viewClock`, which leaks the same fact through a smaller hole: the
   global clock moves when ANY part of the world changes. Scout, who cannot
   see lanes, produced an evidence claim — and a lane change turned it stale
   while Scout's own projection stayed byte-identical. Scout learned that
   something, somewhere, had moved.

       operator view_revision   versions everything the cockpit may see
       projection_digest        versions only what THIS Bot may see        */
const scoutF = B.botFrame('bot_scout');
const scoutU = B.botSay('bot_scout','the ledger',
  [{t:'the ledger stands', kind:'snapshot', source_object:'evidence:ledger'}], scoutF);
t('scout observes evidence but not lanes',
  B.mayObserve(B.botOf('bot_scout'),'evidence','ledger') &&
  !B.mayObserve(B.botOf('bot_scout'),'lanes','lane-a'));
const scoutDigestBefore = scoutF.cursor.projection_digest;
const adaDigestBefore   = B.botFrame('bot_ada').cursor.projection_digest;
global.spawnLane();                       /* a change scout has NO authority to see */
t('the invisible change really moved the world',
  B.botFrame('bot_ada').cursor.projection_digest !== adaDigestBefore);
t('scout\'s projection is byte-identical after it',
  B.botFrame('bot_scout').cursor.projection_digest === scoutDigestBefore);
t('scout learns nothing — its claim did not go stale',
  B.claimStale(scoutU.claims[0], scoutU.basis)===false);
t('a bot that observes the change DOES see it stale',
  B.claimStale({kind:'snapshot'}, {bot:'bot_ada', projection_digest:'sha256:stale'})===true);

/* ---- L6c · NOR MAY COHERENCE REVEAL A CHANGE OUTSIDE THE PROJECTION ----

   W.1.3.2 scoped freshness and left coherence reading the global clock, so
   the leak walked one door down: `botFrame` retried while `viewClock`
   moved, and a private lane churning through the attempts returned
   UNESTABLISHED to a Bot whose permitted projection was byte-identical
   throughout. Scout learns "something outside my projection is moving"
   from the availability of a frame instead of from its content, which is a
   distinction with no difference to Scout.

   The witness is the shipped code's own shape: something otherwise
   invisible touches the world during Scout's assembly, every time. Under
   the clock check that is an unbounded retry ending UNESTABLISHED; under
   the projection check it cannot be observed at all.                      */
const scoutStable = B.stabilityToken(B.botOf('bot_scout'));
t('the stability token is the projection digest, not a clock',
  typeof scoutStable === 'string' && /^sha256:/.test(scoutStable));
B.touched();
t('an invisible change does not move scout\'s stability token',
  B.stabilityToken(B.botOf('bot_scout')) === scoutStable);

/* THE INTERLEAVE, NOT AN ARGUMENT ABOUT ONE.

   `assembleFrame` walks `receiptsLog` on every build, and Scout holds no
   receipts grant, so nothing it contributes can reach Scout's projection.
   Hooking its `filter` gives a `touched()` that fires INSIDE the frame
   build and is invisible to the frame being built — GPT's injection,
   against the shipped object rather than a mock of it.

   Under the clock check this is unbounded: every attempt sees `viewClock`
   move and the fourth returns UNESTABLISHED. Under the projection check it
   cannot be detected at all, which is the point.                          */
const realFilter = S.receiptsLog.filter.bind(S.receiptsLog);
let churn = 0;
S.receiptsLog.filter = function(...a){ churn++; B.touched(); return realFilter(...a); };
const churnFrame  = B.botFrame('bot_scout');
const churnFrameA = B.botFrame('bot_ada');
S.receiptsLog.filter = realFilter;
t('the churn fired inside the frame build', churn >= 2);
t('scout\'s frame is COHERENT despite continuous invisible churn',
  churnFrame.coherence === 'COHERENT');
t('the churn is invisible to scout\'s projection',
  churnFrame.cursor.projection_digest === scoutStable);
t('and the frame still supports a factual claim',
  !B.botSay('bot_scout','the ledger',
    [{t:'the ledger stands', kind:'snapshot', source_object:'evidence:ledger'}], churnFrame).refused);
/* Ada observes receipts and still gets a coherent frame — the fix is not
   "never retry", it is "retry on what this Bot can actually see". */
t('a bot that DOES observe receipts is also coherent', churnFrameA.coherence === 'COHERENT');

/* ---- L4b · an observation grant is scoped by RESOURCE, not by kind ----

   `mayObserve(b,'lanes')` returned true for a resource-scoped grant when no
   resource was supplied, and `assembleFrame` asked once per KIND and then
   emitted every lane. The capability was resource-scoped in syntax and
   kind-scoped in execution.                                                */
const narrowBot = B.newBot('Narrow');
narrowBot.grants.push({capability:'super.observe.lanes', resource:'lane-a'});
const nf = B.botFrame(narrowBot.id);
const nLanes = Object.keys(nf.objects).filter(k=>nf.objects[k].kind==='lanes' && !nf.objects[k].members);
t('a lane-a grant yields exactly lane-a', nLanes.length===1 && nLanes[0]==='lane:lane-a');
t('it does not yield lane-b',            !nf.objects['lane:lane-b']);
t('and its summary names only what it may see',
  (nf.objects['lanes:summary'].members||[]).join()==='lane:lane-a');
uu = B.botSay(narrowBot.id,'lane b',
  [{t:'lane-b is running', kind:'snapshot', source_object:'lane:lane-b'}], nf);
t('it cannot cite the lane it was not granted',
  !!uu.refused && /unobserved-citation/.test(uu.refused));
/* Defence in depth: asking "may this bot see lanes" WITHOUT naming one is the
   question that produced the widening bug, and a resource-scoped grant must
   not answer yes to it. */
t('a resource-scoped grant does not admit the bare kind',
  B.mayObserve(narrowBot,'lanes')===false && B.mayObserve(narrowBot,'lanes','lane-a')===true);

/* ---- L2 · delegation narrows over the WHOLE grant ----

   W.1.3 compared capability and duration. A grant binds nine things, and a
   delegation that keeps two of them can still widen the resource from one
   repo to every repo, the placement from LOCAL to CLOUD, or the policy from
   human_approval_required to auto — each a different effect on the world
   than the parent authorized.                                             */
d = B.botDelegate('bot_ada','deploy.production','kestrel');
t('delegating an unheld capability refuses', !d.ok && /delegation-exceeds-holder/.test(d.refused));
d = B.botDelegate('bot_ada','github.pr.create','kestrel');
t('holding is not permission to pass on',    !d.ok && /delegation-not-permitted/.test(d.refused));

d = B.botDelegate('bot_ada','lane.spawn','kestrel',{duration:'workspace'});
t('delegation may not widen duration',  !d.ok && /delegation-widens · duration/.test(d.refused));
d = B.botDelegate('bot_ada','lane.spawn','kestrel',{duration:'agent'});
t('the duration refusal is not off-by-one', !d.ok && /delegation-widens/.test(d.refused));
d = B.botDelegate('bot_ada','lane.spawn','kestrel',{resource:'*'});
t('delegation may not widen resource',  !d.ok && /delegation-widens · resource/.test(d.refused));
d = B.botDelegate('bot_ada','lane.spawn','kestrel',{placement:'CLOUD'});
t('delegation may not widen placement', !d.ok && /delegation-widens · placement/.test(d.refused));
d = B.botDelegate('bot_ada','lane.spawn','kestrel',{budget:80000});
t('delegation may not widen budget',    !d.ok && /delegation-widens · budget/.test(d.refused));
d = B.botDelegate('bot_ada','lane.spawn','kestrel',{workspace:'pricing-page'});
t('delegation may not cross workspace', !d.ok && /delegation-widens · workspace/.test(d.refused));
d = B.botDelegate('bot_ada','lane.spawn','kestrel',{duration:'forever'});
t('duration enum stays closed',         !d.ok && /invalid-grant-duration/.test(d.refused));

d = B.botDelegate('bot_ada','lane.spawn','kestrel',{duration:'once', budget:500});
t('delegation may narrow every dimension at once', d.ok===true && d.duration==='once' && d.budget===500);
t('an unstated dimension is inherited, not widened', d.resource==='traaviis/trvm' && d.placement==='LOCAL');
t('a delegation names its chain',       Array.isArray(d.delegation_chain) && d.delegation_chain[0]==='bot_ada');
t('a delegation names its parent',      /^bg_bot_ada:lane\.spawn$/.test(d.parent_grant_id));
t('delegation minted no authority grant', !S.activeGrants.some(g=>g.capability==='lane.spawn'));

/* A child may not outlive its parent — a delegated grant whose parent is
   gone is authority with no holder. */
const childId = d.id;
const rv = B.revokeBotGrant('bot_ada','lane.spawn');
t('revoking a parent revokes its children', rv.revoked >= 1);
t('the child is revoked, not deleted',
  B.delegations.some(x=>x.id===childId && x.status==='revoked' && x.revoked_reason==='parent-grant-revoked'));
d = B.botDelegate('bot_ada','lane.spawn','kestrel',{duration:'once'});
t('a revoked parent can no longer delegate', !d.ok && /delegation-exceeds-holder/.test(d.refused));

/* ---- L7 · a Bot may hold an approval-class capability, never the consent ----

   Authorization ≠ approval. Ada is authorized to PROPOSE a PR; she is not
   authorized to consent to one, and no grant in this model could give her
   that. W.1.3's `escalates` list was quasi-authority — it looked like a
   permission and governed nothing; it is now `presents`, a routing
   preference, and the real fact is a held grant with an approval policy.  */
const ada = B.botOf('bot_ada');
t('a bot may hold an approval-class capability',
  B.botGrantFor(ada,'github.pr.create').policy==='human_approval_required');
t('a bot holds no consent capability',
  B.actionGrants(ada).every(g=>!B.HUMAN_ONLY.includes(g.capability)));
t('approval commands are human-control only',
  B.HUMAN_ONLY.includes('approve_effect') && B.HUMAN_ONLY.includes('revoke_grant') &&
  B.BOT_COMMANDS.approve_effect.length===1);
d = B.botDelegate('bot_ada','approve_effect','kestrel');
t('consent cannot be delegated',        !d.ok && /human-control-only/.test(d.refused));
t('escalates is gone; presents is routing', ada.escalates===undefined && Array.isArray(ada.presents));
t('there are three peer kinds',         B.PEER_KINDS.join(',')==='agent,bot,human_control');

/* ---- L8 · a Group is a governed disclosure context ----

   Not another Agent, and not ambient bot-to-bot memory. Its scope is the
   INTERSECTION of its members' at creation, so adding a member can never
   widen anyone — the naive alternative is a covert bridge between two Bots
   whose observation sets differ and which neither's grant describes. The
   rule is not "Ada can see it so Ada may say it" but "the group may see it,
   so Ada may state it here."                                              */
const gw2 = B.botGroups.find(g=>g.id==='g_w2');           /* ada + builder + auditor */
const gtr = B.botGroups.find(g=>g.id==='g_trvm');         /* ada + scout */

/* THE INTERSECTION IS OVER PREDICATES, NOT KIND NAMES.

   W.1.3.1 intersected `OBSERVABLE` kind names, so Ada observing
   `bot(bot_auditor)` and Scout observing `bot(bot_builder)` both "had some
   super.observe.bot" — the group scope came out `['bot']`, and Ada could
   disclose Auditor to a group Scout is in, though Scout was never permitted
   to see Auditor at all.                                                   */
t('a group scope is admitted by every member',
  B.groupScope(gw2).every(p => gw2.members.every(m => B.mayObserve(B.botOf(m), p.kind, p.resource))));
t('adding a member cannot widen a group',
  B.intersectScopes(['bot_ada','bot_scout']).length <= B.scopeOf(B.botOf('bot_ada')).length);
t('scout sees no lanes, so #TRVM discloses none',
  !B.admits(B.groupScope(gtr),'lanes','lane-a'));
let gs = B.groupMaySay('g_trvm','bot_ada',
  {t:'3 lanes running', kind:'snapshot', source_object:'lane:lane-a'}, B.botFrame('bot_ada'));
t('ada may not state a lane fact in a group that cannot see lanes',
  !gs.ok && /outside-group-scope/.test(gs.refused));
gs = B.groupMaySay('g_trvm','bot_ada',
  {t:'the ledger stands', kind:'snapshot', source_object:'evidence:ledger'}, B.botFrame('bot_ada'));
t('ada may state an evidence fact there', gs.ok===true);
gs = B.groupMaySay('g_w2','bot_scout',
  {t:'x', kind:'snapshot', source_object:'evidence:ledger'}, B.botFrame('bot_scout'));
t('a non-member may not speak',          !gs.ok && /not-a-member/.test(gs.refused));

/* Disjoint resources on the same kind intersect to nothing. */
const scoutB = B.botOf('bot_scout');
scoutB.grants.push({capability:'super.observe.bot', resource:'bot_builder'});
t('disjoint resources on one kind intersect to nothing',
  B.intersectScopes(['bot_ada','bot_scout']).filter(p=>p.kind==='bot').length === 0);
gs = B.groupMaySay('g_trvm','bot_ada',
  {t:'auditor found x', kind:'interpretation', source_object:'bot:bot_auditor'}, B.botFrame('bot_ada'));
t('ada may not disclose auditor to a group that cannot see auditor',
  !gs.ok && /outside-group-scope/.test(gs.refused));

/* `*` ∩ X = X — attenuation adds restrictions and never removes them. */
scoutB.grants = scoutB.grants.filter(g=>g.resource!=='bot_builder');
scoutB.grants.push({capability:'super.observe.bot', resource:'*'});
const inter = B.intersectScopes(['bot_ada','bot_scout']).filter(p=>p.kind==='bot');
t('a wildcard intersected with a resource yields exactly that resource',
  inter.length===1 && inter[0].resource==='bot_auditor');
gs = B.groupMaySay('g_trvm','bot_ada',
  {t:'auditor found x', kind:'interpretation', source_object:'bot:bot_auditor'}, B.botFrame('bot_ada'));
t('now ada may disclose auditor there', gs.ok===true);
scoutB.grants = scoutB.grants.filter(g=>!(g.capability==='super.observe.bot'));

/* A collection is admitted by every member it names, so a summary cannot
   smuggle a lane past the group boundary. */
gs = B.groupMaySay('g_trvm','bot_ada',
  {t:'3 of 3 lanes', kind:'snapshot',
   source_objects:['lanes:summary'].concat(B.botFrame('bot_ada').objects['lanes:summary'].members)},
  B.botFrame('bot_ada'));
t('a summary cannot smuggle its members past a group boundary',
  !gs.ok && /outside-group-scope/.test(gs.refused));

/* The isolating case. Grant the group the SUMMARY object by name and nothing
   else: if a collection were admitted by its own id, this would disclose three
   lanes to a group permitted to see none of them. */
gtr.granted = [{kind:'lanes', resource:'summary'}];
gs = B.groupMaySay('g_trvm','bot_ada',
  {t:'3 of 3 lanes', kind:'snapshot', source_object:'lanes:summary'}, B.botFrame('bot_ada'));
t('a collection is admitted by its members, not its own id',
  !gs.ok && /outside-group-scope/.test(gs.refused));
gtr.granted = [];

/* ---- L8b · THE OBJECT ID IS IDENTITY; THE GRANT RESOURCE IS SCOPE ----

   W.1.3.2 recovered the second from the first — `oid.split(':').slice(1)`
   — which holds for `lane:lane-a` and `bot:bot_auditor` and fails for
   `gateway:counters`: admitted into the frame by `capabilities · gateway`,
   tested at the boundary as `capabilities · counters`. A group holding
   exactly the grant the frame used would have refused the object. A false
   denial rather than a leak, and still the wrong reason to be right — two
   encodings of one fact drift, and the disclosure side is the one where
   you cannot see the drift.                                              */
const gwFrame = B.botFrame('bot_ada');
t('ada\'s frame admits the gateway object', !!gwFrame.objects['gateway:counters']);
t('and it carries the resource it was admitted by',
  gwFrame.objects['gateway:counters'].resource === 'gateway');
t('which is NOT its id tail',
  'gateway:counters'.split(':').slice(1).join(':') === 'counters');
gtr.granted = [{kind:'capabilities', resource:'gateway'}];
gs = B.groupMaySay('g_trvm','bot_ada',
  {t:'the gateway held one crossing', kind:'snapshot', source_object:'gateway:counters'}, gwFrame);
t('a group granted capabilities(gateway) may be told about the gateway object', gs.ok===true);
gtr.granted = [{kind:'capabilities', resource:'counters'}];
gs = B.groupMaySay('g_trvm','bot_ada',
  {t:'the gateway held one crossing', kind:'snapshot', source_object:'gateway:counters'}, gwFrame);
t('and a group granted the ID TAIL may not',
  !gs.ok && /outside-group-scope/.test(gs.refused));
gtr.granted = [];

/* The boundary refuses what it cannot scope rather than guessing at it. */
gs = B.groupMaySay('g_trvm','bot_ada', {t:'x', kind:'snapshot', source_object:'lane:lane-a'},
  {objects:{'lane:lane-a':{kind:'lanes', label:'no resource declared'}}});
t('an object with no declared resource is not disclosable',
  !gs.ok && /undeclared-resource/.test(gs.refused));

/* A BOT'S OWN AUTHORITY IS NOT GROUP-DISCLOSABLE BY DEFAULT.

   The `self` objects are the one thing a Bot observes with no grant, and
   before this round they were refused at the boundary for an ACCIDENTAL
   reason: `grant:bot_ada:lane.spawn` split to the resource
   `bot_ada:lane.spawn`, which no scope could ever name. Now they are
   refused for a principled one — `self` is not an observable kind, so no
   member's scope can contain it — and the person can still grant a group
   `self(bot_ada)` explicitly, which is an information-authority change and
   is governed as one. Reasoned about is not measured; this is measured. */
const selfKey = Object.keys(gwFrame.objects).find(k => gwFrame.objects[k].kind === 'self');
t('a self object carries the bot as its resource',
  !!selfKey && gwFrame.objects[selfKey].resource === 'bot_ada');
gs = B.groupMaySay('g_w2','bot_ada', {t:'I hold it', kind:'decision', source_object:selfKey}, gwFrame);
t('a bot may not state its own authority in a group by default',
  !gs.ok && /outside-group-scope/.test(gs.refused));
gw2.granted = [{kind:'self', resource:'bot_ada'}];
gs = B.groupMaySay('g_w2','bot_ada', {t:'I hold it', kind:'decision', source_object:selfKey}, gwFrame);
t('and may when the person grants the group that scope', gs.ok===true);
gw2.granted = [{kind:'self', resource:'bot_scout'}];
gs = B.groupMaySay('g_w2','bot_ada', {t:'I hold it', kind:'decision', source_object:selfKey}, gwFrame);
t('a grant naming a different bot does not do it',
  !gs.ok && /outside-group-scope/.test(gs.refused));
gw2.granted = [];

console.log(`authority battery: ${attempted} assertions · ${fails.length} failed`);
console.log(fails.length ? `authority battery: ${fails.length} FAILURE(S)` :
  'authority battery: clean — grant identity, consent identity, canonical SHA-256 intents, claim validity, domain reconciliation, idempotence, and the eight bot laws all enforced');
process.exit(fails.length?1:0);
