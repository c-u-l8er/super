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

test('the note names the door the card names, and nothing else', () => {
  const note = withheldNote(card(['history']), 'history', 'planning history');
  assert.match(note, /archived/);
  assert.match(note, /kept in the world/);
  assert.match(note, /read_development_task/);
});

test('an attempt card points at the attempt door', () => {
  const c = card(['history'], 'read_development_attempt', {id: 'da_0001'});
  assert.match(withheldNote(c, 'history', 'review history'), /read_development_attempt/);
});

test('a note is refused for a field that is not withheld', () => {
  // The failure this guards is a renderer that prints "this is archived and
  // kept elsewhere" beside a value it is holding — the opposite of the truth.
  const c = card(['history'], 'read_development_task', {criteria: 'Ship it.'});
  assert.equal(withheldNote(c, 'criteria', 'acceptance criteria'), null);
});

test('a card with no door still says the record is archived', () => {
  const c = {id: 'dt_1', archived: {schema: CARD_SCHEMA, omitted: ['history']}};
  const note = withheldNote(c, 'history', 'planning history');
  assert.match(note, /archived/);
  assert.doesNotMatch(note, /read with/);
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
