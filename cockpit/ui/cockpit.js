import { initDevelopmentTasks } from './development-tasks.js';
import { initDevelopment } from './development.js';
import { guidance, updateNavCounts } from './work-guidance.js';
import { runtimeAssignments } from './runtime-assignments.js';
import { mobileDevice, initMobileDevice } from './mobile-device.js';
import { creationDestination, confirmedDestination } from './creation-navigation.js';
import { initDesktopChrome } from './desktop-chrome.js';
import { setReferenceFrame, referenceText, readable, referenceWorld } from './references.js';
import { presentFrame } from './frame-dom.js';
import { initBots } from './bots.js';
import { openRecord, navigationToken, initShell, panel, node, card, detail, history, recordPage, beginFrameLayout, expectedHeadings, screens, selectedWorkspace, syncWorkspacePicker, clearWorkspacePicker } from './app-shell.js';

/* The cockpit's renderer.
 *
 * ────────────────────────────────────────────────────────────────────────
 * THE LAW
 *
 *   The rendered world is a function of the last frame and of nothing
 *   else. An intent that resolves successfully changes nothing inside a
 *   [data-source="frame"] region.
 * ────────────────────────────────────────────────────────────────────────
 *
 * The tempting version of `onRevoke` is four lines long and wrong:
 *
 *     const r = await invoke('intent', { name: 'revoke_grant', args });
 *     if (r.allow) row.remove();                     // ← throws away W.1
 *
 * `r.allow` says the runtime accepted the request. Whether the grant is
 * gone is a fact about the world, and the world states it in a frame — one
 * that carries the incarnation it was assembled in, the epoch, and both
 * clocks, so that a client can tell "this is newer" from "this is a
 * different world" from "the runtime restarted under me". Removing the row
 * on `allow` renders a world nobody asserted, and the person is now
 * looking at a screen whose relationship to the runtime is *hope*.
 *
 * So `submit()` resolves into the receipt rail and joins nothing. Every
 * grant row on screen was put there by `render()`, and `render()` is called
 * on frame arrival, or to change the workspace view of that same held frame.
 *
 * ── the stream is a sink this page hands over ───────────────────────────
 *
 * W.2 listened for a global `cockpit-frame` event. `listen()` resolves
 * asynchronously and an event is not a queue, so the worker's first emit
 * could land before registration completed — and because a missed frame is
 * still marked in flight by the delivery valve, losing that race left the
 * cockpit on *Waiting for the first frame* permanently. It passed on this
 * machine because runtime startup is slow, which is timing evidence and
 * not an ordering guarantee.
 *
 * Now: construct the Channel, install `onmessage`, **then** hand it to the
 * host. The worker holds no sink until that call arrives, so there is no
 * interval in which a frame can be addressed to nobody. A Channel is also
 * ordered by construction and addressed to one page, which a global event
 * is not — and it needs no `core:event` permission, so the cockpit's
 * capability shrinks to the five commands it actually uses.
 *
 * ── the acknowledgement, and why a click holds it ───────────────────────
 *
 * `ack()` closes the valve: the host sends at most one frame this page has
 * not acknowledged, and newer states coalesce rather than queue.
 *
 * `holdBegin()` / `holdEnd()` bracket every submission, and they are a
 * product rule before they are anything else: **do not reflow the list a
 * person is clicking on.** Between "revoke pressed" and "the runtime
 * answered", the rows hold still — otherwise the row under the cursor can
 * move while the cursor is on it, which is a mis-click generator in a
 * surface where a mis-click grants or removes authority.
 *
 * **Keyed, because interactions overlap.** W.2 used one boolean, so two
 * rapid clicks each paused and the first to finish resumed — releasing the
 * second interaction's hold while its outcome was still unknown. Each
 * submission now takes its own token and delivery waits for the set to
 * empty.
 *
 * It is also what turns the flagship from a race into a state. The frame a
 * revocation produces is held for exactly as long as the revocation is in
 * flight, so *"the IPC resolved and the grant is still on screen"* is
 * somewhere the cockpit deterministically **is**, not a millisecond it
 * might pass through.
 *
 * ── W.2.3.3 · link liveness is not projection maintenance ───────────────
 *
 * W.2.3.2 kept ONE clock, `heard_at`, written by every arriving message
 * before anything looked at what the message said. Two different facts were
 * being recorded in it:
 *
 *     the link is alive          ≠      what is on screen is still
 *                                       being maintained
 *
 * and the second is the one the cockpit exists to be truthful about. The
 * host can say, on a heartbeat, *I have given up delivering a newer state*
 * — `valve.in_flight.exhausted` has carried exactly that since W.2.3.1 —
 * and in W.2.3.2 the arrival of that very heartbeat refreshed the clock the
 * lease consults, so **the warning kept the page from acting on the
 * warning**. The projection was stale, provably, and every control that
 * submits authority stayed enabled against it.
 *
 * The two facts now have two clocks and two deadlines:
 *
 *     link_heard_at    any message at all         → silence
 *     projection_at    a message that ATTESTS     → unmaintained
 *                      the projection, which is
 *                      a frame, or a heartbeat
 *                      whose valve holds nothing
 *                      this page has not seen
 *
 * plus one immediate path: a heartbeat that positively reports an exhausted
 * frame newer than anything applied is not a deadline at all, it is a
 * statement, and it withdraws at once.
 *
 * **The two are not redundant, and the transport is why.** Tauri picks a
 * Channel transport by payload size — under 8192 bytes by `webview.eval`,
 * over it by parking the body and asking the page to fetch it. A heartbeat
 * is a few hundred bytes and always takes the first; a frame carrying a
 * real world crosses the threshold and takes the second. So the signal that
 * vouches for the stream can travel a different path from the payload it is
 * vouching for, and the two paths fail independently.
 *
 *   > A liveness signal is evidence about the path it travelled. Where it
 *   > can travel a different path from the thing it vouches for, it is not
 *   > evidence about that thing.
 *
 * ── and the position a message is evidence FOR ──────────────────────────
 *
 * The same shape, one layer down. `bind()` used to write `window.cockpit`
 * from a promise continuation that could not say which attempt it belonged
 * to, so a slow bind resolving after the page had moved on wrote into
 * whatever the page was doing by then — including restarting the deadline
 * of a candidate it had nothing to do with. And `unbind_frame_stream` named
 * no stream, so an unbind issued for a dead one could arrive after the
 * replacement had been established and tear that down instead.
 *
 * A binding is therefore identified — `{page, generation}` — and both the
 * page and the host refuse anything addressed to a position that is no
 * longer the live one. A stale completion still knows which function to
 * call; it has stopped having any authority to call it.
 */

const { invoke, Channel } = window.__TAURI__.core;

const el = {
  state: document.getElementById('badge-state'),
  world: document.getElementById('badge-world'),
  rev: document.getElementById('badge-rev'),
  main: document.getElementById('world'),
  receipts: document.getElementById('receipt-list'),
  receiptsEmpty: document.querySelector('#receipts .empty'),
};

const short = (s) => (typeof s === 'string' && s.length > 12 ? s.slice(0, 12) + '…' : s ?? '—');

/* `actions` is a list, and it became one because the surface needed a row
   to offer both halves of a decision. A row that could only carry one
   button is why `approve_grant_request` sat on `INTENT_SURFACE` with only
   `deny` rendered beside the request it applies to — the person could
   refuse and could not consent, through a surface whose whole job is
   consent. */
function rowNode({ id, cap, who, actions = [] }) {
  const row = document.createElement('div');
  row.className = 'row';
  row.dataset.id = id;

  const c = document.createElement('span');
  c.className = 'cap';
  referenceText(c,cap);

  const w = document.createElement('span');
  w.className = 'who';
  referenceText(w,who);

  const spacer = document.createElement('span');
  spacer.className = 'spacer';

  row.append(c, w, spacer);

  for (const { label, intent, surface, args, danger } of actions) {
    const b = document.createElement('button');
    b.textContent = label;
    /* **`surface` is not an intent and must not look like one.** It changes
       nothing in the world; it opens or dismisses a webview inside this
       process. Giving it its own attribute keeps `data-intent` meaning
       exactly one thing — a mutation submitted to the runtime — rather
       than becoming "a button that does something". */
    if (surface) b.dataset.surface = surface;
    else b.dataset.intent = intent;
    b.dataset.args = JSON.stringify(args ?? {});
    if (danger) b.dataset.danger = 'true';
    row.append(b);
  }
  return row;
}

/* ── D.1.1a · opening a position ──────────────────────────────────────
 *
 * `check-intent-surface.mjs` holds that every authority operation the
 * runtime declares for a person is reachable from this surface. D.1.1
 * added three and left the gate red, correctly: appending the words to
 * `INTENT_SURFACE` would have turned it green while a person still could
 * not open anything. This is what makes its proposition true.
 *
 * Drafts remain module state, separate from runtime facts. Each frame builds
 * a complete planned view; reconciliation updates facts while retaining the
 * same controls so a mouse press can finish across arriving frames. Inputs
 * are populated from the person's draft, including after stream withdrawal.
 * A runtime frame is never entitled to overwrite unfinished user input. */
const draft = { workspace_name: '', goal_title: '', goal_ws: '', lane_goal: '', lane_actor: '', lane_repo: '', lane_base: '',
                worker_lane: '', worker_purpose: '', worker_close: '', worker_reopen: '' };

function fieldNode(key, label, placeholder) {
  const wrap = document.createElement('label');
  wrap.className = 'field';
  wrap.textContent = label;
  const i = document.createElement('input');
  i.type = 'text';
  i.placeholder = placeholder ?? '';
  i.value = draft[key] ?? '';
  i.dataset.draft = key;
  i.addEventListener('input', () => { draft[key] = i.value; });
  wrap.append(i);
  return wrap;
}

function selectNode(key, label, options, empty) {
  const wrap = document.createElement('label');
  wrap.className = 'field';
  wrap.textContent = label;
  const s = document.createElement('select');
  s.dataset.draft = key;
  if (!options.length) {
    const o = document.createElement('option');
    o.value = '';
    o.textContent = empty;
    s.append(o);
    s.disabled = true;
  } else {
    for (const { value, text } of options) {
      const o = document.createElement('option');
      o.value = value;
      o.textContent = readable(text);
      o.selected = draft[key] === value;
      s.append(o);
    }
    /* A stale draft naming an object that no longer exists must not
       silently submit the first option instead — that would be the person
       acting on something they did not choose. */
    if (!options.some((o) => o.value === draft[key])) draft[key] = options[0].value;
    s.value = draft[key];
  }
  s.addEventListener('change', () => { draft[key] = s.value; });
  wrap.append(s);
  return wrap;
}

/* `data-intent-form` rather than `data-args`: the arguments are read from
   the draft at click time, so what is submitted is what the person can
   see, not what the page happened to serialize when it last rendered. */
function formNode(id, intent, fields, action, disabled) {
  const row = document.createElement('div');
  row.className = 'row form';
  row.dataset.id = id;
  fields.forEach((f) => row.append(f));
  const b = document.createElement('button');
  b.textContent = action;
  b.dataset.intentForm = intent;
  b.disabled = !!disabled;
  row.append(b);
  return row;
}

/* Read at click time from the draft. Empty optional fields are omitted
   rather than sent as "", because `Ampd.CommandSpec` types
   `base_revision` as a string and "" is a string — an empty box would
   become a revision nobody named. */
function argsFor(intent) {
  const trim = (s) => (s ?? '').trim();
  if (intent === 'open_workspace') return { name: trim(draft.workspace_name) };
  if (intent === 'open_goal') return { workspace_ref: draft.goal_ws, title: trim(draft.goal_title) };
  if (intent === 'open_lane') {
    const a = { goal_ref: draft.lane_goal, actor: trim(draft.lane_actor), repository_ref: draft.lane_repo };
    if (trim(draft.lane_base)) a.base_revision = trim(draft.lane_base);
    return a;
  }
  /* `open_worker` has no `actor` field, and the omission is the design.
     A Worker's actor is copied from its Lane by the runtime, so there is
     no box in which a person could assign someone to a Lane that is not
     theirs — referential closure the person cannot get wrong rather than
     a validation they can be refused by. */
  if (intent === 'open_worker') return { locus_ref: draft.worker_lane, purpose: trim(draft.worker_purpose) };
  if (intent === 'close_worker') return { worker_ref: draft.worker_close };
  if (intent === 'reopen_worker') return { worker_ref: draft.worker_reopen };
  if (intent === 'reconcile_carrier_attempt') return { ticket_id: draft.attempt_reconcile };
  return {};
}

function section(title, items, empty) {
  const h = node('h2', title);
  const frag = document.createDocumentFragment();
  frag.append(h);
  if (!items.length) {
    const p = document.createElement('p');
    p.className = 'empty';
    p.textContent = empty;
    frag.append(p);
  } else {
    items.forEach((n) => frag.append(n));
  }
  return frag;
}

/* Construct the complete view from one frame, then retain matching DOM
   controls while applying that view. Removing pressed controls on every frame
   prevents real pointer gestures from ever becoming clicks. */
export function render(frame) {
  setReferenceFrame(frame);
  beginFrameLayout();
  el.state.textContent = frame.state;
  el.state.dataset.state = frame.state;

  const w = frame.world ?? {};
  el.world.textContent = `world ${short(w.world_incarnation)} · gen ${w.world_generation ?? '—'} · epoch ${short(w.projection_epoch)}`;
  el.rev.textContent = `authority ${w.authority_revision ?? '—'} · view ${w.view_revision ?? '—'} · frame ${frame.seq}`;

  // A fresh projection may arrive while the person is typing. Preserve
  // input focus and caret as presentation state, alongside the draft.
  const active = document.activeElement;
  const focusedDraft = active?.dataset?.draft;
  const focusedDetail = active?.matches('.record-trigger') ? active.parentElement.dataset.detail : null;
  const caret = active?.tagName === 'INPUT' ? [active.selectionStart, active.selectionEnd] : null;
  const p = frame.projection;
  if (!p) {
    el.main.textContent = '';
    clearWorkspacePicker();
    const note = document.createElement('p');
    note.className = 'empty';
    note.textContent = frame.note ?? 'No projection is held. Nothing is claimed about the world.';
    el.main.append(note);
    return;
  }

  const liveGrants = p.grants ?? [];

  const grants = liveGrants.map((g) =>
    rowNode({
      id: g.id,
      cap: g.capability,
      who: `${g.actor} · ${g.resource} · ${g.duration}`,
      actions: [{ label: 'revoke', intent: 'revoke_grant', args: { grant_id: g.id } }],
    }),
  );

  /* **Bulk revocation, and the confirmation is the set on the screen.**
     `expected_ids` are the ids of the grants rendered in this frame, so
     the set the person is looking at and the set the runtime revokes
     cannot be two different worlds — which is the whole reason
     `Ampd.GrantRegistry.revoke_matching/2` takes them. A button that sent
     the capability alone would be asking the runtime to re-sample. */
  const byCapability = new Map();
  for (const g of liveGrants) {
    if (!byCapability.has(g.capability)) byCapability.set(g.capability, []);
    byCapability.get(g.capability).push(g.id);
  }

  const domains = [...byCapability.entries()].map(([capability, ids]) =>
    rowNode({
      id: `domain-${capability}`,
      cap: capability,
      who: `${ids.length} grant${ids.length === 1 ? '' : 's'} across every actor`,
      actions: [{
        label: `revoke all ${ids.length}`,
        intent: 'revoke_capability_domain',
        args: { scope: { capability }, expected_ids: ids },
        danger: true,
      }],
    }),
  );

  const requests = (p.grant_requests ?? []).map((q) =>
    rowNode({
      id: q.id,
      cap: q.capability,
      who: `${q.actor} asked · ${q.resource}`,
      actions: [
        /* `duration` is omitted, which means "as requested". Approving may
           narrow and never widen — `Ampd.Authority.approve_grant_request/2`
           refuses the other direction — so the safe default is the one the
           agent actually asked for. */
        { label: 'approve', intent: 'approve_grant_request', args: { request_id: q.id } },
        { label: 'deny', intent: 'deny_grant_request', args: { request_id: q.id } },
      ],
    }),
  );

  /* Consent for one exact intent. Both halves rendered together, for the
     same reason the grant request has both: a surface that can only refuse
     is not a consent surface. */
  const approvals = (p.pending_approvals ?? []).map((a) =>
    rowNode({
      id: a.id,
      cap: a.capability,
      who: `${a.actor} · ${a.resource ?? '—'}`,
      actions: [
        {
          label: 'approve',
          intent: 'approve_effect',
          args: { request_id: a.envelope?.request_id, approval_id: a.id },
        },
        { label: 'deny', intent: 'deny_effect', args: { approval_id: a.id } },
      ],
    }),
  );

  const peers = (p.peers ?? []).map((peer) =>
    rowNode({ id: peer.peer_id ?? peer.actor, cap: peer.actor ?? '—', who: peer.role ?? '' }),
  );

  /* ── the positions, and the forms that open them ──────────────────
     Rendered from `operator-projection@2`, which is world-complete for
     the person. The agent's own `list_loci` is ancestry-closed; these are
     two different projections on purpose and the difference is the point
     of F14. */
  const allWorkspaces = Object.values(p.workspaces ?? {});
  syncWorkspacePicker(allWorkspaces);
  const workspaceId = selectedWorkspace();
  updateNavCounts(p,workspaceId);
  const wsList = allWorkspaces.filter(w => !workspaceId || w.id === workspaceId);
  const goalList = Object.values(p.goals ?? {}).filter(g => !workspaceId || g.workspace_ref === workspaceId);
  const goalIds = new Set(goalList.map(g => g.id));
  const laneList = Object.values(p.lanes ?? {}).filter(l => !workspaceId || goalIds.has(l.goal_ref));
  const laneIds = new Set(laneList.map(l => l.id));
  const repoList = Object.values(p.repositories ?? {});
  const caps = Object.values(p.worktree_caps ?? {});

  const workerList = Object.values(p.workers ?? {}).filter(w => !workspaceId || laneIds.has(w.locus_ref));

  const openWorkers = workerList.filter((w) => w.status === 'open');
  const closedWorkers = workerList.filter((w) => w.status !== 'open');
  const laneOptions = laneList.map((l) => ({ value: l.id, text: `${l.id} · ${l.actor}` }));
  const openWorkerOptions = openWorkers.map((w) => ({ value: w.id, text: `${w.id} · ${w.occupancy ?? ''}` }));
  const closedWorkerOptions = closedWorkers.map((w) => ({ value: w.id, text: `${w.id} · closed` }));
  /* Unresolved Carrier starts. The projection sends only these — a committed
     attempt is history and belongs in a receipt, not in a list of things a
     person has to unstick. */
  const unresolvedAttemptOptions = Object.values(p.carrier_attempts ?? {})
    .map((a) => ({ value: a.ticket_id, text: `${a.ticket_id} · ${a.worker_ref} · ${a.state}` }));

  const wsOptions = wsList.map((w) => ({ value: w.id, text: `${w.name ?? w.id}` }));
  const goalOptions = goalList.map((g) => ({ value: g.id, text: `${g.title ?? g.id}` }));
  const repoOptions = repoList.map((r) => ({ value: r.ref, text: r.ref }));

  const newWorkspace = panel('new-workspace');
  const backToWorkspaces = node('button', '← Workspaces', 'record-back'); backToWorkspaces.dataset.nav='positions';
  newWorkspace.insertBefore(backToWorkspaces,newWorkspace.firstChild);
  newWorkspace.append(formNode('open-workspace', 'open_workspace',
    [fieldNode('workspace_name', 'Workspace name', 'e.g. Product development')], 'Create workspace'));
  const cancelWorkspace = node('button', 'Cancel', 'subtle'); cancelWorkspace.dataset.nav='positions'; newWorkspace.append(cancelWorkspace);
  const openers = [

    formNode('open-goal', 'open_goal',
      [selectNode('goal_ws', 'Workspace', wsOptions, 'no workspace yet'),
       fieldNode('goal_title', 'Goal title', 'What do you want to accomplish?')],
      'Create goal', wsOptions.length === 0),

    /* `open_lane` names the actor that may occupy the Lane. That is the
       person deciding who stands where, and it is the reason this whole
       section is an authority surface rather than a convenience. */
    formNode('open-lane', 'open_lane',
      [selectNode('lane_goal', 'Goal', goalOptions, 'no goal yet'),
       fieldNode('lane_actor', 'Actor', 'Actor identity'),
       selectNode('lane_repo', 'Repository', repoOptions, 'no repository registered'),
       fieldNode('lane_base', 'Base revision', 'Optional')],
      'Create lane', goalOptions.length === 0 || repoOptions.length === 0),

    /* D.1.2. Three forms, because a person needs all three verbs: assign
       somebody to a position, end that assignment, and — since ending it
       must not be irreversible — restore it. `close_worker` is the one
       that carries supervision: it is how a person stops a Carrier that
       is already standing somewhere, and the runtime refuses the next
       thing issued from there without anyone having to ask the Carrier
       to cooperate. */
    formNode('open-worker', 'open_worker',
      [selectNode('worker_lane', 'Lane', laneOptions, 'no lane yet'),
       fieldNode('worker_purpose', 'Worker purpose', 'What should this worker do?')],
      'Assign worker', laneOptions.length === 0),

    formNode('close-worker', 'close_worker',
      [selectNode('worker_close', 'Open worker', openWorkerOptions, 'no open worker')],
      'Close worker', openWorkerOptions.length === 0),

    formNode('reopen-worker', 'reopen_worker',
      [selectNode('worker_reopen', 'Closed worker', closedWorkerOptions, 'no closed worker')],
      'Reopen worker', closedWorkerOptions.length === 0),

    /* An ambiguous Carrier start blocks every later start for that Worker.
       This is how a person ends that, and it is the only way: nothing clears
       it on a timer, because the thing it is waiting on is a process that may
       still exist. Disabled when there is nothing unresolved, so the surface
       says "nothing is stuck" rather than offering an action with no
       subject. */
    formNode('reconcile-carrier', 'reconcile_carrier_attempt',
      [selectNode('attempt_reconcile', 'Unresolved start', unresolvedAttemptOptions,
                  'no unresolved carrier start')],
      'Reconcile start', unresolvedAttemptOptions.length === 0),
  ];

  const mission = panel('mission');
  const stats = node('div', undefined, 'stats-grid');
  stats.append(card('Workspaces', wsList.length), card('Open workers', openWorkers.length),
    card('Permission decisions', requests.length + approvals.length), card('Active grants', liveGrants.length));
  mission.append(stats);
  mission.append(guidance({node,card,detail,p,workspace:workspaceId}));
  const overview = node('div', undefined, 'overview-card');
  overview.append(node('h2', wsList.length ? 'Your workspaces' : 'Make room for your first goal'),
    node('p', wsList.length ? 'Open a workspace to see its goals and assigned lanes.'
      : 'Create a workspace, give it a goal, then assign work through lanes and workers.', 'screen-description'));
  for (const ws of wsList) overview.append(detail(ws, `workspace:${ws.id}`, ws.name ?? ws.id));
  const go = node('button', wsList.length ? 'View workspaces →' : 'Create your first workspace →', 'primary');
  go.dataset.nav = wsList.length ? 'positions' : 'new-workspace'; overview.append(go); mission.append(overview);
  mission.append(section('Permission requests', requests, 'No requests need your attention.'),
    section('Consent for one effect', approvals, 'No effects are waiting for consent.'));

  const positions = panel('positions'),goalsPage=panel('goals'),lanesPage=panel('lanes');
  const createWorkspace=node('button','New workspace','primary');createWorkspace.dataset.nav='new-workspace';positions.append(createWorkspace);
  for(const [page,values] of [[positions,[['Workspaces',wsList.length],['Goals',goalList.length]]],[goalsPage,[['Goals',goalList.length],['Without lanes',goalList.filter(g=>!laneList.some(l=>l.goal_ref===g.id)).length]]],[lanesPage,[['Lanes',laneList.length],['Open workers',openWorkers.length]]]]){const summary=node('div',undefined,'stats-grid');for(const [title,value] of values)summary.append(card(title,value));page.append(summary);}
  const manageWork=panel('manage-work');const backToList=node('button','← Workspaces','record-back');backToList.dataset.nav='positions';manageWork.insertBefore(backToList,manageWork.firstChild);manageWork.append(...openers);
  function setupButton(page,label,target){const b=node('button',label,'primary');b.dataset.setupForm=target;page.append(b);}
  setupButton(goalsPage,'New goal','open-goal');setupButton(lanesPage,'New lane','open-lane');
  const manageWorkers=node('button','Manage workers','subtle');manageWorkers.dataset.setupForm='open-worker';lanesPage.append(manageWorkers);
  function directoryCard(record,key,label,notes){const row=detail(record,key,label);for(const note of notes)row.append(node('p',note,'directory-note'));return row;}
  const workspaceCards=wsList.map(w=>{const mine=goalList.filter(g=>g.workspace_ref===w.id),ids=new Set(mine.map(g=>g.id));return directoryCard(w,`position-workspace:${w.id}`,w.name||w.id,[`${mine.length} goals · ${laneList.filter(l=>ids.has(l.goal_ref)).length} lanes`]);});
  positions.append(section('Your workspaces',workspaceCards,'No workspaces yet. Create a workspace to organize your first goal.'));
  goalsPage.append(section('Your goals',goalList.map(g=>directoryCard(g,`goal:${g.id}`,g.title||g.id,[`Workspace: ${g.workspace_ref??'Not set'}`,`${laneList.filter(l=>l.goal_ref===g.id).length} assigned lanes`])),'No goals in this view. Add a goal to describe the outcome you want.'));
  lanesPage.append(section('Your lanes',laneList.map(l=>directoryCard(l,`lane:${l.id}`,l.id,[`Goal: ${l.goal_ref??'Not set'}`,`Actor: ${l.actor||'Not assigned'} · Repository: ${l.repository_ref??'Not set'}`,`${workerList.filter(w=>w.locus_ref===l.id).length} assigned workers`])),'No lanes in this view. A lane connects a goal, an actor, and a repository.'));
  const assignments=runtimeAssignments({frame,node,panel,card,detail});
  const mobile=mobileDevice({node,panel,card});
  const repositories = panel('repositories');
  repositories.append(node('p', 'Choose the top-level folder of a Git repository. Registered repositories are shared across workspaces; choosing one does not grant a worker access.', 'screen-description'));
  const choose = node('button', 'Add local repository…', 'primary'); choose.dataset.hostAction = 'choose-repository'; choose.disabled = repositoryPickerPending;
  repositories.append(choose);
  for (const repo of repoList) repositories.append(detail(repo, `repository:${repo.ref}`, repo.ref));
  if(!repoList.length)repositories.append(node('p','No repositories connected yet. Add a local Git repository to make it available when creating a lane.','empty'));
  repositories.append(node('p','Shared across all workspaces.','scope-note'));
  const repositoryLink=node('button','Manage local repositories →','subtle');repositoryLink.dataset.nav='repositories';manageWork.append(repositoryLink);

  const capabilities = panel('capabilities');
  capabilities.append(section('Active grants', grants, 'No authority is currently granted.'),
    section('Whole capability domains', domains, 'No capability has a grant.'),
    node('p', 'New requests and effect approvals appear in Mission Control. The prototype’s capability marketplace is not connected.', 'availability-note'));

  const evidence = panel('evidence');
  evidence.append(history('Validations', p.validations, 'validations'),
    history('Worktree establishments', p.worktree_receipts, 'worktree'),
    history('Capability effects', p.receipts, 'receipts'));

  const runtime = panel('runtime');
  runtime.append(section('Registered bot identities',Object.values(p.bots??{}).map(b=>detail(b,`bot:${b.id}`,b.name)),'No bot identities registered. Open a bot page to register it in a workspace.'));
  const health = node('div', undefined, 'stats-grid');
  health.append(card('Runtime', p.runtime?.status ?? 'Not reported'), card('Version', p.runtime?.version ?? 'Not reported'),
    card('World loaded', p.runtime?.world_loaded === true ? 'Yes' : p.runtime?.world_loaded === false ? 'No' : 'Not reported'));
  runtime.append(health, section('Connected peers', peers, 'No peers are connected.'),
    section('Channels', (p.channels ?? []).map((c, i) => detail(c, `channel:${c.channel_id ?? c.id ?? i}`, c.channel_id ?? c.id ?? `Channel ${i + 1}`)), 'No channels reported.'),
    section('Unresolved carrier starts', Object.values(p.carrier_attempts ?? {}).map(a => detail(a, `attempt:${a.ticket_id}`, `${a.worker_ref} · ${a.state}`)), 'No unresolved starts.'),
    section('Store seals', (p.seals ?? []).map((s, i) => detail(s, `seal:${i}`, s.registry ?? 'Sealed store')), 'No stores are sealed.'),
    section('Recent refusals', (p.recent_refusals ?? []).map((r, i) => detail(r, `refusal:${r.id ?? i}`, r.code ?? r.refusal?.code ?? 'Refusal')), 'No recent refusals.'),
    detail({ world: frame.world, runtime: p.runtime, manifest: p.world }, 'runtime-identity', 'World & frame identity'));

  const extra = screens.filter(([id]) => !['mission','positions','capabilities','evidence','runtime','bots','new-bot','edit-bot','new-workspace','manage-work','repositories','goals','lanes','runtime-assignments','editor','terminal','browser','development-tasks','mobile'].includes(id)).map(([id]) => {
    const page = panel(id);
    if (id === 'agents') page.append(section('Connected peers', (p.peers ?? []).map(peer => detail(peer, `agent:${peer.peer_id ?? peer.actor}`, peer.actor ?? peer.peer_id ?? 'Peer')), 'No peers are connected.'));
    else if (id === 'authority') page.append(section('Current grants', liveGrants.map(g => detail(g, `authority:${g.id}`, `${g.capability} · ${g.actor}`)), 'No authority is currently granted.'));
    else if (id === 'settings') page.append(node('p', 'Super runs on your machine. Use the workspace switcher to focus the work shown in Mission Control and lanes. Authority and history views cover the whole runtime.', 'overview-card'), detail({state: frame.state, runtime: p.runtime}, 'settings-runtime', 'Connection information'));
    else page.append(node('div', 'NOT CONNECTED · This prototype page needs runtime data and actions that are not available in the desktop app yet.', 'availability-note'));
    return page;
  });
  const scopeName = workspaceId ? wsList[0]?.name ?? workspaceId : 'All workspaces';
  for (const page of [mission, positions, goalsPage, lanesPage]) page.insertBefore(node('p', `Workspace view: ${scopeName}`, 'scope-note'), page.children[3] ?? null);
  for (const page of [capabilities, evidence, runtime, ...extra]) page.append(node('p', 'Scope: whole runtime', 'scope-note'));
  mission.append(node('p', 'Requests, approvals, and active grant totals cover the whole runtime.', 'availability-note'));
  presentFrame(el.main, [mission, positions, goalsPage, lanesPage, assignments, newWorkspace, manageWork, repositories, capabilities, evidence, runtime, mobile, ...extra, recordPage(frame)]);
  if (focusedDraft) {
    const replacement = [...el.main.querySelectorAll('[data-draft]')].find(n => n.dataset.draft === focusedDraft);
    if (replacement && !replacement.disabled) {
      replacement.focus({ preventScroll: true });
      if (caret && replacement.tagName === 'INPUT') replacement.setSelectionRange(...caret);
    }
  }
  if (focusedDetail) {
    const replacement = [...el.main.querySelectorAll('[data-detail]')].find(n => n.dataset.detail === focusedDetail);
    replacement?.querySelector('.record-trigger')?.focus({ preventScroll: true });
  }
  // Compare the headings planned during construction with the actual DOM.
  // Reading the DOM here would make the existing completeness check circular.
  window.cockpit.rendered = { sections: expectedHeadings() };
  document.dispatchEvent(new Event('runtime-view-rendered'));

}

/* A submission, resolved. This writes to the receipt rail — which is
   data-source="submission" — and touches no frame region. */
function receipt(name, outcome, detail) {
  el.receiptsEmpty.hidden = true;
  const li = document.createElement('li');
  li.dataset.outcome = outcome;
  li.dataset.intent = name;
  const label = name.replaceAll('_', ' ');
  referenceText(li,`${label.charAt(0).toUpperCase() + label.slice(1)} · ${outcome}${detail ? ' · ' + detail : ''}`);
  el.receipts.prepend(li);
}

/* **The acknowledgement, and the one rejection it can still have.**
 *
 * W.2.1 sent this with `try_send`, so a full queue discarded it and the
 * frame stream wedged with nothing said — and this line has never awaited
 * it, so there was nowhere for the rejection to be seen even when there was
 * one. The host cannot drop it any more. The only way it can still fail is
 * the worker being gone, which is terminal.
 *
 * The rule that repair is an instance of has two halves:
 *
 *   new work may be refused BUSY, but a message that RELEASES a gate must
 *   enqueue — or move the system to a state that says it could not. Never
 *   silently disappear.
 *
 * The lane closes the first half. This closes the second. **It is the only
 * thing in this file allowed to write into a [data-source="frame"] region
 * without a frame**, and it is allowed because it does not make a claim
 * about the world — it withdraws the one the last frame made. A cockpit
 * whose stream has died must stop looking like a cockpit whose world is
 * simply quiet; those are the two states this entire product exists to
 * keep apart.
 */
const ack = (seq) =>
  invoke('frame_ack', { seq }).catch((e) => {
    window.cockpit.stalled = String(e);
    el.state.textContent = 'stalled';
    el.state.dataset.state = 'reacquire';
    el.main.textContent = '';
  clearWorkspacePicker();
    const p = document.createElement('p');
    p.className = 'empty';
    p.textContent =
      `The frame stream stopped: ${e}. What was on screen is no longer being maintained.`;
    el.main.append(p);
  });

const holdBegin = (id) => invoke('hold_begin', { id });
const holdEnd = (id) => invoke('hold_end', { id });

let holds = 0;

/* ── D.1.3c·2c·1b·1 · the terminal surface ────────────────────────────
 *
 * **What this fixes.** `Watch terminal` was rendered whenever a Worker's
 * projection said `PRESENT`, and in normal Super it could not work: the
 * terminal webview existed only under `SUPER_COCKPIT_PANE=1`, a testing
 * witness, so there was no sink and `Terminal::park` refused before a
 * socket was made. The button was reachable and the capability was not.
 *
 * The surface is opened first and awaited. `terminal_surface` creates the
 * pane if it is absent and reports whether that pane has offered its sink
 * yet; a page takes a moment to load, so this asks again rather than
 * submitting a `terminal_bind` the runtime would have to refuse for a
 * reason that is about our own startup order and not about authority. */
const surface = { present: false };

async function terminalSurface(open) {
  if (!open) {
    const s = await invoke('terminal_surface', { open: false });
    surface.present = false;
    return s;
  }
  const deadline = Date.now() + 5000;
  for (;;) {
    const s = await invoke('terminal_surface', { open: true });
    surface.present = !!(s && s.present);
    if (s && s.bound) return s;
    if (Date.now() > deadline) throw new Error('the terminal surface never offered a sink');
    await new Promise((r) => setTimeout(r, 50));
  }
}

let pendingCreation=null;
function followCreatedRecord(){
  const c=window.cockpit;if(c.withdrawn||c.unavailable||c.stalled)return;
  const next=confirmedDestination(pendingCreation,c.frame,referenceWorld(),navigationToken());pendingCreation=next.pending;
  if(next.key)openRecord(next.key);
}
document.addEventListener('runtime-view-rendered',()=>queueMicrotask(followCreatedRecord));
async function submit(name, args, followCreation=false) {
  const creationOrigin={world:referenceWorld(),route:navigationToken(),seq:window.cockpit.frame?.seq??0};
  if(followCreation)pendingCreation=null;
  /* One token per submission, never a shared flag. */
  const id = `hold-${++holds}`;

  /* Awaited before the intent is sent. The two messages travel the same
     queue and are drained in order by the one thread that also emits, so
     the hold is in force before the world can move. */
  await window.cockpit.holdBegin(id);
  receipt(name, 'submitted', '');
  let accepted = false;
  try {
    /* The one intent that needs a surface before it can be honoured. It
       is done inside the hold so the screen stays still across both, and
       before the intent so a failure to open the pane is reported as the
       refusal it is rather than as a bind that mysteriously did nothing. */
    if (name === 'terminal_bind') await terminalSurface(true);
    const result = await invoke('intent', { name, args });
    const refusal = result?.refusal?.code;
    accepted = !refusal;
    if(followCreation)pendingCreation=creationDestination(name,result,creationOrigin);
    receipt(name, refusal ? 'refused' : 'accepted', refusal ?? '');
  } catch (e) {
    receipt(name, 'refused', String(e));
  }
  /* The screen has not moved and will not move here. It moves when a
     frame arrives — if the world agrees, and once every other interaction
     has released its own hold too. */
  await window.cockpit.holdEnd(id);
  if(followCreation)queueMicrotask(followCreatedRecord);
  return accepted;
}

let repositoryPickerPending = false;
document.addEventListener('record-route-change',()=>{const c=window.cockpit;if(c.frame?.projection&&!c.withdrawn&&!c.unavailable&&!c.stalled)render(c.frame);});
document.addEventListener('workspace-view-change', () => {
  const c = window.cockpit;
  if (c.frame?.projection && !c.withdrawn && !c.unavailable && !c.stalled && el.main.querySelector('[data-screen]')) render(c.frame);
});
document.addEventListener('click', (ev) => {
  const hostAction = ev.target.closest('button[data-host-action="choose-repository"]');
  if (hostAction) {
    if (repositoryPickerPending) return;
    repositoryPickerPending = true; hostAction.disabled = true;
    invoke('choose_repository').then(result => {
      receipt('register_repository', result.status === 'cancelled' ? 'cancelled' : 'accepted', result.repository_ref);
    }).catch(error => receipt('register_repository', 'refused', String(error))).finally(() => {
      repositoryPickerPending = false;
      document.querySelectorAll('[data-host-action="choose-repository"]').forEach(b => { b.disabled = b.dataset.deletionBlocked==='true'; });
    });
    return;
  }

  const s = ev.target.closest('button[data-surface]');
  if (s) {
    /* No hold. A hold exists to keep the world still across a mutation,
       and this is not one — nothing in the world moves when a person puts
       a terminal away. */
    terminalSurface(s.dataset.surface === 'open').catch((e) => {
      receipt('terminal_surface', 'refused', String(e));
    });
    return;
  }

  const b = ev.target.closest('button[data-intent]');
  if (b) { if(b.disabled||b.dataset.deletionBlocked==='true')return;if(b.dataset.confirm){
      const dialog=document.createElement('dialog');dialog.id='delete-workspace-dialog';
      const origin=referenceWorld(),args=JSON.parse(b.dataset.args);dialog.append(node('h2','Delete workspace?'),node('p',b.dataset.confirm));
      const cancel=node('button','Cancel'),accept=node('button','Delete workspace','primary');cancel.type=accept.type='button';accept.dataset.confirmWorkspaceDelete='true';
      cancel.onclick=()=>dialog.close();accept.onclick=()=>{if(origin!==referenceWorld()){dialog.close();receipt('delete_workspace','refused','The runtime world changed. Review the workspace again.');return;}dialog.close();submit('delete_workspace',args);};
      dialog.addEventListener('close',()=>dialog.remove());dialog.append(cancel,accept);document.body.append(dialog);dialog.showModal();cancel.focus();return;
    }submit(b.dataset.intent, JSON.parse(b.dataset.args)); return; }

  /* The form path. Arguments are read from the draft now rather than
     having been serialized at render time, so what is submitted is what
     the person can currently see in the boxes. */
  const f = ev.target.closest('button[data-intent-form]');
  if (!f) return;
  const intent = f.dataset.intentForm;
  const submittedDraft = { ...draft };
  const clearSubmitted = key => {
    if (draft[key] !== submittedDraft[key]) return;
    draft[key] = '';
    document.querySelectorAll('[data-draft]').forEach(input => {
      if (input.dataset.draft === key && input.value === submittedDraft[key]) input.value = '';
    });
  };
  submit(intent, argsFor(intent), true).then((accepted) => {
    if (!accepted) return;
    /* Cleared only for the fields this intent consumed, and only after it
       resolved. Clearing on click would discard what the person typed if
       the runtime refused it, and they would have to type it again to
       find out why. */
    if (intent === 'open_workspace') clearSubmitted('workspace_name');
    if (intent === 'open_goal') clearSubmitted('goal_title');
    if (intent === 'open_lane') { clearSubmitted('lane_actor'); clearSubmitted('lane_base'); }
    /* Only `purpose` — the Lane selection is a choice among things that
       still exist and `selectNode` already re-resolves a stale one. Close
       and reopen consume nothing typed. */
    if (intent === 'open_worker') clearSubmitted('worker_purpose');
  });
});

window.cockpit = {
  render, ack, holdBegin, holdEnd, terminalSurface, surface,
  frame: null, frames: 0, bound: false,
  /* Set only by the terminal path in `ack` above. Null means the stream has
     not told us it stopped, which is not the same as the world being quiet
     — the badge says which. */
  stalled: null,
  /* ── W.2.3 · stream continuity ───────────────────────────────────────
     `applied` is the highest sequence this page has RENDERED. `beats` and
     `valve` are what the link says about itself. `withdrawn` is set when
     the lease expires and is the page's own statement that it has stopped
     believing what is on screen. */
  applied: 0,
  beats: 0,
  duplicates: 0,
  valve: null,
  lease_ms: 0,
  withdrawn: false,
  rebinds: 0,
  /* ── W.2.3.3 · TWO clocks, because there are two facts ────────────────
     `link_heard_at` is when this page last heard anything at all. It is
     evidence about the LINK. `projection_at` is when something last
     attested that what is on screen is still being maintained — a frame,
     or a heartbeat whose valve holds nothing this page has not seen. It is
     evidence about the WORLD CLAIM.

     W.2.3.2 had one field for both and called it `heard_at`, so a heartbeat
     reporting that delivery had been abandoned refreshed the deadline that
     would have acted on it. `tools/check-webview-acl.mjs` refuses the old
     name outright: the substitution that reopens this is one identifier,
     and every comment around it would go on describing a distinction that
     had stopped existing. */
  link_heard_at: 0,
  projection_at: 0,
  /* Which of the three it was — `silence`, `unmaintained`, `exhausted` —
     and the whole of the evidence, sampled AT the withdrawal rather than
     read back afterwards. A battery reading these one round trip later
     cannot tell an exhaustion withdrawal from a lease that expired while it
     was asking. */
  withdraw_reason: null,
  withdrew_at: null,
  /* ── W.2.3.1 · the transport underneath ──────────────────────────────
     The Channel this page is currently bound to, and the callback id Tauri
     registered for it. Named for the same reason `deliver` is: the failure
     this round is about happens BELOW `onmessage`, and a witness that
     cannot address the transport cannot model it. `retired` is the id of
     every channel this page has abandoned — see `retire`. */
  channel: null,
  channel_id: null,
  /* A bounded ring of recent retirements plus the count of all of them —
     see `RETIRED_KEPT`. */
  retired: [],
  retired_total: 0,
  /* ── W.2.3.2 · the recovery's own budget ─────────────────────────────
     `candidates` is how many replacement channels THIS episode has spent.
     `unavailable` is the terminal state it reaches when the budget is gone:
     nothing claimed, nothing spent, nothing further attempted until a
     person starts a new episode — which `episodes` counts. */
  candidates: 0,
  unavailable: false,
  episodes: 0,
  /* ── W.2.3.3 · which established position this page is speaking from ──
     `stream` is the binding the host is being asked to hold: this page
     instance, and the nth channel it has built. Both halves are load-
     bearing and the second alone is not enough — see `PAGE`. Every
     `bind`/`unbind` carries it, and a continuation that finds the
     generation has moved on has stopped being evidence about anything the
     page is doing. `stale_completions` counts those. */
  stream: null,
  generation: 0,
  stale_completions: 0,
};

/* ── W.2.3 · one named entry point for everything the link delivers ──────
 *
 * W.2.2 put this logic in the Channel's `onmessage` closure, where nothing
 * could name it. It is a function on `window.cockpit` now for the same
 * reason `render` and `ack` are: the battery has to be able to model a
 * message that the host believes it sent and the page never processes.
 *
 * That is not a hypothetical. Tauri delivers a Channel payload under 8 KB
 * with `webview.eval`, and wry's WebKitGTK `eval` hands the script to
 * `run_javascript` and returns `Ok(())` **without inspecting the
 * asynchronous result** — with no callback the `Result` is dropped
 * (`wry-0.55.1/src/webkitgtk/mod.rs`; upstream wry#1644 reports exactly
 * this losing Channel messages and hanging the channel). So a frame can be
 * reported sent and never arrive, and W.2.2 wedged forever when it did.
 */
function deliver(msg) {
  const c = window.cockpit;
  /* **This line may say the LINK is alive and nothing else.** W.2.3.2 wrote
     one clock here, before anything had looked at what the message said,
     and the lease that decides whether the world region is still trustworthy
     read it. See the header. */
  c.link_heard_at = Date.now();

  /* A heartbeat is a statement about the LINK, not about the world. It
     carries no projection, is not counted as a frame, is not acknowledged,
     and must never touch a [data-source="frame"] region.

     **W.2.3.1 · and it may not end a withdrawal.** W.2.3 called `restore()`
     from here, which let evidence about the link clear a claim about the
     world. The two are not the same fact and this round is precisely about
     the difference: a heartbeat can arrive on a link whose frame stream is
     permanently wedged. Hearing one ends the SILENCE — the link clock moved
     above, so that deadline will not fire — but only a frame can end the
     withdrawal, because only a frame refills the region that was cleared.

     **W.2.3.3 · and ending the silence was all W.2.3.2 let it do.** The
     clock it moved was also the one the whole lease ran on, so a heartbeat
     reporting an abandoned delivery bought the stale projection another
     lease every 1.5 s, forever. Read on. */
  if (msg && msg.schema === 'cockpit-heartbeat@1') {
    c.beats += 1;
    c.valve = msg.valve ?? null;
    c.lease_ms = msg.lease_ms ?? 0;
    /* ── W.2.3.3 · and here is where the two facts come apart ───────────
       A heartbeat is *always* evidence that the link is alive. Whether it
       is evidence that the projection on screen is still being maintained
       depends on what it SAYS, and W.2.3.2 never asked.

       `in_flight` holds the frame the host has sent and not had back. If
       its sequence is one this page has already applied, the only thing
       outstanding is our own acknowledgement and the page is current. If it
       is NEWER than anything applied, there is a state the person is
       entitled to see that has not arrived — and then:

         `exhausted` false   the host is still retransmitting. Repair is in
                             progress; this beat attests nothing, and if the
                             repair never lands the projection deadline
                             below is what ends it.
         `exhausted` true    the host has stopped trying and is saying so.
                             That is not a silence to wait out, it is a
                             positive statement that what is on screen is
                             behind, arriving on a link that is demonstrably
                             working. Waiting for a lease that this very
                             heartbeat is keeping alive would be waiting
                             forever.

       Withdrawing is all it may do. It may not restore, it may not render,
       and it may not invent — a heartbeat is never about the world's
       CONTENTS. That rule is checked statically; see the note on `restore`
       in `tools/check-webview-acl.mjs`. */
    const f = c.valve && c.valve.in_flight;
    const unseen = !!f && typeof f.seq === 'number' && f.seq > c.applied;
    if (unseen && f.exhausted) {
      if (!c.withdrawn && !c.unavailable) withdraw('exhausted');
      return;
    }
    if (!unseen) c.projection_at = Date.now();
    return;
  }

  /* **A repeat is applied once and acknowledged every time.** The host
     retransmits an unacknowledged frame as itself, so the same sequence can
     legitimately arrive twice — once lost on the way down, once lost on the
     way back. Re-rendering it would reflow the list under a person's cursor
     for no new information; not acknowledging it would leave the host
     retransmitting forever. And a frame OLDER than one already applied can
     arrive from a channel that was replaced while a message was in flight;
     rendering that would walk the world backwards after recovery. */
  if (typeof msg?.seq !== 'number') return;

  /* **A frame of any sequence attests maintenance**, including a repeat.
     The repeat means the host is still delivering and our acknowledgement
     was what went missing — the frame path is working, which is the whole
     of what `projection_at` records. Set before the dedup return, so a
     stream that is healthy except for a lost ack is not withdrawn by the
     deadline for a fault it does not have. */
  c.projection_at = Date.now();

  if (msg.seq <= c.applied) {
    c.duplicates += 1;
    c.ack(msg.seq);
    return;
  }

  c.applied = msg.seq;
  c.frame = msg;
  c.frames += 1;
  if (c.withdrawn) restore();
  render(msg);
  c.ack(msg.seq);
}

/* ── the lease ───────────────────────────────────────────────────────────
 *
 * A quiet world and a dead stream look identical on screen, and only one of
 * them means the projection is still being maintained. The host says *I am
 * still here* on the same Channel; if this page hears nothing at all —
 * neither frame nor heartbeat — for longer than the lease it was given, it
 * **stops claiming**: the badge withdraws, the world region says so, and
 * every control that submits authority is disabled.
 *
 * A timeout may say "I no longer know that this is being maintained". It
 * may never invent world state, and it does not: nothing here writes a
 * grant, and `render` is not called.
 */

/* ── W.2.3.2 · how many replacement channels one episode may try ────────
 *
 * **Policy, not physics, and named as policy.** There is no measurement
 * behind three; it is the number of independent chances a link gets before
 * the page stops spending on it and says so. It is here rather than inlined
 * so that changing it is a decision somebody makes on purpose.
 */
const CANDIDATE_LIMIT = 3;

/* How many retired channel ids to keep for diagnosis.
 *
 * W.2.3.1 kept every one, forever. In a round whose whole subject is that a
 * recovery must not consume without bound, an unbounded diagnostic
 * collection inside the recovery is the defect in miniature — and it grows
 * fastest in exactly the failure it exists to describe. The total is kept
 * as a count; the ids are a ring. */
const RETIRED_KEPT = 4;

/* **W.2.3.3 · three reasons, and the person is told which.**
 *
 * They are three different states of knowledge and only one of them used to
 * exist. `silence` is *I have heard nothing*. `unmaintained` is *I am
 * hearing you, and nothing you have said in a whole lease confirms that
 * what I am showing is current*. `exhausted` is *you have told me you gave
 * up*. Collapsing them into one message would be the same mistake as
 * collapsing the two clocks: a screen that cannot distinguish "I do not
 * know" from "I know it is stale" is back to hope.
 */
const SAID = {
  silence:
    'The frame stream has gone quiet for longer than its lease. What was on '
    + 'screen is no longer known to be maintained, so it is not being shown. '
    + 'Trying to re-establish it.',
  unmaintained:
    'The link is answering, but nothing it has said for a whole lease confirms '
    + 'that what was on screen is still current: a newer state is stuck between '
    + 'the runtime and this page. It is not being shown. Trying to re-establish it.',
  exhausted:
    'The runtime has stopped trying to deliver a newer state and has said so. '
    + 'What was on screen is known to be behind, so it is not being shown. The '
    + 'link is still answering — which is exactly why this had to be stated '
    + 'rather than waited out. Trying to re-establish it.',
  /* A person asked for a new episode from the terminal state. Nothing has
     failed yet; nothing is claimed yet either, and saying `silence` here
     would be reporting evidence the page does not have. */
  episode:
    'Trying to re-establish the frame stream. Nothing is being claimed about '
    + 'the world until one is.',
};

function withdraw(reason) {
  const c = window.cockpit;
  c.withdrawn = true;
  c.withdraw_reason = reason;

  /* **Sampled here, at the withdrawal.** Whether the silence deadline could
     have caused this is a fact about the instant it happened, and a witness
     that reads `link_heard_at` a round trip later is reading a page that has
     been hearing heartbeats in the meantime. The transport-gap witness in
     W.2.3.1 paid for this lesson once; this is the same discipline moved
     into the product, because here the evidence is only available to the
     page. */
  const now = Date.now();
  c.withdrew_at = {
    reason,
    link_age_ms: c.link_heard_at ? now - c.link_heard_at : null,
    projection_age_ms: c.projection_at ? now - c.projection_at : null,
    lease_ms: c.lease_ms,
    beats: c.beats,
    applied: c.applied,
    exhausted: !!(c.valve && c.valve.in_flight && c.valve.in_flight.exhausted),
  };

  el.state.textContent = 'stream lost';
  el.state.dataset.state = 'reacquire';
  el.main.textContent = '';
  clearWorkspacePicker();
  const p = document.createElement('p');
  p.className = 'empty';
  p.textContent = SAID[reason] ?? SAID.silence;
  el.main.append(p);

  /* Nothing may be submitted against a world this page has stopped
     vouching for. */
  document.querySelectorAll('button[data-intent]').forEach((b) => { b.disabled = true; });

  nextCandidate();
}

/* ── W.2.3.1 · reacquisition is a LOOP, and W.2.3's was a single shot ────
 *
 * `withdraw()` returned early once `withdrawn` was set, and only `deliver`
 * could clear it — so **exactly one rebind was ever attempted per
 * episode**. If the channel that rebind produced was also dead, the page
 * sat on *stream lost* forever, having tried once. That is W.2.2's defect
 * one layer further out: a recovery path whose own failure is permanent
 * silence.
 *
 * It is not hypothetical here, and that is the point of the round. The
 * failure being recovered from is a lost WebKit `run_javascript` — nothing
 * says the second call succeeds because the first did. A recovery that
 * assumes its own success is a claim, not a mechanism.
 */
/* ── W.2.3.2 · a candidate is judged by the SAME deadline as the stream ──
 *
 * W.2.3.1 gave a replacement channel `REACQUIRE_EVERY` — 3 s — to prove
 * itself, while an established channel got the host's advertised lease of
 * 6 s. **So the recovery held its candidates to a stricter timing guarantee
 * than the failure detector whose verdict put it there.** A perfectly
 * healthy channel whose first frame took four seconds was killed at three,
 * and the next one, and the next: a permanent outage manufactured out of a
 * merely slow recovery, by the mechanism that exists to end outages.
 *
 * There is one silence deadline in this file. The link clock starts when a
 * candidate is *attempted* rather than when its `bind` resolves, because
 * the waiting starts at the attempt; and the only thing that ends a
 * candidate early is the page hearing nothing for as long as the host
 * itself says silence may last.
 *
 *   > A recovery mechanism may not assume a stricter timing guarantee than
 *   > the mechanism whose failure it is recovering from.
 */
function nextCandidate() {
  const c = window.cockpit;
  if (c.candidates >= CANDIDATE_LIMIT) return unavailable();
  c.candidates += 1;
  c.rebinds += 1;
  /* The candidate's lease starts now, not when the invoke resolves — else
     a slow `bind` would be charged to the channel it produced.
     **W.2.3.3 · and W.2.3.2 said exactly that and then did the opposite**:
     `bind()`'s success arm wrote the clock again when the invoke resolved,
     so a slow or saturated bind silently minted extra lease time for the
     candidate it produced — the brief's claim and the code disagreed, and
     the code was the one running. There is now no clock write in `bind` at
     all, and `tools/check-webview-acl.mjs` counts the assignment sites so
     one cannot come back. */
  c.link_heard_at = Date.now();
  bind();
}

/* ── W.2.3.2 · the terminal state, and why there has to be one ───────────
 *
 * `RETRY_LIMIT` bounds how many times one channel is written to. It is not
 * a bound on anything if the page may then build another channel, and
 * another, without end — **a local budget that recovery can re-mint is not
 * a budget.** Under a permanently broken WebKit transport W.2.3.1 would
 * allocate channels forever, and on Tauri's >8192 path each send whose
 * script never ran leaves a whole serialised projection in
 * `ChannelDataIpcQueue`, a Rust-side map `unregisterCallback` cannot reach.
 * So the page's own retirement discipline could not have bounded it.
 *
 *   > A recovery procedure must itself have a bounded failure mode.
 *
 * UNAVAILABLE is that bound. It claims nothing — no world, no submittable
 * authority, exactly as the withdrawal did — and it additionally stops
 * *spending*: the last channel is retired, the host is told to stop
 * sending, and no further channel is created until a person asks.
 */
function unavailable() {
  const c = window.cockpit;
  c.unavailable = true;

  retire(c.channel);
  c.channel = null;
  c.channel_id = null;
  c.bound = false;

  /* **Telling the host is half of it.** Retiring the callback stops this
     page reading; only this stops the host writing. Without it the runtime
     goes on sending into a webview that has stopped listening, which is the
     resource cost this state exists to end rather than to relocate.

     **W.2.3.3 · and it names the stream it is tearing down.** This invoke
     is not awaited and the one that follows a person's *Try again* is a
     separate command on a separate task: nothing in the IPC orders them,
     and `main.rs` claimed the shared control lane did. It does not — the
     lane orders messages already in it, and the two hops that put them
     there are an `async_runtime::spawn` and a `spawn_blocking` apiece. An
     unbind that overtook the bind after it would have torn down the stream
     the retry had just established. Named, the host can refuse it. */
  invoke('unbind_frame_stream', { stream: c.stream ?? { page: PAGE, generation: c.generation } }).catch(() => {});

  el.state.textContent = 'stream unavailable';
  el.state.dataset.state = 'reacquire';
  el.main.textContent = '';
  clearWorkspacePicker();
  const p = document.createElement('p');
  p.className = 'empty';
  p.textContent =
    `The frame stream could not be re-established after ${CANDIDATE_LIMIT} attempts. `
    + 'Nothing is being claimed about the world and nothing further is being '
    + 'tried. The runtime may still be healthy — this page cannot tell, which '
    + 'is why it is not saying.';
  const b = document.createElement('button');
  /* **No `data-intent`.** This asks the page to try again; it submits
     nothing to the runtime and reaches no authority. The disabled-controls
     assertions are about `button[data-intent]` and are untouched by it. */
  b.id = 'retry-stream';
  b.textContent = 'Try again';
  b.addEventListener('click', retry);
  el.main.append(p, b);
}

/* A deliberate new episode. The budget is spent by the page, so only a
   person may replenish it. */
function retry() {
  const c = window.cockpit;
  if (!c.unavailable) return;
  c.unavailable = false;
  c.candidates = 0;
  c.episodes += 1;
  withdraw('episode');
}

/* Only a frame gets here — see `deliver`. A frame is the evidence that a
   candidate worked, so it is also what ends the episode and returns the
   budget. */
function restore() {
  const c = window.cockpit;
  c.withdrawn = false;
  c.withdraw_reason = null;
  c.candidates = 0;
  document.querySelectorAll('button[data-intent]').forEach((b) => { b.disabled = b.dataset.deletionBlocked==='true'; });
}

function leaseTick() {
  const c = window.cockpit;
  /* Terminal. Nothing is attempted and nothing is claimed until a person
     starts a new episode. */
  if (c.unavailable) return;
  if (!c.bound || !c.lease_ms) return;

  /* **ONE silence deadline**, W.2.3.2's rule: a candidate is not held to a
     stricter timing guarantee than the failure detector whose verdict put
     it there. */
  const silent = c.link_heard_at > 0 && Date.now() - c.link_heard_at > c.lease_ms;

  if (c.withdrawn) {
    /* Reacquisition is a LOOP — W.2.3.1. A candidate that has said nothing
       for a whole lease is spent, and the next one is attempted. */
    if (silent) return nextCandidate();
    return;
  }

  if (silent) return withdraw('silence');

  /* ── W.2.3.3 · the deadline the silence deadline cannot reach ─────────
     Heartbeats arriving keep `link_heard_at` fresh forever, so `silent` is
     false for as long as the link answers. It says nothing about whether
     what is on screen is still being maintained, and under a fault that
     loses frames while heartbeats get through — two Tauri transports, two
     independent failure modes; see the header — that is the entire
     difference between a truthful cockpit and a confident one.

     Gated on `applied`, because a page that has never been shown a frame is
     not claiming anything for a deadline to be about. */
  if (c.applied > 0 && c.projection_at > 0
      && Date.now() - c.projection_at > c.lease_ms) {
    return withdraw('unmaintained');
  }
}

/* ── W.2.3.1 · retiring the channel a rebind replaces ───────────────────
 *
 * A Tauri `Channel` unregisters its own callback when it has seen every
 * transport index up to the `end` its Rust side sends on drop
 * (`#nextMessageIndex === #messageEndIndex → cleanupCallback()`). **The
 * failure this round is about is exactly the one that makes that
 * precondition unreachable**: an index that never arrives is an index the
 * count never passes, so `end` is recorded and waited on forever. Measured
 * on the running app — after one dropped raw callback the abandoned id is
 * still in `__TAURI_INTERNALS__.callbacks`, and every later payload sits in
 * that channel's `#pendingMessages` holding a whole projection each.
 *
 * So the page performs the retirement Tauri would have performed. This is
 * `Channel.cleanupCallback()`'s own body — `unregisterCallback(this.id)` —
 * called in the one case its caller can never run. It is a deliberate,
 * named dependency on a Tauri internal rather than an accidental one:
 * `check-webview-acl.mjs` fails the build if this file reaches for
 * `runCallback` instead, which is the seam that looks equivalent and is
 * not — it is defined non-writable and non-configurable, and assigning to
 * it throws.
 *
 * Best-effort by construction. A Tauri that no longer exposes this simply
 * leaves the old callback registered, which is where W.2.3 already was. */
function retire(ch) {
  if (!ch) return;
  if (typeof window.__TAURI_INTERNALS__?.unregisterCallback !== 'function') return;
  try {
    window.__TAURI_INTERNALS__.unregisterCallback(ch.id);
    /* Bounded — see `RETIRED_KEPT`. The count is the fact; the ids are a
       window onto the recent ones. */
    window.cockpit.retired.push(ch.id);
    if (window.cockpit.retired.length > RETIRED_KEPT) window.cockpit.retired.shift();
    window.cockpit.retired_total += 1;
  } catch (e) {
    /* Nothing here is load-bearing for correctness — the new channel is
       the one being read. */
  }
}

/* ── W.2.3.3 · WHICH page, and a generation counter is not enough ────────
 *
 * The obvious identity for a binding is a counter the page increments. It
 * is wrong here, and the reload check at the end of `cockpit-battery.mjs`
 * is what says so: a reload is a NEW page whose counter starts at one
 * again, and a host refusing anything at or below the generation it already
 * holds would refuse the reloaded page its stream forever — a cockpit that
 * survives a dead transport and dies of being reloaded.
 *
 * The counter collapses two facts, exactly as `heard_at` did. *Which page*
 * and *which attempt by that page* are different questions: a new page is a
 * new locus and is authoritative; a superseded attempt by the SAME page is
 * not. So the identity carries both, the host compares generations only
 * within a page, and a different page always wins.
 */
const PAGE = (globalThis.crypto && typeof crypto.randomUUID === 'function')
  ? crypto.randomUUID()
  : `p-${Date.now().toString(36)}-${Math.floor(Math.random() * 1e9).toString(36)}`;

/* Handler first, sink second. Nothing can be sent to this page until the
   invoke below returns, so the first frame cannot be lost to a listener
   that had not finished registering. */
function bind() {
  const c = window.cockpit;

  /* The channel this one replaces cannot be a source of truth: the host
     drops its end on `bind`, and a page that kept reading it would be
     reading a stream nobody maintains. Retire it before the replacement
     exists, so no window has two live sinks in it. */
  retire(c.channel);

  const generation = (c.generation += 1);
  const stream = { page: PAGE, generation };

  const frames = new Channel();
  frames.onmessage = (msg) => window.cockpit.deliver(msg);
  c.channel = frames;
  c.channel_id = frames.id;
  c.stream = stream;

  /* **Nothing time-related is written below.** The candidate's deadline
     began at the attempt — see `nextCandidate` — and a bind that resolves
     is not a message that arrived. */
  return invoke('bind_frame_stream', { stream, channel: frames }).then(
    () => {
      if (!current(generation)) return;
      window.cockpit.bound = true;
    },
    (e) => {
      if (!current(generation)) return;
      /* The page is not permitted to bind a stream. That is what an
         untrusted pane sees, and saying so is better than an empty window
         that looks like a dead runtime. */
      el.main.textContent = '';
  clearWorkspacePicker();
      const p = document.createElement('p');
      p.className = 'empty';
      p.textContent = `This webview may not bind the frame stream: ${e}`;
      el.main.append(p);
    },
  );
}

/* **W.2.3.3 · a completion is evidence about the position it was issued
 * from, and about no other.**
 *
 * A promise that resolves after the page has moved on still holds a closure
 * over `window.cockpit` and still knows which fields to write. It has
 * stopped having any standing to write them: the channel it was about is
 * retired, the candidate it was timing has been replaced, and the paragraph
 * it wants to paint would describe a binding that no longer exists. Knowing
 * how to reach the state is not the same as being the state's current
 * occupant, and this is the one line that says so. */
function current(generation) {
  if (window.cockpit.generation === generation) return true;
  window.cockpit.stale_completions += 1;
  return false;
}

window.cockpit.deliver = deliver;
window.cockpit.bind = bind;

initBots({ invoke, apply: submit, current: () => window.cockpit, runtimeBotActions:{
  register:args=>submit('register_bot',args),
  update:args=>submit('update_bot',args),
  remove:args=>submit('remove_bot',args)
} });
initDevelopment({invoke,apply:submit,recordAttempt:args=>submit('record_development_attempt',args),recordSet:args=>submit('record_development_change_set',args),current:()=>window.cockpit});
const nativeReviewActions={'accept_development_attempt':args=>invoke('review_tests',{request:{operation:'accept',...args}})};
initDevelopmentTasks({invoke,actions:{accept:nativeReviewActions['accept_development_attempt'],create:args=>submit('create_development_task',args),update:args=>submit('update_development_task',args),updateAttempt:args=>submit('update_development_attempt',args),checkAttempt:args=>submit('check_development_attempt_text',args)},current:()=>window.cockpit});
initShell();
// Polls only while the Mobile page is on screen; see mobile-device.js.
initMobileDevice(invoke, node);
initDesktopChrome(invoke);
bind();
setInterval(leaseTick, 500);
