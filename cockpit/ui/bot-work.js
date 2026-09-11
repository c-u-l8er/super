// Relationships come only from the currently held runtime projection.
export function botWork(projection, clientId) {
  const bot=Object.values(projection?.bots??{}).find(b=>b.client_ref===clientId);
  if(!projection||!bot)return {state:projection?'unregistered':'unavailable',bot:null,lanes:[],workers:[],attempts:[]};
  const lanes=Object.values(projection.lanes??{}).filter(l=>l.actor===bot.actor&&projection.goals?.[l.goal_ref]?.workspace_ref===bot.workspace_ref);
  const laneIds=new Set(lanes.map(l=>l.id));
  const workers=Object.values(projection.workers??{}).filter(w=>laneIds.has(w.locus_ref));
  const attempts=Object.values(projection.carrier_attempts??{}).filter(a=>laneIds.has(a.locus_ref));
  return {state:'registered',bot,lanes,workers,attempts};
}
export function watchable(worker){return worker?.status==='open'&&worker.terminal==='PRESENT';}
