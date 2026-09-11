const knownRegistrations=new Map();
export function heldProjection(current) {
  const c=current();return c?.frame?.projection&&!c.withdrawn&&!c.unavailable&&!c.stalled&&document.querySelector('#world [data-screen]')?c.frame.projection:null;
}
export function runtimeWorld(current){const w=current()?.frame?.world;return w?JSON.stringify([w.world_incarnation,w.world_generation,w.projection_epoch]):null;}
export function registeredBot(current,id){
  const p=heldProjection(current),world=runtimeWorld(current);
  if(p)knownRegistrations.set(world,new Set(Object.values(p.bots??{}).map(b=>b.client_ref)));
  return Object.values(p?.bots??{}).find(b=>b.client_ref===id)??null;
}
export function registrationUnavailable(current,id){return !heldProjection(current)&&knownRegistrations.get(runtimeWorld(current))?.has(id);}
export function botFields(bot,workspace){return {client_ref:bot.id,workspace_ref:workspace,name:bot.name,role:bot.role,instructions:bot.instructions,group:bot.group||'General',provider:bot.provider};}
export function profileOf(record){return {id:record.client_ref,name:record.name,role:record.role,instructions:record.instructions,group:record.group,provider:record.provider};}
export function waitForBot(current,world,predicate){
  return new Promise((resolve,reject)=>{
    let timeout;
    function finish(error){clearTimeout(timeout);document.removeEventListener('runtime-view-rendered',check);error?reject(new Error(error)):resolve();}
    function check(){
      if(runtimeWorld(current)!==world)return finish('The runtime world changed. Reopen the bot before continuing.');
      const p=heldProjection(current);if(p&&predicate(p))finish();
    }
    timeout=setTimeout(()=>finish('The request was sent, but a confirming frame did not arrive. Check the bot before retrying.'),10000);
    document.addEventListener('runtime-view-rendered',check);check();
  });
}
