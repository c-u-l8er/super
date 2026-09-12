#!/usr/bin/env node
/* Submit the held dogfood proposals to Super as combined review records.
 *
 *   node tools/dogfood-submit-proposals.mjs --real
 *
 * A change set is recorded through `record_development_change_set` — the same
 * `intent` door every form in the page uses, the same `:human_control` channel,
 * the same `CommandSpec` validation, and the same `Ampd.DevelopmentAttempt`
 * validation of every byte and digest on the other side. Nothing here is
 * relaxed: the runtime recomputes `basis_id`, `draft_sha256`, `result_sha256`,
 * `unsaved` and the whole-set coherence, and refuses if any of them disagree
 * with the bytes submitted.
 *
 * What this does NOT do is what the Editor does: re-read the file from disk
 * through the native side. It reads the file from disk HERE, which is where
 * `disk_sha256` comes from, and the record says what it is —
 * `provenance: human-recorded-review-material`. Recording is not saving, not
 * testing and not accepting; those are three further, separate steps.
 *
 * Nothing is accepted and nothing is applied to the repository.
 */
import {readFileSync, existsSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {open, Refused} from './lib/cockpit-control.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const HELD = '/home/travis/Documents/Codex/2026-09-10/wh/outputs';
const REAL = process.argv.includes('--real');
const sha = s => createHash('sha256').update(s).digest('hex');
const head = execFileSync('git', ['-C', ROOT, 'rev-parse', 'HEAD'], {encoding: 'utf8'}).trim();

const G='\x1b[32m', Y='\x1b[33m', R='\x1b[31m', X='\x1b[0m';

/* `shared_draft` is the file as it stands, `proposed_text` is the file as
   proposed. A file that does not exist yet has an empty draft and no
   `disk_sha256`, which is what makes `unsaved` true for it. */
function member({path, from}, ctx) {
  const onDisk = resolve(ROOT, path);
  const draft = existsSync(onDisk) ? readFileSync(onDisk, 'utf8') : '';
  const disk_sha256 = existsSync(onDisk) ? sha(draft) : null;
  const draft_sha256 = sha(draft);
  const proposed_text = readFileSync(from, 'utf8');
  return {
    shared_draft: draft,
    proposed_text,
    source: {
      schema: 'selected-file-basis@1',
      scope: 'selected-file-only',
      basis_id: sha(JSON.stringify(['selected-file-basis@1', head, path, disk_sha256, draft_sha256])),
      head, path, disk_sha256, draft_sha256,
      draft_bytes: Buffer.byteLength(draft),
      unsaved: disk_sha256 !== draft_sha256,
      result_sha256: sha(proposed_text),
      result_bytes: Buffer.byteLength(proposed_text),
      task_ref: ctx.task_ref, task_revision: ctx.task_revision,
      repository_ref: ctx.repository_ref, world: ctx.world,
    },
  };
}

const PROPOSALS = [
  {name: 'proposal 1 — a local bot profile can be deleted',
   plan: 'A local bot profile cannot be deleted',
   client_ref: 'dogfood-change-set-1',
   files: [
     {path: 'cockpit/ui/bot-roster.js',        from: `${HELD}/super-dogfood-proposal/bot-roster.js`},
     {path: 'cockpit/ui/bot-directory.js',     from: `${HELD}/super-dogfood-proposal/bot-directory.js`},
     {path: 'tools/bot-roster-delete-test.mjs',from: `${HELD}/super-dogfood-proposal/bot-roster-delete-test.mjs`},
   ]},
  {name: 'proposal 2 — a repository says which one it is',
   plan: 'A repository is offered as a bare reference with nothing to recognise it by',
   client_ref: 'dogfood-change-set-2',
   files: [
     {path: 'ampd/lib/ampd/projection.ex',              from: `${HELD}/super-dogfood-proposal-2/projection.ex`},
     {path: 'cockpit/ui/references.js',                 from: `${HELD}/super-dogfood-proposal-2/references.js`},
     {path: 'cockpit/ui/record-page.js',                from: `${HELD}/super-dogfood-proposal-2/record-page.js`},
     {path: 'cockpit/ui/cockpit.js',                    from: `${HELD}/super-dogfood-proposal-2/cockpit.js`},
     {path: 'cockpit/ui/cockpit.css',                   from: `${HELD}/super-dogfood-proposal-2/cockpit.css`},
     {path: 'ampd/test/projection_repository_test.exs', from: `${HELD}/super-dogfood-proposal-2/projection_repository_test.exs`},
     {path: 'tools/reference-label-test.mjs',           from: `${HELD}/super-dogfood-proposal-2/reference-label-test.mjs`},
   ],
   /* Two of the seven, so the count is inside 2..4 and a refusal can only be
      about the bytes. Recorded as a probe; a refusal creates nothing. */
   probe: ['ampd/lib/ampd/projection.ex', 'cockpit/ui/references.js']},
];

console.log(`\nsubmit held proposals as change sets — ${REAL ? `${R}THE REAL WORLD${X}` : 'a throwaway world'}`);
console.log(`HEAD ${head}\n`);

let cockpit, failed = null;
try {
  cockpit = await open({real: REAL});
  const frame = JSON.parse(await cockpit.page('return JSON.stringify(window.cockpit.frame)'));
  const world = [frame.world.world_incarnation, frame.world.world_generation, frame.world.projection_epoch];
  console.log(`world ${JSON.stringify(world)}\n`);

  for (const p of PROPOSALS) {
    console.log(`${p.name}`);
    const task = (await cockpit.list('development_tasks'))
      .filter(t => t.title === p.plan && t.status !== 'cancelled')
      .sort((a, b) => b.id.localeCompare(a.id))[0];
    if (!task) { console.log(`  ${R}no live plan titled "${p.plan}"${X}\n`); continue; }
    const ctx = {task_ref: task.id, task_revision: task.revision,
                 repository_ref: task.repository_ref, world};
    console.log(`  plan ${task.id} rev ${task.revision} · repository ${task.repository_ref}`);
    for (const f of p.files) {
      const m = member(f, ctx);
      console.log(`    ${f.path.padEnd(42)} draft ${String(m.source.draft_bytes).padStart(6)}` +
        `  proposed ${String(m.source.result_bytes).padStart(6)}` +
        `  ${m.source.draft_bytes <= 24000 && m.source.result_bytes <= 32000 ? `${G}fits${X}` : `${R}OVER${X}`}`);
    }

    const submit = async (label, files) => {
      const material = {files: files.map(f => member(f, ctx))};
      try {
        const r = await cockpit.intent('record_development_change_set',
          {client_ref: p.client_ref + (label === 'probe' ? '-probe' : ''),
           task_ref: task.id, task_revision: task.revision, material});
        const a = r?.development_attempt;
        console.log(`  ${G}recorded${X} ${label} · ${a?.id} · ${a?.schema} · ${a?.status} · ${a?.provenance}`);
        return a;
      } catch (e) {
        console.log(`  ${R}refused${X}  ${label} · ${e instanceof Refused ? e.code : 'error'} · ` +
          `${(e.result?.refusal?.public_message ?? e.message).slice(0, 160)}`);
        return null;
      }
    };

    await submit(`${p.files.length} files`, p.files);
    if (p.probe) {
      const subset = p.files.filter(f => p.probe.includes(f.path));
      await submit('probe', subset);
    }
    console.log('');
  }
} catch (e) {
  failed = e;
  console.error(`\n${R}failed${X}: ${e instanceof Refused ? `${e.intent} refused — ${e.code}` : e.message}\n`);
} finally {
  if (cockpit) await cockpit.close();
}
process.exit(failed ? 1 : 0);
