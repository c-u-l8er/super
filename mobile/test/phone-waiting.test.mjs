/* Laws for Waiting on you on the phone: the real ui/app.js and ui/waiting.js in the T31 phone (phone.mjs), against
 * a real gateway reading a real board file; and the real ui/sw.js in a small worker scope. */
import test from 'node:test';import assert from 'node:assert/strict';
import vm from 'node:vm';import {readFileSync} from 'node:fs';
import {CODE,openPhone} from './phone.mjs';
import {waitingView} from '../waiting.mjs';
import {gatewayAlerts} from '../waiting-alerts.mjs';
import {pushStore} from '../push-store.mjs';
import {T,NOW,line,board,dirs,putBoard,putConfig,phone as pushPhone,pushService} from './waiting-fixture.mjs';

const IPHONE='Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1';
function browserGlobals(t,values){
  const saved=Object.keys(values).map(k=>[k,Object.getOwnPropertyDescriptor(globalThis,k)]);
  for(const [k,v] of Object.entries(values))Object.defineProperty(globalThis,k,{value:v,configurable:true,writable:true});
  t.after(()=>{for(const [k,d] of saved){if(d)Object.defineProperty(globalThis,k,d);else delete globalThis[k];}});
}
async function paired(t,{lines=[line('a')],boardAt=T-60,world}={}){
  const d=dirs(t);putBoard(d.dir,board(lines,{written_at:boardAt}));putConfig(d.dir,{subject:'https://super.example.ts.net'});
  const service=pushService();
  const phone=await openPhone(t,{...(world?{world}:{}),waiting:async()=>waitingView(d.dir,NOW),alerts:gatewayAlerts({dir:d.dir,mobileDir:d.mobileDir,now:()=>NOW,fetch:service.fetch})});
  await phone.pair(CODE);
  await phone.until(()=>phone.$$('#waiting article.waiting-line').length===lines.length&&phone.$('#waiting .alerts')&&!/Checking/.test(phone.text('#waiting .alerts')),'Waiting on you after pairing');
  return {phone,service,...d};
}
const threads=phone=>phone.$$('#waiting article.waiting-line').map(c=>c.dataset.thread);
const alertsText=phone=>phone.text('#waiting .alerts');

test('U1 · Needs me opens with Waiting on you above the plans: oldest first, the chat, the line, how long, the digest note',async t=>{
  const {phone}=await paired(t,{lines:[line('new',{since:T-600}),line('old',{chat:'+Builder · &body · Garage Cell',line:'his go in this chat for the download.',since:T-3*86400-60}),line('mid',{since:T-7200,busy:true})]});
  const app=phone.$('#app');assert.ok(app.childNodes.indexOf(phone.$('#waiting'))<app.childNodes.indexOf(phone.$('#content')),'above the plans');
  assert.equal(phone.$('#waiting').hidden,false);assert.equal(phone.text('#content h1'),'Needs your attention.','the plans are still drawn');
  assert.equal(phone.text('#waiting h2'),'Waiting on you.');assert.deepEqual(threads(phone),['old','mid','new']);
  const [old,mid,young]=phone.$$('#waiting article.waiting-line');
  assert.equal(old.querySelector('h3').textContent,'+Builder · &body · Garage Cell');
  assert.equal(old.querySelector('.line').textContent,'his go in this chat for the download.');
  assert.match(old.querySelector('.meta').textContent,/^Waiting since (Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d{1,2} [A-Z][a-z]{2} \d\d:\d\d · 3 days$/);
  assert.equal(old.querySelector('.note').textContent,'In the 09:00 digest, due now.');
  assert.equal(mid.querySelector('.note').textContent,'Left out of the digest while the chat is busy.');
  assert.match(young.querySelector('.note').textContent,/^In the digest from (Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d{1,2} [A-Z][a-z]{2} \d\d:\d\d\.$/);
  assert.equal(phone.text('#waiting .count'),'3');
  assert.match(alertsText(phone),/Trial: Super works out each digest and logs it/);
});

test("U2 · the board's age is stated, and an old board is said to be old",async t=>{
  const fresh=await paired(t);
  assert.match(fresh.phone.text('#waiting p.muted'),/^From the Mac's dispatcher, .+ \(1 min ago\)\. Next digest: (Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d{1,2} [A-Z][a-z]{2} \d\d:\d\d\.$/,'shown on the phone\'s own clock');
  assert.equal(fresh.phone.$('#waiting .warn'),null);
  const old=await paired(t,{boardAt:T-3*3600,lines:[line('a',{since:T-4*3600})]});
  assert.match(old.phone.text('#waiting .warn'),/^The Mac's board last reported .+, 3 h ago\. These lines may have changed since; the Mac may be asleep\.$/);
  assert.equal(old.phone.text('#waiting .note'),'No digest while the board is old.');
});

test('U3 · the lines still show while the desktop host is away: they are a separate source',async t=>{
  const {phone}=await paired(t,{world:{available:false}});
  assert.equal(phone.text('#content h1'),'Host unavailable');
  assert.deepEqual(threads(phone),['a']);
});

test('U4 · the count rides on the Needs me button on every tab; the section shows only in Needs me',async t=>{
  const {phone}=await paired(t,{lines:[line('a'),line('b',{answered_at:T-60}),line('c',{since:T-100})]});
  const needs=phone.$('[data-view=attention]');
  assert.equal(needs.getAttribute('data-count'),'2','he answered b');assert.equal(needs.getAttribute('aria-label'),'Needs me, 2 waiting on you');
  assert.equal(needs.textContent,'Needs me','the label itself is unchanged');
  phone.tap('[data-view=tasks]');await phone.until(()=>phone.text('#content h1')==='Development tasks.','Tasks');
  assert.equal(phone.$('#waiting').hidden,true);assert.equal(needs.getAttribute('data-count'),'2');
  phone.tap('[data-view=attention]');await phone.until(()=>phone.$('#waiting').hidden===false,'back to Needs me');
  const css=readFileSync(new URL('../ui/style.css',import.meta.url),'utf8');
  assert.match(css,/nav button\[data-count\]:not\(\[data-count=""\]\)::after\{content:attr\(data-count\);position:absolute/,'the count is drawn beside the label, not in it');
});

test('U5 · a phone that cannot take alerts is told how: on an iPhone, Super goes on the Home Screen first',async t=>{
  const plain=await paired(t);
  assert.match(alertsText(plain.phone),/This browser cannot take alerts from Super\./);
  browserGlobals(t,{navigator:{userAgent:IPHONE}});
  const iphone=await paired(t);
  assert.match(alertsText(iphone.phone),/in Safari, tap Share, then Add to Home Screen\. Open Super from its Home Screen icon, then turn alerts on here\./);
});

function pushBrowser(p,{permission='granted'}={}){
  const events=[];let current=null;
  const subscription=()=>({toJSON:()=>({endpoint:p.endpoint,expirationTime:null,keys:p.sub.keys}),unsubscribe:async()=>{events.push(['unsubscribe']);current=null;return true;}});
  const reg={pushManager:{getSubscription:async()=>current,subscribe:async o=>{events.push(['subscribe',o.userVisibleOnly,Buffer.from(o.applicationServerKey).toString('base64url')]);current=subscription();return current;}}};
  const Notification={permission:'default',requestPermission:async()=>{events.push(['permission']);Notification.permission=permission;return permission;}};
  return {events,globals:{navigator:{userAgent:IPHONE,standalone:true,serviceWorker:{register:async url=>{events.push(['register',url]);return reg;},ready:Promise.resolve(reg)}},Notification,PushManager:function PushManager(){}}};
}

test('U6 · Turn on alerts asks permission first, then hands Super the subscription; the test alert and Turn off work',async t=>{
  const p=pushPhone('iphone'),b=pushBrowser(p);browserGlobals(t,b.globals);
  const {phone,service,mobileDir}=await paired(t);
  const root=phone.$('#waiting');
  assert.match(alertsText(phone),/One digest at 09:00 and 17:00 when lines wait, never from 22:00 to 07:00\./,'what turning alerts on brings');
  phone.tap(phone.button('Turn on alerts',root));
  await phone.until(()=>/Alerts are on for this phone\.$/.test(phone.text('#waiting .alerts .note')??''),'alerts on');
  const key=pushStore(mobileDir).keys().publicKey;
  assert.deepEqual(b.events,[['register','/sw.js'],['permission'],['subscribe',true,key]]);
  assert.deepEqual(pushStore(mobileDir).list().map(x=>x.endpoint),[p.endpoint]);
  phone.tap(phone.button('Send a test alert',root));
  await phone.until(()=>/^Test alert handed to the push service/.test(phone.text('#waiting .alerts .note')??''),'test alert');
  assert.deepEqual(service.calls.map(c=>c.url),[p.endpoint]);
  phone.tap(phone.button('Turn off alerts',root));
  await phone.until(()=>phone.text('#waiting .alerts .note')==='Alerts are off for this phone.','alerts off');
  assert.deepEqual(pushStore(mobileDir).list(),[]);assert.deepEqual(b.events.at(-1),['unsubscribe']);
});

test('U8 · with alerts refused on the phone, nothing is subscribed and the phone says where to change it',async t=>{
  const denied=pushBrowser(pushPhone('no'),{permission:'denied'});browserGlobals(t,denied.globals);
  const {phone,mobileDir}=await paired(t);phone.tap(phone.button('Turn on alerts',phone.$('#waiting')));
  await phone.until(()=>/blocked for Super in Settings → Notifications/.test(phone.text('#waiting .alerts .note')??''),'denied');
  assert.equal(denied.events.some(e=>e[0]==='subscribe'),false,'no subscription without permission');
  assert.deepEqual(pushStore(mobileDir).list(),[]);
});

function worker(){
  const handlers={},shown=[],badges=[],opened=[],navigated=[];let windows=[];
  const self={addEventListener:(type,fn)=>{handlers[type]=fn;},skipWaiting(){},registration:{showNotification:async(title,o)=>{shown.push({title,...o});}},
    clients:{claim:async()=>{},matchAll:async()=>windows,openWindow:async url=>{opened.push(url);}},navigator:{setAppBadge:async n=>{badges.push(n);},clearAppBadge:async()=>{badges.push(0);}}};
  vm.runInNewContext(readFileSync(new URL('../ui/sw.js',import.meta.url),'utf8'),{self});
  const fire=async(type,event)=>{const waits=[];handlers[type]({...event,waitUntil:p=>waits.push(p)});await Promise.all(waits);};
  return {fire,shown,badges,opened,navigated,windows:list=>{windows=list;}};
}
test('U7 · the service worker shows the alert under one tag, sets the badge, and a tap opens only Super’s own pages',async()=>{
  const w=worker(),push=m=>w.fire('push',{data:{json:()=>m}});
  await push({title:'Waiting on you',body:'Garage Cell: his go.',tag:'super-waiting',url:'/mobile#/attention',count:3});
  assert.equal(w.shown[0].title,'Waiting on you');assert.equal(w.shown[0].body,'Garage Cell: his go.');assert.equal(w.shown[0].tag,'super-waiting');
  assert.equal(w.shown[0].renotify,true);assert.equal(w.shown[0].data.url,'/mobile#/attention');assert.deepEqual(w.badges,[3]);
  await push({count:0});assert.equal(w.shown[1].title,'Super');assert.equal(w.shown[1].body,'Something is waiting on you.');assert.deepEqual(w.badges,[3,0]);
  for(const url of ['https://evil.example/x','javascript:alert(1)','//evil.example','/api/logout','/mobile#/tasks/../x']){await push({url});assert.equal(w.shown.at(-1).data.url,'/mobile#/attention',url);}
  await w.fire('notificationclick',{notification:{close(){},data:{url:'https://evil.example/x'}}});
  assert.deepEqual(w.opened,['/mobile#/attention'],'with no window open, it opens Needs me');
  const focused=[];w.windows([{navigate:async u=>{w.navigated.push(u);return {focus:async()=>focused.push(u)};}}]);
  await w.fire('notificationclick',{notification:{close(){},data:{url:'/mobile#/tasks'}}});
  assert.deepEqual(w.navigated,['/mobile#/tasks']);assert.deepEqual(focused,['/mobile#/tasks']);
});
