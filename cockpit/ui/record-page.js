import {renderRecordGuidance} from './record-guidance.js';
import {recordTab} from './record-tabs.js';
import { reference, referenceText, readable } from './references.js';
const names={id:'Record ID',ref:'Reference',actor:'Assigned actor',locus_ref:'Lane',workspace_ref:'Workspace',goal_ref:'Goal',repository_ref:'Repository',worker_ref:'Worker',purpose:'Purpose',occupancy:'Connection',world_ref:'World',schema:'Record format',created_at:'Created',public_message:'What happened',operator_detail:'Details',requires_human:'Needs your attention',ticket_id:'Attempt ID',authority_basis:'Authority basis',profile_basis:'Profile basis',terminal:'Terminal'};
export const fieldName=k=>names[k]??k.replaceAll('_',' ').replace(/\b\w/g,c=>c.toUpperCase());
export function describeRecord(record,key,label){
  const id=record.id??record.ref;const known=id?reference(id):null;
  const kind=known?.kind??({'runtime-identity':'Runtime identity','settings-runtime':'Connection',channel:'Channel',attempt:'Carrier start',seal:'Store seal',refusal:'Refusal',agent:'Connected peer',authority:'Grant',validations:'Validation',worktree:'Worktree establishment',receipts:'Effect receipt'}[key.split(':')[0]]??'Record');
  const title=known?.label??record.name?.trim()??record.title?.trim()??record.public_message??record.code??(label==='View record details'?record.kind:label)??kind;
  return {id,kind,title:readable(title||kind),status:record.occupancy??record.state??record.status??record.verdict};
}
export function renderRecordPage({node,entry,frame,backLabel,detail}){
  const page=node('section',undefined,'app-screen record-page');page.dataset.screen='record';
  const back=node('button',`← ${backLabel||'Back'}`,'record-back');back.type='button';back.dataset.recordBack='true';page.append(back);
  if(!entry){page.append(node('p','RECORD UNAVAILABLE','eyebrow'),node('h1','This record is no longer available'),node('p','It may have been removed, left the delivered history window, or belonged to an earlier runtime. Return to the list to see current records.','screen-description'));return page;}
  const {record:r,key,label}=entry,p=frame.projection??{},info=describeRecord(r,key,label);
  page.dataset.recordKey=key;
  const header=node('header',undefined,'record-page-header');header.append(node('p',info.kind.toUpperCase(),'eyebrow'),node('h1',info.title));
  const meta=node('div',undefined,'record-meta');if(info.id)meta.append(node('span',info.id,'record-id'));
  if(info.status)meta.append(node('span',String(info.status).replaceAll('_',' '),'record-status'));header.append(meta);page.append(header);
  const actions=node('div',undefined,'record-actions');
  function action(label,intent,args,danger=false){const b=node('button',label,danger?'record-danger':'primary');b.type='button';b.dataset.intent=intent;b.dataset.args=JSON.stringify(args);if(danger)b.dataset.danger='true';return b;}
  function form(label,field,value,focus){const b=node('button',label,'primary');b.type='button';b.dataset.recordForm=field;b.dataset.recordValue=value;b.dataset.recordFocus=focus;actions.append(b);}
  const relatedTasks=Object.values(p.development_tasks??{}).filter(t=>({Workspace:t.workspace_ref,Goal:t.goal_ref,Lane:t.lane_ref,Bot:t.bot_ref,Repository:t.repository_ref}[info.kind])===(r.id??r.ref));
  if(relatedTasks.length){const plans=node('section');plans.append(node('h2','Development plans'));for(const t of relatedTasks){const b=node('button',`${t.title} · ${t.status}`,'subtle');b.type='button';b.dataset.developmentTask=t.id;plans.append(b);}page.append(plans);}
  const values=k=>Object.values(p[k]??{});
  const goals=values('goals'),lanes=values('lanes'),workers=values('workers');
  let children=[],linked=[];
  if(info.kind==='Workspace'){
    children=goals.filter(g=>g.workspace_ref===r.id);const ids=new Set(children.map(g=>g.id));const activeLanes=lanes.filter(l=>ids.has(l.goal_ref));
    form('Add goal','goal_ws',r.id,'goal_title');
    const stats=node('div',undefined,'record-stats');for(const [label,count] of [['Goals',children.length],['Lanes',activeLanes.length],['Workers',workers.filter(w=>activeLanes.some(l=>l.id===w.locus_ref)).length]]){const card=node('div');card.append(node('strong',String(count)),node('span',label));stats.append(card);}page.append(stats);
    linked.push(['Goals',children.map(g=>[g,`goal:${g.id}`,g.title||g.id])],['Lanes',activeLanes.map(l=>[l,`lane:${l.id}`,l.id])]);
  }else if(info.kind==='Goal'){
    form('Add lane','lane_goal',r.id,'lane_actor');linked.push(['Lanes',lanes.filter(l=>l.goal_ref===r.id).map(l=>[l,`lane:${l.id}`,l.id])]);
  }else if(info.kind==='Lane'){
    form('Assign worker','worker_lane',r.id,'worker_purpose');linked.push(['Workers',workers.filter(w=>w.locus_ref===r.id).map(w=>[w,`worker:${w.id}`,w.purpose||w.id])]);
  }else if(info.kind==='Worker'){
    if(r.status==='open')actions.append(action('Close worker','close_worker',{worker_ref:r.id},true));
    else if(r.status==='closed')actions.append(action('Reopen worker','reopen_worker',{worker_ref:r.id}));
    if(r.terminal==='PRESENT'&&r.status==='open')actions.append(action('Watch terminal','terminal_bind',{worker_ref:r.id,expected_worker_generation:r.generation??1}));
  }else if(info.kind==='Bot'){
    form('Create lane for this bot','lane_actor',r.actor,'lane_goal');
    linked.push(['Lanes',lanes.filter(l=>l.actor===r.actor).map(l=>[l,`lane:${l.id}`,l.id])]);
    const workspace=p.workspaces?.[r.workspace_ref];if(workspace)linked.push(['Workspace',[[workspace,`position-workspace:${workspace.id}`,workspace.name]]]);
  }else if(info.kind==='Repository')linked.push(['Lanes using this repository',lanes.filter(l=>l.repository_ref===r.ref).map(l=>[l,`lane:${l.id}`,l.id])]);
  if(actions.children.length)page.append(actions);
  const tabKey=JSON.stringify([frame.world?.world_incarnation,frame.world?.world_generation,frame.world?.projection_epoch,key]),selectedTab=recordTab(tabKey);page.dataset.tabKey=tabKey;
  const tabs=node('nav',undefined,'record-tabs');tabs.setAttribute('aria-label','Record sections');tabs.setAttribute('role','tablist');
  const views={};for(const [id,title] of [['overview','Overview'],['work','Related work'],['data','Record data']]){const b=node('button',title);b.type='button';b.dataset.recordTab=id;b.setAttribute('role','tab');b.id='record-tab-'+id;b.setAttribute('aria-controls','record-panel-'+id);b.tabIndex=selectedTab===id?0:-1;b.setAttribute('aria-selected',String(selectedTab===id));tabs.append(b);const view=node('div');view.dataset.recordView=id;view.id='record-panel-'+id;view.setAttribute('role','tabpanel');view.setAttribute('aria-labelledby',b.id);view.hidden=selectedTab!==id;views[id]=view;}
  page.append(tabs,views.overview,views.work,views.data);
  const guidance=renderRecordGuidance(node,p,info.kind,r);if(guidance)views.overview.append(guidance);
  const content=node('div',undefined,'record-content-grid');
  function scalar(value){if(value===null||value===undefined||value==='')return node('span','Not set','field-unset');if(typeof value==='boolean')return node('span',value?'Yes':'No');const text=node('span');referenceText(text,String(value));return text;}
  function fields(object,depth=0){
    if(depth>10)return node('p','Further nested data is not displayed.','availability-note');
    if(Array.isArray(object)){const list=node('div',undefined,'record-value-list');if(!object.length)list.append(node('span','None','field-unset'));for(const item of object){const row=node('div',undefined,'record-value-item');row.append(item&&typeof item==='object'?fields(item,depth+1):scalar(item));list.append(row);}return list;}
    const dl=node('dl',undefined,'record-fields');const entries=Object.entries(object??{});if(!entries.length)dl.append(node('p','No additional fields.','field-unset'));
    for(const [key,value] of entries){const group=node('div',undefined,'record-field');group.dataset.fieldKey=key;const term=node('dt',fieldName(key)),definition=node('dd');definition.append(value&&typeof value==='object'?fields(value,depth+1):scalar(value));group.append(term,definition);dl.append(group);}return dl;
  }
  const primary={},technical={};for(const [k,v] of Object.entries(r)){if(['schema','world_ref','generation','profile_basis','authority_basis','projection_epoch','authority_revision','world_generation','view_revision'].includes(k))technical[k]=v;else if(!['id','ref','name','title','purpose'].includes(k))primary[k]=v;}
  if(r.purpose&&info.kind!=='Worker')primary.purpose=r.purpose;
  const overview=node('section',undefined,'record-section');overview.append(node('h2','Overview'),fields(primary));if(Object.keys(primary).length)content.append(overview);
  const relationships=node('aside',undefined,'record-relations');
  for(const [title,items] of linked){const section=node('section',undefined,'record-section');section.append(node('h2',title));if(!items.length)section.append(node('p',`No ${title.toLowerCase()} yet.`,'empty'));for(const [rec,k,lab] of items)section.append(detail(rec,k,lab));relationships.append(section);}
  if(relationships.children.length)views.work.append(relationships);else views.work.append(node('p','No related work is supplied for this record.','empty'));views.overview.append(content);
  if(Object.keys(technical).length){const section=node('section',undefined,'record-section record-metadata');section.append(node('h2','Record information'),fields(technical));views.data.append(section);}
  if(!Object.keys(technical).length)views.data.append(node('p','No additional record metadata is supplied.','empty'));
  if(info.kind==='Workspace'){
    const settings=node('section',undefined,'record-section workspace-settings');settings.append(node('h2','Workspace settings'));
    const hasLanes=lanes.some(l=>children.some(g=>g.id===l.goal_ref));
    const hasBots=Object.values(p.bots??{}).some(b=>b.workspace_ref===r.id);
    if(hasBots)settings.append(node('p','Remove this workspace’s registered bots before deleting it.','availability-note'));
    if(hasLanes)settings.append(node('p','Deletion is unavailable while this workspace contains lanes. The lanes in Related work keep its workers and permissions connected.','availability-note'));
    else if(!hasBots){settings.append(node('p',`Deleting this workspace also removes its ${children.length} goal(s). Repository files and saved conversations remain.`));const remove=action('Delete workspace…','delete_workspace',{workspace_ref:r.id},true);remove.classList.add('workspace-delete');remove.dataset.confirm=`Delete “${info.title}” and its ${children.length} goal(s)? This cannot be undone. Repository files and chat history will remain.`;settings.append(remove);}views.overview.append(settings);
  }
  return page;
}
