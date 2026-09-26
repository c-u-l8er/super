import {REVIEW_FILE_BYTES,bytesOf} from './review-limits.js';
/* T22b — a bounded patch proposal: exact replacements in the ONE snapshot a person shared.
 *
 * A full-content proposal must resend the whole file, and the provider schema caps that at 32 000
 * characters, so every file in this tree over that size could not be proposed at all. A patch names
 * only what changes. It is still applied to nothing but the exact shared snapshot, and what a person
 * accepts is exactly `applyFilePatch(snapshot, edits)` — a pure function of the snapshot and what the
 * bot sent, which a reader can recompute from the conversation record.
 *
 * The rules, each one refused by name rather than guessed around:
 *   · every `old_text` occurs EXACTLY ONCE in the snapshot (absent or repeated is refused — never
 *     "the nearest match", never "the first one");
 *   · edits are located in the snapshot the bot saw, not in the result of an earlier edit, and their
 *     spans must not overlap (touching is allowed);
 *   · all or nothing: one edit that does not apply refuses the patch;
 *   · bounded: 1–64 edits, at most 64 KiB of patch text, a result of at most REVIEW_FILE_BYTES.
 * The host checks the same shape and bounds (`cockpit/src/bots.rs`); this module is the one that knows
 * the snapshot, so application lives here. */
export const PATCH_SCHEMA='file-patch@1';
export const PATCH_MAX_EDITS=64;
export const PATCH_MAX_BYTES=64*1024;

// A string with a lone surrogate cannot be saved as the UTF-8 it claims to be, and a match that ends
// inside a surrogate pair would split a character. Well-formed texts can only match on whole characters.
function wellFormed(s){
  for(let i=0;i<s.length;i++){const c=s.charCodeAt(i);
    if(c>=0xd800&&c<=0xdbff){const d=s.charCodeAt(i+1);if(!(d>=0xdc00&&d<=0xdfff))return false;i++;}
    else if(c>=0xdc00&&c<=0xdfff)return false;}
  return true;
}
/* The shape alone: what a patch must look like before anyone knows which file it is for. Returns a
 * copy holding exactly {old_text,new_text} per edit. */
export function checkPatchEdits(edits){
  if(!Array.isArray(edits)||edits.length<1)throw Error('The patch has no edits.');
  if(edits.length>PATCH_MAX_EDITS)throw Error(`The patch has ${edits.length} edits; at most ${PATCH_MAX_EDITS} are allowed.`);
  let total=0;
  const out=edits.map((e,i)=>{
    const n=i+1;
    if(!e||typeof e!=='object'||Array.isArray(e)||Object.keys(e).length!==2||typeof e.old_text!=='string'||typeof e.new_text!=='string')throw Error(`Edit ${n} must have exactly old_text and new_text, both text.`);
    if(!e.old_text)throw Error(`Edit ${n} has empty old_text; it must quote the text it replaces.`);
    if(e.old_text.includes('\0')||e.new_text.includes('\0'))throw Error(`Edit ${n} contains a NUL character.`);
    if(!wellFormed(e.old_text)||!wellFormed(e.new_text))throw Error(`Edit ${n} contains a broken character (an unpaired surrogate).`);
    total+=bytesOf(e.old_text)+bytesOf(e.new_text);
    return {old_text:e.old_text,new_text:e.new_text};
  });
  if(total>PATCH_MAX_BYTES)throw Error(`The patch is ${total} bytes of text; at most ${PATCH_MAX_BYTES} are allowed.`);
  return out;
}
function occurrences(base,needle){const at=[];for(let i=base.indexOf(needle);i!==-1;i=base.indexOf(needle,i+1))at.push(i);return at;}
/* The patched text, or an Error that says which edit failed and why. `base` is the shared snapshot. */
export function applyFilePatch(base,edits){
  if(typeof base!=='string'||base.includes('\0')||!wellFormed(base))throw Error('The shared file is not text this patch can apply to.');
  const checked=checkPatchEdits(edits);
  const spans=checked.map((e,i)=>{
    const at=occurrences(base,e.old_text);
    if(at.length===0)throw Error(`Edit ${i+1} does not apply: its old_text is not in the shared file. Nothing was applied.`);
    if(at.length>1)throw Error(`Edit ${i+1} does not apply: its old_text occurs ${at.length} times in the shared file; it must quote enough surrounding text to occur once. Nothing was applied.`);
    return {n:i+1,start:at[0],end:at[0]+e.old_text.length,text:e.new_text};
  }).sort((a,b)=>a.start-b.start);
  for(let i=1;i<spans.length;i++)if(spans[i].start<spans[i-1].end)throw Error(`Edits ${Math.min(spans[i-1].n,spans[i].n)} and ${Math.max(spans[i-1].n,spans[i].n)} overlap in the shared file. Nothing was applied.`);
  let out='',from=0;
  for(const s of spans){out+=base.slice(from,s.start)+s.text;from=s.end;}
  out+=base.slice(from);
  if(bytesOf(out)>REVIEW_FILE_BYTES)throw Error('The patched file would be larger than the review limit. Nothing was applied.');
  return out;
}
/* The patch as a recovery record keeps it: the schema and the edits exactly as the bot sent them. */
export function patchRecord(edits){return {schema:PATCH_SCHEMA,edits:checkPatchEdits(edits)};}
export function validatePatchRecord(p){
  if(!p||typeof p!=='object'||p.schema!==PATCH_SCHEMA||Object.keys(p).length!==2)throw Error('Invalid recovery patch.');
  return patchRecord(p.edits);
}
/* A reply's actions as a conversation shows them. Each patch is applied to `referenceFor(path)`, the
 * latest snapshot this conversation shared for that path, and becomes a file proposal carrying the
 * derived content and the patch as sent; review, combined review, Save's stale checks and recovery then
 * treat it like any file proposal. A patch that cannot be applied stays a patch with `refused` saying
 * why. Other actions, and the array itself, are untouched: the conversation history keeps what the bot
 * sent, never the expanded file. */
export function reviewableActions(actions,referenceFor){
  return actions.map(a=>{
    if(a.name!=='propose_file_patch')return a;
    const reference=referenceFor(a.args?.path);
    if(!reference||typeof reference.draft!=='string')return {...a,refused:'Share this file from Editor and request a fresh proposal to review it.'};
    try{return {name:'propose_file_edit',args:{path:a.args.path,content:applyFilePatch(reference.draft,a.args.edits)},patch:patchRecord(a.args.edits)};}
    catch(error){return {...a,refused:String(error.message||error)};}
  });
}
