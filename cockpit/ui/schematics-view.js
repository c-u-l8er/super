import {currentTaskEditor} from './task-editor.js';
import {schematicLayout,adjacentNodes,clampZoom} from './schematics-layout.js';
import {node,navigate,screens,selectedScreen,selectedWorkspace} from './app-shell.js';
import {runtimeWorld,heldProjection} from './runtime-bots.js';
import {currentTaskSession} from './task-session.js';
import {focusChoice} from './work-focus.js';
import {schematic} from './schematics-model.js';
export function initSchematics({current}){
 const toggle=document.getElementById('toggle-schematics'),canvas=document.getElementById('workspace-canvas'),root=node('section',undefined,'schematics');root.id='schematics';root.hidden=true;root.setAttribute('aria-label','Live app schematics');canvas.append(root);
 const title=node('h1','Schematics'),intro=node('p','Follow your work through Super. Select a node to inspect it.','screen-description'),bar=node('nav',undefined,'schematic-levels'),note=node('p','','schematic-note'),board=node('div',undefined,'schematic-board'),inspector=node('aside',undefined,'schematic-inspector'),plan=node('details',undefined,'schematic-plan');
 bar.setAttribute('aria-label','Schematic level');inspector.setAttribute('aria-label','Selected component');inspector.setAttribute('aria-live','polite');
 plan.append(node('summary','Development plan · first connected path'),node('p','Now: layered node placement, routed connections, flow direction controls, distinct work-screen internals and zoom. Every screen has an overview. Next: remaining screen internals, event history, follow-active and deeper WRL execution.'),node('p','Saved plan: docs/plans/SCHEMATICS.md · linked from the repository README.'));
 const body=node('div',undefined,'schematic-body'),viewport=node('div',undefined,'schematic-viewport');viewport.setAttribute('aria-label','Wiring diagram');viewport.tabIndex=0;const extent=node('div',undefined,'schematic-extent');extent.append(board);viewport.append(extent);body.append(viewport,inspector);root.append(node('p','SUPER / SCHEMATICS','eyebrow'),title,intro,bar,note,body,plan);
 let active=false,level='screen',picked=null,model=null,signature='',scroll=0,zoom=1,layout=null,direction='DOWN',renderRevision=0,centerAfter=false;
 const zoomBar=node('div',undefined,'schematic-zoom'),zoomLabel=node('span','100%');zoomLabel.id='schematic-zoom-label';
 function scale(value){zoom=clampZoom(value);board.style.transform=`scale(${zoom})`;if(layout){extent.style.width=layout.width*zoom+'px';extent.style.height=layout.height*zoom+'px';}zoomLabel.textContent=Math.round(zoom*100)+'%';}
 for(const [id,label,action] of [['out','−',()=>scale(zoom-.1)],['in','+',()=>scale(zoom+.1)],['reset','100%',()=>scale(1)],['fit','Fit width',()=>scale((viewport.clientWidth-4)/(layout?.width||1))],['all','Fit diagram',()=>{scale(Math.floor(Math.min((viewport.clientWidth-4)/(layout?.width||1),(viewport.clientHeight-4)/(layout?.height||1))*10)/10);viewport.scrollTo(0,0);}]]){const b=node('button',label);b.type='button';b.dataset.schematicZoom=id;b.setAttribute('aria-label',id==='in'?'Zoom in':id==='out'?'Zoom out':label);b.onclick=action;zoomBar.append(b);}const clear=node('button','Clear trace');clear.type='button';clear.id='schematic-clear-trace';clear.onclick=()=>choose(null);zoomBar.append(zoomLabel,clear);for(const [value,label] of [['DOWN','Flow down'],['RIGHT','Flow right']]){const b=node('button',label);b.type='button';b.dataset.schematicDirection=value;b.onclick=()=>{direction=value;centerAfter=true;signature='';refresh();};zoomBar.append(b);}bar.after(zoomBar);
 for(const [id,label] of [['screen','This screen'],['connections','Connections'],['app','Whole app']]){const b=node('button',label);b.type='button';b.dataset.schematicLevel=id;b.onclick=()=>{level=id;picked=null;signature='';refresh();};bar.append(b);}
 function setActive(value){if(value===active)return;if(value)scroll=canvas.scrollTop;active=value;renderRevision++;if(active)signature='';root.hidden=!active;document.body.classList.toggle('schematics-active',active);toggle.setAttribute('aria-pressed',String(active));document.dispatchEvent(new Event('schematics-changed'));if(active){refresh();canvas.scrollTop=0;title.tabIndex=-1;title.focus({preventScroll:true});}else{canvas.scrollTop=scroll;toggle.focus({preventScroll:true});}}
 toggle.onclick=()=>setActive(!active);
 function choose(id,center=false){picked=id;inspect();if(center){const pt=layout?.points.get(id);if(pt)viewport.scrollTo({left:Math.max(0,(pt.x+98)*zoom-viewport.clientWidth/2),top:Math.max(0,(pt.y+52)*zoom-viewport.clientHeight/2)});}}
 function inspect(){inspector.replaceChildren();const item=model.nodes.find(n=>n.id===picked),near=adjacentNodes(picked,model.edges);for(const b of board.querySelectorAll('button')){b.setAttribute('aria-pressed',String(b.dataset.schematicNode===picked));b.classList.toggle('schematic-muted',!!item&&!near.has(b.dataset.schematicNode));}
 for(const wire of board.querySelectorAll('[data-wire-from]')){const on=!!item&&(wire.dataset.wireFrom===picked||wire.dataset.wireTo===picked);wire.classList.toggle('schematic-traced',on);wire.classList.toggle('schematic-muted',!!item&&!on);}if(!item){inspector.append(node('p','Select a component to see its state, purpose and next destination.'));return;}
  inspector.append(node('h2',item.label),node('p',item.state,'schematic-state'));
  if(item.detail?.length>300){const more=node('details');more.append(node('summary','Full description'),node('p',item.detail));inspector.append(more);}else inspector.append(node('p',item.detail));
  for(const e of model.edges.filter(e=>e.from===item.id||e.to===item.id)){const from=model.nodes.find(n=>n.id===e.from),to=model.nodes.find(n=>n.id===e.to);const other=e.from===item.id?to:from;const follow=node('button',`${e.from===item.id?'To':'From'} ${other?.label} · ${e.label}`,'schematic-follow');follow.type='button';follow.dataset.schematicFollow=other.id;follow.onclick=()=>choose(other.id,true);inspector.append(follow);}
  if(item.route&&!(item.route==='record'&&selectedScreen()!=='record')){const open=node('button','Open '+(screens.find(s=>s[0]===item.route)?.[1]||'conversation'),'primary');open.type='button';open.dataset.schematicOpen=item.id;open.onclick=()=>{setActive(false);if(item.taskId)document.dispatchEvent(new CustomEvent('continue-development-task',{detail:{taskId:item.taskId}}));else navigate(item.route,true);};inspector.append(open);}
 }
 async function refresh(){if(!active)return;const world=runtimeWorld(current),p=heldProjection(current);const next=schematic({screen:selectedScreen(),level,screens,p,world,chosen:focusChoice(localStorage,world),session:currentTaskSession(),editor:currentTaskEditor(),workspace:selectedWorkspace()});const key=JSON.stringify([world,next,direction]);if(key===signature)return;signature=key;model=next;
  title.textContent='Schematics · '+model.title;note.textContent=model.coverage+(p?'':' Runtime unavailable — reconnect to inspect current state.');
  for(const b of bar.children)b.setAttribute('aria-pressed',String(b.dataset.schematicLevel===level));
  const focusedNode=document.activeElement?.dataset.schematicNode;
  const ticket=++renderRevision;board.replaceChildren();inspector.replaceChildren(node('p','Arranging this diagram…'));note.setAttribute('aria-busy','true');
  let arranged;
  try{arranged=await schematicLayout(model.nodes,model.edges,3,{direction});}catch(error){if(ticket!==renderRevision||!active)return;signature='';note.removeAttribute('aria-busy');inspector.replaceChildren(node('p','The diagram could not be arranged. Select a view to retry.'));return;}
  if(ticket!==renderRevision||!active)return;
  note.removeAttribute('aria-busy');layout=arranged;
  for(const b of zoomBar.querySelectorAll('[data-schematic-direction]'))b.setAttribute('aria-pressed',String(b.dataset.schematicDirection===direction));
  board.style.width=layout.width+'px';board.style.height=layout.height+'px';
  const ns='http://www.w3.org/2000/svg',svg=document.createElementNS(ns,'svg');svg.setAttribute('aria-hidden','true');svg.setAttribute('width','100%');svg.setAttribute('height','100%');
  const defs=document.createElementNS(ns,'defs'),marker=document.createElementNS(ns,'marker');marker.id='schematic-arrow';marker.setAttribute('viewBox','0 0 10 10');marker.setAttribute('refX','8');marker.setAttribute('refY','5');marker.setAttribute('markerWidth','5');marker.setAttribute('markerHeight','5');marker.setAttribute('orient','auto-start-reverse');const arrow=document.createElementNS(ns,'path');arrow.setAttribute('d','M 0 0 L 10 5 L 0 10 z');arrow.style.fill='#8ec5f2';marker.append(arrow);defs.append(marker);svg.append(defs);board.append(svg);
  for(const edge of layout.paths){const path=document.createElementNS(ns,'path');path.dataset.wireFrom=edge.from;path.dataset.wireTo=edge.to;path.setAttribute('d',edge.path);path.setAttribute('marker-end','url(#schematic-arrow)');svg.append(path);for(const point of [edge.segments[0],edge.segments.at(-1)]){const port=document.createElementNS(ns,'circle');port.setAttribute('cx',point.x);port.setAttribute('cy',point.y);port.setAttribute('r','2');port.setAttribute('class','schematic-port');svg.append(port);}}
  for(const item of model.nodes){const pt=layout.points.get(item.id),b=node('button',undefined,'schematic-node');b.type='button';b.dataset.schematicNode=item.id;b.style.left=pt.x+'px';b.style.top=pt.y+'px';b.title=item.detail;b.setAttribute('aria-label',item.label+': '+item.state);b.append(node('strong',item.label),node('span',item.state));b.onclick=()=>choose(item.id);board.append(b);}
  scale(zoom);
  if(focusedNode)[...board.querySelectorAll('button')].find(b=>b.dataset.schematicNode===focusedNode)?.focus({preventScroll:true});
  inspect();if(centerAfter){centerAfter=false;if(picked)choose(picked,true);else viewport.scrollTo(0,0);}
 }
 document.addEventListener('page-selected',()=>{scroll=0;picked=null;signature='';refresh();});
 for(const event of ['runtime-view-rendered','task-editor-changed','task-session-changed','workspace-view-change','focus-development-task'])document.addEventListener(event,refresh);
 window.addEventListener('storage',refresh);window.addEventListener('resize',refresh);
 document.addEventListener('keydown',e=>{if(e.key==='Escape'&&active&&!document.querySelector('dialog[open]')){e.preventDefault();setActive(false);}});
}
