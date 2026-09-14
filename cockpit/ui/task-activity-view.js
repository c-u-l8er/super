import {node} from './app-shell.js';
import {taskActivityFor} from './task-activity.js';
export function initTaskActivity({root,context,open}){
 const panel=node('details',undefined,'task-activity'),summary=node('summary','Task activity'),body=node('div',undefined,'task-activity-body'),state=node('p'),meta=node('p',undefined,'task-activity-meta'),output=node('pre',undefined,'task-activity-output'),history=node('details'),events=node('ol'),action=node('button','Open conversation');
 panel.dataset.taskActivity='';state.setAttribute('role','status');output.setAttribute('aria-label','Observed assistant text');history.append(node('summary','Request events'),events);action.type='button';action.onclick=()=>{const c=context();if(c.task&&c.p?.bots?.[c.task.bot_ref])open(c.p.bots[c.task.bot_ref].client_ref);};
 const follow=node('input');follow.type='checkbox';follow.checked=true;const followLabel=node('label',undefined,'task-activity-follow');followLabel.append(follow,document.createTextNode(' Follow new text'));
 body.append(state,meta,output,followLabel,history,action);panel.append(summary,body);root.append(panel);
 let signature='',lastId=null;
 function refresh(){const c=context(),value=taskActivityFor(c.p,c.task,c.world),key=JSON.stringify([c.task?.id,value,!!c.p]);if(key===signature)return;signature=key;
  const nearEnd=output.scrollHeight-output.scrollTop-output.clientHeight<30;
  summary.textContent='Task activity · '+(value?.phase||'No request observed');panel.dataset.phase=value?.status||'none';
  state.textContent=value?value.status==='running'?'This request is in progress. Open the conversation to cancel.':value.status==='complete'?'Read the reply and review its proposals. Nothing is applied automatically.':'Open the conversation to inspect the error and restored draft. Nothing is resent automatically.':c.task?'Send this task’s file request from its assigned conversation. Live activity starts when a request is sent; older replies remain in conversation history.':'Choose a task to inspect its activity.';
  meta.textContent=value?[value.provider,value.model,`Last update ${new Date(value.updated).toLocaleTimeString()}`,value.bytes?`${value.bytes.toLocaleString()} bytes of assistant text`:''].filter(Boolean).join(' · '):'';
  output.textContent=value?.text||'';output.hidden=!value?.text;followLabel.hidden=output.hidden;
  events.replaceChildren();for(const e of value?.events??[])events.append(node('li',`${new Date(e.at).toLocaleTimeString()} · ${e.label}`));history.hidden=!value;action.hidden=!c.task||!c.p?.bots?.[c.task.bot_ref];
  if(value?.id!==lastId){lastId=value?.id??null;if(value?.status==='running')panel.open=true;}
  if(follow.checked&&(nearEnd||value?.status==='running'))output.scrollTop=output.scrollHeight;
 }
 for(const name of ['task-activity-changed','runtime-view-rendered','focus-development-task','page-selected','workspace-view-change'])document.addEventListener(name,refresh);
 refresh();return {refresh,panel};
}
