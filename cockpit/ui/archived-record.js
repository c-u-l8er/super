/* An archived record arrives as a card, and the card says what it is a card onto.
 *
 * T17. `development_tasks` and `development_attempts` still carry every
 * archived record — `Ampd.Loci` merges both archives back for readers, so a
 * completed plan's card does not blank and the accepted reviews it names stay
 * reachable. What they stopped carrying is the WEIGHT: an archived plan's
 * `history` and `criteria`, an archived attempt's `history` and `text_check`.
 * Measured on the live world, that is a loci block of 163,415 bytes where it
 * had been 233,916, against a frame that may carry 262,144.
 *
 * **The problem this module exists for is that `undefined` is two answers.**
 * "This plan recorded no criteria" and "the frame is not carrying the criteria"
 * are different facts, and a renderer that reads both off a missing key states
 * the first when the second is true. The runtime therefore names what it
 * withheld, in an `archived` block, and `fieldState` is the decision made from
 * it — before anything is rendered, with no DOM in reach, which is the shape
 * `retainedSide()` in `review-content.js` uses for the same problem one layer
 * down.
 *
 * Nothing here fetches. The door the card names is an `ampd` read command, and
 * the cockpit's intent surface is mutations only by a rule `worker.rs` states
 * and `tools/check-intent-surface.mjs` enforces — a page that can ask the world
 * a question has a second source of truth. So this layer's honest answer is to
 * say what is not on the frame and where it is; making the page able to redeem
 * that is its own task, with its own architectural decision behind it.
 */

export const CARD_SCHEMA = 'archived-record-card@1';

/** The card block, or null for a record that is not one. */
export function cardOf(record) {
  const a = record && record.archived;
  if (!a || a.schema !== CARD_SCHEMA) return null;
  return {
    omitted: Array.isArray(a.omitted) ? a.omitted : [],
    readWith: typeof a.read_with === 'string' && a.read_with ? a.read_with : null,
  };
}

/**
 * Is this field on the frame, deliberately withheld, or simply not recorded?
 *
 * `carried` is decided by the key being PRESENT, not by its value being
 * truthy — the mirror of the `Map.has_key?/2` the runtime filters `omitted`
 * with. An empty history is a fact the frame is carrying; a withheld one is
 * not on the frame at all.
 */
export function fieldState(record, field) {
  if (record && Object.hasOwn(record, field)) return 'carried';
  const card = cardOf(record);
  return card && card.omitted.includes(field) ? 'withheld' : 'absent';
}

/**
 * The sentence that goes where a withheld field would have been.
 *
 * It says two things: that the record is archived, and that the material is
 * kept rather than lost. `null` for anything not withheld — a caller that
 * renders this note beside a value it did have is stating the opposite of the
 * truth.
 *
 * **It does NOT name the command.** The first version ended *"It is read with
 * read_development_task"*, which is true of the card and false of the reader:
 * the cockpit's intent surface carries mutations only (`worker.rs`, enforced by
 * `tools/check-intent-surface.mjs`), so the page cannot call it and neither can
 * the person reading the sentence. Naming a door nobody at this surface can open
 * is a promise, not an explanation. The door stays in the card's data, where a
 * reader that CAN use it will find it; the sentence stops quoting it until the
 * page has one of its own.
 */
export function withheldNote(record, field, subject = 'material') {
  const card = cardOf(record);
  if (!card || fieldState(record, field) !== 'withheld') return null;
  return `This record is archived. Its ${subject} is kept in the world; this screen does not carry it.`;
}
