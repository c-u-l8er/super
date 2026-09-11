import {reviewTestCoverage} from './review-test-coverage.js';

// Guidance from retained runtime records only. It never authorizes an operation.
export function taskProgress(p,task){
  const result=(state,label,reason,target,attempt)=>({state,label,reason,target,attempt:attempt?.id});
  if(!p||!task)return result('unavailable','Reconnect to view task','Current task state is unavailable.');
  if(task.status==='completed')return result('completed','Plan completed','Accepted results and completion history are retained.');
  if(task.status==='cancelled')return result('cancelled','Plan cancelled','Previous reviews remain available as history.');
  const all=Object.values(p.development_attempts??{}).filter(a=>a.task_ref===task.id);
  const current=all.filter(a=>a.task_revision===task.revision);
  const running=all.find(a=>Object.values(a.test_runs??{}).some(r=>r.state==='started'));
  if(running)return result('waiting','Check unfinished test run','A runtime start is awaiting its final outcome. Open the review for progress or recovery.','review',running);
  if(task.status==='blocked')return result('blocked','Review plan blocker',task.history?.at(-1)?.note||'Resolve the recorded blocker and update the plan.','planning');
  const open=current.filter(a=>!['accepted','dismissed'].includes(a.status));
  const changes=open.find(a=>a.status==='needs_changes');
  if(changes)return result('needs_changes','Review requested changes','Read the review notes before preparing a revised file request.','review',changes);
  for(const a of open){
    const coverage=reviewTestCoverage(a.test_runs,task.required_checks?.profiles??[]);
    if(!coverage.rows.length||coverage.rows.some(r=>r.status==='missing'))return result('checks_missing','Review proposal and run checks','Review the retained proposal, choose this plan’s repository in Editor, then run the appropriate test profile. Complete every required plan check.','review',a);
    if(!coverage.ready)return result('checks_attention','Resolve test results','A used profile is failed, incomplete, or tested a different snapshot. Open the review to inspect and rerun it.','review',a);
  }
  if(open.length)return result('decision','Review saved files and decide','Used test profiles agree. Save the exact proposal in Editor, then use the review’s file check and acceptance control.','review',open[0]);
  if(current.some(a=>a.status==='accepted'&&a.acceptance?.schema==='development-acceptance@1'&&a.acceptance.task_revision===task.revision))return result('finish','Review plan completion','A result for this plan revision is accepted. Confirm the criteria are met and record a completion reason. Integration and rebuilding remain separate.','completion');
  return result('prepare','Prepare file request',all.length?'No open review or accepted result covers this plan revision. Prepare a fresh request using the current criteria.':'Choose a source file in Editor and share it with the assigned bot.','prepare');
}

export function taskProgressRows(p,workspace='',botRef=''){
  return Object.values(p?.development_tasks??{}).filter(t=>(!workspace||t.workspace_ref===workspace)&&(!botRef||t.bot_ref===botRef)&&!['completed','cancelled'].includes(t.status)).map(task=>({task,progress:taskProgress(p,task)}));
}
