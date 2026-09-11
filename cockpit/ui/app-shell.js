import {initRecordTabs} from './record-tabs.js';
import { updateNavCounts } from './work-guidance.js';
import { describeRecord, renderRecordPage } from './record-page.js';
import { referenceText, readable, reference, referenceWorld } from './references.js';
/* Presentation state only. Runtime facts remain inside the frame-owned world. */
export const screens = [
  ['development-tasks', 'Development tasks', 'Plan reviewable work and keep its acceptance criteria with the assigned bot.'],
  ['mission', 'Mission Control', 'Your work, and what needs your attention.'],
  ['new-workspace', 'New workspace', 'Give your workspace a name. You can add goals and assign work afterward.'],
  ['manage-work', 'Create & manage work', 'Add goals, connect lanes, and manage worker assignments.'],
  ['positions', 'Workspaces', 'Organize your projects and open a workspace to manage its goals.'],
  ['goals', 'Goals', 'Define the outcomes you want and see which lanes are assigned to them.'],
  ['lanes', 'Lanes', 'Connect goals to repositories and actors, then assign workers.'],
  ['runtime-assignments', 'Assignments & state', 'Inspect workspace lineage, lane bindings, and worker state reported by the runtime.'],
  ['repositories', 'Local repositories', 'Connect local Git repositories and see where they are used.'],
  ['capabilities', 'Capabilities', 'Review requests and control the authority currently granted.'],
  ['evidence', 'Evidence', 'Durable records from the runtime, with their original subjects.'],
  ['runtime', 'Runtime', 'Health, connections, and unresolved work reported by the runtime.'],
  ['editor', 'Editor', 'Browse and edit files in your selected local repository.'],
  ['terminal', 'Terminal', 'Run local commands and inspect their output.'],
  ['browser', 'Browser', 'Preview the app running on your machine.'],
  ['agents', 'Agents', 'Peers connected to the runtime.'],
  ['routines', 'Routines', 'Scheduled routines are not projected by this runtime yet.'],
  ['fleet', 'Fleet & placement', 'Compute placement is not projected by this runtime yet.'],
  ['gates', 'Gates', 'Build-gate measurements are not delivered to this app yet.'],
  ['rulings', 'Rulings', 'An obligation and ruling directory is not connected yet.'],
  ['authority', 'Authority', 'Authority records supplied by the current runtime.'],
  ['mobile', 'Mobile', 'Read this runtime from your phone. The companion reads; it cannot act for you.'],
  ['settings', 'Settings', 'Local app and connection information.'],
  ['bots', 'Bots', 'Persistent conversational roles for your work.'],
  ['new-bot', 'Create bot', 'Give a bot a name, role, and provider.'],
  ['edit-bot', 'Edit bot', 'Update this bot’s name and instructions.'],
];
let selected = 'mission';
let routeRevision=0;
export const navigationToken=()=>routeRevision;
let workspace = '';
export function selectedWorkspace() { return workspace; }
export function clearWorkspacePicker() {
  updateNavCounts(null);
  const picker = document.getElementById('workspace-picker');
  picker.replaceChildren(node('option', 'Workspace unavailable'));
  picker.disabled = true;
}
export function syncWorkspacePicker(workspaces) {
  const picker = document.getElementById('workspace-picker');
  if (!workspaces.some(w => w.id === workspace)) workspace = '';
  const desired = [{id: '', name: 'All workspaces'}, ...workspaces];
  const changed = picker.options.length !== desired.length || desired.some((w,i) => picker.options[i]?.value !== w.id || picker.options[i]?.textContent !== (w.name?.trim() || readable(w.id)));
  if (changed) {
    picker.replaceChildren();
    for (const w of desired) {
      const option = node('option', w.name?.trim() || readable(w.id)); option.value = w.id; picker.append(option);
    }
  }
  picker.value = workspace; picker.disabled = false;
}

let recordRegistry=new Map(),currentRecord=null;const viewHistory=[];let historyIndex=-1;
let plannedHeadings = 0;
export function beginFrameLayout() { plannedHeadings = 0;recordRegistry=new Map(); }
export function expectedHeadings() { return plannedHeadings; }
export function node(tag, text, cls) {
  const n = document.createElement(tag);
  if (tag === 'h2') plannedHeadings += 1;
  if (text !== undefined) {if (tag==='p') referenceText(n,text);else n.textContent=tag==='option'?readable(text):text;}
  if (cls) n.className = cls;
  return n;
}
export function panel(id) {
  const [, title, description] = screens.find(s => s[0] === id);
  const n = node('section', undefined, 'app-screen');
  n.dataset.screen = id;
  n.hidden = selected !== id;
  n.append(node('p', 'SUPER / ' + title.toUpperCase(), 'eyebrow'), node('h1', title), node('p', description, 'screen-description'));
  return n;
}
// Native `toggle` is queued for a later task. A frame can replace the
// element before that task saves the choice. Commit presentation state in
// the activation event itself; Enter/Space on summary also generate click.
export function bindDisclosure(element, changed = () => {}) {
  const summary = element.querySelector('summary');
  summary.setAttribute('aria-expanded', String(element.open));
  summary.addEventListener('click', event => {
    event.preventDefault();
    const open = !element.open;
    changed(open);
    element.open = open;
    summary.setAttribute('aria-expanded', String(open));
  });
}
export function detail(record,key,label='View details') {
  recordRegistry.set(key,{record,key,label});const info=describeRecord(record,key,label);
  const row=node('section',undefined,'record-detail');row.dataset.detail=key;
  const button=node('button',undefined,'record-trigger');button.type='button';button.dataset.recordOpen=key;button.title=info.id??info.kind;
  const copy=node('span',undefined,'record-row-copy');copy.append(node('span',info.title,'record-row-title'),node('span',[info.kind,info.status].filter(Boolean).join(' · '),'record-row-subtitle'));
  button.append(copy,node('span','→','record-row-arrow'));button.setAttribute('aria-label',`Open ${info.kind.toLowerCase()}: ${info.title}`);row.append(button);return row;
}
function snapshot(){return {screen:selected,record:currentRecord,workspace,scroll:document.getElementById('workspace-canvas').scrollTop};}
function saveRoute(){if(historyIndex>=0)viewHistory[historyIndex]=snapshot();}
function announceHistory(){document.dispatchEvent(new CustomEvent('navigation-history',{detail:{back:historyIndex>0,forward:historyIndex<viewHistory.length-1}}));}
export function openRecord(key) {
  if(selected==='record'&&currentRecord?.key===key)return;
  routeRevision++;saveRoute();currentRecord={key,origin:referenceWorld()};selected='record';
  viewHistory.splice(++historyIndex);viewHistory.push(snapshot());
  document.dispatchEvent(new Event('record-route-change'));navigate('record',true,true);announceHistory();
}
export function travel(direction){
  const next=historyIndex+direction;if(next<0||next>=viewHistory.length)return;
  const destination=viewHistory[next];if(!document.dispatchEvent(new CustomEvent('before-page-select',{cancelable:true,detail:{id:destination.screen}})))return;
  routeRevision++;saveRoute();historyIndex=next;const view=viewHistory[next];selected=view.screen;currentRecord=view.record;workspace=view.workspace;
  document.dispatchEvent(new Event('workspace-view-change'));document.dispatchEvent(new Event('record-route-change'));
  navigate(selected,true,true);document.getElementById('workspace-canvas').scrollTop=view.scroll;announceHistory();
}
export function recordPage(frame){
  let entry=null;
  if(currentRecord?.origin===referenceWorld()){
    entry=recordRegistry.get(currentRecord.key);
    if(!entry){const id=currentRecord.key.split(':').slice(1).join(':');const ref=reference(id);if(ref)entry={record:ref.record,key:ref.key,label:ref.label};}
  }
  const prev=viewHistory[historyIndex-1];const title=prev?.screen==='record'?'Back to previous record':`Back to ${screens.find(s=>s[0]===prev?.screen)?.[1]??'list'}`;
  const page=renderRecordPage({node,entry,frame,backLabel:title,detail});page.hidden=selected!=='record';return page;
}
export function card(title, value, subtitle) {
  const n = node('article', undefined, 'stat-card');
  n.append(node('p', title, 'stat-label'), node('p', String(value), 'stat-value'));
  if (subtitle) n.append(node('p', subtitle, 'stat-note'));
  return n;
}
export function history(title, window, key) {
  const n = node('section', undefined, 'history-section');
  n.append(node('h2', title));
  if (!window || !Array.isArray(window.recent)) {
    n.append(node('p', 'This runtime has not supplied this history.', 'empty'));
    return n;
  }
  n.append(node('p', `Showing ${window.recent.length} of ${window.total} records · newest first`, 'history-count'));
  if (!window.recent.length) n.append(node('p', 'No records yet.', 'empty'));
  for (const r of window.recent) {
    const article = node('article', undefined, 'evidence-record');
    const label = r.kind === 'validation_job_started@1' ? 'Attempt admitted'
      : r.kind === 'validation_job_outcome@1' ? [r.state, r.verdict ?? r.reason].filter(Boolean).join(' · ')
      : r.kind ?? 'Record';
    article.append(node('p', label, 'record-title'), node('p', [r.id, r.actor ?? r.locus_actor, r.job_ref].filter(Boolean).join(' · '), 'mono'));
    article.append(detail(r, `${key}:${r.id}`, 'View record details'));
    n.append(article);
  }
  if (window.next_cursor) n.append(node('p', 'More records exist. Browsing older history is not connected in this app yet.', 'availability-note'));
  return n;
}
export function navigate(id, focus = false, fromRecord=false) {
  if (id!=='record'&&!id.startsWith('bot:')&&!screens.some(s => s[0] === id)) return;
  if(!document.dispatchEvent(new CustomEvent('before-page-select',{cancelable:true,detail:{id}})))return;
  if(!fromRecord){routeRevision++;saveRoute();currentRecord=null;if(selected!==id||historyIndex<0){selected=id;viewHistory.splice(++historyIndex);viewHistory.push(snapshot());}announceHistory();}
  selected = id;
  document.dispatchEvent(new CustomEvent('page-selected',{detail:{id}}));
  document.querySelectorAll('[data-screen]').forEach(n => { n.hidden = n.dataset.screen !== id; });
  document.querySelectorAll('[data-nav]').forEach(n => {
    n.classList.toggle('on', n.dataset.nav === id);
    if (n.dataset.nav === id) n.setAttribute('aria-current', 'page'); else n.removeAttribute('aria-current');
  });
  const heading = document.querySelector(`[data-screen="${id}"] h1`);
  if (heading && focus) { heading.tabIndex = -1; heading.focus({ preventScroll: true }); }
  document.getElementById('workspace-canvas').scrollTop = 0;
}
export function initShell() {
  initRecordTabs();
  document.addEventListener('click',event=>{
    const back=event.target.closest('[data-record-back]');if(back){travel(-1);return;}
    const trigger=event.target.closest('[data-record-open]');if(trigger){openRecord(trigger.dataset.recordOpen);return;}
    const link=event.target.closest('a[data-record-ref]');if(link){event.preventDefault();const r=reference(link.dataset.recordRef);if(r)openRecord(r.key);return;}
    const setup=event.target.closest('[data-setup-form]');if(setup){mode('nav');navigate('manage-work');const target=document.querySelector(`[data-id="${setup.dataset.setupForm}"]`);target?.scrollIntoView({block:'center'});target?.querySelector('input,select')?.focus();return;}
    const form=event.target.closest('[data-record-form]');if(form){
      workspace='';document.dispatchEvent(new Event('workspace-view-change'));mode('nav');navigate('manage-work');
      const field=document.querySelector(`[data-draft="${form.dataset.recordForm}"]`);if(field){field.value=form.dataset.recordValue;field.dispatchEvent(new Event(field.matches('input,textarea')?'input':'change',{bubbles:true}));}
      const focus=document.querySelector(`[data-draft="${form.dataset.recordFocus}"]`);focus?.scrollIntoView({block:'center'});focus?.focus();
    }
  });
  const nav = document.getElementById('app-navigation');
  const groups = [
    ['WORK', [['mission','Mission'],['positions','Workspaces'],['goals','Goals'],['development-tasks','Development tasks'],['lanes','Lanes'],['repositories','Repositories'],['editor','Editor'],['terminal','Terminal'],['browser','Browser']]],
    ['SOCIETY', [['agents','Agents'],['capabilities','Capabilities'],['routines','Routines']]],
    ['COMPUTE', [['fleet','Fleet & placement']]],
    ['TRUTH', [['evidence','Evidence'],['gates','Gates'],['rulings','Rulings']]],
    ['SYSTEM', [['authority','Authority'],['settings','Settings']]],
  ];
  const link = (id, label) => { const b = node('button', undefined, 'nav-item'); b.append(node('span','·','nav-glyph'),node('span',label,'nav-label'));const count=node('span','','nav-count');count.dataset.navCount=id;count.hidden=true;b.append(count);b.dataset.nav = id; return b; };
  for (const [title, links] of groups) {
    const group = node('div', undefined, 'nav-group');
    group.append(node('p', title, 'rail-label'));
    links.forEach(([id,label]) => group.append(link(id,label))); nav.append(group);
  }
  const roster=node('div');roster.id='bot-roster-links';
  document.getElementById('rail-bots').append(node('p','BOTS','rail-label'), link('bots','All bots'),roster,link('new-bot','+ Create bot'));
  const runtime = document.getElementById('rail-runtime');
  runtime.append(node('p','RUNTIME','rail-label'), link('runtime','Runtime overview'), link('runtime-assignments','Assignments & state'), link('capabilities','Grants & capabilities'), link('mission','Approvals'), link('evidence','Evidence ledger'), link('mobile','Mobile device'), node('p','Views of projected records. Process supervision is not supplied.','rail-hint'));
  const modes = [...document.querySelectorAll('[data-rail-mode]')];
  let activeMode='nav';const lastModePage={nav:'mission',bots:'bots',runtime:'runtime'};
  function mode(id,selectPage=false) {
    const changed=activeMode!==id;
    if(changed){if(selected!=='record')lastModePage[activeMode]=selected;activeMode=id;}
    if(selectPage&&changed)navigate(lastModePage[id],true);
    modes.forEach(b => { const on = b.dataset.railMode === id; b.setAttribute('aria-selected', String(on)); b.tabIndex = on ? 0 : -1; });
    document.querySelectorAll('[data-rail-panel]').forEach(p => { p.hidden = p.dataset.railPanel !== id; });
  }
  document.addEventListener('page-selected',event=>{
    const id=event.detail.id;if(id==='record')return;
    const target=(id==='bots'||id==='new-bot'||id==='edit-bot'||id.startsWith('bot:'))?'bots':['runtime','runtime-assignments','mobile'].includes(id)?'runtime':['positions','goals','lanes','repositories','new-workspace','manage-work','editor','terminal','browser','agents','routines','fleet','gates','rulings','authority','settings'].includes(id)?'nav':activeMode;
    activeMode=target;lastModePage[target]=id;mode(target);
  });
  modes.forEach((b,i) => {
    b.addEventListener('click', () => mode(b.dataset.railMode,true));
    b.addEventListener('keydown', e => {
      if (!['ArrowLeft','ArrowRight','Home','End'].includes(e.key)) return;
      e.preventDefault(); const j = e.key === 'Home' ? 0 : e.key === 'End' ? modes.length-1 : (i+(e.key==='ArrowRight'?1:-1)+modes.length)%modes.length;
      mode(modes[j].dataset.railMode,true); modes[j].focus();
    });
  });
  mode('nav');
  document.getElementById('workspace-picker').addEventListener('change', e => {
    routeRevision++;workspace = e.target.value;
    document.dispatchEvent(new Event('workspace-view-change'));
  });
  document.addEventListener('click', e => {
    const b = e.target.closest('[data-nav]');
    if (b) navigate(b.dataset.nav, true);
  });
  const dialog = document.getElementById('navigation-dialog');
  const search = document.getElementById('navigation-search');
  const results = document.getElementById('navigation-results');
  function updateResults() {
    results.textContent = '';
    for (const [id, title] of screens.filter(s => s[1].toLowerCase().includes(search.value.toLowerCase()))) {
      const b = node('button', title, 'palette-result');
      b.addEventListener('click', () => { dialog.close(); navigate(id, true); });
      results.append(b);
    }
    if (!results.children.length) results.append(node('p', 'No matching pages.', 'empty'));
  }
  function open() { search.value = ''; updateResults(); dialog.showModal(); search.focus(); }
  document.getElementById('open-navigation').addEventListener('click', open);
  document.getElementById('close-navigation').addEventListener('click', () => dialog.close());
  search.addEventListener('input', updateResults);
  search.addEventListener('keydown', e => {
    if (e.key === 'ArrowDown') { e.preventDefault(); results.querySelector('button')?.focus(); }
    if (e.key === 'Enter') { e.preventDefault(); results.querySelector('button')?.click(); }
  });
  document.addEventListener('keydown', e => {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); if (!dialog.open) open(); else dialog.close(); }
  });
  navigate(selected);
  document.dispatchEvent(new Event('shell-ready'));
}
