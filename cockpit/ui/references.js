// Display labels and markup never replace original provider/storage text.
let records=new Map(), world=null;
/* THE ONE TABLE: display kind, id prefix, projection collection, record-route
 * prefix. `pattern` is DERIVED from it, so adding a kind here is the whole
 * change. It used to be typed by hand beside the table, and the two drifted:
 * plans (dt_) and review attempts (da_) were minted, projected and searched
 * by the palette while the pattern still knew six prefixes, so their ids
 * printed as plain text everywhere — even inside the paragraphs that did go
 * through this renderer. tools/check-reference-text.mjs holds the finder's
 * collections to this table. */
const kinds=[
  ['Bot','bt','bots','bot'],
  ['Workspace','ws','workspaces','position-workspace'],
  ['Goal','gl','goals','goal'],
  ['Lane','ln','lanes','lane'],
  ['Worker','wk','workers','worker'],
  ['Repository','rp','repositories','repository'],
  ['Development plan','dt','development_tasks','development-task'],
  ['Review attempt','da','development_attempts','development-attempt'],
];
export const referenceKinds=()=>kinds.map(([kind,prefix,collection,route])=>({kind,prefix,collection,route}));
const pattern=new RegExp(`\\b(?:${kinds.map(k=>k[1]).join('|')})\\\\?_\\d+\\b`,'g');
/** A fresh copy of the id pattern (global flag, so callers own their lastIndex). */
export const referencePattern=()=>new RegExp(pattern.source,'g');
const normalize=id=>id.replace('\\_','_');
/* Which kinds this surface can open. The desktop opens every kind; the phone
 * can only show plans, so it renders the rest as tooltip spans, not links. */
let routable=()=>true;
export function setReferenceRouting(fn){routable=typeof fn==='function'?fn:()=>true;}
export function referenceWorld(){return world;}
export function setReferenceFrame(frame){
  world=frame?.world?JSON.stringify([frame.world.world_incarnation,frame.world.world_generation,frame.world.projection_epoch]):null;
  records=new Map();const p=frame?.projection??{};
  for(const [kind,,key,route] of kinds)for(const r of Object.values(p[key]??{})){
    if(!r||typeof r!=='object')continue;const id=r.id??r.ref;if(typeof id!=='string'||!id)continue;
    const title=[r.name,r.title,kind==='Review attempt'&&typeof r.plan_title==='string'&&r.plan_title.trim()?`Review of ${r.plan_title.trim()}`:null,r.purpose,kind==='Lane'?r.actor:null].find(v=>typeof v==='string'&&v.trim());
    records.set(id,{id,kind,record:r,label:title?.trim()||id,key:`${route}:${id}`});
  }
}
export function reference(id){return records.get(normalize(id));}
// Shared display labels. Actor values are opaque identifiers, never names.
const kindOf=id=>kinds.find(([,prefix])=>id.startsWith(prefix+'_'))?.[0]??null;
const nameOf=r=>(r&&typeof r==='object'?[r.name,r.title,r.purpose].find(v=>typeof v==='string'&&v.trim())?.trim():null)||null;
function projected(projection,kind,id){
  const key=kinds.find(k=>k[0]===kind)?.[2];const bucket=key?projection?.[key]:null;if(!bucket||typeof bucket!=='object')return null;
  const direct=Array.isArray(bucket)?null:bucket[id];if(direct&&typeof direct==='object')return direct;
  return Object.values(bucket).find(r=>r&&typeof r==='object'&&(r.id??r.ref)===id)??null;
}
// recordLabel(id,{projection,kind,withId}): actual name/title when known, otherwise the stable ID.
// When a projection is supplied, only that projection is consulted, so labels never mix worlds;
// without one, the current reference frame is used. withId appends the ID for disambiguation.
// Lane labels combine the goal title with the bot registered for the lane actor.
export function recordLabel(id,{projection=null,kind,withId=false}={}){
  const stable=normalize(String(id??''));if(!stable)return '';
  const type=kind??kindOf(stable)??'Record';
  const find=(k,ref)=>projection?projected(projection,k,ref):(reference(ref)?.record??null);
  const record=find(type,stable);let title=null;
  if(type==='Lane'){
    if(record&&typeof record==='object'){
      const goal=typeof record.goal_ref==='string'?nameOf(find('Goal',record.goal_ref)):null;
      const actor=typeof record.actor==='string'&&record.actor?record.actor:null;
      const bots=projection?Object.values(projection.bots??{}):[...records.values()].filter(r=>r.kind==='Bot').map(r=>r.record);
      const bot=actor?bots.find(b=>b&&typeof b==='object'&&b.actor===actor):null;
      title=[goal,nameOf(bot)].filter(Boolean).join(' · ')||null;
    }
  }else title=nameOf(record);
  if(!title)return stable;
  return withId?`${title} (${stable})`:title;
}
export function selectionText(text){return String(text??'').replace(pattern,id=>{const r=reference(id);return r&&r.label!==r.id?`${r.label} (${r.id})`:id;});}
export function readable(text){return String(text??'').replace(pattern,id=>reference(id)?.label??id);}
function signature(raw,origin,mode,display){return JSON.stringify([raw,origin,world,mode,display,[...raw.matchAll(pattern)].map(m=>reference(m[0])?.label)]);}
function prepare(element,raw,origin,mode,display){const key=signature(raw,origin,mode,display);if(element.dataset.referenceRender===key)return false;element.dataset.referenceRender=key;element.dataset.rawText=raw;element.dataset.referenceWorld=origin??'';element.dataset.textFormat=mode;element.dataset.referenceDisplay=display;element.replaceChildren();return true;}
/* A reference inside a control (button, summary, label, another link) must not
 * be a link: a nested anchor is invalid HTML and steals the click from the
 * control that owns it. There it becomes a span with the same identity and
 * tooltip, and the click goes to the control. `demoteNestedReferences` applies
 * the same rule after a frame lands, for references built before their
 * control existed. */
const CONTROLS='button,summary,a,label';
function describe(r,origin,display,link){
  const shown=display==='id'?r.id:r.label,other=display==='id'?r.label:r.id;
  return {shown,title:`${r.kind}: ${other}${link?' — open current record':''}${origin!==world?' (current lookup from an older message)':''}`,aria:`${r.label}, ${r.kind} ${r.id}${link?', open current record':''}`};
}
function referenceNode(r,origin,display,element){
  const link=!element.closest?.(CONTROLS)&&routable(r.kind),d=describe(r,origin,display,link);
  const n=document.createElement(link?'a':'span');if(link)n.href=`#record-${r.id}`;else n.className='record-ref';
  n.dataset.recordRef=r.id;n.dataset.recordKind=r.kind;n.textContent=d.shown;n.title=d.title;n.setAttribute('aria-label',d.aria);return n;
}
export function demoteNestedReferences(root){
  for(const a of root.querySelectorAll(CONTROLS.split(',').map(c=>`${c} a[data-record-ref]`).join(','))){
    const r=reference(a.dataset.recordRef);const s=document.createElement('span');s.className='record-ref';s.dataset.recordRef=a.dataset.recordRef;s.dataset.recordKind=a.dataset.recordKind??'';
    const owner=a.closest('[data-reference-display]');const d=r?describe(r,owner?.dataset.referenceWorld||world,owner?.dataset.referenceDisplay,false):null;
    s.textContent=a.textContent;s.title=d?d.title:a.title;s.setAttribute('aria-label',d?d.aria:a.getAttribute('aria-label')??'');a.replaceWith(s);
  }
}
function appendReferences(element,text,origin,display='label'){
  let end=0;for(const match of text.matchAll(pattern)){element.append(document.createTextNode(text.slice(end,match.index)));const r=reference(match[0]);
    element.append(r?referenceNode(r,origin,display,element):document.createTextNode(match[0]));end=match.index+match[0].length;
  }element.append(document.createTextNode(text.slice(end)));
}
/* referenceText(element,text,origin,{display}) — `display:'label'` (default)
 * shows the record's name with the id in the tooltip; `display:'id'` shows the
 * id with the name in the tooltip, for lines whose job is the identity (record
 * headers, plan rows, palette results). Text with no id takes the fast path
 * and carries no render state. */
export function referenceText(element,text,origin=world,{display='label'}={}){
  const raw=String(text??'');
  if(!pattern.test(raw)){pattern.lastIndex=0;if(element.dataset.referenceRender!==undefined){delete element.dataset.referenceRender;delete element.dataset.rawText;delete element.dataset.referenceWorld;delete element.dataset.textFormat;delete element.dataset.referenceDisplay;}element.textContent=raw;return;}
  pattern.lastIndex=0;if(prepare(element,raw,origin,'plain',display))appendReferences(element,raw,origin,display);
}
function inline(element,text,origin){
  const markup=/(\*\*([^\n]+?)\*\*|`([^`\n]+)`|\*([^*\n]+)\*)/g;let end=0;
  for(const m of text.matchAll(markup)){appendReferences(element,text.slice(end,m.index),origin);const tag=m[2]?'strong':m[3]?'code':'em';const n=document.createElement(tag);appendReferences(n,m[2]??m[3]??m[4],origin);element.append(n);end=m.index+m[0].length;}appendReferences(element,text.slice(end),origin);
}
export function renderMessage(element,text,origin=world){
  const raw=String(text??'');if(!prepare(element,raw,origin,'message','label'))return;
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
export function refreshReferenceText(root){for(const el of root.querySelectorAll('[data-raw-text]')){const origin=el.dataset.referenceWorld||null;if(el.dataset.textFormat==='message')renderMessage(el,el.dataset.rawText,origin);else referenceText(el,el.dataset.rawText,origin,{display:el.dataset.referenceDisplay||'label'});}}
