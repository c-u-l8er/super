// A receipt identifies the destination; only a later authoritative frame can open it.
const kinds={open_workspace:['workspace','workspaces','position-workspace'],open_goal:['goal','goals','goal'],open_lane:['lane','lanes','lane'],open_worker:['worker','workers','worker']};
export function creationDestination(name,result,origin){
  const kind=kinds[name],id=kind&&result?.[kind[0]]?.id;
  return result?.allow===true&&typeof id==='string'?{...origin,id,collection:kind[1],key:`${kind[2]}:${id}`}:null;
}
export function confirmedDestination(pending,frame,world,route){
  if(!pending||pending.world!==world||pending.route!==route)return {pending:null};
  if(!frame?.projection||frame.seq<=pending.seq)return {pending};
  return frame.projection[pending.collection]?.[pending.id]?{pending:null,key:pending.key}:{pending};
}
