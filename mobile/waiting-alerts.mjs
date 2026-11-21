#!/usr/bin/env node
/* The alert pass: Super's own sender for "Waiting on you".
 *
 *   node mobile/waiting-alerts.mjs pass     # one pass: read the board, decide, alert, record
 *
 * Run on the PX13 by systemd, not by the desktop: a path unit starts a pass when the Mac's board arrives, and a
 * ten-minute timer is the backstop (mobile/units). No model turns. At most one digest per digest time (waiting.mjs).
 * In the trial mode ("shadow", the default) a pass decides and logs exactly as it would send, and sends nothing;
 * only "send" contacts the push service.
 *
 * Files, all private to this user:
 *   ~/.local/state/super/waiting/feed.json     the board (written by the Mac's dispatcher)
 *   ~/.local/state/super/waiting/config.json   optional settings (waiting.mjs DEFAULTS)
 *   ~/.local/state/super/waiting/alerts.json   this sender's record: lines, digest times, ended endpoints
 *   ~/.local/state/super/waiting/alerts.log    one line per pass that had something to do
 *   ~/.local/state/super/mobile/push-*.json    the phones that turned alerts on, and the push key (gateway's) */
import {join} from 'node:path';
import {appendFileSync,openSync,closeSync,statSync,unlinkSync,writeSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {homedir} from 'node:os';
import {loadConfig,readFeed,loadAlerts,decide,digestMessage,openCount,ALERTS_SCHEMA} from './waiting.mjs';
import {writePrivateJson} from './private-file.mjs';
import {pushStore,endpointId} from './push-store.mjs';
import {sendPush} from './push.mjs';

const LOCK_STALE_MS=120_000;
function lock(dir,now){
  const file=join(dir,'alerts.lock');
  for(let attempt=0;attempt<2;attempt++){
    try{const fd=openSync(file,'wx',0o600);writeSync(fd,`${process.pid} ${now()}\n`);closeSync(fd);return ()=>{try{unlinkSync(file);}catch{}};}
    catch(e){
      if(e.code==='ENOENT')return ()=>{};                         // no waiting folder yet: no board, nothing to guard
      if(e.code!=='EEXIST')throw e;
      let age=0;try{age=now()-statSync(file).mtimeMs;}catch{continue;}
      if(age<LOCK_STALE_MS)return null;                           // another pass is running: it does this one's work
      try{unlinkSync(file);}catch{}
    }
  }
  return null;
}
const stamp=ms=>new Date(ms).toISOString();

/** One pass. Returns what it did; writes alerts.json (and a log line) only when the board is fresh. */
export async function runPass({dir,mobileDir,now=Date.now,fetch=globalThis.fetch}){
  const release=lock(dir,now);
  if(!release)return {skipped:'another pass is running'};
  try{
    const cfg=loadConfig(dir);
    const feed=readFeed(join(dir,'feed.json'),now(),cfg);
    const alertsFile=join(dir,'alerts.json'),record=loadAlerts(alertsFile);
    const {digest,next}=decide(feed,record,now(),cfg);
    const result={mode:cfg.mode,board:feed.available?(feed.stale?'stale':'fresh'):'none',slot:digest?.slot??null,lines:digest?digest.lines.map(l=>l.thread):[],outcome:null,phones:0};
    if(!feed.available||feed.stale)return result;                // nothing is sent from an old or missing board
    if(digest){
      const t=now()/1000,threads=result.lines,before=next.slots[digest.slot]??{};
      if(cfg.mode==='shadow')result.outcome='shadow';
      else{
        let phones=[],keys=null,problem=null;
        try{
          const store=pushStore(mobileDir,{now,hosts:cfg.push_hosts}),listed=store.list();
          phones=listed.filter(p=>!(record.gone[endpointId(p.endpoint)]>=p.added/1000));
          if(phones.length)keys=store.keys();
          // An ended endpoint that is no longer listed needs no record.
          const ids=new Set(listed.map(p=>endpointId(p.endpoint)));for(const id of Object.keys(record.gone))if(!ids.has(id))delete record.gone[id];
        }catch(e){problem=e.message;phones=[];}
        if(!phones.length)problem??='no phone has turned alerts on';
        let delivered=false;
        const message=digestMessage(digest,openCount(feed));
        for(const p of phones){
          const r=await sendPush(p,message,{keys,subject:cfg.subject,hosts:cfg.push_hosts,now,fetch,ttl:cfg.ttl_seconds});
          if(r.outcome==='sent')delivered=true;
          else{if(r.outcome==='gone')record.gone[endpointId(p.endpoint)]=t;problem=r.detail??r.outcome;}
        }
        result.phones=phones.length;result.outcome=delivered?'sent':'failed';if(!delivered)result.problem=problem;
        if(delivered)for(const l of digest.lines)next.lines[l.thread].digest_at=t;
      }
      next.slots[digest.slot]={outcome:result.outcome,at:t,tries:(before.tries??0)+1,lines:threads};
      const words={sent:`sent to ${result.phones} phone${result.phones===1?'':'s'}`,failed:`not delivered (${result.problem})`,shadow:'trial, would send'}[result.outcome];
      const fd=openSync(join(dir,'alerts.log'),'a',0o600);
      try{appendFileSync(fd,`${stamp(now())} ${cfg.mode}: digest ${digest.slot.slice(-5)} ${words}: ${threads.join(', ')}\n`);}finally{closeSync(fd);}
    }
    const slots=Object.fromEntries(Object.entries(next.slots).sort().slice(-20));
    writePrivateJson(alertsFile,{schema:ALERTS_SCHEMA,lines:next.lines,slots,gone:record.gone});
    return result;
  }finally{release();}
}

/** What the gateway needs for the phone's alert buttons. A test alert goes only to the endpoint that asked. */
export function gatewayAlerts({dir,mobileDir,now=Date.now,fetch=globalThis.fetch}){
  const config=()=>loadConfig(dir);
  const store=()=>pushStore(mobileDir,{now,hosts:config().push_hosts});
  let lastTest=-Infinity;
  return {
    info(){
      try{const c=config();return {available:true,publicKey:store().keys().publicKey,mode:c.mode,can_send:typeof c.subject==='string',digest_times:[...c.digest_times].sort()};}
      catch(e){return {available:false,reason:e.message};}
    },
    status(endpoint){
      const p=store().find(endpoint);if(!p)return {known:false,gone:false};
      let gone=false;try{gone=loadAlerts(join(dir,'alerts.json')).gone[endpointId(endpoint)]>=p.added/1000;}catch{}
      return {known:true,gone};
    },
    subscribe(device,sub){store().add(device,sub);return {subscribed:true};},
    unsubscribe(endpoint){return {subscribed:false,removed:store().remove(endpoint)};},
    forget(device){try{return store().removeDevice(device);}catch{return 0;}},
    async test(endpoint){
      const s=store(),p=s.find(endpoint);if(!p)return {outcome:'failed',detail:'This phone has not turned alerts on.'};
      if(now()-lastTest<30_000)return {outcome:'failed',detail:'One test alert every 30 seconds.'};
      lastTest=now();const c=config();
      return sendPush(p,{title:'Super',body:'Test alert: alerts from Super reach this phone.',tag:'super-waiting-test',url:'/mobile#/attention'},
        {keys:s.keys(),subject:c.subject,hosts:c.push_hosts,now,fetch,ttl:600});
    },
  };
}

export const stateDirs=(env=process.env)=>{const base=env.XDG_STATE_HOME||join(env.HOME||homedir(),'.local/state');return {dir:join(base,'super/waiting'),mobileDir:join(base,'super/mobile')};};

if(process.argv[1]===fileURLToPath(import.meta.url)){
  if(process.argv[2]!=='pass'){process.stderr.write('usage: waiting-alerts.mjs pass\n');process.exit(2);}
  try{const r=await runPass(stateDirs());process.stdout.write(JSON.stringify(r)+'\n');}
  catch(e){process.stderr.write('waiting-alerts: '+e.message+'\n');process.exit(1);}
}
