import {node} from './app-shell.js';
// This surface reports the current conversation request, not runtime workers.
export function initBotActivity({root,connect,input,cancel}) {
  const panel=node('section',undefined,'bot-activity');panel.id='bot-activity';
  panel.setAttribute('aria-label','Current bot activity');
  const title=node('h2','What’s happening'),identity=node('p'),state=node('p'),timing=node('p'),next=node('p');
  state.id='bot-activity-state';state.setAttribute('role','status');next.id='bot-activity-next';
  const action=node('button','Connect provider','primary');action.type='button';action.id='bot-activity-action';
  const preview=node('pre',undefined,'bot-live-output');preview.id='bot-live-output';preview.hidden=true;
  preview.setAttribute('aria-label','Live assistant output');
  panel.append(title,identity,state,timing,next,action,preview);root.append(panel);
  const rail=node('section',undefined,'bot-activity-rail');rail.id='bot-activity-rail';rail.dataset.source='conversation';
  const railTitle=node('p','Bot activity','eyebrow'),railName=node('p'),railState=node('p'),railTiming=node('p'),railOutput=node('pre',undefined,'bot-live-output'),open=node('button','Open bot'),railCancel=node('button','Cancel reply');open.type=railCancel.type='button';
  rail.append(railTitle,railName,railState,railTiming,railOutput,open,railCancel);
  document.querySelector('#receipts .activity-description')?.after(rail);
  railCancel.onclick=()=>cancel.click();
  function syncRail(){railName.textContent=identity.textContent;railState.textContent=state.textContent;railTiming.textContent=timing.textContent;railOutput.textContent=preview.textContent.slice(-1200);railOutput.hidden=preview.hidden;railCancel.hidden=!(running&&target==='cancel');railCancel.disabled=action.disabled;}
  new MutationObserver(syncRail).observe(panel,{childList:true,subtree:true,characterData:true,attributes:true,attributeFilter:['hidden','disabled']});
  let started=0,lastOutput=0,lastBytes=0,running=false,failed=false,completed=false,timer=null,target=null;
  function tick(){timing.textContent=started?`Elapsed ${Math.floor((Date.now()-started)/1000)}s${lastOutput?` · Last output ${Math.floor((Date.now()-lastOutput)/1000)}s ago`:completed?' · Reply delivered at completion':' · No live assistant text received'}`:'';}
  function stop(){running=false;clearInterval(timer);timer=null;tick();}
  action.onclick=()=>{if(target==='cancel')cancel.click();else if(target==='connect')connect.click();else if(target==='reply')document.querySelector('#bot-transcript .bot-assistant:last-of-type')?.scrollIntoView({block:'start'});else if(target==='review')document.querySelector('.bot-proposal button:not(:disabled)')?.focus();else input.focus();};
  return {
    reset(){stop();started=0;failed=false;completed=false;lastOutput=0;lastBytes=0;preview.textContent='';preview.hidden=true;timing.textContent='';},
    refresh({id,name,model,ready,pending,busy,hasProposals}){
      open.dataset.nav='bot:'+id;identity.textContent=[name?.trim()||id,model].filter(Boolean).join(' · ');
      if(running)return;
      if(pending){state.textContent='Waiting for sign-in';next.textContent='Finish signing in in your browser.';action.hidden=true;return;}
      if(!ready){state.textContent='Needs connection';next.textContent='Connect your provider, then send the saved assignment.';target='connect';action.textContent='Connect provider';}
      else if(failed){state.textContent='Reply stopped';next.textContent='Read the error below. Your message is restored; edit or resend it when ready.';target='message';action.textContent='Review saved message';}
      else if(hasProposals){state.textContent='Needs your review';next.textContent='Review the proposed changes below. No change is applied automatically.';target='review';action.textContent='Review proposal';}
      else {state.textContent=completed?'Reply complete':'Ready for a message';next.textContent=completed?'Read the reply below, then send the next step when ready.':'Send an assignment and attach the source files it needs. This conversation bot runs when you send a message.';target=completed?'reply':'message';action.textContent=completed?'Read reply':'Write message';}
      action.hidden=false;action.disabled=busy;
    },
    start(canCancel){stop();failed=false;completed=false;running=true;started=Date.now();lastOutput=0;lastBytes=0;preview.textContent='';preview.hidden=true;state.textContent='Request sent · waiting for provider';next.textContent='Live assistant text will appear here when received.'+(canCancel?' Cancel becomes available when the provider starts.':' Wait for the reply or a reported error.');target=canCancel?'cancel':null;action.textContent='Cancel reply';action.hidden=!canCancel;action.disabled=true;tick();timer=setInterval(tick,1000);},
    observe(value){if(!running)return;if(value.active)next.textContent=value.cancelled?'Waiting for the provider process to stop.':'You can cancel this reply. Completed results will appear below.';action.disabled=!value.active||value.cancelled;state.textContent=value.cancelled?'Cancelling reply':value.phase||(value.received_bytes?'Receiving reply':'Waiting for provider');if(value.received_bytes>lastBytes){lastBytes=value.received_bytes;lastOutput=Date.now();}if(value.text){preview.textContent=value.text;preview.hidden=false;preview.scrollTop=preview.scrollHeight;}tick();},
    finish(error){failed=!!error;completed=!error;stop();if(!error){preview.textContent='';preview.hidden=true;}},
  };
}
