// Regression cover for dt_0051: archiving a local bot profile must retain its identity, SURVIVE a rollback to the
// currently shipped build, and never touch conversation or provider storage.
// Run with: node --test tools/bot-roster-archive-test.mjs
// No DOM, no dependencies: the store is exercised against a Map-backed fake storage.
import test from 'node:test';
import assert from 'node:assert/strict';
import {createBotRoster,ROSTER_KEY,ARCHIVE_KEY} from '../cockpit/ui/bot-roster.js';

const assistant={id:'assistant',name:'Workspace assistant',role:'Planning',instructions:'Help organize work into clear, reviewable steps.',provider:'codex',group:'General'};
const profile=(id,extra={})=>({id,name:`Bot ${id}`,role:'Research',instructions:`Instructions for ${id}`,provider:'claude',group:'Field',...extra});
// The exact field order clean() emits, so a stored record can be compared byte for byte with the shipped serialisation.
const canonical=b=>({id:b.id,name:b.name,role:b.role,instructions:b.instructions,group:b.group,provider:b.provider});
const shipped=bots=>JSON.stringify({version:1,bots:bots.map(canonical)});
function makeStorage(seed={}){
  const map=new Map(Object.entries(seed)),reads=[],writes=[];let failing=null;
  return {
    map,reads,writes,
    fail(on=true){failing=on?()=>true:null;},
    failKey(key){failing=k=>k===key;},
    clearFailure(){failing=null;},
    getItem(key){reads.push(key);return map.has(key)?map.get(key):null;},
    setItem(key,value){writes.push(key);if(failing&&failing(key))throw new Error('QuotaExceededError: the disk is full');map.set(key,String(value));},
    removeItem(key){writes.push(key);map.delete(key);},
  };
}
const seeded=(bots,archived=null)=>makeStorage(archived?{[ROSTER_KEY]:shipped(bots),[ARCHIVE_KEY]:shipped(archived)}:{[ROSTER_KEY]:shipped(bots)});
const record=(storage,key)=>{const raw=storage.map.get(key);return raw===undefined?null:JSON.parse(raw);};

test('archive removes the profile from list() while its identity survives',()=>{
  const storage=seeded([assistant,profile('scout')]);
  const roster=createBotRoster(storage);
  assert.equal(roster.error,null);
  assert.equal(roster.archiveError,null);
  assert.deepEqual(roster.list().map(b=>b.id),['assistant','scout']);
  const archived=roster.archive('scout');
  assert.equal(archived.id,'scout');
  assert.deepEqual(roster.list().map(b=>b.id),['assistant']);
  assert.equal(roster.get('scout'),null);
  assert.deepEqual(roster.listArchived().map(b=>b.id),['scout']);
  assert.deepEqual(roster.getArchived('scout'),profile('scout'));
  assert.deepEqual(record(storage,ARCHIVE_KEY).bots.map(b=>b.id),['scout']);
});

test('restore returns the same id and the same fields',()=>{
  const storage=seeded([assistant,profile('scout',{name:'Scout',group:'Research',instructions:'Keep the survey notes.'})]);
  const roster=createBotRoster(storage);
  const before=roster.get('scout');
  roster.archive('scout');
  const restored=roster.restore('scout');
  assert.equal(restored.id,'scout');
  assert.deepEqual(restored,before);
  assert.deepEqual(roster.get('scout'),before);
  assert.deepEqual(roster.listArchived(),[]);
  assert.deepEqual(roster.list().map(b=>b.id),['assistant','scout']);
});

test('the workspace assistant can never be archived',()=>{
  const storage=seeded([assistant,profile('scout')]);
  const roster=createBotRoster(storage);
  assert.throws(()=>roster.archive('assistant'),/cannot be archived/);
  assert.deepEqual(roster.list().map(b=>b.id),['assistant','scout']);
  assert.deepEqual(roster.listArchived(),[]);
  assert.deepEqual(storage.writes,[]); // refused before any write to either key
  assert.equal(createBotRoster(storage).error,null);
});

test('an unknown id is refused by archive and by restore',()=>{
  const storage=seeded([assistant,profile('scout')]);
  const roster=createBotRoster(storage);
  assert.throws(()=>roster.archive('ghost'),/not an active local profile/);
  assert.throws(()=>roster.restore('ghost'),/not an archived local profile/);
  assert.deepEqual(roster.list().map(b=>b.id),['assistant','scout']);
  assert.deepEqual(roster.listArchived(),[]);
  assert.deepEqual(storage.writes,[]);
});

test('a failed setItem throws and leaves list(), listArchived() and both stored records untouched',()=>{
  const storage=seeded([assistant,profile('scout'),profile('atlas')]);
  const roster=createBotRoster(storage);
  roster.archive('atlas');
  const activeBefore=roster.list(),archivedBefore=roster.listArchived();
  const rosterBefore=storage.map.get(ROSTER_KEY),archiveBefore=storage.map.get(ARCHIVE_KEY);
  storage.fail(true);
  assert.throws(()=>roster.archive('scout'),/Free local storage/);
  assert.throws(()=>roster.restore('atlas'),/Free local storage/);
  assert.throws(()=>roster.save(profile('new-bot')),/Free local storage/);
  storage.clearFailure();
  assert.deepEqual(roster.list(),activeBefore);
  assert.deepEqual(roster.listArchived(),archivedBefore);
  assert.equal(storage.map.get(ROSTER_KEY),rosterBefore);
  assert.equal(storage.map.get(ARCHIVE_KEY),archiveBefore);
});

test('the active roster record is byte for byte what the shipped build writes and the archive lives under its own key',()=>{
  const storage=seeded([assistant,profile('scout')]);
  const roster=createBotRoster(storage);
  roster.archive('scout');
  const rosterRaw=storage.map.get(ROSTER_KEY);
  assert.equal(rosterRaw,shipped([assistant]));
  assert.deepEqual(Object.keys(JSON.parse(rosterRaw)),['version','bots']);
  assert.ok(!rosterRaw.includes('archived'),'the roster record must carry no archived key');
  const archive=record(storage,ARCHIVE_KEY);
  assert.equal(archive.version,1);
  assert.deepEqual(archive.bots.map(b=>b.id),['scout']);
  assert.deepEqual(Object.keys(archive.bots[0]).sort(),['group','id','instructions','name','provider','role']);
  roster.restore('scout');
  assert.equal(storage.map.get(ROSTER_KEY),shipped([assistant,profile('scout')]));
  assert.deepEqual(record(storage,ARCHIVE_KEY),{version:1,bots:[]});
  // Corrected invariant: exactly the two roster keys, and nothing belonging to conversations or providers.
  assert.deepEqual([...new Set([...storage.reads,...storage.writes,...storage.map.keys()])].sort(),[ARCHIVE_KEY,ROSTER_KEY].sort());
  for(const key of [...storage.writes,...storage.reads,...storage.map.keys()])
    assert.ok(!/^super-(conversations|provider-preferences|last-provider)/.test(key),`roster storage touched ${key}`);
});

test('a fresh createBotRoster over the same storage sees the same split',()=>{
  const storage=seeded([assistant,profile('scout'),profile('atlas')]);
  const roster=createBotRoster(storage);
  roster.archive('atlas');
  const reloaded=createBotRoster(storage);
  assert.equal(reloaded.error,null);
  assert.equal(reloaded.archiveError,null);
  assert.deepEqual(reloaded.list().map(b=>b.id),roster.list().map(b=>b.id));
  assert.deepEqual(reloaded.listArchived(),roster.listArchived());
  assert.deepEqual(reloaded.listArchived()[0],profile('atlas'));
  assert.equal(reloaded.get('atlas'),null);
  assert.deepEqual(reloaded.restore('atlas'),profile('atlas'));
  const third=createBotRoster(storage);
  assert.equal(third.error,null);
  assert.deepEqual(third.list().map(b=>b.id),['assistant','scout','atlas']);
  assert.deepEqual(third.listArchived(),[]);
});

test('an archived id cannot be reused by save while it is archived',()=>{
  const storage=seeded([assistant,profile('scout')]);
  const roster=createBotRoster(storage);
  roster.archive('scout');
  const rosterBefore=storage.map.get(ROSTER_KEY),archiveBefore=storage.map.get(ARCHIVE_KEY);
  assert.throws(()=>roster.save(profile('scout',{name:'Impostor'})),/archived/);
  assert.equal(storage.map.get(ROSTER_KEY),rosterBefore);
  assert.equal(storage.map.get(ARCHIVE_KEY),archiveBefore);
  assert.deepEqual(roster.listArchived().map(b=>b.name),['Bot scout']);
  assert.deepEqual(roster.restore('scout'),profile('scout'));
});

test('the 50 profile cap counts active and archived profiles together across both keys',()=>{
  const many=[assistant,...Array.from({length:49},(_,i)=>profile(`bot-${i}`))];
  const storage=seeded(many);
  const roster=createBotRoster(storage);
  assert.equal(roster.error,null);
  roster.archive('bot-0');
  assert.throws(()=>roster.save(profile('overflow')),/Up to 50 bot profiles/);
  assert.equal(roster.list().length+roster.listArchived().length,50);
  const reloaded=createBotRoster(storage);
  assert.equal(reloaded.error,null);
  assert.equal(reloaded.archiveError,null);
  assert.equal(reloaded.list().length+reloaded.listArchived().length,50);
  // Over the combined cap the archive key is the part that is refused; the active roster still loads.
  const over=createBotRoster(seeded(many,[profile('extra')]));
  assert.equal(over.error,null);
  assert.match(over.archiveError,/archived bot profiles/);
  assert.equal(over.list().length,50);
});

test('an older build that rewrites super-bot-roster-v1 leaves the archived profiles intact and still restorable',()=>{
  const storage=seeded([assistant,profile('scout'),profile('atlas')]);
  const roster=createBotRoster(storage);
  roster.archive('atlas');
  // Simulate the currently shipped build at ~/build/super-old-runtime: it knows only {version:1,bots:[...]} and
  // reserialises the WHOLE roster record whenever a bot is created or edited.
  const oldBuildRead=JSON.parse(storage.map.get(ROSTER_KEY));
  assert.equal(oldBuildRead.version,1);
  assert.deepEqual(oldBuildRead.bots.map(b=>b.id),['assistant','scout']);
  storage.setItem(ROSTER_KEY,JSON.stringify({version:1,bots:[...oldBuildRead.bots,canonical(profile('legacy'))]}));
  // Back on the current build.
  const afterRollback=createBotRoster(storage);
  assert.equal(afterRollback.error,null);
  assert.equal(afterRollback.archiveError,null);
  assert.deepEqual(afterRollback.list().map(b=>b.id),['assistant','scout','legacy']);
  assert.deepEqual(afterRollback.listArchived().map(b=>b.id),['atlas']);
  assert.deepEqual(afterRollback.getArchived('atlas'),profile('atlas'));
  assert.deepEqual(afterRollback.restore('atlas'),profile('atlas'));
  assert.deepEqual(afterRollback.list().map(b=>b.id),['assistant','scout','legacy','atlas']);
  assert.deepEqual(createBotRoster(storage).list().map(b=>b.id),['assistant','scout','legacy','atlas']);
});

test('a failed write to the second key leaves list() and listArchived() unchanged and the profile reachable',()=>{
  const storage=seeded([assistant,profile('scout'),profile('atlas')]);
  const roster=createBotRoster(storage);
  roster.archive('atlas');
  const activeBefore=roster.list(),archivedBefore=roster.listArchived();
  // archive() writes the archive key first, then the roster key: fail the SECOND write.
  storage.failKey(ROSTER_KEY);
  assert.throws(()=>roster.archive('scout'),/Free local storage/);
  storage.clearFailure();
  assert.deepEqual(roster.list(),activeBefore);
  assert.deepEqual(roster.listArchived(),archivedBefore);
  const afterArchiveFailure=createBotRoster(storage);
  assert.equal(afterArchiveFailure.error,null);
  assert.equal(afterArchiveFailure.archiveError,null);
  assert.deepEqual(afterArchiveFailure.list().map(b=>b.id),['assistant','scout']); // still reachable: not archived
  assert.deepEqual(afterArchiveFailure.listArchived().map(b=>b.id),['atlas']);
  assert.equal(afterArchiveFailure.archive('scout').id,'scout'); // retry after the failure succeeds
  assert.deepEqual(afterArchiveFailure.listArchived().map(b=>b.id),['atlas','scout']);
  // restore() writes the roster key first, then the archive key: fail the SECOND write.
  const activeBeforeRestore=afterArchiveFailure.list(),archivedBeforeRestore=afterArchiveFailure.listArchived();
  storage.failKey(ARCHIVE_KEY);
  assert.throws(()=>afterArchiveFailure.restore('atlas'),/Free local storage/);
  storage.clearFailure();
  assert.deepEqual(afterArchiveFailure.list(),activeBeforeRestore);
  assert.deepEqual(afterArchiveFailure.listArchived(),archivedBeforeRestore);
  const afterRestoreFailure=createBotRoster(storage);
  assert.equal(afterRestoreFailure.error,null);
  assert.equal(afterRestoreFailure.archiveError,null);
  assert.deepEqual(afterRestoreFailure.list().map(b=>b.id),['assistant','atlas']); // still reachable: restored
  assert.deepEqual(afterRestoreFailure.listArchived().map(b=>b.id),['scout']);
  assert.deepEqual(afterRestoreFailure.get('atlas'),profile('atlas'));
});

test('a corrupt archive key surfaces its own error and leaves the active roster loadable',()=>{
  const storage=seeded([assistant,profile('scout')]);
  storage.map.set(ARCHIVE_KEY,'{"version":1,"bots":[{"id":"atl'); // truncated write
  const roster=createBotRoster(storage);
  assert.equal(roster.error,null);
  assert.deepEqual(roster.list().map(b=>b.id),['assistant','scout']);
  assert.deepEqual(roster.get('scout'),profile('scout'));
  assert.match(roster.archiveError,/archived bot profiles/);
  assert.throws(()=>roster.listArchived(),/archived bot profiles/);
  assert.throws(()=>roster.getArchived('scout'),/archived bot profiles/);
  assert.throws(()=>roster.archive('scout'),/archived bot profiles/);
  assert.throws(()=>roster.restore('scout'),/archived bot profiles/);
  assert.equal(roster.save(profile('atlas')).id,'atlas'); // the active roster keeps working
  assert.deepEqual(storage.writes,[ROSTER_KEY]);
  assert.equal(storage.map.get(ARCHIVE_KEY),'{"version":1,"bots":[{"id":"atl'); // corrupt record preserved
  assert.equal(storage.map.get(ROSTER_KEY),shipped([assistant,profile('scout'),profile('atlas')]));
  // Never the reverse: a broken active roster must not report an empty archive.
  const broken=makeStorage({[ROSTER_KEY]:'{oops',[ARCHIVE_KEY]:shipped([profile('atlas')])});
  const brokenRoster=createBotRoster(broken);
  assert.match(brokenRoster.error,/Could not load bot profiles/);
  assert.throws(()=>brokenRoster.listArchived(),/Could not load bot profiles/);
  assert.throws(()=>brokenRoster.save(profile('x')),/Could not load bot profiles/);
  assert.throws(()=>brokenRoster.archive('scout'),/Could not load bot profiles/);
  assert.deepEqual(broken.writes,[]);
  assert.equal(broken.map.get(ARCHIVE_KEY),shipped([profile('atlas')]));
});
