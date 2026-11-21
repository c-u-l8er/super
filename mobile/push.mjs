/* Web Push for Super Mobile: the PX13 tells the phone's push service (Apple's, for an iPhone) to wake the
 * phone with an alert. Three standards, in node:crypto alone, nothing downloaded:
 *  - RFC 8030, the push request itself;
 *  - RFC 8291 with RFC 8188 (aes128gcm), the message is encrypted for that one phone, so the push service
 *    carries it without reading it;
 *  - RFC 8292 (VAPID), the request is signed with this Super's own key, so only this Super can push to a
 *    subscription it made.
 * Only hosts on the allowlist are ever contacted, and redirects are refused: a paired device hands us the
 * endpoint URL, and it must not be able to make the PX13 call anywhere else. */
import {createECDH,createHmac,createCipheriv,createPrivateKey,generateKeyPairSync,randomBytes,sign} from 'node:crypto';

/** Apple's web push service. An iPhone's subscription endpoint is on one of these hosts. */
export const PUSH_HOSTS=Object.freeze(['web.push.apple.com','.push.apple.com']);
const MAX_ENDPOINT=1024,RECORD=4096;

export const b64u={
  enc:b=>Buffer.from(b).toString('base64url'),
  dec(s){if(typeof s!=='string'||!/^[A-Za-z0-9_-]+={0,2}$/.test(s))throw Error('Not base64url text.');return Buffer.from(s.replace(/=+$/,''),'base64url');},
};
const hmac=(key,data)=>createHmac('sha256',key).update(data).digest();
// HKDF (RFC 5869) with one output block: every length used here is 32 bytes or less.
const hkdf=(salt,ikm,info,length)=>hmac(hmac(salt,ikm),Buffer.concat([info,Buffer.from([1])])).subarray(0,length);

/** Is this endpoint one we may contact? https, port 443, no user part, host on the list ('.x' means any host under x). */
export function allowedEndpoint(endpoint,hosts=PUSH_HOSTS){
  if(typeof endpoint!=='string'||endpoint.length>MAX_ENDPOINT)return false;
  let u;try{u=new URL(endpoint);}catch{return false;}
  if(u.protocol!=='https:'||u.username||u.password||(u.port&&u.port!=='443')||u.href!==endpoint)return false;
  const h=u.hostname.toLowerCase();
  return hosts.some(x=>x.startsWith('.')?h.endsWith(x)&&h.length>x.length:h===x);
}

/** A browser's PushSubscription (its toJSON()), checked: { endpoint, keys: { p256dh, auth } }. Throws with a plain reason. */
export function checkSubscription(sub,hosts=PUSH_HOSTS){
  if(!sub||typeof sub!=='object'||Array.isArray(sub))throw Error('A push subscription is required.');
  const {endpoint,keys}=sub;
  if(!allowedEndpoint(endpoint,hosts))throw Error("That push service is not one Super sends to.");
  if(!keys||typeof keys!=='object')throw Error('The subscription has no keys.');
  let ua,auth;try{ua=b64u.dec(keys.p256dh);auth=b64u.dec(keys.auth);}catch{throw Error('The subscription keys are not readable.');}
  if(ua.length!==65||ua[0]!==4)throw Error('The subscription key is not a P-256 public key.');
  if(auth.length!==16)throw Error('The subscription secret is not 16 bytes.');
  try{const e=createECDH('prime256v1');e.generateKeys();e.computeSecret(ua);}catch{throw Error('The subscription key is not a point on P-256.');}
  return {endpoint,keys:{p256dh:b64u.enc(ua),auth:b64u.enc(auth)}};
}

/** RFC 8291: the message body for one subscription. `salt` and `serverPrivate` are for the RFC's worked example only. */
export function encrypt(payload,{p256dh,auth},{salt=randomBytes(16),serverPrivate}={}){
  const ua=b64u.dec(p256dh),secret=b64u.dec(auth);
  if(ua.length!==65||ua[0]!==4)throw Error('The subscription key is not a P-256 public key.');
  if(secret.length!==16)throw Error('The subscription secret is not 16 bytes.');
  if(!Buffer.isBuffer(salt)||salt.length!==16)throw Error('The salt must be 16 bytes.');
  const ecdh=createECDH('prime256v1');
  if(serverPrivate)ecdh.setPrivateKey(serverPrivate);else ecdh.generateKeys();
  const as=ecdh.getPublicKey(),shared=ecdh.computeSecret(ua);
  const ikm=hkdf(secret,shared,Buffer.concat([Buffer.from('WebPush: info\0'),ua,as]),32);
  const cek=hkdf(salt,ikm,Buffer.from('Content-Encoding: aes128gcm\0'),16);
  const nonce=hkdf(salt,ikm,Buffer.from('Content-Encoding: nonce\0'),12);
  const plain=Buffer.concat([Buffer.from(payload),Buffer.from([2])]);          // one record, so it is the last: delimiter 2
  if(plain.length+16>RECORD)throw Error('The alert is too long to send.');
  const cipher=createCipheriv('aes-128-gcm',cek,nonce);
  const sealed=Buffer.concat([cipher.update(plain),cipher.final(),cipher.getAuthTag()]);
  const head=Buffer.alloc(21);salt.copy(head,0);head.writeUInt32BE(RECORD,16);head[20]=as.length;
  return Buffer.concat([head,as,sealed]);
}

/** A new VAPID key pair: public as the 65-byte point (base64url), private as the JWK `d`. */
export function newVapidKeys(){
  const {privateKey}=generateKeyPairSync('ec',{namedCurve:'P-256'});const j=privateKey.export({format:'jwk'});
  return {publicKey:b64u.enc(Buffer.concat([Buffer.from([4]),b64u.dec(j.x),b64u.dec(j.y)])),privateKey:j.d};
}
const subjectOk=s=>typeof s==='string'&&s.length<=200&&(/^https:\/\/[^\s/?#]+(\/[^\s]*)?$/.test(s)||/^mailto:[^\s@]+@[^\s@]+$/.test(s));

/** RFC 8292: the Authorization header for one endpoint. The token lives one hour (the RFC allows up to 24). */
export function vapid(endpoint,{publicKey,privateKey},subject,nowSeconds){
  if(!subjectOk(subject))throw Error('Alerts need a contact for the push service: an https address or mailto.');
  const pub=b64u.dec(publicKey),aud=new URL(endpoint).origin;
  const key=createPrivateKey({key:{kty:'EC',crv:'P-256',x:b64u.enc(pub.subarray(1,33)),y:b64u.enc(pub.subarray(33,65)),d:privateKey},format:'jwk'});
  const head=b64u.enc(JSON.stringify({typ:'JWT',alg:'ES256'})),claims=b64u.enc(JSON.stringify({aud,exp:Math.floor(nowSeconds)+3600,sub:subject}));
  const signature=sign('sha256',Buffer.from(head+'.'+claims),{key,dsaEncoding:'ieee-p1363'});
  return `vapid t=${head}.${claims}.${b64u.enc(signature)}, k=${publicKey}`;
}

/** One alert to one subscription. Outcome: sent (the push service took it), gone (the subscription ended), failed. */
export async function sendPush(sub,message,{keys,subject,hosts=PUSH_HOSTS,now=Date.now,fetch=globalThis.fetch,ttl=43200,topic='superwaiting',urgency='normal'}){
  if(!allowedEndpoint(sub?.endpoint,hosts))return {outcome:'failed',detail:'endpoint not on the allowlist'};
  // Apple's push service refuses a Topic with a hyphen (400 BadWebPushTopic, seen 21 Nov 2026), though RFC 8030
  // allows the base64url alphabet. Letters and digits only, at most 32.
  if(!/^[A-Za-z0-9]{1,32}$/.test(topic))return {outcome:'failed',detail:'the topic must be 1 to 32 letters or digits'};
  let body,authorization;
  try{body=encrypt(JSON.stringify(message),sub.keys);authorization=vapid(sub.endpoint,keys,subject,now()/1000);}
  catch(e){return {outcome:'failed',detail:e.message};}
  let r;
  try{
    r=await fetch(sub.endpoint,{method:'POST',redirect:'error',signal:AbortSignal.timeout(15000),body,
      headers:{'Content-Encoding':'aes128gcm','Content-Type':'application/octet-stream',TTL:String(ttl),Urgency:urgency,Topic:topic,Authorization:authorization}});
  }catch{return {outcome:'failed',detail:'no answer from the push service'};}
  if(r.status>=200&&r.status<300)return {outcome:'sent',status:r.status};
  if(r.status===404||r.status===410)return {outcome:'gone',status:r.status};
  let reason='';try{reason=String((await r.json())?.reason??'').slice(0,80);}catch{}
  return {outcome:'failed',status:r.status,detail:reason||'refused'};
}
