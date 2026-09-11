let session=null;
export function publishTaskSession(value){session=value;document.dispatchEvent(new Event('task-session-changed'));}
export function taskSessionView(p,task,world,value=session){
  const bot=p?.bots?.[task?.bot_ref];
  if(!p||!task||!bot||!world)return {label:'Session unavailable',detail:'Reconnect to inspect the assigned bot.',available:false};
  if(!value||value.botId!==bot.client_ref||value.world!==world)return {label:'Connection not checked in this view',detail:'Open the assigned bot’s conversation to inspect its current connection. Live reply state is not restored after reload.',available:true};
  const linked=value.tasks?.some(t=>t.id===task.id&&t.revision===task.revision&&t.world===world);
  return {available:true,label:linked&&value.reply?value.reply:value.ready?'Provider connected':'Provider needs connection',detail:linked&&value.reply?value.message:'Current bot session · connection status applies to the bot. This does not establish that this task is running.'};
}
