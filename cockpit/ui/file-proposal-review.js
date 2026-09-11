import {codeEditor} from './vendor/code-editor.js';
import {proposalChanges,displayLine} from './proposal-changes.js';
import {checkFileProposal} from './file-proposal.js';
export function reviewFileProposal({reference,proposal,current,stage,verify,onIdentity,recordAttempt,navigate,el,button}){
  if(document.querySelector('#bot-file-review,#bot-file-set-review'))throw Error('Finish the current file review first.');
  if(proposal.content===null)throw Error('Review deletion together with its related file changes using Review files together.');
  checkFileProposal(reference,proposal,current());navigate('editor');
  const dialog=el('dialog',undefined,'file-proposal-review');dialog.id='bot-file-review';
  dialog.append(el('h2','Review bot edit · '+proposal.path),el('p','Compare the full drafts. Use as editor draft keeps the change unsaved; Save remains a separate step.','directory-note'));
  if(reference.task)dialog.append(el('p',`Development plan ${reference.task.id} · revision ${reference.task.revision}. The selected repository will be checked against this plan before staging. This is not validation or acceptance.`,'availability-note'));
  const identity=el('details',undefined,'proposal-source-record');identity.id='proposal-source-record';
  if(reference.source){identity.append(el('summary','Checking the source and result…'));dialog.append(identity);}
  const diff=proposalChanges(reference.draft,proposal.content),summary=el('section',undefined,'proposal-diff');summary.id='proposal-diff';
  summary.append(el('h3',diff.unchanged?'No changes':`${diff.added} added · ${diff.removed} removed${diff.coarse?' · whole changed block':''}`));
  if(diff.coarse)summary.append(el('p','This change is too large for detailed line matching. The changed block is shown as removed and added; some lines may be unchanged.','directory-note'));
  for(const row of diff.rows){const line=el('div',undefined,'proposal-diff-line '+row.kind);line.append(el('span',row.oldLine??'','diff-line-number'),el('span',row.newLine??'','diff-line-number'),el('code',(row.kind==='added'?'+ ':row.kind==='removed'?'- ':'  ')+displayLine(row.text)));summary.append(line);}
  if(diff.truncated)summary.append(el('p',`${diff.omitted} more lines omitted from this summary. Both complete drafts remain below.`,'availability-note'));
  summary.append(el('p','Line numbers: shared draft / proposed draft. Newline differences are shown explicitly.','directory-note'));dialog.append(summary);
  const columns=el('div',undefined,'file-proposal-columns'),views=[];
  for(const [title,text] of [['Shared draft',reference.draft],['Proposed draft',proposal.content]]){const pane=el('section'),host=el('div',undefined,'file-proposal-code');pane.append(el('h3',title),host);columns.append(pane);const editor=codeEditor(host,()=>{},()=>{});editor.show(editor.state(proposal.path,text));editor.readonly(true);views.push(editor.view);}
  const status=el('p','','availability-note');status.setAttribute('role','status');status.hidden=true;
  const actions=el('div',undefined,'connection-row file-proposal-actions');actions.append(button('Use as editor draft','bot-file-use-draft',async()=>{const use=dialog.querySelector('#bot-file-use-draft');if(recording)return;use.disabled=true;try{if(reference.task&&!verify)throw Error('Repository verification is unavailable. Reopen the plan and file.');checkFileProposal(reference,proposal,current());if(verify){status.hidden=false;status.textContent='Checking the selected repository…';await verify();}if(!dialog.open)return;const text=checkFileProposal(reference,proposal,current());stage(text);dialog.close();}catch(e){status.hidden=false;status.textContent=String(e);}finally{use.disabled=false;}}),button('Cancel','bot-file-cancel',()=>dialog.close()));
  let recording=false;
  if(reference.source&&recordAttempt){
    const saveAttempt=button('Save review attempt','bot-file-record-attempt',async()=>{
      if(recording)return;recording=true;saveAttempt.disabled=true;
      const use=dialog.querySelector('#bot-file-use-draft');use.disabled=true;
      try{
        checkFileProposal(reference,proposal,current());
        status.hidden=false;status.textContent='Checking source before saving the review record…';
        const source=await verify();if(!dialog.open)return;
        checkFileProposal(reference,proposal,current());
        const id=await recordAttempt(source);
        if(dialog.open){status.textContent='Saved review attempt '+id+'. Open the plan to see its retained drafts and add review notes. No file was saved.';saveAttempt.textContent='Review attempt saved';}
      }catch(error){if(dialog.open){status.hidden=false;status.textContent=String(error);saveAttempt.disabled=false;}}
      finally{recording=false;if(dialog.open)use.disabled=false;}
    });
    saveAttempt.disabled=true;actions.prepend(saveAttempt);
  }
  dialog.append(columns,status,actions);dialog.addEventListener('close',()=>{for(const view of views)view.destroy();dialog.remove();});document.body.append(dialog);dialog.showModal();
  if(reference.source){
    const use=dialog.querySelector('#bot-file-use-draft');use.disabled=true;
    Promise.resolve().then(()=>{if(!verify)throw Error('Source verification is unavailable.');return verify();}).then(record=>{
      if(!dialog.open)return;
      checkFileProposal(reference,proposal,current());
      identity.replaceChildren(el('summary',`Source pinned to ${record.head.slice(0,12)} · exact file and result recorded`),el('p','This record describes one file. Other working-tree files, validation and acceptance are not included.','directory-note'),el('pre',JSON.stringify(record,null,2)));
      if(onIdentity)onIdentity(record);use.disabled=false;const saveAttempt=dialog.querySelector('#bot-file-record-attempt');if(saveAttempt)saveAttempt.disabled=false;
    }).catch(error=>{if(dialog.open){identity.replaceChildren(el('summary','Source verification failed'));status.hidden=false;status.textContent=String(error);}});
  }
}
