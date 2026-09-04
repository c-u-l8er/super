/* check-presentation-authority — the terminal disclosure boundary, checked
   against the source rather than against the comment beside it.
   ────────────────────────────────────────────────────────────────────────

   TWO LAWS, and they pull in opposite directions.

     1  A caller outside `Ampd.Terminal.Presentation` cannot obtain a
        presentation basis without passing the human-control predicate.

     2  The control projection cannot reach the process that owns a
        terminal's bytes.

   Law 1 is why the derivation is private. D.1.3c·2c·1a repaired a bug in
   which `current?/1` and `status_of/1` satisfied the role check by BUILDING
   its argument — handing `resolve/3` a synthetic
   `%{"channel" => :human_control}`. The repair split the chain out as
   `derive/2` and then left `derive/2` **public** under `@doc false`, which
   is the unauthorised half of a resolver reachable from anywhere in the
   BEAM, one commit after removing a bypass from it. `@doc false` hides a
   name from `h`. It confines nothing.

   Law 2 is why the chain is split in two. `stream_phase/1` asks the byte
   owner and waits `stream_probe_ms()` before reading silence as `:active`.
   Correct for one presentation; `Ampd.Worker.projected/1` runs once per
   Worker over an unbounded table, inside an ordered observation the
   coordinator may re-run three times. Measured in
   `ampd/probes/projection_latency.exs`: at sixteen busy terminals the old
   shape did not complete inside the transaction budget at all.

   The two laws fight, and that is the point. Satisfying law 2 alone is
   trivial — delete the stream check — and would let a presentation open
   over a stream that has not finished becoming one. So this asserts BOTH
   directions: the projection must not reach the owner, and `resolve/3`
   must.                                                                 */

import { readFileSync } from 'node:fs';
import { dirname, resolve as rpath } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const ROOT = rpath(dirname(fileURLToPath(import.meta.url)), '..');
const SRC = `${ROOT}/ampd/lib/ampd/terminal/presentation.ex`;

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

console.log('[&] Super — terminal presentation authority\n');

const raw = readFileSync(SRC, 'utf8');

/* Doc heredocs in this module describe the boundary at length and name every
   function in it. A sweep that counted prose would report the module that
   explains the rule as the module that breaks it — the D.1.3c·2b·1 bundle
   generator made exactly this mistake, reading a docstring PROMISING no
   ioctl as the ioctl. Strip docs and line comments first, and measure the
   code. */
function codeOnly(s) {
  const out = [];
  let inDoc = false;
  for (const line of s.split('\n')) {
    if (inDoc) { if (line.includes('"""')) inDoc = false; out.push(''); continue }
    if (/^\s*(@(module)?doc\s+)?"""/.test(line)) { inDoc = true; out.push(''); continue }
    out.push(line.replace(/#.*$/, ''));
  }
  return out.join('\n');
}
const code = codeOnly(raw);

// ------------------------------------------------------------------ law 1
const pubDefs = [...code.matchAll(/^\s{2}def\s+([a-z_][A-Za-z0-9_?!]*)/gm)].map((m) => m[1]);
const privDefs = [...code.matchAll(/^\s{2}defp\s+([a-z_][A-Za-z0-9_?!]*)/gm)].map((m) => m[1]);

check(
  'the derivation is private — `derive/2`',
  privDefs.includes('derive') && !pubDefs.includes('derive'),
  'the chain without the human-control predicate is callable from outside the module',
);

check(
  'the derivation is private — `derive_semantic/2`',
  privDefs.includes('derive_semantic') && !pubDefs.includes('derive_semantic'),
  'the semantic chain without the human-control predicate is callable from outside',
);

check(
  'the basis constructor is private — `presentation/4`',
  privDefs.includes('presentation') && !pubDefs.includes('presentation'),
  'the record carrying peer_ref/attachment_ref/epochs is publicly constructible',
);

/* The set equality will fire on a NEW public function too, and that is
   deliberate: adding one to this module is adding a way to reach the
   derivation, and that should be a decision somebody makes on purpose.
   Writing the name here is that decision. */
const SURFACE = ['current?', 'presentable', 'resolve', 'schema', 'status_of'];
const surface = [...new Set(pubDefs)].sort();
check(
  `the public surface is the adjudicated five — ${SURFACE.join(', ')}`,
  JSON.stringify(surface) === JSON.stringify(SURFACE),
  `found: ${surface.join(', ')}`,
);

const humanControlCalls = (code.match(/\bhuman_control\(/g) || []).length;
// one definition head + one clause head + exactly one call site
const humanControlDefs = (code.match(/^\s{2}defp\s+human_control\(/gm) || []).length;
check(
  'the role predicate has exactly one call site',
  humanControlCalls - humanControlDefs === 1,
  `${humanControlCalls - humanControlDefs} call sites — a second one is a second policy`,
);

const resolveBody = code.slice(code.indexOf('def resolve(peer, worker_ref'), code.indexOf('defp derive('));
check(
  'that call site is `resolve/3`, and it gates `derive/2`',
  /human_control\(peer\)/.test(resolveBody) && /derive\(worker_ref, expected_generation\)/.test(resolveBody),
  'resolve/3 no longer runs the predicate before the derivation',
);

// ------------------------------------------------------------------ law 2
const phaseRefs = (code.match(/stream_phase\(/g) || []).length;
check(
  'the byte owner is asked from exactly one place in this module',
  phaseRefs === 1,
  `${phaseRefs} references to stream_phase/1`,
);

function bodyOf(name) {
  // `current?` ends in a regex metacharacter, and an unescaped `t?` matched
  // `curren(` — a check that silently measured a function that does not
  // exist, and reported the module breaking a law it holds.
  const lit = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const re = new RegExp(`^\\s{2}defp?\\s+${lit}\\(`, 'm');
  const m = code.match(re);
  if (!m) return null;
  const from = code.indexOf(m[0]);
  const rest = code.slice(from + m[0].length);
  const next = rest.search(/^\s{2}defp?\s+/m);
  return next === -1 ? rest : rest.slice(0, next);
}

check(
  'the blocking link lives in `streaming/1` and nowhere else',
  /stream_phase\(/.test(bodyOf('streaming') || ''),
  'stream_phase/1 moved out of the one function the split names',
);

for (const [fn, must, mustNot] of [
  ['status_of', 'derive_semantic(', 'streaming('],
  ['current?', 'derive_semantic(', 'streaming('],
]) {
  const b = bodyOf(fn) || '';
  check(
    `\`${fn}\` runs the semantic chain and not the probe`,
    b.includes(must) && !b.includes(mustNot),
    `${fn} reaches the byte owner — the control projection pays a per-Worker wait again`,
  );
}

const dbody = bodyOf('derive') || '';
check(
  '`resolve/3`’s chain DOES ask the byte owner',
  dbody.includes('streaming('),
  'the stream check was deleted rather than moved — a presentation can now open ' +
    'over a stream owner that does not agree it is streaming',
);

check(
  'the projection reports possession, never stream-owner agreement',
  /"PRESENT"/.test(code) && !/->\s*"ACTIVE"/.test(code),
  'status_of/1 says ACTIVE, which asserts an agreement it did not check',
);

// -------------------------------------------------------- across the tree
const grep = (pattern, path) => {
  try {
    return execFileSync('grep', ['-rn', '--include=*.ex', '--include=*.exs', '-E', pattern, path], {
      cwd: ROOT, encoding: 'utf8',
    }).trim().split('\n').filter(Boolean);
  } catch { return []; }
};

const outsideDerive = grep('Presentation\\.derive', 'ampd');
check(
  'nothing in the tree calls the derivation by name',
  outsideDerive.length === 0,
  outsideDerive.join('\n               '),
);

const worker = readFileSync(`${ROOT}/ampd/lib/ampd/worker.ex`, 'utf8');
check(
  '`Ampd.Worker.projected/1` reaches only `status_of/1`',
  /Ampd\.Terminal\.Presentation\.status_of\(/.test(worker) &&
    !/Ampd\.Terminal\.Presentation\.(resolve|derive)/.test(worker),
  'the projection reaches the authorised resolver or the raw derivation',
);

const projection = readFileSync(`${ROOT}/ampd/lib/ampd/projection.ex`, 'utf8');
check(
  '`Ampd.Projection` names neither the stream owner nor its phase',
  !/stream_phase|TerminalAttachment/.test(projection),
  'the projection module reaches the byte owner directly',
);

/* An accessor nothing reads is a comment with parentheses. The whole reason
   `stream_probe_ms/0` exists is that a bare `1_000` at a call site had no
   owner for `C14` to read it off — which is how `Ampd.Embodiment.identity/0`
   came to wait 30 000 ms inside a 15 000 ms budget. */
const c14 = readFileSync(`${ROOT}/ampd/test/effect_channel_test.exs`, 'utf8');
check(
  'the stream probe’s bound is in the deadline chain',
  /Ampd\.Carrier\.Terminal\.stream_probe_ms\(\)/.test(c14),
  'C14 does not read the one wait this slice added to the ordered surface',
);

const term = readFileSync(`${ROOT}/ampd/lib/ampd/carrier/terminal.ex`, 'utf8');
check(
  'and the call site reads the accessor rather than a literal',
  /TerminalAttachment\.state\(pid, stream_probe_ms\(\)\)/.test(term),
  'stream_phase/1 went back to a bare number',
);

console.log(`\n  ${held} held · ${failed} failed\n`);
process.exit(failed ? 1 : 0);
