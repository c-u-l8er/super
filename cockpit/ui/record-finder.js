/* Palette record lookup for the desktop cockpit.
 *
 * The palette searched page titles only, so a person holding a record id —
 * dt_0052, da_0062, bt_0034, rp_0003 — had nowhere to type it, and the
 * Development tasks list is scoped to the selected workspace and shows titles
 * without ids. This module answers one question: which held records match what
 * was typed, ranked so an exact id beats a title fragment. It returns plain
 * data only. app-shell.js owns navigation, clearing the workspace filter and
 * every route it is handed here.
 *
 * Pure: no DOM, no imports, no module state, no clock, no randomness. A
 * malformed projection yields fewer results, never an exception. */
const str=v=>typeof v==='string'?v:'';
/* collection, kind, title field, extra status field, linked-id field.
 * This order is the result order inside a rank band. */
const COLLECTIONS=[
 ['development_tasks','Development plan','title','',''],
 ['development_attempts','Review attempt','plan_title','','task_ref'],
 ['workspaces','Workspace','name','',''],
 ['goals','Goal','title','',''],
 ['lanes','Lane','name','state',''],
 ['bots','Bot','name','',''],
 ['repositories','Repository','name','',''],
 ['workers','Worker','purpose','occupancy',''],
];
/* Exact id, id prefix, id substring; -1 when this text cannot match at all. */
const idBand=(value,q)=>{const v=value.toLowerCase();return !v?-1:v===q?0:v.startsWith(q)?1:v.includes(q)?2:-1;};
export function findRecords(projection,query,{limit=12}={}){
 const q=str(query).trim().toLowerCase(),max=Number.isFinite(limit)?Math.floor(limit):0;
 if(!q||max<=0||!projection||typeof projection!=='object')return [];
 const bands=[[],[],[],[]],seen=new Set();
 for(const [collection,kind,titleKey,statusKey,linkKey] of COLLECTIONS){
  const held=projection[collection];
  if(!held||typeof held!=='object')continue;
  for(const record of Object.values(held)){
   if(!record||typeof record!=='object')continue;
   const id=str(record.id)||str(record.ref);
   if(!id||seen.has(kind+'\n'+id))continue;
   const title=str(record[titleKey]),linked=linkKey?str(record[linkKey]):'';
   let band=idBand(id,q);
   /* An attempt is reachable by the plan id it belongs to, so typing a plan
    * id lists the plan and its attempts together. */
   if(linked){const b=idBand(linked,q);if(b>=0&&(band<0||b<band))band=b;}
   if(band<0&&title.toLowerCase().includes(q))band=3;
   if(band<0)continue;
   seen.add(kind+'\n'+id);
   bands[band].push({kind,id,title:title||id,
    status:str(record.status)||(statusKey?str(record[statusKey]):'')||null,
    route:kind==='Development plan'?{task:id}:kind==='Review attempt'?{task:linked||null,attempt:id}:{record:id}});
  }
 }
 return [].concat(...bands).slice(0,max);
}
