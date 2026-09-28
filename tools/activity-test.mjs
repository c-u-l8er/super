/* The Activity screen's decisions, made before anything is drawn.
 *
 * T18a. `DOCTRINE.md`'s core says the human's job is to judge evidence, not to
 * babysit steps, so the cases below are about the three things a person would
 * act on: is a bound about to refuse, did a run pass, and what is running. None
 * of them is about how fast bytes arrive.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {capacityRows, worstBound, runRows, runTally, nowRows, archivedRecords, WATCH, FULL} from '../cockpit/ui/activity.js';

const capacity = (over = {}) => ({
  schema: 'world-capacity@1',
  frame: {bytes: 100, max: 1000, measures: 'this projection, excluding the capacity block itself'},
  attempts: {bytes: 200, max: 1000, records: 2, archived: 7, reserved: 0},
  plans: {bytes: 300, max: 1000, records: 3, archived: 9, measures: 'recursive term weight'},
  ...over,
});

test('a runtime that reports no capacity yields no rows — and never a zero bar', () => {
  // A bar at 0 % is a claim. "Nothing was said" is the truth here, and the
  // renderer can only tell them apart if this returns empty rather than zeros.
  assert.deepEqual(capacityRows({}), []);
  assert.deepEqual(capacityRows(null), []);
  assert.deepEqual(capacityRows({capacity: {schema: 'something-else@1'}}), []);
});

test('the three bounds come back in a drawable shape', () => {
  const rows = capacityRows({capacity: capacity()});
  assert.deepEqual(rows.map(r => r.key), ['frame', 'attempts', 'plans']);
  assert.equal(rows[2].fraction, 0.3);
  assert.equal(rows[1].records, 2);
  assert.equal(rows[1].archived, 7);
});

test('the three states are keyed to the thresholds, at the boundary', () => {
  const at = n => capacityRows({capacity: capacity({frame: {bytes: n, max: 1000}})})[0].state;
  assert.equal(at(WATCH * 1000 - 1), 'ok');
  assert.equal(at(WATCH * 1000), 'watch', 'the threshold itself must already be watch');
  assert.equal(at(FULL * 1000 - 1), 'watch');
  assert.equal(at(FULL * 1000), 'full');
});

test('a bound that is already over reports full, not a fraction below one', () => {
  // This is the state the block exists for: the world that refused a frame was
  // at 264,708 of 262,144, and a surface that clamped it to "ok" would be the
  // silence the whole panel is here to end.
  const rows = capacityRows({capacity: capacity({frame: {bytes: 1200, max: 1000}})});
  assert.equal(rows[0].state, 'full');
  assert.ok(rows[0].fraction > 1);
});

test('the worst bound is the one reported, not the first', () => {
  const rows = capacityRows({capacity: capacity({plans: {bytes: 950, max: 1000}})});
  assert.equal(worstBound(rows).key, 'plans');
  assert.equal(worstBound([]), null);
});

const world = {
  development_attempts: {
    da_1: {id: 'da_1', task_ref: 'dt_1', test_runs: {
      r1: {run_id: 'r1', profile: 'p-js', state: 'completed', started_at: '2026-09-20T10:00:00Z', outcome: {verdict: 'pass', test_count: 50}},
    }},
    da_2: {id: 'da_2', task_ref: 'dt_1', archived: {schema: 'archived-record-card@1', omitted: ['history'], read_with: 'read_development_attempt'}, test_runs: {
      r2: {run_id: 'r2', profile: 'p-ex', state: 'completed', started_at: '2026-09-20T09:00:00Z', outcome: {verdict: 'fail'}},
      r3: {run_id: 'r3', profile: 'p-ex', state: 'started', started_at: '2026-09-20T11:00:00Z'},
    }},
  },
};

test('runs are read across archived attempts too, which is why T17 kept test_runs', () => {
  // Dropping `test_runs` from an archived card would have saved 6.5 points of
  // frame and turned this history into a history of the last few live attempts.
  const rows = runRows(world);
  assert.equal(rows.length, 3);
  assert.ok(rows.some(r => r.attempt_ref === 'da_2'), 'an archived attempt’s runs are history too');
});

test('runs come back newest first, with a total order', () => {
  assert.deepEqual(runRows(world).map(r => r.run_id), ['r3', 'r1', 'r2']);
  // Same instant, different ids: the order must not swap between frames.
  const tie = {development_attempts: {a: {id: 'a', test_runs: {
    x: {run_id: 'x', started_at: 'T', state: 'completed'},
    y: {run_id: 'y', started_at: 'T', state: 'completed'},
  }}}};
  assert.deepEqual(runRows(tie).map(r => r.run_id), runRows(tie).map(r => r.run_id));
  assert.deepEqual(runRows(tie).map(r => r.run_id), ['y', 'x']);
});

test('a started run has no verdict — a pass is not assumed from a missing outcome', () => {
  const started = runRows(world).find(r => r.run_id === 'r3');
  assert.equal(started.verdict, null);
  assert.equal(started.state, 'started');
});

test('the tally separates running and incomplete from pass and fail', () => {
  assert.deepEqual(runTally(runRows(world)), {passed: 1, failed: 1, running: 1, incomplete: 0});
  assert.deepEqual(runTally([{state: 'interrupted'}]), {passed: 0, failed: 0, running: 0, incomplete: 1});
});

test('Now lists the started run and nothing that has finished', () => {
  const rows = nowRows(world, null);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].kind, 'run');
  assert.match(rows[0].detail, /da_2/);
});

test('a live reply is described as bytes, because bytes is what it is', () => {
  // There is no token count in this runtime. `received_bytes` is bytes of
  // assistant text; calling it anything else would be the invented number
  // DOCTRINE rule 2 forbids.
  const [row] = nowRows({}, {active: true, received_bytes: 2048, phase: 'Thinking · 50 tokens'});
  assert.equal(row.kind, 'reply');
  assert.match(row.detail, /2,048 bytes of assistant text/);
  assert.doesNotMatch(row.detail, /token/);
});

test('an inactive or absent reply puts nothing in Now', () => {
  assert.deepEqual(nowRows({}, {active: false, received_bytes: 900}), []);
  assert.deepEqual(nowRows({}, null), []);
});

/* T21 — what has left the live directories.
 *
 * The capacity rows have counted it since T18a and nothing said what it was.
 * This reads the marker T17 already puts on every archived card, so it costs
 * nothing new on the frame. */

const CARD = {schema: 'archived-record-card@1', omitted: ['history'], read_with: 'read_development_task'};
const archivedWorld = {
  development_tasks: {
    dt_live: {id: 'dt_live', title: 'Still open', status: 'planned'},
    dt_1: {id: 'dt_1', title: 'Older plan', status: 'completed', archived: CARD,
           completion: {at: '2026-09-10T00:00:00Z', accepted_attempt_refs: ['da_1']}},
    dt_2: {id: 'dt_2', title: 'Newer plan', status: 'cancelled', archived: CARD},
    dt_3: {id: 'dt_3', title: 'Newest plan', status: 'completed', archived: CARD,
           completion: {at: '2026-09-20T00:00:00Z', accepted_attempt_refs: ['da_2']}},
  },
  development_attempts: {
    da_live: {id: 'da_live', task_ref: 'dt_live', source: {path: 'open.js'}},
    da_1: {id: 'da_1', task_ref: 'dt_1', status: 'accepted', archived: CARD, source: {path: 'a.js'},
           acceptance: {accepted_at: '2026-09-10T01:00:00Z'}},
    da_2: {id: 'da_2', task_ref: 'dt_3', status: 'accepted', archived: CARD,
           files: [{}, {}, {}], acceptance: {accepted_at: '2026-09-20T01:00:00Z'}},
  },
};

test('T21 · only archived records are listed, and live ones are left alone', () => {
  const {plans, attempts} = archivedRecords(archivedWorld);
  assert.deepEqual(plans.map(p => p.ref).sort(), ['dt_1', 'dt_2', 'dt_3']);
  assert.deepEqual(attempts.map(a => a.ref).sort(), ['da_1', 'da_2']);
});

test('T21 · newest finished first, and a record with no time goes last', () => {
  // `dt_2` was cancelled and has no completion, so it has no time. Sorting it
  // as if it happened at the beginning of time would put a record nobody can
  // date above one that is dated — the list is meant to read as a history.
  assert.deepEqual(archivedRecords(archivedWorld).plans.map(p => p.ref), ['dt_3', 'dt_1', 'dt_2']);
});

test('T21 · the order is total, so the list does not shuffle between frames', () => {
  const world = {development_tasks: {
    a: {id: 'a', archived: CARD, completion: {at: 'T'}},
    b: {id: 'b', archived: CARD, completion: {at: 'T'}},
  }};
  assert.deepEqual(archivedRecords(world).plans.map(p => p.ref), archivedRecords(world).plans.map(p => p.ref));
  assert.deepEqual(archivedRecords(world).plans.map(p => p.ref), ['b', 'a']);
});

test('T21 · a review is named by its path, or by how many files it reviewed', () => {
  const {attempts} = archivedRecords(archivedWorld);
  assert.equal(attempts.find(a => a.ref === 'da_1').title, 'a.js');
  assert.equal(attempts.find(a => a.ref === 'da_2').title, '3 files · combined review');
});

test('T21 · a plan carries the reviews it was completed on', () => {
  assert.deepEqual(archivedRecords(archivedWorld).plans.find(p => p.ref === 'dt_3').accepted, ['da_2']);
  assert.deepEqual(archivedRecords(archivedWorld).plans.find(p => p.ref === 'dt_2').accepted, [],
    'a cancelled plan accepted nothing, and says so as an empty list rather than undefined');
});

test('T21 · a marker of another schema is not an archived record', () => {
  const world = {development_tasks: {x: {id: 'x', archived: {schema: 'something-else@1'}}}};
  assert.deepEqual(archivedRecords(world).plans, []);
  assert.deepEqual(archivedRecords({}).plans, []);
  assert.deepEqual(archivedRecords(null).attempts, []);
});

// T23 · the archived-review list and the run history are windows now, and say so.
import {windowNotes} from '../cockpit/ui/activity.js';
test('T23 · the window names what it left out, and says nothing when it left nothing', () => {
  const window = (withheld, carried = {plans: 6, attempts: 7, runs: 6}) =>
    ({development_attempts_window: {schema: 'archived-attempt-window@1', carried, withheld}});
  const n = windowNotes(window({plans: 12, attempts: 25, runs: 29}));
  assert.match(n.reviews, /^25 reviews of 12 earlier finished plans are kept in the world and not in this view/);
  assert.match(n.reviews, /the 6 most recently finished plans\.$/);
  assert.match(n.runs, /^29 more profile runs, on the reviews of 12 earlier finished plans, are kept/);
  const one = windowNotes(window({plans: 1, attempts: 1, runs: 0}, {plans: 1, attempts: 1, runs: 1}));
  assert.match(one.reviews, /^1 review of 1 earlier finished plan is kept .* the 1 most recently finished plan\.$/);
  assert.equal(one.runs, null, 'no withheld runs, no runs note');
  assert.deepEqual(windowNotes(window({plans: 0, attempts: 0, runs: 0})), {reviews: null, runs: null});
  assert.deepEqual(windowNotes({}), {reviews: null, runs: null}, 'a runtime before T23 withholds nothing');
});
