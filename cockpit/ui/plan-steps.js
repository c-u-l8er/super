/* The plan's path as steps, and a drafted completion reason.
 *
 * The detail page held every control for a plan at once — prepare, review,
 * test, accept, finish, planning note — with "Finish this plan" last, so a
 * person could not tell where they were or what to look at. taskProgress()
 * already decides the ONE next action; this turns that decision into an
 * ordered stepper (done · current · to do · blocked) and, when the plan is
 * finishable, drafts the completion reason from the accepted result so the
 * person approves or edits a sentence instead of composing one.
 *
 * Pure: no DOM, no state. development-tasks.js owns rendering and routing. */
import {taskProgress} from './task-progress.js';

export const STEPS=[
 ['prepare','Prepare file'],
 ['review','Review proposal'],
 ['checks','Run checks'],
 ['accept','Accept result'],
 ['finish','Finish plan'],
];
/* progress.state → index of the current step, and whether it is blocked there. */
const CURRENT={prepare:[0,false],needs_changes:[1,false],checks_missing:[2,false],checks_attention:[2,true],waiting:[2,true],decision:[3,false],finish:[4,false],blocked:[0,true],unavailable:[0,true]};

export function planSteps(p,task){
  const progress=taskProgress(p,task);
  const done=progress.state==='completed';
  const [at,blocked]=done||progress.state==='cancelled'?[STEPS.length,false]:(CURRENT[progress.state]??[0,true]);
  const steps=STEPS.map(([key,label],i)=>({key,label,state:i<at?'done':i===at?(blocked?'blocked':'current'):'todo'}));
  return {steps,current:at<STEPS.length?steps[at].key:null,progress,finishable:progress.state==='finish',cancelled:progress.state==='cancelled',completed:done};
}

const short=s=>typeof s==='string'&&s.length>=12?s.slice(0,12):'';
/* One sentence, at most `limit` characters, built only from the accepted result. */
export function completionReason(p,task,{limit=250}={}){
  if(!p||!task)return '';
  const accepted=Object.values(p.development_attempts??{}).filter(a=>a.task_ref===task.id&&a.task_revision===task.revision&&a.status==='accepted'&&a.acceptance?.schema==='development-acceptance@1').sort((a,b)=>String(a.id).localeCompare(String(b.id)));
  if(!accepted.length)return '';
  const parts=accepted.map(a=>{
    const run=Object.values(a.test_runs??{}).find(r=>r.run_id===a.acceptance.run_id);
    const tests=Number.isInteger(run?.outcome?.test_count)?`${run.outcome.test_count} tests passed`:'tests passed';
    const snap=short(a.acceptance.snapshot_sha256||run?.outcome?.snapshot_sha256);
    const file=typeof a.source?.path==='string'?a.source.path:null;
    return `${a.id}${file?` (${file})`:''}: ${tests}${snap?` on snapshot ${snap}`:''}`;
  });
  const others=Object.values(p.development_attempts??{}).filter(a=>a.task_ref===task.id).length;
  let text=`Accepted at revision ${task.revision} — ${parts.join('; ')}. ${others} review attempt${others===1?'':'s'} recorded. Criteria met.`;
  if(text.length>limit){
    text=`Accepted at revision ${task.revision} — ${accepted.map(a=>a.id).join(', ')}: tests passed. ${others} review attempt${others===1?'':'s'} recorded. Criteria met.`;
    if(text.length>limit)text=text.slice(0,limit-1)+'…';
  }
  return text;
}
