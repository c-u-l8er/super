// Session-only observations. No provider credentials, runtime mutations or timers.
export const ACTIVITY_TEXT_LIMIT=8000;
export const ACTIVITY_EVENT_LIMIT=8;
// Only known categories cross into task guidance; raw provider errors stay in the conversation.
export function replyFailure(error){
 const message=String(error??'');
 if(/sign-in has expired|not authenticated|unauthorized|HTTP 401/i.test(message))return 'sign_in';
 if(/usage limit has been reached|reached your .*limit|rate.?limit|HTTP 429/i.test(message))return 'capacity';
 if(/reply cancelled|request cancelled|request canceled/i.test(message))return 'cancelled';
 if(/timed out|timeout/i.test(message))return 'timeout';
 if(/HTTP 50[234]|connection refused|connection reset|failed to connect|error sending request/i.test(message))return 'connection';
 return 'unknown';
}
export function replyRecovery(kind){
 const rows={
  sign_in:['Sign-in required','Reconnect the assigned bot','Open the conversation and connect the provider again.'],
  capacity:['Provider capacity reached','Review model availability','Wait for capacity to reset or choose another available model in the conversation.'],
  cancelled:['Reply cancelled','Review the cancelled draft','Open the conversation to revise or send the draft when you are ready.'],
  timeout:['Reply timed out','Review the timed-out request','Open the conversation and check provider availability before sending again.'],
  connection:['Provider unavailable','Check the provider connection','Open the conversation and check that the provider is reachable before sending again.'],
  unknown:['Reply stopped','Inspect the stopped request','Open the conversation to inspect the error and restored draft.']
 };
 const [phase,label,detail]=Object.hasOwn(rows,kind)?rows[kind]:rows.unknown;
 return {phase,label,detail:detail+' Nothing is resent automatically.'};
}
const requests=new Map();
const changed=()=>document.dispatchEvent(new Event('task-activity-changed'));
const text=value=>typeof value==='string'?value:'';
function event(state,label,at){if(state.events.at(-1)?.label!==label)state.events=[...state.events,{label,at}].slice(-ACTIVITY_EVENT_LIMIT);}
export function activityStart(value,at=Date.now()){
 return {id:value.id,botId:value.botId,world:value.world,tasks:(value.tasks??[]).map(t=>({...t})),provider:text(value.provider),model:text(value.model),status:'running',phase:'Waiting for provider',text:'',bytes:0,started:at,updated:at,events:[{label:'Request sent',at}]};
}
export function activityUpdate(previous,update,at=Date.now()){
 if(!previous||previous.status!=='running'||update.id!==previous.id)return previous;
 const next={...previous,events:[...previous.events]},bytes=Number.isFinite(update.received_bytes)?Math.max(previous.bytes,update.received_bytes):previous.bytes;
 if(update.type==='finish'){
  next.status=update.error?'stopped':'complete';next.recovery=update.error?replyFailure(update.failure??(previous.phase==='Cancelling reply'?'Reply cancelled':'')):null;next.phase=update.error?replyRecovery(next.recovery).phase:'Reply complete';
  if(typeof update.text==='string')next.text=update.text.slice(-ACTIVITY_TEXT_LIMIT);
  event(next,next.phase,at);
 }else{
  if(update.cancelled){next.phase='Cancelling reply';event(next,next.phase,at);}
  else if(bytes>previous.bytes||text(update.text)!==''&&text(update.text).slice(-ACTIVITY_TEXT_LIMIT)!==previous.text){next.phase='Receiving reply';if(!previous.text&&!previous.bytes)event(next,'Assistant text received',at);}
  else if(update.active&&next.phase==='Waiting for provider'){next.phase='Provider working';event(next,'Provider started',at);}
  next.bytes=bytes;if(typeof update.text==='string'&&update.text)next.text=update.text.slice(-ACTIVITY_TEXT_LIMIT);
 }
 if(next.phase===previous.phase&&next.bytes===previous.bytes&&next.text===previous.text&&next.status===previous.status)return previous;
 next.updated=at;return next;
}
export function beginTaskActivity(value){if(!value.id||requests.has(value.id))return;requests.set(value.id,activityStart(value));while(requests.size>8)requests.delete(requests.keys().next().value);changed();}
export function observeTaskActivity(id,value){const before=requests.get(id),next=activityUpdate(before,{...value,id});if(next&&next!==before){requests.set(id,next);changed();}}
export function taskActivityFor(p,task,world,values=[...requests.values()]){
 if(!p||!task||!world||['completed','cancelled'].includes(task.status))return null;
 const bot=p.bots?.[task.bot_ref];if(!bot)return null;
 return [...values].reverse().find(v=>v.world===world&&v.botId===bot.client_ref&&v.tasks.some(t=>t.id===task.id&&t.revision===task.revision&&t.world===world))??null;
}
