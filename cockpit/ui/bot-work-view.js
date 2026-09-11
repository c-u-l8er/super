import {taskAttentionPanel} from './task-attention.js';
import {taskProgressRows} from './task-progress.js';
import {initLinkedSessions} from './linked-sessions.js';
import {node} from './app-shell.js';
import {heldProjection,runtimeWorld} from './runtime-bots.js';
import {botWork,watchable} from './bot-work.js';
export function initBotWork({root,conversation,current,invoke}){
  const tabs=node('div',undefined,'record-tabs');tabs.setAttribute('role','tablist');tabs.setAttribute('aria-label','Bot details');
  const work=node('section',undefined,'bot-work');work.id='bot-work';conversation.id='bot-conversation';
  const selected=new Map();let botId='',signature='';const buttons={};
  for(const [id,title] of [['conversation','Conversation'],['work','Work']]){
    const b=node('button',title);b.type='button';b.id='bot-tab-'+id;b.setAttribute('role','tab');b.setAttribute('aria-controls','bot-'+id);b.onclick=()=>select(id);buttons[id]=b;tabs.append(b);
    const panel=id==='work'?work:conversation;panel.setAttribute('role','tabpanel');panel.setAttribute('aria-labelledby',b.id);
    b.onkeydown=e=>{if(!['ArrowLeft','ArrowRight','Home','End'].includes(e.key))return;e.preventDefault();const next=e.key==='Home'?'conversation':e.key==='End'?'work':id==='work'?'conversation':'work';select(next);buttons[next].focus();};
  }
  conversation.before(tabs);root.append(work);const assignments=node('div');work.append(assignments);const linked=initLinkedSessions({parent:work,invoke});
  function select(id){selected.set(botId,id);conversation.hidden=id!=='conversation';work.hidden=id!=='work';for(const [key,b] of Object.entries(buttons)){b.setAttribute('aria-selected',String(id===key));b.tabIndex=id===key?0:-1;}}
  function link(title,kind,id){const b=node('button',title,'subtle');b.type='button';b.dataset.recordOpen=kind+':'+id;return b;}
  function form(title,field,value,focus){const b=node('button',title,'subtle');b.type='button';Object.assign(b.dataset,{recordForm:field,recordValue:value,recordFocus:focus});return b;}
  function refresh(id){
    botId=id;linked.setBot(id);select(selected.get(id)||'conversation');const p=heldProjection(current),data=botWork(p,id),world=runtimeWorld(current);
    const taskRows=taskProgressRows(p,'',data.bot?.id);const next=JSON.stringify([id,world,data,taskRows]);if(signature===next)return;signature=next;assignments.replaceChildren();
    assignments.append(node('h2','Assigned work'));
    if(data.state!=='registered'){assignments.append(node('p',data.state==='unavailable'?'Runtime unavailable. Reconnect to see current assignments and terminals.':'Register this bot in a workspace above to assign work to its runtime identity.','availability-note'));return;}
    const stats=node('div',undefined,'bot-work-stats');
    for(const [value,label] of [[data.lanes.length,'Assigned lanes'],[data.workers.filter(w=>w.status==='open').length,'Open workers'],[data.workers.filter(watchable).length,'Available terminals']]){const stat=node('div');stat.append(node('strong',String(value)),node('span',label));stats.append(stat);}
    const tasks=node('button','Open development tasks','subtle');tasks.type='button';tasks.onclick=()=>document.dispatchEvent(new CustomEvent('open-development-tasks',{detail:{bot:id}}));assignments.append(tasks);
    assignments.append(taskAttentionPanel({node,p,botRef:data.bot.id,title:'Development task attention'}));
    assignments.append(stats,node('p','Assignments and availability reported by the runtime. Open workers may be idle or offline.','availability-note'),form('Create lane for this bot','lane_actor',data.bot.actor,'lane_goal'));
    if(!data.lanes.length)assignments.append(node('p','No lanes assigned yet. Create a lane, choose its goal and repository, then assign a worker.','bot-work-empty'));
    for(const lane of data.lanes){
      const section=node('section',undefined,'bot-work-lane');section.append(link(lane.id,'lane',lane.id),node('span',lane.status||'Status not reported','status-chip'),link(p.goals[lane.goal_ref].title||lane.goal_ref,'goal',lane.goal_ref));
      const workers=data.workers.filter(w=>w.locus_ref===lane.id);
      if(!workers.some(w=>w.status==='open'))section.append(node('p','No open worker assigned.','availability-note'),form('Assign worker','worker_lane',lane.id,'worker_purpose'));
      for(const worker of workers){const row=node('div',undefined,'bot-work-worker');row.append(link(worker.purpose||worker.id,'worker',worker.id),node('span',[worker.status,worker.occupancy,'Terminal: '+(worker.terminal||'not reported')].filter(Boolean).join(' · '),'availability-note'));
        if(watchable(worker)){const b=node('button','Watch terminal');b.type='button';b.dataset.watchWorker=worker.id;b.dataset.generation=String(worker.generation??1);b.dataset.world=world;row.append(b);}section.append(row);}
      assignments.append(section);
    }
    if(data.attempts.length){assignments.append(node('h3','Carrier attempts'));for(const a of data.attempts)assignments.append(node('p',[a.ticket_id,a.state,a.refused_as].filter(Boolean).join(' · '),'availability-note'));}
    assignments.append(node('p','Agent browser tabs and automatic delegation are not connected yet.','availability-note'));
  }
  work.onclick=e=>{const b=e.target.closest('[data-watch-worker]');if(!b)return;const w=botWork(heldProjection(current),botId).workers.find(w=>w.id===b.dataset.watchWorker);if(!watchable(w)||String(w.generation??1)!==b.dataset.generation||runtimeWorld(current)!==b.dataset.world){signature='';refresh(botId);return;}document.dispatchEvent(new CustomEvent('watch-runtime-worker',{detail:{id:w.id,generation:w.generation??1,world:b.dataset.world}}));};
  return {refresh,conversation:()=>select('conversation')};
}
