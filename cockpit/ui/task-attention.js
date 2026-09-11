import {bindDisclosure} from './app-shell.js';
const disclosureState=new Map();
import {taskProgressRows} from './task-progress.js';
const kinds=[['blocked','Blocked or needs changes',['blocked','needs_changes']],['checks','Checks need attention',['checks_missing','checks_attention']],['waiting','Unfinished test reports',['waiting']],['decision','Review and decide',['decision']],['finish','Confirm plan completion',['finish']],['prepare','Ready to prepare',['prepare']]];
export function taskAttention(p,workspace='',botRef=''){
  if(!p)return {available:false,total:null,needsAttention:null,groups:[]};
  const rows=taskProgressRows(p,workspace,botRef),groups=kinds.map(([id,label,states])=>({id,label,rows:rows.filter(r=>states.includes(r.progress.state)).sort((a,b)=>a.task.title.localeCompare(b.task.title)||a.task.id.localeCompare(b.task.id))}));
  return {available:true,total:rows.length,needsAttention:groups.filter(g=>!['waiting','prepare'].includes(g.id)).reduce((n,g)=>n+g.rows.length,0),groups};
}
export function taskAttentionPanel({node,p,workspace='',botRef='',title='Development tasks'}){
  const data=taskAttention(p,workspace,botRef),section=node('section',undefined,'work-guidance');section.dataset.taskAttention=botRef?'bot':'workspace';section.append(node('h2',title));
  if(!data.available){section.append(node('p','Runtime unavailable. Task attention cannot be determined.','availability-note'));return section;}
  const summary=node('p',`${data.total} open ${data.total===1?'plan':'plans'} · ${data.needsAttention} need attention`,'availability-note');summary.dataset.taskAttentionTotal=String(data.total);summary.dataset.taskNeedsAttention=String(data.needsAttention);section.append(summary,node('p','One next step per open plan. Unfinished test reports do not confirm that a process is still running.','directory-note'));
  if(!data.total)section.append(node('p','No open development plans in this view.','empty'));
  for(const group of data.groups){if(!group.rows.length)continue;const box=node('details',undefined,'development-attempt');const key=JSON.stringify([workspace,botRef,group.id]);box.id='task-attention-'+encodeURIComponent(key);box.open=disclosureState.get(key)??true;box.dataset.taskAttentionGroup=group.id;box.append(node('summary',`${group.label} (${group.rows.length})`));bindDisclosure(box,open=>disclosureState.set(key,open));
    for(const {task,progress} of group.rows){const row=node('article',undefined,'guidance-item'),open=node('button',task.title,'subtle');open.type='button';open.dataset.developmentTask=task.id;row.append(open,node('p',progress.label+' · '+progress.reason,'directory-note'));box.append(row);}section.append(box);
  }return section;
}
