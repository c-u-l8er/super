/* His Tailscale login and his phone's tailnet addresses, read from `tailscale status --json` each time the private
 * front starts (start-private-front.sh), so neither is written into a unit or a file: the login is his email.
 * His phone is the one node whose MagicDNS name starts with SUPER_MOBILE_OWNER_NODE in this machine's tailnet (iOS
 * reports its host name as "localhost"), owned by this machine's own user and untagged. Anything else refuses and
 * the unit tries again later: the front never starts with a guessed login or a wider list of phones. A refusal never
 * names the login. */
import {execFile} from 'node:child_process';
import {isIPv4,isIPv6} from 'node:net';
import {fileURLToPath} from 'node:url';

const LABEL=/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
// Tailscale's own ranges, in the lower-case form serve stamps: 100.64.0.0/10 and fd7a:115c:a1e0::/48.
const tailnetV4=a=>{if(!isIPv4(a))return false;const [x,y]=a.split('.').map(Number);return x===100&&y>=64&&y<=127;};
const tailnetV6=a=>isIPv6(a)&&/^fd7a:115c:a1e0:[0-9a-f:]*$/.test(a);

/** {login, devices} from a parsed `tailscale status --json`, for the phone named `node` and the front at `origin`. */
export function ownerFromStatus(status,{node,origin}={}){
  if(typeof node!=='string'||!LABEL.test(node))throw Error('Name his phone (SUPER_MOBILE_OWNER_NODE): one MagicDNS label, like iphone-12-mini.');
  if(status?.BackendState!=='Running')throw Error(`Tailscale is not running here yet (${String(status?.BackendState??'no state').slice(0,32)}).`);
  const self=status.Self;
  if(!self||self.Tags?.length)throw Error('This machine is tagged or unknown to Tailscale, so it has no owner login.');
  const login=status.User?.[String(self.UserID)]?.LoginName;
  if(typeof login!=='string'||login.length>254||!/^[^\s@\p{Cc}]+@[^\s@\p{Cc}]+$/u.test(login))throw Error("This machine's Tailscale user has no login name.");
  const here=String(self.DNSName??'').toLowerCase().replace(/\.$/,''),zone=here.split('.').slice(1).join('.');
  if(!zone)throw Error('This machine has no MagicDNS name.');
  // The front's origin is this machine's own name, so a renamed machine refuses here instead of failing every visit.
  if(origin!==`https://${here}`)throw Error(`The private origin is not https://${here}.`);
  const name=`${node}.${zone}`;
  const found=Object.values(status.Peer??{}).filter(p=>String(p?.DNSName??'').toLowerCase().replace(/\.$/,'')===name);
  if(found.length!==1)throw Error(`Found ${found.length} nodes named ${name}, not one.`);
  const [phone]=found;
  if(phone.UserID!==self.UserID)throw Error(`${name} belongs to another Tailscale user.`);
  if(phone.Tags?.length)throw Error(`${name} is tagged, so it is not his own device.`);
  const own=new Set((self.TailscaleIPs??[]).map(a=>String(a).toLowerCase()));
  const devices=[...new Set((phone.TailscaleIPs??[]).map(a=>String(a)))];
  if(!devices.length||devices.length>4)throw Error(`${name} has ${devices.length} tailnet addresses.`);
  for(const a of devices){
    if(own.has(a.toLowerCase()))throw Error(`${name} shares an address with this machine.`);
    if(!tailnetV4(a)&&!tailnetV6(a))throw Error(`${name} has an address outside Tailscale's ranges.`);
  }
  return {login,devices};
}

// Run: two lines on stdout, the login and then the addresses comma-separated, for start-private-front.sh.
if(process.argv[1]===fileURLToPath(import.meta.url)){
  const tailscale=process.env.SUPER_MOBILE_TAILSCALE||'tailscale';
  execFile(tailscale,['status','--json'],{timeout:15_000,maxBuffer:8<<20},(error,stdout)=>{
    try{
      if(error)throw Error(`tailscale status did not answer (${String(error.code??error.signal??'no code').slice(0,32)}).`);
      // JSON.parse quotes the text it stops on, which can be the login.
      let status;try{status=JSON.parse(stdout);}catch{throw Error('tailscale status gave no JSON.');}
      const {login,devices}=ownerFromStatus(status,{node:process.env.SUPER_MOBILE_OWNER_NODE,origin:process.env.SUPER_MOBILE_PRIVATE_ORIGIN});
      process.stdout.write(`${login}\n${devices.join(',')}\n`);
    }catch(e){console.error('Not starting the private front: '+e.message);process.exitCode=1;}
  });
}
