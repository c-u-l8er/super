import {codeEditor} from './vendor/code-editor.js';
import {proposalChanges,displayLine} from './proposal-changes.js';
import {checkProposalSet,prepareProposalSet,proposalSetMaterial} from './file-proposal-set.js';
export function reviewProposalSet({items,current,verify,stage,record,navigate,el,button}){
  if(document.querySelector('#bot-file-review,#bot-file-set-review'))throw Error('Finish the current file review first.');
  checkProposalSet(items,current);navigate('editor');
  const dialog=el('dialog',undefined,'file-proposal-review');dialog.id='bot-file-set-review';
  dialog.append(el('h2',`Review ${items.length} files together`),el('p','Inspect each replacement or deletion, then stage all drafts together. Files remain unsaved. Save combined review keeps both versions on the plan. Open the saved review on the plan to test the complete set and review acceptance.','directory-note'));
  const list=el('div',undefined,'connection-row'),body=el('section'),host=el('div'),views=[];
  let selected=0;
  function show(index){
    selected=index;for(const v of views.splice(0))v.destroy();body.replaceChildren();
    for(const [i,b] of [...list.children].entries())b.setAttribute('aria-pressed',String(i===index));
    const {reference,proposal}=items[index],diff=proposalChanges(reference.draft,proposal.content??'');
    body.append(el('h3',proposal.path+(proposal.content===null?' — DELETE FILE':'')),el('p',proposal.content===null?'File will be deleted':diff.unchanged?'No changes':`${diff.added} added · ${diff.removed} removed${diff.coarse?' · whole changed block':''}`));
    const summary=el('section',undefined,'proposal-diff');
    for(const row of diff.rows){const line=el('div',undefined,'proposal-diff-line '+row.kind);line.append(el('span',row.oldLine??'','diff-line-number'),el('span',row.newLine??'','diff-line-number'),el('code',(row.kind==='added'?'+ ':row.kind==='removed'?'- ':'  ')+displayLine(row.text)));summary.append(line);}
    if(diff.truncated)summary.append(el('p',`${diff.omitted} lines omitted. Complete drafts are below.`,'directory-note'));
    body.append(summary);host.replaceChildren();host.className='file-proposal-columns';
    for(const [label,text] of [['Shared draft',reference.draft],[proposal.content===null?'File will be deleted':'Proposed draft',proposal.content??'']]){const pane=el('section'),code=el('div',undefined,'file-proposal-code');pane.append(el('h3',label),code);host.append(pane);const editor=codeEditor(code,()=>{},()=>{});editor.show(editor.state(proposal.path,text));editor.readonly(true);views.push(editor.view);}
    body.append(host);
  }
  items.forEach((item,i)=>{const b=button(item.proposal.path+(item.proposal.content===null?' (delete)':''),'',()=>show(i));b.dataset.proposalSetPath=item.proposal.path;list.append(b);});
  const status=el('p','All files will be checked again before staging.','availability-note');status.setAttribute('role','status');
  let working=false;
  const use=button('Stage all drafts','bot-file-set-stage',async()=>{
    if(working)return;working=true;use.disabled=true;if(save)save.disabled=true;status.textContent='Checking all shared files…';
    try{const drafts=await prepareProposalSet(items,current,verify,()=>dialog.open);if(!dialog.open)return;stage(drafts);dialog.close();}
    catch(e){if(dialog.open)status.textContent=String(e.message||e);}
    finally{working=false;if(dialog.open){use.disabled=false;if(save&&!saved)save.disabled=false;}}
  });
  let saved=false;
  const save=record?button('Save combined review','bot-file-set-record',async()=>{
    if(working||saved)return;working=true;save.disabled=true;use.disabled=true;
    status.textContent='Checking every file before saving the combined review…';
    try{
      const material=await proposalSetMaterial(items,current,verify,()=>dialog.open);
      if(!dialog.open)return;
      const id=await record(material);saved=true;
      if(dialog.open){save.textContent='Combined review saved';status.textContent='Saved '+id+' on the plan. No drafts staged or files saved.';}
    }catch(e){if(dialog.open)status.textContent=String(e.message||e);}
    finally{working=false;if(dialog.open){use.disabled=false;save.disabled=saved;}}
  }):null;
  const actions=el('div',undefined,'connection-row file-proposal-actions');if(save)actions.append(save);actions.append(use,button('Cancel','bot-file-set-cancel',()=>dialog.close()));
  dialog.append(list,body,status,actions);document.body.append(dialog);show(selected);
  dialog.addEventListener('close',()=>{for(const v of views)v.destroy();dialog.remove();});dialog.showModal();
}
