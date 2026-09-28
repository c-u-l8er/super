/* An archived record's card, and the one thing it must never let a renderer say.
 *
 * T17 stopped publishing an archived plan's `history` and `criteria` and an
 * archived attempt's `history` and `text_check`. Every case below is about the
 * same distinction: a field that is NOT ON THE FRAME and a field that WAS NEVER
 * RECORDED both arrive as a missing key, they are different facts, and the
 * renderer states one of them out loud.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {cardOf, fieldState, withheldNote, CARD_SCHEMA} from '../cockpit/ui/archived-record.js';

const card = (omitted, read_with = 'read_development_task', rest = {}) => ({
  id: 'dt_0001',
  status: 'completed',
  ...rest,
  archived: {schema: CARD_SCHEMA, omitted, read_with},
});

test('a live record is not a card, and every field it has reads as carried', () => {
  const live = {id: 'dt_0001', history: [], criteria: ''};
  assert.equal(cardOf(live), null);
  assert.equal(fieldState(live, 'history'), 'carried');
  assert.equal(fieldState(live, 'criteria'), 'carried');
  assert.equal(withheldNote(live, 'history', 'planning history'), null);
});

test('a withheld field and an unrecorded field are told apart', () => {
  const c = card(['history']);
  assert.equal(fieldState(c, 'history'), 'withheld');
  // `criteria` is not in this card's omitted list, so the record never had one
  assert.equal(fieldState(c, 'criteria'), 'absent');
});

test('carried is decided by the key, not by the value being truthy', () => {
  // An empty history is a fact the frame IS carrying. Reading it as withheld
  // would send a person to a door for a record with nothing behind it.
  const c = card(['criteria'], 'read_development_task', {history: []});
  assert.equal(fieldState(c, 'history'), 'carried');
  assert.equal(withheldNote(c, 'history', 'planning history'), null);
});

test('the note says archived and kept, and does NOT name the door', () => {
  // The door is real and the card carries it, but the cockpit's intent surface
  // is mutations only, so the page cannot call it and neither can the person
  // reading this sentence. Naming it was a promise the reader cannot act on.
  const c = card(['history']);
  const note = withheldNote(c, 'history', 'planning history');
  assert.match(note, /archived/);
  assert.match(note, /kept in the world/);
  assert.doesNotMatch(note, /read_development_task/);
  assert.equal(cardOf(c).readWith, 'read_development_task', 'the card still names it');
});

test('an attempt card still carries the attempt door in its data', () => {
  const c = card(['history'], 'read_development_attempt', {id: 'da_0001'});
  assert.equal(cardOf(c).readWith, 'read_development_attempt');
  assert.doesNotMatch(withheldNote(c, 'history', 'review history'), /read_development_attempt/);
});

test('a note is refused for a field that is not withheld', () => {
  // The failure this guards is a renderer that prints "this is archived and
  // kept elsewhere" beside a value it is holding — the opposite of the truth.
  const c = card(['history'], 'read_development_task', {criteria: 'Ship it.'});
  assert.equal(withheldNote(c, 'criteria', 'acceptance criteria'), null);
});

test('a card with no door reads the same as one with a door', () => {
  const withDoor = withheldNote(card(['history']), 'history', 'planning history');
  const none = withheldNote({id: 'dt_1', archived: {schema: CARD_SCHEMA, omitted: ['history']}},
                            'history', 'planning history');
  assert.equal(none, withDoor);
  assert.equal(cardOf({id: 'dt_1', archived: {schema: CARD_SCHEMA, omitted: ['history']}}).readWith, null);
});

test('a marker of some other schema is not a card', () => {
  // The schema is checked, not the key's presence: a record that grew an
  // `archived` field for another reason must not start withholding fields.
  const c = {id: 'dt_1', archived: {schema: 'something-else@1', omitted: ['history']}};
  assert.equal(cardOf(c), null);
  assert.equal(fieldState(c, 'history'), 'absent');
});

test('a malformed omitted list is treated as claiming nothing', () => {
  const c = {id: 'dt_1', archived: {schema: CARD_SCHEMA, omitted: 'history'}};
  assert.deepEqual(cardOf(c).omitted, []);
  assert.equal(fieldState(c, 'history'), 'absent');
});

/* ── T23 · a plan whose archived attempts the window left out ─────────────── */
import {attemptsOf, withheldAttempts, withheldAttemptsNote, attemptWindowOf} from '../cockpit/ui/archived-record.js';

const plan = attempts => card(['history', 'criteria'], 'read_development_task', {}) && {
  ...card(['history', 'criteria']),
  archived: {...card(['history', 'criteria']).archived, attempts},
};

test('T23 · a withheld plan is told apart from a carried plan and from a plan with none', () => {
  const withheld = plan({carried: false, count: 2, refs: ['da_0003', 'da_0004'], runs: 3});
  assert.deepEqual(attemptsOf(withheld), {carried: false, count: 2, refs: ['da_0003', 'da_0004'], runs: 3});
  assert.equal(withheldAttempts(withheld).count, 2);

  const carried = plan({carried: true, count: 1});
  assert.deepEqual(attemptsOf(carried), {carried: true, count: 1});
  assert.equal(withheldAttempts(carried), null, 'a plan whose attempts ARE on the frame withholds nothing');
  assert.equal(withheldAttemptsNote(carried), null);

  // An archived plan with no marker had no archived attempts; a live plan is not a card.
  assert.equal(attemptsOf(card(['history'])), null);
  assert.equal(attemptsOf({id: 'dt_1', status: 'planned', history: []}), null);
});

test('T23 · a marker is read only off a card, and only when it is well formed', () => {
  // The same block on a record that is NOT an archived card is not a marker.
  assert.equal(attemptsOf({id: 'dt_1', archived: {schema: 'other@1', attempts: {carried: false, count: 2}}}), null);
  for (const bad of [{carried: false, count: 0}, {carried: false}, {carried: 'no', count: 2}, null, 'x'])
    assert.equal(attemptsOf(plan(bad)), null, JSON.stringify(bad));
  // refs and runs are read defensively, never trusted into a sentence as garbage
  assert.deepEqual(attemptsOf(plan({carried: false, count: 1, refs: ['da_1', 7], runs: -1})),
    {carried: false, count: 1, refs: ['da_1'], runs: null});
});

test('T23 · the note says archived, counted and kept, and never "no attempts"', () => {
  const two = withheldAttemptsNote(plan({carried: false, count: 2, refs: [], runs: 3}));
  assert.match(two, /archived/);
  assert.match(two, /2 review attempts and 3 profile runs are kept in the world/);
  assert.match(two, /does not carry them/);
  assert.doesNotMatch(two, /no (review )?attempts|not run|never/i);
  assert.doesNotMatch(two, /read_development_attempt/, 'the page cannot open that door, so it does not name it');

  const one = withheldAttemptsNote(plan({carried: false, count: 1, refs: ['da_1'], runs: 0}));
  assert.match(one, /Its 1 review attempt is kept in the world; this screen does not carry it\./);
});

test('T23 · the window block is read only under its own schema', () => {
  const w = {schema: 'archived-attempt-window@1', carried: {plans: 6, attempts: 7, runs: 6}, withheld: {plans: 12, attempts: 25, runs: 29}};
  assert.deepEqual(attemptWindowOf({development_attempts_window: w}),
    {carriedPlans: 6, withheldPlans: 12, withheldAttempts: 25, withheldRuns: 29});
  assert.equal(attemptWindowOf({}), null, 'a runtime before T23 publishes no window and withholds nothing');
  assert.equal(attemptWindowOf({development_attempts_window: {...w, schema: 'x@1'}}), null);
});

/* ── T25 · a LIVE plan that owns archived (dismissed) attempts ────────────── */
const livePlan = attempts => ({id: 'dt_0138', status: 'planned', history: [], archived_attempts: attempts});

test('T25 · a live plan\'s marker is read like an archived plan\'s, and it is not a card', () => {
  const withheld = livePlan({carried: false, count: 6, refs: ['da_0139', 'da_0140'], runs: 6});
  assert.deepEqual(attemptsOf(withheld), {carried: false, count: 6, refs: ['da_0139', 'da_0140'], runs: 6});
  assert.equal(withheldAttempts(withheld).count, 6);
  assert.equal(cardOf(withheld), null, 'a live plan must never read as an archived card');

  const carried = livePlan({carried: true, count: 6});
  assert.deepEqual(attemptsOf(carried), {carried: true, count: 6});
  assert.equal(withheldAttemptsNote(carried), null);

  for (const bad of [{carried: false, count: 0}, {carried: 'no', count: 2}, null, 'x'])
    assert.equal(attemptsOf(livePlan(bad)), null, JSON.stringify(bad));
});

test('T25 · a live plan\'s note speaks of DISMISSED attempts and never calls the plan archived', () => {
  const six = withheldAttemptsNote(livePlan({carried: false, count: 6, refs: [], runs: 6}));
  assert.equal(six, '6 dismissed review attempts of this plan and 6 profile runs are kept in the world; this screen does not carry them.');
  assert.doesNotMatch(six, /archived/i);
  assert.doesNotMatch(six, /no (review )?attempts|not run|never/i);

  const one = withheldAttemptsNote(livePlan({carried: false, count: 1, refs: ['da_1'], runs: 0}));
  assert.equal(one, '1 dismissed review attempt of this plan is kept in the world; this screen does not carry it.');

  // the archived plan's wording is unchanged by T25
  assert.match(withheldAttemptsNote(plan({carried: false, count: 2, refs: [], runs: 3})),
    /^This plan is archived\. Its 2 review attempts and 3 profile runs are kept in the world/);
});

test('T25 · a plan\'s attempt count adds what its marker withholds, for a live plan and an archived one', async () => {
  const {attemptTotal} = await import('../cockpit/ui/archived-record.js');
  assert.equal(attemptTotal(5, livePlan({carried: false, count: 6, refs: [], runs: 6})), 11);
  assert.equal(attemptTotal(11, livePlan({carried: true, count: 6})), 11, 'carried attempts are already rows');
  assert.equal(attemptTotal(0, plan({carried: false, count: 2, refs: [], runs: 3})), 2, 'never (0) for a withheld archived plan');
  assert.equal(attemptTotal(3, {id: 'dt_1', status: 'planned'}), 3);
});
