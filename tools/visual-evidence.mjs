// Optional visual receipts from the existing native fixtures. No product state changes.
import {mkdirSync,writeFileSync,readFileSync,existsSync} from 'node:fs';
import {resolve} from 'node:path';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
export function visualEvidence(suite,root,driver,selected=[]){
 const destination=process.env.SUPER_VISUAL_EVIDENCE_DIR;
 if(!destination)return {record(){},capture(){},complete(){},close(){},skip(){}};
 if(!process.env.SUPER_NATIVE_NO_WINDOW_MANAGER||!process.env.DISPLAY)throw Error('Visual evidence requires the isolated native display wrapper.');
 const dir=resolve(destination,suite);mkdirSync(dir,{recursive:true});
 const data={schema:'super-visual-evidence@1',suite,status:'running',started_at:new Date().toISOString(),environment:'Isolated X11 native Super window; disposable data; deterministic local provider where used',binary_sha256:createHash('sha256').update(readFileSync(resolve(root,'cockpit/target/release/super-cockpit'))).digest('hex'),test_sha256:createHash('sha256').update(readFileSync(resolve(root,'tools',suite+'.mjs'))).digest('hex'),checks:[],captures:[],skips:[]};
 const save=()=>writeFileSync(resolve(dir,'evidence.json'),JSON.stringify(data,null,2)+'\n');save();
 function capture(label){
  const file=String(data.captures.length+1).padStart(2,'0')+'-'+label.toLowerCase().replace(/[^a-z0-9]+/g,'-').slice(0,100)+'.png';
  execFileSync('/usr/bin/python3',[resolve(root,'tools/development-capture-window.py'),String(driver.pid),resolve(dir,file)],{timeout:20000});
  if(!existsSync(resolve(dir,file)))throw Error('Native capture missing');
  const receipt={label,file,captured_at:new Date().toISOString(),after_check:data.checks.length,sha256:createHash('sha256').update(readFileSync(resolve(dir,file))).digest('hex')};data.captures.push(receipt);save();return receipt;
 }
 return {capture,record(label){data.checks.push({label,status:'passed',at:new Date().toISOString()});save();if(selected.includes(label))capture(label);},skip(label){data.skips.push(label);save();},complete(){data.status='passed';data.finished_at=new Date().toISOString();save();},close(){if(data.status==='running'){data.status='incomplete';data.finished_at=new Date().toISOString();save();}}};
}
