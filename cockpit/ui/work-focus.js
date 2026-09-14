import {replyRecovery} from './task-activity.js';
import {taskProgress} from './task-progress.js';
export const FOCUS_KEY='super-work-focus-v1';
// A chosen task survives a runtime restart; live session checks still use the full epoch.
export function focusWorld(world){try{const value=JSON.parse(world);return Array.isArray(value)?JSON.stringify(value.slice(0,2)):world;}catch{return world;}}
export function focusChoice(storage,world){
  try{const value=JSON.parse(storage.getItem(FOCUS_KEY)||'null');return value?.version===1&&focusWorld(value.world)===focusWorld(world)&&typeof value.taskId==='string'?value.taskId:null;}catch{return null;}
}
export function saveFocus(storage,world,taskId){storage.setItem(FOCUS_KEY,JSON.stringify({version:1,world:focusWorld(world),taskId}));}
export function workFocus(p,world,chosen,session){
  if(!p||!world)return {state:'unavailable',title:'Reconnect to your work',detail:'Waiting for the runtime. Saved progress will return when it reconnects.',queue:[]};
  const tasks=Object.values(p.development_tasks??{}),queue=tasks.filter(t=>!['completed','cancelled'].includes(t.status)).sort((a,b)=>a.id.localeCompare(b.id));
  const task=queue.find(t=>t.id===chosen)||queue[0];
  if(!task)return {state:'empty',title:tasks.length?'All plans are finished':'Choose your first task',detail:tasks.length?'Create the next plan when you are ready.':'Create one small plan with a clear result.',queue};
  const progress=taskProgress(p,task),bot=p.bots?.[task.bot_ref];
  const linked=session?.botId===bot?.client_ref&&session?.world===world&&session?.tasks?.some(t=>t.id===task.id&&t.revision===task.revision&&t.world===world);
  let step=1,label='Prepare source files',detail=progress.reason,target=progress.target;
  if(linked&&session.reply==='Waiting for reply'){step=2;label='Bot is working';detail='Watch its progress. You can open the conversation to cancel.';target='conversation';}
  else if(progress.state==='prepare'&&linked&&session.reply==='Reply did not complete'){step=2;({label,detail}=replyRecovery(session.recovery));target='conversation';}
  else if(progress.state==='prepare'&&linked&&session.prepared){step=2;label='Send the file request';detail='Your source files are attached. Review the message and send it to the bot.';target='conversation';}
  else if(progress.state==='prepare'&&linked&&session.reply==='Reply received'){step=3;label='Review the bot’s reply';detail='Open the reply and review its proposed changes before applying them.';target='conversation';}
  else if(['checks_missing','checks_attention','waiting'].includes(progress.state)){step=4;label=progress.label;}
  else if(['decision','needs_changes'].includes(progress.state)){step=3;label=progress.label;}
  else if(progress.state==='finish'){step=5;label='Confirm this task is finished';}
  else if(progress.state==='blocked'){step=1;label='Resolve this task’s blocker';}
  return {state:progress.state,task,bot,queue,step,label,detail,target,attempt:progress.attempt,waiting:linked&&session.reply==='Waiting for reply'};
}
