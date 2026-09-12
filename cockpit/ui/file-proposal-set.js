import {checkFileProposal} from './file-proposal.js';
import {stageContent} from './review-content.js';
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

export async function proposalSetMaterial(items,current,verify,isOpen=()=>true,stage=null){
  const sources=[];
  await prepareProposalSet(items,current,async(r,text)=>sources.push(await verify(r,text)),isOpen);
  const members=items.map((item,i)=>({source:sources[i],draft:item.reference.draft,proposed:item.proposal.content}));
  // Without a `stage` the member carries its own bytes, which is the shape
  // recorded before content was published separately. It is still accepted by
  // the runtime and still bounded by the per-file caps that shape needs.
  if(!stage)return {files:members.map(m=>({source:m.source,shared_draft:m.draft,proposed_text:m.proposed}))};
  // Publish FIRST, then name. The record must never reference content that is
  // not yet stored, and the digests are the ones the source already carries -
  // draft_sha256 IS the current text's address, result_sha256 the proposed
  // text's - so a member cannot name one thing and carry another.
  for(const m of members){
    await stage(m.source.draft_sha256,m.draft);
    if(m.proposed!==null)await stage(m.source.result_sha256,m.proposed);
    if(!isOpen())throw Error('Review closed. Nothing was recorded.');
  }
  return {files:members.map(m=>({source:m.source}))};
}
