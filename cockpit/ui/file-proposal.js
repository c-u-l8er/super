// File proposals are tied to the exact Editor snapshot shared in this page session.
export function checkFileProposal(reference, proposal, current){
  if(!reference||typeof reference.draft!=='string')throw Error('Share this file from Editor and request a fresh proposal before reviewing it.');
  if(reference.session!==current.session||reference.generation!==current.generation||reference.key!==proposal.path||current.file?.path!==reference.key)throw Error('The linked file or repository changed. Share the file again.');
  if(reference.task&&(!current.task||current.world!==reference.task.world||current.task.id!==reference.task.id||current.task.revision!==reference.task.revision||['cancelled','completed'].includes(current.task.status)))throw Error('The development plan changed or is unavailable. Share the latest plan and file again.');
  if(current.file.draft!==reference.draft)throw Error('Your draft changed after it was shared. Share the latest version before applying a proposal.');
  if(proposal.content===null){if(typeof reference.original!=='string')throw Error('Only an existing file can be deleted.');return null;}
  if(typeof proposal.content!=='string'||proposal.content.includes('\0')||new TextEncoder().encode(proposal.content).length>32000)throw Error('The proposed file is invalid or too large.');
  return proposal.content;
}
