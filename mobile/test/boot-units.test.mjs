/* Laws for Super coming back by itself after the PX13 restarts. The desktop cockpit, which starts the mobile gateway,
 * is a user unit started by his GNOME login (units/super-desktop.service). The private front is a user unit started
 * at boot, as he lingers (units/super-mobile-front.service). Its start step (start-private-front.sh) reads his
 * Tailscale login and his phone's addresses from `tailscale status --json` (tailnet-owner.mjs), so neither is written
 * into a unit or a file: the login is his email. */
import test from 'node:test';import assert from 'node:assert/strict';
import {existsSync,mkdtempSync,readFileSync,rmSync,statSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';import {join} from 'node:path';import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {ownerFromStatus} from '../tailnet-owner.mjs';

const MOBILE=fileURLToPath(new URL('../',import.meta.url));
const LOGIN='owner@example.com',ORIGIN='https://laptop.tail0000.ts.net',NODE='phone-one';
const PHONE='100.64.0.7',PHONE6='fd7a:115c:a1e0::7',SELF='100.64.0.1',SELF6='fd7a:115c:a1e0::1';
/** A `tailscale status --json` as the PX13 sees it: this machine, his phone (iOS calls itself localhost), a box. */
const status=(change=()=>{})=>{const s={
  BackendState:'Running',
  Self:{HostName:'laptop',DNSName:'laptop.tail0000.ts.net.',UserID:11,Tags:null,TailscaleIPs:[SELF,SELF6]},
  User:{'11':{ID:11,LoginName:LOGIN},'22':{ID:22,LoginName:'other@example.com'}},
  Peer:{
    'nodekey:a':{HostName:'localhost',DNSName:'phone-one.tail0000.ts.net.',OS:'iOS',UserID:11,Tags:null,TailscaleIPs:[PHONE,PHONE6]},
    'nodekey:b':{HostName:'box',DNSName:'box.tail0000.ts.net.',OS:'linux',UserID:11,Tags:null,TailscaleIPs:['100.64.0.9','fd7a:115c:a1e0::9']}}};
  change(s,s.Peer['nodekey:a']);return s;};
const owner=(s,o={})=>ownerFromStatus(s,{node:NODE,origin:ORIGIN,...o});
const refuses=(s,re,o={})=>assert.throws(()=>owner(s,o),re);
// Short folders: a Unix socket path must stay under about 100 bytes.
const temp=t=>{const d=mkdtempSync(join(tmpdir(),'sb-'));t.after(()=>rmSync(d,{recursive:true,force:true}));return d;};
/** A stand-in for the tailscale command: prints $FAKE_STATUS for `status --json`, or fails when $FAKE_FAIL is set. */
const fakeTailscale=(dir,text)=>{
  const bin=join(dir,'tailscale'),out=join(dir,'status.json');writeFileSync(out,text);
  writeFileSync(bin,'#!/bin/sh\n[ -n "$FAKE_FAIL" ] && exit 3\n[ "$1 $2" = "status --json" ] || exit 9\ncat "$FAKE_STATUS"\n',{mode:0o755});
  return {SUPER_MOBILE_TAILSCALE:bin,FAKE_STATUS:out};};
const baseEnv=dir=>({PATH:process.env.PATH,HOME:dir,XDG_STATE_HOME:join(dir,'state'),SUPER_MOBILE_OWNER_NODE:NODE,SUPER_MOBILE_PRIVATE_ORIGIN:ORIGIN});
/** Runs a program; with `until`, stops it once its output matches, noting whether `socket` was there by then. */
const run=(cmd,args,env,{until,socket}={})=>new Promise(resolve=>{
  const child=spawn(cmd,args,{env,stdio:['ignore','pipe','pipe']});let out='',err='',sawSocket=false;
  const timer=setTimeout(()=>child.kill('SIGKILL'),20_000);
  child.stdout.on('data',c=>{out+=c;if(until?.test(out)){sawSocket=!!socket&&existsSync(socket);child.kill('SIGTERM');}});
  child.stderr.on('data',c=>err+=c);
  child.on('close',(code,signal)=>{clearTimeout(timer);resolve({code,signal,out,err,sawSocket});});});
/** A unit file as {section: {key: [values]}}; Environment= lines are split into their assignments. */
const unit=name=>{const u={};let sec=null;
  for(const line of readFileSync(join(MOBILE,'units',name),'utf8').split('\n')){
    const s=/^\[(\w+)\]$/.exec(line);if(s){sec=u[s[1]]={};continue;}
    const kv=/^(\w+)=(.*)$/.exec(line);if(!kv||!sec)continue;
    for(const v of kv[1]==='Environment'?kv[2].split(/\s+/).filter(Boolean):[kv[2]])(sec[kv[1]]??=[]).push(v);}
  return u;};
const env=u=>Object.fromEntries((u.Service.Environment??[]).map(a=>[a.slice(0,a.indexOf('=')),a.slice(a.indexOf('=')+1)]));

test("B1 · his login and his phone's addresses are read from Tailscale's status",()=>{
  assert.deepEqual(owner(status()),{login:LOGIN,devices:[PHONE,PHONE6]});
  // The phone found by its MagicDNS name, with or without the closing dot; one address is enough.
  assert.deepEqual(owner(status((s,p)=>{p.DNSName='phone-one.tail0000.ts.net';p.TailscaleIPs=[PHONE];})),{login:LOGIN,devices:[PHONE]});
});

test('B2 · nothing until Tailscale is running here',()=>{
  for(const state of ['Starting','NeedsLogin','Stopped','NoState',undefined])refuses(status(s=>{s.BackendState=state;}),/not running/);
  refuses(null,/not running/);refuses({},/not running/);
});

test("B3 · exactly one node by that name, in this machine's tailnet",()=>{
  refuses(status(),/Found 0 nodes/,{node:'phone-two'});
  refuses(status((s,p)=>{p.DNSName='phone-one.tail9999.ts.net.';}),/Found 0 nodes/);
  refuses(status((s,p)=>{p.DNSName='other.tail0000.ts.net.';p.HostName='phone-one';}),/Found 0 nodes/);
  refuses(status((s,p)=>{s.Peer['nodekey:c']={...p,TailscaleIPs:['100.64.0.8']};}),/Found 2 nodes/);
  refuses(status(s=>{s.Self.DNSName='';}),/no MagicDNS name/);
  for(const node of ['phone one','Phone-One','phone-one.tail0000','',undefined,'-x'])refuses(status(),/Name his phone/,{node});
});

test('B4 · his own untagged phone, seen from an untagged machine with a login',()=>{
  refuses(status((s,p)=>{p.UserID=22;}),/another Tailscale user/);
  refuses(status((s,p)=>{p.Tags=['tag:server'];}),/is tagged/);
  refuses(status(s=>{s.Self.Tags=['tag:server'];}),/tagged or unknown/);
  refuses(status(s=>{delete s.Self;}),/tagged or unknown/);
  for(const name of [undefined,'','owner','owner @example.com','owner@example.com\nx','owner@ex\u0007ample.com','a@b@c'])
    refuses(status(s=>{s.User['11'].LoginName=name;}),/no login name/);
  refuses(status(s=>{delete s.User;}),/no login name/);
});

test("B5 · never this machine's own address, and only in Tailscale's ranges",()=>{
  refuses(status((s,p)=>{p.TailscaleIPs=[PHONE,SELF];}),/shares an address/);
  refuses(status((s,p)=>{p.TailscaleIPs=[SELF6];}),/shares an address/);
  for(const a of ['192.168.1.5','100.128.0.1','100.63.255.255','10.0.0.1','2001:db8::1','FD7A:115C:A1E0::7','fd7a:115c:a1e1::7','localhost'])
    refuses(status((s,p)=>{p.TailscaleIPs=[a];}),/outside Tailscale's ranges/);
  refuses(status((s,p)=>{p.TailscaleIPs=[];}),/0 tailnet addresses/);
  refuses(status((s,p)=>{delete p.TailscaleIPs;}),/0 tailnet addresses/);
  refuses(status((s,p)=>{p.TailscaleIPs=['100.64.0.2','100.64.0.3','100.64.0.4','100.64.0.5','100.64.0.6'];}),/5 tailnet addresses/);
});

test("B6 · the front's origin is this machine's own name",()=>{
  for(const origin of ['https://other.tail0000.ts.net','http://laptop.tail0000.ts.net','https://laptop.tail0000.ts.net/',
    'https://laptop.tail0000.ts.net:8443','https://LAPTOP.tail0000.ts.net','',undefined])
    refuses(status(),/private origin is not https:\/\/laptop\.tail0000\.ts\.net/,{origin});
});

test('B7 · run as a program: two lines for the start step; a refusal exits 1 and never shows the login',async t=>{
  const dir=temp(t),program=join(MOBILE,'tailnet-owner.mjs');
  const good=await run(process.execPath,[program],{...baseEnv(dir),...fakeTailscale(dir,JSON.stringify(status()))});
  assert.equal(good.code,0,good.err);assert.equal(good.out,`${LOGIN}\n${PHONE},${PHONE6}\n`);assert.equal(good.err,'');
  // JSON.parse quotes short text it cannot read, so text holding only the login must not reach the refusal.
  for(const text of [JSON.stringify(status((s,p)=>{p.UserID=22;})),LOGIN,`{"User":{"11":{"LoginName":"${LOGIN}"}`,''])
  {const r=await run(process.execPath,[program],{...baseEnv(dir),...fakeTailscale(dir,text)});
    assert.equal(r.code,1,text);assert.equal(r.out,'');assert.match(r.err,/^Not starting the private front: /);assert.ok(!r.err.includes('owner@'),r.err);}
  const fails=await run(process.execPath,[program],{...baseEnv(dir),...fakeTailscale(dir,JSON.stringify(status())),FAKE_FAIL:'1'});
  assert.equal(fails.code,1);assert.equal(fails.out,'');assert.match(fails.err,/did not answer/);
});

test('B8 · the start step starts the front with his login and phone, and starts nothing when it refuses',async t=>{
  const dir=temp(t),script=join(MOBILE,'start-private-front.sh'),socket=join(dir,'s','front.sock');
  const e={...baseEnv(dir),SUPER_MOBILE_NODE:process.execPath,SUPER_MOBILE_FRONT_SOCKET:socket};
  // Started with a login and the phone's two addresses that the start step read, not ones left in the environment.
  const up=await run('bash',[script],{...e,...fakeTailscale(dir,JSON.stringify(status())),SUPER_MOBILE_TAILSCALE_LOGIN:'',SUPER_MOBILE_OWNER_DEVICES:''},
    {until:/listening on .*\n/,socket});
  assert.match(up.out,new RegExp(`listening on ${socket.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}\\. Connecting without a code: 2 address\\(es\\) of his phone\\.`),up.out+up.err);
  assert.ok(up.sawSocket,'the socket was there');assert.equal(up.err,'');
  rmSync(join(dir,'s'),{recursive:true,force:true});
  const refused=await run('bash',[script],{...e,...fakeTailscale(dir,JSON.stringify(status((s,p)=>{p.Tags=['tag:x'];})))});
  assert.equal(refused.code,1);assert.equal(refused.out,'');assert.ok(!existsSync(join(dir,'s')),'no socket folder');
  assert.match(refused.err,/is tagged/);assert.ok(!refused.err.includes('owner@'));
  for(const node of ['node','',join(dir,'missing')]){const r=await run('bash',[script],{...e,SUPER_MOBILE_NODE:node,...fakeTailscale(dir,JSON.stringify(status()))});
    assert.equal(r.code,1);assert.match(r.err,/SUPER_MOBILE_NODE/);}
  assert.ok(statSync(script).mode&0o100,'the unit can run it');
});

test('B9 · the front starts at boot, keeps trying, stays private, and holds nothing of his',()=>{
  const u=unit('super-mobile-front.service'),e=env(u),text=readFileSync(join(MOBILE,'units','super-mobile-front.service'),'utf8');
  assert.deepEqual(u.Install.WantedBy,['default.target']);
  assert.deepEqual(u.Unit.StartLimitIntervalSec,['0']);
  assert.deepEqual(u.Service.ExecStart,['%h/build/super-review-content/mobile/start-private-front.sh']);
  assert.deepEqual(u.Service.UMask,['0077']);assert.deepEqual(u.Service.Restart,['on-failure']);
  assert.equal(e.SUPER_MOBILE_NODE,'%h/.nvm/versions/node/v25.2.1/bin/node');
  assert.equal(e.SUPER_MOBILE_FRONT_SOCKET,'%t/super-mobile/front.sock');
  assert.equal(e.SUPER_MOBILE_ACCESS_LOG,'1');
  assert.match(e.SUPER_MOBILE_PRIVATE_ORIGIN,/^https:\/\/[a-z0-9-]+\.[a-z0-9-]+\.ts\.net$/);
  assert.match(e.SUPER_MOBILE_OWNER_NODE,/^[a-z0-9-]+$/);
  // His login and his phone's addresses are read at each start, so the unit names neither.
  assert.ok(!('SUPER_MOBILE_TAILSCALE_LOGIN' in e)&&!('SUPER_MOBILE_OWNER_DEVICES' in e));
  assert.ok(!text.includes('@'),'no login in the unit');assert.ok(!/\b100\.\d+\.\d+\.\d+\b|fd7a:/i.test(text),'no address in the unit');
});

test('B10 · the desktop starts with his GNOME login and stops when he logs out',()=>{
  const u=unit('super-desktop.service'),e=env(u);
  assert.deepEqual(u.Install.WantedBy,['graphical-session.target']);
  assert.deepEqual(u.Unit.PartOf,['graphical-session.target']);assert.deepEqual(u.Unit.After,['graphical-session.target']);
  assert.deepEqual(u.Service.ExecStart,['%h/build/super-review-content/mobile/start-local.sh']);
  assert.deepEqual(u.Service.Restart,['on-failure']);
  assert.equal(e.SUPER_MOBILE_PANEL,'0');assert.equal(e.SUPER_ROAD,'0');
  // The display and its key come from his session, never written here.
  assert.ok(!('DISPLAY' in e)&&!('XAUTHORITY' in e));
  assert.ok(statSync(join(MOBILE,'start-local.sh')).mode&0o100,'the unit can run it');
});
