//! A narrow mailbox to the main conversation UI. No runtime or shell commands.
use serde_json::{json,Value};
use std::{collections::VecDeque,sync::{Mutex,OnceLock},time::{Instant,Duration}};
#[derive(Default)]
struct Bridge { frame:Option<(Instant,Value)>, queued:VecDeque<Value>, receipts:VecDeque<Value> }
static BRIDGE:OnceLock<Mutex<Bridge>>=OnceLock::new();
fn bridge()-> &'static Mutex<Bridge>{BRIDGE.get_or_init(||Mutex::new(Bridge::default()))}
pub fn exchange(request:Value)->Result<Value,String>{
 if request.to_string().len()>4_000_000{return Err("Conversation view is too large.".into())}
 let mut b=bridge().lock().map_err(|_|"Conversation bridge busy.")?;
 if let Some(view)=request.get("view"){if !view.is_object(){return Err("Invalid conversation view.".into())}b.frame=Some((Instant::now(),view.clone()));}
 else if let Some((at,_))=&mut b.frame{*at=Instant::now();}
 if let Some(receipts)=request["receipts"].as_array(){for receipt in receipts.iter().take(32){if receipt["id"].is_string(){b.receipts.retain(|r|r["id"]!=receipt["id"]);b.receipts.push_back(receipt.clone());}}}
 while b.receipts.len()>100{b.receipts.pop_front();}
 let requests:Vec<Value>=b.queued.drain(..).collect();
 Ok(json!({"requests":requests}))
}
pub fn view()->Value{
 let Ok(b)=bridge().lock() else{return json!({"available":false})};
 match &b.frame{Some((at,v)) if at.elapsed()<Duration::from_secs(5)=>json!({"available":true,"view":v,"receipts":b.receipts}),_=>json!({"available":false})}
}
pub fn enqueue(request:Value)->Value{
 if request.to_string().len()>12_000{return json!({"error":"Request too large."})}
 let Some(id)=request["id"].as_str() else{return json!({"error":"Request identity required."})};
 if id.len()<16||id.len()>80||!id.bytes().all(|c|c.is_ascii_alphanumeric()||c==b'-'){return json!({"error":"Invalid request identity."})}
 if !["open","create","update","draft","send"].contains(&request["operation"].as_str().unwrap_or("")){return json!({"error":"Unsupported conversation operation."})}
 let Ok(mut b)=bridge().lock() else{return json!({"error":"Conversation bridge busy."})};
 if b.frame.as_ref().map_or(true,|(at,_)|at.elapsed()>Duration::from_secs(5)){return json!({"error":"Desktop conversation view unavailable."})}
 if let Some(receipt)=b.receipts.iter().find(|r|r["id"]==id){return json!({"accepted":true,"receipt":receipt})}
 if let Some(queued)=b.queued.iter().find(|r|r["id"]==id){return if queued==&request{json!({"accepted":true})}else{json!({"error":"Request identity reused with different content."})}}
 if b.queued.len()>=8{return json!({"error":"Conversation queue busy."})}
 b.queued.push_back(request);json!({"accepted":true})
}
#[cfg(test)]mod tests{
 use super::*;
 #[test]fn mailbox_is_bounded_and_deduplicates(){
 exchange(json!({"view":{"active":null}})).unwrap();
 let q=json!({"id":"fixture-request-0001","operation":"draft","text":"hello"});
 assert_eq!(enqueue(q.clone())["accepted"],true);assert_eq!(enqueue(q.clone())["accepted"],true);
 let mut other=q;other["text"]=json!("other");assert!(enqueue(other)["error"].is_string());
 let out=exchange(json!({})).unwrap();assert_eq!(out["requests"].as_array().unwrap().len(),1);
 assert!(enqueue(json!({"id":"fixture-request-0002","operation":"shell"}))["error"].is_string());
 assert!(view()["available"].as_bool().unwrap());
 }
}
