// Resuming a saved review after a restart, without asking a bot again.
//
// The bytes a review names are already recorded: inline in the record for the
// older shape, or published by digest and read back through the `review_content`
// host command for the staged shape. Asking the provider again costs a call and
// can return a different proposal — so this rebuilds the review dialog's items
// from the record instead. For a combined review "Stage all drafts" and "Apply
// staged change set" are then the same controls, running the same checks, as
// for a proposal that arrived a moment ago; for a single-file review (added
// 2026-09-18, after a driver had to write the reviewed bytes by hand) it is the
// single-file dialog's own "Use as editor draft", pinned to the same source
// basis, and Save in the Editor is still the step that writes.
//
// Nothing here writes. A resumed review yields unsaved Editor drafts; the write
// stays behind the explicit apply control, which re-verifies the plan and every
// file basis against the repository chosen NOW. Retained content does not carry
// permission to write with it.
//
// Pure: the caller supplies the record, the plan, the bodies, the file states and
// the hashes, and gets back items `checkProposalSet` accepts — or a refusal that
// names the file and the fact.

const SHA=/^[0-9a-f]{64}$/;
const short=d=>typeof d==='string'?d.slice(0,12):String(d);

/** A review that is still open on a plan that is still open; every refusal names the fact. */
function openReview(attempt,task){
  if(!attempt)throw Error('This review is no longer in the runtime projection. Reopen the plan.');
  if(['accepted','dismissed'].includes(attempt.status))throw Error(`Review ${attempt.id} is ${attempt.status} and retained as history. Record a fresh proposal for further changes.`);
  if(!task||task.id!==attempt.task_ref)throw Error('The plan this review belongs to is no longer available.');
  if(['cancelled','completed'].includes(task.status))throw Error(`Plan ${task.id} is ${task.status}. Its reviews are history and cannot be staged.`);
}
/** One retained member — a set row, or the single-file record itself — as the staging steps read it. */
function retainedMember(row){
  const s=row?.source;
  if(!s||typeof s.path!=='string'||!SHA.test(s.draft_sha256??'')||(s.disk_sha256!==null&&!SHA.test(s.disk_sha256??''))||!SHA.test(s.basis_id??''))throw Error(`${s?.path??'A retained member'}: the retained source basis is incomplete. It cannot be staged.`);
  const deletion=s.schema==='selected-file-deletion-basis@1';
  if(!deletion&&!SHA.test(s.result_sha256??''))throw Error(`${s.path}: the retained member names no proposed result.`);
  if(deletion&&s.disk_sha256===null)throw Error(`${s.path}: a deletion needs an existing file.`);
  const inline=typeof row.shared_draft==='string'?{current:row.shared_draft,proposed:deletion?null:row.proposed_text}:null;
  return {path:s.path,source:s,deletion,inline};
}

/** The retained members of a combined review that may still be staged. */
export function savedReviewSet(attempt,task){
  if(attempt&&(attempt.schema!=='development-review-set@1'||!Array.isArray(attempt.files)))throw Error('Only a combined review is staged from its retained members. A single-file review is staged through its own dialog.');
  openReview(attempt,task);
  if(attempt.files.length<2||attempt.files.length>4)throw Error('A combined review holds two to four files.');
  const members=attempt.files.map(retainedMember);
  if(new Set(members.map(m=>m.path)).size!==members.length)throw Error('The retained review names one file twice.');
  return members;
}

/**
 * The retained single-file review that may still be staged, as a one-member
 * list so the same body read and the same repository check apply. A
 * single-file review never deletes — the single-file dialog refuses a null
 * proposal — so a deletion basis is refused here by name.
 */
export function savedReviewFile(attempt,task){
  if(attempt&&(attempt.schema!=='development-review-attempt@1'||Array.isArray(attempt.files)||!attempt.source))throw Error('Only a single-file review is staged this way. A combined review is staged from its retained members.');
  openReview(attempt,task);
  const m=retainedMember({source:attempt.source,shared_draft:attempt.shared_draft,proposed_text:attempt.proposed_text});
  if(m.deletion)throw Error(`${m.path}: a single-file review cannot stage a deletion. Review it together with a related file.`);
  return [m];
}

/**
 * Every body the review names, checked against the digest that names it.
 *
 * `read(digest)` is the host read — it re-hashes and tells missing from corrupt
 * — and `sha256(text)` is the page's own hash, so the page does not take the
 * host's word for bytes it is about to put in front of a person. A body that
 * cannot be read or does not hash to its name refuses the whole review: half a
 * set is not a set.
 */
export async function savedReviewBodies(members,read,sha256){
  const bodies=[];
  for(const m of members){
    const side=async(label,digest,inline)=>{
      let text;
      try{text=inline!==undefined?inline:await read(digest);}
      catch(e){throw Error(`${m.path}: ${String(e.message||e)}`);}
      if(typeof text!=='string')throw Error(`${m.path}: the ${label} text could not be read.`);
      if(await sha256(text)!==digest)throw Error(`${m.path}: the ${label} text does not match its digest ${short(digest)}. It cannot be staged.`);
      return text;
    };
    const current=await side('reviewed current',m.source.draft_sha256,m.inline?.current);
    const proposed=m.deletion?null:await side('proposed',m.source.result_sha256,m.inline?.proposed);
    bodies.push({path:m.path,current,proposed});
  }
  return bodies;
}

/**
 * One member against the file as the Editor sees it now.
 *
 * `file` is `{original, draft}` — `original` the bytes on disk (null when the
 * file is absent) and `draft` the open tab's text (the same as `original` when
 * no tab is open); `originalSha256` is the hash of `original`, null when absent.
 * The recorded `disk_sha256` is what the file hashed to when it was reviewed:
 * a file that changed since, or that appeared where a new file was reviewed,
 * or that vanished, is refused by name. An unsaved edit in the Editor that is
 * not the review's own shared draft is a conflict, not something to overwrite.
 */
export function savedReviewItem(m,body,file,originalSha256,{session,generation,task}){
  const s=m.source,absent=file.original===null||file.original===undefined;
  if(s.disk_sha256===null){
    if(!absent)throw Error(`${m.path} was reviewed as a new file but now exists in the repository (${short(originalSha256)}). Prepare a fresh review.`);
  }else{
    if(absent)throw Error(`${m.path} no longer exists in the repository. It was reviewed at ${short(s.disk_sha256)}. Prepare a fresh review.`);
    if(originalSha256!==s.disk_sha256)throw Error(`${m.path} changed on disk since it was reviewed (now ${short(originalSha256)}, reviewed at ${short(s.disk_sha256)}). Prepare a fresh review.`);
  }
  const saved=absent?'':file.original;
  if(file.draft!==saved&&file.draft!==body.current)throw Error(`${m.path} has unsaved edits in the Editor. Save or reload it before staging the saved review.`);
  const reference={kind:'editor',key:m.path,generation,title:m.path,original:absent?null:file.original,draft:body.current,session,task:{id:task.id,revision:task.revision,world:task.world},source:s};
  return {reference,proposal:{path:m.path,content:body.proposed}};
}

/** All members, in the record's order. `filesByPath` maps path → `{original, draft, originalSha256}`. */
export function savedReviewItems(members,bodies,filesByPath,context){
  return members.map(m=>{
    const body=bodies.find(b=>b.path===m.path),file=filesByPath.get(m.path);
    if(!body||!file)throw Error(`${m.path}: not every file was read before staging.`);
    return savedReviewItem(m,body,{original:file.original,draft:file.draft},file.originalSha256,context);
  });
}
