/* The in-flight turn is not view state.
 *
 * A reply belongs to the conversation it was sent from, not to whichever
 * conversation is open when it lands. While that fact lived beside `messages`,
 * `transcript` and `input.value` — all of which describe the open view —
 * navigating away did not background a reply, it forgot one: restoring another
 * conversation cleared the turn, and the completion path then wrote into a
 * different conversation's transcript. Everything a reply needs to identify
 * itself lives here instead, out of the DOM, so every caller can ask one
 * question before it writes: does this belong to what I am about to touch?
 *
 * ONE slot, deliberately. A request id on a singleton does not make concurrent
 * replies safe — several live replies need isolated process ownership,
 * cancellation, cleanup and persistence, not a map where a field used to be.
 * begin() refuses while a turn is in flight, and the refusal names the
 * conversation holding it. Navigation is what this module opens up.
 *
 * Pure: no DOM, no storage, no imports, no timers. Constructible and
 * assertable with no browser present. */
export const TURN_STATES=['Waiting','Generating','Cancelling'];
/* Conversation rows carry `id`; the open view carries `conversationId`. Both
 * name the same thing, so both are accepted and compared as one identity. */
export const conversationIdentity=c=>({botId:c?.botId??null,provider:c?.provider??null,conversationId:c?.conversationId??c?.id??null});
export const sameConversation=(a,b)=>!!a&&!!b&&a.botId===b.botId&&a.provider===b.provider&&a.conversationId===b.conversationId;
/* A row's state is a fact about the TURN, not about what is being looked at:
 * the same answer has to come back under every bot filter and in the All
 * conversations view, because the indicator follows the conversation that owns
 * the reply rather than the one on screen. A row that does not own the turn
 * gets null, and the caller keeps its own saved state. */
export function turnStatus(turn,c){
 if(!turn||!c||!sameConversation(turn,conversationIdentity(c)))return null;
 return turn.cancelRequested?'Cancelling':turn.text?'Generating':'Waiting';
}
export const turnLabel=(turn,title)=>'“'+(title||turn?.title||'another conversation')+'”';
/* Refusals name the conversation holding the slot. "Wait" tells a person
 * nothing they can act on; a title tells them where to go to watch or cancel. */
export const holdingRefusal=(turn,title)=>`A reply is still generating in ${turnLabel(turn,title)}. Open it to watch or cancel it, then send again.`;
export const holdingHint=(turn,title)=>`Generating a reply in ${turnLabel(turn,title)} — every other chat stays open for reading. Sending waits for this one.`;
export function createTurnRegistry(){
 let turn=null,issued=0;
 const held=token=>!!turn&&token!=null&&turn.token===token;
 /* Callers get a frozen copy. The registry is the only thing that may move the
  * turn on, so a held reference cannot quietly become a second writer. */
 const view=()=>turn?Object.freeze({...turn,sent:Object.freeze({...turn.sent,files:Object.freeze([...turn.sent.files])})}):null;
 return {
  inFlight:()=>!!turn,
  current:view,
  token:()=>turn?turn.token:null,
  matches:token=>held(token),
  owns:c=>!!turn&&sameConversation(turn,conversationIdentity(c)),
  turnFor:(botId,provider,conversationId=null)=>!!turn&&sameConversation(turn,{botId,provider,conversationId:conversationId??null})?view():null,
  statusFor:c=>turnStatus(turn,c),
  /* Polling and cancelling need the provider the turn was SENT to, never the
   * provider control's current value, which is now whatever is being read. */
  request:()=>turn?Object.freeze({token:turn.token,requestId:turn.requestId,provider:turn.provider,botId:turn.botId,conversationId:turn.conversationId,cancelRequested:turn.cancelRequested}):null,
  begin({botId,provider,conversationId=null,requestId=null,messageCount=0,title='',draft='',files=[],userMessage=null,startedAt=Date.now()}={}){
   if(turn)throw new Error(holdingRefusal(turn));
   if(typeof botId!=='string'||!botId)throw new Error('A turn needs the bot it was sent from.');
   if(typeof provider!=='string'||!provider)throw new Error('A turn needs the provider it was sent to.');
   if(!Number.isInteger(messageCount)||messageCount<0)throw new Error('A turn needs the message count it was sent at.');
   turn={token:++issued,botId,provider,conversationId:conversationId??null,requestId:requestId??null,messageCount,title:String(title||''),text:'',phase:'',receivedBytes:0,reasoningBytes:0,cancelRequested:false,startedAt,
    /* The exact draft and attachments the turn was sent with: a save while it
     * is in flight has to persist the pre-send state so a crash restores it,
     * and reopening the conversation has to put its own message back into the
     * model array the store deliberately saved without it. */
    sent:{draft:String(draft??''),files:[...files],userMessage:userMessage??null}};
   return turn.token;
  },
  /* A first message mints the conversation id only once the store saves it. */
  adopt(token,conversationId){if(!held(token))return false;turn.conversationId=conversationId??null;return true;},
  retitle(token,title){if(!held(token))return false;turn.title=String(title||'');return true;},
  identify(token,requestId){if(!held(token))return false;turn.requestId=requestId??null;return true;},
  /* Stream events and status polls both arrive here; a stale token is ignored
   * rather than resurrecting a finished turn. Counters are read in both
   * spellings, because the poll answers snake_case and the channel camelCase. */
  observe(token,patch={}){
   if(!held(token)||!patch||typeof patch!=='object')return false;
   if(typeof patch.text==='string')turn.text=patch.text;
   if(typeof patch.phase==='string')turn.phase=patch.phase;
   const bytes=patch.receivedBytes??patch.received_bytes,reasoning=patch.reasoningBytes??patch.reasoning_bytes;
   if(Number.isFinite(bytes))turn.receivedBytes=bytes;
   if(Number.isFinite(reasoning))turn.reasoningBytes=reasoning;
   if(patch.cancelled===true||patch.cancelRequested===true)turn.cancelRequested=true;
   return true;
  },
  requestCancel(token){if(!held(token))return false;turn.cancelRequested=true;return true;},
  /* Returns what was cleared, so a completion path can read the turn's last
   * text and identity in the same step that frees the slot. */
  finish(token){if(!held(token))return null;const done=view();turn=null;return done;}
 };
}
