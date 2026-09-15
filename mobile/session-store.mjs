// Same-user private session storage. Never included in diagnostics or HTTP responses.
import {readFileSync,lstatSync,openSync,writeFileSync,fsyncSync,closeSync,renameSync,unlinkSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {dirname,isAbsolute} from 'node:path';
export function sessionStore(path,origin,now=Date.now){
 if(!isAbsolute(path))throw Error('Session storage requires an absolute path.');
 return {
  load(){
   let stat;try{stat=lstatSync(path)}catch(e){if(e.code==='ENOENT')return [];throw e;}
   if(!stat.isFile()||(stat.mode&0o077)||stat.size>64000)throw Error('Session storage is not private or has an invalid size.');
   const data=JSON.parse(readFileSync(path,'utf8'));
   if(data.schema!=='super-mobile-sessions@1'||data.origin!==origin||!Array.isArray(data.sessions)||data.sessions.length>64)throw Error('Session storage does not match this gateway.');
   for(const row of data.sessions)if(!Array.isArray(row)||row.length!==2||!/^[a-f0-9]{64}$/.test(row[0])||!row[1]||!['pairedAt','lastSeen','expires'].every(k=>Number.isFinite(row[1][k]))||!['app','browser','other','unknown'].includes(row[1].kind))throw Error('Session storage is unreadable.');
   return data.sessions.filter(([,s])=>s.expires>now());
  },
  save(sessions){
   if(sessions.size>64)throw Error('Too many paired devices. Disconnect an unused device.');
   const temporary=path+'.'+randomUUID()+'.new';let fd;
   try{fd=openSync(temporary,'wx',0o600);writeFileSync(fd,JSON.stringify({schema:'super-mobile-sessions@1',origin,sessions:[...sessions]}));fsyncSync(fd);closeSync(fd);fd=undefined;renameSync(temporary,path);const dir=openSync(dirname(path),'r');try{fsyncSync(dir)}finally{closeSync(dir)}}
   finally{if(fd!==undefined)closeSync(fd);try{unlinkSync(temporary)}catch{}}
  }
 };
}
