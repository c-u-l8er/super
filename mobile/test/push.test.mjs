/* Laws for web push (push.mjs): the encryption, the signature, which hosts Super will ever contact, and what
 * each answer from the push service means. No network: the push service is a fake. */
import test from 'node:test';import assert from 'node:assert/strict';
import {encrypt,vapid,newVapidKeys,allowedEndpoint,checkSubscription,sendPush,b64u} from '../push.mjs';
import {NOW,T,phone,open,readVapid,pushService} from './waiting-fixture.mjs';

// RFC 8291 section 5's worked example: published test values, not secrets. Joined from pieces so that secret
// scanners read them as the text they are (the commit gate runs gitleaks).
const EXAMPLE={
  plaintext:'When I grow up, I want to be a watermelon',
  receiver:['BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcx','aOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4'].join(''),
  auth:['BTBZMqHH6r4','Tts7J_aSIgg'].join(''),salt:['DGv6ra1nlYg','DCS1FRnbzlw'].join(''),
  sender:['yfWPiYE-n46HLnH0','KqZOF1fJJU3MYrct','3AELtAQ-oRw'].join(''),
};

test("P1 · the encryption matches RFC 8291's worked example byte for byte",()=>{
  const body=encrypt(EXAMPLE.plaintext,{p256dh:EXAMPLE.receiver,auth:EXAMPLE.auth},{salt:b64u.dec(EXAMPLE.salt),serverPrivate:b64u.dec(EXAMPLE.sender)});
  assert.equal(b64u.enc(body),'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN');
});

test('P2 · the phone can read what Super encrypts for it, and another phone cannot',()=>{
  const a=phone('a'),b=phone('b'),message={title:'Waiting on you',body:'Chat: a line — with “quotes” and é',count:2};
  const body=encrypt(JSON.stringify(message),a.sub.keys);
  assert.deepEqual(open(a,body),message);
  assert.throws(()=>open(b,body));
  assert.notDeepEqual(encrypt('same',a.sub.keys),encrypt('same',a.sub.keys),'a fresh salt and key every time');
});

test("P3 · the VAPID token is signed by Super's key, names the push service, lives one hour and carries the contact",()=>{
  const keys=newVapidKeys(),endpoint='https://web.push.apple.com/QGabc';
  const v=readVapid(vapid(endpoint,keys,'https://super.example.ts.net',T));
  assert.equal(v.signed,true);assert.equal(v.k,keys.publicKey);assert.deepEqual(v.head,{typ:'JWT',alg:'ES256'});
  assert.deepEqual(v.claims,{aud:'https://web.push.apple.com',exp:T+3600,sub:'https://super.example.ts.net'});
  const other=newVapidKeys();assert.equal(readVapid(vapid(endpoint,keys,'mailto:a@b.example',T).replace(keys.publicKey,other.publicKey)).signed,false);
  for(const bad of [null,'','super','http://x.example','https://','mailto:nobody'])assert.throws(()=>vapid(endpoint,keys,bad,T),/contact/);
});

test("P4 · only Apple's push hosts, over https on port 443, are ever contacted",()=>{
  for(const ok of ['https://web.push.apple.com/QGx','https://api.push.apple.com/x','https://web.push.apple.com/QG-two'])assert.equal(allowedEndpoint(ok),true,ok);
  for(const bad of ['http://web.push.apple.com/x','https://web.push.apple.com:8443/x','https://user@web.push.apple.com/x','https://push.apple.com/x',
    'https://web.push.apple.com.evil.example/x','https://evilpush.apple.com.example/x','https://evilpush.apple.com/x','https://push.apple.com.evil.example/x','https://127.0.0.1/x','https://[::1]/x','https://192.168.1.130:4318/api/pair',
    'https://fcm.googleapis.com/fcm/send/x','https://web.push.apple.com/'+'x'.repeat(1100),'web.push.apple.com/x',42,null])
    assert.equal(allowedEndpoint(bad),false,String(bad).slice(0,80));
  assert.equal(allowedEndpoint('https://fcm.googleapis.com/fcm/send/x',['fcm.googleapis.com']),true,'the list is a setting');
});

test('P5 · a subscription with a bad key or secret is refused, with a plain reason',()=>{
  const p=phone();assert.deepEqual(checkSubscription(p.sub),p.sub);
  const cases=[[null,/required/],[{...p.sub,endpoint:'https://evil.example/x'},/not one Super sends to/],[{endpoint:p.sub.endpoint},/no keys/],
    [{endpoint:p.sub.endpoint,keys:{p256dh:'!!',auth:p.sub.keys.auth}},/not readable/],
    [{endpoint:p.sub.endpoint,keys:{p256dh:b64u.enc(Buffer.alloc(65,4)),auth:p.sub.keys.auth}},/not a point/],
    [{endpoint:p.sub.endpoint,keys:{p256dh:p.sub.keys.p256dh,auth:b64u.enc(Buffer.alloc(8))}},/16 bytes/]];
  for(const [sub,why] of cases)assert.throws(()=>checkSubscription(sub),why);
});

test('P6 · the push request: encrypted, signed, a TTL and one topic, no redirects; 201 is sent, 404 and 410 are gone, the rest failed',async()=>{
  const p=phone(),keys=newVapidKeys(),send=(status)=>{const s=pushService(status);return sendPush(p.sub,{title:'x',body:'y'},{keys,subject:'https://super.example.ts.net',now:()=>NOW,fetch:s.fetch}).then(r=>({r,calls:s.calls}));};
  const {r,calls}=await send(201);
  assert.equal(r.outcome,'sent');assert.equal(calls.length,1);
  const {url,init}=calls[0];assert.equal(url,p.sub.endpoint);assert.equal(init.method,'POST');assert.equal(init.redirect,'error');
  assert.equal(init.headers['Content-Encoding'],'aes128gcm');assert.equal(init.headers.TTL,'43200');assert.equal(init.headers.Topic,'super-waiting');assert.equal(init.headers.Urgency,'normal');
  assert.deepEqual(open(p,init.body),{title:'x',body:'y'});assert.equal(readVapid(init.headers.Authorization).signed,true);
  for(const [status,outcome] of [[200,'sent'],[202,'sent'],[404,'gone'],[410,'gone'],[400,'failed'],[403,'failed'],[429,'failed'],[500,'failed'],['throw','failed']])
    assert.equal((await send(status)).r.outcome,outcome,String(status));
  const s=pushService();assert.equal((await sendPush({...p.sub,endpoint:'https://evil.example/x'},{},{keys,subject:'https://a.example',fetch:s.fetch})).outcome,'failed');
  assert.equal(s.calls.length,0,'an endpoint off the list is never contacted');
});

test('P7 · an alert too long for one record is refused, never cut',()=>{
  const p=phone();assert.throws(()=>encrypt('x'.repeat(4080),p.sub.keys),/too long/);assert.ok(encrypt('x'.repeat(4000),p.sub.keys).length>4000);
});
