// Presentation metadata in a requested reply header; never an app action.
export const titleInstruction='For this conversation’s first completed reply, begin the text field with <conversation-title>A short descriptive title, at most 80 characters</conversation-title>, then write your normal reply. This header is presentation metadata, not part of the conversation prose.';
export function conversationReply(text,requested){
 const raw=String(text??'');if(!requested)return {text:raw};
 const match=raw.match(/^\s*<conversation-title>([^<>\r\n]{1,100})<\/conversation-title>\s*/);
 if(!match)return {text:raw};const title=match[1].trim().replace(/\s+/g,' ').slice(0,80);
 return title?{title,text:raw.slice(match[0].length)}:{text:raw};
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
