/* Waiting on you, at the top of Needs me: the lines that wait on Travis's answer, from the Mac's board, which
 * Super reads as its own source (mobile/waiting.mjs). It draws into its own section, apart from the plans, so
 * it still shows while the desktop host is away: the two are separate sources and each says how current it is.
 * It answers nothing. Each line names the chat to type the answer in.
 * It also holds this phone's alert switch: web push, which on an iPhone needs Super on the Home Screen. */
const node=(tag,text,cls)=>{const e=document.createElement(tag);if(cls)e.className=cls;if(text!==undefined)e.textContent=text;return e;};
const button=(label,fn,cls)=>{const e=node('button',label,cls);e.onclick=fn;return e;};
const api=async(path,body)=>{const r=await fetch('/api/'+path,{method:body?'POST':'GET',headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined,cache:'no-store',signal:AbortSignal.timeout(6000)});const v=await r.json();if(!r.ok){const e=Error(v.error);e.status=r.status;throw e;}return v;};

const DAYS=['Sun','Mon','Tue','Wed','Thu','Fri','Sat'],MONTHS=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const two=n=>String(n).padStart(2,'0');
/** "Sat 21 Nov 08:04", on this phone's clock. */
export const when=s=>{const d=new Date(s*1000);return `${DAYS[d.getDay()]} ${d.getDate()} ${MONTHS[d.getMonth()]} ${two(d.getHours())}:${two(d.getMinutes())}`;};
/** "12 min", "3 h 10 min", "24 days". */
export const span=seconds=>{const m=Math.floor(Math.max(0,seconds)/60);if(m<1)return 'under a minute';if(m<60)return `${m} min`;const h=Math.floor(m/60);if(h<48)return `${h} h`+(m%60?` ${m%60} min`:'');return `${Math.floor(h/24)} days`;};
/** What Super will do, or did, about each line and the digest (rule 9: one digest at each digest time). */
const at5=slot=>String(slot??'').slice(-5);
export const NOTES={
  due:a=>`In the ${at5(a.slot)} digest, due now.`,
  in:a=>a.by==='mac'?`In the Mac's ${at5(a.slot)} digest, ${when(a.at)}.`:a.by==='trial'?`Trial: Super would have put it in the ${at5(a.slot)} digest, ${when(a.at)}.`:`In the ${at5(a.slot)} digest, sent ${when(a.at)}.`,
  next:a=>a.at?`Waits for the next digest, ${when(a.at)}.`:'Waits for the next digest.',
  quiet:a=>`Held for the morning digest${a.at?`, ${when(a.at)}`:''}: none from 22:00 to 07:00.`,
  retry:a=>`The ${at5(a.slot)} digest was not delivered ${when(a.at)}; tried again after ${when(a.again)}.`,
  answered:a=>`Left out of the digest: you wrote in that chat at ${when(a.at)}, after the line.`,
  'no-chat':()=>'No open chat for this line, so there is nowhere to answer it yet.',
  stale:()=>'No digest while the board is old.',
  busy:()=>'Left out of the digest while the chat is busy.',
  later:a=>`In the digest from ${when(a.at)}.`,
};
const digestWords=times=>`One digest at ${(times?.length?times:['09:00','17:00']).join(' and ')} when lines wait, never from 22:00 to 07:00.`;
const keyBytes=b64=>{const s=atob(b64.replace(/-/g,'+').replace(/_/g,'/')+'='.repeat((4-b64.length%4)%4));return Uint8Array.from(s,c=>c.charCodeAt(0));};

export function initWaiting(root,{shown,paired}){
  let view=null,wasShown=false,first=true,loading=false,push=null,sub=null,status=null,working=false,message='',prepared=false;
  const can=()=>typeof navigator!=='undefined'&&!!navigator.serviceWorker&&typeof PushManager!=='undefined'&&typeof Notification!=='undefined';
  const standalone=()=>{try{if(globalThis.matchMedia?.('(display-mode: standalone)').matches)return true;}catch{}return navigator?.standalone===true;};
  const touchApple=()=>/iPhone|iPad|iPod/.test(navigator?.userAgent??'');
  const count=n=>{
    const b=document.querySelector('[data-view=attention]');
    if(b){b.setAttribute('data-count',n?String(n):'');b.setAttribute('aria-label',n?`Needs me, ${n} waiting on you`:'Needs me');}
    try{if(n)navigator.setAppBadge?.(n)?.catch?.(()=>{});else navigator.clearAppBadge?.()?.catch?.(()=>{});}catch{}
  };
  async function load(){
    if(loading||!paired())return;loading=true;
    try{view=await api('waiting');}
    catch(e){view=e.status===401?null:{available:false,reason:'Could not reach Super for the board. It will try again.',lines:[],open:0,unreachable:true};}
    finally{loading=false;}
    count(view?.open??0);draw();
    if(!prepared&&view){prepared=true;void prepare();}
  }
  /** Once per page: how alerts stand on this Super, and whether this phone already has them on. */
  async function prepare(){
    try{push=await api('push');}catch{push={available:false,reason:'Could not reach Super.'};}
    if(push.available&&can()){
      try{
        const reg=await navigator.serviceWorker.register('/sw.js');sub=await reg.pushManager.getSubscription();
        // Handing the subscription over again keeps it tied to this pairing, and revives one the push service had ended.
        if(sub){const j=sub.toJSON();await api('push/subscribe',{endpoint:j.endpoint,keys:j.keys});status=await api('push/status',{endpoint:j.endpoint});}
      }catch(e){message=e.status?e.message:'Alerts could not be checked on this phone.';}
    }
    draw();
  }
  async function act(fn){if(working)return;working=true;message='';draw();try{message=await fn();}catch(e){message=e.status?e.message:'That did not work: '+(e.message||'no answer');}finally{working=false;draw();}}
  const turnOn=()=>act(async()=>{
    // First, while the tap still counts as the person's own: iOS asks only from a tap.
    const permission=await Notification.requestPermission();
    if(permission!=='granted')return permission==='denied'?'Alerts are blocked for Super in Settings → Notifications on this phone.':'Alerts were not allowed.';
    const reg=await navigator.serviceWorker.ready;
    sub=await reg.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:keyBytes(push.publicKey)});
    const j=sub.toJSON();await api('push/subscribe',{endpoint:j.endpoint,keys:j.keys});status={known:true,gone:false};
    return 'Alerts are on for this phone.';
  });
  const test=()=>act(async()=>{const r=await api('push/test',{endpoint:sub.toJSON().endpoint});return r.outcome==='sent'?'Test alert handed to the push service. It should arrive within a minute.':'The test alert was not delivered: '+(r.detail??r.outcome)+'.';});
  const turnOff=()=>act(async()=>{const endpoint=sub.toJSON().endpoint;try{await sub.unsubscribe();}catch{}await api('push/unsubscribe',{endpoint});sub=null;status=null;return 'Alerts are off for this phone.';});

  function alertsCard(){
    const card=node('section',undefined,'card alerts');card.append(node('h3','Alerts on this phone'));
    if(!push)card.append(node('p','Checking…','muted'));
    else if(!push.available)card.append(node('p',push.reason??'Alerts are not set up on this Super.','muted'));
    else if(!can())card.append(node('p',touchApple()&&!standalone()?'To get alerts on this iPhone: in Safari, tap Share, then Add to Home Screen. Open Super from its Home Screen icon, then turn alerts on here.':'This browser cannot take alerts from Super.','muted'));
    else if(Notification.permission==='denied')card.append(node('p','Alerts are blocked for Super in Settings → Notifications on this phone.','muted'));
    else if(!sub||status?.gone){
      if(status?.gone)card.append(node('p','The push service says alerts to this phone have ended. Turn them on again.','muted'));
      card.append(node('p',digestWords(push.digest_times),'muted'));
      const on=button('Turn on alerts',turnOn,'primary');on.disabled=working;card.append(on);
    }else{
      card.append(node('p','Alerts are on for this phone. '+digestWords(push.digest_times)));
      const t=button('Send a test alert',test),off=button('Turn off alerts',turnOff);t.disabled=off.disabled=working;card.append(t,off);
    }
    if(push?.available&&push.mode==='shadow')card.append(node('p','Trial: Super works out each digest and logs it, but sends only test alerts. The digest still comes from the Mac until the trial ends.','muted'));
    if(message)card.append(node('p',message,'note'));
    return card;
  }
  function draw(){
    const visible=shown()&&!!view;root.hidden=!visible;if(!visible)return;
    root.replaceChildren(node('p','SUPER / WAITING ON YOU','eyebrow'),node('h2','Waiting on you.'));
    if(!view.available){root.append(node('p',view.reason,'empty'));root.append(alertsCard());return;}
    const summary=node('div',undefined,'summary');
    summary.append(node('span',String(view.open),'count'),node('p',`${view.open===1?'line waits':'lines wait'} on your answer\nOldest first. Answer each in the chat it names.`));
    root.append(summary);
    if(view.stale)root.append(node('p',`The Mac's board last reported ${when(view.written_at)}, ${span(view.age_seconds)} ago. These lines may have changed since; the Mac may be asleep.`,'warn'));
    else root.append(node('p',`From the Mac's dispatcher, ${when(view.written_at)} (${span(view.age_seconds)} ago).`+(view.next_digest?` Next digest: ${when(view.next_digest)}.`:''),'muted'));
    if(!view.lines.length)root.append(node('p','Nothing waits on you.','empty'));
    for(const l of view.lines){
      const card=node('article',undefined,'card waiting-line');card.dataset.thread=l.thread;card.dataset.alert=l.alert?.state??'';
      card.append(node('h3',l.chat??'No open chat'),node('p',l.line,'line'),node('p',`Waiting since ${when(l.since)} · ${span(view.now-l.since)}`,'meta'));
      const note=NOTES[l.alert?.state];if(note)card.append(node('p',note(l.alert),'meta note'));
      root.append(card);
    }
    root.append(alertsCard());
  }
  setInterval(()=>{if(paired()&&!document.hidden)void load();},30000);
  return {
    /** Called on every redraw of the page: shows or hides the section, and loads afresh when it comes into view. */
    update(){const now=shown()&&!document.hidden;if((now&&!wasShown)||(first&&paired()&&!document.hidden)){first=false;void load();}wasShown=now;draw();},
    reset(){view=null;push=null;sub=null;status=null;prepared=false;message='';wasShown=false;first=true;count(0);root.hidden=true;},
  };
}
