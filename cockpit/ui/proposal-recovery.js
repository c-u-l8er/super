import {REVIEW_FILE_BYTES,bytesOf} from './review-limits.js';
import {applyFilePatch,validatePatchRecord} from './file-patch.js';
import {isBodyRef,validBodyRef} from './conversation-bodies.js';
// A bot proposal survives a restart only as a RECOVERY RECORD: the target path, the exact proposed
// content, the shared draft and original it was made against, the `selected-file-basis@1` record
// the host produced at share time, and the plan link. A proposal recorded without a basis is kept
// as history and can never be applied — the basis is historical evidence and is not manufactured.
export const RECOVERY_SCHEMA='proposal-recovery@1';
const BASIS_SCHEMA='selected-file-basis@1';
function text(v,max,what){if(typeof v!=='string'||v.includes('\0')||bytesOf(v)>max)throw Error(`Invalid recovery ${what}.`);return v;}
export function validateBasis(b){
  if(!b||typeof b!=='object'||b.schema!==BASIS_SCHEMA)throw Error('Invalid recovery basis.');
  const out={schema:BASIS_SCHEMA,basis_id:text(b.basis_id,128,'basis id'),head:text(b.head,128,'basis head'),path:text(b.path,512,'basis path'),draft_sha256:text(b.draft_sha256,128,'basis draft digest')};
  if(b.disk_sha256!==null&&b.disk_sha256!==undefined)out.disk_sha256=text(b.disk_sha256,128,'basis disk digest');else out.disk_sha256=null;
  return out;
}
export function validateRecovery(r){
  if(!r||typeof r!=='object'||r.schema!==RECOVERY_SCHEMA)throw Error('Invalid proposal recovery record.');
  const out={schema:RECOVERY_SCHEMA,path:text(r.path,512,'path'),content:r.content===null?null:text(r.content,REVIEW_FILE_BYTES,'content'),draft:text(r.draft,REVIEW_FILE_BYTES,'draft'),original:r.original===null?null:text(r.original,REVIEW_FILE_BYTES,'original'),source:validateBasis(r.source),task:null};
  if(out.path.startsWith('/')||out.path.split('/').some(s=>!s||s==='.'||s==='..'))throw Error('Invalid recovery path.');
  if(out.source.path!==out.path)throw Error('Recovery basis names a different file.');
  if(r.task!==null&&r.task!==undefined){const t=r.task;if(typeof t.id!=='string'||!Number.isSafeInteger(t.revision)||t.revision<1||typeof t.world!=='string')throw Error('Invalid recovery plan link.');out.task={id:text(t.id,100,'plan id'),revision:t.revision,world:text(t.world,500,'plan world')};}
  /* dt_0138: a proposal shared without a plan records the repository root it was shared from, so after a restart it
     is offered only in that repository. A plan-linked proposal is bound by its plan instead. */
  if(r.root!==null&&r.root!==undefined)out.root=text(r.root,4096,'repository');
  /* T22b: a proposal that arrived as a patch keeps the patch exactly as sent. The record is then
     self-verifying: the patch applied to the recorded draft must give the recorded content, or the
     record is refused whole. A record without a patch keeps T22a's shape exactly. */
  if(r.patch!==null&&r.patch!==undefined){
    out.patch=validatePatchRecord(r.patch);
    let derived;try{derived=applyFilePatch(out.draft,out.patch.edits);}catch{throw Error('Recovery patch does not apply to its recorded draft.');}
    if(out.content===null||derived!==out.content)throw Error('Recovery patch does not reproduce its recorded content.');
  }
  return out;
}
/* T24: a saved record whose bodies are references to the device body store. Everything but the bodies is
   validated exactly as validateRecovery does; the bodies are validated as references. The patch's self-verification
   needs the bytes, so it runs when the bodies are resolved — validateRecovery on the resolved record — and a record
   whose bodies are all inline is validated whole, here, exactly as before. */
export function validateRecoveryShape(r){
  if(!r||typeof r!=='object'||r.schema!==RECOVERY_SCHEMA)throw Error('Invalid proposal recovery record.');
  if(![r.content,r.draft,r.original].some(isBodyRef))return validateRecovery(r);
  const body=(v,nullable,what)=>v===null&&nullable?null:isBodyRef(v)?validBodyRef(v):text(v,REVIEW_FILE_BYTES,what);
  const out={schema:RECOVERY_SCHEMA,path:text(r.path,512,'path'),content:body(r.content,true,'content'),draft:body(r.draft,false,'draft'),original:body(r.original,true,'original'),source:validateBasis(r.source),task:null};
  if(out.path.startsWith('/')||out.path.split('/').some(s=>!s||s==='.'||s==='..'))throw Error('Invalid recovery path.');
  if(out.source.path!==out.path)throw Error('Recovery basis names a different file.');
  if(r.task!==null&&r.task!==undefined){const t=r.task;if(typeof t.id!=='string'||!Number.isSafeInteger(t.revision)||t.revision<1||typeof t.world!=='string')throw Error('Invalid recovery plan link.');out.task={id:text(t.id,100,'plan id'),revision:t.revision,world:text(t.world,500,'plan world')};}
  if(r.root!==null&&r.root!==undefined)out.root=text(r.root,4096,'repository');
  if(r.patch!==null&&r.patch!==undefined){out.patch=validatePatchRecord(r.patch);if(out.content===null)throw Error('Recovery patch does not reproduce its recorded content.');}
  return out;
}
/* From a live Editor reference and the bot's proposal to the record that is saved beside the card.
   Returns null when the share carried no basis: such a proposal is not recoverable, and saying so is
   the point. */
export function recoveryRecord(reference,proposal,patch=null){
  if(!reference||reference.kind!=='editor'||typeof reference.draft!=='string'||!reference.source)return null;
  if(!proposal||proposal.path!==reference.key)return null;
  try{return validateRecovery({schema:RECOVERY_SCHEMA,path:reference.key,content:proposal.content,draft:reference.draft,original:reference.original??null,source:reference.source,task:reference.task??null,...(typeof reference.root==='string'?{root:reference.root}:{}),...(patch?{patch}:{})});}
  catch{return null;}
}
/* Why a saved proposal cannot be applied — the explanation a card shows instead of a Review button. */
export function unavailableReason(saved){
  if(typeof saved==='string')return 'Saved before proposals kept their original basis · cannot be applied. Ask the assistant for a fresh proposal.';
  if(!saved||!saved.recovery)return 'Saved without its original basis · cannot be applied. Ask the assistant for a fresh proposal.';
  return null;
}
/* The reference a recovered proposal is reviewed under. It is NOT yet bound to a page session: the
   Editor binds it after the host re-verifies the file on disk against the recorded basis. */
export function recoveredReference(record){
  const r=validateRecovery(record);
  return {kind:'editor',key:r.path,title:r.path,original:r.original,draft:r.draft,source:r.source,task:r.task,root:r.root??null,recovered:true,recordedSource:r.source};
}
/* The one check that keeps a recovered proposal honest: the file on disk today must be the file the
   proposal was made against. `head` and `basis_id` move with any commit and are not compared; the
   disk digest and the path are. A missing disk digest (the file did not exist) must still match. */
export function checkRecoveredBasis(record,basis){
  const r=validateRecovery(record);
  if(!basis||basis.schema!==BASIS_SCHEMA)throw Error('The repository did not return a file basis. Reopen the repository and try again.');
  if(basis.path!==r.path)throw Error('The repository returned a basis for a different file. Nothing was applied.');
  if((basis.disk_sha256??null)!==(r.source.disk_sha256??null))throw Error('This proposal is outdated: the file on disk no longer matches the version it was proposed against. Applying it would replace newer work. Nothing has been written.');
  return basis;
}
/* dt_0138 · a proposal is made against ONE version of its file: `original`, the file as the Editor last read or saved
   it (null when it did not exist), and, when the share carried it, `draft`, the exact text the assistant was shown.
   Before a proposal becomes an Editor draft, and again before Save writes it, the open tab and the file on disk must
   still hold that version. Returns null, or the explanation a person is shown. Pure: the caller reads the tab and the
   disk. A side passed as undefined was not read and is not judged; `unreadable` is why the disk could not be read. */
export function proposalBasisProblem(basis,{tab,disk,unreadable}={}){
  const path=basis?.key??basis?.path??'The file',original=basis?.original??null,draft=typeof basis?.draft==='string'?basis.draft:undefined;
  const outdated=`This proposal is outdated: ${path} no longer matches the version it was proposed against. Applying it would replace newer work. Nothing has been written and the newer content is kept. Ask the assistant for a fresh proposal.`;
  if(tab!==undefined){
    if(!tab)return `${path} is not open in the Editor. Open it, then review this proposal again. Nothing has been written.`;
    if((tab.original??null)!==original){
      /* The shared unsaved draft was saved exactly as shared: the text the assistant saw is on disk, but the proposal
         is pinned to the version before that save. Refused with that reason; it is not called outdated. */
      if(draft!==undefined&&draft!==original&&tab.original===draft)return `${path} was saved after it was shared: the unsaved draft the assistant saw is now on disk. This proposal is tied to the version before that save, so it cannot be applied. Nothing has been written. Share the file again for a fresh proposal.`;
      return outdated;
    }
    if(draft!==undefined&&tab.draft!==draft)return outdated;
  }
  if(typeof unreadable==='string'&&original!==null)return `This proposal is outdated: ${path} can no longer be read as the text it was proposed against (${unreadable}). It may have been deleted, moved or replaced. Nothing has been written and the file is left as it is. Ask the assistant for a fresh proposal.`;
  if(disk!==undefined&&(disk??null)!==original)return outdated;
  return null;
}
/* A plan link records the world as [incarnation, generation, projection_epoch]; the epoch is a
   per-process value, so no recorded link can equal the world after a restart. Recovery rebinds the
   link to the current world ONLY when the world itself — incarnation and generation — is the same;
   a different world is a different world and the proposal stays refused. */
export function rebindTaskWorld(recorded,current){
  let r,c;try{r=JSON.parse(recorded);c=JSON.parse(current);}catch{throw Error('The proposal\'s plan link is unreadable. Ask the assistant for a fresh proposal.');}
  if(!Array.isArray(r)||!Array.isArray(c)||r.length<2||c.length<2)throw Error('The proposal\'s plan link is unreadable. Ask the assistant for a fresh proposal.');
  if(r[0]!==c[0]||r[1]!==c[1])throw Error('This proposal was made in a different world (runtime incarnation or generation changed). It cannot be applied here.');
  return current;
}
