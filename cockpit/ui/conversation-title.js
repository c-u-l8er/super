// Presentation metadata in a requested reply header; never an app action.
export const titleInstruction='For this conversation’s first completed reply, begin the text field with <conversation-title>A short descriptive title, at most 80 characters</conversation-title>, then write your normal reply. This header is presentation metadata, not part of the conversation prose.';
export function conversationReply(text,requested){
 const raw=String(text??'');if(!requested)return {text:raw};
 const match=raw.match(/^\s*<conversation-title>([^<>\r\n]{1,100})<\/conversation-title>\s*/);
 if(!match)return {text:raw};const title=match[1].trim().replace(/\s+/g,' ').slice(0,80);
 return title?{title,text:raw.slice(match[0].length)}:{text:raw};
}
