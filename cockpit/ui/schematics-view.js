import {node,navigate,screens,selectedScreen,selectedWorkspace} from './app-shell.js';
import {runtimeWorld,heldProjection} from './runtime-bots.js';
import {currentTaskSession} from './task-session.js';
import {focusChoice} from './work-focus.js';
import {schematic} from './schematics-model.js';
export function initSchematics({current}){
 const toggle=document.getElementById('toggle-schematics'),canvas=document.getElementById('workspace-canvas'),root=node('section',undefined,'schematics');root.id='schematics';root.hidden=true;root.setAttribute('aria-label','Live app schematics');canvas.append(root);
 const title=node('h1','Schematics'),intro=node('p','Follow your work through Super. Select a node to inspect it.','screen-description'),bar=node('nav',undefined,'schematic-levels'),note=node('p','','schematic-note'),board=node('div',undefined,'schematic-board'),inspector=node('aside',undefined,'schematic-inspector'),plan=node('details',undefined,'schematic-plan');
 bar.setAttribute('aria-label','Schematic level');inspector.setAttribute('aria-label','Selected component');inspector.setAttribute('aria-live','polite');
 plan.append(node('summary','Development plan · first connected path'),node('p','Now: every screen has an overview and connections; Continue work, Bots, Editor and Reviews share a live task path. Next: detailed internals for the remaining screens, event history, pan/zoom and deeper WRL execution.'),node('p','Saved plan: docs/plans/SCHEMATICS.md · linked from the repository README.'));
 const body=node('div',undefined,'schematic-body'),viewport=node('div',undefined,'schematic-viewport');viewport.setAttribute('aria-label','Wiring diagram');viewport.tabIndex=0;viewport.append(board);body.append(viewport,inspector);root.append(node('p','SUPER / SCHEMATICS','eyebrow'),title,intro,bar,note,body,plan);
 let active=false,level='screen',picked=null,model=null,signature='',scroll=0;
 for(const [id,label] of [['screen','This screen'],['connections','Connections'],['app','Whole app']]){const b=node('button',label);b.type='button';b.dataset.schematicLevel=id;b.onclick=()=>{level=id;picked=null;signature='';refresh();};bar.append(b);}
 function setActive(value){if(value===active)return;if(value)scroll=canvas.scrollTop;active=value;root.hidden=!active;document.body.classList.toggle('schematics-active',active);toggle.setAttribute('aria-pressed',String(active));document.dispatchEvent(new Event('schematics-changed'));if(active){refresh();canvas.scrollTop=0;title.tabIndex=-1;title.focus({preventScroll:true});}else{canvas.scrollTop=scroll;toggle.focus({preventScroll:true});}}
 toggle.onclick=()=>setActive(!active);
 function inspect(){inspector.replaceChildren();const item=model.nodes.find(n=>n.id===picked);for(const b of board.querySelectorAll('button'))b.setAttribute('aria-pressed',String(b.dataset.schematicNode===picked));if(!item){inspector.append(node('p','Select a component to see its state, purpose and next destination.'));return;}
  inspector.append(node('h2',item.label),node('p',item.state,'schematic-state'));
  if(item.detail?.length>300){const more=node('details');more.append(node('summary','Full description'),node('p',item.detail));inspector.append(more);}else inspector.append(node('p',item.detail));
  for(const e of model.edges.filter(e=>e.from===item.id||e.to===item.id)){const from=model.nodes.find(n=>n.id===e.from),to=model.nodes.find(n=>n.id===e.to);inspector.append(node('p',`${from?.label} → ${e.label} → ${to?.label}`,'schematic-note'));}
  if(item.route&&!(item.route==='record'&&selectedScreen()!=='record')){const open=node('button','Open '+(screens.find(s=>s[0]===item.route)?.[1]||'conversation'),'primary');open.type='button';open.dataset.schematicOpen=item.id;open.onclick=()=>{setActive(false);if(item.taskId)document.dispatchEvent(new CustomEvent('continue-development-task',{detail:{taskId:item.taskId}}));else navigate(item.route,true);};inspector.append(open);}
 }
 function refresh(){if(!active)return;const world=runtimeWorld(current),p=heldProjection(current);const next=schematic({screen:selectedScreen(),level,screens,p,world,chosen:focusChoice(localStorage,world),session:currentTaskSession(),workspace:selectedWorkspace()});const key=JSON.stringify([world,next,canvas.clientWidth]);if(key===signature)return;signature=key;model=next;
  title.textContent='Schematics · '+model.title;note.textContent=model.coverage+(p?'':' Runtime unavailable — reconnect to inspect current state.');
  for(const b of bar.children)b.setAttribute('aria-pressed',String(b.dataset.schematicLevel===level));
  board.replaceChildren();const cols=Math.max(1,Math.min(level==='app'?4:3,Math.floor((viewport.clientWidth-38)/230))),w=230,h=140,pad=18;board.style.width=`${cols*w+pad*2}px`;board.style.height=`${Math.ceil(model.nodes.length/cols)*h+pad*2}px`;
  const ns='http://www.w3.org/2000/svg',svg=document.createElementNS(ns,'svg');svg.setAttribute('aria-hidden','true');svg.setAttribute('width','100%');svg.setAttribute('height','100%');const defs=document.createElementNS(ns,'defs'),marker=document.createElementNS(ns,'marker');marker.id='schematic-arrow';marker.setAttribute('viewBox','0 0 10 10');marker.setAttribute('refX','8');marker.setAttribute('refY','5');marker.setAttribute('markerWidth','5');marker.setAttribute('markerHeight','5');marker.setAttribute('orient','auto-start-reverse');const arrow=document.createElementNS(ns,'path');arrow.setAttribute('d','M 0 0 L 10 5 L 0 10 z');arrow.style.fill='#577d9f';marker.append(arrow);defs.append(marker);svg.append(defs);board.append(svg);const points=new Map(model.nodes.map((n,i)=>[n.id,{x:pad+i%cols*w,y:pad+Math.floor(i/cols)*h}]));
  for(const e of model.edges){const a=points.get(e.from),b=points.get(e.to);if(!a||!b)continue;const path=document.createElementNS(ns,'path');path.setAttribute('d',`M ${a.x+98} ${a.y+78} L ${a.x+98} ${a.y+94} L ${b.x+98} ${a.y+94} L ${b.x+98} ${b.y}`);const label=document.createElementNS(ns,'title');label.textContent=e.label;path.setAttribute('marker-end','url(#schematic-arrow)');path.append(label);svg.append(path);}
  for(const item of model.nodes){const pt=points.get(item.id),b=node('button',undefined,'schematic-node');b.type='button';b.dataset.schematicNode=item.id;b.style.left=pt.x+'px';b.style.top=pt.y+'px';b.title=item.detail;b.setAttribute('aria-label',item.label+': '+item.state);b.append(node('strong',item.label),node('span',item.state));b.onclick=()=>{picked=item.id;inspect();};board.append(b);}
  inspect();
 }
 document.addEventListener('page-selected',()=>{scroll=0;picked=null;signature='';refresh();});
 for(const event of ['runtime-view-rendered','task-session-changed','workspace-view-change','focus-development-task'])document.addEventListener(event,refresh);
 window.addEventListener('storage',refresh);window.addEventListener('resize',refresh);
 document.addEventListener('keydown',e=>{if(e.key==='Escape'&&active&&!document.querySelector('dialog[open]')){e.preventDefault();setActive(false);}});
}
