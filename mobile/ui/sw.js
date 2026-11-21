/* Super Mobile's service worker: it only shows alerts. It caches nothing and answers no page requests, so a
 * stale copy can never stand in for live state. An alert carries its own text; a tap opens Needs me. */
const HOME='/mobile#/attention';
// Only this companion's own places open from an alert: never a URL the message carries from elsewhere.
const place=url=>typeof url==='string'&&/^\/(mobile)?(#\/[a-z]+)?$/.test(url)?url:HOME;
const words=(v,max,otherwise)=>typeof v==='string'&&v.trim()?v.slice(0,max):otherwise;

self.addEventListener('install',()=>self.skipWaiting());
self.addEventListener('activate',event=>event.waitUntil(self.clients.claim()));
self.addEventListener('push',event=>{
  let m={};try{m=event.data?event.data.json():{};}catch{}
  const shown=self.registration.showNotification(words(m.title,80,'Super'),{
    body:words(m.body,300,'Something is waiting on you.'),
    // One tag: a newer alert takes the place of the one before, rather than piling up.
    tag:words(m.tag,40,'super-waiting'),renotify:true,icon:'/icon-512.png',data:{url:place(m.url)},
  });
  const n=Number.isInteger(m.count)&&m.count>=0&&m.count<1000?m.count:null,nav=self.navigator;
  const badge=n===null?Promise.resolve():Promise.resolve().then(()=>n?nav.setAppBadge?.(n):nav.clearAppBadge?.()).catch(()=>{});
  event.waitUntil(Promise.all([shown,badge]));
});
self.addEventListener('notificationclick',event=>{
  event.notification.close();
  const url=place(event.notification.data?.url);
  event.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(async list=>{
    for(const c of list){try{const w=c.navigate?await c.navigate(url):c;return (w??c).focus();}catch{}}
    return self.clients.openWindow(url);
  }));
});
