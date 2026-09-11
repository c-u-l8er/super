import {checkFileProposal} from './file-proposal.js';
// One response, one plan revision, one Editor session. This produces drafts only.
export function checkProposalSet(items,current){
  if(!Array.isArray(items)||items.length<2||items.length>4)throw Error('Review between two and four file edits together.');
  const paths=new Set(),first=items[0]?.reference;
  if(!first?.task||!first.source)throw Error('Prepare a development plan and share its related files before reviewing them together.');
  const identity=r=>JSON.stringify([r.session,r.generation,r.task?.id,r.task?.revision,r.task?.world,r.source?.head,r.source?.repository_ref]);
  return items.map(({reference:r,proposal:p})=>{
    if(!r?.source||!r.task||identity(r)!==identity(first))throw Error('All edits must come from the same plan, repository and shared source commit. Share the files again.');
    if(paths.has(p?.path))throw Error('The reply contains more than one edit for the same file. Request one replacement per file.');
    paths.add(p?.path);
    const state=current(r);
    const text=checkFileProposal(r,p,state);
    if(state.file.original!==r.original)throw Error('A file was saved or reloaded after sharing. Share the files again.');
    return {path:p.path,text};
  });
}
export async function prepareProposalSet(items,current,verify,isOpen=()=>true){
  checkProposalSet(items,current);
  // Recheck every selected file before returning any drafts. No mutation here.
  for(const item of items){try{await verify(item.reference,item.proposal.content);}catch(e){throw Error(item.proposal.path+': '+String(e.message||e));}if(!isOpen())throw Error('Review closed. No drafts were staged.');checkProposalSet(items,current);}
  return checkProposalSet(items,current);
}

export async function proposalSetMaterial(items,current,verify,isOpen=()=>true){
  const sources=[];
  await prepareProposalSet(items,current,async(r,text)=>sources.push(await verify(r,text)),isOpen);
  return {files:items.map((item,i)=>({source:sources[i],shared_draft:item.reference.draft,proposed_text:item.proposal.content}))};
}
