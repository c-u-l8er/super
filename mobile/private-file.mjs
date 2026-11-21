// Same-user private JSON files (mode 0600), as session-store.mjs keeps them: read only when private and
// small, written to a new temporary file, synced, then renamed into place so no reader sees half of one.
import {readFileSync,lstatSync,openSync,writeFileSync,fsyncSync,closeSync,renameSync,unlinkSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {dirname,isAbsolute} from 'node:path';

/** The parsed file, or `fallback` when it does not exist. Throws a plain reason when it is not private, too big, or not JSON. */
export function readPrivateJson(path,{maxBytes=65536,fallback=null}={}){
  if(!isAbsolute(path))throw Error('A private file needs an absolute path.');
  let stat;try{stat=lstatSync(path);}catch(e){if(e.code==='ENOENT')return fallback;throw Error('The file could not be read.');}
  if(!stat.isFile())throw Error('It is not a plain file.');
  if(stat.mode&0o077)throw Error('It is open to other users.');
  if(stat.size>maxBytes)throw Error('It is too large.');
  try{return JSON.parse(readFileSync(path,'utf8'));}catch{throw Error('It is not readable JSON.');}
}

export function writePrivateJson(path,value){
  if(!isAbsolute(path))throw Error('A private file needs an absolute path.');
  const temporary=path+'.'+randomUUID()+'.new';let fd;
  try{
    fd=openSync(temporary,'wx',0o600);writeFileSync(fd,JSON.stringify(value));fsyncSync(fd);closeSync(fd);fd=undefined;
    renameSync(temporary,path);
    const dir=openSync(dirname(path),'r');try{fsyncSync(dir);}finally{closeSync(dir);}
  }finally{if(fd!==undefined)closeSync(fd);try{unlinkSync(temporary);}catch{}}
}
