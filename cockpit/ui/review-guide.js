import {node,navigate} from './app-shell.js';
import {heldProjection,runtimeWorld} from './runtime-bots.js';
import {reviewNextStep} from './review-next-step.js';
const progress=new Map();
let progressWorld=null;
// Presentation only. The existing native controls perform every operation.
export function guideReview({card,material,attempt,task,current}){
  const origin=runtimeWorld(current),guide=node('section',undefined,'attempt-checks review-guide'),title=node('h4','Next step'),explanation=node('p'),action=node('button','','primary'),message=node('p','','availability-note');
  guide.dataset.reviewGuide=attempt.id;action.type='button';action.dataset.reviewNext=attempt.id;message.setAttribute('role','status');guide.append(title,explanation,action,message);
  const more=node('details',undefined,'review-details');more.append(node('summary','Review details and other controls'));
  for(const child of [...card.children].slice(1))more.append(child);
  material.hidden=true;guide.append(material);card.append(guide,more);let signature='';
  if(progressWorld!==origin){progress.clear();progressWorld=origin;}
  const key=JSON.stringify([attempt.id,attempt.task_revision]);
  const saved=progress.get(key)??{reviewed:false,openedEditor:false};progress.set(key,saved);
  function state(){const p=runtimeWorld(current)===origin?heldProjection(current):null;return reviewNextStep(p?.development_tasks?.[task.id],p?.development_attempts?.[attempt.id],saved);}
  function expose(element){if(element===material)material.hidden=false;else more.open=true;if(element){if(element.tagName==='DETAILS')element.open=true;element.scrollIntoView({block:'nearest'});}}
  function refresh(){const s=state(),key=JSON.stringify(s);if(key!==signature){signature=key;action.textContent=s.label;explanation.textContent=s.kind==='apply'&&!card.querySelector('[data-stage-saved-review]')?'Open the reviewed proposal in Editor, save its exact replacement, then return here. The retained text is available below.':s.detail;action.disabled=['unavailable','stale','done'].includes(s.kind);}
    const notices=[...more.querySelectorAll('[role=status]')].map(n=>n.textContent.trim()).filter(Boolean);const text=notices.at(-1)||'';if(message.textContent!==text)message.textContent=text;
  }
  action.onclick=()=>{
    const s=state();
    if(s.kind==='review'){saved.reviewed=true;expose(material);}
    else if(s.kind==='test'){
      const select=card.querySelector('[id="attempt-test-profile-'+attempt.id+'"]'),run=card.querySelector('[id="attempt-run-'+attempt.id+'"]');
      if(!run||run.disabled){message.textContent='Checks are not ready. Open the details to inspect the current run.';expose(run);return;}
      select.value=s.profile;run.click();
    }else if(s.kind==='running'){expose(card.querySelector('[id="attempt-test-history-'+attempt.id+'"]'));}
    else if(s.kind==='apply'){
      const stage=card.querySelector('[data-stage-saved-review]');saved.openedEditor=true;
      if(stage)stage.click();else navigate('editor',true);
    }else if(s.kind==='accept'){
      const decision=card.querySelector('[data-acceptance-run]');expose(decision);decision?.querySelector('input')?.focus();
    }else if(s.kind==='blocked'){expose(card.querySelector('[id="attempt-note-'+attempt.id+'"]'));}
    refresh();
  };
  const observer=new MutationObserver(refresh);observer.observe(more,{childList:true,subtree:true,characterData:true});
  const update=()=>{if(!card.isConnected){observer.disconnect();document.removeEventListener('runtime-view-rendered',update);return;}refresh();};
  document.addEventListener('runtime-view-rendered',update);refresh();
}
