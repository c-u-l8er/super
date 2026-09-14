// Product adapter for the shared road. Super retains its own webview and session.
let superVisible=false;
const roadApply=apply;
apply=async function(op,args={},options={}) {
  if(op==='promote'&&args.package==='super') {
    try {
      await invoke('super_sign',{visible:true,rect:args.rect});superVisible=true;
      return {ok:true,result:{pane:{package:'super',generation:gen()},hosted:true}};
    } catch(e) { return {ok:false,why:String(e)}; }
  }
  if(op==='demote'&&superVisible) {
    try {await invoke('super_sign',{visible:false});superVisible=false;return {ok:true,result:{hidden:'super',sessionRetained:true}};}
    catch(e){return {ok:false,why:String(e)};}
  }
  return roadApply(op,args,options);
};
function superCatalogue(catalogue) {
  document.getElementById('cockpit').hidden=true;
  document.getElementById('integration-status').textContent='Super is the live app in its road sign. Leave window returns to the road and keeps your work open.';
  const sign={primitives:[{kind:'rect',x:0,y:0,w:240,h:132},{kind:'text',x:16,y:38,size:24,weight:700,value:'Super (CD)'},{kind:'text',x:16,y:70,size:14,value:'Your work, one next step'},{kind:'text',x:16,y:106,size:13,value:'Enter the live window →'}]};
  document.getElementById('enter').innerHTML='↖ SUPER (CD)<small>Enter your work window</small>';
  document.getElementById('enter').onclick=async()=>show(await promote('super'));
  return {...catalogue,packages:[{id:'super',sign}]};
}
