import {internalSchematic} from './schematics-internals.js';
import {workFocus} from './work-focus.js';
import {taskSessionView} from './task-session.js';
import {reviewTestCoverage} from './review-test-coverage.js';
export const connections=[
 ['positions','goals','contains goals'],['goals','lanes','assigns work'],['lanes','repositories','uses source'],['lanes','development-tasks','organizes plans'],
 ['continue-work','development-tasks','focuses a plan'],['development-tasks','bots','assigns a bot'],['development-tasks','editor','shares source'],['bots','editor','proposes changes'],
 ['development-tasks','evidence','retains outcomes'],['editor','terminal','local commands'],['editor','browser','preview'],['runtime','runtime-assignments','reports assignments'],
 ['runtime-assignments','lanes','binds lanes'],['runtime','agents','reports peers'],['runtime','capabilities','reports grants'],['capabilities','authority','authority records'],
 ['mission','continue-work','next task'],['mission','evidence','inspect outcomes'],['repositories','editor','opens files'],['settings','mobile','device connection'],['mobile','runtime','observes runtime'],
 ['new-workspace','positions','creates workspace'],['manage-work','goals','creates goals'],['manage-work','lanes','assigns lanes'],['new-bot','bots','creates profile'],['edit-bot','bots','edits profile']
];
const collections={positions:'workspaces',goals:'goals',lanes:'lanes',repositories:'repositories',bots:'bots',agents:'agents','development-tasks':'development_tasks','runtime-assignments':'workers'};
const detailed=new Set(['continue-work','development-tasks','editor','bots']);
const unavailable=new Set(['fleet','gates','rulings','routines']);
export const screenKind=id=>id.startsWith('bot:')?'bots':id;
export function schematic({screen,level='screen',screens,p,world,chosen,session,editor,workspace=''}){
 const kind=screenKind(screen),catalog=[...screens.map(([id,label,description])=>({id,label,description})),{id:'record',label:'Record details',description:'Inspect the selected record and its references.'}];
 const entry=catalog.find(s=>s.id===kind)??{id:kind,label:'Current screen',description:'Internal wiring is not mapped yet.'};
 const pageNode=s=>({id:s.id,label:s.label,state:!p?'Unavailable':unavailable.has(s.id)?'Not connected':collections[s.id]?`${Object.values(p[collections[s.id]]??{}).length} records`:'Screen',detail:s.description+' '+(detailed.has(s.id)?'Core work path available.':'Detailed internal wiring is planned.'),route:s.id});
 if(level!=='screen'){
  const links=connections.filter(([a,b])=>level==='app'||a===kind||b===kind),ids=new Set([kind,...links.flatMap(([a,b])=>[a,b])]);
  return {title:level==='app'?'Whole app':'Connections · '+entry.label,coverage:'Screen relationships · these links describe app structure, not observed execution.',nodes:catalog.filter(s=>level==='app'||ids.has(s.id)).map(pageNode),edges:links.map(([from,to,label])=>({from,to,label}))};
 }
 if(!detailed.has(kind))return {title:entry.label,coverage:'Screen overview · detailed internal wiring is planned.',nodes:[{id:'input',label:'Screen context',state:p?'Available':'Unavailable',detail:'The selected workspace and page determine what this screen displays.'},pageNode(entry),{id:'output',label:'Connected screens',state:'Explore connections',detail:'Use Connections to follow this screen into other areas. Links describe structure; event tracing is planned.'}],edges:[{from:'input',to:entry.id,label:'provides context'},{from:entry.id,to:'output',label:'follow connections'}]};
 const scoped=p?{...p,development_tasks:Object.fromEntries(Object.entries(p.development_tasks??{}).filter(([,t])=>(!workspace||t.workspace_ref===workspace)&&(!screen.startsWith('bot:')||p.bots?.[t.bot_ref]?.client_ref===screen.slice(4))))}:null;
 const editorTask=kind==='editor'&&editor?.task?.world===world&&scoped?.development_tasks?.[editor.task.id]?.revision===editor.task.revision?editor.task.id:null;
 const focus=workFocus(scoped,world,editorTask||chosen,session),task=focus.task,bot=task?p?.bots?.[task.bot_ref]:null;
 const all=task?Object.values(p.development_attempts??{}).filter(a=>a.task_ref===task.id&&a.task_revision===task.revision):[];
 const attempt=all.find(a=>a.id===focus.attempt)||all.at(-1),coverage=reviewTestCoverage(attempt?.test_runs,task?.required_checks?.profiles??[]);
 const sv=taskSessionView(p,task,world,session),live=!!task&&session?.world===world&&session.botId===bot?.client_ref&&session.tasks?.some(t=>t.id===task.id&&t.revision===task.revision&&t.world===world);
 const state=(value)=>!p?'Unavailable':!task?'No selected task':value;
 const nodes=[
 {id:'task',label:task?.title||'Development task',state:state(task?.status),detail:task?.criteria||'Choose or create a task in Continue work.',route:'continue-work'},
 {id:'provider',label:'Provider connection',state:state(sv.label),detail:sv.detail,route:bot?'bot:'+bot.client_ref:'bots'},
 {id:'bot',label:bot?.name||'Assigned bot',state:state(live?session.reply||'No active reply':'No observed task session'),detail:live?session.message||'Current session for this exact task and plan revision.':'Open the assigned conversation to inspect its live output.',route:bot?'bot:'+bot.client_ref:'bots'},
 {id:'source',label:'Source files · Editor',state:state('Inspect in Editor'),detail:'Open files, drafts and disk contents are distinct. Open Editor to inspect or save the source.',route:'editor'},
 {id:'proposal',label:'Review proposal',state:state(attempt?.status||'Not recorded'),detail:attempt?`${all.length} review(s) for this plan revision. Open the plan to inspect retained text.`:'No retained review for this plan revision.',route:'development-tasks',taskId:task?.id},
 {id:'checks',label:'Checks',state:state(!attempt?'Awaiting proposal':!Object.keys(attempt.test_runs??{}).length?'Not run':coverage.ready?'Passed on one snapshot':coverage.rows.some(r=>r.status==='running')?'Running':coverage.rows.length?'Needs attention':'Not run'),detail:coverage.rows.map(r=>`${r.profile}: ${r.status}`).join('\n')||'No test result recorded. Checks run on a captured proposal.',route:'development-tasks',taskId:task?.id},
 {id:'decision',label:'Your next step',state:state(focus.label),detail:focus.detail||'Choose a plan to continue.',route:'continue-work'}];
 const internal=internalSchematic(kind,{nodes,task,p,world,editor,session,live});if(internal)return {title:entry.label,taskId:task?.id,...internal,nodes:internal.nodes.map(n=>p?n:{...n,state:'Unavailable'})};
 return {title:entry.label,taskId:task?.id,coverage:task?'Core task path · saved runtime state and matching session observations.':'Core task path · choose an unfinished task to populate it.',nodes,edges:[['task','bot','assignment'],['provider','bot','connection'],['source','bot','source request'],['bot','proposal','proposed changes'],['proposal','checks','test snapshot'],['checks','decision','result'],['decision','source','review and save']].map(([from,to,label])=>({from,to,label}))};
}
