/* The two rules the dogfood is not allowed to guess at.
 *
 * Every case here is a shape that actually occurred or that the round showed
 * could occur: one registered repository that is the wrong one, two sharing a
 * name because a name is two path segments, and a cancelled plan standing where
 * a live one is expected.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {selectRepository, carriedPlan, livePlans, refOf} from './lib/dogfood-selection.mjs';

const CD = {ref: 'rp_0001', name: 'ProjectAmp2/computedriven.com'};
const SUPER = {ref: 'rp_0002', name: 'ProjectAmp2/super'};
const SUPER_ELSEWHERE = {ref: 'rp_0003', name: 'ProjectAmp2/super'};
const UNNAMED_1 = {ref: 'rp_0001'};
const UNNAMED_2 = {ref: 'rp_0002'};

test('an explicit reference selects exactly that repository', () => {
  const r = selectRepository({repos: [CD, SUPER], wanted: 'rp_0002', name: 'ProjectAmp2/super'});
  assert.equal(refOf(r.repo), 'rp_0002');
});

test('an explicit reference that is not registered refuses, and says what is', () => {
  const r = selectRepository({repos: [CD, SUPER], wanted: 'rp_0099'});
  assert.ok(r.refusal);
  assert.match(r.refusal, /rp_0099/);
  assert.match(r.refusal, /rp_0001=ProjectAmp2\/computedriven\.com/);
  assert.equal(r.repo, undefined);
});

test('THE DEFECT: the only registered repository is not a match when it is the wrong one', () => {
  // `repos.length === 1 ? repos[0]` returned computedriven.com here, and the
  // lane it bound cannot be closed.
  const r = selectRepository({repos: [CD], name: 'ProjectAmp2/super'});
  assert.ok(r.refusal, 'a sole wrong repository must not be taken as the match');
  assert.equal(r.repo, undefined);
});

test('the only registered repository IS a match when its name is the one asked for', () => {
  const r = selectRepository({repos: [SUPER], name: 'ProjectAmp2/super'});
  assert.equal(refOf(r.repo), 'rp_0002');
});

test('two repositories sharing a name refuse rather than taking the first', () => {
  // A name is the last two path segments; /a/ProjectAmp2/super and
  // /b/ProjectAmp2/super produce the same one. `.find` would have taken rp_0002.
  const r = selectRepository({repos: [SUPER, SUPER_ELSEWHERE], name: 'ProjectAmp2/super'});
  assert.ok(r.refusal, 'an ambiguous name must refuse');
  assert.match(r.refusal, /rp_0002/);
  assert.match(r.refusal, /rp_0003/);
  assert.match(r.refusal, /--repo=/, 'the refusal must say how to resolve it');
});

test('an explicit reference resolves what a shared name cannot', () => {
  const r = selectRepository({repos: [SUPER, SUPER_ELSEWHERE], wanted: 'rp_0003'});
  assert.equal(refOf(r.repo), 'rp_0003');
});

test('a world publishing no names refuses by name and is resolvable by reference', () => {
  // The state the first real run was actually in.
  const byName = selectRepository({repos: [UNNAMED_1, UNNAMED_2], name: 'ProjectAmp2/super'});
  assert.ok(byName.refusal);
  const byRef = selectRepository({repos: [UNNAMED_1, UNNAMED_2], wanted: 'rp_0002'});
  assert.equal(refOf(byRef.repo), 'rp_0002');
});

test('an empty world refuses and names the one step a person has to take', () => {
  const r = selectRepository({repos: [], name: 'ProjectAmp2/super'});
  assert.ok(r.refusal);
  assert.match(r.refusal, /Repositories/);
});

test('nothing is ever both selected and refused', () => {
  for (const repos of [[], [CD], [SUPER], [CD, SUPER], [SUPER, SUPER_ELSEWHERE], [UNNAMED_1]])
    for (const wanted of ['', 'rp_0002', 'rp_0099'])
      for (const name of ['ProjectAmp2/super', 'nothing/at-all']) {
        const r = selectRepository({repos, wanted, name});
        assert.equal(!!r.repo, !r.refusal, JSON.stringify({repos: repos.map(refOf), wanted, name}));
      }
});

// ---------------------------------------------------------------- plans

const plans = {
  dt_0022: {id: 'dt_0022', lane_ref: 'ln_0016', title: 'A local bot profile cannot be deleted', status: 'cancelled'},
  dt_0025: {id: 'dt_0025', lane_ref: 'ln_0023', title: 'A local bot profile cannot be deleted', status: 'planned'},
  dt_0040: {id: 'dt_0040', lane_ref: 'ln_0023', title: 'Something already cancelled here', status: 'cancelled'},
};

test('a live plan on the lane is carried', () => {
  assert.equal(carriedPlan({tasks: plans, lane: 'ln_0023',
    title: 'A local bot profile cannot be deleted'})?.id, 'dt_0025');
});

test('THE DEFECT: a cancelled plan on the target lane is NOT carried', () => {
  // The recovery skipped re-creating this plan and then cancelled the source,
  // because `.find` on (lane, title) matched a cancelled record.
  assert.equal(carriedPlan({tasks: plans, lane: 'ln_0023',
    title: 'Something already cancelled here'}), undefined);
});

test('a plan on a different lane is not carried, however it is titled', () => {
  // ln_0016 is bound to a different repository; a plan there is different work.
  assert.equal(carriedPlan({tasks: plans, lane: 'ln_0099',
    title: 'A local bot profile cannot be deleted'}), undefined);
  assert.equal(carriedPlan({tasks: plans, lane: 'ln_0016',
    title: 'A local bot profile cannot be deleted'}), undefined,
    'that one is cancelled, so it is not carried either');
});

test('live plans exclude cancelled and never cross a lane', () => {
  assert.deepEqual(livePlans({tasks: plans, lane: 'ln_0023'}).map(p => p.id), ['dt_0025']);
  assert.deepEqual(livePlans({tasks: plans, lane: 'ln_0016'}).map(p => p.id), []);
});

test('a task list given as an array behaves the same as one given as a map', () => {
  assert.equal(carriedPlan({tasks: Object.values(plans), lane: 'ln_0023',
    title: 'A local bot profile cannot be deleted'})?.id, 'dt_0025');
});
