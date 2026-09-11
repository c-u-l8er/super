let context=null,signature='';
export function publishTaskEditor(value){const next=JSON.stringify(value);if(next===signature)return;signature=next;context=value;document.dispatchEvent(new Event('task-editor-changed'));}
export function taskEditorView(p,task,world,value=context){
  const empty=(state,message)=>({state,message,files:[]});
  if(!p||!task||!world)return empty('unavailable','Reconnect to inspect current Editor context.');
  if(!value?.task||value.task.id!==task.id||value.task.world!==world)return empty('unlinked','No current Editor session is linked to this plan. Use Prepare file request to connect one.');
  if(value.task.revision!==task.revision||['cancelled','completed'].includes(task.status))return empty('stale','This Editor context belongs to an earlier or closed plan. Prepare a fresh file request before continuing.');
  return {state:'linked',message:'Open tabs in this Editor session. Repository matching is checked separately when sharing. Draft status does not certify current disk contents, tests or acceptance.',root:value.root,files:value.files,session:value.session,generation:value.generation,task:value.task,busy:value.busy};
}
export function canOpenTaskEditor(p,task,world,current,request){const view=taskEditorView(p,task,world,current);return view.state==='linked'&&!view.busy&&request.session===view.session&&request.generation===view.generation&&request.task?.id===view.task.id&&request.task?.revision===view.task.revision&&request.task?.world===world&&view.files.some(f=>f.path===request.path);}
