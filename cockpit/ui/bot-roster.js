// Device-local conversational identities. These records confer no runtime authority.
export const ROSTER_KEY = 'super-bot-roster-v1';
export const providers = ['codex', 'claude', 'ollama', 'openai', 'anthropic'];
const initial = {id:'assistant',name:'Workspace assistant',role:'Planning',instructions:'Help organize work into clear, reviewable steps.',provider:'codex',group:'General'};
function clean(b) {
  const result = {};
  for (const [key,max] of [['id',100],['name',80],['role',100],['instructions',4000],['group',80]]) {
    if(typeof b[key] !== 'string' || b[key].length > max || (key !== 'instructions' && !b[key].trim())) throw new Error('Enter a valid bot name, role, and group.');
    result[key]=b[key].trim();
  }
  if(!/^[a-zA-Z0-9_-]+$/.test(result.id)||!providers.includes(b.provider)) throw new Error('Invalid bot identity or provider.');
  return {...result,provider:b.provider};
}
export function createBotRoster(storage) {
  let bots=[{...initial}],error=null;
  try {
    const raw=storage.getItem(ROSTER_KEY);
    if(raw){const value=JSON.parse(raw);if(value.version!==1||!Array.isArray(value.bots)||value.bots.length>50)throw new Error('Unsupported roster format');
      const loaded=value.bots.map(clean);if(new Set(loaded.map(b=>b.id)).size!==loaded.length||!loaded.some(b=>b.id==='assistant'))throw new Error('Invalid roster identities');bots=loaded;}
  }catch(e){error=`Could not load bot profiles: ${e.message}. Existing data is preserved.`;}
  return {
    error,
    list:()=>bots.map(b=>({...b})),
    get:id=>{const b=bots.find(b=>b.id===id);return b?{...b}:null;},
    save(value){
      if(error)throw new Error(error);
      const b=clean({...value,id:value.id||crypto.randomUUID()});
      const next=bots.some(x=>x.id===b.id)?bots.map(x=>x.id===b.id?b:x):[...bots,b];
      if(next.length>50)throw new Error('Up to 50 bot profiles are supported on this device.');
      try{storage.setItem(ROSTER_KEY,JSON.stringify({version:1,bots:next}));}catch{throw new Error('Could not save the bot. Free local storage and try again.');}
      bots=next;return {...b};
    },
  };
}
