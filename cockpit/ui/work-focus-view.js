import {node,navigate} from './app-shell.js';
import {heldProjection,runtimeWorld} from './runtime-bots.js';
import {currentTaskSession} from './task-session.js';
import {FOCUS_KEY,focusChoice,saveFocus,workFocus} from './work-focus.js';
export function initWorkFocus({current}){
  const root=node('section',undefined,'app-screen work-focus');root.id='work-focus';root.dataset.screen='continue-work';root.hidden=!document.querySelector('[data-nav="continue-work"].on');
  const heading=node('h1','Continue work'),intro=node('p','One task. One next step. Your progress stays here.','screen-description'),notice=node('p','','bot-status'),card=node('section',undefined,'focus-card'),other=node('details',undefined,'focus-queue');
  notice.setAttribute('role','status');root.append(node('p','SUPER / CONTINUE WORK','eyebrow'),heading,intro,notice,card,other);document.getElementById('workspace-canvas').append(root);
  const home=node('button','Continue work','primary');home.type='button';home.dataset.nav='continue-work';home.id='focus-home';document.querySelector('#receipts h2')?.after(home);
  let signature='',chosen=null,heldWorld=null;
  function refresh(){
    const world=runtimeWorld(current);if(world!==heldWorld){heldWorld=world;chosen=focusChoice(localStorage,world);signature='';}
    const view=workFocus(heldProjection(current),world,chosen,currentTaskSession()),key=JSON.stringify([world,view]);if(signature===key)return;signature=key;card.replaceChildren();delete card.dataset.focusTask;other.replaceChildren();
    if(!view.task){card.append(node('h2',view.title),node('p',view.detail));other.hidden=true;if(view.state==='empty'){const create=node('button','Create a plan','primary');create.onclick=()=>navigate('development-tasks',true);card.append(create);}return;}
    const task=view.task;card.dataset.focusTask=task.id;card.append(node('h2',task.title),node('p',view.bot?.name||task.bot_ref,'focus-bot'));
    const steps=node('ol',undefined,'focus-steps');steps.setAttribute('aria-label','Development steps');
    for(const [i,label] of ['Prepare','Bot reply','Review','Check','Finish'].entries()){const li=node('li',label);if(i+1===view.step)li.setAttribute('aria-current','step');steps.append(li);}
    const state=node('p',view.label,'focus-current');state.id='focus-current';state.setAttribute('role','status');card.append(state,node('p',view.detail));
    const next=node('button',view.waiting?'Watch bot':view.label,'primary');next.id='focus-next';next.type='button';next.onclick=()=>{
      if(runtimeWorld(current)!==world){signature='';refresh();return;}
      const latest=workFocus(heldProjection(current),runtimeWorld(current),task.id,currentTaskSession());
      if(!latest.task||latest.task.id!==task.id){signature='';refresh();return;}
      if(latest.target==='conversation'&&latest.bot){navigate('bot:'+latest.bot.client_ref,true);document.dispatchEvent(new CustomEvent('open-task-conversation',{detail:{botId:latest.bot.client_ref}}));}
      else document.dispatchEvent(new CustomEvent('continue-development-task',{detail:{taskId:task.id}}));
    };card.append(next);card.append(steps);
    const criteria=node('details',undefined,'focus-criteria');criteria.append(node('summary','Done when'),node('p',task.criteria));card.append(criteria);
    const detail=node('button','Task details','subtle');detail.type='button';detail.dataset.developmentTask=task.id;card.append(detail);
    other.hidden=false;other.append(node('summary',`Other work (${view.queue.length-1})`));
    for(const t of view.queue.filter(t=>t.id!==task.id)){const pick=node('button',t.title,'subtle');pick.type='button';pick.dataset.focusChoose=t.id;pick.onclick=()=>choose(t.id);other.append(pick);}
    if(view.queue.length===1)other.append(node('p','Finish this task, then choose the next one.'));
  }
  function choose(id){const p=heldProjection(current),world=runtimeWorld(current);if(!p?.development_tasks?.[id])return;try{saveFocus(localStorage,world,id);chosen=id;notice.textContent='';}catch{notice.textContent='Could not remember this choice. Free local storage and try again.';return;}signature='';refresh();navigate('continue-work',true);}
  document.addEventListener('focus-development-task',e=>choose(e.detail.taskId));
  document.addEventListener('runtime-view-rendered',refresh);document.addEventListener('task-session-changed',refresh);
  window.addEventListener('storage',e=>{if(e.key===FOCUS_KEY){heldWorld=null;refresh();}});
  new MutationObserver(refresh).observe(document.getElementById('world'),{childList:true});refresh();
}
