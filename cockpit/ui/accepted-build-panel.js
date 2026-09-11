import {node} from './app-shell.js';
import {heldProjection,runtimeWorld} from './runtime-bots.js';
export function buildSummary(record,snapshot){
  if(record.snapshot_sha256!==snapshot)return 'Different accepted snapshot';
  if(record.state==='running')return 'Building accepted source…';
  if(record.state==='interrupted')return 'Build interrupted';
  if(record.state==='completed'&&record.result?.artifact?.sha256&&record.result.snapshot_sha256===snapshot)return record.artifact_available===true?'Development build ready':'Build completed — artifact unavailable';
  if(record.state==='failed'&&record.result?.reason==='timeout')return 'Build timed out';
  return record.result?.reason==='cancelled'?'Build cancelled':'Build failed';
}
export function previewSummary(state){return ({starting:'Opening preview…',ready:'Preview displayed its first runtime frame.',unconfirmed:'Preview process is running, but startup is not confirmed. Check its window; older builds cannot report readiness.',closed:'Preview closed. You are back in the original app.',failed:'Preview could not keep running. Your original app is still available.'})[state]||'';}
export function acceptedBuildPanel({attempt,invoke,current}){
  const panel=node('section',undefined,'attempt-checks');panel.dataset.acceptedBuilds=attempt.id;
  panel.append(node('h4','Build accepted app'),node('p','Builds the Super cockpit offline from the accepted snapshot. Requires Rust and cached Cargo dependencies. A fresh build can take up to 15 minutes. The retained bundle includes a launcher and captured runtime source; it requires the local Elixir and desktop dependencies.','directory-note'));
  const start=node('button','Build accepted app','subtle');start.type='button';start.dataset.buildAccepted=attempt.id;
  const notice=node('p','','availability-note');notice.setAttribute('role','status');notice.hidden=true;
  const history=node('div');panel.append(start,notice,history);
  const origin=runtimeWorld(current),world=JSON.parse(origin);let busy=false,polling=false,signature='';
  const same=()=>{const a=heldProjection(current)?.development_attempts?.[attempt.id];return runtimeWorld(current)===origin&&a?.revision===attempt.revision&&a.status==='accepted';};
  async function refresh(){if(polling||!same())return;polling=true;try{
    const result=await invoke('review_tests',{request:{operation:'list_builds',world,attempt_ref:attempt.id}});if(!panel.isConnected||!same())return;
    result.preview=await invoke('review_tests',{request:{operation:'preview_status',world}});if(!panel.isConnected||!same())return;
    if(['Preview process started. Switch to its window to try the app.'].includes(notice.textContent)){notice.textContent='';notice.hidden=true;}
    const running=result.builds.some(b=>b.state==='running');start.disabled=busy||running;if(!running&&['Build started. Progress and output appear below.','Cancellation requested. Waiting for the build to stop…'].includes(notice.textContent)){notice.textContent='';notice.hidden=true;}const next=JSON.stringify(result);if(next===signature)return;signature=next;
    const open=new Set([...history.querySelectorAll('details[open]')].map(d=>d.dataset.buildOutput));history.replaceChildren();
    if(!result.builds.length)history.append(node('p','No local builds yet. Builds do not install the app or change the acceptance decision.','directory-note'));
    for(const build of result.builds){const row=node('article',undefined,'development-attempt');row.dataset.buildId=build.build_id;row.append(node('h4',buildSummary(build,attempt.acceptance.snapshot_sha256)),node('p','Device-local build history · '+build.build_id,'directory-note'));
      if(build.state==='running'){const cancel=node('button','Cancel build','subtle');cancel.type='button';cancel.dataset.cancelBuild=build.build_id;cancel.onclick=async()=>{cancel.disabled=true;try{await invoke('review_tests',{request:{operation:'cancel_build',world,build_id:build.build_id}});notice.hidden=false;notice.textContent='Cancellation requested. Waiting for the build to stop…';}catch(e){notice.hidden=false;notice.textContent=String(e);}finally{await refresh();}};row.append(cancel);}
      const preview=result.preview;
      if(preview.build_id===build.build_id){row.append(node('p',previewSummary(preview.state),'availability-note'));if(preview.message)row.append(node('p',preview.message,'availability-note'));if(preview.output){const details=node('details');details.append(node('summary','Preview diagnostic output'),node('pre',preview.output,'attempt-text'));row.append(details);}}
      if(preview.build_id===build.build_id&&['starting','ready','unconfirmed'].includes(preview.state)){
        row.append(node('p','The preview uses a separate test session. Your original app remains here.','availability-note'));
        const close=node('button','Close preview','subtle');close.type='button';close.dataset.closePreview=build.build_id;close.onclick=async()=>{close.disabled=true;try{await invoke('review_tests',{request:{operation:'stop_preview',world,build_id:build.build_id}});notice.hidden=false;notice.textContent='Preview closed. You are back in the original app.';}catch(e){notice.hidden=false;notice.textContent=String(e.message||e);}finally{await refresh();}};row.append(close);
      }else if(build.state==='completed'&&build.artifact_available===true){
        const launch=node('button','Try this build','subtle');launch.type='button';launch.dataset.tryBuild=build.build_id;launch.disabled=['starting','ready','unconfirmed','other-world'].includes(preview.state);
        row.append(node('p','Try it in a separate, temporary session. Close the preview to return here. This does not install the build or carry over your work and connections.','directory-note'),launch);
        launch.onclick=async()=>{launch.disabled=true;notice.hidden=false;notice.textContent='Checking the build and captured source…';try{const selected=await invoke('development_request',{request:{operation:'status'}});if(!same())throw Error('The review changed. Reopen it before trying the build.');await invoke('review_tests',{request:{operation:'launch_build',generation:selected.generation,attempt_ref:attempt.id,revision:attempt.revision,world,build_id:build.build_id}});notice.textContent='Preview process started. Switch to its window to try the app.';}catch(e){notice.textContent=String(e.message||e);}finally{signature='';await refresh();}};
      }
      if(build.message)row.append(node('p',build.message,'availability-note'));
      if(build.result){const result=build.result,detail=node('details');detail.dataset.buildOutput=build.build_id;detail.open=open.has(build.build_id);detail.append(node('summary','Build output and source identity'),node('p','Source snapshot: '+result.snapshot_sha256,'directory-note'),node('pre',result.output||'No compiler output recorded.','attempt-text'));row.append(detail);
        if(result.artifact&&build.state==='completed'&&build.artifact_available===true){row.append(node('p','Development build bundle retained. It has not replaced the running app.','availability-note'),node('p','Launcher'),node('pre',result.artifact.launcher,'attempt-text'),node('p','Executable SHA-256: '+result.artifact.sha256,'directory-note'));}
      }history.append(row);
    }
  }catch(e){if(panel.isConnected&&same()){notice.hidden=false;notice.textContent=String(e.message||e);}}finally{polling=false;}}
  start.onclick=async()=>{if(busy||!same())return;busy=true;start.disabled=true;notice.hidden=false;notice.textContent='Checking accepted source and starting the build…';try{
    const selected=await invoke('development_request',{request:{operation:'status'}});if(!same())throw Error('The review changed. Reopen it before building.');
    await invoke('review_tests',{request:{operation:'build_accepted',generation:selected.generation,attempt_ref:attempt.id,revision:attempt.revision,world}});
    if(panel.isConnected&&same())notice.textContent='Build started. Progress and output appear below.';
  }catch(e){if(panel.isConnected&&same())notice.textContent=String(e.message||e);}finally{busy=false;await refresh();}};
  const timer=setInterval(()=>{if(!panel.isConnected){clearInterval(timer);return;}refresh();},1000);queueMicrotask(refresh);return panel;
}
