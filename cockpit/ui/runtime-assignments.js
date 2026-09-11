// Operational facts are taken from the current authoritative projection.
import {referenceText} from './references.js';
export function runtimeAssignments({frame,node,panel,card,detail}){
  const page=panel('runtime-assignments'),p=frame.projection??{};
  const workspaces=Object.values(p.workspaces??{}),goals=Object.values(p.goals??{}),lanes=Object.values(p.lanes??{}),workers=Object.values(p.workers??{}),caps=Object.values(p.worktree_caps??{});
  page.append(node('p','Whole runtime · independent of the workspace filter. Counts describe delivered records; occupancy and terminal state are reported by the runtime.','scope-note'));
  const stats=node('div',undefined,'stats-grid');stats.append(card('Workspaces',workspaces.length),card('Lanes',lanes.length),card('Open workers',workers.filter(w=>w.status==='open').length),card('Occupied workers',workers.filter(w=>w.occupancy==='OCCUPIED').length));page.append(stats);
  function table(title,headers,rows){
    const section=node('section',undefined,'runtime-table-section');section.append(node('h2',title));
    if(!rows.length){section.append(node('p','No records reported.','empty'));page.append(section);return;}
    const wrap=node('div',undefined,'runtime-table-scroll'),table=node('table',undefined,'runtime-table'),head=node('thead'),tr=node('tr');
    for(const h of headers){const th=node('th',h);th.scope='col';tr.append(th);}head.append(tr);table.append(head);const body=node('tbody');
    for(const [id,values] of rows){const row=node('tr');row.dataset.runtimeRecord=id;for(const value of values){const cell=node('td');if(value instanceof Node)cell.append(value);else referenceText(cell,value===null||value===undefined||value===''?'Not reported':String(value));row.append(cell);}body.append(row);}table.append(body);wrap.append(table);section.append(wrap);page.append(section);
  }
  function raw(id){return node('code',id??'Not reported','runtime-record-id');}
  table('Workspace lineage',['Workspace','Runtime ID','World generation','Goals','Lanes'],workspaces.map(w=>{
    const mine=goals.filter(g=>g.workspace_ref===w.id),ids=new Set(mine.map(g=>g.id));return [w.id,[w.id,raw(w.id),w.world_ref?.generation,mine.length,lanes.filter(l=>ids.has(l.goal_ref)).length]];
  }));
  table('Goal assignments',['Goal','Workspace','Runtime ID','Assigned lanes'],goals.map(g=>[g.id,[g.id,g.workspace_ref,raw(g.id),lanes.filter(l=>l.goal_ref===g.id).length]]));
  table('Lane bindings',['Lane','Goal','Allowed actor','Repository','Status','Active worktree capabilities'],lanes.map(l=>[l.id,[l.id,l.goal_ref,l.actor||'Not assigned',l.repository_ref,l.status,caps.filter(c=>c.locus_ref===l.id&&c.status==='active').length]]));
  table('Worker state',['Worker','Lane','Assignment','Occupancy','Terminal','Generation'],workers.map(w=>[w.id,[w.id,w.locus_ref,w.status,w.occupancy,w.terminal,w.generation]]));
  page.append(node('p','An open assignment does not prove execution. Occupancy and terminal availability are separate runtime facts. Open a worker record for its available controls.','availability-note'));
  const attempts=Object.values(p.carrier_attempts??{});
  table('Carrier attempts',['Attempt','Worker','State'],attempts.map(a=>[a.ticket_id,[a.ticket_id,a.worker_ref,a.state]]));
  page.append(detail({world:frame.world,runtime:p.runtime,manifest:p.world},'runtime-assignment-identity','Projection identity'));
  return page;
}
