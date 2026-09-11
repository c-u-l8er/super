import {acceptedBuildPanel} from './accepted-build-panel.js';
import {acceptedResultCheck} from './accepted-result-check.js';
import {taskEditorView} from './task-editor.js';
import {botConversationHistory,taskHistoryLinks} from './task-conversations.js';
import {taskSessionView} from './task-session.js';
import {taskProgress} from './task-progress.js';
import {reviewTestPanel} from './review-test-panel.js';
import {node,navigate,selectedWorkspace} from './app-shell.js';
import {heldProjection,runtimeWorld,waitForBot} from './runtime-bots.js';
export function taskScope(p,workspace='',botClient=''){
  const bots=p?.bots??{};
  return Object.values(p?.development_tasks??{}).filter(t=>(!workspace||t.workspace_ref===workspace)&&(!botClient||bots[t.bot_ref]?.client_ref===botClient));
}
export function taskReviewCounts(p,taskId){
  const counts={accepted:0,awaiting:0,needsChanges:0};
  for(const attempt of Object.values(p?.development_attempts??{})){
    if(attempt.task_ref!==taskId)continue;
    if(attempt.status==='accepted'&&attempt.acceptance?.schema==='development-acceptance@1')counts.accepted++;
    else if(attempt.status==='recorded')counts.awaiting++;
    else if(attempt.status==='needs_changes')counts.needsChanges++;
  }
  return counts;
}
export function initDevelopmentTasks({invoke,actions,current}){
  const root=node('section',undefined,'app-screen');root.dataset.screen='development-tasks';root.hidden=true;root.id='development-tasks';
  root.append(node('p','SUPER / DEVELOPMENT TASKS','eyebrow'),node('h1','Development tasks'),node('p','Keep a development plan, acceptance criteria and blocker history with its assigned bot. Plans do not start execution.','screen-description'));
  const scope=node('p','','availability-note'),all=node('button','Show all bots','subtle');all.type='button';
  const form=node('form',undefined,'bot-profile-form');form.id='development-task-form';
  const field=(label,control)=>{const wrap=node('label',label,'field');wrap.append(control);return wrap;};
  const lane=node('select');lane.id='task-lane';lane.required=true;
  const title=node('input');title.id='task-title';title.maxLength=80;title.required=true;
  const criteria=node('textarea');criteria.id='task-criteria';criteria.maxLength=1000;criteria.rows=4;criteria.required=true;
  const checks=node('fieldset');checks.id='task-required-checks';checks.append(node('legend','Required checks'),node('p','Choose at least one. These checks stay with this plan; create a new plan to change them.','directory-note'));
  const checkInputs=[['super-javascript-behavior@1','JavaScript'],['super-elixir-review@1','Elixir'],['super-rust-review@1','Rust']].map(([value,label],i)=>{const input=node('input');input.type='checkbox';input.value=value;input.checked=i===0;checks.append(field(label,input));return input;});
  const create=node('button','Create development plan','primary');create.type='submit';
  form.append(field('Assigned lane',lane),field('Task title',title),field('Acceptance criteria',criteria),checks,create);
  const notice=node('p','','bot-status');notice.setAttribute('role','status');
  const list=node('div');list.id='development-task-list';const details=node('section');details.id='development-task-detail';
  root.append(scope,all,notice,list,details,form);document.getElementById('workspace-canvas').append(root);
  let botFilter='',signature='',selection=null,pending=false,request=null,world=null,attemptSignature='';
  const button=(label,fn)=>{const b=node('button',label,'subtle');b.type='button';b.onclick=fn;return b;};
  const record=(label,kind,id)=>{const b=node('button',label,'subtle');b.type='button';b.dataset.recordOpen=kind+':'+id;return b;};
  function show(task){
    selection=task?{id:task.id,revision:task.revision,world:runtimeWorld(current)}:null;form.hidden=!!task;list.hidden=!!task;details.replaceChildren();if(!task)return;details.append(button('← All development plans',()=>show(null)));
    const p=heldProjection(current);details.append(node('h2',task.title),node('span',task.status,'status-chip'),node('p',task.criteria),node('p',`Plan ${task.id} · revision ${task.revision} · lane base: ${task.base_revision||'not selected'} (not a validated result)`,'availability-note'));
    details.append(node('p',task.required_checks?'Required checks: '+task.required_checks.profiles.map(p=>p.includes('javascript')?'JavaScript':p.includes('elixir')?'Elixir':'Rust').join(', '):'Legacy plan: no required checks selected. Every profile run must pass.','directory-note'));
    details.append(record('Open goal' ,'goal',task.goal_ref),record('Open lane','lane',task.lane_ref),record('Open repository','repository',task.repository_ref));
    const bot=p?.bots?.[task.bot_ref];if(bot)details.append(button('Open '+bot.name,()=>navigate('bot:'+bot.client_ref,true)));
    const progress=taskProgress(p,task),next=node('section',undefined,'attempt-checks');next.dataset.taskNextAction=task.id;
    next.append(node('h3','Next action'),node('p',progress.reason));
    if(progress.target)next.append(button(progress.label,()=>{
      if(progress.target==='prepare'){details.querySelector('#task-prepare-file')?.click();return;}
      const target=progress.target==='review'?[...details.querySelectorAll('[data-attempt-id]')].find(n=>n.dataset.attemptId===progress.attempt):details.querySelector(progress.target==='completion'?'#task-completion-reason':'#task-note');
      if(target){if(progress.target==='review')target.open=true;target.scrollIntoView({block:'center'});const focus=target.querySelector?.('summary')||target;focus.focus();}
    }));else next.append(node('p',progress.label));
    details.append(next);
    const editorPanel=node('section',undefined,'attempt-checks');editorPanel.id='task-editor-context';details.append(editorPanel);renderEditor();
    const sessionPanel=node('section',undefined,'attempt-checks');sessionPanel.id='task-provider-session';details.append(sessionPanel);renderSession();
    details.append(node('h3','Plan history'));
    for(const event of task.history)details.append(node('p',`${event.at} · ${event.status} · ${event.note}`,'availability-note'));
    renderAttempts(task);
    if(task.status==='completed'){details.append(node('h3','Plan completed'),node('p','This is your planning decision based on the linked accepted results. It does not certify later source changes.','availability-note'));const receipt=node('p',`Completed ${task.completion?.at??''} · Accepted reviews: ${(task.completion?.accepted_attempt_refs??[]).join(', ')}`,'directory-note');receipt.dataset.planCompletion=task.id;details.append(receipt);return;}
    if(task.status==='cancelled')return;
    const prepare=button('Prepare file request',()=>{const event=new CustomEvent('prepare-task-file',{cancelable:true,detail:{id:task.id,revision:task.revision,world:runtimeWorld(current)}});if(!document.dispatchEvent(event))notice.textContent='Reopen the latest plan and finish any current editor operation before preparing a file request.';});prepare.id='task-prepare-file';details.append(prepare);

    const complete=node('button','Mark plan complete','subtle');complete.type='button';complete.id='task-complete';
    const reason=node('input');reason.id='task-completion-reason';reason.maxLength=250;reason.placeholder='Explain why this plan is finished';reason.setAttribute('aria-label','Plan completion reason');
    const completionField=node('label','Completion reason','field');completionField.append(reason);
    const section=node('section',undefined,'attempt-checks');section.append(node('h3','Finish this plan'),node('p','Requires an accepted result for the current plan revision. Resolve other open reviews and test runs first.','directory-note'),completionField,complete);details.append(section);
    const finishRevision=task.revision;
    complete.onclick=async()=>{if(pending)return;if(!reason.value.trim()){notice.textContent='Explain why the plan is finished before completing it.';reason.focus();return;}if([...details.querySelectorAll('textarea')].some(n=>n.value)){notice.textContent='Save your unfinished review or planning note before completing the plan.';return;}await send('update',{task_ref:task.id,revision:finishRevision,status:'completed',note:reason.value},p=>p.development_tasks?.[task.id]?.status==='completed',()=>show(heldProjection(current)?.development_tasks?.[task.id]));};

    const update=node('form',undefined,'bot-profile-form');update.id='development-plan-update';const status=node('select');status.id='task-status';for(const s of ['planned','blocked','cancelled']){const o=node('option',s);o.value=s;status.append(o);}status.value=task.status;
    const note=node('textarea');note.id='task-note';note.required=true;note.maxLength=250;note.rows=3;
    const save=node('button','Save planning update','primary');save.type='submit';update.append(field('Planning status',status),field('Reason / progress note',note),save);details.append(update);
    const captured={...selection};
    update.onsubmit=async e=>{e.preventDefault();if(pending||!update.reportValidity())return;
      const latest=heldProjection(current)?.development_tasks?.[captured.id];
      if(runtimeWorld(current)!==captured.world||!latest||latest.revision!==captured.revision){notice.textContent='The task changed or the runtime disconnected. Reopen the task to review its latest state. Your note remains here.';return;}
      await send('update',{task_ref:captured.id,revision:captured.revision,status:status.value,note:note.value},p=>p.development_tasks?.[captured.id]?.revision===captured.revision+1,()=>show(heldProjection(current)?.development_tasks?.[captured.id]));
    };
  }
  function renderEditor(){
    const panel=details.querySelector('#task-editor-context');if(!panel||!selection)return;
    const p=heldProjection(current),task=p?.development_tasks?.[selection.id],view=taskEditorView(p,task,runtimeWorld(current));
    panel.replaceChildren(node('h3','Editor context'),node('p',view.message,'availability-note'));
    if(view.state!=='linked')return;
    panel.append(node('p',view.root||'No repository selected','directory-note'));
    if(!view.files.length)panel.append(node('p','No open file tabs. Prepare a file request and choose a file.','availability-note'));
    for(const file of view.files){const row=node('div',undefined,'attempt-checks'),open=button(file.path,()=>{const event=new CustomEvent('open-task-editor-file',{cancelable:true,detail:{session:view.session,generation:view.generation,task:view.task,path:file.path}});if(!document.dispatchEvent(event))notice.textContent='The Editor context changed or is busy. Reopen the plan and try again.';});open.dataset.taskEditorFile=file.path;open.disabled=view.busy;row.append(open,node('p',[file.selected?'Selected tab':null,file.unsaved?'Unsaved draft':'No draft changes'].filter(Boolean).join(' · '),'directory-note'));panel.append(row);}
  }
  document.addEventListener('task-editor-changed',renderEditor);
  document.addEventListener('runtime-view-rendered',renderEditor);
  function renderSession(){
    const panel=details.querySelector('#task-provider-session');if(!panel||!selection)return;
    const p=heldProjection(current),task=p?.development_tasks?.[selection.id],view=taskSessionView(p,task,runtimeWorld(current));
    panel.replaceChildren(node('h3','Provider session'),node('p',view.label),node('p',view.detail,'availability-note'));
    const bot=p?.bots?.[task?.bot_ref];
    if(view.available&&bot)panel.append(button('Open conversation',()=>{navigate('bot:'+bot.client_ref,true);const event=new CustomEvent('open-task-conversation',{cancelable:true,detail:{botId:bot.client_ref}});if(!document.dispatchEvent(event))notice.textContent='Finish the current bot operation before opening this conversation.';}));
    if(view.available&&bot){const history=botConversationHistory(localStorage,bot.client_ref);const links=taskHistoryLinks(history,task.id,runtimeWorld(current));panel.append(node('h4','Saved task conversations'));
      if(history.error)panel.append(node('p',history.error,'availability-note'));
      else if(!links.length)panel.append(node('p','No linked conversation saved on this device yet. Share a plan-linked file to connect one.','availability-note'));
      for(const link of links){const row=node('div',undefined,'attempt-checks'),open=button(link.title,()=>{const world=runtimeWorld(current);navigate('bot:'+bot.client_ref,true);document.dispatchEvent(new CustomEvent('open-saved-task-conversation',{detail:{botId:bot.client_ref,taskId:task.id,world,conversationId:link.id,provider:link.provider}}));});open.dataset.taskConversation=link.id;row.append(open,node('p',`${link.provider} · plan revision ${link.revisions.join(', ')} · Saved on this device`,'directory-note'));panel.append(row);}
    }

  }
  document.addEventListener('task-session-changed',renderSession);
  function renderAttempts(task){
    const rows=Object.values(heldProjection(current)?.development_attempts??{}).filter(a=>a.task_ref===task.id);
    const section=node('section',undefined,'development-attempts');section.id='development-attempts';
    section.append(node('h3',`Review attempts (${rows.length})`),node('p','Retained review material and human notes. Recording does not save a file, run checks or accept a result.','directory-note'));
    if(!rows.length)section.append(node('p','Open a plan-linked file proposal and choose Save review attempt to retain it here.','availability-note'));
    for(const attempt of rows){
      const combined=attempt.schema==='development-review-set@1';
      const card=node('details',undefined,'development-attempt');card.dataset.attemptId=attempt.id;
      card.append(node('summary',`${combined?attempt.files.length+' files · Combined review':attempt.source.path} · ${attempt.status.replaceAll('_',' ')} · ${attempt.id}`));
      card.append(node('p',`Recorded against plan revision ${attempt.task_revision}; current plan revision ${task.revision}. Review revision ${attempt.revision}.`,'availability-note'),node('p',attempt.criteria));
      const material=node('details');material.append(node('summary','Retained source and proposed text'));
      const retained=combined?attempt.files:[attempt];
      for(const row of retained){const file=node('section');file.dataset.retainedFile=row.source.path;file.append(node('h4',row.source.path));for(const [label,text] of [['Shared draft',row.shared_draft],[row.proposed_text===null?'Delete file':'Proposed text',row.proposed_text===null?'This reviewed result removes the file.':row.proposed_text]])file.append(node('h4',label),node('pre',text,'attempt-text'));material.append(file);}

      const source=node('details');source.append(node('summary','Recorded source identities'),node('pre',JSON.stringify(attempt.source,null,2),'attempt-text'));material.append(source);card.append(material);
      if(combined)card.append(node('p','Combined review retained. Tests apply every replacement to one snapshot. Acceptance checks all saved files against that tested snapshot.','availability-note'));
      else {
      const checks=node('section',undefined,'attempt-checks');checks.id='attempt-checks-'+attempt.id;
      checks.append(node('h4','Proposed-text checks'),node('p','Checks cover this retained proposal only. App tests were not run. Changes in the editor or other files are not covered.','directory-note'));
      if(attempt.text_check){
        const result=attempt.text_check;
        checks.append(node('p',result.outcome==='pass'?'Text checks passed':'Text checks found issues','availability-note'));
        for(const check of result.checks)checks.append(node('p',`${check.label}: ${check.outcome.replaceAll('_',' ')}. ${check.message}${check.count?' '+check.count+' finding(s). Lines: '+check.lines.join(', '):''}`));
        checks.append(node('p',`Checked ${result.at} · ${result.result_bytes} bytes`,'directory-note'));
        const identity=node('details');identity.append(node('summary','Exact checked result'),node('pre',result.result_sha256,'attempt-text'));checks.append(identity);
      }else if(!['cancelled','completed'].includes(task.status)&&!['dismissed','accepted'].includes(attempt.status)){
        const check=button('Check proposed text',async()=>{
          if(pending)return;
          if([...details.querySelectorAll('textarea')].some(n=>n.value)){notice.textContent='Save your draft note before checking; your note is preserved.';return;}
          const latest=heldProjection(current)?.development_attempts?.[attempt.id];
          if(!latest||latest.revision!==attempt.revision){notice.textContent='The review changed. Reopen it before checking.';return;}
          await send('checkAttempt',{attempt_ref:attempt.id,revision:attempt.revision},p=>!!p.development_attempts?.[attempt.id]?.text_check,()=>{show(heldProjection(current)?.development_tasks?.[task.id]);details.querySelector(`[data-attempt-id="${attempt.id}"]`).open=true;});
        });check.id='attempt-check-'+attempt.id;checks.append(check);
      }else checks.append(node('p','No text checks were recorded.','availability-note'));
      card.append(checks);
      }
      card.append(reviewTestPanel({attempt,invoke,current,acceptResult:actions.accept,readOnly:['cancelled','completed'].includes(task.status)}));
      if(attempt.acceptance){
        const accepted=node('section',undefined,'attempt-checks');accepted.dataset.acceptedAttempt=attempt.id;
        accepted.append(node('h4','Accepted tested result'),node('p',attempt.acceptance.note),node('p','Accepted: '+attempt.acceptance.accepted_at,'directory-note'),node('p','Test run: '+attempt.acceptance.run_id,'directory-note'),node('p','Tested snapshot: '+attempt.acceptance.snapshot_sha256,'directory-note'),node('p','This decision covers the saved proposal and captured test snapshot. Later edits are not covered, and the plan is not automatically completed.','availability-note'));if(attempt.acceptance.profile_run_refs)for(const [profile,run] of Object.entries(attempt.acceptance.profile_run_refs))accepted.append(node('p','Covered profile: '+profile+' · '+run,'directory-note'));card.append(accepted);if(!['cancelled','completed'].includes(task.status)&&task.revision===attempt.task_revision)accepted.append(acceptedResultCheck({attempt,invoke,current}),acceptedBuildPanel({attempt,invoke,current}));
      }
      card.append(node('h4','Review history'));
      for(const event of attempt.history)card.append(node('p',`${event.at} · ${event.status.replaceAll('_',' ')} · ${event.note}`,'availability-note'));
      if(!['cancelled','completed'].includes(task.status)&&!['dismissed','accepted'].includes(attempt.status)){
        const form=node('form',undefined,'bot-profile-form'),status=node('select'),note=node('textarea');status.id='attempt-status-'+attempt.id;note.id='attempt-note-'+attempt.id;note.required=true;note.maxLength=250;note.rows=3;
        for(const value of ['recorded','needs_changes','dismissed']){const option=node('option',value.replaceAll('_',' '));option.value=value;status.append(option);}status.value=attempt.status;
        const save=node('button','Save review note','primary');save.type='submit';form.append(field('Review status',status),field('Reason / review note',note),save);card.append(form);
        form.onsubmit=async event=>{event.preventDefault();if(pending||!form.reportValidity())return;
          const latest=heldProjection(current)?.development_attempts?.[attempt.id];
          if(!latest||latest.revision!==attempt.revision){notice.textContent='The review changed. Reopen the plan before saving this note.';return;}
          await send('updateAttempt',{attempt_ref:attempt.id,revision:attempt.revision,status:status.value,note:note.value},p=>p.development_attempts?.[attempt.id]?.revision===attempt.revision+1,()=>{show(heldProjection(current)?.development_tasks?.[task.id]);details.querySelector(`[data-attempt-id="${attempt.id}"]`).open=true;});
        };
      }else card.append(node('p',attempt.status==='accepted'?'Accepted result retained as read-only history. Record a fresh proposal for further changes.':'Dismissed review retained as read-only history. Record a fresh proposal to continue.','directory-note'));
      section.append(card);
    }
    details.append(section);
  }
  async function send(intent,args,confirmed,done){
    const origin=runtimeWorld(current);pending=true;refresh();notice.textContent=intent==='checkAttempt'?'Checking retained proposed text…':'Saving…';
    try{if(!await actions[intent](args))throw Error('The runtime refused this change. Check Activity; your form is preserved.');await waitForBot(current,origin,confirmed);notice.textContent='Saved in the runtime.';done();}
    catch(e){notice.textContent=String(e.message||e);}finally{pending=false;signature='';refresh();}
  }
  form.onsubmit=async e=>{e.preventDefault();if(pending||!form.reportValidity()||!heldProjection(current))return;
    const profiles=checkInputs.filter(i=>i.checked).map(i=>i.value);if(!profiles.length){notice.textContent='Choose at least one required check.';return;}
    const content={lane_ref:lane.value,title:title.value,criteria:criteria.value,required_checks:{profiles}},key=JSON.stringify([runtimeWorld(current),content]);
    if(request?.key!==key)request={key,client_ref:crypto.randomUUID()};
    const ref=request.client_ref;
    await send('create',{client_ref:ref,...content},p=>Object.values(p.development_tasks??{}).some(t=>t.client_ref===ref),()=>{title.value='';criteria.value='';request=null;show(Object.values(heldProjection(current)?.development_tasks??{}).find(t=>t.client_ref===ref));});
  };
  function refresh(){
    const p=heldProjection(current),nextWorld=runtimeWorld(current),ws=selectedWorkspace();
    const badge=document.querySelector('[data-nav-count=development-tasks]');if(badge){badge.hidden=!p;badge.textContent=p?String(taskScope(p,ws).filter(t=>!['cancelled','completed'].includes(t.status)).length):'';badge.title='Open development plans in the selected workspace';}
    if(world!==nextWorld){world=nextWorld;show(null);request=null;}
    form.querySelectorAll('input,textarea,select,button').forEach(c=>c.disabled=pending||!p);
    details.querySelectorAll('input,textarea,select,button').forEach(c=>c.disabled=pending||!p);
    if(!p){signature='';list.replaceChildren(node('p','Runtime unavailable. Reconnect to view current development plans.','availability-note'));details.hidden=true;lane.replaceChildren();scope.textContent='Runtime unavailable';return;}
    details.hidden=false;
    const nextAttempts=JSON.stringify([p.development_tasks,p.development_attempts]);
    if(nextAttempts!==attemptSignature){attemptSignature=nextAttempts;if(selection&&!pending&&![...details.querySelectorAll('textarea')].some(n=>n.value)){const opened=[...details.querySelectorAll('[data-attempt-id][open]')].map(n=>n.dataset.attemptId);show(p.development_tasks?.[selection.id]);for(const id of opened){const card=details.querySelector(`[data-attempt-id="${id}"]`);if(card)card.open=true;}}}

    const next=JSON.stringify([world,ws,botFilter,p.development_tasks,p.development_attempts,p.lanes,p.goals,p.bots]);if(next===signature)return;signature=next;
    scope.textContent=(ws?'Selected workspace':'All workspaces')+(botFilter?' · selected bot':'');all.hidden=!botFilter;
    const previous=lane.value;lane.replaceChildren();
    for(const l of Object.values(p.lanes??{})){const bot=Object.values(p.bots??{}).find(b=>b.actor===l.actor),goal=p.goals?.[l.goal_ref];if(!bot||!goal||(ws&&goal.workspace_ref!==ws)||(botFilter&&bot.client_ref!==botFilter))continue;const o=node('option',`${goal.title} · ${bot.name} · Lane ${l.id.split('_').at(-1)}`);o.value=l.id;lane.append(o);}
    if([...lane.options].some(o=>o.value===previous))lane.value=previous;
    create.disabled=pending||!lane.options.length;
    const rows=taskScope(p,ws,botFilter);list.replaceChildren(node('h2',`Plans (${rows.length})`));
    if(!lane.options.length)list.append(node('p','Create a goal and repository lane for a registered bot to plan development work.','availability-note'));
    for(const task of rows){
      const row=node('article',undefined,'bot-work-lane');
      const counts=taskReviewCounts(p,task.id);
      const summary=node('p',`${counts.accepted} accepted · ${counts.awaiting} awaiting decision · ${counts.needsChanges} need changes`,'availability-note');summary.dataset.taskReviewSummary=task.id;
      row.append(button(task.title,()=>show(task)),node('span',task.status,'status-chip'),summary,node('p',taskProgress(p,task).label,'availability-note'));list.append(row);
    }
    if(selection&&!rows.some(t=>t.id===selection.id)){show(null);}
  }
  all.onclick=()=>{botFilter='';signature='';refresh();};
  document.addEventListener('click',e=>{const b=e.target.closest('[data-development-task]');if(!b)return;const task=heldProjection(current)?.development_tasks?.[b.dataset.developmentTask];if(!task)return;botFilter='';signature='';refresh();show(task);navigate('development-tasks',true);});
  document.addEventListener('open-development-tasks',e=>{botFilter=e.detail?.bot||'';signature='';refresh();navigate('development-tasks',true);});
  document.addEventListener('runtime-view-rendered',refresh);document.addEventListener('workspace-view-change',()=>{show(null);refresh();});
  new MutationObserver(refresh).observe(document.getElementById('world'),{childList:true});refresh();
}
