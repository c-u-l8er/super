/* phone.mjs: a phone for node:test (T31). A helper, not a test (the suite's glob is test/*.test.mjs).
 *
 * It runs the companion's REAL modules, ui/app.js and ui/conversations.js and what they import,
 * unmodified, in a small DOM built from the real ui/index.html, against a REAL gateway
 * (createGateway from ../server.mjs) over loopback HTTP, keeping the session cookie the way a
 * browser does. It fakes only what Node does not have: the DOM, the window's scroll, history and
 * location, localStorage, and the page's timers. Those run only when a test ticks them, so the
 * two-second redraw is `phone.tick(2000)`.
 *
 * Absolute imports ('/conversations.js') resolve through the gateway's own asset table (read from
 * server.mjs), and the harness test in phone-layout.test.mjs holds what loads here byte-equal to
 * what the gateway answers. */
import {registerHooks} from 'node:module';
import http from 'node:http';
import {readFileSync} from 'node:fs';
import {setTimeout as delay} from 'node:timers/promises';
import {createGateway} from '../server.mjs';

const ROOT=new URL('../../',import.meta.url).href;
const UI=new URL('../ui/',import.meta.url),SERVER=new URL('../server.mjs',import.meta.url);
export const ORIGIN='http://127.0.0.1:4318';
export const CODE='0f1e2d3c4b5a69788796a5b4c3d2e1f00123456789abcdef';
// The gateway's own asset table, read from server.mjs: a path it does not serve does not load here either.
const ASSETS=new Map([...readFileSync(SERVER,'utf8').matchAll(/\['(\/[\w.-]*)',\s*\['([^']+)'/g)].map(m=>[m[1],new URL(m[2],SERVER)]));
export const served=name=>{const url=ASSETS.get('/'+name);if(!url)throw Error(`the gateway does not serve /${name}`);return url;};
let hooked=false;
function hook(){
  if(hooked)return;hooked=true;
  registerHooks({resolve(specifier,context,next){
    if(/^\/[\w.-]+\.js$/.test(specifier)&&context.parentURL?.startsWith(ROOT))return {url:served(specifier.slice(1)).href,shortCircuit:true};
    return next(specifier,context);
  }});
}

/* ---- a small DOM ---- */
const kebab=k=>k.replace(/[A-Z]/g,c=>'-'+c.toLowerCase());
const VOID=new Set(['meta','link','input','br','img','hr','source']);
const ENTITIES={amp:'&',lt:'<',gt:'>',quot:'"',apos:"'",nbsp:' '};
const decode=s=>s.replace(/&(#\d+|#x[0-9a-f]+|[a-z]+);/gi,(m,e)=>e[0]==='#'?String.fromCodePoint(/^#x/i.test(e)?parseInt(e.slice(2),16):Number(e.slice(1))):ENTITIES[e]??m);
export class FakeEvent{constructor(type,{bubbles=true,state}={}){Object.assign(this,{type,bubbles,state,defaultPrevented:false,target:null,currentTarget:null,stopped:false});}preventDefault(){this.defaultPrevented=true;}stopPropagation(){this.stopped=true;}}
function dispatch(target,event){
  event.target??=target;
  for(let n=target;n;n=n.parentNode){
    event.currentTarget=n;const handler=n['on'+event.type];if(typeof handler==='function')handler.call(n,event);
    for(const f of [...(n.listeners?.get(event.type)??[])])f.call(n,event);
    if(event.stopped||!event.bubbles)break;
  }
  return !event.defaultPrevented;
}
const compiled=new Map();
function compile(selector){
  let chains=compiled.get(selector);if(chains)return chains;
  chains=selector.split(',').map(one=>one.trim().split(/\s+/).map(compound=>{
    const tests=[],re=/([a-zA-Z][\w-]*)|#([\w-]+)|\.([\w-]+)|\[([\w-]+)(?:=(?:"([^"]*)"|'([^']*)'|([^\]"']*)))?\]|\*/y;let at=0;
    while(at<compound.length){re.lastIndex=at;const m=re.exec(compound);if(!m)throw Error(`phone.mjs: unsupported selector "${selector}"`);at=re.lastIndex;
      if(m[1])tests.push(e=>e.localName===m[1].toLowerCase());else if(m[2])tests.push(e=>e.id===m[2]);else if(m[3])tests.push(e=>e.classList.contains(m[3]));
      else if(m[4]){const v=m[5]??m[6]??m[7];tests.push(v===undefined?e=>e.hasAttribute(m[4]):e=>e.getAttribute(m[4])===v);}}
    return e=>tests.every(t=>t(e));
  }));
  compiled.set(selector,chains);return chains;
}
function matches(el,selector){
  return compile(selector).some(chain=>{if(!chain.at(-1)(el))return false;let i=chain.length-2;for(let n=el.parentNode;i>=0&&n&&n.nodeType===1;n=n.parentNode)if(chain[i](n))i--;return i<0;});
}
class FakeNode{
  constructor(doc,type){this.ownerDocument=doc;this.nodeType=type;this.parentNode=null;this.childNodes=[];}
  get parentElement(){return this.parentNode?.nodeType===1?this.parentNode:null;}
  get isConnected(){for(let n=this;n;n=n.parentNode)if(n.nodeType===9)return true;return false;}
  get previousElementSibling(){const s=this.parentNode?.childNodes??[];for(let i=s.indexOf(this)-1;i>=0;i--)if(s[i].nodeType===1)return s[i];return null;}
  get nextSibling(){const s=this.parentNode?.childNodes;return s?s[s.indexOf(this)+1]??null:null;}
  remove(){const p=this.parentNode;if(!p)return;p.childNodes.splice(p.childNodes.indexOf(this),1);this.parentNode=null;}
  replaceWith(...nodes){const p=this.parentNode;if(!p)return;const at=p.childNodes.indexOf(this);this.remove();p.insertAt(at,nodes);}
}
class FakeText extends FakeNode{constructor(doc,data){super(doc,3);this.data=String(data);}get textContent(){return this.data;}set textContent(v){this.data=String(v);}}
const optionValue=o=>o.value!==undefined?String(o.value):o.textContent;
export class FakeElement extends FakeNode{
  constructor(doc,tag){
    super(doc,1);this.localName=String(tag).toLowerCase();this.attrs=new Map();this.listeners=new Map();this.disabled=false;this.scrollTop=0;this.scrollHeight=0;this.clientHeight=0;this.style={};
    if(this.localName==='input'||this.localName==='textarea')this.value='';
    if(this.localName==='select')Object.defineProperty(this,'value',{configurable:true,get(){const options=this.querySelectorAll('option');if(this.chosen!==undefined&&options.some(o=>optionValue(o)===this.chosen))return this.chosen;return options[0]?optionValue(options[0]):'';},set(v){this.chosen=String(v);}});
    const el=this;
    this.dataset=new Proxy({},{get:(_,k)=>typeof k==='string'?el.attrs.get('data-'+kebab(k)):undefined,set:(_,k,v)=>(el.attrs.set('data-'+kebab(k),String(v)),true),deleteProperty:(_,k)=>(el.attrs.delete('data-'+kebab(k)),true),has:(_,k)=>el.attrs.has('data-'+kebab(k))});
    this.classList={contains:c=>el.classes().includes(c),add:(...c)=>{el.className=[...new Set([...el.classes(),...c])].join(' ');},remove:(...c)=>{el.className=el.classes().filter(x=>!c.includes(x)).join(' ');},
      toggle:(c,force)=>{const on=force===undefined?!el.classes().includes(c):!!force;if(on)el.classList.add(c);else el.classList.remove(c);return on;}};
  }
  classes(){return (this.attrs.get('class')??'').split(/\s+/).filter(Boolean);}
  get tagName(){return this.localName.toUpperCase();}
  get id(){return this.attrs.get('id')??'';}set id(v){this.attrs.set('id',String(v));}
  get className(){return this.attrs.get('class')??'';}set className(v){this.attrs.set('class',String(v));}
  get hidden(){return this.attrs.has('hidden');}set hidden(v){if(v)this.attrs.set('hidden','');else this.attrs.delete('hidden');}
  getAttribute(n){return this.attrs.has(n)?this.attrs.get(n):null;}
  setAttribute(n,v){this.attrs.set(String(n).toLowerCase(),String(v));}
  removeAttribute(n){this.attrs.delete(n);}
  hasAttribute(n){return this.attrs.has(n);}
  get children(){return this.childNodes.filter(n=>n.nodeType===1);}
  get textContent(){return this.childNodes.map(n=>n.textContent).join('');}
  set textContent(v){for(const c of [...this.childNodes])c.remove();const s=v==null?'':String(v);if(s)this.append(s);}
  insertAt(at,nodes){for(const n of nodes){const node=typeof n==='string'?this.ownerDocument.createTextNode(n):n;node.remove();node.parentNode=this;this.childNodes.splice(at++,0,node);}}
  append(...nodes){this.insertAt(this.childNodes.length,nodes);}
  prepend(...nodes){this.insertAt(0,nodes);}
  appendChild(n){this.append(n);return n;}
  replaceChildren(...nodes){for(const c of [...this.childNodes])c.remove();this.append(...nodes);}
  matches(selector){return matches(this,selector);}
  closest(selector){for(let n=this;n&&n.nodeType===1;n=n.parentNode)if(matches(n,selector))return n;return null;}
  querySelectorAll(selector){const out=[],walk=n=>{for(const c of n.childNodes)if(c.nodeType===1){if(matches(c,selector))out.push(c);walk(c);}};walk(this);return out;}
  querySelector(selector){return this.querySelectorAll(selector)[0]??null;}
  addEventListener(type,fn){if(!this.listeners.has(type))this.listeners.set(type,[]);this.listeners.get(type).push(fn);}
  removeEventListener(type,fn){const l=this.listeners.get(type),i=l?l.indexOf(fn):-1;if(i>=0)l.splice(i,1);}
  dispatchEvent(event){return dispatch(this,event);}
  click(){if(!this.disabled)this.dispatchEvent(new FakeEvent('click'));}
  focus(){this.ownerDocument.activeElement=this;this.dispatchEvent(new FakeEvent('focus',{bubbles:false}));}
  blur(){if(this.ownerDocument.activeElement===this)this.ownerDocument.activeElement=this.ownerDocument.body;}
  showModal(){this.open=true;}
  close(){if(this.open){this.open=false;this.dispatchEvent(new FakeEvent('close',{bubbles:false}));}}
  requestSubmit(){this.dispatchEvent(new FakeEvent('submit'));}
  /** No layout here: the call and its options are recorded on the document (`intoView`) for a test to read. */
  scrollIntoView(options){(this.ownerDocument.intoView??=[]).push({element:this,options});}
  /** No layout either: a test that needs boxes gives the document a `layout(element)` model; otherwise all zeros. */
  getBoundingClientRect(){const box=this.ownerDocument.layout?.(this);return {top:0,bottom:0,left:0,right:0,width:0,height:0,...box};}
}
class FakeDocument extends FakeElement{
  constructor(){super(null,'#document');this.ownerDocument=this;this.nodeType=9;this.activeElement=null;}
  createElement(tag){return new FakeElement(this,tag);}
  createTextNode(text){return new FakeText(this,text);}
  get body(){return this.querySelector('body');}
  get documentElement(){return this.querySelector('html');}
}
/** A document parsed from HTML (enough for ui/index.html: tags, quoted attributes, text, entities). */
export function documentFrom(html){
  const doc=new FakeDocument(),stack=[doc],re=/<!--[\s\S]*?-->|<!doctype[^>]*>|<\/([a-zA-Z0-9]+)\s*>|<([a-zA-Z0-9]+)((?:\s+[^\s=>]+(?:="[^"]*")?)*)\s*\/?>|([^<]+)/gi;
  for(const m of html.matchAll(re)){
    if(m[1]){const tag=m[1].toLowerCase(),at=stack.findLastIndex(e=>e.localName===tag);if(at>0)stack.length=at;}
    else if(m[2]){const el=doc.createElement(m[2]);for(const a of m[3].matchAll(/([^\s=>]+)(?:="([^"]*)")?/g))el.setAttribute(a[1],decode(a[2]??''));
      if(el.localName==='input')el.value=el.getAttribute('value')??'';stack.at(-1).append(el);if(!VOID.has(el.localName))stack.push(el);}
    else if(m[4]&&stack.length>1)stack.at(-1).append(decode(m[4]));
  }
  doc.activeElement=doc.body;return doc;
}

/* ---- a window, history that survives a reload, the page's timers ---- */
class FakeWindow{
  constructor(){this.listeners=new Map();this.scrollY=0;this.innerWidth=390;this.innerHeight=844;this.clamp=null;}
  addEventListener(type,fn){if(!this.listeners.has(type))this.listeners.set(type,[]);this.listeners.get(type).push(fn);}
  removeEventListener(type,fn){const l=this.listeners.get(type),i=l?l.indexOf(fn):-1;if(i>=0)l.splice(i,1);}
  dispatchEvent(event){for(const f of [...(this.listeners.get(event.type)??[])])f.call(this,event);return true;}
  // With a layout model (`clamp()`: the page's maximum scroll), scrolling stops at the page's ends, as a browser's does.
  scrollTo(x,y){if(x&&typeof x==='object')y=x.top??this.scrollY;y=Number(y)||0;if(this.clamp)y=Math.max(0,Math.min(y,this.clamp()));this.scrollY=y;}
  scrollBy(x,y){if(x&&typeof x==='object')y=x.top??0;this.scrollTo(0,this.scrollY+(Number(y)||0));}
}
class FakeHistory{
  constructor(tab){this.tab=tab;this.scrollRestoration='auto';}
  get length(){return this.tab.entries.length;}
  get state(){return structuredClone(this.tab.entries[this.tab.index].state);}
  pushState(state,_title,url){const t=this.tab;t.entries.splice(t.index+1);t.entries.push({state:structuredClone(state??null),url:t.resolve(url)});t.index++;}
  replaceState(state,_title,url){const t=this.tab;t.entries[t.index]={state:structuredClone(state??null),url:url==null?t.url:t.resolve(url)};}
  back(){this.go(-1);}
  forward(){this.go(1);}
  // Like Safari: going back past the first entry leaves the page; popstate arrives as a later task.
  go(delta){const t=this.tab,to=t.index+delta;if(to<0){t.leftPage=true;return;}if(to>=t.entries.length)return;t.index=to;const page=t.page;
    queueMicrotask(()=>{if(t.page===page&&!page.closed)page.window.dispatchEvent(new FakeEvent('popstate',{bubbles:false,state:this.state}));});}
}
class Clock{
  constructor(){this.now=0;this.seq=0;this.jobs=new Map();}
  add(fn,ms,every){const id=++this.seq;this.jobs.set(id,{fn,at:this.now+Math.max(0,Number(ms)||0),every});return id;}
  next(until){let best=null;for(const [id,j] of this.jobs)if(j.at<=until&&(!best||j.at<best[1].at||(j.at===best[1].at&&id<best[0])))best=[id,j];return best;}
}
class Storage{constructor(){this.items=new Map();}getItem(k){return this.items.has(k)?this.items.get(k):null;}setItem(k,v){this.items.set(k,String(v));}removeItem(k){this.items.delete(k);}clear(){this.items.clear();}}
const define=(name,value)=>Object.defineProperty(globalThis,name,{value,configurable:true,writable:true,enumerable:false});

let pages=0,live=null;
class Page{
  constructor(tab,{fetch}={}){
    this.tab=tab;this.closed=false;this.inflight=0;this.clock=new Clock();this.window=new FakeWindow();this.history=new FakeHistory(tab);this.fetchOverride=fetch;
    this.document=documentFrom(readFileSync(new URL('index.html',UI),'utf8'));
    Object.assign(this.window,{document:this.document,history:this.history,location:tab.location});
  }
  install(){
    if(live&&live!==this)live.closed=true;live=this;
    const c=this.clock;
    for(const [name,value] of Object.entries({document:this.document,window:this.window,history:this.history,location:this.tab.location,localStorage:this.tab.storage,
      fetch:(path,init)=>this.fetch(path,init),setTimeout:(fn,ms)=>c.add(fn,ms,0),clearTimeout:id=>c.jobs.delete(id),
      setInterval:(fn,ms)=>c.add(fn,ms,Math.max(1,Number(ms)||1)),clearInterval:id=>c.jobs.delete(id),requestAnimationFrame:fn=>{queueMicrotask(()=>fn(0));return 0;}}))define(name,value);
  }
  async fetch(path,{method='GET',headers={},body}={}){
    if(this.closed)return new Promise(()=>{});
    this.inflight++;
    try{
      if(this.fetchOverride){const value=await this.fetchOverride(String(path),{method,body});return new Response(JSON.stringify(value),{status:200,headers:{'content-type':'application/json'}});}
      const tab=this.tab,url=new URL(path,ORIGIN);
      tab.requests.push(`${method} ${url.pathname}`);
      // A request the network loses (`phone.failNext`): it rejects as the browser's fetch would, and never reaches the gateway.
      const lost=tab.failures.get(url.pathname);if(lost){tab.failures.delete(url.pathname);await delay(1);throw lost;}
      const res=await new Promise((resolve,reject)=>{
        const req=http.request({host:'127.0.0.1',port:tab.port,path:url.pathname+url.search,method,headers:{Host:'127.0.0.1:4318',...(method==='GET'?{}:{Origin:ORIGIN}),...(tab.cookie?{Cookie:tab.cookie}:{}),...headers}},
          r=>{let text='';r.setEncoding('utf8');r.on('data',c=>text+=c);r.on('end',()=>resolve({status:r.statusCode,headers:r.headers,text}));});
        req.on('error',reject);req.end(body);
      });
      const set=res.headers['set-cookie']?.[0];if(set){const pair=set.split(';')[0];tab.cookie=pair.endsWith('=')?null:pair;}
      if(this.closed)return new Promise(()=>{});
      return new Response(res.text,{status:res.status,headers:{'content-type':res.headers['content-type']??'application/json'}});
    }finally{this.inflight--;}
  }
  /** Quiet: no request in flight for a few turns of the event loop. */
  async idle(){let calm=0;for(let i=0;i<400&&calm<3;i++){await delay(2);calm=this.inflight?0:calm+1;}}
  async tick(ms){
    const end=this.clock.now+ms;
    for(let job;(job=this.clock.next(end));){const [id,j]=job;this.clock.now=j.at;if(j.every)j.at+=j.every;else this.clock.jobs.delete(id);j.fn();await this.idle();}
    this.clock.now=end;
  }
}

/** A browser tab on a fresh gateway. `world` is the snapshot the desktop publishes; change it to redraw. */
export async function openPhone(t,{code=CODE,world=fixtureWorld(),url=ORIGIN+'/',conversations,conversation}={}){
  hook();
  const tab={entries:[{state:null,url}],index:0,cookie:null,storage:new Storage(),leftPage:false,world,gatewayNow:0,page:null,requests:[],failures:new Map(),
    get url(){return this.entries[this.index].url;},resolve(u){return new URL(u,this.url).href;}};
  tab.location={get href(){return tab.url;},get hash(){return new URL(tab.url).hash;},get pathname(){return new URL(tab.url).pathname;},get origin(){return ORIGIN;}};
  const gateway=createGateway({origin:ORIGIN,pairingCode:code,now:()=>tab.gatewayNow,snapshot:async()=>structuredClone(tab.world),
    conversations:conversations??(async()=>({available:false})),conversation:conversation??(async()=>({error:'Conversation channel unavailable.'}))});
  await new Promise(r=>gateway.listen(0,'127.0.0.1',r));tab.port=gateway.address().port;
  t.after(()=>{if(tab.page)tab.page.closed=true;gateway.closeAllConnections();gateway.close();});
  const phone={
    tab,gateway,
    get page(){return tab.page;},get window(){return tab.page.window;},get history(){return tab.page.history;},get document(){return tab.page.document;},
    get world(){return tab.world;},set world(v){tab.world=v;},
    get hash(){return tab.location.hash;},
    /** Every request the page made, as "METHOD /path", and a way to lose the next one to a path. */
    requests:tab.requests,
    failNext(path,error){tab.failures.set(path,error);},
    $:selector=>tab.page.document.querySelector(selector),
    $$:selector=>tab.page.document.querySelectorAll(selector),
    text:selector=>tab.page.document.querySelector(selector)?.textContent??null,
    /** The button whose own text (before any nested meta) starts with `label`. */
    button(label,root=tab.page.document){const all=root.querySelectorAll('button'),b=all.find(b=>b.textContent===label)??all.find(b=>b.textContent.startsWith(label));if(!b)throw Error(`no button "${label}" in: ${root.querySelectorAll('button').map(b=>b.textContent).join(' | ')}`);return b;},
    tap(target){const el=typeof target==='string'?tab.page.document.querySelector(target):target;if(!el)throw Error(`nothing to tap: ${target}`);el.click();},
    async pair(typed){const input=phone.$('#code');input.value=typed;phone.$('#pair-form').requestSubmit();await tab.page.idle();},
    tick:ms=>tab.page.tick(ms),
    idle:()=>tab.page.idle(),
    async until(test,what='the expected state'){for(let i=0;i<1500;i++){let ok=false;try{ok=test();}catch{}if(ok)return ok;await delay(2);}throw Error(`timed out waiting for ${what}; #content reads: ${(phone.text('#content')??'').slice(0,300)}`);},
    /** A reload: a new page, the same URL, history and cookie (and, if asked, history.state lost). */
    async reload({dropState=false}={}){if(dropState)tab.entries[tab.index].state=null;return phone.open();},
    async open(){
      const page=new Page(tab);if(tab.page)tab.page.closed=true;tab.page=page;page.install();
      await import(new URL(`../ui/app.js?page=${++pages}`,import.meta.url).href);await page.idle();return phone;
    },
    /** Straight to the gateway, as the session cookie (or another one). */
    request(path,{cookie=tab.cookie,method='GET',body}={}){return new Promise((resolve,reject)=>{const req=http.request({host:'127.0.0.1',port:tab.port,path,method,headers:{Host:'127.0.0.1:4318',Origin:ORIGIN,...(cookie?{Cookie:cookie}:{}),...(body?{'Content-Type':'application/json'}:{})}},r=>{let text='';r.on('data',c=>text+=c);r.on('end',()=>resolve({status:r.statusCode,text}));});req.on('error',reject);req.end(body?JSON.stringify(body):undefined);});},
    /** The plan ids of the cards on screen, top to bottom. */
    cards:()=>phone.$$('#content article.card').map(c=>/\b(dt_\d+)\b/.exec(c.querySelector('.meta')?.textContent??'')?.[1]),
  };
  await phone.open();
  return phone;
}

/** The chat panel alone (conversations.js), on a page whose fetch answers with `answer()`. */
export async function openChat(t,{visible=()=>true,answer}){
  hook();
  const tab={entries:[{state:null,url:ORIGIN+'/'}],index:0,storage:new Storage(),get url(){return this.entries[this.index].url;},resolve(u){return new URL(u,this.url).href;}};
  tab.location={get href(){return tab.url;},get hash(){return new URL(tab.url).hash;}};
  const page=new Page(tab,{fetch:async path=>path==='/api/conversations'?answer():{error:'not in this test'}});tab.page=page;page.install();
  t.after(()=>{page.closed=true;});
  const {initConversations}=await import(served('conversations.js').href);
  const root=page.document.querySelector('#conversations');root.hidden=false;
  initConversations(root,visible);await page.idle();
  return {page,root,tick:ms=>page.tick(ms),idle:()=>page.idle(),
    button(label){const b=root.querySelectorAll('button').find(b=>b.textContent===label);if(!b)throw Error(`no button "${label}"`);return b;},
    async until(test,what){for(let i=0;i<1500;i++){let ok=false;try{ok=test();}catch{}if(ok)return ok;await delay(2);}throw Error('timed out waiting for '+what);}};
}

/** A desktop's conversation view, as the gateway relays it. */
export function chatView({revision=3,draft='',entries=[{role:'user',text:'hello'},{role:'assistant',text:'hi'}]}={}){
  return {available:true,receipts:[],view:{
    active:{id:'c1',botId:'bt_0001',provider:'claude',revision,model:'',efforts:[''],effort:'',busy:false,generating:false,data:{draft,entries,taskLinks:[]}},
    conversations:[{id:'c1',botId:'bt_0001',provider:'claude',title:'Pinned talk',pinned:true,updated:'2026-10-02T10:00:00Z',revision,messageCount:2},
      {id:'c2',botId:'bt_0002',provider:'codex',title:'Other talk',pinned:false,updated:'2026-10-02T09:00:00Z',revision:1,messageCount:1}],
    bots:[{id:'bt_0001',name:'Builder',provider:'claude'},{id:'bt_0002',name:'Reviewer',provider:'codex'}],turn:null}};
}

export const ACTOR='bot_'+'5e1f'.repeat(8);
export const CRITERIA='The plan opens at its top.\nBack returns to the list.\n- one\n- two';
/** The desktop's snapshot: eight plans inserted cancelled-first (the walkthrough's order), two bots.
 *  Progress states: dt_0004 blocked, dt_0005 needs changes, dt_0007 checks missing (attention);
 *  dt_0003, dt_0006 prepare (open); dt_0001, dt_0008 cancelled, dt_0002 completed (done). */
export function fixtureWorld({revision6=2,workspaces=1}={}){
  const plan=(n,title,status,bot,extra={})=>({id:`dt_000${n}`,title,status,revision:1,bot_ref:bot,criteria:`Criteria of plan ${n}.`,history:[],...extra});
  const tasks=[plan(1,'Old cancelled plan','cancelled','bt_0001'),plan(8,'New cancelled plan','cancelled','bt_0002'),plan(2,'Completed plan','completed','bt_0002'),
    plan(3,'First open plan','planned','bt_0001'),plan(4,'Blocked plan','blocked','bt_0002'),plan(5,'Plan with requested changes','planned','bt_0001'),
    plan(6,'Second open plan','planned','bt_0001',{revision:revision6,criteria:CRITERIA}),plan(7,'Plan awaiting checks','planned','bt_0002')];
  const attempt=(n,task,status)=>({id:`da_000${n}`,task_ref:task,task_revision:1,status,title:'Review',test_runs:{}});
  return {available:true,world:{world_incarnation:'w-t31',world_generation:1,projection_epoch:'e1'},projection:{
    development_tasks:Object.fromEntries(tasks.map(t=>[t.id,t])),
    development_attempts:{da_0001:attempt(1,'dt_0005','needs_changes'),da_0002:attempt(2,'dt_0007','proposed')},
    bots:{bt_0001:{id:'bt_0001',name:'Builder',provider:'claude',actor:ACTOR,revision:1},bt_0002:{id:'bt_0002',name:'Reviewer',provider:'codex',actor:'bot_'+'0a9b'.repeat(8),revision:1}},
    workspaces:Object.fromEntries(Array.from({length:workspaces},(_,i)=>[`ws_000${i+1}`,{id:`ws_000${i+1}`,name:'Workspace'}])),goals:{},lanes:{},workers:{}}};
}
