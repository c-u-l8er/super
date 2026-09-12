/* The two choices this dogfood is not allowed to guess at.
 *
 * Both were defects, both were found by running the thing:
 *
 *   * `?? repos[0]` opened a lane against `ProjectAmp2/computedriven.com` on the
 *     first real run. **The missing labels made the interface confusing; the
 *     guess is what bound the lane.** No command closes a lane, so the guess was
 *     permanent.
 *   * a cancelled plan on the target lane read as "already carried", so the
 *     recovery skipped re-creating the real one and then cancelled the source —
 *     losing the work it existed to save.
 *
 * Pure, so they are tested without standing up a world.
 */

export const refOf = r => r?.ref ?? r?.id;

/**
 * The one repository this run may use, or a refusal saying why not.
 *
 * There is no fallback. "The only one registered" is not a match — a world with
 * one repository that is not the one asked for is exactly the case `repos[0]`
 * got wrong. A name that two repositories share is not a match either: a name
 * is the last two path segments and those can collide, which is why the
 * reference is published beside it.
 *
 * @returns {{repo: object} | {refusal: string}}
 */
export function selectRepository({repos = [], wanted = '', name = ''} = {}) {
  if (!repos.length)
    return {refusal: 'no repository is registered. Nav → Repositories → choose the folder. ' +
      'The chooser takes no path from a script, which is the point of it.'};

  const [by, value, matches] = wanted
    ? ['reference', wanted, repos.filter(r => refOf(r) === wanted)]
    : ['name', name, repos.filter(r => r.name === name)];

  const inventory = repos.map(r => `${refOf(r)}${r.name ? `=${r.name}` : ''}`).join(', ');

  if (matches.length === 1) return {repo: matches[0]};
  if (matches.length === 0)
    return {refusal: `no repository matches ${by} ${value || '(unset)'} — this world has ` +
      `${inventory}. Pass --repo=<ref> to say which. Guessing binds a lane that cannot be undone.`};
  return {refusal: `${matches.length} repositories share the ${by} ${value}: ` +
    `${matches.map(refOf).join(', ')}. A name can collide; a reference cannot. ` +
    `Pass --repo=<ref>.`};
}

/**
 * The live plan carrying `title` on `lane`, if there is one.
 *
 * **Cancelled is not carried.** A cancelled plan is the record of work moved or
 * abandoned, so treating one as present makes a recovery skip the plan it was
 * asked to re-create, and makes a setup report a plan the lane does not have.
 * Scoped to the lane because a plan on a different lane names a different
 * repository.
 */
export function carriedPlan({tasks = [], lane, title}) {
  return Object.values(tasks).find(
    t => t?.lane_ref === lane && t?.title === title && t?.status !== 'cancelled');
}

/** Plans on `lane` that still represent work. */
export function livePlans({tasks = [], lane}) {
  return Object.values(tasks).filter(t => t?.lane_ref === lane && t?.status !== 'cancelled');
}
