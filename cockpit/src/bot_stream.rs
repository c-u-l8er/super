//! Bounded incremental provider decoding. Partial proposals never leave this adapter.
use serde_json::{json,Value};
use std::collections::BTreeMap;
#[derive(Default)]
pub struct Stream { pub text:String, tools:BTreeMap<usize,Value>, pub done:bool, reason:String, pending:Vec<u8>, event:String, total:usize }
impl Stream {
 pub fn feed(&mut self,p:&str,bytes:&[u8])->Result<(),String>{
  self.total+=bytes.len();if self.total>4*1_048_576{return Err("The provider reply exceeded the size limit.".into())}
  self.pending.extend_from_slice(bytes);
  while let Some(end)=self.pending.iter().position(|b|*b==b'\n'){
   let raw:Vec<_>=self.pending.drain(..=end).collect();let line=std::str::from_utf8(&raw).map_err(|_|"Invalid provider text encoding.")?.trim_end_matches(['\r','\n']);
   if p=="ollama" {if !line.is_empty(){self.value(p,serde_json::from_str(line).map_err(|_|"Unreadable provider stream.")?)?;}}
   else if line.is_empty(){self.event(p)?;}else if let Some(data)=line.strip_prefix("data:"){if !self.event.is_empty(){self.event.push('\n')}self.event.push_str(data.trim_start());}
  }Ok(())
 }
 fn event(&mut self,p:&str)->Result<(),String>{let data=std::mem::take(&mut self.event);if data.is_empty(){return Ok(())}if data=="[DONE]"{self.done=true;return Ok(())}self.value(p,serde_json::from_str(&data).map_err(|_|"Unreadable provider stream.")?)}
 fn value(&mut self,p:&str,v:Value)->Result<(),String>{
  if v.get("error").is_some()||v["type"]=="error"{return Err("The provider stopped the reply with an error.".into())}
  if p=="anthropic"{
   let index=v["index"].as_u64().unwrap_or(0) as usize;
   match v["type"].as_str().unwrap_or(""){
    "content_block_start"=>{let b=&v["content_block"];if b["type"]=="tool_use"{self.tools.insert(index,json!({"name":b["name"],"arguments":""}));}else if let Some(t)=b["text"].as_str(){self.text.push_str(t)}},
    "content_block_delta"=>{let d=&v["delta"];if let Some(t)=d["text"].as_str(){self.text.push_str(t)}if let Some(t)=d["partial_json"].as_str(){let tool=self.tools.get_mut(&index).ok_or("Unexpected provider tool fragment.")?;let s=tool["arguments"].as_str().unwrap_or("").to_owned()+t;tool["arguments"]=json!(s);}},
    "message_delta"=>self.reason=v["delta"]["stop_reason"].as_str().unwrap_or("").into(),
    "message_stop"=>self.done=true,_=>{}
   }
  }else if p=="openai"{
   let c=&v["choices"][0];if let Some(t)=c["delta"]["content"].as_str(){self.text.push_str(t)}
   if let Some(reason)=c["finish_reason"].as_str(){self.reason=reason.into();}
   if let Some(calls)=c["delta"]["tool_calls"].as_array(){for call in calls{let i=call["index"].as_u64().ok_or("Missing provider tool index.")? as usize;let tool=self.tools.entry(i).or_insert(json!({"name":"","arguments":""}));for key in ["name","arguments"]{if let Some(s)=call["function"][key].as_str(){tool[key]=json!(tool[key].as_str().unwrap_or("").to_owned()+s);}}}}
  }else{
   if let Some(t)=v["message"]["content"].as_str(){self.text.push_str(t)}
   if let Some(calls)=v["message"]["tool_calls"].as_array(){for c in calls{self.tools.insert(self.tools.len(),c["function"].clone());}}
   if v["done"]==true{self.done=true;self.reason=v["done_reason"].as_str().unwrap_or("").into();}
  }
  if self.text.len()>160000||self.tools.len()>8{return Err("The provider reply exceeded the supported limits.".into())}Ok(())
 }
 pub fn finish(mut self,p:&str)->Result<Value,String>{
  self.feed(p,b"\n\n")?;
  if !self.done{return Err("The provider stream ended before completion. No proposal was accepted.".into())}
  if ["length","max_tokens"].contains(&self.reason.as_str()){return Err("The reply reached its output limit. Ask for a smaller step.".into())}
  let tools:Vec<_>=self.tools.into_values().collect();
  Ok(if p=="anthropic"{let mut content=vec![json!({"type":"text","text":self.text})];for t in tools{let input=serde_json::from_str::<Value>(t["arguments"].as_str().unwrap_or("{}")).map_err(|_|"Incomplete provider tool arguments.")?;content.push(json!({"type":"tool_use","name":t["name"],"input":input}));}json!({"content":content,"stop_reason":self.reason})}
   else {let message=json!({"content":self.text,"tool_calls":tools.into_iter().map(|t|json!({"function":t})).collect::<Vec<_>>()});if p=="openai"{json!({"choices":[{"message":message,"finish_reason":self.reason}]})}else{json!({"message":message})}})
 }
}
#[cfg(test)]mod tests{use super::*;
 #[test]fn fragments_are_live_and_utf8_safe(){let mut s=Stream::default();let wire="{\"message\":{\"content\":\"Hé\"},\"done\":false}\n";for b in wire.as_bytes(){s.feed("ollama",&[*b]).unwrap()}assert_eq!(s.text,"Hé");assert!(!s.done);s.feed("ollama",b"{\"message\":{\"content\":\"llo\"},\"done\":true}\n").unwrap();assert_eq!(s.finish("ollama").unwrap()["message"]["content"],"Héllo");}
 #[test]fn incomplete_is_not_a_completed_reply(){let mut s=Stream::default();s.feed("openai",b"data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n").unwrap();assert_eq!(s.text,"partial");assert!(s.finish("openai").is_err());}
 #[test]fn sse_tool_fragments_are_assembled_only_at_completion(){let mut s=Stream::default();for v in [json!({"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"open_workspace","arguments":"{\"name\":"}}]}}]}),json!({"choices":[{"delta":{"content":"Ready","tool_calls":[{"index":0,"function":{"arguments":"\"Test\"}"}}]},"finish_reason":"tool_calls"}]})]{s.feed("openai",format!("data: {v}\n\n").as_bytes()).unwrap()}s.feed("openai",b"data: [DONE]\n\n").unwrap();assert_eq!(s.finish("openai").unwrap()["choices"][0]["message"]["tool_calls"][0]["function"]["arguments"],"{\"name\":\"Test\"}");}
 #[test]fn anthropic_text_and_stop(){let mut s=Stream::default();for v in [json!({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}),json!({"type":"message_delta","delta":{"stop_reason":"end_turn"}}),json!({"type":"message_stop"})]{s.feed("anthropic",format!("event: ignored\ndata: {v}\n\n").as_bytes()).unwrap()}assert_eq!(s.finish("anthropic").unwrap()["content"][0]["text"],"Hi");}
}
