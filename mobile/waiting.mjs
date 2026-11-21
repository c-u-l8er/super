/* "Waiting on you": the lines that wait on Travis's answer, as one of Super's own sources.
 *
 * The board comes from the Mac's dispatcher, which reads each thread's card and the desktop app's chat records
 * (only the Mac can see those). Every pass it writes one file into Super's state folder on the PX13:
 *   ~/.local/state/super/waiting/feed.json   (schema super-waiting@1, private to this user)
 * Super reads that file here, checks it, and judges it by its own rules: how old it is, and when a line earns an
 * alert. Nothing in the file is trusted beyond being shown and counted. An old board is shown as old, never as now.
 *
 * The alert rule is rule 9 of the standing rules as it stands since 21 Nov 2026 (his "Yes, digest"), moved into Super
 * unchanged: at most one alert per digest time (09:00 and 17:00), and only when a line waits. It names every line
 * that has waited 30 minutes, oldest first, by quest name, and says how many are new. A digest time's alert may go
 * from that time until the next digest time or the quiet hours, so a pass missed while a machine slept is made up.
 * Never from 22:00 to 07:00. Left out: a line whose chat is busy, and one he has typed after. A digest that was not
 * delivered is tried again after 30 minutes. Two additions: nothing goes out from an old board, and a digest time
 * the Mac already sent counts as sent, and lines the Mac told him about are not new (no double alert at the switch). */
import {join} from 'node:path';
import {readPrivateJson} from './private-file.mjs';
import {PUSH_HOSTS} from './push.mjs';

export const FEED_SCHEMA='super-waiting@1',ALERTS_SCHEMA='super-waiting-alerts@1';
export const DEFAULTS=Object.freeze({
  mode:'shadow',               // shadow: decide and log, send nothing (only test alerts). send: alert the phones.
  alert_after_minutes:30,retry_minutes:30,quiet_from_hour:22,quiet_to_hour:7,time_zone:'America/Chicago',
  digest_times:Object.freeze(['09:00','17:00']),
  stale_after_minutes:25,      // the dispatcher writes every 10 minutes; two missed passes and some slack
  subject:null,                // the contact the push service sees (https or mailto); needed only to send
  push_hosts:PUSH_HOSTS,ttl_seconds:43200,
});
const LIMITS={lines:64,chat:160,line:300};
const control=/[\u0000-\u001f\u007f]/;
const text=(v,max)=>typeof v==='string'&&v.length>0&&v.length<=max&&!control.test(v);
const epoch=v=>typeof v==='number'&&Number.isFinite(v)&&v>0;
const THREAD=/^[a-z0-9][a-z0-9-]{0,63}$/,SLOT=/^\d{4}-\d\d-\d\d ([01]\d|2[0-3]):[0-5]\d$/,HM=/^([01]\d|2[0-3]):[0-5]\d$/;
const LINE_KEYS=['thread','chat','chat_id','line','key','since','busy','answered_at','mac_notice_at'];
const two=n=>String(n).padStart(2,'0');

/** Super's settings for this source: config.json in the waiting folder, if present. A bad file is refused whole. */
export function loadConfig(dir){
  const raw=readPrivateJson(join(dir,'config.json'),{maxBytes:8192,fallback:{}});
  if(!raw||typeof raw!=='object'||Array.isArray(raw))throw Error('config.json is not an object.');
  const c={...DEFAULTS};
  for(const [k,v] of Object.entries(raw)){
    if(!(k in DEFAULTS))throw Error(`config.json has an unknown setting: ${k}.`);
    const ok={mode:['shadow','send'].includes(v),subject:v===null||typeof v==='string',time_zone:typeof v==='string',
      digest_times:Array.isArray(v)&&v.length>0&&v.length<=6&&v.every(x=>typeof x==='string'&&HM.test(x))&&new Set(v).size===v.length,
      push_hosts:Array.isArray(v)&&v.length>0&&v.every(h=>typeof h==='string'&&/^\.?[a-z0-9.-]+$/.test(h))}[k]
      ??(Number.isInteger(v)&&v>=0&&v<=(/hour/.test(k)?23:100000));
    if(!ok)throw Error(`config.json: ${k} has a value Super does not accept.`);
    c[k]=v;
  }
  try{new Intl.DateTimeFormat('en-US',{timeZone:c.time_zone});}catch{throw Error('config.json: time_zone is not a time zone.');}
  return c;
}

/** The board, checked. {available:false, reason} when there is none or it is refused; else the lines, oldest first. */
export function readFeed(file,nowMs,{stale_after_minutes=DEFAULTS.stale_after_minutes}={}){
  const refuse=reason=>({available:false,reason});
  let data;
  try{data=readPrivateJson(file,{maxBytes:65536});}catch(e){return refuse('The board file was refused: '+e.message.toLowerCase().replace(/\.$/,'')+'.');}
  if(data===null)return refuse('No board has come from the Mac yet.');
  if(!data||typeof data!=='object'||Array.isArray(data)||data.schema!==FEED_SCHEMA)return refuse('The board is not one Super reads (wrong schema).');
  if(Object.keys(data).some(k=>!['schema','written_at','source','lines','mac_digests'].includes(k)))return refuse('The board has fields Super does not know.');
  if(!epoch(data.written_at)||!text(data.source,80)||!Array.isArray(data.lines)||data.lines.length>LIMITS.lines)return refuse('The board is malformed.');
  const now=nowMs/1000;
  if(data.written_at>now+300)return refuse('The board is dated in the future: the Mac and the PX13 clocks disagree.');
  // The digests the Mac has sent, by digest time: Super does not send one again (the switch-over).
  const macDigests=data.mac_digests??{};
  if(!macDigests||typeof macDigests!=='object'||Array.isArray(macDigests)||Object.keys(macDigests).length>8||Object.entries(macDigests).some(([k,v])=>
    !SLOT.test(k)||!v||typeof v!=='object'||Object.keys(v).some(x=>!['at','lines'].includes(x))||!epoch(v.at)||!Array.isArray(v.lines)||v.lines.length>LIMITS.lines||!v.lines.every(x=>typeof x==='string'&&THREAD.test(x))))
    return refuse("The board's record of the Mac's digests is malformed.");
  const seen=new Set(),lines=[];
  for(const l of data.lines){
    if(!l||typeof l!=='object'||Array.isArray(l)||Object.keys(l).some(k=>!LINE_KEYS.includes(k)))return refuse('A line on the board has fields Super does not know.');
    const ok=typeof l.thread==='string'&&THREAD.test(l.thread)&&!seen.has(l.thread)
      &&(l.chat===null||text(l.chat,LIMITS.chat))&&(l.chat_id===null||(typeof l.chat_id==='string'&&/^local_[A-Za-z0-9-]{1,64}$/.test(l.chat_id)))
      &&(l.chat===null)===(l.chat_id===null)
      &&text(l.line,LIMITS.line)&&typeof l.key==='string'&&/^[0-9a-f]{12}$/.test(l.key)
      &&epoch(l.since)&&l.since<=data.written_at+60&&typeof l.busy==='boolean'
      &&(l.answered_at===null||epoch(l.answered_at))&&(l.mac_notice_at===null||epoch(l.mac_notice_at));
    if(!ok)return refuse(`The board's line for ${typeof l.thread==='string'?l.thread.slice(0,64):'a thread'} is malformed.`);
    seen.add(l.thread);lines.push({...l});
  }
  lines.sort((a,b)=>a.since-b.since||(a.thread<b.thread?-1:1));
  const age=Math.max(0,now-data.written_at);
  return {available:true,written_at:data.written_at,source:data.source,age_seconds:Math.round(age),stale:age>stale_after_minutes*60,lines,mac_digests:macDigests};
}

/** The sender's record: per line {key, digest_at}; per digest time {outcome, at, tries, lines}; ended push endpoints. */
export function loadAlerts(file){
  const data=readPrivateJson(file,{maxBytes:262144,fallback:{schema:ALERTS_SCHEMA,lines:{},slots:{},gone:{}}});
  if(data.schema!==ALERTS_SCHEMA||[data.lines,data.slots,data.gone].some(x=>!x||typeof x!=='object'||Array.isArray(x)))throw Error('alerts.json does not match this Super.');
  return data;
}

// Wall-clock time in the configured zone, not the machine's.
const PARTS=new Map();
function partsIn(timeZone,ms){
  let f=PARTS.get(timeZone);if(!f)PARTS.set(timeZone,f=new Intl.DateTimeFormat('en-US',{timeZone,hourCycle:'h23',year:'numeric',month:'numeric',day:'numeric',hour:'numeric',minute:'numeric'}));
  const p=Object.fromEntries(f.formatToParts(ms).filter(x=>x.type!=='literal').map(x=>[x.type,Number(x.value)]));p.hour%=24;return p;
}
export const hourIn=(timeZone,ms)=>partsIn(timeZone,ms).hour;
/** The moment (ms) a wall-clock time happens in a zone. */
export function wallClock(timeZone,y,mo,d,h,mi){
  const want=Date.UTC(y,mo-1,d,h,mi);let at=want;
  for(let i=0;i<3;i++){const p=partsIn(timeZone,at);at+=want-Date.UTC(p.year,p.month-1,p.day,p.hour,p.minute);}
  return at;
}
/** Inside the no-alert hours (22:00 to 07:00 by default), on the configured clock. */
export function quiet(c,ms){const h=hourIn(c.time_zone,ms),a=c.quiet_from_hour,b=c.quiet_to_hour;return a>b?(h>=a||h<b):(a<=h&&h<b);}
const times=(c,ms,dayOffset)=>{const p=partsIn(c.time_zone,ms),day=new Date(Date.UTC(p.year,p.month-1,p.day+dayOffset));
  return [...c.digest_times].sort().map(hm=>{const [h,mi]=hm.split(':').map(Number),y=day.getUTCFullYear(),mo=day.getUTCMonth()+1,d=day.getUTCDate();
    return {key:`${y}-${two(mo)}-${two(d)} ${hm}`,at:wallClock(c.time_zone,y,mo,d,h,mi)};});};
/** The digest time whose digest may go now, or null. It may go from that time until the next digest time or the quiet hours. */
export function digestSlot(c,ms){
  if(quiet(c,ms))return null;
  let slot=null;
  for(const x of times(c,ms,0))if(x.at<=ms&&!quiet(c,x.at))slot={key:x.key,at:x.at/1000};
  return slot;
}
/** The next digest time after now (seconds), for the view. */
export function nextDigest(c,ms){for(const offset of [0,1,2])for(const x of times(c,ms,offset))if(x.at>ms&&!quiet(c,x.at))return x.at/1000;return null;}

/** He has answered: he typed in that chat after the line appeared. */
const answered=l=>l.answered_at!==null&&l.answered_at>=l.since;

/** Whether a digest goes now and with which lines, and a note for every line (what the view shows).
 *  Pure: it sends and writes nothing. `state` is alerts.json's {lines, slots}. */
export function decide(feed,state,nowMs,cfg){
  const c={...DEFAULTS,...cfg},t=nowMs/1000,after=c.alert_after_minutes*60,retry=c.retry_minutes*60;
  const known=state.lines??{},slots={...(state.slots??{})};
  const hush=quiet(c,nowMs),slot=digestSlot(c,nowMs),upcoming=nextDigest(c,nowMs),notes={};
  const base={quiet:hush,slot:slot?.key??null,next_digest:upcoming};
  if(!feed.available)return {...base,digest:null,notes,next:state};
  const lines={},ready=[];
  for(const l of feed.lines){
    let s=known[l.thread];
    if(!s||s.key!==l.key)s={key:l.key,digest_at:null};                  // a changed Status is a new line
    lines[l.thread]=s;
    if(answered(l))notes[l.thread]={state:'answered',at:l.answered_at};
    else if(l.chat_id===null)notes[l.thread]={state:'no-chat'};
    else if(feed.stale)notes[l.thread]={state:'stale'};
    else if(l.busy)notes[l.thread]={state:'busy'};
    else if(t-l.since<after)notes[l.thread]={state:'later',at:l.since+after};
    else ready.push(l);
  }
  let digest=null;
  if(ready.length){
    const mine=slot?slots[slot.key]:null,mac=slot?feed.mac_digests?.[slot.key]:null;
    for(const l of ready){
      if(!slot)notes[l.thread]={state:hush?'quiet':'next',at:upcoming};
      else if(mine&&['sent','shadow'].includes(mine.outcome)||mac){
        const by=mine&&['sent','shadow'].includes(mine.outcome)?mine:mac,inIt=by.lines.includes(l.thread);
        notes[l.thread]=inIt?{state:'in',slot:slot.key,at:by.at,by:by===mac?'mac':mine.outcome==='shadow'?'trial':'super'}:{state:'next',at:upcoming};
      }
      else if(mine?.at&&t-mine.at<retry)notes[l.thread]={state:'retry',slot:slot.key,at:mine.at,again:mine.at+retry};
      else notes[l.thread]={state:'due',slot:slot.key};
    }
    const due=ready.filter(l=>notes[l.thread].state==='due');
    // New: he has not been told of this very line, by Super or by the Mac.
    if(due.length)digest={slot:slot.key,lines:due,new:due.filter(l=>!lines[l.thread].digest_at&&l.mac_notice_at===null).length};
  }
  // A board that is old changes no record: lines that left it may only have left with it.
  return {...base,digest,notes,next:feed.stale?state:{lines,slots}};
}

/** Lines still open for him: the badge on the app icon and the count in the view. */
export const openCount=feed=>feed.available?feed.lines.filter(l=>!answered(l)).length:0;
/** A chat's quest name: the part after its last ' · ', without markdown (as the Mac's digest names it). */
export const questName=chat=>chat.replace(/[*`#]/g,'').split(' · ').at(-1).trim()||chat;

/** The digest alert: rule 9's words, "3 lines, 1 new — A; B; C", at most 200 characters ("; and N more" when cut). */
export function digestMessage(digest,count){
  const k=digest.lines.length,names=digest.lines.map(l=>l.chat?questName(l.chat):l.thread);
  const head=`${k} line${k===1?'':'s'}, ${digest.new} new — `;let body=head;
  for(let j=k;j>=0;j--){
    const shown=names.slice(0,j).join('; '),more=k-j;
    body=(head+shown+(more?(shown?'; and ':'and ')+`${more} more`:'')).replace(/\s+/g,' ');
    if(body.length<=200)break;
  }
  return {title:'Waiting on you',body:body.slice(0,200),tag:'super-waiting',url:'/mobile#/attention',count};
}

/** What the phone shows: the board, Super's note for each line, and how alerts stand. Reads; never writes. */
export function waitingView(dir,nowMs){
  let cfg,config_error=null;
  try{cfg=loadConfig(dir);}catch(e){cfg={...DEFAULTS};config_error=e.message;}
  const feed=readFeed(join(dir,'feed.json'),nowMs,cfg);
  let state={lines:{},slots:{},gone:{}};try{state=loadAlerts(join(dir,'alerts.json'));}catch{}
  const r=decide(feed,state,nowMs,cfg);
  const base={now:Math.round(nowMs/1000),mode:cfg.mode,quiet_now:r.quiet,next_digest:r.next_digest,digest_times:[...cfg.digest_times].sort(),
    stale_after_seconds:cfg.stale_after_minutes*60,...(config_error?{config_error}:{})};
  if(!feed.available)return {...base,available:false,reason:feed.reason,lines:[],open:0};
  return {...base,available:true,written_at:feed.written_at,age_seconds:feed.age_seconds,stale:feed.stale,open:openCount(feed),
    lines:feed.lines.map(l=>({thread:l.thread,chat:l.chat,chat_id:l.chat_id,line:l.line,since:l.since,alert:r.notes[l.thread]}))};
}
