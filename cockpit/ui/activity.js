/* Activity — what is running, what has run, and what this world has left.
 *
 * T18a. The core of `DOCTRINE.md` says the human's job is to *set direction and
 * judge evidence, not to babysit steps*, and that sentence decides what belongs
 * on this screen. Watching bytes arrive is babysitting. Whether a run passed,
 * what it ran on, and whether this world is about to refuse the next one is
 * evidence, and it is the kind a person acts on.
 *
 * So the three panels are: what is running NOW (from the frame, which is
 * already pushed), what has RUN (every profile run this world holds, live and
 * archived alike — which is why T17 kept `test_runs` on an archived card), and
 * CAPACITY (the bounds, published before they refuse rather than at the moment
 * they do).
 *
 * **Nothing here samples, stores or estimates.** There is no token count in
 * this runtime — `received_bytes` is bytes of assistant text and
 * `thinking_tokens` is a provider's estimate of thinking alone, on one
 * connection — and rule 2 says an invented number is worse than a missing one.
 * The live reply is shown as what it is: bytes received and the provider's own
 * phase, unnamed as anything else.
 */

/** Above this fraction a bound is worth noticing; above the second, acting on. */
export const WATCH = 0.7;
export const FULL = 0.9;

const pct = (used, max) => (max > 0 ? used / max : 0);

/**
 * The bounds, as rows a bar can be drawn from.
 *
 * Returns `[]` when the runtime does not publish `capacity` — an older one, or
 * the agent projection, which has no business carrying a world's ceilings. An
 * empty list renders as "this runtime does not report it", never as zero used:
 * a bar at 0 % is a claim, and the honest answer here is that nothing was said.
 */
export function capacityRows(projection) {
  const c = projection?.capacity;
  if (!c || c.schema !== 'world-capacity@1') return [];
  const row = (key, label, block, note) => {
    const used = Number(block?.bytes ?? 0), max = Number(block?.max ?? 0);
    const fraction = pct(used, max);
    return {
      key, label, used, max, fraction,
      state: fraction >= FULL ? 'full' : fraction >= WATCH ? 'watch' : 'ok',
      records: block?.records ?? null,
      archived: block?.archived ?? null,
      note,
    };
  };
  return [
    row('frame', 'Projection frame', c.frame, c.frame?.measures),
    row('attempts', 'Review directory', c.attempts,
        c.attempts?.reserved ? `${c.attempts.reserved} B reserved for runs in flight` : null),
    row('plans', 'Plan directory', c.plans, c.plans?.measures),
  ];
}

/**
 * What has left the live directories, newest finished first.
 *
 * T21. T14 and T16 gave the two directories an exit and T17 put every archived
 * record on the frame as a card — so **this costs nothing new on the wire**:
 * the marker `archived_cards/3` already writes is what tells the two apart, and
 * this reads it. Until now the only trace of an archive anywhere in the app was
 * a count in the capacity row, a number with nothing behind it.
 *
 * **There is deliberately no restore, and that is not an omission.**
 * `bot-directory.js` archives a bot BY CHOICE and can therefore un-choose it. A
 * plan is archived BECAUSE IT IS FINISHED — `Ampd.DevelopmentTask.update/3`
 * refuses `task-completed` and `task-cancelled` by name — so there is nothing to
 * restore it to. Different reason, different affordance.
 */
export function archivedRecords(projection) {
  const card = r => r && r.archived && r.archived.schema === 'archived-record-card@1';
  const plans = Object.values(projection?.development_tasks ?? {}).filter(card).map(t => ({
    ref: t.id,
    kind: 'plan',
    title: t.title ?? t.id,
    status: t.status ?? 'unknown',
    at: t.completion?.at ?? null,
    accepted: t.completion?.accepted_attempt_refs ?? [],
  }));
  const attempts = Object.values(projection?.development_attempts ?? {}).filter(card).map(a => ({
    ref: a.id,
    kind: 'attempt',
    title: a.source?.path ?? (Array.isArray(a.files) ? `${a.files.length} files · combined review` : a.id),
    status: a.status ?? 'unknown',
    at: a.acceptance?.accepted_at ?? null,
    task_ref: a.task_ref ?? null,
  }));
  // Newest first. A record with no time falls out last without a clause of its
  // own: `?? ''` makes it the empty string, which a DESCENDING compare puts at
  // the end. An explicit null-first test was written here and removed once a
  // mutant showed it changed nothing — the behaviour is the fallback's, and the
  // case below pins it so a change to that fallback cannot quietly move them.
  // Ties broken by ref, so the order is total and does not shuffle per frame.
  const order = (x, y) =>
    String(y.at ?? '').localeCompare(String(x.at ?? '')) ||
    String(y.ref).localeCompare(String(x.ref));
  return {plans: plans.sort(order), attempts: attempts.sort(order)};
}

/**
 * What the frame's archived-attempt window left out, said where it matters.
 *
 * T23. Archived attempts ride in a window of the most recently finished plans,
 * so the archived-review list and the run history below are windows too. A list
 * that shortened silently would present "the reviews this world holds" and
 * "every profile run" as complete. `null` for each when nothing is withheld,
 * including a runtime from before T23, which publishes no window.
 */
export function windowNotes(projection) {
  const w = attemptWindowOf(projection);
  if (!w || !w.withheldAttempts) return {reviews: null, runs: null};
  const n = (k, one, many) => `${k} ${k === 1 ? one : many}`;
  const plans = n(w.withheldPlans, 'earlier finished plan', 'earlier finished plans');
  return {
    reviews: `${n(w.withheldAttempts, 'review', 'reviews')} of ${plans} ${w.withheldAttempts === 1 ? 'is' : 'are'} kept in the world ` +
      `and not in this view, which carries the reviews of the ${n(w.carriedPlans, 'most recently finished plan', 'most recently finished plans')}.`,
    runs: w.withheldRuns
      ? `${n(w.withheldRuns, 'more profile run', 'more profile runs')}, on the reviews of ${plans}, ${w.withheldRuns === 1 ? 'is' : 'are'} kept in the world and not in this view.`
      : null,
  };
}

/** The worst bound, for a one-line summary. `null` when nothing is reported. */
export function worstBound(rows) {
  if (!rows.length) return null;
  return rows.reduce((a, b) => (b.fraction > a.fraction ? b : a));
}

/**
 * Every profile run this world holds, newest first.
 *
 * Read across ALL attempts, archived included — which is exactly why T17 kept
 * `test_runs` on an archived card rather than saving the 6.5 points of frame it
 * would have cost to drop it. A run history that stopped at the last few live
 * attempts would be a history of this week.
 */
export function runRows(projection) {
  const rows = [];
  for (const attempt of Object.values(projection?.development_attempts ?? {})) {
    for (const run of Object.values(attempt.test_runs ?? {})) {
      rows.push({
        run_id: run.run_id ?? null,
        profile: run.profile ?? 'super-javascript-behavior@1',
        state: run.state ?? 'unknown',
        verdict: run.state === 'started' ? null : (run.outcome?.verdict ?? null),
        tests: run.outcome?.test_count ?? null,
        snapshot: run.outcome?.snapshot_sha256 ?? null,
        started_at: run.started_at ?? null,
        attempt_ref: attempt.id,
        task_ref: attempt.task_ref ?? null,
      });
    }
  }
  // Ties broken by run id so the order is total: two runs started in the same
  // millisecond must not swap places between frames.
  return rows.sort((a, b) =>
    String(b.started_at ?? '').localeCompare(String(a.started_at ?? '')) ||
    String(b.run_id ?? '').localeCompare(String(a.run_id ?? '')));
}

/** Pass / fail / still running, counted over whatever rows you hand it. */
export function runTally(rows) {
  const t = {passed: 0, failed: 0, running: 0, incomplete: 0};
  for (const r of rows) {
    if (r.state === 'started') t.running++;
    else if (r.state !== 'completed') t.incomplete++;
    else if (r.verdict === 'pass') t.passed++;
    else t.failed++;
  }
  return t;
}

/**
 * What is running right now, from the frame plus the reply sample.
 *
 * `reply` is the most recent `reply_status` the conversation poll has seen
 * (`bots.js` re-broadcasts it); it is session-only and nothing keeps it. Its
 * bytes are described as bytes, because that is what they are.
 */
export function nowRows(projection, reply) {
  const rows = [];
  for (const r of runRows(projection)) {
    if (r.state === 'started') {
      rows.push({kind: 'run', label: r.profile, detail: `${r.attempt_ref} · started ${r.started_at ?? '—'}`});
    }
  }
  for (const e of Object.values(projection?.effects ?? {})) {
    rows.push({kind: 'effect', label: e.capability ?? e.id ?? 'effect', detail: e.state ?? e.status ?? 'in flight'});
  }
  if (reply?.active) {
    const bytes = Number(reply.received_bytes ?? 0);
    rows.push({
      kind: 'reply',
      label: reply.phase || 'Waiting for provider',
      detail: bytes
        ? `${bytes.toLocaleString()} bytes of assistant text received`
        : 'no assistant text received yet',
    });
  }
  return rows;
}

/* ── the screen ─────────────────────────────────────────────────────────────
 * Rendering only. Every decision above is reached before a node is made, which
 * is the shape `retainedSide()` and `fieldState()` already use here and the
 * reason those two are under test while a renderer is not.                    */
import {node, panel} from './app-shell.js';
import {attemptWindowOf} from './archived-record.js';

const bytes = n => (n >= 1024 ? `${(n / 1024).toFixed(1)} KB` : `${n} B`);

function bar(row) {
  const wrap = node('div', undefined, 'capacity-row');
  wrap.dataset.capacity = row.key;
  wrap.dataset.capacityState = row.state;
  const head = node('div', undefined, 'capacity-head');
  head.append(node('span', row.label), node('span', `${Math.round(row.fraction * 100)} %`, 'capacity-pct'));
  const track = node('div', undefined, 'capacity-track'), fill = node('div', undefined, 'capacity-fill');
  fill.style.width = `${Math.min(100, Math.round(row.fraction * 100))}%`;
  track.append(fill);
  wrap.append(head, track,
    node('p', `${bytes(row.used)} of ${bytes(row.max)}` +
      (row.records !== null ? ` · ${row.records} live` : '') +
      (row.archived ? ` · ${row.archived} archived` : ''), 'directory-note'));
  // A footnote, not a warning. `availability-note` is a bordered callout in
  // this app's CSS, and two of them under two green bars read as two
  // problems — looked at in the running app, which is the only way that
  // was going to be noticed.
  if (row.note) wrap.append(node('p', row.note, 'directory-note'));
  return wrap;
}

export function activityPanel(projection, reply) {
  const root = panel('activity');
  root.dataset.activityView = '';

  // --- capacity first: it is the one that stops work, and it is the one no
  //     surface in this app has ever shown.
  const cap = node('section', undefined, 'activity-capacity');
  cap.append(node('h2', 'Capacity'));
  const rows = capacityRows(projection);
  if (!rows.length) {
    cap.append(node('p', 'This runtime does not report its bounds. Nothing is claimed about how full it is.', 'availability-note'));
  } else {
    const worst = worstBound(rows);
    const line = node('p',
      worst.state === 'full' ? `${worst.label} is at ${Math.round(worst.fraction * 100)} %. The next write may be refused.`
      : worst.state === 'watch' ? `${worst.label} is at ${Math.round(worst.fraction * 100)} %. Finishing work frees it.`
      : 'Every bound this runtime reports has room.',
      'availability-note');
    line.dataset.capacitySummary = worst.state;
    cap.append(line);
    for (const r of rows) cap.append(bar(r));
  }

  // T21. The capacity rows have counted what is archived since T18a; this is
  // the first place in the app that says WHAT. It adds nothing to the frame —
  // T17 already put every archived record on it as a card.
  const gone = archivedRecords(projection), notes = windowNotes(projection);
  for (const [kind, label, rows2] of [['plans', 'plans', gone.plans], ['attempts', 'reviews', gone.attempts]]) {
    // T23: a window that carries no archived review still has reviews to say
    // are kept, so an empty list is not a reason to say nothing.
    const withheld = kind === 'attempts' ? notes.reviews : null;
    if (!rows2.length && !withheld) continue;
    const box = node('details', undefined, 'activity-archived');
    box.dataset.archived = kind;
    box.append(node('summary', `${rows2.length} archived ${label}${withheld ? ' in view' : ''}`));
    if (withheld) {
      const kept = node('p', withheld, 'directory-note');
      kept.dataset.archivedWithheld = '';
      box.append(kept);
    }
    box.append(node('p', kind === 'plans'
      ? 'Finished plans. They hold no directory budget and cannot be reopened — finishing is terminal.'
      : 'Reviews of finished plans. Their identity, acceptance and runs are kept; the working material was released.',
      'directory-note'));
    for (const r of rows2) {
      const row = node('article', undefined, 'guidance-item');
      row.dataset.archivedRef = r.ref;
      const open = node('button', r.title, 'subtle');
      open.type = 'button';
      // The app's own deep-link contract: a plan ref, optionally with an
      // attempt to reveal inside it (`development-tasks.js`'s `reveal`).
      open.dataset.developmentTask = r.kind === 'plan' ? r.ref : (r.task_ref ?? '');
      if (r.kind === 'attempt' && r.task_ref) open.dataset.attemptId = r.ref;
      if (!open.dataset.developmentTask) open.disabled = true;
      // **The ref goes in an attribute, not in the text.** `references.js`
      // rewrites any `dt_`/`da_` id it finds in a text node into that record's
      // display label — so `${r.ref}` rendered the plan's title a second time,
      // and a plan's accepted reviews came out as "Review of <the whole title>"
      // once each. Found by opening the screen, not by reading the code.
      open.title = r.ref;
      row.append(open, node('p',
        `${r.status} · ${r.at ?? 'no recorded time'}` +
        (r.accepted?.length ? ` · ${r.accepted.length} accepted review${r.accepted.length === 1 ? '' : 's'}` : ''),
        'directory-note'));
      box.append(row);
    }
    cap.append(box);
  }
  root.append(cap);

  // --- now
  const now = node('section', undefined, 'activity-now');
  fillNow(now, projection, reply);
  root.append(now);

  // --- runs
  const runs = node('section', undefined, 'activity-runs');
  const all = runRows(projection), tally = runTally(all);
  runs.append(node('h2', `Runs (${all.length})`),
    node('p', `${tally.passed} passed · ${tally.failed} failed · ${tally.running} running · ${tally.incomplete} incomplete`, 'directory-note'));
  if (notes.runs) {
    const kept = node('p', notes.runs, 'directory-note');
    kept.dataset.runsWithheld = '';
    runs.append(kept);
  }
  if (!all.length && !notes.runs) runs.append(node('p', 'No profile run is recorded in this world.', 'availability-note'));
  for (const r of all.slice(0, 50)) {
    const item = node('article', undefined, 'guidance-item');
    item.dataset.activityRun = r.run_id ?? '';
    item.dataset.activityVerdict = r.verdict ?? r.state;
    const open = node('button', r.profile, 'subtle');
    open.type = 'button';
    if (r.task_ref) open.dataset.developmentTask = r.task_ref;
    if (r.attempt_ref) open.dataset.attemptId = r.attempt_ref;
    item.append(open,
      node('p', `${r.verdict ?? r.state}${r.tests ? ` · ${r.tests} tests` : ''} · ${r.started_at ?? 'no start time'}`, 'directory-note'));
    runs.append(item);
  }
  if (all.length > 50) runs.append(node('p', `Showing the 50 most recent of ${all.length}.`, 'availability-note'));
  root.append(runs);
  return root;
}

/* The Now panel's contents, separable because it is the one part that moves
 * between frames: the reply poll samples every 300 ms and the world does not.
 * Everything else on this screen changes only when a frame arrives. */
function fillNow(section, projection, reply) {
  const running = nowRows(projection, reply);
  section.dataset.activityRunning = String(running.length);
  section.replaceChildren(node('h2', 'Now'));
  if (!running.length) section.append(node('p', 'Nothing is running.', 'availability-note'));
  for (const r of running) {
    const item = node('article', undefined, 'guidance-item');
    item.dataset.activityKind = r.kind;
    item.append(node('p', r.label), node('p', r.detail, 'directory-note'));
    section.append(item);
  }
}

/**
 * Repaint Now from a fresh reply sample without touching the rest of the screen.
 *
 * Returns false when the screen is not mounted, which is the common case — the
 * poll runs whenever a bot is replying, and this panel is usually not the one
 * being looked at. A repaint of the whole frame every 300 ms to move one line
 * of text would be the cost this app already pays elsewhere and regrets.
 */
export function refreshNow(projection, reply) {
  const section = document.querySelector('[data-activity-view] .activity-now');
  if (!section) return false;
  fillNow(section, projection, reply);
  return true;
}
