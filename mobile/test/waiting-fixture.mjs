/* waiting-fixture.mjs: what the Waiting on you laws share. A helper, not a test (the suite's glob is *.test.mjs).
 * Every law runs in its own temp folders; nothing here reads or writes ~/.local/state, and nothing reaches a
 * network: the push service is a fake that decrypts what it is sent, as the phone would. */
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,rmSync,writeFileSync,chmodSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createECDH,createHash,createHmac,createDecipheriv,createPublicKey,randomBytes,verify} from 'node:crypto';

/** Sat 21 Nov 2026, 11:00 in Chicago (17:00 UTC): outside the quiet hours. */
export const NOW=Date.UTC(2026,10,21,17,0,0),T=NOW/1000;
/** A Chicago wall-clock time on 21 or 22 Nov 2026 (CST is UTC-6). */
export const chicago=(day,hour,minute=0)=>Date.UTC(2026,10,day,hour+6,minute,0);

export const key=s=>createHash('sha1').update(s).digest('hex').slice(0,12);
export const line=(thread,o={})=>({thread,chat:`Chat for ${thread}`,chat_id:`local_${thread}-0001`,line:`The line for ${thread}.`,
  key:key(thread+(o.status??'')),since:T-3600,busy:false,answered_at:null,mac_notice_at:null,...Object.fromEntries(Object.entries(o).filter(([k])=>k!=='status'))});
export const board=(lines,o={})=>({schema:'super-waiting@1',written_at:T-60,source:'mac-dispatcher',lines,...o});

export function dirs(t){
  const root=mkdtempSync(join(tmpdir(),'super-waiting-laws-'));t.after(()=>rmSync(root,{recursive:true,force:true}));
  const dir=join(root,'waiting'),mobileDir=join(root,'mobile');mkdirSync(dir,{mode:0o700});mkdirSync(mobileDir,{mode:0o700});
  return {root,dir,mobileDir};
}
export function put(path,value,mode=0o600){writeFileSync(path,typeof value==='string'?value:JSON.stringify(value),{mode});chmodSync(path,mode);return path;}
export const putBoard=(dir,b,mode)=>put(join(dir,'feed.json'),b,mode);
export const putConfig=(dir,c)=>put(join(dir,'config.json'),c);

/** A phone's push keys, and its subscription for an endpoint on Apple's service. */
export function phone(name='a'){
  const ecdh=createECDH('prime256v1');ecdh.generateKeys();const auth=randomBytes(16);
  const endpoint=`https://web.push.apple.com/QG-${name}-${randomBytes(6).toString('hex')}`;
  return {ecdh,auth,endpoint,sub:{endpoint,keys:{p256dh:ecdh.getPublicKey().toString('base64url'),auth:auth.toString('base64url')}}};
}
const h=(k,d)=>createHmac('sha256',k).update(d).digest();
/** What the phone does with a push body (RFC 8291, receiving side), written apart from push.mjs. */
export function open(p,body){
  const salt=body.subarray(0,16),rs=body.readUInt32BE(16),idlen=body[20],as=body.subarray(21,21+idlen),sealed=body.subarray(21+idlen);
  assert.equal(rs,4096);assert.equal(idlen,65);
  const ua=p.ecdh.getPublicKey(),ikm=h(h(p.auth,p.ecdh.computeSecret(as)),Buffer.concat([Buffer.from('WebPush: info\0'),ua,as,Buffer.from([1])]));
  const prk=h(salt,ikm),cek=h(prk,Buffer.from('Content-Encoding: aes128gcm\0\x01')).subarray(0,16),nonce=h(prk,Buffer.from('Content-Encoding: nonce\0\x01')).subarray(0,12);
  const d=createDecipheriv('aes-128-gcm',cek,nonce);d.setAuthTag(sealed.subarray(sealed.length-16));
  const plain=Buffer.concat([d.update(sealed.subarray(0,sealed.length-16)),d.final()]);
  let i=plain.length-1;while(i>=0&&plain[i]===0)i--;assert.equal(plain[i],2,'one record, marked last');
  return JSON.parse(plain.subarray(0,i).toString('utf8'));
}
/** The VAPID header, checked as a push service would: the signature against k, and the claims. */
export function readVapid(header){
  const m=/^vapid t=([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+), k=([A-Za-z0-9_-]+)$/.exec(header);assert.ok(m,'vapid t=…, k=…');
  const pub=Buffer.from(m[4],'base64url');
  const keyObject=createPublicKey({key:{kty:'EC',crv:'P-256',x:pub.subarray(1,33).toString('base64url'),y:pub.subarray(33,65).toString('base64url')},format:'jwk'});
  return {signed:verify('sha256',Buffer.from(m[1]+'.'+m[2]),{key:keyObject,dsaEncoding:'ieee-p1363'},Buffer.from(m[3],'base64url')),
    head:JSON.parse(Buffer.from(m[1],'base64url')),claims:JSON.parse(Buffer.from(m[2],'base64url')),k:m[4]};
}
/** A fake push service: records each request; answers `status` (a number, or a function of the URL). */
export function pushService(status=201){
  const calls=[];
  const fetch=async(url,init)=>{calls.push({url:String(url),init});const s=typeof status==='function'?status(String(url)):status;if(s==='throw')throw TypeError('fetch failed');return {status:s,json:async()=>({reason:'BadDeviceToken'})};};
  return {fetch,calls};
}
