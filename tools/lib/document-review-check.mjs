// The closed check behind `repository-document-review@1`. It executes no
// repository code: it reads the reviewed documents out of the snapshot and
// holds them to what a document in a repository has to be — decodable, whole,
// unmerged, its fences closed, and every repository path it names actually
// there. That is the whole point of the profile: a repository that is not
// Super has no `tools/*-test.mjs` for the JavaScript profile to discover, and
// running its own build would be a caller-supplied command. This runs Super's
// own pinned bytes over the reviewed files instead.
//
// The module is both the check and its sandbox entry: with
// SUPER_DOCUMENT_REVIEW naming a manifest it registers one node:test per
// reviewed document, so the runner reads the same TAP it reads for every other
// profile. Imported without it (by tools/document-review-test.mjs) it is a
// pure library.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

export const DOCUMENT_EXTENSIONS=['.md','.markdown','.txt'];
export const isDocumentPath=path=>typeof path==='string'&&DOCUMENT_EXTENSIONS.some(e=>path.toLowerCase().endsWith(e));

// Fenced blocks are content, not prose: a WRL or shell sample inside one may
// hold anything that looks like a link or a marker, and does not.
function* proseLines(text){
  let fence=null;
  for(const [index,line] of text.split('\n').entries()){
    const opened=/^\s{0,3}(`{3,}|~{3,})/.exec(line);
    if(opened){if(!fence)fence=opened[1][0];else if(opened[1][0]===fence)fence=null;continue;}
    if(!fence)yield [index+1,line.replace(/`[^`\n]*`/g,'')];
  }
  if(fence!==null)yield [0,null];
}

export function linkTargets(text){
  const targets=[];
  for(const [line,body] of proseLines(text)){
    if(body===null)continue;
    for(const m of body.matchAll(/\[[^\]\n]*\]\(\s*<?([^)<>\s]+)>?(?:\s+["'][^"'\n]*["'])?\s*\)/g))targets.push({line,target:m[1]});
  }
  return targets;
}

// Only a target that looks like a path in this repository is checkable. A URL,
// a bare anchor, a site-absolute path and a parenthesised aside such as
// `[door:L1](law)` are none of Super's business, and saying so here is why the
// check can be strict about the ones that remain.
export function repositoryTarget(target){
  if(/^[a-z][a-z0-9+.-]*:/i.test(target)||target.startsWith('//')||target.startsWith('#')||target.startsWith('/'))return null;
  const path=target.split('#')[0].split('?')[0];
  if(!path||!(path.includes('/')||/\.[A-Za-z0-9]{1,8}$/.test(path)))return null;
  return path;
}

export function resolveAgainst(documentPath,target){
  const parts=documentPath.split('/').slice(0,-1);
  for(const part of target.split('/')){
    if(part==='.'||part==='')continue;
    if(part==='..'){if(!parts.length)return null;parts.pop();continue;}
    parts.push(part);
  }
  return parts.length?parts.join('/'):null;
}

// `paths` is the repository's own Git-listed path set, so a link may name a
// directory as well as a file.
export function checkDocument({path,text,paths}){
  const problems=[],listed=paths instanceof Set?paths:new Set(paths??[]),directories=new Set();
  for(const p of listed){const parts=p.split('/');for(let i=1;i<parts.length;i++)directories.add(parts.slice(0,i).join('/'));}
  if(!isDocumentPath(path))problems.push('is not a document ('+DOCUMENT_EXTENSIONS.join(', ')+')');
  if(!text.length)problems.push('is empty');
  if(text.includes('\0'))problems.push('contains a NUL byte');
  if(text.includes('\r'))problems.push('contains a carriage return');
  if(text.length&&!text.endsWith('\n'))problems.push('does not end with a newline');
  let closed=true;
  for(const [line,body] of proseLines(text)){
    if(body===null){closed=false;continue;}
    if(/^(<{7}|>{7}|\|{7}) /.test(body)||/^={7}$/.test(body))problems.push('line '+line+' is a merge conflict marker');
  }
  if(!closed)problems.push('has an unclosed fenced block');
  for(const {line,target} of linkTargets(text)){
    const wanted=repositoryTarget(target);if(!wanted)continue;
    const resolved=resolveAgainst(path,wanted);
    if(!resolved||!(listed.has(resolved)||directories.has(resolved)))problems.push('line '+line+' links to '+target+', which is not in the repository');
  }
  return problems;
}

export function checkDocumentBytes({path,bytes,paths}){
  let text;
  try{text=new TextDecoder('utf-8',{fatal:true}).decode(bytes);}
  catch{return ['is not valid UTF-8'];}
  return checkDocument({path,text,paths});
}

const manifest=process.env.SUPER_DOCUMENT_REVIEW;
if(manifest){
  const {documents,paths}=JSON.parse(readFileSync(manifest,'utf8')),listed=new Set(paths);
  for(const path of documents)test(path,()=>{
    const problems=checkDocumentBytes({path,bytes:readFileSync(path),paths:listed});
    assert.deepEqual(problems,[],path+' — '+problems.join('; '));
  });
}
