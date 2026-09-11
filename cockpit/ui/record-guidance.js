// Derive setup gaps from one delivered frame. A connected worker is not proof of success.
export function recordGuidance(p,kind,r) {
  const allGoals=Object.values(p.goals??{}),allLanes=Object.values(p.lanes??{}),allWorkers=Object.values(p.workers??{});
  let goals=[],lanes=[],workers=[];
  if(kind==='Workspace')goals=allGoals.filter(g=>g.workspace_ref===r.id);
  if(kind==='Goal')goals=[r];
  if(kind==='Workspace'||kind==='Goal'){const ids=new Set(goals.map(g=>g.id));lanes=allLanes.filter(l=>ids.has(l.goal_ref));}
  if(kind==='Lane')lanes=[r];
  if(kind==='Bot')lanes=allLanes.filter(l=>l.actor===r.actor);
  if(kind==='Repository')lanes=allLanes.filter(l=>l.repository_ref===r.ref);
  const laneIds=new Set(lanes.map(l=>l.id));workers=kind==='Worker'?[r]:allWorkers.filter(w=>laneIds.has(w.locus_ref));
  const flags=[];
  const form=(title,text,field,value,focus)=>flags.push({title,text,form:{field,value,focus}});
  if(kind==='Workspace'&&!goals.length)form('Define the first goal','Describe the outcome this workspace should produce.','goal_ws',r.id,'goal_title');
  for(const g of goals)if(!lanes.some(l=>l.goal_ref===g.id))form('Goal needs a lane',g.title||g.id,'lane_goal',g.id,'lane_actor');
  for(const l of lanes){if(!l.repository_ref||!p.repositories?.[l.repository_ref])flags.push({title:'Repository not available',text:l.id+' · Check its registered repository before starting work.',nav:'repositories'});
    if(!workers.some(w=>w.locus_ref===l.id&&w.status==='open'))form('Lane needs an open worker',l.id,'worker_lane',l.id,'worker_purpose');}
  for(const w of workers)if(w.status==='open'&&w.occupancy==='OFFLINE')flags.push({title:'Worker is offline',text:w.purpose||w.id,record:'worker:'+w.id});
  const states={};for(const w of workers){const label=w.status==='open'?(w.occupancy||'Not reported'):(w.status||'Not reported');states[label]=(states[label]??0)+1;}
  return {goals,lanes,workers,flags,states};
}
export function renderRecordGuidance(node,p,kind,r) {
  if(!['Workspace','Goal','Lane','Worker','Bot','Repository'].includes(kind))return null;
  const s=recordGuidance(p,kind,r),root=node('section',undefined,'record-guidance');root.append(node('h2','Next steps'));
  if(!s.flags.length)root.append(node('p','No setup gaps in the delivered records. Execution and validation results are separate evidence.','scope-note'));
  for(const f of s.flags.slice(0,50)){const row=node('article',undefined,'record-flag');row.dataset.id='flag-'+JSON.stringify(f);const b=node('button',f.title,'subtle');b.type='button';if(f.form){b.dataset.recordForm=f.form.field;b.dataset.recordValue=f.form.value;b.dataset.recordFocus=f.form.focus;}if(f.nav)b.dataset.nav=f.nav;if(f.record)b.dataset.recordOpen=f.record;row.append(b,node('span',f.text));root.append(row);}
  if(s.flags.length>50)root.append(node('p',`Showing 50 of ${s.flags.length} setup gaps. Open related work for the complete directory.`,'scope-note'));
  const stats=node('div',undefined,'record-stats');for(const [label,count] of [['Lanes',s.lanes.length],['Open workers',s.workers.filter(w=>w.status==='open').length],['Setup gaps',s.flags.length]]){const n=node('div');n.append(node('strong',String(count)),node('span',label));stats.append(n);}root.append(stats);
  if(s.workers.length){root.append(node('h2','Reported worker state'));for(const [state,count] of Object.entries(s.states)){const row=node('div',undefined,'chart-row');const meter=node('meter');meter.min=0;meter.max=s.workers.length;meter.value=count;meter.setAttribute('aria-label',state+': '+count+' of '+s.workers.length);row.append(node('span',state),meter,node('strong',String(count)));root.append(row);}}
  return root;
}
