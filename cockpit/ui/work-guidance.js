import {taskAttentionPanel} from './task-attention.js';
// All measurements describe one accepted frame; no simulated trends or cached world facts.
export function summarizeWork(p,workspace='') {
  const workspaces=Object.values(p.workspaces??{}).filter(w=>!workspace||w.id===workspace);
  const goals=Object.values(p.goals??{}).filter(g=>!workspace||g.workspace_ref===workspace);
  const goalIds=new Set(goals.map(g=>g.id));
  const lanes=Object.values(p.lanes??{}).filter(l=>!workspace||goalIds.has(l.goal_ref));
  const laneIds=new Set(lanes.map(l=>l.id));
  const workers=Object.values(p.workers??{}).filter(w=>!workspace||laneIds.has(w.locus_ref));
  const unassignedGoals=goals.filter(g=>!lanes.some(l=>l.goal_ref===g.id));
  const unstaffedLanes=lanes.filter(l=>!workers.some(w=>w.locus_ref===l.id&&w.status==='open'));
  const counts={};for(const w of workers){const state=w.status==='open'?(w.occupancy||'Not reported'):(w.status||'Not reported');counts[state]=(counts[state]||0)+1;}
  const outcomes=(p.validations?.recent??[]).filter(r=>r.kind==='validation_job_outcome@1');
  const validation={};for(const r of outcomes){const label=r.state==='completed'?`Completed · ${r.verdict??'No verdict'}`:`${r.state??'Not reported'} · ${r.reason??'No reason'}`;validation[label]=(validation[label]||0)+1;}
  return {workspaces,goals,lanes,workers,offlineWorkers:workers.filter(w=>w.status==='open'&&String(w.occupancy).toUpperCase()==='OFFLINE'),unassignedGoals,unstaffedLanes,counts,validation,
    pending:(p.grant_requests??[]).length+(p.pending_approvals??[]).length,
    unresolved:Object.values(p.carrier_attempts??{}).length,
    evidenceTotal:[p.validations,p.worktree_receipts,p.receipts].reduce((n,w)=>n+(Number.isFinite(w?.total)?w.total:0),0)};
}
export function guidance({node,card,detail,p,workspace}) {
  const s=summarizeWork(p,workspace),root=node('section',undefined,'work-guidance');
  root.append(taskAttentionPanel({node,p,workspace}));
  root.append(node('h2','Next steps'));
  const items=[];
  if(!s.workspaces.length)items.push(['Create a workspace','new-workspace','Start by giving your project a home.']);
  if(s.workspaces.length&&!s.goals.length)items.push(['Define a goal','goals','Describe the result you want to achieve.']);
  if(!Object.keys(p.repositories??{}).length)items.push(['Connect a repository','repositories','Add the Super repository before setting up a development lane.']);
  if(s.unassignedGoals.length)items.push([`${s.unassignedGoals.length} ${s.unassignedGoals.length===1?'goal needs a lane':'goals need lanes'}`,'goals','Open a goal and assign a lane to it.']);
  if(s.unstaffedLanes.length)items.push([`${s.unstaffedLanes.length} ${s.unstaffedLanes.length===1?'lane has':'lanes have'} no open worker`,'lanes','Assign a worker to prepare the lane for execution.']);
  if(s.offlineWorkers.length)items.push([`${s.offlineWorkers.length} ${s.offlineWorkers.length===1?'worker is':'workers are'} offline`,'runtime-assignments','Inspect the assignment and runtime connection before expecting work to run.']);
  if(s.pending)items.push([`${s.pending} ${s.pending===1?'request needs':'requests need'} your decision`,'mission','Review grant requests and effect consent in Mission Control. Whole runtime.']);
  if(s.unresolved)items.push([`${s.unresolved} unresolved ${s.unresolved===1?'start':'starts'}`,'runtime','Inspect the runtime record before reconciling. Whole runtime.']);
  for(const [title,route,description] of items){const row=node('article',undefined,'guidance-item');const b=node('button',title,'subtle');b.dataset.nav=route;row.append(b,node('p',description));root.append(row);}
  if(!items.length)root.append(node('p','No setup gaps found in this frame. Worker assignment alone does not confirm execution.','empty'));
  const stats=node('div',undefined,'stats-grid');stats.append(card('Goals',s.goals.length,'Selected workspace view'),card('Lanes',s.lanes.length,'Selected workspace view'),card('Goals without lanes',s.unassignedGoals.length),card('Lanes without open workers',s.unstaffedLanes.length));root.append(stats);
  function bars(title,counts,scope){
    const chart=node('section',undefined,'frame-chart');chart.append(node('h2',title),node('p',scope,'scope-note'));
    const total=Object.values(counts).reduce((a,b)=>a+b,0);
    if(!total)chart.append(node('p','No records reported yet.','empty'));
    for(const [label,value] of Object.entries(counts)){const row=node('div',undefined,'chart-row');const meter=node('meter');meter.min=0;meter.max=total;meter.value=value;meter.setAttribute('aria-label',`${label}: ${value} of ${total}`);row.append(node('span',label),meter,node('strong',String(value)));chart.append(row);}return chart;
  }
  root.append(bars('Worker state',s.counts,'Current frame · selected workspace view'),bars('Recent validation outcomes',s.validation,'Whole runtime · supplied recent window only; starts are not results.'));
  if(s.unassignedGoals.length){root.append(node('h2','Goals awaiting lanes'));for(const g of s.unassignedGoals)root.append(detail(g,`guidance-goal:${g.id}`,g.title));}
  return root;
}
export function updateNavCounts(p,workspace='') {
  const s=p?summarizeWork(p,workspace):null;
  const values=s?{mission:s.pending,positions:s.workspaces.length,goals:s.goals.length,lanes:s.lanes.length,repositories:Object.keys(p.repositories??{}).length,agents:(p.peers??[]).length,capabilities:(p.grants??[]).length,evidence:s.evidenceTotal,authority:(p.grants??[]).length}:{};
  document.querySelectorAll('[data-nav-count]').forEach(n=>{
    const id=n.dataset.navCount,value=values[id];n.textContent=value===undefined?'':String(value);n.hidden=value===undefined;
    n.classList.toggle('needs-attention',id==='mission'&&value>0);
    n.title=['positions','goals','lanes'].includes(id)?'Selected workspace view':id==='evidence'?'Total records across three supplied histories':'Whole runtime';
  });
}
