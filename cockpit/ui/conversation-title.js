// Presentation metadata in a requested reply header; never an app action.
export const titleInstruction='For this conversation’s first completed reply, begin the text field with <conversation-title>A short descriptive title, at most 80 characters</conversation-title>, then write your normal reply. This header is presentation metadata, not part of the conversation prose.';
const clean=raw=>raw.trim().replace(/\s+/g,' ').slice(0,80);
export function conversationReply(text,requested){
 const raw=String(text??'');if(!requested)return {text:raw};
 const match=raw.match(/^\s*<conversation-title>([^<>\r\n]{1,100})<\/conversation-title>\s*/);
 if(match){const title=clean(match[1]);return title?{title,text:raw.slice(match[0].length)}:{text:raw};}
 // A header the model opened and never closed, with nothing after it. Measured
 // 2026-09-18 (opus[1m]/xhigh, the first reply of a new conversation): the whole
 // structured text was `<conversation-title>Persist the Cancelled fold state on
 // record pages (dt_0069)` — 78 bytes, no note, no action. The title is still
 // usable; the reply is not, and `emptyFirstReply` says so. A header that prose
 // follows without closing is left as it is: that reply has an answer in it.
 const open=raw.match(/^\s*<conversation-title>([^<>\r\n]{1,100})\s*$/);
 if(open){const title=clean(open[1]);return title?{title,text:''}:{text:raw};}
 return {text:raw};
}
// The first reply of a conversation that carries nothing a person can read or
// act on: at most the requested header, no prose, no proposal. The page fails
// the turn on this instead of landing "Reply received." with nothing to review.
export function emptyFirstReply(titled,actions){
 return !String(titled?.text??'').trim()&&!(Array.isArray(actions)&&actions.length);
}

// Extract only the public text field from an unfinished structured reply.
export function streamingReply(raw,structured=true){
 let text=String(raw??'');
 if(structured&&text.trimStart().startsWith('{')){
  const match=text.match(/^\s*\{\s*"text"\s*:\s*"/);if(!match)return '';
  const rest=text.slice(match[0].length);let encoded='';
  for(let i=0;i<rest.length;i++){const c=rest[i];if(c==='"')break;if(c==='\\'){const size=rest[i+1]==='u'?6:2;if(i+size>rest.length)break;encoded+=rest.slice(i,i+size);i+=size-1;}else encoded+=c;}
  try{text=JSON.parse('"'+encoded+'"')}catch{return '';}
 }
 if(text.trimStart().startsWith('<')&&'<conversation-title>'.startsWith(text.trimStart()))return '';
 if(/^\s*<conversation-title>/.test(text)&&!text.includes('</conversation-title>'))return '';
 return conversationReply(text,true).text;
}
