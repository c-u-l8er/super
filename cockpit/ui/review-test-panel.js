import {reviewTestCoverage} from './review-test-coverage.js';
import {node} from './app-shell.js';
import {runtimeWorld,heldProjection} from './runtime-bots.js';
const profileLabelFor=value=>({'super-elixir-review@1':'Elixir plan and review tests','super-rust-review@1':'Rust review and reply tests'}[value]??'JavaScript behavior tests');
export function reviewTestPanel({attempt,invoke,current,acceptResult,readOnly=false}){
  const panel=node('section',undefined,'attempt-checks');panel.id='attempt-tests-'+attempt.id;
  panel.append(node('h4','Local test runs'),node('p','Runs the captured source with every file in this review applied together. Ignored files and installed dependencies are excluded. Elixir tests cover the runtime’s plan and review workflow and require Elixir and Erlang installed with asdf. Rust tests cover review recovery and reply controls, require rustup and cached Cargo dependencies, and run offline. The runtime records the start and outcome; full output stays on this device. Tests do not accept the plan.','directory-note'));
  const controls=node('div',undefined,'connection-row'),start=node('button','Run JavaScript tests','subtle');start.type='button';start.id='attempt-run-'+attempt.id;
  const profile=node('select');profile.id='attempt-test-profile-'+attempt.id;profile.setAttribute('aria-label','Test profile');for(const [value,label] of [['super-javascript-behavior@1','JavaScript behavior tests'],['super-elixir-review@1','Elixir plan and review tests'],['super-rust-review@1','Rust review and reply tests']]){const option=node('option',label);option.value=value;profile.append(option);}start.textContent='Run selected tests';
  const profileLabel=node('label','Test profile','field');profileLabel.append(profile);
  const notice=node('p','','availability-note');notice.setAttribute('role','status');notice.hidden=true;new MutationObserver(()=>{notice.hidden=!notice.textContent;}).observe(notice,{childList:true});const history=node('div');history.id='attempt-test-history-'+attempt.id;
  if(!readOnly&&!['dismissed','accepted'].includes(attempt.status))controls.append(profileLabel,start);panel.append(controls,notice,history);
  const origin=runtimeWorld(current),world=JSON.parse(origin);let busy=false,signature='',polling=false;
  async function refresh(){
    if(polling||runtimeWorld(current)!==origin)return;polling=true;
    try{
      const result=await invoke('review_tests',{request:{operation:'list',world,attempt_ref:attempt.id}});
      if(!panel.isConnected||runtimeWorld(current)!==origin)return;
      const running=result.runs.some(r=>['running','starting'].includes(r.state));start.disabled=busy||running;profile.disabled=busy||running;
      if(!running&&notice.textContent==='Cancellation requested. Waiting for the final outcome…')notice.textContent='Cancellation recorded. The outcome is saved below.';
      const latestAttempt=heldProjection(current)?.development_attempts?.[attempt.id];
      const saved=latestAttempt?.test_runs??{};
      const latestRun=Object.values(saved).sort((a,b)=>a.started_at.localeCompare(b.started_at)||a.run_id.localeCompare(b.run_id)).at(-1);
      for(const run of Object.values(saved))if(!result.runs.some(r=>r.run_id===run.run_id))result.runs.push({run_id:run.run_id,state:run.state==='started'?'awaiting_outcome':run.state,attempt_ref:attempt.id,runtime_only:true});
      const next=JSON.stringify([result,saved]);if(next===signature)return;signature=next;
      const opened=new Set([...history.querySelectorAll('details[open]')].map(d=>d.dataset.runOutput));history.replaceChildren();
      const task=heldProjection(current)?.development_tasks?.[attempt.task_ref];
      const coverage=reviewTestCoverage(saved,task?.required_checks?.profiles??[]);
      if(coverage.rows.length){const summary=node('section',undefined,'attempt-checks');summary.dataset.profileCoverage=attempt.id;summary.append(node('h4',coverage.ready?'Test profiles agree':'Test coverage needs attention'),node('p','Required plan checks and every additional profile you run need their latest passing result on the same snapshot.','directory-note'));for(const row of coverage.rows){const labels={missing:'Required — not run yet',passed:'Passed on this snapshot',failed:'Tests failed — rerun this profile',incomplete:'No completed result — rerun this profile',running:'Still running',"different-snapshot":'Passed on a different snapshot — rerun this profile'};summary.append(node('p',profileLabelFor(row.profile)+': '+labels[row.status]));}history.append(summary);}
      if(!result.runs.length)history.append(node('p','No local test runs recorded. Choose this plan’s repository in Editor before starting.','directory-note'));
      for(const run of result.runs){
        const row=node('article',undefined,'development-attempt');row.dataset.testRun=run.run_id;
        const recorded=saved[run.run_id],interrupted=recorded?.outcome?.reason==='interrupted';
        const result=interrupted?null:run.result,label=interrupted?'Interrupted':result?.reason==='cancelled'?'Cancelled':run.state==='completed'?(result?.verdict==='pass'?'Tests passed':'Tests failed'):run.state==='running'?'Tests running':run.state==='interrupted'?'Interrupted':run.state==='starting'?'Preparing tests':'Could not complete tests';
        row.append(node('h4',interrupted?'Interrupted':run.runtime_only?'Runtime test history':label),node('p',run.run_id,'directory-note'));

        const confirmation=node('p',recorded?(recorded.state==='started'?'Runtime start recorded · awaiting final outcome':'Start and outcome saved in runtime'):'Runtime confirmation unavailable','availability-note');confirmation.dataset.runtimeTest=run.run_id;row.append(confirmation);if(recorded?.profile)row.append(node('p','Profile: '+profileLabelFor(recorded.profile),'directory-note'));
        if(run.runtime_save_error)row.append(node('p','The host could not save the final outcome in the runtime. Local output remains below; this run is not confirmed there.','availability-note'));
        if(run.retryable){
          const retry=node('button','Retry saving outcome','subtle');retry.type='button';retry.dataset.retryTest=run.run_id;retry.disabled=busy;
          retry.onclick=async()=>{
            if(busy||runtimeWorld(current)!==origin)return;busy=true;retry.disabled=true;notice.textContent='Saving the retained outcome. Tests are not rerun…';
            try{await invoke('review_tests',{request:{operation:'retry',world,run_id:run.run_id}});notice.textContent='Outcome saved. Tests were not rerun.';}
            catch(e){notice.textContent=String(e);}finally{busy=false;signature='';await refresh();}
          };row.append(retry);
        }
        if(run.runtime_save_error&&!run.retryable)row.append(node('p','This app session has no retained completion to resend. The runtime result remains unconfirmed.','directory-note'));
        if((run.runtime_only||interrupted)&&recorded?.outcome){row.append(node('p',`Runtime outcome: ${recorded.outcome.verdict??recorded.outcome.reason}`),node('p','Snapshot: '+(recorded.outcome.snapshot_sha256??'not captured'),'directory-note'),node(interrupted?'p':'pre',recorded.outcome.output||'No output preview.',interrupted?'directory-note':'attempt-text'));if(recorded.outcome.output_omitted)row.append(node('p','Output preview is shortened; the full output was device-local.','directory-note'));}
        if(interrupted)row.append(node('p','Super restarted before this run finished reporting. No passing result is recorded. Run tests again when ready.','availability-note'));
        if(run.message&&!interrupted)row.append(node('p',run.message,'availability-note'));
        if(result){
          row.append(node('p',`${profileLabelFor(result.profile)} · Saved proposal only · ${result.profile==='super-rust-review@1'?'Focused native test target':result.tests.length+' test '+(result.tests.length===1?'file':'files')} · ${result.finished_at??result.started_at}`,'directory-note'));
          if(result.reason)row.append(node('p','Run outcome: '+result.reason,'availability-note'));
          const output=node('details');output.dataset.runOutput=run.run_id;output.open=opened.has(run.run_id);
          if(result.toolchain_sha256)output.append(node('p',(result.profile==='super-rust-review@1'?'Rust toolchain and cached dependencies: ':'Elixir / Erlang toolchain: ')+result.toolchain_sha256,'directory-note'));
          output.append(node('summary','Test output and exact snapshot'),node('p','Snapshot: '+result.snapshot_sha256,'directory-note'),node('p','Reviewed result: '+result.result_sha256,'directory-note'),node('pre',result.output||'No test output was captured.','attempt-text'));
          if(result.result_paths)output.append(node('p','Applied files: '+result.result_paths.join(', '),'directory-note'));
          if(result.omitted_bytes)output.append(node('p',`${result.omitted_bytes} output bytes omitted.`,'availability-note'));row.append(output);
        }
        if(['running','starting'].includes(run.state)){
          const cancel=node('button','Cancel test run','subtle');cancel.type='button';cancel.dataset.cancelTest=run.run_id;
          cancel.onclick=async()=>{if(busy)return;busy=true;cancel.disabled=true;try{await invoke('review_tests',{request:{operation:'cancel',world,run_id:run.run_id}});notice.textContent='Cancellation requested. Waiting for the final outcome…';}catch(e){notice.textContent=String(e);}finally{busy=false;await refresh();}};row.append(cancel);
        }
        if(coverage.ready&&!readOnly&&latestRun?.run_id===run.run_id&&recorded?.outcome?.verdict==='pass'&&!['dismissed','accepted'].includes(latestAttempt?.status)){
          const decision=node('section',undefined,'attempt-checks');decision.dataset.acceptanceRun=run.run_id;
          decision.append(node('h4','Accept this tested result'),node('p','Save every reviewed file first. Super checks all saved replacements and the repository against this passing snapshot. Explain why it meets the review criteria.','directory-note'));
          const label=node('label','Acceptance reason','field'),note=node('input');note.type='text';note.required=true;note.maxLength=250;note.dataset.acceptanceNote=attempt.id;label.append(note);decision.append(label);
          const accept=node('button','Check files and accept result','subtle');accept.type='button';accept.dataset.acceptResult=attempt.id;accept.disabled=busy;
          accept.onclick=async()=>{
            if(busy||runtimeWorld(current)!==origin||!note.reportValidity())return;
            if([...panel.closest('#development-task-detail').querySelectorAll('textarea')].some(n=>n.value)){notice.textContent='Save your unfinished review or planning note before accepting.';return;}
            busy=true;accept.disabled=true;notice.textContent='Checking saved files against the passing test snapshot…';
            try{
              const selected=await invoke('development_request',{request:{operation:'status'}});
              await acceptResult({generation:selected.generation,attempt_ref:attempt.id,revision:latestAttempt.revision,world,run_id:run.run_id,note:note.value});
              note.value='';notice.textContent='Acceptance saved for this exact tested result.';
            }catch(e){notice.textContent=String(e);}finally{busy=false;accept.disabled=false;}
          };decision.append(accept);row.append(decision);
        }
        history.append(row);
      }
    }catch(e){notice.textContent=String(e);}finally{polling=false;}
  }
  start.onclick=async()=>{
    if(busy||runtimeWorld(current)!==origin)return;
    if([...panel.closest('#development-task-detail').querySelectorAll('textarea')].some(n=>n.value)){notice.textContent='Save your unfinished review or planning note before starting tests.';return;}
    busy=true;start.disabled=true;profile.disabled=true;notice.textContent='Checking the saved review and selected repository…';
    try{
      const selected=await invoke('development_request',{request:{operation:'status'}});
      if(runtimeWorld(current)!==origin)throw Error('The runtime changed. Reopen the review.');
      await invoke('review_tests',{request:{operation:'start',world,attempt_ref:attempt.id,revision:attempt.revision,generation:selected.generation,profile:profile.value}});
      notice.textContent='Local test run recorded. Progress and output appear below.';
    }catch(e){notice.textContent=String(e);}finally{busy=false;await refresh();}
  };
  const timer=setInterval(()=>{if(!panel.isConnected){clearInterval(timer);return;}if(panel.closest('details')?.open)refresh();},600);
  setTimeout(refresh,0);return panel;
}
