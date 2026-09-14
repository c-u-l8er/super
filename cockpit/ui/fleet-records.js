// Observation-only records. VM identity is scoped to its host, never its display name.
export const machineKey=id=>'machine:'+encodeURIComponent(id);
export const vmKey=(host,id)=>'vm:'+encodeURIComponent(host)+':'+encodeURIComponent(id);
export function fleetRecords(fleet){
 if(fleet?.status!=='configured')return [];
 return (fleet.hosts??[]).flatMap(h=>{
  const i=h.inventory,observed=h.status==='observed';
  const machine={id:machineKey(h.id),name:h.label,status:h.status,host_id:h.id,hostname:i?.hostname??'Unavailable',operating_system:i?`${i.os} ${i.release}`:'Unavailable',hypervisor:i?.hypervisor??'Unavailable',logical_cpus:i?.logicalCpus??'Unavailable',memory:i?`${(i.memoryBytes/2**30).toFixed(1)} GiB`:'Unavailable',architecture:i?.arch??'Unavailable',last_observation:new Date(h.observedAt).toLocaleString(),observation_note:observed?'Recently observed; this is not a continuous health check.':'Current state is unavailable. Any retained capacity is from the last observation.',connection_detail:h.reason||'No connection error reported',next_step:h.nextStep,tools:i?.tools??{},check_readiness:'Inventory does not grant execution. Use the configured task check workflow.'};
  return [{key:machine.id,record:machine},...(i?.guests??[]).map(g=>({key:vmKey(h.id,g.id),record:{id:vmKey(h.id,g.id),name:g.label,machine_id:machine.id,host_name:h.label,guest_id:g.id,status:observed?g.status:'unknown',last_observation:machine.last_observation,state_explanation:!observed?'Host observation is unavailable; guest state is unknown.':g.status==='present'?'The hypervisor reports this guest as present. Running state has not been verified.':'State reported by the host observer.',resources:'Guest CPU, memory and disk measurements are not supplied by this observer.',check_readiness:machine.check_readiness,next_step:h.nextStep}}))];
 });
}
