// Display labels and markup never replace original provider/storage text.
let records=new Map(), world=null;
const pattern=/\b(?:ws|gl|ln|wk|rp|bt)\\?_\d+\b/g;
const normalize=id=>id.replace('\\_','_');
export function referenceWorld(){return world;}
export function setReferenceFrame(frame){
  world=frame?.world?JSON.stringify([frame.world.world_incarnation,frame.world.world_generation,frame.world.projection_epoch]):null;
  records=new Map();const p=frame?.projection??{};
  for(const [kind,prefix,key] of [['Bot','bt','bots'],['Workspace','ws','workspaces'],['Goal','gl','goals'],['Lane','ln','lanes'],['Worker','wk','workers'],['Repository','rp','repositories']])for(const r of Object.values(p[key]??{})){
    const id=r.id??r.ref;if(!id)continue;
    const title=[r.name,r.title,r.purpose,kind==='Lane'?r.actor:null].find(v=>typeof v==='string'&&v.trim());
    records.set(id,{id,kind,record:r,label:title?.trim()||`${kind} ${id.split('_').at(-1).replace(/^0+/,'')||'0'}`,key:`${prefix==='ws'?'position-workspace':kind.toLowerCase()}:${id}`});
  }
}
export function reference(id){return records.get(normalize(id));}
export function readable(text){return String(text??'').replace(pattern,id=>reference(id)?.label??id);}
function signature(raw,origin,mode){return JSON.stringify([raw,origin,world,mode,[...raw.matchAll(pattern)].map(m=>reference(m[0])?.label)]);}
function prepare(element,raw,origin,mode){const key=signature(raw,origin,mode);if(element.dataset.referenceRender===key)return false;element.dataset.referenceRender=key;element.dataset.rawText=raw;element.dataset.referenceWorld=origin??'';element.dataset.textFormat=mode;element.replaceChildren();return true;}
function appendReferences(element,text,origin){
  let end=0;for(const match of text.matchAll(pattern)){element.append(document.createTextNode(text.slice(end,match.index)));const r=reference(match[0]);
    if(r){const a=document.createElement('a');a.href=`#record-${r.id}`;a.dataset.recordRef=r.id;a.textContent=r.label;
      a.title=`${r.kind}: ${r.id} — open current record${origin!==world?' (current lookup from an older message)':''}`;
      a.setAttribute('aria-label',`${r.label}, ${r.kind} ${r.id}, open current record`);element.append(a);
    }else element.append(document.createTextNode(match[0]));end=match.index+match[0].length;
  }element.append(document.createTextNode(text.slice(end)));
}
export function referenceText(element,text,origin=world){const raw=String(text??'');if(prepare(element,raw,origin,'plain'))appendReferences(element,raw,origin);}
function inline(element,text,origin){
  const markup=/(\*\*([^\n]+?)\*\*|`([^`\n]+)`|\*([^*\n]+)\*)/g;let end=0;
  for(const m of text.matchAll(markup)){appendReferences(element,text.slice(end,m.index),origin);const tag=m[2]?'strong':m[3]?'code':'em';const n=document.createElement(tag);appendReferences(n,m[2]??m[3]??m[4],origin);element.append(n);end=m.index+m[0].length;}appendReferences(element,text.slice(end),origin);
}
export function renderMessage(element,text,origin=world){
  const raw=String(text??'');if(!prepare(element,raw,origin,'message'))return;
  const lines=raw.split('\n');let i=0;
  while(i<lines.length){
    if(!lines[i].trim()){i++;continue;}
    if(/^\s*```/.test(lines[i])){i++;const code=[];while(i<lines.length&&!/^\s*```/.test(lines[i]))code.push(lines[i++]);if(i<lines.length)i++;const pre=document.createElement('pre'),c=document.createElement('code');c.textContent=code.join('\n');pre.append(c);element.append(pre);continue;}
    const list=lines[i].match(/^\s*(?:([-*])|(\d+)\.)\s+(.+)$/);
    if(list){const ul=document.createElement(list[2]?'ol':'ul');while(i<lines.length){const item=lines[i].match(/^\s*(?:([-*])|(\d+)\.)\s+(.+)$/);if(!item||!!item[2]!==!!list[2])break;const li=document.createElement('li');inline(li,item[3],origin);ul.append(li);i++;}element.append(ul);continue;}
    const heading=lines[i].match(/^#{1,6}\s+(.+)$/);if(heading){const h=document.createElement('h3');inline(h,heading[1],origin);element.append(h);i++;continue;}
    const p=document.createElement('p');const parts=[];while(i<lines.length&&lines[i].trim()&&!/^\s*(?:```|[-*]\s|\d+\.\s|#{1,6}\s)/.test(lines[i]))parts.push(lines[i++]);if(!parts.length)parts.push(lines[i++]);inline(p,parts.join('\n'),origin);element.append(p);
  }
}
export function refreshReferenceText(root){for(const el of root.querySelectorAll('[data-raw-text]'))(el.dataset.textFormat==='message'?renderMessage:referenceText)(el,el.dataset.rawText,el.dataset.referenceWorld||null);}
