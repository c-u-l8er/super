import {node,navigate} from './app-shell.js';
import {heldProjection,runtimeWorld} from './runtime-bots.js';

// A dated observation only. Neither the page nor local history supplies an acceptance.
export async function checkAcceptedResult({attempt,invoke,scope}){
  const origin=scope();
  const same=()=>{const now=scope();return now.world===origin.world&&now.revision===attempt.revision&&now.status==='accepted';};
  if(!same())throw Error('The review changed. Reopen the accepted result.');
  const selected=await invoke('development_request',{request:{operation:'status'}});
  if(!same())throw Error('The runtime or review changed. Reopen the accepted result.');
  const result=await invoke('review_tests',{request:{operation:'verify_accepted',attempt_ref:attempt.id,revision:attempt.revision,generation:selected.generation,world:JSON.parse(origin.world)}});
  if(!same())throw Error('The runtime or review changed during the check. Try again.');
  if(result.matched!==true||result.attempt_ref!==attempt.id||result.snapshot_sha256!==attempt.acceptance.snapshot_sha256||!Number.isFinite(result.checked_at))throw Error('The native check did not confirm this accepted snapshot.');
  return result;
}
export function acceptedResultCheck({attempt,invoke,current}){
  const panel=node('section',undefined,'attempt-checks');panel.dataset.acceptedFileCheck=attempt.id;
  panel.append(node('h4','Check saved result'),node('p','Before integration or rebuilding, check that the selected repository still matches the accepted files and tested snapshot. This check does not run a build.','directory-note'));
  const check=node('button','Check saved result','subtle');check.type='button';check.dataset.verifyAccepted=attempt.id;
  const editor=node('button','Open Editor','subtle');editor.type='button';editor.onclick=()=>navigate('editor',true);
  const notice=node('p','','availability-note');notice.setAttribute('role','status');notice.hidden=true;panel.append(check,editor,notice);
  const world=runtimeWorld(current);
  check.onclick=async()=>{if(check.disabled||runtimeWorld(current)!==world)return;check.disabled=true;notice.hidden=false;notice.textContent='Checking saved files against the accepted snapshot…';
    try{const result=await checkAcceptedResult({attempt,invoke,scope:()=>{const a=heldProjection(current)?.development_attempts?.[attempt.id];return {world:runtimeWorld(current),revision:a?.revision,status:a?.status};}});
      if(panel.isConnected&&runtimeWorld(current)===world)notice.textContent='Matched at '+new Date(result.checked_at).toLocaleString()+'. All reviewed files and the captured repository matched the accepted snapshot. Later edits require another file check.';
    }catch(e){if(panel.isConnected&&runtimeWorld(current)===world)notice.textContent=String(e.message||e);}finally{check.disabled=false;}
  };
  return panel;
}
