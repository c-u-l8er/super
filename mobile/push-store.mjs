/* The phones that asked for alerts, and this Super's own push key. Both live beside sessions.json in the
 * mobile state folder (~/.local/state/super/mobile), private to this user.
 *  - push-key.json: the VAPID key pair, made once. The private half never leaves this file.
 *  - push-subscriptions.json: at most eight phones. Written only by the gateway (a phone turning alerts on
 *    or off). The alert sender only reads it; a subscription the push service says has ended is noted in the
 *    sender's own file (alerts.json, `gone`), and skipped until that phone turns alerts on again. */
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {readPrivateJson,writePrivateJson} from './private-file.mjs';
import {checkSubscription,newVapidKeys,PUSH_HOSTS} from './push.mjs';

const MAX_PHONES=8;
/** A short one-way name for an endpoint, for the sender's records: the endpoint itself is a capability. */
export const endpointId=endpoint=>createHash('sha256').update('super-push-endpoint:'+endpoint).digest('hex').slice(0,16);

export function pushStore(dir,{now=Date.now,hosts=PUSH_HOSTS}={}){
  const keyFile=join(dir,'push-key.json'),subFile=join(dir,'push-subscriptions.json');
  const list=()=>{
    const data=readPrivateJson(subFile,{fallback:{schema:'super-mobile-push@1',phones:[]}});
    if(data.schema!=='super-mobile-push@1'||!Array.isArray(data.phones)||data.phones.length>MAX_PHONES)throw Error('The alert list does not match this Super.');
    return data.phones.filter(p=>p&&typeof p.device==='string'&&Number.isFinite(p.added)&&(()=>{try{checkSubscription(p,hosts);return true;}catch{return false;}})());
  };
  const save=phones=>writePrivateJson(subFile,{schema:'super-mobile-push@1',phones});
  return {
    /** The key pair, made on first use. */
    keys(){
      const k=readPrivateJson(keyFile);
      if(k){if(k.schema!=='super-mobile-push-key@1'||typeof k.publicKey!=='string'||typeof k.privateKey!=='string')throw Error('The push key file does not match this Super.');return {publicKey:k.publicKey,privateKey:k.privateKey};}
      const made=newVapidKeys();writePrivateJson(keyFile,{schema:'super-mobile-push-key@1',...made,made:now()});return made;
    },
    list,
    /** A phone turns alerts on. The same endpoint again replaces its entry (new keys, new time); the oldest phone gives way past eight. */
    add(device,sub){
      const clean=checkSubscription(sub,hosts);
      const phones=list().filter(p=>p.endpoint!==clean.endpoint);
      phones.push({device,...clean,added:now()});
      while(phones.length>MAX_PHONES)phones.shift();
      save(phones);return clean;
    },
    /** A phone turns alerts off, by the endpoint it holds. True if one was removed. */
    remove(endpoint){const phones=list(),kept=phones.filter(p=>p.endpoint!==endpoint);if(kept.length===phones.length)return false;save(kept);return true;},
    /** Every phone a device turned on, removed (Disconnect this device). */
    removeDevice(device){const phones=list(),kept=phones.filter(p=>p.device!==device);if(kept.length!==phones.length)save(kept);return phones.length-kept.length;},
    find(endpoint){return list().find(p=>p.endpoint===endpoint)??null;},
  };
}
