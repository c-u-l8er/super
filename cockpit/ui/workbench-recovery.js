// Local recovery copies only. Never stores credentials, process handles or commands.
export const RECOVERY_KEY='super-workbench-recovery-v1';
const MAX=3_000_000;
function text(v,n){if(typeof v!=='string'||v.length>n)throw Error('Invalid recovery text.');return v;}
function path(v){v=text(v,4096);if(!v||v.startsWith('/')||v.includes('\0')||v.split('/').some(p=>!p||p==='.'||p==='..'||p==='.git'))throw Error('Invalid recovery file path.');return v;}
function url(v){const u=new URL(text(v,8192));if(!['http:','https:'].includes(u.protocol)||!['localhost','127.0.0.1','[::1]'].includes(u.hostname)||u.username||u.password)throw Error('Invalid recovery address.');return u.href;}
function array(v,n,clean){if(!Array.isArray(v)||v.length>n)throw Error('Recovery limit exceeded.');return v.map(clean);}
function project(v){const seen=new Set();return {root:text(v.root,4096),selected:v.selected===null?null:path(v.selected),files:array(v.files,16,f=>{const p=path(f.path);if(seen.has(p))throw Error('Duplicate recovery file.');seen.add(p);return f.dirty===true?{path:p,dirty:true,original:f.original===null?null:text(f.original,1048576),draft:text(f.draft,1048576)}:{path:p,dirty:false};})};}
function clean(v){if(v.version!==1)throw Error('Unsupported recovery format.');const roots=new Set();return {version:1,projects:array(v.projects,5,p=>{const value=project(p);if(!value.root||roots.has(value.root))throw Error('Invalid recovery repository.');roots.add(value.root);return value;}),browsers:array(v.browsers,8,url),shells:Number.isInteger(v.shells)&&v.shells>=0&&v.shells<=8?v.shells:0};}
export function createWorkbenchRecovery(storage){
  let state={version:1,projects:[],browsers:[],shells:0},error=null;
  try{const raw=storage.getItem(RECOVERY_KEY);if(raw){if(raw.length>MAX)throw Error('Recovery copy exceeds the supported limit.');state=clean(JSON.parse(raw));}}catch(e){error='Recovery could not load: '+e.message+' Existing saved data was kept.';}
  const copy=v=>JSON.parse(JSON.stringify(v));
  function commit(next){if(error)throw Error(error);next=clean(next);const raw=JSON.stringify(next);if(raw.length>MAX)throw Error('Recovery storage is full. Save files to disk or forget an older repository recovery copy.');try{storage.setItem(RECOVERY_KEY,raw);}catch{throw Error('Could not save recovery on this device. Keep Super open until you save your drafts to disk.');}state=next;}
  return {get error(){return error;},snapshot:()=>copy(state),get:root=>copy(state.projects.find(p=>p.root===root)??null),
    saveProject(value){value=project(value);const projects=state.projects.filter(p=>p.root!==value.root);if(projects.length>=5)throw Error('Five repositories are saved for recovery. Forget an older recovery copy first.');commit({...state,projects:[...projects,value]});},
    saveSurfaces(browsers,shells){commit({...state,browsers,shells});},
    forget(root){commit({...state,projects:state.projects.filter(p=>p.root!==root)});},
    clear(){try{storage.removeItem(RECOVERY_KEY);}catch{throw Error('Could not clear recovery data.');}state={version:1,projects:[],browsers:[],shells:0};error=null;}
  };
}
export function recoveryFile(saved,disk){
  if(!saved.dirty||disk===saved.draft)return {path:saved.path,original:disk,draft:disk,changed:false};
  // The original bytes must survive: saving will still refuse an external edit.
  return {path:saved.path,original:saved.original,draft:saved.draft,changed:disk!==saved.original};
}
export function patchAttachment(diff){
  const sections=[['Working tree compared with index',diff.working],['Staged compared with HEAD',diff.staged],['Untracked file',diff.untracked]];
  const header=`Git review snapshot: ${diff.path}\nCaptured: ${new Date().toISOString()}\nSaved disk state only; unsaved drafts excluded. This is not validation or acceptance.\n`;
  const full=header+sections.filter(([title,s])=>s!==null&&s!==undefined&&(s!==''||title==='Untracked file')).map(([title,s])=>'\n'+title+'\n'+(s||'(Empty file)')).join('');
  const bytes=new TextEncoder().encode(full),limit=23000;
  return bytes.length<=limit?full:new TextDecoder().decode(bytes.slice(0,limit))+'\n[Patch excerpt truncated. Open Changes to inspect the full diff.]';
}
