#!/usr/bin/env node
/* saved-file-review-resume-smoke — a saved SINGLE-FILE review, staged again from the
   bytes its record names, through the single-file dialog, with no bot and no live
   transcript card (the case after a restart). Real cockpit, throwaway world
   (SUPER_COCKPIT_CARRIER=1 seeds workspace/goal/repo); the review record is made by
   intent — bodies published by digest, the record its source basis alone — exactly
   as the page records one, so the page's resume path is what is exercised.
     node tools/saved-file-review-resume-smoke.mjs
     APP_SMOKE_SCREENSHOTS=/some/dir node tools/saved-file-review-resume-smoke.mjs   */
import {open} from './lib/cockpit-control.mjs';
import {execFileSync} from 'node:child_process';
import {writeFileSync, mkdirSync, existsSync} from 'node:fs';
import {createHash} from 'node:crypto';
process.env.SUPER_COCKPIT_CARRIER = '1'; process.env.GDK_BACKEND ??= 'x11';
let held = 0, failed = 0;
const check = (what, ok, detail = '') => { console.log(`  ${ok ? '\x1b[32mheld\x1b[0m' : '\x1b[31mFAILED\x1b[0m'}  ${what}${detail ? ' — ' + detail : ''}`); ok ? held++ : failed++; };
const q = s => JSON.stringify(s), sha = t => createHash('sha256').update(t).digest('hex'), sleep = ms => new Promise(r => setTimeout(r, ms));
const shots = process.env.APP_SMOKE_SCREENSHOTS; if (shots) mkdirSync(shots, {recursive: true});
const PATH = 'notes/todo.js', CURRENT = "export const todo=['write it'];\n", PROPOSED = "export const todo=['write it','review it'];\n";
console.log('\nsaved-file-review-resume (a saved single-file review is staged again from its record)\n');
let c;
try {
  c = await open();
  const shot = async name => { if (!shots) return; try { const r = await fetch(`http://127.0.0.1:${process.env.COCKPIT_CONTROL_PORT ?? 4495}/session/${c.session()}/screenshot`); const j = await r.json(); writeFileSync(`${shots}/${name}.png`, Buffer.from(j.value, 'base64')); } catch (e) { console.log('  (screenshot failed: ' + e.message + ')'); } };
  const ws = (await c.list('workspaces'))[0], repo = (await c.list('repositories'))[0], goal = (await c.list('goals'))[0];
  // The seeded repository on disk. The projection names a repository by ref and
  // basename only; opening the registered repository in the Editor (no dialog)
  // makes the Editor state its root, and that label is the path.
  await c.openRepository(repo.ref);
  const root = await c.until(async () => { const t = await c.page(`return document.querySelector('[data-screen=editor] .workbench-root')?.textContent ?? ''`); return t && t !== 'No repository selected' ? t : null; }, 20_000, 'editor root');
  if (!existsSync(root + '/.git')) throw Error('the Editor root is not the seeded repository: ' + root);
  const git = (...a) => execFileSync('git', ['-C', root, ...a], {encoding: 'utf8'}).trim();
  mkdirSync(root + '/notes', {recursive: true}); writeFileSync(`${root}/${PATH}`, CURRENT);
  git('add', PATH); git('-c', 'user.name=Smoke', '-c', 'user.email=smoke@example.invalid', 'commit', '-qm', 'the reviewed file');
  const head = git('rev-parse', 'HEAD');
  const bot = (await c.create('register_bot', {client_ref: 'saved-file-resume-bot', workspace_ref: ws.id, name: 'Saved file resume bot', role: 'Reviewer', group: 'Smoke', provider: 'ollama', instructions: 'Holds the smoke lane.'}, {kind: 'bots', field: 'name', value: 'Saved file resume bot'})).record;
  await c.intent('open_lane', {goal_ref: goal.id, actor: bot.actor, repository_ref: repo.ref});
  const lane = await c.until(async () => (await c.list('lanes')).find(l => l.actor === bot.actor), 20_000, 'lane');
  const plan = (await c.create('create_development_task', {client_ref: 'saved-file-resume', lane_ref: lane.id, title: 'Saved single-file review resumes', criteria: 'The todo list gains a second item.', required_checks: {profiles: ['super-javascript-behavior@1']}}, {kind: 'development_tasks', field: 'client_ref', value: 'saved-file-resume'})).record;
  const world = JSON.parse(await c.page(`const w=window.cockpit.frame.world;return JSON.stringify([w.world_incarnation,w.world_generation,w.projection_epoch])`));
  // ---- the record, as the page makes one: bodies first, then the basis alone
  const source = {schema: 'selected-file-basis@1', scope: 'selected-file-only', head, path: PATH, disk_sha256: sha(CURRENT), draft_sha256: sha(CURRENT), draft_bytes: Buffer.byteLength(CURRENT), unsaved: false, result_sha256: sha(PROPOSED), result_bytes: Buffer.byteLength(PROPOSED), task_ref: plan.id, task_revision: plan.revision, repository_ref: repo.ref, world};
  source.basis_id = sha(JSON.stringify(['selected-file-basis@1', head, PATH, source.disk_sha256, source.draft_sha256]));
  for (const text of [CURRENT, PROPOSED]) await c.intent('put_review_content', {digest: sha(text), offset: 0, chunk: Buffer.from(text).toString('base64'), part: 'final'});
  const attempt = (await c.create('record_development_attempt', {client_ref: 'saved-file-resume-review', task_ref: plan.id, task_revision: plan.revision, source}, {kind: 'development_attempts', field: 'client_ref', value: 'saved-file-resume-review'})).record;
  check('a single-file review is recorded staged, its bodies in the content store', attempt.schema === 'development-review-attempt@1' && attempt.status === 'recorded' && attempt.content?.held === 'staged' && !('proposed_text' in attempt), `${attempt.id} · held ${attempt.content?.held}`);

  // ---- the plan page, in a cockpit whose transcript never saw a proposal card
  const openPlan = async () => {
    await c.page(`document.querySelector('[data-rail-mode=nav]')?.click(); document.querySelector('#app-navigation [data-nav=development-tasks]').click();`);
    await c.until(() => c.page(`return !!document.querySelector('[data-development-task=${q(plan.id)}]')`), 15_000, 'plan listed');
    await c.page(`document.querySelector('[data-development-task=${q(plan.id)}]').click()`);
    await c.until(() => c.page(`return !!document.querySelector('#task-steps')`), 15_000, 'stepper');
    await c.page(`const b=document.querySelector('#task-wizard-all');if(b&&!b.checked){b.checked=true;b.dispatchEvent(new Event('change'));}`);
    await c.until(() => c.page(`return !!document.querySelector('[data-attempt-id=${q(attempt.id)}]')`), 15_000, 'attempt card');
    await c.page(`const d=document.querySelector('[data-attempt-id=${q(attempt.id)}]');if(!d.open)d.querySelector('summary').click();`);
    await sleep(300);
  };
  await openPlan();
  const stageSel = `[data-stage-saved-review=${q(attempt.id)}]`, statusSel = `[data-saved-review-status=${q(attempt.id)}]`;
  check('the single-file card offers Stage saved review in Editor', await c.page(`return document.querySelector(${q(stageSel)})?.textContent`) === 'Stage saved review in Editor');
  check('its note names Use as editor draft and Save as the writing step', (await c.page(`return document.querySelector(${q(stageSel)}).previousSibling.textContent`)).includes('Use as editor draft, then Save in the Editor is the step that writes'));
  const status = () => c.page(`return document.querySelector(${q(statusSel)})?.textContent ?? ''`);
  const stage = async () => { await c.page(`document.querySelector(${q(stageSel)}).click()`); await c.until(status, 15_000, 'status line'); return status(); };
  let s = await stage();
  check('before a file request is prepared for this plan it is refused by name', s.startsWith('Prepare a file request for this plan'), s);
  await shot('01-refused-no-file-request');

  // ---- Prepare file request (the repository is already open in the Editor), back to the plan
  await c.page(`document.querySelector('#task-prepare-file').click()`);
  await c.until(() => c.page(`return !document.querySelector('[data-screen=editor]').hidden`), 15_000, 'editor screen');
  await openPlan();
  await c.page(`document.querySelector(${q(stageSel)}).click()`);
  await c.until(() => c.page(`return !!document.querySelector('#bot-file-review[open]')`), 20_000, 'the single-file review dialog');
  s = await status();
  check('the status line says the content was read and checked, and names Save as the writing step', s.startsWith('Recorded content read and checked') && s.includes('Save is the step that writes'), s);
  check('the single-file dialog opens on the recorded file', (await c.page(`return document.querySelector('#bot-file-review h2').textContent`)) === 'Review bot edit · ' + PATH);
  const diff = await c.page(`const d=document.querySelector('#proposal-diff');return {added:d.querySelectorAll('.added').length,removed:d.querySelectorAll('.removed').length}`);
  check('the diff is the recorded change', diff.added === 1 && diff.removed === 1, JSON.stringify(diff));
  const pinned = await c.until(async () => { const t = await c.page(`return document.querySelector('#proposal-source-record summary')?.textContent ?? ''`); return t.startsWith('Source pinned') || t.startsWith('Source verification failed') ? t : null; }, 20_000, 'source verification');
  check('the source is pinned to the recorded commit', pinned === `Source pinned to ${head.slice(0, 12)} · exact file and result recorded`, pinned);
  check('Use as editor draft is enabled and there is no Save review attempt: the record exists', await c.page(`return !document.querySelector('#bot-file-use-draft').disabled && !document.querySelector('#bot-file-record-attempt')`));
  await shot('02-single-file-dialog-resumed');
  await c.page(`document.querySelector('#bot-file-use-draft').click()`);
  await c.until(() => c.page(`return !document.querySelector('#bot-file-review')`), 20_000, 'dialog closed');
  await c.until(() => c.page(`return !document.querySelector('[data-screen=editor]').hidden && !document.getElementById('editor-save').disabled`), 15_000, 'editor draft');
  check('the Editor holds the proposed text as an UNSAVED draft', (await c.page(`return document.querySelector('#editor-status')?.textContent ?? ''`)).includes(PATH) && !await c.page(`return document.getElementById('editor-save').disabled`), await c.page(`return document.querySelector('#editor-status')?.textContent`));
  check('nothing was written', execFileSync('cat', [`${root}/${PATH}`], {encoding: 'utf8'}) === CURRENT && git('status', '--porcelain', '--', PATH) === '');
  await shot('03-editor-unsaved-draft');

  // ---- refusals by name: an unsaved Editor edit that is not the review's own draft, then a file that changed on disk
  await openPlan();
  s = await stage();
  check('with the proposed draft unsaved in the Editor, staging again is refused as an unsaved edit', s.includes('has unsaved edits in the Editor'), s);
  // The disk is checked before the tab: a file that changed since the review is
  // refused as that, whatever the Editor holds.
  writeFileSync(`${root}/${PATH}`, CURRENT + '// changed since\n');
  await openPlan();
  s = await stage();
  check('a file that changed on disk since the review is refused by name', s.startsWith(`${PATH} changed on disk since it was reviewed`) && s.includes(`reviewed at ${source.disk_sha256.slice(0, 12)}`), s);
  await shot('04-refused-changed-on-disk');
} catch (e) {
  failed++;
  console.log(`  \x1b[31mFAILED\x1b[0m  ${e.message}`);
} finally {
  await c?.close();
}
console.log(`\nsaved-file-review-resume: ${held} held · ${failed} failed\n`);
process.exit(failed ? 1 : 0);
