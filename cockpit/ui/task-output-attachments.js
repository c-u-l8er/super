import {node} from './app-shell.js';
export function outputAttachments({record,save}){
 const panel=node('details',undefined,'task-output-attachments');panel.append(node('summary','Before and after logs · tests, benchmarks or terminal output'),node('p','Import text logs from work done outside Super. Record the exact command (including inputs and benchmark units), source version and machine/environment. Imported logs are user-supplied evidence; they do not establish a passing check or acceptance.','directory-note'));
 const pair=node('div',undefined,'screenshot-pair');panel.append(pair);
 for(const side of ['before','after']){
  const saved=record.outputs?.[side],box=node('section');box.append(node('h4',side==='before'?'Before log':'After log'));
  if(saved){box.append(node('p',`${saved.command} · ${saved.environment}`),node('p','Source: '+saved.source,'directory-note'),node('p','Imported log · origin unverified','directory-note'),node('pre',saved.text,'attempt-text'));const remove=node('button','Remove '+side+' log');remove.type='button';remove.onclick=()=>save(side,'remove_output').catch(e=>{status.textContent=String(e.message||e);});box.append(remove);}
  const fields={};for(const [key,title] of [['command','Command, inputs and units'],['source','Source version / commit'],['environment','Machine and environment']]){const label=node('label',title,'field'),input=node('input');input.type='text';input.maxLength=1000;input.required=true;input.value=saved?.[key]||'';fields[key]=input;label.append(input);box.append(label);}
  const label=node('label','Import '+side+' text log','field'),file=node('input');file.type='file';file.accept='.txt,.log,.json,.csv,text/plain';file.setAttribute('aria-label','Import '+side+' text log');const status=node('p');status.setAttribute('role','status');label.append(file);box.append(label,status);
  file.onchange=async()=>{const chosen=file.files[0];if(!chosen)return;try{if(chosen.size>100000)throw Error('Choose a text log no larger than 100 KB.');for(const input of Object.values(fields))if(!input.reportValidity()){file.value='';return;}const text=await chosen.text();if(text.includes('\0'))throw Error('Choose a text log, not a binary file.');await save(side,'save_output',{text,...Object.fromEntries(Object.entries(fields).map(([k,v])=>[k,v.value]))});}catch(e){status.textContent=String(e.message||e);}finally{file.value='';}};
  pair.append(box);
 }
 return panel;
}
