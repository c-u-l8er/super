// Required plan profiles and all profiles actually run must agree.
export function reviewTestCoverage(saved,required=[]){
  const runs=Object.values(saved??{}).sort((a,b)=>a.started_at.localeCompare(b.started_at)||a.run_id.localeCompare(b.run_id)),latest=runs.at(-1),profiles=new Map();
  for(const run of runs)profiles.set(run.profile??'super-javascript-behavior@1',run);
  const snapshot=latest?.outcome?.snapshot_sha256;
  const rows=[...profiles].sort(([a],[b])=>a.localeCompare(b)).map(([profile,run])=>({profile,run_id:run.run_id,status:run.state==='started'?'running':run.state!=='completed'?'incomplete':run.outcome?.verdict!=='pass'?'failed':!snapshot||run.outcome.snapshot_sha256!==snapshot?'different-snapshot':'passed'}));
  for(const profile of required)if(!profiles.has(profile))rows.push({profile,status:'missing'});
  return {rows,ready:rows.length>0&&rows.every(r=>r.status==='passed')&&!runs.some(r=>r.state==='started')};
}
