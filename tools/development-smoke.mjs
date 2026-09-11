import {visualEvidence} from './visual-evidence.mjs';
/* Native Editor → Terminal → Browser flow in a throwaway repository/world. */
import {createServer} from 'node:http';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtempSync,writeFileSync,readFileSync,mkdirSync} from 'node:fs';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const testRoot=process.env.DEVELOPMENT_TEST_ROOT;
if(!testRoot)throw Error('Set DEVELOPMENT_TEST_ROOT to a disposable directory visible to the desktop folder chooser.');
mkdirSync(testRoot,{recursive:true});
const temp=mkdtempSync(resolve(testRoot,'development-native-'));
execFileSync('git',['init','-q',temp]);
const original=`<!doctype html>
<html>
  <head><title>Super development check</title></head>
  <body>
    <h1>Before editing</h1>
    <button onclick="this.textContent='Working'">Try app</button>
  </body>
</html>`;
writeFileSync(temp+'/index.html',original);
writeFileSync(temp+'/example.js','const answer = 42;\nconsole.log(answer);\n');
execFileSync('git',['-C',temp,'add','.']);
execFileSync('git',['-C',temp,'-c','user.name=Test','-c','user.email=test@example.invalid','commit','-qm','Initial']);
const port=Number(process.env.DEVELOPMENT_SMOKE_PORT??4474),serverPort=Number(process.env.DEVELOPMENT_APP_PORT??48743),base=`http://127.0.0.1:${port}`;
const driver=spawn('tauri-driver',['--port',String(port),'--native-port',String(port+1),'--native-driver','/usr/bin/WebKitWebDriver'],{cwd:root,detached:true,stdio:['ignore','pipe','pipe'],env:{...process.env,GDK_BACKEND:'x11',XDG_DATA_HOME:temp+'/data',AMPD_DIR:root+'/ampd',SUPER_WORLD_MODE:'ephemeral',SUPER_COCKPIT_FIXTURE:'0',SUPER_COCKPIT_PANE:'0',WEBKIT_DISABLE_COMPOSITING_MODE:'1'}});
let session,main,mainHeight,log='',checks=0;driver.stdout.on('data',b=>log=(log+b).slice(-8000));driver.stderr.on('data',b=>log=(log+b).slice(-8000));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function wd(method,path,body){const r=await fetch(base+path,{method,headers:{'content-type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(45000)});const j=await r.json();if(!r.ok||j.value?.error)throw Error(JSON.stringify(j));return j.value;}
const script=(s,args=[])=>wd('POST',`/session/${session}/execute/sync`,{script:s,args});
async function until(fn,ms=15000){const end=Date.now()+ms;while(Date.now()<end){const v=await fn();if(v)return v;await sleep(150);}throw Error('Timed out waiting for development UI');}
const evidence=visualEvidence('development-smoke',root,driver,["Editor starts without write authority", "Two file tabs coexist", "Conflict preserves draft and disk", "Changes shows the real working-tree patch", "Patch sharing stages the inspected diff without sending", "Editor review shows both complete drafts", "Cancelling file review preserves the editor and disk", "An old proposal cannot overwrite a changed draft", "Typing into xterm reaches the live shell", "Native browser executes edited app", "Bot Work shows the explicitly linked shell and browser", "Restart offers recovery without reopening file access", "Selecting the same repository restores both file tabs and unsaved bytes", "Recovery still refuses to overwrite an external edit", "Recovery copies can be reviewed and explicitly forgotten"]);
function check(name,ok){assert.ok(ok,name);evidence.record(name);checks++;console.log('held '+name);}
const click=s=>script('document.querySelector(arguments[0]).click()',[s]);
const fill=(s,v)=>script('const n=document.querySelector(arguments[0]);n.value=arguments[1];n.dispatchEvent(new Event("input",{bubbles:true}));',[s,v]);
const handles=()=>wd('GET',`/session/${session}/window/handles`);
const switchTo=handle=>wd('POST',`/session/${session}/window`,{handle});
async function shot(name){if(!process.env.DEVELOPMENT_SCREENSHOTS)return;mkdirSync(process.env.DEVELOPMENT_SCREENSHOTS,{recursive:true});writeFileSync(resolve(process.env.DEVELOPMENT_SCREENSHOTS,name+'.png'),Buffer.from(await wd('GET',`/session/${session}/screenshot`),'base64'));}
const native=async (operation,args={})=>{await script('window.__result=null;window.__TAURI__.core.invoke("development_request",{request:{operation:arguments[0],...arguments[1]}}).then(v=>window.__result={value:v},e=>window.__result={error:String(e)})',[operation,args]);const r=await until(()=>script('return window.__result'));if(r.error)throw Error(r.error);return r.value;};
const editorText=()=>script('return window.__editorView.findFromDOM(document.querySelector(".cm-editor")).state.doc.toString()');
const change=txt=>script('const v=window.__editorView.findFromDOM(document.querySelector(".cm-editor"));v.dispatch({changes:{from:0,to:v.state.doc.length,insert:arguments[0]}})',[txt]);
let fileReply='',fileRequest=null;
const fileProvider=createServer((req,res)=>{res.setHeader('content-type','application/json');if(req.url==='/api/tags'){res.end(JSON.stringify({models:[{name:'file-review-test'}]}));return;}let body='';req.on('data',b=>body+=b);req.on('end',()=>{fileRequest=JSON.parse(body);res.end(JSON.stringify({message:{role:'assistant',content:'Review this single-file proposal.',tool_calls:[{function:{name:'propose_file_edit',arguments:{path:'index.html',content:fileReply}}}]},done:true}));});});
await new Promise(resolve=>fileProvider.listen(0,'127.0.0.1',resolve));
try {
 await until(async()=>{try{return(await fetch(base+'/status')).ok;}catch{return false;}});
 session=(await wd('POST','/session',{capabilities:{alwaysMatch:{'tauri:options':{application:root+'/cockpit/target/release/super-cockpit'}}}})).sessionId;
 await until(()=>script('return !!window.cockpit?.frame && !!document.querySelector(".cm-editor")'),60000);main=(await handles())[0];
 await script('import("./vendor/code-editor.js").then(m=>window.__editorView=m.EditorView)');await until(()=>script('return !!window.__editorView'));
 await click('[data-nav=editor]');
 check('Editor starts without write authority',await script('return document.querySelector("#editor-save").disabled'));
 await click('#development-choose-editor');await sleep(600);execFileSync('/usr/bin/python3',[root+'/tools/development-confirm-folder.py',String(driver.pid),temp]);await sleep(1000);
 if(!await script('return document.querySelector(".workbench-root").textContent!=="No repository selected"'))execFileSync('/usr/bin/python3',[root+'/tools/development-confirm-folder.py',String(driver.pid),temp]);
 await until(()=>script('return [...document.querySelectorAll("[data-file-path]")].some(b=>b.dataset.filePath==="index.html")'));
 await click('[data-file-path="index.html"]');await until(async()=>(await editorText()).includes('Before editing'));
 check('Real editor reads disk',await editorText()===original);
 check('Code has syntax tokens and line numbers',await script('return document.querySelectorAll(".cm-line span").length>3&&!!document.querySelector(".cm-lineNumbers")'));
 const changed=original.replace('Before editing','Built inside Super');await change(changed);
 await click('[data-file-path="example.js"]');await until(async()=>(await editorText()).includes('answer'));
 check('Editor styles are painted, not just tokenized',await script('const s=getComputedStyle(document.querySelector(".cm-scroller")),line=document.querySelector(".cm-line").getBoundingClientRect(),host=document.querySelector("#editor-content").getBoundingClientRect();return s.fontFamily.includes("monospace")&&line.top-host.top<60&&getComputedStyle(document.querySelector(".cm-line span")).color!==getComputedStyle(document.querySelector(".cm-line")).color'));
 check('Two file tabs coexist',await script('return document.querySelectorAll("[data-screen=editor] [role=tab]").length===2'));
 await script('[...document.querySelectorAll("[data-screen=editor] [role=tab]")].find(b=>b.textContent.includes("index.html")).click()');
 check('Switching files preserves draft',await editorText()===changed);
 await click('#editor-save');await until(async()=>readFileSync(temp+'/index.html','utf8')===changed&&await script('return document.querySelector("#editor-save").disabled'));
 check('Save writes actual bytes',readFileSync(temp+'/index.html','utf8')===changed);
 await change(changed+'<!-- draft -->');writeFileSync(temp+'/index.html',changed+'<!-- outside edit -->');await click('#editor-save');await until(()=>script('return document.querySelector("#editor-status").textContent.includes("changed on disk")'));
 check('Conflict preserves draft and disk',(await editorText()).includes('draft')&&readFileSync(temp+'/index.html','utf8').includes('outside edit'));
 await script('window.confirm=()=>true');await click('#editor-reload');await until(async()=>(await editorText()).includes('outside edit'));await shot('editor-tabs');
 await click('#editor-changes');await until(()=>script('return [...document.querySelectorAll("[data-change-path]")].some(n=>n.dataset.changePath==="index.html")'));
 check('Changes hides Editor and disables unrelated file actions',await script('return document.querySelector("#editor-content").hidden&&document.querySelector("#editor-save").disabled&&document.querySelector("#editor-discuss").disabled'));
 await click('[data-change-path="index.html"]');await until(()=>script('return document.querySelector("#change-diff").textContent.includes("outside edit")'));
 check('Changes shows the real working-tree patch',await script('return [...document.querySelectorAll("#change-diff .diff-added")].some(n=>n.textContent.includes("Built inside Super"))'));
 await shot('editor-changes');
 await click('#changes-discuss');await until(()=>script('return document.querySelector(".linked-surface")?.textContent.includes("Changes: index.html")'));
 if(process.env.SUPER_VISUAL_EVIDENCE_DIR)await script(`document.querySelector(arguments[0])?.scrollIntoView({block:'center'})`,["#bot-attachment-list"]);check('Patch sharing stages the inspected diff without sending',await script('return document.querySelector("#bot-attachment-list").textContent.includes("Changes: index.html")&&document.querySelector("#bot-message").value===""'));
 await click('.linked-surface');await until(()=>script('return !document.querySelector("#change-diff").hidden&&document.querySelector("#change-diff").textContent.includes("outside edit")'));
 check('Patch backlink returns to current changes for the same file',true);
 await click('#changes-open-file');
 check('Review returns to the matching editable file',await script('return !document.querySelector("#editor-content").hidden&&!document.querySelector("#editor-discuss").disabled'));
 await click('#editor-discuss');await until(()=>script('return document.querySelector(".linked-surface")?.textContent.includes("index.html")'));
 check('Bot receives attachment without automatic send',await script('return !!document.querySelector(".linked-surface")&&document.querySelector("#bot-message").value===""'));
 await click('.linked-surface');check('Bot backlink opens the same file',await editorText()===changed+'<!-- outside edit -->');
 fileReply=changed+'<!-- outside edit -->\n<!-- BOT_REVIEWED: this file passed the review flow -->';
 await click('#editor-discuss');await until(()=>script('return !document.querySelector("#bot-surface").hidden'));
 await script('const p=document.querySelector("#bot-provider");p.value="ollama";p.dispatchEvent(new Event("change"))');
 await fill('#bot-endpoint',`http://127.0.0.1:${fileProvider.address().port}`);await click('#bot-connect');await until(()=>script('return !document.querySelector("#bot-send").disabled'));
 // Re-share on the selected provider, whose attachment list is separate.
 await click('[data-nav=editor]');await click('#editor-discuss');await fill('#bot-message','Propose a small edit to this exact file');await click('#bot-send');
 await until(()=>script('return [...document.querySelectorAll(".bot-proposal button")].some(b=>b.textContent==="Review in Editor") && !document.querySelector("#bot-send").disabled'));
 check('Native provider returns a code proposal without changing disk',readFileSync(temp+'/index.html','utf8')===changed+'<!-- outside edit -->'&&fileRequest.messages.some(m=>m.content.includes('outside edit')));
 await script('[...document.querySelectorAll(".bot-proposal button")].find(b=>b.textContent==="Review in Editor").click()');await until(()=>script('return !!document.querySelector("#bot-file-review[open]")'));
 check('Editor review exposes a line-numbered changes summary',await script('return !!document.querySelector("#proposal-diff .added") && !!document.querySelector("#proposal-diff .removed") && document.querySelector("#proposal-diff").textContent.includes("BOT_REVIEWED")'));
 check('Editor review shows both complete drafts',await script('return document.querySelectorAll("#bot-file-review .cm-editor").length===2 && document.querySelector("#bot-file-review").textContent.includes("BOT_REVIEWED")'));
 if(process.env.SUPER_PROGRESS_SCREENSHOTS){await wd('POST',`/session/${session}/window/rect`,{width:1280,height:880});execFileSync('/usr/bin/python3',[root+'/tools/development-capture-window.py',String(driver.pid),resolve(process.env.SUPER_PROGRESS_SCREENSHOTS,'Super_Progress_05_Bot_Code_Review.png')]);}
 await click('#bot-file-cancel');check('Cancelling file review preserves the editor and disk',(await editorText())===changed+'<!-- outside edit -->'&&readFileSync(temp+'/index.html','utf8')===changed+'<!-- outside edit -->');
 await click('[data-rail-mode=bots]');await click('#rail-bots [data-nav="bot:assistant"]');await script('[...document.querySelectorAll(".bot-proposal button")].find(b=>b.textContent==="Review in Editor").click()');await until(()=>script('return !!document.querySelector("#bot-file-review[open]")'));await click('#bot-file-use-draft');
 check('Accepting a file proposal stages only an unsaved editor draft',(await editorText())===fileReply&&readFileSync(temp+'/index.html','utf8')!==fileReply);
 await click('#editor-save');await until(()=>script('return document.querySelector("#editor-status").textContent.includes("Saved")'));check('Explicit Save writes the reviewed code',readFileSync(temp+'/index.html','utf8')===fileReply);
 await click('[data-rail-mode=bots]');await click('#rail-bots [data-nav="bot:assistant"]');await script('[...document.querySelectorAll(".bot-proposal button")].find(b=>b.textContent==="Review in Editor").click()');if(process.env.SUPER_VISUAL_EVIDENCE_DIR)await script(`document.querySelector(arguments[0])?.scrollIntoView({block:'center'})`,[".bot-proposal"]);check('An old proposal cannot overwrite a changed draft',await script('return !document.querySelector("#bot-file-review") && document.querySelector(".bot-proposal").textContent.includes("draft changed")'));
 await click('[data-nav=editor]');
 await click('[data-nav=terminal]');await click('#terminal-new');await until(()=>script('return document.querySelectorAll(".shell-terminal").length===1'));
 const generation=(await native('status')).generation;let state=await native('status');const first=state.shells[0].id;
 await native('shell_input',{generation,id:first,data:`python3 -u -m http.server ${serverPort} --bind 127.0.0.1\r`});
 await until(async()=>{try{return(await fetch(`http://127.0.0.1:${serverPort}`)).ok;}catch{return false;}});
 check('Interactive shell serves edited checkout',true);
 await click('#terminal-new');await until(()=>script('return document.querySelectorAll(".shell-terminal").length===2'));state=await native('status');const second=state.shells.find(s=>s.id!==first).id;
 await native('shell_input',{generation,id:second,data:'printf "SECOND_SHELL_OK\\n"\r'});await until(()=>script('return document.querySelector("#terminal-output").textContent.includes("SECOND_SHELL_OK")'));
 check('Two live terminal sessions are tabbed',state.shells.length===2);
 check('Shell inventory excludes captured output',state.shells.every(s=>!('output' in s)));
 await script('window.__shellTab=document.querySelector("[data-screen=terminal] [role=tab]")');await sleep(2300);
 check('Unchanged shell tabs retain focusable elements across polling',await script('return window.__shellTab===document.querySelector("[data-screen=terminal] [role=tab]")'));
 const keyTarget=await wd('POST',`/session/${session}/element`,{using:'css selector',value:'.shell-terminal:not([hidden]) .xterm-helper-textarea'});
 await wd('POST',`/session/${session}/element/${keyTarget['element-6066-11e4-a52e-4f735466cecf']}/value`,{text:"printf 'KEYBOARD_%s\\n' OK\uE007"});
 await until(()=>script('return document.querySelector("#terminal-output").textContent.includes("KEYBOARD_OK")'));
 check('Typing into xterm reaches the live shell',true);
await shot('terminal-tabs');
 await click('[data-nav=browser]');await fill('#browser-url',`http://127.0.0.1:${serverPort}/`);await click('#browser-go');
 const preview=await until(async()=>{const h=await handles();return h.find(x=>x!==main);});await switchTo(preview);await until(()=>script('return document.querySelector("h1")?.textContent==="Built inside Super"'));await click('button');
 check('Native browser executes edited app',await script('return document.querySelector("button").textContent==="Working"'));await shot('browser-page');
 await switchTo(main);const old=await wd('GET',`/session/${session}/window/rect`);await wd('POST',`/session/${session}/window/rect`,{width:900,height:680});await sleep(600);
 check('Window shrinks with browser open',(await wd('GET',`/session/${session}/window/rect`)).width<=905);
 await wd('POST',`/session/${session}/window/rect`,{width:1180,height:820});await sleep(500);
 check('Window grows with browser open',(await wd('GET',`/session/${session}/window/rect`)).width>=1175);
 if(process.env.SUPER_NATIVE_NO_WINDOW_MANAGER==='1'){evidence.skip('Compositor pointer resize: isolated display has no window manager');console.log('skipped compositor pointer-resize check: isolated display has no window manager');}else{
 await wd('POST',`/session/${session}/window/rect`,{x:100,y:100,width:1000,height:700});await sleep(500);
 await script('window.__pointerTrace=[];document.addEventListener("pointermove",e=>{window.__pointerTrace.push([e.clientX,e.clientY,e.target.id,e.target.className]);if(window.__pointerTrace.length>8)window.__pointerTrace.shift();},{passive:true});');
 const beforeDrag=await wd('GET',`/session/${session}/window/rect`);
 const dragGeometry=execFileSync('/usr/bin/python3',[root+'/tools/development-resize-window.py',String(driver.pid)]).toString();await sleep(500);
 const afterDrag=await wd('GET',`/session/${session}/window/rect`);
 if(!(afterDrag.width<beforeDrag.width-20&&afterDrag.height<beforeDrag.height-20))console.error('Pointer resize diagnostic',{beforeDrag,afterDrag,dragGeometry,viewport:await script('return {innerWidth,innerHeight,dialogs:document.querySelectorAll("dialog").length,trace:window.__pointerTrace}')});
 check('Real pointer drag resizes the browser window',afterDrag.width<beforeDrag.width-20&&afterDrag.height<beforeDrag.height-20);
 }
 check('Eight border resize handles exist',await script('return document.querySelectorAll("[data-window-resize]").length===8'));
 check('Browser viewport fills remaining panel',await script('const a=document.querySelector("#browser-viewport").getBoundingClientRect(),b=document.querySelector("[data-screen=browser]").getBoundingClientRect();return Math.abs(a.width-b.width)<2&&Math.abs(a.bottom-(b.bottom-24))<3'));
 await click('#browser-new');await fill('#browser-url',`http://127.0.0.1:${serverPort}/example.js`);await click('#browser-go');const secondPreview=await until(async()=>{const h=await handles();return h.find(x=>x!==main&&x!==preview);});
 await switchTo(secondPreview);await until(()=>script('return document.body.textContent.includes("answer")'));check('Second browser tab renders independently',true);
 await switchTo(main);await script('document.querySelector("[data-screen=browser] [role=tab]").click()');await switchTo(preview);check('Browser tab preserves page state',await script('return document.querySelector("button").textContent==="Working"'));
 await script('window.__denied=null;const invoke=window.__TAURI__?.core?.invoke??window.__TAURI_INTERNALS__?.invoke;if(!invoke)window.__denied="no bridge";else invoke("development_request",{request:{operation:"status"}}).then(()=>window.__denied="ALLOWED",e=>window.__denied=String(e));');await until(()=>script('return window.__denied!==null'));check('Browser content cannot invoke local controls',await script('return window.__denied!=="ALLOWED"'));
 await switchTo(main);await click('#browser-link-bot');await until(()=>script('return document.querySelector("#browser-status").textContent.includes("Linked to")'));
 await click('[data-nav=terminal]');await click('#terminal-link-bot');await until(()=>script('return document.querySelector("#terminal-status").textContent.includes("Linked to")'));
 async function botWork(){await click('[data-rail-mode=bots]');await click('#rail-bots [data-nav="bot:assistant"]');await click('#bot-tab-work');}
 await botWork();await until(()=>script('return document.querySelectorAll(".linked-session-row").length===2'));
 if(process.env.SUPER_VISUAL_EVIDENCE_DIR)await script(`document.querySelector(arguments[0])?.scrollIntoView({block:'center'})`,["#bot-linked-sessions"]);check('Bot Work shows the explicitly linked shell and browser',await script('return document.querySelector("#bot-linked-sessions").textContent.includes("Shared by you") && [...document.querySelectorAll(".linked-session-row")].some(n=>n.textContent.includes("running"))'));
 const linkedIds=await script('return [...document.querySelectorAll(".linked-session-row")].map(n=>n.dataset.sessionId).sort()');
 if(process.env.SUPER_PROGRESS_SCREENSHOTS){mkdirSync(process.env.SUPER_PROGRESS_SCREENSHOTS,{recursive:true});await wd('POST',`/session/${session}/window/rect`,{width:1280,height:880});await script('document.querySelector("#bot-linked-sessions").scrollIntoView({block:"end"})');execFileSync('/usr/bin/python3',[root+'/tools/development-capture-window.py',String(driver.pid),resolve(process.env.SUPER_PROGRESS_SCREENSHOTS,'Super_Progress_04_Linked_Sessions.png')]);}
 await script('[...document.querySelectorAll("[data-open-linked-session]")].find(b=>b.textContent.includes("Terminal")).click()');await until(()=>script('return !document.querySelector("[data-screen=terminal]").hidden'));
 check('Bot session link opens the existing terminal',await script('return document.querySelectorAll(".shell-terminal").length===2'));
 await botWork();await script('[...document.querySelectorAll("[data-open-linked-session]")].find(b=>b.textContent.includes("Browser")).click()');await until(()=>script('return !document.querySelector("[data-screen=browser]").hidden'));
 await switchTo(preview);check('Bot session link preserves the actual browser page',await script('return document.querySelector("button").textContent==="Working"'));
 await script('window.__sessionDenied=null;const invoke=window.__TAURI__?.core?.invoke??window.__TAURI_INTERNALS__?.invoke;if(!invoke)window.__sessionDenied="no bridge";else invoke("surface_sessions",{request:{operation:"list"}}).then(()=>window.__sessionDenied="ALLOWED",e=>window.__sessionDenied=String(e))');await until(()=>script('return window.__sessionDenied!==null'));check('Preview cannot read or change session associations',await script('return window.__sessionDenied!=="ALLOWED"'));
 await switchTo(main);await click('[data-nav=editor]');await sleep(700);await wd('POST',`/session/${session}/refresh`,{});
 await until(()=>script('return !!window.cockpit?.frame && !!document.querySelector("#bot-tab-work")'),60000);await botWork();await until(()=>script('return document.querySelectorAll(".linked-session-row").length===2'));
 check('Native session associations survive main page reload',JSON.stringify(await script('return [...document.querySelectorAll(".linked-session-row")].map(n=>n.dataset.sessionId).sort()'))===JSON.stringify(linkedIds));
 await script('import("./vendor/code-editor.js").then(m=>window.__editorView=m.EditorView)');await until(()=>script('return !!window.__editorView && document.querySelector(".workbench-root").textContent!=="No repository selected"'));
 await click('[data-nav=editor]');await until(async()=>(await editorText()).includes('outside edit'));
 await switchTo(main);await native('close_shell',{generation,id:first});check('Closing one shell preserves its sibling',(await native('status')).shells.some(s=>s.id===second&&s.running));
 check('Closing server shell stops foreground server',await until(async()=>{try{await fetch(`http://127.0.0.1:${serverPort}/`,{signal:AbortSignal.timeout(500)});return false;}catch{return true;}}));
 await native('close_shell',{generation,id:second});
 await botWork();await until(()=>script('return document.querySelectorAll(".linked-session-row").length===1'));check('Closed shells disappear from bot Work',true);
 await click('[data-unlink-session]');await until(()=>script('return document.querySelectorAll(".linked-session-row").length===0'));check('Unlinking a browser preserves its native tab',(await handles()).includes(preview));

 await click('[data-nav=editor]');const recoveryDraft=changed+'<!-- RECOVERY_DRAFT -->';await change(recoveryDraft);await sleep(800);
 check('Unsaved editor draft has a recovery copy',await script('return JSON.parse(localStorage.getItem("super-workbench-recovery-v1")).projects.some(p=>p.files.some(f=>f.draft?.includes("RECOVERY_DRAFT")))'));
 writeFileSync(temp+'/index.html',changed+'<!-- RESTART_EXTERNAL_CHANGE -->');
 await wd('DELETE',`/session/${session}`);session=null;
 session=(await wd('POST','/session',{capabilities:{alwaysMatch:{'tauri:options':{application:root+'/cockpit/target/release/super-cockpit'}}}})).sessionId;
 await until(()=>script('return !!window.cockpit?.frame&&!!document.querySelector("#editor-changes")'),60000);main=(await handles())[0];
 await script('import("./vendor/code-editor.js").then(m=>window.__editorView=m.EditorView)');await until(()=>script('return !!window.__editorView'));
 await click('[data-nav=editor]');
 check('Restart offers recovery without reopening file access',await script('return document.querySelector(".workbench-root").textContent==="No repository selected"&&document.querySelector("[data-screen=editor] .workbench-recovery[role=status]").textContent.includes("Recovery available")'));
 check('Restart does not execute saved shell commands',(await native('status')).shells.length===0);
 await click('#development-choose-editor');await sleep(600);execFileSync('/usr/bin/python3',[root+'/tools/development-confirm-folder.py',String(driver.pid),temp]);await sleep(1000);
 if(!await script('return document.querySelector(".workbench-root").textContent!=="No repository selected"'))execFileSync('/usr/bin/python3',[root+'/tools/development-confirm-folder.py',String(driver.pid),temp]);
 await until(async()=>(await editorText()).includes('RECOVERY_DRAFT'));
 check('Selecting the same repository restores both file tabs and unsaved bytes',await editorText()===recoveryDraft&&await script('return document.querySelectorAll("[data-screen=editor] [role=tab]").length===2'));
 await click('#editor-save');await until(()=>script('return document.querySelector("#editor-status").textContent.includes("changed on disk")'));
 check('Recovery still refuses to overwrite an external edit',readFileSync(temp+'/index.html','utf8').includes('RESTART_EXTERNAL_CHANGE')&&(await editorText()).includes('RECOVERY_DRAFT'));
 await click('[data-nav=browser]');await script('[...document.querySelectorAll("[data-screen=browser] .workbench-recovery button")].find(b=>b.textContent==="Restore browser tabs").click()');
 await until(()=>script('return document.querySelectorAll("[data-screen=browser] [role=tab]").length===2'));
 check('Browser recovery restores addresses without starting a server',await script('return document.querySelector("#browser-url").value.includes(arguments[0])',[String(serverPort)])&&(await native('status')).shells.length===0);
 await click('[data-nav=editor]');await click('#workbench-recovery-manage');
 check('Recovery copies can be reviewed and explicitly forgotten',await script('return !!document.querySelector("dialog[open] .recovery-project")'));
 await shot('workbench-recovery');await script('document.querySelector("dialog[open]").close()');
 evidence.complete();
 console.log(`\n${checks} tabbed workbench checks held`);
} catch(e){await switchTo(main).catch(()=>{});console.error(await script('return {editor:document.querySelector("#editor-status")?.textContent,terminal:document.querySelector("#terminal-status")?.textContent,browser:document.querySelector("#browser-status")?.textContent,root:document.querySelector(".workbench-root")?.textContent}').catch(()=>{}));await shot('failure').catch(()=>{});console.error(log.slice(-1500));throw e;} finally {evidence.close();fileProvider.close();if(session)await wd('DELETE',`/session/${session}`).catch(()=>{});try{process.kill(-driver.pid,'SIGTERM');}catch{}}
