/* check-intent-surface — the cockpit's intent surface, checked against the
   runtime's own declaration rather than against a comment beside it.
   ────────────────────────────────────────────────────────────────────────

   THE LAW

     The cockpit submits mutations on the human control channel and
     nothing else. It cannot ask the world a question.

   A surface with a read on it is a second way for the WebView to learn the
   world, and a second way to learn the world is a second source of truth
   however carefully the first one was built. W.1 spent four rounds making
   a projection say only what the runtime could establish; a cockpit that
   can call `operator_projection` whenever it likes has a second, unpaired,
   uncursored view — with no incarnation, no epoch and no revision attached
   to it — and can render from that instead.

   `Ampd.CommandSpec` is the ONE declaration of what every command is:
   which channel may say it, and whether it reads or mutates. So this reads
   it, rather than restating it:

     super-cockpit --intents          what the cockpit will submit
     Ampd.CommandSpec                 what each of those actually is

   **The set equality is deliberate, and it is the part that will fire one
   day.** If `ampd` grows a new `:human_control` mutation, this goes red —
   not because the new command is wrong, but because the cockpit is now the
   surface through which a person exercises authority, and an authority
   operation a person cannot reach from it is a decision somebody should
   make on purpose. Adding the name here is that decision; so is writing
   down why it is excluded.                                              */

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const APP = `${ROOT}/cockpit/target/release/super-cockpit`;

let held = 0;
let failed = 0;

function check(name, ok, detail = '') {
  if (ok) { held++; console.log(`  \x1b[32mheld\x1b[0m         ${name}`); }
  else {
    failed++;
    console.log(`  \x1b[31mFAILED\x1b[0m       ${name}`);
    if (detail) console.log(`               ${detail}`);
  }
}

if (!existsSync(APP)) {
  console.error(`no cockpit at ${APP} — build it first:\n  cd cockpit && cargo build --release`);
  process.exit(2);
}

console.log('[&] Super — cockpit intent surface\n');

const surface = JSON.parse(execFileSync(APP, ['--intents'], { encoding: 'utf8' })).intents;

/* Tab-separated rather than JSON: `ampd` carries no JSON encoder as a
   dependency, and introducing one so a gate can read its own output would
   be a strange reason to widen the runtime's dependency set. */
const raw = execFileSync(
  'mix',
  ['run', '--no-start', '-e', `
    for w <- Ampd.CommandSpec.commands() do
      s = Ampd.CommandSpec.get(w)
      IO.puts([w, "\\t", to_string(s.channel), "\\t", to_string(s.kind)])
    end
  `],
  { cwd: `${ROOT}/ampd`, encoding: 'utf8', env: { ...process.env, MIX_ENV: 'dev' } },
);

const spec = new Map();
for (const line of raw.split('\n')) {
  const [word, channel, kind] = line.trim().split('\t');
  if (word && channel && kind) spec.set(word, { channel, kind });
}

check(
  'the runtime declares its commands and this gate can read them',
  spec.size > 10,
  `${spec.size} commands parsed`,
);

const unknown = surface.filter((n) => !spec.has(n));
check(
  'every intent the cockpit can submit is a command the runtime declares',
  unknown.length === 0,
  `not in CommandSpec: ${unknown.join(', ')}`,
);

const reads = surface.filter((n) => spec.get(n)?.kind !== 'mutation');
check(
  'no intent on the surface is a read',
  reads.length === 0,
  `reads on the intent surface: ${reads.map((n) => `${n} (${spec.get(n)?.kind})`).join(', ')}`,
);

const offChannel = surface.filter((n) => spec.get(n)?.channel !== 'human_control');
check(
  'every intent is exclusive to the human control channel',
  offChannel.length === 0,
  `not human_control: ${offChannel.map((n) => `${n} (${spec.get(n)?.channel})`).join(', ')}`,
);

const humanMutations = [...spec.entries()]
  .filter(([, s]) => s.channel === 'human_control' && s.kind === 'mutation')
  .map(([w]) => w)
  .sort();

const missing = humanMutations.filter((n) => !surface.includes(n));
check(
  'every authority operation a person has is reachable from the cockpit',
  missing.length === 0,
  `declared by the runtime, absent from the cockpit: ${missing.join(', ')}`,
);

/* **The loophole this gate had, closed.**

   Every check above reads `INTENT_SURFACE`, which is a `const` in
   `worker.rs`. So the cheapest way to turn the check above green has
   always been to append three strings — after which the gate reports that
   a person can reach an operation they cannot see, cannot type into, and
   cannot press. That is W.1.4.2's dead-code-that-reads-like-a-check with
   the check and the code in different languages.

   D.1.1 left this red rather than take that shortcut. Refusing a shortcut
   is a decision one session makes; removing it is a property the tree
   keeps. So: an intent must also be *submittable from the page*, which
   means the name appears in `ui/cockpit.js` as either a row action
   (`intent: 'name'`, rendered to `data-intent`) or a form
   (`'name'` handled in `argsFor`, rendered to `data-intent-form`).

   This is still a source-level probe and it does not prove the button
   works — `cockpit-battery.mjs` drives the real webview for that. What it
   proves is that the const and the page cannot drift apart silently,
   which is the specific failure that was available here.                */
const ui = readFileSync(`${ROOT}/cockpit/ui/cockpit.js`, 'utf8');
const unsubmittable = surface.filter((n) => !ui.includes(`'${n}'`) && !ui.includes(`"${n}"`));
check(
  'every intent the cockpit declares is submittable from the page',
  unsubmittable.length === 0,
  `on INTENT_SURFACE, absent from ui/cockpit.js: ${unsubmittable.join(', ')} — ` +
    'appending a name to the const does not make a person able to perform it',
);

console.log(`\n  covering ${surface.length} of ${humanMutations.length} human-control mutations`);
/* Prefixed for the same reason the cockpit battery's is — see the note
   there, and the `host_acceptance` entry in `tools/emit-measurements.mjs`. */
console.log(`intent surface: ${held} held · ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
