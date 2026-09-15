import {open} from './lib/cockpit-control.mjs';
import {readFileSync,mkdirSync,writeFileSync,mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';import {join} from 'node:path';import http from 'node:http';import assert from 'node:assert/strict';
const out=process.env.SUPER_VISUAL_EVIDENCE_DIR||'/tmp/super-mobile-conversations';mkdirSync(out,{recursive:true});const pair=join(mkdtempSync(join(tmpdir(),'super-chat-')),'pair');
process.env.SUPER_MOBILE_NODE=process.execPath;process.env.SUPER_MOBILE_GATEWAY=new URL('../mobile/server.mjs',import.meta.url).pathname;process.env.SUPER_MOBILE_PORT='4346';process.env.SUPER_MOBILE_ORIGIN='http://127.0.0.1:4346';process.env.SUPER_MOBILE_PAIR_FILE=pair;
let calls=0;const checks=[];let app;const fixture=http.createServer(async(req,res)=>{let raw='';for await(const chunk of req)raw+=chunk;res.setHeader('content-type','application/json');if(req.url==='/api/tags')return res.end(JSON.stringify({models:[{name:'fixture'}]}));const body=JSON.parse(raw);assert.equal(body.model,'fixture');calls++;setTimeout(()=>res.end(JSON.stringify({message:{content:'<conversation-title>Shared mobile task</conversation-title>Fixture reply: the shared conversation received your message.',tool_calls:[]}})),500);});
await new Promise(r=>fixture.listen(0,'127.0.0.1',r));let cookie='';
const api=async(path,body)=>{const r=await fetch('http://127.0.0.1:4346/api/'+path,{method:body?'POST':'GET',headers:{Origin:'http://127.0.0.1:4346',Cookie:cookie,...(body?{'Content-Type':'application/json'}:{})},body:body?JSON.stringify(body):undefined});if(path==='pair')cookie=r.headers.get('set-cookie')?.split(';')[0]||'';return r.json();};
const check=(name,value)=>{assert.ok(value,name);checks.push(name);console.log('PASS '+name);};
try{
 app=await open({port:4599});const page=code=>app.page(code),wait=(fn,label)=>app.until(fn,20000,label);
 await page(`localStorage.setItem('super-last-provider','ollama');const {createConversationStore}=await import('./conversation-store.js');const store=createConversationStore(localStorage);store.save('ollama',null,{messages:[],entries:[],draft:'Original desktop draft',files:[],includeContext:false});location.reload();`);
 await wait(()=>page(`return !!document.querySelector('#bot-provider')&&document.querySelector('#bot-provider').value==='ollama'`),'bot initialization');
 await page(`document.querySelector('[data-nav="bot:assistant"]').click();document.querySelector('#bot-tab-settings').click();document.querySelector('#bot-endpoint').value='http://127.0.0.1:${fixture.address().port}';document.querySelector('#bot-model').value='fixture';document.querySelector('#bot-connect').click();`);
 await wait(()=>page(`return !document.querySelector('#bot-send').disabled`),'fixture connected');
 const paired=await api('pair',{code:readFileSync(pair,'utf8').trim()});check('isolated mobile session paired',paired.paired===true);
 await wait(async()=> {const d=await api('conversations');return d.available&&d.view.active.model==='fixture';},'conversation publication');
 let view=(await api('conversations')).view;console.log('fixture state',JSON.stringify({model:view.active.model,draft:view.active.data?.draft,id:view.active.id,count:view.conversations.length}));check('mobile reads the exact desktop conversation and draft',view.active.data.draft==='Original desktop draft'&&view.active.model==='fixture');
 const make=(operation,extra={})=>({id:crypto.randomUUID(),createdAt:Date.now(),operation,botId:view.active.botId,provider:view.active.provider,conversationId:view.active.id,revision:view.active.revision,...extra});
 const execute=async q=>{const result=await api('conversation',q);assert.equal(result.accepted,true);let receipt;await wait(async()=>{receipt=(await api('conversations')).receipts?.find(r=>r.id===q.id);return !!receipt},'request receipt');return receipt;};
 const rename=make('update',{title:'Phone and desktop agree',pinned:true});check('mobile title and pin accepted',(await execute(rename)).state==='done');
 check('desktop sidebar immediately reflects mobile title',await page(`return document.querySelector('.conversation-title').textContent==='Phone and desktop agree'`));
 check('stale phone draft cannot overwrite newer desktop revision',(await execute(make('draft',{text:'stale overwrite'}))).state==='error');
 view=(await api('conversations')).view;
 check('missing model cannot send',(await execute(make('send',{text:'Do not send a default model'}))).state==='error');check('no provider call from refused send',calls===0);
 const send=make('send',{text:'Continue the shared task',model:'fixture',effort:''});check('explicit model send dispatched',(await execute(send)).state==='done');await execute(send);
 await wait(async()=>{view=(await api('conversations')).view;return !view.active.busy&&view.active.data.entries.some(e=>e.text.includes('Fixture reply'))},'reply persisted');
 check('duplicate send produces one provider request',calls===1);check('phone and desktop share final history',await page(`return document.querySelector('#bot-transcript').textContent.includes('Fixture reply')`));
 const response=await fetch(`http://127.0.0.1:4599/session/${app.session()}/screenshot`);writeFileSync(out+'/desktop-chat.png',Buffer.from((await response.json()).value,'base64'));
 writeFileSync(out+'/checks.json',JSON.stringify({checks,providerCalls:calls,provider:'local controlled fixture'},null,2));
 if(process.env.SUPER_KEEP_CHAT_FIXTURE==='1'){writeFileSync(out+'/ready.json',JSON.stringify({gateway:4346,driver:4599,session:app.session()}));console.log('Fixture ready for emulator');await new Promise(()=>{});}
}finally{await app?.close();fixture.close();}
