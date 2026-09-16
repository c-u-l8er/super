// Device-local conversational identities. These records confer no runtime authority.
export const ROSTER_KEY = 'super-bot-roster-v1';
export const ARCHIVE_KEY = 'super-bot-roster-archived-v1';
export const providers = ['codex', 'claude', 'ollama', 'openai', 'anthropic'];
const MAX_PROFILES = 50;
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
// Both keys hold the same record shape, {version:1,bots:[...]} of cleaned entries, and are parsed by the same reader.
function readRecord(storage,key,label){
  const raw=storage.getItem(key);
  if(!raw)return null;
  const value=JSON.parse(raw);
  if(!value||typeof value!=='object'||value.version!==1||!Array.isArray(value.bots))throw new Error(`Unsupported ${label} format`);
  const list=value.bots.map(clean);
  if(new Set(list.map(b=>b.id)).size!==list.length)throw new Error(`Invalid ${label} identities`);
  return list;
}
export function createBotRoster(storage) {
  // STORAGE LAYOUT. super-bot-roster-v1 keeps EXACTLY the shipped shape {version:1,bots:[...]} with no additional
  // top-level key, so an older build reads it, rewrites it on any save, and cannot drop something it never knew about.
  // Archived profiles live in their own key, super-bot-roster-archived-v1, in the same {version:1,bots:[...]} shape
  // with identically cleaned entries. An older build never reads or writes that key, so archiving is rollback-
  // SURVIVABLE, not merely rollback-readable: a profile archived here is still archived after a rollback, a save on
  // the old build, and a return to this build.
  //
  // WRITE ORDER. Archiving and restoring each write two keys and either write can fail, so the key that GAINS the
  // profile is always written before the key that LOSES it:
  //   archive(id)  -> archive key first (it gains the profile), then the roster key (it loses it).
  //   restore(id)  -> roster key first (it gains the profile), then the archive key (it loses it).
  // If the second write throws, the profile is durably present in BOTH keys for a moment - still reachable from a
  // surface - and neither in-memory list is mutated, so the person can simply retry; both writes are idempotent.
  // The opposite order would leave a window in which the profile is in NEITHER key, which is the unreachable saved
  // history that this change exists to prevent.
  //
  // DUPLICATE RESOLUTION. A load that finds an id in both keys treats the ACTIVE roster as authoritative and drops the
  // archived duplicate, so an interrupted archive rolls back and an interrupted restore completes. Either way the
  // profile is reachable. The next archive-key write clears the duplicate from storage.
  //
  // INDEPENDENT FAILURE. A broken archive key surfaces its own error and leaves the active roster loading, listing and
  // saving. The reverse is never allowed: if the active roster fails to load, the archive reports that same failure
  // rather than claiming to be empty.
  //
  // Archiving and restoring move roster membership only: no super-conversations-v1*, super-provider-preferences* or
  // super-last-provider* key is read, written, migrated or deleted here.
  let bots=[{...initial}],archived=[],error=null,archiveError=null;
  try {
    const loaded=readRecord(storage,ROSTER_KEY,'roster');
    if(loaded){
      if(loaded.length>MAX_PROFILES)throw new Error('Unsupported roster format');
      if(!loaded.some(b=>b.id==='assistant'))throw new Error('Invalid roster identities');
      bots=loaded;
    }
  } catch(e){error=`Could not load bot profiles: ${e.message}. Existing data is preserved.`;}
  if(error){
    archiveError=error; // Every mutation is blocked while the active roster is broken; never report an empty archive.
  } else {
    try {
      const kept=readRecord(storage,ARCHIVE_KEY,'archive');
      if(kept){
        const active=new Set(bots.map(b=>b.id));
        const resolved=kept.filter(b=>!active.has(b.id)); // interrupted archive/restore: the active roster wins
        if(bots.length+resolved.length>MAX_PROFILES)throw new Error('Unsupported archive format');
        archived=resolved;
      }
    } catch(e){archiveError=`Could not load archived bot profiles: ${e.message}. Existing data is preserved.`;}
  }
  const writeRoster=(next,failure)=>{try{storage.setItem(ROSTER_KEY,JSON.stringify({version:1,bots:next}));}catch{throw new Error(failure);}};
  const writeArchive=(next,failure)=>{try{storage.setItem(ARCHIVE_KEY,JSON.stringify({version:1,bots:next}));}catch{throw new Error(failure);}};
  const requireRoster=()=>{if(error)throw new Error(error);};
  const requireArchive=()=>{requireRoster();if(archiveError)throw new Error(archiveError);};
  return {
    error,
    archiveError,
    list:()=>bots.map(b=>({...b})),
    get:id=>{const b=bots.find(b=>b.id===id);return b?{...b}:null;},
    listArchived(){requireArchive();return archived.map(b=>({...b}));},
    getArchived(id){requireArchive();const b=archived.find(b=>b.id===id);return b?{...b}:null;},
    save(value){
      // Writes the roster key only, in exactly the shipped shape. While the archive key is unreadable the archived-id
      // check below has nothing to compare against; that is reported through archiveError, not by blocking saves.
      requireRoster();
      const b=clean({...value,id:value.id||crypto.randomUUID()});
      if(archived.some(x=>x.id===b.id))throw new Error('That id belongs to an archived bot. Restore it from Archived bots instead.');
      const next=bots.some(x=>x.id===b.id)?bots.map(x=>x.id===b.id?b:x):[...bots,b];
      if(next.length+archived.length>MAX_PROFILES)throw new Error('Up to 50 bot profiles are supported on this device.');
      writeRoster(next,'Could not save the bot. Free local storage and try again.');
      bots=next;return {...b};
    },
    archive(id){
      requireArchive();
      if(id==='assistant')throw new Error('The workspace assistant cannot be archived.'); // refused before any write
      const bot=bots.find(b=>b.id===id);if(!bot)throw new Error('That bot is not an active local profile on this device.');
      const nextArchived=[...archived,{...bot}],nextBots=bots.filter(b=>b.id!==id);
      const failure='Could not archive the bot. Free local storage and try again.';
      writeArchive(nextArchived,failure); // the archive gains the profile first
      writeRoster(nextBots,failure);      // only then does the roster lose it
      bots=nextBots;archived=nextArchived;return {...bot};
    },
    restore(id){
      requireArchive();
      const bot=archived.find(b=>b.id===id);if(!bot)throw new Error('That bot is not an archived local profile on this device.');
      if(bots.some(b=>b.id===id))throw new Error('An active bot already uses that id.');
      const nextBots=[...bots,{...bot}],nextArchived=archived.filter(b=>b.id!==id);
      const failure='Could not restore the bot. Free local storage and try again.';
      writeRoster(nextBots,failure);      // the roster gains the profile first
      writeArchive(nextArchived,failure); // only then does the archive lose it
      bots=nextBots;archived=nextArchived;return {...bot};
    },
  };
}
