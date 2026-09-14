import {initTaskActivity} from './task-activity-view.js';
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
 plan.append(node('summary','Development plan · first connected path'),node('p','Now: a full-canvas workspace with floating panels, drag-to-pan, layered node placement, routed connections, flow direction controls, distinct work-screen internals and zoom. Every screen has an overview. Next: remaining screen internals, event history, follow-active and deeper WRL execution.'),node('p','Saved plan: docs/plans/SCHEMATICS.md · linked from the repository README.'));
 const heading=node('section',undefined,'schematic-heading'),about=node('details',undefined,'schematic-about');about.append(node('summary','About this diagram'),intro,note,plan);heading.append(title,bar,about);
 const body=node('div',undefined,'schematic-body'),viewport=node('div',undefined,'schematic-viewport');viewport.setAttribute('aria-label','Wiring diagram');viewport.tabIndex=0;const extent=node('div',undefined,'schematic-extent');extent.append(board);viewport.append(extent);body.append(viewport,inspector);root.append(body,heading);
 let active=false,level='screen',picked=null,model=null,signature='',scroll=0,zoom=1,layout=null,direction='DOWN',renderRevision=0,centerAfter=false,inspectorOpen=false;
 const activity=initTaskActivity({root,context:()=>{const p=heldProjection(current);return {p,world:runtimeWorld(current),task:p?.development_tasks?.[model?.taskId]};},open:id=>{setActive(false);navigate('bot:'+id,true);document.dispatchEvent(new CustomEvent('open-task-conversation',{detail:{botId:id}}));}});
 activity.panel.classList.add('schematic-task-activity');activity.panel.addEventListener('toggle',()=>{if(model&&layout)inspect();});
 const zoomBar=node('div',undefined,'schematic-zoom'),zoomLabel=node('span','100%');zoomLabel.id='schematic-zoom-label';
 // Floating panels never shrink the viewport. Reserve their footprints only when
 // placing/fitting the graph, so the surrounding canvas remains pannable.
 function usable(){const v=viewport.getBoundingClientRect(),h=heading.getBoundingClientRect(),z=zoomBar.getBoundingClientRect();return {left:24,top:h.bottom-v.top+24,width:Math.max(160,v.width-(inspector.hidden&&activity.panel.hidden?48:300+64)),height:Math.max(100,z.top-h.bottom-48)};}
 function place(){if(!layout||!active)return;root.style.setProperty('--schematic-toolbar-height',zoomBar.offsetHeight+'px');root.style.setProperty('--schematic-inspector-top',(activity.panel.hidden?16:activity.panel.offsetHeight+28)+'px');const area=usable(),w=layout.width*zoom,h=layout.height*zoom,left=area.left+Math.max(0,(area.width-w)/2),top=area.top+Math.max(0,(area.height-h)/2);board.style.left=left+'px';board.style.top=top+'px';extent.style.width=Math.max(viewport.clientWidth,left+w+24)+'px';extent.style.height=Math.max(viewport.clientHeight,top+h+zoomBar.offsetHeight+48)+'px';}
 function scale(value){zoom=clampZoom(value);board.style.transform=`scale(${zoom})`;zoomLabel.textContent=Math.round(zoom*100)+'%';place();}
 function fit(all=true){if(!layout)return;const area=usable();scale(Math.floor(Math.min(area.width/layout.width,all?area.height/layout.height:1.5)*10)/10);viewport.scrollTo(0,0);}
 for(const [id,label,action] of [['out','−',()=>scale(zoom-.1)],['in','+',()=>scale(zoom+.1)],['reset','100%',()=>scale(1)],['fit','Fit width',()=>fit(false)],['all','Fit diagram',()=>fit()]]){const b=node('button',label);b.type='button';b.dataset.schematicZoom=id;b.setAttribute('aria-label',id==='in'?'Zoom in':id==='out'?'Zoom out':label);b.onclick=action;zoomBar.append(b);}const clear=node('button','Clear trace');clear.type='button';clear.id='schematic-clear-trace';clear.onclick=()=>choose(null);zoomBar.append(zoomLabel,clear);for(const [value,label] of [['DOWN','Flow down'],['RIGHT','Flow right']]){const b=node('button',label);b.type='button';b.dataset.schematicDirection=value;b.onclick=()=>{direction=value;centerAfter=true;signature='';refresh();};zoomBar.append(b);}root.append(zoomBar);
 const detailsToggle=node('button','Details');detailsToggle.type='button';detailsToggle.id='schematic-details-toggle';detailsToggle.setAttribute('aria-controls','schematic-inspector');inspector.id='schematic-inspector';detailsToggle.onclick=()=>{inspectorOpen=!inspectorOpen;if(inspectorOpen)activity.panel.open=false;inspect();};zoomBar.append(detailsToggle);
 // Drag the empty canvas with the primary pointer. Nodes retain their usual
 // click/keyboard behavior; scrollbars and arrow keys remain available too.
 let pan=null;
 viewport.addEventListener('pointerdown',e=>{if(e.button!==0||e.target.closest('button'))return;pan={id:e.pointerId,x:e.clientX,y:e.clientY,left:viewport.scrollLeft,top:viewport.scrollTop};viewport.setPointerCapture(e.pointerId);viewport.classList.add('schematic-panning');e.preventDefault();viewport.focus({preventScroll:true});});
 viewport.addEventListener('pointermove',e=>{if(!pan||pan.id!==e.pointerId)return;viewport.scrollTo(pan.left+pan.x-e.clientX,pan.top+pan.y-e.clientY);});
 for(const event of ['pointerup','pointercancel','lostpointercapture'])viewport.addEventListener(event,()=>{pan=null;viewport.classList.remove('schematic-panning');});
 new ResizeObserver(()=>{if(active)place();}).observe(root);
 new ResizeObserver(()=>{if(active)place();}).observe(heading);
 new ResizeObserver(()=>{if(active)place();}).observe(zoomBar);
 new ResizeObserver(()=>{if(active)place();}).observe(activity.panel);
 for(const [id,label] of [['screen','This screen'],['connections','Connections'],['app','Whole app']]){const b=node('button',label);b.type='button';b.dataset.schematicLevel=id;b.onclick=()=>{level=id;picked=null;signature='';refresh();};bar.append(b);}
 function setActive(value){if(value===active)return;if(value)scroll=canvas.scrollTop;active=value;renderRevision++;if(active)signature='';root.hidden=!active;document.body.classList.toggle('schematics-active',active);toggle.setAttribute('aria-pressed',String(active));document.dispatchEvent(new Event('schematics-changed'));if(active){refresh();canvas.scrollTop=0;title.tabIndex=-1;title.focus({preventScroll:true});}else{canvas.scrollTop=scroll;toggle.focus({preventScroll:true});}}
 toggle.onclick=()=>setActive(!active);
 function choose(id,center=false){picked=id;inspectorOpen=!!id;if(id)activity.panel.open=false;inspect();if(center){const pt=layout?.points.get(id),area=usable();if(pt)viewport.scrollTo({left:Math.max(0,board.offsetLeft+(pt.x+98)*zoom-area.left-area.width/2),top:Math.max(0,board.offsetTop+(pt.y+52)*zoom-area.top-area.height/2)});}}
 function inspect(){inspector.replaceChildren();const item=model.nodes.find(n=>n.id===picked),near=adjacentNodes(picked,model.edges);inspector.hidden=!item||!inspectorOpen||activity.panel.open;detailsToggle.disabled=!item;detailsToggle.setAttribute('aria-expanded',String(!inspector.hidden));place();for(const b of board.querySelectorAll('button')){b.setAttribute('aria-pressed',String(b.dataset.schematicNode===picked));b.classList.toggle('schematic-muted',!!item&&!near.has(b.dataset.schematicNode));}
 for(const wire of board.querySelectorAll('[data-wire-from]')){const on=!!item&&(wire.dataset.wireFrom===picked||wire.dataset.wireTo===picked);wire.classList.toggle('schematic-traced',on);wire.classList.toggle('schematic-muted',!!item&&!on);}if(!item){inspector.append(node('p','Select a component to see its state, purpose and next destination.'));return;}
  const close=node('button','×','schematic-inspector-close');close.type='button';close.setAttribute('aria-label','Hide component details');close.onclick=()=>{inspectorOpen=false;inspect();detailsToggle.focus({preventScroll:true});};inspector.append(close,node('h2',item.label),node('p',item.state,'schematic-state'));
  if(item.detail?.length>300){const more=node('details');more.append(node('summary','Full description'),node('p',item.detail));inspector.append(more);}else inspector.append(node('p',item.detail));
  for(const e of model.edges.filter(e=>e.from===item.id||e.to===item.id)){const from=model.nodes.find(n=>n.id===e.from),to=model.nodes.find(n=>n.id===e.to);const other=e.from===item.id?to:from;const follow=node('button',`${e.from===item.id?'To':'From'} ${other?.label} · ${e.label}`,'schematic-follow');follow.type='button';follow.dataset.schematicFollow=other.id;follow.onclick=()=>choose(other.id,true);inspector.append(follow);}
  if(item.route&&!(item.route==='record'&&selectedScreen()!=='record')){const open=node('button','Open '+(screens.find(s=>s[0]===item.route)?.[1]||'conversation'),'primary');open.type='button';open.dataset.schematicOpen=item.id;open.onclick=()=>{setActive(false);if(item.taskId)document.dispatchEvent(new CustomEvent('continue-development-task',{detail:{taskId:item.taskId}}));else navigate(item.route,true);};inspector.append(open);}
 }
 async function refresh(){if(!active)return;const world=runtimeWorld(current),p=heldProjection(current);const next=schematic({screen:selectedScreen(),level,screens,p,world,chosen:focusChoice(localStorage,world),session:currentTaskSession(),editor:currentTaskEditor(),workspace:selectedWorkspace()});const key=JSON.stringify([world,next,direction]);if(key===signature)return;signature=key;model=next;activity.panel.hidden=!model.taskId;activity.refresh();
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
