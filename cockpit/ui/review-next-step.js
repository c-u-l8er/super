import {reviewTestCoverage} from './review-test-coverage.js';
export function reviewNextStep(task,attempt,{reviewed=false,openedEditor=false}={}){
  if(!task||!attempt)return {kind:'unavailable',label:'Reconnect to continue',detail:'Current review state is unavailable.'};
  if(['completed','cancelled'].includes(task.status)||['accepted','dismissed'].includes(attempt.status))return {kind:'done',label:'Review retained',detail:'This review is saved as history.'};
  if(task.status==='blocked'||attempt.status==='needs_changes')return {kind:'blocked',label:'Read the review notes',detail:'Resolve the recorded blocker or requested changes before continuing.'};
  const coverage=reviewTestCoverage(attempt.test_runs,task.required_checks?.profiles??[]);
  if(Object.values(attempt.test_runs??{}).some(r=>r.state==='started'))return {kind:'running',label:'Watch checks',detail:'Wait for the recorded outcome. Do not apply files while checks are running.'};
  if(!reviewed)return {kind:'review',label:'Review proposed files',detail:'Inspect the saved replacements before running checks or applying files.'};
  if(!coverage.ready){const next=coverage.rows.find(r=>r.status!=='passed');return {kind:'test',profile:next?.profile??'super-javascript-behavior@1',label:next&&next.status!=='missing'?'Resolve checks and rerun':'Run the next check',detail:'Tests use a separate copy of the proposal. Keep the source files unchanged until every required check passes.'};}
  if(!openedEditor)return {kind:'apply',label:'Apply the tested files in Editor',detail:'All required checks passed on the same snapshot. Review and save those exact files in Editor, then return here.'};
  return {kind:'accept',label:'Check saved files and accept',detail:'Explain why the result meets the criteria. Super will verify the saved files against the passing snapshot before accepting.'};
}
